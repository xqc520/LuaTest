---@diagnostic disable: undefined-global

local M = {}

-- 这个模块是一个很轻量的“SD 访问互斥锁”：
-- 1. acquire(timeout_ms) : 尝试在超时时间内拿锁
-- 2. release()           : 释放锁并唤醒等待方
-- 3. run(fn, timeout, ...) : 自动加锁、执行函数、释放锁

local locked = false

local DEFAULT_WAIT_MS = 5000
local WAIT_SLICE_MS = 100
local RELEASE_EVENT = "SD_GUARD_RELEASE"
local unpack_fn = table.unpack or unpack

-- 优先使用 MCU tick 获取毫秒时间；如果没有，就退化到 os.time。
local function now_ms()
    if mcu and type(mcu.ticks) == "function" and type(mcu.hz) == "function" then
        local hz = tonumber(mcu.hz()) or 0
        if hz > 0 then
            return math.floor((tonumber(mcu.ticks()) or 0) * 1000 / hz)
        end
    end

    return (tonumber(os.time()) or 0) * 1000
end

-- 尝试获取 SD 访问锁。
-- 如果当前已被占用，就按 100ms 的切片等待释放事件，直到超时。
function M.acquire(timeout_ms)
    local timeout = math.max(0, tonumber(timeout_ms) or DEFAULT_WAIT_MS)
    local deadline = now_ms() + timeout

    while locked do
        local remaining = deadline - now_ms()
        if remaining <= 0 then
            return false, "timeout"
        end

        sys.waitUntil(RELEASE_EVENT, math.min(WAIT_SLICE_MS, remaining))
    end

    locked = true
    return true
end

-- 释放 SD 访问锁。
-- 释放后会广播事件，唤醒其他正在等待锁的任务。
function M.release()
    if not locked then
        return
    end

    locked = false
    sys.publish(RELEASE_EVENT)
end

-- 在锁保护下执行一个函数。
-- 返回值保持原约定：
-- 1. 第一个返回值表示“是否成功拿到锁”
-- 2. 如果拿到锁，再继续返回被调用函数的原始返回值
-- 3. 如果函数内部抛错，则返回 false, 错误信息
function M.run(fn, timeout_ms, ...)
    if type(fn) ~= "function" then
        return false, "invalid function"
    end

    local acquired, reason = M.acquire(timeout_ms)
    if not acquired then
        return false, reason
    end

    local results = { pcall(fn, ...) }
    M.release()

    if not results[1] then
        return false, results[2]
    end

    return true, unpack_fn(results, 2)
end

return M
