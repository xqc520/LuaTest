---@diagnostic disable: undefined-global

PROJECT = "MQTT"
VERSION = "001.000.002"

-- Boot-time behaviour switches. Keep them集中在文件顶部，方便现场排查时统一看。
local ENABLE_PERIODIC_STATUS_LOG = true
local STATUS_LOG_INTERVAL_MS = 60000
local WAIT_4G_LOG_INTERVAL_SEC = 10
local ENABLE_NETWORK_WATCHDOG = false
local NETWORK_START_DELAY_MS = 15000
local ENABLE_FIELD_DEBUG_LOG = true
local FIELD_DEBUG_INTERVAL_MS = 5000
local PRIMARY_MQTT_SERVER_ID = 1









-- Basic hardware defaults that should be ready before the rest of the project starts.
gpio.setup(141, 1, gpio.PULLUP)
log.info("main", "project", PROJECT, "version", VERSION)

if wdt then
    wdt.init(9000)
    sys.timerLoopStart(wdt.feed, 3000)
end

require("epd_main")
local status_leds = require("status_leds")
local sensor_power = require("sensor_power")
flash_config = require("flash_config")
require("epd_status")
EPD_STATUS.init()
status_leds.init()
sensor_power.init(true)
local mqtt_topics = require("mqtt_topics")

local boot_cfg = flash_config.get()
local enabled_servers = flash_config.getEnabledServers(boot_cfg)
local boot_should_start_network = flash_config.is_config_complete(boot_cfg)
local boot_should_start_ap = flash_config.should_start_ap_config(boot_cfg)
local device_sn = EPD_STATUS.get_sn()

if boot_should_start_ap then
    log.warn("boot", "config incomplete, start AP config mode and close after 5 minutes")
    if not boot_should_start_network then
        EPD_STATUS.set_mode("CFG AP ON")
    else
        EPD_STATUS.set_mode("AP 5MIN")
    end
else
    log.info("boot", "config complete, AP config mode will close after 5 minutes")
    EPD_STATUS.set_mode("AP 5MIN")
end

require("ap_config_net")

require("sd_writer")
local error_logger = require("error_logger")
local uart485 = require("485uart")
--require("uart10_dg")
require("uart11_232")
require("uart12_485")
local device_metrics = require("device_metrics")

local server_status = { "offline", "offline" }

-- ---------------------------------------------------------------------------
-- Runtime status helpers
-- ---------------------------------------------------------------------------

local function get_now_string()
    local now = os.time()
    if type(now) ~= "number" or now <= 0 then
        return "NO_TIME"
    end

    local ok, text = pcall(os.date, "%Y-%m-%d %H:%M:%S", now)
    if ok and type(text) == "string" and text ~= "" then
        return text
    end

    return tostring(now)
end

local function get_current_mode()
    if EPD_STATUS and type(EPD_STATUS.mode_text) == "string" and EPD_STATUS.mode_text ~= "" then
        return EPD_STATUS.mode_text
    end

    return "UNKNOWN"
end

local function get_current_ip()
    if not socket or not socket.localIP or not socket.LWIP_GP then
        return "-"
    end

    local ok, ip = pcall(socket.localIP, socket.LWIP_GP)
    if not ok or type(ip) ~= "string" or ip == "" or ip == "0.0.0.0" then
        return "-"
    end

    return ip
end

local function get_server_status_text()
    return string.format(
        "S1=%s S2=%s",
        server_status[1] or "-",
        server_status[2] or "-"
    )
end

local function preview_payload(payload, max_len)
    if type(payload) ~= "string" then
        return tostring(payload)
    end

    local text = payload:gsub("[\r\n]+", " ")
    local limit = tonumber(max_len) or 240
    if #text <= limit then
        return text
    end

    return text:sub(1, limit) .. "..."
end

-- Field log is the single summary line used during outdoor maintenance.
local function start_field_debug_log()
    if not ENABLE_FIELD_DEBUG_LOG then
        return
    end

    sys.taskInit(function()
        while true do
            log.info(
                "field",
                get_now_string(),
                "mode=" .. get_current_mode(),
                "ip=" .. get_current_ip(),
                device_metrics.get_log_text(),
                get_server_status_text()
            )
            sys.wait(FIELD_DEBUG_INTERVAL_MS)
        end
    end)
end

-- ---------------------------------------------------------------------------
-- EPD status helpers
-- ---------------------------------------------------------------------------

local function update_epd_mode()
    if not boot_should_start_network then
        EPD_STATUS.set_mode("CFG AP ON")
        return
    end

    if #enabled_servers == 0 then
        EPD_STATUS.set_mode("NO MQTT")
        return
    end

    local any_online = false
    local any_connecting = false
    for _, srv in ipairs(enabled_servers) do
        local status = server_status[srv.id]
        if status == "online" then
            any_online = true
        elseif status == "connecting" then
            any_connecting = true
        end
    end

    if any_online then
        EPD_STATUS.set_mode("RUN")
    elseif any_connecting then
        EPD_STATUS.set_mode("MQTT WAIT")
    else
        EPD_STATUS.set_mode("4G WAIT")
    end
end

local function refresh_all_servers()
    EPD_STATUS.set_all_server_status(server_status)
    update_epd_mode()
end

local function mark_enabled_servers_connecting(list)
    local changed = false
    for _, srv in ipairs(list) do
        if server_status[srv.id] ~= "connecting" then
            server_status[srv.id] = "connecting"
            changed = true
        end
    end

    if changed then
        refresh_all_servers()
    else
        update_epd_mode()
    end
end

local function make_mqtt_status_handler(index)
    return function(status)
        server_status[index] = status and "online" or "offline"
        refresh_all_servers()
    end
end

