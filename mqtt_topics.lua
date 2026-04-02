---@diagnostic disable: undefined-global

local M = {}

local SYS_PREFIX = "sys"
local DATA_TYPE = "json"

local function clean_topic_part(value, default)
    value = tostring(value or default or "")
    value = value:gsub("^%s+", ""):gsub("%s+$", "")
    value = value:gsub("[/]+", "_")
    if value == "" then
        return default or ""
    end
    return value
end

function M.get_device_sn(default)
    local sn = default or "NO_SN"
    if EPD_STATUS and EPD_STATUS.get_sn then
        local value = EPD_STATUS.get_sn()
        if type(value) == "string" and value ~= "" then
            sn = value
        end
    end

    return clean_topic_part(sn, "NO_SN")
end

function M.build_sys_topic(sn, direction, func, data_type)
    return table.concat({
        SYS_PREFIX,
        clean_topic_part(sn, "NO_SN"),
        clean_topic_part(data_type, DATA_TYPE),
        clean_topic_part(direction, "up"),
        clean_topic_part(func, "")
    }, "/")
end

function M.get_realtime_topic(sn)
    return M.build_sys_topic(sn, "up", "realTime", DATA_TYPE)
end

function M.get_down_cmd_topic(sn)
    return M.build_sys_topic(sn, "down", "cmd", DATA_TYPE)
end

function M.get_down_resp_topic(sn)
    return M.build_sys_topic(sn, "down", "resp", DATA_TYPE)
end

function M.get_up_resp_topic(sn)
    return M.build_sys_topic(sn, "up", "resp", DATA_TYPE)
end

function M.get_ota_update_topic(sn)
    return table.concat({
        SYS_PREFIX,
        clean_topic_part(sn, "NO_SN"),
        "ota",
        "down",
        "update"
    }, "/")
end

function M.get_ota_report_topic(sn)
    return table.concat({
        SYS_PREFIX,
        clean_topic_part(sn, "NO_SN"),
        "ota",
        "up",
        "resport"
    }, "/")
end

return M
