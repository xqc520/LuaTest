---@diagnostic disable: undefined-global

local M = {}

local VALID_TIME_MIN = 1700000000
local CERT_PATHS = {
    "/luadb/rootCA.crt",
    "/flash/rootCA.crt",
    "/rootCA.crt"
}

local cached_cert
local cached_path

local function trim_text(value)
    if type(value) ~= "string" then
        return ""
    end
    return value:gsub("^%s+", ""):gsub("%s+$", "")
end

local function read_file(path)
    if type(path) ~= "string" or path == "" then
        return nil
    end

    if io and type(io.readFile) == "function" then
        local ok, data = pcall(io.readFile, path)
        if ok and type(data) == "string" and data ~= "" then
            return data
        end
    end

    if fs and type(fs.readFile) == "function" then
        local ok, data = pcall(fs.readFile, path)
        if ok and type(data) == "string" and data ~= "" then
            return data
        end
    end

    if io and type(io.open) == "function" then
        local file = io.open(path, "rb")
        if file then
            local data = file:read("*a")
            file:close()
            if type(data) == "string" and data ~= "" then
                return data
            end
        end
    end

    return nil
end

function M.is_ip_host(host)
    host = trim_text(host)
    if host == "" then
        return false
    end

    local a, b, c, d = host:match("^(%d+)%.(%d+)%.(%d+)%.(%d+)$")
    a, b, c, d = tonumber(a), tonumber(b), tonumber(c), tonumber(d)
    return a and a <= 255 and b and b <= 255 and c and c <= 255 and d and d <= 255
end

function M.build_verify_hint(host, port)
    local addr = trim_text(host)
    local port_text = tostring(port or "")
    if addr == "" then
        return "tls verify target empty, please check mqtt host config"
    end

    if M.is_ip_host(addr) then
        return string.format(
            "tls verify target %s:%s uses ip, broker server cert SAN/CN must contain this ip or switch config host to the cert domain",
            addr,
            port_text
        )
    end

    return string.format(
        "tls verify target %s:%s, broker server cert chain must be signed by rootCA.crt and cert name must match this host",
        addr,
        port_text
    )
end

function M.is_time_valid()
    local now = os.time()
    return type(now) == "number" and now >= VALID_TIME_MIN
end

function M.load_server_cert(force_reload)
    if not force_reload and type(cached_cert) == "string" and cached_cert ~= "" then
        return cached_cert, cached_path
    end

    for _, path in ipairs(CERT_PATHS) do
        local cert = read_file(path)
        if type(cert) == "string" and cert ~= "" then
            cached_cert = cert
            cached_path = path
            return cached_cert, cached_path
        end
    end

    cached_cert = nil
    cached_path = nil
    return nil, "rootCA.crt not found"
end

function M.get_client_options()
    local cert, path_or_err = M.load_server_cert()
    if not cert then
        return nil, path_or_err or "rootCA.crt not found"
    end

    return {
        server_cert = cert
    }, path_or_err
end

return M
