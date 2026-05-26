---@diagnostic disable: undefined-global

local json_codec = require("json_codec")
local error_logger = require("error_logger")
local mqtt_topics = require("mqtt_topics")

local M = {}

-- RTC in this project does not use public NTP.
-- Time is requested from the primary MQTT server only.
local DEFAULT_TIMEZONE = "+08:00"
local REQUEST_INTERVAL_SEC = 15
local VALID_TIME_MIN = 1700000000
local PERIODIC_SYNC_INTERVAL_MS = 24 * 60 * 60 * 1000
local INVALID_TIME_RETRY_INTERVAL_MS = 60 * 1000
local PRIMARY_MQTT_SERVER_ID = 1

local request_state = {
    last_request_at = {},
    online = { false, false }
}

-- Small value helpers
local function get_text(value, default)
    if type(value) ~= "string" then
        return default or ""
    end

    local trimmed = value:gsub("^%s+", ""):gsub("%s+$", "")
    if trimmed == "" then
        return default or ""
    end

    return trimmed
end

local function get_number(value, default)
    local n = tonumber(value)
    if not n then
        return default
    end
    return n
end

-- Topic / identity helpers
local function get_device_sn()
    return mqtt_topics.get_device_sn("NO_SN")
end

local function get_report_topic()
    return mqtt_topics.get_up_resp_topic(get_device_sn())
end

local function get_time_sync_topic()
    return mqtt_topics.get_down_resp_topic(get_device_sn())
end

-- MQTT publish wrapper used by request/reply flows
local function publish_to_server(server_id, body)
    local target = tonumber(server_id)
    if target ~= PRIMARY_MQTT_SERVER_ID then
        return false
    end

    local payload = json_codec.encode(body)
    if not payload then
        return false
    end

    log.info(
        "rtc.tx",
        "cmd=" .. tostring(body.cmd or ""),
        "request_id=" .. tostring(body.request_id or ""),
        "result=" .. tostring(body.result or ""),
        "reason=" .. tostring(body.reason or ""),
        "topic=" .. get_report_topic()
    )
    sys.publish("mqtt" .. target .. "_send_data_req", "rtc_cmd", get_report_topic(), payload, 1)
    return true
end

-- Timezone / RTC write helpers
local function parse_timezone(text)
    local tz = get_text(text, DEFAULT_TIMEZONE)
    local sign, hour, minute = tz:match("^([%+%-])(%d%d):(%d%d)$")
    if not sign then
        return false, "invalid_timezone"
    end

    hour = tonumber(hour)
    minute = tonumber(minute)
    if not hour or not minute or hour > 23 or minute > 59 or (minute % 15) ~= 0 then
        return false, "invalid_timezone"
    end

    local quarter = hour * 4 + math.floor(minute / 15)
    local seconds = hour * 3600 + minute * 60
    if sign == "-" then
        quarter = -quarter
        seconds = -seconds
    end

    return true, {
        text = string.format("%s%02d:%02d", sign, hour, minute),
        quarter = quarter,
        seconds = seconds
    }
end

local function set_rtc_from_server_time(server_time, timezone_text)
    local epoch = get_number(server_time)
    if not epoch or epoch <= 0 then
        return false, "invalid_server_time"
    end

    local ok, tz = parse_timezone(timezone_text)
    if not ok then
        return false, tz
    end

    rtc.setBaseYear(1900)
    rtc.timezone(tz.quarter)

    -- LuatOS RTC write expects epoch-based UTC calendar fields.
    -- timezone is configured separately via rtc.timezone().
    local rtc_time = os.date("!*t", epoch)
    if type(rtc_time) ~= "table" then
        return false, "build_rtc_time_failed"
    end

    local set_ok, err = pcall(rtc.set, {
        year = rtc_time.year,
        mon = rtc_time.month,
        day = rtc_time.day,
        hour = rtc_time.hour,
        min = rtc_time.min,
        sec = rtc_time.sec
    })
    if not set_ok then
        return false, err or "rtc_set_failed"
    end

    local local_time = os.date("!*t", epoch + tz.seconds)
    if type(local_time) ~= "table" then
        return false, "build_local_time_failed"
    end

    sys.publish("RTC_TIME_UPDATED", epoch, tz.text)
    return true, {
        server_time = epoch,
        timezone = tz.text,
        local_time = string.format(
            "%04d-%02d-%02d %02d:%02d:%02d",
            local_time.year,
            local_time.month,
            local_time.day,
            local_time.hour,
            local_time.min,
            local_time.sec
        )
    }
