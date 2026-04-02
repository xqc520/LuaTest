---@diagnostic disable: undefined-global

local M = {}

local UART_BUFFER_SIZE = 10240
local UART_USE_ZBUFF = true
local LOG_PREVIEW_BYTES = 64
local REPEAT_LOG_INTERVAL_SEC = 2
local REPEAT_LOG_COUNT_STEP = 20
local STUCK_LOW_WARN_REPEAT = 20
local STUCK_LOW_WARN_INTERVAL = 200

local function normalize_send_data(data)
    if type(data) == "string" then
        return data
    end

    if data == nil then
        return nil
    end

    return tostring(data)
end

local function to_hex_preview(data, max_bytes)
    if type(data) ~= "string" or #data == 0 then
        return ""
    end

    local limit = math.max(1, tonumber(max_bytes) or LOG_PREVIEW_BYTES)
    local preview = data
    local truncated = false
    if #preview > limit then
        preview = preview:sub(1, limit)
        truncated = true
    end

    local hex
    if string and string.toHex then
        local ok, result = pcall(string.toHex, preview)
        if ok and type(result) == "string" then
            hex = result
        end
    end

    if not hex or hex == "" then
        local ok, result = pcall(function()
            return preview:toHex()
        end)
        if ok and type(result) == "string" then
            hex = result
        end
    end

    if not hex or hex == "" then
        hex = preview:gsub("[^%g ]", ".")
    end

    if truncated then
        return hex .. "..."
    end

    return hex
end

local function is_all_zero_payload(data)
    return type(data) == "string" and #data > 0 and data:find("[^\0]") == nil
end

local function log_receive(port_name, data, log_state)
    local preview = to_hex_preview(data, LOG_PREVIEW_BYTES)
    local data_len = #data
    local now = os.time()

    if log_state.last_len == data_len and log_state.last_preview == preview then
        log_state.repeat_count = (log_state.repeat_count or 0) + 1

        if log_state.last_all_zero == true then
            if
                log_state.repeat_count == STUCK_LOW_WARN_REPEAT
                or log_state.repeat_count % STUCK_LOW_WARN_INTERVAL == 0
            then
                log.warn(port_name, "rx maybe stuck low or level mismatch", "repeat=" .. log_state.repeat_count, "len=" .. data_len)
            end
        end

        if
            log_state.repeat_count == 1
            or log_state.repeat_count % REPEAT_LOG_COUNT_STEP == 0
            or (now - (log_state.last_repeat_log_at or 0)) >= REPEAT_LOG_INTERVAL_SEC
        then
            log.info(port_name, "receive repeat", "count=" .. log_state.repeat_count, "len=" .. data_len, "preview=" .. preview)
            log_state.last_repeat_log_at = now
        end
        return
    end

    if (log_state.repeat_count or 0) > 0 then
        log.info(
            port_name,
            "receive repeat end",
            "count=" .. log_state.repeat_count,
            "len=" .. (log_state.last_len or 0),
            "preview=" .. (log_state.last_preview or "")
        )
    end

    log_state.last_len = data_len
    log_state.last_preview = preview
    log_state.last_all_zero = is_all_zero_payload(data)
    log_state.repeat_count = 0
    log_state.last_repeat_log_at = now
    log.info(port_name, "receive", "len=" .. data_len, "preview=" .. preview)
end

