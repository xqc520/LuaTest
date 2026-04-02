---@diagnostic disable: undefined-global

local M = {}

local locked = false
local DEFAULT_WAIT_MS = 5000
local WAIT_SLICE_MS = 100

local function now_ms()
    if mcu and type(mcu.ticks) == "function" and type(mcu.hz) == "function" then
        local hz = tonumber(mcu.hz()) or 0
        if hz > 0 then
            return math.floor((tonumber(mcu.ticks()) or 0) * 1000 / hz)
        end
    end

    return (tonumber(os.time()) or 0) * 1000
end

local function unpack_results(results, start_index)
    if table.unpack then
        return table.unpack(results, start_index or 1)
    end

    return unpack(results, start_index or 1)
end

function M.acquire(timeout_ms)
    local timeout = math.max(0, tonumber(timeout_ms) or DEFAULT_WAIT_MS)
    local deadline = now_ms() + timeout

    while locked do
        local remaining = deadline - now_ms()
        if remaining <= 0 then
            return false, "timeout"
        end

        sys.waitUntil("SD_GUARD_RELEASE", math.min(WAIT_SLICE_MS, remaining))
    end

    locked = true
    return true
end

function M.release()
    if not locked then
        return
    end

    locked = false
    sys.publish("SD_GUARD_RELEASE")
end

function M.run(fn, timeout_ms, ...)
    if type(fn) ~= "function" then
        return false, "invalid function"
    end

    local ok, err = M.acquire(timeout_ms)
    if not ok then
        return false, err
    end

    local results = { pcall(fn, ...) }
    M.release()

    if not results[1] then
        return false, results[2]
    end

    return true, unpack_results(results, 2)
end

return M
