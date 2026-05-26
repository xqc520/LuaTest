---@diagnostic disable: undefined-global

local json_codec = require("json_codec")
local mqtt_topics = require("mqtt_topics")
local error_logger = require("error_logger")
local sd = require("sdcard")
local sd_guard = require("sd_guard")
local uart_reliable_queue = require("uart_reliable_queue")
local gnss = require("gnss")

local M = {}

-- ---------------------------------------------------------------------------
-- Sampling / conversion configuration
-- ---------------------------------------------------------------------------

local BATTERY_ADC_ID = 0
local BATTERY_R_TOP_OHM = 170000
local BATTERY_R_BOTTOM_OHM = 10000
local BATTERY_DIVIDER_SCALE = (BATTERY_R_TOP_OHM + BATTERY_R_BOTTOM_OHM) / BATTERY_R_BOTTOM_OHM
local TEMP_ADC_ID = 1
local TEMP_PULLUP_OHM = 100000
local TEMP_VREF_MV = 3300
local TEMP_TABLE_START_C = -40
local TEMP_NTC_BOX_10K_TAB = {
    190556, 183413, 175674, 167647, 159565, 151598, 143862, 136436, 129364, 122668,
    116352, 110410, 104827, 99585, 94661, 90033, 85678, 81575, 77703, 74044,
    70581, 67299, 64183, 61223, 58408, 55728, 53177, 50746, 48429, 46222,
    44120, 42118, 40212, 38399, 36675, 35036, 33480, 32004, 30603, 29275,
    28017, 26826, 25697, 24629, 23618, 22660, 21752, 20892, 20075, 19299,
    18560, 18482, 18149, 17632, 16992, 16280, 15535, 14787, 14055, 13354,
    12690, 12068, 11490, 10954, 10458, 10000, 9576, 9184, 8819, 8478,
    8160, 7861, 7578, 7311, 7056, 6813, 6581, 6357, 6142, 5934,
    5734, 5540, 5353, 5172, 4998, 4829, 4665, 4507, 4355, 4208,
    4065, 3927, 3794, 3664, 3538, 3415, 3294, 3175, 3058, 2941,
    2825, 2776, 2718, 2652, 2582, 2508, 2432, 2356, 2280, 2206,
    2135, 2066, 2000, 1938, 1878, 1822, 1770, 1720, 1673, 1628,
    1586, 1546, 1508, 1471, 1435, 1401, 1367, 1334, 1301, 1268,
    1236, 1204, 1171, 1139, 1107, 1074, 1042, 1010, 979, 948,
    918, 889, 861, 835, 810, 787, 766, 748, 733, 721,
    713
}
local BATTERY_SAMPLE_COUNT = 10
local CACHE_TTL_MS = 5 * 1000
local STATUS_CMD = "get_device_status"
local SIM_INFO_CMD = "get_sim_info"
local MQTT_SERVER_COUNT = 2
local PERIODIC_STATUS_INTERVAL_MINUTES = 10
local PERIODIC_STATUS_INTERVAL_SECONDS = PERIODIC_STATUS_INTERVAL_MINUTES * 60
local VALID_TIME_MIN = 1700000000
local PERIODIC_STATUS_LOG_DIR = "/sd/log/status"
local STORAGE_CACHE_TTL_MS = 30 * 1000

-- Cached snapshots avoid repeated ADC / storage reads during field logs.
local cache = {
    updated_at = 0,
    snapshot = nil
}

local storage_cache = {
    updated_at = 0,
    snapshot = nil
}

-- ---------------------------------------------------------------------------
-- Generic helpers
-- ---------------------------------------------------------------------------

local function now_ms()
    if mcu and type(mcu.ticks) == "function" and type(mcu.hz) == "function" then
        local hz = tonumber(mcu.hz()) or 0
        if hz > 0 then
            return math.floor((tonumber(mcu.ticks()) or 0) * 1000 / hz)
        end
    end

    return (tonumber(os.time()) or 0) * 1000
end

local function round(value)
    local number = tonumber(value) or 0
    if number >= 0 then
        return math.floor(number + (1 / 2))
    end

    return math.ceil(number - (1 / 2))
end

local function round_to(value, digits)
    local number = tonumber(value)
    if not number then
        return nil
    end

    local factor = 10 ^ (tonumber(digits) or 0)
    if number >= 0 then
        return math.floor(number * factor + 1 / 2) / factor
    end

    return math.ceil(number * factor - 1 / 2) / factor
end

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

