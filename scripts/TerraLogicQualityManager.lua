--[[
    TerraLogicQualityManager.lua
    Persistent work-quality cells, harvest penalties and multiplayer sync.

    Copyright (c) 2026 The Mod Workshop. All rights reserved.
    Unauthorized copying, modification, or redistribution is prohibited
    except where expressly permitted by the copyright owner.

    Source fingerprint: TMW-TL-QUAL-1.200400
]]

TerraLogicQualityManager = {}
OverSpeedQualityManager = TerraLogicQualityManager
-- Numeric source signature only; it is deliberately excluded from gameplay math.
TerraLogicQualityManager.SOURCE_FINGERPRINT = 1.200400

TerraLogicQualityManager.CELL_SIZE = 4
TerraLogicQualityManager.CHUNK_SIZE = 32
TerraLogicQualityManager.CHUNK_CELL_COUNT = 32 * 32
TerraLogicQualityManager.LAYER_FLUSH_THRESHOLD = 128
-- A mower can process the same fixed TerraLogic cell through several WorkAreas and
-- over several simulation frames. Finish the harvest only after that cell has
-- not been touched for a short period, so perennial recovery runs once per
-- cut instead of once per WorkArea/frame.
TerraLogicQualityManager.MOWER_CELL_SETTLE_TIME_MS = 500
-- Three semantic crop windows drive root-zone and moisture sampling. They no
-- longer recover a separate plough-quality value; the soil maps themselves
-- develop through roots, cover and monthly physical recovery.
TerraLogicQualityManager.PLOW_GROWTH_STAGES = 3
TerraLogicQualityManager.PLOW_GROWTH_DELAY_MS = 1500
TerraLogicQualityManager.PLOW_GROWTH_CHECKS_PER_FRAME = 512
TerraLogicQualityManager.SAVE_FILE = "terraLogicWorkQuality.xml"
TerraLogicQualityManager.LEGACY_SAVE_FILE = "overSpeedWorkQuality.xml"
-- Quality is almost perfect throughout the advertised working range. Above
-- shop speed the yield-per-hour target, not an arbitrary linear quality loss,
-- drives the curve. K=1 makes every overspeed marginally uneconomical before
-- draft, abrasion and random impacts are counted as additional costs.
TerraLogicQualityManager.QUALITY_AT_REAL_SPEED = 1.00
-- Every speed up to the implement's advertised shop limit is agronomically
-- neutral by itself. Soil, moisture and condition still reduce total Work
-- Quality; the speed component begins to deteriorate only above shop speed.
TerraLogicQualityManager.QUALITY_AT_SHOP_SPEED = 0.98
TerraLogicQualityManager.MINIMUM_SPEED_QUALITY = 0.00
TerraLogicQualityManager.ECONOMY_CURVE_K = 1.00
-- The calibrated points form a monotone condition envelope. Slow travel can
-- recover only its motion-dependent share; the remaining loss still requires
-- repair. Smooth interpolation avoids visible steps at damage milestones.
TerraLogicQualityManager.CONDITION_QUALITY_START_DAMAGE = 0.75
TerraLogicQualityManager.CONDITION_BROKEN_DAMAGE = 0.9995
-- Slower travel can reduce bouncing and loss of ground contact, but it cannot
-- repair worn metal or prepare an unsuitable seedbed. These caps deliberately
-- leave a visible residual loss at realistic speed so the permanent remedy
-- remains understandable to the player.
TerraLogicQualityManager.SLOWDOWN_SOIL_QUALITY_RECOVERY = 0.35
TerraLogicQualityManager.SLOWDOWN_SOIL_DROPOUT_RECOVERY = 0.70
TerraLogicQualityManager.SLOWDOWN_CONDITION_RECOVERY = 0.50
TerraLogicQualityManager.CONDITION_QUALITY_CURVE = {
    {damage = 0.75, quality = 1.00},
    {damage = 0.80, quality = 0.99},
    {damage = 0.85, quality = 0.93},
    {damage = 0.90, quality = 0.82},
    {damage = 0.95, quality = 0.63},
    {damage = 0.99, quality = 0.42},
    {damage = 1.00, quality = 0.00}
}
-- TerraLogic changes the yield already produced by Vanilla/Precision Farming.
-- The standing crop can range from 60% to 110% of that untouched baseline.
-- Physical seed misses remain absent plants and therefore stay outside this
-- clamp; an excellent surviving stand can never recreate a missed row.
TerraLogicQualityManager.MINIMUM_FINAL_YIELD_FACTOR = 0.60
TerraLogicQualityManager.MAXIMUM_FINAL_YIELD_FACTOR = 1.10
TerraLogicQualityManager.MINIMUM_ROOT_ZONE_FACTOR = 0.65
TerraLogicQualityManager.ROOT_ZONE_SPREAD_EXPONENT = 1.15
TerraLogicQualityManager.YIELD_LOSS_SPREAD_EXPONENT = 1.25
TerraLogicQualityManager.MAXIMUM_TOTAL_YIELD_PENALTY = 0.40
local CATEGORY_BALANCE = TerraLogicImplementProfiles.WORK_QUALITY_CATEGORIES
TerraLogicQualityManager.COMPONENTS = {
    soilPlow      = {group = "soil", labelKey = "terraLogic_workQualitySoil", fallbackLabel = "Soil condition", yieldWeight = CATEGORY_BALANCE.soil.weight, maxYieldPenalty = CATEGORY_BALANCE.soil.maxPenalty, affectsYield = false, dynamicSoil = true, bit = 1},
    soilCultivate = {group = "soil", labelKey = "terraLogic_workQualitySoil", fallbackLabel = "Soil condition", yieldWeight = CATEGORY_BALANCE.soil.weight, maxYieldPenalty = CATEGORY_BALANCE.soil.maxPenalty, affectsYield = false, dynamicSoil = true, bit = 2},
    seed          = {group = "seed", labelKey = "terraLogic_workQualitySeed", fallbackLabel = "Seeding quality", yieldWeight = CATEGORY_BALANCE.seed.weight, maxYieldPenalty = CATEGORY_BALANCE.seed.maxPenalty, directDensityPenalty = true, bit = 4},
    fertilizer    = {group = "fertilizer", labelKey = "terraLogic_workQualityFertilizer", fallbackLabel = "Fertilizing quality", yieldWeight = CATEGORY_BALANCE.fertilizer.weight, maxYieldPenalty = CATEGORY_BALANCE.fertilizer.maxPenalty, bit = 8},
    herbicide     = {group = "herbicide", labelKey = "terraLogic_workQualityHerbicide", fallbackLabel = "Weed control quality", yieldWeight = CATEGORY_BALANCE.herbicide.weight, maxYieldPenalty = CATEGORY_BALANCE.herbicide.maxPenalty, affectsYield = false, bit = 16},
    roller        = {group = "roller", labelKey = "terraLogic_workQualityRoller", fallbackLabel = "Rolling quality", yieldWeight = CATEGORY_BALANCE.roller.weight, maxYieldPenalty = CATEGORY_BALANCE.roller.maxPenalty, affectsYield = false, bit = 32},
    mulch         = {group = "mulch", labelKey = "terraLogic_workQualityMulch", fallbackLabel = "Mulching quality", yieldWeight = 0.025, maxYieldPenalty = 0.025, affectsYield = false, bit = 64},
    lime          = {group = "lime", labelKey = "terraLogic_workQualityLime", fallbackLabel = "Liming quality", yieldWeight = CATEGORY_BALANCE.lime.weight, maxYieldPenalty = CATEGORY_BALANCE.lime.maxPenalty, bit = 128}
}
TerraLogicQualityManager.COMPONENT_ORDER = {
    "soilPlow", "soilCultivate", "seed", "fertilizer", "lime", "herbicide", "roller", "mulch"
}
TerraLogicQualityManager.GROUP_ORDER = {
    "soil", "seed", "fertilizer", "lime", "herbicide", "roller", "mulch"
}
TerraLogicQualityManager.GROUP_DEFINITIONS = {
    soil = TerraLogicQualityManager.COMPONENTS.soilPlow,
    seed = TerraLogicQualityManager.COMPONENTS.seed,
    fertilizer = TerraLogicQualityManager.COMPONENTS.fertilizer,
    lime = TerraLogicQualityManager.COMPONENTS.lime,
    herbicide = TerraLogicQualityManager.COMPONENTS.herbicide,
    roller = TerraLogicQualityManager.COMPONENTS.roller,
    mulch = TerraLogicQualityManager.COMPONENTS.mulch
}
-- Live-only effects are never serialized into field chunks. Mower quality is
-- evaluated for the current cut and scales only the grass liters created by
-- that pass; the underlying mown area remains Vanilla/PF-owned.
TerraLogicQualityManager.LIVE_COMPONENTS = {
    mower = {
        group = "mower",
        labelKey = "terraLogic_workQualityMower",
        fallbackLabel = "Mowing quality",
        yieldWeight = TerraLogicImplementProfiles.YIELD_QUALITY.mower.weight,
        maxYieldPenalty = TerraLogicImplementProfiles.YIELD_QUALITY.mower.maxPenalty
    }
}

-- Components whose underlying Vanilla result is destroyed by a later pass.
-- Fertilizer, lime and mulch deliberately survive tillage: Vanilla keeps
-- their agronomic benefit. Soil work destroys the crop/seedbed, rolling and
-- crop-specific weed control. A successful new seed pass likewise starts a
-- new crop and invalidates rolling and weed control from the previous crop.
TerraLogicQualityManager.OVERWRITTEN_COMPONENTS = {
    soilPlow = {"seed", "roller", "herbicide"},
    soilCultivate = {"seed", "roller", "herbicide"},
    seed = {"roller", "herbicide"}
}
TerraLogicQualityManager.BONUS_GROUPS = {
    -- Vanilla fertilizer has two successful 22.5 percentage-point stages.
    -- One WorkArea change represents one newly earned stage.
    fertilizer = {bonus = 0.225, label = "fertilizer stage", rateLimitedRange = 0.80},
    lime = {bonus = 0.15, label = "lime", rateLimitedRange = 0.80},
    herbicide = {bonus = 0.20, label = "weed control", rateLimitedRange = 0.80},
    roller = {bonus = 0.025, label = "rolling"},
    mulch = {bonus = 0.025, label = "mulching"}
}
TerraLogicQualityManager.chunks = {}
TerraLogicQualityManager.dirty = false
TerraLogicQualityManager.clientCells = {}
TerraLogicQualityManager.pendingHarvestClears = {}
TerraLogicQualityManager.pendingMowerClears = {}
TerraLogicQualityManager.partialHarvestCells = {}

-- Text and compact-storage helpers -----------------------------------------

-- Clears counters used only by the harvest debug screen.
function TerraLogicQualityManager:resetHarvestDiagnostics()
    self.harvestDiagnosticCount = 0
    self.harvestClearDiagnosticCount = 0
    self.harvestDiagnosticState = {}
end

function TerraLogicQualityManager:getText(key, fallback)
    if g_i18n ~= nil and g_i18n.getText ~= nil then
        local translated = g_i18n:getText(key)
        if translated ~= nil and translated ~= "" and translated ~= key then
            return translated
        end
    end
    return fallback or key
end

function TerraLogicQualityManager:getComponentLabel(name)
    local definition = self.COMPONENTS[name] or self.GROUP_DEFINITIONS[name]
        or self.LIVE_COMPONENTS[name]
    if definition == nil then return tostring(name or "") end
    return self:getText(definition.labelKey, definition.fallbackLabel)
end

local ZERO_DATA = string.rep(string.char(0), TerraLogicQualityManager.CHUNK_CELL_COUNT)
local PERFECT_DATA = string.rep(string.char(255), TerraLogicQualityManager.CHUNK_CELL_COUNT)
local BYTE_TO_HEX = {}
for value = 0, 255 do BYTE_TO_HEX[value] = string.format("%02X", value) end

local function getCellIndex(value)
    return math.floor(value / TerraLogicQualityManager.CELL_SIZE)
end

local function getChunkPosition(ix, iz)
    local chunkX = math.floor(ix / TerraLogicQualityManager.CHUNK_SIZE)
    local chunkZ = math.floor(iz / TerraLogicQualityManager.CHUNK_SIZE)
    local localX = ix - chunkX * TerraLogicQualityManager.CHUNK_SIZE
    local localZ = iz - chunkZ * TerraLogicQualityManager.CHUNK_SIZE
    return chunkX, chunkZ,
        tostring(chunkX) .. ":" .. tostring(chunkZ),
        localZ * TerraLogicQualityManager.CHUNK_SIZE + localX + 1
end

local function hasBit(mask, bit)
    return mask % (bit * 2) >= bit
end

local function addBit(mask, bit)
    return hasBit(mask, bit) and mask or mask + bit
end

local function removeBit(mask, bit)
    return hasBit(mask, bit) and mask - bit or mask
end

local function bytesToHex(data)
    local result = {}
    for index = 1, #data do
        result[index] = BYTE_TO_HEX[string.byte(data, index)]
    end
    return table.concat(result)
end

local function hexToBytes(value, defaultByte)
    if value == nil then
        return string.rep(string.char(defaultByte), TerraLogicQualityManager.CHUNK_CELL_COUNT)
    end
    local result = {}
    for index = 1, TerraLogicQualityManager.CHUNK_CELL_COUNT do
        local startIndex = index * 2 - 1
        local byte = tonumber(string.sub(value, startIndex, startIndex + 1), 16)
        result[index] = string.char(byte or defaultByte)
    end
    return table.concat(result)
end

local function mergeFormat5SoilLayers(
        statusData, cultivateHex, directHex, defaultByte, isQuality)
    local cultivateData = hexToBytes(cultivateHex, defaultByte)
    local directData = hexToBytes(directHex, defaultByte)
    local result = {}
    for offset = 1, TerraLogicQualityManager.CHUNK_CELL_COUNT do
        local mask = string.byte(statusData, offset) or 0
        local hasCultivate, hasDirect = hasBit(mask, 2), hasBit(mask, 64)
        local first = string.byte(cultivateData, offset) or defaultByte
        local second = string.byte(directData, offset) or defaultByte
        local value = defaultByte
        if hasCultivate and hasDirect then
            if isQuality then
                local q1 = first == 255 and 1 or first / 254
                local q2 = second == 255 and 1 or second / 254
                local quality = (q1 + q2) * 0.5
                value = quality >= 0.9995 and 255
                    or math.clamp(math.floor(quality * 254 + 0.5), 0, 254)
            else
                value = math.clamp(math.floor((first + second) * 0.5 + 0.5), 0, 255)
            end
        elseif hasCultivate then
            value = first
        elseif hasDirect then
            value = second
        end
        result[offset] = string.char(value)
    end
    return table.concat(result)
end

local function newLayer(defaultByte, data)
    data = data or string.rep(string.char(defaultByte), TerraLogicQualityManager.CHUNK_CELL_COUNT)
    local nonDefaultCount = 0
    for index = 1, TerraLogicQualityManager.CHUNK_CELL_COUNT do
        if string.byte(data, index) ~= defaultByte then
            nonDefaultCount = nonDefaultCount + 1
        end
    end
    return {
        data = data,
        defaultByte = defaultByte,
        changes = {},
        changeCount = 0,
        nonDefaultCount = nonDefaultCount
    }
end

local function getLayerByte(layer, offset)
    local changed = layer.changes[offset]
    return changed ~= nil and changed or string.byte(layer.data, offset)
end

local function flushLayer(layer)
    if layer.changeCount == 0 then return end
    local bytes = {}
    for index = 1, TerraLogicQualityManager.CHUNK_CELL_COUNT do
        bytes[index] = string.char(layer.changes[index]
            or string.byte(layer.data, index)
            or layer.defaultByte)
    end
    layer.data = table.concat(bytes)
    layer.changes = {}
    layer.changeCount = 0
end

local function setLayerByte(layer, offset, value)
    local oldValue = getLayerByte(layer, offset)
    if oldValue == value then return false end
    if oldValue == layer.defaultByte and value ~= layer.defaultByte then
        layer.nonDefaultCount = layer.nonDefaultCount + 1
    elseif oldValue ~= layer.defaultByte and value == layer.defaultByte then
        layer.nonDefaultCount = layer.nonDefaultCount - 1
    end
    if layer.changes[offset] == nil then
        layer.changeCount = layer.changeCount + 1
    end
    layer.changes[offset] = value
    if layer.changeCount >= TerraLogicQualityManager.LAYER_FLUSH_THRESHOLD then
        flushLayer(layer)
    end
    return true
end

local function newChunk(chunkX, chunkZ, statusData)
    return {
        x = chunkX,
        z = chunkZ,
        status = newLayer(0, statusData or ZERO_DATA),
        qualities = {},
        penalties = {},
        counts = {},
        metadata = {}
    }
end

local function getAreaGeometry(workArea)
    if workArea == nil or workArea.start == nil or workArea.width == nil
        or workArea.height == nil then
        return nil
    end
    local sx, _, sz = getWorldTranslation(workArea.start)
    local wx, _, wz = getWorldTranslation(workArea.width)
    local hx, _, hz = getWorldTranslation(workArea.height)
    return sx, sz, wx - sx, wz - sz, hx - sx, hz - sz
end

local function isHarvestableProbe(fruitTypeIndex, growthState,
        useMinForageState)
    fruitTypeIndex, growthState = tonumber(fruitTypeIndex),
        tonumber(growthState)
    if fruitTypeIndex == nil or fruitTypeIndex <= 0
        or growthState == nil then return false end
    if g_fruitTypeManager == nil
        or g_fruitTypeManager.getFruitTypeByIndex == nil then return true end
    local desc = g_fruitTypeManager:getFruitTypeByIndex(fruitTypeIndex)
    if desc == nil then return true end
    local minimum = tonumber(desc.minHarvestingGrowthState)
    local maximum = tonumber(desc.maxHarvestingGrowthState)
    if useMinForageState == true then
        minimum = tonumber(desc.minForageGrowthState) or minimum
        maximum = tonumber(desc.maxForageGrowthState) or maximum
    end
    if minimum ~= nil and growthState < minimum then return false end
    if maximum ~= nil and growthState > maximum then return false end
    return true
end

-- Samples the narrow swept cutter parallelogram before GIANTS removes its
-- crop. One-metre strips along the header preserve local four-metre yield
-- cells even when the vehicle moves only a few centimetres in one frame.
function TerraLogicQualityManager:createCutterAreaProbe(cutter, workArea)
    local sx, sz, widthX, widthZ, heightX, heightZ = getAreaGeometry(workArea)
    if sx == nil then return nil end
    local cross = math.abs(widthX * heightZ - widthZ * heightX)
    local width = math.sqrt(widthX * widthX + widthZ * widthZ)
    local depth = width > 0.001 and cross / width
        or math.sqrt(heightX * heightX + heightZ * heightZ)
    local columns = math.clamp(math.max(1, math.ceil(width)), 1, 96)
    -- The complete cutter footprint overlaps the crop already removed in the
    -- preceding frame. The newly harvested strip is normally found directly
    -- at one of its two depth edges. Probe immediately inside and just beyond
    -- both edges; the small outward offset still resolves to the same local
    -- four-metre yield neighbourhood while reliably seeing the standing crop
    -- before the next density-map step removes it.
    local depthFractions = {-0.04, 0.02, 0.98, 1.04}
    local rows = #depthFractions
    local sampleWeight = math.max(cross, 0.0001) / (columns * rows)
    local params = cutter ~= nil and cutter.spec_cutter ~= nil
        and cutter.spec_cutter.workAreaParameters or nil
    local allowed = {}
    local fruitTypesToUse = params ~= nil
        and (params.fruitTypeIndicesToUse or params.fruitTypesToUse) or {}
    for key, value in pairs(fruitTypesToUse) do
        local index = value == true and tonumber(key) or tonumber(value)
        if index ~= nil then allowed[index] = true end
    end
    local hasAllowed = next(allowed) ~= nil
    local useMinForageState = cutter ~= nil and cutter.spec_cutter ~= nil
        and (cutter.spec_cutter.useMinForageState == true
            or cutter.spec_cutter.allowsForageGrowthState == true)
    local probe = {
        allCells={}, cropCells={}, probeSamples=0, cropProbeSamples=0,
        rawArea=0, cropRawArea=0, queryErrorSamples=0,
        noFruitSamples=0, disallowedFruitSamples=0,
        missingGrowthSamples=0, unharvestableSamples=0,
        validFruitSamples=0
    }
    for column = 0, columns - 1 do
        local u = (column + 0.5) / columns
        for row = 1, rows do
            local v = depthFractions[row]
            local x = sx + widthX * u + heightX * v
            local z = sz + widthZ * u + heightZ * v
            local ix, iz = getCellIndex(x), getCellIndex(z)
            local key = tostring(ix) .. ":" .. tostring(iz)
            local function addSample(target, fruitTypeIndex)
                local entry = target[key]
                if entry == nil then
                    local chunkX, chunkZ, chunkKey, offset =
                        getChunkPosition(ix, iz)
                    entry = {
                        ix=ix, iz=iz, chunkX=chunkX, chunkZ=chunkZ,
                        chunkKey=chunkKey, offset=offset, rawWeight=0,
                        fruitWeights={}
                    }
                    target[key] = entry
                end
                entry.rawWeight = entry.rawWeight + sampleWeight
                if fruitTypeIndex ~= nil then
                    entry.fruitWeights[fruitTypeIndex] =
                        (entry.fruitWeights[fruitTypeIndex] or 0) + sampleWeight
                end
            end
            addSample(probe.allCells, nil)
            probe.rawArea = probe.rawArea + sampleWeight
            probe.probeSamples = probe.probeSamples + 1
            if FSDensityMapUtil ~= nil
                and FSDensityMapUtil.getFruitTypeIndexAtWorldPos ~= nil then
                local ok, fruitTypeIndex, growthState = pcall(
                    FSDensityMapUtil.getFruitTypeIndexAtWorldPos, x, z)
                fruitTypeIndex = tonumber(fruitTypeIndex)
                growthState = tonumber(growthState)
                local unknownFruit = FruitType ~= nil
                    and tonumber(FruitType.UNKNOWN) or 0
                if not ok then
                    probe.queryErrorSamples = probe.queryErrorSamples + 1
                elseif fruitTypeIndex == nil or fruitTypeIndex <= 0
                    or fruitTypeIndex == unknownFruit then
                    probe.noFruitSamples = probe.noFruitSamples + 1
                elseif hasAllowed and allowed[fruitTypeIndex] ~= true then
                    probe.disallowedFruitSamples =
                        probe.disallowedFruitSamples + 1
                elseif growthState == nil then
                    probe.missingGrowthSamples =
                        probe.missingGrowthSamples + 1
                elseif not isHarvestableProbe(
                        fruitTypeIndex, growthState,
                        useMinForageState) then
                    probe.unharvestableSamples =
                        probe.unharvestableSamples + 1
                else
                    probe.validFruitSamples = probe.validFruitSamples + 1
                    addSample(probe.cropCells, fruitTypeIndex)
                    probe.cropRawArea = probe.cropRawArea + sampleWeight
                    probe.cropProbeSamples = probe.cropProbeSamples + 1
                end
            end
        end
    end
    -- Reuse the existing footprint calculation for PF write attribution.
    probe.pfGeometry = {
        minX=math.min(sx,sx+widthX,sx+heightX,sx+widthX+heightX),
        maxX=math.max(sx,sx+widthX,sx+heightX,sx+widthX+heightX),
        minZ=math.min(sz,sz+widthZ,sz+heightZ,sz+widthZ+heightZ),
        maxZ=math.max(sz,sz+widthZ,sz+heightZ,sz+widthZ+heightZ)}
    return probe
end

function TerraLogicQualityManager:recordCutterAreaResult(
        cutter, probe, deltaArea, deltaMultiplierArea)
    if cutter == nil or probe == nil then return end
    deltaArea = math.max(tonumber(deltaArea) or 0, 0)
    deltaMultiplierArea = math.max(tonumber(deltaMultiplierArea) or 0, 0)
    local now = g_currentMission ~= nil and g_currentMission.time or 0
    local capture = cutter.terraLogicHarvestCapture
    if capture == nil or capture.time ~= now then
        local configured = cutter.spec_workArea ~= nil
            and #(cutter.spec_workArea.workAreas or {}) or 0
        capture = {
            time=now, cells={}, processedWorkAreas=0,
            successfulWorkAreas=0, configuredWorkAreas=configured,
            harvestedArea=0, multiplierArea=0, probeSamples=0,
            cropProbeSamples=0, queryErrorSamples=0, noFruitSamples=0,
            disallowedFruitSamples=0, missingGrowthSamples=0,
            unharvestableSamples=0, validFruitSamples=0,
            fallbackUsed=false, fallbackReason="none"
        }
        cutter.terraLogicHarvestCapture = capture
    end
    capture.processedWorkAreas = capture.processedWorkAreas + 1
    capture.probeSamples = capture.probeSamples + (probe.probeSamples or 0)
    capture.cropProbeSamples = capture.cropProbeSamples
        + (probe.cropProbeSamples or 0)
    for _, name in ipairs({
            "queryErrorSamples", "noFruitSamples",
            "disallowedFruitSamples", "missingGrowthSamples",
            "unharvestableSamples", "validFruitSamples"}) do
        capture[name] = (capture[name] or 0) + (probe[name] or 0)
    end
    if deltaArea <= 0 then return end
    capture.successfulWorkAreas = capture.successfulWorkAreas + 1
    capture.harvestedArea = capture.harvestedArea + deltaArea
    capture.multiplierArea = capture.multiplierArea + deltaMultiplierArea
    local source, rawTotal = probe.cropCells, probe.cropRawArea
    if rawTotal == nil or rawTotal <= 0 then
        source, rawTotal = probe.allCells, probe.rawArea
        capture.fallbackUsed = true
        capture.fallbackReason = "no_matching_pre_cut_crop_probe"
    end
    if rawTotal == nil or rawTotal <= 0 then return end
    for key, sample in pairs(source) do
        local share = (sample.rawWeight or 0) / rawTotal
        local entry = capture.cells[key]
        if entry == nil then
            entry = {
                ix=sample.ix, iz=sample.iz, chunkX=sample.chunkX,
                chunkZ=sample.chunkZ, chunkKey=sample.chunkKey,
                offset=sample.offset, areaWeight=0, multiplierWeight=0,
                fruitWeights={}
            }
            capture.cells[key] = entry
        end
        entry.areaWeight = entry.areaWeight + deltaArea * share
        entry.multiplierWeight = entry.multiplierWeight
            + deltaMultiplierArea * share
        for fruitTypeIndex, fruitWeight in pairs(sample.fruitWeights or {}) do
            entry.fruitWeights[fruitTypeIndex] =
                (entry.fruitWeights[fruitTypeIndex] or 0)
                + fruitWeight / rawTotal * deltaArea
        end
    end
