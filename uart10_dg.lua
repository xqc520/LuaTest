---@diagnostic disable: undefined-global

local uart_port_common = require("uart_port_common")

local M = {}

local function handle_receive(data)
    -- UART10 receive handling entry.
    log.info("uart10_dg", "handle receive", #data)
end

local function handle_send(data)
    -- UART10 send handling entry.
    -- Return processed data if this port needs custom framing.
    return data
end

local function handle_sent()
    -- UART10 send-complete handling entry.
end

local port = uart_port_common.start({
    name = "uart10_dg",
    id = 10,
    baud = 115200,
    recv_event = "UART10_DG_RECV",
    send_events = { "UART10_DG_SEND", "UART10_SEND" },
    tx_pin_no = 57,
    tx_pin_func = "UART10_TX",
    rx_pin_no = 58,
    rx_pin_func = "UART10_RX",
    on_receive = handle_receive,
    on_prepare_send = handle_send,
    on_sent = handle_sent
})

function M.send(data)
    if port and port.send then
        return port.send(data)
    end
    return false
end

return M