-- ---------------------------------------------------------------------------
-- Formatting helpers used by logs / HTTP / MQTT responses
-- ---------------------------------------------------------------------------

local function format_voltage(mv)
    local value = tonumber(mv)
    if not value or value < 0 then
        return "-"
    end

    return string.format("%.2fV", value / 1000)
end

local function format_temperature(temp_c)
    local value = tonumber(temp_c)
    if not value then
        return "-"
    end

    return string.format("%.2fC", value)
end

local function format_bytes(bytes)
    local value = tonumber(bytes)
    if not value or value < 0 then
        return "-"
    end

    if value >= 1024 * 1024 * 1024 then
        return string.format("%.2fGB", value / 1024 / 1024 / 1024)
    end

    if value >= 1024 * 1024 then
        return string.format("%.1fMB", value / 1024 / 1024)
    end

    if value >= 1024 then
        return string.format("%.1fKB", value / 1024)
    end

    return string.format("%dB", round(value))
end

local function build_periodic_status_log_path(timestamp)
    local t = os.date("*t", tonumber(timestamp) or os.time())
    if type(t) ~= "table" then
        return nil
    end

    return string.format(
        "%s/%04d%02d%02d/%d.log",
        PERIODIC_STATUS_LOG_DIR,
        t.year,
        t.month,
        t.day,
        t.hour
    )
end

-- ---------------------------------------------------------------------------
-- Device identity helpers
-- ---------------------------------------------------------------------------

local function read_mobile_text(method_name, default)
    if not mobile or type(mobile[method_name]) ~= "function" then
        return default or ""
    end

    local ok, value = pcall(mobile[method_name])
    if not ok or value == nil then
        return default or ""
    end

    if type(value) == "string" then
        return get_text(value, default or "")
    end

    if type(value) == "number" then
        return tostring(value)
    end

    return default or ""
end

local function read_mobile_number(method_name)
    if not mobile or type(mobile[method_name]) ~= "function" then
        return nil
    end

    local ok, value = pcall(mobile[method_name])
    if not ok then
        return nil
    end

    if type(value) == "number" then
        return value
    end

    local number = tonumber(value)
    if number then
        return number
    end

    return nil
end

-- ---------------------------------------------------------------------------
-- ADC and sensor helpers
-- ---------------------------------------------------------------------------

local function average_trimmed_samples(samples)
    if type(samples) ~= "table" or #samples == 0 then
        return nil
    end

    table.sort(samples)

    local start_index = 1
    local end_index = #samples
    if #samples > 2 then
        start_index = 2
        end_index = #samples - 1
    end

    local sum = 0
    local count = 0
    for i = start_index, end_index do
        local value = tonumber(samples[i])
        if value and value >= 0 then
            sum = sum + value
            count = count + 1
        end
    end

    if count == 0 then
        return nil
    end

    return round(sum / count)
end

local function lookup_temperature_from_ntc_ohm(ntc_ohm)
    local resistance_ohm = tonumber(ntc_ohm) or 0
    if resistance_ohm <= 0 then
        return nil
    end

    local table_size = #TEMP_NTC_BOX_10K_TAB
    if table_size == 0 then
        return nil
    end

    if resistance_ohm >= TEMP_NTC_BOX_10K_TAB[1] then
        return TEMP_TABLE_START_C
    end

    if resistance_ohm <= TEMP_NTC_BOX_10K_TAB[table_size] then
        return TEMP_TABLE_START_C + table_size - 1
    end

    for i = 1, table_size - 1 do
        local high_res = TEMP_NTC_BOX_10K_TAB[i]
        local low_res = TEMP_NTC_BOX_10K_TAB[i + 1]
        if resistance_ohm <= high_res and resistance_ohm >= low_res then
            local span = high_res - low_res
            local base_temp = TEMP_TABLE_START_C + i - 1
            if span <= 0 then
                return base_temp
            end

            return base_temp + (high_res - resistance_ohm) / span
        end
    end

    return nil
end

