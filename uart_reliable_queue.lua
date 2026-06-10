---@diagnostic disable: undefined-global

local bit32 = bit32 or bit

local json_codec = require("json_codec")
local sd = require("sdcard")
local sd_guard = require("sd_guard")
local sm4_codec = require("sm4_codec")
local error_logger = require("error_logger")
local mqtt_topics = require("mqtt_topics")

local M = {}

-- 可靠上报队列常驻在 SD 卡中，主要给三类场景共用：
-- 1. 485 传感器实时上报
-- 2. 设备周期状态上报
-- 3. 平台主动触发的历史补录
local BASE_DIR = "/sd/reliable_uart"
local RECORD_DIR = BASE_DIR .. "/records"
local META_FILE = BASE_DIR .. "/meta.json"
local SD_GUARD_TIMEOUT_MS = 5000
local PUBLISH_QOS = 2
local RETRY_INTERVAL_MS = 2000
local SERVER_COUNT = 2
local MQTT_SEND_TOPIC_PREFIX = "mqtt"
local BACKFILL_CMD = "backfill_data"
local BACKFILL_DEFAULT_LIMIT = 1000
local BACKFILL_MAX_LIMIT = 5000
local BACKFILL_SCAN_YIELD_EVERY = 20
local BACKFILL_SCAN_YIELD_MS = 5
local BACKFILL_FILE_STEP_MS = 1
local BACKFILL_PUBLISH_TAG = "uart_backfill"
local RELIABLE_SOURCE = "uart_reliable"
local PUMP_WAKE_EVENT = "UART_RELIABLE_WAKE"
local BACKFILL_START_EVENT = "UART_BACKFILL_START"

-- 运行时状态：
-- inited: 只做一次性的初始化
-- ready: SD 目录和 meta 是否已准备好
-- target_mask: 默认投递目标服务集合
-- head_seq/tail_seq: 队列头尾序号
-- online: 各 MQTT 服务在线状态
-- inflight: 各 MQTT 服务当前正在发送的记录
-- backfill.running: 是否有补录任务正在执行
local state = {
    inited = false,
    ready = false,
    device_sn = "NO_SN",
    target_mask = 0,
    head_seq = 1,
    tail_seq = 0,
    online = {},
    inflight = {},
    backfill = {
        running = false
    }
}

local load_meta
local last_encrypt_error_at = 0

-- ---------------------------------------------------------------------------
-- 基础工具
-- ---------------------------------------------------------------------------

-- 读取文本配置时统一去掉首尾空白，并在空值时回退默认值。
local function get_text(value, default)
    if type(value) ~= "string" then
        return default or ""
    end

    local trimmed = value:gsub("^%s+", ""):gsub("%s+$", "")
    if trimmed == "" then
        return default or ""
    end

    return trimmed
end

-- 把配置值安全地转成数字。
local function get_number(value, default)
    local num = tonumber(value)
    if not num then
        return default
    end

    return num
end

-- 补录最大条数做上下限保护，避免一次补太多。
local function clamp_backfill_limit(value)
    local limit = math.floor(get_number(value, BACKFILL_DEFAULT_LIMIT) or BACKFILL_DEFAULT_LIMIT)
    if limit < 1 then
        limit = 1
    end
    if limit > BACKFILL_MAX_LIMIT then
        limit = BACKFILL_MAX_LIMIT
    end
    return limit
end

-- 原始 payload 落盘前转成十六进制，避免二进制内容直接进 JSON。
local function to_hex(data)
    if type(data) ~= "string" then
        return nil
    end

    if string and string.toHex then
        local ok, hex = pcall(string.toHex, data)
        if ok and type(hex) == "string" and #hex > 0 then
            return hex
        end
    end

    local ok, hex = pcall(function()
        return data:toHex()
    end)
    if ok and type(hex) == "string" and #hex > 0 then
        return hex
    end

    return nil
end

-- 从十六进制字符串恢复原始 payload。
local function from_hex(hex)
    if type(hex) ~= "string" or #hex == 0 or (#hex % 2 ~= 0) or not hex:match("^[0-9A-Fa-f]+$") then
        return nil
    end

    return (hex:gsub("..", function(pair)
        return string.char(tonumber(pair, 16))
    end))
end

