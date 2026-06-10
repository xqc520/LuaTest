---@diagnostic disable: undefined-global

local json_codec = require("json_codec")
local flash_config = require("flash_config")
local bounded_queue = require("bounded_queue")
local uart_reliable_queue = require("uart_reliable_queue")
local mqtt_topics = require("mqtt_topics")

local M = {}

-- 审核版说明：
-- 1. 仅补充中文注释、整理注释表达与空行，不改现有功能。
-- 2. 常量取值、时序、队列策略、对外接口全部保持原样。
-- 3. 原文件正常运行，这里只做“更容易看懂”的整理。

-- ---------------------------------------------------------------------------
-- UART1 / RS485 物理配置
-- ---------------------------------------------------------------------------

local UART_ID = 1
local UART_BAUD = 115200
local UART_RXTX_PIN = 17
local UART_RX_PIN_LEVEL = 0
local UART_TXRX_DELAY_US = 1666

-- ---------------------------------------------------------------------------
-- 收发队列容量配置
-- ---------------------------------------------------------------------------

local RX_BUFFER_LIMIT = 4096
-- 如果总线数据流没有换行符，则在 UART 接收静默达到该时长后，
-- 强制把当前缓存切成一帧。
local RX_FORCE_FLUSH_LIMIT = 3072
local RX_IDLE_TIMEOUT_MS = 15
local RX_TASK_BATCH_SIZE = 8
local FRAME_QUEUE_MAX_ITEMS = 128
local FRAME_QUEUE_MAX_BYTES = 64 * 1024
local TX_QUEUE_MAX_ITEMS = 64
local TX_QUEUE_MAX_BYTES = 16 * 1024

-- ---------------------------------------------------------------------------
-- 共享 BUSY 线仲裁
-- ---------------------------------------------------------------------------
--
-- 接线时参考的硬件焊盘标号：
--   BUSY_DEC -> module pad 24
--   BUSY_IO  -> module pad 98
--
-- gpio.setup/gpio.get/gpio.set 使用的是 GPIO 编号，不是模块焊盘号。
-- 根据 pins_air8000a.json：
--   pad 24 -> GPIO21
--   pad 98 -> GPIO3
local BUSY_DEC_GPIO_NUMBER = 21
local BUSY_IO_GPIO_NUMBER = 3

local BUSY_LOCK_BACKOFF_MIN_MS = 8
local BUSY_LOCK_BACKOFF_MAX_MS = 25

local TX_SENT_EVENT = "UART1_TX_SENT"
local TX_SENT_TIMEOUT_MIN_MS = 200
local TX_SENT_TIMEOUT_PER_BYTE_MS = 2
local TX_SEND_RETRY_LIMIT = 3
local TX_SEND_RETRY_BACKOFF_MS = 30

-- ---------------------------------------------------------------------------
-- MQTT 控制命令
-- ---------------------------------------------------------------------------

-- MQTT 服务端可以通过该命令向 RS485 总线写入原始数据。
-- 主题：sys/{SN}/json/down/cmd
-- 示例：
--   {"cmd":"bus_send","request_id":"bus-001","encoding":"hex","data":"010300000002C40B"}
--   {"cmd":"bus_send","request_id":"bus-002","encoding":"text","data":"hello","append_crlf":true}
local BUS_SEND_CMD = "bus_send"
local MQTT_SERVER_COUNT = 2
-- 周期性向 RS485 总线广播简化版服务器信息 JSON。
-- 报文尽量短，方便 STM32 侧快速解析。
local SERVER_INFO_INTERVAL_MS = 60 * 1000
local SERVER_INFO_CMD = "Server"

uart.setup(
    UART_ID,
    UART_BAUD,
    8,
    1,
    uart.NONE,
    uart.LSB,
    1024,
    UART_RXTX_PIN,
    UART_RX_PIN_LEVEL,
    UART_TXRX_DELAY_US
)