-- ---------------------------------------------------------------------------
-- Network and MQTT boot helpers
-- ---------------------------------------------------------------------------

local function apply_apn_config(cfg)
    local apn_cfg = cfg and cfg.apn or {}
    if apn_cfg.mode == "manual" then
        log.info("net", "manual apn", apn_cfg.apn or "")
        if mobile and mobile.apn then
            mobile.apn(0, 1, apn_cfg.apn or "", apn_cfg.user or "", apn_cfg.pass or "", nil, 3)
            log.info("net", "manual apn applied")
        end
        return
    end

    log.info("net", "auto apn")
    if mobile and mobile.apn then
        mobile.apn(0, 1, "", "", "", nil, 0)
    end
end

-- Wait until the 4G default adapter has a usable IP.
local function wait_for_4g_ready()
    local last_wait_log_at = 0

    sys.wait(1000)

    if socket.adapter and socket.LWIP_GP then
        socket.adapter(socket.LWIP_GP)
        log.info("net", "default adapter locked", "LWIP_GP")
    end

    log.info("sys", "waiting for 4G network")
    while true do
        local ip = socket.localIP(socket.LWIP_GP)
        if ip and #ip >= 7 and ip ~= "0.0.0.0" then
            log.info("sys", "4G ready", ip)
            return ip
        end

        if socket.adapter and socket.LWIP_GP then
            socket.adapter(socket.LWIP_GP)
        end

        local now = os.time()
        if now - last_wait_log_at >= WAIT_4G_LOG_INTERVAL_SEC then
            last_wait_log_at = now
            log.warn("sys", "waiting for 4G ip")
        end
        sys.wait(2000)
    end
end

local function start_enabled_mqtt_channels(list)
    for _, srv in ipairs(list) do
        local id = srv.id
        log.info("sys", "enable mqtt channel", id)

        if id == 1 then
            require("mqtts1_main")
        elseif id == 2 then
            require("mqtts2_main")
        end
    end
end

local function is_down_cmd_topic(topic)
    return topic == mqtt_topics.get_down_cmd_topic(device_sn)
end

start_field_debug_log()

if boot_should_start_network then
    local json_codec = require("json_codec")
    local rtc_app = require("rtc_app")
    local gnss = require("gnss")

    if ENABLE_NETWORK_WATCHDOG then
        require("network_watchdog")
    else
        log.warn("boot", "network watchdog disabled for field stability")
    end
    require("fota")

    local ota_manager = require("ota_manager")
    local sm4_command = require("sm4_command")
    local uart_reliable_queue = require("uart_reliable_queue")

    sys.subscribe("MQTT1_CONN_EVENT", make_mqtt_status_handler(1))
    sys.subscribe("MQTT2_CONN_EVENT", make_mqtt_status_handler(2))
    gnss.start()
    device_metrics.start_periodic_realtime_reporter(PRIMARY_MQTT_SERVER_ID)

    if ENABLE_PERIODIC_STATUS_LOG and #enabled_servers > 0 then
        sys.taskInit(function()
            while true do
                sys.wait(STATUS_LOG_INTERVAL_MS)
                log.info("main", "server status", table.concat(server_status, ", "))
            end
        end)
    end

    -- Only MQTT1 is allowed to process control traffic.
    local function dispatch_primary_server_command(server_id, topic, obj)
        if rtc_app.handle_command(server_id, topic, obj) then
            return true
        end

        if not is_down_cmd_topic(topic) then
            return true
        end

        if sm4_command.handle_command(server_id, obj) then
            return true
        end

        if sensor_power.handle_command(server_id, obj) then
            return true
        end

        if uart485 and uart485.handle_command and uart485.handle_command(server_id, obj) then
            return true
        end

        if device_metrics.handle_command(server_id, obj) then
            return true
        end

        if uart_reliable_queue.handle_command(server_id, obj) then
            return true
        end

        if error_logger.handle_command(server_id, obj) then
            return true
        end

        return false
    end

    local function handle_server_message(server_id, topic, payload)
        if server_id ~= PRIMARY_MQTT_SERVER_ID then
            return
        end

        log.info("mqtt.rx", "server=" .. tostring(server_id), "topic=" .. tostring(topic), preview_payload(payload, 240))

        if ota_manager.handle_message(server_id, topic, payload) then
            return
        end

        if not is_down_cmd_topic(topic) and not rtc_app.is_time_sync_topic(topic) then
            return
        end

        local obj, err = json_codec.decode(payload or "")
        if not obj then
            error_logger.error("mqtt", err)
            return
        end

        local cmd = json_codec.get(obj, "cmd", "")
        log.info("mqtt.rx", "cmd=" .. tostring(cmd), "request_id=" .. tostring(obj.request_id or ""))

        if not dispatch_primary_server_command(server_id, topic, obj) then
            log.warn("mqtt.rx", "unhandled", "topic=" .. tostring(topic), "cmd=" .. tostring(cmd))
        end
    end

    sys.subscribe("RECV_DATA_FROM_MQTTS1_SERVER", function(prefix, topic, payload)
        handle_server_message(1, topic, payload)
    end)

    log.info("device", "sn", EPD_STATUS.get_sn())

    -- Delay 4G startup a little so AP configuration mode is stable first.
    sys.taskInit(function()
        log.info("boot", "delay network start for AP stability", NETWORK_START_DELAY_MS, "ms")
        sys.wait(NETWORK_START_DELAY_MS)
        EPD_STATUS.set_mode("4G WAIT")
        require("netdrv_4g")
        apply_apn_config(boot_cfg)
        wait_for_4g_ready()
        mark_enabled_servers_connecting(enabled_servers)
        start_enabled_mqtt_channels(enabled_servers)
    end)
else
    log.warn("boot", "skip 4G/MQTT/network watchdog until config is complete")
end


sys.run()