-- 递归确保目录存在。
local function ensure_dir(path)
    if io.dexist(path) then
        return true
    end

    local parent = path:match("(.+)/[^/]+$")
    if parent and parent ~= path and parent ~= "" and not io.dexist(parent) then
        ensure_dir(parent)
    end

    return io.mkdir(path) == true or io.dexist(path)
end

-- ---------------------------------------------------------------------------
-- SD 文件读写
-- ---------------------------------------------------------------------------

-- 所有 SD 读取都先重新初始化，并通过 sd_guard 串行化。
local function read_file(path)
    if not sd.init() then
        sd.mark_fault("reliable_uart_read_init_failed")
        log.error("reliable_uart", "sd init failed before read", path)
        return nil
    end

    local ok, exists, content = sd_guard.run(function(target_path)
        if not io.exists(target_path) then
            return false, nil
        end

        local file = io.open(target_path, "rb")
        if not file then
            return true, nil
        end

        local data = file:read("*a")
        file:close()
        return true, data
    end, SD_GUARD_TIMEOUT_MS, path)

    if not ok then
        sd.mark_fault("reliable_uart_read_busy")
        log.error("reliable_uart", "read file busy", path, exists or "")
        return nil
    end

    if not exists then
        return nil
    end

    return content
end

-- 覆盖写文件，记录文件和 meta 文件都走这条路径。
local function write_file(path, content)
    if not sd.init() then
        sd.mark_fault("reliable_uart_write_init_failed")
        log.error("reliable_uart", "sd init failed before write", path)
        return false
    end

    local ok, written = sd_guard.run(function(target_path, target_content)
        ensure_dir(target_path:match("(.+)/[^/]+$") or BASE_DIR)

        local file = io.open(target_path, "wb")
        if not file then
            return false
        end

        file:write(target_content or "")
        file:close()
        return true
    end, SD_GUARD_TIMEOUT_MS, path, content)

    if not ok then
        sd.mark_fault("reliable_uart_write_busy")
        log.error("reliable_uart", "write file busy", path, written or "")
        return false
    end

    return written == true
end

-- 删除一个记录文件。
-- 某些环境 remove 接口不统一，所以这里按多个实现依次尝试。
local function remove_file(path)
    if not sd.init() then
        sd.mark_fault("reliable_uart_remove_init_failed")
        log.error("reliable_uart", "sd init failed before remove", path)
        return false
    end

    local ok, removed = sd_guard.run(function(target_path)
        if os and type(os.remove) == "function" then
            local ok_remove, ret = pcall(os.remove, target_path)
            if ok_remove and ret ~= false then
                return true
            end
        end

        if io and type(io.remove) == "function" then
            local ok_remove, ret = pcall(io.remove, target_path)
            if ok_remove and ret ~= false then
                return true
            end
        end

        local file = io.open(target_path, "wb")
        if file then
            file:close()
        end
        return false
    end, SD_GUARD_TIMEOUT_MS, path)

    if not ok then
        sd.mark_fault("reliable_uart_remove_busy")
        log.error("reliable_uart", "remove file busy", path, removed or "")
        return false
    end

    return removed == true
end

-- 每条可靠记录都按序号映射成独立文件。
local function record_path(seq)
    return string.format("%s/%010d.json", RECORD_DIR, tonumber(seq) or 0)
end

-- 根据时间戳找到对应的小时日志文件，用于补录扫描历史日志。
local function history_log_path(ts)
    local t = os.date("*t", ts)
    if type(t) ~= "table" then
        return nil
    end

    return string.format("/sd/log/%04d%02d%02d/%d.log", t.year, t.month, t.day, t.hour)
end

-- 判断 SD 上某个文件是否存在。
local function sd_file_exists(path)
    if type(path) ~= "string" or path == "" then
        return false
    end

    local ok, exists = sd_guard.run(function(target_path)
        return io.exists(target_path) == true
    end, SD_GUARD_TIMEOUT_MS, path)

    return ok and exists == true
end

-- 读取并解析 JSON 文件，失败时统一打错误日志。
local function load_json_file(path)
    local content = read_file(path)
    if not content or content == "" then
        return nil
    end

    local obj, err = json_codec.decode(content)
    if not obj then
        error_logger.error("reliable_uart", "json decode failed", path, err or "")
        return nil
    end

    return obj
end

