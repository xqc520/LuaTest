---@diagnostic disable: undefined-global

local udpsrv = require("udpsrv")

local dhcpsrv = {}
local TAG = "dhcpsrv"

local function ip_string_to_table(ip)
    if type(ip) ~= "string" then
        return nil
    end
    local a, b, c, d = ip:match("^(%d+)%.(%d+)%.(%d+)%.(%d+)$")
    if not a then
        return nil
    end
    return {tonumber(a), tonumber(b), tonumber(c), tonumber(d)}
end

local function ip_table_to_bytes(ip)
    return string.char(ip[1], ip[2], ip[3], ip[4])
end

local function dhcp_decode(buff)
    local pkg = {}

    pkg.op = buff[0]
    pkg.htype = buff[1]
    pkg.hlen = buff[2]
    pkg.hops = buff[3]

    buff:seek(4)
    pkg.xid = buff:read(4)
    _, pkg.secs = buff:unpack(">H")
    _, pkg.flags = buff:unpack(">H")
    pkg.ciaddr = buff:read(4)
    pkg.yiaddr = buff:read(4)
    pkg.siaddr = buff:read(4)
    pkg.giaddr = buff:read(4)
    pkg.chaddr = buff:read(16)
    buff:seek(192, zbuff.SEEK_CUR)
    _, pkg.magic = buff:unpack(">I")

    pkg.opts = {}
    while buff:len() > buff:used() do
        local tag_raw = buff:read(1)
        if not tag_raw or #tag_raw == 0 then
            break
        end

        local tag = tag_raw:byte()
        if tag == 0 then
        elseif tag == 0xFF then
            break
        else
            local len_raw = buff:read(1)
            if not len_raw or #len_raw == 0 then
                break
            end

            local len = len_raw:byte()
            if len == 0 then
                break
            end

            local data = buff:read(len)
            if not data or #data ~= len then
                break
            end

            if tag == 53 then
                pkg.msgtype = data:byte()
            end

            pkg.opts[#pkg.opts + 1] = {tag, data}
        end
    end

    if not pkg.msgtype then
        return nil
    end

    return pkg
end

local function dhcp_encode(pkg, buff)
    buff:seek(0)
    buff[0] = pkg.op
    buff[1] = pkg.htype
    buff[2] = pkg.hlen
    buff[3] = pkg.hops

    buff:seek(4)
    buff:write(pkg.xid)
    buff:pack(">H", pkg.secs)
    buff:pack(">H", pkg.flags)
    buff:write(pkg.ciaddr)
    buff:write(pkg.yiaddr)
    buff:write(pkg.siaddr)
    buff:write(pkg.giaddr)
    buff:write(pkg.chaddr)
    buff:seek(192, zbuff.SEEK_CUR)
    buff:pack(">I", pkg.magic)

    for _, opt in ipairs(pkg.opts) do
        buff:write(opt[1])
        buff:write(#opt[2])
        buff:write(opt[2])
    end

    buff:write(0xFF, 0x00)
end

local function send_reply(srv, pkg, client, msgtype)
    local buff = zbuff.create(300)
    local gw = srv.opts.gw
    local dns = srv.opts.dns or gw

    pkg.op = 2
    pkg.secs = 0
    pkg.ciaddr = "\0\0\0\0"
    pkg.yiaddr = string.char(gw[1], gw[2], gw[3], client.ip)
    pkg.siaddr = string.char(gw[1], gw[2], gw[3], gw[4])
    pkg.giaddr = "\0\0\0\0"
    pkg.opts = {
        {53, string.char(msgtype)},
        {1, ip_table_to_bytes(srv.opts.mark)},
        {3, ip_table_to_bytes(gw)},
        {51, "\x00\x00\x1E\x00"},
        {54, ip_table_to_bytes(gw)},
        {6, ip_table_to_bytes(dns)}
    }

    dhcp_encode(pkg, buff)

    local dst = "255.255.255.255"
    if msgtype == 4 then
        dst = string.format("%d.%d.%d.%d", gw[1], gw[2], gw[3], client.ip)
    end
    srv.udp:send(buff, dst, 68)
end

local function send_offer(srv, pkg, client)
    send_reply(srv, pkg, client, 2)
end

local function send_ack(srv, pkg, client)
    send_reply(srv, pkg, client, 5)
end

local function send_nack(srv, pkg, client)
    send_reply(srv, pkg, client, 6)
end

local function handle_discover(srv, pkg)
    local mac = pkg.chaddr:sub(1, pkg.hlen)

    for _, client in pairs(srv.clients) do
        if client.mac == mac then
            send_offer(srv, pkg, client)
            return
        end
    end

    local ip_suffix
    for i = srv.opts.ip_start, srv.opts.ip_end, 1 do
        if not srv.clients[i] then
            ip_suffix = i
            break
        end
    end

    if not ip_suffix then
        log.warn(TAG, "no free IP for client", mac:toHex())
        return
    end

    local client = {
        mac = mac,
        ip = ip_suffix,
        tm = mcu.ticks() // mcu.hz(),
        stat = 1
    }
    srv.clients[ip_suffix] = client
    send_offer(srv, pkg, client)
end

local function handle_request(srv, pkg)
    local mac = pkg.chaddr:sub(1, pkg.hlen)

    for _, client in pairs(srv.clients) do
        if client.mac == mac then
            client.tm = mcu.ticks() // mcu.hz()
            client.stat = 3
            send_ack(srv, pkg, client)
            if srv.opts.ack_cb then
                local cip = string.format(
                    "%d.%d.%d.%d",
                    srv.opts.gw[1],
                    srv.opts.gw[2],
                    srv.opts.gw[3],
                    client.ip
                )
                srv.opts.ack_cb(cip, mac:toHex())
            end
            return
        end
    end

    send_nack(srv, pkg, {ip = 0})
end

local function handle_pkg(srv, pkg)
    if pkg.magic ~= 0x63825363 then
        return
    end
    if pkg.op ~= 1 or pkg.htype ~= 1 or pkg.hlen ~= 6 then
        return
    end

    local mac = pkg.chaddr:sub(1, pkg.hlen)
    if mac == "\0\0\0\0\0\0" or mac == "\xFF\xFF\xFF\xFF\xFF\xFF" then
        return
    end

    if pkg.msgtype == 1 then
        handle_discover(srv, pkg)
    elseif pkg.msgtype == 3 then
        handle_request(srv, pkg)
    end
end

local function dhcp_task(srv)
    while not srv.closed do
        local ok, data = sys.waitUntil(srv.udp_topic, 1000)
        if ok and data and not srv.closed then
            local pkg = dhcp_decode(zbuff.create(#data, data))
            if pkg then
                handle_pkg(srv, pkg)
            end
        end
    end
end

function dhcpsrv.create(opts)
    local srv = {}
    opts = opts or {}

    if not opts.mark then
        opts.mark = {255, 255, 255, 0}
    end

    if not opts.gw and opts.adapter then
        opts.gw = ip_string_to_table(netdrv.ipv4(opts.adapter))
    end
    if not opts.gw then
        opts.gw = {192, 168, 4, 1}
    end

    if not opts.dns then
        opts.dns = {opts.gw[1], opts.gw[2], opts.gw[3], opts.gw[4]}
    end

    if not opts.ip_start then
        opts.ip_start = 100
    end
    if not opts.ip_end then
        opts.ip_end = 200
    end

    srv.opts = opts
    srv.clients = {}
    srv.closed = false
    srv.udp_topic = "dhcpd_inc_" .. tostring(opts.adapter or 0) .. "_" .. tostring(mcu.ticks())
    srv.udp = udpsrv.create(67, srv.udp_topic, opts.adapter)

    if not srv.udp then
        return nil
    end

    sys.taskInit(dhcp_task, srv)

    function srv:close()
        if self.closed then
            return
        end
        self.closed = true
        if self.udp and self.udp.close then
            self.udp:close()
        end
        self.udp = nil
        sys.publish(self.udp_topic)
    end

    return srv
end

return dhcpsrv
