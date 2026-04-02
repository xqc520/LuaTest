---@diagnostic disable: undefined-global

local WATCHDOG_TIMEOUT_MS = 300000
local REBOOT_DELAY_MS = 3000
local error_logger = require("error_logger")

local function network_watchdog_task()
    while true do
        if not sys.waitUntil("FEED_NETWORK_WATCHDOG", WATCHDOG_TIMEOUT_MS) then
            error_logger.error("network_watchdog", "feed timeout, reboot in", REBOOT_DELAY_MS, "ms")
            sys.wait(REBOOT_DELAY_MS)
            rtos.reboot()
        end
    end
end

sys.taskInit(network_watchdog_task)
