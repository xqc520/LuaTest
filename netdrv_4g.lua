--[[
@module  netdrv_4g
@summary 4G network status helper
@version 1.0
@date    2026.04.01
@author  OpenAI
@usage
Only logs IP ready/lose state.
Do not override operator DNS.
Do not add public DNS fallback.
]]

---@diagnostic disable: undefined-global

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

local function ip_ready_func(ip, adapter)
    if adapter ~= socket.LWIP_GP then
        return
    end

    local ip_text = trim_text(ip, socket.localIP and socket.localIP(socket.LWIP_GP) or "")
    log.info("netdrv_4g", "IP_READY", ip_text, "dns_policy=operator_only")
end

local function ip_lose_func(adapter)
    if adapter ~= socket.LWIP_GP then
        return
    end

    log.warn("netdrv_4g", "IP_LOSE")
end

sys.subscribe("IP_READY", ip_ready_func)
sys.subscribe("IP_LOSE", ip_lose_func)