end

-- Runtime state helpers
local function is_time_valid()
    local now = os.time()
    return type(now) == "number" and now >= VALID_TIME_MIN
end

local function reply(server_id, request_id, result, reason, extra)
    local body = {
        cmd = "timeSync",
        request_id = request_id,
        result = result,
        reason = reason,
        sn = get_device_sn(),
        time = os.time()
    }

    if type(extra) == "table" then
        for k, v in pairs(extra) do
            body[k] = v
        end
    end

    publish_to_server(server_id, body)
end

-- Time request helpers
local function request_time(server_id, force)
    local now = os.time()
    local last_request_at = request_state.last_request_at[server_id] or 0
    if not force and now - last_request_at < REQUEST_INTERVAL_SEC then
        return false
    end

    request_state.last_request_at[server_id] = now
    return publish_to_server(server_id, {
        cmd = "request_time",
        request_id = "timereq-" .. tostring(server_id) .. "-" .. tostring(now),
        sn = get_device_sn(),
        has_valid_time = is_time_valid(),
        time = now
    })
end

local function get_preferred_online_server()
    if request_state.online[PRIMARY_MQTT_SERVER_ID] == true then
        return PRIMARY_MQTT_SERVER_ID
    end

    return nil
end

local function request_time_from_online_server(force, reason)
    local server_id = get_preferred_online_server()
    if not server_id then
        log.warn("rtc", "skip time request, no mqtt online", reason or "")
        return false
    end

    log.info("rtc", "request time", reason or "manual", "server", server_id)
    return request_time(server_id, force == true)
end

-- Public API
function M.request_now(server_id, force)
    return request_time(server_id, force == true)
end

function M.is_time_valid()
    return is_time_valid()
end

function M.is_time_sync_topic(topic)
    local current = get_text(topic, "")
    if current == "" then
        return false
    end

    return current == get_time_sync_topic() or current == mqtt_topics.get_down_cmd_topic(get_device_sn())
end

function M.handle_command(server_id, topic, obj)
    if type(obj) ~= "table" or not M.is_time_sync_topic(topic) then
        return false
    end

    local cmd = get_text(obj.cmd, "")
    if cmd ~= "timeSync" then
        return false
    end

    local request_id = get_text(obj.request_id, "time-sync-" .. tostring(os.time()))
    local server_time = obj.serverTime
    if server_time == nil then
        server_time = obj.time
    end

    log.info(
        "rtc.rx",
        "cmd=" .. cmd,
        "request_id=" .. request_id,
        "serverTime=" .. tostring(server_time or ""),
        "timezone=" .. tostring(obj.timezone or "")
    )

    local ok, info_or_err = set_rtc_from_server_time(server_time, obj.timezone)
    if not ok then
        error_logger.error("rtc", "time sync failed", info_or_err or "")
        reply(server_id, request_id, -1, info_or_err or "time_sync_failed")
        return true
    end

    log.info("rtc", "time synced", info_or_err.local_time, info_or_err.timezone)
    reply(server_id, request_id, 0, "ok", {
        serverTime = info_or_err.server_time,
        timezone = info_or_err.timezone,
        localTime = info_or_err.local_time
    })
    return true
end

-- MQTT connection event -> trigger first time request
local function make_conn_handler(server_id)
    return function(online)
        request_state.online[server_id] = online == true
        if online == true then
            sys.timerStart(function()
                request_time(server_id, true)
            end, 1500)
        end
    end
end

rtc.setBaseYear(1900)
local tz_ok, tz = parse_timezone(DEFAULT_TIMEZONE)
if tz_ok then
    rtc.timezone(tz.quarter)
end

sys.subscribe("MQTT1_CONN_EVENT", make_conn_handler(PRIMARY_MQTT_SERVER_ID))

-- Periodic maintenance loop:
-- invalid time -> retry frequently
-- valid time   -> sync once per day
sys.taskInit(function()
    while true do
        if is_time_valid() then
            sys.wait(PERIODIC_SYNC_INTERVAL_MS)
            request_time_from_online_server(true, "periodic")
        else
            sys.wait(INVALID_TIME_RETRY_INTERVAL_MS)
            request_time_from_online_server(true, "recover")
        end
    end
end)

return M