end

local function appendCell(result, seen, x, z)
    local ix, iz = getCellIndex(x), getCellIndex(z)
    local cellKey = tostring(ix) .. ":" .. tostring(iz)
    if seen[cellKey] then return end
    local chunkX, chunkZ, chunkKey, offset = getChunkPosition(ix, iz)
    seen[cellKey] = true
    result[#result + 1] = {
        ix = ix, iz = iz, chunkX = chunkX, chunkZ = chunkZ,
        chunkKey = chunkKey, offset = offset
    }
end

function TerraLogicQualityManager:getTouchedCellsFromWorldParallelogram(
        sx, sz, wx, wz, hx, hz)
    if sx == nil or sz == nil or wx == nil or wz == nil
        or hx == nil or hz == nil then return {} end
    local widthX, widthZ = wx - sx, wz - sz
    local heightX, heightZ = hx - sx, hz - sz
    local width = math.sqrt(widthX * widthX + widthZ * widthZ)
    local depth = math.sqrt(heightX * heightX + heightZ * heightZ)
    local columns = math.max(1, math.ceil(width / self.CELL_SIZE))
    local rows = math.max(1, math.ceil(depth / self.CELL_SIZE))
    local result, seen = {}, {}
    for column = 0, columns do
        local u = columns > 0 and column / columns or 0.5
        for row = 0, rows do
            local v = rows > 0 and row / rows or 0.5
            local x = sx + widthX * u + heightX * v
            local z = sz + widthZ * u + heightZ * v
            appendCell(result, seen, x, z)
        end
    end
    return result
end

-- Rebuilds complete ledger positions from the exact cell keys captured inside
-- a Vanilla density-map callback.  This avoids intersecting those authoritative
-- cells with a second approximation of an implement's outer WorkArea geometry.
function TerraLogicQualityManager:getPositionsFromCellKeys(cellKeys)
    local result = {}
    for key, accepted in pairs(cellKeys or {}) do
        if accepted == true then
            local ixText, izText = string.match(
                tostring(key), "^(-?%d+):(-?%d+)$")
            local ix, iz = tonumber(ixText), tonumber(izText)
            if ix ~= nil and iz ~= nil then
                local chunkX, chunkZ, chunkKey, offset =
                    getChunkPosition(ix, iz)
                result[#result + 1] = {
                    ix=ix, iz=iz, chunkX=chunkX, chunkZ=chunkZ,
                    chunkKey=chunkKey, offset=offset
                }
            end
        end
    end
    return result
end

-- Converts a work-area parallelogram into stable map-aligned quality cells.
function TerraLogicQualityManager:getTouchedCells(workArea, includeApplicationWidth)
    local sx, sz, widthX, widthZ, heightX, heightZ = getAreaGeometry(workArea)
    if sx == nil then return {} end
    local result = self:getTouchedCellsFromWorldParallelogram(
        sx, sz, sx + widthX, sz + widthZ,
        sx + heightX, sz + heightZ)
    local seen = {}
    for _, cell in ipairs(result) do
        seen[tostring(cell.ix) .. ":" .. tostring(cell.iz)] = true
    end

    -- Centred broadcast spreaders describe their fan with the two outer
    -- nodes behind the start node. Sampling only the two start vectors can
    -- therefore miss the outer working width. Add the complete line between
    -- the outer nodes for application work areas. At 45 m this is only about
    -- twelve additional four-metre samples per processed area.
    if includeApplicationWidth then
        local wx, wz = sx + widthX, sz + widthZ
        local hx, hz = sx + heightX, sz + heightZ
        local pairs = {
            {sx, sz, wx, wz},
            {sx, sz, hx, hz},
            {wx, wz, hx, hz}
        }
        local widest, widestLength = nil, 0
        for _, pair in ipairs(pairs) do
            local dx, dz = pair[3] - pair[1], pair[4] - pair[2]
            local length = math.sqrt(dx * dx + dz * dz)
            if length > widestLength then
                widest, widestLength = pair, length
            end
        end
        if widest ~= nil and widestLength > 0.01 then
            local steps = math.max(1, math.ceil(widestLength / self.CELL_SIZE))
            for index = 0, steps do
                local t = index / steps
                appendCell(
                    result,
                    seen,
                    widest[1] + (widest[3] - widest[1]) * t,
                    widest[2] + (widest[4] - widest[2]) * t
                )
            end
        end
    end
    return result
end

-- Classifies arable land, field grass and natural meadow at a world position.
function TerraLogicQualityManager:getSurfaceTypeAtWorldPosition(x, z)
    local fruitTypeIndex = nil
    if FSDensityMapUtil ~= nil
        and FSDensityMapUtil.getFruitTypeIndexAtWorldPos ~= nil then
        fruitTypeIndex = FSDensityMapUtil.getFruitTypeIndexAtWorldPos(x, z)
    end
    local field = false
    if FSDensityMapUtil ~= nil
        and FSDensityMapUtil.getIsFieldAtWorldPos ~= nil then
        field = FSDensityMapUtil.getIsFieldAtWorldPos(x, z) == true
    else
        -- Compatibility fallback for maps that replace the standard helper.
        field = true
    end
    local isMeadow = fruitTypeIndex ~= nil and FruitType ~= nil
        and FruitType.MEADOW ~= nil and fruitTypeIndex == FruitType.MEADOW
    local isGrass = fruitTypeIndex ~= nil
        and FruitType ~= nil and FruitType.GRASS ~= nil
        and fruitTypeIndex == FruitType.GRASS
    -- A single density-map point can fall between grass blades and report no
    -- fruit even though the surrounding TerraLogic cell was successfully rolled.
    -- Confirm GRASS/MEADOW over a small footprint before rejecting the cell.
    if not isMeadow and not isGrass and FSDensityMapUtil ~= nil
        and FSDensityMapUtil.getFruitArea ~= nil and FruitType ~= nil then
        local halfSize = math.min(self.CELL_SIZE * 0.25, 1)
        local function hasFruitArea(fruitIndex)
            if fruitIndex == nil then return false end
            local ok, area = pcall(
                FSDensityMapUtil.getFruitArea,
                fruitIndex,
                x - halfSize, z - halfSize,
                x + halfSize, z - halfSize,
                x - halfSize, z + halfSize,
                true, true)
            return ok and (tonumber(area) or 0) > 0
        end
        isGrass = hasFruitArea(FruitType.GRASS)
        isMeadow = not isGrass and hasFruitArea(FruitType.MEADOW)
    end
    if isMeadow or isGrass then
        return field and "grassField" or "grass"
    end
    return field and "field" or "outside"
end

function TerraLogicQualityManager:isComponentAllowedAtCell(
        component, ix, iz, vehicle)
    local surface = self:getSurfaceTypeAtWorldPosition(
        (ix + 0.5) * self.CELL_SIZE,
        (iz + 0.5) * self.CELL_SIZE
    )
    if surface == "outside" or surface == "grass" then return false end

    local definition = self.COMPONENTS[component]
    local group = definition ~= nil and definition.group or component
    local rollerSpec = vehicle ~= nil and vehicle.spec_roller or nil
    if surface == "grassField" then
        if group == "fertilizer" then
            return true
        end
        -- Vanilla grass neither requires nor consumes lime. Precision Farming
        -- does model persistent pH depletion over several cuts, so only PF
        -- saves receive a grass-lime quality record.
        if group == "lime" then
            return TerraLogicMain ~= nil
                and TerraLogicMain.isPrecisionFarmingActive ~= nil
                and TerraLogicMain:isPrecisionFarmingActive()
        end
        -- Grass sown on a real field receives seed quality (and direct-drill
        -- soil preparation quality). They describe the persistent grass stand
        -- and therefore remain valid across regrowth until new tillage/reseeding
        -- overwrites them. Native changed-area checks still gate every write.
        if surface == "grassField"
            and (group == "seed" or group == "soil") then
            return true
        end
        -- Natural meadow was rejected above. Only a real grass field owns a
        -- persistent grass-roller ledger.
        return group == "roller"
            and (rollerSpec == nil or rollerSpec.isGrassRoller == true)
    end

    -- A grass-only roller must not leave soil-rolling quality on arable land.
    if group == "roller" and rollerSpec ~= nil
        and rollerSpec.isGrassRoller == true
        and rollerSpec.isSoilRoller ~= true then
        return false
    end
    return true
end

function TerraLogicQualityManager:getOrCreateChunk(chunkX, chunkZ, chunkKey)
    local chunk = self.chunks[chunkKey]
    if chunk == nil then
        chunk = newChunk(chunkX, chunkZ)
        self.chunks[chunkKey] = chunk
    end
    return chunk
end

function TerraLogicQualityManager:calculateYieldPenalty(
        quality, yieldWeight, maxYieldPenalty)
    local weight = math.max(tonumber(yieldWeight) or 0, 0)
    local maximum = math.clamp(tonumber(maxYieldPenalty) or 0, 0, 1)
    local workQuality = math.clamp(tonumber(quality) or 1, 0, 1)
    return math.min(weight * (1 - workQuality), maximum)
end

local function smoothStep01(value)
    value = math.clamp(tonumber(value) or 0, 0, 1)
    return value * value * (3 - 2 * value)
end

function TerraLogicQualityManager:getProtectedQualitySpeeds(realSpeed, shopSpeed)
    shopSpeed = math.max(tonumber(shopSpeed) or 0, 0.01)
    realSpeed = math.max(tonumber(realSpeed) or shopSpeed, 0.01)
    if shopSpeed < realSpeed then
        realSpeed = TerraLogicImplementProfiles
            .getLowShopSafeSpeed(shopSpeed)
    end
    return math.min(realSpeed, shopSpeed), shopSpeed
end

-- Returns the common speed/economy terms. `hourlyTarget` is deliberately the
-- value shown by the balancing HUD: below 1 means that speed cannot pay for
-- itself through increased field throughput alone.
-- Quality and economy model -------------------------------------------------

-- Calculates quality, time saving and profitability from the active speed.
function TerraLogicQualityManager:getSpeedEconomyForSpeeds(
        realSpeed, shopSpeed, currentSpeed, shopSpeedQuality)
    local protectedReal, protectedShop = self:getProtectedQualitySpeeds(
        realSpeed, shopSpeed)
    local speed = math.max(tonumber(currentSpeed) or 0, 0)
    local quality
    local qualityAtShop = math.clamp(tonumber(shopSpeedQuality)
        or self.QUALITY_AT_SHOP_SPEED, 0.90, 1.00)
    if speed <= protectedReal then
        quality = self.QUALITY_AT_REAL_SPEED
    elseif speed <= protectedShop then
        local span = math.max(protectedShop - protectedReal, 0.01)
        local t = (speed - protectedReal) / span
        quality = self.QUALITY_AT_REAL_SPEED
            - (self.QUALITY_AT_REAL_SPEED - qualityAtShop)
                * smoothStep01(t)
    else
        quality = qualityAtShop
    end

    local shopRatio = speed / protectedShop
    local overspeed = math.max(shopRatio - 1, 0)
    local hourlyTarget = shopRatio > 1
        and math.exp(-self.ECONOMY_CURVE_K * overspeed * overspeed)
        or shopRatio
    local areaRetention = shopRatio > 0
        and hourlyTarget / shopRatio or 1
    return {
        speed = speed,
        realSpeed = protectedReal,
        shopSpeed = protectedShop,
        shopRatio = shopRatio,
        overspeed = overspeed,
        timeSaved = shopRatio > 1 and 1 - 1 / shopRatio or 0,
        preShopQuality = math.clamp(quality, 0, 1),
        hourlyTarget = math.clamp(hourlyTarget, 0, 1),
        areaRetention = math.clamp(areaRetention, 0, 1)
    }
end

function TerraLogicQualityManager:getSpeedEconomy(vehicle, currentSpeed)
    local spec = vehicle ~= nil and vehicle.spec_terraLogic or nil
    local classKey = spec ~= nil and spec.implementClassKey or nil
    local profile = classKey ~= nil
        and TerraLogicImplementProfiles.PROFILES[classKey] or nil
    local work = profile ~= nil and profile.work or nil
    return self:getSpeedEconomyForSpeeds(
        spec ~= nil and spec.optimalSpeed or nil,
        spec ~= nil and spec.ratedSpeed or nil,
        currentSpeed,
        work ~= nil and work.shopSpeedQuality or nil)
end

-- Shared condition model for stored quality, physical misses and HUD. Slower
-- travel reduces bouncing and contact loss, but its capped recovery declines
-- with damage and never repairs the underlying mechanical condition.
function TerraLogicQualityManager:getSlowdownRecoveryProgress(
        vehicle, currentSpeed)
    local economy = self:getSpeedEconomy(vehicle, currentSpeed)
    if economy == nil or economy.shopSpeed <= economy.realSpeed + 0.01 then
        return 0
    end
    local progress = math.clamp(
        (economy.shopSpeed - math.max(tonumber(currentSpeed) or 0, 0))
            / math.max(economy.shopSpeed - economy.realSpeed, 0.01),
        0,
        1)
    return smoothStep01(progress)
end

-- SoilManager already evaluates the class-specific safe speed and performs
-- the one allowed slowdown recovery. Do not recover the same loss a second
-- time here; this function remains the common consumer/debug adapter.
function TerraLogicQualityManager:getMitigatedSoilSuitability(
        vehicle, currentSpeed, classKey)
    local qualityFactor, dropoutFraction, context = 1, 0, nil
    if TerraLogicSoilManager ~= nil then
        qualityFactor, dropoutFraction, context =
            TerraLogicSoilManager:getActiveSuitability(vehicle, classKey)
    end
    local rawQualityLoss = math.max(1-qualityFactor, 0)
    local rawDropout = math.clamp(dropoutFraction, 0, 1)
    local progress = context ~= nil
        and math.clamp(tonumber(context.suitabilitySlowRecovery) or 0, 0, 1)
        or 0
    return math.clamp(1-rawQualityLoss, 0, 1), rawDropout, context, {
            progress=progress,
            context=context,
            rawQualityFactor=qualityFactor,
            rawDropoutFraction=rawDropout,
            qualityRecoveryShare=0,
            dropoutRecoveryShare=0,
            recoveryAppliedBy="soil suitability profile"
        }
end

