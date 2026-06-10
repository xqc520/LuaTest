-- sd_writer.lua
---@diagnostic disable: undefined-global

local sd = require("sdcard")
local sd_guard = require("sd_guard")

-- 是否打印每次写入成功日志。
-- 默认关闭，避免高频写卡时日志过多。
local LOG_WRITE_SUCCESS = false

-- 目录创建成功后记到缓存，后续同目录写入不再重复检查。
local ensured_dirs = {}

local SD_WRITE_EVENT = "SD_WRITE"
local SD_GUARD_TIMEOUT_MS = 5000
local INIT_RETRY_WAIT_MS = 500

-- 确保目标文件所在目录存在。
-- 这里只接受 /sd/ 开头的路径，避免误写到其他位置。
local function ensure_dir(file_path)
    if type(file_path) ~= "string" or not file_path:match("^/sd/") then
        log.error("sd_writer", "invalid sd path", file_path)
        return false
    end

    local dir = file_path:match("(.+)/[^/]+$")
    if not dir then
        return false
    end

    if ensured_dirs[dir] then
        return true
    end

    local current_dir = ""
    for name in dir:gmatch("[^/]+") do
        current_dir = current_dir .. "/" .. name
        if not ensured_dirs[current_dir] then
            if not io.dexist(current_dir) then
                io.mkdir(current_dir)
            end
            ensured_dirs[current_dir] = true
        end
    end

    ensured_dirs[dir] = true
    return true
end

-- 追加一行内容到 SD 文件末尾。
-- 保持原行为：
-- 1. 内容为空时写入空字符串
-- 2. 每次额外补一个换行
local function append_line(file_path, content)
    if not ensure_dir(file_path) then
        return false, "ensure_dir_failed"
    end

    local file = io.open(file_path, "a+")
    if not file then
        return false
    end

    file:write(content or "")
    file:write("\n")
    file:close()
    return true
end

-- 单次处理一个写卡请求。
-- 返回值约定保持和原逻辑一致，方便主循环只关心结果分类：
-- 1. true, "write_ok"       : 写入成功
-- 2. false, "open_failed"   : 抢到锁了，但打开/写入失败
-- 3. false, "sd_busy"       : SD 锁忙或写函数异常
-- 4. false, "init_failed"   : SD 初始化失败
local function handle_sd_write(path, data)
    if not sd.init() then
        sd.mark_fault("sd_writer_init_failed")
        log.error("sd_writer", "sd reinit failed", path)
        return false, "init_failed"
    end

    local guard_ok, write_result = sd_guard.run(append_line, SD_GUARD_TIMEOUT_MS, path, data)
    if guard_ok and write_result then
        if LOG_WRITE_SUCCESS then
            log.info("sd_writer", "write ok", path)
        end
        return true, "write_ok"
    end

    if guard_ok then
        sd.mark_fault("sd_writer_open_failed")
        log.error("sd_writer", "open failed", path, write_result or "")
        return false, "open_failed"
    end

    sd.mark_fault("sd_writer_busy")
    log.error("sd_writer", "sd busy", path, write_result or "")
    return false, "sd_busy"
end

-- 后台写卡任务：
-- 1. 启动时先尝试初始化 SD
-- 2. 持续监听 SD_WRITE 事件
-- 3. 每次收到事件后串行处理写入
sys.taskInit(function()
    if not sd.init() then
        log.error("sd_writer", "sd init failed on boot, writer will keep retrying")
    end

    while true do
        local ok, path, data = sys.waitUntil(SD_WRITE_EVENT)
        if ok then
            local write_ok, reason = handle_sd_write(path, data)
            if not write_ok and reason == "init_failed" then
                sys.wait(INIT_RETRY_WAIT_MS)
            end
        end
    end
end)