-- 编码并保存 JSON 文件。
local function save_json_file(path, obj)
    local content, err = json_codec.encode(obj)
    if not content then
        error_logger.error("reliable_uart", "json encode failed", path, err or "")
        return false
    end

    if not write_file(path, content) then
        sd.mark_fault("reliable_uart_write_failed")
        log.error("reliable_uart", "write file failed", path)
        return false
    end

    return true
end

-- meta 只记录队列头尾序号。
local function save_meta()
    return save_json_file(META_FILE, {
        head_seq = state.head_seq,
        tail_seq = state.tail_seq
    })
end

-- ---------------------------------------------------------------------------
-- 持久化元数据
-- ---------------------------------------------------------------------------

-- 初始化持久化目录和 meta。
local function ensure_storage_ready()
    if state.ready then
        return true
    end

    if not sd.init() then
        return false
    end

    ensure_dir(BASE_DIR)
    ensure_dir(RECORD_DIR)
    if not load_meta() then
        return false
    end

    state.ready = true
    return true
end

-- 对外入口统一用这个函数做“懒初始化”。
local function ensure_queue_ready()
    return state.ready or ensure_storage_ready()
end

-- 启动时恢复队列头尾；如果没有 meta，就按空队列初始化。
function load_meta()
    local meta = load_json_file(META_FILE)
    if type(meta) ~= "table" then
        state.head_seq = 1
        state.tail_seq = 0
        return save_meta()
    end

    state.head_seq = math.max(1, tonumber(meta.head_seq) or 1)
    state.tail_seq = math.max(0, tonumber(meta.tail_seq) or 0)
    if state.tail_seq < state.head_seq - 1 then
        state.tail_seq = state.head_seq - 1
    end
    return true
end

-- ---------------------------------------------------------------------------
-- 目标服务器与位掩码
-- ---------------------------------------------------------------------------

-- server_id 从 1 开始，对应 bit0/bit1...
local function bit_for_server(server_id)
    return bit32.lshift(1, server_id - 1)
end

-- 只接受当前支持范围内的服务编号。
local function normalize_server_id(server_id)
    local id = tonumber(server_id)
    if not id or id < 1 or id > SERVER_COUNT then
        return nil
    end

    return math.floor(id)
end

-- 把一个服务编号追加到位掩码里。
local function add_server_to_mask(mask, server_id)
    local id = normalize_server_id(server_id)
    if not id then
        return mask
    end

    return bit32.bor(mask, bit_for_server(id))
end

-- 把 target_servers 数组收拢成位掩码。
local function build_server_mask(target_servers)
    local mask = 0

    for _, server in ipairs(type(target_servers) == "table" and target_servers or {}) do
        local raw_id = type(server) == "table" and server.id or server
        mask = add_server_to_mask(mask, raw_id)
    end

    return mask
end

-- 这条记录是否需要发往指定服务。
local function is_server_targeted(record, server_id)
    local mask = tonumber(record and record.target_mask) or 0
    return bit32.band(mask, bit_for_server(server_id)) ~= 0
end

-- 这条记录是否已经被指定服务确认过。
local function is_server_acked(record, server_id)
    local mask = tonumber(record and record.acked_mask) or 0
    return bit32.band(mask, bit_for_server(server_id)) ~= 0
end

-- 给记录打上某个服务的 ack 标记。
local function mark_server_acked(record, server_id)
    record.acked_mask = bit32.bor(tonumber(record.acked_mask) or 0, bit_for_server(server_id))
end

-- 当前策略里，只要任意一个目标服务发送成功，就算这条记录完成。
local function has_publish_succeeded(record)
    return (tonumber(record and record.sent_at) or 0) > 0
end

-- 记录最近一次发送成功的服务和时间。
local function mark_publish_succeeded(record, server_id)
    mark_server_acked(record, server_id)
    record.sent_at = os.time()
    record.sent_server = server_id
end

-- 单独保留完成判断，后续如果策略变化更容易改。
local function is_record_complete(record)
    return has_publish_succeeded(record)
end

-- SN 会用于 msg_id 和 topic，先做一次安全清洗。
local function sanitize_sn(sn)
    sn = tostring(sn or "NO_SN")
    sn = sn:gsub("[^%w%-_]", "")
    if sn == "" then
        return "NO_SN"
    end
    return sn
end

-- msg_id 用于在异步回调里判断是不是同一条消息。
local function make_msg_id(seq)
    return string.format("%s-%d-%d", sanitize_sn(state.device_sn), os.time(), tonumber(seq) or 0)
