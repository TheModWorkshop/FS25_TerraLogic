--[[
    TerraLogicGrassGapManager.lua
    Sparse, server-owned recovery of physical grass seeding gaps.

    Copyright (c) 2026 The Mod Workshop. All rights reserved.
    Unauthorized copying, modification, or redistribution is prohibited
    except where expressly permitted by the copyright owner.
]]

TerraLogicGrassGapManager = {}

TerraLogicGrassGapManager.SAVE_FILE = "terraLogicGrassGaps.xml"
TerraLogicGrassGapManager.CHUNK_SIZE = 16
TerraLogicGrassGapManager.DEFAULT_CELL_SIZE = 0.5
TerraLogicGrassGapManager.GROWTH_DELAY_MS = 1000
TerraLogicGrassGapManager.MAX_AREA_CELLS = 65536
TerraLogicGrassGapManager.CHECKS_PER_FRAME = 4096
TerraLogicGrassGapManager.WRITES_PER_FRAME = 96
TerraLogicGrassGapManager.SIGNAL_REFRESH_INTERVAL_MS = 500
TerraLogicGrassGapManager.SIGNAL_CHUNKS_PER_TICK = 24
TerraLogicGrassGapManager.SIGNAL_SEARCH_MAX_QUERIES = 64
TerraLogicGrassGapManager.MAX_PASS_GAP_WIDTH_M = 1.5
TerraLogicGrassGapManager.MAX_PASS_GAP_SIDE_SAMPLES = 8
TerraLogicGrassGapManager.PASS_GAP_RESCAN_MS = 1500
TerraLogicGrassGapManager.PASS_GAP_CACHE_RETENTION_MS = 30000
TerraLogicGrassGapManager.PASS_GAP_CACHE_PRUNE_INTERVAL_MS = 5000
TerraLogicGrassGapManager.PASS_GAP_CACHE_PRUNE_THRESHOLD = 4096

local NEIGHBOR_OFFSETS = {
    { -1, 0 },
    { 1, 0 },
    { 0, -1 },
    { 0, 1 },
    { -1, -1 },
    { 1, -1 },
    { -1, 1 },
    { 1, 1 },
}

local function rowsAreEmpty(rows)
    if rows == nil then
        return true
    end
    for row = 1, TerraLogicGrassGapManager.CHUNK_SIZE do
        if (tonumber(rows[row]) or 0) ~= 0 then
            return false
        end
    end
    return true
end

local function copyRows(rows)
    local copy = {}
    for row = 1, TerraLogicGrassGapManager.CHUNK_SIZE do
        copy[row] = tonumber(rows ~= nil and rows[row]) or 0
    end
    return copy
end

local function hasMaskBit(mask, localX)
    local bitValue = 2 ^ localX
    return math.floor((tonumber(mask) or 0) / bitValue) % 2 == 1
end

local function addMaskBit(mask, localX)
    mask = tonumber(mask) or 0
    if hasMaskBit(mask, localX) then
        return mask, false
    end
    return mask + 2 ^ localX, true
end

local function removeMaskBit(mask, localX)
    mask = tonumber(mask) or 0
    if not hasMaskBit(mask, localX) then
        return mask, false
    end
    return mask - 2 ^ localX, true
end

local function serializeRows(rows)
    local values = {}
    for row = 1, TerraLogicGrassGapManager.CHUNK_SIZE do
        values[row] = string.format("%04X", tonumber(rows[row]) or 0)
    end
    return table.concat(values, ",")
end

local function deserializeRows(value)
    local rows, row = {}, 1
    for token in string.gmatch(tostring(value or ""), "[^,]+") do
        if row > TerraLogicGrassGapManager.CHUNK_SIZE then
            break
        end
        rows[row] = math.clamp(tonumber(token, 16) or 0, 0, 65535)
        row = row + 1
    end
    for index = row, TerraLogicGrassGapManager.CHUNK_SIZE do
        rows[index] = 0
    end
    return rows
end

local function getChunkKey(chunkX, chunkZ)
    return tostring(chunkX) .. ":" .. tostring(chunkZ)
end

local function getCellPosition(ix, iz)
    local size = TerraLogicGrassGapManager.CHUNK_SIZE
    local chunkX, chunkZ = math.floor(ix / size), math.floor(iz / size)
    return chunkX, chunkZ, getChunkKey(chunkX, chunkZ), ix - chunkX * size, iz - chunkZ * size
end

local function getAreaCoordinates(area)
    if area == nil then
        return nil
    end
    if
        tonumber(area.startX) ~= nil
        and tonumber(area.startZ) ~= nil
        and tonumber(area.widthX) ~= nil
        and tonumber(area.widthZ) ~= nil
        and tonumber(area.heightX) ~= nil
        and tonumber(area.heightZ) ~= nil
    then
        return tonumber(area.startX),
            tonumber(area.startZ),
            tonumber(area.widthX),
            tonumber(area.widthZ),
            tonumber(area.heightX),
            tonumber(area.heightZ)
    end
    if area.start == nil or area.width == nil or area.height == nil or getWorldTranslation == nil then
        return nil
    end
    local startX, _, startZ = getWorldTranslation(area.start)
    local widthX, _, widthZ = getWorldTranslation(area.width)
    local heightX, _, heightZ = getWorldTranslation(area.height)
    return startX, startZ, widthX, widthZ, heightX, heightZ
