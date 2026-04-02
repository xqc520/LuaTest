---@diagnostic disable: undefined-global

local mqtts_receiver = require("mqtts1_receiver")
local mqtts_sender = require("mqtts1_sender")
local ota_manager = require("ota_manager")
local error_logger = require("error_logger")
local mqtt_topics = require("mqtt_topics")
local mqtt_tls = require("mqtt_tls")

-- MQTT1 is the primary control channel in this project.
-- Time sync, OTA, SM4 command flow and downlink commands all use this server.
local cfg = flash_config.get()
local srv = cfg.servers[1] or {}
local DEVICE_SN = EPD_STATUS and EPD_STATUS.get_sn and EPD_STATUS.get_sn() or "NO_SN"

local CHANNEL_ID = 1
local SERVER_ADDR = srv.host or "183.6.36.233"
local SERVER_PORT = srv.port or 8883
local USERNAME = srv.user or "admin"
local PASSWORD = srv.pass or "123456"
local TASK_NAME = mqtts_sender.TASK_NAME_PREFIX .. "main"
local SUBSCRIBE_TOPICS = ota_manager.get_subscribe_topics()
SUBSCRIBE_TOPICS[mqtt_topics.get_down_cmd_topic(DEVICE_SN)] = 2
SUBSCRIBE_TOPICS[mqtt_topics.get_down_resp_topic(DEVICE_SN)] = 2

-- MQTT callback -> convert raw client events into task messages
local function mqtts_client_event_cbfunc(mqtt_client, event, data, payload, metas)
    log.info("mqtt1.event", event, data, payload, json.encode(metas))

    if event == "conack" then
        sys.sendMsg(TASK_NAME, "MQTT_EVENT", "CONNECT", true)
        if not mqtt_client:subscribe(SUBSCRIBE_TOPICS) then
            sys.sendMsg(TASK_NAME, "MQTT_EVENT", "SUBSCRIBE", false, -1)
        end
    elseif event == "suback" then
        sys.sendMsg(TASK_NAME, "MQTT_EVENT", "SUBSCRIBE", data, payload)
    elseif event == "unsuback" then
        sys.sendMsg(TASK_NAME, "MQTT_EVENT", "UNSUBSCRIBE", true)
    elseif event == "recv" then
        mqtts_receiver.proc(data, payload, metas)
    elseif event == "sent" then
        sys.sendMsg(mqtts_sender.TASK_NAME, "MQTT_EVENT", "PUBLISH_OK", data)
    elseif event == "disconnect" then
        sys.sendMsg(TASK_NAME, "MQTT_EVENT", "DISCONNECTED", false)
    elseif event == "pong" then
        sys.publish("FEED_NETWORK_WATCHDOG")
    elseif event == "error" then
        if data == "connect" or data == "conack" then
            sys.sendMsg(TASK_NAME, "MQTT_EVENT", "CONNECT", false)
        elseif data == "other" or data == "tx" then
            sys.sendMsg(TASK_NAME, "MQTT_EVENT", "ERROR")
        end
    end
end

-- Wait until the default network adapter is ready
local function wait_for_ip_ready()
    while not socket.adapter(socket.dft()) do
        log.warn("mqtt1.main", "wait IP_READY", socket.dft())
        sys.waitUntil("IP_READY", 1000)
    end
end

-- Create one TLS MQTT client using the current saved config
local function create_client()
    if not mqtt_tls.is_time_valid() then
        error_logger.error("mqtt1.main", "rtc invalid, mqtt tls ca verify requires valid time")
        return nil
    end

    local tls_options, cert_path_or_err = mqtt_tls.get_client_options()
    if not tls_options then
        error_logger.error("mqtt1.main", cert_path_or_err or "rootCA.crt load failed")
        return nil
    end

    log.info("mqtt1.main", "tls target", SERVER_ADDR, SERVER_PORT)
    log.info("mqtt1.main", mqtt_tls.build_verify_hint(SERVER_ADDR, SERVER_PORT))

    local mqtt_client = mqtt.create(nil, SERVER_ADDR, SERVER_PORT, tls_options)
    if not mqtt_client then
        error_logger.error("mqtt1.main", "mqtt.create error")
        return nil
    end

    local client_id = tostring(mobile.imei() or "unknown") .. "mqtts" .. CHANNEL_ID
    if not mqtt_client:auth(client_id, USERNAME, PASSWORD, false) then
        error_logger.error("mqtt1.main", "mqtt_client:auth error")
        mqtt_client:close()
        return nil
    end

    mqtt_client:on(mqtts_client_event_cbfunc)
    if not mqtt_client:connect() then
        error_logger.error("mqtt1.main", "mqtt connect failed, check tls broker cert chain/name/port")
        mqtt_client:close()
        return nil
    end

    log.info("mqtt1.main", "tls ca cert", cert_path_or_err)

    return mqtt_client
end

-- Simple connect/reconnect loop
local function mqtts_client_main_task_func()
    while true do
        wait_for_ip_ready()
        log.info("mqtt1.main", "IP ready", socket.dft())
        sys.cleanMsg(TASK_NAME)

        local mqtt_client = create_client()
        if mqtt_client then
            while true do
                local msg = sys.waitMsg(TASK_NAME, "MQTT_EVENT")
                log.info("mqtt1.main", "waitMsg", msg[2], msg[3], msg[4])

                if msg[2] == "CONNECT" then
                    if msg[3] then
                        sys.sendMsg(mqtts_sender.TASK_NAME, "MQTT_EVENT", "CONNECT_OK", mqtt_client)
                    else
                        log.warn("mqtt1.main", "connect failed", SERVER_ADDR, SERVER_PORT)
                        log.warn("mqtt1.main", mqtt_tls.build_verify_hint(SERVER_ADDR, SERVER_PORT))
                        break
                    end
                elseif msg[2] == "SUBSCRIBE" then
                    if not msg[3] then
                        mqtt_client:disconnect()
                        sys.wait(1000)
                        break
                    end
                elseif msg[2] == "CLOSE" then
                    mqtt_client:disconnect()
                    sys.wait(1000)
                    break
                elseif msg[2] == "DISCONNECTED" or msg[2] == "ERROR" then
                    break
                end
            end

            mqtt_client:close()
            mqtt_client = nil
        end

        sys.cleanMsg(TASK_NAME)
        sys.sendMsg(mqtts_sender.TASK_NAME, "MQTT_EVENT", "DISCONNECTED")
        sys.wait(5000)
    end
end

sys.taskInitEx(mqtts_client_main_task_func, TASK_NAME)
