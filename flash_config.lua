---@diagnostic disable: undefined-global

local M = {}

local CONFIG_FILE = "/flash/net_config.json"
local CONFIG_DIR = "/flash"
local SERVER_COUNT = 2
local DEFAULT_SERVER = {
    enable = false,
    host = "",
    port = 8883,
    user = "",
    pass = ""
}
local DEFAULT_CONFIG = {
    device = {
        sn = "",
        fw = (PROJECT and VERSION) and (PROJECT .. "-" .. VERSION) or "unknown"
    },
    apn = {
        mode = "auto",
        apn = "",
        user = "",
        pass = ""
    },
    sm4 = {
        key = "",
        iv = ""
    },
    servers = {
        {
            enable = false,
            host = "",
            port = 8883,
            user = "",
            pass = ""
        },
        {
            enable = false,
            host = "",
            port = 8883,
            user = "",
            pass = ""
        }
    }
}

local g_config
local busy = false

local function deepcopy(value)
    if type(value) ~= "table" then
        return value
    end

    local copy = {}
    for key, item in pairs(value) do
        copy[deepcopy(key)] = deepcopy(item)
    end

    return copy
end

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

local function to_bool(value)
    return value == true or value == 1 or value == "1" or value == "true" or value == "TRUE"
end

local function ensure_dir(dir)
    if io.dexist(dir) then
        return true
    end

    return io.mkdir(dir) == true
end

local function normalize_server(server)
    local item = deepcopy(DEFAULT_SERVER)
    if type(server) ~= "table" then
        return item
    end

    item.enable = to_bool(server.enable)
    item.host = trim_text(server.host, "")

    local port = tonumber(server.port)
    if port and port > 0 then
        item.port = port
    end

    item.user = trim_text(server.user, "")
    item.pass = trim_text(server.pass, "")
    return item
end

local function normalize_sm4(sm4, fallback)
    local item = {
        key = "",
        iv = ""
    }
    fallback = type(fallback) == "table" and fallback or {}
    sm4 = type(sm4) == "table" and sm4 or {}

    item.key = trim_text(sm4.key, trim_text(fallback.key, ""))
    item.iv = trim_text(sm4.iv, trim_text(fallback.iv, ""))
    return item
end

local function normalize(cfg)
    cfg = type(cfg) == "table" and cfg or {}
    local current = type(g_config) == "table" and g_config or DEFAULT_CONFIG

    local normalized = {}
    normalized.device = deepcopy(DEFAULT_CONFIG.device)
    normalized.apn = deepcopy(DEFAULT_CONFIG.apn)
    normalized.sm4 = normalize_sm4(cfg.sm4, current.sm4 or DEFAULT_CONFIG.sm4)
    normalized.servers = {}

    if type(cfg.device) == "table" then
        normalized.device.sn = trim_text(cfg.device.sn, "")
    end

    if type(cfg.apn) == "table" then
        local mode = trim_text(cfg.apn.mode, normalized.apn.mode)
        normalized.apn.mode = mode == "manual" and "manual" or "auto"
        normalized.apn.apn = trim_text(cfg.apn.apn, "")
        normalized.apn.user = trim_text(cfg.apn.user, "")
        normalized.apn.pass = trim_text(cfg.apn.pass, "")
    end

    local servers = type(cfg.servers) == "table" and cfg.servers or {}
    for i = 1, SERVER_COUNT do
        normalized.servers[i] = normalize_server(servers[i])
    end

    return normalized
end

local function ensure_loaded()
    if g_config then
        return g_config
    end

    ensure_dir(CONFIG_DIR)

    if io.exists(CONFIG_FILE) then
        local file = io.open(CONFIG_FILE, "rb")
        if file then
            local content = file:read("*a")
            file:close()

            local ok, cfg = pcall(json.decode, content)
            if ok and type(cfg) == "table" then
                g_config = normalize(cfg)
                return g_config
            end

            log.warn("flash_config", "invalid config file, use default")
        end
    end

    g_config = normalize(nil)
    return g_config
end

function M.load()
    return ensure_loaded()
end

function M.get()
    return ensure_loaded()
end

function M.has_device_sn(cfg)
    cfg = cfg or ensure_loaded()
    return trim_text(cfg and cfg.device and cfg.device.sn, "") ~= ""
end

function M.getEnabledServers(cfg)
    cfg = cfg or ensure_loaded()

    local enabled = {}
    local servers = cfg and cfg.servers or {}
    for i = 1, SERVER_COUNT do
        local server = normalize_server(servers[i])
        if server.enable and server.host ~= "" then
            server.id = i
            enabled[#enabled + 1] = server
        end
    end

    return enabled
end

function M.has_enabled_server(cfg)
    return #M.getEnabledServers(cfg) > 0
end

function M.is_config_complete(cfg)
    cfg = cfg or ensure_loaded()
    return M.has_device_sn(cfg) and M.has_enabled_server(cfg)
end

function M.should_start_ap_config(cfg)
    return not M.is_config_complete(cfg)
end

function M.getServer(index, cfg)
    local target = tonumber(index)
    if not target or target < 1 or target > SERVER_COUNT then
        return nil
    end

    cfg = cfg or ensure_loaded()
    local server = normalize_server(cfg and cfg.servers and cfg.servers[target] or nil)
    if not server.enable or server.host == "" then
        return nil
    end

    server.id = target
    return server
end

function M.getSm4(cfg)
    cfg = cfg or ensure_loaded()
    return normalize_sm4(cfg and cfg.sm4, DEFAULT_CONFIG.sm4)
end

function M.setSm4(sm4)
    local cfg = deepcopy(ensure_loaded())
    cfg.sm4 = normalize_sm4(sm4, cfg.sm4 or DEFAULT_CONFIG.sm4)
    return M.save(cfg)
end

function M.save(cfg)
    if busy then
        return false
    end

    busy = true
    local data_to_save = normalize(cfg or ensure_loaded())

    ensure_dir(CONFIG_DIR)
    local file = io.open(CONFIG_FILE, "wb")
    if not file then
        busy = false
        return false
    end

    local ok = pcall(function()
        file:write(json.encode(data_to_save))
    end)
    file:close()

    if ok then
        g_config = data_to_save
        busy = false
        log.info("flash_config", "config saved")
        return true
    end

    busy = false
    return false
end

function M.set(cfg)
    return M.save(cfg)
end

M.load()

return M