end

-- 计算一条记录最终投递到哪些 MQTT 服务。
-- 优先级：target_mask > server_id > target_servers > 模块默认配置。
local function resolve_target_mask(opts)
    opts = type(opts) == "table" and opts or {}

    local mask = tonumber(opts.target_mask)
    if mask and mask > 0 then
        return math.floor(mask)
    end

    local server_id = normalize_server_id(opts.server_id)
    if server_id then
        return bit_for_server(server_id)
    end

    if type(opts.target_servers) == "table" then
        local built_mask = build_server_mask(opts.target_servers)
        if built_mask ~= 0 then
            return built_mask
        end
    end

    return state.target_mask
end

-- ---------------------------------------------------------------------------
-- 队列记录读写
-- ---------------------------------------------------------------------------

-- 把一段 payload 包装成可靠队列记录。
local function build_payload_record(frame, seq, opts)
    opts = type(opts) == "table" and opts or {}

    local raw_hex = to_hex(frame)
    if not raw_hex then
        return nil, "raw payload to hex failed"
    end

    local target_mask = resolve_target_mask(opts)
    if not target_mask or target_mask == 0 then
        return nil, "no enabled mqtt target"
    end

    return {
        seq = seq,
        msg_id = make_msg_id(seq),
        topic = get_text(opts.topic, mqtt_topics.get_realtime_topic(state.device_sn)),
        qos = get_number(opts.qos, PUBLISH_QOS) or PUBLISH_QOS,
        raw_hex = raw_hex,
        created_at = os.time(),
        target_mask = target_mask,
        acked_mask = 0,
        sent_at = 0,
        sent_server = 0,
        source = get_text(opts.source, RELIABLE_SOURCE)
    }
end

-- 按序号读取一条可靠记录。
local function load_record(seq)
    return load_json_file(record_path(seq))
end

-- 保存一条可靠记录。
local function save_record(record)
    if type(record) ~= "table" then
        return false
    end

    return save_json_file(record_path(record.seq), record)
end

-- 从队头开始清理已完成或已丢失的记录。
local function cleanup_head()
    local changed = false

    while state.head_seq <= state.tail_seq do
        local record = load_record(state.head_seq)
        if not record then
            state.head_seq = state.head_seq + 1
            changed = true
        elseif is_record_complete(record) then
            remove_file(record_path(state.head_seq))
            state.head_seq = state.head_seq + 1
            changed = true
        else
            break
        end
    end

    if state.tail_seq < state.head_seq - 1 then
        state.tail_seq = state.head_seq - 1
        changed = true
    end

    if changed then
        save_meta()
    end
end

-- ---------------------------------------------------------------------------
-- MQTT 应答与补录回包
-- ---------------------------------------------------------------------------

-- 补录过程的响应统一发到上行响应 topic。
local function get_report_topic()
    return mqtt_topics.get_up_resp_topic(state.device_sn)
end

-- 给指定 MQTT 服务发送一条消息。
local function publish_to_server(server_id, topic, payload, qos)
    local target = normalize_server_id(server_id)
    if not target then
        return false
    end

    sys.publish(MQTT_SEND_TOPIC_PREFIX .. target .. "_send_data_req", BACKFILL_PUBLISH_TAG, topic, payload, qos or 1)
    return true
end

-- 把 Lua table 编码成 JSON 再发出去。
local function publish_body(server_id, body)
    local payload = json_codec.encode(body)
    if not payload then
        return false
    end

    return publish_to_server(server_id, get_report_topic(), payload, 1)
end

-- 补录过程中的 start/empty/done/failed 都走这一个回包函数。
local function reply_backfill(server_id, request_id, result, reason, extra)
    local body = {
        cmd = BACKFILL_CMD,
        request_id = request_id,
        result = result,
        reason = reason,
        sn = state.device_sn,
        time = os.time()
    }

    if type(extra) == "table" then
        for k, v in pairs(extra) do
            body[k] = v
        end
    end

    publish_body(server_id, body)
end

-- ---------------------------------------------------------------------------
-- 历史日志扫描与补录
-- ---------------------------------------------------------------------------

-- 把任意时间戳落到所在小时的起点。
local function hour_floor(ts)
    local n = math.floor(tonumber(ts) or 0)
    return n - (n % 3600)
