local bit = require("bit")
local cpu = require("6502")
local sid = require("lovesid")

local header = {}

local status = ""
local sid_data, is_pal, is_ntsc, is_loaded, play_speed
local play_timer = 0
local clock_timer = 0

local ww, wh = love.graphics.getDimensions()

local function cleanString(str)
    if not str then return "Unknown" end
    local cleaned = str:gsub("[\128-\255]", "?"):gsub("[%c]", " ")
    return cleaned:match("^%s*(.-)%s*$")
end

local function read16be(data, offset)
    return bit.bor(bit.lshift(data:byte(offset), 8), data:byte(offset + 1))
end

local function read32be(data, offset)
    return bit.bor(bit.lshift(data:byte(offset), 24), bit.lshift(data:byte(offset + 1), 16),
        bit.lshift(data:byte(offset + 2), 8), data:byte(offset + 3))
end

local function runCpuUntilReturn(addr)
    if not addr or addr == 0 then return end

    cpu.sp = 0xff
    cpu.ram[0x01ff] = 0xff
    cpu.ram[0x01fe] = 0xfe
    cpu.sp = 0xfd
    cpu.pc = addr

    local instr = 0
    while cpu.pc ~= 0xffff and instr < 20000 do
        cpu:step()
        instr = instr + 1
    end
end

-- setup w65c02
function cpu:writemem(addr, val)
    if addr >= 0xd400 and addr <= 0xd418 then
        sid[addr - 0xd400 + 1] = val
    else
        self.ram[addr] = val
    end
end

function cpu:readmem(addr)
    if addr >= 0xd400 and addr <= 0xd418 then
        return sid[addr - 0xd400 + 1] or 0
    end
    return self.ram[addr]
end

local function parseHeader(data)
    header.magic       = string.sub(data, 1, 4)
    header.version     = read16be(data, 5)
    header.dataOffset  = read16be(data, 7)
    header.loadAddress = read16be(data, 9)
    header.initAddress = read16be(data, 11)
    header.playAddress = read16be(data, 13)
    header.songs       = read16be(data, 15)
    header.startSong   = read16be(data, 17)
    header.speed       = read32be(data, 19)
    header.flags       = read16be(data, 119)
    header.name        = cleanString(data:sub(23, 54):match("^([^%z]*)"))
    header.author      = cleanString(data:sub(55, 86):match("^([^%z]*)"))
    header.copyright   = cleanString(data:sub(87, 118):match("^([^%z]*)"))
end

local function parseSidDataAndLoadSong(data)
    parseHeader(data)

    if not header then
        return
    end
    if header.magic ~= "PSID" then
        status = "SID file not compatible"
    end

    is_pal         = bit.band(header.flags, 0x04) ~= 0
    is_ntsc        = bit.band(header.flags, 0x08) ~= 0
    sid.is_ntsc    = is_ntsc and not is_pal
    play_speed     = (is_pal and (1 / 50)) or (1 / 60)

    local songData = data:sub(header.dataOffset + 1)
    if header.loadAddress == 0 then
        header.loadAddress = bit.bor(bit.lshift(songData:byte(2), 8), songData:byte(1))
        songData = songData:sub(3)
    end

    for i = 0, 0xffff do cpu:writemem(i, 0) end

    for i = 1, #songData do
        cpu:writemem(header.loadAddress + i - 1, songData:byte(i))
    end
    cpu:init()

    play_timer, clock_timer = 0, 0

    cpu.A = header.startSong - 1
    if header.initAddress ~= 0 then
        runCpuUntilReturn(header.initAddress)
    end

    is_loaded = true
end

function love.load()
    love.graphics.setFont(love.graphics.newFont(20))

    local filename = arg[2]
    if filename then
        is_loaded = false

        if love.filesystem.getInfo(filename, "file") then
            local file = love.filesystem.newFileData(filename)
            parseSidDataAndLoadSong(file:getString())
        end
    else
        status = "drag and drop a .sid file to play"
    end
end

function love.update(dt)
    if is_loaded then
        play_timer = play_timer + dt
        clock_timer = clock_timer + dt

        while play_timer >= play_speed do
            runCpuUntilReturn(header.playAddress)
            play_timer = play_timer - play_speed
        end

        sid:update()
    end
end

function love.draw()
    if not is_loaded then
        love.graphics.printf(status, 0, wh / 2 - 10, ww, "center")
    else
        love.graphics.printf(
            {
                { 1,   1,   1 }, "Currently playing: " .. header.name,
                { 0.5, 0.5, 0.5 }, "\nby " .. header.author,
                { 0.4, 0.4, 0.4 }, " (c) " .. header.copyright,
                { 1,   1,   1 }, "\n\n" .. string.format("Time: %.2f", clock_timer),
                { 1, 1, 1 }, (is_pal and "\nPAL 50Hz") or (is_ntsc and "\nNTSC 60Hz")
            },
            20, 20, ww - 40, "left"
        )
    end
end

---@param file love.DroppedFile
function love.filedropped(file)
    file:open("r")
    parseSidDataAndLoadSong(file:read("string"))
    file:close()
end
