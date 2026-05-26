---@diagnostic disable: undefined-global

local bit32 = bit32 or bit

local json_codec = require("json_codec")
local sd = require("sdcard")
local sd_guard = require("sd_guard")
local sm4_codec = require("sm4_codec")
local error_logger = require("error_logger")
local mqtt_topics = require("mqtt_topics")

local M = {}

-- Persistent queue stored on SD card. It is shared by:
-- 1. UART1/485 normal upload path
-- 2. 10-minute device status report path
-- 3. Manual backfill command path
local BASE_DIR = "/sd/reliable_uart"
local RECORD_DIR = BASE_DIR .. "/records"
local META_FILE = BASE_DIR .. "/meta.json"
local PUBLISH_QOS = 2
local RETRY_INTERVAL_MS = 2000
local SERVER_COUNT = 2
local MQTT_SEND_TOPIC_PREFIX = "mqtt"
local BACKFILL_CMD = "backfill_data"
local BACKFILL_DEFAULT_LIMIT = 1000
local BACKFILL_MAX_LIMIT = 5000

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

-- Basic type / text helpers
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

local function get_number(value, default)
    local num = tonumber(value)
    if not num then
        return default
    end

    return num
end

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

local function from_hex(hex)
    if type(hex) ~= "string" or #hex == 0 or (#hex % 2 ~= 0) or not hex:match("^[0-9A-Fa-f]+$") then
        return nil
    end

    return (hex:gsub("..", function(pair)
        return string.char(tonumber(pair, 16))
    end))
end

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

-- SD file read / write / remove helpers
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
    end, 5000, path)

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
    end, 5000, path, content)

    if not ok then
        sd.mark_fault("reliable_uart_write_busy")
        log.error("reliable_uart", "write file busy", path, written or "")
        return false
    end

    return written == true
end

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
    end, 5000, path)

    if not ok then
        sd.mark_fault("reliable_uart_remove_busy")
        log.error("reliable_uart", "remove file busy", path, removed or "")
        return false
    end

    return removed == true
end

local function record_path(seq)
    return string.format("%s/%010d.json", RECORD_DIR, tonumber(seq) or 0)
end

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

local function save_meta()
    return save_json_file(META_FILE, {
        head_seq = state.head_seq,
        tail_seq = state.tail_seq
    })
end

-- Storage bootstrap
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

-- Per-server bitmask helpers
local function bit_for_server(server_id)
    return bit32.lshift(1, server_id - 1)
end

local function is_server_targeted(record, server_id)
    local mask = tonumber(record and record.target_mask) or 0
    return bit32.band(mask, bit_for_server(server_id)) ~= 0
end

local function is_server_acked(record, server_id)
    local mask = tonumber(record and record.acked_mask) or 0
    return bit32.band(mask, bit_for_server(server_id)) ~= 0
end

local function mark_server_acked(record, server_id)
    record.acked_mask = bit32.bor(tonumber(record.acked_mask) or 0, bit_for_server(server_id))
end

local function has_publish_succeeded(record)
    return (tonumber(record and record.sent_at) or 0) > 0
end

local function mark_publish_succeeded(record, server_id)
    mark_server_acked(record, server_id)
    record.sent_at = os.time()
    record.sent_server = server_id
end

local function is_record_complete(record)
    return has_publish_succeeded(record)
end

local function sanitize_sn(sn)
    sn = tostring(sn or "NO_SN")
    sn = sn:gsub("[^%w%-_]", "")
    if sn == "" then
        return "NO_SN"
    end
    return sn
end

local function make_msg_id(seq)
    return string.format("%s-%d-%d", sanitize_sn(state.device_sn), os.time(), tonumber(seq) or 0)
end

local function resolve_target_mask(opts)
    opts = type(opts) == "table" and opts or {}

    local mask = tonumber(opts.target_mask)
    if mask and mask > 0 then
        return math.floor(mask)
    end

    local server_id = tonumber(opts.server_id)
    if server_id and server_id >= 1 and server_id <= SERVER_COUNT then
        return bit_for_server(server_id)
    end

    local target_servers = type(opts.target_servers) == "table" and opts.target_servers or nil
    if target_servers then
        local built_mask = 0
        for _, server in ipairs(target_servers) do
            local id = tonumber(type(server) == "table" and server.id or server)
            if id and id >= 1 and id <= SERVER_COUNT then
                built_mask = bit32.bor(built_mask, bit_for_server(id))
            end
        end
        if built_mask ~= 0 then
            return built_mask
        end
    end

    return state.target_mask
end

-- Record build / load / save helpers
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
        source = get_text(opts.source, "uart_reliable")
    }
end

local function load_record(seq)
    return load_json_file(record_path(seq))
end

local function save_record(record)
    if type(record) ~= "table" then
        return false
    end

    return save_json_file(record_path(record.seq), record)
end

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

-- MQTT publish / reply helpers
local function get_report_topic()
    return mqtt_topics.get_up_resp_topic(state.device_sn)
end

