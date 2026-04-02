---@diagnostic disable: undefined-global

local dhcpsrv = require("dhcpsrv")
local flash_config = require("flash_config")
local captive_dns = require("captive_dns")

local AP_TIMEOUT = 300000
local AP_SSID_PREFIX = "HQX-"
local AP_SSID_FALLBACK = "HQX-DTU"
local AP_PASS = "HZ88888888"
local AP_IP = "192.168.4.1"
local AP_MASK = "255.255.255.0"
local AP_GATEWAY = "192.168.4.1"
local AP_URL = "http://" .. AP_IP .. "/"

local ap_timer
local ap_dhcp
local index_html_cache
local g_config = flash_config.get()

local PROBE_URIS = {
    ["/generate_204"] = true,
    ["/gen_204"] = true,
    ["/hotspot-detect.html"] = true,
    ["/library/test/success.html"] = true,
    ["/connecttest.txt"] = true,
    ["/ncsi.txt"] = true,
    ["/success.txt"] = true,
    ["/redirect"] = true,
    ["/canonical.html"] = true,
    ["/fwlink/"] = true
}

local function get_ap_ssid()
    local imei = ""
    if mobile and mobile.imei then
        local ok, value = pcall(mobile.imei)
        if ok and value ~= nil then
            imei = tostring(value):gsub("%s+", "")
        end
    end

    if imei ~= "" then
        return AP_SSID_PREFIX .. imei
    end

    return AP_SSID_FALLBACK
end

local function get_device_imei()
    local imei = ""
    if mobile and mobile.imei then
        local ok, value = pcall(mobile.imei)
        if ok and value ~= nil then
            imei = tostring(value):gsub("%s+", "")
        end
    end

    if imei == "" then
        return "NO_IMEI"
    end

    return imei
end

local function captive_redirect()
    return 302, {
        ["Location"] = AP_URL,
        ["Cache-Control"] = "no-store, no-cache, must-revalidate",
        ["Pragma"] = "no-cache",
        ["Content-Type"] = "text/html; charset=utf-8"
    }, '<html><head><meta http-equiv="refresh" content="0;url=' .. AP_URL .. '"></head><body>Redirecting...</body></html>'
end

local function stop_ap()
    log.info("AP", "boot timeout reached, stopping WiFi AP")
    ap_timer = nil
    httpsrv.stop(80)

    if ap_dhcp and ap_dhcp.close then
        pcall(function()
            ap_dhcp:close()
        end)
        ap_dhcp = nil
    end

    captive_dns.stop()
    wlan.setMode(wlan.NONE)
    log.info("AP", "WiFi AP stopped")
end

local function start_ap_shutdown_timer()
    if ap_timer then
        return
    end

    ap_timer = sys.timerStart(stop_ap, AP_TIMEOUT)
    log.info("AP", "shutdown timer started", AP_TIMEOUT, "ms")
end

local function create_ap()
    local ap_ssid = get_ap_ssid()
    wlan.createAP(ap_ssid, AP_PASS)
    netdrv.ipv4(socket.LWIP_AP, AP_IP, AP_MASK, AP_GATEWAY)
    ap_dhcp = dhcpsrv.create({
        adapter = socket.LWIP_AP,
        gw = {192, 168, 4, 1},
        dns = {192, 168, 4, 1}
    })
    captive_dns.start(socket.LWIP_AP, AP_IP)
    log.info("AP", "ssid", ap_ssid, "ready at", AP_URL)
end

local function handle_http_request(fd, method, uri, headers, body)
    log.info("HTTP", method, uri)
    local path = uri and uri:match("^[^?]+") or uri

    if method == "GET" and PROBE_URIS[path] then
        return captive_redirect()
    end

    if path == "/" and method == "GET" then
        if not index_html_cache then
            index_html_cache = fs.readFile("/flash/index.html") or "no html"
        end
        return 200, {["Content-Type"] = "text/html"}, index_html_cache
    end

    if path == "/api/config" and method == "GET" then
        local cfg = json.decode(json.encode(g_config or {})) or {}
        cfg.device = type(cfg.device) == "table" and cfg.device or {}
        cfg.device.imei = get_device_imei()
        return 200, {["Content-Type"] = "application/json"}, json.encode(cfg)
    end

    if path == "/api/config" and method == "POST" then
        if body and #body > 10 then
            local ok, cfg = pcall(json.decode, body)
            if ok and cfg then
                g_config = cfg
                flash_config.save(g_config)
                log.info("CONFIG", "config saved")
                return 200, {}, "ok"
            end
        end
        return 400, {}, "bad request"
    end

    if path == "/api/apply" and method == "POST" then
        flash_config.save(g_config)
        sys.timerStart(function()
            rtos.reboot()
        end, 1000)
        return 200, {}, "rebooting"
    end

    if method == "GET" and path and not path:match("^/api/") then
        return captive_redirect()
    end

    return 404, {}, "Not Found"
end

local function start_http()
    httpsrv.start(80, handle_http_request, socket.LWIP_AP)
    log.info("WEB", AP_URL)
end

sys.taskInit(function()
    log.info("SYS", "starting AP config mode")
    log.info("AP", "will stop after", AP_TIMEOUT, "ms")
    wlan.init()
    create_ap()
    start_http()
    start_ap_shutdown_timer()
end)
