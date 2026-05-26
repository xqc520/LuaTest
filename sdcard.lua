---@diagnostic disable: undefined-global

local sd_guard = require("sd_guard")

local M = {}

local SPI_ID = 1
local PIN_CS = 20
local PIN_CH390_POWER = 140
local PIN_CH390_CS = 12
local SPI_INIT_HZ = 400 * 1000
local SPI_WORK_HZ = 8 * 1000 * 1000
local INIT_TIMEOUT_MS = 10000
local REINIT_MIN_INTERVAL_MS = 2000
local FAULT_WINDOW_MS = 60 * 1000
local FAULT_REBOOT_THRESHOLD = 5
local REBOOT_DELAY_MS = 3000

local mounted = false
local last_init_at = 0
local fault_window_start = 0
local fault_count = 0
local reboot_scheduled = false

local function now_ms()
    if mcu and type(mcu.ticks) == "function" and type(mcu.hz) == "function" then
        local hz = tonumber(mcu.hz()) or 0
        if hz > 0 then
            return math.floor((tonumber(mcu.ticks()) or 0) * 1000 / hz)
        end
    end

    return (tonumber(os.time()) or 0) * 1000
end

local function safe_unmount()
    if fatfs and type(fatfs.unmount) == "function" then
        pcall(fatfs.unmount, "/sd")
    end
    if spi and type(spi.close) == "function" then
        pcall(spi.close, SPI_ID)
    end
    mounted = false
end

local function schedule_reboot(reason)
    if reboot_scheduled then
        return
    end

    reboot_scheduled = true
    log.error("sd", "too many faults, rebooting", tostring(reason or "unknown"))
    sys.timerStart(rtos.reboot, REBOOT_DELAY_MS)
end

local function record_fault(reason)
    local now = now_ms()
    if fault_window_start == 0 or (now - fault_window_start) > FAULT_WINDOW_MS then
        fault_window_start = now
        fault_count = 0
    end

    fault_count = fault_count + 1
    log.warn("sd", "fault", tostring(reason or "unknown"), "count", fault_count)

    if fault_count >= FAULT_REBOOT_THRESHOLD then
        schedule_reboot(reason)
    end
end

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
        "/sd",
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

function M.init()
    if mounted then
        return true
    end

    local now = now_ms()
    if (now - last_init_at) < REINIT_MIN_INTERVAL_MS then
        return false
    end
    last_init_at = now

    local ok_guard, result = sd_guard.run(function()
        return mount_sd()
    end, INIT_TIMEOUT_MS)

    if not ok_guard then
        log.error("sd", "mount busy", result or "")
        record_fault(result or "mount_busy")
        return false
    end

    return result == true
end

function M.mark_fault(reason)
    log.warn("sd", "mark fault", tostring(reason or "unknown"))
    record_fault(reason or "unknown")
    safe_unmount()
    return false
end

return M
