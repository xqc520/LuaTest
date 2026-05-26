-- sd_writer.lua
---@diagnostic disable: undefined-global

local sd = require("sdcard")
local sd_guard = require("sd_guard")

local LOG_WRITE_SUCCESS = false
local ensured_dirs = {}

local function ensure_dir(path)
    if type(path) ~= "string" or not path:match("^/sd/") then
        log.error("sd_writer", "invalid sd path", path)
        return false
    end

    local dir = path:match("(.+)/[^/]+$")
    if not dir then
        return false
    end

    if ensured_dirs[dir] then
        return true
    end

    local cur = ""
    for name in dir:gmatch("[^/]+") do
        cur = cur .. "/" .. name
        if not ensured_dirs[cur] then
            if not io.dexist(cur) then
                io.mkdir(cur)
            end
            ensured_dirs[cur] = true
        end
    end

    ensured_dirs[dir] = true
    return true
end

sys.taskInit(function()
    if not sd.init() then
        log.error("sd_writer", "sd init failed on boot, writer will keep retrying")
    end

    while true do
        local ret, path, data = sys.waitUntil("SD_WRITE")
        if ret then
            if sd.init() then
                local ok, open_result = sd_guard.run(function(target_path, content)
                    if not ensure_dir(target_path) then
                        return false, "ensure_dir_failed"
                    end

                    local f = io.open(target_path, "a+")
                    if not f then
                        return false
                    end

                    f:write(content or "")
                    f:write("\n")
                    f:close()
                    return true
                end, 5000, path, data)

                if ok and open_result then
                    if LOG_WRITE_SUCCESS then
                        log.info("sd_writer", "write ok", path)
                    end
                elseif ok then
                    sd.mark_fault("sd_writer_open_failed")
                    log.error("sd_writer", "open failed", path, open_result or "")
                else
                    sd.mark_fault("sd_writer_busy")
                    log.error("sd_writer", "sd busy", path, open_result or "")
                end
            else
                sd.mark_fault("sd_writer_init_failed")
                log.error("sd_writer", "sd reinit failed", path)
                sys.wait(500)
            end
        end
    end
end)