end

-- 历史日志逐行读取时先去掉空白和换行。
local function normalize_line(line)
    if type(line) ~= "string" then
        return nil
    end

    local trimmed = line:gsub("^[%s\r\n]+", ""):gsub("[%s\r\n]+$", "")
    if trimmed == "" then
        return nil
    end

    return trimmed
end

-- 从日志行 JSON 里提取 timeStamp 字段。
local function get_line_timestamp(line)
    local obj = json_codec.decode(line)
    if type(obj) ~= "table" then
        return nil
    end

    return get_number(obj.timeStamp)
end

-- 执行一次完整补录：
-- 1. 回复 accepted
-- 2. 按小时扫描历史日志
-- 3. 命中的记录重新入可靠队列
-- 4. 回复最终状态
local function process_backfill_request(req)
    local server_id = req.server_id
    local request_id = req.request_id
    local start_time = req.start_time
    local end_time = req.end_time
    local limit = req.limit

    local scanned_files = 0
    local matched = 0
    local enqueued = 0
    local failed = 0
    local last_error = ""
    local truncated = false

    -- 先回一条 accepted，避免平台长时间等待时误以为设备没收到命令。
    reply_backfill(server_id, request_id, 0, "accepted", {
        status = "start",
        startTime = start_time,
        endTime = end_time,
        limit = limit
    })

    -- 历史日志按“小时文件”组织，所以这里也按小时粒度扫描。
    for ts = hour_floor(start_time), hour_floor(end_time), 3600 do
        local path = history_log_path(ts)
        local exists = sd_file_exists(path)

        if path and exists then
            scanned_files = scanned_files + 1
            log.info("backfill", "scan", path, "request", request_id)

            local content = read_file(path)
            if content and content ~= "" then
                -- 一行就是一条 JSON 历史记录，逐行筛时间窗口。
                for raw_line in content:gmatch("[^\r\n]+") do
                    local line = normalize_line(raw_line)
                    if line then
                        local line_ts = get_line_timestamp(line)
                        if line_ts and line_ts >= start_time and line_ts <= end_time then
                            matched = matched + 1
                            -- 命中的历史数据重新进入可靠队列，
                            -- 后面的加密、发送、重试继续复用现有主流程。
                            local ok, err = M.enqueue_frame(line)
                            if ok then
                                enqueued = enqueued + 1
                            else
                                failed = failed + 1
                                last_error = tostring(err or "enqueue_failed")
                            end

                            if matched >= limit then
                                truncated = true
                                break
                            end

                            if (matched % BACKFILL_SCAN_YIELD_EVERY) == 0 then
                                sys.wait(BACKFILL_SCAN_YIELD_MS)
                            end
                        end
                    end
                end
            else
                failed = failed + 1
                last_error = "open_log_failed"
            end
        end

        if truncated then
            break
        end

        sys.wait(BACKFILL_FILE_STEP_MS)
    end

    -- 没命中且没失败，明确回复 empty，便于平台区分“无数据”和“执行失败”。
    if matched == 0 and failed == 0 then
        reply_backfill(server_id, request_id, 0, "empty", {
            status = "empty",
            startTime = start_time,
            endTime = end_time,
            limit = limit,
            scanned_files = scanned_files,
            matched = 0,
            enqueued = 0,
            failed = 0,
            truncated = false
        })
        return
    end

    local reason = "ok"
    local status = "done"
    if failed > 0 and enqueued == 0 then
        reason = last_error ~= "" and last_error or "failed"
        status = "failed"
    elseif failed > 0 then
        reason = "partial"
        status = "partial"
    elseif truncated then
        reason = "truncated"
        status = "partial"
    end

    reply_backfill(server_id, request_id, status == "failed" and -1 or 0, reason, {
        status = status,
        startTime = start_time,
        endTime = end_time,
        limit = limit,
        scanned_files = scanned_files,
        matched = matched,
        enqueued = enqueued,
        failed = failed,
        truncated = truncated,
        last_error = last_error ~= "" and last_error or nil
    })
end

-- ---------------------------------------------------------------------------
-- 发送泵与回执处理
-- ---------------------------------------------------------------------------

-- 清除某个服务当前的 inflight 占位。
local function clear_inflight(server_id)
    state.inflight[server_id] = nil
end

