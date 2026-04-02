---@diagnostic disable: undefined-global

local json_codec = require("json_codec")
local mqtt_topics = require("mqtt_topics")
local sd = require("sdcard")
local sd_guard = require("sd_guard")

local M = {}

local DAILY_LOG_DIR = "/sd/error/daily"
local LATEST_LOG_PATH = "/sd/error/latest.log"
local DEFAULT_LIMIT = 10
local MAX_LIMIT = 30
local MAX_REPORT_ENTRIES = 4
local MAX_MESSAGE_LEN = 240
local RECENT_CACHE_SIZE = 40
local READ_WINDOW_BYTES = 16 * 1024
local MQTT_SERVER_COUNT = 2

local installed = false
local recent_entries = {}

local function get_text(value, default)
    if type(value) == "string" and value ~= "" then
        return value
    end

    return default
end

local function clamp_limit(value)
    local limit = math.floor(tonumber(value) or DEFAULT_LIMIT)
    if limit < 1 then
        limit = 1
    elseif limit > MAX_LIMIT then
        limit = MAX_LIMIT
    end

    return limit
end

local function get_device_info()
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

local function get_report_topic()
    return mqtt_topics.get_up_resp_topic(get_device_info().sn)
end

local function truncate_text(text, max_len)
    if type(text) ~= "string" then
        text = tostring(text)
    end

    if #text <= max_len then
        return text
    end

    return text:sub(1, max_len) .. "..."
end

local function stringify_value(value)
    local value_type = type(value)
    if value_type == "string" then
        return value
    end

    if value_type == "number" or value_type == "boolean" or value == nil then
        return tostring(value)
    end

    if value_type == "table" then
        local encoded = json_codec.encode(value)
        if encoded then
            return encoded
        end
    end

    return tostring(value)
end

