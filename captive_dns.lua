---@diagnostic disable: undefined-global

local M = {}

local dns_socket
local rx_buff = zbuff.create(1500)
local ap_ip = "192.168.4.1"
local ap_ip_bytes = string.char(192, 168, 4, 1)

local function to_u16_be(n)
    return string.char((n >> 8) & 0xFF, n & 0xFF)
end

local function to_u32_be(n)
    return string.char(
        (n >> 24) & 0xFF,
        (n >> 16) & 0xFF,
        (n >> 8) & 0xFF,
        n & 0xFF
    )
end

local function read_u16_be(s, pos)
    local a, b = s:byte(pos, pos + 1)
    if not a or not b then
        return nil
    end
    return a * 256 + b
end

local function update_ap_ip(ip)
    local a, b, c, d = ip:match("^(%d+)%.(%d+)%.(%d+)%.(%d+)$")
    if not a then
        return false
    end

    ap_ip = ip
    ap_ip_bytes = string.char(tonumber(a), tonumber(b), tonumber(c), tonumber(d))
    return true
end

local function build_dns_response(query)
    if not query or #query < 17 then
        return nil
    end

    local qdcount = read_u16_be(query, 5)
    if not qdcount or qdcount < 1 then
        return nil
    end

    local pos = 13
    while pos <= #query do
        local label_len = query:byte(pos)
        if not label_len then
            return nil
        end
        pos = pos + 1
        if label_len == 0 then
            break
        end
        pos = pos + label_len
    end

    if pos + 3 > #query then
        return nil
    end

    local qtype = read_u16_be(query, pos)
    local question = query:sub(13, pos + 3)
    local id = query:sub(1, 2)

    local answer_count = 0
    local answer = ""

    if qtype == 1 or qtype == 255 then
        answer_count = 1
        answer =
            "\192\012" ..
            "\000\001" ..
            "\000\001" ..
            to_u32_be(30) ..
            "\000\004" ..
            ap_ip_bytes
    end

    local header =
        id ..
        "\129\128" ..
        query:sub(5, 6) ..
        to_u16_be(answer_count) ..
        "\000\000" ..
        "\000\000"

    return header .. question .. answer
end

local function remote_ip_to_string(remote_ip)
    if remote_ip and #remote_ip == 5 then
        local ip1, ip2, ip3, ip4 = remote_ip:byte(2), remote_ip:byte(3), remote_ip:byte(4), remote_ip:byte(5)
        return string.format("%d.%d.%d.%d", ip1, ip2, ip3, ip4)
    end
    return nil
end

local function on_dns_request(sc, event)
    if event ~= socket.EVENT then
        return
    end

    while true do
        rx_buff:seek(0)
        local succ, data_len, remote_ip, remote_port = socket.rx(sc, rx_buff)
        if not succ or not data_len or data_len <= 0 then
            break
        end

        local query = rx_buff:toStr(0, data_len)
        rx_buff:del()

        local response = build_dns_response(query)
        local client_ip = remote_ip_to_string(remote_ip)
        if response and client_ip and remote_port then
            socket.tx(sc, response, client_ip, remote_port)
        end
    end
end

function M.start(adapter, ip)
    if ip then
        update_ap_ip(ip)
    end

    if dns_socket then
        return true
    end

    dns_socket = socket.create(adapter, on_dns_request)
    if not dns_socket then
        return false
    end

    socket.config(dns_socket, 53, true)
    return socket.connect(dns_socket, "255.255.255.255", 0)
end

function M.stop()
    if not dns_socket then
        return
    end

    socket.close(dns_socket)
    if socket.release then
        socket.release(dns_socket)
    end
    dns_socket = nil
end

function M.get_ip()
    return ap_ip
end

return M