end

function TerraLogicGrassGapManager:getSavePath()
    local info = g_currentMission ~= nil and g_currentMission.missionInfo or nil
    local directory = info ~= nil and info.savegameDirectory or nil
    return directory ~= nil and directory .. "/" .. self.SAVE_FILE or nil
end

function TerraLogicGrassGapManager:getMirrorPath(createDirectory)
    if getUserProfileAppPath == nil then
        return nil
    end
    local info = g_currentMission ~= nil and g_currentMission.missionInfo or nil
    local directory = info ~= nil and info.savegameDirectory or nil
    local slot = info ~= nil and tonumber(info.savegameIndex) or nil
    if slot == nil and directory ~= nil then
        slot = tonumber(string.match(directory, "savegame(%d+)"))
    end
    if slot == nil then
        return nil
    end
    local mirrorDirectory = getUserProfileAppPath() .. "modSettings/FS25_TerraLogic"
    if createDirectory == true and type(createFolder) == "function" then
        createFolder(mirrorDirectory)
    end
    return string.format("%s/savegame%d_%s", mirrorDirectory, slot, self.SAVE_FILE)
end

function TerraLogicGrassGapManager:resolveCellSize()
    local mission = g_currentMission
    local terrainSize = mission ~= nil and tonumber(mission.terrainSize) or tonumber(g_terrainSize) or 0
    local fruitDesc = FruitType ~= nil
            and FruitType.GRASS ~= nil
            and g_fruitTypeManager ~= nil
            and g_fruitTypeManager:getFruitTypeByIndex(FruitType.GRASS)
        or nil
    local densitySize = nil
    if fruitDesc ~= nil and fruitDesc.terrainDataPlaneId ~= nil and type(getDensityMapSize) == "function" then
        local value = getDensityMapSize(fruitDesc.terrainDataPlaneId)
        do
            densitySize = tonumber(value)
        end
    end
    if terrainSize > 0 and densitySize ~= nil and densitySize > 0 then
        return math.clamp(terrainSize / densitySize, 0.125, 2)
    end
    local detailSize = mission ~= nil and tonumber(mission.terrainDetailMapSize) or 0
    if terrainSize > 0 and detailSize > 0 then
        return math.clamp(terrainSize / detailSize, 0.125, 2)
    end
    return self.DEFAULT_CELL_SIZE
end

function TerraLogicGrassGapManager:getOrCreateChunk(chunkX, chunkZ, key)
    local chunk = self.chunks[key]
    if chunk == nil then
        chunk = {
            x = chunkX,
            z = chunkZ,
            matureRows = {},
            youngRows = {},
        }
        for row = 1, self.CHUNK_SIZE do
            chunk.matureRows[row], chunk.youngRows[row] = 0, 0
        end
        self.chunks[key] = chunk
        self.chunkKeysDirty = true
    end
    return chunk
end

function TerraLogicGrassGapManager:removeChunkIfEmpty(key, chunk)
    if chunk ~= nil and rowsAreEmpty(chunk.matureRows) and rowsAreEmpty(chunk.youngRows) then
        self.chunks[key] = nil
        self.chunkKeysDirty = true
        return true
    end
    return false
end

function TerraLogicGrassGapManager:hasCell(ix, iz, rowsByKey)
    local _, _, key, localX, localZ = getCellPosition(ix, iz)
    local rows
    if rowsByKey ~= nil then
        rows = rowsByKey[key]
    else
        local chunk = self.chunks[key]
        rows = chunk ~= nil and chunk.matureRows or nil
    end
    return rows ~= nil and hasMaskBit(rows[localZ + 1], localX)
end

function TerraLogicGrassGapManager:clearCell(ix, iz)
    local _, _, key, localX, localZ = getCellPosition(ix, iz)
    local chunk = self.chunks[key]
    if chunk == nil then
        return false
    end
    local row = localZ + 1
    local changed = false
    chunk.matureRows[row], changed = removeMaskBit(chunk.matureRows[row], localX)
    local youngChanged
    chunk.youngRows[row], youngChanged = removeMaskBit(chunk.youngRows[row], localX)
    changed = changed or youngChanged
    if changed then
        self.dirty = true
        self:removeChunkIfEmpty(key, chunk)
    end
    return changed
end

function TerraLogicGrassGapManager:addYoungCell(ix, iz, touchedKeys)
    local chunkX, chunkZ, key, localX, localZ = getCellPosition(ix, iz)
    local chunk = self:getOrCreateChunk(chunkX, chunkZ, key)
    local row = localZ + 1
    if hasMaskBit(chunk.matureRows[row], localX) then
        return false
    end
    local changed
    chunk.youngRows[row], changed = addMaskBit(chunk.youngRows[row], localX)
    if changed then
        self.dirty = true
        if touchedKeys ~= nil then
            touchedKeys[key] = true
        end
    end
    return changed
end

