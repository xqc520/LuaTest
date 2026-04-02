---@diagnostic disable: undefined-global

local libfota2 = require("libfota2")
local ota_manager = require("ota_manager")

local ENABLE_VERSION_HEARTBEAT_LOG = false
local DUPLICATE_WINDOW_SEC = 60
local OTA_REBOOT_DELAY_MS = 2000
local OTA_WATCHDOG_FEED_MS = 5000

local ota_busy = false
local current_request
local last_request_key
local last_request_at = 0

local function log_version()
    log.info("fota", "version", VERSION, "core", rtos.version())
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
    log.info("fota", "callback", ret, message)

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
        sys.waitUntil("IP_READY", 1000)
    end
end

sys.taskInit(function()
    wait_for_ip_ready()
    log.info("fota", "IP ready")

    while true do
        local ret, request = sys.waitUntil("OTA_EXEC_REQUEST")
        if ret and request then
            if is_recent_duplicate(request) then
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

                publish_request_report("start", "ota start", nil)
                log.info("fota", "start upgrade", request.url, request.version or "")

                local opts = {
                    url = request.url
                }
                if request.timeout then
                    opts.timeout = request.timeout
                end

                local started = libfota2.request(fota_cb, opts)
                if started == false then
                    publish_request_report("failed", "fota request start failed", -1)
                    ota_busy = false
                    current_request = nil
                end
            end
        end
    end
end)
