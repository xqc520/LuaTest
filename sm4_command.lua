---@diagnostic disable: undefined-global

local json_codec = require("json_codec")
local flash_config = require("flash_config")
local sm4_codec = require("sm4_codec")
local error_logger = require("error_logger")
local mqtt_topics = require("mqtt_topics")

local M = {}

local REQUEST_INTERVAL_SEC = 15
local PRIMARY_MQTT_SERVER_ID = 1
local request_state = {
    last_request_at = {}
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

local function has_local_sm4()
    local saved = flash_config.getSm4 and flash_config.getSm4() or nil
    if type(saved) ~= "table" then
        return false
    end

    return sm4_codec.validate_remote_config(saved.key, saved.iv) == true
end

local function publish_to_server(server_id, body)
    local target = tonumber(server_id)
    if target ~= PRIMARY_MQTT_SERVER_ID then
        return false
    end

    local payload = json_codec.encode(body)
    if not payload then
        return false
    end

    sys.publish("mqtt" .. target .. "_send_data_req", "sm4_cmd", get_report_topic(), payload, 1)
    return true
end

local function reply(server_id, request_id, result, reason, extra)
    local body = {
        cmd = "set_sm4",
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

local function request_sm4(server_id, force)
    local now = os.time()
    local last_request_at = request_state.last_request_at[server_id] or 0
    if not force and now - last_request_at < REQUEST_INTERVAL_SEC then
        return false
    end

    request_state.last_request_at[server_id] = now
    return publish_to_server(server_id, {
        cmd = "request_sm4",
        request_id = "sm4req-" .. tostring(server_id) .. "-" .. tostring(now),
        sn = get_device_sn(),
        has_local = has_local_sm4(),
        time = now
    })
end

function M.request_now(server_id, force)
    return request_sm4(server_id, force == true)
end

function M.is_ready()
    return sm4_codec.is_runtime_ready and sm4_codec.is_runtime_ready() or false
end

function M.handle_command(server_id, obj)
    if type(obj) ~= "table" then
        return false
    end

    local cmd = get_text(obj.cmd, "")
    if cmd ~= "set_sm4" then
        return false
    end

    local request_id = get_text(obj.request_id, "set-sm4-" .. tostring(os.time()))
    local key = get_text(obj.key, "")
    local iv = get_text(obj.iv, "")

    local ok, info_or_err = sm4_codec.validate_remote_config(key, iv)
    if not ok then
        reply(server_id, request_id, -1, info_or_err or "invalid_sm4")
        return true
    end

    if not flash_config.setSm4({
        key = key,
        iv = iv
    }) then
        error_logger.error("sm4_cmd", "save sm4 config failed")
        reply(server_id, request_id, -1, "save_failed")
        return true
    end

    reply(server_id, request_id, 0, "ok", {
        mode = info_or_err.mode,
        padding = info_or_err.padding,
        key_format = info_or_err.key_format,
        iv_format = info_or_err.iv_format
    })
    sys.publish("SM4_CONFIG_READY")
    return true
end

local function make_conn_handler(server_id)
    return function(online)
        if online == true then
            sys.timerStart(function()
                request_sm4(server_id, true)
            end, 1000)
        end
    end
end

sys.subscribe("MQTT1_CONN_EVENT", make_conn_handler(PRIMARY_MQTT_SERVER_ID))

return M
