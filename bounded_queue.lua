---@diagnostic disable: undefined-global

local M = {}

function M.new(opts)
    opts = opts or {}

    local q = {
        name = opts.name or "queue",
        max_items = opts.max_items or 64,
        max_bytes = opts.max_bytes or 64 * 1024,
        head = 1,
        tail = 1,
        count = 0,
        bytes = 0,
        data = {}
    }

    function q:length()
        return self.count
    end

    function q:used_bytes()
        return self.bytes
    end

    function q:is_empty()
        return self.count == 0
    end

    function q:pop()
        if self.count == 0 then
            return nil
        end

        local node = self.data[self.head]
        self.data[self.head] = nil
        self.head = self.head + 1
        self.count = self.count - 1
        self.bytes = self.bytes - (node.size or 0)

        if self.count == 0 then
            self.head = 1
            self.tail = 1
        end

        return node.item, node.size
    end

    function q:push(item, size, on_drop)
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
            if on_drop then
                pcall(on_drop, old_item, "overflow")
            end
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

    function q:clear(on_drop, reason)
        reason = reason or "clear"
        while true do
            local item = self:pop()
            if item == nil then
                break
            end

            if on_drop then
                pcall(on_drop, item, reason)
            end
        end
    end

    return q
end

return M
