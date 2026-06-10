---@diagnostic disable: undefined-global

local M = {}

local Queue = {}
Queue.__index = Queue

local DEFAULT_MAX_ITEMS = 64
local DEFAULT_MAX_BYTES = 64 * 1024

-- 当队列被取空后，把头尾索引重置回 1。
-- 这样可以避免索引一直增长，也保持原有行为不变。
local function reset_if_empty(queue)
    if queue.count == 0 then
        queue.head = 1
        queue.tail = 1
    end
end

-- 安全调用丢弃回调。
-- 回调异常不影响队列主逻辑。
local function notify_drop(on_drop, item, reason)
    if on_drop then
        pcall(on_drop, item, reason)
    end
end

function Queue:length()
    return self.count
end

function Queue:used_bytes()
    return self.bytes
end

function Queue:is_empty()
    return self.count == 0
end

-- 从队头取出一个元素。
-- 返回值保持原约定：
-- 1. 空队列时返回 nil
-- 2. 非空时返回 item, size
function Queue:pop()
    if self.count == 0 then
        return nil
    end

    local node = self.data[self.head]
    self.data[self.head] = nil
    self.head = self.head + 1
    self.count = self.count - 1
    self.bytes = self.bytes - (node.size or 0)

    reset_if_empty(self)
    return node.item, node.size
end

-- 向队尾压入一个元素。
-- 如果超过元素数或字节数限制，会先丢弃最旧元素再写入新元素。
-- 返回值保持原约定：
-- 1. true, nil, dropped_count
-- 2. false, "nil_item", 0
-- 3. false, "item_too_large", 0
function Queue:push(item, size, on_drop)
    if item == nil then
        return false, "nil_item", 0
    end

    size = math.max(0, tonumber(size) or 0)
    if size > self.max_bytes then
        return false, "item_too_large", 0
    end

    local dropped = 0
    while self.count >= self.max_items or (self.bytes + size) > self.max_bytes do
        local old_item = self:pop()
        if old_item == nil then
            break
        end

        dropped = dropped + 1
        notify_drop(on_drop, old_item, "overflow")
    end

    self.data[self.tail] = {
        item = item,
        size = size
    }
    self.tail = self.tail + 1
    self.count = self.count + 1
    self.bytes = self.bytes + size

    return true, nil, dropped
end

-- 清空整个队列。
-- 会逐个弹出元素，并对每个元素调用 on_drop。
function Queue:clear(on_drop, reason)
    reason = reason or "clear"

    while true do
        local item = self:pop()
        if item == nil then
            break
        end

        notify_drop(on_drop, item, reason)
    end
end

-- 创建一个带容量限制的队列实例。
-- 限制维度有两个：
-- 1. max_items : 最多元素个数
-- 2. max_bytes : 最多累计字节数
function M.new(opts)
    opts = opts or {}

    return setmetatable({
        name = opts.name or "queue",
        max_items = opts.max_items or DEFAULT_MAX_ITEMS,
        max_bytes = opts.max_bytes or DEFAULT_MAX_BYTES,
        head = 1,
        tail = 1,
        count = 0,
        bytes = 0,
        data = {}
    }, Queue)
end

return M
