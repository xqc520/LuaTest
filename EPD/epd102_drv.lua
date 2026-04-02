---@diagnostic disable: undefined-global

local drv = {}

drv.WIDTH = 128
drv.HEIGHT = 80
drv.BUFFER_SIZE = math.floor(drv.WIDTH * drv.HEIGHT / 8)

local DIN, CLK, CS, DC, RES, BUSY = 2, 38, 37, 36, 35, 34

local LUT_W1 = {
    0x60, 0x5A, 0x5A, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00
}

local LUT_B1 = {
    0x90, 0x5A, 0x5A, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00
}

local initialized = false
local sleeping = false

local function write_byte(data)
    for i = 7, 0, -1 do
        gpio.set(CLK, 0)
        gpio.set(DIN, bit.band(bit.lshift(1, i), data) ~= 0 and 1 or 0)
        gpio.set(CLK, 1)
    end
end

local function write_cmd(cmd)
    gpio.set(DC, 0)
    gpio.set(CS, 0)
    write_byte(cmd)
    gpio.set(CS, 1)
end

local function write_data(data)
    gpio.set(DC, 1)
    gpio.set(CS, 0)
    write_byte(data)
    gpio.set(CS, 1)
end

function drv.wait_idle()
    sys.wait(100)
    local retry = 0
    while retry < 1000 do
        write_cmd(0x71)
        if gpio.get(BUSY) == 0 then
            break
        end
        sys.wait(10)
        retry = retry + 1
    end
    sys.wait(800)
end

local function set_lut()
    write_cmd(0x23)
    for i = 1, #LUT_W1 do
        write_data(LUT_W1[i])
    end

    write_cmd(0x24)
    for i = 1, #LUT_B1 do
        write_data(LUT_B1[i])
    end
end

function drv.init()
    if initialized and not sleeping then
        return true
    end

    gpio.setup(DIN, 0)
    gpio.setup(CLK, 0)
    gpio.setup(CS, 1)
    gpio.setup(DC, 1)
    gpio.setup(RES, 1)
    gpio.setup(BUSY, nil, gpio.PULLUP)

    gpio.set(RES, 1)
    sys.wait(20)
    gpio.set(RES, 0)
    sys.wait(2)
    gpio.set(RES, 1)
    sys.wait(20)

    write_cmd(0xD2)
    write_data(0x3F)
    write_cmd(0x00)
    write_data(0x6F)
    write_cmd(0x01)
    write_data(0x03)
    write_data(0x00)
    write_data(0x2B)
    write_data(0x2B)
    write_cmd(0x06)
    write_data(0x3F)
    write_cmd(0x2A)
    write_data(0x00)
    write_data(0x00)
    write_cmd(0x30)
    write_data(0x17)
    write_cmd(0x50)
    write_data(0x57)
    write_cmd(0x60)
    write_data(0x22)
    write_cmd(0x61)
    write_data(0x50)
    write_data(0x80)
    write_cmd(0x82)
    write_data(0x12)
    write_cmd(0xE3)
    write_data(0x33)

    set_lut()

    write_cmd(0x04)
    drv.wait_idle()

    initialized = true
    sleeping = false
    return true
end

local function ensure_awake()
    if initialized and not sleeping then
        return true
    end

    return drv.init()
end

function drv.display(buffer)
    if type(buffer) ~= "string" or #buffer < drv.BUFFER_SIZE then
        log.warn("epd.drv", "invalid buffer", type(buffer), buffer and #buffer or 0)
        return false
    end

    if not ensure_awake() then
        return false
    end

    write_cmd(0x10)
    for i = 1, drv.BUFFER_SIZE do
        write_data(0xFF)
    end

    write_cmd(0x13)
    for i = 1, drv.BUFFER_SIZE do
        write_data(buffer:byte(i))
    end

    write_cmd(0x12)
    drv.wait_idle()
    return true
end

function drv.sleep()
    if not initialized or sleeping then
        return true
    end

    write_cmd(0x50)
    write_data(0xF7)
    write_cmd(0x02)
    drv.wait_idle()
    write_cmd(0x07)
    write_data(0xA5)
    gpio.set(RES, 0)

    sleeping = true
    return true
end

return drv