-- BUSY_IO: 输出脚，用来声明“当前设备正在占用总线”。
-- BUSY_DEC: 输入脚，用来检测“总线当前是否繁忙”。
gpio.setup(BUSY_IO_GPIO_NUMBER, 1)  -- 设置 BUSY_IO 为输出
gpio.setup(BUSY_DEC_GPIO_NUMBER, nil, gpio.PULLDOWN) -- 设置 BUSY_DEC 为下拉输入
gpio.set(BUSY_IO_GPIO_NUMBER, 0)    --初始状态总线空闲，输出低电平

-- 给随机退避逻辑初始化随机种子。
math.randomseed(os.time())

local rx_buf = ""
local frame_queue = bounded_queue.new({
    name = "uart1_frame_queue",
    max_items = FRAME_QUEUE_MAX_ITEMS,
    max_bytes = FRAME_QUEUE_MAX_BYTES
})
local tx_queue = bounded_queue.new({
    name = "uart1_tx_queue",
    max_items = TX_QUEUE_MAX_ITEMS,
    max_bytes = TX_QUEUE_MAX_BYTES
})
local enabled_servers = flash_config.getEnabledServers()
local last_warn_at = {}
local last_rx_at = 0
local bus_lock_held = false
local tx_sent_seq = 0
local push_tx

uart_reliable_queue.init({
    device_sn = EPD_STATUS and EPD_STATUS.get_sn and EPD_STATUS.get_sn() or "NO_SN",
    target_servers = enabled_servers
})

-- ---------------------------------------------------------------------------
-- 通用小工具函数
-- ---------------------------------------------------------------------------

-- 同一类告警 5 秒内只打印一次，避免日志刷屏。
local function warn_throttled(key, ...)
    local now = os.time()
    local last = last_warn_at[key] or 0
    if now - last >= 5 then
        last_warn_at[key] = now
        log.warn(...)
    end
end

-- 优先使用 MCU tick 获取毫秒时间；没有 tick 时退化到 os.time。
local function now_ms()
    if mcu and type(mcu.ticks) == "function" and type(mcu.hz) == "function" then
        local hz = tonumber(mcu.hz()) or 0
        if hz > 0 then
            return math.floor((tonumber(mcu.ticks()) or 0) * 1000 / hz)
        end
    end

    return (tonumber(os.time()) or 0) * 1000
end

last_rx_at = now_ms()

-- 统一清洗字符串入参：去首尾空白，空值回退到默认值。
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

local function get_bool(value)
    return value == true or value == 1 or value == "1" or value == "true" or value == "TRUE"
end