-- 发布前构造最终 payload：
-- 优先用内存里的 payload；没有的话从 raw_hex 还原，再走 SM4 加密。
local function build_publish_payload(record)
    if type(record.payload) == "string" and #record.payload > 0 then
        return true, record.payload
    end

    local raw_payload = record and record.raw_payload
    if (type(raw_payload) ~= "string" or raw_payload == "") and type(record and record.raw_hex) == "string" then
        raw_payload = from_hex(record.raw_hex)
    end

    if type(raw_payload) ~= "string" or raw_payload == "" then
        return false, "raw payload missing"
    end

    return sm4_codec.encrypt_to_hex(raw_payload)
end

-- 可靠发送采用“事件唤醒 + 定时兜底”模式，这里统一发唤醒事件。
local function wake_pump()
    sys.publish(PUMP_WAKE_EVENT)
end

-- MQTT 发送回调。
-- 这里只认当前 inflight 且 msg_id 匹配的回调，避免旧回调误伤新状态。
local function publish_cb(result, para)
    local server_id = para and para.server_id
    local inflight = server_id and state.inflight[server_id] or nil
    if not inflight then
        return
    end

    if inflight.seq ~= para.seq or inflight.msg_id ~= para.msg_id then
        return
    end

    if result then
        -- 成功后把记录标记为完成，并尝试继续泵下一条。
        local record = load_record(inflight.seq)
        if record and record.msg_id == inflight.msg_id then
            mark_publish_succeeded(record, server_id)
            save_record(record)
            cleanup_head()
        end

        clear_inflight(server_id)
        wake_pump()
    else
        -- 失败时不删记录，只释放 inflight，让后续重试继续接管。
        clear_inflight(server_id)
        wake_pump()
    end
end

-- 向指定服务发送一条可靠记录，并挂上异步回调。
local function send_record_to_server(server_id, record)
    local ok, payload_or_err = build_publish_payload(record)
    if not ok then
        local now = os.time()
        if now - last_encrypt_error_at >= 10 then
            last_encrypt_error_at = now
            error_logger.error("reliable_uart", "build publish payload failed", payload_or_err or "")
        end
        return false
    end

    local publish_topic = get_text(record and record.topic, mqtt_topics.get_realtime_topic(state.device_sn))
    local publish_tag = get_text(record and record.source, RELIABLE_SOURCE)
    local send_topic = MQTT_SEND_TOPIC_PREFIX .. server_id .. "_send_data_req"
    -- 先占住 inflight，避免同一个服务并发发出多条记录。
    state.inflight[server_id] = {
        seq = record.seq,
        msg_id = record.msg_id
    }

    sys.publish(
        send_topic,
        publish_tag,
        publish_topic,
        payload_or_err,
        record.qos or PUBLISH_QOS,
        {
            func = publish_cb,
            para = {
                server_id = server_id,
                seq = record.seq,
                msg_id = record.msg_id
            }
        }
    )
    return true
end

-- 找到某个服务下一条应该发送的记录。
local function find_next_record_for_server(server_id)
    for seq = state.head_seq, state.tail_seq do
        local record = load_record(seq)
        if record and not is_record_complete(record) and is_server_targeted(record, server_id) and not is_server_acked(record, server_id) then
            return record
        end
    end

    return nil
end

-- 单个服务的发送泵：在线且没有 inflight 时才继续取下一条。
local function pump_server(server_id)
    if not state.ready or not state.online[server_id] then
        return
    end

    local inflight = state.inflight[server_id]
    if inflight then
        return
    end

    local record = find_next_record_for_server(server_id)
    if record then
        send_record_to_server(server_id, record)
    end
end

-- 每次唤醒先清理队头，再分别驱动所有服务。
local function pump_all()
    cleanup_head()

    for server_id = 1, SERVER_COUNT do
        pump_server(server_id)
    end
end

-- ---------------------------------------------------------------------------
-- 对外接口
-- ---------------------------------------------------------------------------

-- 初始化默认 SN 和默认目标服务集合。
function M.init(opts)
    opts = type(opts) == "table" and opts or {}
    state.device_sn = sanitize_sn(opts.device_sn)
    state.target_mask = build_server_mask(opts.target_servers)

    if not state.inited then
        for i = 1, SERVER_COUNT do
            state.online[i] = false
            state.inflight[i] = nil
        end
        state.inited = true
    end

    if not ensure_storage_ready() then
        error_logger.error("reliable_uart", "sd init failed, reliable queue disabled")
        return false
    end

    return true
