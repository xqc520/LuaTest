---@diagnostic disable: undefined-global

local M = {}

local NETWORK_LED_PIN = 146
local LED_ON_LEVEL = 1
local LED_OFF_LEVEL = 0

local initialized = false
local subscribed = false
local network_active = false

local function apply_level(pin, active)
    gpio.set(pin, active and LED_ON_LEVEL or LED_OFF_LEVEL)
end

local function ensure_init()
    if initialized then
        return true
    end

    if not gpio or type(gpio.setup) ~= "function" or type(gpio.set) ~= "function" then
        return false
    end

    gpio.setup(NETWORK_LED_PIN, LED_OFF_LEVEL, gpio.PULLUP)
    apply_level(NETWORK_LED_PIN, false)
    initialized = true
    return true
end

local function set_led_state(tag, pin, active)
    if not ensure_init() then
        return false
    end

    apply_level(pin, active == true)
    log.info("status_leds", tag, active == true and "on" or "off")
    return true
end

function M.set_network(active)
    network_active = active == true
    return set_led_state("network", NETWORK_LED_PIN, network_active)
end

function M.set_gnss(active)
    return active == true
end

function M.init()
    if not ensure_init() then
        return false
    end

    M.set_network(network_active)

    if subscribed then
        return true
    end

    if sys and type(sys.subscribe) == "function" then
        sys.subscribe("IP_READY", function()
            M.set_network(true)
        end)

        sys.subscribe("IP_LOSE", function()
            M.set_network(false)
        end)

        subscribed = true
    end

    return true
end

return M
