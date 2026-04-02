---@diagnostic disable: undefined-global

_G.EPD_STATUS = {}

local M = _G.EPD_STATUS

M.STATUS_SHORT = {
    online = "ON",
    offline = "OFF",
    connecting = "WAIT",
    error = "ERR"
}

M.server_status = { [1] = "offline", [2] = "offline" }
M.mode_text = "BOOT"

M.DEFAULT_CONFIG = {
    device = {
        sn = (PROJECT or "DEV") .. "-" .. (VERSION or "0.0"),
        fw = (PROJECT and VERSION) and (PROJECT .. "-" .. VERSION) or "unknown"
    },
    apn = { mode = "auto", apn = "", user = "", pass = "" },
    servers = {
        { enable = false, host = "", port = 8883 },
        { enable = false, host = "", port = 8883 }
    }
}

local function trim_text(value, default)
    if type(value) ~= "string" then
        return default or ""
    end

    local trimmed = value:gsub("^%s+", ""):gsub("%s+$", "")
    if trimmed == "" then
        return default or ""
    end

    return trimmed
end

local function short_str(value, maxlen)
    local text = trim_text(value, "")
    if #text <= maxlen then
        return text
    end

    return text:sub(1, maxlen)
end

local function normalize_sn(value)
    return trim_text(value, "NO_SN")
end

local function normalize_fw(cfg)
    local fw = cfg and cfg.device and cfg.device.fw
    if trim_text(fw, "") ~= "" then
        return fw
    end

    return (PROJECT and VERSION) and (PROJECT .. "-" .. VERSION) or (VERSION or "unknown")
end

local function format_display_version(cfg)
    local fw = normalize_fw(cfg)
    local major, minor, patch = fw:match("(%d+)%.(%d+)%.(%d+)")
    if major and minor and patch then
        return string.format("V%d.%d.%d", tonumber(major) or 0, tonumber(minor) or 0, tonumber(patch) or 0)
    end

    local version_only = fw:match("-(%d+%.%d+%.%d+)$")
    if version_only then
        major, minor, patch = version_only:match("(%d+)%.(%d+)%.(%d+)")
        if major and minor and patch then
            return string.format("V%d.%d.%d", tonumber(major) or 0, tonumber(minor) or 0, tonumber(patch) or 0)
        end
    end

    if fw:match("^[Vv]%d+%.%d+%.%d+$") then
        return fw:gsub("^v", "V")
    end

    return short_str(fw, 13)
end

local function short_host(value)
    local host = trim_text(value, "-")
    host = host:gsub("^mqtt://", "")
    host = host:gsub("^tcp://", "")
    host = host:gsub("^ssl://", "")
    host = host:gsub("^https?://", "")
    host = host:gsub("/.*$", "")
    return short_str(host, 15)
end

local function build_primary_server_lines(cfg, status)
    local index = 1
    local srv = cfg and cfg.servers and cfg.servers[index]
    if not srv or not srv.enable or trim_text(srv.host, "") == "" then
        return "-", "S1 OFF"
    end

    local st = M.STATUS_SHORT[status[index]] or "--"
    return short_host(srv.host), string.format("P:%d %s", srv.port or 0, st)
end

local function publish_status()
    sys.publish("EPD_MSG", M.build_msg(M.cfg, M.server_status))
end

function M.build_msg(cfg, status)
    cfg = cfg or M.cfg or M.DEFAULT_CONFIG
    status = status or M.server_status

    local host_line, detail_line = build_primary_server_lines(cfg, status)
    local lines = {
        "SN:" .. short_str(normalize_sn(cfg.device and cfg.device.sn), 13),
        host_line,
        detail_line
    }

    return table.concat(lines, "\n")
end

function M.init()
    local cfg = flash_config.get()
    if not cfg then
        cfg = M.DEFAULT_CONFIG
        flash_config.set(cfg)
    end

    M.cfg = cfg
    publish_status()
end

function M.set_mode(mode)
    local next_mode = short_str(trim_text(mode, "BOOT"), 11)
    if M.mode_text ~= next_mode then
        M.mode_text = next_mode
        publish_status()
    end
end

function M.set_server_status(index, status)
    if M.server_status[index] ~= status then
        M.server_status[index] = status
        publish_status()
    end
end

function M.set_all_server_status(status_table)
    if type(status_table) ~= "table" then
        return
    end

    local changed = false
    for i = 1, 2 do
        local next_status = status_table[i] or "offline"
        if M.server_status[i] ~= next_status then
            M.server_status[i] = next_status
            changed = true
        end
    end

    if changed then
        publish_status()
    end
end

function M.get_sn()
    return normalize_sn(M.cfg and M.cfg.device and M.cfg.device.sn)
end