local function read_data(id, rx_buffer)
    if UART_USE_ZBUFF and rx_buffer and type(uart.rx) == "function" then
        local chunks = {}
        local total_len = 0

        while true do
            local len = uart.rx(id, rx_buffer)
            if not len or len <= 0 then
                break
            end

            local data = rx_buffer:toStr(0, len)
            rx_buffer:seek(0)
            if type(data) == "string" and #data > 0 then
                chunks[#chunks + 1] = data
                total_len = total_len + #data
            end

            if len < UART_BUFFER_SIZE then
                break
            end
        end

        if total_len > 0 then
            return table.concat(chunks)
        end

        return nil
    end

    local chunks = {}
    local total_len = 0
    while true do
        local data = uart.read(id, UART_BUFFER_SIZE)
        if not data or #data == 0 then
            break
        end

        chunks[#chunks + 1] = data
        total_len = total_len + #data
        if #data < UART_BUFFER_SIZE then
            break
        end
    end

    if total_len > 0 then
        return table.concat(chunks)
    end

    return nil
end

local function setup_mux(port)
    if not pins or type(pins.setup) ~= "function" then
        log.warn(port.name, "pins.setup unavailable, keep default uart mux")
        return
    end

    if port.rx_pin_no and port.rx_pin_func then
        local ok = pcall(pins.setup, port.rx_pin_no, port.rx_pin_func)
        if ok then
            log.info(port.name, "rx mux", port.rx_pin_no, port.rx_pin_func)
        else
            log.warn(port.name, "rx mux failed", port.rx_pin_no, port.rx_pin_func)
        end
    end

    if port.tx_pin_no and port.tx_pin_func then
        local ok = pcall(pins.setup, port.tx_pin_no, port.tx_pin_func)
        if ok then
            log.info(port.name, "tx mux", port.tx_pin_no, port.tx_pin_func)
        else
            log.warn(port.name, "tx mux failed", port.tx_pin_no, port.tx_pin_func)
        end
    end
end

local function setup_uart(port)
    local baud = tonumber(port.baud) or 115200
    if port.rx_tx_pin ~= nil then
        uart.setup(
            port.id,
            baud,
            8,
            1,
            uart.NONE,
            uart.LSB,
            UART_BUFFER_SIZE,
            port.rx_tx_pin,
            port.rx_pin_level or 0,
            port.tx_rx_delay_us or 0
        )
        return
    end

    uart.setup(
        port.id,
        baud,
        8,
        1,
        uart.NONE,
        uart.LSB,
        UART_BUFFER_SIZE
    )
end

function M.start(port)
    local api = {}
    local rx_log_state = {
        last_len = 0,
        last_preview = "",
        last_all_zero = false,
        repeat_count = 0,
        last_repeat_log_at = 0
    }
    local rx_buffer = nil

    if UART_USE_ZBUFF and zbuff and type(zbuff.create) == "function" then
        rx_buffer = zbuff.create(UART_BUFFER_SIZE)
    end

    setup_mux(port)
    setup_uart(port)

    uart.on(port.id, "receive", function(id)
        while true do
            local data = read_data(id, rx_buffer)
            if not data or #data == 0 then
                break
            end

            log_receive(port.name, data, rx_log_state)
            if type(port.on_receive) == "function" then
                local ok, err = pcall(port.on_receive, data, id)
                if not ok then
                    log.warn(port.name, "on_receive failed", err or "")
                end
            end
            if port.recv_event then
                sys.publish(port.recv_event, data)
            end
        end
    end)

    uart.on(port.id, "sent", function()
        log.info(port.name, "tx sent")
        if type(port.on_sent) == "function" then
            local ok, err = pcall(port.on_sent, port.id)
            if not ok then
                log.warn(port.name, "on_sent failed", err or "")
            end
        end
    end)

    local function send_data(data)
        data = normalize_send_data(data)
        if not data or data == "" then
            return false
        end

        if type(port.on_prepare_send) == "function" then
            local ok, prepared = pcall(port.on_prepare_send, data, port.id)
            if not ok then
                log.warn(port.name, "on_prepare_send failed", prepared or "")
                return false
            end

            if prepared == false then
                return false
            end

            if prepared ~= nil then
                data = normalize_send_data(prepared)
                if not data or data == "" then
                    return false
                end
            end
        end

        uart.write(port.id, data)
        return true
    end

    for _, event_name in ipairs(port.send_events or {}) do
        sys.subscribe(event_name, function(data)
            send_data(data)
        end)
    end

    log.info(
        port.name,
        "uart ready",
        "id=" .. tostring(port.id),
        "baud=" .. tostring(tonumber(port.baud) or 115200),
        "rx_mode=" .. (rx_buffer and "zbuff" or "string")
    )

    api.send = send_data
    return api
end

return M
