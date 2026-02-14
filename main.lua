local bit = require("bit")
local cpu = require("6502")
local sid = require("lovesid")

local header = {}

local status = ""
local sid_data, is_pal, is_ntsc, is_loaded, play_speed
local play_timer = 0
local clock_timer = 0
local checkpoint_timer = 0
local CHECKPOINT_INTERVAL = 60
local MAX_CHECKPOINTS = 20

local is_seeking = false
local seek_target_time = 0

local ww, wh = love.graphics.getDimensions()

local seek_checkpoints = {}

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
    sid_data = data
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

    seek_checkpoints = {}
    checkpoint_timer = 0
    is_seeking = false

    is_loaded = true
end

local function createSeekCheckpoint()
    for i = #seek_checkpoints, 1, -1 do
        if seek_checkpoints[i].clock_timer >= clock_timer then
            table.remove(seek_checkpoints, i)
        end
    end
    local checkpoint = {
        cpu = {
            A = cpu.A,
            X = cpu.X,
            Y = cpu.Y,
            pc = cpu.pc,
            sp = cpu.sp
        },
        ram = {},
        sid = { unpack(sid) },

        play_timer = play_timer,
        clock_timer = clock_timer
    }
    for i = 0, 0xffff do
        checkpoint.ram[i] = cpu.ram[i]
    end
    table.insert(seek_checkpoints, checkpoint)
    if #seek_checkpoints > MAX_CHECKPOINTS then
        table.remove(seek_checkpoints, 1) -- Remove the oldest one
    end
end

local function loadSeekCheckpoint(checkpoint)
    if not checkpoint then return end

    cpu.A, cpu.X, cpu.Y, cpu.pc, cpu.sp = checkpoint.cpu.A, checkpoint.cpu.X, checkpoint.cpu.Y, checkpoint.cpu.pc,
        checkpoint.cpu.sp

    play_timer = checkpoint.play_timer
    clock_timer = checkpoint.clock_timer

    for i = 0, 0xffff do
        cpu.ram[i] = checkpoint.ram[i]
    end

    for i = 1, #checkpoint.sid do
        sid[i] = checkpoint.sid[i]
    end
end

local function seek(target_second)
    if not is_loaded then return end
    if target_second < 0 then
        target_second = 0
    end

    if target_second < clock_timer then
        local best_checkpoint = nil

        for i = #seek_checkpoints, 1, -1 do
            if seek_checkpoints[i].clock_timer <= target_second then
                best_checkpoint = seek_checkpoints[i]
                break
            end
        end

        if best_checkpoint then
            loadSeekCheckpoint(best_checkpoint)
        else
            parseSidDataAndLoadSong(sid_data)
        end
    end

    seek_target_time = target_second
    is_seeking = true
end

local function runSong(dt)
    if not is_loaded then return end

    if is_seeking then
        local chunk_limit = clock_timer + 5
        local final_target = math.min(chunk_limit, seek_target_time)

        while clock_timer < final_target do
            runCpuUntilReturn(header.playAddress)
            clock_timer = clock_timer + play_speed

            checkpoint_timer = checkpoint_timer + play_speed

            if checkpoint_timer >= CHECKPOINT_INTERVAL then
                checkpoint_timer = 0
                createSeekCheckpoint()
            end
        end

        if clock_timer >= seek_target_time then
            clock_timer = seek_target_time
            is_seeking = false
            play_timer = 0
            checkpoint_timer = clock_timer % CHECKPOINT_INTERVAL
        end
    else
        play_timer = play_timer + dt
        clock_timer = clock_timer + dt
        checkpoint_timer = checkpoint_timer + dt

        while play_timer >= play_speed do
            runCpuUntilReturn(header.playAddress)
            play_timer = play_timer - play_speed
        end

        if checkpoint_timer >= CHECKPOINT_INTERVAL then
            checkpoint_timer = 0
            createSeekCheckpoint()
        end
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
    runSong(dt)
    if not is_seeking then
        sid:update()
    end
end

function love.draw()
    love.graphics.setColor(1, 1, 1)
    if not is_loaded then
        love.graphics.printf(status, 0, wh / 2 - 10, ww, "center")
    else
        love.graphics.printf(
            {
                { 1,   1,   1 }, "Currently playing: " .. header.name,
                { 0.5, 0.5, 0.5 }, "\nby " .. header.author,
                { 0.4, 0.4, 0.4 }, " (c) " .. header.copyright,
                { 1,   1,   1 }, "\n\n" .. (is_seeking and string.format("Time: %.2f (seeking)", seek_target_time) or
                string.format("Time: %.2f", clock_timer)),
                { 1,   1,   1 }, (is_pal and "\nPAL 50Hz") or (is_ntsc and "\nNTSC 60Hz"),
                { 0.5, 0.5, 0.5 }, "\n\n\n<- and -> to seek"
            },
            20, 20, ww - 40, "left"
        )
    end

    love.graphics.setColor(0.3, 0.3, 0.3)
    love.graphics.printf("made with love by voltie_dev", 0, 270, ww, "center")
end

---@param file love.DroppedFile
function love.filedropped(file)
    file:open("r")
    parseSidDataAndLoadSong(file:read("string"))
    file:close()
end

function love.keypressed(key)
    if not is_seeking then
        if key == "right" then
            seek(clock_timer + 10)
        elseif key == "left" then
            seek(clock_timer - 10)
        end
    end
end
