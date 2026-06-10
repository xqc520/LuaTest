---@diagnostic disable: undefined-global

local M = {}

-- 只有当 RTC 时间已经可靠时，才允许做 TLS 证书时间校验。
-- 这里用一个固定的“合理下限时间”做粗判断。
local VALID_TIME_MIN = 1700000000

local CERT_NOT_FOUND_MSG = "rootCA.crt not found"
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

local function is_non_empty_text(value)
    return type(value) == "string" and value ~= ""
end

-- 用指定读取函数尝试读取证书文本。
-- 读取失败或拿到空字符串时统一返回 nil。
local function try_read(reader, ...)
    if type(reader) ~= "function" then
        return nil
    end

    local ok, data = pcall(reader, ...)
    if ok and is_non_empty_text(data) then
        return data
    end

    return nil
end

-- 依次尝试多种文件接口读取证书。
-- 保持原有读取顺序不变：
-- 1. io.readFile
-- 2. fs.readFile
-- 3. io.open(..., "rb")
local function read_file(path)
    if not is_non_empty_text(path) then
        return nil
    end

    local data = try_read(io and io.readFile, path)
    if data then
        return data
    end

    data = try_read(fs and fs.readFile, path)
    if data then
        return data
    end

    if io and type(io.open) == "function" then
        local file = io.open(path, "rb")
        if file then
            local content = file:read("*a")
            file:close()
            if is_non_empty_text(content) then
                return content
            end
        end
    end

    return nil
end

-- 判断 host 是否是 IPv4 地址。
-- 如果是 IP，TLS 校验证书名称时需要证书 SAN/CN 里也包含该 IP。
function M.is_ip_host(host)
    host = trim_text(host)
    if host == "" then
        return false
    end

    local a, b, c, d = host:match("^(%d+)%.(%d+)%.(%d+)%.(%d+)$")
    a, b, c, d = tonumber(a), tonumber(b), tonumber(c), tonumber(d)
    return a and a <= 255 and b and b <= 255 and c and c <= 255 and d and d <= 255
end

-- 生成一条更容易排查 TLS 证书问题的提示信息。
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

-- 判断当前系统时间是否已经足够可信，可用于 TLS 证书时间校验。
function M.is_time_valid()
    local now = os.time()
    return type(now) == "number" and now >= VALID_TIME_MIN
end

-- 加载服务端根证书，并做简单缓存。
-- 如果 force_reload=true，会强制重新扫路径读取证书。
function M.load_server_cert(force_reload)
    if not force_reload and is_non_empty_text(cached_cert) then
        return cached_cert, cached_path
    end

    for _, path in ipairs(CERT_PATHS) do
        local cert = read_file(path)
        if is_non_empty_text(cert) then
            cached_cert = cert
            cached_path = path
            return cached_cert, cached_path
        end
    end

    cached_cert = nil
    cached_path = nil
    return nil, CERT_NOT_FOUND_MSG
end

-- 生成 mqtt.create(...) 需要的 TLS 选项。
-- 目前只下发 server_cert，保持原有行为不变。
function M.get_client_options()
    local cert, path_or_err = M.load_server_cert()
    if not cert then
        return nil, path_or_err or CERT_NOT_FOUND_MSG
    end

    return {
        server_cert = cert
    }, path_or_err
end

return M
