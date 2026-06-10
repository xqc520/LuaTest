---@diagnostic disable: undefined-global

local libfota2 = require("libfota2")
local ota_manager = require("ota_manager")
local sdcard = require("sdcard")

-- ---------------------------------------------------------------------------
-- 固定配置
-- ---------------------------------------------------------------------------

local ENABLE_VERSION_HEARTBEAT_LOG = false
local VERSION_LOG_INTERVAL_MS = 30000

-- 同一请求在短时间内重复到达时，直接忽略后续重复请求。
local DUPLICATE_WINDOW_SEC = 60

-- OTA 成功后延时重启，给状态上报和日志留一点缓冲时间。
local OTA_REBOOT_DELAY_MS = 2000

-- OTA 下载时间可能较长，期间持续喂网络看门狗，避免误判卡死。
local OTA_WATCHDOG_FEED_MS = 5000

local OTA_LOG_TAG = "fota"
local OTA_EXEC_EVENT = "OTA_EXEC_REQUEST"
local IP_READY_EVENT = "IP_READY"
local FEED_NETWORK_WATCHDOG_EVENT = "FEED_NETWORK_WATCHDOG"

-- MD5 预校验下载时优先落到 SD；如果 SD 不可用，则回退到 flash 临时文件。
local VERIFY_FILE_SD_PATH = "/sd/ota_verify.bin"
local VERIFY_FILE_FLASH_PATH = "/ota_verify.bin"

local RESULT_MESSAGES = {
    [0] = "upgrade package downloaded",
    [1] = "connect failed",
    [2] = "invalid url",
    [3] = "server disconnected",
    [4] = "package download failed",
    [5] = "invalid version format"
}

-- ---------------------------------------------------------------------------
-- 运行时状态
-- ---------------------------------------------------------------------------

-- ota_busy: 当前是否已经有一个 OTA 请求在执行
-- current_request: 当前正在处理的请求，供回调和状态回包复用
-- last_request_key/last_request_at: 用于短时间重复请求去重
local ota_busy = false
local current_request
local last_request_key
local last_request_at = 0

-- ---------------------------------------------------------------------------
-- 通用工具
-- ---------------------------------------------------------------------------

-- 服务端下发的 OTA URL 可能带前缀 ###，日志和校验下载时需要去掉。
local function display_url(url)
    if type(url) ~= "string" then
        return ""
    end

    return url:gsub("^###", "")
end

local function log_version()
    log.info(OTA_LOG_TAG, "version", VERSION, "core", rtos.version())
end

-- 把 libfota2 的结果码翻译成日志和回包可用的文案。
local function result_message(ret)
    return RESULT_MESSAGES[ret] or ("unknown result " .. tostring(ret))
end

-- request_id 优先作为去重键；没有 request_id 时，再退回到 url/version/topic 组合。
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

-- 同一时间窗口内的同一请求视为重复请求。
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

-- 删除临时校验文件时不关心失败，只做尽力而为的清理。
local function safe_remove(path)
    if not path or not os or type(os.remove) ~= "function" then
        return
    end

    pcall(os.remove, path)
end

-- 把 MD5 规范成 32 位小写十六进制，非法时返回 nil。
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

-- 校验下载的临时文件优先放到 SD，避免占用内部 flash。
local function pick_verify_file_path()
    if sdcard and type(sdcard.init) == "function" and sdcard.init() then
        return VERIFY_FILE_SD_PATH
    end

    return VERIFY_FILE_FLASH_PATH
end

-- 等待网络拿到 IP。OTA 启动前和真正开始下载前都会调用。
local function wait_for_ip_ready()
    while not socket.adapter(socket.dft()) do
        log.info(OTA_LOG_TAG, "wait IP_READY")
        sys.waitUntil(IP_READY_EVENT, 1000)
    end
end

-- ---------------------------------------------------------------------------
-- 回包与状态管理
-- ---------------------------------------------------------------------------

local function build_report_payload(request, status, message, result_code)
    request = request or {}

    return {
        request_id = request.request_id,
        status = status,
        message = message,
        target_version = request.version,
        url = request.url,
        md5 = request.md5,
        source_server = request.source_server,
        source_topic = request.source_topic,
        result_code = result_code
    }
end

-- 给指定请求发送 OTA 状态回包。
local function publish_report_for_request(request, status, message, result_code)
    request = request or {}
    ota_manager.publish_report(
        request.source_server,
        build_report_payload(request, status, message, result_code)
    )
end

-- 当前请求的状态回包，同时补一条结构化日志，便于问题定位。
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

    publish_report_for_request(request, status, message, result_code)
