---@diagnostic disable: undefined-global

local libfota2 = require("libfota2")
local ota_manager = require("ota_manager")
local sdcard = require("sdcard")

local ENABLE_VERSION_HEARTBEAT_LOG = false
local DUPLICATE_WINDOW_SEC = 60
local OTA_REBOOT_DELAY_MS = 2000
local OTA_WATCHDOG_FEED_MS = 5000
local OTA_LOG_TAG = "fota"
local VERIFY_FILE_SD_PATH = "/sd/ota_verify.bin"
local VERIFY_FILE_FLASH_PATH = "/ota_verify.bin"

local ota_busy = false
local current_request
local last_request_key
local last_request_at = 0

local function display_url(url)
    if type(url) ~= "string" then
        return ""
    end

    return url:gsub("^###", "")
end

local function log_version()
    log.info(OTA_LOG_TAG, "version", VERSION, "core", rtos.version())
end

if ENABLE_VERSION_HEARTBEAT_LOG then
    sys.timerLoopStart(log_version, 30000)
else
    log_version()
end

sys.timerLoopStart(function()
    if ota_busy then
        sys.publish("FEED_NETWORK_WATCHDOG")
    end
end, OTA_WATCHDOG_FEED_MS)

local function result_message(ret)
    local messages = {
        [0] = "upgrade package downloaded",
        [1] = "connect failed",
        [2] = "invalid url",
        [3] = "server disconnected",
        [4] = "package download failed",
        [5] = "invalid version format"
    }

    return messages[ret] or ("unknown result " .. tostring(ret))
end

local function build_request_key(request)
    if request.request_id and request.request_id ~= "" then
        return "id:" .. request.request_id
    end

    return table.concat({
        tostring(request.url or ""),
        tostring(request.version or ""),
        tostring(request.source_topic or "")
    }, "|")
end

local function is_recent_duplicate(request)
    local key = build_request_key(request)
    local now = os.time()
    if last_request_key == key and (now - last_request_at) <= DUPLICATE_WINDOW_SEC then
        return true
    end

    last_request_key = key
    last_request_at = now
    return false
end

local function publish_request_report(status, message, result_code)
    local request = current_request or {}
    log.info(
        OTA_LOG_TAG,
        "report",
        "status",
        tostring(status),
        "request_id",
        tostring(request.request_id or ""),
        "code",
        tostring(result_code or ""),
        "message",
        tostring(message or "")
    )
    ota_manager.publish_report(request.source_server, {
        request_id = request.request_id,
        status = status,
        message = message,
        target_version = request.version,
        url = request.url,
        md5 = request.md5,
        source_server = request.source_server,
        source_topic = request.source_topic,
        result_code = result_code
    })
end

local function fota_cb(ret)
    local message = result_message(ret)
    log.info(OTA_LOG_TAG, "callback", "ret", ret, "request_id", tostring(current_request and current_request.request_id or ""), message)

    if ret == 0 then
        publish_request_report("success", message, ret)
        ota_busy = false
        current_request = nil
        sys.timerStart(rtos.reboot, OTA_REBOOT_DELAY_MS)
        return
    end

    publish_request_report("failed", message, ret)
    ota_busy = false
    current_request = nil
end

local function wait_for_ip_ready()
    while not socket.adapter(socket.dft()) do
        log.info(OTA_LOG_TAG, "wait IP_READY")
        sys.waitUntil("IP_READY", 1000)
    end
end

local function safe_remove(path)
    if not path or not os or type(os.remove) ~= "function" then
        return
    end

    pcall(os.remove, path)
end

local function normalize_md5(value)
    if type(value) ~= "string" then
        return nil
    end

    local text = value:gsub("%s+", ""):lower()
    if text:match("^[0-9a-f]{32}$") then
        return text
    end

    return nil
end

local function pick_verify_file_path()
    if sdcard and type(sdcard.init) == "function" and sdcard.init() then
        return VERIFY_FILE_SD_PATH
    end

    return VERIFY_FILE_FLASH_PATH
end

