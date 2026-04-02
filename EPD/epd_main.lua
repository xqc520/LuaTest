---@diagnostic disable: undefined-global

local epd = require("epd_app")
local drv = require("epd102_drv")

local REFRESH_DEBOUNCE_MS = 2000
local REFRESH_COOLDOWN_MS = 6000
local IDLE_WAIT_MS = 1000
local FULL_CLEAR_EVERY = 6
local CLEAR_SETTLE_MS = 600

local pending_text
local last_displayed_text
local refresh_count = 0

local function normalize_text(msg)
    if msg == nil then
        return nil
    end

    local text = type(msg) == "string" and msg or tostring(msg)
    text = text:gsub("\r\n", "\n"):gsub("\r", "\n"):gsub("\n+$", "")
    if text == "" then
        return nil
    end

    return text
end

local function recv_data_from_epd_proc(msg)
    local text = normalize_text(msg)
    if not text then
        return
    end

    if text == pending_text or text == last_displayed_text then
        return
    end

    pending_text = text
    sys.publish("EPD_DIRTY")
end

sys.taskInit(function()
    drv.init()
    epd.clear()
    sys.wait(CLEAR_SETTLE_MS)

    while true do
        if not pending_text then
            sys.waitUntil("EPD_DIRTY", IDLE_WAIT_MS)
        end

        if pending_text then
            sys.wait(REFRESH_DEBOUNCE_MS)

            local text = pending_text
            pending_text = nil

            if text and text ~= last_displayed_text then
                if refresh_count > 0 and (refresh_count % FULL_CLEAR_EVERY) == 0 then
                    epd.clear()
                    sys.wait(CLEAR_SETTLE_MS)
                end

                local ok = epd.updateDisplay(text)
                if ok then
                    last_displayed_text = text
                    refresh_count = refresh_count + 1
                else
                    log.warn("epd", "update failed")
                end

                sys.wait(REFRESH_COOLDOWN_MS)
            end
        end
    end
end)

sys.subscribe("EPD_MSG", recv_data_from_epd_proc)
