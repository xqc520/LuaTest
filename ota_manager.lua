---@diagnostic disable: undefined-global

local json_codec = require("json_codec")
local error_logger = require("error_logger")
local mqtt_topics = require("mqtt_topics")

local M = {}

local OTA_REPORT_QOS = 1
local VERSION_PARTS = 3
local MQTT_SERVER_COUNT = 2
local PRIMARY_MQTT_SERVER_ID = 1

local function get_text(value, default)
    if type(value) == "string" and value ~= "" then
        return value
    end

    return default
end

local function get_bool(value)
    return value == true or value == 1 or value == "1" or value == "true" or value == "TRUE"
end

local function split_version(value)
    if type(value) ~= "string" or value == "" then
        return nil
    end

    local parts = {}
    for num in value:gmatch("(%d+)") do
        parts[#parts + 1] = tonumber(num) or 0
        if #parts >= VERSION_PARTS then
            break
        end
    end

    if #parts == 0 then
        return nil
    end

    return parts
end

local function normalize_custom_url(url)
    if type(url) ~= "string" or url == "" then
        return nil
    end

    if url:find("^###") then
        return url
    end

    if url:find("^https?://") then
        return "###" .. url
    end

    return url
end

local function publish_to_server(server_id, topic, payload, qos)
    local target = tonumber(server_id)
    if target and target >= 1 and target <= MQTT_SERVER_COUNT then
        sys.publish("mqtt" .. target .. "_send_data_req", "ota", topic, payload, qos or OTA_REPORT_QOS)
        return
    end

    sys.publish("mqtt" .. PRIMARY_MQTT_SERVER_ID .. "_send_data_req", "ota", topic, payload, qos or OTA_REPORT_QOS)
end

function M.get_device_info()
    local sn = "NO_SN"
    if EPD_STATUS and EPD_STATUS.get_sn then
        sn = get_text(EPD_STATUS.get_sn(), sn)
    end

    local imei = "NO_IMEI"
    if mobile and mobile.imei then
        imei = get_text(mobile.imei(), imei)
    end

    local project = tostring(PROJECT or "UNKNOWN")
    local version = tostring(VERSION or "0.0.0")
    local firmware = project .. "-" .. version

    local core_version = ""
    if rtos and rtos.version then
        core_version = tostring(rtos.version() or "")
    end

    return {
        sn = sn,
        imei = imei,
        project = project,
        version = version,
        firmware = firmware,
        core_version = core_version
    }
end

function M.compare_versions(left, right)
    local left_parts = split_version(left)
    local right_parts = split_version(right)
    if not left_parts or not right_parts then
        return nil
    end

    for i = 1, VERSION_PARTS do
        local left_num = left_parts[i] or 0
        local right_num = right_parts[i] or 0
        if left_num < right_num then
            return -1
        elseif left_num > right_num then
            return 1
        end
    end

    return 0
end

function M.get_subscribe_topics()
    local device_info = M.get_device_info()

    return {
        [mqtt_topics.get_ota_update_topic(device_info.sn)] = 2
    }
end

function M.is_ota_topic(topic)
    if type(topic) ~= "string" then
        return false
    end

    return M.get_subscribe_topics()[topic] ~= nil
end

local function parse_request_body(payload)
    if type(payload) ~= "string" or payload == "" then
        return {}, nil
    end

    local obj, err = json_codec.decode(payload)
    if type(obj) == "table" then
        return obj, nil
    end

    if payload:find("^###https?://") or payload:find("^https?://") then
        return { url = payload }, nil
    end

    if payload == "update" or payload == "ota" then
        return {}, nil
    end

    return nil, err or "invalid ota payload"
end

function M.build_request(server_id, topic, payload)
    local body, err = parse_request_body(payload)
    if not body then
        return nil, err
    end

    local device_info = M.get_device_info()
    local version = get_text(body.version, nil)
    if version and not split_version(version) then
        return nil, "invalid target version"
    end

    local normalized_url = normalize_custom_url(body.url)
    if not normalized_url then
        return nil, "missing ota url"
    end

    local request = {
        request_id = get_text(body.request_id, string.format("%s-%d", device_info.sn, os.time())),
        url = normalized_url,
        version = version,
        md5 = get_text(body.md5, nil),
        force = get_bool(body.force),
        timeout = tonumber(body.timeout),
        source_server = tonumber(server_id),
        source_topic = topic,
        requested_at = os.time()
    }

    if request.timeout and request.timeout <= 0 then
        request.timeout = nil
    end

    return request
end

function M.get_report_topic()
    return mqtt_topics.get_ota_report_topic(M.get_device_info().sn)
end

function M.publish_report(server_id, report)
    local device_info = M.get_device_info()
    local body = {
        request_id = report and report.request_id or "",
        status = report and report.status or "unknown",
        message = report and report.message or "",
        sn = device_info.sn,
        imei = device_info.imei,
        project = device_info.project,
        version = device_info.version,
        firmware = device_info.firmware,
        core_version = device_info.core_version,
        target_version = report and report.target_version or nil,
        url = report and report.url or nil,
        md5 = report and report.md5 or nil,
        source_server = report and report.source_server or nil,
        source_topic = report and report.source_topic or nil,
        result_code = report and report.result_code or nil,
        time = os.time()
    }

    local payload, err = json_codec.encode(body)
    if not payload then
        error_logger.error("ota", "encode report failed", err or "")
        return false
    end

    publish_to_server(server_id or (report and report.source_server), M.get_report_topic(), payload, OTA_REPORT_QOS)
    return true
end

function M.handle_message(server_id, topic, payload)
    if not M.is_ota_topic(topic) then
        return false
    end

    local request, err = M.build_request(server_id, topic, payload)
    if not request then
        M.publish_report(server_id, {
            status = "invalid_payload",
            message = err or "invalid ota payload",
            source_server = server_id,
            source_topic = topic
        })
        return true
    end

    if request.version and not request.force then
        local cmp = M.compare_versions(request.version, M.get_device_info().version)
        if cmp and cmp <= 0 then
            M.publish_report(server_id, {
                request_id = request.request_id,
                status = "already_latest",
                message = "target version is not newer",
                target_version = request.version,
                url = request.url,
                md5 = request.md5,
                source_server = request.source_server,
                source_topic = request.source_topic
            })
            return true
        end
    end

    sys.publish("OTA_EXEC_REQUEST", request)
    return true
end

return M
