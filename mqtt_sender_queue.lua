---@diagnostic disable: undefined-global

local bounded_queue = require("bounded_queue")

local M = {}

local DEFAULT_QUEUE_NAME = "mqtt_send_queue"
local MAX_SEND_QUEUE_ITEMS = 128
local MAX_SEND_QUEUE_BYTES = 96 * 1024

-- 估算一条 MQTT 发送项占用的队列字节数。
-- 这里不是精确序列化大小，只是用于队列容量控制的近似值。
local function item_size(item)
    return #(item.topic or "") + #(item.payload or "") + 32
end

-- 通知回调调用方本条消息的发送结果。
-- 回调异常不影响发送队列主逻辑。
function M.notify(item, result)
    if item and item.cb and item.cb.func then
        pcall(item.cb.func, result, item.cb.para)
    end
end

-- 统一处理“本条消息发送失败”的通知逻辑。
local function notify_failed(item)
    M.notify(item, false)
end

-- 创建 MQTT 发送队列实例。
function M.new(name)
    return bounded_queue.new({
        name = name or DEFAULT_QUEUE_NAME,
        max_items = MAX_SEND_QUEUE_ITEMS,
        max_bytes = MAX_SEND_QUEUE_BYTES
    })
end

-- 放入一条待发送消息。
-- 如果队列因为超限而淘汰旧消息，会同步通知旧消息失败。
-- 如果当前消息自己入队失败，也会通知当前消息失败。
function M.enqueue(queue, item)
    local ok, reason, dropped = queue:push(item, item_size(item), function(old_item)
        notify_failed(old_item)
    end)

    if not ok then
        notify_failed(item)
    end

    return ok, reason, dropped
end

-- 从队列中取出下一条可发送消息，并尝试立刻发布。
-- 行为保持原样：
-- 1. 队列空时返回 nil
-- 2. 发布成功时返回该消息项
-- 3. 发布失败时通知失败，并继续尝试队列中的下一条
function M.publish_next(queue, mqtt_client)
    while true do
        local item = queue:pop()
        if not item then
            return nil
        end

        local result = mqtt_client:publish(item.topic, item.payload, item.qos)
        if result then
            return item
        end

        notify_failed(item)
    end
end

-- 清空整个发送队列，并把剩余消息全部按失败通知出去。
function M.clear(queue)
    queue:clear(function(item)
        notify_failed(item)
    end, "clear")
end

return M
