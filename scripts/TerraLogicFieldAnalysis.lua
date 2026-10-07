--[[
    TerraLogicFieldAnalysis.lua

    Player-facing, read-only field analysis for the ESC menu. All expensive
    sampling is performed on the authoritative server only when the page is
    opened or manually refreshed. The map page uses transient visualization
    resources only; authoritative soil data remains in the existing maps.
]]

TerraLogicFieldAnalysis = {
    MOD_DIR = g_currentModDirectory,
    SAMPLE_GRID = 13,
    DYNAMIC_FIELD_CELL_SIZE = 8,
    DYNAMIC_FIELD_MAX_CELLS = 32768,
    pageInstalled = false,
    requestSerial = 0
}

TerraLogicFieldAnalysis.SOIL_KEYS = {
    "surfaceCompaction", "deepCompaction", "aggregateSize",
    "roughness", "resilience"
}
TerraLogicFieldAnalysis.CATEGORY_KEYS = {
    "seed", "fertilizer", "lime", "herbicide", "roller", "mulch"
}
TerraLogicFieldAnalysis.PLANNER_GROUPS = {
    "soilWork", "sowing", "cropCare", "other"
}
TerraLogicFieldAnalysis.MECHANIC_CLASSES = {
    {key="plow", depth=30, group="soilWork"},
    {key="subsoiler", depth=50, group="soilWork"},
    {key="cultivator", depth=15, group="soilWork"},
    {key="shallowCultivator", depth=8, group="soilWork"},
    {key="discHarrow", depth=12, group="soilWork"},
    {key="powerHarrow", depth=10, group="soilWork"},
    {key="ridgeFormer", depth=15, group="soilWork"},
    {key="spader", depth=30, group="soilWork"},
    {key="roller", depth=3, group="soilWork"},
    {key="sowingMachine", depth=5, group="sowing"},
    {key="directDrill", depth=8, group="sowing"},
    {key="precisionPlanter", depth=6, group="sowing"},
    {key="precisionDirectDrill", depth=6, group="sowing"},
    {key="potatoPlanter", depth=15, group="sowing"},
    {key="vegetablePlanter", depth=5, group="sowing"},
    {key="sugarcanePlanter", depth=15, group="sowing"},
    {key="mulcher", depth=3, group="cropCare"},
    {key="stonePicker", depth=5, group="cropCare"},
    {key="weeder", depth=2, group="cropCare"},
    {key="hoe", depth=4, group="cropCare"},
    {key="liquidSprayer", depth=0, group="cropCare"},
    {key="fertilizerSpreader", depth=0, group="cropCare"},
    {key="manureSpreader", depth=0, group="cropCare"},
    {key="slurrySpreader", depth=0, group="cropCare"},
    {key="slurryApplicator", depth=8, group="cropCare"},
    {key="slurryInjector", depth=5, group="cropCare"},
    {key="mower", depth=0, group="other"},
    {key="defoliator", depth=0, group="other"},
    {key="windrower", depth=0, group="other"},
    {key="tedder", depth=0, group="other"},
    {key="baler", depth=0, group="other"},
    {key="loaderWagon", depth=0, group="other"}
}

local function clamp01(value)
    return math.clamp(tonumber(value) or 0, 0, 1)
end

-- A critical share describes genuinely damaged area, not every point below a
-- generic aspirational quality. Compaction uses the layer-specific 4% yield-
-- loss boundary below; the remaining metrics keep quality thresholds here.
local CRITICAL_QUALITY = {
    aggregateSize=0.45,
    roughness=0.45,
    resilience=0.40
}

local function tr(key, fallback)
    if g_i18n ~= nil then
        local value = g_i18n:getText(key)
        if value ~= nil and value ~= "" and value ~= key then return value end
    end
    return fallback or key
end