-- 为了做真 md5 校验，先临时下载一份升级包到本地。
-- 这样能算出文件 md5，但代价是服务器会被下载两次：
-- 1. 校验下载
-- 2. libfota2 正式升级下载
local function verify_request_md5(request)
    local expected_md5 = normalize_md5(request.md5)
    if not expected_md5 then
        return false, "invalid md5 format"
    end

    if not http or type(http.request) ~= "function" then
        return false, "http library unavailable"
    end

    if not crypto or type(crypto.md_file) ~= "function" then
        return false, "crypto md_file unavailable"
    end

    local verify_url = display_url(request.url)
    if verify_url == "" then
        return false, "invalid verify url"
    end

    local verify_path = pick_verify_file_path()
    safe_remove(verify_path)

    log.info(OTA_LOG_TAG, "verify download", "request_id", tostring(request.request_id), "path", verify_path, "url", verify_url)
    publish_request_report("verify_start", "ota md5 verify start", nil)

    local code, headers, body = http.request("GET", verify_url, nil, nil, {
        timeout = request.timeout,
        dst = verify_path
    }).wait()

    if code ~= 200 then
        safe_remove(verify_path)
        return false, "verify download failed code=" .. tostring(code or "nil")
    end

    local actual_md5 = crypto.md_file("MD5", verify_path)
    safe_remove(verify_path)

    if type(actual_md5) ~= "string" or actual_md5 == "" then
        return false, "verify md5 calculate failed"
    end

    actual_md5 = actual_md5:lower()
    log.info(OTA_LOG_TAG, "verify md5", "request_id", tostring(request.request_id), "expected", expected_md5, "actual", actual_md5)

    if actual_md5 ~= expected_md5 then
        return false, "md5 mismatch expected=" .. expected_md5 .. " actual=" .. actual_md5
    end

    publish_request_report("verify_ok", "ota md5 verify ok", nil)
    return true
end

sys.taskInit(function()
    wait_for_ip_ready()
    log.info(OTA_LOG_TAG, "IP ready")

    while true do
        local ret, request = sys.waitUntil("OTA_EXEC_REQUEST")
        if ret and request then
            if is_recent_duplicate(request) then
                log.warn(OTA_LOG_TAG, "duplicate request", tostring(request.request_id))
                ota_manager.publish_report(request.source_server, {
                    request_id = request.request_id,
                    status = "duplicate",
                    message = "duplicate ota request ignored",
                    target_version = request.version,
                    url = request.url,
                    md5 = request.md5,
                    source_server = request.source_server,
                    source_topic = request.source_topic
                })
            elseif ota_busy then
                log.warn(OTA_LOG_TAG, "busy request", tostring(request.request_id))
                ota_manager.publish_report(request.source_server, {
                    request_id = request.request_id,
                    status = "busy",
                    message = "ota already in progress",
                    target_version = request.version,
                    url = request.url,
                    md5 = request.md5,
                    source_server = request.source_server,
                    source_topic = request.source_topic
                })
            else
                wait_for_ip_ready()

                current_request = request
                ota_busy = true

                log.info(
                    OTA_LOG_TAG,
                    "start request",
                    "request_id",
                    tostring(request.request_id),
                    "version",
                    tostring(request.version or ""),
                    "timeout",
                    tostring(request.timeout or ""),
                    "md5",
                    tostring(request.md5 or ""),
                    "url",
                    display_url(request.url)
                )

                local verify_ok = true
                if request.md5 and request.md5 ~= "" then
                    local ok_verify, verify_message = verify_request_md5(request)
                    if not ok_verify then
                        log.error(OTA_LOG_TAG, "verify failed", tostring(request.request_id), verify_message)
                        publish_request_report("verify_failed", verify_message, -2)
                        ota_busy = false
                        current_request = nil
                        verify_ok = false
                    end
                end

                if verify_ok then
                    publish_request_report("start", "ota start", nil)

                    local opts = {
                        url = request.url
                    }
                    if request.timeout then
                        opts.timeout = request.timeout
                    end

                    local started = libfota2.request(fota_cb, opts)
                    if started == false then
                        log.error(OTA_LOG_TAG, "request start failed", tostring(request.request_id))
                        publish_request_report("failed", "fota request start failed", -1)
                        ota_busy = false
                        current_request = nil
                    end
                end
            end
        end
    end
end)