end

local function clear_current_request()
    ota_busy = false
    current_request = nil
end

local function begin_current_request(request)
    current_request = request
    ota_busy = true
end

-- 失败场景统一走这里，先回包再清状态。
local function fail_current_request(status, message, result_code)
    publish_request_report(status, message, result_code)
    clear_current_request()
end

local function report_duplicate_request(request)
    log.warn(OTA_LOG_TAG, "duplicate request", tostring(request.request_id))
    publish_report_for_request(request, "duplicate", "duplicate ota request ignored", nil)
end

local function report_busy_request(request)
    log.warn(OTA_LOG_TAG, "busy request", tostring(request.request_id))
    publish_report_for_request(request, "busy", "ota already in progress", nil)
end

-- ---------------------------------------------------------------------------
-- OTA 回调与校验
-- ---------------------------------------------------------------------------

local function fota_cb(ret)
    local message = result_message(ret)

    log.info(
        OTA_LOG_TAG,
        "callback",
        "ret",
        ret,
        "request_id",
        tostring(current_request and current_request.request_id or ""),
        message
    )

    if ret == 0 then
        publish_request_report("success", message, ret)
        clear_current_request()
        sys.timerStart(rtos.reboot, OTA_REBOOT_DELAY_MS)
        return
    end

    fail_current_request("failed", message, ret)
end

-- 为了做真实 MD5 校验，先临时下载一份升级包到本地。
-- 这样能算出文件 MD5，但代价是服务器会被下载两次：
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

    log.info(
        OTA_LOG_TAG,
        "verify download",
        "request_id",
        tostring(request.request_id),
        "path",
        verify_path,
        "url",
        verify_url
    )
    publish_request_report("verify_start", "ota md5 verify start", nil)

    local code = http.request("GET", verify_url, nil, nil, {
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
    log.info(
        OTA_LOG_TAG,
        "verify md5",
        "request_id",
        tostring(request.request_id),
        "expected",
        expected_md5,
        "actual",
        actual_md5
    )

    if actual_md5 ~= expected_md5 then
        return false, "md5 mismatch expected=" .. expected_md5 .. " actual=" .. actual_md5
    end

    publish_request_report("verify_ok", "ota md5 verify ok", nil)
    return true
end

-- 有 MD5 才做预校验；失败时统一回包并结束当前请求。
local function verify_request_if_needed(request)
    if not request.md5 or request.md5 == "" then
        return true
    end

    local ok_verify, verify_message = verify_request_md5(request)
    if ok_verify then
        return true
    end

    log.error(OTA_LOG_TAG, "verify failed", tostring(request.request_id), verify_message)
    fail_current_request("verify_failed", verify_message, -2)
    return false
end

-- ---------------------------------------------------------------------------
-- 请求启动
-- ---------------------------------------------------------------------------

local function log_start_request(request)
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
end

local function build_fota_options(request)
    local opts = {
        url = request.url
    }

    if request.timeout then
        opts.timeout = request.timeout
    end

    return opts
end

local function start_fota_request(request)
    publish_request_report("start", "ota start", nil)

    local started = libfota2.request(fota_cb, build_fota_options(request))
    if started == false then
        log.error(OTA_LOG_TAG, "request start failed", tostring(request.request_id))
        fail_current_request("failed", "fota request start failed", -1)
        return false
    end

    return true
end

local function handle_ota_request(request)
    if is_recent_duplicate(request) then
        report_duplicate_request(request)
        return
    end

    if ota_busy then
        report_busy_request(request)
        return
    end

    wait_for_ip_ready()

    begin_current_request(request)
    log_start_request(request)

    if not verify_request_if_needed(request) then
        return
    end

    start_fota_request(request)
end

-- ---------------------------------------------------------------------------
-- 启动阶段
-- ---------------------------------------------------------------------------

if ENABLE_VERSION_HEARTBEAT_LOG then
    sys.timerLoopStart(log_version, VERSION_LOG_INTERVAL_MS)
else
    log_version()
end

sys.timerLoopStart(function()
    if ota_busy then
        sys.publish(FEED_NETWORK_WATCHDOG_EVENT)
    end
end, OTA_WATCHDOG_FEED_MS)

sys.taskInit(function()
    wait_for_ip_ready()
    log.info(OTA_LOG_TAG, "IP ready")

    while true do
        local ok, request = sys.waitUntil(OTA_EXEC_EVENT)
        if ok and request then
            handle_ota_request(request)
        end
    end
end)
