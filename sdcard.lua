---@diagnostic disable: undefined-global

local sd_guard = require("sd_guard")

local M = {}

-- SD 卡硬件连接参数。
local SPI_ID = 1
local PIN_CS = 20
local PIN_CH390_POWER = 140
local PIN_CH390_CS = 12

-- SPI 初始化时先用较低频率，挂载成功后再切到工作频率。
local SPI_INIT_HZ = 400 * 1000
local SPI_WORK_HZ = 8 * 1000 * 1000

local SD_MOUNT_POINT = "/sd"
local INIT_TIMEOUT_MS = 10000
local REINIT_MIN_INTERVAL_MS = 2000
local PENDING_ERROR_LOG_LIMIT = 16

-- 故障保护策略：
-- 在一个时间窗口内累计故障过多时，安排一次延时重启。
local FAULT_WINDOW_MS = 60 * 1000
local FAULT_REBOOT_THRESHOLD = 5
local REBOOT_DELAY_MS = 3000

-- 运行时状态。
local mounted = false
local last_init_at = 0
local fault_window_start = 0
local fault_count = 0
local reboot_scheduled = false
local pending_error_logs = {}

-- 优先使用 MCU tick 获取毫秒时间；没有 tick 时退化到 os.time。
local function now_ms()
    if mcu and type(mcu.ticks) == "function" and type(mcu.hz) == "function" then
        local hz = tonumber(mcu.hz()) or 0
        if hz > 0 then
            return math.floor((tonumber(mcu.ticks()) or 0) * 1000 / hz)
        end
    end

    return (tonumber(os.time()) or 0) * 1000
end

-- 尽量安全地卸载 SD，并关闭 SPI。
-- 这里只做清理，不抛异常。
local function safe_unmount()
    if fatfs and type(fatfs.unmount) == "function" then
        pcall(fatfs.unmount, SD_MOUNT_POINT)
    end
    if spi and type(spi.close) == "function" then
        pcall(spi.close, SPI_ID)
    end
    mounted = false
end

local function get_error_logger()
    local loaded = package and package.loaded and package.loaded["error_logger"] or nil
    if type(loaded) == "table" and type(loaded.error) == "function" then
        return loaded
    end

    return nil
end

local function cache_error_log(tag, message)
    pending_error_logs[#pending_error_logs + 1] = {
        tag = tostring(tag or "sd"),
        message = tostring(message or "")
    }

    if #pending_error_logs > PENDING_ERROR_LOG_LIMIT then
        table.remove(pending_error_logs, 1)
    end
end

local function persist_error_log(tag, message)
    local error_logger = get_error_logger()
    if not error_logger then
        cache_error_log(tag, message)
        return false
    end

    pcall(error_logger.error, tag, message)
    return true
end

-- 安排一次延时重启，避免在短时间内重复安排。
local function schedule_reboot(reason)
    if reboot_scheduled then
        return
    end

    reboot_scheduled = true
    log.error("sd", "too many faults, rebooting", tostring(reason or "unknown"))
    persist_error_log("sd", "too many faults, rebooting " .. tostring(reason or "unknown"))
    sys.timerStart(rtos.reboot, REBOOT_DELAY_MS)
end

-- 记录一次 SD 故障，并在窗口内累计次数。
local function record_fault(reason)
    local now = now_ms()
    if fault_window_start == 0 or (now - fault_window_start) > FAULT_WINDOW_MS then
        fault_window_start = now
        fault_count = 0
    end

    fault_count = fault_count + 1
    log.warn("sd", "fault", tostring(reason or "unknown"), "count", fault_count)
    persist_error_log("sd", "fault " .. tostring(reason or "unknown") .. " count=" .. tostring(fault_count))

    if fault_count >= FAULT_REBOOT_THRESHOLD then
        schedule_reboot(reason)
    end
end

-- 执行一次真实的 SD 挂载。
-- 保持原行为：
-- 1. 已挂载时直接返回 true
-- 2. 挂载失败时记录故障
-- 3. 挂载成功时清空故障窗口
local function mount_sd()
    if mounted then
        return true
    end

    gpio.setup(PIN_CH390_POWER, 1, gpio.PULLUP)
    gpio.setup(PIN_CH390_CS, 1)
    gpio.setup(PIN_CS, 1)

    spi.setup(SPI_ID, nil, 0, 0, SPI_INIT_HZ)

    local ok, err = fatfs.mount(
        fatfs.SPI,
        SD_MOUNT_POINT,
        SPI_ID,
        PIN_CS,
        SPI_WORK_HZ
    )

    if not ok then
        log.error("sd", "TF SD mount failed", err or "")
        record_fault(err or "mount_failed")
        return false
    end

    mounted = true
    fault_window_start = 0
    fault_count = 0
    log.info("sd", "mount ok", "spi_hz", SPI_WORK_HZ)
    return true
end

-- 对外初始化接口。
-- 这里有两个保护：
-- 1. 已挂载则直接成功
-- 2. 距离上次尝试太近时直接返回 false，避免频繁重试
function M.init()
    if mounted then
        return true
    end

    local now = now_ms()
    if (now - last_init_at) < REINIT_MIN_INTERVAL_MS then
        return false
    end
    last_init_at = now

    local ok_guard, result = sd_guard.run(mount_sd, INIT_TIMEOUT_MS)
    if not ok_guard then
        log.error("sd", "mount busy", result or "")
        record_fault(result or "mount_busy")
        return false
    end

    return result == true
end

function M.flush_error_logs()
    local error_logger = get_error_logger()
    if not error_logger or #pending_error_logs == 0 then
        return false
    end

    local logs = pending_error_logs
    pending_error_logs = {}

    for _, entry in ipairs(logs) do
        pcall(error_logger.error, entry.tag, entry.message)
    end

    return true
end

-- 外部发现 SD 访问异常时，统一从这里标记故障并卸载。
function M.mark_fault(reason)
    log.warn("sd", "mark fault", tostring(reason or "unknown"))
    record_fault(reason or "unknown")
    safe_unmount()
    return false
end

return M