local function join_args(start_index, ...)
    local parts = {}
    for i = start_index, select("#", ...) do
        parts[#parts + 1] = stringify_value(select(i, ...))
    end

    return truncate_text(table.concat(parts, " "), MAX_MESSAGE_LEN)
end

local function build_entry(...)
    local arg_count = select("#", ...)
    local ts = os.time()
    local tag = "error"
    local message = ""

    if arg_count <= 0 then
        message = "unknown error"
    elseif arg_count == 1 then
        message = join_args(1, ...)
    else
        tag = truncate_text(stringify_value(select(1, ...)), 48)
        message = join_args(2, ...)
    end

    if message == "" then
        message = "unknown error"
    end

    return {
        ts = ts,
        time = os.date("%Y-%m-%d %H:%M:%S", ts),
        tag = tag,
        message = message
    }
end

local function get_daily_log_path(ts)
    local t = os.date("*t", ts or os.time())
    return string.format("%s/%04d%02d%02d.log", DAILY_LOG_DIR, t.year, t.month, t.day)
end

local function cache_entry(entry)
    recent_entries[#recent_entries + 1] = entry
    if #recent_entries > RECENT_CACHE_SIZE then
        table.remove(recent_entries, 1)
    end
end

local function persist_entry(entry)
    local line = json_codec.encode(entry)
    if not line then
        return
    end

    sys.publish("SD_WRITE", get_daily_log_path(entry.ts), line)
    sys.publish("SD_WRITE", LATEST_LOG_PATH, line)
end

local function parse_log_line(line)
    local obj = json_codec.decode(line)
    if type(obj) == "table" then
        obj.tag = get_text(obj.tag, "error")
        obj.message = get_text(obj.message, "")
        obj.time = get_text(obj.time, "")
        obj.ts = tonumber(obj.ts) or 0
        return obj
    end

    return {
        ts = 0,
        time = "",
        tag = "error",
        message = truncate_text(line, MAX_MESSAGE_LEN)
    }
end

local function read_tail_text(path)
    if not sd.init() then
        log.error("error_log", "sd init failed before read", path)
        return nil
    end

    local ok_guard, content = sd_guard.run(function(target_path)
        local file = io.open(target_path, "rb")
        if not file then
            return nil
        end

        local ok, file_size = pcall(function()
            return file:seek("end", 0)
        end)

        local text
        if ok and type(file_size) == "number" then
            local start_pos = 0
            if file_size > READ_WINDOW_BYTES then
                start_pos = file_size - READ_WINDOW_BYTES
            end

            pcall(function()
                file:seek("set", start_pos)
            end)
            text = file:read("*a") or ""
            if start_pos > 0 then
                text = text:gsub("^[^\n]*\n", "", 1)
                text = text:gsub("^\r", "", 1)
            end
        else
            text = file:read("*a") or ""
        end

        file:close()
        return text
    end, 5000, path)

    if not ok_guard then
        log.error("error_log", "read tail busy", path, content or "")
        return nil
    end

    return content
end

local function tail_entries(entries, limit)
    if #entries <= limit then
        return entries
    end

    local result = {}
    local start_index = #entries - limit + 1
    for i = start_index, #entries do
        result[#result + 1] = entries[i]
    end
    return result
end

local function load_entries_from_sd(limit)
    local content = read_tail_text(LATEST_LOG_PATH)
    if not content or content == "" then
        return nil
    end

    local entries = {}
    for line in content:gmatch("[^\r\n]+") do
        entries[#entries + 1] = parse_log_line(line)
    end

    if #entries == 0 then
        return nil
    end

    return tail_entries(entries, limit)
end

local function load_recent_entries(limit)
    local entries = load_entries_from_sd(limit)
    if entries and #entries > 0 then
        return entries
    end

    local cached = {}
    local start_index = #recent_entries - limit + 1
    if start_index < 1 then
        start_index = 1
    end

    for i = start_index, #recent_entries do
        cached[#cached + 1] = recent_entries[i]
    end

    return cached
end

local function publish_to_server(server_id, topic, payload, qos)
    local target = tonumber(server_id)
    if not target or target < 1 or target > MQTT_SERVER_COUNT then
        return false
    end

    sys.publish("mqtt" .. target .. "_send_data_req", "error_log", topic, payload, qos or 1)
    return true
end

local function publish_body(server_id, body)
    local payload = json_codec.encode(body)
    if not payload then
        return false
    end

    return publish_to_server(server_id, get_report_topic(), payload, 1)
end

local function publish_entries(server_id, request_id, entries)
    local device_info = get_device_info()

    if #entries == 0 then
        publish_body(server_id, {
            request_id = request_id,
            cmd = "get_error_log",
            result = 0,
            reason = "empty",
            status = "empty",
            sn = device_info.sn,
            imei = device_info.imei,
            project = device_info.project,
            version = device_info.version,
            firmware = device_info.firmware,
            core_version = device_info.core_version,
            log_path = LATEST_LOG_PATH,
            time = os.time(),
            entries = {}
        })
        return
    end

    local total_parts = math.ceil(#entries / MAX_REPORT_ENTRIES)
    local total_entries = #entries
    local part_index = 1

    for i = 1, #entries, MAX_REPORT_ENTRIES do
        local chunk = {}
        local chunk_end = i + MAX_REPORT_ENTRIES - 1
        if chunk_end > #entries then
            chunk_end = #entries
        end

        for j = i, chunk_end do
            chunk[#chunk + 1] = entries[j]
        end

        publish_body(server_id, {
            request_id = request_id,
            cmd = "get_error_log",
            result = 0,
            reason = "ok",
            status = "ok",
            sn = device_info.sn,
            imei = device_info.imei,
            project = device_info.project,
            version = device_info.version,
            firmware = device_info.firmware,
            core_version = device_info.core_version,
            log_path = LATEST_LOG_PATH,
            total_entries = total_entries,
            part = part_index,
            total_parts = total_parts,
            time = os.time(),
            entries = chunk
        })

        part_index = part_index + 1
    end
end

local function record_entry(entry)
    cache_entry(entry)
    persist_entry(entry)
end

function M.install()
    installed = true
end

function M.error(...)
    if log and type(log.error) == "function" then
        log.error(...)
    end

    local ok, entry = pcall(build_entry, ...)
    if ok and type(entry) == "table" then
        pcall(record_entry, entry)
    end
end

function M.handle_command(server_id, obj)
    if type(obj) ~= "table" then
        return false
    end

    local cmd = get_text(obj.cmd, "")
    if cmd ~= "get_error_log" then
        return false
    end

    local request_id = get_text(obj.request_id, "errlog-" .. tostring(os.time()))
    local limit = clamp_limit(obj.limit)
    local entries = load_recent_entries(limit)

    publish_entries(server_id, request_id, entries)
    return true
end

function M.get_latest_log_path()
    return LATEST_LOG_PATH
end

M.install()

return M