local function formatFieldScope(snapshot)
    if snapshot == nil or snapshot.fieldScoped ~= true then return "-" end
    local kind, id = snapshot.scopeKind or "native",
        tonumber(snapshot.fieldId) or -1
    if kind == "section" and id >= 0 then
        return TerraLogicI18n.format(tr("terraLogic_fa_ui_fieldScopeSection",
            "Field %d - section"), id)
    elseif kind == "extended" and id >= 0 then
        return TerraLogicI18n.format(tr("terraLogic_fa_ui_fieldScopeExtended",
            "Field %d - extended"), id)
    elseif kind == "created" then
        return tr("terraLogic_fa_ui_fieldScopeCreated", "Created field")
    elseif kind == "connected" then
        local ids = {}
        for _, fieldId in ipairs(snapshot.fieldIds or {}) do
            ids[#ids+1] = tostring(fieldId)
        end
        return TerraLogicI18n.format(tr("terraLogic_fa_ui_fieldScopeConnected",
            "Connected fields %s"), #ids > 0 and table.concat(ids, ", ") or "-")
    elseif id >= 0 then
        return TerraLogicI18n.format(tr("terraLogic_fa_ui_fieldScope", "Field %d"), id)
    end
    return tr("terraLogic_fa_ui_fieldScopeUnknown", "Field at current location")
end

-- Soil metrics do not all share the same useful operating range. Keep the
-- colour and caption thresholds in one place so a red value can never still
-- be labelled "Watch".
local function qualityThresholds(key)
    if key == "resilience" then return 0.65, 0.45 end
    return 0.80, 0.60
end

local function compactionLoss(key, rawValue)
    if TerraLogicSoilManager ~= nil
        and TerraLogicSoilManager.getCompactionYieldLoss ~= nil then
        return TerraLogicSoilManager:getCompactionYieldLoss(key, rawValue)
    end
    local deep = key == "deepCompaction"
    local good, maximum, exponent = deep and 0.10 or 0.30,
        deep and 0.26 or 0.15, deep and 1.45 or 1.40
    local normalized = clamp01((clamp01(rawValue)-good)
        / math.max(1-good, 0.0001))
    return maximum * normalized ^ exponent
end

-- The colour describes the amount of compaction, not its layer-specific
-- yield impact. Both layers therefore use the same scale.
local function compactionDisplayQuality(key, rawValue)
    return 1-clamp01(rawValue)
end

local function qualityColor(value, key)
    value = clamp01(value)
    if key == "surfaceCompaction" or key == "deepCompaction" then
        return TerraLogicDisplay.color(key,1-value)
    elseif key == "roughness" then return TerraLogicDisplay.color(key,1-value)
    elseif key == "resilience" or key == "continuity" then return TerraLogicDisplay.color(key,value)
    end
    return TerraLogicDisplay.color("work", value)
end

local function consequenceColor(severity)
    if severity == "green" then return 0.35, 0.82, 0.31, 1 end
    if severity == "yellow" then return 1.00, 0.78, 0.08, 1 end
    if severity == "orange" then return 1.00, 0.4287, 0.0006, 1 end
    return 1.00, 0.18, 0.10, 1
end

local function formatPercent(value)
    return TerraLogicI18n.format("%.0f%%", math.clamp(
        tonumber(value) or 0, 0, 1.10) * 100)
end

local function formatLossPercent(value)
    local loss = math.max(tonumber(value) or 0, 0)
    if loss < 0.0005 then return TerraLogicI18n.format("%.1f%%", 0) end
    return TerraLogicI18n.format("-%.1f%%", loss * 100)
end

local function hasRecordedWork(snapshot)
    for _, key in ipairs(TerraLogicFieldAnalysis.CATEGORY_KEYS) do
        local value = snapshot ~= nil and snapshot.categories ~= nil
            and snapshot.categories[key] or nil
        local definition = TerraLogicQualityManager ~= nil
            and TerraLogicQualityManager.GROUP_DEFINITIONS ~= nil
            and TerraLogicQualityManager.GROUP_DEFINITIONS[key] or nil
        if value ~= nil and value >= 0
            and (definition == nil or definition.affectsYield ~= false) then
            return true
        end
    end
    return false
end

local function totalYieldLossMaximum()
    return TerraLogicQualityManager ~= nil
        and tonumber(TerraLogicQualityManager.MAXIMUM_TOTAL_YIELD_PENALTY)
        or 0.40
end

local function rootZoneLossMaximum()
    local minimum = TerraLogicQualityManager ~= nil
        and tonumber(TerraLogicQualityManager.MINIMUM_ROOT_ZONE_FACTOR)
        or 0.65
    return 1-math.clamp(minimum, 0, 1)
end

local function compactionLossMaximum(key)
    local rule = TerraLogicSoilProfiles ~= nil
        and TerraLogicSoilProfiles.ROOT_YIELD ~= nil
        and TerraLogicSoilProfiles.ROOT_YIELD[key] or nil
    return math.max(tonumber(rule ~= nil and rule.maximumLoss) or
        (key == "deepCompaction" and 0.26 or 0.15), 0.01)
end

-- Consequence colours scale to the real range of the value being shown. The
-- first percentage point is always green; the remaining possible loss is
-- split evenly into yellow, orange and red thirds.
local function consequenceQuality(loss, maximumLoss)
    loss = math.max(tonumber(loss) or 0, 0)
    if loss < 0.01 then return "green" end
    maximumLoss = math.max(tonumber(maximumLoss) or 1, 0.01)
    if maximumLoss <= 0.01 then return "red" end
    local rangePosition = math.clamp((loss-0.01)/(maximumLoss-0.01), 0, 1)
    if rangePosition < 1/3 then return "yellow" end
    if rangePosition < 2/3 then return "orange" end
    return "red"
end

local function setText(element, value, colorValue, colorKey)
    if element == nil then return end
    element:setText(tostring(value or ""))
    if type(colorValue) == "string" then
        element:setTextColor(consequenceColor(colorValue))
    elseif colorValue ~= nil then
        element:setTextColor(qualityColor(colorValue, colorKey))
    else
        element:setTextColor(1, 1, 1, 1)
    end
end

-- Notes keep the subdued colour and typography supplied by their GUI profile.
local function setNoteText(element, value)
    if element ~= nil then element:setText(tostring(value or "")) end
end

local function getPointXZ(point)
    if type(point) == "number" and entityExists(point) then
        local x, _, z = getWorldTranslation(point)
        return x, z
    end
    if type(point) ~= "table" then return nil, nil end
    local x = tonumber(point.x or point[1] or point.worldX)
    local z = tonumber(point.z or point[3] or point[2] or point.worldZ)
    if x ~= nil and z ~= nil then return x, z end
    local node = point.node or point.nodeId
    if node ~= nil and entityExists(node) then
        x, _, z = getWorldTranslation(node)
        return x, z
    end
    return nil, nil
end

local function pointInPolygon(x, z, polygon)
    local inside, previous = false, polygon[#polygon]
    for _, current in ipairs(polygon) do
        local crosses = (current.z > z) ~= (previous.z > z)
        if crosses then
            local edgeX = (previous.x - current.x) * (z - current.z)
                / (previous.z - current.z) + current.x
            if x < edgeX then inside = not inside end
        end
        previous = current
    end
    return inside
end

local getFieldPolygon

-- Field.id is the scenegraph node id and is not the player-facing field
-- number.  The values can happen to look plausible in singleplayer, but are
-- different on multiplayer clients (for example field 4 may have node id 31).
-- GIANTS uses Field:getId() whenever a field number is saved or displayed.
local function getFieldNumber(field)
    if field == nil then return -1 end
    if field.getId ~= nil then
        local ok, value = pcall(field.getId, field)
        value = ok and tonumber(value) or nil
        if value ~= nil and value >= 0 then return value end
    end
    local value = tonumber(field.fieldId)
    if value ~= nil and value >= 0 then return value end
    if g_fieldManager ~= nil then
        for index, candidate in ipairs(g_fieldManager.fields or {}) do
            if candidate == field then return index end
        end
    end
    return -1
end

local function getFieldAtPosition(x, z, polygons)
    local function polygonOf(candidate)
        if polygons == nil then return getFieldPolygon(candidate) end
        if polygons[candidate] == nil then
            polygons[candidate] = getFieldPolygon(candidate) or false
        end
        return polygons[candidate] or nil
    end
    if g_farmlandManager == nil or g_fieldManager == nil
        or g_farmlandManager.getFarmlandAtWorldPosition == nil then return nil end
    local farmland = g_farmlandManager:getFarmlandAtWorldPosition(x, z)
    if farmland == nil then return nil end
    local mapping = g_fieldManager.farmlandIdFieldMapping or {}
    local field = mapping[farmland.id]
    if type(field) == "table" and field[1] ~= nil
        and field.getPolygonPoints == nil then
        local candidates = field
        field = nil
        for _, candidate in ipairs(candidates) do
            local polygon = polygonOf(candidate)
            if polygon ~= nil and pointInPolygon(x, z, polygon) then
                field = candidate
                break
            end
        end
    elseif field ~= nil then
        -- A farmland can contain substantially more land than its mapped
        -- field. Never treat the whole parcel as that field merely because
        -- the farmland-to-field mapping contains a single entry.
        local polygon = polygonOf(field)
        if polygon ~= nil and not pointInPolygon(x, z, polygon) then
            field = nil
        end
    end
    return field, farmland
end

getFieldPolygon = function(field)
    if field == nil then return nil end
    local source = nil
    if field.getPolygonPoints ~= nil then
        local ok, result = pcall(field.getPolygonPoints, field)
        if ok then source = result end
    end
    source = source or field.polygonPoints
    if type(source) ~= "table" then return nil end
    local polygon = {}
    for _, point in ipairs(source) do
        local x, z = getPointXZ(point)
        if x ~= nil then polygon[#polygon + 1] = {x=x, z=z} end
    end
    return #polygon >= 3 and polygon or nil
end

local function isSoilSurface(x, z)
    if TerraLogicQualityManager == nil
        or TerraLogicQualityManager.getSurfaceTypeAtWorldPosition == nil then
        return true
    end
    local surface = TerraLogicQualityManager:getSurfaceTypeAtWorldPosition(x, z)
    return surface == "field" or surface == "grassField"
end

-- Live cultivated terrain determines field membership. Surface classification
-- and the visualization layer are only a fallback when terrain data is absent.
local function isVisibleSoilSurface(x, z)
    -- Discover geometry from live terrain, never the asynchronously populated
    -- visualization map. Otherwise one field can appear as several islands.
    if TerraLogicSoilManager ~= nil
        and TerraLogicSoilManager.isCultivatableTerrainAtWorldPosition ~= nil then
        local cultivated = TerraLogicSoilManager:isCultivatableTerrainAtWorldPosition(x, z)
        if cultivated ~= nil then return cultivated == true end
    end
    if not isSoilSurface(x, z) then return false end
    if TerraLogicSoilManager == nil
        or TerraLogicSoilManager.getVisualizationRawAtWorldPosition == nil then
        return false
    end
    if TerraLogicSoilManager:getVisualizationRawAtWorldPosition(
            "surfaceCompaction", x, z) <= 0 then return false end
    return true
end

-- Player-created fields have no GIANTS Field object or polygon. Reconstruct a
-- bounded, connected working area from TerraLogic's 8 m visibility mask and
-- select at most the same 13x13 samples used for native fields. This gives the
-- analysis a genuine area average without making ordinary per-frame gameplay
-- scan the map.
local function getPolygonAreaHa(polygon)
    if polygon == nil or #polygon < 3 then return 0 end
    local twiceArea, previous = 0, polygon[#polygon]
    for _, current in ipairs(polygon) do
        twiceArea = twiceArea + previous.x*current.z-current.x*previous.z
        previous = current
    end
    return math.abs(twiceArea)*0.5/10000
end

local function createDynamicFieldJob(x, z, options)
    options = options or {}
    local surfaceCache = {}
    local function visible(px, pz)
        local key = string.format("%.2f:%.2f", px, pz)
        if surfaceCache[key] == nil then
            surfaceCache[key] = isVisibleSoilSurface(px, pz)
                and (options.allowed == nil or options.allowed(px, pz))
        end
        return surfaceCache[key]
    end
    local function clearSegment(ax, az, bx, bz)
        local count = math.max(1, math.ceil(math.max(math.abs(bx-ax), math.abs(bz-az))))
        for i=1,count do
            if not visible(ax+(bx-ax)*i/count, az+(bz-az)*i/count) then return false end
        end
        return true
    end
    if not visible(x, z) then
        return {done=true, result={{}, 0, 0, 0, "none", -1, {}, {}},
            step=function() return true end}
    end
    local cellSize = TerraLogicFieldAnalysis.DYNAMIC_FIELD_CELL_SIZE
    local maxCells = TerraLogicFieldAnalysis.DYNAMIC_FIELD_MAX_CELLS
    local startIx, startIz = math.floor(x/cellSize), math.floor(z/cellSize)
    local queue, visited, cells, head = {
        {ix=startIx, iz=startIz, x=x, z=z}
    }, {}, {}, 1
    visited[tostring(startIx) .. ":" .. tostring(startIz)] = true
    local minX, maxX, minZ, maxZ = math.huge, -math.huge, math.huge, -math.huge
    local equivalentCells = 0
    local neighbours = {{1,0},{-1,0},{0,1},{0,-1}}
    local fieldIds, fieldIdSet, outsidePoints, polygons = {}, {}, {}, {}
    local singleField = nil
    local function walkOne()
        if head > #queue or #cells >= maxCells then return false end
        local cell = queue[head]
        head = head + 1
        local cx, cz = (cell.ix+0.5)*cellSize, (cell.iz+0.5)*cellSize
        local fraction = 1
        if not visible(cx, cz) or not clearSegment(cell.x, cell.z, cx, cz) then
            cx, cz = cell.x, cell.z
            -- A narrow bridge or edge fragment is not a full 64 m² cell.
            -- Refine only these exceptional cells, and weight the final
            -- sample distribution so tiny edge fragments cannot dominate it.
            local hits = 0
            for sz=0,3 do for sx=0,3 do
                if visible((cell.ix+(sx+.5)/4)*cellSize,
                    (cell.iz+(sz+.5)/4)*cellSize) then hits=hits+1 end
            end end
            fraction = math.max(hits/16, 1/64)
        end
        equivalentCells = equivalentCells + fraction
        cells[#cells+1] = {x=cx, z=cz, ix=cell.ix, iz=cell.iz, fraction=fraction}
        local field = getFieldAtPosition(cx, cz, polygons)
        local id = getFieldNumber(field)
        if field == nil or id < 0 then
            outsidePoints[#outsidePoints+1] = cells[#cells]
        else
            singleField = singleField or field
            if fieldIdSet[id] ~= true then
                fieldIdSet[id] = true
                fieldIds[#fieldIds+1] = id
            end
        end
        minX, maxX = math.min(minX, cx), math.max(maxX, cx)
        minZ, maxZ = math.min(minZ, cz), math.max(maxZ, cz)
        for _, offset in ipairs(neighbours) do
            local ix, iz = cell.ix+offset[1], cell.iz+offset[2]
            local key = tostring(ix) .. ":" .. tostring(iz)
            if visited[key] == nil then
                local nx, nz = (ix+0.5)*cellSize, (iz+0.5)*cellSize
                local connected = visible(nx, nz) and clearSegment(cx, cz, nx, nz)
                -- Only failed coarse edges receive narrow-connection probes.
                -- Each detour must be continuously cultivatable; never jump
                -- roads merely because soil exists on both sides.
                if not connected then
                    for _, shift in ipairs({-3,-2,-1,1,2,3}) do
                        local ax = (cell.ix+0.5)*cellSize + offset[2]*shift
                        local az = (cell.iz+0.5)*cellSize + offset[1]*shift
                        local bx, bz = ax+offset[1]*cellSize, az+offset[2]*cellSize
                        if visible(bx, bz) and clearSegment(cx, cz, ax, az)
                            and clearSegment(ax, az, bx, bz) then
                            nx, nz, connected = bx, bz, true
                            break
                        end
                    end
                end
                if connected then
                    visited[key] = true
                    queue[#queue+1] = {ix=ix, iz=iz, x=nx, z=nz}
                end
            end
        end
        return true
    end
    local meaningfulOutside, outsideIndex, polygon = 0, 1, nil
    local function outsideOne()
        if #fieldIds ~= 1 or outsideIndex > #outsidePoints then return false end
        local point = outsidePoints[outsideIndex]
        outsideIndex = outsideIndex + 1
        local nearest = math.huge
        if polygon ~= nil then
            local previous = polygon[#polygon]
            for _, vertex in ipairs(polygon) do
                local dx, dz = vertex.x-previous.x, vertex.z-previous.z
                local length = dx*dx+dz*dz
                local t = length > 0 and math.clamp(
                    ((point.x-previous.x)*dx+(point.z-previous.z)*dz)/length, 0, 1) or 0
                nearest = math.min(nearest,
                    (point.x-previous.x-t*dx)^2+(point.z-previous.z-t*dz)^2)
                previous = vertex
            end
        end
        if nearest > 2*2 then meaningfulOutside = meaningfulOutside + point.fraction end
        return true
    end
    local function finish()
    -- Canonical ordering gives the same samples from either original field or
    -- either side of a harvested/sown boundary within this connected component.
    table.sort(cells, function(a,b) return a.z < b.z or (a.z == b.z and a.x < b.x) end)
    local points = {}
    local maximum = TerraLogicFieldAnalysis.SAMPLE_GRID ^ 2
    if #cells <= maximum and equivalentCells == #cells then
        points = cells
    else
        local count = math.min(maximum, #cells)
        local sourceIndex, cumulative = 1, cells[1].fraction
        for index = 1, count do
            local target = (index-.5)*equivalentCells/count
            while cumulative < target and sourceIndex < #cells do
                sourceIndex=sourceIndex+1
                cumulative=cumulative+cells[sourceIndex].fraction
            end
            points[#points+1] = cells[sourceIndex]
        end
    end
    local spanX = #cells > 0 and maxX-minX+cellSize or 0
    local spanZ = #cells > 0 and maxZ-minZ+cellSize or 0
    local areaHa = equivalentCells*cellSize*cellSize/10000
    table.sort(fieldIds)
    local scopeKind, fieldId = "created", -1
    if #fieldIds > 1 then
        scopeKind = "connected"
    elseif #fieldIds == 1 then
        fieldId = fieldIds[1]
        local nativeArea = singleField ~= nil
            and (tonumber(singleField.areaHa or singleField.fieldArea) or 0) or 0
        if nativeArea <= 0 then
            nativeArea = getPolygonAreaHa(getFieldPolygon(singleField))
        end
        if nativeArea > 0 and areaHa < nativeArea*0.85 then
            scopeKind = "section"
        elseif meaningfulOutside >= 3 and meaningfulOutside/equivalentCells > 0.03 then
            scopeKind = "extended"
        else
            scopeKind = "native"
        end
    end
    return points, areaHa, math.min(spanX, spanZ), math.max(spanX, spanZ),
        scopeKind, fieldId, fieldIds, cells
    end
    -- FS25's mod sandbox does not expose Lua coroutines. Retain ordinary Lua
    -- state between update calls instead; each step visits a bounded number
    -- of geometry cells or boundary points.
    local job = {phase="walk", done=false}
    function job:step(budget)
        if self.done then return true end
        for _=1,math.max(1, budget or 8) do
            if self.phase == "walk" then
                if not walkOne() then
                    polygon = getFieldPolygon(singleField)
                    self.phase = "outside"
                end
            elseif self.phase == "outside" then
                if not outsideOne() then self.phase = "finish" end
            else
                self.result = {finish()}
                self.done = true
                return true
            end
        end
        return false
    end
    return job
end

local function buildDynamicFieldSamples(x, z, options)
    if options ~= nil and options.geometry ~= nil then return unpack(options.geometry) end
    local job = createDynamicFieldJob(x, z, options)
    while not job.done do job:step(128) end
    return unpack(job.result)
end

-- Shared by the server's bounded owned-field catalogue, not a per-frame scan.
TerraLogicFieldAnalysis.buildDynamicFieldSamples = buildDynamicFieldSamples
TerraLogicFieldAnalysis.createDynamicFieldJob = createDynamicFieldJob
TerraLogicFieldAnalysis.getFieldPolygon = getFieldPolygon
TerraLogicFieldAnalysis.getFieldNumber = getFieldNumber
TerraLogicFieldAnalysis.isVisibleSoilSurface = isVisibleSoilSurface

local function buildSamplePoints(x, z, options)
    local points, areaHa, efficientWidthM, efficientLengthM,
        scopeKind, fieldId, fieldIds = buildDynamicFieldSamples(x, z, options)
    return points, #points > 0, fieldId, areaHa,
        efficientWidthM, efficientLengthM, scopeKind, fieldIds
end

local function getCellPosition(x, z)
    local size = TerraLogicQualityManager.CELL_SIZE or 4
    return {ix=math.floor(x / size), iz=math.floor(z / size)}
end

local function persistentDraftMultiplier(state, classKey)
    local response = TerraLogicImplementProfiles ~= nil
        and TerraLogicImplementProfiles.getSoilDraftResponse ~= nil
        and TerraLogicImplementProfiles.getSoilDraftResponse(classKey) or nil
    local defaults = TerraLogicSoilProfiles ~= nil
        and TerraLogicSoilProfiles.DEFAULTS or nil
    if response == nil or defaults == nil then return 1 end
    local function stress(v, e) return clamp01(v) ^ e end
    local function coarse(v) return math.max((0.5-clamp01(v))/0.5, 0)^1.4 end
    local function loose(v) return (1-clamp01(v))^1.4 end
    local excess = (response.surface or 0)
            * (stress(state.surfaceCompaction,1.6)-stress(defaults.surfaceCompaction,1.6))
        + (response.deep or 0)
            * (stress(state.deepCompaction,1.8)-stress(defaults.deepCompaction,1.8))
        + (response.coarse or 0)
            * (coarse(state.aggregateSize)-coarse(defaults.aggregateSize))
        + (response.rough or 0)
            * (stress(state.roughness,1.5)-stress(defaults.roughness,1.5))
        + (response.looseSurface or 0)
            * (loose(state.surfaceCompaction)-loose(defaults.surfaceCompaction))
    return math.clamp(1 + excess,
        TerraLogic ~= nil and TerraLogic.SOIL_STATE_DRAFT_MIN or 0.96,
        TerraLogic ~= nil and TerraLogic.SOIL_STATE_DRAFT_MAX or 1.08)
end

local function textureDraftMultiplier(soilTypeIndex, depth)
    local soil = TerraLogic ~= nil and TerraLogic.SOIL_DATA ~= nil
        and TerraLogic.SOIL_DATA[tonumber(soilTypeIndex)] or nil
    if soil == nil then return 1 end
    local response = TerraLogic ~= nil and TerraLogic.getDraftDepthResponse ~= nil
        and TerraLogic.getDraftDepthResponse(depth) or 1
    return TerraLogic.applyDraftDepthResponse(soil.resistance, response)
end

function TerraLogicFieldAnalysis.isActiveCrop(fruit, state)
    if (tonumber(fruit) or 0) <= 0 or (tonumber(state) or -1) < 0 then return false end
    local manager = TerraLogicSoilManager
    if manager == nil then return false end
    if manager.isCoverCrop ~= nil and manager:isCoverCrop(fruit) then return false end
    local info = manager:getRecoveryFruitStateInfo(fruit)
    if info == nil or (info.withered or {})[state] then return false end
    return not (info.cut or {})[state] or (info.regrowthSources or {})[state] == true
end

function TerraLogicFieldAnalysis:getActiveCropGroups(position)
    local samples, valid = TerraLogicQualityManager:getAnalysisCropSamples(position.ix, position.iz)
    local groups, cover, fieldSamples, accepted = {}, false, 0, {}
    if not valid or #samples == 0 then return groups, 1, cover end
    for _, sample in ipairs(samples) do
        local fruit, state = sample.fruitTypeIndex, sample.growthState
        -- A field sample's 4 m history cell can extend into a verge or a
        -- landscaped boundary. Test every plant probe against live ground,
        -- not an old field polygon or the crop found at the cell centre.
        local onField = false
        if sample.x ~= nil and sample.z ~= nil then
            if TerraLogicSoilManager.isCultivatableTerrainAtWorldPosition ~= nil then
                onField = TerraLogicSoilManager:
                    isCultivatableTerrainAtWorldPosition(sample.x, sample.z)
            end
            if onField == nil or TerraLogicSoilManager.isCultivatableTerrainAtWorldPosition == nil then
                onField = isVisibleSoilSurface(sample.x, sample.z)
            end
        end
        if onField == true then
            fieldSamples = fieldSamples + 1
            if TerraLogicSoilManager.isCoverCrop ~= nil and fruit ~= nil
                and TerraLogicSoilManager:isCoverCrop(fruit) then cover = true end
            if self.isActiveCrop(fruit, state) then
                accepted[sample.x] = accepted[sample.x] or {}
                accepted[sample.x][sample.z] = fruit
                local group = groups[fruit] or {fruit=fruit, state=state, count=0}
                group.count = group.count + 1
                group.state = math.max(group.state, state)
                groups[fruit] = group
            end
        end
    end
    -- Reuse the same selection for roots/losses without extra terrain queries.
    -- Bare on-field points count towards coverage; outside points do not.
    local function includeRootSample(fruit, state, x, z)
        return accepted[x] ~= nil and accepted[x][z] == fruit
    end
    return groups, math.max(fieldSamples, 1), cover, includeRootSample
end

function TerraLogicFieldAnalysis:buildSnapshot(x, z, serial, options)
    x, z = tonumber(x) or 0, tonumber(z) or 0
    if x ~= x or z ~= z or math.abs(x) > 10000000 or math.abs(z) > 10000000 then
        x, z = 0, 0
    end
    local snapshot = {
        valid=false, serial=serial or 0, x=x, z=z, fieldScoped=false,
        fieldId=-1, scopeKind="none", fieldIds={}, areaHa=0,
        sampleCount=0, fieldEfficientWidthM=0,
        fieldEfficientLengthM=0, soil={}, critical={},
        categories={}, fruitTypeIndex=-1, growthState=-1, growthStage=0,
        profileIndex=0, profileMixed=false, profileMask=0,
        surfaceMoisture=0, subsoilMoisture=0,
        surfaceTemperatureC=0, subsoilTemperatureC=0,
        temperatureInitializing=false, moistureInitializing=false,
        surfaceFrozen=false, subsoilFrozen=false, soilQuality=0, tilthQuality=0,
        rootFactor=1, moistureFactor=1, ledgerFactor=1, workQualityTotal=1,
        totalFactor=1,
        growthSteps=0, growthHistoryCoverage=0, growthHistoryUpdating=false,
        biologicalContinuity=0.25,
        moistureYieldActive=false, mechanics={},
        soilDeduction=0, waterDeduction=0, workDeduction=0,
        surfaceRootLoss=0, deepRootLoss=0, trafficSurfaceMultiplier=1,
        trafficDeepMultiplier=1, rollerRescuePotential=0, categoryLosses={},
        rotationKnownShare=0, rotationRepeatedShare=0,
        rotationDiverseShare=0, coverCrop=false,
        cropShare=0, cropCount=0, yieldRecordedWork=false, categoryCoverage={},
        harvestPending=false
    }
    if TerraLogicSoilManager == nil or TerraLogicQualityManager == nil then
        return snapshot
    end
    local points, fieldScoped, fieldId, areaHa, efficientWidthM,
        efficientLengthM, scopeKind, fieldIds = buildSamplePoints(x, z, options)
    if #points == 0 then return snapshot end
    snapshot.valid, snapshot.fieldScoped = true, fieldScoped
    snapshot.fieldId, snapshot.areaHa, snapshot.sampleCount = fieldId, areaHa, #points
    snapshot.scopeKind, snapshot.fieldIds = scopeKind or "created", fieldIds or {}
    snapshot.fieldEfficientWidthM = efficientWidthM
    snapshot.fieldEfficientLengthM = efficientLengthM
    local sums, critical = {}, {}
    local categorySums, categoryCounts = {}, {}
    local soilQualitySum, tilthQualitySum, rootSum, moistureSum, ledgerSum,
        totalSum, stepsSum, continuitySum = 0, 0, 0, 0, 0, 0, 0, 0
    local growthCropSamples, growthHistorySamples = 0, 0
    local activeWeight, cropCounts, cropStates = 0, {}, {}
    local surfaceMoistureSum, subsoilMoistureSum, profileCounts = 0, 0, {}
    local soilDeductionSum, waterDeductionSum, workDeductionSum = 0, 0, 0
    local surfaceLossSum, deepLossSum, trafficSurfaceSum, trafficDeepSum = 0, 0, 0, 0
    local rollerRescueSum = 0
    local rotationKnownCount, rotationRepeatedCount, rotationDiverseCount = 0, 0, 0
    local mechanicSums = {}
    local categoryLossSums = {}
    for _, definition in ipairs(self.MECHANIC_CLASSES) do
        mechanicSums[definition.key] = {quality=0, dropout=0, safeSpeedRatio=0, effectiveness=0,
            draft=0, wet=0, dry=0, frost=0, penetration=0, projected={}}
        for _, key in ipairs(self.SOIL_KEYS) do
            mechanicSums[definition.key].projected[key] = 0
        end
    end
    local moistureActive = TerraLogicSettings == nil
        or TerraLogicSettings:getMoistureYieldEnabled()
    for _, key in ipairs(self.SOIL_KEYS) do sums[key], critical[key] = 0, 0 end
    for _, key in ipairs(self.CATEGORY_KEYS) do categorySums[key], categoryCounts[key] = 0, 0 end
    for _, point in ipairs(points) do
        local state = TerraLogicSoilManager:getStateAtWorldPosition(point.x, point.z)
        if TerraLogicSoilManager.getRotationDebugAtWorldPosition ~= nil then
            local rotation = TerraLogicSoilManager:
                getRotationDebugAtWorldPosition(point.x, point.z)
            local lastGroup = tonumber(rotation.lastGroup) or 0
            local currentGroup = tonumber(rotation.currentGroup) or 0
            if lastGroup > 0 and currentGroup > 0 then
                rotationKnownCount = rotationKnownCount + 1
                if lastGroup ~= currentGroup then
                    rotationDiverseCount = rotationDiverseCount + 1
                elseif tostring(rotation.currentGroupName) ~= "perennial" then
                    rotationRepeatedCount = rotationRepeatedCount + 1
                end
            end
        end
        local qualities = {
            surfaceCompaction=1-clamp01(state.surfaceCompaction),
            deepCompaction=1-clamp01(state.deepCompaction),
            aggregateSize=TerraLogicSoilManager:getDisplayValue("aggregateSize", state.aggregateSize),
            roughness=1-clamp01(state.roughness), resilience=clamp01(state.resilience)
        }
        for _, key in ipairs(self.SOIL_KEYS) do
            sums[key] = sums[key] + clamp01(state[key])
            local isCritical
            if key == "surfaceCompaction" or key == "deepCompaction" then
                isCritical = compactionLoss(key, state[key]) >= 0.04
            else
                local threshold = CRITICAL_QUALITY[key] or 0.45
                isCritical = qualities[key] < threshold
            end
            if isCritical then
                critical[key] = critical[key] + 1
            end
        end
        soilQualitySum = soilQualitySum + (TerraLogicSoilManager:getTillageQualityFromState(state) or 1)
        tilthQualitySum = tilthQualitySum + qualities.aggregateSize
        local position = getCellPosition(point.x, point.z)
        if TerraLogicSoilManager.getBiologicalContinuityAtWorldPosition ~= nil then
            continuitySum = continuitySum
                + TerraLogicSoilManager:getBiologicalContinuityAtWorldPosition(
                    point.x, point.z)
        else
            continuitySum = continuitySum + 0.25
        end
        local soilType = TerraLogicSoilManager:getPFSoilTypeAtWorldPosition(point.x, point.z)
        local trafficSurface, trafficDeep = 1, 1
        if TerraLogicSoilMoistureManager ~= nil then
            trafficSurface, trafficDeep =
                TerraLogicSoilMoistureManager:getTrafficMultipliers(soilType)
        end
        -- Resilience is the soil's resistance to traffic damage.  At 50%
        -- resilience it is neutral; this is the same factor used by wheel passes.
        local temperature = TerraLogicSoilTemperatureManager or {}
        local surfaceSensitivity, deepSensitivity =
            TerraLogicSoilManager:getTrafficSensitivityFactors(
                soilType, state.resilience, trafficSurface, trafficDeep,
                temperature.surfaceFrozen == true, temperature.subsoilFrozen == true)
        trafficSurfaceSum = trafficSurfaceSum + surfaceSensitivity
        trafficDeepSum = trafficDeepSum + deepSensitivity
        local rawGround = TerraLogicSoilManager:getGroundTypeAtWorldPosition(point.x, point.z)
        for _, definition in ipairs(self.MECHANIC_CLASSES) do
            local result = TerraLogicSoilManager:getSuitabilityAtState(
                state, soilType, definition.key, definition.depth, rawGround)
            local sumsForClass = mechanicSums[definition.key]
            sumsForClass.quality = sumsForClass.quality + result.qualityFactor
            sumsForClass.dropout = sumsForClass.dropout + result.dropoutFraction
            sumsForClass.safeSpeedRatio = sumsForClass.safeSpeedRatio
                + (result.safeSpeedRatio or 1)
            sumsForClass.effectiveness = sumsForClass.effectiveness + result.soilEffectiveness
            sumsForClass.wet = sumsForClass.wet + result.wetSeverity
            sumsForClass.dry = sumsForClass.dry + result.drySeverity
            sumsForClass.frost = sumsForClass.frost + result.frostSeverity
            sumsForClass.penetration = sumsForClass.penetration + result.penetrationFactor
            local texture = textureDraftMultiplier(soilType, definition.depth)
            local base = math.clamp(texture
                * persistentDraftMultiplier(state, definition.key)
                * (result.draftMultiplier or 1),
                TerraLogic ~= nil and TerraLogic.ENVIRONMENT_DRAFT_MIN or 0.88,
                TerraLogic ~= nil and TerraLogic.ENVIRONMENT_DRAFT_MAX or 1.45)
            sumsForClass.draft = sumsForClass.draft + math.clamp(base
                + math.max((result.frostDraftMultiplier or 1)-1, 0),
                TerraLogic ~= nil and TerraLogic.ENVIRONMENT_DRAFT_MIN or 0.88,
                TerraLogic ~= nil and TerraLogic.FROST_ENVIRONMENT_DRAFT_MAX or 1.95)
            if TerraLogicSoilManager.previewOperationFromState ~= nil then
                local projected = TerraLogicSoilManager:previewOperationFromState(
                    state, soilType, definition.key, definition.depth)
                for _, key in ipairs(self.SOIL_KEYS) do
                    sumsForClass.projected[key] = sumsForClass.projected[key]
                        + (tonumber(projected[key]) or tonumber(state[key]) or 0)
                end
            else
                for _, key in ipairs(self.SOIL_KEYS) do
                    sumsForClass.projected[key] = sumsForClass.projected[key]
                        + (tonumber(state[key]) or 0)
                end
            end
        end
        if TerraLogicSoilMoistureManager ~= nil then
            local pointMoisture = TerraLogicSoilMoistureManager:getStateAtWorldPosition(point.x, point.z)
            surfaceMoistureSum = surfaceMoistureSum + clamp01(pointMoisture.surface)
            subsoilMoistureSum = subsoilMoistureSum + clamp01(pointMoisture.subsoil)
            local pointProfile = tonumber(pointMoisture.profileIndex) or 0
            profileCounts[pointProfile] = (profileCounts[pointProfile] or 0) + 1
        end
        local cell = TerraLogicQualityManager:getPackedCell(position.ix, position.iz)
        local entries = cell ~= nil and TerraLogicQualityManager:getGroupedEntriesFromCell(cell) or {}
        local harvestMarker = (TerraLogicQualityManager.partialHarvestCells or {})[
            tostring(position.ix) .. ":" .. tostring(position.iz) .. ":arable"]
        if #entries > 0 and harvestMarker ~= nil and not harvestMarker.remainderClosed then
            snapshot.harvestPending = true
        end
        local rawRescue = TerraLogicQualityManager:getSeedRollerRecoveryAtCell(position)
        local seedQuality = 1
        for _, entry in ipairs(entries) do
            if entry.name == "seed" then seedQuality = clamp01(entry.quality) end
        end
        local rescueShare, rescueMaximum = 0, 0
        if TerraLogicSoilProfiles ~= nil then
            rescueShare, rescueMaximum =
                TerraLogicSoilProfiles:getRollerSeedRescueLimits()
        end
        rollerRescueSum = rollerRescueSum + math.min(rawRescue * rescueShare,
            rescueMaximum or 0, 1-seedQuality)
        local ledger = TerraLogicQualityManager:getEffectiveYieldFactor(entries, true)
        local groups, sampleTotal, cover, sampleFilter = self:getActiveCropGroups(position)
        snapshot.coverCrop = snapshot.coverCrop or cover
        for fruitIndex, group in pairs(groups) do
            local weight = group.count / sampleTotal
            local rootCurrent, _, _, surfaceLoss, deepLoss =
                TerraLogicQualityManager:getCropWeightedRootYieldFactor(position.ix, position.iz,
                    fruitIndex, sampleFilter)
            local rootProjected, rootSteps = TerraLogicQualityManager:
                getGrowthRootYieldFactor(position, false, true, rootCurrent)
            local moistureProjected = TerraLogicQualityManager:
                getGrowthMoistureYieldFactor(position, false, true, fruitIndex)
            local semantic = TerraLogicQualityManager:getSemanticPlowGrowthStage(fruitIndex, group.state, nil)
            if moistureProjected == nil and TerraLogicSoilMoistureManager ~= nil then
                local response = TerraLogicSoilMoistureManager:getCropYieldResponse(soilType, fruitIndex, semantic)
                moistureProjected = response ~= nil and response.factor or 1
            end
            rootProjected = clamp01(rootProjected or rootCurrent or 1)
            moistureProjected = clamp01(moistureProjected or 1)
            local combined, yieldDetail = TerraLogicQualityManager:getTerraLogicYieldFactor(
                entries, rootProjected, moistureProjected, moistureActive, 1, state.resilience)
            rootSum, moistureSum = rootSum + rootProjected*weight, moistureSum + moistureProjected*weight
            surfaceLossSum, deepLossSum = surfaceLossSum + surfaceLoss*weight, deepLossSum + deepLoss*weight
            ledgerSum, totalSum = ledgerSum + ledger*weight, totalSum + combined*weight
            soilDeductionSum = soilDeductionSum + yieldDetail.soilDeduction*weight
            waterDeductionSum = waterDeductionSum + yieldDetail.waterDeduction*weight
            workDeductionSum = workDeductionSum + yieldDetail.workDeduction*weight
            activeWeight = activeWeight + weight
            cropCounts[fruitIndex] = (cropCounts[fruitIndex] or 0) + weight
            cropStates[fruitIndex] = math.max(cropStates[fruitIndex] or -1, group.state)
            growthCropSamples = growthCropSamples + weight
            if (rootSteps or 0) > 0 then
                growthHistorySamples = growthHistorySamples + weight
                stepsSum = stepsSum + rootSteps*weight
            end
            for _, entry in ipairs(entries) do
                local definition = TerraLogicQualityManager.GROUP_DEFINITIONS[entry.name]
                if definition ~= nil and definition.affectsYield ~= false then snapshot.yieldRecordedWork = true end
            end
        end
        for _, entry in ipairs(entries) do
            if categorySums[entry.name] ~= nil then
                categorySums[entry.name] = categorySums[entry.name] + clamp01(entry.quality)
                categoryCounts[entry.name] = categoryCounts[entry.name] + 1
                categoryLossSums[entry.name] = (categoryLossSums[entry.name] or 0)
                    + clamp01(entry.harvestPenalty or entry.yieldPenalty or 0)
            end
        end
    end
    for _, key in ipairs(self.SOIL_KEYS) do
        snapshot.soil[key] = sums[key] / #points
        snapshot.critical[key] = critical[key] / #points
    end
    for _, key in ipairs(self.CATEGORY_KEYS) do
        snapshot.categories[key] = categoryCounts[key] > 0
            and categorySums[key] / categoryCounts[key] or -1
        snapshot.categoryCoverage[key] = categoryCounts[key] / #points
    end
    -- This is the literal mean quality of the yield-relevant operations that
    -- were actually recorded. Supporting results remain visible below but do
    -- not dilute this headline. `ledgerFactor` is deliberately separate: it is an economic
    -- retained-yield factor, so an 89% sowing result can legitimately retain
    -- about 98% yield and must not be labelled as 98% Work Quality.
    local workQualitySum, workQualityCount = 0, 0
    for _, key in ipairs(self.CATEGORY_KEYS) do
        local value = snapshot.categories[key]
        local definition = TerraLogicQualityManager.GROUP_DEFINITIONS[key]
        if value ~= nil and value >= 0
            and (definition == nil or definition.affectsYield ~= false) then
            workQualitySum = workQualitySum + value
            workQualityCount = workQualityCount + 1
        end
    end
    snapshot.workQualityTotal = workQualityCount > 0
        and workQualitySum/workQualityCount or 1
    snapshot.soilQuality = soilQualitySum / #points
    snapshot.tilthQuality = tilthQualitySum / #points
    local yieldDivisor = math.max(activeWeight, 0.000001)
    snapshot.rootFactor, snapshot.moistureFactor = rootSum / yieldDivisor, moistureSum / yieldDivisor
    snapshot.soilDeduction = soilDeductionSum / yieldDivisor
    snapshot.waterDeduction = waterDeductionSum / yieldDivisor
    snapshot.workDeduction = workDeductionSum / yieldDivisor
    snapshot.surfaceRootLoss, snapshot.deepRootLoss =
        surfaceLossSum / yieldDivisor, deepLossSum / yieldDivisor
    snapshot.trafficSurfaceMultiplier = trafficSurfaceSum / #points
    snapshot.trafficDeepMultiplier = trafficDeepSum / #points
    snapshot.rollerRescuePotential = rollerRescueSum / #points
    snapshot.rotationKnownShare = rotationKnownCount / #points
    snapshot.rotationRepeatedShare = rotationRepeatedCount / #points
    snapshot.rotationDiverseShare = rotationDiverseCount / #points
    for _, definition in ipairs(self.MECHANIC_CLASSES) do
        local source, target = mechanicSums[definition.key], {projected={}}
        for key, value in pairs(source) do
            if key ~= "projected" then target[key] = value / #points end
        end
        for _, key in ipairs(self.SOIL_KEYS) do
            target.projected[key] = source.projected[key] / #points
        end
        snapshot.mechanics[definition.key] = target
    end
    for _, key in ipairs(self.CATEGORY_KEYS) do
        snapshot.categoryLosses[key] = categoryCounts[key] > 0
            and (categoryLossSums[key] or 0) / categoryCounts[key] or 0
    end
    snapshot.ledgerFactor, snapshot.totalFactor = ledgerSum / yieldDivisor, totalSum / yieldDivisor
    if activeWeight <= 0 then
        -- Hidden crop values must remain neutral for recommendations/help too.
        snapshot.rootFactor, snapshot.moistureFactor = 1, 1
        snapshot.ledgerFactor, snapshot.totalFactor = 1, 1
    end
    snapshot.cropShare = activeWeight / #points
    snapshot.growthSteps = growthHistorySamples > 0
        and math.floor(stepsSum / growthHistorySamples + 0.5) or 0
    snapshot.growthHistoryCoverage = growthCropSamples > 0
        and growthHistorySamples / growthCropSamples or 0
    snapshot.growthHistoryUpdating =
        TerraLogicQualityManager.isGrowthHistoryUpdating ~= nil
        and TerraLogicQualityManager:isGrowthHistoryUpdating() or false
    snapshot.biologicalContinuity = continuitySum / #points
    snapshot.moistureYieldActive = moistureActive
    local dominantCropWeight = -1
    for fruit, weight in pairs(cropCounts) do
        snapshot.cropCount = snapshot.cropCount + 1
        if weight > dominantCropWeight or (weight == dominantCropWeight and fruit < snapshot.fruitTypeIndex) then
            dominantCropWeight = weight
            snapshot.fruitTypeIndex, snapshot.growthState = fruit, cropStates[fruit]
        end
    end
    snapshot.growthStage = tonumber(TerraLogicQualityManager:getSemanticPlowGrowthStage(
        snapshot.fruitTypeIndex, snapshot.growthState, nil)) or 0
    local dominantCount = -1
    local profileTypeCount = 0
    for profileIndex, count in pairs(profileCounts) do
        profileTypeCount = profileTypeCount + 1
        if profileIndex >= 1 and profileIndex <= 4 then
            snapshot.profileMask = snapshot.profileMask + 2 ^ (profileIndex - 1)
        end
        if count > dominantCount then snapshot.profileIndex, dominantCount = profileIndex, count end
    end
    snapshot.profileMixed = profileTypeCount > 1
    snapshot.surfaceMoisture = surfaceMoistureSum / #points
    snapshot.subsoilMoisture = subsoilMoistureSum / #points
    local temperature = TerraLogicSoilTemperatureManager ~= nil
        and TerraLogicSoilTemperatureManager:getState() or {}
    local moisture = TerraLogicSoilMoistureManager ~= nil
        and TerraLogicSoilMoistureManager:getState() or {}
    snapshot.surfaceTemperatureC = tonumber(temperature.surfaceTemperatureC) or 0
    snapshot.subsoilTemperatureC = tonumber(temperature.subsoilTemperatureC) or 0
    snapshot.temperatureInitializing = temperature.spinupComplete ~= true
        and string.format("%.1f", snapshot.surfaceTemperatureC)
            == string.format("%.1f", snapshot.subsoilTemperatureC)
    snapshot.moistureInitializing =
        (tonumber(moisture.simulatedGameHours) or 0)
            < 720 / math.max(tonumber(moisture.calendarScale) or 1, 0.01)
        and math.floor(clamp01(snapshot.surfaceMoisture) * 100 + 0.5)
            == math.floor(clamp01(snapshot.subsoilMoisture) * 100 + 0.5)
    snapshot.surfaceFrozen = temperature.surfaceFrozen == true
    snapshot.subsoilFrozen = temperature.subsoilFrozen == true
    return snapshot
end

function TerraLogicFieldAnalysis:getLocalPosition()
    local node = nil
    if g_localPlayer ~= nil and g_localPlayer.getCurrentVehicle ~= nil then
        local vehicle = g_localPlayer:getCurrentVehicle()
        node = vehicle ~= nil and (vehicle.rootNode or vehicle.components ~= nil
            and vehicle.components[1] ~= nil and vehicle.components[1].node) or nil
    end
    node = node or (g_localPlayer ~= nil and g_localPlayer.rootNode or nil)
    if node == nil or not entityExists(node) then return 0, 0 end
    local x, _, z = getWorldTranslation(node)
    return x, z
end

function TerraLogicFieldAnalysis:requestSnapshot()
    local x, z = self:getLocalPosition()
    local selected = self.selectedField
    if selected ~= nil then x, z = selected.x, selected.z end
    local root = g_localPlayer ~= nil
        and g_localPlayer.getCurrentVehicle ~= nil
        and g_localPlayer:getCurrentVehicle() or nil
    if root ~= nil and root.getRootVehicle ~= nil then
        local ok, resolved = pcall(root.getRootVehicle, root)
        if ok and resolved ~= nil then root = resolved end
    end
    self.requestSerial = (self.requestSerial or 0) + 1
    if self.frame ~= nil then self.frame:setLoading(true) end
    if g_currentMission ~= nil and g_currentMission:getIsServer() then
        TerraLogicFieldCatalog:queueSnapshot(nil, x, z, self.requestSerial, root,
            selected ~= nil)
    elseif g_client ~= nil then
        local connection = g_client:getServerConnection()
        if connection ~= nil then
            connection:sendEvent(TerraLogicFieldAnalysisRequestEvent.new(
                x, z, self.requestSerial, root, selected ~= nil))
        end
    end
end

function TerraLogicFieldAnalysis:applySnapshot(snapshot)
    if snapshot == nil or snapshot.serial < (self.requestSerial or 0) then return end
    self.snapshot = snapshot
    local selected=self.selectedField
    for _,entry in ipairs(TerraLogicFieldCatalog.entries or {}) do
        if (selected~=nil and selected.key==entry.key) or (selected==nil and entry.current) then
            if snapshot.valid then entry.areaHa,entry.condition=snapshot.areaHa,snapshot.soilQuality end
        end
    end
    if TerraLogicTutorialManager ~= nil then
        TerraLogicTutorialManager:observeAnalysis(snapshot)
    end
    TerraLogicLogging.debug("[FS25_TerraLogic] Field analysis snapshot: valid=%s field=%s id=%s samples=%s",
        tostring(snapshot.valid), tostring(snapshot.fieldScoped),
        tostring(snapshot.fieldId), tostring(snapshot.sampleCount))
    if self.frame ~= nil then self.frame:setSnapshot(snapshot) end
end

function TerraLogicFieldAnalysis:loadMap()
    self.pageInstalled, self.pageInstallFailed = false, false
    self.snapshot, self.requestCooldowns = nil, {}
    self.selectedField = nil
    if TerraLogicFieldCatalog ~= nil then TerraLogicFieldCatalog:reset() end
end

function TerraLogicFieldAnalysis:update()
    if not self.pageInstalled then self:tryInstallMenu() end
    if TerraLogicFieldCatalog ~= nil then TerraLogicFieldCatalog:update() end
end

function TerraLogicFieldAnalysis:deleteMap()
    if TerraLogicFieldCatalog ~= nil then TerraLogicFieldCatalog:reset() end
    if self.frame ~= nil and self.frame.deleteFieldMapResources ~= nil then
        self.frame:deleteFieldMapResources()
    end
    self.frame, self.snapshot = nil, nil
    self.pageInstalled, self.pageInstallFailed = false, false
end

function TerraLogicFieldAnalysis:tryInstallMenu()
    -- InGameMenu constructs its page hashes asynchronously while loadMap is
    -- still running. Registering a runtime page in that window leaves a page
    -- frame without an idPageHash entry and can stall map loading. Wait for
    -- the mission-start flag; from this point the Vanilla menu is complete.
    if self.pageInstalled or self.pageInstallFailed or g_gui == nil
        or g_currentMission == nil
        or g_currentMission.isMissionStarted ~= true then return end
    local menu = g_gui.screenControllers ~= nil and g_gui.screenControllers[InGameMenu]
        or g_currentMission.inGameMenu
    if menu == nil or menu.pagingElement == nil or menu.pagingElement.pages == nil
        or menu.pageFrames == nil or menu.controlIDs == nil then return end
    local pageName = "pageTerraLogicAnalysis"
    if menu[pageName] ~= nil then
        self.frame, self.pageInstalled = menu[pageName], true
        return
    end
    -- Prevent a malformed third-party menu replacement from causing the same
    -- insertion attempt and error on every subsequent frame.
    self.pageInstallFailed = true
    g_gui:loadProfiles(self.MOD_DIR .. "gui/guiProfiles.xml")
    local frame = TerraLogicFieldAnalysisFrame.new()
    -- This is an InGameMenu page, not a standalone screen. Loading it as a
    -- frame defers absolute layout until the paging element owns it. This is
    -- the same pattern used by Yield Tracker and prevents all children from
    -- retaining coordinates calculated against the full screen.
    g_gui:loadGui(self.MOD_DIR .. "gui/TerraLogicFieldAnalysisFrame.xml",
        "terraLogicFieldAnalysisFrame", frame, true)
    local targetPosition = #menu.pagingElement.elements + 1
    for index, child in ipairs(menu.pagingElement.elements or {}) do
        if child == menu.pageStatistics then targetPosition = index; break end
    end

    -- Add the paging entry before the frame and its icon are registered. This
    -- is the same ordering used by established FS25 menu mods and prevents an
    -- asynchronously loaded icon from rebuilding tabs during a half-created
    -- page transaction.
    menu.controlIDs[pageName] = nil
    menu[pageName] = frame
    menu.pagingElement:addElement(frame)
    if menu.exposeControlsAsFields ~= nil then menu:exposeControlsAsFields(pageName) end
    local function moveTo(list, predicate, position)
        for index, value in ipairs(list or {}) do
            if predicate(value) then
                table.remove(list, index)
                table.insert(list, math.min(position, #list + 1), value)
                return
            end
        end
    end
    moveTo(menu.pagingElement.elements,
        function(value) return value == frame end, targetPosition)
    moveTo(menu.pagingElement.pages,
        function(value) return value.element == frame end, targetPosition)
    menu.pagingElement:updateAbsolutePosition()
    menu.pagingElement:updatePageMapping()
    menu:registerPage(frame, targetPosition, function() return true end)
    -- The supplied monochrome mark can receive Vanilla's normal tab tint in
    -- every state and therefore also follows user-selected UI accent colours.
    menu:addPageTab(frame,
        self.MOD_DIR .. "gui/icon_terraLogicMenu.dds",
        GuiUtils.getUVs("0px 0px 512px 512px", {512, 512}))
    moveTo(menu.pageFrames, function(value) return value == frame end, targetPosition)
    menu:rebuildTabList()
    frame:initialize()
    self.frame, self.pageInstalled, self.pageInstallFailed = frame, true, false
end

-- Menu frame ----------------------------------------------------------------

TerraLogicFieldAnalysisFrame = {}
TerraLogicFieldAnalysisFrame.SUB = {
    OVERVIEW=1, RESULTS=2, CONDITIONS=3, PLANNER=4, ADVICE=5
}
-- The active navigation deliberately exposes only decision-oriented pages.
-- The legacy Soil detail page and the field-map prototype remain hidden; their
-- useful information is covered by Overview/Conditions and the minimap.
TerraLogicFieldAnalysisFrame.PAGE_BY_SUB = {1, 3, 4, 7, 6}
TerraLogicFieldAnalysisFrame.SUB_COUNT = 5
local TerraLogicFieldAnalysisFrame_mt = Class(
    TerraLogicFieldAnalysisFrame, TabbedMenuFrameElement)

function TerraLogicFieldAnalysisFrame.new(target, customMt)
    local self = TabbedMenuFrameElement.new(target, customMt or TerraLogicFieldAnalysisFrame_mt)
    self.name = "TerraLogicFieldAnalysis"
    self.subCategoryState = self.SUB.OVERVIEW
    self.plannerGroupIndex = 1
    self.plannerClassIndex = 1
    self.plannerSelectionManual = false
    self.fieldMapMode = 1
    self.hasCustomMenuButtons = true
    return self
end

local function bindAnalysisControls(controller, element)
    if element == nil then return end
    local id = element.id
    if id ~= nil and id ~= "" then
        local arrayName, arrayIndex = string.match(id, "^([%w_]+)%[(%d+)%]$")
        if arrayName ~= nil then
            controller[arrayName] = controller[arrayName] or {}
            controller[arrayName][tonumber(arrayIndex)] = element
        elseif controller[id] == nil then
            controller[id] = element
        end
    end
    for _, child in ipairs(element.elements or {}) do
        bindAnalysisControls(controller, child)
    end
end

function TerraLogicFieldAnalysisFrame:initialize()
    self.backButtonInfo = {inputAction=InputAction.MENU_BACK}
    self.previousButtonInfo = {inputAction=InputAction.MENU_PAGE_PREV,
        text=tr("ui_ingameMenuPrev", "Previous"),
        callback=function() self:setSubCategory(math.max(self.subCategoryState - 1, 1)) end}
    self.nextButtonInfo = {inputAction=InputAction.MENU_PAGE_NEXT,
        text=tr("ui_ingameMenuNext", "Next"),
        callback=function() self:setSubCategory(math.min(
            self.subCategoryState + 1, self.SUB_COUNT)) end}
    -- MENU_ACCEPT belongs to the focused GUI element. Binding it globally to
    -- Refresh consumed the controller's A button before tabs, help buttons and
    -- planner selectors could activate. Snapshots already refresh on page open
    -- and selection changes, so no competing global Accept action is needed.
    self:setMenuButtonInfo({self.backButtonInfo, self.previousButtonInfo,
        self.nextButtonInfo})
end

function TerraLogicFieldAnalysisFrame:focusSubCategoryPaging()
    -- The visible tab buttons only draw the individual captions. Vanilla's
    -- fs25_subCategorySelectorTabbed MultiTextOption owns gamepad navigation
    -- for the complete strip. Focusing a caption button leaves the page focus
    -- context without a valid controller target on dynamically added pages.
    local paging = self.subCategoryPaging
    if paging == nil or FocusManager == nil
        or FocusManager.setFocus == nil then return false end
    -- GIANTS' FocusManager:setFocus() is a command, not a boolean query. Some
    -- engine builds return nil after successfully assigning the focus, which
    -- previously produced a misleading warning every time the page opened.
    local ok = pcall(function() FocusManager:setFocus(paging) end)
    return ok
end

function TerraLogicFieldAnalysisFrame:onGuiSetupFinished()
    TerraLogicFieldAnalysisFrame:superClass().onGuiSetupFinished(self)
    for _, root in ipairs(self.elements or {}) do bindAnalysisControls(self, root) end
    if self.fieldBrowserList~=nil then
        self.fieldBrowserList:setDataSource(self)
        self.fieldBrowserList:setDelegate(self)
    end
    if self.recommendationList~=nil then
        self.recommendationList:setDataSource(self)
        self.recommendationList:setDelegate(self)
    end
    for _, name in ipairs({"scopeOverviewText", "scopeSoilText", "scopeYieldText", "scopeWeatherText", "scopeAdviceText", "scopePlannerText", "scopeFieldMapText"}) do
        local picker = self[name]
        if picker ~= nil and picker.setImageFilename ~= nil then
            picker:setImageFilename(TerraLogicFieldAnalysis.MOD_DIR.."gui/tableRow.dds")
        end
    end
    for _, element in ipairs(self.tableStripes or {}) do
        element:setImageFilename(TerraLogicFieldAnalysis.MOD_DIR.."gui/tableRow.dds")
    end
    if self.fieldBrowserPanel~=nil then self.fieldBrowserPanel:setVisible(false) end
    if self.menuHeaderIcon ~= nil then
        self.menuHeaderIcon:setImageFilename(
            TerraLogicFieldAnalysis.MOD_DIR .. "gui/icon_terraLogicMenu.dds")
    end
    for index, tab in ipairs(self.subCategoryTabs or {}) do
        tab.getIsSelected = function() return self.subCategoryState == index end
    end
    for _, id in ipairs({"planner_selectorContainer", "planner_groupPrevious",
            "planner_groupNext", "planner_operationPrevious",
            "planner_operationNext", "planner_group", "planner_operation"}) do
        if self[id] ~= nil then self[id]:setVisible(true) end
    end
    self:updateSubCategoryPages(self.subCategoryState)
    TerraLogicLogging.debug("[FS25_TerraLogic] Field analysis GUI ready: tabs=%d pages=%d scopes=%s/%s/%s",
        #(self.subCategoryTabs or {}), #(self.subCategoryPages or {}),
        tostring(self.scopeOverviewText ~= nil), tostring(self.scopeSoilText ~= nil),
        tostring(self.scopeYieldText ~= nil))
end

function TerraLogicFieldAnalysisFrame:onFrameOpen()
    self.fieldBrowserOpen=false
    if self.recommendationList~=nil then
        self.recommendationList:setDataSource(self)
        self.recommendationList:setDelegate(self)
    end
    for _, name in ipairs({"scopeOverviewText", "scopeSoilText", "scopeYieldText", "scopeWeatherText", "scopeAdviceText", "scopePlannerText", "scopeFieldMapText"}) do
        local picker = self[name]
        if picker ~= nil and picker.setImageFilename ~= nil then
            picker:setImageFilename(TerraLogicFieldAnalysis.MOD_DIR.."gui/tableRow.dds")
        end
    end
    for _, element in ipairs(self.tableStripes or {}) do
        element:setImageFilename(TerraLogicFieldAnalysis.MOD_DIR.."gui/tableRow.dds")
    end
    if self.fieldBrowserPanel~=nil then self.fieldBrowserPanel:setVisible(false) end
    TerraLogicFieldAnalysis.selectedField = nil
    if self.subCategoryBox ~= nil and self.subCategoryPaging ~= nil then
        for index, tab in ipairs(self.subCategoryTabs or {}) do
            tab:setVisible(index <= self.SUB_COUNT)
        end
        self.subCategoryBox:invalidateLayout()
        self.subCategoryPaging:setTexts({"1", "2", "3", "4", "5"})
        self.subCategoryPaging:setSize(
            self.subCategoryBox.maxFlowSize + 200 * g_pixelSizeScaledX, 57 * g_pixelSizeScaledY)
        -- The native arrow backgrounds may extend beyond their button bounds.
        -- Keep clipping off for this small control subtree, not for the page.
        local function unclip(element)
            element.clipping=false
            for _,child in ipairs(element.elements or {}) do unclip(child) end
        end
        unclip(self.subCategoryPaging)
        for _,part in ipairs({{"left",self.subCategoryPaging.leftButtonElement},
                {"right",self.subCategoryPaging.rightButtonElement}}) do
            if part[2]~=nil then
                part[2]:setImageFilename(TerraLogicFieldAnalysis.MOD_DIR.."gui/tabArrow_"..part[1]..".dds")
            end
        end
        self.subCategoryPaging:setState(self.subCategoryState, false)
    end
    if self.subCategoryState == self.SUB.PLANNER then
        self.plannerSelectionManual = false
    end
    self:updateSubCategoryPages(self.subCategoryState)
    TerraLogicFieldAnalysisFrame:superClass().onFrameOpen(self)
    if not self:focusSubCategoryPaging() then
        Logging.warning(
            "[FS25_TerraLogic] Field analysis controller focus could not be initialized")
    end
    local page = (self.subCategoryPages or {})[1]
    local firstCard = page ~= nil and (page.elements or {})[2] or nil
    local firstHeader = firstCard ~= nil and (firstCard.elements or {})[1] or nil
    if TerraLogicLogging.verbose and page ~= nil and firstCard ~= nil and firstHeader ~= nil then
        TerraLogicLogging.debug(
            "[FS25_TerraLogic] Field analysis geometry: page=(%.4f,%.4f) size=(%.4f,%.4f), card=(%.4f,%.4f) size=(%.4f,%.4f), header=(%.4f,%.4f) size=(%.4f,%.4f)",
            page.absPosition[1], page.absPosition[2], page.absSize[1], page.absSize[2],
            firstCard.absPosition[1], firstCard.absPosition[2],
            firstCard.absSize[1], firstCard.absSize[2],
            firstHeader.absPosition[1], firstHeader.absPosition[2],
            firstHeader.absSize[1], firstHeader.absSize[2])
    end
    -- Establish page visibility before starting any data/discovery work.
    TerraLogicFieldCatalog:open()
    TerraLogicFieldAnalysis:requestSnapshot()
end

function TerraLogicFieldAnalysisFrame:setLoading(loading)
    local value = loading and tr("terraLogic_fa_ui_loading", "Calculating field overview...") or ""
    setText(self.scopeOverviewText, value)
    setText(self.scopeSoilText, value)
    setText(self.scopeYieldText, value)
    setText(self.scopeWeatherText, value)
    setText(self.scopeWorkText, value)
    setText(self.scopeAdviceText, value)
    setText(self.scopePlannerText, value)
    setText(self.scopeFieldMapText, value)
end

function TerraLogicFieldAnalysisFrame:setSnapshot(snapshot)
    self.snapshot = snapshot
    self:deleteFieldMapResources()
    self:updateContent()
    TerraLogicFieldCatalog:updateControls()
end

function TerraLogicFieldAnalysisFrame:onClickFieldPrevious()
    TerraLogicFieldCatalog:select(-1)
end

function TerraLogicFieldAnalysisFrame:onClickFieldNext()
    TerraLogicFieldCatalog:select(1)
end

function TerraLogicFieldAnalysisFrame:getCurrentSubCategory()
    return math.clamp(tonumber(self.subCategoryState) or 1, 1, self.SUB_COUNT)
end

function TerraLogicFieldAnalysisFrame:updateSubCategoryPages(index)
    if self.fieldBrowserOpen then self:closeFieldBrowser() end
    local previousIndex = self.subCategoryState
    if index ~= nil then
        self.subCategoryState = math.clamp(
            tonumber(index) or 1, 1, self.SUB_COUNT)
    end
    local enteredPlanner = self.subCategoryState == self.SUB.PLANNER
        and previousIndex ~= self.SUB.PLANNER
    if enteredPlanner then self.plannerSelectionManual = false end
    local targetPage = self.PAGE_BY_SUB[self.subCategoryState]
        or self.subCategoryState
    for pageIndex, page in pairs(self.subCategoryPages or {}) do
        page:setVisible(pageIndex == targetPage)
    end
    if enteredPlanner and self.snapshot ~= nil then self:updatePlannerContent() end
    self:setMenuButtonInfoDirty()
    if previousIndex ~= self.subCategoryState then
        self:focusSubCategoryPaging()
    end
end

function TerraLogicFieldAnalysisFrame:onClickFieldBrowser()
    if self.fieldBrowserPanel==nil or self.fieldBrowserList==nil then return end
    self.fieldBrowserOpen=true
    for _,page in pairs(self.subCategoryPages or {}) do page:setVisible(false) end
    self.fieldBrowserPanel:setVisible(true)
    self:refreshFieldBrowser()
    self.backButtonInfo.callback=function() self:closeFieldBrowser() end
    self:setMenuButtonInfoDirty()
    if FocusManager~=nil then FocusManager:setFocus(self.fieldBrowserList) end
end

function TerraLogicFieldAnalysisFrame:closeFieldBrowser()
    self.fieldBrowserOpen=false
    if self.recommendationList~=nil then
        self.recommendationList:setDataSource(self)
        self.recommendationList:setDelegate(self)
    end
    for _, name in ipairs({"scopeOverviewText", "scopeSoilText", "scopeYieldText", "scopeWeatherText", "scopeAdviceText", "scopePlannerText", "scopeFieldMapText"}) do
        local picker = self[name]
        if picker ~= nil and picker.setImageFilename ~= nil then
            picker:setImageFilename(TerraLogicFieldAnalysis.MOD_DIR.."gui/tableRow.dds")
        end
    end
    for _, element in ipairs(self.tableStripes or {}) do
        element:setImageFilename(TerraLogicFieldAnalysis.MOD_DIR.."gui/tableRow.dds")
    end
    if self.fieldBrowserPanel~=nil then self.fieldBrowserPanel:setVisible(false) end
    if self.backButtonInfo~=nil then self.backButtonInfo.callback=nil end
    local page=self.PAGE_BY_SUB[self.subCategoryState]
    for i,element in pairs(self.subCategoryPages or {}) do element:setVisible(i==page) end
    self:setMenuButtonInfoDirty()
    self:focusSubCategoryPaging()
end

function TerraLogicFieldAnalysisFrame:refreshFieldBrowser()
    if not self.fieldBrowserOpen or self.fieldBrowserList==nil then return end
    self.browserEntries={}
    for _,entry in ipairs(TerraLogicFieldCatalog.entries or {}) do self.browserEntries[#self.browserEntries+1]=entry end
    self.fieldBrowserList:reloadData()
    if self.fieldBrowserEmpty~=nil then self.fieldBrowserEmpty:setVisible(#self.browserEntries==0) end
end

function TerraLogicFieldAnalysisFrame:getNumberOfItemsInSection(list,section)
    if list==self.recommendationList then return #(self.recommendationEntries or {}) end
    return list==self.fieldBrowserList and #(self.browserEntries or {}) or 0
end

function TerraLogicFieldAnalysisFrame:getCellTypeForItemInSection(list,section,index)
    if list==self.recommendationList then
        local entry=(self.recommendationEntries or {})[index]
        return "row"..tostring(entry and entry.height or 82)
    end
    return "default"
end

function TerraLogicFieldAnalysisFrame:populateCellForItemInSection(list,section,index,cell)
    if list==self.recommendationList then
        local entry=(self.recommendationEntries or {})[index]
        if entry~=nil then
            cell.terraLogicRecommendation=entry
            for i=0,1 do
                local background=cell:getDescendantByName("adviceBackground"..i)
                if background~=nil then
                    background:setImageFilename(TerraLogicFieldAnalysis.MOD_DIR.."gui/tableRow.dds")
                    background:setVisible((index-1)%2==i)
                end
            end
            cell:getDescendantByName("adviceTitle"):setText(entry.empty and "" or entry.title)
            local body = cell:getDescendantByName("adviceBody")
            if body ~= nil then body:setText(entry.text) end
        end
        return
    end
    if list~=self.fieldBrowserList then return end
    local entry=(self.browserEntries or {})[index]
    if entry==nil then return end
    cell.terraLogicFieldEntry=entry
    local selected=TerraLogicFieldAnalysis.selectedField
    local current=(selected~=nil and selected.key==entry.key) or (selected==nil and entry.current)
    setText(cell:getDescendantByName("fieldName"),(current and "> " or "")..TerraLogicFieldCatalog:entryName(entry))
    setText(cell:getDescendantByName("fieldArea"),entry.areaHa and entry.areaHa>0
        and TerraLogicI18n.formatArea(entry.areaHa) or "-")
    setText(cell:getDescendantByName("fieldCondition"),entry.condition~=nil
        and formatPercent(entry.condition) or tr("terraLogic_fa_browserUnknown","Not yet assessed"))
end

function TerraLogicFieldAnalysisFrame:onClickBrowserField(element)
    local entry=element~=nil and element.terraLogicFieldEntry or nil
    if entry==nil then return end
    self:closeFieldBrowser()
    TerraLogicFieldCatalog:selectEntry(entry)
end

local function compactBelow(target, source, minimumHeight, gap, baseY)
    if target==nil or source==nil or target.setPosition==nil or target.position==nil
        or source.size==nil or source.getTextHeight==nil then return end
    local scale=source.textSize and source.textSize/14 or 1/1080
    local h=math.max(minimumHeight*scale,source:getTextHeight() or 0)
    target:setPosition(target.position[1],-(baseY*scale+h+gap*scale))
end

function TerraLogicFieldAnalysisFrame:layoutPlannerNotes()
    local note=self.planner_noSoilImpact
    if note~=nil and note.text~=nil and note.text~="" then
        compactBelow(self.planner_operationNote,note,0,16,322)
    elseif self.planner_operationNote~=nil and self.planner_operationNote.setPosition~=nil then
        local scale=self.planner_operationNote.textSize and self.planner_operationNote.textSize/14 or 1/1080
        self.planner_operationNote:setPosition(self.planner_operationNote.position[1],-322*scale)
    end
end

function TerraLogicFieldAnalysisFrame:layoutSetupNotes()
    local name=self.planner_setupName
    if name==nil or name.getTextHeight==nil or name.size==nil then return end
    local scale=name.textSize and name.textSize/14 or 1/1080
    local h=math.max(20*scale,name:getTextHeight() or 0)
    if name.setSize~=nil then name:setSize(name.size[1],h) end
    -- Table header is at 124px; shift the whole group and following advice together.
    local offset=64*scale+h+16*scale-124*scale
    if self.planner_setupTable~=nil and self.planner_setupTable.setPosition~=nil then
        self.planner_setupTable:setPosition(0,-offset)
    end
    if self.planner_setupAdvice~=nil and self.planner_setupAdvice.setPosition~=nil then
        self.planner_setupAdvice:setPosition(self.planner_setupAdvice.position[1],-424*scale-offset)
    end
end

-- Height is measured with the same width/font as the visible cell templates.
function TerraLogicFieldAnalysisFrame:recommendationHeight(title, body)
    local height=20
    for _,part in ipairs({{self.recommendationMeasureTitle,title,42},{self.recommendationMeasureBody,body,101}}) do
        local element,text,approxWidth=part[1],part[2],part[3]
        local measured=math.ceil(#(text or "")/approxWidth)*20
        if element~=nil and element.getTextHeight~=nil then
            element:setText(text or "")
            local scale=element.textSize and element.textSize/16 or 1/1080
            measured=math.max(20,(element:getTextHeight() or 0)/scale)
        end
        height=math.max(height,measured)
    end
    return math.max(42,math.ceil((height+22-42-0.01)/20)*20+42)
end

function TerraLogicFieldAnalysisFrame:updateRecommendationList(recommendations)
    local previous=self.selectedRecommendationKey
    local entries,seen={},{}
    local rank={now=1,next=2,long=3}
    for _,item in ipairs(recommendations or {}) do
        if rank[item.bucket]~=nil and item.key~="terraLogic_fa_action_goodDynamic"
            and not seen[item.key or item.text] then
            seen[item.key or item.text]=true
            entries[#entries+1]={key=item.key,title=item.title,text=item.text,
                bucket=item.bucket,priority=item.priority or 0}
        end
    end
    table.sort(entries,function(a,b)
        if rank[a.bucket]~=rank[b.bucket] then return rank[a.bucket]<rank[b.bucket] end
        if a.priority~=b.priority then return a.priority>b.priority end
        return tostring(a.key)<tostring(b.key)
    end)
    -- Very long localized text continues in another cell; no words are dropped.
    local rows,total={},0
    for _,entry in ipairs(entries) do
        local chunk,part="",0
        local function append()
            if chunk=="" then return end
            part=part+1
            local height=math.min(442,self:recommendationHeight(entry.title,chunk))
            rows[#rows+1]={key=part==1 and entry.key or entry.key..":"..part,
                title=entry.title,text=chunk,height=height}
            total=total+height;chunk=""
        end
        local text=tostring(entry.text or "")
        if self:recommendationHeight(entry.title,text)<=442 then
            chunk=text
        else
            for word in text:gmatch("%S+") do
                local candidate=chunk=="" and word or chunk.." "..word
                if chunk~="" and self:recommendationHeight(entry.title,candidate)>442 then append();candidate=word end
                chunk=candidate
            end
        end
        append()
    end
    self.recommendationEntries=rows
    local selected,index=rows[1],1
    for i,entry in ipairs(rows) do if entry.key==previous then selected=entry;index=i;break end end
    self:showRecommendation(selected)
    if self.recommendationEmpty~=nil then
        self.recommendationEmpty:setVisible(#rows==0)
        setText(self.recommendationEmpty,tr(self.snapshot~=nil and self.snapshot.valid
            and "terraLogic_fa_actions_empty" or "terraLogic_fa_actions_noField","No recommendations available."))
    end
    if self.recommendationList~=nil then
        self.recommendationList:reloadData()
        if #rows>0 and self.recommendationList.setSelectedItem~=nil and previous~=self.selectedRecommendationKey then
            self.recommendationList:setSelectedItem(1,index)
        end
    end
    if self.recommendationScroll~=nil then self.recommendationScroll:setVisible(total>490) end
end

function TerraLogicFieldAnalysisFrame:onListSelectionChanged(list, section, index)
    if list==self.recommendationList then
        self:showRecommendation((self.recommendationEntries or {})[index])
    end
end

function TerraLogicFieldAnalysisFrame:showRecommendation(entry)
    self.selectedRecommendation=entry
    self.selectedRecommendationKey=entry and entry.key or nil
    setNoteText(self.recommendationTitle,entry and entry.title or "")
    setNoteText(self.recommendationBody,entry and entry.text or "")
end

function TerraLogicFieldAnalysisFrame:onClickRecommendation(element)
    if element~=nil then self:showRecommendation(element.terraLogicRecommendation) end
end

function TerraLogicFieldAnalysisFrame:onClickRecommendationDetails()
    local entry=self.selectedRecommendation
    if entry~=nil and InfoDialog~=nil and InfoDialog.show~=nil then
        InfoDialog.show(entry.title.."\n\n"..entry.text,nil,nil,nil,tr("button_ok","OK"))
    end
end

function TerraLogicFieldAnalysisFrame:setSubCategory(index)
    if self.subCategoryPaging ~= nil then self.subCategoryPaging:setState(index, true) end
    self:updateSubCategoryPages(index)
end

function TerraLogicFieldAnalysisFrame:updateCatalogScope()
    local entry=TerraLogicFieldAnalysis.selectedField
    if entry==nil then
        for _,candidate in ipairs(TerraLogicFieldCatalog.entries or {}) do
            if candidate.current then entry=candidate;break end
        end
    end
    if entry==nil or self.snapshot==nil or not self.snapshot.valid then return end
    local scope=formatFieldScope(self.snapshot)
    if (entry.sectionNumber or 0)>0 or #(entry.fieldIds or {})==0 then
        scope=TerraLogicFieldCatalog:entryName(entry)
    end
    local summary=TerraLogicI18n.format(tr("terraLogic_fa_ui_summaryScope", "%s | Field-wide assessment"),scope)
    for _,id in ipairs({"scopeOverviewText","scopeSoilText","scopeYieldText","scopeWorkText"}) do setText(self[id],summary) end
    for _,id in ipairs({"scopeWeatherText","scopeAdviceText","scopePlannerText","scopeFieldMapText"}) do setText(self[id],scope) end
end

function TerraLogicFieldAnalysisFrame:onClickOverview() self:setSubCategory(self.SUB.OVERVIEW) end
function TerraLogicFieldAnalysisFrame:onClickResults() self:setSubCategory(self.SUB.RESULTS) end
function TerraLogicFieldAnalysisFrame:onClickConditions() self:setSubCategory(self.SUB.CONDITIONS) end
function TerraLogicFieldAnalysisFrame:onClickAdvice() self:setSubCategory(self.SUB.ADVICE) end
function TerraLogicFieldAnalysisFrame:onClickPlanner()
    self.plannerSelectionManual = false
    self:setSubCategory(self.SUB.PLANNER)
    self:updatePlannerContent()
end

local FIELD_MAP_LAYERS = {
    {id="surfaceCompaction", titleKey="terraLogic_fa_map_surface",
        title="Surface compaction", legendKey="terraLogic_fa_map_legendCompaction",
        legend="Low     Moderate     High"},
    {id="deepCompaction", titleKey="terraLogic_fa_map_deep",
        title="Deep compaction", legendKey="terraLogic_fa_map_legendCompaction",
        legend="Low     Moderate     High"},
    {id="aggregateSize", titleKey="terraLogic_fa_map_tilth",
        title="Tilth", legendKey="terraLogic_fa_map_legendTilth",
        legend="Coarse     Crumbly     Too fine"},
    {id="roughness", titleKey="terraLogic_fa_map_evenness",
        title="Evenness", legendKey="terraLogic_fa_map_legendEvenness",
        legend="Even     Moderate     Rough"},
    {id="resilience", titleKey="terraLogic_fa_map_resilience",
        title="Soil resilience", legendKey="terraLogic_fa_map_legendResilience",
        legend="Low     Moderate     High"}
}

function TerraLogicFieldAnalysisFrame:deleteFieldMapResources()
    if self.fieldMapOverlay ~= nil and delete ~= nil then
        delete(self.fieldMapOverlay)
    end
    if self.fieldMapMask ~= nil and delete ~= nil then
        delete(self.fieldMapMask)
    end
    self.fieldMapOverlay = nil
    self.fieldMapMask = nil
    self.fieldMapOverlayReady = false
    self.fieldMapOverlayPending = false
    self.fieldMapCacheKey = nil
    self.fieldMapBounds = nil
end

function TerraLogicFieldAnalysisFrame:setFieldMapMode(index)
    self.fieldMapMode = math.clamp(tonumber(index) or 1, 1, #FIELD_MAP_LAYERS)
    self:deleteFieldMapResources()
    self:updateFieldMapLabels()
end

function TerraLogicFieldAnalysisFrame:updateFieldMapLabels()
    local selected = FIELD_MAP_LAYERS[self.fieldMapMode or 1]
    if selected == nil then return end
    setText(self.fieldMapLayerTitle, tr(selected.titleKey, selected.title))
    setText(self.fieldMapLegendText,
        tr(selected.legendKey, selected.legend))
    for index, button in ipairs(self.fieldMapLayerButtons or {}) do
        local layer = FIELD_MAP_LAYERS[index]
        if layer ~= nil and button ~= nil then
            button:setText((index == self.fieldMapMode and "> " or "")
                .. tr(layer.titleKey, layer.title))
        end
    end
end

function TerraLogicFieldAnalysisFrame:onClickFieldMap()
    self:setSubCategory(self.SUB.MAP)
    self:updateFieldMapLabels()
end
function TerraLogicFieldAnalysisFrame:onClickFieldMapSurface() self:setFieldMapMode(1) end
function TerraLogicFieldAnalysisFrame:onClickFieldMapDeep() self:setFieldMapMode(2) end
function TerraLogicFieldAnalysisFrame:onClickFieldMapTilth() self:setFieldMapMode(3) end
function TerraLogicFieldAnalysisFrame:onClickFieldMapEvenness() self:setFieldMapMode(4) end
function TerraLogicFieldAnalysisFrame:onClickFieldMapResilience() self:setFieldMapMode(5) end

function TerraLogicFieldAnalysisFrame:ensureFieldMapOverlay()
    local snapshot = self.snapshot
    local selected = FIELD_MAP_LAYERS[self.fieldMapMode or 1]
    local manager = TerraLogicSoilManager
    if snapshot == nil or snapshot.fieldScoped ~= true or selected == nil
        or manager == nil or manager.rasterReady ~= true
        or manager.maps == nil then
        setText(self.fieldMapStatusText,
            tr("terraLogic_fa_map_noField", "Stand on a field and refresh the analysis."))
        return false
    end
    local sourceMap = manager.maps[selected.id]
    if sourceMap == nil then
        setText(self.fieldMapStatusText,
            tr("terraLogic_fa_map_unavailable", "Soil map is not available."))
        return false
    end
    local field = getFieldAtPosition(snapshot.x, snapshot.z)
    local polygon = getFieldPolygon(field)
    if polygon == nil then
        setText(self.fieldMapStatusText,
            tr("terraLogic_fa_map_noField", "Stand on a field and refresh the analysis."))
        return false
    end
    local sizeX, sizeZ = getBitVectorMapSize(sourceMap)
    sizeX, sizeZ = tonumber(sizeX) or 0, tonumber(sizeZ) or tonumber(sizeX) or 0
    local channels = getBitVectorMapNumChannels ~= nil
        and tonumber(getBitVectorMapNumChannels(sourceMap)) or 6
    local cacheKey = string.format("%s:%s:%d:%d:%d",
        tostring(snapshot.fieldId), selected.id, sizeX, sizeZ, channels)
    if self.fieldMapCacheKey == cacheKey and self.fieldMapOverlay ~= nil then
        if self.fieldMapOverlayPending and getIsDensityMapVisualizationOverlayReady ~= nil
            and getIsDensityMapVisualizationOverlayReady(self.fieldMapOverlay) then
            self.fieldMapOverlayPending = false
            self.fieldMapOverlayReady = true
            setText(self.fieldMapStatusText, "")
        end
        return self.fieldMapOverlayReady == true
    end
    self:deleteFieldMapResources()
    if sizeX <= 0 or sizeZ <= 0 or createBitVectorMap == nil
        or createDensityMapVisualizationOverlay == nil then return false end

    local minX, maxX, minZ, maxZ = math.huge, -math.huge, math.huge, -math.huge
    for _, point in ipairs(polygon) do
        minX, maxX = math.min(minX, point.x), math.max(maxX, point.x)
        minZ, maxZ = math.min(minZ, point.z), math.max(maxZ, point.z)
    end
    local margin = math.max(math.max(maxX-minX, maxZ-minZ) * 0.04, 5)
    self.fieldMapBounds = {minX=minX-margin, maxX=maxX+margin,
        minZ=minZ-margin, maxZ=maxZ+margin}

    local ok = pcall(function()
        self.fieldMapMask = createBitVectorMap("terraLogic_analysisFieldMask")
        loadBitVectorMapNew(self.fieldMapMask, sizeX, sizeZ, 1, false)
        local modifier = DensityMapModifier.new(
            self.fieldMapMask, 0, 1, g_terrainNode)
        modifier:clearPolygonPoints()
        for _, point in ipairs(polygon) do
            modifier:addPolygonPointWorldCoords(point.x, point.z)
        end
        modifier:executeSet(1)
        modifier:clearPolygonPoints()

        local overlaySize = math.min(math.max(sizeX, 1),
            tonumber(manager.MAX_OVERLAY_RESOLUTION) or 2048)
        self.fieldMapOverlay = createDensityMapVisualizationOverlay(
            "terraLogicFieldAnalysisOverlay", overlaySize, overlaySize)
        resetDensityMapVisualizationOverlay(self.fieldMapOverlay)
        local steps = math.max(2 ^ channels - 2, 1)
        for state=1,2 ^ channels - 1 do
            local value = math.clamp((state - 1) / steps, 0, 1)
            local r, g, b = manager:getColor(selected.id, value)
            setDensityMapVisualizationOverlayStateColor(
                self.fieldMapOverlay, sourceMap, self.fieldMapMask, 1,
                0, channels, state, r, g, b)
        end
        generateDensityMapVisualizationOverlay(self.fieldMapOverlay)
    end)
    if not ok then
        self:deleteFieldMapResources()
        setText(self.fieldMapStatusText,
            tr("terraLogic_fa_map_unavailable", "Soil map is not available."))
        return false
    end
    self.fieldMapCacheKey = cacheKey
    self.fieldMapOverlayPending = true
    setText(self.fieldMapStatusText,
        tr("terraLogic_fa_map_loading", "Preparing field map..."))
    return false
end

function TerraLogicFieldAnalysisFrame:drawFieldMap()
    local viewport = self.fieldMapViewport
    if viewport == nil or viewport.absPosition == nil
        or viewport.absSize == nil then return end
    local x, y = viewport.absPosition[1], viewport.absPosition[2]
    local width, height = viewport.absSize[1], viewport.absSize[2]
    if drawFilledRect ~= nil then
        drawFilledRect(x, y, width, height, 0.015, 0.02, 0.022, 0.88)
    end
    if not self:ensureFieldMapOverlay() or self.fieldMapOverlay == nil
        or renderOverlay == nil then return end
    local bounds = self.fieldMapBounds
    local terrainSize = TerraLogicSoilManager ~= nil
        and tonumber(TerraLogicSoilManager.terrainSize) or 0
    if bounds == nil or terrainSize <= 0 then return end
    local half = terrainSize * 0.5
    local u0 = math.clamp((bounds.minX + half) / terrainSize, 0, 1)
    local u1 = math.clamp((bounds.maxX + half) / terrainSize, 0, 1)
    local v0 = math.clamp((bounds.minZ + half) / terrainSize, 0, 1)
    local v1 = math.clamp((bounds.maxZ + half) / terrainSize, 0, 1)
    -- Keep the field's world-space proportions. The wide card acts as a
    -- viewport; square fields are centered instead of being stretched flat.
    local fieldAspect = math.max(bounds.maxX-bounds.minX, 0.001)
        / math.max(bounds.maxZ-bounds.minZ, 0.001)
    local screenWidth = math.max(tonumber(g_screenWidth) or 1, 1)
    local screenHeight = math.max(tonumber(g_screenHeight) or 1, 1)
    local normalizedAspect = fieldAspect * screenHeight / screenWidth
    local drawWidth, drawHeight = width, height
    if drawWidth / math.max(drawHeight, 0.001) > normalizedAspect then
        drawWidth = drawHeight * normalizedAspect
    else
        drawHeight = drawWidth / math.max(normalizedAspect, 0.001)
    end
    local drawX = x + (width-drawWidth)*0.5
    local drawY = y + (height-drawHeight)*0.5
    setOverlayUVs(self.fieldMapOverlay,
        u0, v0, u1, v0, u0, v1, u1, v1)
    setOverlayColor(self.fieldMapOverlay, 1, 1, 1, 0.92)
    renderOverlay(self.fieldMapOverlay, drawX, drawY, drawWidth, drawHeight)
end

function TerraLogicFieldAnalysisFrame:draw()
    TerraLogicFieldAnalysisFrame:superClass().draw(self)
    if self.subCategoryState == self.SUB.MAP then self:drawFieldMap() end
end

function TerraLogicFieldAnalysisFrame:onFrameClose()
    if self.fieldBrowserOpen then self:closeFieldBrowser() end
    TerraLogicFieldCatalog.opened = false
    self:deleteFieldMapResources()
    TerraLogicFieldAnalysisFrame:superClass().onFrameClose(self)
end

local function getPlannerClasses(group)
    local result = {}
    for _, definition in ipairs(TerraLogicFieldAnalysis.MECHANIC_CLASSES) do
        if definition.group == group then result[#result+1] = definition end
    end
    return result
end

local function getPlannerDefinition(frame)
    local groups = TerraLogicFieldAnalysis.PLANNER_GROUPS
    frame.plannerGroupIndex = math.clamp(
        tonumber(frame.plannerGroupIndex) or 1, 1, #groups)
    local definitions = getPlannerClasses(groups[frame.plannerGroupIndex])
    frame.plannerClassIndex = math.clamp(
        tonumber(frame.plannerClassIndex) or 1, 1, math.max(#definitions, 1))
    return definitions[frame.plannerClassIndex], groups[frame.plannerGroupIndex]
end

local function selectPlannerClass(frame, classKey)
    for groupIndex, group in ipairs(TerraLogicFieldAnalysis.PLANNER_GROUPS) do
        local definitions = getPlannerClasses(group)
        for classIndex, definition in ipairs(definitions) do
            if definition.key == classKey then
                frame.plannerGroupIndex = groupIndex
                frame.plannerClassIndex = classIndex
                return true
            end
        end
    end
    return false
end

function TerraLogicFieldAnalysisFrame:onClickPlannerGroupPrevious()
    local count = #TerraLogicFieldAnalysis.PLANNER_GROUPS
    self.plannerGroupIndex = ((tonumber(self.plannerGroupIndex) or 1)-2)
        % count + 1
    self.plannerClassIndex = 1
    self.plannerSelectionManual = true
    self:updatePlannerContent()
end

function TerraLogicFieldAnalysisFrame:onClickPlannerGroupNext()
    local count = #TerraLogicFieldAnalysis.PLANNER_GROUPS
    self.plannerGroupIndex = (tonumber(self.plannerGroupIndex) or 1)
        % count + 1
    self.plannerClassIndex = 1
    self.plannerSelectionManual = true
    self:updatePlannerContent()
end

function TerraLogicFieldAnalysisFrame:onClickPlannerPrevious()
    local _, group = getPlannerDefinition(self)
    local count = #getPlannerClasses(group)
    self.plannerClassIndex = ((tonumber(self.plannerClassIndex) or 1)-2)
        % count + 1
    self.plannerSelectionManual = true
    self:updatePlannerContent()
end

function TerraLogicFieldAnalysisFrame:onClickPlannerNext()
    local _, group = getPlannerDefinition(self)
    local count = #getPlannerClasses(group)
    self.plannerClassIndex = (tonumber(self.plannerClassIndex) or 1)
        % count + 1
    self.plannerSelectionManual = true
    self:updatePlannerContent()
end

local function soilQuality(snapshot, key)
    local value = snapshot.soil[key] or 0
    if key == "aggregateSize" then return clamp01(snapshot.tilthQuality) end
    if key == "resilience" then return value end
    return 1 - value
end

local function statusText(value)
    return TerraLogicDisplay.caption("work", value)
end
local function formatQuality(value)
    return TerraLogicI18n.format("%s | %s", formatPercent(value), statusText(value))
end
local function formatBiologicalContinuity(value)
    return TerraLogicI18n.format("%s | %s", formatPercent(value),
        TerraLogicDisplay.caption("continuity", value))
end

local PLANNER_PURPOSE = {
    plow="Inverts and deeply loosens the upper soil, but leaves a rough, cloddy surface and disturbs long-term resilience.",
    subsoiler="Relieves deep compaction with limited surface disturbance. It is most useful where axle traffic has damaged the root zone.",
    cultivator="Loosens the upper soil and levels the field. It reduces coarse clods, but cannot repair deep compaction.",
    shallowCultivator="Levels and refines the surface with little depth. Use it for seedbed preparation, not deep repair.",
    discHarrow="Levels and fragments the surface efficiently. Repeated passes can make the seedbed unnecessarily fine.",
    powerHarrow="Produces a level, fine seedbed. It is precise but can overwork already fine soil.",
    spader="Loosens and mixes soil without reproducing every effect of a mouldboard plough.",
    roller="Consolidates and levels the seedbed. After sowing it can recover the correctable part of poor seed contact.",
    sowingMachine="Places seed in a prepared seedbed. Evenness, tilth, moisture, frost, wear and speed affect placement and gaps.",
    directDrill="Seeds without full-width tillage. It saves passes and resilience, but needs manageable compaction and surface conditions.",
    precisionPlanter="Precision placement reacts strongly to an uneven or unsuitable seedbed and excessive speed.",
    precisionDirectDrill="Combines precision placement with direct planting. It tolerates residue better than a conventional planter but still needs controlled compaction and surface contact.",
    mulcher="Processes residues and supports the following operation; speed, stones and surface conditions affect the result.",
    stonePicker="Removes surface stones. A suitable speed reduces missed areas and impact damage.",
    weeder="Controls weeds mechanically. Poor ground contact and excessive speed increase misses and may uproot the crop.",
    hoe="Controls weeds between rows. Accurate guidance, a level surface and suitable speed protect the crop.",
    liquidSprayer="Applies liquid products. Speed mainly affects coverage quality and untreated gaps.",
    fertilizerSpreader="Spreads fertilizer. Speed and equipment condition determine distribution quality.",
    manureSpreader="Spreads solid manure. Speed affects distribution and missed material.",
    slurrySpreader="Distributes slurry on the surface; traffic remains relevant even though the tool does not till the soil.",
    slurryApplicator="Places slurry close to or into the soil and therefore also reacts to penetration conditions.",
    slurryInjector="Cuts narrow slots with ground-driven discs and places slurry below the surface. It adds modest draft and wear without cultivating the full width.",
    mower="Cuts the crop. Stones, speed and rough ground influence damage and missed material.",
    windrower="Forms swaths. Excess speed can leave an irregular or incomplete swath.",
    tedder="Spreads and turns forage. Excess speed increases losses and uneven work.",
    baler="Collects and bales material. Excess speed causes pickup losses rather than a soil-work effect.",
    loaderWagon="Collects swaths. Excess speed causes pickup losses rather than a soil-work effect."
}

local function plannerLabel(key)
    local fallback = TerraLogicImplementProfiles ~= nil
        and TerraLogicImplementProfiles.PROFILES ~= nil
        and TerraLogicImplementProfiles.PROFILES[key] ~= nil
        and TerraLogicImplementProfiles.PROFILES[key].name or key
    return tr("terraLogic_fa_planner_ui_class_" .. key, fallback)
end

local function getControlledRootVehicle()
    local vehicle = g_localPlayer ~= nil and g_localPlayer.getCurrentVehicle ~= nil
        and g_localPlayer:getCurrentVehicle() or nil
    if vehicle ~= nil and vehicle.getRootVehicle ~= nil then
        local ok, root = pcall(vehicle.getRootVehicle, vehicle)
        if ok and root ~= nil then vehicle = root end
    end
    return vehicle
end

local function getVehicleTrain(root)
    if root == nil then return {} end
    local result, seen = {}, {}
    local function add(vehicle)
        if vehicle == nil or seen[vehicle] then return end
        seen[vehicle] = true
        result[#result+1] = vehicle
        if vehicle.getChildVehicles ~= nil then
            local ok, children = pcall(vehicle.getChildVehicles, vehicle)
            if ok then for _, child in ipairs(children or {}) do add(child) end end
        end
        for _, attached in ipairs(vehicle.spec_attacherJoints ~= nil
                and vehicle.spec_attacherJoints.attachedImplements or {}) do
            add(attached.object)
        end
    end
    add(root)
    return result
end

-- Vehicle weight and solved tire loads exist authoritatively on the server.
-- Keeping them in the Field Analysis response avoids a permanent 0 t / 0 kPa
-- planner result on remote clients without introducing a continuous vehicle
-- stream for values that are only needed while this menu is refreshed.
function TerraLogicFieldAnalysis:buildVehicleSetup(root)
    if root == nil or TerraLogicWheelCompactionManager == nil
        or TerraLogicWheelCompactionManager.getLoadPreview == nil then
        return nil
    end
    if root.getRootVehicle ~= nil then
        local ok, resolved = pcall(root.getRootVehicle, root)
        if ok and resolved ~= nil then root = resolved end
    end
    local train = getVehicleTrain(root)
    local result = {valid=true, vehicleMass=0, implementMass=0,
        combinationMass=0, maxAxleLoadT=0, maxPressureKPa=0}
    for index, object in ipairs(train) do
        local preview = TerraLogicWheelCompactionManager:getLoadPreview(object)
        local mass = math.max(tonumber(preview.massT) or 0, 0)
        if index == 1 then result.vehicleMass = mass
        else result.implementMass = result.implementMass + mass end
        result.combinationMass = result.combinationMass + mass
        result.maxAxleLoadT = math.max(result.maxAxleLoadT,
            tonumber(preview.maxAxleLoadT) or 0)
        result.maxPressureKPa = math.max(result.maxPressureKPa,
            tonumber(preview.maxPressureKPa) or 0)
    end
    return result
end

local function objectName(object)
    if object == nil then return "-" end
    if object.getFullName ~= nil then
        local ok, value = pcall(object.getFullName, object)
        if ok and value ~= nil and value ~= "" then return tostring(value) end
    end
    if object.getName ~= nil then
        local ok, value = pcall(object.getName, object)
        if ok and value ~= nil and value ~= "" then return tostring(value) end
    end
    return "-"
end

local function getImplementWorkWidth(object)
    local spec = object ~= nil and object.spec_terraLogic or nil
    local configured = spec ~= nil and tonumber(spec.configuredWorkWidthM) or nil
    if configured ~= nil and configured > 0 then return configured end
    local maximum = 0
    for _, area in ipairs(object ~= nil and object.spec_workArea ~= nil
            and object.spec_workArea.workAreas or {}) do
        if area.start ~= nil and area.width ~= nil then
            local sx, _, sz = getWorldTranslation(area.start)
            local wx, _, wz = getWorldTranslation(area.width)
            maximum = math.max(maximum,
                math.sqrt((wx-sx)^2 + (wz-sz)^2),
                tonumber(area.workWidth) or 0)
        end
    end
    return maximum
end

local function displayedSoilValue(key, raw)
    -- Compaction is shown as actual compaction: low is good and high is bad.
    -- Evenness remains a positive condition value although roughness is stored.
    if key == "roughness" then return 1-clamp01(raw) end
    return clamp01(raw)
end

local function displayedSoilCondition(key, displayed)
    if key == "surfaceCompaction" or key == "deepCompaction" then
        return 1-clamp01(displayed)
    end
    if key == "aggregateSize" then
        return 1-math.min(math.abs(clamp01(displayed)-0.50)/0.50, 1)
    end
    return clamp01(displayed)
end

local function plannerGroupLabel(group)
    return tr("terraLogic_fa_planner_ui_group_"..tostring(group), group)
end

local function plannerStoneNote(key)
    if key == "mower" then
        return tr("terraLogic_fa_planner_ui_stoneRiskMower",
            "Stone damage: visible stones can strike the mower; uneven ground increases exposure, and speed increases impact severity.")
    end
    if key == "stonePicker" then
        return tr("terraLogic_fa_planner_ui_stoneRiskPicker",
            "Stone effect: this pass removes visible stones, but hidden stones can still affect later soil-engaging work.")
    end
    local profile = TerraLogicImplementProfiles ~= nil
        and TerraLogicImplementProfiles.PROFILES ~= nil
        and TerraLogicImplementProfiles.PROFILES[key] or nil
    local impacts = profile ~= nil and profile.impacts or nil
    if impacts ~= nil and impacts.underground == true then
        return tr("terraLogic_fa_planner_ui_stoneRiskTillage",
            "Stone damage: working depth can contact hidden stones; stone size, speed and rotating parts determine impact damage.")
    end
    if impacts ~= nil and impacts.vanilla == true then
        return tr("terraLogic_fa_planner_ui_stoneRiskSurface",
            "Stone damage: this implement can contact visible field stones. Stone size, speed and rotating parts determine impact damage.")
    end
    return nil
end

function TerraLogicFieldAnalysisFrame:updatePlannerContent()
    for _, id in ipairs({"planner_selectorContainer", "planner_groupPrevious",
            "planner_groupNext", "planner_operationPrevious",
            "planner_operationNext", "planner_group", "planner_operation"}) do
        if self[id] ~= nil then self[id]:setVisible(true) end
    end
    local s = self.snapshot or {}
    local hasSoil = s.valid == true
    local train = getVehicleTrain(getControlledRootVehicle())
    local attached = {}
    for _, object in ipairs(train) do
        local spec = object.spec_terraLogic
        if spec ~= nil and spec.implementClassKey ~= nil then
            attached[#attached+1] = object
        end
    end
    if not self.plannerSelectionManual and attached[1] ~= nil then
        local attachedKey = attached[1].spec_terraLogic.implementClassKey
        selectPlannerClass(self, attachedKey)
    end
    local definition, selectedGroup = getPlannerDefinition(self)
    local key, mechanic = definition.key, (s.mechanics or {})[definition.key] or {}
    local attachedForClass = nil
    for _, object in ipairs(attached) do
        if object.spec_terraLogic.implementClassKey == key then
            attachedForClass = object
            break
        end
    end
    setText(self.planner_group, plannerGroupLabel(selectedGroup))
    setText(self.planner_operation, plannerLabel(key))
    local profile = TerraLogicImplementProfiles ~= nil
        and TerraLogicImplementProfiles.PROFILES ~= nil
        and TerraLogicImplementProfiles.PROFILES[key] or nil
    local hasDraftEffect = profile ~= nil and profile.draft ~= nil
        and profile.draft.enabled == true
    local workProfile = profile ~= nil and profile.work or nil
    local speed = workProfile ~= nil
        and tonumber(workProfile.optimalSpeedKph) or 0
    -- Factor-based profiles need the exact implement's shop speed at runtime.
    -- During manual class browsing no exact implement exists, so use the
    -- central realistic class reference instead of displaying no value.
    if speed <= 0 and TerraLogicImplementProfiles ~= nil then
        speed = tonumber((TerraLogicImplementProfiles.REAL_SPEED_KPH or {})[key])
            or 0
    end
    if attachedForClass ~= nil then
        local attachedSpec = attachedForClass.spec_terraLogic or {}
        local attachedOptimal = tonumber(attachedSpec.optimalSpeed) or 0
        local attachedRated = tonumber(attachedSpec.ratedSpeed) or 0
        if attachedOptimal > 0 then
            speed = attachedOptimal
        elseif attachedRated > 0 then
            if TerraLogicImplementProfiles ~= nil
                and TerraLogicImplementProfiles.getOptimalSpeed ~= nil then
                local resolved = TerraLogicImplementProfiles.getOptimalSpeed(
                    attachedRated, key, profile)
                speed = tonumber(resolved) or attachedRated
            else
                speed = attachedRated
            end
        end
    end
    if hasSoil and (key == "sowingMachine" or key == "directDrill"
        or key == "precisionPlanter" or key == "precisionDirectDrill"
        or TerraLogicSpecialImplements.SEED_CLASSES[key]) then
        speed = speed * math.clamp(tonumber(mechanic.safeSpeedRatio) or 1,
            0.35, 1)
    end
    setText(self.planner_speed, speed > 0 and TerraLogicI18n.formatSpeed(speed) or "-")
    -- The help must use the same resolved implement and soil-adjusted speed.
    self.plannerHelpSpeed = speed
    local resilienceImpact, continuityImpact =
        TerraLogicSoilManager:getImplementBiologicalImpact(key)
    setText(self.planner_resilienceImpact,
        tr("terraLogic_fa_impact_"..resilienceImpact, resilienceImpact))
    setText(self.planner_continuityImpact,
        tr("terraLogic_fa_impact_"..continuityImpact, continuityImpact))
    setText(self.planner_quality, hasSoil and key ~= "defoliator" and formatPercent(mechanic.quality or 1) or "-",
        hasSoil and (mechanic.quality or 1) or nil)
    setText(self.planner_dropout, hasSoil
        and TerraLogicI18n.format("%.1f%%", (mechanic.dropout or 0)*100) or "-",
        hasSoil and (1-math.clamp((mechanic.dropout or 0)/0.15, 0, 1)) or nil)
    setText(self.planner_draft, hasSoil and hasDraftEffect
        and TerraLogicI18n.format("x%.2f", mechanic.draft or 1) or "-",
        hasSoil and hasDraftEffect and (1-math.clamp(
            math.max((mechanic.draft or 1)-1, 0)/0.45, 0, 1)) or nil)
    local changedCount = 0
    local resultIds = {surfaceCompaction="surface", deepCompaction="deep",
        aggregateSize="tilth", roughness="evenness", resilience="resilience"}
    for _, soilKey in ipairs(TerraLogicFieldAnalysis.SOIL_KEYS) do
        local id = resultIds[soilKey]
        if not hasSoil then
            setText(self["planner_result_"..id.."Before"], "-")
            setText(self["planner_result_"..id.."After"], "-")
            setText(self["planner_result_"..id.."Delta"], "-")
        else
            local before = displayedSoilValue(
                soilKey, (s.soil or {})[soilKey])
            local after = displayedSoilValue(
                soilKey, (mechanic.projected or {})[soilKey])
            if math.abs(after-before) >= 0.00005 then
                changedCount = changedCount + 1
            end
            local isCompaction = soilKey == "surfaceCompaction"
                or soilKey == "deepCompaction"
            local beforeCondition = isCompaction
                and compactionDisplayQuality(soilKey, before)
                or displayedSoilCondition(soilKey, before)
            local afterCondition = isCompaction
                and compactionDisplayQuality(soilKey, after)
                or displayedSoilCondition(soilKey, after)
            local unchanged = math.abs(after-before) < 0.00005
            local rawDeltaPoints = (after-before)*100
            setText(self["planner_result_"..id.."Before"], formatPercent(before))
            setText(self["planner_result_"..id.."After"], formatPercent(after),
                select(2,TerraLogicDisplay.rating(soilKey, soilKey=="roughness" and 1-after or after)))
            local deltaElement = self["planner_result_"..id.."Delta"]
            setText(deltaElement, math.abs(rawDeltaPoints)<0.05 and "—" or TerraLogicI18n.format("%+.1f", rawDeltaPoints))
        end
    end
    setNoteText(self.planner_noSoilImpact, not hasSoil
        and tr("terraLogic_fa_planner_ui_fieldRequired",
            "Stand on a field to calculate soil effects and recommendations.")
        or changedCount == 0
        and tr("terraLogic_fa_planner_ui_noSoilChange",
            "The selected implement type does not change soil conditions.") or "")
    setText(self.planner_moistureLimit, hasSoil and formatPercent(
        math.max(mechanic.wet or 0, mechanic.dry or 0)) or "-")
    setText(self.planner_frostLimit, hasSoil and formatPercent(mechanic.frost or 0) or "-")
    setText(self.planner_penetration, hasSoil and formatPercent(mechanic.penetration or 1) or "-")

    setNoteText(self.planner_operationNote, tr("terraLogic_fa_table_tradeoff", "See the operation help for its purpose and trade-offs."))
    self:layoutPlannerNotes()
    local selectedImplement = attachedForClass or attached[1]
    local root = getControlledRootVehicle()
    if self.planner_setupTable~=nil then self.planner_setupTable:setVisible(root~=nil and selectedImplement~=nil) end
    if self.planner_setupEmptyHint~=nil then self.planner_setupEmptyHint:setVisible(root==nil or selectedImplement==nil) end
    if root == nil or selectedImplement == nil then
        setText(self.planner_setupName, tr("terraLogic_fa_planner_ui_enterVehicle",
            "Enter a vehicle and attach a supported implement for a setup analysis."))
        for _, id in ipairs({"planner_tractorMass","planner_implementMass",
                "planner_totalMass","planner_axleLoad","planner_groundPressure",
                "planner_traffic"}) do setText(self[id], "-") end
        setNoteText(self.planner_setupAdvice, "")
        self:layoutSetupNotes()
        compactBelow(self.planner_setupEmptyHint,self.planner_setupName,20,12,64)
        self.plannerSetupHelpValues = {
            vehicleMass="-", equipmentMass="-", combinationMass="-",
            axleLoad="-", groundPressure="-", traffic="-"
        }
        return
    end
    local selectedSpec = selectedImplement ~= nil
        and (selectedImplement.spec_terraLogic or {}) or {}
    local syncedSetup = s.vehicleSetup
    local rootPreview = {massT=0, maxAxleLoadT=0, maxPressureKPa=0}
    local implementMass, totalMass, maxAxle, maxPressure = 0, 0, 0, 0
    if syncedSetup ~= nil and syncedSetup.valid == true then
        rootPreview.massT = tonumber(syncedSetup.vehicleMass) or 0
        implementMass = tonumber(syncedSetup.implementMass) or 0
        totalMass = tonumber(syncedSetup.combinationMass)
            or rootPreview.massT + implementMass
        maxAxle = tonumber(syncedSetup.maxAxleLoadT) or 0
        maxPressure = tonumber(syncedSetup.maxPressureKPa) or 0
    else
        rootPreview = TerraLogicWheelCompactionManager ~= nil
            and TerraLogicWheelCompactionManager:getLoadPreview(root)
            or rootPreview
        totalMass = rootPreview.massT or 0
        maxAxle = rootPreview.maxAxleLoadT or 0
        maxPressure = rootPreview.maxPressureKPa or 0
        for _, object in ipairs(train) do
            if object ~= root then
                local preview = TerraLogicWheelCompactionManager ~= nil
                    and TerraLogicWheelCompactionManager:getLoadPreview(object)
                    or {massT=0}
                implementMass = implementMass + (preview.massT or 0)
                totalMass = totalMass + (preview.massT or 0)
                maxAxle = math.max(maxAxle, preview.maxAxleLoadT or 0)
                maxPressure = math.max(maxPressure,
                    preview.maxPressureKPa or 0)
            end
        end
    end
    local selectedKey = selectedSpec.implementClassKey
    local selectedMechanic = (s.mechanics or {})[selectedKey] or mechanic
    local selectedSpeed = tonumber(selectedSpec.optimalSpeed or selectedSpec.ratedSpeed) or speed
    local pressureRisk = math.clamp(maxPressure/300, 0, 1)
    local axleRisk = math.clamp(maxAxle/11, 0, 1)^2
    local trafficScore = math.max(pressureRisk*(s.trafficSurfaceMultiplier or 1),
        axleRisk*(s.trafficDeepMultiplier or 1))
    local trafficLabel = trafficScore < 0.30
        and tr("terraLogic_fa_ui_riskLow", "Low")
        or trafficScore < 0.65 and tr("terraLogic_fa_ui_riskElevated", "Elevated")
        or tr("terraLogic_fa_ui_riskHigh", "High")
    local attachmentCount = math.max(#train-1, 0)
    local setupName = objectName(root)
    if selectedImplement ~= nil then
        setupName = TerraLogicI18n.format("%s + %s", setupName,
            objectName(selectedImplement))
    end
    if attachmentCount > (selectedImplement ~= nil and 1 or 0) then
        setupName = setupName .. " " .. TerraLogicI18n.format(
            tr("terraLogic_fa_planner_ui_additionalAttachments", "(+%d more)"),
            attachmentCount-(selectedImplement ~= nil and 1 or 0))
    end
    if selectedImplement == nil then
        setupName = setupName .. "\n" .. tr(
            "terraLogic_fa_planner_ui_unsupportedTrafficOnly",
            "No supported TerraLogic implement is attached. Vehicle traffic is still analysed.")
    end
    setText(self.planner_setupName, setupName)
    self:layoutSetupNotes()
    setText(self.planner_tractorMass, TerraLogicI18n.format("%.1f t", rootPreview.massT or 0))
    setText(self.planner_implementMass, TerraLogicI18n.format("%.1f t", implementMass))
    setText(self.planner_totalMass, TerraLogicI18n.format("%.1f t", totalMass))
    setText(self.planner_axleLoad, TerraLogicI18n.format("%.1f t", maxAxle),
        1-axleRisk)
    setText(self.planner_groundPressure, TerraLogicI18n.format("%.0f kPa", maxPressure),
        1-pressureRisk)
    local loadModel = selectedSpec.mechanicalLoadModel or "none"
    local warningLoadRatio = tonumber(selectedSpec.mechanicalWarningRatio)
        or math.huge
    local ratedSpeed = math.max(tonumber(selectedSpec.ratedSpeed) or 0, 0)
    local predictedLoadRatio = loadModel ~= "none" and ratedSpeed > 0
        and math.max((selectedMechanic.draft or 1)
            * selectedSpeed/ratedSpeed, 0) or 0
    setText(self.planner_traffic, trafficLabel, 1-trafficScore)
    self.plannerSetupHelpValues = {
        vehicleMass=TerraLogicI18n.format("%.1f t", rootPreview.massT or 0),
        equipmentMass=TerraLogicI18n.format("%.1f t", implementMass),
        combinationMass=TerraLogicI18n.format("%.1f t", totalMass),
        axleLoad=TerraLogicI18n.format("%.1f t", maxAxle),
        groundPressure=TerraLogicI18n.format("%.0f kPa", maxPressure),
        traffic=trafficLabel
    }
    local advice = {}
    if not hasSoil then
        advice[#advice+1] = tr("terraLogic_fa_planner_ui_fieldRequired",
            "Vehicle values are available here. Stand on a field to calculate soil effects, traffic consequences and field-specific recommendations.")
    end
    if loadModel ~= "none" and warningLoadRatio < math.huge
            and predictedLoadRatio > warningLoadRatio then
        advice[#advice+1] = tr("terraLogic_fa_planner_ui_mechanicalOverload",
            "The estimated mechanical load at the recommended speed is above the warning threshold. Reduce speed before the structural limit is exceeded.")
    end
    if trafficScore >= 0.65 then
        advice[#advice+1] = tr("terraLogic_fa_planner_ui_trafficHigh",
            "Current axle load or ground contact pressure creates a high compaction risk. Reduce load, use suitable tires or wait for drier soil where practical.")
    elseif trafficScore >= 0.30 then
        advice[#advice+1] = tr("terraLogic_fa_planner_ui_trafficElevated",
            "Traffic risk is elevated. Avoid overlap and unnecessary headland manoeuvres.")
    end
    if selectedImplement == nil then
        advice[#advice+1] = tr("terraLogic_fa_planner_ui_catalogHint",
            "The operation forecast remains available. Use the arrows to compare supported implement classes.")
    end
    if #advice == 0 then advice[1] = tr("terraLogic_fa_planner_ui_setupSuitable",
        "The setup is plausible for the current field conditions. Keep to the recommended speed and avoid repeated traffic.") end
    setNoteText(self.planner_setupAdvice, table.concat(advice, "\n\n"))
end

function TerraLogicFieldAnalysisFrame:showPlannerSetupHelp(metric)
    local titles = {
        vehicleMass={"terraLogic_fa_planner_ui_tractorMass", "Vehicle weight"},
        equipmentMass={"terraLogic_fa_planner_ui_implementMass", "Equipment weight"},
        combinationMass={"terraLogic_fa_planner_ui_totalMass", "Combination weight"},
        axleLoad={"terraLogic_fa_planner_ui_axleLoad", "Maximum axle load"},
        groundPressure={"terraLogic_fa_planner_ui_groundPressure", "Ground contact pressure"},
        traffic={"terraLogic_fa_ui_trafficRisk", "Compaction risk"}
    }
    local valueLabels = {
        vehicleMass={"terraLogic_fa_planner_help_valueVehicleMass", "Vehicle weight: %s"},
        equipmentMass={"terraLogic_fa_planner_help_valueEquipmentMass", "Equipment weight: %s"},
        combinationMass={"terraLogic_fa_planner_help_valueCombinationMass", "Combination weight: %s"},
        axleLoad={"terraLogic_fa_planner_help_valueAxleLoad", "Maximum axle load: %s"},
        groundPressure={"terraLogic_fa_planner_help_valueGroundPressure", "Ground contact pressure: %s"},
        traffic={"terraLogic_fa_planner_help_valueTraffic", "Compaction risk: %s"}
    }
    local title = titles[metric] or titles.vehicleMass
    local valueLabel = valueLabels[metric] or valueLabels.vehicleMass
    local value = self.plannerSetupHelpValues ~= nil
        and self.plannerSetupHelpValues[metric] or "-"
    local body = TerraLogicI18n.format("%s\n\n%s\n\n%s",
        tr(title[1], title[2]),
        TerraLogicI18n.format(tr(valueLabel[1], valueLabel[2]), value),
        tr("terraLogic_fa_planner_help_setup_"..metric,
            "This value helps estimate how the current vehicle setup affects field traffic."))
    if InfoDialog ~= nil and InfoDialog.show ~= nil then
        InfoDialog.show(body, nil, nil, nil, tr("button_ok", "OK"))
    elseif g_currentMission ~= nil
        and g_currentMission.addIngameNotification ~= nil then
        g_currentMission:addIngameNotification(
            FSBaseMission.INGAME_NOTIFICATION_INFO, body)
    end
end

function TerraLogicFieldAnalysisFrame:onClickHelpPlannerOperation()
    local definition = getPlannerDefinition(self)
    local key = definition.key
    local body = tr("terraLogic_fa_planner_desc_"..key,
        PLANNER_PURPOSE[key] or "This operation is supported by TerraLogic.")
    local stoneNote = plannerStoneNote(key)
    if stoneNote ~= nil then body = body .. "\n\n" .. stoneNote end
    local title = plannerLabel(key)
    if InfoDialog ~= nil and InfoDialog.show ~= nil then
        InfoDialog.show(title .. "\n\n" .. body, nil, nil, nil,
            tr("button_ok", "OK"))
    elseif g_currentMission ~= nil
        and g_currentMission.addIngameNotification ~= nil then
        g_currentMission:addIngameNotification(
            FSBaseMission.INGAME_NOTIFICATION_INFO, title .. "\n\n" .. body)
    end
end

function TerraLogicFieldAnalysisFrame:showPlannerHelp(metric)
    local definition = getPlannerDefinition(self)
    local mechanic = self.snapshot ~= nil
        and (self.snapshot.mechanics or {})[definition.key] or {}
    local profile = TerraLogicImplementProfiles ~= nil
        and TerraLogicImplementProfiles.PROFILES ~= nil
        and TerraLogicImplementProfiles.PROFILES[definition.key] or nil
    local speed = profile ~= nil and profile.work ~= nil
        and tonumber(profile.work.optimalSpeedKph) or 0
    speed = self.plannerHelpSpeed or speed
    local hasSoilEffect = TerraLogicSoilProfiles ~= nil
        and TerraLogicSoilProfiles:getProfile(definition.key) ~= nil
    local hasDraftEffect = profile ~= nil and profile.draft ~= nil
        and profile.draft.enabled == true
    local titles = {
        speed={"terraLogic_fa_planner_ui_recommendedSpeed", "Recommended speed"},
        quality={"terraLogic_fa_planner_ui_achievableQuality", "Achievable work quality"},
        dropout={"terraLogic_fa_planner_ui_dropouts", "Expected missed areas"},
        effectiveness={"terraLogic_fa_planner_ui_soilEffectiveness", "Achievable soil effect"},
        draft={"terraLogic_fa_planner_ui_draftFactor", "Draft factor"},
        resilienceImpact={"terraLogic_fa_planner_ui_resilienceImpact", "Resilience impact"},
        continuityImpact={"terraLogic_fa_planner_ui_continuityImpact", "Continuity impact"}
    }
    local values = {
        speed=speed > 0 and TerraLogicI18n.formatSpeed(speed) or "-",
        quality=formatPercent(mechanic.quality or 1),
        dropout=TerraLogicI18n.format("%.1f%%", (mechanic.dropout or 0)*100),
        effectiveness=hasSoilEffect
            and formatPercent(mechanic.effectiveness or 1) or "-",
        draft=hasDraftEffect and TerraLogicI18n.format("x%.2f", mechanic.draft or 1) or "-",
        load=""
    }
    local valueLabels = {
        speed={"terraLogic_fa_help_valueRecommendedSpeed", "Recommended speed: %s"},
        quality={"terraLogic_fa_help_valueAchievableQuality", "Achievable work quality: %s"},
        dropout={"terraLogic_fa_help_valueExpectedGaps", "Expected missed areas: %s"},
        effectiveness={"terraLogic_fa_help_valueSoilEffect", "Achievable soil effect: %s"},
        draft={"terraLogic_fa_help_valueDraftFactor", "Draft factor: %s"}
    }
    local title = titles[metric] or titles.quality
    local text = tr("terraLogic_fa_planner_help_"..metric,
        "This value describes the selected operation under the current field conditions.")
    local valueLabel = valueLabels[metric]
    local current = values[metric] ~= nil and values[metric] ~= ""
        and TerraLogicI18n.format("\n\n%s", TerraLogicI18n.format(
            tr(valueLabel[1], valueLabel[2]), values[metric])) or ""
    local body = TerraLogicI18n.format("%s%s\n\n%s", tr(title[1], title[2]), current, text)
    if InfoDialog ~= nil and InfoDialog.show ~= nil then
        InfoDialog.show(body, nil, nil, nil, tr("button_ok", "OK"))
    elseif g_currentMission ~= nil
        and g_currentMission.addIngameNotification ~= nil then
        g_currentMission:addIngameNotification(
            FSBaseMission.INGAME_NOTIFICATION_INFO, body)
    end
end

function TerraLogicFieldAnalysisFrame:onClickHelpPlannerSpeed() self:showPlannerHelp("speed") end
function TerraLogicFieldAnalysisFrame:onClickHelpPlannerQuality() self:showPlannerHelp("quality") end
function TerraLogicFieldAnalysisFrame:onClickHelpPlannerDropout() self:showPlannerHelp("dropout") end
function TerraLogicFieldAnalysisFrame:onClickHelpPlannerDraft() self:showPlannerHelp("draft") end
function TerraLogicFieldAnalysisFrame:onClickHelpPlannerResilienceImpact() self:showPlannerHelp("resilienceImpact") end
function TerraLogicFieldAnalysisFrame:onClickHelpPlannerContinuityImpact() self:showPlannerHelp("continuityImpact") end
function TerraLogicFieldAnalysisFrame:onClickHelpPlannerVehicleMass() self:showPlannerSetupHelp("vehicleMass") end
function TerraLogicFieldAnalysisFrame:onClickHelpPlannerEquipmentMass() self:showPlannerSetupHelp("equipmentMass") end
function TerraLogicFieldAnalysisFrame:onClickHelpPlannerCombinationMass() self:showPlannerSetupHelp("combinationMass") end
function TerraLogicFieldAnalysisFrame:onClickHelpPlannerAxleLoad() self:showPlannerSetupHelp("axleLoad") end
function TerraLogicFieldAnalysisFrame:onClickHelpPlannerGroundPressure() self:showPlannerSetupHelp("groundPressure") end
function TerraLogicFieldAnalysisFrame:onClickHelpPlannerTraffic() self:showPlannerSetupHelp("traffic") end

local function joinRecommendations(recommendations, firstIndex, lastIndex)
    local lines = {}
    for index=firstIndex,lastIndex do
        local item = recommendations[index]
        if item ~= nil then lines[#lines + 1] = "- " .. item.text end
    end
    return table.concat(lines, "\n\n")
end

local function joinBucket(recommendations, bucket, maximum, compact)
    local lines = {}
    for _, item in ipairs(recommendations or {}) do
        if item.bucket == bucket and #lines < (maximum or 99) then
            lines[#lines + 1] = compact and (item.shortText or item.text) or ("- " .. item.text)
        end
    end
    if #lines > 0 then return table.concat(lines, "\n\n") end
    local key = bucket == "now" and "noImmediate" or bucket == "next" and "noNext" or "noLong"
    return tr("terraLogic_fa_ui_"..key, "No action needed.")
end

function TerraLogicFieldAnalysisFrame:showActionHelp(bucket)
    if self.snapshot == nil or self.snapshot.soil == nil then return end
    local body=joinBucket(self:buildRecommendations(self.snapshot),bucket,1)
    if InfoDialog ~= nil and InfoDialog.show ~= nil then
        InfoDialog.show(body,nil,nil,nil,tr("button_ok","OK"))
    end
end

-- Summarize the same deductions as the detailed ledger, never a second model.
local fruitName
function TerraLogicFieldAnalysisFrame:updateOverviewSummary(s)
    local active = s ~= nil and TerraLogicFieldAnalysis.hasActiveYieldCrop(s)
    setNoteText(self.overview_mainLoss, "")
    setNoteText(self.overview_cropContext, "")
    setNoteText(self.overview_coverage, "")
    if not active then return end
    local losses = {s.soilDeduction or 0, s.waterDeduction or 0, s.workDeduction or 0}
    local keys = {"Soil", "Water", "Work"}
    local largest, winner = 0, 1
    for i, loss in ipairs(losses) do
        if loss > largest then largest, winner = loss, i end
    end
    local ties = 0
    for _, loss in ipairs(losses) do
        if math.abs(loss-largest) < 0.0005 then ties = ties+1 end
    end
    local key = largest < 0.0005 and "terraLogic_fa_ui_noMainLoss"
        or (ties > 1 and "terraLogic_fa_ui_mainLossMixed"
            or "terraLogic_fa_ui_mainLoss"..keys[winner])
    setNoteText(self.overview_mainLoss, tr(key, "See Work and Yield for details."))
    local crop = fruitName(s.fruitTypeIndex)
    if (s.cropCount or 0) > 1 then
        crop = TerraLogicI18n.format(tr("terraLogic_fa_ui_cropMix", "%s (+%d more)"), crop, s.cropCount-1)
    end
    setNoteText(self.overview_cropContext, crop)
end
function TerraLogicFieldAnalysisFrame:onClickHelpActionNow() self:showActionHelp("now") end
function TerraLogicFieldAnalysisFrame:onClickHelpActionNext() self:showActionHelp("next") end
function TerraLogicFieldAnalysisFrame:onClickHelpActionLong() self:showActionHelp("long") end

fruitName = function(index)
    if index == nil or index < 0 or g_fruitTypeManager == nil then
        return tr("terraLogic_fa_ui_noCrop", "No growing crop detected")
    end
    local desc = g_fruitTypeManager:getFruitTypeByIndex(index)
    -- The fruit name is a technical identifier; fill types carry localized
    -- crop titles, including mod crops. Meadow can share grass's harvested
    -- fill type but is a distinct plant cover.
    if (FruitType ~= nil and FruitType.MEADOW ~= nil and index == FruitType.MEADOW)
        or (desc ~= nil and tostring(desc.name):upper() == "MEADOW") then
        return tr("terraLogic_fa_ui_meadow", "Meadow")
    end
    local fillType = g_fruitTypeManager.getFillTypeByFruitTypeIndex ~= nil
        and g_fruitTypeManager:getFillTypeByFruitTypeIndex(index) or nil
    local function localizedTitle(title)
        if type(title) ~= "string" or title == "" then return nil end
        local key = title:match("^%$l10n_(.+)$")
        if key ~= nil then
            if g_i18n ~= nil and g_i18n.hasText ~= nil and g_i18n:hasText(key) then
                return g_i18n:getText(key)
            end
            return nil
        end
        return title
    end
    local title = type(fillType) == "table" and localizedTitle(fillType.title) or nil
    if title == nil and desc ~= nil and desc.title ~= desc.name then
        title = localizedTitle(desc.title)
    end
    return title or tr("terraLogic_fa_ui_unknownCrop", "Unknown crop")
end

-- Presentation only: never feed these visibility decisions into yield simulation.
function TerraLogicFieldAnalysis.hasActiveYieldCrop(s)
    if s.cropShare ~= nil then return s.cropShare > 0 end
    if (s.fruitTypeIndex or -1) <= 0 or (s.growthState or -1) < 0 then return false end
    local manager = TerraLogicSoilManager
    if manager and manager.getRecoveryFruitStateInfo then
        local info = manager:getRecoveryFruitStateInfo(s.fruitTypeIndex)
        if info.withered[s.growthState] then return false end
        if info.cut[s.growthState] and not info.regrowthSources[s.growthState] then return false end
    end
    return true
end

local function formatSoilProfiles(snapshot)
    local names = {
        [0]=tr("terraLogic_fa_ui_genericSoil", "Generic soil (Precision Farming inactive)"),
        [1]=tr("terraLogic_fa_ui_loamySand", "Loamy sand"),
        [2]=tr("terraLogic_fa_ui_sandyLoam", "Sandy loam"),
        [3]=tr("terraLogic_fa_ui_loam", "Loam"),
        [4]=tr("terraLogic_fa_ui_siltyClay", "Silty clay")
    }
    local mask = math.max(math.floor(tonumber(snapshot.profileMask) or 0), 0)
    local found = {}
    for index=1,4 do
        if math.floor(mask / 2 ^ (index-1)) % 2 == 1 then
            found[#found+1] = names[index]
        end
    end
    if #found > 0 then return table.concat(found, ", ") end
    return names[snapshot.profileIndex] or names[0]
end

local function criticalAreaText(share)
    share = clamp01(share)
    local percent = math.floor(share*100+0.5)
    if percent <= 0 then
        return tr("terraLogic_fa_ui_criticalNone", "No critical area detected")
    end
    if share < 0.30 then
        return TerraLogicI18n.format(tr("terraLogic_fa_ui_criticalLocal",
            "Localized issue - %d%% of the field area"), percent)
    end
    return TerraLogicI18n.format(tr("terraLogic_fa_ui_criticalWidespread",
        "Widespread issue - %d%% of the field area"), percent)
end

function TerraLogicFieldAnalysisFrame:showMetricHelp(metric)
    local s = self.snapshot
    if s == nil or not s.valid then
        local message = tr("terraLogic_fa_ui_noField",
            "No TerraLogic field soil was found at this position.")
        if InfoDialog ~= nil and InfoDialog.show ~= nil then
            InfoDialog.show(message)
        end
        return
    end

    local titleKey, titleFallback, textKey, currentValue
    local profile = TerraLogicSoilMoistureManager ~= nil
        and (TerraLogicSoilMoistureManager.PROFILES[s.profileIndex]
            or TerraLogicSoilMoistureManager.PROFILES[0]) or {}
    local wetOnset = tonumber(profile.wetOnset) or 0.70
    local surfaceCapacity = tonumber(profile.fieldCapacitySurface) or 0.62
    local fieldCapacity = tonumber(profile.fieldCapacitySubsoil) or 0.68
    local rootWetOnset = math.min(wetOnset + 0.05, 0.84)

    if metric == "soilOverall" then
        titleKey, titleFallback = "terraLogic_fa_ui_soilCondition", "Soil condition"
        currentValue = formatPercent(s.soilQuality)
        textKey = s.soilQuality >= 0.80
            and "terraLogic_fa_help_soilGood"
            or s.soilQuality >= 0.60
                and "terraLogic_fa_help_soilWatch"
                or "terraLogic_fa_help_soilPoor"
    elseif metric == "surface" then
        local raw = clamp01(s.soil.surfaceCompaction)
        titleKey, titleFallback = "terraLogic_fa_ui_surfaceCompaction", "Surface compaction"
        currentValue = formatPercent(raw)
        textKey = "terraLogic_fa_help_surfaceScale"
    elseif metric == "deep" then
        local raw = clamp01(s.soil.deepCompaction)
        titleKey, titleFallback = "terraLogic_fa_ui_deepCompaction", "Deep compaction"
        currentValue = formatPercent(raw)
        textKey = "terraLogic_fa_help_deepScale"
    elseif metric == "tilth" then
        local raw = clamp01(s.soil.aggregateSize)
        titleKey, titleFallback = "terraLogic_fa_ui_tilth", "Tilth"
        currentValue = formatPercent(raw)
        local quality = soilQuality(s, "aggregateSize")
        textKey = quality >= 0.80 and "terraLogic_fa_help_tilthGood"
            or quality >= 0.60 and raw < 0.50
                and "terraLogic_fa_help_tilthCoarseWatch"
            or quality >= 0.60 and "terraLogic_fa_help_tilthFineWatch"
            or raw < 0.50 and "terraLogic_fa_help_tilthCoarse"
            or "terraLogic_fa_help_tilthFine"
    elseif metric == "evenness" then
        local quality = soilQuality(s, "roughness")
        titleKey, titleFallback = "terraLogic_fa_ui_evenness", "Evenness"
        currentValue = formatPercent(quality)
        textKey = quality >= 0.80
            and "terraLogic_fa_help_evennessGood"
            or quality >= 0.60
                and "terraLogic_fa_help_evennessWatch"
                or "terraLogic_fa_help_evennessPoor"
    elseif metric == "resilience" then
        local quality = soilQuality(s, "resilience")
        titleKey, titleFallback = "terraLogic_fa_ui_resilience", "Resilience"
        currentValue = formatPercent(quality)
        textKey = quality >= 0.65
            and "terraLogic_fa_help_resilienceGood"
            or quality >= 0.45
                and "terraLogic_fa_help_resilienceWatch"
                or "terraLogic_fa_help_resiliencePoor"
    elseif metric == "continuity" then
        local quality = clamp01(s.biologicalContinuity or 0.25)
        titleKey, titleFallback = "terraLogic_fa_ui_biologicalContinuity",
            "Biological continuity"
        currentValue = formatPercent(quality)
        textKey = quality >= 0.85
            and "terraLogic_fa_help_continuityEstablished"
            or quality >= 0.40
                and "terraLogic_fa_help_continuityRecovering"
                or "terraLogic_fa_help_continuityInterrupted"
    elseif metric == "yield" then
        titleKey, titleFallback = "terraLogic_fa_ui_terraLogicShare", "Estimated yield"
        currentValue = TerraLogicI18n.format("%.1f%%", s.totalFactor * 100)
        textKey = "terraLogic_fa_help_yieldGood"
    elseif metric == "root" then
        titleKey, titleFallback = "terraLogic_fa_ui_soilDeduction", "Soil during growth"
        currentValue = TerraLogicI18n.format("%.1f", (s.soilDeduction or 0) * 100)
        textKey = "terraLogic_fa_help_rootGood"
    elseif metric == "surfaceMoisture" then
        titleKey, titleFallback = "terraLogic_fa_ui_surfaceMoisture", "Topsoil moisture"
        currentValue = formatPercent(s.surfaceMoisture)
        textKey = s.surfaceMoisture < 0.32
            and "terraLogic_fa_help_surfaceMoistureDry"
            or s.surfaceMoisture >= wetOnset
                and "terraLogic_fa_help_surfaceMoistureWet"
                or "terraLogic_fa_help_surfaceMoistureGood"
    elseif metric == "rootMoisture" then
        titleKey, titleFallback = "terraLogic_fa_ui_rootMoisture", "Root-zone moisture"
        currentValue = formatPercent(s.subsoilMoisture)
        textKey = s.subsoilMoisture < fieldCapacity * 0.70
            and "terraLogic_fa_help_rootMoistureDry"
            or s.subsoilMoisture >= rootWetOnset
                and "terraLogic_fa_help_rootMoistureWet"
                or "terraLogic_fa_help_rootMoistureGood"
    elseif metric == "moisture" then
        titleKey, titleFallback = "terraLogic_fa_ui_waterDeduction", "Water supply during growth"
        currentValue = TerraLogicI18n.format("%.1f", (s.waterDeduction or 0) * 100)
        textKey = not s.moistureYieldActive and "terraLogic_fa_help_moistureDisabled"
            or "terraLogic_fa_help_moistureGood"
    elseif metric == "work" then
        titleKey, titleFallback = "terraLogic_fa_ui_totalWorkQuality", "Total work quality"
        local recorded = hasRecordedWork(s)
        currentValue = recorded and formatPercent(s.workQualityTotal)
            or tr("terraLogic_fa_ui_notRecorded", "Not recorded")
        textKey = not recorded and "terraLogic_fa_help_workNone"
            or s.workQualityTotal >= 0.80
            and "terraLogic_fa_help_workGood" or "terraLogic_fa_help_workPoor"
    elseif metric == "ledger" then
        titleKey, titleFallback = "terraLogic_fa_ui_workDeduction", "Fieldwork"
        currentValue = TerraLogicI18n.format("%.1f", (s.workDeduction or 0) * 100)
        textKey = "terraLogic_fa_help_ledgerFactor"
    elseif metric == "workSeed" then
        titleKey, titleFallback = "terraLogic_fa_ui_seeding", "Seeding"
        local value = s.categories.seed
        currentValue = value ~= nil and value >= 0 and formatPercent(value)
            or tr("terraLogic_fa_ui_notRecorded", "Not recorded")
        textKey = "terraLogic_fa_help_workSeed"
    elseif metric == "workFertilizer" then
        titleKey, titleFallback = "terraLogic_fa_ui_fertilizing", "Fertilizing"
        local value = s.categories.fertilizer
        currentValue = value ~= nil and value >= 0 and formatPercent(value)
            or tr("terraLogic_fa_ui_notRecorded", "Not recorded")
        textKey = "terraLogic_fa_help_workFertilizer"
    elseif metric == "workLime" then
        titleKey, titleFallback = "terraLogic_fa_ui_liming", "Liming"
        local value = s.categories.lime
        currentValue = value ~= nil and value >= 0 and formatPercent(value)
            or tr("terraLogic_fa_ui_notRecorded", "Not recorded")
        textKey = "terraLogic_fa_help_workLime"
    elseif metric == "workHerbicide" then
        titleKey, titleFallback = "terraLogic_fa_ui_weedControl", "Weed control"
        local value = s.categories.herbicide
        currentValue = value ~= nil and value >= 0 and formatPercent(value)
            or tr("terraLogic_fa_ui_notRecorded", "Not recorded")
        textKey = "terraLogic_fa_help_workHerbicide"
    elseif metric == "workRoller" then
        titleKey, titleFallback = "terraLogic_fa_ui_rolling", "Rolling"
        local value = s.categories.roller
        currentValue = value ~= nil and value >= 0 and formatPercent(value)
            or tr("terraLogic_fa_ui_notRecorded", "Not recorded")
        textKey = "terraLogic_fa_help_workRoller"
    elseif metric == "workMulch" then
        titleKey, titleFallback = "terraLogic_fa_ui_mulching", "Mulching"
        local value = s.categories.mulch
        currentValue = value ~= nil and value >= 0 and formatPercent(value)
            or tr("terraLogic_fa_ui_notRecorded", "Not recorded")
        textKey = "terraLogic_fa_help_workMulch"
    elseif metric == "surfaceTemperature" then
        titleKey, titleFallback = "terraLogic_fa_ui_surfaceTemperature", "Surface temperature"
        currentValue = TerraLogicI18n.formatTemperature(s.surfaceTemperatureC)
        textKey = s.surfaceFrozen
            and "terraLogic_fa_help_surfaceTemperatureFrozen"
            or "terraLogic_fa_help_surfaceTemperatureOpen"
    elseif metric == "deepTemperature" then
        titleKey, titleFallback = "terraLogic_fa_ui_deepTemperature", "Temperature at 35 cm"
        currentValue = TerraLogicI18n.formatTemperature(s.subsoilTemperatureC)
        textKey = s.subsoilFrozen
            and "terraLogic_fa_help_deepTemperatureFrozen"
            or "terraLogic_fa_help_deepTemperatureOpen"
    elseif metric == "traffic" then
        titleKey, titleFallback = "terraLogic_fa_ui_soilSensitivity", "Soil susceptibility"
        currentValue = TerraLogicI18n.format(tr("terraLogic_fa_ui_trafficLayers", "Top x%.2f / Deep x%.2f"),
            s.trafficSurfaceMultiplier or 1, s.trafficDeepMultiplier or 1)
        textKey = "terraLogic_fa_help_soilSensitivity"
    elseif metric == "tillage" then
        titleKey, titleFallback = "terraLogic_fa_ui_tillageWindow", "Tillage"
        currentValue = formatPercent(s.surfaceMoisture)
        textKey = (s.surfaceFrozen or s.surfaceMoisture >= wetOnset)
            and "terraLogic_fa_help_tillagePoor"
            or s.surfaceMoisture <= 0.14
                and "terraLogic_fa_help_tillageWatch"
                or "terraLogic_fa_help_tillageGood"
    else
        local seedbed = math.min(soilQuality(s, "aggregateSize"),
            soilQuality(s, "roughness"))
        titleKey, titleFallback = "terraLogic_fa_ui_seedingWindow", "Seeding"
        currentValue = formatPercent(seedbed)
        local tillageQuality = s.surfaceFrozen and 0.10
            or s.surfaceMoisture >= wetOnset and 0.35
            or s.surfaceMoisture <= 0.14 and 0.62 or 0.92
        seedbed = math.min(seedbed, tillageQuality)
        textKey = seedbed >= 0.80
            and "terraLogic_fa_help_seedingGood"
            or seedbed >= 0.55
                and "terraLogic_fa_help_seedingWatch"
                or "terraLogic_fa_help_seedingPoor"
    end

    local valueLabels = {
        soilOverall={"terraLogic_fa_help_valueOverallSoil", "Combined soil condition: %s"},
        surface={"terraLogic_fa_help_valueSurfaceCompaction", "Surface compaction: %s"},
        deep={"terraLogic_fa_help_valueDeepCompaction", "Deep compaction: %s"},
        tilth={"terraLogic_fa_help_valueTilth", "Tilth: %s"},
        evenness={"terraLogic_fa_help_valueEvenness", "Evenness: %s"},
        resilience={"terraLogic_fa_help_valueResilience", "Soil resilience: %s"},
        continuity={"terraLogic_fa_help_valueContinuity", "Biological continuity: %s"},
        yield={"terraLogic_fa_help_valueFinalYield", "Estimated yield: %s"},
        root={"terraLogic_fa_help_deductionValue", "Yield deduction: %s percentage points"},
        surfaceMoisture={"terraLogic_fa_help_valueTopsoilMoisture", "Current topsoil moisture: %s"},
        rootMoisture={"terraLogic_fa_help_valueRootMoisture", "Current root-zone moisture: %s"},
        moisture={"terraLogic_fa_help_deductionValue", "Yield deduction: %s percentage points"},
        ledger={"terraLogic_fa_help_deductionValue", "Yield deduction: %s percentage points"},
        work={"terraLogic_fa_help_valueWorkFactor", "Recorded field-work factor: %s"},
        workSeed={"terraLogic_fa_help_valueRecordedQuality", "Recorded work quality: %s"},
        workFertilizer={"terraLogic_fa_help_valueRecordedQuality", "Recorded work quality: %s"},
        workLime={"terraLogic_fa_help_valueRecordedQuality", "Recorded work quality: %s"},
        workHerbicide={"terraLogic_fa_help_valueRecordedQuality", "Recorded work quality: %s"},
        workRoller={"terraLogic_fa_help_valueRecordedQuality", "Recorded work quality: %s"},
        workMulch={"terraLogic_fa_help_valueRecordedQuality", "Recorded work quality: %s"},
        surfaceTemperature={"terraLogic_fa_help_valueTemperature", "Current temperature: %s"},
        deepTemperature={"terraLogic_fa_help_valueTemperature", "Current temperature: %s"},
        traffic={"terraLogic_fa_help_valueSensitivity", "Soil susceptibility: %s"},
        tillage={"terraLogic_fa_help_valueTopsoilMoisture", "Current topsoil moisture: %s"},
        seeding={"terraLogic_fa_help_valueSeedbed", "Current seedbed suitability: %s"}
    }
    local valueLabel = valueLabels[metric]
        or {"terraLogic_fa_help_currentValue", "Current field value: %s"}
    if (metric == "root" or metric == "moisture" or metric == "yield" or metric == "ledger")
            and not TerraLogicFieldAnalysis.hasActiveYieldCrop(s) then
        currentValue = "-"
        textKey = "terraLogic_fa_ui_estimateNone"
    end
    local body = TerraLogicI18n.format("%s\n\n%s\n\n%s",
        tr(titleKey, titleFallback),
        TerraLogicI18n.format(tr(valueLabel[1], valueLabel[2]),
            currentValue), tr(textKey, textKey))
    local activeYield = TerraLogicFieldAnalysis.hasActiveYieldCrop(s)
    if not activeYield and (metric == "yield" or metric == "root"
            or metric == "moisture" or metric == "ledger") then
        body = tr(titleKey, titleFallback) .. "\n\n" .. tr(textKey, textKey)
    elseif metric == "yield" then
        local delta = (s.totalFactor - 1) * 100
        local explanation = math.abs(delta) < 0.05
            and tr("terraLogic_fa_help_yieldSame", "")
            or TerraLogicI18n.format(tr(delta > 0
                and "terraLogic_fa_help_yieldMore" or "terraLogic_fa_help_yieldLess", "%.1f%%"), math.abs(delta))
        body = TerraLogicI18n.format(tr(valueLabel[1], valueLabel[2]), currentValue)
            .. "\n\n" .. explanation .. "\n\n" .. tr(textKey, textKey)
    end
    if activeYield and (metric == "yield" or metric == "root"
            or (metric == "moisture" and s.moistureYieldActive)) then
        body = body .. "\n\n" .. tr((s.growthSteps or 0) > 0
            and "terraLogic_fa_help_growthHistory" or "terraLogic_fa_help_growthPreview", "")
    end
    local coverageKey = ({workSeed="seed",workFertilizer="fertilizer",workLime="lime",
        workHerbicide="herbicide",workRoller="roller",workMulch="mulch"})[metric]
    if coverageKey~=nil then
        local share=(s.categoryCoverage or {})[coverageKey] or 0
        if share>0 then
            body=body.."\n\n"..TerraLogicI18n.format(tr("terraLogic_fa_ui_workCoverage",
                "Recorded on approx. %d%% of field area"),math.max(1,math.floor(share*100+0.5)))
        end
    end
    if metric == "seeding" then
        body = body .. "\n\n" .. tr("terraLogic_fa_table_reference",
            "Seeding forecast: precision planter at its reference speed. Other implements may respond differently.")
    end
    if metric == "workSeed" then
        local share = (s.categoryCoverage or {}).seed or 0
        local gain = (s.rollerRescuePotential or 0)
            * math.clamp(((s.mechanics or {}).roller or {}).quality or 1,0,1)
            * (TerraLogicQualityManager.QUALITY_AT_SHOP_SPEED or .95)
        if share>0 and gain>0 then
            body = body .. "\n\n" .. TerraLogicI18n.format(tr("terraLogic_fa_help_rollerPotential",
                "Estimated recoverable sowing quality: +%.1f points on the area with recorded sowing. This is not a direct yield bonus."),gain/share*100)
        end
    end
    if InfoDialog ~= nil and InfoDialog.show ~= nil then
        InfoDialog.show(body, nil, nil, nil, tr("button_ok", "OK"))
    elseif g_currentMission ~= nil and g_currentMission.addIngameNotification ~= nil then
        g_currentMission:addIngameNotification(
            FSBaseMission.INGAME_NOTIFICATION_INFO, body)
    end
end

function TerraLogicFieldAnalysisFrame:onClickHelpSoilOverall() self:showMetricHelp("soilOverall") end
function TerraLogicFieldAnalysisFrame:onClickHelpSurface() self:showMetricHelp("surface") end
function TerraLogicFieldAnalysisFrame:onClickHelpDeep() self:showMetricHelp("deep") end
function TerraLogicFieldAnalysisFrame:onClickHelpTilth() self:showMetricHelp("tilth") end
function TerraLogicFieldAnalysisFrame:onClickHelpEvenness() self:showMetricHelp("evenness") end
function TerraLogicFieldAnalysisFrame:onClickHelpResilience() self:showMetricHelp("resilience") end
function TerraLogicFieldAnalysisFrame:onClickHelpContinuity() self:showMetricHelp("continuity") end
function TerraLogicFieldAnalysisFrame:onClickHelpYield() self:showMetricHelp("yield") end
function TerraLogicFieldAnalysisFrame:onClickHelpRoot() self:showMetricHelp("root") end
function TerraLogicFieldAnalysisFrame:onClickHelpMoisture() self:showMetricHelp("moisture") end
function TerraLogicFieldAnalysisFrame:onClickHelpSurfaceMoisture() self:showMetricHelp("surfaceMoisture") end
function TerraLogicFieldAnalysisFrame:onClickHelpRootMoisture() self:showMetricHelp("rootMoisture") end
function TerraLogicFieldAnalysisFrame:onClickHelpWork() self:showMetricHelp("work") end
function TerraLogicFieldAnalysisFrame:onClickHelpWorkSeed() self:showMetricHelp("workSeed") end
function TerraLogicFieldAnalysisFrame:onClickHelpYieldWork() self:showMetricHelp("ledger") end
function TerraLogicFieldAnalysisFrame:onClickHelpWorkFertilizer() self:showMetricHelp("workFertilizer") end
function TerraLogicFieldAnalysisFrame:onClickHelpWorkLime() self:showMetricHelp("workLime") end
function TerraLogicFieldAnalysisFrame:onClickHelpWorkHerbicide() self:showMetricHelp("workHerbicide") end
function TerraLogicFieldAnalysisFrame:onClickHelpWorkRoller() self:showMetricHelp("workRoller") end
function TerraLogicFieldAnalysisFrame:onClickHelpWorkMulch() self:showMetricHelp("workMulch") end
function TerraLogicFieldAnalysisFrame:onClickHelpSurfaceTemperature() self:showMetricHelp("surfaceTemperature") end
function TerraLogicFieldAnalysisFrame:onClickHelpDeepTemperature() self:showMetricHelp("deepTemperature") end
function TerraLogicFieldAnalysisFrame:onClickHelpTraffic() self:showMetricHelp("traffic") end
function TerraLogicFieldAnalysisFrame:onClickHelpTillage() self:showMetricHelp("tillage") end
function TerraLogicFieldAnalysisFrame:onClickHelpSeeding() self:showMetricHelp("seeding") end

local function getCurrentVehicleContext(snapshot)
    local vehicle = g_localPlayer ~= nil and g_localPlayer.getCurrentVehicle ~= nil
        and g_localPlayer:getCurrentVehicle() or nil
    if vehicle == nil then return nil end
    local root = vehicle.rootVehicle or vehicle
    local diagnostic = TerraLogicWheelCompactionManager ~= nil
        and TerraLogicWheelCompactionManager.diagnostics ~= nil
        and (TerraLogicWheelCompactionManager.diagnostics[root]
            or TerraLogicWheelCompactionManager.diagnostics[vehicle]) or nil
    local synced = snapshot ~= nil and snapshot.vehicleSetup or nil
    local context = synced ~= nil and synced.valid == true and {
        mass=tonumber(synced.combinationMass) or 0,
        maxAxle=tonumber(synced.maxAxleLoadT) or 0,
        maxPressure=tonumber(synced.maxPressureKPa) or 0}
        or diagnostic ~= nil and {
        mass=tonumber(diagnostic.vehicleMass) or 0,
        maxAxle=tonumber(diagnostic.maxAxleLoad) or 0,
        maxPressure=tonumber(diagnostic.maxPressure) or 0} or {}
    local children = root.getChildVehicles ~= nil and root:getChildVehicles() or {root}
    for _, child in ipairs(children or {}) do
        local spec = child.spec_terraLogic
        if spec ~= nil and spec.implementClassKey == "roller"
            and context.rollerConditionQuality == nil then
            context.rollerConditionQuality = TerraLogicQualityManager ~= nil
                and TerraLogicQualityManager.getConditionQualityModel ~= nil
                and select(1, TerraLogicQualityManager:getConditionQualityModel(
                    child, tonumber(spec.optimalSpeed or spec.ratedSpeed) or 0))
                or 1
            context.rollerName = child.getName ~= nil
                and tostring(child:getName()) or "roller"
        end
        if spec ~= nil and spec.implementClassKey ~= nil
            and child.getWorkingSpeedRatio ~= nil then
            local ok, ratio = pcall(child.getWorkingSpeedRatio, child)
            ratio = ok and tonumber(ratio) or nil
            if ratio ~= nil and ratio > (context.speedRatio or 0) then
                context.speedRatio = ratio
                context.classKey = spec.implementClassKey
            end
        end
    end
    return next(context) ~= nil and context or nil
end

function TerraLogicFieldAnalysisFrame:buildRecommendations(snapshot)
    local recommendations = {}
    local function add(bucket, priority, key, fallback, ...)
        local template = tr(key, fallback)
        -- Hide a rounded zero missed-area figure, but retain meaningful missed areas.
        if key=="terraLogic_fa_action_seedbedDynamic" or key=="terraLogic_fa_action_seedbedDirectDynamic" then
            local missed=select(2,...)
            if tonumber(missed)~=nil and tonumber(missed)<0.05 then
                template=tr(key.."NoMisses",template)
            end
        end
        local ok, text = pcall(TerraLogicI18n.format, template, ...)
        recommendations[#recommendations + 1] = {
            bucket=bucket, priority=priority, key=key, title=tr(key.."Title", tr("terraLogic_fa_ui_advice", "Recommendation")), text=ok and text or template,
            shortText=tr(key.."Short", ok and text or template)}
    end
    local mechanics = snapshot.mechanics or {}
    local plow = mechanics.plow or {}
    local cultivate = mechanics.cultivator or {}
    local seed = mechanics.sowingMachine or {}
    local precision = mechanics.precisionPlanter or seed
    local direct = mechanics.directDrill or seed
    local precisionDirect = mechanics.precisionDirectDrill or precision
    local roller = mechanics.roller or {}
    local worstDraft = math.max(plow.draft or 1, cultivate.draft or 1)
    local tillageEffect = math.min(plow.effectiveness or 1,
        cultivate.effectiveness or 1)
    -- Recommendations explicitly describe precision sowing, so their values
    -- must come from that same class instead of a hidden worst-of mixture.
    local seedQuality = precision.quality or seed.quality or 1
    local seedDropout = precision.dropout or seed.dropout or 0
    local precisionDirectResult = (precisionDirect.quality or 0)
        * (1-math.clamp(precisionDirect.dropout or 0, 0, 1))
    local frostSeverity = math.max(plow.frost or 0, seed.frost or 0)
    local wetSeverity = math.max(plow.wet or 0, seed.wet or 0)
    local drySeverity = math.max(plow.dry or 0, seed.dry or 0)
    local vehicle = getCurrentVehicleContext(snapshot)

    if frostSeverity >= 0.08 then
        add("now", 100, "terraLogic_fa_action_frozenDynamic",
            "Wait for thaw. Frozen soil raises tillage draft to x%.2f and leaves only %d%% penetration.",
            worstDraft, math.floor(tillageEffect*100+0.5))
    elseif wetSeverity >= 0.18 then
        add("now", 96, "terraLogic_fa_action_wetDynamic",
            "Let the topsoil dry before heavy traffic or tillage. Soil-working effectiveness is currently %d%%.",
            math.floor(tillageEffect*100+0.5))
    elseif drySeverity >= 0.45 and (1-tillageEffect) >= 0.08 then
        add("now", 90, "terraLogic_fa_action_dryDynamic",
            "Very dry soil weakens tillage. Draft is about x%.2f and only %d%% of the intended soil change is achieved.",
            worstDraft, math.floor(tillageEffect*100+0.5))
    elseif (snapshot.trafficSurfaceMultiplier or 1) >= 1.12 then
        add("now", 86, "terraLogic_fa_action_trafficDynamic",
            "Traffic is currently x%.2f more damaging. Keep heavy tractors and implements on existing lanes where possible.",
            snapshot.trafficSurfaceMultiplier)
    end
    if vehicle ~= nil and ((vehicle.maxAxle or 0) >= 8.5
        or (vehicle.maxPressure or 0) >= 180)
        and (snapshot.trafficSurfaceMultiplier or 1) >= 1.08 then
        add("now", 97, "terraLogic_fa_action_heavyVehicleDynamic",
            "The current combination is heavy for these conditions: up to %.1f t axle load and %.0f kPa ground contact pressure. Moisture and resilience multiply its compaction effect, so reduce load or reuse traffic lanes.",
            vehicle.maxAxle or 0, vehicle.maxPressure or 0)
    end
    if vehicle ~= nil and (vehicle.speedRatio or 0) >= 1.08 then
        add("now", 99, "terraLogic_fa_action_overspeedDynamic",
            "The active implement is running at %.0f%% of its rated speed. Overspeed adds wear and damage, can reduce Work Quality and create missed areas; ground tools also demand extra draft.",
            vehicle.speedRatio*100)
    end

    if (snapshot.deepRootLoss or 0) >= 0.04 then
        add("next", 92, "terraLogic_fa_action_deepDynamic",
            "Loosen the root zone: deep compaction currently costs about %.1f%% yield. Use a subsoiler when the soil is workable.",
            (snapshot.deepRootLoss or 0)*100)
    end
    if (snapshot.surfaceRootLoss or 0) >= 0.04 then
        add("next", 88, "terraLogic_fa_action_surfaceDynamic",
            "Loosen the upper soil: its compaction costs about %.1f%% yield. A cultivator is suitable; plough or spade only if the planned crop and field condition require deeper inversion.",
            (snapshot.surfaceRootLoss or 0)*100)
    end
    local severeSurfaceShare = clamp01(
        snapshot.critical ~= nil and snapshot.critical.surfaceCompaction or 0)
    if severeSurfaceShare >= 0.05 and (snapshot.surfaceRootLoss or 0) < 0.04 then
        add("next", 76, "terraLogic_fa_action_surfaceTracksDynamic",
            "There are compacted wheel tracks on %d%% of the sampled area. Correct them during the next suitable cultivation instead of working the whole field only for a few tracks.",
            math.floor(severeSurfaceShare*100+0.5))
    end
    local predictedSeedLoss = 1-seedQuality
    if predictedSeedLoss >= 0.03 or seedDropout >= 0.01 then
        local directResult = (direct.quality or 0)
            * (1-math.clamp(direct.dropout or 0, 0, 1))
        local precisionResult = seedQuality
            * (1-math.clamp(seedDropout, 0, 1))
        local directBetter = math.max(directResult, precisionDirectResult)
            > precisionResult + 0.025
        add("next", 84, directBetter
                and "terraLogic_fa_action_seedbedDirectDynamic"
                or "terraLogic_fa_action_seedbedDynamic",
            directBetter
                and "Prepare a more even seedbed or use a direct drill. A precision planter would currently lose about %.1f%% Work Quality with %.1f%% soil-related missed areas. Use a shallow cultivator, disc harrow or power harrow only where tilth or evenness requires it."
                or "Prepare a more even, suitably crumbled seedbed. Precision sowing would currently lose about %.1f%% Work Quality with %.1f%% soil-related missed areas. Use a shallow cultivator, disc harrow or power harrow only where tilth or evenness requires it.",
            predictedSeedLoss*100, seedDropout*100)
    end
    local rollerQualityGain = math.max(
        tonumber(snapshot.rollerRescuePotential) or 0, 0)
        * math.clamp((tonumber(roller.quality) or 1)
            * (TerraLogicQualityManager ~= nil
                and TerraLogicQualityManager.QUALITY_AT_SHOP_SPEED or 0.95),
            0, 1)
    local seedPenaltyCap = TerraLogicQualityManager ~= nil
        and TerraLogicQualityManager.COMPONENTS ~= nil
        and TerraLogicQualityManager.COMPONENTS.seed ~= nil
        and (TerraLogicQualityManager.COMPONENTS.seed.maxYieldPenalty or 0.18)
        or 0.18
    local rollerYieldGain = rollerQualityGain * seedPenaltyCap
    local currentRollerQuality = vehicle ~= nil
        and tonumber(vehicle.rollerConditionQuality) or nil
    local currentRollerGain = currentRollerQuality ~= nil
        and rollerQualityGain * math.clamp(currentRollerQuality, 0, 1) or nil
    local currentRollerYieldGain = currentRollerGain ~= nil
        and currentRollerGain * seedPenaltyCap or nil
    local recordedSeedShare = math.max((snapshot.categoryCoverage or {}).seed or 0, 0.000001)
    -- An extra pass is recommended only for a material result.  Half a yield
    -- percentage point across the sampled field is the minimum; smaller gains
    -- stay in the help instead of urging the player to add traffic. Wet/frozen ground suppresses the advice until conditions suit it.
    if rollerYieldGain >= 0.005 and frostSeverity < 0.08
        and wetSeverity < 0.18 then
        if currentRollerGain ~= nil then
            add("next", 98, "terraLogic_fa_action_rollerRescueCurrentDynamic",
                "Improve seed contact now: a healthy roller could recover up to %.1f Sowing Quality points (about %.1f%% yield). The attached roller's condition limits the current setup to about %.1f points (%.1f%% yield). Missing seed cannot be replaced.",
                rollerQualityGain/recordedSeedShare*100, rollerYieldGain*100,
                currentRollerGain/recordedSeedShare*100, currentRollerYieldGain*100)
        else
            add("next", 98, "terraLogic_fa_action_rollerRescueDynamic",
                "Improve seed contact now: a healthy field roller at recommended speed can raise average Sowing Quality by up to %.1f points and recover about %.1f%% yield potential. It cannot replace seeds already missed.",
                rollerQualityGain/recordedSeedShare*100, rollerYieldGain*100)
        end
    end
    local resilience = soilQuality(snapshot, "resilience")
    if resilience < 0.45 then
        add("long", 72, "terraLogic_fa_action_resilienceDynamic",
            "Build soil resilience with living roots, crop rotation between shallow- and deep-rooted crops, cover crops or grass, and fewer intensive passes. Ploughing does not repair resilience.")
    elseif resilience < 0.60 then
        add("long", 45, "terraLogic_fa_action_resilienceWatchDynamic",
            "Resilience is moderate. A diverse crop rotation with crops that root at different depths, cover crops or grass, and reduced tillage make future traffic less damaging.")
    end
    local continuity = clamp01(snapshot.biologicalContinuity or 0.25)
    if continuity < 0.65 then
        add("long", 73, "terraLogic_fa_action_continuityDynamic",
            "Recent intensive tillage interrupted the biological soil structure. Keep living roots and avoid unnecessary additional passes while it gradually rebuilds.")
    end
    if snapshot.coverCrop == true
        and (snapshot.rotationRepeatedShare or 0) >= 0.50 then
        add("long", 79, "terraLogic_fa_action_coverCropRepeatedDynamic",
            "Cover crop active: its additional root bonus partly offsets this repeated crop group. For the following cash crop, change to a different rooting group to regain the full rotation-diversity benefit.")
    elseif (snapshot.rotationRepeatedShare or 0) >= 0.50 then
        add("long", 78, "terraLogic_fa_action_rotationRepeatedDynamic",
            "A similar crop group follows itself on %.0f%% of the field. Repetition receives only part of the normal resilience gain; rotate to a different rooting group or establish a cover crop next.",
            (snapshot.rotationRepeatedShare or 0)*100)
    elseif snapshot.coverCrop == true then
        add("long", 74, "terraLogic_fa_action_coverCropDynamic",
            "Cover crop active: its living roots receive an additional resilience and soil-structure bonus while the crop develops. Keep it established until the next planned operation.")
    elseif (snapshot.rotationDiverseShare or 0) >= 0.50
        and resilience < 0.78 then
        add("long", 50, "terraLogic_fa_action_rotationDiverseDynamic",
            "A diverse crop-group transition is active on %.0f%% of the field and is building resilience more effectively than a repeated group.",
            (snapshot.rotationDiverseShare or 0)*100)
    end
    if snapshot.moistureYieldActive and snapshot.moistureFactor < 0.97 then
        add("result", 65, "terraLogic_fa_action_cropWaterDynamic",
            "Water supply during growth has reduced final yield potential by about %.1f%%. This is recorded weather history, not a problem that fieldwork can undo.",
            (1-snapshot.moistureFactor)*100)
    end
    if snapshot.ledgerFactor < 0.97 then
        add("result", 60, "terraLogic_fa_action_workQualityDynamic",
            "Recorded fieldwork has reduced final yield potential by about %.1f%%. Check the Work Quality page for the operation involved.",
            (1-snapshot.ledgerFactor)*100)
    end
    if snapshot.totalFactor > 1.005 then
        add("result", 58, "terraLogic_fa_action_yieldGainDynamic",
            "Healthy roots, accurate fieldwork and resilient soil currently raise TerraLogic yield to %.1f%% of the Vanilla/Precision Farming result.",
            snapshot.totalFactor*100)
    end
    if #recommendations == 0 then
        add("next", 1, "terraLogic_fa_action_goodDynamic",
            "No corrective pass is justified by the current consequences. Choose the next operation for the crop and avoid unnecessary traffic.")
    end
    table.sort(recommendations, function(a, b) return a.priority > b.priority end)
    return recommendations
end

-- A result card has one populated state and one quiet empty state.
function TerraLogicFieldAnalysisFrame:setYieldCardState(active, hasField)
    for _,prefix in ipairs({"overview","yield"}) do
        local content=self[prefix.."_yieldContent"]
        local empty=self[prefix.."_yieldEmpty"]
        if content~=nil and content.setVisible~=nil then content:setVisible(active) end
        if empty~=nil and empty.setVisible~=nil then empty:setVisible(not active) end
        setNoteText(self[prefix.."_yieldEmptyReason"], hasField
            and tr("terraLogic_fa_ui_yieldEmptyReason", "No active harvest crop was detected on this field.")
            or tr("terraLogic_fa_ui_yieldNoField", "Select a field to display its yield estimate."))
    end
end

function TerraLogicFieldAnalysisFrame:updateContent()
    if self.work_total~=nil then self.work_total:setVisible(false) end
    if self.work_totalEmpty~=nil then self.work_totalEmpty:setVisible(true) end
    self:setYieldCardState(false, false)
    self:updateOverviewSummary(nil)
    if self.planner_setupTable~=nil then self.planner_setupTable:setVisible(false) end
    if self.planner_setupEmptyHint~=nil then self.planner_setupEmptyHint:setVisible(false) end
    for _,id in ipairs({"weather_trafficTop","weather_trafficDeep","weather_seedQuality","weather_seedGaps"}) do setText(self[id], "-") end
    -- Clear supplementary cells even when the next selection has no soil data.
    for _, id in ipairs({"surface","deep","tilth","evenness","resilience","continuity"}) do
        setText(self["overview_"..id.."Rating"], "")
    end
    for _, id in ipairs(TerraLogicFieldAnalysis.CATEGORY_KEYS) do
        setText(self["work_"..id.."Rating"], "")
    end
    local s = self.snapshot
    if s == nil or not s.valid then
        self:updateRecommendationList({})
        local message = tr("terraLogic_fa_ui_noField", "No TerraLogic field soil was found at this position.")
        setText(self.scopeOverviewText, message)
        setText(self.scopeSoilText, message)
        setText(self.scopeYieldText, message)
        setText(self.scopeWeatherText, message)
        setText(self.scopeWorkText, message)
        setText(self.scopeAdviceText, message)
        setText(self.scopePlannerText, message)
        setText(self.scopeFieldMapText, message)
        local valueIds = {
            "overview_soilTotal", "overview_surface", "overview_deep",
            "overview_tilth", "overview_evenness", "overview_resilience",
            "overview_continuity",
            "overview_yieldTotal", "overview_net", "overview_stage", "overview_crop", "overview_root",
            "overview_water", "overview_work", "soil_surface", "soil_deep",
            "soil_tilth", "soil_evenness", "soil_resilience", "soil_profile",
            "soil_surfaceMoisture", "soil_subsoilMoisture",
            "soil_surfaceTemperature", "soil_subsoilTemperature",
            "yield_total", "yield_crop", "yield_stage", "yield_root",
            "yield_moisture", "yield_ledger", "yield_seed",
            "yield_fertilizer", "yield_lime", "yield_herbicide",
            "yield_roller", "yield_mulch", "weather_profile", "weather_current",
            "weather_surfaceMoisture", "weather_subsoilMoisture",
            "weather_surfaceTemperature", "weather_subsoilTemperature",
            "weather_initializationHint", "weather_effectSummary",
            "weather_traffic", "weather_tillage",
            "weather_seeding", "weather_cropWater", "work_total",
            "work_seed", "work_fertilizer", "work_lime",
            "work_herbicide", "work_roller", "work_mulch",
            "soil_surfaceYieldLoss", "soil_deepYieldLoss",
            "soil_seedingSuitability", "soil_trafficSensitivity",
            "yield_surfaceLoss", "yield_deepLoss", "yield_waterLoss",
            "yield_workLoss"
        }
        for _, id in ipairs({"planner_group","planner_operation","planner_speed","planner_quality",
                "planner_dropout","planner_draft",
                "planner_tractorMass","planner_implementMass","planner_totalMass",
                "planner_axleLoad","planner_groundPressure",
                "planner_traffic"}) do valueIds[#valueIds+1] = id end
        for _, id in ipairs(valueIds) do setText(self[id], "-") end
        setText(self.overview_coverage, "")
        setText(self.yield_coverage, "")
        setText(self.work_harvestStatus, "")
        for _, key in ipairs(TerraLogicFieldAnalysis.CATEGORY_KEYS) do
            setNoteText(self["workCoverage_" .. key], "")
        end
        setText(self.overview_actionNow, "-")
        setText(self.overview_actionNext, "-")
        setText(self.overview_actionLong, "-")
        for _, id in ipairs({"surface", "deep", "tilth", "evenness", "resilience"}) do
            setText(self["soil_" .. id .. "Area"], "")
        end
        setText(self.soil_consequenceText, message)
        setText(self.weather_effectSummary, message)
        setText(self.adviceListNow, "-")
        setText(self.adviceListNext, "-")
        setText(self.adviceListLong, "-")
        for _, id in ipairs({"surface","deep","tilth","evenness","resilience"}) do
            setText(self["planner_result_"..id.."Before"], "-")
            setText(self["planner_result_"..id.."After"], "-")
            setText(self["planner_result_"..id.."Delta"], "-")
        end
        setNoteText(self.planner_noSoilImpact, message)
        setText(self.planner_moistureLimit, "-")
        setText(self.planner_frostLimit, "-")
        setText(self.planner_penetration, "-")
        setText(self.planner_setupName, message)
        setNoteText(self.planner_setupAdvice, "")
        -- Soil forecasting needs a field, but the attached vehicle's mass,
        -- axle load and contact pressure do not.
        self:updatePlannerContent()
        return
    end
    local scope = formatFieldScope(s)
    local selected=TerraLogicFieldAnalysis.selectedField
    if selected==nil then
        for _,entry in ipairs(TerraLogicFieldCatalog.entries or {}) do
            if entry.current then selected=entry;break end
        end
    end
    if selected~=nil and ((selected.sectionNumber or 0)>0
            or (#(selected.fieldIds or {})==0 and (selected.customId or 0)>0)) then
        scope=TerraLogicFieldCatalog:entryName(selected)
    end
    local summaryScope = TerraLogicI18n.format(tr("terraLogic_fa_ui_summaryScope",
        "%s | Field-wide assessment"), scope)
    setText(self.scopeOverviewText, summaryScope)
    setText(self.scopeSoilText, summaryScope)
    setText(self.scopeYieldText, summaryScope)
    setText(self.scopeWeatherText, scope)
    setText(self.scopeWorkText, summaryScope)
    setText(self.scopeAdviceText, scope)
    setText(self.scopePlannerText, scope)
    setText(self.scopeFieldMapText, scope)
    self:updateFieldMapLabels()
    local labels = {surfaceCompaction="surface", deepCompaction="deep",
        aggregateSize="tilth", roughness="evenness", resilience="resilience"}
    for key, id in pairs(labels) do
        local value = soilQuality(s, key)
        local isCompaction = key == "surfaceCompaction"
            or key == "deepCompaction"
        local raw = clamp01(s.soil[key])
        local displayed = (isCompaction or key=="aggregateSize") and raw or value
        local display = TerraLogicI18n.format("%s | %s",formatPercent(displayed),
            TerraLogicDisplay.caption(key,raw))
        local _, color = TerraLogicDisplay.rating(key,raw)
        setText(self["overview_" .. id], formatPercent(displayed))
        setText(self["overview_" .. id .. "Rating"], TerraLogicDisplay.caption(key,raw), color)
        setText(self["soil_" .. id], display, color)
        setText(self["soil_" .. id .. "Area"],
            criticalAreaText(s.critical[key] or 0))
    end
    setText(self.overview_soilTotal, formatPercent(s.soilQuality), s.soilQuality)
    setText(self.overview_continuity, formatPercent(s.biologicalContinuity or 0.25))
    setText(self.overview_continuityRating, TerraLogicDisplay.caption("continuity",s.biologicalContinuity or 0.25),
        s.biologicalContinuity or 0.25, "continuity")
    setText(self.overview_yieldTotal, TerraLogicI18n.format("%.1f%%", s.totalFactor*100),
        consequenceQuality(1-s.totalFactor, totalYieldLossMaximum()))
    setText(self.overview_crop, fruitName(s.fruitTypeIndex))
    setText(self.overview_root, formatPercent(s.rootFactor),
        consequenceQuality(1-s.rootFactor, rootZoneLossMaximum()))
    setText(self.overview_water, s.moistureYieldActive
        and formatPercent(s.moistureFactor)
        or tr("terraLogic_fa_ui_disabled", "Disabled"),
        consequenceQuality(s.moistureYieldActive and 1-s.moistureFactor or 0,
            rootZoneLossMaximum()))
    local recordedWork = hasRecordedWork(s)
    if self.work_total~=nil then self.work_total:setVisible(recordedWork) end
    if self.work_totalEmpty~=nil then self.work_totalEmpty:setVisible(not recordedWork) end
    setText(self.work_harvestStatus, s.harvestPending
        and tr("terraLogic_fa_ui_harvestPending", "Harvest is not yet complete in some areas.") or "")
    local yieldWork = s.yieldRecordedWork == true
    setText(self.overview_work,
        yieldWork and formatPercent(s.ledgerFactor) or "-",
        yieldWork and consequenceQuality(1-s.ledgerFactor, totalYieldLossMaximum()) or nil)
    local recommendations = self:buildRecommendations(s)
    for _, item in ipairs({{"now", "Now", "noImmediate"}, {"next", "Next", "noNext"}, {"long", "Long", "noLong"}}) do
        local text = joinBucket(recommendations, item[1], 1, true)
        if text == "-" then text = tr("terraLogic_fa_ui_"..item[3], "No action needed.") end
        setNoteText(self["overview_action"..item[2]], text)
    end
    self:updateOverviewSummary(s)
    self:updateRecommendationList(recommendations)
    setText(self.soil_profile, formatSoilProfiles(s))
    local seedMechanic = (s.mechanics or {}).precisionPlanter
        or (s.mechanics or {}).sowingMachine or {}
    setText(self.soil_surfaceYieldLoss,
        TerraLogicI18n.format("%.1f%%", (s.surfaceRootLoss or 0)*100),
        consequenceQuality(s.surfaceRootLoss,
            compactionLossMaximum("surfaceCompaction")))
    setText(self.soil_deepYieldLoss,
        TerraLogicI18n.format("%.1f%%", (s.deepRootLoss or 0)*100),
        consequenceQuality(s.deepRootLoss,
            compactionLossMaximum("deepCompaction")))
    setText(self.soil_seedingSuitability, TerraLogicI18n.format(
        tr("terraLogic_fa_ui_qualityDropoutFormat", "%d%% quality / %.1f%% missed areas"),
        math.floor((seedMechanic.quality or 1)*100+0.5),
        (seedMechanic.dropout or 0)*100), seedMechanic.quality or 1)
    setText(self.soil_trafficSensitivity, TerraLogicI18n.format("x%.2f",
        s.trafficSurfaceMultiplier or 1),
        1-math.clamp(((s.trafficSurfaceMultiplier or 1)-1)/0.45, 0, 1))
    setText(self.soil_consequenceText,
        tr("terraLogic_fa_note_soilConsequenceNote",
            "These consequences use the same soil, weather and implement model as fieldwork. Compaction is shown directly: 0% is loose and 100% is severely compacted; a warning appears when the expected effect becomes material."))
    setText(self.yield_total, TerraLogicI18n.format("%.1f%%", s.totalFactor*100),
        consequenceQuality(1-s.totalFactor, totalYieldLossMaximum()))
    setText(self.yield_crop, fruitName(s.fruitTypeIndex))
    setText(self.yield_root, formatPercent(s.rootFactor),
        consequenceQuality(1-s.rootFactor, rootZoneLossMaximum()))
    setText(self.yield_moisture, s.moistureYieldActive and formatPercent(s.moistureFactor)
        or tr("terraLogic_fa_ui_disabled", "Disabled"),
        consequenceQuality(s.moistureYieldActive and 1-s.moistureFactor or 0,
            rootZoneLossMaximum()))
    setText(self.yield_ledger, formatPercent(s.ledgerFactor),
        consequenceQuality(1-s.ledgerFactor, totalYieldLossMaximum()))
    setText(self.yield_surfaceLoss, formatLossPercent(s.soilDeduction),
        (s.soilDeduction or 0)>=0.0005 and consequenceQuality(s.soilDeduction, 0.50) or nil)
    setText(self.yield_waterLoss, formatLossPercent(s.waterDeduction),
        (s.waterDeduction or 0)>=0.0005 and consequenceQuality(s.waterDeduction, 0.50) or nil)
    setText(self.yield_workLoss, formatLossPercent(s.workDeduction),
        (s.workDeduction or 0)>=0.0005 and consequenceQuality(s.workDeduction, 0.50) or nil)
    setText(self.yield_deepLoss, TerraLogicI18n.format(tr("terraLogic_fa_ui_netYieldFormat",
        "%+.1f%% compared with base yield"), (s.totalFactor-1)*100),
        consequenceQuality(1-s.totalFactor, totalYieldLossMaximum()))
    setText(self.overview_net, TerraLogicI18n.format(tr("terraLogic_fa_ui_netYieldFormat",
        "%+.1f%% compared with base yield"),(s.totalFactor-1)*100),
        consequenceQuality(1-s.totalFactor,totalYieldLossMaximum()))
    setText(self.overview_surfaceLoss, formatLossPercent(s.soilDeduction),
        (s.soilDeduction or 0)>=0.0005 and consequenceQuality(s.soilDeduction, 0.50) or nil)
    setText(self.overview_waterLoss, formatLossPercent(s.waterDeduction),
        (s.waterDeduction or 0)>=0.0005 and consequenceQuality(s.waterDeduction, 0.50) or nil)
    setText(self.overview_workLoss, formatLossPercent(s.workDeduction),
        (s.workDeduction or 0)>=0.0005 and consequenceQuality(s.workDeduction, 0.50) or nil)
    local activeCrop = TerraLogicFieldAnalysis.hasActiveYieldCrop(s)
    self:setYieldCardState(activeCrop, true)
    local cropCaption = fruitName(s.fruitTypeIndex)
    if (s.cropCount or 0) > 1 then
        cropCaption = TerraLogicI18n.format(tr("terraLogic_fa_ui_cropMix", "%s (+%d more)"),
            cropCaption, s.cropCount - 1)
    end
    setText(self.overview_crop, cropCaption)
    setText(self.yield_crop, cropCaption)
    local status = not activeCrop
        and tr("terraLogic_fa_ui_estimateNone", "No active crop - no yield estimate yet.")
        or ((s.growthSteps or 0) > 0
            and tr("terraLogic_fa_ui_contextHistory", "Applies to the existing crop, not unsown areas. Includes growth recorded so far; the estimate can change as growth continues.")
            or tr("terraLogic_fa_ui_contextCurrent", "Applies to the existing crop, not unsown areas. Based on current conditions; the estimate can change during growth."))
    setNoteText(self.overview_stage, activeCrop and tr("terraLogic_fa_ui_overviewYieldNote", "Applies only to the existing crop. The estimate can change during growth.") or "")
    setNoteText(self.yield_stage, status)
    local coverage = activeCrop and TerraLogicI18n.format(
        tr("terraLogic_fa_ui_cropAreaValue", "Approx. %d%%"),
        math.max(1, math.floor(clamp01(s.cropShare)*100+0.5))) or ""
    setText(self.overview_coverage, coverage)
    setText(self.yield_coverage, coverage)
    if not activeCrop then
        setText(self.overview_crop, tr("terraLogic_fa_ui_noCrop", "No growing crop detected"))
        setText(self.yield_crop, tr("terraLogic_fa_ui_noCrop", "No growing crop detected"))
        for _, name in ipairs({"overview_root", "overview_water", "overview_yieldTotal",
                "yield_root", "yield_moisture", "yield_total", "yield_surfaceLoss",
                 "yield_deepLoss", "yield_waterLoss", "yield_workLoss",
                 "overview_work", "yield_ledger", "overview_net"}) do
            setText(self[name], "-")
        end
    end
    if not yieldWork then
        setText(self.yield_ledger, "-")
        -- No recorded work contributes zero to the additive deductions.
    end
    for _, key in ipairs(TerraLogicFieldAnalysis.CATEGORY_KEYS) do
        local value = s.categories[key]
        local display = value ~= nil and value >= 0
            and formatPercent(value)
            or ""
        local color = value ~= nil and value >= 0 and value or nil
        setText(self["work_" .. key], display, color~=nil and select(2,TerraLogicDisplay.rating("work",color)) or nil)
        setText(self["work_" .. key .. "Rating"], color~=nil and TerraLogicDisplay.caption("work",color)
            or tr("terraLogic_fa_ui_notRecorded", "Not recorded"),
            color~=nil and select(2,TerraLogicDisplay.rating("work",color)) or nil)
        if color == nil then
            for _, suffix in ipairs({"", "Rating"}) do
                local element = self["work_"..key..suffix]
                if element ~= nil then element:setTextColor(0.65, 0.65, 0.65, 1) end
            end
        end
        local share = (s.categoryCoverage or {})[key] or 0
        setNoteText(self["workCoverage_" .. key], share > 0 and share < 0.995 and TerraLogicI18n.format(
            tr("terraLogic_fa_ui_workCoverage", "Recorded on approx. %d%% of field area"),
            math.max(1, math.floor(clamp01(share)*100+0.5))) or "")
    end

    local profile = TerraLogicSoilMoistureManager ~= nil
        and TerraLogicSoilMoistureManager.PROFILES[s.profileIndex] or nil
    profile = profile or (TerraLogicSoilMoistureManager ~= nil
        and TerraLogicSoilMoistureManager.PROFILES[0]) or {}
    local profileText = formatSoilProfiles(s)
    setText(self.weather_profile, profileText)
    local temperatureState = TerraLogicSoilTemperatureManager ~= nil
        and TerraLogicSoilTemperatureManager.getState ~= nil
        and TerraLogicSoilTemperatureManager:getState() or {}
    local moistureState = TerraLogicSoilMoistureManager ~= nil
        and TerraLogicSoilMoistureManager.getState ~= nil
        and TerraLogicSoilMoistureManager:getState() or {}
    local airTemperature = tonumber(temperatureState.airTemperatureC)
        or tonumber(s.surfaceTemperatureC) or 0
    local precipitation = math.clamp(
        tonumber(moistureState.rainScale) or 0, 0, 1)
    local liquidShare = math.clamp(
        tonumber(moistureState.liquidPrecipitationFactor) or 0, 0, 1)
    local precipitationText
    if precipitation < 0.01 then
        precipitationText = tr("terraLogic_fa_ui_weatherDry", "No precipitation")
    elseif liquidShare >= 0.75 then
        precipitationText = TerraLogicI18n.format(tr(
            "terraLogic_fa_ui_weatherRain", "Rain %.0f%%"),
            precipitation * 100)
    elseif liquidShare <= 0.25 then
        precipitationText = TerraLogicI18n.format(tr(
            "terraLogic_fa_ui_weatherSnow", "Snow %.0f%%"),
            precipitation * 100)
    else
        precipitationText = TerraLogicI18n.format(tr(
            "terraLogic_fa_ui_weatherMixed", "Mixed precipitation %.0f%%"),
            precipitation * 100)
    end
    setText(self.weather_current, TerraLogicI18n.format("%s  |  %s",
        TerraLogicI18n.formatTemperature(airTemperature), precipitationText))
    setText(self.weather_surfaceMoisture, formatPercent(s.surfaceMoisture))
    setText(self.weather_subsoilMoisture, formatPercent(s.subsoilMoisture))
    setText(self.weather_surfaceTemperature, TerraLogicI18n.format("%s%s",
        TerraLogicI18n.formatTemperature(s.surfaceTemperatureC), s.surfaceFrozen
            and " - " .. tr("terraLogic_fa_ui_frozen", "frozen") or ""))
    setText(self.weather_subsoilTemperature, TerraLogicI18n.format("%s%s",
        TerraLogicI18n.formatTemperature(s.subsoilTemperatureC), s.subsoilFrozen
            and " - " .. tr("terraLogic_fa_ui_frozen", "frozen") or ""))
    local initializationHints = {}
    if s.temperatureInitializing then
        initializationHints[#initializationHints + 1] = tr(
            "terraLogic_fa_ui_temperatureInitializing",
            "The soil-temperature model is still building its weather history. The two depths can initially show the same value; this notice disappears after the layers have separated.")
    end
    if s.moistureInitializing then
        initializationHints[#initializationHints + 1] = tr(
            "terraLogic_fa_ui_moistureInitializing",
            "The soil-moisture model is still building its weather history. The two layers can initially show the same value; this notice disappears after the profiles have separated.")
    end
    setText(self.weather_initializationHint, table.concat(initializationHints, "\n"))

    local plowMechanic = (s.mechanics or {}).plow or {}
    local cultivatorMechanic = (s.mechanics or {}).cultivator or {}
    local tillageDraft = math.max(plowMechanic.draft or 1,
        cultivatorMechanic.draft or 1)
    local tillageEffect = math.min(plowMechanic.effectiveness or 1,
        cultivatorMechanic.effectiveness or 1)
    local trafficMultiplier = s.trafficSurfaceMultiplier or 1
    setText(self.weather_trafficTop, TerraLogicI18n.format("x%.2f", trafficMultiplier))
    setText(self.weather_trafficDeep, TerraLogicI18n.format("x%.2f", s.trafficDeepMultiplier or 1))
    setText(self.weather_tillage, TerraLogicI18n.format("x%.2f", tillageDraft))
    setText(self.weather_seeding, formatPercent(tillageEffect))
    setText(self.weather_seedQuality, formatPercent(seedMechanic.quality or 1))
    setText(self.weather_seedGaps, TerraLogicI18n.format("%.1f%%", (seedMechanic.dropout or 0)*100))
    local currentEffects = {}
    local function addCurrentEffect(key, fallback, ...)
        if #currentEffects >= 3 then return end
        local template = tr(key, fallback)
        local ok, value = pcall(TerraLogicI18n.format, template, ...)
        currentEffects[#currentEffects + 1] = "- " .. (ok and value or template)
    end
    if s.surfaceFrozen or s.subsoilFrozen then
        addCurrentEffect("terraLogic_fa_condition_frost",
            "Frozen soil increases draft and reduces penetration.")
    end
    if trafficMultiplier >= 1.10 then
        addCurrentEffect("terraLogic_fa_condition_traffic",
            "Current moisture raises compaction risk to x%.2f.",
            trafficMultiplier)
    end
    if (seedMechanic.quality or 1) <= 0.97
        or (seedMechanic.dropout or 0) >= 0.005 then
        local uneven = clamp01((s.soil or {}).roughness) >= 0.25
        local tilth = soilQuality(s, "aggregateSize")
        local actionKey = (uneven or tilth < 0.75)
            and "terraLogic_fa_condition_seedingActionSeedbed"
            or "terraLogic_fa_condition_seedingActionSpeed"
        local actionFallback = (uneven or tilth < 0.75)
            and "Prepare a more even, suitably crumbled seedbed or slow down until the openers follow reliably."
            or "Reduce speed until the openers follow the surface reliably."
        local base = TerraLogicI18n.format(tr("terraLogic_fa_condition_seeding",
            "A seeder at reference speed would achieve %d%% placement quality with %.1f%% missed area."),
            math.floor((seedMechanic.quality or 1) * 100 + 0.5),
            (seedMechanic.dropout or 0) * 100)
        local rollerHint = tr("terraLogic_fa_condition_seedingRollerHint",
            "Rolling after sowing can recover part of soil-contact placement loss, but it cannot replace missed seed.")
        if #currentEffects < 3 then
            currentEffects[#currentEffects + 1] = "- " .. base .. " "
                .. tr(actionKey, actionFallback) .. " " .. rollerHint
        end
    end
    if tillageDraft >= 1.04 then
        addCurrentEffect("terraLogic_fa_condition_draft",
            "Current soil conditions raise tillage draft to x%.2f.",
            tillageDraft)
    end
    if tillageEffect <= 0.94 then
        addCurrentEffect("terraLogic_fa_condition_tillage",
            "Tillage currently reaches only %d%% of its normal effect.",
            math.floor(tillageEffect * 100 + 0.5))
    end
    if #currentEffects == 0 then
        addCurrentEffect("terraLogic_fa_condition_good",
            "No material weather-related restriction is active here.")
    end
    if #currentEffects == 1 then
        currentEffects[1] = currentEffects[1]:gsub("^%- ", "")
    end
    self.weatherEffectDetails=table.concat(currentEffects, "\n\n")
    local effectKey = (s.surfaceFrozen or s.subsoilFrozen) and "weatherFrost"
        or trafficMultiplier>=1.10 and "weatherWet"
        or ((seedMechanic.quality or 1)<0.97 or (seedMechanic.dropout or 0)>=0.005) and "weatherSeed"
        or "weatherGood"
    setNoteText(self.weather_effectSummary, tr("terraLogic_fa_table_"..effectKey, "Check conditions in the Planner."))

    setText(self.work_total,
        recordedWork and formatPercent(s.workQualityTotal) or "-",
        recordedWork and select(2, TerraLogicDisplay.rating("work",s.workQualityTotal)) or nil)
    setText(self.adviceListNow, joinBucket(recommendations, "now", 3))
    setText(self.adviceListNext, joinBucket(recommendations, "next", 4))
    setText(self.adviceListLong, joinBucket(recommendations, "long", 3))
    self:updatePlannerContent()
end

-- Compact request/response events keep all persistent map reads on the server.
TerraLogicFieldAnalysisRequestEvent = {}
local TerraLogicFieldAnalysisRequestEvent_mt = Class(TerraLogicFieldAnalysisRequestEvent, Event)
InitEventClass(TerraLogicFieldAnalysisRequestEvent, "TerraLogicFieldAnalysisRequestEvent")
function TerraLogicFieldAnalysisRequestEvent.emptyNew() return Event.new(TerraLogicFieldAnalysisRequestEvent_mt) end
function TerraLogicFieldAnalysisRequestEvent.new(x, z, serial, vehicle, selected)
    local self = TerraLogicFieldAnalysisRequestEvent.emptyNew()
    self.x, self.z, self.serial, self.vehicle = x, z, serial, vehicle
    self.selected = selected == true
    return self
end
function TerraLogicFieldAnalysisRequestEvent:readStream(streamId, connection)
    self.x, self.z = streamReadFloat32(streamId), streamReadFloat32(streamId)
    self.serial = streamReadInt32(streamId)
    self.vehicle = NetworkUtil.readNodeObject(streamId)
    self.selected = streamReadBool(streamId)
    self:run(connection)
end
function TerraLogicFieldAnalysisRequestEvent:writeStream(streamId, connection)
    streamWriteFloat32(streamId, self.x); streamWriteFloat32(streamId, self.z)
    streamWriteInt32(streamId, self.serial)
    NetworkUtil.writeNodeObject(streamId, self.vehicle)
    streamWriteBool(streamId, self.selected == true)
end
function TerraLogicFieldAnalysisRequestEvent:run(connection)
    if connection:getIsServer() then return end
    TerraLogicFieldCatalog:queueSnapshot(connection, self.x, self.z,
        self.serial, self.vehicle, self.selected)
end

TerraLogicFieldAnalysisSyncEvent = {}
local TerraLogicFieldAnalysisSyncEvent_mt = Class(TerraLogicFieldAnalysisSyncEvent, Event)
InitEventClass(TerraLogicFieldAnalysisSyncEvent, "TerraLogicFieldAnalysisSyncEvent")
local FIELD_SCOPE_TO_ID = {
    none=0, native=1, section=2, extended=3, created=4, connected=5
}
local FIELD_SCOPE_FROM_ID = {
    [0]="none", [1]="native", [2]="section", [3]="extended",
    [4]="created", [5]="connected"
}
function TerraLogicFieldAnalysisSyncEvent.emptyNew() return Event.new(TerraLogicFieldAnalysisSyncEvent_mt) end
function TerraLogicFieldAnalysisSyncEvent.new(snapshot)
    local self = TerraLogicFieldAnalysisSyncEvent.emptyNew(); self.snapshot = snapshot; return self
end
function TerraLogicFieldAnalysisSyncEvent:writeStream(streamId, connection)
    local s = self.snapshot
    streamWriteBool(streamId, s.valid); streamWriteInt32(streamId, s.serial)
    streamWriteFloat32(streamId, s.x); streamWriteFloat32(streamId, s.z)
    streamWriteBool(streamId, s.fieldScoped); streamWriteInt32(streamId, s.fieldId)
    streamWriteUInt8(streamId, FIELD_SCOPE_TO_ID[s.scopeKind] or 0)
    local fieldIdCount = math.min(#(s.fieldIds or {}), 8)
    streamWriteUInt8(streamId, fieldIdCount)
    for index=1,fieldIdCount do
        streamWriteInt32(streamId, tonumber(s.fieldIds[index]) or -1)
    end
    streamWriteFloat32(streamId, s.areaHa); streamWriteUInt8(streamId, math.min(s.sampleCount, 255))
    streamWriteFloat32(streamId, s.fieldEfficientWidthM or 0)
    streamWriteFloat32(streamId, s.fieldEfficientLengthM or 0)
    local vehicle = s.vehicleSetup
    streamWriteBool(streamId, vehicle ~= nil and vehicle.valid == true)
    if vehicle ~= nil and vehicle.valid == true then
        streamWriteFloat32(streamId, vehicle.vehicleMass or 0)
        streamWriteFloat32(streamId, vehicle.implementMass or 0)
        streamWriteFloat32(streamId, vehicle.combinationMass or 0)
        streamWriteFloat32(streamId, vehicle.maxAxleLoadT or 0)
        streamWriteFloat32(streamId, vehicle.maxPressureKPa or 0)
    end
    streamWriteInt32(streamId, s.fruitTypeIndex); streamWriteInt32(streamId, s.growthState)
    streamWriteUInt8(streamId, s.growthStage); streamWriteUInt8(streamId, s.profileIndex)
    streamWriteBool(streamId, s.profileMixed)
    streamWriteUInt8(streamId, math.min(tonumber(s.profileMask) or 0, 255))
    for _, key in ipairs(TerraLogicFieldAnalysis.SOIL_KEYS) do streamWriteFloat32(streamId, s.soil[key] or 0) end
    for _, key in ipairs(TerraLogicFieldAnalysis.SOIL_KEYS) do streamWriteFloat32(streamId, s.critical[key] or 0) end
    streamWriteFloat32(streamId, s.surfaceMoisture); streamWriteFloat32(streamId, s.subsoilMoisture)
    streamWriteFloat32(streamId, s.surfaceTemperatureC); streamWriteFloat32(streamId, s.subsoilTemperatureC)
    streamWriteBool(streamId, s.surfaceFrozen); streamWriteBool(streamId, s.subsoilFrozen)
    streamWriteBool(streamId, s.temperatureInitializing == true)
    streamWriteBool(streamId, s.moistureInitializing == true)
    streamWriteFloat32(streamId, s.soilQuality); streamWriteFloat32(streamId, s.tilthQuality)
    streamWriteFloat32(streamId, s.rootFactor)
    streamWriteFloat32(streamId, s.moistureFactor); streamWriteFloat32(streamId, s.ledgerFactor)
    streamWriteFloat32(streamId, s.workQualityTotal or 1)
    streamWriteFloat32(streamId, s.totalFactor); streamWriteUInt8(streamId, s.growthSteps)
    streamWriteFloat32(streamId, s.growthHistoryCoverage or 0)
    streamWriteBool(streamId, s.growthHistoryUpdating == true)
    streamWriteFloat32(streamId, s.biologicalContinuity or 0.25)
    streamWriteBool(streamId, s.moistureYieldActive)
    for _, key in ipairs(TerraLogicFieldAnalysis.CATEGORY_KEYS) do streamWriteFloat32(streamId, s.categories[key] or -1) end
    streamWriteFloat32(streamId, s.soilDeduction or 0)
    streamWriteFloat32(streamId, s.waterDeduction or 0)
    streamWriteFloat32(streamId, s.workDeduction or 0)
    streamWriteFloat32(streamId, s.surfaceRootLoss or 0)
    streamWriteFloat32(streamId, s.deepRootLoss or 0)
    streamWriteFloat32(streamId, s.trafficSurfaceMultiplier or 1)
    streamWriteFloat32(streamId, s.trafficDeepMultiplier or 1)
    streamWriteFloat32(streamId, s.rollerRescuePotential or 0)
    streamWriteFloat32(streamId, s.rotationKnownShare or 0)
    streamWriteFloat32(streamId, s.rotationRepeatedShare or 0)
    streamWriteFloat32(streamId, s.rotationDiverseShare or 0)
    streamWriteBool(streamId, s.coverCrop == true)
    for _, key in ipairs(TerraLogicFieldAnalysis.CATEGORY_KEYS) do
        streamWriteFloat32(streamId, (s.categoryLosses or {})[key] or 0)
    end
    streamWriteFloat32(streamId, s.cropShare or 0)
    streamWriteBool(streamId, s.harvestPending == true)
    streamWriteUInt8(streamId, math.min(s.cropCount or 0, 255))
    streamWriteBool(streamId, s.yieldRecordedWork == true)
    for _, key in ipairs(TerraLogicFieldAnalysis.CATEGORY_KEYS) do
        streamWriteFloat32(streamId, (s.categoryCoverage or {})[key] or 0)
    end
    for _, definition in ipairs(TerraLogicFieldAnalysis.MECHANIC_CLASSES) do
        local m = (s.mechanics or {})[definition.key] or {}
        for _, key in ipairs({"quality","dropout","safeSpeedRatio","effectiveness","draft",
                "wet","dry","frost","penetration"}) do
            streamWriteFloat32(streamId, m[key] or (key == "draft" and 1 or 0))
        end
        for _, key in ipairs(TerraLogicFieldAnalysis.SOIL_KEYS) do
            streamWriteFloat32(streamId, (m.projected or {})[key] or 0)
        end
    end
end
function TerraLogicFieldAnalysisSyncEvent:readStream(streamId, connection)
    local s = {soil={}, critical={}, categories={}, categoryLosses={}, mechanics={}}
    s.valid=streamReadBool(streamId); s.serial=streamReadInt32(streamId)
    s.x=streamReadFloat32(streamId); s.z=streamReadFloat32(streamId)
    s.fieldScoped=streamReadBool(streamId); s.fieldId=streamReadInt32(streamId)
    s.scopeKind=FIELD_SCOPE_FROM_ID[streamReadUInt8(streamId)] or "none"
    s.fieldIds={}
    local fieldIdCount=math.min(streamReadUInt8(streamId), 8)
    for index=1,fieldIdCount do
        s.fieldIds[index]=streamReadInt32(streamId)
    end
    s.areaHa=streamReadFloat32(streamId); s.sampleCount=streamReadUInt8(streamId)
    s.fieldEfficientWidthM=streamReadFloat32(streamId)
    s.fieldEfficientLengthM=streamReadFloat32(streamId)
    if streamReadBool(streamId) then
        s.vehicleSetup={valid=true,
            vehicleMass=streamReadFloat32(streamId),
            implementMass=streamReadFloat32(streamId),
            combinationMass=streamReadFloat32(streamId),
            maxAxleLoadT=streamReadFloat32(streamId),
            maxPressureKPa=streamReadFloat32(streamId)}
    end
    s.fruitTypeIndex=streamReadInt32(streamId); s.growthState=streamReadInt32(streamId)
    s.growthStage=streamReadUInt8(streamId); s.profileIndex=streamReadUInt8(streamId)
    s.profileMixed=streamReadBool(streamId)
    s.profileMask=streamReadUInt8(streamId)
    for _, key in ipairs(TerraLogicFieldAnalysis.SOIL_KEYS) do s.soil[key]=streamReadFloat32(streamId) end
    for _, key in ipairs(TerraLogicFieldAnalysis.SOIL_KEYS) do s.critical[key]=streamReadFloat32(streamId) end
    s.surfaceMoisture=streamReadFloat32(streamId); s.subsoilMoisture=streamReadFloat32(streamId)
    s.surfaceTemperatureC=streamReadFloat32(streamId); s.subsoilTemperatureC=streamReadFloat32(streamId)
    s.surfaceFrozen=streamReadBool(streamId); s.subsoilFrozen=streamReadBool(streamId)
    s.temperatureInitializing=streamReadBool(streamId)
    s.moistureInitializing=streamReadBool(streamId)
    s.soilQuality=streamReadFloat32(streamId); s.tilthQuality=streamReadFloat32(streamId)
    s.rootFactor=streamReadFloat32(streamId)
    s.moistureFactor=streamReadFloat32(streamId); s.ledgerFactor=streamReadFloat32(streamId)
    s.workQualityTotal=streamReadFloat32(streamId)
    s.totalFactor=streamReadFloat32(streamId); s.growthSteps=streamReadUInt8(streamId)
    s.growthHistoryCoverage=streamReadFloat32(streamId)
    s.growthHistoryUpdating=streamReadBool(streamId)
    s.biologicalContinuity=streamReadFloat32(streamId)
    s.moistureYieldActive=streamReadBool(streamId)
    for _, key in ipairs(TerraLogicFieldAnalysis.CATEGORY_KEYS) do s.categories[key]=streamReadFloat32(streamId) end
    s.soilDeduction=streamReadFloat32(streamId)
    s.waterDeduction=streamReadFloat32(streamId)
    s.workDeduction=streamReadFloat32(streamId)
    s.surfaceRootLoss=streamReadFloat32(streamId); s.deepRootLoss=streamReadFloat32(streamId)
    s.trafficSurfaceMultiplier=streamReadFloat32(streamId)
    s.trafficDeepMultiplier=streamReadFloat32(streamId)
    s.rollerRescuePotential=streamReadFloat32(streamId)
    s.rotationKnownShare=streamReadFloat32(streamId)
    s.rotationRepeatedShare=streamReadFloat32(streamId)
    s.rotationDiverseShare=streamReadFloat32(streamId)
    s.coverCrop=streamReadBool(streamId)
    for _, key in ipairs(TerraLogicFieldAnalysis.CATEGORY_KEYS) do
        s.categoryLosses[key]=streamReadFloat32(streamId)
    end
    s.cropShare=streamReadFloat32(streamId)
    s.harvestPending=streamReadBool(streamId)
    s.cropCount=streamReadUInt8(streamId)
    s.yieldRecordedWork=streamReadBool(streamId)
    s.categoryCoverage={}
    for _, key in ipairs(TerraLogicFieldAnalysis.CATEGORY_KEYS) do
        s.categoryCoverage[key]=streamReadFloat32(streamId)
    end
    for _, definition in ipairs(TerraLogicFieldAnalysis.MECHANIC_CLASSES) do
        local m = {}
        for _, key in ipairs({"quality","dropout","safeSpeedRatio","effectiveness","draft",
                "wet","dry","frost","penetration"}) do
            m[key]=streamReadFloat32(streamId)
        end
        m.projected = {}
        for _, key in ipairs(TerraLogicFieldAnalysis.SOIL_KEYS) do
            m.projected[key]=streamReadFloat32(streamId)
        end
        s.mechanics[definition.key]=m
    end
    self.snapshot=s; self:run(connection)
end
function TerraLogicFieldAnalysisSyncEvent:run(connection)
    if not connection:getIsServer() then return end
    TerraLogicFieldAnalysis:applySnapshot(self.snapshot)
end

addModEventListener(TerraLogicFieldAnalysis)
