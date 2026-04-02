---@diagnostic disable: undefined-global

local json_codec = require("json_codec")
local mqtt_topics = require("mqtt_topics")

local M = {}

local SENSOR_POWER_EN_GPIO = 16
local SENSOR_POWER_ON_LEVEL = 1
local SENSOR_POWER_OFF_LEVEL = 0
local SENSOR_POWER_DEFAULT_ON = false
local SENSOR_POWER_CMD = "sensor_power"
local MQTT_SERVER_COUNT = 2

local state = {
    inited = false,
    subscribed = false,
    enabled = false,
    timer_seq = 0
}

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

local function get_device_sn()
    return mqtt_topics.get_device_sn("NO_SN")
end

local function get_report_topic()
    return mqtt_topics.get_up_resp_topic(get_device_sn())
end

local function ensure_gpio_ready()
    if state.inited then
        return true
    end

    if not gpio or type(gpio.setup) ~= "function" or type(gpio.set) ~= "function" then
        return false
    end

    gpio.setup(SENSOR_POWER_EN_GPIO, SENSOR_POWER_OFF_LEVEL, gpio.PULLDOWN)
    state.inited = true
    return true
end

local function cancel_auto_off()
    state.timer_seq = state.timer_seq + 1
end

local function apply_state(enable, source)
    if not ensure_gpio_ready() then
        return false, "gpio_unavailable"
    end

    state.enabled = enable == true
    gpio.set(SENSOR_POWER_EN_GPIO, state.enabled and SENSOR_POWER_ON_LEVEL or SENSOR_POWER_OFF_LEVEL)
    log.info("sensor_power", "gpio=" .. SENSOR_POWER_EN_GPIO, state.enabled and "on" or "off", source or "")
    return true, state.enabled and "on" or "off"
end

local function schedule_auto_off(duration_ms, source)
    local duration = math.floor(tonumber(duration_ms) or 0)
    if duration <= 0 then
        return
    end

    state.timer_seq = state.timer_seq + 1
    local current_seq = state.timer_seq
    sys.timerStart(function()
        if current_seq ~= state.timer_seq then
            return
        end

        apply_state(false, source or "auto_off")
    end, duration)
end

local function publish_to_server(server_id, body)
    local target = tonumber(server_id)
    if not target or target < 1 or target > MQTT_SERVER_COUNT then
        return false
    end

    local payload = json_codec.encode(body)
    if not payload then
        return false
    end

    sys.publish("mqtt" .. target .. "_send_data_req", "sensor_power", get_report_topic(), payload, 1)
    return true
end

local function reply(server_id, request_id, result, reason, extra)
    local body = {
        cmd = SENSOR_POWER_CMD,
        request_id = request_id,
        result = result,
        reason = reason,
        sn = get_device_sn(),
        time = os.time(),
        gpio = SENSOR_POWER_EN_GPIO,
        enabled = state.enabled
    }

    if type(extra) == "table" then
        for k, v in pairs(extra) do
            body[k] = v
        end
    end

    publish_to_server(server_id, body)
end

local function normalize_enable(obj)
    if type(obj) ~= "table" then
        return nil
    end

    if type(obj.enable) == "boolean" then
        return obj.enable
    end

    if type(obj.on) == "boolean" then
        return obj.on
    end

    local state_text = get_text(obj.state, "")
    if state_text == "on" or state_text == "open" or state_text == "1" then
        return true
    end
    if state_text == "off" or state_text == "close" or state_text == "0" then
        return false
    end

    local action_text = get_text(obj.action, "")
    if action_text == "on" or action_text == "open" then
        return true
    end
    if action_text == "off" or action_text == "close" then
        return false
    end

    return nil
end

function M.is_on()
    return state.enabled == true
end

function M.set(enable, source, auto_off_ms)
    cancel_auto_off()

    local ok, reason = apply_state(enable == true, source)
    if not ok then
        return false, reason
    end

    if enable == true then
        schedule_auto_off(auto_off_ms, source)
    end

    return true, reason
end

function M.on(source, auto_off_ms)
    return M.set(true, source or "manual_on", auto_off_ms)
end

function M.off(source)
    return M.set(false, source or "manual_off")
end

function M.init(default_on)
    if not ensure_gpio_ready() then
        return false
    end

    apply_state(default_on == true, "boot")

    if state.subscribed then
        return true
    end

    if sys and type(sys.subscribe) == "function" then
        sys.subscribe("SENSOR_POWER_SET", function(enable, auto_off_ms)
            M.set(enable == true, "event_set", auto_off_ms)
        end)

        sys.subscribe("SENSOR_POWER_ON", function(auto_off_ms)
            M.on("event_on", auto_off_ms)
        end)

        sys.subscribe("SENSOR_POWER_OFF", function()
            M.off("event_off")
        end)

        state.subscribed = true
    end

    return true
end

function M.handle_command(server_id, obj)
    if type(obj) ~= "table" then
        return false
    end

    local cmd = get_text(obj.cmd, "")
    if cmd ~= SENSOR_POWER_CMD and cmd ~= "set_sensor_power" then
        return false
    end

    local enable = normalize_enable(obj)
    local request_id = get_text(obj.request_id, "sensor-power-" .. tostring(os.time()))
    local auto_off_ms = tonumber(obj.auto_off_ms or obj.duration_ms or obj.timeout_ms or 0) or 0

    if enable == nil then
        reply(server_id, request_id, -1, "invalid_state", {
            auto_off_ms = auto_off_ms
        })
        return true
    end

    local ok, reason = M.set(enable, "mqtt_cmd", auto_off_ms)
    if not ok then
        reply(server_id, request_id, -1, reason or "set_failed", {
            auto_off_ms = auto_off_ms
        })
        return true
    end

    reply(server_id, request_id, 0, "ok", {
        auto_off_ms = auto_off_ms
    })
    return true
end

return M
