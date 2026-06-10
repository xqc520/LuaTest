---@diagnostic disable: undefined-global

local json_codec = require("json_codec")
local error_logger = require("error_logger")
local mqtt_topics = require("mqtt_topics")

local M = {}

local OTA_REPORT_QOS = 1
local VERSION_PARTS = 3
local MQTT_SERVER_COUNT = 2
local PRIMARY_MQTT_SERVER_ID = 1
local OTA_LOG_TAG = "ota"
local MAX_PAYLOAD_PREVIEW = 200

local DEFAULT_SN = "NO_SN"
local DEFAULT_IMEI = "NO_IMEI"
local DEFAULT_PROJECT = "UNKNOWN"
local DEFAULT_VERSION = "0.0.0"
local OTA_EXEC_EVENT = "OTA_EXEC_REQUEST"
local DEFAULT_INVALID_PAYLOAD_MSG = "invalid ota payload"
local DEFAULT_MISSING_URL_MSG = "missing ota url"
local DEFAULT_INVALID_VERSION_MSG = "invalid target version"

-- ---------------------------------------------------------------------------
-- 通用小工具
-- ---------------------------------------------------------------------------

local function get_text(value, default)
    if type(value) == "string" and value ~= "" then
        return value
    end

    return default
end

local function get_bool(value)
    return value == true or value == 1 or value == "1" or value == "true" or value == "TRUE"
end

local function preview_text(value)
    if type(value) ~= "string" then
        return tostring(value)
    end

    local text = value:gsub("[\r\n]+", " ")
    if #text > MAX_PAYLOAD_PREVIEW then
        return text:sub(1, MAX_PAYLOAD_PREVIEW) .. "..."
    end

    return text
end

local function normalize_payload_text(payload)
    if type(payload) ~= "string" then
        return nil
    end

    local text = payload:gsub("^%s+", ""):gsub("%s+$", "")
    if text == "" then
        return nil
    end

    return text
end

local function resolve_server_id(server_id)
    local target = tonumber(server_id)
    if target and target >= 1 and target <= MQTT_SERVER_COUNT then
        return target
    end

    return PRIMARY_MQTT_SERVER_ID
end

local function publish_to_server(server_id, topic, payload, qos)
    local target = resolve_server_id(server_id)
    sys.publish("mqtt" .. target .. "_send_data_req", "ota", topic, payload, qos or OTA_REPORT_QOS)
    return target
end

-- ---------------------------------------------------------------------------
-- 设备信息与版本处理
-- ---------------------------------------------------------------------------

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

function M.get_device_info()
    local sn = DEFAULT_SN
    if EPD_STATUS and EPD_STATUS.get_sn then
        sn = get_text(EPD_STATUS.get_sn(), sn)
    end

    local imei = DEFAULT_IMEI
    if mobile and mobile.imei then
        imei = get_text(mobile.imei(), imei)
    end

    local project = tostring(PROJECT or DEFAULT_PROJECT)
    local version = tostring(VERSION or DEFAULT_VERSION)
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

-- ---------------------------------------------------------------------------
-- OTA topic 与请求解析
-- ---------------------------------------------------------------------------

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

-- OTA 下发支持三种最常见格式：
-- 1. JSON：{"url":"http://...","version":"1.0.1","force":false}
-- 2. 纯文本 URL：http://...
-- 3. 简单触发词：update / ota（此时仍要求后续能解析出有效 url）
local function parse_request_body(payload)
    local text = normalize_payload_text(payload)
    if not text then
        return {}, nil
    end

    local obj, err = json_codec.decode(text)
    if type(obj) == "table" then
        return obj, nil
    end

    if text:find("^###https?://") or text:find("^https?://") then
        return { url = text }, nil
    end

    if text == "update" or text == "ota" then
        return {}, nil
    end

    return nil, err or DEFAULT_INVALID_PAYLOAD_MSG
end

function M.build_request(server_id, topic, payload)
    local body, err = parse_request_body(payload)
    if not body then
        return nil, err
    end

    local device_info = M.get_device_info()
    local version = get_text(body.version, nil)
    if version and not split_version(version) then
        return nil, DEFAULT_INVALID_VERSION_MSG
    end

    local normalized_url = normalize_custom_url(body.url)
    if not normalized_url then
        return nil, DEFAULT_MISSING_URL_MSG
    end

    local timeout = tonumber(body.timeout)
    if timeout and timeout <= 0 then
        timeout = nil
    end

    return {
        request_id = get_text(body.request_id, string.format("ota-%s-%d", device_info.sn, os.time())),
        url = normalized_url,
        version = version,
        md5 = get_text(body.md5, nil),
        force = get_bool(body.force),
        timeout = timeout,
        source_server = tonumber(server_id),
        source_topic = topic,
        requested_at = os.time()
    }
end

-- ---------------------------------------------------------------------------
-- OTA 回包
-- ---------------------------------------------------------------------------

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
        time = os.time()
    }

    if report and report.result_code ~= nil then
        body.result_code = report.result_code
    end

    local payload, err = json_codec.encode(body)
    if not payload then
        error_logger.error("ota", "encode report failed", err or "")
        return false
    end

    local target_server = publish_to_server(
        server_id or (report and report.source_server),
        M.get_report_topic(),
        payload,
        OTA_REPORT_QOS
    )

    log.info(
        OTA_LOG_TAG,
        "tx report",
        "server",
        target_server,
        "status",
        tostring(body.status),
        "request_id",
        tostring(body.request_id),
        "result_code",
        tostring(body.result_code or ""),
        "message",
        preview_text(body.message or "")
    )
    return true
end

-- ---------------------------------------------------------------------------
-- OTA 消息入口
-- ---------------------------------------------------------------------------

function M.handle_message(server_id, topic, payload)
    if not M.is_ota_topic(topic) then
        return false
    end

    log.info(
        OTA_LOG_TAG,
        "rx update",
        "server",
        tostring(server_id or ""),
        "topic",
        tostring(topic or ""),
        "payload",
        preview_text(payload or "")
    )

    local request, err = M.build_request(server_id, topic, payload)
    if not request then
        log.warn(OTA_LOG_TAG, "reject update", err or DEFAULT_INVALID_PAYLOAD_MSG)
        M.publish_report(server_id, {
            status = "invalid_payload",
            message = err or DEFAULT_INVALID_PAYLOAD_MSG,
            source_server = server_id,
            source_topic = topic
        })
        return true
    end

    local current_version = M.get_device_info().version
    if request.version and not request.force then
        local cmp = M.compare_versions(request.version, current_version)
        if cmp and cmp <= 0 then
            log.info(
                OTA_LOG_TAG,
                "skip update",
                "request_id",
                tostring(request.request_id),
                "target_version",
                tostring(request.version),
                "current_version",
                tostring(current_version)
            )
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

    log.info(
        OTA_LOG_TAG,
        "queue update",
        "request_id",
        tostring(request.request_id),
        "version",
        tostring(request.version or ""),
        "force",
        request.force and "1" or "0",
        "timeout",
        tostring(request.timeout or ""),
        "url",
        preview_text(request.url or "")
    )

    sys.publish(OTA_EXEC_EVENT, request)
    return true
end

return M
