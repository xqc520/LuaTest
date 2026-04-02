---@diagnostic disable: undefined-global

local json_codec = require("json_codec")
local flash_config = require("flash_config")
local bounded_queue = require("bounded_queue")
local uart_reliable_queue = require("uart_reliable_queue")
local mqtt_topics = require("mqtt_topics")

local M = {}

-- ---------------------------------------------------------------------------
-- UART1 / RS485 physical configuration
-- ---------------------------------------------------------------------------

local UART_ID = 1
local UART_BAUD = 115200
local UART_RXTX_PIN = 17
local UART_RX_PIN_LEVEL = 0
local UART_TXRX_DELAY_US = 1666

-- ---------------------------------------------------------------------------
-- RX/TX queue sizing
-- ---------------------------------------------------------------------------

local RX_BUFFER_LIMIT = 4096
-- When the bus data stream has no line ending, split one frame after this
-- many milliseconds of silence on UART RX.
local RX_FORCE_FLUSH_LIMIT = 3072
local RX_IDLE_TIMEOUT_MS = 30
local RX_TASK_BATCH_SIZE = 8
local FRAME_QUEUE_MAX_ITEMS = 128
local FRAME_QUEUE_MAX_BYTES = 64 * 1024
local TX_QUEUE_MAX_ITEMS = 64
local TX_QUEUE_MAX_BYTES = 16 * 1024

-- ---------------------------------------------------------------------------
-- Shared BUSY-line arbitration
-- ---------------------------------------------------------------------------

local BUSY_DEC_GPIO_NUMBER = 24
local BUSY_IO_GPIO_NUMBER = 98
local BUSY_IDLE_STABLE_CHECKS = 3
local BUSY_LOCK_RETRY_LIMIT = 60
local BUSY_LOCK_BACKOFF_MIN_MS = 8
local BUSY_LOCK_BACKOFF_MAX_MS = 25
local BUSY_CLAIM_SETTLE_MS = 2

local TX_SENT_EVENT = "UART1_TX_SENT"
local TX_SENT_TIMEOUT_MIN_MS = 200
local TX_SENT_TIMEOUT_PER_BYTE_MS = 2
local TX_SEND_RETRY_LIMIT = 3
local TX_SEND_RETRY_BACKOFF_MS = 30

-- ---------------------------------------------------------------------------
-- MQTT control command
-- ---------------------------------------------------------------------------

-- MQTT server can send this command to write raw data to the RS485 bus.
-- Topic: sys/{SN}/json/down/cmd
-- Example:
--   {"cmd":"bus_send","request_id":"bus-001","encoding":"hex","data":"010300000002C40B"}
--   {"cmd":"bus_send","request_id":"bus-002","encoding":"text","data":"hello","append_crlf":true}
local BUS_SEND_CMD = "bus_send"
local MQTT_SERVER_COUNT = 2

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

gpio.setup(BUSY_IO_GPIO_NUMBER, 0)
gpio.setup(BUSY_DEC_GPIO_NUMBER, nil, gpio.PULLDOWN)

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

uart_reliable_queue.init({
    device_sn = EPD_STATUS and EPD_STATUS.get_sn and EPD_STATUS.get_sn() or "NO_SN",
    target_servers = enabled_servers
})

-- ---------------------------------------------------------------------------
-- Common small helpers
-- ---------------------------------------------------------------------------

local function warn_throttled(key, ...)
    local now = os.time()
    local last = last_warn_at[key] or 0
    if now - last >= 5 then
        last_warn_at[key] = now
        log.warn(...)
    end
end

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

local function get_report_topic()
    return mqtt_topics.get_up_resp_topic(get_device_sn())
end

-- MQTT1/MQTT2 both use the same response topic format, but bus control/report
-- traffic is still only forwarded through MQTT1.
local function publish_to_server(server_id, body)
    local target = tonumber(server_id)
    if not target or target < 1 or target > MQTT_SERVER_COUNT then
        return false
    end

    local payload = json_codec.encode(body)
    if not payload then
        return false
    end

    sys.publish("mqtt" .. target .. "_send_data_req", "bus_cmd", get_report_topic(), payload, 1)
    return true
end

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

-- ---------------------------------------------------------------------------
-- Send-side state helpers
-- ---------------------------------------------------------------------------

-- Read current send path state.
-- bus_busy:
--   true  -> another bus node is transmitting, or we already hold the lock.
-- queue_pending:
--   true  -> UART1 still has data waiting to send.
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

local function wait_bus_idle_once()
    local stable_checks = 0

    while stable_checks < BUSY_IDLE_STABLE_CHECKS do
        if gpio.get(BUSY_DEC_GPIO_NUMBER) ~= 0 then
            return false
        end

        stable_checks = stable_checks + 1
        if stable_checks < BUSY_IDLE_STABLE_CHECKS then
            sys.wait(1)
        end
    end

    return true
end

local function bus_locked()
    if bus_lock_held then
        return true
    end

    local retry = 0
    while retry < BUSY_LOCK_RETRY_LIMIT do
        if wait_bus_idle_once() then
            sys.wait(math.random(BUSY_LOCK_BACKOFF_MIN_MS, BUSY_LOCK_BACKOFF_MAX_MS))
            if gpio.get(BUSY_DEC_GPIO_NUMBER) == 0 then
                gpio.set(BUSY_IO_GPIO_NUMBER, 1)
                sys.wait(BUSY_CLAIM_SETTLE_MS)
                if gpio.get(BUSY_DEC_GPIO_NUMBER) == 1 then
                    bus_lock_held = true
                    return true
                end

                gpio.set(BUSY_IO_GPIO_NUMBER, 0)
            end
        end

        retry = retry + 1
        sys.wait(math.random(BUSY_LOCK_BACKOFF_MIN_MS, BUSY_LOCK_BACKOFF_MAX_MS))
    end

    return false, "busy_timeout"