function TerraLogicGrassGapManager:rasterizeArea(area, callback)
    local startX, startZ, widthX, widthZ, heightX, heightZ = getAreaCoordinates(area)
    if startX == nil then
        return 0
    end
    local uX, uZ = widthX - startX, widthZ - startZ
    local vX, vZ = heightX - startX, heightZ - startZ
    local determinant = uX * vZ - uZ * vX
    if math.abs(determinant) < 0.00001 then
        return 0
    end
    local cornerX, cornerZ = widthX + heightX - startX, widthZ + heightZ - startZ
    local cellSize = self.cellSize
    local minX = math.floor(math.min(startX, widthX, heightX, cornerX) / cellSize)
    local maxX = math.floor(math.max(startX, widthX, heightX, cornerX) / cellSize)
    local minZ = math.floor(math.min(startZ, widthZ, heightZ, cornerZ) / cellSize)
    local maxZ = math.floor(math.max(startZ, widthZ, heightZ, cornerZ) / cellSize)
    local candidateCount = math.max(maxX - minX + 1, 0) * math.max(maxZ - minZ + 1, 0)
    if candidateCount > self.MAX_AREA_CELLS then
        if self.largeAreaWarningShown ~= true then
            self.largeAreaWarningShown = true
            Logging.warning("[FS25_TerraLogic] Ignoring unusually large grass-gap area (%d cells)", candidateCount)
        end
        return 0
    end
    local processed = 0
    for iz = minZ, maxZ do
        local z = (iz + 0.5) * cellSize
        for ix = minX, maxX do
            local x = (ix + 0.5) * cellSize
            local dx, dz = x - startX, z - startZ
            local a = (dx * vZ - dz * vX) / determinant
            local b = (uX * dz - uZ * dx) / determinant
            if a >= -0.0001 and a <= 1.0001 and b >= -0.0001 and b <= 1.0001 then
                callback(ix, iz)
                processed = processed + 1
            end
        end
    end
    return processed
end

function TerraLogicGrassGapManager:clearArea(area)
    if self.chunks == nil or next(self.chunks) == nil then
        return 0
    end
    local cleared = 0
    self:rasterizeArea(area, function(ix, iz)
        if self:clearCell(ix, iz) then
            cleared = cleared + 1
        end
    end)
    return cleared
end

function TerraLogicGrassGapManager:addGapArea(area, touchedKeys)
    local added = 0
    self:rasterizeArea(area, function(ix, iz)
        if self:addYoungCell(ix, iz, touchedKeys) then
            added = added + 1
        end
    end)
    return added
end

function TerraLogicGrassGapManager:getGrassStateAt(x, z)
    if
        FSDensityMapUtil == nil
        or type(FSDensityMapUtil.getFruitTypeIndexAtWorldPos) ~= "function"
        or FruitType == nil
        or FruitType.GRASS == nil
    then
        return nil
    end
    local fruitTypeIndex, growthState = FSDensityMapUtil.getFruitTypeIndexAtWorldPos(x, z)
    if fruitTypeIndex ~= FruitType.GRASS then
        return nil
    end
    return tonumber(growthState)
end

function TerraLogicGrassGapManager:findSignalForChunk(chunk)
    if chunk == nil then
        return nil
    end
    local queries = 0
    for localZ = 0, self.CHUNK_SIZE - 1 do
        local mature = chunk.matureRows[localZ + 1] or 0
        local young = chunk.youngRows[localZ + 1] or 0
        for localX = 0, self.CHUNK_SIZE - 1 do
            if hasMaskBit(mature, localX) or hasMaskBit(young, localX) then
                local ix = chunk.x * self.CHUNK_SIZE + localX
                local iz = chunk.z * self.CHUNK_SIZE + localZ
                for _, offset in ipairs(NEIGHBOR_OFFSETS) do
                    local x = (ix + offset[1] + 0.5) * self.cellSize
                    local z = (iz + offset[2] + 0.5) * self.cellSize
                    local state = self:getGrassStateAt(x, z)
                    if state ~= nil then
                        return x, z, state
                    end
                    queries = queries + 1
                    if queries >= self.SIGNAL_SEARCH_MAX_QUERIES then
                        return nil
                    end
                end
            end
        end
    end
    return nil
end

function TerraLogicGrassGapManager:getGrassCutStates()
    if self.grassCutStates ~= nil then
        return self.grassCutStates
    end
    self.grassCutStates = {}
    local desc = FruitType ~= nil
            and FruitType.GRASS ~= nil
            and g_fruitTypeManager ~= nil
            and g_fruitTypeManager:getFruitTypeByIndex(FruitType.GRASS)
        or nil
    if desc ~= nil then
        if tonumber(desc.cutState) ~= nil then
            self.grassCutStates[tonumber(desc.cutState)] = true
        end
        if type(desc.getGrowthStateByName) == "function" then
            for _, name in ipairs({ "cut", "cutRolled" }) do
                local value = desc.getGrowthStateByName(desc, name)
                if tonumber(value) ~= nil then
                    self.grassCutStates[tonumber(value)] = true
                end
            end
        end
    end
    return self.grassCutStates
end

