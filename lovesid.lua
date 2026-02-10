-- lovesid.lua
-- Copyright (c) 2026 Mustafa Bildirici @mstfbil (voltie_dev)
-- Licensed under the MIT License

local bit          = require("bit")

local PAL_CLK      = 985248
local NTSC_CLK     = 1022727
local SAMPLE_RATE  = 44100
local BUFFER_COUNT = 2
local BUFFER_SIZE  = 1024
local ADSR_TABLE   = {
    attack  = { 0.002, 0.008, 0.016, 0.024, 0.038, 0.056, 0.068, 0.080, 0.100, 0.250, 0.500, 0.800, 1.000, 3.000, 5.000, 8.000 },
    decay   = { 0.006, 0.024, 0.048, 0.072, 0.114, 0.168, 0.204, 0.240, 0.300, 0.750, 1.500, 2.400, 3.000, 9.000, 15.00, 24.00 },
    release = { 0.006, 0.024, 0.048, 0.072, 0.114, 0.168, 0.204, 0.240, 0.300, 0.750, 1.500, 2.400, 3.000, 9.000, 15.00, 24.00 }
}

local _registers   = {}
local _chStates    = {
    { acc = 0.0, prev_acc = 0.0, env_level = 0, env_state = "IDLE", noise_reg = 0xfffff, last_bit19 = 0 },
    { acc = 0.0, prev_acc = 0.0, env_level = 0, env_state = "IDLE", noise_reg = 0xfffff, last_bit19 = 0 },
    { acc = 0.0, prev_acc = 0.0, env_level = 0, env_state = "IDLE", noise_reg = 0xfffff, last_bit19 = 0 },
}
local _filterState = {
    low = 0,
    band = 0
}

local lovesid      = setmetatable({}, {
    __newindex = function(t, k, v)
        if type(k) == "number" and k >= 1 and k <= 25 then
            _registers[k] = bit.band(v, 0xff)
        else
            rawset(t, k, v)
        end
    end,
    __index = function(t, k)
        return (type(k) == "number" and _registers[k])
            or rawget(t, k)
    end
})

lovesid.source     = love.audio.newQueueableSource(44100, 16, 1, BUFFER_COUNT)
lovesid.is_ntsc    = false

lovesid.samples    = { {}, {}, {} }
lovesid.freqs      = { 0, 0, 0 }

local function getFrequency(channel)
    if channel < 1 or channel > 3 then return end

    local offset = (channel - 1) * 7 + 1
    local lo, hi = _registers[offset] or 0, _registers[offset + 1] or 0
    local word = bit.bor(bit.lshift(hi, 8), lo)
    return word
end

local function wordToHz(word)
    local clock = lovesid.is_ntsc and NTSC_CLK or PAL_CLK
    return word * (clock / 16777216)
end

local function getPulseWidth(channel)
    if channel < 1 or channel > 3 then return end

    local offset = (channel - 1) * 7 + 3
    local lo, hi = _registers[offset] or 0, bit.band(_registers[offset + 1] or 0, 0xf)
    local word = bit.bor(bit.lshift(hi, 8), lo)

    return word
end

local function getControl(channel)
    if channel < 1 or channel > 3 then return end

    local offset = (channel - 1) * 7 + 5
    local byte   = _registers[offset] or 0

    local gate   = bit.band(byte, 0x01) ~= 0
    local sync   = bit.band(byte, 0x02) ~= 0
    local ring   = bit.band(byte, 0x04) ~= 0
    local test   = bit.band(byte, 0x08) ~= 0
    local tri    = bit.band(byte, 0x10) ~= 0
    local saw    = bit.band(byte, 0x20) ~= 0
    local pulse  = bit.band(byte, 0x40) ~= 0
    local noise  = bit.band(byte, 0x80) ~= 0

    return gate, sync, ring, test, tri, saw, pulse, noise
end

local function getADSR(channel)
    if channel < 1 or channel > 3 then return end

    local offset = (channel - 1) * 7 + 6
    local AD, SR = _registers[offset] or 0, _registers[offset + 1] or 0
    local attack = bit.band(bit.rshift(AD, 4), 0xf)
    local decay = bit.band(AD, 0xf)
    local sustain = bit.band(bit.rshift(SR, 4), 0xf)
    local release = bit.band(SR, 0xf)

    return attack, decay, sustain, release
end

local function getVolume()
    local byte = _registers[25] or 0
    return bit.band(byte, 0xf)
end

local function getFilterCutoff()
    local lo, hi = bit.band(_registers[22] or 0, 0x7), _registers[23] or 0
    local word = bit.bor(lo, bit.lshift(hi, 3))

    return word
end