end

local function bus_unlocked()
    if not bus_lock_held then
        return true
    end

    gpio.set(BUSY_IO_GPIO_NUMBER, 0)
    sys.wait(BUSY_CLAIM_SETTLE_MS)
    bus_lock_held = false
    return true
end

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
-- RX frame queue
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
-- TX queue
-- ---------------------------------------------------------------------------

local function push_tx(data)
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
-- MQTT downlink -> UART bytes
-- ---------------------------------------------------------------------------

-- Convert server command payload into real UART bytes.
-- encoding=text : send obj.data as-is
-- encoding=hex  : obj.data must be hex string, then convert to binary bytes
-- append_crlf   : optional, append "\r\n" after payload
-- If obj.data is omitted, server can also send a short bus command directly:
--   {"cmd":"bus_send","adress":1,"u_cmd":"freq","v":60}
-- Then device will auto-build:
--   {"adress":1,"cmd":"freq","v":60}\r\n
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

local function build_server_send_payload(obj)
    if type(obj) ~= "table" then
        return nil, "invalid_payload"
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
-- UART1 short JSON response -> MQTT1 up/resp
-- ---------------------------------------------------------------------------

-- STM32 on the UART1/485 bus can reply with a short JSON line such as:
--   {"adress":1,"ok":1,"cmd":"freq"}
--   {"adress":1,"ok":0,"cmd":"freq","err":1}
-- If the frame matches this simple format, forward it to MQTT1 up/resp.
-- Other UART1 frames still keep the original reliable upload path unchanged.
local function decode_frame_json(frame)
    local trimmed = normalize_frame(frame)
    if not trimmed then
        return nil
    end

    if trimmed:sub(1, 1) ~= "{" or trimmed:sub(-1) ~= "}" then
        return nil
    end

    return json_codec.decode(trimmed)
end

local function get_bus_adress(obj)
    if type(obj) ~= "table" then
        return nil
    end

    -- Keep compatibility with the old "id" field, but normalize to "adress"
    -- in the MQTT payload sent back to the server.
    return obj.adress ~= nil and obj.adress or obj.id
end

local function is_uart1_bus_response(obj)
    if type(obj) ~= "table" then
        return false
    end

    -- Keep the existing telemetry/report frames on the old upload path.
    if obj.sensorName or obj.sensorAddr or obj.sendFrequency or obj.timeStamp or obj.SN then
        return false
    end

    return get_bus_adress(obj) ~= nil and type(obj.cmd) == "string" and obj.cmd ~= ""
end

local function build_uart1_response_body(obj)
    local body = {
        cmd = "bus_recv",
        sn = get_device_sn(),
        time = os.time()
    }

    for k, v in pairs(obj) do
        if k ~= "sn" and k ~= "time" and k ~= "id" then
            body[k] = v
        end
    end

    -- Preserve the child command in a stable field, because top-level cmd is
    -- reserved for the device-to-server transport type.
    body.adress = get_bus_adress(obj)
    body.u_cmd = get_text(obj.cmd, "")
    body.source = "bus"
    return body
end

local function forward_uart1_bus_response(frame)
    local obj = decode_frame_json(frame)
    if not is_uart1_bus_response(obj) then
        return false
    end

    local body = build_uart1_response_body(obj)
    local ok = publish_to_server(1, body)
    if ok then
        log.info("bus_resp", "forwarded", "adress=" .. tostring(body.adress), "u_cmd=" .. tostring(body.u_cmd))
    else
        log.warn("bus_resp", "forward failed")
    end

    return true
end

-- ---------------------------------------------------------------------------
-- Raw UART receive callback
-- ---------------------------------------------------------------------------

local function uart_rx_cb(id)
    while true do
        local data = uart.read(id, 1024)
        if not data or #data == 0 then
            break
        end

        rx_buf = rx_buf .. data
        last_rx_at = now_ms()
        if #rx_buf > RX_BUFFER_LIMIT then
            rx_buf = rx_buf:sub(#rx_buf - RX_BUFFER_LIMIT + 1)
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
-- RX split task: convert raw UART stream into frame_queue items
-- ---------------------------------------------------------------------------

sys.taskInit(function()
    while true do
        local processed = false

        while pop_line_frame() do
            processed = true
        end

        if not processed then
            processed = flush_rx_buffer_if_needed()
        end

        sys.wait(processed and 1 or 5)
    end
end)

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

local function handle_rx_frame(frame)
    if forward_uart1_bus_response(frame) then
        return
    end

    queue_frame_to_existing_upload_path(frame)
end

-- ---------------------------------------------------------------------------
-- RX process task: consume frame_queue and dispatch each frame
-- ---------------------------------------------------------------------------

sys.taskInit(function()
    while true do
        local processed = 0

        while processed < RX_TASK_BATCH_SIZE do
            local frame = frame_queue:pop()
            if not frame then
                break
            end

            handle_rx_frame(frame)

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
-- TX task: lock the shared bus, write UART bytes, wait for sent callback
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

sys.subscribe("UART_SEND", function(data)
    push_tx(data)
end)

function M.send(data)
    return push_tx(data)
end

-- Handle MQTT downlink command: cmd=bus_send
-- Design goal:
-- 1. Server only puts data into UART1 send queue
-- 2. Real UART sending still reuses the existing BUSY lock logic
-- 3. If require_idle=true, reject when bus/queue is busy
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