end

-- 入队一条新的可靠 payload。
-- 成功返回 true, msg_id；失败返回 false, reason。
function M.enqueue_payload(payload, opts)
    if type(payload) ~= "string" or payload == "" then
        return false, "invalid payload"
    end

    if not ensure_queue_ready() then
        return false, "reliable queue not ready"
    end

    local seq = state.tail_seq + 1
    local record, err = build_payload_record(payload, seq, opts)
    if not record then
        return false, err
    end

    if not save_record(record) then
        return false, "save record failed"
    end

    state.tail_seq = seq
    if not save_meta() then
        return false, "save meta failed"
    end

    wake_pump()
    return true, record.msg_id
end

-- 兼容旧调用名，frame 本质上也是一段字符串 payload
-- 兼容旧调用名，frame 本质上也是字符串 payload。
function M.enqueue_frame(frame)
    return M.enqueue_payload(frame)
end

-- 处理 MQTT 下发命令。
-- 当前这里只接管 backfill_data，其它命令仍由上层继续处理。
function M.handle_command(server_id, obj)
    if type(obj) ~= "table" then
        return false
    end

    local cmd = get_text(obj.cmd, "")
    if cmd ~= BACKFILL_CMD then
        return false
    end

    local request_id = get_text(obj.request_id, "backfill-" .. tostring(os.time()))
    local start_time = get_number(obj.startTime or obj.start_time)
    local end_time = get_number(obj.endTime or obj.end_time)
    local limit = clamp_backfill_limit(obj.limit or obj.maxCount)

    if not start_time or not end_time or start_time <= 0 or end_time <= 0 then
        reply_backfill(server_id, request_id, -1, "invalid_time_range")
        return true
    end

    if end_time < start_time then
        reply_backfill(server_id, request_id, -1, "invalid_time_range")
        return true
    end

    if not ensure_queue_ready() then
        reply_backfill(server_id, request_id, -1, "sd_not_ready")
        return true
    end

    if state.target_mask == 0 then
        reply_backfill(server_id, request_id, -1, "no_enabled_mqtt_target")
        return true
    end

    -- 同一时刻只允许一个补录任务，避免并发扫卡和重复入队。
    if state.backfill.running then
        reply_backfill(server_id, request_id, -1, "busy")
        return true
    end

    state.backfill.running = true
    -- 真正的补录逻辑放到后台任务里跑，这里只做参数校验和任务投递。
    sys.publish(BACKFILL_START_EVENT, {
        server_id = server_id,
        request_id = request_id,
        start_time = math.floor(start_time),
        end_time = math.floor(end_time),
        limit = limit
    })
    return true
end

-- ---------------------------------------------------------------------------
-- 事件订阅与后台任务
-- ---------------------------------------------------------------------------

-- 连接状态变化时更新 online 标记，并唤醒发送泵重新调度。
local function make_conn_handler(server_id)
    return function(online)
        state.online[server_id] = online == true
        if not state.online[server_id] then
            clear_inflight(server_id)
        end
        wake_pump()
    end
end

sys.subscribe("MQTT1_CONN_EVENT", make_conn_handler(1))
sys.subscribe("MQTT2_CONN_EVENT", make_conn_handler(2))
sys.subscribe("SM4_CONFIG_READY", wake_pump)

-- 补录后台任务：串行执行补录请求，避免多个补录任务同时扫 SD。
sys.taskInit(function()
    while true do
        local ok, req = sys.waitUntil(BACKFILL_START_EVENT)
        if ok and type(req) == "table" then
            local done_ok, err = pcall(process_backfill_request, req)
            if not done_ok then
                error_logger.error("reliable_uart", "backfill failed", err or "")
                reply_backfill(req.server_id, req.request_id, -1, "internal_error", {
                    status = "failed"
                })
            end
            state.backfill.running = false
        end
    end
end)

-- 可靠发送后台任务：收到唤醒事件就立刻尝试发送，没有事件也按定时兜底重试。
sys.taskInit(function()
    while true do
        sys.waitUntil(PUMP_WAKE_EVENT, RETRY_INTERVAL_MS)
        if ensure_queue_ready() then
            pump_all()
        end
    end
end)

return M
