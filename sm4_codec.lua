---@diagnostic disable: undefined-global

local flash_config = require("flash_config")

local M = {}

local SM4_MODE = "CBC"
local SM4_PADDING = "PKCS7"

local function trim_text(value)
    if type(value) ~= "string" then
        return ""
    end

    return value:gsub("^%s+", ""):gsub("%s+$", "")
end

local function from_hex(text)
    local value = trim_text(text)
    if #value ~= 32 or not value:match("^[0-9A-Fa-f]+$") then
        return nil
    end

    return (value:gsub("..", function(pair)
        return string.char(tonumber(pair, 16))
    end))
end

local function decode_material(value)
    local text = trim_text(value)
    if #text == 16 then
        return text, "text"
    end

    local raw = from_hex(text)
    if raw then
        return raw, "hex"
    end

    return nil
end

local function to_hex(data)
    if type(data) ~= "string" then
        return nil
    end

    if string and string.toHex then
        local ok, result = pcall(string.toHex, data)
        if ok and type(result) == "string" and result ~= "" then
            return result
        end
    end

    local ok, result = pcall(function()
        return data:toHex()
    end)
    if ok and type(result) == "string" and result ~= "" then
        return result
    end

    return nil
end

local function load_runtime_config()
    local saved = flash_config.getSm4 and flash_config.getSm4() or nil
    local key = saved and decode_material(saved.key) or nil
    local iv = saved and decode_material(saved.iv) or nil

    if not key or not iv then
        return nil, "SM4 key/iv not ready"
    end

    return {
        key = key,
        iv = iv
    }
end

local function ensure_gmssl()
    if not gmssl or type(gmssl.sm4encrypt) ~= "function" then
        return false, "current firmware has no gmssl.sm4encrypt"
    end

    return true
end

function M.validate_remote_config(key, iv)
    local remote_key, key_format = decode_material(key)
    if not remote_key then
        return false, "SM4 key must be 16 chars or 32 hex chars"
    end

    local remote_iv, iv_format = decode_material(iv)
    if not remote_iv then
        return false, "SM4 iv must be 16 chars or 32 hex chars"
    end

    return true, {
        mode = SM4_MODE,
        padding = SM4_PADDING,
        key_format = key_format,
        iv_format = iv_format
    }
end

function M.is_runtime_ready()
    local cfg = load_runtime_config()
    return cfg ~= nil
end

function M.encrypt_to_hex(payload)
    if type(payload) ~= "string" then
        return false, "payload must be a string"
    end

    local ok, err = ensure_gmssl()
    if not ok then
        return false, err
    end

    local cfg, cfg_err = load_runtime_config()
    if not cfg then
        return false, cfg_err
    end

    local cipher = gmssl.sm4encrypt(SM4_MODE, SM4_PADDING, payload, cfg.key, cfg.iv)
    if type(cipher) ~= "string" or cipher == "" then
        return false, "gmssl.sm4encrypt failed"
    end

    local hex = to_hex(cipher)
    if not hex then
        return false, "failed to convert SM4 ciphertext to hex"
    end

    return true, hex, {
        mode = SM4_MODE,
        padding = SM4_PADDING
    }
end

return M
