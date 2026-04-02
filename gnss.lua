---@diagnostic disable: undefined-global

local exgnss = require("exgnss")

local M = {}

local GNSS_MODE = 2
local AGPS_ENABLE = false
local BOOT_OPEN_DELAY_MS = 5000
local STATUS_LOG_INTERVAL_MS = 10 * 1000
local GNSS_APP_MODE = exgnss.DEFAULT
local GNSS_APP_TAG = "project"

local MIN_SATELLITES = 5
local MAX_HDOP = 3
local REQUIRED_STABLE_FIXES = 3

local started = false
local setup_done = false
local last_reason = "init"
local last_location = {
    latitude = nil,
    longitude = nil,
    time = 0
}
local last_quality = {
    satellites = 0,
    hdop = nil,
    fix_quality = 0,
    stable_count = 0
}

local function set_reason(reason)
    last_reason = tostring(reason or "unknown")
end

local function has_location()
    return type(last_location.latitude) == "number" and type(last_location.longitude) == "number"
end

local function save_location(lat, lng)
    last_location.latitude = tonumber(lat)
    last_location.longitude = tonumber(lng)
    last_location.time = tonumber(os.time()) or 0
    set_reason("fixed")
end

local function call_first(fn1, fn2, ...)
    local fn = exgnss[fn1] or exgnss[fn2]
    if type(fn) ~= "function" then
        return false, nil
    end
    return pcall(fn, ...)
end

local function is_active()
    local ok, active = call_first("is_active", "isActive", GNSS_APP_MODE, {tag = GNSS_APP_TAG})
    return ok and active == true
end

local function is_fix()
    local ok, fixed = call_first("is_fix", "isFix")
    return ok and fixed == true
end

local function read_rmc()
    local ok, rmc = pcall(exgnss.rmc, 2)
    if not ok or type(rmc) ~= "table" then
        set_reason("rmc_read_failed")
        return nil
    end

    local lat = tonumber(rmc.lat)
    local lng = tonumber(rmc.lng)
    if not lat or not lng then
        set_reason("rmc_invalid")
        return nil
    end

    if lat == 0 and lng == 0 then
        set_reason("no_signal")
        return nil
    end

    return lat, lng
end

local function read_gga_quality()
    local ok, gga = call_first("gga", "getGga", 2)
    if not ok or type(gga) ~= "table" then
        return {
            satellites = 0,
            hdop = nil,
            fix_quality = 0
        }
    end

    return {
        satellites = tonumber(gga.satellites_tracked) or 0,
        hdop = tonumber(gga.hdop),
        fix_quality = tonumber(gga.fix_quality) or 0
    }
end

local function refresh_location()
    local lat, lng = read_rmc()
    local quality = read_gga_quality()

    last_quality.satellites = quality.satellites
    last_quality.hdop = quality.hdop
    last_quality.fix_quality = quality.fix_quality

    if not lat or not lng then
        last_quality.stable_count = 0
        return false
    end

    if not is_fix() then
        set_reason("fix_false")
        last_quality.stable_count = 0
        return false
    end

    if quality.fix_quality < 1 then
        set_reason("fix_quality_low")
        last_quality.stable_count = 0
        return false
    end

    if quality.satellites < MIN_SATELLITES then
        set_reason("low_satellites")
        last_quality.stable_count = 0
        return false
    end

    if type(quality.hdop) ~= "number" or quality.hdop <= 0 or quality.hdop > MAX_HDOP then
        set_reason("hdop_poor")
        last_quality.stable_count = 0
        return false
    end

    last_quality.stable_count = last_quality.stable_count + 1
    if last_quality.stable_count < REQUIRED_STABLE_FIXES then
        set_reason("stabilizing")
        return false
    end

    save_location(lat, lng)
    return true
end

local function gnss_fix_callback()
    if refresh_location() then
        log.info(
            "gnss",
            "fixed",
            "lat=" .. string.format("%.6f", last_location.latitude),
            "lng=" .. string.format("%.6f", last_location.longitude)
        )
    end
end

local function ensure_setup()
    if setup_done then
        return true
    end

    local ok, err = pcall(exgnss.setup, {
        gnssmode = GNSS_MODE,
        agps_enable = AGPS_ENABLE,
        debug = false
    })
    if not ok then
        set_reason("setup_failed")
        log.error("gnss", "setup failed", err or "")
        return false
    end

    setup_done = true
    log.info(
        "gnss",
        "setup ok",
        "mode=" .. tostring(GNSS_MODE),
        "agps=" .. tostring(AGPS_ENABLE),
        "min_sats=" .. tostring(MIN_SATELLITES),
        "max_hdop=" .. tostring(MAX_HDOP),
        "stable=" .. tostring(REQUIRED_STABLE_FIXES)
    )
    return true
end

local function open_gnss(source)
    if not ensure_setup() then
        return false
    end

    if is_active() then
        set_reason("already_active")
        return true
    end

    log.info("gnss", "open", tostring(source or ""))

    local ok, err = pcall(exgnss.open, GNSS_APP_MODE, {
        tag = GNSS_APP_TAG,
        cb = gnss_fix_callback
    })
    if not ok then
        set_reason("open_failed")
        log.error("gnss", "open failed", tostring(source or ""), err or "")
        return false
    end

    if refresh_location() then
        log.info("gnss", "current ready")
    else
        log.warn("gnss", "open ok", "please go outdoor")
    end

    return true
end

local function log_position_status()
    if not is_active() then
        open_gnss("retry")
    end

    if refresh_location() then
        log.info(
            "gnss",
            "position",
            "WGS84",
            "lat=" .. string.format("%.6f", last_location.latitude),
            "lng=" .. string.format("%.6f", last_location.longitude),
            "sats=" .. tostring(last_quality.satellites),
            "hdop=" .. string.format("%.2f", tonumber(last_quality.hdop) or 99),
            "stable=" .. tostring(last_quality.stable_count)
        )
    else
        log.warn(
            "gnss",
            "position",
            "waiting",
            "reason=" .. tostring(last_reason),
            "sats=" .. tostring(last_quality.satellites),
            "hdop=" .. string.format("%.2f", tonumber(last_quality.hdop) or 99),
            "stable=" .. tostring(last_quality.stable_count) .. "/" .. tostring(REQUIRED_STABLE_FIXES),
            "fix=" .. tostring(is_fix())
        )
    end
end

function M.start()
    if started then
        return true
    end

    started = true
    log.info("gnss", "start", "boot_delay=" .. tostring(BOOT_OPEN_DELAY_MS), "status_ms=" .. tostring(STATUS_LOG_INTERVAL_MS))

    sys.subscribe("GNSS_STATE", function(event)
        if event == "FIXED" then
            log.info("gnss", "state", "FIXED")
        elseif event == "LOSE" then
            log.warn("gnss", "state", "LOSE")
        end
    end)

    sys.taskInit(function()
        sys.wait(BOOT_OPEN_DELAY_MS)
        open_gnss("boot")

        sys.timerLoopStart(function()
            log_position_status()
        end, STATUS_LOG_INTERVAL_MS)
    end)

    return true
end

function M.get_location()
    if not has_location() then
        refresh_location()
    end

    if not has_location() then
        return nil
    end

    return {
        latitude = last_location.latitude,
        longitude = last_location.longitude,
        time = last_location.time
    }
end

return M