function TerraLogicGrassGapManager:isGrassGrowthTransition(oldState, newState)
    oldState, newState = tonumber(oldState), tonumber(newState)
    if oldState == nil or newState == nil or oldState == newState then
        return false
    end
    -- Mowing, grass rolling and reseeding also change the observed state. Only
    -- a forward growth-state change, or regrowth from a cut state, may close a
    -- gap. This also works with custom calendars and direct-growth mods without
    -- treating a reset to the invisible seeding state as crop growth.
    local cutStates = self:getGrassCutStates()
    if cutStates[newState] == true then
        return false
    end
    if cutStates[oldState] == true then
        return true
    end
    return newState > oldState
end

function TerraLogicGrassGapManager:queueGrowthPass()
    if self.growthJob ~= nil then
        self.growthPassQueuedAfterJob = true
    else
        self.growthPassPending = true
        self.growthDelayRemaining = self.GROWTH_DELAY_MS
    end
end

function TerraLogicGrassGapManager:refreshChunkSignal(chunk, detectGrowth)
    if chunk == nil then
        return false
    end
    if chunk.signalX ~= nil and chunk.signalZ ~= nil then
        local state = self:getGrassStateAt(chunk.signalX, chunk.signalZ)
        if state ~= nil then
            if detectGrowth == true and self:isGrassGrowthTransition(chunk.signalState, state) then
                self:queueGrowthPass()
                return true
            end
            chunk.signalState = state
            return true
        end
    end
    local x, z, state = self:findSignalForChunk(chunk)
    chunk.signalX, chunk.signalZ, chunk.signalState = x, z, state
    return state ~= nil
end

function TerraLogicGrassGapManager:replaceSowingArea(area, failedLanes, detectNarrowPassGaps)
    if g_currentMission == nil or not g_currentMission:getIsServer() then
        return 0, 0, 0
    end
    local cleared = self:clearArea(area)
    local touchedKeys, added = {}, 0
    for _, lane in ipairs(failedLanes or {}) do
        added = added + self:addGapArea(lane, touchedKeys)
    end
    local bridged = 0
    if detectNarrowPassGaps == true then
        bridged = self:detectNarrowSowingPassGaps(area, touchedKeys)
    end
    for key in pairs(touchedKeys) do
        self:refreshChunkSignal(self.chunks[key])
    end
    return cleared, added, bridged
end