local function getFilterResonance()
    local byte = _registers[24] or 0
    return bit.band(bit.rshift(byte, 4), 0xf)
end

local function getFilterApply()
    local byte = _registers[24] or 0

    local filt1 = bit.band(byte, 0x1) ~= 0
    local filt2 = bit.band(byte, 0x2) ~= 0
    local filt3 = bit.band(byte, 0x4) ~= 0
    -- filtEx unused for now

    return filt1, filt2, filt3
end

local function getFilterPass()
    local byte = _registers[25] or 0

    local lowPass = bit.band(byte, 0x10) ~= 0
    local bandPass = bit.band(byte, 0x20) ~= 0
    local highPass = bit.band(byte, 0x40) ~= 0

    return lowPass, bandPass, highPass
end

local function getChannel3Off()
    local byte = _registers[25] or 0
    return (bit.band(byte, 0x80) == 0x80) or false
end

local function updateEnvelope(channel)
    local state = _chStates[channel]
    local gate = getControl(channel)
    local a, d, s, r = getADSR(channel)

    local sustain_level = s * 17
    local dt = 1 / SAMPLE_RATE

    if gate then
        if state.env_state == "IDLE" or state.env_state == "RELEASE" then
            state.env_state = "ATTACK"
        end
    else
        state.env_state = "RELEASE"
    end

    if state.env_state == "ATTACK" then
        local duration = ADSR_TABLE.attack[a + 1]
        state.env_level = state.env_level + (255 / duration) * dt
        if state.env_level >= 255 then
            state.env_level = 255
            state.env_state = "DECAY"
        end
    elseif state.env_state == "DECAY" then
        local duration = ADSR_TABLE.decay[d + 1]
        state.env_level = state.env_level - (255 / duration) * dt
        if state.env_level <= sustain_level then
            state.env_level = sustain_level
            state.env_state = "SUSTAIN"
        end
    elseif state.env_state == "SUSTAIN" then
        state.env_level = sustain_level
    elseif state.env_state == "RELEASE" then
        local duration = ADSR_TABLE.release[r + 1]
        state.env_level = state.env_level - (255 / duration) * dt
        if state.env_level <= 0 then
            state.env_level = 0
            state.env_state = "IDLE"
        end
    end
end

local function processFilter(input, lp, bp, hp, resonance)
    local cutoff = getFilterCutoff()

    local f = (cutoff / 2047) * 0.7
    if f > 0.85 then f = 0.85 end

    local q = 1.0 - (resonance / 15)
    if q < 0.05 then q = 0.05 end

    local high = input - _filterState.low - (q * _filterState.band)
    _filterState.band = _filterState.band + (f * high)
    _filterState.low = _filterState.low + (f * _filterState.band)

    if _filterState.band > 1 then
        _filterState.band = 1
    elseif _filterState.band < -1 then
        _filterState.band = -1
    end

    if _filterState.low > 1 then
        _filterState.low = 1
    elseif _filterState.low < -1 then
        _filterState.low = -1
    end

    local output = 0
    if lp then output = output + _filterState.low end
    if bp then output = output + _filterState.band end
    if hp then output = output + high end

    return (output * 0.8) + (input * 0.2)
end

local function stepOscillators()
    local clock = lovesid.is_ntsc and NTSC_CLK or PAL_CLK
    local dt_clock = clock / SAMPLE_RATE

    for i = 1, 3 do
        local state = _chStates[i]
        local _, _, _, test = getControl(i)

        state.prev_acc = state.acc
        if test then
            state.noise_reg = 0xfffff
            state.acc = 0
        else
            local freq = getFrequency(i)
            state.acc = (state.acc + freq * dt_clock) % 16777216
        end
    end

    for i = 1, 3 do
        local _, sync = getControl(i)
        if sync then
            local modIdx = (i == 1) and 3 or (i - 1)
            if _chStates[modIdx].acc < _chStates[modIdx].prev_acc then
                _chStates[i].acc = 0
            end
        end
    end
end