local function publish_to_server(server_id, topic, payload, qos)
    local target = tonumber(server_id)
    if not target or target < 1 or target > SERVER_COUNT then
        return false
    end

    sys.publish("mqtt" .. target .. "_send_data_req", "uart_backfill", topic, payload, qos or 1)
    return true
end

local function publish_body(server_id, body)
    local payload = json_codec.encode(body)
    if not payload then
        return false
    end

    return publish_to_server(server_id, get_report_topic(), payload, 1)
end

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

-- Historical log scan helpers used by backfill
local function hour_floor(ts)
    local n = math.floor(tonumber(ts) or 0)
    return n - (n % 3600)
end

local function build_history_log_path(ts)
    local t = os.date("*t", ts)
    if type(t) ~= "table" then
        return nil
    end

    return string.format("/sd/log/%04d%02d%02d/%d.log", t.year, t.month, t.day, t.hour)
end

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

local function get_line_timestamp(line)
    local obj = json_codec.decode(line)
    if type(obj) ~= "table" then
        return nil
    end

    return get_number(obj.timeStamp)
end

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

    reply_backfill(server_id, request_id, 0, "accepted", {
        status = "start",
        startTime = start_time,
        endTime = end_time,
        limit = limit
    })

    for ts = hour_floor(start_time), hour_floor(end_time), 3600 do
        local path = build_history_log_path(ts)
        local exists = false
        if path then
            local ok_exists, exists_result = sd_guard.run(function(target_path)
                return io.exists(target_path) == true
            end, 5000, path)
            exists = ok_exists and exists_result == true
        end

        if path and exists then
            scanned_files = scanned_files + 1
            log.info("backfill", "scan", path, "request", request_id)

            local content = read_file(path)
            if content and content ~= "" then
                for raw_line in content:gmatch("[^\r\n]+") do
                    local line = normalize_line(raw_line)
                    if line then
                        local line_ts = get_line_timestamp(line)
                        if line_ts and line_ts >= start_time and line_ts <= end_time then
                            matched = matched + 1
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

                            if (matched % 20) == 0 then
                                sys.wait(5)
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

        sys.wait(1)
    end

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

-- Inflight publish state and queue pump helpers
local function clear_inflight(server_id)
    state.inflight[server_id] = nil
end

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

local function wake_pump()
    sys.publish("UART_RELIABLE_WAKE")
end

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
        local record = load_record(inflight.seq)
        if record and record.msg_id == inflight.msg_id then
            mark_publish_succeeded(record, server_id)
            save_record(record)
            cleanup_head()
        end

        clear_inflight(server_id)
        wake_pump()
    else
        clear_inflight(server_id)
        wake_pump()
    end
end

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
    local publish_tag = get_text(record and record.source, "uart_reliable")
    local send_topic = MQTT_SEND_TOPIC_PREFIX .. server_id .. "_send_data_req"
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

local function find_next_record_for_server(server_id)
    for seq = state.head_seq, state.tail_seq do
        local record = load_record(seq)
        if record and not is_record_complete(record) and is_server_targeted(record, server_id) and not is_server_acked(record, server_id) then
            return record
        end
    end

    return nil
end

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

local function pump_all()
    cleanup_head()

    for server_id = 1, SERVER_COUNT do
        pump_server(server_id)
    end
end

-- Public queue API
function M.init(opts)
    opts = type(opts) == "table" and opts or {}
    state.device_sn = sanitize_sn(opts.device_sn)
    state.target_mask = 0

    local target_servers = type(opts.target_servers) == "table" and opts.target_servers or {}
    for _, server in ipairs(target_servers) do
        local id = tonumber(server.id)
        if id and id >= 1 and id <= SERVER_COUNT then
            state.target_mask = bit32.bor(state.target_mask, bit_for_server(id))
        end
    end

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

function M.enqueue_payload(payload, opts)
    if type(payload) ~= "string" or payload == "" then
        return false, "invalid payload"
    end

    if not state.ready and not ensure_storage_ready() then
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

function M.enqueue_frame(frame)
    return M.enqueue_payload(frame)
end

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

    if not state.ready and not ensure_storage_ready() then
        reply_backfill(server_id, request_id, -1, "sd_not_ready")
        return true
    end

    if state.target_mask == 0 then
        reply_backfill(server_id, request_id, -1, "no_enabled_mqtt_target")
        return true
    end

    if state.backfill.running then
        reply_backfill(server_id, request_id, -1, "busy")
        return true
    end

    state.backfill.running = true
    sys.publish("UART_BACKFILL_START", {
        server_id = server_id,
        request_id = request_id,
        start_time = math.floor(start_time),
        end_time = math.floor(end_time),
        limit = limit
    })
    return true
end

-- MQTT online/offline state hooks
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
sys.taskInit(function()
    while true do
        local ok, req = sys.waitUntil("UART_BACKFILL_START")
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

sys.taskInit(function()
    while true do
        sys.waitUntil("UART_RELIABLE_WAKE", RETRY_INTERVAL_MS)
        if state.ready or ensure_storage_ready() then
            pump_all()
        end
    end
end)

return M