-- 十六进制字符串转原始字节；格式不合法时返回 nil。
local function from_hex(text)
    local value = get_text(text, ""):gsub("%s+", "")
    if value == "" or (#value % 2) ~= 0 or not value:match("^[0-9A-Fa-f]+$") then
        return nil
    end

    return (value:gsub("..", function(pair)
        return string.char(tonumber(pair, 16))
    end))
end

local function get_device_sn()
    return mqtt_topics.get_device_sn("NO_SN")
end

-- MQTT1 和 MQTT2 使用相同的响应主题格式，但总线控制/回报
-- 目前仍只转发到 MQTT1。
local function publish_to_server(server_id, body)
    local target = tonumber(server_id)
    if not target or target < 1 or target > MQTT_SERVER_COUNT then
        return false
    end

    local payload = json_codec.encode(body)
    if not payload then
        return false
    end

    local topic = mqtt_topics.get_up_resp_topic(get_device_sn())
    sys.publish("mqtt" .. target .. "_send_data_req", "bus_cmd", topic, payload, 1)
    return true
end

-- 回应 bus_send 指令的处理结果，便于服务端做闭环确认。
local function reply_send(server_id, request_id, result, reason, extra)
    local body = {
        cmd = BUS_SEND_CMD,
        request_id = request_id,
        result = result,
        reason = reason,
        sn = get_device_sn(),
        time = os.time()
    }

    if type(extra) == "table" then
        if extra.adress ~= nil then
            body.adress = extra.adress
        end

        if extra.u_cmd ~= nil and extra.u_cmd ~= "" then
            body.u_cmd = extra.u_cmd
        end
    end

    publish_to_server(server_id, body)
end

-- 周期广播的 Server 信息只在这里使用，直接在此处组包，减少来回跳转。
local function queue_periodic_server_info()
    local payload, err = json_codec.encode({
        [SERVER_INFO_CMD] = {
            SN = get_device_sn(),
            NtpTimeStamp = tostring((tonumber(os.time()) or 0))
        }
    })
    if not payload then
        warn_throttled("bus_server_info_encode", "UART", "server info encode failed", err or "")
        return false
    end

    -- 追加换行符，方便总线侧设备按行切分帧。
    payload = payload .. "\r\n"
    local ok, reason = push_tx(payload)
    if not ok then
        warn_throttled("bus_server_info_queue", "UART", "server info queue failed", reason or "")
        return false
    end

    log.info("bus_server", "queued", "sn=" .. get_device_sn(), "ts=" .. tostring(os.time() or 0))
    return true
end

-- ---------------------------------------------------------------------------
-- 发送侧状态辅助函数
-- ---------------------------------------------------------------------------

-- 读取当前发送链路状态。
-- bus_busy：
--   true  -> 其他节点正在发送，或当前节点已经持有总线锁。
-- queue_pending：
--   true  -> UART1 发送队列里仍有待发送数据。
local function get_send_status()
    return {
        bus_busy = bus_lock_held == true or gpio.get(BUSY_DEC_GPIO_NUMBER) == 1,
        queue_pending = tx_queue:length() > 0
    }
end

local function calc_tx_timeout_ms(data_len)
    local payload_len = tonumber(data_len) or 0
    return math.max(TX_SENT_TIMEOUT_MIN_MS, payload_len * TX_SENT_TIMEOUT_PER_BYTE_MS + TX_SENT_TIMEOUT_MIN_MS)
end

--- 给485总线加锁
-- @return boolean true 成功
function bus_locked()
    local timeout = 0

    -- 第一轮忙检测
    while gpio.get(BUSY_DEC_GPIO_NUMBER) == 1 do -- GPIO_PIN_SET 对应 1
        -- 对应 C 代码中的 RNG_Get_RandnomRange(300, 800)。
        timeout = math.random(300, 800)
        log.debug("BUS", "总线正在使用; 稍等片刻 " .. timeout .. " ms")
        sys.wait(timeout)
    end

    -- 占用总线
    -- 注意：根据你的 C 代码逻辑，占用是 WritePin(1)
    gpio.set(BUSY_IO_GPIO_NUMBER, 1)
    log.info("BUS", "总线锁定成功")

    return true
end

--- 给485总线解锁
-- @return boolean true 成功
function bus_unlocked()
    -- 释放总线
    gpio.set(BUSY_IO_GPIO_NUMBER, 0)

    -- 对应 C 代码中的 osDelay(5)
    sys.wait(5)

    log.info("BUS", "总线解锁释放")
    return true
end
-- 去掉帧首尾空白/换行，空帧直接丢弃。
local function normalize_frame(frame)
    if type(frame) ~= "string" then
        return nil
    end

    frame = frame:gsub("^[%s\r\n]+", ""):gsub("[%s\r\n]+$", "")
    if #frame == 0 then
        return nil
    end

    return frame
end

-- ---------------------------------------------------------------------------
-- 接收帧队列
-- ---------------------------------------------------------------------------

local function push_frame(frame)
    frame = normalize_frame(frame)
    if not frame then
        return false
    end

    local ok, reason, dropped = frame_queue:push(frame, #frame)
    if dropped and dropped > 0 then
        warn_throttled(
            "uart_frame_drop",
            "UART",
            "frame queue overflow, dropped",
            dropped,
            "remain",
            frame_queue:length(),
            "bytes",
            frame_queue:used_bytes()
        )
    end

    if not ok then
        warn_throttled("uart_frame_reject", "UART", "drop frame", reason, #frame)
        return false
    end

    return true
end

-- ---------------------------------------------------------------------------
-- 发送队列
-- ---------------------------------------------------------------------------

-- 放入发送队列，不在这里直接写 UART。
push_tx = function(data)
    if type(data) ~= "string" or #data == 0 then
        return false, "empty_data"
    end

    local ok, reason, dropped = tx_queue:push(data, #data)
    if dropped and dropped > 0 then
        warn_throttled(
            "uart_tx_drop",
            "UART",
            "tx queue overflow, dropped",
            dropped,
            "remain",
            tx_queue:length(),
            "bytes",
            tx_queue:used_bytes()
        )
    end

    if not ok then
        warn_throttled("uart_tx_reject", "UART", "drop tx data", reason, #data)
        return false, reason or "queue_reject"
    end

    return true, "queued"
end

-- ---------------------------------------------------------------------------
-- MQTT 下行 -> UART 原始字节
-- ---------------------------------------------------------------------------

-- 把服务端命令负载转换成真正的 UART 字节流。
-- encoding=text : 原样发送 obj.data
-- encoding=hex  : obj.data 必须是十六进制字符串，随后转换成二进制字节
-- append_crlf   : 可选，是否在负载后追加 "\r\n"
-- 如果没有 obj.data，服务端也可以直接下发简写版总线命令：
--   {"cmd":"bus_send","adress":1,"u_cmd":"freq","v":60}
-- 设备会自动拼成：
--   {"adress":1,"cmd":"freq","v":60}\r\n
-- 或者服务端可以直接发送 Server 对象：
--   {"cmd":"bus_send","Server":{"SN":"001265CE","sensorAddr":33554945,"sensorName":"XT_278","sendFrequency":1}}
-- 设备会把同样的 JSON 发送到 BUS/485，并追加 "\r\n"。
-- 把简写版总线命令补全成完整 JSON，再转成 UART 文本帧。
local function build_short_bus_json_payload(obj)
    if type(obj) ~= "table" then
        return nil, "invalid_bus_json"
    end

    local adress = obj.adress ~= nil and obj.adress or obj.id
    local u_cmd = get_text(obj.u_cmd, "")
    if adress == nil or u_cmd == "" then
        return nil, "missing_bus_json_fields"
    end

    local reserved = {
        cmd = true,
        request_id = true,
        encoding = true,
        data = true,
        append_crlf = true,
        require_idle = true,
        u_cmd = true,
        id = true,
        adress = true
    }

    local bus_obj = {
        adress = adress,
        cmd = u_cmd
    }

    if obj.v ~= nil then
        bus_obj.v = obj.v
    end

    for k, v in pairs(obj) do
        if not reserved[k] and bus_obj[k] == nil then
            bus_obj[k] = v
        end
    end

    local payload, err = json_codec.encode(bus_obj)
    if not payload then
        return nil, err or "json_encode_failed"
    end

    payload = payload .. "\r\n"
    return payload, {
        encoding = "text",
        bytes = #payload,
        append_crlf = true,
        mode = "json",
        adress = adress,
        u_cmd = u_cmd
    }
end

-- 透传 Server 对象，并补充一份用于日志/回执的元信息。
local function build_server_object_payload(obj)
    if type(obj) ~= "table" or type(obj.Server) ~= "table" then
        return nil, "invalid_server_payload"
    end

    local payload, err = json_codec.encode({
        Server = obj.Server
    })
    if not payload then
        return nil, err or "json_encode_failed"
    end

    local server_obj = obj.Server
    local u_cmd = ""
    if server_obj.sendFrequency ~= nil then
        u_cmd = "sendFrequency"
    elseif server_obj.status ~= nil then
        u_cmd = "status"
    end

    return payload .. "\r\n", {
        encoding = "text",
        bytes = #payload + 2,
        append_crlf = true,
        mode = "server_json",
        sensorAddr = server_obj.sensorAddr,
        sensorName = server_obj.sensorName,
        u_cmd = u_cmd
    }
end

-- 统一处理三种下发方式：Server 对象、简写 JSON、原始 data。
local function build_server_send_payload(obj)
    if type(obj) ~= "table" then
        return nil, "invalid_payload"
    end

    if type(obj.Server) == "table" then
        return build_server_object_payload(obj)
    end

    if (obj.data == nil or obj.data == "") and (obj.adress ~= nil or obj.id ~= nil or obj.u_cmd ~= nil) then
        return build_short_bus_json_payload(obj)
    end

    local encoding = string.lower(get_text(obj.encoding, "text"))
    local raw = obj.data
    local append_crlf = get_bool(obj.append_crlf)
    local payload

    if encoding == "hex" then
        payload = from_hex(raw)
        if not payload then
            return nil, "invalid_hex_data"
        end
    else
        encoding = "text"
        payload = get_text(raw, "")
        if payload == "" then
            return nil, "empty_text_data"
        end
    end

    if append_crlf then
        payload = payload .. "\r\n"
    end

    return payload, {
        encoding = encoding,
        bytes = #payload,
        append_crlf = append_crlf,
        mode = "raw"
    }
end

-- 如果收到的是传感器上报 JSON，则推导出 SD 卡日志路径。
local function build_log_path(data)
    if not data or #data == 0 then
        return nil
    end

    local trimmed = data:gsub("^[%s\r\n]+", ""):gsub("[%s\r\n]+$", "")
    local obj = json_codec.decode(trimmed)
    if not obj then
        return nil
    end

    if not (obj.sensorName and obj.timeStamp and obj.SN and obj.sensorAddr and obj.sendFrequency) then
        return nil
    end

    local t = os.date("*t", tonumber(obj.timeStamp))
    if not t then
        return nil
    end

    return string.format("/sd/log/%04d%02d%02d/%d.log", t.year, t.month, t.day, t.hour)
end

-- ---------------------------------------------------------------------------
-- UART1 简短 JSON 响应 -> MQTT1 up/resp
-- ---------------------------------------------------------------------------

-- UART1/485 总线上的 STM32 可能返回如下简短 JSON 行：
--   {"adress":1,"ok":1,"cmd":"freq"}
--   {"adress":1,"ok":0,"cmd":"freq","err":1}
-- 如果帧符合这种简短格式，就转发到 MQTT1 的 up/resp。
-- 其他 UART1 帧仍然走原来的可靠上传链路，不做改变。
-- 这里把“识别 JSON 响应”“判断是不是总线短回复”“组 MQTT 回执”
-- 放在一个函数里，顺着读就能看到完整处理流程。
local function forward_uart1_bus_response(frame)
    local trimmed = normalize_frame(frame)
    if not trimmed or trimmed:sub(1, 1) ~= "{" or trimmed:sub(-1) ~= "}" then
        return false
    end

    local obj = json_codec.decode(trimmed)
    if type(obj) ~= "table" then
        return false
    end

    -- 现有遥测/上报类帧继续沿用原来的上传链路。
    if obj.sensorName or obj.sensorAddr or obj.sendFrequency or obj.timeStamp or obj.SN then
        return false
    end

    -- 兼容旧字段 "id"，但对外统一回传成 "adress"。
    local adress = obj.adress ~= nil and obj.adress or obj.id
    local u_cmd = get_text(obj.cmd, "")
    if adress == nil or u_cmd == "" then
        return false
    end

    local body = {
        cmd = "bus_recv",
        sn = get_device_sn(),
        time = os.time(),
        source = "bus",
        adress = adress,
        u_cmd = u_cmd
    }

    for k, v in pairs(obj) do
        if k ~= "sn" and k ~= "time" and k ~= "id" then
            body[k] = v
        end
    end

    local ok = publish_to_server(1, body)
    if ok then
        log.info("bus_resp", "forwarded", "adress=" .. tostring(body.adress), "u_cmd=" .. tostring(body.u_cmd))
    else
        log.warn("bus_resp", "forward failed")
    end

    return true
end

-- ---------------------------------------------------------------------------
-- UART 原始接收回调
-- ---------------------------------------------------------------------------

-- UART 底层回调只负责把字节先攒到 rx_buf。
local function uart_rx_cb(id)
    while true do
        local data = uart.read(id, 1024)
        if not data or #data == 0 then
            break
        end

        rx_buf = rx_buf .. data
        last_rx_at = now_ms()
        if #rx_buf > RX_BUFFER_LIMIT then
            local keep_from = #rx_buf - RX_BUFFER_LIMIT + 1
            local json_start = rx_buf:find("{", keep_from, true)
            if json_start and json_start > keep_from then
                warn_throttled("uart_rx_trim_resync", "UART", "rx overflow drop partial prefix", json_start - 1)
                rx_buf = rx_buf:sub(json_start)
            else
                rx_buf = rx_buf:sub(keep_from)
            end
            warn_throttled("uart_rx_trim", "UART", "rx buffer trimmed to", #rx_buf)
        end
    end
end

local function uart_tx_sent_cb()
    tx_sent_seq = tx_sent_seq + 1
    sys.publish(TX_SENT_EVENT, tx_sent_seq)
end

uart.on(UART_ID, "receive", uart_rx_cb)
uart.on(UART_ID, "sent", uart_tx_sent_cb)

local function pop_line_frame()
    local crlf_pos = rx_buf:find("\r\n", 1, true)
    local lf_pos = rx_buf:find("\n", 1, true)
    local pos
    local sep_len = 0

    if crlf_pos and lf_pos then
        if crlf_pos <= lf_pos then
            pos = crlf_pos
            sep_len = 2
        else
            pos = lf_pos
            sep_len = 1
        end
    elseif crlf_pos then
        pos = crlf_pos
        sep_len = 2
    elseif lf_pos then
        pos = lf_pos
        sep_len = 1
    end

    if not pos then
        return false
    end

    push_frame(rx_buf:sub(1, pos - 1))
    rx_buf = rx_buf:sub(pos + sep_len)
    return true
end

-- 如果总线设备发送 JSON 时没有 "\r\n"，就按完整 JSON 对象切帧：
--   {"a":1}{"b":2}
-- 即使没有空闲间隔，也会拆成两个独立帧。
-- 逐字符扫描 JSON，正确处理字符串和转义符。
local function find_json_frame_bounds(text)
    if type(text) ~= "string" or text == "" then
        return nil
    end

    local start_pos = text:find("%S")
    if not start_pos then
        return nil
    end

    if text:sub(start_pos, start_pos) ~= "{" then
        local json_start = text:find("{", start_pos + 1, true)
        if not json_start then
            return nil
        end
        start_pos = json_start
    end

    local depth = 0
    local in_string = false
    local escaped = false

    for i = start_pos, #text do
        local ch = text:sub(i, i)

        if in_string then
            if escaped then
                escaped = false
            elseif ch == "\\" then
                escaped = true
            elseif ch == "\"" then
                in_string = false
            end
        else
            if ch == "\"" then
                in_string = true
            elseif ch == "{" then
                depth = depth + 1
            elseif ch == "}" then
                depth = depth - 1
                if depth == 0 then
                    return start_pos, i
                end
            end
        end
    end

    return nil
end

local function pop_json_frame()
    local start_pos, end_pos = find_json_frame_bounds(rx_buf)
    if not end_pos then
        return false
    end

    if start_pos > 1 then
        warn_throttled("uart_rx_json_resync", "UART", "drop partial json prefix", start_pos - 1)
    end

    push_frame(rx_buf:sub(start_pos, end_pos))
    rx_buf = rx_buf:sub(end_pos + 1)
    return true
end

-- 超过大小阈值或总线静默超时后，强制把缓存作为一帧推出。
local function flush_rx_buffer_if_needed()
    if #rx_buf == 0 then
        return false
    end

    local now = now_ms()
    if #rx_buf >= RX_FORCE_FLUSH_LIMIT then
        warn_throttled("uart_rx_force_flush", "UART", "force flush by size", #rx_buf)
        push_frame(rx_buf)
        rx_buf = ""
        return true
    end

    if (now - last_rx_at) >= RX_IDLE_TIMEOUT_MS then
        push_frame(rx_buf)
        rx_buf = ""
        return true
    end

    return false
end

-- ---------------------------------------------------------------------------
-- 接收拆帧任务：把原始 UART 字节流整理成 frame_queue 中的完整帧
-- ---------------------------------------------------------------------------

sys.taskInit(function()
    while true do
        local processed = false

        while pop_line_frame() do
            processed = true
        end

        while pop_json_frame() do
            processed = true
        end

        if not processed then
            processed = flush_rx_buffer_if_needed()
        end

        sys.wait(processed and 1 or 2)
    end
end)

-- 保持原有可靠上传和 SD 落盘逻辑不变。
local function queue_frame_to_existing_upload_path(frame)
    local ok, reason = uart_reliable_queue.enqueue_frame(frame)
    if not ok then
        warn_throttled("uart_reliable_fail", "UART", "reliable enqueue failed", reason or "unknown")
    end

    local path = build_log_path(frame)
    if path then
        sys.publish("SD_WRITE", path, frame)
    end
end

-- 生成适合写日志的可见字符串，避免控制字符直接污染日志。
local function visible_text(data, max_len)
    if data == nil then
        return "nil"
    end

    data = tostring(data)
    max_len = max_len or 256

    local s = data
    if #s > max_len then
        s = s:sub(1, max_len) .. string.format(" ... total=%d", #data)
    end

    s = s:gsub("\r", "\\r")
    s = s:gsub("\n", "\\n")
    s = s:gsub("\t", "\\t")

    return s
end
-- ---------------------------------------------------------------------------
-- 接收处理任务：消费 frame_queue，并分发每一帧
-- ---------------------------------------------------------------------------

sys.taskInit(function()
    while true do
        local processed = 0

        while processed < RX_TASK_BATCH_SIZE do
            local frame = frame_queue:pop()
            if not frame then
                break
            end
            log.info("UART_RX", "frame complete", "len=" .. tostring(#frame))
            log.info("UART_RX", "ascii", visible_text(frame, 1024))

            -- 简短 BUS 响应直接回 MQTT1；其他数据仍走原有可靠上传链路。
            if not forward_uart1_bus_response(frame) then
                queue_frame_to_existing_upload_path(frame)
            end

            processed = processed + 1
        end

        if processed == 0 then
            sys.wait(5)
        else
            sys.wait(1)
        end
    end
end)

-- ---------------------------------------------------------------------------
-- 发送任务：申请共享总线、写 UART、等待 sent 回调
-- ---------------------------------------------------------------------------

sys.taskInit(function()
    local pending_data
    local send_retry = 0

    while true do
        if not pending_data then
            pending_data = tx_queue:pop()
            send_retry = 0
        end

        if pending_data then
            local locked, reason = bus_locked()
            if not locked then
                warn_throttled("uart_bus_lock_timeout", "UART", "bus lock failed", reason or "unknown")
                sys.wait(math.random(BUSY_LOCK_BACKOFF_MIN_MS, BUSY_LOCK_BACKOFF_MAX_MS))
            else
                local expect_seq = tx_sent_seq + 1
                local timeout_ms = calc_tx_timeout_ms(#pending_data)
                log.info("UART", "tx len", #pending_data)
                log.info("UART", "tx ascii", pending_data)
                uart.write(UART_ID, pending_data)

                if tx_sent_seq < expect_seq then
                    sys.waitUntil(TX_SENT_EVENT, timeout_ms)
                end

                bus_unlocked()

                if tx_sent_seq >= expect_seq then
                    pending_data = nil
                    send_retry = 0
                else
                    send_retry = send_retry + 1
                    warn_throttled("uart_tx_timeout", "UART", "tx sent timeout", #pending_data, "retry", send_retry)
                    if send_retry >= TX_SEND_RETRY_LIMIT then
                        warn_throttled("uart_tx_drop_after_timeout", "UART", "drop tx data after timeout", #pending_data)
                        pending_data = nil
                        send_retry = 0
                    else
                        sys.wait(TX_SEND_RETRY_BACKOFF_MS)
                    end
                end
            end
        else
            sys.wait(10)
        end
    end
end)

-- 周期性服务器广播：
-- {"Server":{"SN":"<real sn>","NtpTimeStamp":"<real unix time>"}}\r\n
-- 复用普通 UART1 发送队列，因此 BUSY 锁处理逻辑保持不变。
sys.taskInit(function()

    sys.wait(5000)
    while true do
        queue_periodic_server_info()
        sys.wait(SERVER_INFO_INTERVAL_MS)
    end
end)

sys.subscribe("UART_SEND", function(data)
    push_tx(data)
end)

function M.send(data)
    return push_tx(data)
end

-- 处理 MQTT 下行命令：cmd=bus_send
-- 设计目标：
-- 1. 服务端只负责把数据放进 UART1 发送队列
-- 2. 真正的 UART 发送仍复用现有 BUSY 加锁逻辑
-- 3. 如果 require_idle=true，则在总线或队列忙时直接拒绝
function M.handle_command(server_id, obj)
    if type(obj) ~= "table" then
        return false
    end

    local cmd = get_text(obj.cmd, "")
    if cmd ~= BUS_SEND_CMD then
        return false
    end

    local request_id = get_text(obj.request_id, "bus-" .. tostring(os.time()))
    local payload, meta_or_err = build_server_send_payload(obj)
    if not payload then
        log.warn("bus_cmd", "invalid payload", request_id, meta_or_err or "invalid_data")
        reply_send(server_id, request_id, -1, meta_or_err or "invalid_data")
        return true
    end

    local status = get_send_status()
    log.info(
        "bus_cmd",
        "recv",
        request_id,
        "encoding=" .. tostring(meta_or_err.encoding),
        "mode=" .. tostring(meta_or_err.mode),
        "bytes=" .. tostring(meta_or_err.bytes),
        meta_or_err.adress ~= nil and ("adress=" .. tostring(meta_or_err.adress)) or "",
        meta_or_err.u_cmd and meta_or_err.u_cmd ~= "" and ("u_cmd=" .. tostring(meta_or_err.u_cmd)) or "",
        meta_or_err.sensorAddr ~= nil and ("sensorAddr=" .. tostring(meta_or_err.sensorAddr)) or "",
        meta_or_err.sensorName and meta_or_err.sensorName ~= "" and ("sensorName=" .. tostring(meta_or_err.sensorName)) or "",
        "bus_busy=" .. tostring(status.bus_busy),
        "queue_pending=" .. tostring(status.queue_pending)
    )

    if get_bool(obj.require_idle) and (status.bus_busy or status.queue_pending) then
        log.warn("bus_cmd", "reject busy", request_id)
        reply_send(server_id, request_id, -1, "bus_busy", {
            encoding = meta_or_err.encoding,
            mode = meta_or_err.mode,
            bytes = meta_or_err.bytes,
            adress = meta_or_err.adress,
            u_cmd = meta_or_err.u_cmd,
            bus_busy = status.bus_busy,
            queue_pending = status.queue_pending
        })
        return true
    end

    local ok, reason = push_tx(payload)
    if not ok then
        log.warn("bus_cmd", "queue failed", request_id, reason or "queue_failed")
        reply_send(server_id, request_id, -1, reason or "queue_failed", {
            encoding = meta_or_err.encoding,
            mode = meta_or_err.mode,
            bytes = meta_or_err.bytes,
            adress = meta_or_err.adress,
            u_cmd = meta_or_err.u_cmd,
            bus_busy = status.bus_busy,
            queue_pending = status.queue_pending
        })
        return true
    end

    log.info("bus_cmd", "queued", request_id, "tx_queue_len=" .. tostring(tx_queue:length()))
    reply_send(server_id, request_id, 0, status.bus_busy and "queued_busy" or "queued", {
        encoding = meta_or_err.encoding,
        mode = meta_or_err.mode,
        bytes = meta_or_err.bytes,
        append_crlf = meta_or_err.append_crlf,
        adress = meta_or_err.adress,
        u_cmd = meta_or_err.u_cmd,
        bus_busy = status.bus_busy,
        queue_pending = status.queue_pending,
        tx_queue_len = tx_queue:length(),
        tx_queue_bytes = tx_queue:used_bytes()
    })
    return true
end

return M
