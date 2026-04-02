--[[------------------------------------------------
@module  json_codec
@summary JSON 解码/编码工具模块（工程化封装）
@version 1.0
@date    2025.10.29
@author
@usage
local json_codec = require("json_codec")

local obj, err = json_codec.decode(json_str)
if not obj then
    log.error("json", err)
end
--------------------------------------------------]]

---@diagnostic disable: undefined-global
local M = {}

--------------------------------------------------
-- 内部工具函数
--------------------------------------------------
local function _decode(json_str)
    if type(json_str) ~= "string" or json_str == "" then
        return nil, "json string invalid"
    end

    local obj, ok, err = json.decode(json_str)
    if ok == false then
        return nil, err or "json decode failed"
    end

    return obj
end

--------------------------------------------------
-- 对外接口
--------------------------------------------------

--- JSON 解码（安全）
-- @param json_str string
-- @return table|string|number|boolean|nil
-- @return err_msg string|nil
function M.decode(json_str)
    return _decode(json_str)
end


--- JSON 编码（简单封装）
-- @param lua_obj any
-- @param fmt string|nil  如 "3f"
-- @return string|nil
-- @return err_msg|string|nil
function M.encode(lua_obj, fmt)
    local json_str, err = json.encode(lua_obj, fmt)
    if not json_str then
        return nil, err
    end
    return json_str
end


--- 判断是否为 JSON null
-- @param v any
-- @return boolean
function M.is_null(v)
    return v == json.null
end


--- 判断字段是否“有效存在”
-- JSON null 和 nil 都视为无效
function M.is_valid(v)
    return v ~= nil and v ~= json.null
end


--- 获取字段值（带默认值）
-- @param tbl table
-- @param key string
-- @param default any
function M.get(tbl, key, default)
    if type(tbl) ~= "table" then
        return default
    end

    local v = tbl[key]
    if v == nil or v == json.null then
        return default
    end

    return v
end

return M
