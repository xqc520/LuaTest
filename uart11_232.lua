---@diagnostic disable: undefined-global

local M = {}

-- Simple UART11 text receive/send test port.
local UART_ID = 11
local UART_BAUD = 115200
local UART_BUFFER_SIZE = 1024
local UART_READ_CHUNK = 1028
local ENABLE_TEST_SEND = true
local TEST_SEND_INTERVAL_MS = 1000
local TEST_SEND_DATA = "test data.\r\n"

-- Normalize everything to string before writing.
local function normalize_send_data(data)
    if type(data) == "string" then
        return data
    end

    if data == nil then
        return nil
    end

    return tostring(data)
end

-- Public/local send entry used by both sys.publish and M.send.
local function send_data(data)
    data = normalize_send_data(data)
    if not data or data == "" then
        return false
    end

    uart.write(UART_ID, data)
    return true
end

local function uart_send_cb(id)
  --  log.info("uart11_232", id, "数据发送完成回调")
end

-- Read all buffered bytes and publish them as one chunk.
local function uart_cb(id, len)
    local s = ""
    repeat
        s = uart.read(id, UART_READ_CHUNK)
        if #s > 0 then
            log.info("uart11_232", "receive", id, #s, s)
            sys.publish("UART11_232_RECV", s)
        end
    until s == ""
end

uart.setup(
    UART_ID,
    UART_BAUD,
    8,
    1,
    uart.NONE,
    uart.LSB,
    UART_BUFFER_SIZE
)

uart.on(UART_ID, "receive", uart_cb)
uart.on(UART_ID, "sent", uart_send_cb)

sys.subscribe("UART11_232_SEND", send_data)
sys.subscribe("UART11_SEND", send_data)

if ENABLE_TEST_SEND then
    sys.taskInit(function()
        while true do
            sys.wait(TEST_SEND_INTERVAL_MS)
            send_data(TEST_SEND_DATA)
        end
    end)
end

function M.send(data)
    return send_data(data)
end

return M