local function getNoiseSample(channel)
    local state = _chStates[channel]
    local acc_i = math.floor(state.acc)
    local current_bit19 = bit.band(bit.rshift(acc_i, 19), 1)

    if state.last_bit19 == 0 and current_bit19 == 1 then
        local reg = state.noise_reg
        local bit22 = bit.band(bit.rshift(reg, 22), 1)
        local bit17 = bit.band(bit.rshift(reg, 17), 1)
        local feedback = bit.bxor(bit22, bit17)

        reg = bit.band(bit.lshift(reg, 1), 0x7fffff)
        reg = bit.bor(reg, feedback)

        state.noise_reg = reg
    end
    state.last_bit19 = current_bit19

    local r = state.noise_reg
    local out = 0
    out = bit.bor(out, bit.lshift(bit.band(bit.rshift(r, 22), 1), 7))
    out = bit.bor(out, bit.lshift(bit.band(bit.rshift(r, 20), 1), 6))
    out = bit.bor(out, bit.lshift(bit.band(bit.rshift(r, 16), 1), 5))
    out = bit.bor(out, bit.lshift(bit.band(bit.rshift(r, 13), 1), 4))
    out = bit.bor(out, bit.lshift(bit.band(bit.rshift(r, 11), 1), 3))
    out = bit.bor(out, bit.lshift(bit.band(bit.rshift(r, 7), 1), 2))
    out = bit.bor(out, bit.lshift(bit.band(bit.rshift(r, 4), 1), 1))
    out = bit.bor(out, bit.band(bit.rshift(r, 2), 1))

    return out
end

local function getSample(channel)
    if channel < 1 or channel > 3 then return end

    local modulatorIndex = (channel == 1) and 3 or (channel - 1)

    local state = _chStates[channel]

    local gate, sync, ring, test, tri, saw, pulse, noise = getControl(channel)

    if test then
        return 0
    end

    local sampleRaw = 0xff
    local anyWave = false
    local acc_i = math.floor(state.acc)

    if tri then
        local raw_tri_acc = acc_i

        if ring then
            local carMsb = bit.band(bit.rshift(acc_i, 23), 1)
            local modMsb = bit.band(bit.rshift(_chStates[modulatorIndex].acc, 23), 1)
            local ringMsb = bit.bxor(carMsb, modMsb)

            raw_tri_acc = bit.bor(
                bit.band(acc_i, 0x7fffff),
                bit.lshift(ringMsb, 23)
            )
        end

        local msb = bit.band(bit.rshift(raw_tri_acc, 23), 1)
        local v = bit.band(bit.rshift(raw_tri_acc, 16), 0x7f)

        if msb == 1 then v = 0x7f - v end
        sampleRaw = bit.band(sampleRaw, v * 2)
        anyWave = true
    end
    if saw then
        local v = bit.band(bit.rshift(acc_i, 16), 0xff)
        sampleRaw = bit.band(sampleRaw, v)
        anyWave = true
    end
    if pulse then
        local pw = getPulseWidth(channel) or 0
        local acc12 = bit.band(bit.rshift(acc_i, 12), 0xfff)
        local v = (acc12 < pw) and 0xff or 0x00
        sampleRaw = bit.band(sampleRaw, v)
        anyWave = true
    end
    if noise then
        local v = getNoiseSample(channel)
        sampleRaw = bit.band(sampleRaw, v)
        anyWave = true
    end

    if not anyWave then return 0 end

    -- normalize
    local sample = (sampleRaw / 127.5) - 1

    return sample * (state.env_level / 0xff) * (getVolume() / 16)
end

function lovesid:update()
    self.source:play()
    while self.source:getFreeBufferCount() > 0 do
        local soundData = love.sound.newSoundData(BUFFER_SIZE, SAMPLE_RATE, 16, 1)

        local f1, f2, f3 = getFilterApply()
        local lp, bp, hp = getFilterPass()
        local res = getFilterResonance()
        local mainVol = getVolume() / 15

        for ch = 1, 3 do
            local word = getFrequency(ch)
            self.freqs[ch] = wordToHz(word)
        end

        for i = 0, BUFFER_SIZE - 1 do
            updateEnvelope(1)
            updateEnvelope(2)
            updateEnvelope(3)
            stepOscillators()

            local s1, s2, s3 = getSample(1) / 3 or 0, getSample(2) / 3 or 0,
                (not getChannel3Off() and (getSample(3) / 3)) or 0
            lovesid.samples[1][i + 1] = s1
            lovesid.samples[2][i + 1] = s2
            lovesid.samples[3][i + 1] = s3

            local filteredInput = 0
            local unfilteredOutput = 0

            if f1 then
                filteredInput = filteredInput + s1
            else
                unfilteredOutput = unfilteredOutput + s1
            end
            if f2 then
                filteredInput = filteredInput + s2
            else
                unfilteredOutput = unfilteredOutput + s2
            end
            if f3 then
                filteredInput = filteredInput + s3
            else
                unfilteredOutput = unfilteredOutput + s3
            end

            local filteredOutput = processFilter(filteredInput, lp, bp, hp, res)

            local finalSample = (unfilteredOutput + filteredOutput) * mainVol
            if finalSample ~= finalSample then finalSample = 0 end
            soundData:setSample(i, math.max(-1, math.min(1, finalSample)))
        end

        self.source:queue(soundData)
    end
end

return lovesid
