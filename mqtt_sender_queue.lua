---@diagnostic disable: undefined-global

local bounded_queue = require("bounded_queue")

local M = {}

local MAX_SEND_QUEUE_ITEMS = 128
local MAX_SEND_QUEUE_BYTES = 96 * 1024

local function item_size(item)
    return #(item.topic or "") + #(item.payload or "") + 32
end

function M.new(name)
    return bounded_queue.new({
        name = name or "mqtt_send_queue",
        max_items = MAX_SEND_QUEUE_ITEMS,
        max_bytes = MAX_SEND_QUEUE_BYTES
    })
end

function M.notify(item, result)
    if item and item.cb and item.cb.func then
        pcall(item.cb.func, result, item.cb.para)
    end
end

function M.enqueue(queue, item)
    local ok, reason, dropped = queue:push(item, item_size(item), function(old_item)
        M.notify(old_item, false)
    end)

    if not ok then
        M.notify(item, false)
    end

    return ok, reason, dropped
end

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

        M.notify(item, false)
    end
end

function M.clear(queue)
    queue:clear(function(item)
        M.notify(item, false)
    end, "clear")
end

return M
