---@diagnostic disable: undefined-global

local mqtt_sender_queue = require("mqtt_sender_queue")

local mqtts_sender = {}
local send_queue = mqtt_sender_queue.new("mqtts_1_send_queue")
local MAX_PUBLISH_RETRIES = 2

mqtts_sender.TASK_NAME_PREFIX = "mqtts_1"
mqtts_sender.TASK_NAME = mqtts_sender.TASK_NAME_PREFIX .. "sender"

local function send_data_req_proc_func(tag, topic, payload, qos, cb)
    local ok, reason, dropped = mqtt_sender_queue.enqueue(send_queue, {
        topic = topic,
        payload = payload,
        qos = qos or 0,
        cb = cb
    })

    if dropped and dropped > 0 then
        log.warn("mqtts1_sender", "queue overflow, dropped", dropped, "remain", send_queue:length(), "bytes", send_queue:used_bytes())
    end

    if not ok then
        log.warn("mqtts1_sender", "drop payload", reason, topic, payload and #payload or 0)
        return
    end

    sys.sendMsg(mqtts_sender.TASK_NAME, "MQTT_EVENT", "PUBLISH_REQ")
end

local function publish_item_cbfunc(item, result)
    if item then
        item.retry_count = 0
        item.last_mid = nil
    end
    mqtt_sender_queue.notify(item, result)
end

local function log_publish_result(channel_tag, item, result, mid)
    if not item then
        return
    end

    local topic = tostring(item.topic or "")
    local qos = tonumber(item.qos) or 0
    local bytes = item.payload and #item.payload or 0
    mid = mid or item.last_mid
    if result then
        log.info(channel_tag, "publish ok", "mid=" .. tostring(mid or ""), "qos=" .. tostring(qos), "bytes=" .. tostring(bytes), topic)
    else
        log.warn(channel_tag, "publish failed", "mid=" .. tostring(mid or ""), "qos=" .. tostring(qos), "bytes=" .. tostring(bytes), topic)
    end
end

local function consume_retry(item)
    local retry_count = tonumber(item and item.retry_count) or 0
    if retry_count >= MAX_PUBLISH_RETRIES then
        return false, retry_count
    end

    retry_count = retry_count + 1
    item.retry_count = retry_count
    return true, retry_count
end

local function log_retry(channel_tag, item, retry_count, reason)
    if not item then
        return
    end

    local topic = tostring(item.topic or "")
    local qos = tonumber(item.qos) or 0
    local bytes = item.payload and #item.payload or 0
    log.warn(
        channel_tag,
        "publish retry",
        "retry=" .. tostring(retry_count),
        "reason=" .. tostring(reason or ""),
        "qos=" .. tostring(qos),
        "bytes=" .. tostring(bytes),
        topic
    )
end

local function try_publish_item(mqtt_client, item)
    while item do
        item.last_mid = nil
        local mid = mqtt_client:publish(item.topic, item.payload, item.qos)
        if mid then
            item.last_mid = mid
            return item
        end

        local can_retry, retry_count = consume_retry(item)
        if not can_retry then
            log_publish_result("mqtt1.tx", item, false, nil)
            publish_item_cbfunc(item, false)
            return nil
        end

        log_retry("mqtt1.tx", item, retry_count, "publish_return_false")
    end

    return nil
end

local function publish_next_item(mqtt_client, retry_item)
    if retry_item then
        local sent_item = try_publish_item(mqtt_client, retry_item)
        if sent_item then
            return sent_item
        end
    end

    while true do
        local item = send_queue:pop()
        if not item then
            return nil
        end

        local sent_item = try_publish_item(mqtt_client, item)
        if sent_item then
            return sent_item
        end
    end
end

local function mqtts_client_sender_task_func()
    local mqtt_client
    local send_item
    local retry_item

    while true do
        local msg = sys.waitMsg(mqtts_sender.TASK_NAME, "MQTT_EVENT")

        if msg[2] == "CONNECT_OK" then
            mqtt_client = msg[3]
            send_item = publish_next_item(mqtt_client, retry_item)
            retry_item = nil
            sys.publish("MQTT1_CONN_EVENT", true)
        elseif msg[2] == "PUBLISH_REQ" then
            if mqtt_client and not send_item then
                send_item = publish_next_item(mqtt_client, retry_item)
                retry_item = nil
            end
        elseif msg[2] == "PUBLISH_OK" then
            log_publish_result("mqtt1.tx", send_item, true, msg[3])
            publish_item_cbfunc(send_item, true)
            sys.publish("FEED_NETWORK_WATCHDOG")
            send_item = publish_next_item(mqtt_client, retry_item)
            retry_item = nil
        elseif msg[2] == "DISCONNECTED" then
            mqtt_client = nil
            if send_item then
                local can_retry, retry_count = consume_retry(send_item)
                if can_retry then
                    log_retry("mqtt1.tx", send_item, retry_count, "disconnect_before_sent")
                    retry_item = send_item
                else
                    log_publish_result("mqtt1.tx", send_item, false, nil)
                    publish_item_cbfunc(send_item, false)
                end
            end
            mqtt_sender_queue.clear(send_queue)
            send_item = nil
            sys.publish("MQTT1_CONN_EVENT", false)
        end
    end
end

sys.subscribe("mqtt1_send_data_req", send_data_req_proc_func)
sys.taskInitEx(mqtts_client_sender_task_func, mqtts_sender.TASK_NAME)

return mqtts_sender