local function read_battery_info()
    if not adc or type(adc.open) ~= "function" or type(adc.get) ~= "function" then
        return {
            ok = false,
            reason = "adc_unavailable",
            adc_mv = nil,
            battery_mv = nil,
            voltage = "-"
        }
    end

    if type(adc.setRange) == "function" and adc.ADC_RANGE_MIN ~= nil then
        pcall(adc.setRange, adc.ADC_RANGE_MIN)
    end

    if not adc.open(BATTERY_ADC_ID) then
        return {
            ok = false,
            reason = "adc_open_failed",
            adc_mv = nil,
            battery_mv = nil,
            voltage = "-"
        }
    end

    local samples = {}
    for _ = 1, BATTERY_SAMPLE_COUNT do
        local value = adc.get(BATTERY_ADC_ID)
        if type(value) == "number" and value >= 0 then
            samples[#samples + 1] = value
        end
    end

    if type(adc.close) == "function" then
        pcall(adc.close, BATTERY_ADC_ID)
    end

    local adc_mv = average_trimmed_samples(samples)
    if not adc_mv then
        return {
            ok = false,
            reason = "adc_read_failed",
            adc_mv = nil,
            battery_mv = nil,
            voltage = "-"
        }
    end

    local battery_mv = round(adc_mv * BATTERY_DIVIDER_SCALE)
    return {
        ok = true,
        reason = "ok",
        adc_mv = adc_mv,
        battery_mv = battery_mv,
        voltage = format_voltage(battery_mv),
        sample_count = #samples
    }
end

local function read_temperature_info()
    if not adc or type(adc.open) ~= "function" or type(adc.get) ~= "function" then
        return {
            ok = false,
            reason = "adc_unavailable",
            adc_mv = nil,
            ntc_ohm = nil,
            temp_c = nil,
            temperature = "-"
        }
    end

    if type(adc.setRange) == "function" and adc.ADC_RANGE_MAX ~= nil then
        pcall(adc.setRange, adc.ADC_RANGE_MAX)
    end

    if not adc.open(TEMP_ADC_ID) then
        return {
            ok = false,
            reason = "adc_open_failed",
            adc_mv = nil,
            ntc_ohm = nil,
            temp_c = nil,
            temperature = "-"
        }
    end

    local samples = {}
    for _ = 1, BATTERY_SAMPLE_COUNT do
        local value = adc.get(TEMP_ADC_ID)
        if type(value) == "number" and value >= 0 then
            samples[#samples + 1] = value
        end
    end

    if type(adc.close) == "function" then
        pcall(adc.close, TEMP_ADC_ID)
    end

    local adc_mv = average_trimmed_samples(samples)
    if not adc_mv or adc_mv <= 0 or adc_mv >= TEMP_VREF_MV then
        return {
            ok = false,
            reason = "temp_adc_read_failed",
            adc_mv = adc_mv,
            ntc_ohm = nil,
            temp_c = nil,
            temperature = "-"
        }
    end

    local ntc_ohm = TEMP_PULLUP_OHM * adc_mv / (TEMP_VREF_MV - adc_mv)
    if not ntc_ohm or ntc_ohm <= 0 then
        return {
            ok = false,
            reason = "temp_ntc_calc_failed",
            adc_mv = adc_mv,
            ntc_ohm = nil,
            temp_c = nil,
            temperature = "-"
        }
    end

    local temp_c = lookup_temperature_from_ntc_ohm(ntc_ohm)
    if not temp_c then
        return {
            ok = false,
            reason = "temp_lookup_failed",
            adc_mv = adc_mv,
            ntc_ohm = round(ntc_ohm),
            temp_c = nil,
            temperature = "-"
        }
    end

    return {
        ok = true,
        reason = "ok",
        adc_mv = adc_mv,
        ntc_ohm = round(ntc_ohm),
        temp_c = temp_c,
        temperature = format_temperature(temp_c),
        sample_count = #samples
    }
end

local function read_sd_info_uncached()
    if not sd.init() then
        return {
            ok = false,
            reason = "sd_not_ready",
            mounted = false,
            total_bytes = nil,
            used_bytes = nil,
            free_bytes = nil,
            total = "-",
            used = "-",
            free = "-",
            fs_type = ""
        }
    end

    if fs and type(fs.fsstat) == "function" then
        local ok_guard, ok_call, ok_stat, total_blocks, used_blocks, block_size, fs_type = sd_guard.run(function()
            return pcall(fs.fsstat, "/sd")
        end, 5000)
        if ok_guard and ok_call and ok_stat then
            local total_bytes = (tonumber(total_blocks) or 0) * (tonumber(block_size) or 0)
            local used_bytes = (tonumber(used_blocks) or 0) * (tonumber(block_size) or 0)
            local free_bytes = total_bytes - used_bytes
            if free_bytes < 0 then
                free_bytes = 0
            end

            return {
                ok = true,
                reason = "ok",
                mounted = true,
                total_bytes = total_bytes,
                used_bytes = used_bytes,
                free_bytes = free_bytes,
                total = format_bytes(total_bytes),
                used = format_bytes(used_bytes),
                free = format_bytes(free_bytes),
                fs_type = get_text(fs_type, "")
            }
        end
        if not ok_guard then
            log.warn("metrics", "sd fsstat busy", ok_call or "")
        end
    end

    if fatfs and type(fatfs.getfree) == "function" then
        for _, mount_point in ipairs({ "/sd", "sd", "SD" }) do
            local ok_guard, ok_call, info = sd_guard.run(function(target_mount)
                return pcall(fatfs.getfree, target_mount)
            end, 5000, mount_point)
            if ok_guard and ok_call and type(info) == "table" then
                local total_bytes = (tonumber(info.total_kb) or 0) * 1024
                local free_bytes = (tonumber(info.free_kb) or 0) * 1024
                local used_bytes = total_bytes - free_bytes
                if used_bytes < 0 then
                    used_bytes = 0
                end

                return {
                    ok = true,
                    reason = "ok",
                    mounted = true,
                    total_bytes = total_bytes,
                    used_bytes = used_bytes,
                    free_bytes = free_bytes,
                    total = format_bytes(total_bytes),
                    used = format_bytes(used_bytes),
                    free = format_bytes(free_bytes),
                    fs_type = "fatfs"
                }
            end
            if not ok_guard then
                log.warn("metrics", "sd getfree busy", mount_point)
                break
            end
        end
    end

    return {
        ok = false,
        reason = "sd_stat_failed",
        mounted = true,
        total_bytes = nil,
        used_bytes = nil,
        free_bytes = nil,
        total = "-",
        used = "-",
        free = "-",
        fs_type = ""
    }
end

local function read_sd_info(force_refresh)
    local now = now_ms()
    if not force_refresh and storage_cache.snapshot and (now - storage_cache.updated_at) < STORAGE_CACHE_TTL_MS then
        return storage_cache.snapshot
    end

    local snapshot = read_sd_info_uncached()
    storage_cache.updated_at = now
    storage_cache.snapshot = snapshot
    return snapshot
end

local function read_sim_info()
    local imei = read_mobile_text("imei", "")
    local imsi = read_mobile_text("imsi", "")
    local iccid = read_mobile_text("iccid", "")
    local simid = read_mobile_number("simid")
    local status = read_mobile_number("status")
    local ok = iccid ~= ""

    return {
        ok = ok,
        reason = ok and "ok" or "iccid_unavailable",
        imei = imei,
        imsi = imsi,
        iccid = iccid,
        simid = simid,
        status = status
    }
end

local function read_gnss_info()
    if type(gnss) ~= "table" or type(gnss.get_location) ~= "function" then
        return {
            ok = false,
            reason = "gnss_unavailable",
            latitude = nil,
            longitude = nil
        }
    end

    local ok, location = pcall(gnss.get_location)
    if not ok then
        return {
            ok = false,
            reason = "gnss_read_failed",
            latitude = nil,
            longitude = nil
        }
    end

    local lat = tonumber(location and location.latitude)
    local lng = tonumber(location and location.longitude)
    if not lat or not lng then
        return {
            ok = false,
            reason = "gnss_invalid",
            latitude = nil,
            longitude = nil
        }
    end

    return {
        ok = true,
        reason = "ok",
        latitude = round_to(lat, 6),
        longitude = round_to(lng, 6)
    }
end

local function collect_snapshot(force_refresh)
    local battery = read_battery_info()
    local temperature = read_temperature_info()
    local storage = read_sd_info(force_refresh)
    local sim = read_sim_info()
    local gnss = read_gnss_info()
    return {
        sn = get_device_sn(),
        time = os.time(),
        battery = battery,
        temperature = temperature,
        storage = storage,
        sim = sim,
        gnss = gnss
    }
end

function M.get_snapshot(force_refresh)
    local now = now_ms()
    if not force_refresh and cache.snapshot and (now - cache.updated_at) < CACHE_TTL_MS then
        return cache.snapshot
    end

    local ok, snapshot = pcall(collect_snapshot, force_refresh)
    if not ok or type(snapshot) ~= "table" then
        error_logger.error("metrics", "collect snapshot failed", snapshot or "")
        if cache.snapshot then
            return cache.snapshot
        end

        return {
            sn = get_device_sn(),
            time = os.time(),
            battery = {
                ok = false,
                reason = "collect_failed",
                voltage = "-"
            },
            temperature = {
                ok = false,
                reason = "collect_failed",
                temperature = "-"
            },
            storage = {
                ok = false,
                reason = "collect_failed",
                mounted = false,
                total = "-",
                used = "-",
                free = "-"
            },
            sim = {
                ok = false,
                reason = "collect_failed",
                imei = read_mobile_text("imei", ""),
                imsi = read_mobile_text("imsi", ""),
                iccid = read_mobile_text("iccid", ""),
                simid = read_mobile_number("simid"),
                status = read_mobile_number("status")
            },
            gnss = {
                ok = false,
                reason = "collect_failed",
                latitude = nil,
                longitude = nil
            }
        }
    end

    cache.updated_at = now
    cache.snapshot = snapshot
    return snapshot
end

function M.get_log_text(force_refresh)
    local snapshot = M.get_snapshot(force_refresh)
    local battery = snapshot.battery or {}
    local temperature = snapshot.temperature or {}
    local storage = snapshot.storage or {}

    local battery_text = "bat=" .. get_text(battery.voltage, "-")
    local temperature_text = "temp=" .. get_text(temperature.temperature, "-")
    local sd_text
    if storage.mounted then
        sd_text = string.format("sd=%s/%s", get_text(storage.free, "-"), get_text(storage.total, "-"))
    else
        sd_text = "sd=OFF"
    end

    return battery_text .. " " .. temperature_text .. " " .. sd_text
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

    log.info(
        "metrics.tx",
        "cmd=" .. tostring(body.cmd or ""),
        "request_id=" .. tostring(body.request_id or ""),
        "result=" .. tostring(body.result or ""),
        "reason=" .. tostring(body.reason or ""),
        "topic=" .. mqtt_topics.get_up_resp_topic(get_device_sn())
    )
    sys.publish("mqtt" .. target .. "_send_data_req", "device_metrics", mqtt_topics.get_up_resp_topic(get_device_sn()), payload, 1)
    return true
end

local function publish_status(server_id, request_id, result, reason, snapshot)
    local battery = snapshot and snapshot.battery or {}
    local temperature = snapshot and snapshot.temperature or {}
    local storage = snapshot and snapshot.storage or {}
    local sim = snapshot and snapshot.sim or {}

    publish_to_server(server_id, {
        cmd = STATUS_CMD,
        request_id = request_id,
        result = result,
        reason = reason,
        sn = get_device_sn(),
        time = os.time(),
        battery_adc_mv = battery.adc_mv,
        battery_mv = battery.battery_mv,
        battery_voltage = battery.voltage,
        temp_adc_mv = temperature.adc_mv,
        temp_ntc_ohm = temperature.ntc_ohm,
        temp_c = temperature.temp_c,
        temperature = temperature.temperature,
        imei = sim.imei,
        imsi = sim.imsi,
        iccid = sim.iccid,
        simid = sim.simid,
        mobile_status = sim.status,
        sd_mounted = storage.mounted == true,
        sd_total_bytes = storage.total_bytes,
        sd_used_bytes = storage.used_bytes,
        sd_free_bytes = storage.free_bytes,
        sd_total = storage.total,
        sd_used = storage.used,
        sd_free = storage.free,
        sd_fs_type = storage.fs_type
    })
end

local function publish_sim_info(server_id, request_id, snapshot)
    local sim = snapshot and snapshot.sim or {}
    local result = sim.ok and 0 or -1
    local reason = get_text(sim.reason, sim.ok and "ok" or "iccid_unavailable")

    publish_to_server(server_id, {
        cmd = SIM_INFO_CMD,
        request_id = request_id,
        result = result,
        reason = reason,
        sn = get_device_sn(),
        time = os.time(),
        imei = sim.imei,
        imsi = sim.imsi,
        iccid = sim.iccid,
        simid = sim.simid,
        mobile_status = sim.status
    })
end

local function to_json_number_or_null(value, digits)
    local number = round_to(value, digits)
    if number == nil then
        return json and json.null or nil
    end
    return number
end

local function to_json_integer_or_null(value, divisor)
    local number = tonumber(value)
    divisor = tonumber(divisor) or 1
    if not number or divisor <= 0 then
        return json and json.null or nil
    end

    return round(number / divisor)
end

-- ---------------------------------------------------------------------------
-- Periodic device status reporting (every 10 minutes)
-- ---------------------------------------------------------------------------

function M.build_periodic_status_payload(snapshot, timestamp)
    snapshot = snapshot or M.get_snapshot(true)
    local battery = snapshot.battery or {}
    local temperature = snapshot.temperature or {}
    local storage = snapshot.storage or {}
    local gnss = snapshot.gnss or {}
    local unix_ts = tonumber(timestamp) or tonumber(snapshot.time) or tonumber(os.time()) or 0
    local battery_mv = tonumber(battery.battery_mv)

    return {
        SN = get_device_sn(),
        timeStamp = tostring(unix_ts),
        sendFrequency = PERIODIC_STATUS_INTERVAL_MINUTES,
        tcase = to_json_number_or_null(temperature.temp_c, 1),
        batteryVoltage = to_json_number_or_null(battery_mv and (battery_mv / 1000) or nil, 1),
        cardMemory = to_json_integer_or_null(storage.total_bytes, 1024 * 1024),
        latitude = to_json_number_or_null(gnss.latitude, 6),
        longitude = to_json_number_or_null(gnss.longitude, 6)
    }
end

function M.enqueue_periodic_status(server_id, timestamp)
    local snapshot = M.get_snapshot(true)
    local payload = M.build_periodic_status_payload(snapshot, timestamp)
    local payload_json = json_codec.encode(payload)
    if not payload_json then
        return false, payload, "json encode failed"
    end

    local log_path = build_periodic_status_log_path(timestamp)
    if log_path then
        sys.publish("SD_WRITE", log_path, payload_json)
    end

    local ok, msg_or_err = uart_reliable_queue.enqueue_payload(payload_json, {
        server_id = server_id,
        qos = 1,
        source = "device_metrics",
        topic = mqtt_topics.get_realtime_topic(get_device_sn())
    })
    if not ok then
        return false, payload, msg_or_err
    end

    return true, payload, msg_or_err
end

function M.start_periodic_realtime_reporter(server_id)
    local target = tonumber(server_id) or 1
    local task_name = "device_metrics_periodic_status"

    sys.taskInitEx(function()
        local last_boundary = 0

        while true do
            local now = tonumber(os.time()) or 0
            if now < VALID_TIME_MIN then
                sys.wait(1000)
            else
                local next_boundary = math.floor(now / PERIODIC_STATUS_INTERVAL_SECONDS) * PERIODIC_STATUS_INTERVAL_SECONDS + PERIODIC_STATUS_INTERVAL_SECONDS
                local wait_ms = (next_boundary - now) * 1000
                if wait_ms < 200 then
                    wait_ms = 200
                end

                sys.wait(wait_ms)

                local current_ts = tonumber(os.time()) or 0
                if current_ts >= VALID_TIME_MIN then
                    local boundary = math.floor(current_ts / PERIODIC_STATUS_INTERVAL_SECONDS) * PERIODIC_STATUS_INTERVAL_SECONDS
                    if boundary > 0 and boundary ~= last_boundary then
                        last_boundary = boundary
                        local ok, payload, msg_or_err = M.enqueue_periodic_status(target, boundary)
                        if ok then
                            log.info("metrics", "periodic realtime report queued", json_codec.encode(payload))
                        else
                            error_logger.error("metrics", "periodic realtime report enqueue failed", msg_or_err or "")
                        end
                    end
                end
            end
        end
    end, task_name)
end

-- ---------------------------------------------------------------------------
-- MQTT command entry
-- ---------------------------------------------------------------------------

function M.handle_command(server_id, obj)
    if type(obj) ~= "table" then
        return false
    end

    local cmd = get_text(obj.cmd, "")
    log.info("metrics.rx", "cmd=" .. tostring(cmd), "request_id=" .. tostring(obj.request_id or ""))

    if cmd == SIM_INFO_CMD then
        local request_id = get_text(obj.request_id, "sim-" .. tostring(os.time()))
        local snapshot = M.get_snapshot(true)
        publish_sim_info(server_id, request_id, snapshot)
        return true
    end

    if cmd ~= STATUS_CMD then
        return false
    end

    local request_id = get_text(obj.request_id, "status-" .. tostring(os.time()))
    local snapshot = M.get_snapshot(true)

    local result = 0
    local reason = "ok"
    if
        not (snapshot.battery and snapshot.battery.ok)
        and not (snapshot.temperature and snapshot.temperature.ok)
        and not (snapshot.storage and snapshot.storage.ok)
    then
        result = -1
        reason = "collect_failed"
    elseif
        not (snapshot.battery and snapshot.battery.ok)
        or not (snapshot.temperature and snapshot.temperature.ok)
        or not (snapshot.storage and snapshot.storage.ok)
    then
        reason = "partial"
    end

    publish_status(server_id, request_id, result, reason, snapshot)
    return true
end

return M