function TerraLogicQualityManager:getConditionQualityModel(vehicle, currentSpeed)
    local damage = vehicle ~= nil and vehicle.getDamageAmount ~= nil
        and math.clamp(tonumber(vehicle:getDamageAmount()) or 0, 0, 1) or 0
    local curve = self.CONDITION_QUALITY_CURVE
    local quality = 1
    if damage >= (tonumber(self.CONDITION_BROKEN_DAMAGE) or 0.9995) then
        quality = 0
    elseif curve ~= nil and #curve > 0 and damage > curve[1].damage then
        quality = curve[#curve].quality
        for index = 2, #curve do
            local lower, upper = curve[index - 1], curve[index]
            if damage <= upper.damage then
                local span = math.max(upper.damage - lower.damage, 0.0001)
                local t = math.clamp((damage - lower.damage) / span, 0, 1)
                local smooth = t * t * (3 - 2 * t)
                quality = lower.quality
                    + (upper.quality - lower.quality) * smooth
                break
            end
        end
    end
    quality = math.clamp(tonumber(quality) or 1, 0, 1)
    local basePenalty = 1 - quality
    local startDamage = tonumber(self.CONDITION_QUALITY_START_DAMAGE) or 0.75
    local progress = math.clamp(
        (damage - startDamage) / math.max(1 - startDamage, 0.01), 0, 1)
    local slowdownProgress = self:getSlowdownRecoveryProgress(
        vehicle, currentSpeed)
    local recoverableShare = damage >= self.CONDITION_BROKEN_DAMAGE and 0
        or self.SLOWDOWN_CONDITION_RECOVERY * (1-progress)
    local recovered = basePenalty * slowdownProgress * recoverableShare
    local penalty = math.clamp(basePenalty-recovered, 0, 1)
    quality = 1-penalty
    return quality, penalty, {
        damage = damage,
        progress = progress,
        baseLoss = basePenalty,
        recoveredLoss = recovered,
        speedRatio = currentSpeed,
        recoverySpeedRatio = slowdownProgress,
        speedLoad = 1-slowdownProgress,
        irrecoverableShare = progress,
        loadFactor = 1-slowdownProgress*recoverableShare,
        penalty = penalty,
        qualityFactor = quality,
        startDamage = startDamage
    }
end

function TerraLogicQualityManager:applyProductiveEconomy(economy, maximumPenalty)
    local cap = math.clamp(tonumber(maximumPenalty) or 0, 0, 1)
    local shopAreaFactor = 1 - cap * (1 - self.QUALITY_AT_SHOP_SPEED)
    local areaFactor, quality
    if economy.shopRatio <= 1 then
        quality = economy.preShopQuality
        areaFactor = 1 - cap * (1 - quality)
    else
        areaFactor = math.max(1 - cap,
            shopAreaFactor * economy.areaRetention)
        quality = cap > 0 and 1 - (1 - areaFactor) / cap or 1
    end
    quality = math.clamp(quality, 0, 1)
    local penalty = math.clamp(1 - areaFactor, 0, cap)
    return quality, penalty, areaFactor, shopAreaFactor
end

-- Starts continuously at full quality at shop speed, then bends smoothly
-- towards a class-specific lower bound. `additionalLoss`
-- is intentionally unbounded, so the curve never reaches a hard cap at a
-- finite speed but converges on the minimum at increasingly absurd speeds.
function TerraLogicQualityManager:approachMinimumQuality(
        minimumQuality, additionalLoss)
    local minimum = math.clamp(tonumber(minimumQuality) or 0, 0, 0.99)
    local shopQuality = self.QUALITY_AT_SHOP_SPEED
    local remainingRange = math.max(shopQuality - minimum, 0.0001)
    local loss = math.max(tonumber(additionalLoss) or 0, 0)
    return minimum + remainingRange * math.exp(-loss / remainingRange)
end

-- Converts the shared speed curve into one of the two gameplay effects.
-- Productive work may reduce the whole yield down to its category cap. Bonus
-- work can only remove the positive contribution passed in `bonusOverride`.
function TerraLogicQualityManager:getWorkQualityModel(
        vehicle, currentSpeed, component, bonusOverride,
        dropoutReductionAllowed)
    local definition = self.COMPONENTS[component]
        or self.GROUP_DEFINITIONS[component]
        or self.LIVE_COMPONENTS[component]
    local group = definition ~= nil and (definition.group or component)
        or component
    local economy = self:getSpeedEconomy(vehicle, currentSpeed)
    local bonusDefinition = self.BONUS_GROUPS[group]
    local quality, penalty, areaFactor, shopAreaFactor
    local vehicleSpec = vehicle ~= nil and vehicle.spec_terraLogic or nil
    local classKey = vehicleSpec ~= nil
        and vehicleSpec.implementClassKey or nil
    if component == "seed" and vehicleSpec ~= nil
        and vehicleSpec.seedSoilClassKey ~= nil then
        classKey = vehicleSpec.seedSoilClassKey
    end
    if vehicleSpec ~= nil
        and vehicleSpec.applicationSuitabilityClassKey ~= nil
        and (component == "fertilizer" or component == "lime"
            or component == "herbicide") then
        classKey = vehicleSpec.applicationSuitabilityClassKey
    end
    local minimumQuality = TerraLogicImplementProfiles
        .getMinimumWorkQuality(classKey, component)
    local isDirectDrillSoilPass = component == "soilCultivate"
        and vehicleSpec ~= nil
        and (vehicleSpec.implementClassKey == "directDrill"
            or vehicleSpec.implementClassKey == "precisionDirectDrill")
    local hasMatchingPhysicalDropouts =
        TerraLogicImplementProfiles.WORK_QUALITY_DROPOUT_COMPONENTS[
            component
        ] == true or isDirectDrillSoilPass
    local dropoutOverspeedShare = 1
    if economy.shopRatio > 1 and dropoutReductionAllowed ~= false
        and TerraLogicSettings ~= nil
        and TerraLogicSettings:getPhysicalDropoutsEnabled()
        and hasMatchingPhysicalDropouts then
        dropoutOverspeedShare = math.clamp(
            tonumber(TerraLogicImplementProfiles
                .WORK_QUALITY_DROPOUT_OVERSPEED_SHARE) or 0.30,
            0,
            1
        )
    end
    local conditionQuality, conditionPenalty, condition =
        self:getConditionQualityModel(vehicle, currentSpeed)

    if bonusDefinition ~= nil then
        local bonus = math.max(tonumber(bonusOverride)
            or bonusDefinition.bonus or 0, 0)
        local totalAtShop = 1 + bonus * self.QUALITY_AT_SHOP_SPEED
        local totalNow
        if economy.shopRatio <= 1 then
            quality = economy.preShopQuality
            totalNow = 1 + bonus * quality
        elseif tonumber(bonusDefinition.rateLimitedRange) ~= nil
            and minimumQuality ~= nil then
            -- Application equipment has a limited mass/volume flow. Slightly
            -- exceeding shop speed therefore under-applies gently. The
            -- squared demand is flat at shop speed, while the exponential
            -- envelope prevents an abrupt total loss at high overspeed.
            local range = math.max(
                tonumber(bonusDefinition.rateLimitedRange) or 0.80, 0.01)
            local t = economy.overspeed / range
            local additionalLoss = self.QUALITY_AT_SHOP_SPEED
                * 2 * t * t * dropoutOverspeedShare
            quality = self:approachMinimumQuality(
                minimumQuality, additionalLoss)
            totalNow = 1 + bonus * quality
            economy.rateLimitedCurve = true
            economy.rateLimitedRange = range
        elseif (tonumber(bonusDefinition.bonus) or 0) <= 0.05
            and minimumQuality ~= nil then
            -- A 2.5% roller/mulcher bonus is smaller than almost every useful
            -- overspeed time saving. Strict hourly break-even would therefore
            -- collapse quality to zero almost immediately. Keep these tiny
            -- optional bonuses readable and smooth; wear/impacts still punish
            -- speed and the balancing HUD may honestly report it as profitable.
            local additionalLoss = 4.05
                * economy.overspeed * economy.overspeed
            quality = self:approachMinimumQuality(
                minimumQuality, additionalLoss)
            totalNow = 1 + bonus * quality
            economy.microBonusCurve = true
        else
            totalNow = math.max(1, totalAtShop * economy.areaRetention)
            quality = bonus > 0 and (totalNow - 1) / bonus or 1
        end
        quality = math.clamp(quality, 0, 1)
        if dropoutOverspeedShare < 1 and minimumQuality == nil then
            quality = math.clamp(
                self.QUALITY_AT_SHOP_SPEED
                    - (self.QUALITY_AT_SHOP_SPEED - quality)
                        * dropoutOverspeedShare,
                0,
                1
            )
            totalNow = 1 + bonus * quality
        end
        areaFactor = totalNow / math.max(1 + bonus, 0.0001)
        shopAreaFactor = totalAtShop / math.max(1 + bonus, 0.0001)
        penalty = math.clamp(1 - areaFactor, 0, 1)
        economy.effectType = "bonus"
        economy.bonus = bonus
        economy.bonusFloorReached = minimumQuality ~= nil
            and quality <= minimumQuality + 0.00001
            or totalNow <= 1.00001
    else
        local cap = math.clamp(definition ~= nil
            and definition.maxYieldPenalty or 0, 0, 1)
        if economy.shopRatio > 1 and minimumQuality ~= nil and cap > 0 then
            shopAreaFactor = 1 - cap
                * (1 - self.QUALITY_AT_SHOP_SPEED)
            -- -log(retention) follows the old economy curve at mild overspeed
            -- but keeps growing after the former hard yield cap was reached.
            local retention = math.max(economy.areaRetention, 0.000000001)
            local additionalLoss = shopAreaFactor / cap
                * (-math.log(retention)) * dropoutOverspeedShare
            quality = self:approachMinimumQuality(
                minimumQuality, additionalLoss)
            areaFactor = 1 - cap * (1 - quality)
            penalty = math.clamp(1 - areaFactor, 0, cap)
            economy.minimumEnvelopeCurve = true
        else
            quality, penalty, areaFactor, shopAreaFactor =
                self:applyProductiveEconomy(economy, cap)
        end
        if dropoutOverspeedShare < 1 and minimumQuality == nil then
            areaFactor = math.clamp(
                shopAreaFactor
                    - (shopAreaFactor - areaFactor)
                        * dropoutOverspeedShare,
                1 - cap,
                1
            )
            quality = cap > 0
                and 1 - (1 - areaFactor) / cap or 1
            quality = math.clamp(quality, 0, 1)
            penalty = math.clamp(1 - areaFactor, 0, cap)
        end
        economy.effectType = "wholeYield"
        economy.maximumPenalty = cap
        economy.penaltyFloorReached = minimumQuality ~= nil
            and quality <= minimumQuality + 0.00001
            or areaFactor <= 1 - cap + 0.00001
    end

    -- Seed placement above shop speed follows an agronomic response rather
    -- than the generic yield-per-hour break-even envelope. Modern metering
    -- systems first lose spacing/depth accuracy and only collapse at extreme
    -- speed; true missing seed remains the separate physical dropout model.
    if component == "seed" and economy.shopRatio > 1 then
        local classProfile = classKey ~= nil
            and TerraLogicImplementProfiles.PROFILES[classKey] or nil
        local workProfile = classProfile ~= nil and classProfile.work or nil
        if workProfile ~= nil
            and workProfile.seedOverspeedMinimum ~= nil then
            local failedRatio = math.max(
                tonumber(workProfile.seedFailedRatio) or 2, 1.10)
            local progress = math.clamp((economy.shopRatio-1)
                / (failedRatio-1), 0, 1)
            local exponent = math.max(
                tonumber(workProfile.seedOverspeedExponent) or 1.25, 0.5)
            local shopQuality = math.clamp(
                tonumber(workProfile.shopSpeedQuality)
                    or self.QUALITY_AT_SHOP_SPEED, 0, 1)
            local minimum = math.clamp(
                tonumber(workProfile.seedOverspeedMinimum) or 0.15, 0, 0.90)
            quality = shopQuality
                - (shopQuality-minimum) * progress ^ exponent
            local cap = math.clamp(definition ~= nil
                and definition.maxYieldPenalty or 0, 0, 1)
            areaFactor = 1-cap*(1-quality)
            shopAreaFactor = 1-cap*(1-shopQuality)
            penalty = math.clamp(1-areaFactor, 0, cap)
            economy.seedPlacementCurve = true
        end
    end

    local qualityBeforeCondition = math.clamp(quality, 0, 1)
    -- Condition remains a ceiling rather than another multiplicative loss.
    -- The model above may lift only its motion-dependent share at low speed;
    -- overspeed can still produce an even lower value.
    quality = math.min(qualityBeforeCondition, conditionQuality)
    local qualityBeforeSoil = quality
    local soilQualityFactor, soilDropoutFraction, soilContext = 1, 0, nil
    local soilComponentAllowed = classKey == "plow" and component == "soilPlow"
        or (classKey == "subsoiler" or classKey == "cultivator"
            or classKey == "shallowCultivator" or classKey == "discHarrow"
            or classKey == "powerHarrow" or classKey == "spader"
            or classKey == "ridgeFormer")
            and component == "soilCultivate"
        or (classKey == "sowingMachine" or classKey == "directDrill"
            or classKey == "precisionPlanter"
            or classKey == "precisionDirectDrill"
            or TerraLogicSpecialImplements.SEED_CLASSES[classKey]) and component == "seed"
        or classKey == "roller" and component == "roller"
        or classKey == "mulcher" and component == "mulch"
        or classKey == "mower" and component == "mower"
        or (classKey == "liquidSprayer" or classKey == "fertilizerSpreader"
            or classKey == "manureSpreader" or classKey == "slurrySpreader"
            or classKey == "slurryApplicator"
            or classKey == "slurryInjector")
            and (component == "fertilizer" or component == "lime"
                or component == "herbicide")
    if TerraLogicSoilManager ~= nil and soilComponentAllowed then
        soilQualityFactor, soilDropoutFraction, soilContext,
            economy.soilMitigation = self:getMitigatedSoilSuitability(
                vehicle, currentSpeed, classKey)
    end
    quality = math.clamp(quality * soilQualityFactor, 0, 1)
    local qualityBeforeRain = quality
    local herbicideRain = nil
    if component == "herbicide"
        and TerraLogicSoilMoistureManager ~= nil
        and TerraLogicSoilMoistureManager.getHerbicideRainResponse ~= nil then
        herbicideRain = TerraLogicSoilMoistureManager:
            getHerbicideRainResponse()
        quality = math.clamp(quality
            * (tonumber(herbicideRain.qualityFactor) or 1), 0, 1)
    end
    if bonusDefinition ~= nil then
        local bonus = math.max(tonumber(bonusOverride)
            or bonusDefinition.bonus or 0, 0)
        local totalNow = 1 + bonus * quality
        areaFactor = totalNow / math.max(1 + bonus, 0.0001)
        penalty = math.clamp(1 - areaFactor, 0, 1)
    else
        local cap = math.clamp(definition ~= nil
            and definition.maxYieldPenalty or 0, 0, 1)
        areaFactor = 1 - cap * (1 - quality)
        penalty = math.clamp(1 - areaFactor, 0, cap)
    end

    -- Some operations now describe or alter physical field state instead of
    -- owning an additional harvest ledger. Keep their Work Quality visible,
    -- but return an explicitly yield-neutral economic result so callers and
    -- diagnostics cannot accidentally reintroduce the former double charge.
    if definition ~= nil and definition.affectsYield == false then
        penalty = 0
        areaFactor = 1
        economy.yieldNeutral = true
    end

    economy.quality = quality
    economy.minimumQuality = minimumQuality
    economy.dropoutWorkQualityOverspeedShare = dropoutOverspeedShare
    economy.yieldPenalty = penalty
    economy.areaFactor = areaFactor
    economy.shopAreaFactor = shopAreaFactor
    economy.profitabilityIndex = economy.shopRatio
        * areaFactor / math.max(shopAreaFactor, 0.0001)
    economy.qualityBeforeCondition = qualityBeforeCondition
    economy.conditionQualityFactor = conditionQuality
    economy.conditionQualityPenalty = conditionPenalty
    economy.conditionQualityLoss = math.max(
        qualityBeforeCondition - qualityBeforeSoil, 0)
    economy.conditionFullPenalty = conditionPenalty
    economy.conditionPhysicalShare = 1
    economy.conditionDamage = condition.damage
    economy.conditionProgress = condition.progress
    economy.conditionLoadFactor = condition.loadFactor
    economy.qualityBeforeSoil = qualityBeforeSoil
    economy.soilQualityFactor = soilQualityFactor
    economy.soilQualityLoss = math.max(qualityBeforeSoil - quality, 0)
    economy.soilDropoutFraction = soilDropoutFraction
    economy.herbicideRainSeverity = herbicideRain ~= nil
        and (tonumber(herbicideRain.severity) or 0) or 0
    economy.herbicideRainIntensity = herbicideRain ~= nil
        and (tonumber(herbicideRain.rainIntensity) or 0) or 0
    economy.herbicideRainQualityFactor = herbicideRain ~= nil
        and (tonumber(herbicideRain.qualityFactor) or 1) or 1
    economy.herbicideRainQualityLoss = math.max(qualityBeforeRain-quality, 0)
    economy.herbicideRainDropoutFraction = herbicideRain ~= nil
        and (tonumber(herbicideRain.dropoutFraction) or 0) or 0
    economy.frostSeverity = soilContext ~= nil
        and (tonumber(soilContext.frostSeverity) or 0) or 0
    economy.frostQualityFactor = soilContext ~= nil
        and (tonumber(soilContext.frostQualityFactor) or 1) or 1
    economy.frostPenetrationFactor = soilContext ~= nil
        and (tonumber(soilContext.frostPenetrationFactor) or 1) or 1
    economy.frostDropoutFraction = soilContext ~= nil
        and (tonumber(soilContext.frostDropoutFraction) or 0) or 0
    economy.soilSuitabilityClass = soilContext ~= nil
        and soilContext.classKey or nil
    economy.soilSuitabilityCells = soilContext ~= nil
        and soilContext.eligibleCells or 0
    return quality, penalty, economy
end

-- Quality ledger ------------------------------------------------------------

local PLOW_GROWTH_BASE_LAYER = "plowGrowthBase"
local PLOW_GROWTH_STEP_LAYER = "plowGrowthSteps"
-- The root-yield ledger uses three semantic growth windows. Raw fruit density
-- states are not equal
-- agronomic periods and differ between crops; green-small, green-middle/big
-- and harvest-ready give every crop three comparable shares of potential
-- yield while still reacting only to genuine growth transitions.
local CROP_GROWTH_BASE_LAYER = "cropGrowthBase"
local CROP_GROWTH_STEP_LAYER = "cropGrowthSteps"
local CROP_ROOT_YIELD_LAYER = "cropRootYield"
local CROP_MOISTURE_YIELD_LAYER = "cropMoistureYield"
local CROP_MOISTURE_PERIOD_LAYER = "cropMoisturePeriod"
local PLOW_GROWTH_SAMPLE_OFFSETS = {
    {0, 0}, {-0.25, -0.25}, {0.25, -0.25},
    {-0.25, 0.25}, {0.25, 0.25}
}

-- getFruitArea deliberately follows harvest/forage state rules and therefore
-- reports no area for many freshly sown crops. Root history instead needs a
-- state-independent occupancy test. Probe the same 1 m centres used by the
-- spatial soil integration and retain only the latest cell so the immediate
-- getGrowthStateAtCell -> root-factor sequence does not query it twice.
local function probeCropOccupancyCell(manager, ix, iz)
    local now = g_currentMission ~= nil and (g_currentMission.time or 0) or 0
    local cached = manager.lastCropOccupancyProbe
    if cached ~= nil and cached.ix == ix and cached.iz == iz
        and cached.time == now then
        return cached
    end
    local result = {
        ix=ix, iz=iz, time=now, valid=true, samples={}, total=0,
        dominantFruit=nil, dominantGrowth=nil
    }
    if FSDensityMapUtil == nil
        or FSDensityMapUtil.getFruitTypeIndexAtWorldPos == nil then
        result.valid = false
        manager.lastCropOccupancyProbe = result
        return result
    end
    local sampleStep = manager.CELL_SIZE / 4
    local minX = ix * manager.CELL_SIZE
    local minZ = iz * manager.CELL_SIZE
    local fruitCounts, growthCounts = {}, {}
    for sampleZ=0,3 do
        for sampleX=0,3 do
            local x = minX + (sampleX + 0.5) * sampleStep
            local z = minZ + (sampleZ + 0.5) * sampleStep
            local ok, fruitTypeIndex, growthState = pcall(
                FSDensityMapUtil.getFruitTypeIndexAtWorldPos, x, z)
            if not ok then result.valid = false end
            fruitTypeIndex = tonumber(fruitTypeIndex)
            growthState = tonumber(growthState)
            result.total = result.total + 1
            result.samples[#result.samples + 1] = {
                x=x, z=z, fruitTypeIndex=fruitTypeIndex,
                growthState=growthState,
                quadrant=math.floor(sampleX / 2)
                    + math.floor(sampleZ / 2) * 2 + 1
            }
            if ok and fruitTypeIndex ~= nil and growthState ~= nil then
                fruitCounts[fruitTypeIndex] =
                    (fruitCounts[fruitTypeIndex] or 0) + 1
                growthCounts[fruitTypeIndex] =
                    growthCounts[fruitTypeIndex] or {}
                growthCounts[fruitTypeIndex][growthState] =
                    (growthCounts[fruitTypeIndex][growthState] or 0) + 1
            end
        end
    end
    local dominantCount = 0
    for fruitTypeIndex, count in pairs(fruitCounts) do
        if count > dominantCount then
            dominantCount = count
            result.dominantFruit = fruitTypeIndex
        end
    end
    if result.dominantFruit ~= nil then
        local dominantGrowthCount = 0
        for growthState, count in pairs(
                growthCounts[result.dominantFruit] or {}) do
            if count > dominantGrowthCount
                or (count == dominantGrowthCount
                    and (result.dominantGrowth == nil
                        or growthState > result.dominantGrowth)) then
                dominantGrowthCount = count
                result.dominantGrowth = growthState
            end
        end
    end
    manager.lastCropOccupancyProbe = result
    return result
end

-- Read-only occupancy access for field summaries. No new persistent raster.
function TerraLogicQualityManager:getAnalysisCropSamples(ix, iz)
    local probe = probeCropOccupancyCell(self, ix, iz)
    return probe.valid and probe.samples or {}, probe.valid
end

function TerraLogicQualityManager:getGrowthStateAtCell(ix, iz)
    if FSDensityMapUtil == nil
        or FSDensityMapUtil.getFruitTypeIndexAtWorldPos == nil then
        return nil, nil
    end
    local x = (ix + 0.5) * self.CELL_SIZE
    local z = (iz + 0.5) * self.CELL_SIZE
    for _, sample in ipairs(PLOW_GROWTH_SAMPLE_OFFSETS) do
        local ok, fruitTypeIndex, growthState = pcall(
            FSDensityMapUtil.getFruitTypeIndexAtWorldPos,
            x + sample[1] * self.CELL_SIZE,
            z + sample[2] * self.CELL_SIZE)
        if ok and tonumber(growthState) ~= nil then
            return tonumber(fruitTypeIndex), tonumber(growthState)
        end
    end
    -- A narrow tramline can cover all five quick probes while crop still grows
    -- in the remainder of this 4 m history cell. Use the complete occupancy
    -- lattice only as that exceptional fallback.
    local occupancy = probeCropOccupancyCell(self, ix, iz)
    return occupancy.valid and occupancy.dominantFruit or nil,
        occupancy.valid and occupancy.dominantGrowth or nil
end

function TerraLogicQualityManager:getPlowGrowthStateMap(fruitTypeIndex)
    fruitTypeIndex = tonumber(fruitTypeIndex)
    if fruitTypeIndex == nil or g_fruitTypeManager == nil
        or g_fruitTypeManager.getFruitTypeByIndex == nil then return nil end
    self.plowGrowthStateMaps = self.plowGrowthStateMaps or {}
    local cached = self.plowGrowthStateMaps[fruitTypeIndex]
    if cached ~= nil then return cached ~= false and cached or nil end
    local desc = g_fruitTypeManager:getFruitTypeByIndex(fruitTypeIndex)
    if desc == nil then
        self.plowGrowthStateMaps[fruitTypeIndex] = false
        return nil
    end
    local map = {
        stages = {},
        minHarvest = tonumber(desc.minHarvestingGrowthState),
        maxHarvest = tonumber(desc.maxHarvestingGrowthState)
    }
    -- Oilseed radish uses a terminal withered state as its incorporation-ready
    -- state. Complete its one growth cycle, but never treat ordinary withered
    -- cash crops as successfully matured crops.
    local isOilseedRadish = string.lower(tostring(desc.name or ""))
        :gsub("[^%a]", "") == "oilseedradish"
    -- Fruit XMLs use different numbers of internal states. Classify their
    -- named visual phases instead of assuming that every crop advances by the
    -- same raw density-map distance. Prefix matching also covers variants such
    -- as greenSmall3, greenMiddleSecond and greenBig4.
    for state, name in pairs(desc.growthStateToName or {}) do
        state = tonumber(state)
        local normalized = string.lower(tostring(name or ""))
        local stage
        if isOilseedRadish and state ~= nil
            and (state == tonumber(desc.witheredState)
                or string.find(normalized, "withered", 1, true) ~= nil) then
            stage = self.PLOW_GROWTH_STAGES
        elseif state ~= nil and map.minHarvest ~= nil
            and map.minHarvest > 0 and state >= map.minHarvest
            and state <= (map.maxHarvest or map.minHarvest) then
            stage = self.PLOW_GROWTH_STAGES
        elseif string.find(normalized, "greensmall", 1, true) ~= nil then
            stage = 1
        elseif string.find(normalized, "greenmiddle", 1, true) ~= nil
            or string.find(normalized, "greenbig", 1, true) ~= nil then
            stage = 2
        elseif (map.minHarvest == nil or map.minHarvest <= 0)
            and string.find(normalized, "harvestready", 1, true) ~= nil then
            stage = self.PLOW_GROWTH_STAGES
        end
        if state ~= nil and stage ~= nil then map.stages[state] = stage end
    end
    if isOilseedRadish and tonumber(desc.witheredState) ~= nil then
        map.stages[tonumber(desc.witheredState)] = self.PLOW_GROWTH_STAGES
    end
    self.plowGrowthStateMaps[fruitTypeIndex] = map
    return map
end

-- Density-map states are not consecutive visible growth stages. Wheat, for
-- example, may use greenSmall=2, greenBig=6 and harvestReady=8, and growth
-- calendar mods can jump directly between them. Prefer the named phases and
-- use normalized progress only as a compatibility fallback for custom crops.
function TerraLogicQualityManager:getSemanticPlowGrowthStage(
        fruitTypeIndex, growthState, baseState)
    growthState = tonumber(growthState)
    baseState = tonumber(baseState)
    if growthState == nil then return 0 end
    -- Some crops (for example rice) are sown directly into a named visible
    -- state. Merely observing that unchanged starting state is not growth.
    if baseState ~= nil and growthState == baseState then return 0 end
    local stateMap = self:getPlowGrowthStateMap(fruitTypeIndex)
    if stateMap ~= nil then
        local namedStage = stateMap.stages[growthState]
        if namedStage ~= nil then return namedStage end
        local minHarvest = stateMap.minHarvest
        local maxHarvest = stateMap.maxHarvest or minHarvest
        if minHarvest ~= nil and growthState >= minHarvest
            and growthState <= maxHarvest then return self.PLOW_GROWTH_STAGES end
        local startState = baseState or 1
        if minHarvest ~= nil and minHarvest > startState
            and growthState > startState and growthState < minHarvest then
            local progress = (growthState - startState)
                / (minHarvest - startState)
            return math.clamp(math.floor(
                progress * self.PLOW_GROWTH_STAGES + 0.5), 1,
                self.PLOW_GROWTH_STAGES - 1)
        end
    end
    if baseState ~= nil and growthState > baseState then
        return math.clamp(growthState - baseState, 1,
            self.PLOW_GROWTH_STAGES - 1)
    end
    return 0
end

function TerraLogicQualityManager:clearPlowGrowthCycleAtOffset(chunk, offset)
    if chunk == nil then return false end
    local changed = false
    for _, name in ipairs({PLOW_GROWTH_BASE_LAYER, PLOW_GROWTH_STEP_LAYER}) do
        local layer = chunk.counts[name]
        if layer ~= nil then
            changed = setLayerByte(layer, offset, 0) or changed
            if layer.nonDefaultCount == 0 then chunk.counts[name] = nil end
        end
    end
    return changed
end

function TerraLogicQualityManager:clearCropGrowthCycleAtOffset(chunk, offset)
    if chunk == nil then return false end
    local changed = false
    for _, name in ipairs({
            CROP_GROWTH_BASE_LAYER, CROP_GROWTH_STEP_LAYER,
            CROP_ROOT_YIELD_LAYER, CROP_MOISTURE_YIELD_LAYER,
            CROP_MOISTURE_PERIOD_LAYER
        }) do
        local layer = chunk.counts[name]
        if layer ~= nil then
            changed = setLayerByte(layer, offset, 0) or changed
            if layer.nonDefaultCount == 0 then chunk.counts[name] = nil end
        end
    end
    return changed
end

function TerraLogicQualityManager:beginCropGrowthCycle(ix, iz)
    local _, _, chunkKey, offset = getChunkPosition(ix, iz)
    local chunk = self.chunks[chunkKey]
    if chunk == nil then return false end
    local mask = getLayerByte(chunk.status, offset)
    if not hasBit(mask, self.COMPONENTS.seed.bit) then
        return self:clearCropGrowthCycleAtOffset(chunk, offset)
    end
    local _, growthState = self:getGrowthStateAtCell(ix, iz)
    growthState = growthState or 1
    local baseLayer = chunk.counts[CROP_GROWTH_BASE_LAYER]
    if baseLayer == nil then
        baseLayer = newLayer(0, ZERO_DATA)
        chunk.counts[CROP_GROWTH_BASE_LAYER] = baseLayer
    end
    local stepLayer = chunk.counts[CROP_GROWTH_STEP_LAYER]
    if stepLayer == nil then
        stepLayer = newLayer(0, ZERO_DATA)
        chunk.counts[CROP_GROWTH_STEP_LAYER] = stepLayer
    end
    local changed = setLayerByte(baseLayer, offset,
        math.clamp(math.floor(growthState + 1), 1, 255))
    changed = setLayerByte(stepLayer, offset, 0) or changed
    local yieldLayer = chunk.counts[CROP_ROOT_YIELD_LAYER]
    if yieldLayer ~= nil then
        changed = setLayerByte(yieldLayer, offset, 0) or changed
        if yieldLayer.nonDefaultCount == 0 then
            chunk.counts[CROP_ROOT_YIELD_LAYER] = nil
        end
    end
    local moistureLayer = chunk.counts[CROP_MOISTURE_YIELD_LAYER]
    if moistureLayer ~= nil then
        changed = setLayerByte(moistureLayer, offset, 0) or changed
        if moistureLayer.nonDefaultCount == 0 then
            chunk.counts[CROP_MOISTURE_YIELD_LAYER] = nil
        end
    end
    local periodLayer = chunk.counts[CROP_MOISTURE_PERIOD_LAYER]
    if periodLayer == nil then
        periodLayer = newLayer(0, ZERO_DATA)
        chunk.counts[CROP_MOISTURE_PERIOD_LAYER] = periodLayer
    end
    local periodMarker = TerraLogicSoilMoistureManager ~= nil
        and TerraLogicSoilMoistureManager.encodePeriodMarker ~= nil
        and TerraLogicSoilMoistureManager:encodePeriodMarker(
            TerraLogicSoilMoistureManager:getPeriodSerial()) or 1
    changed = setLayerByte(
        periodLayer, offset, periodMarker) or changed
    return changed
end

-- Crop history remains stored in 4 m cells, but roots only experience the
-- soil below plants that actually exist. The 1 m crop probes match the spatial
-- soil samples exactly, preserving the relationship between a tyre track, an
-- unsown lane and the roots beside it at every visible growth state.
function TerraLogicQualityManager:getCropWeightedRootYieldFactor(
        ix, iz, fruitTypeIndex, sampleFilter)
    local x = (ix + 0.5) * self.CELL_SIZE
    local z = (iz + 0.5) * self.CELL_SIZE
    local fallbackFactor, fallbackSurfaceLoss, fallbackDeepLoss = 1, 0, 0
    if TerraLogicSoilManager ~= nil then
        fallbackFactor, fallbackSurfaceLoss, fallbackDeepLoss =
            TerraLogicSoilManager:getRootYieldFactorForArea(
                x, z, self.CELL_SIZE)
    end
    if fruitTypeIndex == nil or TerraLogicSoilManager == nil then
        return fallbackFactor, 1, false,
            fallbackSurfaceLoss, fallbackDeepLoss, 0
    end
    local weightedFactor, weightedSurfaceLoss, weightedDeepLoss = 0, 0, 0
    local occupancy = probeCropOccupancyCell(self, ix, iz)
    if not occupancy.valid then
        return fallbackFactor, 1, false,
            fallbackSurfaceLoss, fallbackDeepLoss, 0
    end
    local cropSamples, occupiedQuadrantSet = 0, {}
    for _, sample in ipairs(occupancy.samples) do
        if sample.fruitTypeIndex == fruitTypeIndex
            and sample.growthState ~= nil
            and (sampleFilter == nil or sampleFilter(sample.fruitTypeIndex,
                sample.growthState, sample.x, sample.z)) then
            local factor, surfaceLoss, deepLoss = TerraLogicSoilManager:
                getRootYieldFactorAtWorldPosition(sample.x, sample.z)
            weightedFactor = weightedFactor
                + math.clamp(tonumber(factor) or 1, 0, 1)
            weightedSurfaceLoss = weightedSurfaceLoss
                + math.clamp(tonumber(surfaceLoss) or 0, 0, 1)
            weightedDeepLoss = weightedDeepLoss
                + math.clamp(tonumber(deepLoss) or 0, 0, 1)
            cropSamples = cropSamples + 1
            occupiedQuadrantSet[sample.quadrant] = true
        end
    end
    -- A quick point sample found this crop, so a zero-occupancy lattice is most
    -- likely a transient or custom-fruit incompatibility. Keep the prior safe
    -- behaviour instead of granting a neutral root score.
    if cropSamples <= 0 or occupancy.total <= 0 then
        return fallbackFactor, 0, false,
            fallbackSurfaceLoss, fallbackDeepLoss, 0
    end
    local occupiedQuadrants = 0
    for _ in pairs(occupiedQuadrantSet) do
        occupiedQuadrants = occupiedQuadrants + 1
    end
    return weightedFactor / cropSamples,
        cropSamples / occupancy.total, true,
        weightedSurfaceLoss / cropSamples,
        weightedDeepLoss / cropSamples,
        occupiedQuadrants
end

function TerraLogicQualityManager:processCropGrowthCell(
        chunk, chunkKey, offset)
    local mask = getLayerByte(chunk.status, offset)
    if not hasBit(mask, self.COMPONENTS.seed.bit) then return false end
    local baseLayer = chunk.counts[CROP_GROWTH_BASE_LAYER]
    if baseLayer == nil then return false end
    local baseEncoded = getLayerByte(baseLayer, offset)
    if baseEncoded <= 0 then return false end
    local zeroOffset = offset - 1
    local position = {
        ix = chunk.x * self.CHUNK_SIZE + zeroOffset % self.CHUNK_SIZE,
        iz = chunk.z * self.CHUNK_SIZE
            + math.floor(zeroOffset / self.CHUNK_SIZE),
        chunkKey = chunkKey,
        offset = offset
    }
    local fruitTypeIndex, growthState = self:getGrowthStateAtCell(
        position.ix, position.iz)
    if growthState == nil then return false end
    local desiredSteps = self:getSemanticPlowGrowthStage(
        fruitTypeIndex, growthState, baseEncoded - 1)
    local stepLayer = chunk.counts[CROP_GROWTH_STEP_LAYER]
    local completedSteps = stepLayer ~= nil
        and math.clamp(getLayerByte(stepLayer, offset),
            0, self.PLOW_GROWTH_STAGES) or 0
    if desiredSteps <= completedSteps then return false end

    -- The soil at each genuine transition owns one equal share of potential
    -- root yield. If a calendar mod skips visible states, the current sample
    -- fills every skipped window; this is conservative and deterministic.
    local x = (position.ix + 0.5) * self.CELL_SIZE
    local z = (position.iz + 0.5) * self.CELL_SIZE
    local rootFactor, cropCoverage =
        self:getCropWeightedRootYieldFactor(
            position.ix, position.iz, fruitTypeIndex)
    rootFactor = math.clamp(tonumber(rootFactor) or 1, 0, 1)
    local yieldLayer = chunk.counts[CROP_ROOT_YIELD_LAYER]
    local oldAverage = 1
    if completedSteps > 0 and yieldLayer ~= nil then
        oldAverage = getLayerByte(yieldLayer, offset) / 255
    end
    local newAverage = (oldAverage * completedSteps
        + rootFactor * (desiredSteps - completedSteps))
        / math.max(desiredSteps, 1)
    if yieldLayer == nil then
        yieldLayer = newLayer(0, ZERO_DATA)
        chunk.counts[CROP_ROOT_YIELD_LAYER] = yieldLayer
    end
    local changed = setLayerByte(yieldLayer, offset,
        math.clamp(math.floor(newAverage * 255 + 0.5), 1, 255))

    -- Moisture is recorded even while its gameplay option is disabled. This
    -- keeps the crop history honest when an admin changes the option and
    -- avoids creating a free reset exploit. Each crop may weight its three
    -- biological windows differently while still using only one byte/cell.
    if TerraLogicSoilMoistureManager ~= nil
        and TerraLogicSoilMoistureManager.getCropYieldResponse ~= nil then
        local soilTypeIndex = TerraLogicSoilManager ~= nil
            and TerraLogicSoilManager.getPFSoilTypeAtWorldPosition ~= nil
            and TerraLogicSoilManager:getPFSoilTypeAtWorldPosition(x, z) or nil
        local moistureLayer = chunk.counts[CROP_MOISTURE_YIELD_LAYER]
        local periodLayer = chunk.counts[CROP_MOISTURE_PERIOD_LAYER]
        local currentPeriod = TerraLogicSoilMoistureManager:getPeriodSerial()
        local startPeriod = periodLayer ~= nil
            and TerraLogicSoilMoistureManager:decodePeriodMarker(
                getLayerByte(periodLayer, offset)) or nil
        local oldMoistureAverage = 1
        if completedSteps > 0 and moistureLayer ~= nil then
            oldMoistureAverage = getLayerByte(moistureLayer, offset) / 255
        end
        local oldWeight, addedWeight, addedWeighted = 0, 0, 0
        for sampleStage = 1, desiredSteps do
            local response
            if sampleStage > completedSteps
                and startPeriod ~= nil
                and TerraLogicSoilMoistureManager.
                    getCropYieldResponseForPeriodRange ~= nil then
                response = TerraLogicSoilMoistureManager:
                    getCropYieldResponseForPeriodRange(
                        startPeriod, currentPeriod, soilTypeIndex,
                        fruitTypeIndex, sampleStage)
            else
                response = TerraLogicSoilMoistureManager:
                    getCropYieldResponse(
                        soilTypeIndex, fruitTypeIndex, sampleStage)
            end
            local weight = math.max(tonumber(response.stageWeight) or 0, 0)
            if sampleStage <= completedSteps then
                oldWeight = oldWeight + weight
            else
                addedWeight = addedWeight + weight
                addedWeighted = addedWeighted
                    + math.clamp(tonumber(response.factor) or 1, 0, 1) * weight
            end
        end
        local totalWeight = oldWeight + addedWeight
        local moistureAverage = totalWeight > 0
            and (oldMoistureAverage * oldWeight + addedWeighted) / totalWeight
            or 1
        if moistureLayer == nil then
            moistureLayer = newLayer(0, ZERO_DATA)
            chunk.counts[CROP_MOISTURE_YIELD_LAYER] = moistureLayer
        end
        changed = setLayerByte(moistureLayer, offset,
            math.clamp(math.floor(moistureAverage * 255 + 0.5), 1, 255))
            or changed
        if periodLayer == nil then
            periodLayer = newLayer(0, ZERO_DATA)
            chunk.counts[CROP_MOISTURE_PERIOD_LAYER] = periodLayer
        end
        changed = setLayerByte(periodLayer, offset,
            TerraLogicSoilMoistureManager:encodePeriodMarker(currentPeriod))
            or changed
    end
    if stepLayer == nil then
        stepLayer = newLayer(0, ZERO_DATA)
        chunk.counts[CROP_GROWTH_STEP_LAYER] = stepLayer
    end
    changed = setLayerByte(stepLayer, offset, desiredSteps) or changed

    -- Sample first, then let the newly formed roots improve future growth
    -- windows. The crop cannot retroactively improve the interval it just
    -- completed.
    if TerraLogicSoilManager ~= nil
        and TerraLogicSoilManager.applyRootGrowthAtWorldPosition ~= nil then
        TerraLogicSoilManager:applyRootGrowthAtWorldPosition(
            x, z, fruitTypeIndex, desiredSteps - completedSteps,
            tostring(self.growthScanSerial or 0)
                .. ":" .. tostring(desiredSteps), cropCoverage)
    end
    if changed then self.dirty = true end
    return changed
end

function TerraLogicQualityManager:getGrowthRootYieldFactor(
        position, finalize, projected, currentRootFactor)
    if position ~= nil and (position.chunkKey == nil
        or position.offset == nil) and position.ix ~= nil
        and position.iz ~= nil then
        local _, _, chunkKey, offset = getChunkPosition(
            position.ix, position.iz)
        position.chunkKey, position.offset = chunkKey, offset
    end
    local chunk = position ~= nil and self.chunks[position.chunkKey] or nil
    if chunk == nil then return nil, 0 end
    if finalize == true then
        self:processCropGrowthCell(chunk, position.chunkKey, position.offset)
    end
    local stepLayer = chunk.counts[CROP_GROWTH_STEP_LAYER]
    local steps = stepLayer ~= nil
        and math.clamp(getLayerByte(stepLayer, position.offset),
            0, self.PLOW_GROWTH_STAGES) or 0
    local yieldLayer = chunk.counts[CROP_ROOT_YIELD_LAYER]
    if steps <= 0 or yieldLayer == nil then return nil, steps end
    local average = getLayerByte(yieldLayer, position.offset) / 255
    if projected == true and steps < self.PLOW_GROWTH_STAGES
        and TerraLogicSoilManager ~= nil then
        local current = tonumber(currentRootFactor)
        if current == nil then
            local fruitTypeIndex = self:getGrowthStateAtCell(
                position.ix, position.iz)
            current = self:getCropWeightedRootYieldFactor(
                position.ix, position.iz, fruitTypeIndex)
        end
        average = (average * steps
            + math.clamp(tonumber(current) or 1, 0, 1)
                * (self.PLOW_GROWTH_STAGES - steps))
            / self.PLOW_GROWTH_STAGES
    end
    return math.clamp(average, 0, 1), steps
end

function TerraLogicQualityManager:getGrowthMoistureYieldFactor(
        position, finalize, projected, projectedFruitType)
    if position ~= nil and (position.chunkKey == nil
        or position.offset == nil) and position.ix ~= nil
        and position.iz ~= nil then
        local _, _, chunkKey, offset = getChunkPosition(
            position.ix, position.iz)
        position.chunkKey, position.offset = chunkKey, offset
    end
    local chunk = position ~= nil and self.chunks[position.chunkKey] or nil
    if chunk == nil then return nil, 0 end
    if finalize == true then
        self:processCropGrowthCell(chunk, position.chunkKey, position.offset)
    end
    local stepLayer = chunk.counts[CROP_GROWTH_STEP_LAYER]
    local steps = stepLayer ~= nil and math.clamp(
        getLayerByte(stepLayer, position.offset), 0,
        self.PLOW_GROWTH_STAGES) or 0
    local layer = chunk.counts[CROP_MOISTURE_YIELD_LAYER]
    if steps <= 0 or layer == nil then return nil, steps end
    local average = getLayerByte(layer, position.offset) / 255
    if projected == true and steps < self.PLOW_GROWTH_STAGES
        and TerraLogicSoilMoistureManager ~= nil then
        local x = (position.ix + 0.5) * self.CELL_SIZE
        local z = (position.iz + 0.5) * self.CELL_SIZE
        local fruitTypeIndex = projectedFruitType or select(1,
            self:getGrowthStateAtCell(position.ix, position.iz))
        local soilTypeIndex = TerraLogicSoilManager ~= nil
            and TerraLogicSoilManager.getPFSoilTypeAtWorldPosition ~= nil
            and TerraLogicSoilManager:getPFSoilTypeAtWorldPosition(x, z) or nil
        local completedWeight, totalWeight, weighted = 0, 0, 0
        for stage = 1, self.PLOW_GROWTH_STAGES do
            local response = TerraLogicSoilMoistureManager:
                getCropYieldResponse(soilTypeIndex, fruitTypeIndex, stage)
            local weight = math.max(tonumber(response.stageWeight) or 0, 0)
            totalWeight = totalWeight + weight
            if stage <= steps then
                completedWeight = completedWeight + weight
            else
                weighted = weighted
                    + math.clamp(tonumber(response.factor) or 1, 0, 1) * weight
            end
        end
        average = totalWeight > 0
            and (average * completedWeight + weighted) / totalWeight
            or average
    end
    return math.clamp(average, 0, 1), steps
end

function TerraLogicQualityManager:processPlowGrowthCell(
        chunk, chunkKey, offset)
    local cropChanged = self:processCropGrowthCell(chunk, chunkKey, offset)
    -- Legacy plough-quality growth bytes are obsolete. Dynamic soil recovery
    -- owns the physical development; this scanner remains for crop root and
    -- moisture history and cleans old saves incrementally.
    local legacyChanged = self:clearPlowGrowthCycleAtOffset(chunk, offset)
    if legacyChanged then self.dirty = true end
    return legacyChanged or cropChanged
end

function TerraLogicQualityManager:queuePlowGrowthRecovery()
    if g_currentMission == nil or not g_currentMission:getIsServer() then return end
    self.growthScanSerial = (self.growthScanSerial or 0) + 1
    if self.plowGrowthJob ~= nil then
        -- Never replace a partially processed field with a later month. One
        -- follow-up scan is sufficient because semantic stages can catch up
        -- every skipped window from the current crop state.
        self.plowGrowthQueuedAfterJob = true
        return
    end
    self.plowGrowthPending = true
    self.plowGrowthDelayRemaining = self.PLOW_GROWTH_DELAY_MS
end

function TerraLogicQualityManager:startPlowGrowthRecovery()
    local keys = {}
    for key, chunk in pairs(self.chunks) do
        if chunk.status.nonDefaultCount > 0
            and (chunk.counts[PLOW_GROWTH_BASE_LAYER] ~= nil
                or chunk.counts[CROP_GROWTH_BASE_LAYER] ~= nil) then
            keys[#keys + 1] = key
        end
    end
    self.plowGrowthPending = false
    self.plowGrowthJob = #keys > 0 and {
        keys = keys,
        keyIndex = 1,
        offset = 1
    } or nil
end

function TerraLogicQualityManager:updatePlowGrowthRecovery(dt)
    if g_currentMission == nil or not g_currentMission:getIsServer() then return end
    if self.plowGrowthPending and self.plowGrowthJob == nil then
        self.plowGrowthDelayRemaining = math.max(
            (self.plowGrowthDelayRemaining or 0) - (tonumber(dt) or 0), 0)
        if self.plowGrowthDelayRemaining <= 0 then
            self:startPlowGrowthRecovery()
        end
    end
    local job = self.plowGrowthJob
    if job == nil then return end
    local checks = 0
    while job.keyIndex <= #job.keys
        and checks < self.PLOW_GROWTH_CHECKS_PER_FRAME do
        local key = job.keys[job.keyIndex]
        local chunk = self.chunks[key]
        if chunk == nil then
            job.keyIndex = job.keyIndex + 1
            job.offset = 1
        else
            self:processPlowGrowthCell(chunk, key, job.offset)
            checks = checks + 1
            job.offset = job.offset + 1
            if job.offset > self.CHUNK_CELL_COUNT then
                job.keyIndex = job.keyIndex + 1
                job.offset = 1
            end
        end
    end
    if job.keyIndex > #job.keys then
        self.plowGrowthJob = nil
        if self.plowGrowthQueuedAfterJob == true then
            self.plowGrowthQueuedAfterJob = false
            self.plowGrowthPending = true
            -- The first job already provided the safety delay. Run the final
            -- consistency pass promptly after a burst of accelerated months.
            self.plowGrowthDelayRemaining = 0
        end
    end
end

function TerraLogicQualityManager:isGrowthHistoryUpdating()
    return self.plowGrowthPending == true or self.plowGrowthJob ~= nil
        or self.plowGrowthQueuedAfterJob == true
end

-- Writes one successful operation into a cell while preserving group history.
function TerraLogicQualityManager:setCellComponent(
        ix, iz, component, quality, yieldWeight, maxYieldPenalty,
        explicitHarvestPenalty, aggregateVanillaFertilizer,
        seedSoilQualityLoss)
    local definition = self.COMPONENTS[component]
    if definition == nil then return false end
    local chunkX, chunkZ, chunkKey, offset = getChunkPosition(ix, iz)
    local chunk = self:getOrCreateChunk(chunkX, chunkZ, chunkKey)
    local oldMask = getLayerByte(chunk.status, offset)
    local changed = setLayerByte(chunk.status, offset, addBit(oldMask, definition.bit))

    quality = math.clamp(tonumber(quality) or 1, 0, 1)
    if aggregateVanillaFertilizer == true and component == "fertilizer" then
        self.applicationCellStamps = self.applicationCellStamps or {}
        local stampKey = chunkKey .. ":" .. tostring(offset) .. ":fertilizer"
        local now = g_currentMission ~= nil and g_currentMission.time or 0
        local lastStamp = self.applicationCellStamps[stampKey]
        local isNewStage = lastStamp == nil or now - lastStamp >= 30000
        self.applicationCellStamps[stampKey] = now
        local countLayer = chunk.counts[component]
        local oldCount = countLayer ~= nil
            and getLayerByte(countLayer, offset) or 0
        local oldLayer = chunk.qualities[component]
        local oldEncoded = oldLayer ~= nil
            and getLayerByte(oldLayer, offset) or 255
        local oldQuality = oldEncoded == 255 and 1 or oldEncoded / 254
        local count = oldCount
        if isNewStage and oldCount < 2 then count = oldCount + 1 end
        if count <= 0 then count = 1 end
        if isNewStage and count > oldCount then
            quality = (oldQuality * oldCount + quality) / count
        elseif oldCount > 0 then
            -- Work areas overlap between frames. A cell which already belongs
            -- to this fertilizer stage must retain its accumulated value; it
            -- is not a new application merely because a neighbouring pixel
            -- changed during the same call.
            quality = oldQuality
        end
        if countLayer == nil then
            countLayer = newLayer(0, ZERO_DATA)
            chunk.counts[component] = countLayer
        end
        if setLayerByte(countLayer, offset, count) then changed = true end
        local totalBonus = 0.225 * math.min(count, 2)
        explicitHarvestPenalty = totalBonus * (1 - quality)
            / math.max(1 + totalBonus, 0.0001)
    end
    local encoded = quality >= 0.9995 and 255
        or math.clamp(math.floor(quality * 254 + 0.5), 0, 254)
    local layer = chunk.qualities[component]
    if encoded < 255 and layer == nil then
        layer = newLayer(255, PERFECT_DATA)
        chunk.qualities[component] = layer
    end
    if layer ~= nil and setLayerByte(layer, offset, encoded) then
        changed = true
        if layer.nonDefaultCount == 0 then
            chunk.qualities[component] = nil
        end
    end

    local penalty = explicitHarvestPenalty ~= nil
        and math.clamp(tonumber(explicitHarvestPenalty) or 0, 0, 1)
        or self:calculateYieldPenalty(
            quality,
            yieldWeight ~= nil and yieldWeight or definition.yieldWeight,
            maxYieldPenalty ~= nil and maxYieldPenalty
                or definition.maxYieldPenalty
        )
    local penaltyEncoded = math.clamp(
        math.floor(penalty * 255 + 0.5),
        0,
        255
    )
    local penaltyLayer = chunk.penalties[component]
    if penaltyEncoded > 0 and penaltyLayer == nil then
        penaltyLayer = newLayer(0, ZERO_DATA)
        chunk.penalties[component] = penaltyLayer
    end
    if penaltyLayer ~= nil
        and setLayerByte(penaltyLayer, offset, penaltyEncoded) then
        changed = true
        if penaltyLayer.nonDefaultCount == 0 then
            chunk.penalties[component] = nil
        end
    end
    if component == "seed" then
        local correctableLoss = math.clamp(
            tonumber(seedSoilQualityLoss) or 0, 0, 1)
        if correctableLoss > 0 and TerraLogicSoilManager ~= nil
            and TerraLogicSoilProfiles ~= nil then
            local x = (ix + 0.5) * self.CELL_SIZE
            local z = (iz + 0.5) * self.CELL_SIZE
            local state = TerraLogicSoilManager:getStateAtWorldPosition(x, z)
            local soilTypeIndex = TerraLogicSoilManager:getPFSoilTypeAtWorldPosition(
                x, z)
            correctableLoss = correctableLoss
                * TerraLogicSoilProfiles:getRollerSeedRescuePotential(
                    state, soilTypeIndex)
        else
            correctableLoss = 0
        end
        local encodedLoss = math.clamp(
            math.floor(correctableLoss * 255 + 0.5), 0, 255)
        local recoveryLayer = chunk.metadata.seedRollerRecoverable
        if encodedLoss > 0 and recoveryLayer == nil then
            recoveryLayer = newLayer(0, ZERO_DATA)
            chunk.metadata.seedRollerRecoverable = recoveryLayer
        end
        if recoveryLayer ~= nil
            and setLayerByte(recoveryLayer, offset, encodedLoss) then
            changed = true
            if recoveryLayer.nonDefaultCount == 0 then
                chunk.metadata.seedRollerRecoverable = nil
            end
        end
        changed = self:beginCropGrowthCycle(ix, iz) or changed
    end
    return changed
end

-- A successful post-sowing soil-roller pass can recover only the quality loss
-- previously marked as seedbed-correctable.  It never recreates missing fruit
-- pixels and never repairs speed- or wear-caused placement errors.  Vanilla's
-- roller density state ensures the same ground cannot be credited repeatedly.
function TerraLogicQualityManager:rescueSeedQualityWithRoller(
        workArea, rollerQuality, changedArea, vehicle,
        speedKph, shopSpeedKph)
    if g_currentMission == nil or not g_currentMission:getIsServer()
        or (tonumber(changedArea) or 0) <= 0 then
        return 0, 0, 0
    end
    local rollerSpec = vehicle ~= nil and vehicle.spec_roller or nil
    if rollerSpec ~= nil and rollerSpec.isSoilRoller ~= true then
        return 0, 0, 0
    end
    local maximumShare, maximumGain = 0, 0
    if TerraLogicSoilProfiles ~= nil then
        maximumShare, maximumGain =
            TerraLogicSoilProfiles:getRollerSeedRescueLimits()
    end
    local qualityFactor = math.clamp(tonumber(rollerQuality) or 0, 0, 1)
    local seedDefinition = self.COMPONENTS.seed
    local rescuedCells, qualityGainSum, penaltyGainSum = 0, 0, 0
    local changed = false
    for _, position in ipairs(self:getTouchedCells(workArea, false)) do
        local chunk = self.chunks[position.chunkKey]
        local recoveryLayer = chunk ~= nil and chunk.metadata ~= nil
            and chunk.metadata.seedRollerRecoverable or nil
        local mask = chunk ~= nil and getLayerByte(chunk.status, position.offset) or 0
        if recoveryLayer ~= nil and hasBit(mask, seedDefinition.bit)
            and self:isComponentAllowedAtCell(
                "roller", position.ix, position.iz, vehicle) then
            local recoverable = getLayerByte(recoveryLayer, position.offset) / 255
            if recoverable > 0 then
                local contactEfficiency = 1
                if TerraLogicSoilProfiles ~= nil
                    and TerraLogicSoilProfiles.getRollerContactEfficiency
                        ~= nil and TerraLogicSoilManager ~= nil then
                    local x = (position.ix + 0.5) * self.CELL_SIZE
                    local z = (position.iz + 0.5) * self.CELL_SIZE
                    local soilState = TerraLogicSoilManager:
                        getStateAtWorldPosition(x, z)
                    contactEfficiency = TerraLogicSoilProfiles:
                        getRollerContactEfficiency(
                            soilState, speedKph, shopSpeedKph)
                end
                local qualityLayer = chunk.qualities.seed
                local qualityEncoded = qualityLayer ~= nil
                    and getLayerByte(qualityLayer, position.offset) or 255
                local oldQuality = qualityEncoded == 255
                    and 1 or qualityEncoded / 254
                local gain = math.min(
                    recoverable * maximumShare * qualityFactor
                        * contactEfficiency,
                    maximumGain,
                    1 - oldQuality
                )
                if gain > 0.0001 then
                    local newQuality = math.clamp(oldQuality + gain, 0, 1)
                    local newEncoded = newQuality >= 0.9995 and 255
                        or math.clamp(math.floor(newQuality * 254 + 0.5), 0, 254)
                    if qualityLayer == nil and newEncoded < 255 then
                        qualityLayer = newLayer(255, PERFECT_DATA)
                        chunk.qualities.seed = qualityLayer
                    end
                    if qualityLayer ~= nil then
                        changed = setLayerByte(
                            qualityLayer, position.offset, newEncoded) or changed
                        if qualityLayer.nonDefaultCount == 0 then
                            chunk.qualities.seed = nil
                        end
                    end
                    local penaltyLayer = chunk.penalties.seed
                    if penaltyLayer ~= nil then
                        local oldPenalty = getLayerByte(
                            penaltyLayer, position.offset) / 255
                        local newPenalty = math.max(oldPenalty
                            - seedDefinition.maxYieldPenalty * gain, 0)
                        local newPenaltyEncoded = math.clamp(
                            math.floor(newPenalty * 255 + 0.5), 0, 255)
                        changed = setLayerByte(
                            penaltyLayer, position.offset,
                            newPenaltyEncoded) or changed
                        penaltyGainSum = penaltyGainSum
                            + math.max(oldPenalty - newPenalty, 0)
                        if penaltyLayer.nonDefaultCount == 0 then
                            chunk.penalties.seed = nil
                        end
                    end
                    rescuedCells = rescuedCells + 1
                    qualityGainSum = qualityGainSum + gain
                end
                -- Vanilla accepts a soil-roller result only once. Consume the
                -- rescue marker even when a worn/fast roller achieved no gain.
                changed = setLayerByte(
                    recoveryLayer, position.offset, 0) or changed
            end
            if recoveryLayer.nonDefaultCount == 0 then
                chunk.metadata.seedRollerRecoverable = nil
            end
        end
    end
    if changed then self.dirty = true end
    if rescuedCells > 0 then
        qualityGainSum = qualityGainSum / rescuedCells
        penaltyGainSum = penaltyGainSum / rescuedCells
    end
    return rescuedCells, qualityGainSum, penaltyGainSum
end

function TerraLogicQualityManager:getPackedCell(ix, iz)
    local _, _, chunkKey, offset = getChunkPosition(ix, iz)
    local chunk = self.chunks[chunkKey]
    if chunk == nil then return nil end
    local mask = getLayerByte(chunk.status, offset)
    if mask == 0 then return nil end
    local cell = {mask = mask, values = {}, penalties = {}, applicationCounts = {}}
    for _, name in ipairs(self.COMPONENT_ORDER) do
        local definition = self.COMPONENTS[name]
        if hasBit(mask, definition.bit) then
            local layer = chunk.qualities[name]
            local encoded = layer ~= nil and getLayerByte(layer, offset) or 255
            if encoded < 255 then cell.values[name] = encoded / 254 end
            local penaltyLayer = chunk.penalties[name]
            local penaltyEncoded = penaltyLayer ~= nil
                and getLayerByte(penaltyLayer, offset) or 0
            if penaltyEncoded > 0 then
                cell.penalties[name] = penaltyEncoded / 255
            end
            local countLayer = chunk.counts[name]
            if countLayer ~= nil then
                cell.applicationCounts[name] = math.max(
                    getLayerByte(countLayer, offset), 1)
            end
        end
    end
    local growthStepLayer = chunk.counts[CROP_GROWTH_STEP_LAYER]
    local rootYieldLayer = chunk.counts[CROP_ROOT_YIELD_LAYER]
    local growthSteps = growthStepLayer ~= nil
        and math.clamp(getLayerByte(growthStepLayer, offset),
            0, self.PLOW_GROWTH_STAGES) or 0
    if growthSteps > 0 and rootYieldLayer ~= nil then
        cell.rootYieldSteps = growthSteps
        cell.rootYieldAverage = getLayerByte(rootYieldLayer, offset) / 255
        local moistureLayer = chunk.counts[CROP_MOISTURE_YIELD_LAYER]
        if moistureLayer ~= nil then
            cell.moistureYieldAverage =
                getLayerByte(moistureLayer, offset) / 255
        end
    end
    return cell
end

-- Vanilla's field-info query covers a 5x5 metre area rather than a single
-- point. Aggregate every four-metre TerraLogic cell intersecting the same footprint
-- so that the displayed quality cannot disappear at an internal cell edge.
function TerraLogicQualityManager:getPackedSummaryInArea(x, z, radius)
    radius = math.max(tonumber(radius) or 0, 0)
    local minIx, maxIx = getCellIndex(x - radius), getCellIndex(x + radius)
    local minIz, maxIz = getCellIndex(z - radius), getCellIndex(z + radius)
    local mask, sums, penaltySums, applicationCountSums, counts =
        0, {}, {}, {}, {}
    for ix = minIx, maxIx do
        for iz = minIz, maxIz do
            local cell = self:getPackedCell(ix, iz)
            if cell ~= nil then
                for _, name in ipairs(self.COMPONENT_ORDER) do
                    local definition = self.COMPONENTS[name]
                    if hasBit(cell.mask or 0, definition.bit) then
                        mask = addBit(mask, definition.bit)
                        sums[name] = (sums[name] or 0) + (cell.values[name] or 1)
                        penaltySums[name] = (penaltySums[name] or 0)
                            + ((cell.penalties or {})[name] or 0)
                        applicationCountSums[name] =
                            (applicationCountSums[name] or 0)
                            + ((cell.applicationCounts or {})[name] or 1)
                        counts[name] = (counts[name] or 0) + 1
                    end
                end
            end
        end
    end
    if mask == 0 then return nil end
    local result = {mask = mask, values = {}, penalties = {}, applicationCounts = {}}
    for _, name in ipairs(self.COMPONENT_ORDER) do
        if counts[name] ~= nil and counts[name] > 0 then
            local quality = sums[name] / counts[name]
            if quality < 0.9995 then result.values[name] = quality end
            local penalty = (penaltySums[name] or 0) / counts[name]
            if penalty > 0 then result.penalties[name] = penalty end
            result.applicationCounts[name] = math.max(math.floor(
                (applicationCountSums[name] or counts[name]) / counts[name]
                    + 0.5), 1)
        end
    end
    return result
end

function TerraLogicQualityManager:clearSeedRollerRecoveryAtCell(position)
    local chunk = position ~= nil and self.chunks[position.chunkKey] or nil
    local recoveryLayer = chunk ~= nil and chunk.metadata ~= nil
        and chunk.metadata.seedRollerRecoverable or nil
    if recoveryLayer == nil then return false end
    local changed = setLayerByte(recoveryLayer, position.offset, 0)
    if recoveryLayer.nonDefaultCount == 0 then
        chunk.metadata.seedRollerRecoverable = nil
    end
    return changed
end

function TerraLogicQualityManager:getSeedRollerRecoveryAtCell(position)
    if position ~= nil and position.chunkKey == nil
        and position.ix ~= nil and position.iz ~= nil then
        local _, _, chunkKey, offset = getChunkPosition(position.ix, position.iz)
        position = {chunkKey=chunkKey, offset=offset}
    end
    local chunk = position ~= nil and self.chunks[position.chunkKey] or nil
    local layer = chunk ~= nil and chunk.metadata ~= nil
        and chunk.metadata.seedRollerRecoverable or nil
    return layer ~= nil and getLayerByte(layer, position.offset) / 255 or 0
end

function TerraLogicQualityManager:clearCell(position)
    local chunk = self.chunks[position.chunkKey]
    if chunk == nil or getLayerByte(chunk.status, position.offset) == 0 then
        return false
    end
    setLayerByte(chunk.status, position.offset, 0)
    for _, name in ipairs(self.COMPONENT_ORDER) do
        local layer = chunk.qualities[name]
        if layer ~= nil then
            setLayerByte(layer, position.offset, 255)
            if layer.nonDefaultCount == 0 then chunk.qualities[name] = nil end
        end
        local penaltyLayer = chunk.penalties[name]
        if penaltyLayer ~= nil then
            setLayerByte(penaltyLayer, position.offset, 0)
            if penaltyLayer.nonDefaultCount == 0 then
                chunk.penalties[name] = nil
            end
        end
        local countLayer = chunk.counts[name]
        if countLayer ~= nil then
            setLayerByte(countLayer, position.offset, 0)
            if countLayer.nonDefaultCount == 0 then chunk.counts[name] = nil end
        end
    end
    for name, metadataLayer in pairs(chunk.metadata or {}) do
        setLayerByte(metadataLayer, position.offset, 0)
        if metadataLayer.nonDefaultCount == 0 then
            chunk.metadata[name] = nil
        end
    end
    self:clearPlowGrowthCycleAtOffset(chunk, position.offset)
    self:clearCropGrowthCycleAtOffset(chunk, position.offset)
    if chunk.status.nonDefaultCount == 0 then
        self.chunks[position.chunkKey] = nil
    end
    return true
end

function TerraLogicQualityManager:clearCellComponent(position, component)
    local definition = self.COMPONENTS[component]
    local chunk = definition ~= nil and self.chunks[position.chunkKey] or nil
    if chunk == nil then return false end
    local oldMask = getLayerByte(chunk.status, position.offset)
    if not hasBit(oldMask, definition.bit) then return false end
    setLayerByte(chunk.status, position.offset, removeBit(oldMask, definition.bit))
    local layer = chunk.qualities[component]
    if layer ~= nil then
        setLayerByte(layer, position.offset, 255)
        if layer.nonDefaultCount == 0 then chunk.qualities[component] = nil end
    end
    local penaltyLayer = chunk.penalties[component]
    if penaltyLayer ~= nil then
        setLayerByte(penaltyLayer, position.offset, 0)
        if penaltyLayer.nonDefaultCount == 0 then
            chunk.penalties[component] = nil
        end
    end
    local countLayer = chunk.counts[component]
    if countLayer ~= nil then
        setLayerByte(countLayer, position.offset, 0)
        if countLayer.nonDefaultCount == 0 then chunk.counts[component] = nil end
    end
    if component == "seed" or component == "soilPlow" then
        self:clearPlowGrowthCycleAtOffset(chunk, position.offset)
    end
    if component == "seed" then
        self:clearCropGrowthCycleAtOffset(chunk, position.offset)
    end
    if component == "seed" and chunk.metadata ~= nil then
        self:clearSeedRollerRecoveryAtCell(position)
    end
    if chunk.status.nonDefaultCount == 0 then
        self.chunks[position.chunkKey] = nil
    end
    return true
end

-- Persistent establishment defects gradually normalize over repeated crop
-- cycles. A 50 percent recovery share produces 50 -> 75 -> 87.5 -> 93.75.
-- The matching yield penalty follows the same decay. The component bit stays
-- present so field info can continue showing the recovered quality.
-- Harvest lifecycle ---------------------------------------------------------

-- Recovers a persistent quality layer and/or its locked crop penalty. Growth
-- uses quality-only recovery; harvest uses penalty-only recovery afterwards.
function TerraLogicQualityManager:recoverPersistentQualityAfterHarvest(
        position, component, recoveryShare, recoverQuality, recoverPenalty)
    local definition = self.COMPONENTS[component]
    if definition == nil then return false end
    local chunk = self.chunks[position.chunkKey]
    if chunk == nil then return false end
    local mask = getLayerByte(chunk.status, position.offset)
    if not hasBit(mask, definition.bit) then return false end

    local changed = false
    recoveryShare = math.clamp(tonumber(recoveryShare) or 0.5, 0, 1)
    recoverQuality = recoverQuality ~= false
    recoverPenalty = recoverPenalty ~= false
    local qualityLayer = chunk.qualities[component]
    local encoded = qualityLayer ~= nil
        and getLayerByte(qualityLayer, position.offset) or 255
    if recoverQuality and encoded < 255 then
        local quality = encoded / 254
        local recovered = quality + (1 - quality) * recoveryShare
        local recoveredEncoded = recovered >= 0.9995 and 255
            or math.clamp(math.floor(recovered * 254 + 0.5), 0, 254)
        if setLayerByte(qualityLayer, position.offset, recoveredEncoded) then
            changed = true
        end
        if qualityLayer.nonDefaultCount == 0 then
            chunk.qualities[component] = nil
        end
    end

    local penaltyLayer = chunk.penalties[component]
    if recoverPenalty and penaltyLayer ~= nil then
        local oldPenalty = getLayerByte(penaltyLayer, position.offset)
        local recoveredPenalty = math.floor(
            oldPenalty * (1 - recoveryShare) + 0.5)
        if setLayerByte(penaltyLayer, position.offset, recoveredPenalty) then
            changed = true
        end
        if penaltyLayer.nonDefaultCount == 0 then
            chunk.penalties[component] = nil
        end
    end
    return changed
end

function TerraLogicQualityManager:advanceCellAfterHarvest(position)
    local changed = false
    for _, component in ipairs(self.COMPONENT_ORDER) do
        changed = self:clearCellComponent(position, component) or changed
    end
    return changed
end

-- Grass is a perennial crop in FS25. Cutting consumes only work that belongs
-- to this growth/cut cycle. Establishment quality (soil + seed) remains until
-- the player actually tills or reseeds the stand. PF lime also remains because
-- PF consumes pH gradually over several harvests; Vanilla grass ignores lime.
function TerraLogicQualityManager:clearAfterMowerPass(
        position, wasGrass, precisionFarmingActive)
    if not wasGrass then
        return self:advanceCellAfterHarvest(position)
    end

    local changed = self:clearCellComponent(position, "soilPlow")
    changed = self:clearCellComponent(position, "soilCultivate") or changed
    -- A perennial grass stand closes poor sowing gaps over repeated regrowth.
    -- Annual crops use advanceCellAfterHarvest() and still discard seed
    -- quality completely after their one harvest.
    changed = self:recoverPersistentQualityAfterHarvest(
        position, "seed", 0.5) or changed
    -- Rolling can aid emergence only immediately after establishment. Once a
    -- perennial stand has completed its first cut, later grass rolling must
    -- not resurrect the old sowing rescue opportunity.
    changed = self:clearSeedRollerRecoveryAtCell(position) or changed
    -- Shallow cultivation belongs to the harvested surface cycle and does not
    -- persist like a deep plowing defect. Grass establishment/seed remains
    -- valid for the perennial stand until the player tills or reseeds it.
    for _, component in ipairs({
            "soilCultivate", "fertilizer", "roller", "herbicide", "mulch"
        }) do
        changed = self:clearCellComponent(position, component) or changed
    end
    if not precisionFarmingActive then
        -- Also migrates legacy Vanilla-grass cells that could store lime before
        -- the lifecycle distinction was introduced.
        changed = self:clearCellComponent(position, "lime") or changed
    end
    -- Grass keeps its establishment layers after cutting, so the cut state is
    -- the base of the next three-step regrowth cycle.
    changed = self:beginCropGrowthCycle(
        position.ix, position.iz) or changed
    return changed
end

-- Some annual crops (notably spinach) regrow after their first harvest. Keep
-- the establishment record and open a fresh three-window growth history;
-- terminal harvests still use the normal complete arable reset.
function TerraLogicQualityManager:clearAfterRegrowingAnnualPass(position)
    local changed = self:clearCellComponent(position, "soilPlow")
    changed = self:clearCellComponent(position, "soilCultivate") or changed
    changed = self:clearSeedRollerRecoveryAtCell(position) or changed
    for _, component in ipairs({
            "soilCultivate", "fertilizer", "lime", "roller",
            "herbicide", "mulch"
        }) do
        changed = self:clearCellComponent(position, component) or changed
    end
    changed = self:beginCropGrowthCycle(position.ix, position.iz) or changed
    return changed
end

function TerraLogicQualityManager:markPartialHarvest(
        position, domain, fruitTypeIndex)
    if position == nil or domain == nil then return false end
    local key = tostring(position.ix) .. ":" .. tostring(position.iz)
        .. ":" .. tostring(domain)
    local old = self.partialHarvestCells[key]
    local validFruitType = fruitTypeIndex ~= nil
        and (FruitType == nil or fruitTypeIndex ~= FruitType.UNKNOWN)
    local marker = old or {
        ix = position.ix,
        iz = position.iz,
        domain = domain,
        fruitTypeIndex = validFruitType and fruitTypeIndex
            or (old ~= nil and old.fruitTypeIndex or nil)
    }
    if validFruitType and marker.fruitTypeIndex ~= fruitTypeIndex then
        marker = {ix=position.ix, iz=position.iz, domain=domain,
            fruitTypeIndex=fruitTypeIndex}
    end
    local changed = old == nil or old.domain ~= marker.domain
        or old.fruitTypeIndex ~= marker.fruitTypeIndex
    self.partialHarvestCells[key] = marker
    if changed then self.dirty = true end
    return changed
end

function TerraLogicQualityManager:completePartialHarvest(
        position, expectedDomain, precisionFarmingActive)
    if position == nil or expectedDomain == nil then return false end
    local key = tostring(position.ix) .. ":" .. tostring(position.iz)
        .. ":" .. tostring(expectedDomain)
    local marker = self.partialHarvestCells[key]
    if marker == nil then return false end
    if position.chunkKey == nil or position.offset == nil then
        local _, _, chunkKey, offset = getChunkPosition(position.ix, position.iz)
        position.chunkKey, position.offset = chunkKey, offset
    end
    self.partialHarvestCells[key] = nil
    -- A delayed worker may only close the harvest it originally observed.
    self.pendingHarvestClears[key] = nil
    if marker.remainderClosed == true then
        self.dirty = true
        return true
    end
    local _, currentGrowthState = self:getGrowthStateAtCell(
        position.ix, position.iz)
    local stateInfo = marker.fruitTypeIndex ~= nil
        and TerraLogicSoilManager ~= nil
        and TerraLogicSoilManager.getRecoveryFruitStateInfo ~= nil
        and TerraLogicSoilManager:getRecoveryFruitStateInfo(
            marker.fruitTypeIndex) or nil
    local regrows = marker.domain == "arable"
        and stateInfo ~= nil and currentGrowthState ~= nil
        and stateInfo.regrowthSources[currentGrowthState] == true
    if TerraLogicSoilManager ~= nil
        and TerraLogicSoilManager.completeCropCycleAtQualityCell ~= nil
        and marker.fruitTypeIndex ~= nil and not regrows then
        local _, growthSteps = self:getGrowthRootYieldFactor(
            position, false, false)
        TerraLogicSoilManager:completeCropCycleAtQualityCell(
            position.ix, position.iz, marker.fruitTypeIndex,
            self.CELL_SIZE, growthSteps > 0)
    end
    local changed
    if marker.domain == "fieldGrass" then
        changed = self:clearAfterMowerPass(
            position, true, precisionFarmingActive == true)
    else
        if regrows then
            changed = self:clearAfterRegrowingAnnualPass(position)
        else
            changed = self:advanceCellAfterHarvest(position)
        end
    end
    self.dirty = true
    return true
end

function TerraLogicQualityManager:completePartialHarvestBeforeNewWork(position)
    local surface = self:getSurfaceTypeAtWorldPosition(
        (position.ix + 0.5) * self.CELL_SIZE,
        (position.iz + 0.5) * self.CELL_SIZE)
    local cellKey = tostring(position.ix) .. ":" .. tostring(position.iz)
    local arableMarker = self.partialHarvestCells[cellKey .. ":arable"]
    local grassMarker = self.partialHarvestCells[cellKey .. ":fieldGrass"]
    local domain
    if surface == "grassField" then
        domain = "fieldGrass"
    elseif arableMarker ~= nil or grassMarker == nil then
        domain = "arable"
    else
        -- Tillage may already have converted field grass back to ordinary
        -- field ground before this successful-work callback runs.
        domain = "fieldGrass"
    end
    local pfActive = TerraLogicMain ~= nil
        and TerraLogicMain.isPrecisionFarmingActive ~= nil
        and TerraLogicMain:isPrecisionFarmingActive()
    return self:completePartialHarvest(position, domain, pfActive)
end

function TerraLogicQualityManager:scheduleMowerClear(
        mower, positions, domain, fruitTypeIndex, precisionFarmingActive)
    if mower == nil or positions == nil then return end
    local now = g_currentMission ~= nil and g_currentMission.time or 0
    for _, position in ipairs(positions) do
        -- Key globally by fixed cell and domain, not by vehicle. Separate
        -- front/rear or butterfly mower objects therefore share one harvest
        -- completion for the same perennial cell.
        local key = tostring(position.ix) .. ":" .. tostring(position.iz)
            .. ":" .. tostring(domain)
        self:markPartialHarvest(position, domain, fruitTypeIndex)
        local entry = self.pendingMowerClears[key]
        if entry == nil then
            self.pendingMowerClears[key] = {
                position = position,
                domain = domain,
                fruitTypeIndex = fruitTypeIndex,
                lastTouchedAt = now,
                precisionFarmingActive = precisionFarmingActive == true
            }
        else
            entry.domain = domain or entry.domain
            entry.fruitTypeIndex = fruitTypeIndex or entry.fruitTypeIndex
            entry.lastTouchedAt = now
            entry.precisionFarmingActive = precisionFarmingActive == true
        end
    end
end

function TerraLogicQualityManager:flushPendingMowerClears()
    if g_currentMission == nil or not g_currentMission:getIsServer() then return end
    local now = g_currentMission.time or 0
    local changed = false
    -- Settle each global cell independently. This lets every section/frame and
    -- every attached mower read the same pre-cut quality before one shared
    -- perennial recovery is applied.
    for key, entry in pairs(self.pendingMowerClears) do
        if now - (entry.lastTouchedAt or 0)
                >= self.MOWER_CELL_SETTLE_TIME_MS then
            entry.position.fruitTypeIndex = entry.fruitTypeIndex
            entry.position.useMinForageState = true
            local remaining, queryKnown =
                self:cellHasRemainingHarvestFruit(entry.position)
            if queryKnown and not remaining then
                changed = self:completePartialHarvest(
                    entry.position, entry.domain,
                    entry.precisionFarmingActive) or changed
            end
            self.pendingMowerClears[key] = nil
        end
    end
    self.dirty = self.dirty or changed
end

function TerraLogicQualityManager:clearOverwrittenComponents(
        position, newComponent)
    local components = self.OVERWRITTEN_COMPONENTS[newComponent]
    if components == nil then return false end
    local changed = false
    for _, component in ipairs(components) do
        changed = self:clearCellComponent(position, component) or changed
    end
    return changed
end

-- Invalidates crop-cycle components where an unintended mechanical pass has
-- genuinely destroyed plants, without crediting that accident as a successful
-- soil-quality operation. This deliberately reuses the normal contributor and
-- partial-harvest lifecycle rules instead of editing quality layers directly.
function TerraLogicQualityManager:invalidateSoilDamageWorkArea(
        workArea, vehicle)
    if g_currentMission == nil or not g_currentMission:getIsServer()
        or workArea == nil then
        return 0, false
    end
    local changed, acceptedCells = false, 0
    for _, position in ipairs(self:getTouchedCells(workArea, false)) do
        if self:isComponentAllowedAtCell(
                "soilCultivate", position.ix, position.iz, vehicle) then
            acceptedCells = acceptedCells + 1
            changed = self:completePartialHarvestBeforeNewWork(position)
                or changed
            changed = self:clearOverwrittenComponents(
                position, "soilCultivate") or changed
        end
    end
    if changed then self.dirty = true end
    return acceptedCells, changed
end

function TerraLogicQualityManager:beginStoredCellPrune()
    self.pruneChunkKeys = {}
    for chunkKey in pairs(self.chunks) do
        self.pruneChunkKeys[#self.pruneChunkKeys + 1] = chunkKey
    end
    self.pruneChunkIndex = 1
    self.pruneOffset = 1
    self.pruneRemoved = 0
end

function TerraLogicQualityManager:processStoredCellPrune(maxCells, maxOffsets)
    if self.pruneChunkKeys == nil then return end
    maxCells = math.max(tonumber(maxCells) or 64, 1)
    maxOffsets = math.max(tonumber(maxOffsets) or 2048, maxCells)
    local checkedCells, checkedOffsets = 0, 0
    while checkedCells < maxCells and checkedOffsets < maxOffsets do
        local chunkKey = self.pruneChunkKeys[self.pruneChunkIndex]
        if chunkKey == nil then
            if self.pruneRemoved > 0 then
                self.dirty = true
                TerraLogicLogging.debug(
                    "[FS25_TerraLogic] Removed %d invalid saved work-quality entries outside compatible surfaces",
                    self.pruneRemoved
                )
            end
            self.pruneChunkKeys = nil
            return
        end
        local chunk = self.chunks[chunkKey]
        if chunk == nil or self.pruneOffset > self.CHUNK_CELL_COUNT then
            self.pruneChunkIndex = self.pruneChunkIndex + 1
            self.pruneOffset = 1
        else
            local offset = self.pruneOffset
            self.pruneOffset = self.pruneOffset + 1
            checkedOffsets = checkedOffsets + 1
            local mask = getLayerByte(chunk.status, offset)
            if mask ~= 0 then
                checkedCells = checkedCells + 1
                local zeroOffset = offset - 1
                local position = {
                    ix = chunk.x * self.CHUNK_SIZE
                        + zeroOffset % self.CHUNK_SIZE,
                    iz = chunk.z * self.CHUNK_SIZE
                        + math.floor(zeroOffset / self.CHUNK_SIZE),
                    chunkKey = chunkKey,
                    offset = offset
                }
                for _, component in ipairs(self.COMPONENT_ORDER) do
                    local definition = self.COMPONENTS[component]
                    if hasBit(mask, definition.bit)
                        and not self:isComponentAllowedAtCell(
                            component, position.ix, position.iz, nil) then
                        if self:clearCellComponent(position, component) then
                            self.pruneRemoved = self.pruneRemoved + 1
                        end
                    end
                end
            end
        end
    end
end

function TerraLogicQualityManager:scheduleHarvestClear(
        cutter, positions, fruitTypeIndex, useMinForageState)
    if cutter == nil or positions == nil then return 0 end
    local now = g_currentMission ~= nil and g_currentMission.time or 0
    local added = 0
    for _, position in ipairs(positions) do
        local key = tostring(position.ix) .. ":" .. tostring(position.iz) .. ":arable"
        local marker = self.partialHarvestCells[key]
        if marker ~= nil and marker.remainderClosed ~= true then
            local entry = self.pendingHarvestClears[key]
            if entry == nil or entry.marker ~= marker then
                entry = {ix=position.ix, iz=position.iz, key=key, marker=marker}
                self.pendingHarvestClears[key] = entry
                self:enqueueHarvestCheck(entry)
                added = added + 1
            end
            entry.fruitTypeIndex = marker.fruitTypeIndex
            entry.useMinForageState = useMinForageState == true
            marker.useMinForageState = entry.useMinForageState
            entry.nextCheckAt = now + 750
        end
    end
    return added
end

-- A bounded linked queue avoids scanning every outstanding cell each frame.
-- Entries own a marker identity; new work invalidates that identity before write.
function TerraLogicQualityManager:enqueueHarvestCheck(entry)
    if entry.queued then return end
    entry.queued, entry.next = true, nil
    if self.harvestCheckTail then self.harvestCheckTail.next = entry
    else self.harvestCheckHead = entry end
    self.harvestCheckTail = entry
end

function TerraLogicQualityManager:cellHasRemainingHarvestFruit(position)
    local fruitTypeIndex = position ~= nil and position.fruitTypeIndex or nil
    if fruitTypeIndex == nil
        or (FruitType ~= nil and fruitTypeIndex == FruitType.UNKNOWN)
        or FSDensityMapUtil == nil
        or FSDensityMapUtil.getFruitArea == nil then
        return true, false
    end
    local minX = position.ix * self.CELL_SIZE
    local minZ = position.iz * self.CELL_SIZE
    local maxX = minX + self.CELL_SIZE
    local maxZ = minZ + self.CELL_SIZE
    local ok, area = pcall(
        FSDensityMapUtil.getFruitArea,
        fruitTypeIndex,
        minX, minZ,
        maxX, minZ,
        minX, maxZ,
        false,
        position.useMinForageState == true
    )
    if not ok or area == nil then return true, false end
    area = tonumber(area)
    if area == nil or area ~= area or area < 0 then return true, false end
    local pixelArea = g_currentMission ~= nil
        and g_currentMission.getFruitPixelsToSqm ~= nil
        and tonumber(g_currentMission:getFruitPixelsToSqm()) or nil
    return area > 0, true, pixelArea ~= nil and pixelArea > 0
        and area * pixelArea or nil
end

function TerraLogicQualityManager:isNegligibleHarvestRemainder(entry, areaSqm)
    if areaSqm == nil or areaSqm > 0.25
        or areaSqm > self.CELL_SIZE * self.CELL_SIZE * 0.02 then return false end
    local manager = TerraLogicSoilManager
    if manager == nil or manager.getRecoveryFruitStateInfo == nil then return false end
    local info = manager:getRecoveryFruitStateInfo(entry.fruitTypeIndex)
    if info == nil then return false end
    for source, regrows in pairs(info.regrowthSources or {}) do
        -- This table also contains ordinary growing-to-growing transitions.
        -- Only regrowth from a cut state makes the crop a repeat-harvest crop.
        if regrows and (info.cut or {})[source] then return false end
    end
    local util = FSDensityMapUtil
    if util == nil or util.getIsFieldAtWorldPos == nil then return false end
    -- Never apply the tolerance to mixed field-border cells or a detected young/
    -- different crop. Only tiny residual candidates pay for this extra check.
    local probe = probeCropOccupancyCell(self, entry.ix, entry.iz)
    if not probe.valid then return false end
    for _, sample in ipairs(probe.samples) do
        local ok, isField = pcall(util.getIsFieldAtWorldPos, sample.x, sample.z)
        if not ok or isField ~= true then return false end
        local fruit, state = sample.fruitTypeIndex, sample.growthState
        if fruit ~= nil and fruit > 0 and state ~= nil then
            local currentInfo = manager:getRecoveryFruitStateInfo(fruit)
            if currentInfo == nil then return false end
            local cut = (currentInfo.cut or {})[state] == true
            local dead = (currentInfo.withered or {})[state] == true
            if not cut and not dead then
                if fruit ~= entry.fruitTypeIndex then return false end
                local semantic = self:getSemanticPlowGrowthStage(fruit, state, nil)
                if semantic == nil or semantic < self.PLOW_GROWTH_STAGES then return false end
            end
        end
    end
    return true
end

function TerraLogicQualityManager:processHarvestCheck(entry, now)
    if self.pendingHarvestClears[entry.key] ~= entry
        or self.partialHarvestCells[entry.key] ~= entry.marker then return false end
    local remaining, known, areaSqm = self:cellHasRemainingHarvestFruit(entry)
    if known and not remaining then
        -- Harvestable-area queries alone cannot distinguish bare ground from
        -- young crops (including a partly cut forage crop after save/load).
        local probe = probeCropOccupancyCell(self, entry.ix, entry.iz)
        if not probe.valid then known = false end
        for _, sample in ipairs(probe.samples) do
            local fruit, state = sample.fruitTypeIndex, sample.growthState
            if fruit ~= nil and fruit > 0 and state ~= nil then
                local info = TerraLogicSoilManager ~= nil
                    and TerraLogicSoilManager:getRecoveryFruitStateInfo(fruit) or nil
                if info == nil then known = false
                elseif not (info.cut or {})[state] and not (info.withered or {})[state]
                    and not (fruit == entry.fruitTypeIndex and (info.regrowthSources or {})[state]) then
                    known = false
                end
            end
        end
    end
    local negligible = known and remaining
        and self:isNegligibleHarvestRemainder(entry, areaSqm)
    if known and (not remaining or negligible) then
        if negligible and entry.tinyObserved ~= true then
            entry.tinyObserved = true
            entry.nextCheckAt = now + 1000
            return false
        end
        local completed = self:completePartialHarvest(entry, "arable", false)
        if negligible and completed then
            -- Preserve only an acknowledgement, not quality. Picking up the
            -- last stalk later must not record a second rotation/biology cycle.
            entry.marker.remainderClosed = true
            self.partialHarvestCells[entry.key] = entry.marker
            self.dirty = true
        end
        return completed
    end
    entry.tinyObserved = false
    entry.nextCheckAt = now + (known and 10000 or 30000)
    return false
end

function TerraLogicQualityManager:flushPendingHarvestClears(cutter, maxCells)
    if g_currentMission == nil or not g_currentMission:getIsServer() then return 0 end
    local now = g_currentMission.time or 0
    if now < (self.harvestCheckNextTick or 0) then return 0 end
    self.harvestCheckNextTick = now + 100
    local checked, advanced, visited = 0, 0, 0
    local stop = self.harvestCheckTail
    while self.harvestCheckHead ~= nil and checked < (maxCells or 4) and visited < 32 do
        local entry = self.harvestCheckHead
        self.harvestCheckHead = entry.next
        if self.harvestCheckHead == nil then self.harvestCheckTail = nil end
        entry.next, entry.queued = nil, false
        visited = visited + 1
        if self.pendingHarvestClears[entry.key] == entry
            and self.partialHarvestCells[entry.key] == entry.marker then
            if now >= (entry.nextCheckAt or 0) then
                checked = checked + 1
                if self:processHarvestCheck(entry, now) then advanced = advanced + 1 end
            end
            if self.pendingHarvestClears[entry.key] == entry then self:enqueueHarvestCheck(entry) end
        elseif self.pendingHarvestClears[entry.key] == entry then
            self.pendingHarvestClears[entry.key] = nil
        end
        if entry == stop then break end
    end
    return advanced
end

function TerraLogicQualityManager:flushAllPendingHarvestClears()
    -- Save the remaining markers instead of an unbounded save-time density scan.
    -- The same bounded worker resumes them after loading.
    return self:flushPendingHarvestClears(nil, 4)
end

-- Records only cells accepted by both Vanilla's changed area and surface rules.
function TerraLogicQualityManager:recordWorkArea(
        workArea, component, quality, changedArea,
        yieldWeight, maxYieldPenalty, vehicle, explicitHarvestPenalty,
        allowedCellKeys, aggregateVanillaFertilizer,
        prevalidatedSurfaceCellKeys, seedSoilQualityLoss)
    if g_currentMission == nil or not g_currentMission:getIsServer()
        or tonumber(changedArea) == nil or changedArea <= 0
        or self.COMPONENTS[component] == nil then
        return 0, 0, false
    end
    local definition = self.COMPONENTS[component]
    if definition.physicalDropoutsOnly == true then
        return 0, 0, false
    end
    local group = definition.group or component
    local vehicleSpec = vehicle ~= nil and vehicle.spec_terraLogic or nil
    if vehicleSpec ~= nil then
        vehicleSpec.liveWorkQualityGroups = vehicleSpec.liveWorkQualityGroups or {}
        vehicleSpec.liveWorkQualityGroups[group] = {
            quality = math.clamp(tonumber(quality) or 1, 0, 1),
            yieldPenalty = explicitHarvestPenalty ~= nil
                and math.clamp(tonumber(explicitHarvestPenalty) or 0, 0, 1)
                or self:calculateYieldPenalty(
                    quality,
                    definition.yieldWeight,
                    definition.maxYieldPenalty
                ),
            time = g_currentMission.time or 0
        }
    end
    local changed, acceptedCells = false, 0
    local isApplication = group == "fertilizer"
        or group == "lime" or group == "herbicide"
    local touchedPositions = self:getTouchedCells(workArea, isApplication)
    for _, position in ipairs(touchedPositions) do
        local cellKey = tostring(position.ix) .. ":" .. tostring(position.iz)
        local surfaceAllowed = prevalidatedSurfaceCellKeys ~= nil
                and prevalidatedSurfaceCellKeys[cellKey] == true
            or self:isComponentAllowedAtCell(
                component, position.ix, position.iz, vehicle)
        if (allowedCellKeys == nil or allowedCellKeys[cellKey] == true)
            and surfaceAllowed then
            acceptedCells = acceptedCells + 1
            -- Any successful agronomic pass after a partial harvest belongs to
            -- the next cycle. Close only that cell's marked arable/field-grass
            -- cycle before writing the new work; natural meadow has no marker.
            changed = self:completePartialHarvestBeforeNewWork(position)
                or changed
            -- Invalidate only after Vanilla reported a successful pass and
            -- only in the same TerraLogic cell admitted for the new component.
            changed = self:clearOverwrittenComponents(
                position, component) or changed
            if self:setCellComponent(
                    position.ix, position.iz, component, quality,
                    yieldWeight, maxYieldPenalty, explicitHarvestPenalty,
                    aggregateVanillaFertilizer, seedSoilQualityLoss) then
                changed = true
            end
        end
    end
    if acceptedCells > 0 and vehicleSpec ~= nil then
        vehicleSpec.lastActualWorkTime = g_currentMission.time or 0
        vehicleSpec.lastActualWorkProfile = group
        vehicleSpec.lastQualityWorkTime = g_currentMission.time or 0
        local stateChanged = false
        if vehicleSpec.actualWorkActive ~= true then
            vehicleSpec.actualWorkActive = true
            stateChanged = true
        end
        if vehicleSpec.qualityWorkActive ~= true then
            vehicleSpec.qualityWorkActive = true
            stateChanged = true
        end
        if vehicle ~= nil and vehicle.isServer and stateChanged then
            vehicle:raiseDirtyFlags(vehicleSpec.actualWorkDirtyFlag)
        end
    end
    if changed then self.dirty = true end
    return acceptedCells, #touchedPositions, changed
end

-- Direct drills may publish their fruit-density write one or two frames after
-- the sowing WorkArea callback. Record the already verified cells here without
-- broadening them to the complete implement rectangle or overwriting overlaps.
function TerraLogicQualityManager:recordDeferredSeedCells(
        positions, allowedCellKeys, quality, yieldWeight, maxYieldPenalty,
        vehicle, explicitHarvestPenalty, seedSoilQualityLoss)
    if g_currentMission == nil or not g_currentMission:getIsServer()
        or positions == nil or allowedCellKeys == nil then return 0, false end
    local accepted, changed = 0, false
    for _, position in ipairs(positions) do
        local key = tostring(position.ix) .. ":" .. tostring(position.iz)
        if allowedCellKeys[key] == true
            and self:isComponentAllowedAtCell(
                "seed", position.ix, position.iz, vehicle) then
            accepted = accepted + 1
            changed = self:completePartialHarvestBeforeNewWork(position)
                or changed
            changed = self:clearOverwrittenComponents(position, "seed")
                or changed
            changed = self:setCellComponent(
                position.ix, position.iz, "seed", quality,
                yieldWeight, maxYieldPenalty, explicitHarvestPenalty,
                false, seedSoilQualityLoss) or changed
        end
    end
    local spec = vehicle ~= nil and vehicle.spec_terraLogic or nil
    if accepted > 0 and spec ~= nil then
        local now = g_currentMission.time or 0
        spec.lastActualWorkTime = now
        spec.lastActualWorkProfile = "seed"
        spec.lastQualityWorkTime = now
        spec.actualWorkActive = true
        spec.qualityWorkActive = true
        spec.liveWorkQualityGroups = spec.liveWorkQualityGroups or {}
        spec.liveWorkQualityGroups.seed = {
            quality=math.clamp(tonumber(quality) or 1, 0, 1),
            yieldPenalty=math.clamp(
                tonumber(explicitHarvestPenalty) or 0, 0, 1),
            time=now
        }
    end
    if changed then self.dirty = true end
    return accepted, changed
end

-- Tillage quality is now represented exclusively by the persistent physical
-- soil maps.  This companion path keeps the live HUD state and crop-cycle
-- invalidation of a successful pass without writing a second, gradually
-- ageing soilPlow/soilCultivate quality ledger.
function TerraLogicQualityManager:recordDynamicSoilWorkArea(
        workArea, component, quality, changedArea, vehicle,
        allowedCellKeys)
    if g_currentMission == nil or not g_currentMission:getIsServer()
        or tonumber(changedArea) == nil or changedArea <= 0
        or (component ~= "soilPlow" and component ~= "soilCultivate") then
        return 0, 0, false
    end
    local vehicleSpec = vehicle ~= nil and vehicle.spec_terraLogic or nil
    if vehicleSpec ~= nil then
        vehicleSpec.liveWorkQualityGroups = vehicleSpec.liveWorkQualityGroups or {}
        vehicleSpec.liveWorkQualityGroups.soil = {
            quality = math.clamp(tonumber(quality) or 1, 0, 1),
            yieldPenalty = 0,
            time = g_currentMission.time or 0
        }
    end
    local changed, acceptedCells = false, 0
    local touchedPositions = self:getTouchedCells(workArea, false)
    for _, position in ipairs(touchedPositions) do
        local cellKey = tostring(position.ix) .. ":" .. tostring(position.iz)
        local allowed = allowedCellKeys ~= nil
            and allowedCellKeys[cellKey] == true
        local surfaceAllowed = allowed
        if allowedCellKeys == nil then
            surfaceAllowed = self:isComponentAllowedAtCell(
                component, position.ix, position.iz, vehicle)
        end
        if surfaceAllowed then
            acceptedCells = acceptedCells + 1
            changed = self:completePartialHarvestBeforeNewWork(position)
                or changed
            changed = self:clearOverwrittenComponents(position, component)
                or changed
            -- Remove legacy soil ledgers opportunistically when this ground is
            -- worked by the new physical model.
            changed = self:clearCellComponent(position, "soilPlow") or changed
            changed = self:clearCellComponent(position, "soilCultivate") or changed
        end
    end
    if acceptedCells > 0 and vehicleSpec ~= nil then
        vehicleSpec.lastActualWorkTime = g_currentMission.time or 0
        vehicleSpec.lastActualWorkProfile = "soil"
        vehicleSpec.lastQualityWorkTime = g_currentMission.time or 0
        local stateChanged = false
        if vehicleSpec.actualWorkActive ~= true then
            vehicleSpec.actualWorkActive = true
            stateChanged = true
        end
        if vehicleSpec.qualityWorkActive ~= true then
            vehicleSpec.qualityWorkActive = true
            stateChanged = true
        end
        if vehicle ~= nil and vehicle.isServer and stateChanged then
            vehicle:raiseDirtyFlags(vehicleSpec.actualWorkDirtyFlag)
        end
    end
    if changed then self.dirty = true end
    return acceptedCells, #touchedPositions, changed
end

function TerraLogicQualityManager:getSpeedQualityForSpeeds(
        realSpeed, shopSpeed, currentSpeed)
    return self:getSpeedEconomyForSpeeds(
        realSpeed, shopSpeed, currentSpeed).preShopQuality
end

function TerraLogicQualityManager:getSpeedQuality(vehicle, currentSpeed)
    return self:getSpeedEconomy(vehicle, currentSpeed).preShopQuality
end

function TerraLogicQualityManager:getRootCropHarvesterPenalty(cutter)
    -- Harvesters and headers are deliberately outside TerraLogic's implement
    -- simulation. The common Cutter hook below only applies quality already
    -- stored by earlier field work; harvesting speed itself adds no penalty.
    return 0, 1, "stored field quality only"
end

function TerraLogicQualityManager:getCellAtWorldPosition(x, z, fallbackX, fallbackZ)
    local ix, iz = getCellIndex(x), getCellIndex(z)
    if g_currentMission == nil or g_currentMission:getIsServer() then
        return self:getPackedCell(ix, iz), false
    end
    local key = tostring(ix) .. ":" .. tostring(iz)
    local cached = self.clientCells[key]
    local now = g_currentMission.time or 0
    if g_client ~= nil and (self.lastClientRequestKey ~= key
        or now >= (self.nextClientRequestTime or 0)) then
        local connection = g_client:getServerConnection()
        if connection ~= nil and TerraLogicQualityRequestEvent ~= nil then
            connection:sendEvent(TerraLogicQualityRequestEvent.new(
                ix, iz, x, z, fallbackX or x, fallbackZ or z))
            self.lastClientRequestKey = key
            self.nextClientRequestTime = now + 1000
        end
    end
    -- A missing cache entry means that the client is waiting for this exact
    -- cell. `false` is different: the server has answered and confirmed that
    -- no stored TerraLogic quality exists there. Exposing that distinction lets
    -- the HUD bridge network latency without retaining stale field data after
    -- an authoritative empty response.
    if cached == nil then return nil, true end
    return cached ~= false and cached or nil, false
end

function TerraLogicQualityManager:getSummaryAtWorldPosition(x, z, fallbackX, fallbackZ)
    -- The quality box describes the land under the player, not the camera
    -- crosshair or an averaged neighbouring footprint.
    local cell, requestPending = self:getCellAtWorldPosition(x, z)
    local entries = cell ~= nil and self:getGroupedEntriesFromCell(cell) or {}
    local surface = self:getSurfaceTypeAtWorldPosition(x, z)
    if TerraLogicSoilManager ~= nil
        and (surface == "field" or surface == "grassField") then
        local state = TerraLogicSoilManager:getStateAtWorldPosition(x, z)
        local soilQuality = TerraLogicSoilManager:getTillageQualityFromState(state)
        local ix, iz = getCellIndex(x), getCellIndex(z)
        local cellCenterX = (ix + 0.5) * self.CELL_SIZE
        local cellCenterZ = (iz + 0.5) * self.CELL_SIZE
        local rootFactor, shallowLoss, deepLoss =
            TerraLogicSoilManager:getRootYieldFactorForArea(
                cellCenterX, cellCenterZ, self.CELL_SIZE)
        local _, _, chunkKey, offset = getChunkPosition(ix, iz)
        local projected = nil
        if cell ~= nil and (cell.rootYieldSteps or 0) > 0
            and cell.rootYieldAverage ~= nil then
            local steps = math.clamp(cell.rootYieldSteps,
                0, self.PLOW_GROWTH_STAGES)
            projected = (cell.rootYieldAverage * steps
                + rootFactor * (self.PLOW_GROWTH_STAGES - steps))
                / self.PLOW_GROWTH_STAGES
        else
            projected = self:getGrowthRootYieldFactor({
                ix=ix, iz=iz, chunkKey=chunkKey, offset=offset
            }, false, true)
        end
        if projected ~= nil then rootFactor = projected end
        if soilQuality ~= nil then
            table.insert(entries, 1, {
                name = "soil",
                label = self:getComponentLabel("soil"),
                quality = soilQuality,
                yieldPenalty = 0,
                harvestPenalty = 0,
                affectsYield = false,
                rootYieldFactor = rootFactor,
                rootShallowLoss = shallowLoss,
                rootDeepLoss = deepLoss,
                dynamicSoil = true
            })
        end
    end
    if #entries == 0 then
        return nil, nil, requestPending == true
    end
    local sum, count = 0, #entries
    for _, entry in ipairs(entries) do sum = sum + entry.quality end
    return count > 0 and sum / count or nil, entries, false
end

function TerraLogicQualityManager:getGroupedEntriesFromCell(cell)
    local grouped = {}
    for _, component in ipairs(self.COMPONENT_ORDER) do
        local definition = self.COMPONENTS[component]
        if hasBit(cell.mask or 0, definition.bit)
            and definition.physicalDropoutsOnly ~= true then
            local group = definition.group or component
            local value = grouped[group]
            if value == nil then
                value = {
                    qualitySum = 0,
                    harvestPenaltySum = 0,
                    applicationCountSum = 0,
                    count = 0
                }
                grouped[group] = value
            end
            value.qualitySum = value.qualitySum
                + ((cell.values or {})[component] or 1)
            value.harvestPenaltySum = value.harvestPenaltySum
                + ((cell.penalties or {})[component] or 0)
            value.applicationCountSum = value.applicationCountSum
                + ((cell.applicationCounts or {})[component] or 1)
            value.count = value.count + 1
        end
    end
    local entries = {}
    for _, group in ipairs(self.GROUP_ORDER) do
        local value = grouped[group]
        local definition = self.GROUP_DEFINITIONS[group]
        if group ~= "soil" and value ~= nil and value.count > 0
            and definition ~= nil then
            local quality = value.qualitySum / value.count
            -- New records persist the category-specific economic result. Old
            -- saves without an explicit penalty still receive their legacy
            -- quality-derived fallback during migration/display.
            local storedPenalty = value.harvestPenaltySum / value.count
            local qualityPenalty = math.clamp(
                (definition.maxYieldPenalty or 0) * (1 - quality), 0,
                definition.maxYieldPenalty or 0)
            local targetPenalty = definition.directDensityPenalty == true
                and qualityPenalty or (storedPenalty > 0 and storedPenalty
                or (quality < 0.9995 and self:calculateYieldPenalty(
                    quality,
                    definition.yieldWeight,
                    definition.maxYieldPenalty
                ) or 0))
            local applicationCount = math.max(math.floor(
                value.applicationCountSum / value.count + 0.5), 1)
            local bonusDefinition = self.BONUS_GROUPS[group]
            local effectiveBonus = nil
            if bonusDefinition ~= nil then
                local denominator = 1 - quality - targetPenalty
                local inferredUnitBonus = denominator > 0.0001
                    and targetPenalty / denominator
                    or math.max(tonumber(bonusDefinition.bonus) or 0, 0)
                effectiveBonus = math.max(inferredUnitBonus, 0)
                    * applicationCount
            end
            entries[#entries + 1] = {
                name = group,
                label = self:getComponentLabel(group),
                quality = quality,
                yieldPenalty = targetPenalty,
                harvestPenalty = definition.directDensityPenalty == true
                    and storedPenalty or targetPenalty,
                directDensityPenalty = definition.directDensityPenalty == true,
                contributors = value.count,
                applicationCount = applicationCount,
                bonus = effectiveBonus
            }
        end
    end
    return entries
end

function TerraLogicQualityManager:getEffectiveYieldFactor(entries, useHarvestPenalty)
    local storedLoss, directDensityFactor = 0, 1
    local idealBonus, retainedBonus = 0, 0
    local rootYieldFactor = 1
    for _, entry in ipairs(entries or {}) do
        local definition = self.GROUP_DEFINITIONS[entry.name]
        local penalty = math.clamp(tonumber(useHarvestPenalty
            and entry.harvestPenalty or entry.yieldPenalty) or 0, 0, 1)
        local bonus = math.max(tonumber(entry.bonus) or 0, 0)
        if entry.rootYieldFactor ~= nil then
            rootYieldFactor = rootYieldFactor
                * math.clamp(tonumber(entry.rootYieldFactor) or 1, 0, 1)
        elseif definition ~= nil and definition.affectsYield == false then
            -- Retain the quality entry for HUD/diagnostics, but never convert
            -- its historical penalty or bonus into another yield channel.
        elseif bonus > 0 then
            idealBonus = idealBonus + bonus
            retainedBonus = retainedBonus
                + bonus * math.clamp(tonumber(entry.quality) or 1, 0, 1)
        elseif definition ~= nil and definition.directDensityPenalty == true then
            directDensityFactor = directDensityFactor * (1 - penalty)
        else
            storedLoss = storedLoss + penalty
        end
    end
    local bonusFactor = (1 + retainedBonus) / math.max(1 + idealBonus, 0.0001)
    return math.clamp(
        rootYieldFactor * directDensityFactor
            * (1 - math.min(storedLoss, self.MAXIMUM_TOTAL_YIELD_PENALTY))
            * bonusFactor,
        0,
        1
    )
end

local function yieldSmoothStep(value)
    value = math.clamp(tonumber(value) or 0, 0, 1)
    return value * value * (3 - 2 * value)
end

-- Converts every TerraLogic cause into one continuous signed harvest factor.
-- The lower branch spreads real losses; the upper branch is reachable only
-- when every critical part of the same assessment is healthy. It is therefore
-- not a separate flat bonus and cannot hide a serious soil or work problem.
function TerraLogicQualityManager:getTerraLogicYieldFactor(
        entries, rootFactor, moistureFactor, moistureEnabled,
        liveFactor, resilience)
    entries = entries or {}
    rootFactor = math.clamp(tonumber(rootFactor) or 1, 0, 1)
    moistureFactor = moistureEnabled == false and 1
        or math.clamp(tonumber(moistureFactor) or 1, 0, 1)
    liveFactor = math.clamp(tonumber(liveFactor) or 1, 0, 1)
    resilience = math.clamp(tonumber(resilience) or 0.50, 0, 1)

    -- HUD/analysis summaries may prepend a synthetic soil entry containing the
    -- same root factor supplied explicitly below. Exclude it here so diagnostic
    -- callers cannot charge compaction twice; persisted cell entries never
    -- contain this synthetic record.
    local ledgerEntries = {}
    for _, entry in ipairs(entries) do
        if entry.rootYieldFactor == nil then
            ledgerEntries[#ledgerEntries + 1] = entry
        end
    end
    local ledgerFactor = self:getEffectiveYieldFactor(ledgerEntries, true)
    local rootZoneFactor = math.max(
        rootFactor * moistureFactor, self.MINIMUM_ROOT_ZONE_FACTOR)
    local retainedFactor = math.clamp(
        liveFactor * ledgerFactor * rootZoneFactor, 0, 1)

    -- Make mediocre and poor results economically visible without a threshold.
    -- Biological resilience is reflected through soil development only.
    -- Retained as a zero-valued diagnostic for existing HUD/audit consumers.
    -- Resilience affects soil development, never the harvest directly.
    local resiliencePenalty = 0
    -- Root-zone losses retain their independent 35% ceiling. Widen their
    -- middle range inside that fixed interval, then spread fieldwork/harvest
    -- errors separately. Only combined causes reach the overall 40% floor.
    local rootProgress = math.clamp(
        (rootZoneFactor-self.MINIMUM_ROOT_ZONE_FACTOR)
            / math.max(1-self.MINIMUM_ROOT_ZONE_FACTOR, 0.0001), 0, 1)
    local spreadRootFactor = self.MINIMUM_ROOT_ZONE_FACTOR
        + (1-self.MINIMUM_ROOT_ZONE_FACTOR)
            * rootProgress ^ self.ROOT_ZONE_SPREAD_EXPONENT
    local executionFactor = math.clamp(liveFactor*ledgerFactor, 0, 1)
        ^ self.YIELD_LOSS_SPREAD_EXPONENT
    local lossFactor = spreadRootFactor * executionFactor
        * (1 - resiliencePenalty)

    local minimumWorkQuality = 1
    local workQualitySum, workQualityCount = 0, 0
    local seedQuality, hasSeedRecord = 0, false
    for _, entry in ipairs(entries) do
        local definition = self.GROUP_DEFINITIONS[entry.name]
        if definition == nil or definition.affectsYield ~= false then
            local quality = math.clamp(tonumber(entry.quality) or 1, 0, 1)
            minimumWorkQuality = math.min(minimumWorkQuality, quality)
            workQualitySum = workQualitySum + quality
            workQualityCount = workQualityCount + 1
            if entry.name == "seed" then
                seedQuality, hasSeedRecord = quality, true
            end
        end
    end
    local averageWorkQuality = workQualityCount > 0
        and workQualitySum / workQualityCount or 0

    local rootScore = yieldSmoothStep((rootFactor - 0.95) / 0.05)
    local moistureScore = moistureEnabled == false and 1
        or yieldSmoothStep((moistureFactor - 0.95) / 0.05)
    local workScore = yieldSmoothStep((averageWorkQuality - 0.95) / 0.05)
    local excellenceScore = rootScore * 0.40 + moistureScore * 0.20
        + workScore * 0.40

    -- A recorded, clean establishment is required for the positive branch.
    -- The gates are smooth: no damage or reward changes at one exact percent.
    -- One weakest-link gate replaces overlapping multiplicative gates.
    -- Resilience influences soil development, not eligibility for excellence.
    -- Missing sowing records never create an unearned positive contribution.
    local limitingQuality = math.min(rootFactor, moistureFactor,
        minimumWorkQuality, seedQuality, liveFactor)
    local positiveGate = hasSeedRecord
        and yieldSmoothStep((limitingQuality - 0.90) / 0.09) or 0
    local positivePotential = 0.10 * excellenceScore * positiveGate
    local finalFactor = math.clamp(
        lossFactor + positivePotential,
        self.MINIMUM_FINAL_YIELD_FACTOR,
        self.MAXIMUM_FINAL_YIELD_FACTOR)

    return finalFactor, {
        ledgerFactor=ledgerFactor,
        rootZoneFactor=rootZoneFactor,
        spreadRootFactor=spreadRootFactor,
        executionFactor=executionFactor,
        retainedFactor=retainedFactor,
        resiliencePenalty=resiliencePenalty,
        lossFactor=lossFactor,
        positivePotential=positivePotential,
        excellenceScore=excellenceScore,
        positiveGate=positiveGate,
        minimumWorkQuality=minimumWorkQuality,
        averageWorkQuality=averageWorkQuality,
        seedQuality=seedQuality,
        hasSeedRecord=hasSeedRecord
    }
end

function TerraLogicQualityManager:getAverageStoredYieldFactor(
        workArea, touchedCells, fruitTypeIndex, liveFactor)
    local factorSum, samples, touched = 0, 0,
        touchedCells or self:getTouchedCells(workArea)
    for _, position in ipairs(touched) do
        local cell = self:getPackedCell(position.ix, position.iz)
        local rootFactor = self:getGrowthRootYieldFactor(
            position, true, false)
        if rootFactor == nil and TerraLogicSoilManager ~= nil then
            rootFactor = TerraLogicSoilManager:getRootYieldFactorForArea(
                (position.ix + 0.5) * self.CELL_SIZE,
                (position.iz + 0.5) * self.CELL_SIZE,
                self.CELL_SIZE)
        end
        local moistureFactor = self:getGrowthMoistureYieldFactor(
            position, false, false) or 1
        if TerraLogicSettings == nil
            or not TerraLogicSettings:getMoistureYieldEnabled() then
            moistureFactor = 1
        end
        local resilience = TerraLogicSoilManager ~= nil
            and TerraLogicSoilManager:getValueAtWorldPosition(
                "resilience",
                (position.ix + 0.5) * self.CELL_SIZE,
                (position.iz + 0.5) * self.CELL_SIZE) or 0.50
        local factor = self:getTerraLogicYieldFactor(
            cell ~= nil and self:getGroupedEntriesFromCell(cell) or {},
            rootFactor, moistureFactor,
            TerraLogicSettings == nil
                or TerraLogicSettings:getMoistureYieldEnabled(),
            liveFactor or 1, resilience)
        factorSum = factorSum + factor
        samples = samples + 1
    end
    return samples > 0 and factorSum / samples or 1, touched
end

function TerraLogicQualityManager:getAverageStoredYieldLoss(
        workArea, touchedCells, fruitTypeIndex)
    local factor, touched = self:getAverageStoredYieldFactor(
        workArea, touchedCells, fruitTypeIndex, 1)
    return math.max(1-factor, 0), touched, factor
end

-- Applies the stored total-yield factor before harvested material is credited.
function TerraLogicQualityManager:applyHarvestQuality(
    cutter, workArea, harvestedArea, multiplierAreaBefore,
    liveHarvestPenalty, liveHarvestQuality, liveHarvestClass,
    fruitTypeIndex, useMinForageState, spatialCapture)
    if g_currentMission == nil or not g_currentMission:getIsServer() then return end
    local params = cutter ~= nil and cutter.spec_cutter ~= nil
        and cutter.spec_cutter.workAreaParameters or nil
    harvestedArea = tonumber(harvestedArea) or 0
    if harvestedArea <= 0 then return end
    if TerraLogicTutorialManager ~= nil then
        TerraLogicTutorialManager:observeHarvest(cutter, harvestedArea)
    end
    local factorSum, legacyFactorSum, weightSum = 0, 0, 0
    local samples, storedSamples, penalizedSamples = 0, 0, 0
    local rootLossSum, moistureLossSum = 0, 0
    local positivePotentialSum, resiliencePenaltySum = 0, 0
    local touched = {}
    if spatialCapture ~= nil and next(spatialCapture.cells or {}) ~= nil then
        for _, position in pairs(spatialCapture.cells) do
            touched[#touched + 1] = position
        end
    else
        touched = self:getTouchedCells(workArea)
        if spatialCapture == nil then
            spatialCapture = {
                processedWorkAreas=workArea ~= nil and 1 or 0,
                successfulWorkAreas=workArea ~= nil and 1 or 0,
                configuredWorkAreas=workArea ~= nil and 1 or 0,
                harvestedArea=harvestedArea, multiplierArea=0,
                probeSamples=0, cropProbeSamples=0
            }
        end
        spatialCapture.fallbackUsed = true
        spatialCapture.fallbackReason =
            spatialCapture.fallbackReason ~= nil
                and spatialCapture.fallbackReason ~= "none"
                and spatialCapture.fallbackReason
                or "legacy_work_area_fallback"
    end
    for _, position in ipairs(touched) do
        local cell = self:getPackedCell(position.ix, position.iz)
        -- Crop-cycle biology is independent of whether this cell already has
        -- a Work Quality ledger (for example a crop present when TerraLogic
        -- was first installed).
        self:markPartialHarvest(position, "arable", fruitTypeIndex)
        local liveFactor = 1 - math.clamp(
            tonumber(liveHarvestPenalty) or 0, 0, 1)
        local entries = {}
        if cell ~= nil then
            storedSamples = storedSamples + 1
            -- Stored penalties are relative losses of the complete local
            -- Vanilla/PF yield. A missing operation remains neutral because
            -- Vanilla/PF already owns its normal base-game bonus.
            -- Seed stores only the residual target loss not already
            -- represented by physical missing plants. Bonus groups are
            -- combined as one earned-bonus block, preventing several poor
            -- bonus passes from ever pushing yield below the prior baseline.
            entries = self:getGroupedEntriesFromCell(cell)
        end
        local rootFactor = self:getGrowthRootYieldFactor(
            position, true, false)
        if rootFactor == nil and TerraLogicSoilManager ~= nil then
            rootFactor = TerraLogicSoilManager:getRootYieldFactorForArea(
                (position.ix + 0.5) * self.CELL_SIZE,
                (position.iz + 0.5) * self.CELL_SIZE,
                self.CELL_SIZE)
        end
        local rootLoss = 1 - math.clamp(rootFactor, 0, 1)
        local weight = math.max(tonumber(position.multiplierWeight) or 0, 0)
        if weight <= 0 then
            weight = math.max(tonumber(position.areaWeight) or 0, 0)
        end
        if weight <= 0 then weight = 1 end
        rootLossSum = rootLossSum + rootLoss * weight
        local moistureFactor = self:getGrowthMoistureYieldFactor(
            position, false, false) or 1
        if TerraLogicSettings == nil
            or not TerraLogicSettings:getMoistureYieldEnabled() then
            moistureFactor = 1
        end
        moistureLossSum = moistureLossSum
            + (1 - math.clamp(moistureFactor, 0, 1)) * weight
        local x = (position.ix + 0.5) * self.CELL_SIZE
        local z = (position.iz + 0.5) * self.CELL_SIZE
        local resilience = TerraLogicSoilManager ~= nil
            and TerraLogicSoilManager:getValueAtWorldPosition(
                "resilience", x, z) or 0.50
        local factor, detail = self:getTerraLogicYieldFactor(
            entries, rootFactor, moistureFactor,
            TerraLogicSettings == nil
                or TerraLogicSettings:getMoistureYieldEnabled(),
            liveFactor, resilience)
        -- A live root-crop harvesting loss is independent of the stored field
        -- operations, so it must also count when this cell has no TerraLogic record.
        factorSum = factorSum + factor * weight
        legacyFactorSum = legacyFactorSum + factor
        weightSum = weightSum + weight
        positivePotentialSum = positivePotentialSum
            + (detail.positivePotential or 0) * weight
        resiliencePenaltySum = resiliencePenaltySum
            + (detail.resiliencePenalty or 0) * weight
        if factor < 0.9999 then penalizedSamples = penalizedSamples + 1 end
        samples = samples + 1
    end
    local averageFactor = weightSum > 0 and factorSum / weightSum or 1
    local legacyAverageFactor = samples > 0
        and legacyFactorSum / samples or averageFactor
    local averageLoss = math.max(1 - averageFactor, 0)
    local averageGain = math.max(averageFactor - 1, 0)
    local oldMultiplierArea = -1
    local relativeAppliedChange = 0
    if params ~= nil and params.lastMultiplierArea ~= nil then
        oldMultiplierArea = tonumber(params.lastMultiplierArea) or 0
        local currentBaseArea = oldMultiplierArea
            - math.max(tonumber(multiplierAreaBefore) or 0, 0)
        if currentBaseArea <= 0 then currentBaseArea = oldMultiplierArea end
        local previousArea = math.max(oldMultiplierArea - currentBaseArea, 0)
        local newMultiplierArea = math.max(
            previousArea + currentBaseArea * averageFactor, 0)
        local appliedAreaDelta = newMultiplierArea - oldMultiplierArea
        params.lastMultiplierArea = newMultiplierArea
        self.lastHarvestDebug = {
            averageFactor = averageFactor,
            averageLoss = averageLoss,
            averageGain = averageGain,
            baseMultiplier = harvestedArea > 0
                and currentBaseArea / harvestedArea or 0,
            finalMultiplier = harvestedArea > 0
                and math.max(
                    currentBaseArea * averageFactor,
                    0
                )
                    / harvestedArea or 0,
            appliedDeduction = harvestedArea > 0
                and math.max(-appliedAreaDelta, 0) / harvestedArea or 0,
            appliedIncrease = harvestedArea > 0
                and math.max(appliedAreaDelta, 0) / harvestedArea or 0,
            appliedDelta = harvestedArea > 0
                and appliedAreaDelta / harvestedArea or 0,
            relativeLoss = currentBaseArea > 0
                and math.max(-appliedAreaDelta / currentBaseArea, 0) or 0,
            relativeGain = currentBaseArea > 0
                and math.max(appliedAreaDelta / currentBaseArea, 0) or 0,
            relativeChange = currentBaseArea > 0
                and appliedAreaDelta / currentBaseArea or 0,
            samples = samples,
            weightedCells = samples,
            touchedCells = samples,
            weightSum = weightSum,
            legacyAverageFactor = legacyAverageFactor,
            spatialFactorDelta = averageFactor - legacyAverageFactor,
            harvestedArea = harvestedArea,
            capturedArea = tonumber(spatialCapture.harvestedArea) or 0,
            capturedMultiplierArea =
                tonumber(spatialCapture.multiplierArea) or 0,
            configuredWorkAreas =
                tonumber(spatialCapture.configuredWorkAreas) or 0,
            processedWorkAreas =
                tonumber(spatialCapture.processedWorkAreas) or 0,
            successfulWorkAreas =
                tonumber(spatialCapture.successfulWorkAreas) or 0,
            probeSamples = tonumber(spatialCapture.probeSamples) or 0,
            cropProbeSamples =
                tonumber(spatialCapture.cropProbeSamples) or 0,
            queryErrorSamples =
                tonumber(spatialCapture.queryErrorSamples) or 0,
            noFruitSamples =
                tonumber(spatialCapture.noFruitSamples) or 0,
            disallowedFruitSamples =
                tonumber(spatialCapture.disallowedFruitSamples) or 0,
            missingGrowthSamples =
                tonumber(spatialCapture.missingGrowthSamples) or 0,
            unharvestableSamples =
                tonumber(spatialCapture.unharvestableSamples) or 0,
            validFruitSamples =
                tonumber(spatialCapture.validFruitSamples) or 0,
            fallbackUsed = spatialCapture.fallbackUsed == true,
            fallbackReason = spatialCapture.fallbackReason or "none",
            averageRootLoss = weightSum > 0 and rootLossSum / weightSum or 0,
            averageMoistureLoss = weightSum > 0
                and moistureLossSum / weightSum or 0,
            averagePositivePotential = weightSum > 0
                and positivePotentialSum / weightSum or 0,
            averageResiliencePenalty = weightSum > 0
                and resiliencePenaltySum / weightSum or 0,
            liveHarvestPenalty = liveHarvestPenalty or 0,
            liveHarvestQuality = liveHarvestQuality or 1,
            liveHarvestClass = liveHarvestClass or "none",
            time = g_currentMission.time or 0
        }
        relativeAppliedChange = self.lastHarvestDebug.relativeChange
    end
    -- Do not clear a fixed four-metre cell on the header's first narrow
    -- contact. A later zero-area frame checks the complete cell and advances
    -- its crop-cycle ledger only after the matching fruit is actually gone.
    local newlyPending = self:scheduleHarvestClear(
        cutter,
        touched,
        fruitTypeIndex,
        useMinForageState
    )
    if TerraLogicLogging ~= nil and TerraLogicLogging.verbose == true then
        local now = g_currentMission.time or 0
        local state = self.harvestDiagnosticState[cutter]
        local changed = state == nil
            or state.storedSamples ~= storedSamples
            or state.penalizedSamples ~= penalizedSamples
            or math.abs((state.averageLoss or 0) - averageLoss) >= 0.005
        local intervalElapsed = state == nil
            or now - (state.lastLogTime or 0) >= 250
        if (changed or intervalElapsed)
            and (self.harvestDiagnosticCount or 0) < 160 then
            local pendingCount = 0
            for _ in pairs(self.pendingHarvestClears) do pendingCount = pendingCount + 1 end
            self.harvestDiagnosticCount =
                (self.harvestDiagnosticCount or 0) + 1
            TerraLogicLogging.debug(
                "[FS25_TerraLogic] Harvest sample: area=%.4f multiplierArea=%.4f cells=%d stored=%d penalized=%d factor=%.2f%% change=%+.2f%% pending=%d(+%d) fruit=%s liveClass=%s",
                harvestedArea,
                oldMultiplierArea,
                samples,
                storedSamples,
                penalizedSamples,
                averageFactor * 100,
                relativeAppliedChange * 100,
                pendingCount,
                newlyPending,
                tostring(fruitTypeIndex),
                tostring(liveHarvestClass or "none")
            )
            self.harvestDiagnosticState[cutter] = {
                storedSamples = storedSamples,
                penalizedSamples = penalizedSamples,
                averageLoss = averageLoss,
                lastLogTime = now
            }
        end
    end
end

-- Persistence ---------------------------------------------------------------

-- Returns the primary quality-ledger path in the active savegame.
function TerraLogicQualityManager:getSavePath()
    local info = g_currentMission ~= nil and g_currentMission.missionInfo or nil
    local directory = info ~= nil and info.savegameDirectory or nil
    return directory ~= nil and directory .. "/" .. self.SAVE_FILE or nil
end

function TerraLogicQualityManager:getLegacySavePath()
    local info = g_currentMission ~= nil and g_currentMission.missionInfo or nil
    local directory = info ~= nil and info.savegameDirectory or nil
    return directory ~= nil and directory .. "/" .. self.LEGACY_SAVE_FILE or nil
end

-- Keep one redundant copy outside the savegame directory. GIANTS rewrites a
-- save slot when saving; if a broken/disabled mod cannot recreate its custom
-- file during that pass, the slot copy can disappear. The mirror survives
-- such a pass and is automatically used by the next working mod version.
function TerraLogicQualityManager:getMirrorPath(createDirectory, legacy)
    if getUserProfileAppPath == nil then return nil end
    local info = g_currentMission ~= nil and g_currentMission.missionInfo or nil
    local directory = info ~= nil and info.savegameDirectory or nil
    local slot = info ~= nil and tonumber(info.savegameIndex) or nil
    if slot == nil and directory ~= nil then
        slot = tonumber(string.match(directory, "savegame(%d+)"))
    end
    if slot == nil then return nil end
    local mirrorDirectory = getUserProfileAppPath() .. "modSettings/"
        .. (legacy == true and "FS25_OverSpeedDamage" or "FS25_TerraLogic")
    if createDirectory == true and createFolder ~= nil then
        pcall(createFolder, mirrorDirectory)
    end
    return string.format(
        "%s/savegame%d_%s", mirrorDirectory, slot,
        legacy == true and self.LEGACY_SAVE_FILE or self.SAVE_FILE)
end

-- Loads current data, legacy data, or the redundant mirror in that order.
function TerraLogicQualityManager:load()
    self.chunks = {}
    self.applicationCellStamps = {}
    self.pendingHarvestClears = {}
    self.harvestCheckHead, self.harvestCheckTail, self.harvestCheckNextTick = nil, nil, nil
    self.pendingMowerClears = {}
    self.partialHarvestCells = {}
    self.plowGrowthPending = false
    self.plowGrowthDelayRemaining = 0
    self.plowGrowthJob = nil
    self.plowGrowthQueuedAfterJob = false
    self.plowGrowthStateMaps = {}
    self.growthScanSerial = 0
    self:resetHarvestDiagnostics()
    self.pruneChunkKeys = nil
    self.pruneChunkIndex = nil
    self.pruneOffset = nil
    self.pruneRemoved = 0
    local path = self:getSavePath()
    if path == nil or fileExists == nil then return end
    local loadPath = path
    local mirrorPath = self:getMirrorPath(false)
    local legacyPath = self:getLegacySavePath()
    local legacyMirrorPath = self:getMirrorPath(false, true)
    local recoveredFromMirror = false
    local migratedFromLegacy = false
    if not fileExists(loadPath) then
        if legacyPath ~= nil and fileExists(legacyPath) then
            loadPath = legacyPath
            migratedFromLegacy = true
        elseif mirrorPath ~= nil and fileExists(mirrorPath) then
            loadPath = mirrorPath
            recoveredFromMirror = true
        elseif legacyMirrorPath ~= nil and fileExists(legacyMirrorPath) then
            loadPath = legacyMirrorPath
            recoveredFromMirror = true
            migratedFromLegacy = true
        else
            return
        end
        Logging.warning(
            "[TerraLogic] Work-quality data recovered from %s",
            tostring(loadPath)
        )
    end
    local xml = loadXMLFile("terraLogicWorkQuality", loadPath)
    local format = getXMLInt(xml, "quality#format") or 1
    local legacyNames = {
        soilPlow = "plow",
        soilCultivate = "cultivate",
        seed = "seed",
        fertilizer = "fertilizer",
        lime = "lime",
        herbicide = "herbicide",
        roller = "roller",
        mulch = "mulch"
    }
    local loadedCells, loadedChunks = 0, 0
    if format >= 2 then
        local index = 0
        while hasXMLProperty(xml, string.format("quality.chunk(%d)", index)) do
            local key = string.format("quality.chunk(%d)", index)
            local chunkX, chunkZ = getXMLInt(xml, key .. "#x"), getXMLInt(xml, key .. "#z")
            local statusHex = getXMLString(xml, key .. "#status")
            if chunkX ~= nil and chunkZ ~= nil and statusHex ~= nil then
                local chunk = newChunk(chunkX, chunkZ, hexToBytes(statusHex, 0))
                local format5StatusData = format == 5 and chunk.status.data or nil
                if format == 5 then
                    -- Format 5 temporarily used bit 64 for direct-drill soil.
                    -- Format 6 folds direct drilling into the normal soil-
                    -- cultivation contributor and restores bit 64 to mulch.
                    for offset = 1, self.CHUNK_CELL_COUNT do
                        local mask = getLayerByte(chunk.status, offset)
                        if hasBit(mask, 64) then
                            setLayerByte(chunk.status, offset,
                                addBit(removeBit(mask, 64), 2))
                        end
                    end
                end
                if chunk.status.nonDefaultCount > 0 then
                    for _, name in ipairs(self.COMPONENT_ORDER) do
                        local savedName = format < 5 and legacyNames[name] or name
                        local value = savedName ~= nil
                            and getXMLString(xml, key .. "#" .. savedName) or nil
                        if format == 5 and name == "soilCultivate" then
                            local directValue = getXMLString(
                                xml, key .. "#soilDirect")
                            value = bytesToHex(mergeFormat5SoilLayers(
                                format5StatusData, value, directValue, 255, true))
                        end
                        if value ~= nil then
                            local layer = newLayer(255, hexToBytes(value, 255))
                            if layer.nonDefaultCount > 0 then chunk.qualities[name] = layer end
                        end
                        local penaltyValue = nil
                        if not (format < 5 and name == "seed") then
                            penaltyValue = getXMLString(
                                xml,
                                savedName ~= nil
                                    and key .. "#penalty_" .. savedName
                                    or key .. "#unused"
                            )
                        end
                        if format == 5 and name == "soilCultivate" then
                            local directPenalty = getXMLString(
                                xml, key .. "#penalty_soilDirect")
                            penaltyValue = bytesToHex(mergeFormat5SoilLayers(
                                format5StatusData, penaltyValue,
                                directPenalty, 0, false))
                        end
                        if penaltyValue ~= nil then
                            local penaltyLayer = newLayer(
                                0,
                                hexToBytes(penaltyValue, 0)
                            )
                            if penaltyLayer.nonDefaultCount > 0 then
                                chunk.penalties[name] = penaltyLayer
                            end
                        end
                    end
                    if format >= 7 then
                        local countNames = {"fertilizer"}
                        if format >= 9 then
                            countNames[#countNames + 1] =
                                PLOW_GROWTH_BASE_LAYER
                            countNames[#countNames + 1] =
                                PLOW_GROWTH_STEP_LAYER
                        end
                        if format >= 11 then
                            countNames[#countNames + 1] =
                                CROP_GROWTH_BASE_LAYER
                            countNames[#countNames + 1] =
                                CROP_GROWTH_STEP_LAYER
                            countNames[#countNames + 1] =
                                CROP_ROOT_YIELD_LAYER
                        end
                        if format >= 12 then
                            countNames[#countNames + 1] =
                                CROP_MOISTURE_YIELD_LAYER
                        end
                        if format >= 13 then
                            countNames[#countNames + 1] =
                                CROP_MOISTURE_PERIOD_LAYER
                        end
                        for _, countName in ipairs(countNames) do
                            local countValue = getXMLString(
                                xml, key .. "#count_" .. countName)
                            if countValue ~= nil then
                                local countLayer = newLayer(
                                    0, hexToBytes(countValue, 0))
                                if countLayer.nonDefaultCount > 0 then
                                    chunk.counts[countName] = countLayer
                                end
                            end
                        end
                    else
                        -- Older saves stored every application as a universal
                        -- whole-yield deduction. Convert bonus work to the new
                        -- safe semantics: poor work may remove its own Vanilla
                        -- bonus, but can never reduce the pre-treatment yield.
                        local legacyBonus = {
                            fertilizer = 0.225,
                            lime = 0.15,
                            herbicide = 0.20,
                            roller = 0.025,
                            mulch = 0.025
                        }
                        for name, bonus in pairs(legacyBonus) do
                            local definition = self.COMPONENTS[name]
                            if definition ~= nil then
                                local countLayer = nil
                                if name == "fertilizer" then
                                    countLayer = newLayer(0, ZERO_DATA)
                                end
                                local qualityLayer = chunk.qualities[name]
                                local penaltyLayer = newLayer(0, ZERO_DATA)
                                for offset = 1, self.CHUNK_CELL_COUNT do
                                    local mask = getLayerByte(chunk.status, offset)
                                    if hasBit(mask, definition.bit) then
                                        local encoded = qualityLayer ~= nil
                                            and getLayerByte(qualityLayer, offset)
                                            or 255
                                        local quality = encoded == 255
                                            and 1 or encoded / 254
                                        local relativePenalty = bonus * (1 - quality)
                                            / math.max(1 + bonus, 0.0001)
                                        local penaltyEncoded = math.clamp(
                                            math.floor(relativePenalty * 255 + 0.5),
                                            0, 255)
                                        if penaltyEncoded > 0 then
                                            setLayerByte(
                                                penaltyLayer, offset,
                                                penaltyEncoded)
                                        end
                                        if countLayer ~= nil then
                                            setLayerByte(countLayer, offset, 1)
                                        end
                                    end
                                end
                                if penaltyLayer.nonDefaultCount > 0 then
                                    chunk.penalties[name] = penaltyLayer
                                else
                                    chunk.penalties[name] = nil
                                end
                                if countLayer ~= nil
                                    and countLayer.nonDefaultCount > 0 then
                                    chunk.counts.fertilizer = countLayer
                                end
                            end
                        end
                    end
                    if format >= 10 then
                        local recoveryValue = getXMLString(
                            xml, key .. "#meta_seedRollerRecoverable")
                        if recoveryValue ~= nil then
                            local recoveryLayer = newLayer(
                                0, hexToBytes(recoveryValue, 0))
                            if recoveryLayer.nonDefaultCount > 0 then
                                chunk.metadata.seedRollerRecoverable = recoveryLayer
                            end
                        end
                    end
                    self.chunks[tostring(chunkX) .. ":" .. tostring(chunkZ)] = chunk
                    loadedCells = loadedCells + chunk.status.nonDefaultCount
                    loadedChunks = loadedChunks + 1
                end
            end
            index = index + 1
        end
    else
        local index = 0
        while hasXMLProperty(xml, string.format("quality.cell(%d)", index)) do
            local key = string.format("quality.cell(%d)", index)
            local ix, iz = getXMLInt(xml, key .. "#x"), getXMLInt(xml, key .. "#z")
            if ix ~= nil and iz ~= nil then
                local found = false
                for _, name in ipairs(self.COMPONENT_ORDER) do
                    local savedName = legacyNames[name]
                    local value = savedName ~= nil
                        and getXMLInt(xml, key .. "#" .. savedName) or nil
                    if value ~= nil then
                        local quality = math.clamp(value / 100, 0, 1)
                        local definition = self.COMPONENTS[name]
                        local group = definition ~= nil
                            and (definition.group or name) or name
                        local bonusDefinition = self.BONUS_GROUPS[group]
                        local explicitPenalty = name == "seed" and 0 or nil
                        if bonusDefinition ~= nil then
                            local bonus = bonusDefinition.bonus or 0
                            explicitPenalty = bonus * (1 - quality)
                                / math.max(1 + bonus, 0.0001)
                        end
                        self:setCellComponent(
                            ix, iz, name, quality,
                            nil, nil, explicitPenalty,
                            name == "fertilizer"
                        )
                        found = true
                    end
                end
                if found then loadedCells = loadedCells + 1 end
            end
            index = index + 1
        end
        for _ in pairs(self.chunks) do loadedChunks = loadedChunks + 1 end
    end
    local loadedPartialHarvests = 0
    if format >= 8 then
        local partialIndex = 0
        while hasXMLProperty(
                xml, string.format("quality.partialHarvest(%d)", partialIndex)) do
            local key = string.format("quality.partialHarvest(%d)", partialIndex)
            local ix = getXMLInt(xml, key .. "#x")
            local iz = getXMLInt(xml, key .. "#z")
            local domain = getXMLString(xml, key .. "#domain")
            local fruitTypeIndex = getXMLInt(xml, key .. "#fruitType")
            if ix ~= nil and iz ~= nil
                and (domain == "arable" or domain == "fieldGrass") then
                local markerKey = tostring(ix) .. ":" .. tostring(iz)
                    .. ":" .. tostring(domain)
                self.partialHarvestCells[markerKey] = {
                    ix = ix,
                    iz = iz,
                    domain = domain,
                    fruitTypeIndex = fruitTypeIndex,
                    remainderClosed = getXMLBool(xml, key .. "#remainderClosed") == true,
                    useMinForageState = getXMLBool(xml, key .. "#useMinForageState") == true
                }
                local marker = self.partialHarvestCells[markerKey]
                if domain == "arable" and not marker.remainderClosed then
                    local entry = {ix=ix, iz=iz, key=markerKey, marker=marker,
                        fruitTypeIndex=fruitTypeIndex,
                        useMinForageState=marker.useMinForageState,
                        nextCheckAt=(g_currentMission.time or 0)+5000}
                    self.pendingHarvestClears[markerKey] = entry
                    self:enqueueHarvestCheck(entry)
                end
                loadedPartialHarvests = loadedPartialHarvests + 1
            end
            partialIndex = partialIndex + 1
        end
    end
    delete(xml)
    self.dirty = format < 13 or recoveredFromMirror or migratedFromLegacy
    self.mirrorNeedsSync = mirrorPath == nil or not fileExists(mirrorPath)
    self:beginStoredCellPrune()
    TerraLogicLogging.debug("[FS25_TerraLogic] Loaded %d work-quality cells in %d compact chunks (%d partial harvest markers)",
        loadedCells, loadedChunks, loadedPartialHarvests)
end

-- Writes only non-default cells using compact byte layers and updates the mirror.
function TerraLogicQualityManager:save()
    if g_currentMission == nil or not g_currentMission:getIsServer() then return end
    self:flushAllPendingHarvestClears()
    local path = self:getSavePath()
    if path == nil then return end
    if not self.dirty and self.mirrorNeedsSync ~= true then return end
    local index, savedCells = 0, 0
    if self.dirty then
        local xml = createXMLFile("terraLogicWorkQuality", path, "quality")
        setXMLInt(xml, "quality#format", 13)
        setXMLInt(xml, "quality#cellSize", self.CELL_SIZE)
        setXMLInt(xml, "quality#chunkSize", self.CHUNK_SIZE)
        for _, chunk in pairs(self.chunks) do
            if chunk.status.nonDefaultCount > 0 then
                savedCells = savedCells + chunk.status.nonDefaultCount
                flushLayer(chunk.status)
                local key = string.format("quality.chunk(%d)", index)
                setXMLInt(xml, key .. "#x", chunk.x)
                setXMLInt(xml, key .. "#z", chunk.z)
                setXMLString(xml, key .. "#status", bytesToHex(chunk.status.data))
                for name, layer in pairs(chunk.qualities) do
                    if layer.nonDefaultCount > 0 then
                        flushLayer(layer)
                        setXMLString(xml, key .. "#" .. name, bytesToHex(layer.data))
                    end
                end
                for name, penaltyLayer in pairs(chunk.penalties) do
                    if penaltyLayer.nonDefaultCount > 0 then
                        flushLayer(penaltyLayer)
                        setXMLString(
                            xml,
                            key .. "#penalty_" .. name,
                            bytesToHex(penaltyLayer.data)
                        )
                    end
                end
                for name, countLayer in pairs(chunk.counts) do
                    if countLayer.nonDefaultCount > 0 then
                        flushLayer(countLayer)
                        setXMLString(
                            xml,
                            key .. "#count_" .. name,
                            bytesToHex(countLayer.data)
                        )
                    end
                end
                for name, metadataLayer in pairs(chunk.metadata or {}) do
                    if metadataLayer.nonDefaultCount > 0 then
                        flushLayer(metadataLayer)
                        setXMLString(
                            xml,
                            key .. "#meta_" .. name,
                            bytesToHex(metadataLayer.data)
                        )
                    end
                end
                index = index + 1
            end
        end
        local partialIndex = 0
        for key, marker in pairs(self.partialHarvestCells) do
            local position = marker ~= nil and {
                ix = marker.ix,
                iz = marker.iz
            } or nil
            if position ~= nil then
                local xmlKey = string.format(
                    "quality.partialHarvest(%d)", partialIndex)
                setXMLInt(xml, xmlKey .. "#x", position.ix)
                setXMLInt(xml, xmlKey .. "#z", position.iz)
                setXMLString(xml, xmlKey .. "#domain", marker.domain)
                setXMLBool(xml, xmlKey .. "#remainderClosed", marker.remainderClosed == true)
                setXMLBool(xml, xmlKey .. "#useMinForageState", marker.useMinForageState == true)
                if marker.fruitTypeIndex ~= nil then
                    setXMLInt(
                        xml, xmlKey .. "#fruitType", marker.fruitTypeIndex)
                end
                partialIndex = partialIndex + 1
            else
                self.partialHarvestCells[key] = nil
            end
        end
        saveXMLFile(xml)
        delete(xml)
        self.dirty = false
        TerraLogicLogging.debug(
            "[FS25_TerraLogic] Saved %d work-quality cells in %d compact chunks to %s",
            savedCells,
            index,
            tostring(path)
        )
    end
    local mirrorPath = self:getMirrorPath(true)
    if mirrorPath ~= nil and fileExists ~= nil and fileExists(path)
        and copyFile ~= nil then
        local ok, copied = pcall(copyFile, path, mirrorPath, true)
        if ok and copied ~= false then
            self.mirrorNeedsSync = false
        else
            Logging.warning(
                "[FS25_TerraLogic] Could not update work-quality mirror %s",
                tostring(mirrorPath)
            )
        end
    end
end

TerraLogicQualityRequestEvent = {}
local TerraLogicQualityRequestEvent_mt = Class(TerraLogicQualityRequestEvent, Event)
InitEventClass(TerraLogicQualityRequestEvent, "TerraLogicQualityRequestEvent")

-- Multiplayer synchronization ----------------------------------------------

-- Constructs an empty client request for one quality cell.
function TerraLogicQualityRequestEvent.emptyNew()
    return Event.new(TerraLogicQualityRequestEvent_mt)
end

function TerraLogicQualityRequestEvent.new(ix, iz, x, z, fallbackX, fallbackZ)
    local self = TerraLogicQualityRequestEvent.emptyNew()
    self.ix, self.iz = ix, iz
    self.x, self.z = x, z
    self.fallbackX, self.fallbackZ = fallbackX, fallbackZ
    return self
end

function TerraLogicQualityRequestEvent:readStream(streamId, connection)
    self.ix = streamReadInt32(streamId)
    self.iz = streamReadInt32(streamId)
    self.x = streamReadFloat32(streamId)
    self.z = streamReadFloat32(streamId)
    self.fallbackX = streamReadFloat32(streamId)
    self.fallbackZ = streamReadFloat32(streamId)
    self:run(connection)
end

function TerraLogicQualityRequestEvent:writeStream(streamId, connection)
    streamWriteInt32(streamId, self.ix)
    streamWriteInt32(streamId, self.iz)
    streamWriteFloat32(streamId, self.x)
    streamWriteFloat32(streamId, self.z)
    streamWriteFloat32(streamId, self.fallbackX)
    streamWriteFloat32(streamId, self.fallbackZ)
end

function TerraLogicQualityRequestEvent:run(connection)
    if connection:getIsServer() then return end
    local cell = TerraLogicQualityManager:getPackedCell(self.ix, self.iz)
    connection:sendEvent(TerraLogicQualitySyncEvent.new(self.ix, self.iz, cell))
end

TerraLogicQualitySyncEvent = {}
local TerraLogicQualitySyncEvent_mt = Class(TerraLogicQualitySyncEvent, Event)
InitEventClass(TerraLogicQualitySyncEvent, "TerraLogicQualitySyncEvent")

function TerraLogicQualitySyncEvent.emptyNew()
    return Event.new(TerraLogicQualitySyncEvent_mt)
end

function TerraLogicQualitySyncEvent.new(ix, iz, cell)
    local self = TerraLogicQualitySyncEvent.emptyNew()
    self.ix, self.iz, self.cell = ix, iz, cell
    return self
end

function TerraLogicQualitySyncEvent:readStream(streamId, connection)
    self.ix = streamReadInt32(streamId)
    self.iz = streamReadInt32(streamId)
    local hasCell = streamReadBool(streamId)
    if hasCell then
        self.cell = {
            mask = streamReadUInt8(streamId),
            values = {},
            penalties = {}
        }
        for _, name in ipairs(TerraLogicQualityManager.COMPONENT_ORDER) do
            local encoded = streamReadUInt8(streamId)
            if encoded < 255 then self.cell.values[name] = encoded / 254 end
            local penaltyEncoded = streamReadUInt8(streamId)
            if penaltyEncoded > 0 then
                self.cell.penalties[name] = penaltyEncoded / 255
            end
        end
        self.cell.rootYieldSteps = streamReadUInt8(streamId)
        local rootYieldEncoded = streamReadUInt8(streamId)
        if self.cell.rootYieldSteps > 0 then
            self.cell.rootYieldAverage = rootYieldEncoded / 255
        end
        local moistureYieldEncoded = streamReadUInt8(streamId)
        if self.cell.rootYieldSteps > 0 then
            self.cell.moistureYieldAverage = moistureYieldEncoded / 255
        end
    end
    self:run(connection)
end

function TerraLogicQualitySyncEvent:writeStream(streamId, connection)
    streamWriteInt32(streamId, self.ix)
    streamWriteInt32(streamId, self.iz)
    streamWriteBool(streamId, self.cell ~= nil)
    if self.cell ~= nil then
        streamWriteUInt8(streamId, self.cell.mask or 0)
        for _, name in ipairs(TerraLogicQualityManager.COMPONENT_ORDER) do
            local quality = self.cell.values[name]
            streamWriteUInt8(streamId, quality ~= nil
                and math.clamp(math.floor(quality * 254 + 0.5), 0, 254) or 255)
            local penalty = (self.cell.penalties or {})[name]
            streamWriteUInt8(streamId, penalty ~= nil
                and math.clamp(math.floor(penalty * 255 + 0.5), 0, 255) or 0)
        end
        streamWriteUInt8(streamId, math.clamp(
            tonumber(self.cell.rootYieldSteps) or 0, 0,
            TerraLogicQualityManager.PLOW_GROWTH_STAGES))
        streamWriteUInt8(streamId, self.cell.rootYieldAverage ~= nil
            and math.clamp(math.floor(
                self.cell.rootYieldAverage * 255 + 0.5), 0, 255) or 0)
        streamWriteUInt8(streamId, self.cell.moistureYieldAverage ~= nil
            and math.clamp(math.floor(
                self.cell.moistureYieldAverage * 255 + 0.5), 0, 255) or 0)
    end
end

function TerraLogicQualitySyncEvent:run(connection)
    if not connection:getIsServer() then return end
    local key = tostring(self.ix) .. ":" .. tostring(self.iz)
    TerraLogicQualityManager.clientCells[key] = self.cell or false
end

if Cutter ~= nil and Cutter.processCutterArea ~= nil
    and Cutter.terraLogicSpatialHarvestHookInstalled ~= true then
    local originalProcessCutterArea = Cutter.processCutterArea
    Cutter.processCutterArea = function(self, workArea, dt)
        if TerraLogicPFHarvestTrace ~= nil and TerraLogicPFHarvestTrace.active ~= nil then
            TerraLogicPFHarvestTrace.safe("stage", "area.begin", self, workArea)
        end
        local manager = TerraLogicQualityManager
        local isServer = g_currentMission ~= nil
            and g_currentMission:getIsServer()
        local probe = isServer
            and manager:createCutterAreaProbe(self, workArea) or nil
        if TerraLogicPFYieldBridge ~= nil and isServer then
            TerraLogicPFYieldBridge:begin(self, probe ~= nil and probe.pfGeometry or nil)
        end
        local params = self.spec_cutter ~= nil
            and self.spec_cutter.workAreaParameters or nil
        local areaBefore = params ~= nil
            and tonumber(params.lastArea) or 0
        local multiplierBefore = params ~= nil
            and tonumber(params.lastMultiplierArea) or 0
        local resultArea, resultMultiplierArea =
            originalProcessCutterArea(self, workArea, dt)
        if isServer and params ~= nil then
            manager:recordCutterAreaResult(
                self, probe,
                (tonumber(params.lastArea) or areaBefore) - areaBefore,
                (tonumber(params.lastMultiplierArea) or multiplierBefore)
                    - multiplierBefore)
        end
        if TerraLogicPFHarvestTrace ~= nil and TerraLogicPFHarvestTrace.active ~= nil then
            TerraLogicPFHarvestTrace.safe("stage", "area.afterOriginal", self, workArea)
        end
        return resultArea, resultMultiplierArea
    end
    Cutter.terraLogicSpatialHarvestHookInstalled = true
    TerraLogicLogging.debug(
        "[FS25_TerraLogic] Installed spatial per-WorkArea Cutter capture"
    )
end

if Cutter ~= nil and Cutter.onEndWorkAreaProcessing ~= nil
    and Cutter.terraLogicQualityEndHookInstalled ~= true then
    local originalOnEndWorkAreaProcessing = Cutter.onEndWorkAreaProcessing
    Cutter.onEndWorkAreaProcessing = function(self, dt, hasProcessed)
        if TerraLogicPFHarvestTrace ~= nil and TerraLogicPFHarvestTrace.active ~= nil then
            TerraLogicPFHarvestTrace.safe("stage", "end.beforeTL", self)
        end
        local spec = self.spec_cutter
        local params = spec ~= nil and spec.workAreaParameters or nil
        local harvestedArea = params ~= nil and tonumber(params.lastArea) or 0
        local pfMultiplierBefore = params ~= nil and tonumber(params.lastMultiplierArea) or 0
        if g_currentMission ~= nil and g_currentMission:getIsServer()
            and harvestedArea > 0 then
            local workArea = self.getWorkAreaByIndex ~= nil
                and self:getWorkAreaByIndex(1) or nil
            local liveHarvestPenalty, liveHarvestQuality, liveHarvestClass =
                TerraLogicQualityManager:getRootCropHarvesterPenalty(self)
            local fruitTypeIndex = params ~= nil and params.lastFruitType or nil
            local useMinForageState = spec ~= nil
                and spec.useMinForageState == true
            TerraLogicQualityManager:applyHarvestQuality(
                self, workArea, harvestedArea, 0,
                liveHarvestPenalty, liveHarvestQuality, liveHarvestClass,
                fruitTypeIndex, useMinForageState,
                self.terraLogicHarvestCapture)
        elseif g_currentMission ~= nil and g_currentMission:getIsServer() then
            TerraLogicQualityManager:flushPendingHarvestClears(self)
        end
        if TerraLogicPFYieldBridge ~= nil then
            TerraLogicPFYieldBridge:complete(self, pfMultiplierBefore,
                params ~= nil and tonumber(params.lastMultiplierArea) or pfMultiplierBefore)
        end
        if TerraLogicPFHarvestTrace ~= nil and TerraLogicPFHarvestTrace.active ~= nil then
            TerraLogicPFHarvestTrace.safe("stage", "end.afterTL", self)
        end
        local result = originalOnEndWorkAreaProcessing(self, dt, hasProcessed)
        if TerraLogicPFHarvestTrace ~= nil and TerraLogicPFHarvestTrace.active ~= nil then
            TerraLogicPFHarvestTrace.safe("stage", "end.afterOriginal", self)
        end
        self.terraLogicHarvestCapture = nil
        return result
    end
    Cutter.terraLogicQualityEndHookInstalled = true
    TerraLogicLogging.debug(
        "[FS25_TerraLogic] Installed pre-liter Cutter work-quality hook"
    )
end

if Mower ~= nil and Mower.processMowerArea ~= nil
    and Mower.terraLogicQualityHookInstalled ~= true then
    local originalProcessMowerArea = Mower.processMowerArea
    Mower.processMowerArea = function(self, workArea, dt)
        -- Capture the surface before Vanilla changes GRASS/MEADOW into its cut
        -- state. This decides whether to use the perennial selective reset.
        local touchedBefore = TerraLogicQualityManager:getTouchedCells(workArea)
        local fieldGrassPositions = {}
        for _, position in ipairs(touchedBefore or {}) do
            local surface = TerraLogicQualityManager:getSurfaceTypeAtWorldPosition(
                (position.ix + 0.5) * TerraLogicQualityManager.CELL_SIZE,
                (position.iz + 0.5) * TerraLogicQualityManager.CELL_SIZE)
            if surface == "grassField" then
                fieldGrassPositions[#fieldGrassPositions + 1] = position
            end
        end
        -- A mower changes the fruit density state inside the Vanilla call.
        -- Close the harvest-ready growth window while the living crop is
        -- still visible; later liter scaling then reads the locked average.
        if g_currentMission ~= nil and g_currentMission:getIsServer() then
            for _, position in ipairs(touchedBefore or {}) do
                TerraLogicQualityManager:getGrowthRootYieldFactor(
                    position, true, false)
                TerraLogicQualityManager:getGrowthMoistureYieldFactor(
                    position, false, false)
            end
        end
        local dropArea = self.getDropArea ~= nil and self:getDropArea(workArea) or nil
        local dropBefore = dropArea ~= nil
            and tonumber(dropArea.litersToDrop) or nil
        local mowerSpec = self.spec_mower
        local fillUnitIndex = mowerSpec ~= nil and mowerSpec.fillUnitIndex or nil
        local fillBefore = fillUnitIndex ~= nil
            and self.getFillUnitFillLevel ~= nil
            and self:getFillUnitFillLevel(fillUnitIndex) or nil
        local changedArea, totalArea = originalProcessMowerArea(self, workArea, dt)
        if g_currentMission ~= nil and g_currentMission:getIsServer()
            and (tonumber(changedArea) or 0) > 0 then
            local inputFruitType = mowerSpec ~= nil
                and mowerSpec.workAreaParameters ~= nil
                and mowerSpec.workAreaParameters.lastInputFruitType or nil
            local isMeadowInput = FruitType ~= nil
                and FruitType.MEADOW ~= nil
                and inputFruitType == FruitType.MEADOW
            local isGrassInput = FruitType ~= nil
                and FruitType.GRASS ~= nil
                and inputFruitType == FruitType.GRASS
            local ledgerPositions, harvestDomain = {}, nil
            if isGrassInput then
                -- Sown grass on a field owns the perennial ledger. Natural
                -- GRASS outside a field contributes no stored-quality loss.
                ledgerPositions = fieldGrassPositions
                harvestDomain = "fieldGrass"
            elseif not isMeadowInput
                and inputFruitType ~= nil
                and (FruitType == nil or inputFruitType ~= FruitType.UNKNOWN) then
                ledgerPositions = touchedBefore
                harvestDomain = "arable"
            end
            local mowerPenalty = 0
            local terraLogicSpec = self.spec_terraLogic
            if terraLogicSpec ~= nil and terraLogicSpec.implementClassKey == "mower" then
                terraLogicSpec.liveWorkQualityGroups = terraLogicSpec.liveWorkQualityGroups or {}
                local mowerQualityEnabled = TerraLogicMain == nil
                    or TerraLogicMain.mowerQualityEnabled ~= false
                if mowerQualityEnabled then
                    local speed = self.getLastSpeed ~= nil
                        and math.abs(tonumber(self:getLastSpeed(true)) or 0) or 0
                    local mowerQuality, livePenalty, model =
                        TerraLogicQualityManager:getWorkQualityModel(
                            self, speed, "mower", nil)
                    mowerPenalty = math.clamp(tonumber(livePenalty) or 0, 0, 1)
                    terraLogicSpec.mowerQuality = mowerQuality
                    terraLogicSpec.mowerYieldPenalty = mowerPenalty
                    terraLogicSpec.mowerQualityModel = model
                    terraLogicSpec.liveWorkQualityGroups.mower = {
                        quality = mowerQuality,
                        yieldPenalty = mowerPenalty,
                        time = g_currentMission.time or 0
                    }
                else
                    terraLogicSpec.mowerQuality = nil
                    terraLogicSpec.mowerYieldPenalty = 0
                    terraLogicSpec.mowerQualityModel = nil
                    terraLogicSpec.liveWorkQualityGroups.mower = nil
                end
            end

            -- Evaluate sown grass through the same signed 60-110% curve as an
            -- arable harvest. Natural meadow has no persistent field ledger and
            -- receives only the current mower-quality result.
            local retainedFactor = 1 - mowerPenalty
            if #ledgerPositions > 0 then
                local fieldFactor = TerraLogicQualityManager:
                    getAverageStoredYieldFactor(
                        workArea, ledgerPositions, inputFruitType,
                        1-mowerPenalty)
                if isGrassInput and #touchedBefore > 0 then
                    local fieldShare = math.clamp(
                        #ledgerPositions / #touchedBefore, 0, 1)
                    local liveOnlyFactor = 1-mowerPenalty
                    retainedFactor = liveOnlyFactor
                        + (fieldFactor-liveOnlyFactor) * fieldShare
                else
                    retainedFactor = fieldFactor
                end
            end
            if math.abs(retainedFactor-1) > 0.0001
                and dropArea ~= nil and dropBefore ~= nil then
                local dropAfter = tonumber(dropArea.litersToDrop) or dropBefore
                local newlyAdded = math.max(dropAfter - dropBefore, 0)
                local retained = newlyAdded * retainedFactor
                dropArea.litersToDrop = dropBefore + retained
                if workArea.lastPickupLiters ~= nil then
                    workArea.lastPickupLiters = workArea.lastPickupLiters * retainedFactor
                end
                if workArea.pickedUpLiters ~= nil then
                    workArea.pickedUpLiters = workArea.pickedUpLiters * retainedFactor
                end
            elseif math.abs(retainedFactor-1) > 0.0001
                and fillUnitIndex ~= nil and fillBefore ~= nil
                and self.getFillUnitFillLevel ~= nil
                and self.addFillUnitFillLevel ~= nil then
                local fillAfter = self:getFillUnitFillLevel(fillUnitIndex)
                local adjustment = math.max(fillAfter - fillBefore, 0)
                    * (retainedFactor-1)
                if math.abs(adjustment) > 0.0001 then
                    local fillType = self.getFillUnitFillType ~= nil
                        and self:getFillUnitFillType(fillUnitIndex) or FillType.UNKNOWN
                    self:addFillUnitFillLevel(
                        self:getOwnerFarmId(), fillUnitIndex, adjustment,
                        fillType, ToolType.UNDEFINED)
                end
            end
            local pfActive = TerraLogicMain ~= nil
                and TerraLogicMain.isPrecisionFarmingActive ~= nil
                and TerraLogicMain:isPrecisionFarmingActive()
            if harvestDomain ~= nil and #ledgerPositions > 0 then
                TerraLogicQualityManager:scheduleMowerClear(
                    self, ledgerPositions, harvestDomain,
                    inputFruitType, pfActive)
            end
        end
        return changedArea, totalArea
    end
    Mower.terraLogicQualityHookInstalled = true
    TerraLogicLogging.debug("[FS25_TerraLogic] Installed mower work-quality yield hook")
end