function TerraLogicGrassGapManager:rebuildChunkKeys()
    self.chunkKeys = {}
    for key in pairs(self.chunks or {}) do
        self.chunkKeys[#self.chunkKeys + 1] = key
    end
    table.sort(self.chunkKeys)
    self.chunkKeysDirty = false
    self.signalChunkIndex = math.min(self.signalChunkIndex or 1, math.max(#self.chunkKeys, 1))
end

function TerraLogicGrassGapManager:refreshSignalsIncremental(maxChunks)
    if self.chunkKeysDirty or self.chunkKeys == nil then
        self:rebuildChunkKeys()
    end
    local count = #self.chunkKeys
    if count == 0 then
        return
    end
    local index = self.signalChunkIndex or 1
    for _ = 1, math.min(maxChunks or 1, count) do
        if index > count then
            index = 1
        end
        self:refreshChunkSignal(self.chunks[self.chunkKeys[index]], true)
        index = index + 1
    end
    self.signalChunkIndex = index
end

function TerraLogicGrassGapManager:onPeriodChanged()
    if g_currentMission == nil or not g_currentMission:getIsServer() then
        return
    end
    if TerraLogicQualityManager ~= nil and TerraLogicQualityManager.queuePlowGrowthRecovery ~= nil then
        TerraLogicQualityManager:queuePlowGrowthRecovery()
    end
    if self.chunks == nil or next(self.chunks) == nil then
        return
    end
    self:queueGrowthPass()
end

function TerraLogicGrassGapManager:startGrowthPass()
    if self.chunkKeysDirty or self.chunkKeys == nil then
        self:rebuildChunkKeys()
    end
    local snapshots, youngSnapshots, keys = {}, {}, {}
    for _, key in ipairs(self.chunkKeys) do
        local chunk = self.chunks[key]
        if chunk ~= nil and chunk.signalX ~= nil and chunk.signalZ ~= nil and chunk.signalState ~= nil then
            local currentState = self:getGrassStateAt(chunk.signalX, chunk.signalZ)
            if currentState ~= nil and self:isGrassGrowthTransition(chunk.signalState, currentState) then
                snapshots[key] = copyRows(chunk.matureRows)
                youngSnapshots[key] = copyRows(chunk.youngRows)
                keys[#keys + 1] = key
            end
            if currentState ~= nil then
                chunk.signalState = currentState
            end
        elseif chunk ~= nil then
            self:refreshChunkSignal(chunk)
        end
    end
    self.growthPassPending = false
    if #keys == 0 then
        return false
    end
    self.growthJob = {
        keys = keys,
        snapshots = snapshots,
        youngSnapshots = youngSnapshots,
        keyIndex = 1,
        rowIndex = 1,
        localX = 0,
        filled = 0,
        invalidated = 0,
    }
    return true
end

function TerraLogicGrassGapManager:getSnapshotHas(job, ix, iz)
    return self:hasCell(ix, iz, job.snapshots)
end

function TerraLogicGrassGapManager:getFruitTypeAt(x, z)
    if FSDensityMapUtil ~= nil and type(FSDensityMapUtil.getFruitTypeIndexAtWorldPos) == "function" then
        local value = FSDensityMapUtil.getFruitTypeIndexAtWorldPos(x, z)
        do
            return value, true
        end
    end
    return nil, false
end

function TerraLogicGrassGapManager:getIsFieldAt(x, z)
    if FSDensityMapUtil ~= nil and type(FSDensityMapUtil.getIsFieldAtWorldPos) == "function" then
        local value = FSDensityMapUtil.getIsFieldAtWorldPos(x, z)
        return value == true
    end
    return true
end

function TerraLogicGrassGapManager:prunePassGapScanCache(now)
    local cache = self.passGapScanCache
    if
        cache == nil
        or (self.passGapScanCacheCount or 0) < self.PASS_GAP_CACHE_PRUNE_THRESHOLD
        or now - (self.passGapCacheLastPrune or 0) < self.PASS_GAP_CACHE_PRUNE_INTERVAL_MS
    then
        return
    end
    local cutoff = now - self.PASS_GAP_CACHE_RETENTION_MS
    local count = self.passGapScanCacheCount or 0
    for key, timestamp in pairs(cache) do
        if timestamp < cutoff then
            cache[key] = nil
            count = count - 1
        end
    end
    self.passGapScanCacheCount = math.max(count, 0)
    self.passGapCacheLastPrune = now
end

function TerraLogicGrassGapManager:getPassGapScanKey(boundaryX, boundaryZ, outsideX, outsideZ)
    local cellSize = self.cellSize
    local ix = math.floor(boundaryX / cellSize)
    local iz = math.floor(boundaryZ / cellSize)
    local directionX = math.floor(outsideX * 4 + (outsideX >= 0 and 0.5 or -0.5))
    local directionZ = math.floor(outsideZ * 4 + (outsideZ >= 0 and 0.5 or -0.5))
    return string.format("%d:%d:%d:%d", ix, iz, directionX, directionZ)
end

function TerraLogicGrassGapManager:getShouldScanPassGapRay(boundaryX, boundaryZ, outsideX, outsideZ)
    local now = g_currentMission ~= nil and tonumber(g_currentMission.time) or 0
    if self.passGapScanCache == nil then
        self.passGapScanCache = {}
        self.passGapScanCacheCount = 0
    end
    self:prunePassGapScanCache(now)
    local key = self:getPassGapScanKey(boundaryX, boundaryZ, outsideX, outsideZ)
    local previous = self.passGapScanCache[key]
    if previous ~= nil and now - previous < self.PASS_GAP_RESCAN_MS then
        return false
    end
    if previous == nil then
        self.passGapScanCacheCount = (self.passGapScanCacheCount or 0) + 1
    end
    self.passGapScanCache[key] = now
    return true
end

function TerraLogicGrassGapManager:scanNarrowSowingPassGapRay(boundaryX, boundaryZ, outsideX, outsideZ, touchedKeys)
    local cellSize = self.cellSize
    local insideDistance = math.max(cellSize * 0.6, 0.2)
    local insideX = boundaryX - outsideX * insideDistance
    local insideZ = boundaryZ - outsideZ * insideDistance
    local insideFruit, insideKnown = self:getFruitTypeAt(insideX, insideZ)
    if
        not insideKnown
        or FruitType == nil
        or insideFruit ~= FruitType.GRASS
        or not self:getIsFieldAt(insideX, insideZ)
    then
        return 0
    end
    if not self:getShouldScanPassGapRay(boundaryX, boundaryZ, outsideX, outsideZ) then
        return 0
    end

    local emptyCells, sampledCells = {}, {}
    local firstEmptyDistance, lastEmptyDistance = nil, nil
    local stepDistance = math.max(cellSize * 0.4, 0.1)
    local maxDistance = self.MAX_PASS_GAP_WIDTH_M + cellSize * 2
    local distance = math.max(cellSize * 0.25, 0.05)
    while distance <= maxDistance + 0.0001 do
        local sampleX = boundaryX + outsideX * distance
        local sampleZ = boundaryZ + outsideZ * distance
        local ix = math.floor(sampleX / cellSize)
        local iz = math.floor(sampleZ / cellSize)
        local cellKey = tostring(ix) .. ":" .. tostring(iz)
        if sampledCells[cellKey] ~= true then
            sampledCells[cellKey] = true
            local centerX = (ix + 0.5) * cellSize
            local centerZ = (iz + 0.5) * cellSize
            local fruitType, queryKnown = self:getFruitTypeAt(centerX, centerZ)
            if not queryKnown then
                return 0
            end
            if fruitType == FruitType.GRASS then
                if #emptyCells > 0 then
                    if not self:getIsFieldAt(centerX, centerZ) then
                        return 0
                    end
                    local gapWidth = lastEmptyDistance - firstEmptyDistance + cellSize
                    if gapWidth > self.MAX_PASS_GAP_WIDTH_M + 0.0001 then
                        return 0
                    end
                    local added = 0
                    for _, cell in ipairs(emptyCells) do
                        if self:addYoungCell(cell.ix, cell.iz, touchedKeys) then
                            added = added + 1
                        end
                    end
                    return added
                end
            elseif fruitType == nil or (FruitType.UNKNOWN ~= nil and fruitType == FruitType.UNKNOWN) then
                if not self:getIsFieldAt(centerX, centerZ) then
                    return 0
                end
                firstEmptyDistance = firstEmptyDistance or distance
                lastEmptyDistance = distance
                if lastEmptyDistance - firstEmptyDistance + cellSize > self.MAX_PASS_GAP_WIDTH_M + 0.0001 then
                    return 0
                end
                emptyCells[#emptyCells + 1] = { ix = ix, iz = iz }
            else
                -- Never grow grass across another crop.
                return 0
            end
        end
        distance = distance + stepDistance
    end
    return 0
end

function TerraLogicGrassGapManager:detectNarrowSowingPassGaps(area, touchedKeys)
    local startX, startZ, widthX, widthZ, heightX, heightZ = getAreaCoordinates(area)
    if startX == nil then
        return 0
    end
    local uX, uZ = widthX - startX, widthZ - startZ
    local vX, vZ = heightX - startX, heightZ - startZ
    local widthLength = math.sqrt(uX * uX + uZ * uZ)
    local depthLength = math.sqrt(vX * vX + vZ * vZ)
    if widthLength < 0.1 or depthLength < 0.02 then
        return 0
    end

    local unitX, unitZ = uX / widthLength, uZ / widthLength
    local samples =
        math.clamp(math.ceil(depthLength / math.max(self.cellSize * 0.75, 0.1)), 1, self.MAX_PASS_GAP_SIDE_SAMPLES)
    local added = 0
    for sampleIndex = 1, samples do
        local t = (sampleIndex - 0.5) / samples
        local leftX = startX + vX * t
        local leftZ = startZ + vZ * t
        added = added + self:scanNarrowSowingPassGapRay(leftX, leftZ, -unitX, -unitZ, touchedKeys)
        local rightX = widthX + vX * t
        local rightZ = widthZ + vZ * t
        added = added + self:scanNarrowSowingPassGapRay(rightX, rightZ, unitX, unitZ, touchedKeys)
    end
    return added
end

function TerraLogicGrassGapManager:getDensityContext()
    if self.grassModifier ~= nil then
        return self.grassModifier, self.groundModifier, self.smallGrowthState, self.grassGroundValue
    end
    if
        FruitType == nil
        or FruitType.GRASS == nil
        or g_fruitTypeManager == nil
        or DensityMapModifier == nil
        or type(DensityMapModifier.new) ~= "function"
        or DensityCoordType == nil
        or DensityCoordType.POINT_POINT_POINT == nil
    then
        return nil
    end
    local desc = g_fruitTypeManager:getFruitTypeByIndex(FruitType.GRASS)
    if desc == nil or desc.terrainDataPlaneId == nil then
        return nil
    end
    local grassModifier =
        DensityMapModifier.new(desc.terrainDataPlaneId, desc.startStateChannel, desc.numStateChannels, g_terrainNode)
    if grassModifier == nil then
        return nil
    end
    self.grassModifier = grassModifier
    self.grassMapId = desc.terrainDataPlaneId
    local smallState = nil
    if type(desc.getGrowthStateByName) == "function" then
        local value = desc.getGrowthStateByName(desc, "greenSmall")
        do
            smallState = tonumber(value)
        end
    end
    self.smallGrowthState = smallState or math.max((tonumber(desc.minHarvestingGrowthState) or 3) - 1, 1)
    local mission = g_currentMission
    if
        mission ~= nil
        and mission.fieldGroundSystem ~= nil
        and FieldDensityMap ~= nil
        and FieldDensityMap.GROUND_TYPE ~= nil
        and FieldGroundType ~= nil
        and FieldGroundType.GRASS ~= nil
        and FieldGroundType.getValueByType ~= nil
    then
        local mapId, firstChannel, numChannels =
            mission.fieldGroundSystem:getDensityMapData(FieldDensityMap.GROUND_TYPE)
        if mapId ~= nil and mapId ~= 0 then
            local groundModifier = DensityMapModifier.new(mapId, firstChannel, numChannels, g_terrainNode)
            if groundModifier ~= nil then
                self.groundModifier = groundModifier
                self.grassGroundValue = FieldGroundType.getValueByType(FieldGroundType.GRASS)
            end
        end
    end
    return self.grassModifier, self.groundModifier, self.smallGrowthState, self.grassGroundValue
end

function TerraLogicGrassGapManager:writeYoungGrassCell(ix, iz)
    local grassModifier, groundModifier, smallState, grassGroundValue = self:getDensityContext()
    if grassModifier == nil or smallState == nil then
        return false
    end
    local x, z = ix * self.cellSize, iz * self.cellSize
    grassModifier:setParallelogramWorldCoords(
        x,
        z,
        x + self.cellSize,
        z,
        x,
        z + self.cellSize,
        DensityCoordType.POINT_POINT_POINT
    )
    if type(setDensityNewTypeIndexMode) == "function" and self.grassMapId ~= nil then
        setDensityNewTypeIndexMode(self.grassMapId, 0)
    end
    grassModifier.executeSet(grassModifier, smallState)

    if groundModifier ~= nil and grassGroundValue ~= nil then
        groundModifier:setParallelogramWorldCoords(
            x,
            z,
            x + self.cellSize,
            z,
            x,
            z + self.cellSize,
            DensityCoordType.POINT_POINT_POINT
        )
        groundModifier.executeSet(groundModifier, grassGroundValue)
    end
    local centerX, centerZ = x + self.cellSize * 0.5, z + self.cellSize * 0.5
    return self:getFruitTypeAt(centerX, centerZ) == FruitType.GRASS
end

function TerraLogicGrassGapManager:processGrowthCell(job, chunk, localX, localZ)
    local ix = chunk.x * self.CHUNK_SIZE + localX
    local iz = chunk.z * self.CHUNK_SIZE + localZ
    -- A cultivator, plow or new sowing pass may invalidate a marker while this
    -- throttled job is still crossing the map. Never write from a stale
    -- snapshot after ownership has been cleared by newer field work.
    if not self:hasCell(ix, iz) then
        return false
    end
    local centerX = (ix + 0.5) * self.cellSize
    local centerZ = (iz + 0.5) * self.cellSize
    local fruitType = self:getFruitTypeAt(centerX, centerZ)
    if fruitType == FruitType.GRASS then
        self:clearCell(ix, iz)
        job.invalidated = job.invalidated + 1
        return false
    end
    if fruitType ~= nil and (FruitType.UNKNOWN == nil or fruitType ~= FruitType.UNKNOWN) then
        self:clearCell(ix, iz)
        job.invalidated = job.invalidated + 1
        return false
    end
    if not self:getIsFieldAt(centerX, centerZ) then
        self:clearCell(ix, iz)
        job.invalidated = job.invalidated + 1
        return false
    end
    local touchesGrass = false
    for _, offset in ipairs(NEIGHBOR_OFFSETS) do
        local nx, nz = ix + offset[1], iz + offset[2]
        if not self:getSnapshotHas(job, nx, nz) then
            local x = (nx + 0.5) * self.cellSize
            local z = (nz + 0.5) * self.cellSize
            if self:getFruitTypeAt(x, z) == FruitType.GRASS then
                touchesGrass = true
                break
            end
        end
    end
    if touchesGrass and self:writeYoungGrassCell(ix, iz) then
        self:clearCell(ix, iz)
        job.filled = job.filled + 1
        return true
    end
    return false
end

function TerraLogicGrassGapManager:finishGrowthPass(job)
    for _, key in ipairs(job.keys) do
        local chunk = self.chunks[key]
        local captured = job.youngSnapshots[key]
        if chunk ~= nil and captured ~= nil then
            for localZ = 0, self.CHUNK_SIZE - 1 do
                local row = localZ + 1
                for localX = 0, self.CHUNK_SIZE - 1 do
                    if hasMaskBit(captured[row], localX) and hasMaskBit(chunk.youngRows[row], localX) then
                        chunk.youngRows[row] = removeMaskBit(chunk.youngRows[row], localX)
                        chunk.matureRows[row] = addMaskBit(chunk.matureRows[row], localX)
                        self.dirty = true
                    end
                end
            end
            self:removeChunkIfEmpty(key, chunk)
        end
    end
    TerraLogicLogging.debug(
        "[FS25_TerraLogic] Grass-gap growth pass completed: %d new grass cells, %d stale cells removed",
        job.filled,
        job.invalidated
    )
    self.growthJob = nil
    if self.growthPassQueuedAfterJob then
        self.growthPassQueuedAfterJob = false
        self.growthPassPending = true
        self.growthDelayRemaining = self.GROWTH_DELAY_MS
    end
end

function TerraLogicGrassGapManager:processGrowthJob(maxChecks, maxWrites)
    local job = self.growthJob
    if job == nil then
        return
    end
    local checks, writes = 0, 0
    while job.keyIndex <= #job.keys and checks < maxChecks and writes < maxWrites do
        local key = job.keys[job.keyIndex]
        local chunk = self.chunks[key]
        local rows = job.snapshots[key]
        if chunk == nil or rows == nil then
            job.keyIndex = job.keyIndex + 1
            job.rowIndex, job.localX = 1, 0
        else
            local rowMask = rows[job.rowIndex] or 0
            checks = checks + 1
            if hasMaskBit(rowMask, job.localX) then
                if self:processGrowthCell(job, chunk, job.localX, job.rowIndex - 1) then
                    writes = writes + 1
                end
            end
            job.localX = job.localX + 1
            if job.localX >= self.CHUNK_SIZE then
                job.localX = 0
                job.rowIndex = job.rowIndex + 1
                if job.rowIndex > self.CHUNK_SIZE then
                    job.rowIndex = 1
                    job.keyIndex = job.keyIndex + 1
                end
            end
        end
    end
    if job.keyIndex > #job.keys then
        self:finishGrowthPass(job)
    end
end

function TerraLogicGrassGapManager:update(dt)
    if g_currentMission == nil or not g_currentMission:getIsServer() then
        return
    end
    if self.growthPassPending then
        self.growthDelayRemaining = math.max((self.growthDelayRemaining or 0) - (tonumber(dt) or 0), 0)
        if self.growthDelayRemaining <= 0 then
            self:startGrowthPass()
        end
    end
    if self.growthJob ~= nil then
        self:processGrowthJob(self.CHECKS_PER_FRAME, self.WRITES_PER_FRAME)
    elseif not self.growthPassPending then
        self.signalRefreshElapsed = (self.signalRefreshElapsed or 0) + (tonumber(dt) or 0)
        if self.signalRefreshElapsed >= self.SIGNAL_REFRESH_INTERVAL_MS then
            self.signalRefreshElapsed = self.signalRefreshElapsed % self.SIGNAL_REFRESH_INTERVAL_MS
            self:refreshSignalsIncremental(self.SIGNAL_CHUNKS_PER_TICK)
        end
    end
end

function TerraLogicGrassGapManager:load()
    self.chunks = {}
    self.chunkKeys = {}
    self.chunkKeysDirty = false
    self.signalChunkIndex = 1
    self.signalRefreshElapsed = 0
    self.passGapScanCache = {}
    self.passGapScanCacheCount = 0
    self.passGapCacheLastPrune = 0
    self.growthJob = nil
    self.growthPassPending = false
    self.growthPassQueuedAfterJob = false
    self.grassModifier, self.groundModifier = nil, nil
    self.grassCutStates = nil
    self.cellSize = self:resolveCellSize()
    self.dirty = false
    self.mirrorNeedsSync = false
    if g_messageCenter ~= nil and MessageType ~= nil and MessageType.PERIOD_CHANGED ~= nil then
        g_messageCenter:subscribe(MessageType.PERIOD_CHANGED, self.onPeriodChanged, self)
    end
    local path = self:getSavePath()
    local mirrorPath = self:getMirrorPath(false)
    if path == nil or fileExists == nil then
        return
    end
    local loadPath = path
    if not fileExists(loadPath) and mirrorPath ~= nil and fileExists(mirrorPath) then
        loadPath = mirrorPath
        self.dirty = true
    end
    if fileExists(loadPath) then
        local xml = loadXMLFile("terraLogicGrassGaps", loadPath)
        if xml ~= nil and xml ~= 0 then
            local savedCellSize = tonumber(getXMLFloat(xml, "grassGaps#cellSize"))
            if savedCellSize ~= nil and savedCellSize >= 0.125 and savedCellSize <= 2 then
                self.cellSize = savedCellSize
            end
            local index = 0
            while hasXMLProperty(xml, string.format("grassGaps.chunk(%d)", index)) do
                local key = string.format("grassGaps.chunk(%d)", index)
                local chunkX = getXMLInt(xml, key .. "#x")
                local chunkZ = getXMLInt(xml, key .. "#z")
                if chunkX ~= nil and chunkZ ~= nil then
                    local chunkKey = getChunkKey(chunkX, chunkZ)
                    local chunk = self:getOrCreateChunk(chunkX, chunkZ, chunkKey)
                    chunk.matureRows = deserializeRows(getXMLString(xml, key .. "#mature"))
                    chunk.youngRows = deserializeRows(getXMLString(xml, key .. "#young"))
                    self:removeChunkIfEmpty(chunkKey, chunk)
                end
                index = index + 1
            end
            delete(xml)
        end
    end
    self.chunkKeysDirty = true
    self.mirrorNeedsSync = mirrorPath == nil or not fileExists(mirrorPath)
end

function TerraLogicGrassGapManager:save()
    if g_currentMission == nil or not g_currentMission:getIsServer() then
        return
    end
    local path = self:getSavePath()
    if path == nil or (not self.dirty and self.mirrorNeedsSync ~= true) then
        return
    end
    if self.dirty then
        local xml = createXMLFile("terraLogicGrassGaps", path, "grassGaps")
        setXMLInt(xml, "grassGaps#format", 1)
        setXMLFloat(xml, "grassGaps#cellSize", self.cellSize)
        setXMLInt(xml, "grassGaps#chunkSize", self.CHUNK_SIZE)
        local index = 0
        for _, chunk in pairs(self.chunks) do
            if not rowsAreEmpty(chunk.matureRows) or not rowsAreEmpty(chunk.youngRows) then
                local key = string.format("grassGaps.chunk(%d)", index)
                setXMLInt(xml, key .. "#x", chunk.x)
                setXMLInt(xml, key .. "#z", chunk.z)
                setXMLString(xml, key .. "#mature", serializeRows(chunk.matureRows))
                setXMLString(xml, key .. "#young", serializeRows(chunk.youngRows))
                index = index + 1
            end
        end
        saveXMLFile(xml)
        delete(xml)
        self.dirty = false
    end
    local mirrorPath = self:getMirrorPath(true)
    if mirrorPath ~= nil and fileExists ~= nil and fileExists(path) and type(copyFile) == "function" then
        local copied = copyFile(path, mirrorPath, true)
        if copied ~= false then
            self.mirrorNeedsSync = false
        end
    end
end

function TerraLogicGrassGapManager:delete(saveFirst)
    if saveFirst == true then
        self:save()
    end
    if g_messageCenter ~= nil then
        g_messageCenter:unsubscribeAll(self)
    end
    self.chunks, self.chunkKeys, self.growthJob = {}, {}, nil
    self.passGapScanCache = {}
    self.passGapScanCacheCount = 0
end
