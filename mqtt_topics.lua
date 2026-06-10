---@diagnostic disable: undefined-global

local M = {}

local SYS_PREFIX = "sys"
local DEFAULT_JSON_TYPE = "json"
local DEFAULT_SN = "NO_SN"
local OTA_TYPE = "ota"

-- 清洗 topic 片段：
-- 1. 去掉首尾空白
-- 2. 把 "/" 替换成 "_"，避免破坏 topic 层级
-- 3. 空值时回退到默认值
local function clean_topic_part(value, default)
    value = tostring(value or default or "")
    value = value:gsub("^%s+", ""):gsub("%s+$", "")
    value = value:gsub("[/]+", "_")
    if value == "" then
        return default or ""
    end

    return value
end

-- 读取当前设备 SN。
-- 如果 EPD_STATUS 还没准备好，或者 SN 为空，则回退到默认值。
function M.get_device_sn(default)
    local sn = default or DEFAULT_SN
    if EPD_STATUS and EPD_STATUS.get_sn then
        local value = EPD_STATUS.get_sn()
        if type(value) == "string" and value ~= "" then
            sn = value
        end
    end

    return clean_topic_part(sn, DEFAULT_SN)
end

-- 构造 sys/{sn}/{type}/{direction}/{func} 结构的标准 topic。
function M.build_sys_topic(sn, direction, func, data_type)
    return table.concat({
        SYS_PREFIX,
        clean_topic_part(sn, DEFAULT_SN),
        clean_topic_part(data_type, DEFAULT_JSON_TYPE),
        clean_topic_part(direction, "up"),
        clean_topic_part(func, "")
    }, "/")
end

-- 构造 sys/{sn}/ota/{direction}/{func} 结构的 OTA topic。
local function build_ota_topic(sn, direction, func)
    return table.concat({
        SYS_PREFIX,
        clean_topic_part(sn, DEFAULT_SN),
        OTA_TYPE,
        clean_topic_part(direction, "up"),
        clean_topic_part(func, "")
    }, "/")
end

function M.get_realtime_topic(sn)
    return M.build_sys_topic(sn, "up", "realTime", DEFAULT_JSON_TYPE)
end

function M.get_down_cmd_topic(sn)
    return M.build_sys_topic(sn, "down", "cmd", DEFAULT_JSON_TYPE)
end

function M.get_down_resp_topic(sn)
    return M.build_sys_topic(sn, "down", "resp", DEFAULT_JSON_TYPE)
end

function M.get_up_resp_topic(sn)
    return M.build_sys_topic(sn, "up", "resp", DEFAULT_JSON_TYPE)
end

function M.get_ota_update_topic(sn)
    return build_ota_topic(sn, "down", "update")
end

function M.get_ota_report_topic(sn)
    -- 这里保持现有协议拼写 "resport" 不变，避免影响兼容性。
    return build_ota_topic(sn, "up", "resport")
end

return M
