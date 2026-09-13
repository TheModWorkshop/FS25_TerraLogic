-- TerraLogic Phase 1 persistent soil structure and minimap visualization.

TerraLogicSoilManager = {
    -- Kept for diagnostics and compatibility with the independent Work
    -- Quality ledger. Soil storage itself uses the per-layer sizes below.
    CELL_SIZE = 4,
    WHEEL_CELL_SIZE = 1,
    RESILIENCE_CELL_SIZE = 8,
    RECOVERY_CELL_SIZE = 8,
    RECOVERY_AGE_MAX = 15,
    RECOVERY_DELAY_MS = 3500,
    RECOVERY_CELLS_PER_FRAME = 128,
    RECOVERY_SNAPSHOT_VERSION = 1,
    NPC_PRESET_VERSION = 1,
    OWNED_PRESET_INITIALIZATION_VERSION = 1,
    NPC_PRESET_SCAN_DELAY_MS = 5000,
    NPC_PRESET_RETRY_DELAY_MS = 1000,
    NPC_PRESET_PATCH_SIZE_M = 24,
    NPC_PRESET_PATCHES_PER_FRAME = 6,
    LEGACY_CELL_SIZE = 4,
    NUM_CHANNELS = 6,
    MIN_SOIL_PASS_SPEED_KPH = 0.5,
    PASS_COOLDOWN_MS = 6500,
    OVERLAY_REFRESH_DELAY_MS = 2000,
    MINIMAP_ZOOM_TRANSITION_MS = 450,
    PF_MINIMAP_TRANSITION_MS = 550,
    MAX_OVERLAY_RESOLUTION = 2048,
    layers = {
        {id="surfaceCompaction", cellSize=1,
            file="terraLogicSoilSurface.grle",
            visualFile="terraLogicSoilSurfaceMask.grle"},
        {id="deepCompaction", cellSize=2,
            file="terraLogicSoilDeep.grle",
            visualFile="terraLogicSoilDeepMask.grle"},
        {id="aggregateSize", cellSize=2,
            file="terraLogicSoilAggregate.grle",
            visualFile="terraLogicSoilAggregateMask.grle"},
        {id="roughness", cellSize=2,
            file="terraLogicSoilRoughness.grle",
            visualFile="terraLogicSoilRoughnessMask.grle"},
        {id="resilience", cellSize=8, channels=8,
            -- v64 starts a clean 8-bit biology layer. The short-lived v63
            -- prototype used 6-bit quantization and contained no dependable
            -- sub-step history that could be migrated losslessly.
            file="terraLogicSoilResilience8.grle",
            visualFile="terraLogicSoilResilienceMask8.grle"}
    },
    maps = {},
    modifiers = {},
    layerCells = {},
    legacyCells = {},
    legacyCellLookup = {},
    mapSizes = {},
    visualizationMapSizes = {},
    mapSizeX = 0,
    mapSizeZ = 0,
    terrainSize = 2048,
    dirty = false,
    overlay = nil,
    overlayReady = false,
    overlayPending = false,
    visualizationDirty = false,
    overlayRefreshTime = 0,
    activeMapMode = 0,
    rasterReady = false,
    rasterInitRetryTime = 0,
    rasterDeferredLogged = false,
    deepMapMigration = nil,
    DEEP_MIGRATION_SCAN_PER_FRAME = 16384,
    DEEP_MIGRATION_WRITES_PER_FRAME = 1024,
    overlayLoggedMode = nil,
    pfMinimapHookInstalled = false,
    pfMinimapRequests = {},
    pfMinimapSuppressed = false,
    pfMinimapSuppressionRequested = false,
    -- Multiplayer soil-state transport is deliberately pull-based. A compact
    -- five-value sample keeps the local work HUD current, while the selected
    -- minimap layer is streamed in small world-space tiles. No full raster is
    -- ever placed in a join stream or broadcast after every soil write.
    NETWORK_SAMPLE_INTERVAL_MS = 500,
    NETWORK_SAMPLE_MAX_AGE_MS = 2500,
    NETWORK_SAMPLE_RADIUS_M = 40,
    NETWORK_TILE_WORLD_SIZE_M = 32,
    NETWORK_TILE_RADIUS = 3,
    -- The fixed radius remains the guaranteed near-player reserve. The actual
    -- request window expands to the visible minimap footprint without changing
    -- the native soil-map resolution.
    NETWORK_TILE_VIEWPORT_MAX_RADIUS = 16,
    NETWORK_TILE_REQUEST_INTERVAL_MS = 180,
    NETWORK_TILE_FAST_REQUEST_INTERVAL_MS = 90,
    NETWORK_TILE_FAST_MODE_MS = 5000,
    NETWORK_TILE_MOVE_FAST_MODE_MS = 1500,
    NETWORK_TILE_REQUEST_TIMEOUT_MS = 5000,
    NETWORK_TILE_CENTER_REFRESH_MS = 1000,
    -- Forty-eight surrounding tiles cannot all be refreshed inside eight
    -- seconds without either starving the outer rings or wasting bandwidth.
    -- Twelve seconds matches the bounded request budget while the fair cursor
    -- below guarantees that every nearby tile advances.
    NETWORK_TILE_REFRESH_MS = 12000,
    NETWORK_OVERLAY_REFRESH_DELAY_MS = 1000,
    NETWORK_TILE_APPLY_CELLS_PER_FRAME = 256,
    NETWORK_TILE_MAX_PENDING_JOBS = 4,
    NETWORK_TILE_MAX_INFLIGHT_REQUESTS = 4,
    NETWORK_SERVER_SAMPLE_COOLDOWN_MS = 350,
    NETWORK_SERVER_TILE_COOLDOWN_MS = 75,
    -- Each replicated cell reads one soil value plus one visibility bit. The
    -- fixed 256-cell budget caps this at 512 cheap point reads per server
    -- frame even when several clients request nearby tiles simultaneously.
    NETWORK_SERVER_TILE_CELLS_PER_FRAME = 256,
    NETWORK_SERVER_TILE_MAX_PENDING_JOBS = 64,
    -- Revisions are deliberately bounded to the unsigned 16-bit values used
    -- by the events. A tile overflow advances its layer generation and clears
    -- that layer's revision table. If the generation itself reaches the same
    -- boundary, clients receive an explicit cache-reset event before it wraps.
    NETWORK_TILE_REVISION_MAX = 65534,
    NETWORK_TILE_GENERATION_MAX = 65534,
    -- Landscaping can remove cultivatable terrain without changing the
    -- map-defined field polygon. Reconcile only small nearby/edited regions
    -- and spread the density queries across frames.
    COVERAGE_RECONCILE_TILE_SIZE_M = 32,
    COVERAGE_RECONCILE_CELLS_PER_FRAME = 128,
    COVERAGE_RECONCILE_REQUEST_INTERVAL_MS = 3000,
    COVERAGE_RECONCILE_STATIONARY_INTERVAL_MS = 15000,
    COVERAGE_RECONCILE_SERVER_COOLDOWN_MS = 500,
    COVERAGE_RECONCILE_MAX_JOBS = 96,
    COVERAGE_RECONCILE_MAX_REGION_M = 192,
    -- Visibility is decided from several live one-metre/sub-cell ground
    -- samples, never from a single permissive point. Requiring a clear
    -- majority removes the narrow mask hairs left when a wheel exits a field,
    -- while keeping genuine worked strips whose cell area is mostly arable.
    COVERAGE_VISIBLE_MIN_FRACTION = 0.55,
    COVERAGE_AUTHORITY_SAMPLE_M = 0.5,
    COVERAGE_FINE_SAMPLE_GRID = 2,
    COVERAGE_COARSE_SAMPLE_GRID_MAX = 4
}

-- The rotation map is not a player-facing soil layer. One byte stores the
-- previous completed crop group, the currently sown group and a tiny phase
-- marker. This makes sowing/harvest callbacks idempotent without retaining a
-- full per-cell crop history.
local ROTATION_FILE = "terraLogicCropRotation.grle"
local ROTATION_CHANNELS = 8
local ROTATION_PHASE_UNKNOWN = 0
local ROTATION_PHASE_PLANTED = 1
local ROTATION_PHASE_COMPLETED = 2

-- Recovery stores an equivalent age, not crop history. Current cover comes
-- from the game's density maps; crop diversity stays in the rotation byte.
-- Fixed-point months preserve small, area-weighted disturbances. Zero is an
-- unmigrated cell; stored ages use 1 + months * 256. Legacy data stays read-only.
local RECOVERY_AGE_FILE = "terraLogicRecoveryAgeFine.grle"
local RECOVERY_AGE_CHANNELS = 12
local RECOVERY_AGE_SCALE = 256
local RECOVERY_AGE_LEGACY_FILE = "terraLogicRecoveryAge.grle"

local CROP_GROUP = {
    NONE=0, CEREAL=1, LEGUME=2, OILSEED=3, ROOT=4,
    MAIZE=5, OTHER=6, PERENNIAL=7
}
local COVER_CROP_RESILIENCE_BONUS = 0.004

-- Fields use the live Vanilla FieldState as a cheap semantic initialization.
-- Values are stored in TerraLogic's native form: compaction/roughness rise as
-- conditions worsen, aggregateSize is optimum near 0.50 and resilience rises
-- as biological stability improves. Player-owned fields receive exactly one
-- preset on a new TerraLogic installation/save; NPC fields continue to follow
-- Vanilla's semantic state until ownership changes.
local NPC_FIELD_PRESETS = {
    bare={surfaceCompaction=0.42, deepCompaction=0.28,
        aggregateSize=0.48, roughness=0.35, resilience=0.45},
    harvested={surfaceCompaction=0.48, deepCompaction=0.33,
        aggregateSize=0.55, roughness=0.32, resilience=0.48},
    shallow={surfaceCompaction=0.38, deepCompaction=0.30,
        aggregateSize=0.58, roughness=0.14, resilience=0.48},
    cultivated={surfaceCompaction=0.31, deepCompaction=0.28,
        aggregateSize=0.58, roughness=0.20, resilience=0.47},
    subsoiled={surfaceCompaction=0.25, deepCompaction=0.14,
        aggregateSize=0.32, roughness=0.50, resilience=0.46},
    plowed={surfaceCompaction=0.16, deepCompaction=0.27,
        aggregateSize=0.20, roughness=0.75, resilience=0.44},
    seedbed={surfaceCompaction=0.34, deepCompaction=0.28,
        aggregateSize=0.54, roughness=0.08, resilience=0.48},
    sown={surfaceCompaction=0.40, deepCompaction=0.29,
        aggregateSize=0.52, roughness=0.12, resilience=0.49},
    directSown={surfaceCompaction=0.43, deepCompaction=0.30,
        aggregateSize=0.50, roughness=0.18, resilience=0.52},
    growing={surfaceCompaction=0.43, deepCompaction=0.30,
        aggregateSize=0.50, roughness=0.22, resilience=0.50},
    perennial={surfaceCompaction=0.37, deepCompaction=0.24,
        aggregateSize=0.50, roughness=0.14, resilience=0.64}
}

local NPC_CROP_MODIFIERS = {
    [CROP_GROUP.CEREAL]={resilience=0.01},
    [CROP_GROUP.LEGUME]={deepCompaction=-0.015, resilience=0.05},
    [CROP_GROUP.OILSEED]={deepCompaction=-0.02, resilience=0.035},
    [CROP_GROUP.ROOT]={surfaceCompaction=0.03,
        deepCompaction=0.015, roughness=0.03, resilience=-0.005},
    [CROP_GROUP.MAIZE]={surfaceCompaction=0.02,
        deepCompaction=0.01, roughness=0.02},
    [CROP_GROUP.OTHER]={},
    [CROP_GROUP.PERENNIAL]={surfaceCompaction=-0.02,
        deepCompaction=-0.02, roughness=-0.02, resilience=0.08}
}

local NPC_FIELD_VARIATION = {
    surfaceCompaction={field=0.012, localValue=0.026, salt=11},
    deepCompaction={field=0.008, localValue=0.016, salt=23},
    aggregateSize={field=0.018, localValue=0.035, salt=37},
    roughness={field=0.018, localValue=0.035, salt=53},
    resilience={field=0.018, localValue=0.026, salt=71}
}

local RESILIENCE_TILLAGE = {
    plow=-0.014, spader=-0.012, powerHarrow=-0.009,
    cultivator=-0.006, shallowCultivator=-0.003,
    discHarrow=-0.006, subsoiler=-0.004,
    slurryInjector=-0.001,
    -- Residues are a small positive contribution, not a repeatable direct
    -- yield bonus. Vanilla only reports changed mulch area once.
    mulcher=0.006
}

-- Mechanical disturbance changes biological continuity, not merely the
-- visible seedbed. Estimated targets are on the 25..100% continuity scale;
-- strengths describe a complete pass, with partial coverage applied once.
-- Rolling and ordinary above-ground mulching preserve continuity.
local RECOVERY_AGE_WORK = {
    plow={target=0.25, strength=0.95},
    spader={target=0.35, strength=0.85},
    cultivator={target=0.45, strength=0.85},
    powerHarrow={target=0.50, strength=0.85},
    discHarrow={target=0.60, strength=0.70},
    subsoiler={target=0.60, strength=0.70},
    shallowCultivator={target=0.72, strength=0.70},
    sowingMachine={target=0.90, strength=0.50},
    precisionPlanter={target=0.90, strength=0.50},
    directDrill={target=0.97, strength=0.50},
    precisionDirectDrill={target=0.97, strength=0.50},
    stonePicker={target=0.90, strength=0.50},
    hoe={target=0.94, strength=0.50},
    weeder={target=0.97, strength=0.50},
    slurryInjector={target=0.97, strength=0.50}
}
for key, rule in pairs(TerraLogicSpecialImplements.BIOLOGY) do
    RESILIENCE_TILLAGE[key] = rule.resilience
    RECOVERY_AGE_WORK[key] = {target=rule.target, strength=rule.strength}
end

-- Monthly background recovery. Living-root effects remain in
-- ROOT_GROWTH_RESPONSE; these values represent slower pore ageing, fauna,
-- wet/dry and frost/thaw action. Natural processes deliberately stop above
-- mechanical tool targets. Tilth targets are covered-soil equilibria, not a
-- free seedbed pass; bare soil only fragments very coarse clods and can slake.
local RECOVERY_COVER = {
    bare={surfaceTarget=0.32, deepTarget=0.30, resilienceCeiling=0.42,
        activity=0.18, resilienceRate=0.0000, resilienceDecay=0.0030,
        tilthActivity=0.10, settlingTarget=0.32, settlingActivity=0.55,
        settlementCompactionFloor=0.30, protection=0.00},
    sown={surfaceTarget=0.30, deepTarget=0.27, resilienceCeiling=0.48,
        activity=0.30, resilienceRate=0.0008,
        tilthTarget=0.50, tilthActivity=0.24,
        settlingTarget=0.30, settlingActivity=0.38,
        settlementCompactionFloor=0.27, protection=0.30},
    residue={surfaceTarget=0.28, deepTarget=0.24, resilienceCeiling=0.60,
        activity=0.50, resilienceRate=0.0024,
        tilthTarget=0.49, tilthActivity=0.38,
        settlingTarget=0.30, settlingActivity=0.28,
        settlementCompactionFloor=0.25, protection=0.55},
    annual={surfaceTarget=0.25, deepTarget=0.25, resilienceCeiling=0.64,
        activity=0.65, resilienceRate=0.0030,
        tilthTarget=0.50, tilthActivity=0.52,
        settlingTarget=0.28, settlingActivity=0.24,
        settlementCompactionFloor=0.23, protection=0.72},
    rootCrop={surfaceTarget=0.24, deepTarget=0.23,
        resilienceCeiling=0.68, activity=0.68, resilienceRate=0.0031,
        tilthTarget=0.50, tilthActivity=0.56,
        settlingTarget=0.28, settlingActivity=0.23,
        settlementCompactionFloor=0.22, protection=0.74},
    deepRoot={surfaceTarget=0.22, deepTarget=0.17, resilienceCeiling=0.74,
        activity=0.82, resilienceRate=0.0036,
        tilthTarget=0.50, tilthActivity=0.68,
        settlingTarget=0.27, settlingActivity=0.20,
        settlementCompactionFloor=0.21, protection=0.80},
    perennial={surfaceTarget=0.20, deepTarget=0.21, resilienceCeiling=0.84,
        activity=1.00, resilienceRate=0.0044,
        tilthTarget=0.50, tilthActivity=0.78,
        settlingTarget=0.24, settlingActivity=0.15,
        settlementCompactionFloor=0.19, protection=0.90},
    deepPerennial={surfaceTarget=0.19, deepTarget=0.15,
        resilienceCeiling=0.88, activity=1.00, resilienceRate=0.0048,
        tilthTarget=0.50, tilthActivity=0.82,
        settlingTarget=0.24, settlingActivity=0.14,
        settlementCompactionFloor=0.18, protection=0.92}
}

local RECOVERY_TEXTURE = {
    [1]={surface=0.75, deep=0.65, resilience=0.85,
        tilth=0.78, settling=1.12}, -- Loamy Sand
    [2]={surface=1.00, deep=1.00, resilience=1.00,
        tilth=1.00, settling=1.00}, -- Sandy Loam
    [3]={surface=1.05, deep=1.00, resilience=1.05,
        tilth=1.08, settling=0.92}, -- Loam
    [4]={surface=1.15, deep=0.75, resilience=0.90,
        tilth=1.18, settling=0.82}  -- Silty Clay
}

local DEEP_ROOT_GROUP = {
    [CROP_GROUP.LEGUME]=true,
    [CROP_GROUP.OILSEED]=true
}

-- ValueMap requests use the requesting vehicle/tool as their identity. Keep a
-- stable key for the defensive nil-requester case as Lua tables cannot index
-- entries by nil.
local PF_NIL_REQUESTER = {}

local function getPrecisionFarmingValueMapClass()
    -- Cross-mod classes normally live in PF's custom Lua environment. The
    -- direct global remains as a compatibility fallback for alternate builds.
    local environment = FS25_precisionFarming
    if environment ~= nil and environment.ValueMap ~= nil then
        return environment.ValueMap
    end
    return ValueMap
end

local function clamp01(value)
    return math.max(0, math.min(tonumber(value) or 0, 1))
end

local function getSavegameDirectory()
    local info = g_currentMission ~= nil and g_currentMission.missionInfo or nil
    return info ~= nil and info.savegameDirectory or nil
end

local function getCellKey(ix, iz)
    return tostring(ix) .. ":" .. tostring(iz)
end

local function getLayerDefinition(layerId)
    for _, layer in ipairs(TerraLogicSoilManager.layers) do
        if layer.id == layerId then return layer end
    end
    return nil
end

local function getLayerCellSize(layerId)
    local layer = getLayerDefinition(layerId)
    return layer ~= nil and layer.cellSize
        or TerraLogicSoilManager.LEGACY_CELL_SIZE
end

local function getLayerChannels(layerId)
    local layer = getLayerDefinition(layerId)
    return layer ~= nil and tonumber(layer.channels)
        or TerraLogicSoilManager.NUM_CHANNELS
end

local function smoothStep01(value)
    local t = clamp01(value)
    return t * t * (3 - 2 * t)
end

local function getSoilDevelopmentSpeed()
    if TerraLogicSettings ~= nil
        and TerraLogicSettings.getSoilDevelopmentSpeed ~= nil then
        return math.clamp(tonumber(
            TerraLogicSettings:getSoilDevelopmentSpeed()) or 4, 1, 8)
    end
    return 4
end

local PHYSICAL_DEVELOPMENT_SPEED = 4
local ROOT_LOOSENING_SPEED = 4
TerraLogicSoilManager.DEEP_TRAFFIC_RATE = 0.85
-- This is the ramp to the soil's full biological recovery activity, not the
-- time required to restore resilience itself. Intensive inversion therefore
-- remains visible for roughly one crop year instead of disappearing after
-- three months; actual resilience still develops over several years.
local REST_DEVELOPMENT_SPEED = 1

local function getBiologicalContinuityFromAge(age)
    local restProgress = smoothStep01(
        math.min((tonumber(age) or 0) * REST_DEVELOPMENT_SPEED, 15) / 12)
    return 0.25 + 0.75 * restProgress
end

local function getAgeFromBiologicalContinuity(continuity)
    local progress = math.clamp((continuity - 0.25) / 0.75, 0, 1)
    -- Inverse of 3*t*t - 2*t*t*t; retains the existing monthly recovery curve.
    return 12 * (0.5 - math.sin(math.asin(1 - 2 * progress) / 3))
        / REST_DEVELOPMENT_SPEED
end

function TerraLogicSoilManager:applyContinuityRule(continuity, classKey, coverage)
    local rule = RECOVERY_AGE_WORK[classKey]
    if rule == nil then return continuity end
    return continuity - rule.strength * clamp01(coverage or 1)
        * math.max(0, continuity - rule.target)
end

function TerraLogicSoilManager:getImplementBiologicalImpact(classKey)
    local loss = math.max(0, -(RESILIENCE_TILLAGE[classKey] or 0))
    local resilience = loss >= 0.009 and "strong"
        or (loss >= 0.004 and "medium" or (loss > 0 and "low" or "none"))
    local lossContinuity = 1 - self:applyContinuityRule(1, classKey, 1)
    local continuity = lossContinuity >= 0.40 and "strong"
        or (lossContinuity >= 0.20 and "medium"
            or (lossContinuity > 0 and "low" or "none"))
    return resilience, continuity
end

local function getResilienceDevelopmentSpeed(displayedSpeed)
    if TerraLogicSettings ~= nil
        and TerraLogicSettings.getResilienceDevelopmentSpeed ~= nil then
        return math.clamp(tonumber(
            TerraLogicSettings:getResilienceDevelopmentSpeed(displayedSpeed))
            or 4, 1, 8)
    end
    local speed = tonumber(displayedSpeed) or getSoilDevelopmentSpeed()
    return speed <= 1 and 1 or (speed <= 4 and 4 or 8)
end

local function getResilienceTillageLossScale()
    if TerraLogicSettings ~= nil
        and TerraLogicSettings.getResilienceTillageLossScale ~= nil then
        return math.clamp(tonumber(
            TerraLogicSettings:getResilienceTillageLossScale()) or 4, 1, 8)
    end
    local speed = getSoilDevelopmentSpeed()
    return speed <= 1 and 1 or (speed <= 4 and 4 or 8)
end

-- Repeating a bounded process N times is not the same as multiplying its
-- percentage by N. This composition preserves every target and asymptote:
-- 1 - (1 - strength)^N. At 1x it is bit-for-bit the original strength.
local function scaleSlowStrength(strength, speed)
    local normalized = clamp01(strength)
    return 1 - (1 - normalized) ^ math.clamp(
        tonumber(speed) or getSoilDevelopmentSpeed(), 1, 16)
end

-- Applies an explicitly supplied process tier after environmental factors.
-- Callers choose the fixed physical/root rate or the selected resilience rate;
-- keeping that choice at each process prevents accidental recoupling.
local function scaleEnvironmentalStrength(strength, environment, speed)
    return scaleSlowStrength(clamp01(strength)
        * math.clamp(tonumber(environment) or 1, 0, 2), speed)
end

local function newRecoveryAccumulator()
    return {
        hours=0, surfaceTemperatureSum=0, subsoilTemperatureSum=0,
        airTemperatureSum=0, profiles={}
    }
end

local function getRecoveryProfileOrder()
    return TerraLogicSoilMoistureManager ~= nil
        and TerraLogicSoilMoistureManager.PROFILE_ORDER
        or {0, 1, 2, 3, 4}
end

local function getSuitabilityFactorScore(value, factor)
    value = clamp01(value)
    if factor.shape == "band" then
        local distance = math.abs(value - clamp01(factor.target or 0.5))
        local good = math.max(tonumber(factor.goodRadius) or 0, 0)
        local bad = math.max(tonumber(factor.badRadius) or 0.5, good + 0.0001)
        return 1 - smoothStep01((distance - good) / (bad - good))
    end
    local good = clamp01(factor.good or 0)
    local bad = math.max(clamp01(factor.bad or 1), good + 0.0001)
    return 1 - smoothStep01((value - good) / (bad - good))
end

-- Pure single-cell version of the work-area suitability calculation.  The
-- Field Analysis page uses this to preview real implement behaviour without
-- creating a WorkArea, mutating the implement, or writing a density map.
function TerraLogicSoilManager:getSuitabilityAtState(state, soilTypeIndex,
        classKey, workDepthCm, rawGround)
    local profile = TerraLogicSoilProfiles ~= nil
        and TerraLogicSoilProfiles:getSuitabilityProfile(classKey) or nil
    if state == nil or profile == nil then
        return {qualityFactor=1, structuralQualityFactor=1,
            moistureQualityFactor=1, dropoutFraction=0,
            structuralDropoutFraction=0, moistureDropoutFraction=0,
            dropoutRisk=0, safeSpeedRatio=1,
            soilEffectiveness=1, draftMultiplier=1, frostSeverity=0,
            penetrationFactor=1, wetSeverity=0, drySeverity=0}
    end
    local qualitySum, qualityWeight, dropoutSum, dropoutWeight = 0, 0, 0, 0
    for layerId, factor in pairs(profile.factors or {}) do
        factor = TerraLogicSpecialImplements.getSuitabilityFactor(classKey, layerId, factor, rawGround)
        local score = getSuitabilityFactorScore(state[layerId], factor)
        local qWeight = math.max(tonumber(factor.qualityWeight) or 0, 0)
        local dWeight = math.max(tonumber(factor.dropoutWeight) or 0, 0)
        qualitySum, qualityWeight = qualitySum + score * qWeight,
            qualityWeight + qWeight
        dropoutSum, dropoutWeight = dropoutSum + score * dWeight,
            dropoutWeight + dWeight
    end
    local qualityScore = qualityWeight > 0 and qualitySum / qualityWeight or 1
    local rawQuality = clamp01((profile.qualityFloor or 1)
        + (1 - (profile.qualityFloor or 1)) * qualityScore)
    local residual = clamp01(profile.residualQualityShare == nil
        and 1 or profile.residualQualityShare)
    local structuralQuality = 1 - (1 - rawQuality) * residual
    local dropoutScore = dropoutWeight > 0 and dropoutSum / dropoutWeight or 1
    local dropoutRisk = clamp01(((1 - clamp01(dropoutScore))
        - clamp01(profile.dropoutOnset or 0))
        / math.max(1 - clamp01(profile.dropoutOnset or 0), 0.0001))
    local safeMinimumRatio = clamp01(profile.safeSpeedMinimumRatio or 1)
    local safeSpeedRatio = 1 - dropoutRisk * (1 - safeMinimumRatio)
    -- Planner previews use the class reference/shop speed. The same smooth
    -- activation used at runtime therefore predicts zero misses on a healthy
    -- seedbed and an increasing risk when that speed exceeds soil-safe speed.
    local speedWindowRatio = math.max(
        tonumber(profile.dropoutSpeedWindowRatio) or 0.30, 0.05)
    local speedT = clamp01((1 - safeSpeedRatio) / speedWindowRatio)
    local speedActivation = speedT * speedT * (3 - 2 * speedT)
    local structuralDropout = clamp01(
        (profile.dropoutMax or 0) * dropoutRisk * speedActivation)
    local moisture = TerraLogicSoilMoistureManager ~= nil
        and TerraLogicSoilMoistureManager:getMechanicalResponse(
            soilTypeIndex, classKey, workDepthCm or 0) or {}
    local rawMoistureQuality = clamp01(moisture.qualityFactor or 1)
    local moistureQuality = 1 - (1 - rawMoistureQuality) * residual
    local moistureDropout = math.max(
        clamp01(moisture.dropoutFraction or 0) * speedActivation,
        clamp01(moisture.frostDropoutFraction or 0)
            * clamp01((clamp01(moisture.frostSeverity or 0)-0.55)/0.35))
    return {
        qualityFactor=math.min(structuralQuality, moistureQuality),
        structuralQualityFactor=structuralQuality,
        moistureQualityFactor=moistureQuality,
        dropoutFraction=math.max(structuralDropout, moistureDropout),
        structuralDropoutFraction=structuralDropout,
        moistureDropoutFraction=moistureDropout,
        dropoutRisk=dropoutRisk,
        safeSpeedRatio=safeSpeedRatio,
        suitabilitySpeedActivation=speedActivation,
        soilEffectiveness=clamp01(moisture.soilEffectiveness or 1),
        draftMultiplier=tonumber(moisture.draftMultiplier) or 1,
        frostDraftMultiplier=tonumber(moisture.frostDraftMultiplier) or 1,
        frostSeverity=clamp01(moisture.frostSeverity or 0),
        penetrationFactor=clamp01(moisture.penetrationFactor or 1),
        wetSeverity=moisture.implementMoistureActive == true
            and clamp01(moisture.wetSeverity or 0) or 0,
        drySeverity=moisture.implementMoistureActive == true
            and clamp01(moisture.drySeverity or 0) or 0
    }
end

-- Poor workability first weakens the intended mechanical pass. A separate,
-- tightly bounded reaction then records what the disturbed soil itself does:
-- cohesive soil can form dry/wet clods, while high-shear tools can pulverize
-- dry light soil or smear wet plastic soil. This second stage is deliberately
-- bidirectional. An individual aggregate-size value may move nearer optimum
-- by chance, while compaction, roughness and Work Quality still preserve the
-- overall cost of working in unsuitable conditions.
local MOISTURE_TEXTURE_COHESION = {
    [0]=0.55, [1]=0.10, [2]=0.35, [3]=0.70, [4]=1.00
}

local MOISTURE_HIGH_SHEAR = {
    ridgeFormer=true,
    powerHarrow=true, spader=true, roller=true
}

local MOISTURE_NARROW_SLOT = {
    vegetablePlanter=true, sugarcanePlanter=true,
    sowingMachine=true, precisionPlanter=true,
    directDrill=true, precisionDirectDrill=true,
    slurryInjector=true
}

local function getMoistureAdverseRule(classKey, layerId, response)
    if response == nil then return nil, 0, 0 end
    local dry = clamp01(response.drySeverity)
    local wet = clamp01(response.wetSeverity)
    if layerId == "surfaceCompaction" and wet > 0 then
        local targets = {
            roller=0.82, precisionPlanter=0.58,
            precisionDirectDrill=0.56, sowingMachine=0.56,
            directDrill=0.54, plow=0.48, subsoiler=0.46
        }
        local strengths = {
            roller=0.34, precisionPlanter=0.09,
            precisionDirectDrill=0.07, sowingMachine=0.07,
            directDrill=0.05, plow=0.10, subsoiler=0.07
        }
        local maximumDelta = classKey == "roller" and 0.10
            or (MOISTURE_NARROW_SLOT[classKey] and 0.035 or 0.060)
        return {target=targets[classKey] or 0.58,
            strength=strengths[classKey] or 0.14,
            mode="increaseOnly"}, wet, maximumDelta
    end
    if layerId == "aggregateSize" then
        local texture = tonumber(response.profileIndex) or 0
        local cohesion = MOISTURE_TEXTURE_COHESION[texture]
            or MOISTURE_TEXTURE_COHESION[0]
        local lightness = 1 - cohesion
        if wet > 0 then
            if MOISTURE_HIGH_SHEAR[classKey] then
                return {target=0.90,
                    strength=0.06 + 0.08 * cohesion}, wet,
                    0.025 + 0.045 * cohesion
            end
            if MOISTURE_NARROW_SLOT[classKey] then
                return {target=0.90,
                    strength=0.015 + 0.025 * cohesion}, wet,
                    0.010 + 0.020 * cohesion
            end
            return {target=0.10,
                strength=0.035 + 0.065 * cohesion}, wet,
                0.020 + 0.040 * cohesion
        elseif dry > 0 then
            if MOISTURE_HIGH_SHEAR[classKey]
                or (classKey == "discHarrow" and lightness >= 0.50) then
                return {target=0.90,
                    strength=0.035 + 0.045 * lightness}, dry,
                    0.020 + 0.035 * lightness
            end
            -- Dry cohesive horizons fracture into hard clods. On light soil
            -- this reaction is weak and the normal implement target remains
            -- dominant.
            return {target=0.08,
                strength=0.030 + 0.060 * cohesion}, dry,
                0.015 + 0.040 * cohesion
        end
    end
    return nil, 0, 0
end

-- Snapshot the soil before an operation.  WorkArea callbacks are small and
-- frequent, so their average remains local while avoiding a second density
-- map.  The same snapshot feeds physical misses, live HUD quality and the
-- persistent Work Quality ledger.
function TerraLogicSoilManager:prepareWorkAreaSuitability(
        implement, workArea, classKey)
    local spec = implement ~= nil and implement.spec_terraLogic or nil
    local profile = TerraLogicSoilProfiles ~= nil
        and TerraLogicSoilProfiles:getSuitabilityProfile(classKey) or nil
    if spec == nil or profile == nil or TerraLogicQualityManager == nil then
        if spec ~= nil then spec.soilSuitabilityContext = nil end
        return nil
    end
    local touchedCells = TerraLogicQualityManager:getTouchedCells(workArea, false)
    local qualitySum, qualityWeight = 0, 0
    local dropoutSum, dropoutWeight = 0, 0
    local moistureQualitySum, moistureDropoutSum = 0, 0
    local drySeveritySum, wetSeveritySum = 0, 0
    local dryQualityLossSum, wetQualityLossSum = 0, 0
    local frostSeveritySum, frostQualitySum = 0, 0
    local frostPenetrationSum, frostDropoutSum = 0, 0
    local layerSums, eligible = {}, 0
    local qualityDeficits, dropoutDeficits = {}, {}
    local eligibleCellKeys = {}
    local mechanicalResponses = {}
    for _, cell in ipairs(touchedCells) do
        local x = (cell.ix + 0.5) * self.CELL_SIZE
        local z = (cell.iz + 0.5) * self.CELL_SIZE
        -- Soil tools only need to know whether this is live cultivatable
        -- ground. Query the authoritative ground-type channel directly;
        -- checking fruit, grass and meadow density maps again for every bare
        -- seedbed cell was both redundant and substantially more expensive.
        local cultivatable, rawGround = self:isCultivatableTerrainAtWorldPosition(x, z)
        if cultivatable == nil then
            local surface = TerraLogicQualityManager:
                getSurfaceTypeAtWorldPosition(x, z)
            cultivatable = surface == "field" or surface == "grassField"
        end
        if cultivatable == true then
            eligible = eligible + 1
            eligibleCellKeys[tostring(cell.ix) .. ":"
                .. tostring(cell.iz)] = true
            local state = self:getStateAtWorldPosition(x, z)
            local soilTypeIndex = self:getPFSoilTypeAtWorldPosition(x, z)
            local responseKey = tostring(soilTypeIndex or "default")
            local moisture = mechanicalResponses[responseKey]
            if moisture == nil and TerraLogicSoilMoistureManager ~= nil then
                moisture = TerraLogicSoilMoistureManager:
                    getMechanicalResponse(soilTypeIndex, classKey,
                        spec.workDepthCm or 0)
                mechanicalResponses[responseKey] = moisture
            end
            moistureQualitySum = moistureQualitySum
                + (moisture ~= nil and moisture.qualityFactor or 1)
            moistureDropoutSum = moistureDropoutSum
                + (moisture ~= nil and moisture.dropoutFraction or 0)
            drySeveritySum = drySeveritySum
                + (moisture ~= nil and moisture.drySeverity or 0)
            wetSeveritySum = wetSeveritySum
                + (moisture ~= nil and moisture.wetSeverity or 0)
            dryQualityLossSum = dryQualityLossSum
                + (moisture ~= nil and moisture.dryQualityLoss or 0)
            wetQualityLossSum = wetQualityLossSum
                + (moisture ~= nil and moisture.wetQualityLoss or 0)
            frostSeveritySum = frostSeveritySum
                + (moisture ~= nil and moisture.frostSeverity or 0)
            frostQualitySum = frostQualitySum
                + (moisture ~= nil and moisture.frostQualityFactor or 1)
            frostPenetrationSum = frostPenetrationSum
                + (moisture ~= nil and moisture.penetrationFactor or 1)
            frostDropoutSum = frostDropoutSum
                + (moisture ~= nil and moisture.frostDropoutFraction or 0)
            for layerId, factor in pairs(profile.factors or {}) do
                factor = TerraLogicSpecialImplements.getSuitabilityFactor(classKey, layerId, factor, rawGround)
                local score = getSuitabilityFactorScore(state[layerId], factor)
                local qWeight = math.max(tonumber(factor.qualityWeight) or 0, 0)
                local dWeight = math.max(tonumber(factor.dropoutWeight) or 0, 0)
                qualitySum = qualitySum + score * qWeight
                qualityWeight = qualityWeight + qWeight
                dropoutSum = dropoutSum + score * dWeight
                dropoutWeight = dropoutWeight + dWeight
                -- Attribute warnings from the same samples and weights as
                -- suitability, not from a second scan or an arbitrary value.
                qualityDeficits[layerId] = (qualityDeficits[layerId] or 0)
                    + (1-score)*qWeight
                dropoutDeficits[layerId] = (dropoutDeficits[layerId] or 0)
                    + (1-score)*dWeight
                layerSums[layerId] = (layerSums[layerId] or 0)
                    + clamp01(state[layerId])
            end
        end
    end
    if eligible <= 0 then
        spec.soilSuitabilityContext = nil
        return nil
    end
    local qualityScore = qualityWeight > 0 and qualitySum / qualityWeight or 1
    local rawQualityFactor = clamp01((profile.qualityFloor or 1)
        + (1 - (profile.qualityFloor or 1)) * qualityScore)
    local residualShare = clamp01(profile.residualQualityShare == nil
        and 1 or profile.residualQualityShare)
    local structuralQualityFactor = 1
        - (1 - rawQualityFactor) * residualShare
    local rawMoistureQualityFactor = moistureQualitySum / eligible
    -- The profile already reserves the complementary share for physical
    -- dropout. Apply that same split to moisture so seed-placement misses and
    -- invisible Work Quality do not charge the full moisture loss twice.
    local moistureQualityFactor = 1
        - (1 - rawMoistureQualityFactor) * residualShare
    local dropoutScore = dropoutWeight > 0 and dropoutSum / dropoutWeight or 1
    local dropoutRisk = 1 - clamp01(dropoutScore)
    local dropoutOnset = clamp01(profile.dropoutOnset or 0)
    dropoutRisk = clamp01((dropoutRisk - dropoutOnset)
        / math.max(1 - dropoutOnset, 0.0001))
    local implementSpeed = implement ~= nil and implement.getLastSpeed ~= nil
        and math.abs(tonumber(implement:getLastSpeed(true)) or 0) or 0
    local ratedSpeed = math.max(tonumber(spec.ratedSpeed)
        or tonumber(spec.optimalSpeed) or 0, 0)
    local safeMinimumRatio = clamp01(profile.safeSpeedMinimumRatio or 1)
    local safeSpeedRatio = 1 - dropoutRisk * (1 - safeMinimumRatio)
    local safeSpeedKph = ratedSpeed > 0 and ratedSpeed * safeSpeedRatio or 0
    local speedWindow = math.max(ratedSpeed
        * (tonumber(profile.dropoutSpeedWindowRatio) or 0.30), 1)
    local speedActivation = 0
    if safeSpeedKph > 0 and implementSpeed > safeSpeedKph then
        local speedT = clamp01((implementSpeed - safeSpeedKph) / speedWindow)
        speedActivation = speedT * speedT * (3 - 2 * speedT)
    end
    -- Slowing below the soil-dependent safe speed can eliminate bouncing and
    -- opener misses.  It recovers most, but not all, placement-quality loss;
    -- the remaining loose/coarse contact deficit is what rolling can repair.
    local slowRecovery = clamp01(profile.slowQualityRecovery or 0)
    local recoveryProgress = safeSpeedKph > 0 and clamp01(
        (ratedSpeed - implementSpeed)
            / math.max(ratedSpeed - safeSpeedKph, 0.01)) or 0
    structuralQualityFactor = structuralQualityFactor
        + (1 - structuralQualityFactor) * slowRecovery * recoveryProgress
    local structuralDropoutFraction = clamp01(
        (profile.dropoutMax or 0) * dropoutRisk * speedActivation)
    local rawMoistureDropout = clamp01(moistureDropoutSum / eligible)
    local frostDropout = clamp01(frostDropoutSum / eligible)
    -- Unsuitable moisture normally lowers placement/emergence quality rather
    -- than deleting seed.  True missing rows appear only when speed also
    -- prevents surface following; severe frost is the physical exception.
    local moistureDropoutFraction = math.max(
        rawMoistureDropout * speedActivation,
        frostDropout * clamp01((frostSeveritySum / eligible - 0.55) / 0.35))
    local dropoutFraction = math.max(
        structuralDropoutFraction, moistureDropoutFraction)
    -- A ceiling avoids charging structurally bad and wet/dry soil as two
    -- multiplied versions of the same failed penetration/placement outcome.
    local qualityFactor = math.min(
        structuralQualityFactor, moistureQualityFactor)
    local averages = {}
    for layerId, sum in pairs(layerSums) do averages[layerId] = sum / eligible end
    local function dominantFactor(deficits)
        local key, maximum = nil, 0
        for layerId, deficit in pairs(deficits) do
            if deficit > maximum or (deficit == maximum and deficit > 0
                and (key == nil or layerId < key)) then
                key, maximum = layerId, deficit
            end
        end
        return key
    end
    local context = {
        dominantQualityFactor = dominantFactor(qualityDeficits),
        dominantDropoutFactor = dominantFactor(dropoutDeficits),
        classKey = classKey,
        qualityFactor = qualityFactor,
        structuralQualityFactor = structuralQualityFactor,
        moistureQualityFactor = moistureQualityFactor,
        rawMoistureQualityFactor = rawMoistureQualityFactor,
        drySeverity = drySeveritySum / eligible,
        wetSeverity = wetSeveritySum / eligible,
        dryQualityLoss = dryQualityLossSum / eligible,
        wetQualityLoss = wetQualityLossSum / eligible,
        rawQualityFactor = rawQualityFactor,
        qualityScore = qualityScore,
        dropoutFraction = dropoutFraction,
        structuralDropoutFraction = structuralDropoutFraction,
        moistureDropoutFraction = moistureDropoutFraction,
        frostSeverity = frostSeveritySum / eligible,
        frostQualityFactor = frostQualitySum / eligible,
        frostPenetrationFactor = frostPenetrationSum / eligible,
        frostDropoutFraction = frostDropoutSum / eligible,
        dropoutScore = dropoutScore,
        dropoutRisk = dropoutRisk,
        safeSpeedRatio = safeSpeedRatio,
        safeSpeedKph = safeSpeedKph,
        suitabilitySpeedActivation = speedActivation,
        suitabilitySlowRecovery = recoveryProgress,
        eligibleCells = eligible,
        touchedCells = #touchedCells,
        eligibleCellKeys = eligibleCellKeys,
        averages = averages,
        time = g_currentMission ~= nil and g_currentMission.time or 0
    }
    spec.soilSuitabilityContext = context
    spec.soilSuitabilityQuality = qualityFactor
    spec.soilSuitabilityDropout = dropoutFraction
    spec.soilSuitabilityClass = classKey
    spec.soilSuitabilitySafeSpeedKph = safeSpeedKph
    spec.soilSuitabilitySafeSpeedRatio = safeSpeedRatio
    spec.soilSuitabilityDropoutRisk = dropoutRisk
    return context
end

function TerraLogicSoilManager:getActiveSuitability(implement, classKey)
    local spec = implement ~= nil and implement.spec_terraLogic or nil
    local context = spec ~= nil and spec.soilSuitabilityContext or nil
    if context == nil or (classKey ~= nil and context.classKey ~= classKey) then
        return 1, 0, nil
    end
    local now = g_currentMission ~= nil and g_currentMission.time or 0
    if now - (context.time or now) > 2500 then return 1, 0, nil end
    return clamp01(context.qualityFactor or 1),
        clamp01(context.dropoutFraction or 0), context
end

-- Returns PF's physical texture even on an unpurchased/unsampled field. The
-- public PF query is coverage-masked, while TerraLogic's existing raw resolver
-- reads the underlying four-type map used by PF itself.
function TerraLogicSoilManager:getPFSoilTypeAtWorldPosition(x, z)
    if self.auditSoilTypeOverride ~= nil then
        return tonumber(self.auditSoilTypeOverride)
    end
    if TerraLogicMain == nil
        or TerraLogicMain.isPrecisionFarmingActive == nil
        or not TerraLogicMain:isPrecisionFarmingActive()
        or TerraLogic == nil
        or TerraLogic.getRawPrecisionFarmingSoilType == nil then
        return nil
    end
    local soilMap = self.pfSoilMap
    if soilMap == nil and TerraLogicMain.getPrecisionFarmingSoilMap ~= nil then
        soilMap = TerraLogicMain:getPrecisionFarmingSoilMap()
        self.pfSoilMap = soilMap
    end
    if soilMap == nil then return nil end
    local soilTypeIndex = TerraLogic.getRawPrecisionFarmingSoilType(
        TerraLogic, x, z, soilMap)
    return tonumber(soilTypeIndex)
end

local function isMinimapLayout(layout)
    if layout == nil or layout.isa == nil then return false end
    return (IngameMapLayoutCircle ~= nil and layout:isa(IngameMapLayoutCircle))
        or (IngameMapLayoutSquare ~= nil and layout:isa(IngameMapLayoutSquare))
        or (IngameMapLayoutSquareLarge ~= nil
            and layout:isa(IngameMapLayoutSquareLarge))
end

local function isRoundMinimapLayout(layout)
    return layout ~= nil and layout.isa ~= nil
        and IngameMapLayoutCircle ~= nil
        and layout:isa(IngameMapLayoutCircle)
end

local function encode(value, channels)
    local steps = math.max(2 ^ (tonumber(channels) or 6) - 2, 1)
    return math.floor(clamp01(value) * steps + 1.5)
end

local function decode(value, default, channels)
    value = tonumber(value) or 0
    if value <= 0 then return default end
    local steps = math.max(2 ^ (tonumber(channels) or 6) - 2, 1)
    return clamp01((value - 1) / steps)
end

local function gradient(value)
    value = clamp01(value)
    if value < 0.5 then
        local t = value * 2
        -- Meet the warm half of the scale continuously at 0.50. The old
        -- fixed blue component jumped from 0.15 to 0.12 at the midpoint, so
        -- one 8-bit improvement from the 50% default looked conspicuous.
        return 0.15 + 0.75 * t, 0.80, 0.15 - 0.03 * t, 0.78
    end
    local t = (value - 0.5) * 2
    return 0.90, 0.80 * (1 - t) + 0.12, 0.12, 0.78
end

-- Compaction is stored and displayed directly: 0 is loose/good, 1 is
-- severely compacted/bad.  The two layers need different colour boundaries
-- because their root-yield curves have different agronomic consequences.
-- Green ends at 1% layer loss; red begins at 4% layer loss.  Deriving the
-- values from ROOT_YIELD keeps maps, HUD and Field Analysis in lockstep with
-- the harvest model if that balance is tuned later.
local function compactionThresholds(layerId)
    local profile = TerraLogicSoilProfiles ~= nil
        and TerraLogicSoilProfiles.ROOT_YIELD ~= nil
        and TerraLogicSoilProfiles.ROOT_YIELD[layerId] or nil
    local good = clamp01(profile ~= nil and profile.good
        or (layerId == "deepCompaction" and 0.10 or 0.30))
    local maximum = math.max(tonumber(profile ~= nil
        and profile.maximumLoss) or (layerId == "deepCompaction" and 0.26 or 0.15),
        0.0001)
    local exponent = math.max(tonumber(profile ~= nil
        and profile.exponent) or (layerId == "deepCompaction" and 1.45 or 1.40),
        1)
    local function valueAtLoss(loss)
        return clamp01(good + (1-good)
            * (math.clamp(loss/maximum, 0, 1) ^ (1/exponent)))
    end
    return valueAtLoss(0.01), valueAtLoss(0.04)
end

-- Resilience is a direct good/bad scale and needs a perceptually monotonic
-- palette of its own. The generic soil palette becomes visually darker on
-- the green side, which made a numerical improvement look orange or worse.
local function resilienceGradient(value)
    value = clamp01(value)
    if value <= 0.5 then
        local t = value * 2
        return 0.90 + 0.08 * t,
            0.12 + 0.73 * t,
            0.08 - 0.03 * t, 0.94
    end
    local t = (value - 0.5) * 2
    return 0.98 - 0.63 * t,
        0.85 + 0.15 * t,
        0.05 + 0.10 * t, 0.94
end

-- Tilth uses a directional scale rather than the ordinary bad-to-good scale:
-- coarse clods are red, the crumb target at 0.50 is green, and increasingly
-- pulverized soil becomes blue.  Yellow is therefore used only on the coarse
-- side and can no longer mean two opposite conditions.
local function tilthGradient(value)
    value = clamp01(value)
    local anchors = {
        {0.00, 0.90, 0.12, 0.10},
        {0.25, 0.96, 0.78, 0.08},
        {0.50, 0.15, 0.82, 0.18},
        {1.00, 0.10, 0.42, 0.96}
    }
    for index=1,#anchors-1 do
        local left, right = anchors[index], anchors[index + 1]
        if value <= right[1] then
            local t = (value - left[1])
                / math.max(right[1] - left[1], 0.0001)
            return left[2] + (right[2] - left[2]) * t,
                left[3] + (right[3] - left[3]) * t,
                left[4] + (right[4] - left[4]) * t,
                0.78
        end
    end
    local last = anchors[#anchors]
    return last[2], last[3], last[4], 0.78
end

local SOIL_MAP_LABEL_KEYS = {
    "terraLogic_soilMapSurface", "terraLogic_soilMapDeep",
    "terraLogic_soilMapAggregate", "terraLogic_soilMapRoughness",
    "terraLogic_soilMapResilience"
}

local SOIL_MAP_COMPACT_LABEL_KEYS = {
    "terraLogic_soilSurface", "terraLogic_soilDeep",
    "terraLogic_soilAggregate", "terraLogic_soilEvenness",
    "terraLogic_soilResilience"
}

local function getLocalizedSoilMapLabel(mode)
    local key = SOIL_MAP_LABEL_KEYS[mode]
    if key ~= nil and g_i18n ~= nil then
        return g_i18n:getText(key)
    end
    return "TerraLogic Soil"
end

local function getLocalizedCompactSoilMapLabel(mode)
    local key = SOIL_MAP_COMPACT_LABEL_KEYS[mode]
    if key ~= nil and g_i18n ~= nil then return g_i18n:getText(key) end
    return "Soil"
end

local function fitTextSize(text, preferredSize, maximumWidth, minimumScale)
    local width = getTextWidth(preferredSize, tostring(text or ""))
    if width <= maximumWidth or width <= 0 then return preferredSize end
    return preferredSize * math.max(
        maximumWidth / width, tonumber(minimumScale) or 0.60)
end

local function getTerrainDataNode()
    local node = g_terrainNode
    if node ~= nil and node ~= 0 then return node end
    node = g_currentMission ~= nil and g_currentMission.terrainRootNode or nil
    if node ~= nil and node ~= 0 then return node end
    return nil
end

function TerraLogicSoilManager:getMapDimensions()
    -- DensityMapModifier requires the actual terrain data node. The mission's
    -- terrainRootNode may be a parent transform and silently produces empty
    -- reads/writes without a Lua error.
    local terrainNode = getTerrainDataNode()
    local terrainSize = nil
    if terrainNode ~= nil and getTerrainSize ~= nil then
        local ok, size = pcall(getTerrainSize, terrainNode)
        if ok and tonumber(size) ~= nil and size > 1 then
            terrainSize = size
        end
    end
    -- mission.terrainSize is a scale value on FS25 maps, not the size in
    -- metres. Only accept it as a fallback when it is plausibly a world size.
    local missionSize = g_currentMission ~= nil
        and tonumber(g_currentMission.terrainSize) or nil
    if terrainSize == nil and missionSize ~= nil and missionSize >= 256 then
        terrainSize = missionSize
    end
    terrainSize = terrainSize or 2048
    local size = math.max(math.floor(terrainSize / self.CELL_SIZE + 0.5), 1)
    return size, size, terrainSize
end

function TerraLogicSoilManager:getLayerMapSize(layerId, terrainSize)
    return math.max(math.floor((tonumber(terrainSize) or self.terrainSize or 2048)
        / getLayerCellSize(layerId) + 0.5), 1)
end

function TerraLogicSoilManager:tryInitializeRaster()
    if self.rasterReady then return true end
    local terrainNode = getTerrainDataNode()
    if DensityMapModifier == nil or terrainNode == nil then
        if TerraLogicLogging.verbose and not self.rasterDeferredLogged then
            self.rasterDeferredLogged = true
            TerraLogicLogging.debug(
                "[FS25_TerraLogic] Soil raster deferred until terrain data is ready")
        end
        return false
    end

    local initializedLayers = 0
    for _, layer in ipairs(self.layers) do
        local map = self.maps[layer.id]
        if map ~= nil then
            local modifier = self.modifiers[layer.id]
            if modifier == nil then
                modifier = DensityMapModifier.new(
                    map, 0, getLayerChannels(layer.id), terrainNode)
                self.modifiers[layer.id] = modifier
                if self.mapNeedsDefaults ~= nil
                    and self.mapNeedsDefaults[layer.id] == true then
                    self:initializeFieldDefaults(layer.id, self.terrainSize)
                end
            end
            if modifier ~= nil then initializedLayers = initializedLayers + 1 end
        end
    end
    if initializedLayers ~= #self.layers then return false end
    if self.rotationMap ~= nil and self.rotationModifier == nil then
        self.rotationModifier = DensityMapModifier.new(
            self.rotationMap, 0, ROTATION_CHANNELS, terrainNode)
    end
    if self.recoveryAgeMap ~= nil and self.recoveryAgeModifier == nil then
        self.recoveryAgeModifier = DensityMapModifier.new(
            self.recoveryAgeMap, 0, RECOVERY_AGE_CHANNELS, terrainNode)
    end
    if self.rotationMap == nil or self.rotationModifier == nil
        or self.recoveryAgeMap == nil or self.recoveryAgeModifier == nil then
        return false
    end

    -- Runtime cells include changes made before the terrain became ready.
    -- Legacy savegame values are copied as aligned 4 m regions; the finer
    -- maps subdivide them naturally without thousands of individual writes.
    for _, layer in ipairs(self.layers) do
        for _, cell in pairs((self.layerCells or {})[layer.id] or {}) do
            self:writeRasterCell(layer.id, cell.ix, cell.iz, cell.value)
        end
    end
    for _, legacyCell in ipairs(self.legacyCells or {}) do
        for _, layer in ipairs(self.layers) do
            self:writeLegacyRegion(layer.id, legacyCell, false)
        end
    end
    self:createVisualizationMaps()
    -- The GRLE maps are authoritative once both modifier sets exist. Keeping
    -- millions of one-metre Lua cell tables after migration would defeat the
    -- memory benefit of the packed maps.
    for _, layer in ipairs(self.layers) do
        self.layerCells[layer.id] = {}
    end
    self.legacyCells = {}
    self.legacyCellLookup = {}
    self.rasterReady = true
    self.rasterDeferredLogged = false
    self.visualizationDirty = self.activeMapMode > 0
    self.overlayRefreshTime = 0
    TerraLogicLogging.debug(
        "[FS25_TerraLogic] Soil raster ready: %d layers, center=%d/%d/%d/%d/%d",
        initializedLayers,
        self:getRawAtWorldPosition(self.layers[1].id, 0, 0),
        self:getRawAtWorldPosition(self.layers[2].id, 0, 0),
        self:getRawAtWorldPosition(self.layers[3].id, 0, 0),
        self:getRawAtWorldPosition(self.layers[4].id, 0, 0),
        self:getRawAtWorldPosition(self.layers[5].id, 0, 0))
    return true
end

function TerraLogicSoilManager:createVisualizationMaps()
    local terrainNode = getTerrainDataNode()
    if terrainNode == nil then return false end

    for _, map in pairs(self.visualizationMaps or {}) do
        if map ~= nil and delete ~= nil then delete(map) end
    end
    self.visualizationMaps = {}
    self.visualizationModifiers = {}
    self.visualizationMapSizes = {}

    -- Rasterize the map's native field definitions directly into each
    -- one-bit display mask. FS25 fields expose polygon points; the older
    -- parallelogram fieldDimensions representation remains as a compatibility
    -- fallback for converted maps. This avoids the engine's compare-map path,
    -- which cannot combine different raster resolutions.
    local fieldPolygons = {}
    local fieldRegions = {}
    local fields = nil
    if g_fieldManager ~= nil then
        if g_fieldManager.getFields ~= nil then
            fields = g_fieldManager:getFields()
        else
            fields = g_fieldManager.fields
        end
    end
    for _, field in pairs(fields or {}) do
        if field.getPolygonPoints ~= nil then
            local polygonNodes = field:getPolygonPoints()
            local polygon = {}
            for _, pointNode in ipairs(polygonNodes or {}) do
                if pointNode ~= nil and pointNode ~= 0 then
                    local x, _, z = getWorldTranslation(pointNode)
                    polygon[#polygon + 1] = {x=x, z=z}
                end
            end
            if #polygon >= 3 then
                fieldPolygons[#fieldPolygons + 1] = polygon
            end
        end
        local dimensions = field.fieldDimensions
        if dimensions ~= nil and dimensions ~= 0 then
            local numDimensions = getNumOfChildren(dimensions)
            for index=0,numDimensions-1 do
                local widthNode = getChildAt(dimensions, index)
                if widthNode ~= nil and widthNode ~= 0
                    and getNumOfChildren(widthNode) >= 2 then
                    local startNode = getChildAt(widthNode, 0)
                    local heightNode = getChildAt(widthNode, 1)
                    local x, _, z = getWorldTranslation(startNode)
                    local widthX, _, widthZ = getWorldTranslation(widthNode)
                    local heightX, _, heightZ = getWorldTranslation(heightNode)
                    fieldRegions[#fieldRegions + 1] = {
                        x, z, widthX, widthZ, heightX, heightZ
                    }
                end
            end
        end
    end

    local halfSize = self.terrainSize * 0.5
    local directory = getSavegameDirectory()
    for _, layer in ipairs(self.layers) do
        local storageSize = self.mapSizes[layer.id] ~= nil
            and self.mapSizes[layer.id].x
            or self:getLayerMapSize(layer.id, self.terrainSize)
        -- This derived map stores only a one-bit field mask. Matching the
        -- authoritative map's dimensions lets the overlay read live soil
        -- values directly without maintaining a second value cache.
        local visualSizeX = storageSize
        local visualSizeZ = self.mapSizes[layer.id] ~= nil
            and self.mapSizes[layer.id].z or storageSize
        local map = createBitVectorMap(
            "terraLogic_visual_" .. layer.id)
        local loaded = false
        local path = directory ~= nil and layer.visualFile ~= nil
            and (directory .. "/" .. layer.visualFile) or nil
        if path ~= nil and fileExists(path)
            and loadBitVectorMapFromFile ~= nil then
            loaded = loadBitVectorMapFromFile(map, path, 1)
            if loaded then
                local loadedX, loadedZ = getBitVectorMapSize(map)
                loadedZ = tonumber(loadedZ) or tonumber(loadedX)
                local channels = getBitVectorMapNumChannels ~= nil
                    and getBitVectorMapNumChannels(map) or 1
                if loadedX ~= visualSizeX or loadedZ ~= visualSizeZ
                    or channels ~= 1 then
                    delete(map)
                    map = createBitVectorMap(
                        "terraLogic_visual_" .. layer.id)
                    loaded = false
                end
            end
        end
        if not loaded then
            loadBitVectorMapNew(map, visualSizeX, visualSizeZ, 1, false)
        end
        local modifier = DensityMapModifier.new(map, 0, 1, terrainNode)
        local defaultState = 1
        if not loaded and #fieldPolygons > 0 then
            for _, polygon in ipairs(fieldPolygons) do
                modifier:clearPolygonPoints()
                for _, point in ipairs(polygon) do
                    modifier:addPolygonPointWorldCoords(point.x, point.z)
                end
                modifier:executeSet(defaultState)
            end
            modifier:clearPolygonPoints()
        end
        if not loaded and #fieldRegions > 0 then
            for _, region in ipairs(fieldRegions) do
                modifier:setParallelogramWorldCoords(
                    region[1], region[2], region[3], region[4],
                    region[5], region[6], DensityCoordType.POINT_POINT_POINT)
                modifier:executeSet(defaultState)
            end
        elseif not loaded and #fieldPolygons == 0 then
            -- Defensive fallback for maps without native field definitions.
            -- It preserves a usable visualization instead of producing an
            -- entirely transparent overlay.
            modifier:setParallelogramWorldCoords(
                -halfSize, -halfSize,
                 halfSize, -halfSize,
                -halfSize,  halfSize,
                DensityCoordType.POINT_POINT_POINT)
            modifier:executeSet(defaultState)
        end
        self.visualizationMaps[layer.id] = map
        self.visualizationModifiers[layer.id] = modifier
        self.visualizationMapSizes[layer.id] = {
            x=visualSizeX, z=visualSizeZ
        }
    end
    for _, layer in ipairs(self.layers) do
        for _, cell in pairs((self.layerCells or {})[layer.id] or {}) do
            self:writeVisualizationCell(
                layer.id, cell.ix, cell.iz, cell.value)
        end
    end
    for _, legacyCell in ipairs(self.legacyCells or {}) do
        for _, layer in ipairs(self.layers) do
            self:writeLegacyRegion(layer.id, legacyCell, true)
        end
    end
    TerraLogicLogging.debug(
        "[FS25_TerraLogic] Soil visualization masks ready: surface=%d deep=%d tilth=%d evenness=%d resilience=%d fieldPolygons=%d legacyRegions=%d fallback=%s",
        self.visualizationMapSizes.surfaceCompaction.x,
        self.visualizationMapSizes.deepCompaction.x,
        self.visualizationMapSizes.aggregateSize.x,
        self.visualizationMapSizes.roughness.x,
        self.visualizationMapSizes.resilience.x,
        #fieldPolygons, #fieldRegions,
        tostring(#fieldPolygons == 0 and #fieldRegions == 0))
    return true
end

function TerraLogicSoilManager:initializeFieldDefaults(layerId, terrainSize)
    local modifier = self.modifiers[layerId]
    if modifier == nil then return false end

    local halfSize = terrainSize * 0.5
    modifier:setParallelogramWorldCoords(
        -halfSize, -halfSize,
         halfSize, -halfSize,
        -halfSize,  halfSize,
        DensityCoordType.POINT_POINT_POINT)
    -- New gameplay maps start at the agronomic defaults. Loaded GRLE maps skip
    -- this step so their persistent values remain intact.
    modifier:executeSet(encode(
        TerraLogicSoilProfiles.DEFAULTS[layerId],
        getLayerChannels(layerId)))
    return true
end

function TerraLogicSoilManager:load()
    self.groundTypeDensityData = nil
    self:delete(false)
    -- Developer comparison overrides are deliberately session-local. They
    -- must never leak into a normal save after a reload or be persisted.
    self.auditSoilTypeOverride = nil
    self.auditSoilTypeOverrideName = nil
    self.testSectionPresetActive = false
    self.layerCells = {}
    self.legacyCells = {}
    self.mapSizes = {}
    self.mapNeedsDefaults = {}
    self.lastPass = nil
    self.lastRejectedPass = nil
    self.lastWrite = nil
    self.lastWheelImpactDebug = nil
    self.layerWriteSerial = {}
    self.continuousTrafficValues = {deepCompaction={}}
    self.deepMapMigration = nil
    self.loadedSoilLayerCount = 0
    local _, _, terrainSize = self:getMapDimensions()
    self.terrainSize = terrainSize
    local directory = getSavegameDirectory()
    for _, layer in ipairs(self.layers) do
        self.layerCells[layer.id] = {}
        local expectedSize = self:getLayerMapSize(layer.id, terrainSize)
        local expectedChannels = getLayerChannels(layer.id)
        local map = createBitVectorMap("terraLogic_" .. layer.id)
        local loaded = false
        local path = directory ~= nil and (directory .. "/" .. layer.file) or nil
        if path ~= nil and fileExists(path) and loadBitVectorMapFromFile ~= nil then
            loaded = loadBitVectorMapFromFile(map, path, expectedChannels)
            if loaded then
                local loadedSize = getBitVectorMapSize(map)
                local loadedChannels = getBitVectorMapNumChannels ~= nil
                    and getBitVectorMapNumChannels(map) or expectedChannels
                if loadedSize ~= expectedSize
                    or loadedChannels ~= expectedChannels then
                    local canUpscaleDeep = layer.id == "deepCompaction"
                        and loadedChannels == expectedChannels
                        and tonumber(loadedSize) ~= nil
                        and loadedSize * 2 == expectedSize
                    if canUpscaleDeep then
                        self.deepMapMigration = {
                            sourceMap=map,
                            sourceSize=loadedSize,
                            sourceChannels=loadedChannels,
                            index=0,
                            changedCells=0
                        }
                        Logging.warning(
                            "[FS25_TerraLogic] Preserving 4 m deep-compaction map for incremental 2 m migration (%d -> %d pixels)",
                            loadedSize, expectedSize)
                    else
                        Logging.warning(
                            "[FS25_TerraLogic] Reinitializing incompatible soil layer %s from %s to %s pixels (%s channels)",
                            layer.id, tostring(loadedSize),
                            tostring(expectedSize), tostring(loadedChannels))
                        delete(map)
                    end
                    map = createBitVectorMap("terraLogic_" .. layer.id)
                    loaded = false
                end
            end
        end
        if not loaded then
            loadBitVectorMapNew(map, expectedSize, expectedSize,
                expectedChannels, false)
        end
        self.maps[layer.id] = map
        self.mapSizes[layer.id] = {x=expectedSize, z=expectedSize}
        self.mapNeedsDefaults[layer.id] = not loaded
        if loaded then
            self.loadedSoilLayerCount = self.loadedSoilLayerCount + 1
        end
        self.mapSizeX = math.max(self.mapSizeX or 0, expectedSize)
        self.mapSizeZ = math.max(self.mapSizeZ or 0, expectedSize)
    end
    local rotationSize = math.max(math.floor(
        terrainSize / self.RESILIENCE_CELL_SIZE + 0.5), 1)
    local rotationMap = createBitVectorMap("terraLogic_cropRotation")
    local rotationLoaded = false
    local rotationPath = directory ~= nil
        and (directory .. "/" .. ROTATION_FILE) or nil
    if rotationPath ~= nil and fileExists(rotationPath)
        and loadBitVectorMapFromFile ~= nil then
        rotationLoaded = loadBitVectorMapFromFile(
            rotationMap, rotationPath, ROTATION_CHANNELS)
        if rotationLoaded then
            local loadedX, loadedZ = getBitVectorMapSize(rotationMap)
            loadedZ = tonumber(loadedZ) or tonumber(loadedX)
            local channels = getBitVectorMapNumChannels ~= nil
                and getBitVectorMapNumChannels(rotationMap)
                or ROTATION_CHANNELS
            if loadedX ~= rotationSize or loadedZ ~= rotationSize
                or channels ~= ROTATION_CHANNELS then
                delete(rotationMap)
                rotationMap = createBitVectorMap("terraLogic_cropRotation")
                rotationLoaded = false
            end
        end
    end
    if not rotationLoaded then
        loadBitVectorMapNew(rotationMap, rotationSize, rotationSize,
            ROTATION_CHANNELS, false)
    end
    self.rotationMap = rotationMap
    self.rotationMapSize = rotationSize
    self.rotationModifier = nil
    local recoveryAgeMap = createBitVectorMap("terraLogic_recoveryAge")
    local recoveryAgeLoaded = false
    local recoveryAgePath = directory ~= nil
        and (directory .. "/" .. RECOVERY_AGE_FILE) or nil
    if recoveryAgePath ~= nil and fileExists(recoveryAgePath)
        and loadBitVectorMapFromFile ~= nil then
        recoveryAgeLoaded = loadBitVectorMapFromFile(
            recoveryAgeMap, recoveryAgePath, RECOVERY_AGE_CHANNELS)
        if recoveryAgeLoaded then
            local loadedX, loadedZ = getBitVectorMapSize(recoveryAgeMap)
            loadedZ = tonumber(loadedZ) or tonumber(loadedX)
            local channels = getBitVectorMapNumChannels ~= nil
                and getBitVectorMapNumChannels(recoveryAgeMap)
                or RECOVERY_AGE_CHANNELS
            if loadedX ~= rotationSize or loadedZ ~= rotationSize
                or channels ~= RECOVERY_AGE_CHANNELS then
                delete(recoveryAgeMap)
                recoveryAgeMap = createBitVectorMap(
                    "terraLogic_recoveryAge")
                recoveryAgeLoaded = false
            end
        end
    end
    if not recoveryAgeLoaded then
        loadBitVectorMapNew(recoveryAgeMap, rotationSize, rotationSize,
            RECOVERY_AGE_CHANNELS, false)
    end
    self.recoveryAgeMap = recoveryAgeMap
    self.recoveryAgeMapSize = rotationSize
    -- Lazy migration: untouched cells still read their exact legacy month.
    -- No whole-map conversion or recurring scan is needed.
    local legacyPath = directory ~= nil
        and (directory .. "/" .. RECOVERY_AGE_LEGACY_FILE) or nil
    self.recoveryAgeLegacyMap = nil
    if legacyPath ~= nil and fileExists(legacyPath) then
        local legacy = createBitVectorMap("terraLogic_recoveryAgeLegacy")
        local loaded = loadBitVectorMapFromFile(legacy, legacyPath, 4)
        local lx, lz = getBitVectorMapSize(legacy)
        if loaded and lx == rotationSize and (lz or lx) == rotationSize then
            self.recoveryAgeLegacyMap = legacy
        else
            delete(legacy)
        end
    end
    self.recoveryAgeModifier = nil
    self.recoveryPending = false
    self.recoveryPendingPasses = 0
    self.recoverySnapshotQueue = {}
    self.recoveryEnvironmentAccumulator = newRecoveryAccumulator()
    self.recoveryCompletedPeriods = 0
    self.recoveryLastSnapshot = nil
    self.recoveryResumeJob = nil
    self.recoveryJob = nil
    self.recoverySerial = 0
    self.recoveryGroundCoverSets = nil
    self.recoveryFruitStateInfoCache = nil
    self.rootGrowthRecent = {}
    self.npcPresetSignatures = {}
    self.npcPresetFarmlands = {}
    self.npcPresetQueue = {}
    self.npcPresetQueued = {}
    self.npcPresetCurrentJob = nil
    self.npcPresetScanPending = false
    self.npcPresetScanDelayRemaining = 0
    self.ownedPresetInitializationVersion = 0
    self.ownedPresetInitializationPending = false
    self.ownedPresetInitializationStateLoaded = false
    self.ownedPresetInitializedFields = {}
    self.dirty = false
    self.activeMapMode = 0
    self.pfMinimapRequests = {}
    self.pfMinimapSuppressed = false
    self.pfMinimapSuppressionRequested = false
    self.clientNetworkSample = nil
    self.clientNetworkSampleNextTime = 0
    self.clientNetworkTileNextTime = 0
    self.clientNetworkTilePending = {}
    self.clientNetworkTileFresh = {}
    self.clientNetworkTileKnownRevision = {}
    self.clientNetworkTileJobs = {}
    self.clientNetworkTileLayer = 0
    self.clientNetworkTileCursor = 0
    self.clientNetworkTileCenterX = nil
    self.clientNetworkTileCenterZ = nil
    self.clientNetworkTileViewportRadius = self.NETWORK_TILE_RADIUS
    self.clientNetworkTileViewportSignature = nil
    self.clientNetworkTileVisible = {}
    self.clientNetworkTileFastUntil = 0
    self.serverNetworkSampleCooldowns = setmetatable({}, {__mode="k"})
    self.serverNetworkTileCooldowns = setmetatable({}, {__mode="k"})
    self.serverNetworkTilePending = setmetatable({}, {__mode="k"})
    self.serverNetworkTileJobs = {}
    self.serverNetworkTileLayerGeneration = {}
    self.serverNetworkTileRevisions = {}
    self.fullPresetReinitializationPending = false
    self.coverageReconcileJobs = {}
    TerraLogicMapMaintenance:reset()
    self.mapViewportLastDraw = nil
    self.coverageViewportRadius = 96
    self.coverageReconcilePending = {}
    self.coverageReconcileNextRequestTime = 0
    self.coverageReconcileLastTileKey = nil
    self.coverageReconcileLastTileTime = 0
    self.coverageReconcileCooldowns = setmetatable({}, {__mode="k"})
    self.constructionCoverageTiles = {}
    self.constructionCoverageHookInstalled = false
    self.networkStats = {
        samplesReceived=0, tilesQueued=0, tilesSent=0,
        tilesReceived=0, tilesApplied=0, tileAcksSent=0,
        tileAcksReceived=0, serverQueuePeak=0
    }
    -- Install before vehicles finish loading so PF requests made by their
    -- specializations are already known when a saved TerraLogic mode is
    -- restored immediately after this load call.
    self:installPrecisionFarmingMinimapHook()
    self:installConstructionCoverageHook()
    if g_messageCenter ~= nil and MessageType ~= nil
        and MessageType.PERIOD_CHANGED ~= nil then
        g_messageCenter:subscribe(MessageType.PERIOD_CHANGED,
            self.onPeriodChanged, self)
    end
    if g_messageCenter ~= nil and MessageType ~= nil
        and MessageType.FARMLAND_OWNER_CHANGED ~= nil then
        g_messageCenter:subscribe(MessageType.FARMLAND_OWNER_CHANGED,
            self.onFarmlandOwnerChanged, self)
    end
    self:loadSparseState()
    if (tonumber(self.ownedPresetInitializationVersion) or 0)
            >= self.OWNED_PRESET_INITIALIZATION_VERSION then
        self.ownedPresetInitializationPending = false
    elseif self.ownedPresetInitializationPending == true
        or (tonumber(self.loadedSoilLayerCount) or 0) == 0 then
        -- No TerraLogic layer existed before this load: this is either a new
        -- savegame or the first installation in an existing Vanilla save.
        -- A persisted pending flag resumes safely after an unusually early
        -- save without reinitializing already completed fields.
        self.ownedPresetInitializationPending = true
        TerraLogicLogging.debug(
            "[FS25_TerraLogic] One-time owned-field soil preset initialization scheduled")
    else
        -- Builds before this marker may already contain months or years of
        -- player-created soil history. Preserve those maps instead of treating
        -- an update as a first installation.
        self.ownedPresetInitializationVersion =
            self.OWNED_PRESET_INITIALIZATION_VERSION
        self.ownedPresetInitializationPending = false
        self.ownedPresetInitializedFields = {}
        TerraLogicLogging.debug(
            "[FS25_TerraLogic] Existing TerraLogic soil maps detected; owned-field preset initialization marked complete without overwriting player data")
    end
    self.recoveryLastIntegratedGameHours =
        TerraLogicSoilTemperatureManager ~= nil
        and tonumber(TerraLogicSoilTemperatureManager.simulatedGameHours) or 0
    self.recoveryPendingPasses = #(self.recoverySnapshotQueue or {})
    if self.recoveryResumeJob ~= nil then
        self.recoveryJob = self.recoveryResumeJob
        self.recoveryResumeJob = nil
    elseif self.recoveryPendingPasses > 0 then
        self.recoveryPending = true
        self.recoveryDelayRemaining = self.RECOVERY_DELAY_MS
    end
    self:tryInitializeRaster()
    self:queueNpcPresetScan(self.NPC_PRESET_SCAN_DELAY_MS)
    TerraLogicLogging.debug(
        "[FS25_TerraLogic] Soil model loaded: surface=%d@1m deep=%d@2m tilth=%d@2m evenness=%d@2m resilience=%d@8m recoveryAge=%d@8m/12bit (terrain %.0f m, raster=%s, deepMigration=%s)",
        self.mapSizes.surfaceCompaction.x,
        self.mapSizes.deepCompaction.x,
        self.mapSizes.aggregateSize.x,
        self.mapSizes.roughness.x,
        self.mapSizes.resilience.x, self.recoveryAgeMapSize, terrainSize,
        self.rasterReady and "ready" or "pending",
        self.deepMapMigration ~= nil and "active" or "none")
end

function TerraLogicSoilManager:save()
    if g_currentMission == nil or not g_currentMission:getIsServer() then return end
    local directory = getSavegameDirectory()
    if directory == nil then return end
    for _, layer in ipairs(self.layers) do
        local map = self.maps[layer.id]
        -- Until the incremental 4 m -> 2 m conversion is complete, retain
        -- the old deep file on disk. Overwriting it with a partially migrated
        -- map would make an unusually early save destructive.
        local migrationActive = layer.id == "deepCompaction"
            and self.deepMapMigration ~= nil
        if map ~= nil and not migrationActive
            and saveBitVectorMapToFile ~= nil then
            saveBitVectorMapToFile(map, directory .. "/" .. layer.file)
        end
        local visualMap = self.visualizationMaps ~= nil
            and self.visualizationMaps[layer.id] or nil
        if visualMap ~= nil and layer.visualFile ~= nil
            and not migrationActive
            and saveBitVectorMapToFile ~= nil then
            saveBitVectorMapToFile(
                visualMap, directory .. "/" .. layer.visualFile)
        end
    end
    if self.rotationMap ~= nil and saveBitVectorMapToFile ~= nil then
        saveBitVectorMapToFile(
            self.rotationMap, directory .. "/" .. ROTATION_FILE)
    end
    if self.recoveryAgeMap ~= nil and saveBitVectorMapToFile ~= nil then
        saveBitVectorMapToFile(
            self.recoveryAgeMap, directory .. "/" .. RECOVERY_AGE_FILE)
        if self.recoveryAgeLegacyMap ~= nil then
            saveBitVectorMapToFile(self.recoveryAgeLegacyMap,
                directory .. "/" .. RECOVERY_AGE_LEGACY_FILE)
        end
    end
    self:saveSparseState()
    self.dirty = false
end

function TerraLogicSoilManager:getSparseStatePath()
    local directory = getSavegameDirectory()
    return directory ~= nil and (directory .. "/terraLogicSoilState.xml") or nil
end

function TerraLogicSoilManager:writeRecoverySnapshot(xml, key, snapshot)
    if xml == nil or snapshot == nil then return end
    xml:setInt(key .. "#version", tonumber(snapshot.version)
        or self.RECOVERY_SNAPSHOT_VERSION)
    xml:setInt(key .. "#serial", tonumber(snapshot.serial) or 0)
    xml:setFloat(key .. "#hours", tonumber(snapshot.hours) or 0)
    xml:setFloat(key .. "#daysPerPeriod",
        tonumber(snapshot.daysPerPeriod) or 1)
    xml:setFloat(key .. "#calendarScale",
        tonumber(snapshot.calendarScale) or 1)
    xml:setInt(key .. "#developmentSpeed",
        math.clamp(tonumber(snapshot.developmentSpeed) or 4, 1, 8))
    xml:setFloat(key .. "#surfaceTemperatureC",
        tonumber(snapshot.surfaceTemperatureC) or 10)
    xml:setFloat(key .. "#subsoilTemperatureC",
        tonumber(snapshot.subsoilTemperatureC) or 10)
    xml:setFloat(key .. "#airTemperatureC",
        tonumber(snapshot.airTemperatureC) or 10)
    xml:setFloat(key .. "#surfaceThawPulse",
        tonumber(snapshot.surfaceThawPulse) or 0)
    xml:setFloat(key .. "#deepThawPulse",
        tonumber(snapshot.deepThawPulse) or 0)
    xml:setString(key .. "#source", snapshot.source or "periodAverage")
    for listIndex, profileIndex in ipairs(getRecoveryProfileOrder()) do
        local profile = snapshot.profiles ~= nil
            and snapshot.profiles[profileIndex] or nil
        if profile ~= nil then
            local profileKey = string.format("%s.profile(%d)",
                key, listIndex - 1)
            xml:setInt(profileKey .. "#index", profileIndex)
            for _, name in ipairs({"moistureFactor", "biologicalFactor",
                    "physicalSurfaceFactor", "physicalDeepFactor",
                    "surfaceMoisture", "subsoilMoisture"}) do
                xml:setFloat(profileKey .. "#" .. name,
                    tonumber(profile[name]) or 0)
            end
        end
    end
end

function TerraLogicSoilManager:readRecoverySnapshot(xml, key)
    if xml == nil then return nil end
    local snapshot = {
        version=xml:getInt(key .. "#version", 1),
        serial=xml:getInt(key .. "#serial", 0),
        hours=math.max(xml:getFloat(key .. "#hours", 0), 0),
        daysPerPeriod=math.max(xml:getFloat(
            key .. "#daysPerPeriod", 1), 1),
        calendarScale=math.max(xml:getFloat(
            key .. "#calendarScale", 1), 1),
        developmentSpeed=math.clamp(xml:getInt(
            key .. "#developmentSpeed", 4), 1, 8),
        surfaceTemperatureC=xml:getFloat(
            key .. "#surfaceTemperatureC", 10),
        subsoilTemperatureC=xml:getFloat(
            key .. "#subsoilTemperatureC", 10),
        airTemperatureC=xml:getFloat(key .. "#airTemperatureC", 10),
        surfaceThawPulse=math.max(xml:getFloat(
            key .. "#surfaceThawPulse", 0), 0),
        deepThawPulse=math.max(xml:getFloat(
            key .. "#deepThawPulse", 0), 0),
        source=xml:getString(key .. "#source", "savedSnapshot"),
        profiles={}
    }
    xml:iterate(key .. ".profile", function(_, profileKey)
        local index = xml:getInt(profileKey .. "#index")
        if index ~= nil then
            local profile = {}
            for _, name in ipairs({"moistureFactor", "biologicalFactor",
                    "physicalSurfaceFactor", "physicalDeepFactor",
                    "surfaceMoisture", "subsoilMoisture"}) do
                profile[name] = xml:getFloat(profileKey .. "#" .. name, 0)
            end
            snapshot.profiles[index] = profile
        end
    end)
    return next(snapshot.profiles) ~= nil and snapshot or nil
end

function TerraLogicSoilManager:loadRecoverySchedulerState(xml)
    local root = "terraLogicSoil.recovery"
    self.recoveryCompletedPeriods = math.max(
        xml:getInt(root .. "#completedPeriods", 0), 0)
    local accumulator = newRecoveryAccumulator()
    accumulator.hours = math.max(xml:getFloat(root .. "#hours", 0), 0)
    accumulator.surfaceTemperatureSum = xml:getFloat(
        root .. "#surfaceTemperatureSum", 0)
    accumulator.subsoilTemperatureSum = xml:getFloat(
        root .. "#subsoilTemperatureSum", 0)
    accumulator.airTemperatureSum = xml:getFloat(
        root .. "#airTemperatureSum", 0)
    accumulator.daysPerPeriod = xml:getFloat(root .. "#daysPerPeriod", 1)
    accumulator.calendarScale = xml:getFloat(root .. "#calendarScale", 1)
    xml:iterate(root .. ".accumulatorProfile", function(_, profileKey)
        local index = xml:getInt(profileKey .. "#index")
        if index ~= nil then
            local profile = {hours=math.max(
                xml:getFloat(profileKey .. "#hours", 0), 0)}
            for _, name in ipairs({"moistureFactor", "biologicalFactor",
                    "physicalSurfaceFactor", "physicalDeepFactor",
                    "surfaceMoisture", "subsoilMoisture"}) do
                profile[name] = xml:getFloat(profileKey .. "#" .. name, 0)
            end
            accumulator.profiles[index] = profile
        end
    end)
    self.recoveryEnvironmentAccumulator = accumulator
    self.recoverySnapshotQueue = {}
    xml:iterate(root .. ".queue.snapshot", function(_, snapshotKey)
        local snapshot = self:readRecoverySnapshot(xml, snapshotKey)
        if snapshot ~= nil then
            self.recoverySnapshotQueue[#self.recoverySnapshotQueue + 1] =
                snapshot
        end
    end)
    local activeKey = root .. ".active"
    local activeSnapshot = self:readRecoverySnapshot(
        xml, activeKey .. ".snapshot")
    if activeSnapshot ~= nil then
        self.recoveryResumeJob = self:createRecoveryJob(
            activeSnapshot,
            math.max(xml:getInt(activeKey .. "#index", 0), 0),
            xml:getInt(activeKey .. "#developmentSpeed", 4))
    end
    self.recoveryLastSnapshot = self:readRecoverySnapshot(
        xml, root .. ".lastSnapshot")
    local latestSerial = tonumber(self.recoveryCompletedPeriods) or 0
    if self.recoveryResumeJob ~= nil then
        latestSerial = math.max(latestSerial,
            tonumber(self.recoveryResumeJob.serial) or 0)
    end
    for _, snapshot in ipairs(self.recoverySnapshotQueue) do
        latestSerial = math.max(latestSerial,
            tonumber(snapshot.serial) or 0)
    end
    self.recoverySerial = latestSerial
end

function TerraLogicSoilManager:saveRecoverySchedulerState(xml)
    local root = "terraLogicSoil.recovery"
    xml:setInt(root .. "#version", self.RECOVERY_SNAPSHOT_VERSION)
    xml:setInt(root .. "#completedPeriods",
        tonumber(self.recoveryCompletedPeriods) or 0)
    local accumulator = self.recoveryEnvironmentAccumulator
        or newRecoveryAccumulator()
    xml:setFloat(root .. "#hours", tonumber(accumulator.hours) or 0)
    xml:setFloat(root .. "#surfaceTemperatureSum",
        tonumber(accumulator.surfaceTemperatureSum) or 0)
    xml:setFloat(root .. "#subsoilTemperatureSum",
        tonumber(accumulator.subsoilTemperatureSum) or 0)
    xml:setFloat(root .. "#airTemperatureSum",
        tonumber(accumulator.airTemperatureSum) or 0)
    xml:setFloat(root .. "#daysPerPeriod",
        tonumber(accumulator.daysPerPeriod) or 1)
    xml:setFloat(root .. "#calendarScale",
        tonumber(accumulator.calendarScale) or 1)
    local profileNumber = 0
    for _, profileIndex in ipairs(getRecoveryProfileOrder()) do
        local profile = accumulator.profiles[profileIndex]
        if profile ~= nil then
            local key = string.format("%s.accumulatorProfile(%d)",
                root, profileNumber)
            profileNumber = profileNumber + 1
            xml:setInt(key .. "#index", profileIndex)
            xml:setFloat(key .. "#hours", tonumber(profile.hours) or 0)
            for _, name in ipairs({"moistureFactor", "biologicalFactor",
                    "physicalSurfaceFactor", "physicalDeepFactor",
                    "surfaceMoisture", "subsoilMoisture"}) do
                xml:setFloat(key .. "#" .. name,
                    tonumber(profile[name]) or 0)
            end
        end
    end
    for index, snapshot in ipairs(self.recoverySnapshotQueue or {}) do
        self:writeRecoverySnapshot(xml, string.format(
            "%s.queue.snapshot(%d)", root, index - 1), snapshot)
    end
    if self.recoveryLastSnapshot ~= nil then
        self:writeRecoverySnapshot(
            xml, root .. ".lastSnapshot", self.recoveryLastSnapshot)
    end
    local job = self.recoveryJob
    if job ~= nil and job.snapshot ~= nil then
        local activeKey = root .. ".active"
        xml:setInt(activeKey .. "#index", tonumber(job.index) or 0)
        xml:setInt(activeKey .. "#developmentSpeed",
            tonumber(job.developmentSpeed) or getSoilDevelopmentSpeed())
        self:writeRecoverySnapshot(
            xml, activeKey .. ".snapshot", job.snapshot)
    end
end

function TerraLogicSoilManager:loadSparseState()
    local path = self:getSparseStatePath()
    if path == nil or XMLFile == nil or not fileExists(path) then return end
    local xml = XMLFile.loadIfExists("terraLogicSoilState", path)
    if xml == nil then return end
    TerraLogicMapMaintenance.cursor = math.max(0, xml:getInt(
        "terraLogicSoil.mapMaintenance#cursor", 0))
    TerraLogicMapMaintenance.cycles = math.max(0, xml:getInt(
        "terraLogicSoil.mapMaintenance#cycles", 0))
    local sourceCount = 0
    xml:iterate("terraLogicSoil.cell", function(_, key)
        local ix = xml:getInt(key .. "#x")
        local iz = xml:getInt(key .. "#z")
        if ix ~= nil and iz ~= nil then
            local legacyCell = {
                ix=ix, iz=iz,
                surfaceCompaction=clamp01(xml:getFloat(
                    key .. "#surface",
                    TerraLogicSoilProfiles.DEFAULTS.surfaceCompaction)),
                deepCompaction=clamp01(xml:getFloat(
                    key .. "#deep",
                    TerraLogicSoilProfiles.DEFAULTS.deepCompaction)),
                aggregateSize=clamp01(xml:getFloat(
                    key .. "#aggregate",
                    TerraLogicSoilProfiles.DEFAULTS.aggregateSize)),
                roughness=clamp01(xml:getFloat(
                    key .. "#roughness",
                    TerraLogicSoilProfiles.DEFAULTS.roughness))
            }
            self.legacyCells[#self.legacyCells + 1] = legacyCell
            self.legacyCellLookup[getCellKey(ix, iz)] = legacyCell
            sourceCount = sourceCount + 1
        end
    end)
    self:loadRecoverySchedulerState(xml)
    self.npcPresetSignatures = self.npcPresetSignatures or {}
    self.npcPresetFarmlands = self.npcPresetFarmlands or {}
    xml:iterate("terraLogicSoil.npcPresets.field", function(_, key)
        local fieldKey = xml:getString(key .. "#fieldKey")
        local farmlandId = xml:getInt(key .. "#farmlandId")
        local signature = xml:getString(key .. "#signature")
        if fieldKey ~= nil and farmlandId ~= nil and signature ~= nil then
            self.npcPresetSignatures[fieldKey] = signature
            self.npcPresetFarmlands[fieldKey] = farmlandId
        end
    end)
    local ownedRoot = "terraLogicSoil.ownedPresetInitialization"
    self.ownedPresetInitializationVersion = xml:getInt(
        ownedRoot .. "#version", 0) or 0
    self.ownedPresetInitializationPending =
        (xml:getInt(ownedRoot .. "#pending", 0) or 0) > 0
    self.ownedPresetInitializationStateLoaded = true
    self.ownedPresetInitializedFields =
        self.ownedPresetInitializedFields or {}
    xml:iterate(ownedRoot .. ".field", function(_, key)
        local fieldKey = xml:getString(key .. "#fieldKey")
        local signature = xml:getString(key .. "#signature")
        if fieldKey ~= nil and signature ~= nil then
            self.ownedPresetInitializedFields[fieldKey] = signature
        end
    end)
    xml:delete()
    if sourceCount > 0 then
        TerraLogicLogging.debug(
            "[FS25_TerraLogic] Queued %d legacy 4m soil regions for layer migration",
            sourceCount)
    end
end

function TerraLogicSoilManager:saveSparseState()
    local path = self:getSparseStatePath()
    if path == nil or XMLFile == nil then return end
    local xml = XMLFile.create(
        "terraLogicSoilState", path, "terraLogicSoil")
    if xml == nil then return end
    -- Version 5 adds a resumable one-time marker for initializing fields that
    -- already belong to a player when TerraLogic first creates its soil maps.
    -- Soil values remain authoritative in the per-layer GRLE maps.
    xml:setInt("terraLogicSoil#version", 5)
    xml:setInt("terraLogicSoil.mapMaintenance#cursor", TerraLogicMapMaintenance.cursor or 0)
    xml:setInt("terraLogicSoil.mapMaintenance#cycles", TerraLogicMapMaintenance.cycles or 0)
    self:saveRecoverySchedulerState(xml)
    xml:setInt("terraLogicSoil.npcPresets#version",
        self.NPC_PRESET_VERSION)
    local index = 0
    for fieldKey, signature in pairs(self.npcPresetSignatures or {}) do
        local key = string.format(
            "terraLogicSoil.npcPresets.field(%d)", index)
        index = index + 1
        xml:setString(key .. "#fieldKey", tostring(fieldKey))
        xml:setInt(key .. "#farmlandId", tonumber(
            self.npcPresetFarmlands ~= nil
                and self.npcPresetFarmlands[fieldKey]) or 0)
        xml:setString(key .. "#signature", tostring(signature))
    end
    local ownedRoot = "terraLogicSoil.ownedPresetInitialization"
    xml:setInt(ownedRoot .. "#version", tonumber(
        self.ownedPresetInitializationVersion) or 0)
    xml:setInt(ownedRoot .. "#pending",
        self.ownedPresetInitializationPending == true and 1 or 0)
    index = 0
    for fieldKey, signature in pairs(
            self.ownedPresetInitializedFields or {}) do
        local key = string.format("%s.field(%d)", ownedRoot, index)
        index = index + 1
        xml:setString(key .. "#fieldKey", tostring(fieldKey))
        xml:setString(key .. "#signature", tostring(signature))
    end
    xml:save()
    xml:delete()
end

function TerraLogicSoilManager:delete(saveFirst)
    if saveFirst == true then self:save() end
    if g_messageCenter ~= nil then g_messageCenter:unsubscribeAll(self) end
    self:restoreMinimapZoom(self.minimapHookMap)
    if self.overlay ~= nil and delete ~= nil then delete(self.overlay) end
    self.overlay = nil
    self.overlayResolution = nil
    self.overlayReady = false
    self.overlayPending = false
    if self.deepMapMigration ~= nil
        and self.deepMapMigration.sourceMap ~= nil and delete ~= nil then
        delete(self.deepMapMigration.sourceMap)
    end
    self.deepMapMigration = nil
    for id, map in pairs(self.maps or {}) do
        if map ~= nil and delete ~= nil then delete(map) end
        self.maps[id] = nil
    end
    if self.rotationMap ~= nil and delete ~= nil then
        delete(self.rotationMap)
    end
    self.rotationMap = nil
    self.rotationMapSize = nil
    self.rotationModifier = nil
    if self.recoveryAgeMap ~= nil and delete ~= nil then
        delete(self.recoveryAgeMap)
    end
    self.recoveryAgeMap = nil
    if self.recoveryAgeLegacyMap ~= nil and delete ~= nil then
        delete(self.recoveryAgeLegacyMap)
    end
    self.recoveryAgeLegacyMap = nil
    self.recoveryAgeMapSize = nil
    self.recoveryAgeModifier = nil
    self.recoveryPending = false
    self.recoveryPendingPasses = 0
    self.recoverySnapshotQueue = {}
    self.recoveryEnvironmentAccumulator = nil
    self.recoveryLastIntegratedGameHours = nil
    self.recoveryLastSnapshot = nil
    self.recoveryCompletedPeriods = 0
    self.auditSoilTypeOverride = nil
    self.auditSoilTypeOverrideName = nil
    self.testSectionPresetActive = false
    self.recoveryResumeJob = nil
    self.recoveryJob = nil
    self.recoveryGroundCoverSets = nil
    self.recoveryFruitStateInfoCache = nil
    self.rootGrowthRecent = {}
    self.npcPresetSignatures = {}
    self.npcPresetFarmlands = {}
    self.npcPresetQueue = {}
    self.npcPresetQueued = {}
    self.npcPresetCurrentJob = nil
    self.npcPresetScanPending = false
    self.npcPresetScanDelayRemaining = 0
    self.loadedSoilLayerCount = 0
    self.ownedPresetInitializationVersion = 0
    self.ownedPresetInitializationPending = false
    self.ownedPresetInitializationStateLoaded = false
    self.ownedPresetInitializedFields = {}
    for _, map in pairs(self.visualizationMaps or {}) do
        if map ~= nil and delete ~= nil then delete(map) end
    end
    self.visualizationMaps = {}
    self.visualizationModifiers = {}
    self.modifiers = {}
    self.layerCells = {}
    self.legacyCells = {}
    self.legacyCellLookup = {}
    self.mapSizes = {}
    self.visualizationMapSizes = {}
    self.mapNeedsDefaults = {}
    self.lastPass = nil
    self.lastRejectedPass = nil
    self.lastWrite = nil
    self.lastWheelImpactDebug = nil
    self.layerWriteSerial = {}
    self.continuousTrafficValues = {}
    self.minimapHookInstalled = false
    self.minimapHookMap = nil
    self.minimapBaseHookElement = nil
    self.minimapZoomFactor = nil
    self.minimapZoomTarget = nil
    self.minimapZoomStartTime = nil
    self.minimapZoomEndTime = nil
    self.minimapZoomFromFactor = nil
    self.pendingMapMode = nil
    self.mapModeTransitionPhase = nil
    self.mapModeTransitionEndTime = nil
    -- Do not leave Precision Farming hidden across a mission teardown. The
    -- class wrapper itself is intentionally retained because PF's ValueMap
    -- class is global and may outlive this manager instance.
    self:setPrecisionFarmingMinimapSuppressed(false)
    self.pfMinimapRequests = {}
    self.pfMinimapSuppressed = false
    self.pfMinimapSuppressionRequested = false
    self.pfMinimapHookInstalled = false
    self.pfValueMapClass = nil
    self.clientNetworkSample = nil
    self.clientNetworkTilePending = nil
    self.clientNetworkTileFresh = nil
    self.clientNetworkTileKnownRevision = nil
    self.clientNetworkTileJobs = nil
    self.clientNetworkTileCursor = nil
    self.clientNetworkTileCenterX = nil
    self.clientNetworkTileCenterZ = nil
    self.clientNetworkTileViewportRadius = nil
    self.clientNetworkTileViewportSignature = nil
    self.clientNetworkTileVisible = nil
    self.clientNetworkTileFastUntil = nil
    self.serverNetworkSampleCooldowns = nil
    self.serverNetworkTileCooldowns = nil
    self.serverNetworkTilePending = nil
    self.serverNetworkTileJobs = nil
    self.serverNetworkTileLayerGeneration = nil
    self.serverNetworkTileRevisions = nil
    self.fullPresetReinitializationPending = nil
    self.coverageReconcileJobs = nil
    self.coverageReconcilePending = nil
    self.coverageReconcileNextRequestTime = nil
    self.coverageReconcileLastTileKey = nil
    self.coverageReconcileLastTileTime = nil
    self.coverageReconcileCooldowns = nil
    self.groundTypeDensityData = nil
    self.constructionCoverageTiles = nil
    self.constructionCoverageHookInstalled = false
    self.networkStats = nil
    self.rasterReady = false
    self.rasterInitRetryTime = 0
    self.rasterDeferredLogged = false
    self.overlayLoggedMode = nil
    self.mapSizeX, self.mapSizeZ = 0, 0
end

function TerraLogicSoilManager:setModifierToCell(modifier, layerId, ix, iz)
    if modifier == nil then return false end
    local cellSize = getLayerCellSize(layerId)
    local minX = ix * cellSize
    local minZ = iz * cellSize
    modifier:setParallelogramWorldCoords(
        minX, minZ,
        minX + cellSize, minZ,
        minX, minZ + cellSize,
        DensityCoordType.POINT_POINT_POINT)
    return true
end

function TerraLogicSoilManager:setModifierToWorldRegion(
        modifier, minX, minZ, size)
    if modifier == nil then return false end
    modifier:setParallelogramWorldCoords(
        minX, minZ,
        minX + size, minZ,
        minX, minZ + size,
        DensityCoordType.POINT_POINT_POINT)
    return true
end

function TerraLogicSoilManager:writeLegacyRegion(
        layerId, legacyCell, visualization)
    local modifier = visualization == true
        and self.visualizationModifiers[layerId]
        or self.modifiers[layerId]
    local minX = legacyCell.ix * self.LEGACY_CELL_SIZE
    local minZ = legacyCell.iz * self.LEGACY_CELL_SIZE
    if not self:setModifierToWorldRegion(
            modifier, minX, minZ, self.LEGACY_CELL_SIZE) then
        return false
    end
    if visualization == true then
        -- Visualization maps are one-bit field masks. Legacy soil regions
        -- were field data, so make their display area visible.
        modifier:executeSet(1)
    else
        modifier:executeSet(encode(
            legacyCell[layerId], getLayerChannels(layerId)))
    end
    return true
end

local function getRawFromBitVectorMap(
        map, channels, terrainSize, x, z, cachedSizeX, cachedSizeZ)
    if map == nil or getBitVectorMapPoint == nil then return 0 end
    local sizeX, sizeZ = tonumber(cachedSizeX), tonumber(cachedSizeZ)
    if sizeX == nil or sizeX <= 0 or sizeZ == nil or sizeZ <= 0 then
        sizeX, sizeZ = getBitVectorMapSize(map)
        sizeX, sizeZ = tonumber(sizeX) or 0,
            tonumber(sizeZ) or tonumber(sizeX) or 0
    end
    if sizeX <= 0 or sizeZ <= 0 then return 0 end
    terrainSize = tonumber(terrainSize) or 2048
    -- Match GIANTS' world-to-BitVectorMap conversion exactly. Density-map
    -- modifiers address floor(size * normalizedPosition), not a rounded
    -- position on a size-1 interval. The old conversion could therefore read
    -- the neighbouring pixel after writing the correct world-space cell.
    local px = math.floor(((tonumber(x) or 0) / terrainSize + 0.5)
        * sizeX)
    local pz = math.floor(((tonumber(z) or 0) / terrainSize + 0.5)
        * sizeZ)
    px = math.max(0, math.min(px, sizeX - 1))
    pz = math.max(0, math.min(pz, sizeZ - 1))
    return tonumber(getBitVectorMapPoint(
        map, px, pz, 0, channels)) or 0
end

function TerraLogicSoilManager:getRawAtWorldPosition(layerId, x, z)
    local size = self.mapSizes ~= nil and self.mapSizes[layerId] or nil
    return getRawFromBitVectorMap(
        self.maps[layerId], getLayerChannels(layerId),
        self.terrainSize, x, z,
        size ~= nil and size.x or nil, size ~= nil and size.z or nil)
end

-- Converts only old pixels that differ from the agronomic default. Zero is a
-- valid fully loosened value and must therefore be copied as well. The new map
-- is initialized to the default first, so a normal savegame needs many cheap
-- reads but comparatively few density-map writes. One old 4 m pixel is
-- copied as a 4 m block, yielding four identical 2 m children without any
-- interpolation or loss of the persisted six-bit value.
function TerraLogicSoilManager:updateDeepMapMigration()
    local job = self.deepMapMigration
    local modifier = self.modifiers ~= nil
        and self.modifiers.deepCompaction or nil
    if job == nil or modifier == nil then return false end
    local size = tonumber(job.sourceSize) or 0
    if size <= 0 then return false end
    local total = size * size
    local stop = math.min(job.index
        + self.DEEP_MIGRATION_SCAN_PER_FRAME, total)
    local writesThisFrame = 0
    local channels = tonumber(job.sourceChannels)
        or getLayerChannels("deepCompaction")
    local defaultRaw = encode(
        TerraLogicSoilProfiles.DEFAULTS.deepCompaction, channels)
    local oldCellSize = self.terrainSize / size
    local halfSize = self.terrainSize * 0.5
    while job.index < stop do
        local px = job.index % size
        local pz = math.floor(job.index / size)
        local raw = tonumber(getBitVectorMapPoint(
            job.sourceMap, px, pz, 0, channels)) or 0
        if raw ~= defaultRaw then
            local minX = -halfSize + px * oldCellSize
            local minZ = -halfSize + pz * oldCellSize
            modifier:setParallelogramWorldCoords(
                minX, minZ,
                minX + oldCellSize, minZ,
                minX, minZ + oldCellSize,
                DensityCoordType.POINT_POINT_POINT)
            modifier:executeSet(raw)
            job.changedCells = job.changedCells + 1
            writesThisFrame = writesThisFrame + 1
        end
        job.index = job.index + 1
        -- A normal map contains comparatively few non-default cells, but a
        -- heavily driven map can contain hundreds of thousands. Bound the
        -- expensive writes independently from the cheap reads so migration
        -- cannot produce a single-frame spike on an established savegame.
        if writesThisFrame >= self.DEEP_MIGRATION_WRITES_PER_FRAME then
            break
        end
    end
    if job.index >= total then
        if delete ~= nil and job.sourceMap ~= nil then
            delete(job.sourceMap)
        end
        self.deepMapMigration = nil
        self.dirty = true
        self.visualizationDirty = self.activeMapMode == 2
            or self.visualizationDirty
        self.overlayRefreshTime = 0
        self:invalidateServerNetworkLayer("deepCompaction")
        Logging.info(
            "[FS25_TerraLogic] Deep-compaction migration complete: %d old 4 m cells preserved in the 2 m map",
            job.changedCells)
    end
    return true
end

function TerraLogicSoilManager:getValueAtWorldPosition(layerId, x, z)
    local cellSize = getLayerCellSize(layerId)
    local ix = math.floor((tonumber(x) or 0) / cellSize)
    local iz = math.floor((tonumber(z) or 0) / cellSize)
    -- Remote clients do not own the authoritative custom BitVectorMaps. Use
    -- the latest tiny server sample around their controlled vehicle/player for
    -- draft, work-quality warnings and the on-foot soil HUD. Tiles written
    -- into the local raster remain the fallback outside this small radius.
    if g_client ~= nil and g_server == nil then
        local sample = self.clientNetworkSample
        local now = g_currentMission ~= nil and g_currentMission.time or 0
        local dx = sample ~= nil and (tonumber(x) or 0) - sample.x or 0
        local dz = sample ~= nil and (tonumber(z) or 0) - sample.z or 0
        local maximumAge = self.NETWORK_SAMPLE_MAX_AGE_MS
        local radius = self.NETWORK_SAMPLE_RADIUS_M
        if sample ~= nil and now - sample.time <= maximumAge
            and dx*dx + dz*dz <= radius*radius
            and sample.values[layerId] ~= nil then
            return sample.values[layerId]
        end
    end
    local continuous = self.continuousTrafficValues ~= nil
        and self.continuousTrafficValues[layerId] or nil
    local continuousValue = continuous ~= nil
        and continuous[getCellKey(ix, iz)] or nil
    if continuousValue ~= nil then return continuousValue end
    local cached = self.layerCells ~= nil
        and self.layerCells[layerId] ~= nil
        and self.layerCells[layerId][getCellKey(ix, iz)] or nil
    if cached ~= nil then return cached.value end
    if layerId == "deepCompaction" and self.deepMapMigration ~= nil then
        local job = self.deepMapMigration
        return decode(getRawFromBitVectorMap(
            job.sourceMap, job.sourceChannels,
            self.terrainSize, x, z),
            TerraLogicSoilProfiles.DEFAULTS.deepCompaction,
            job.sourceChannels)
    end
    if self.rasterReady ~= true and self.legacyCellLookup ~= nil then
        local legacyIx = math.floor((tonumber(x) or 0) / self.LEGACY_CELL_SIZE)
        local legacyIz = math.floor((tonumber(z) or 0) / self.LEGACY_CELL_SIZE)
        local legacyCell = self.legacyCellLookup[
            getCellKey(legacyIx, legacyIz)]
        if legacyCell ~= nil then return legacyCell[layerId] end
    end
    return decode(self:getRawAtWorldPosition(layerId, x, z),
        TerraLogicSoilProfiles.DEFAULTS[layerId],
        getLayerChannels(layerId))
end

local function normalizeCropName(value)
    return string.lower(tostring(value or "")):gsub("[^%a%d]", "")
end

local function containsAny(value, needles)
    for _, needle in ipairs(needles) do
        if string.find(value, needle, 1, true) ~= nil then return true end
    end
    return false
end

local function isCoverCropName(name)
    return containsAny(normalizeCropName(name), {
        "oilseedradish", "covercrop", "catchcrop", "greenmanure"
    })
end

function TerraLogicSoilManager:isCoverCrop(fruitTypeIndex)
    fruitTypeIndex = tonumber(fruitTypeIndex)
    if fruitTypeIndex == nil or g_fruitTypeManager == nil
        or g_fruitTypeManager.getFruitTypeByIndex == nil then return false end
    local desc = g_fruitTypeManager:getFruitTypeByIndex(fruitTypeIndex)
    return desc ~= nil and isCoverCropName(desc.name or desc.title)
end

function TerraLogicSoilManager:getCropGroup(fruitTypeIndex)
    fruitTypeIndex = tonumber(fruitTypeIndex)
    if fruitTypeIndex == nil or g_fruitTypeManager == nil
        or g_fruitTypeManager.getFruitTypeByIndex == nil then
        return CROP_GROUP.NONE, "unknown"
    end
    local desc = g_fruitTypeManager:getFruitTypeByIndex(fruitTypeIndex)
    if desc == nil then return CROP_GROUP.NONE, "unknown" end
    local name = normalizeCropName(desc.name or desc.title)
    if isCoverCropName(name) then
        return CROP_GROUP.OILSEED, name
    elseif containsAny(name, {"grass", "meadow", "alfalfa", "clover"}) then
        return CROP_GROUP.PERENNIAL, name
    elseif containsAny(name, {"soybean", "pea", "bean", "lentil", "lupin"}) then
        return CROP_GROUP.LEGUME, name
    elseif containsAny(name, {"canola", "rapeseed", "sunflower", "mustard"}) then
        return CROP_GROUP.OILSEED, name
    elseif containsAny(name, {"potato", "sugarbeet", "beetroot", "carrot", "parsnip"}) then
        return CROP_GROUP.ROOT, name
    elseif containsAny(name, {"maize", "corn"}) then
        return CROP_GROUP.MAIZE, name
    elseif containsAny(name, {"wheat", "barley", "oat", "rye", "triticale",
            "sorghum", "millet", "rice", "spelt"}) then
        return CROP_GROUP.CEREAL, name
    end
    return CROP_GROUP.OTHER, name
end

local function npcGroundIs(groundType, names)
    if FieldGroundType == nil then return false end
    for _, name in ipairs(names) do
        local value = FieldGroundType[name]
        if value ~= nil and groundType == value then return true end
    end
    return false
end

local function npcHashString(value)
    local hash = 216613626
    value = tostring(value or "")
    for index=1,#value do
        hash = (hash * 131 + string.byte(value, index)) % 2147483647
    end
    return hash
end

local function npcSignedNoise(seed, x, z, salt)
    local value = (tonumber(seed) or 1)
        + (tonumber(x) or 0) * 73856093
        + (tonumber(z) or 0) * 19349663
        + (tonumber(salt) or 0) * 83492791
    value = value % 2147483647
    value = (value * 48271 + 1) % 2147483647
    return value / 2147483647 * 2 - 1
end

local function npcPointInPolygon(x, z, polygon)
    if polygon == nil or #polygon < 3 then return false end
    local inside = false
    local previous = polygon[#polygon]
    for _, current in ipairs(polygon) do
        if (current.z > z) ~= (previous.z > z) then
            local edgeX = (previous.x - current.x) * (z - current.z)
                / (previous.z - current.z) + current.x
            if x < edgeX then inside = not inside end
        end
        previous = current
    end
    return inside
end

local function getNpcFieldId(field, farmlandId)
    if field ~= nil and field.getId ~= nil then
        local ok, value = pcall(field.getId, field)
        if ok and tonumber(value) ~= nil then return tonumber(value) end
    end
    return tonumber(field ~= nil and (field.fieldId or field.id))
        or tonumber(farmlandId) or -1
end

local function getNpcFieldCenter(field)
    if field ~= nil and field.getCenterOfFieldWorldPosition ~= nil then
        local ok, x, z = pcall(field.getCenterOfFieldWorldPosition, field)
        if ok and tonumber(x) ~= nil and tonumber(z) ~= nil then
            return tonumber(x), tonumber(z)
        end
    end
    return tonumber(field ~= nil and field.posX),
        tonumber(field ~= nil and field.posZ)
end

local function getNpcFieldKey(field, farmlandId)
    local fieldId = getNpcFieldId(field, nil)
    if fieldId ~= nil and fieldId >= 0 then
        return tostring(fieldId), fieldId
    end
    local x, z = getNpcFieldCenter(field)
    return string.format("%d:%d:%d", tonumber(farmlandId) or -1,
        math.floor((tonumber(x) or 0) + 0.5),
        math.floor((tonumber(z) or 0) + 0.5)), fieldId
end

local function getNpcFieldPolygon(field)
    if field == nil then return nil end
    local source = nil
    if field.getPolygonPoints ~= nil then
        local ok, points = pcall(field.getPolygonPoints, field)
        if ok then source = points end
    end
    source = source or field.polygonPoints
    if type(source) ~= "table" then return nil end
    local polygon = {}
    for _, point in ipairs(source) do
        local x, z = nil, nil
        if type(point) == "table" then
            x = tonumber(point.x or point[1])
            z = tonumber(point.z or point[3] or point[2])
        elseif point ~= nil and point ~= 0 and entityExists(point) then
            x, _, z = getWorldTranslation(point)
        end
        if x ~= nil and z ~= nil then
            polygon[#polygon + 1] = {x=x, z=z}
        end
    end
    if #polygon < 3 then return nil end
    local minX, maxX, minZ, maxZ = math.huge, -math.huge,
        math.huge, -math.huge
    for _, point in ipairs(polygon) do
        minX, maxX = math.min(minX, point.x), math.max(maxX, point.x)
        minZ, maxZ = math.min(minZ, point.z), math.max(maxZ, point.z)
    end
    return polygon, {minX=minX, maxX=maxX, minZ=minZ, maxZ=maxZ}
end

function TerraLogicSoilManager:getNpcFieldOwner(field, farmlandId)
    farmlandId = tonumber(farmlandId)
        or tonumber(field ~= nil and field.farmland ~= nil
            and field.farmland.id)
    if farmlandId == nil or g_farmlandManager == nil then return nil end
    if g_farmlandManager.getFarmlandOwner ~= nil then
        local ok, owner = pcall(
            g_farmlandManager.getFarmlandOwner,
            g_farmlandManager, farmlandId)
        if ok then return tonumber(owner) end
    end
    local farmland = field ~= nil and field.farmland or nil
    return tonumber(farmland ~= nil and farmland.farmId)
end

function TerraLogicSoilManager:getIsNpcField(field, farmlandId)
    local owner = self:getNpcFieldOwner(field, farmlandId)
    local noOwner = FarmlandManager ~= nil
        and tonumber(FarmlandManager.NO_OWNER_FARM_ID) or 0
    return owner ~= nil and owner == noOwner
end

function TerraLogicSoilManager:getIsPlayerOwnedField(field, farmlandId)
    local owner = self:getNpcFieldOwner(field, farmlandId)
    local noOwner = FarmlandManager ~= nil
        and tonumber(FarmlandManager.NO_OWNER_FARM_ID) or 0
    return owner ~= nil and owner ~= noOwner
end

function TerraLogicSoilManager:getIsNpcFieldMissionActive(field)
    if field == nil then return false end
    local mission = field.currentMission
    if mission ~= nil and mission.getIsActive ~= nil then
        local ok, active = pcall(mission.getIsActive, mission)
        if ok and active == true then return true end
    end
    local x, z = getNpcFieldCenter(field)
    if x ~= nil and g_missionManager ~= nil
        and g_missionManager.getMissionAtWorldPosition ~= nil then
        local ok, activeMission = pcall(
            g_missionManager.getMissionAtWorldPosition,
            g_missionManager, x, z)
        if ok and activeMission ~= nil then return true end
    end
    return false
end

local function getNpcGrowthPhase(fruitTypeIndex, growthState)
    growthState = math.max(tonumber(growthState) or 0, 0)
    local desc = g_fruitTypeManager ~= nil
        and g_fruitTypeManager.getFruitTypeByIndex ~= nil
        and g_fruitTypeManager:getFruitTypeByIndex(fruitTypeIndex) or nil
    local maximum = desc ~= nil and tonumber(
        desc.maxHarvestingGrowthState or desc.numGrowthStates) or nil
    maximum = math.max(maximum or growthState or 1, 1)
    local harvestable = false
    if desc ~= nil and desc.getIsHarvestable ~= nil then
        local ok, result = pcall(desc.getIsHarvestable, desc, growthState)
        harvestable = ok and result == true
    elseif desc ~= nil and tonumber(desc.minHarvestingGrowthState) ~= nil then
        harvestable = growthState >= desc.minHarvestingGrowthState
            and growthState <= (tonumber(desc.maxHarvestingGrowthState)
                or growthState)
    end
    if harvestable then return 4 end
    return math.clamp(math.ceil(growthState / maximum * 4), 1, 4)
end

local function getPresetKeyFromFieldState(
        groundType, plowLevel, fruitTypeIndex, growthState, rollerLevel)
    local unknownFruit = FruitType ~= nil
        and tonumber(FruitType.UNKNOWN) or 0
    local hasFruit = fruitTypeIndex ~= nil
        and fruitTypeIndex ~= unknownFruit and fruitTypeIndex > 0
    local group = hasFruit
        and TerraLogicSoilManager:getCropGroup(fruitTypeIndex)
        or CROP_GROUP.NONE
    local phase = hasFruit and getNpcGrowthPhase(
        fruitTypeIndex, growthState) or 0
    local presetKey
    if group == CROP_GROUP.PERENNIAL then
        presetKey = "perennial"
    -- A live crop is more authoritative than a stale harvested/tillage ground
    -- flag. This matters especially on player-owned fields whose FieldState is
    -- not guaranteed to follow every density-map operation.
    elseif hasFruit then
        if phase <= 1 and npcGroundIs(groundType, {"DIRECT_SOWN"}) then
            presetKey = "directSown"
        elseif phase <= 1 and npcGroundIs(groundType, {"SOWN"}) then
            presetKey = "sown"
        else
            presetKey = "growing"
        end
    elseif npcGroundIs(groundType,
            {"HARVESTED", "GRASS_CUT", "MULCHED"}) then
        presetKey = "harvested"
    elseif npcGroundIs(groundType, {"PLOWED"}) then
        presetKey = "plowed"
    elseif (tonumber(plowLevel) or 0) > 0
        and (g_currentMission == nil
            or g_currentMission.missionInfo == nil
            or g_currentMission.missionInfo.plowingRequiredEnabled ~= false)
        and npcGroundIs(groundType,
            {"CULTIVATED", "STUBBLE_TILLAGE"}) then
        presetKey = "subsoiled"
    elseif npcGroundIs(groundType, {"STUBBLE_TILLAGE"}) then
        presetKey = "shallow"
    elseif npcGroundIs(groundType, {"CULTIVATED"}) then
        presetKey = "cultivated"
    elseif npcGroundIs(groundType, {"SEEDBED", "ROLLED_SEEDBED"})
        or (tonumber(rollerLevel) or 0) > 0 then
        presetKey = "seedbed"
    elseif npcGroundIs(groundType, {"DIRECT_SOWN"}) then
        presetKey = "directSown"
    elseif npcGroundIs(groundType, {"SOWN"}) then
        presetKey = "sown"
    elseif npcGroundIs(groundType, {"GRASS"}) then
        presetKey = "perennial"
    else
        presetKey = "bare"
    end
    return presetKey, hasFruit, group, phase
end

-- Player-owned fields are initialized from their live density maps. Vanilla's
-- persistent FieldState is authoritative for simulated NPC work, but it may
-- retain the map's original ploughed/cultivated state after a player has sown
-- the field. A small deterministic interior grid is enough to reject isolated
-- misses and headland remnants without scanning the full density map.
function TerraLogicSoilManager:getLiveOwnedFieldState(field)
    local polygon, bounds = getNpcFieldPolygon(field)
    if polygon == nil or bounds == nil then return nil end
    local fruitVotes, growthVotes, groundVotes = {}, {}, {}
    local samples = 0
    local function addVote(target, key)
        if key == nil then return end
        target[key] = (target[key] or 0) + 1
    end
    local function sampleAt(x, z)
        if not npcPointInPolygon(x, z, polygon) then return end
        samples = samples + 1
        local fruitTypeIndex, growthState = nil, nil
        if FSDensityMapUtil ~= nil
            and FSDensityMapUtil.getFruitTypeIndexAtWorldPos ~= nil then
            local ok, fruit, growth = pcall(
                FSDensityMapUtil.getFruitTypeIndexAtWorldPos, x, z)
            if ok then
                fruitTypeIndex, growthState = tonumber(fruit), tonumber(growth)
            end
        end
        local unknownFruit = FruitType ~= nil
            and tonumber(FruitType.UNKNOWN) or 0
        if fruitTypeIndex ~= nil and fruitTypeIndex > 0
            and fruitTypeIndex ~= unknownFruit then
            addVote(fruitVotes, fruitTypeIndex)
            growthVotes[fruitTypeIndex] = growthVotes[fruitTypeIndex] or {}
            addVote(growthVotes[fruitTypeIndex], growthState or 0)
        end
        -- Density-map values are not FieldGroundType IDs. NPC field states
        -- already contain IDs; translate only this live-density boundary.
        local rawGround = self:getGroundTypeAtWorldPosition(x, z)
        local groundType = nil
        if rawGround ~= nil and FieldGroundType ~= nil
                and FieldGroundType.getTypeByValue ~= nil then
            groundType = FieldGroundType.getTypeByValue(rawGround)
        end
        addVote(groundVotes, groundType)
    end
    local grid = 5
    for iz=0,grid-1 do
        for ix=0,grid-1 do
            sampleAt(
                bounds.minX + (ix + 0.5) / grid
                    * (bounds.maxX - bounds.minX),
                bounds.minZ + (iz + 0.5) / grid
                    * (bounds.maxZ - bounds.minZ))
        end
    end
    local centerX, centerZ = getNpcFieldCenter(field)
    if centerX ~= nil then sampleAt(centerX, centerZ) end
    if samples <= 0 then return nil end

    local function dominant(votes)
        local selected, count = nil, -1
        for value, votesForValue in pairs(votes or {}) do
            if votesForValue > count
                or (votesForValue == count
                    and (selected == nil or value < selected)) then
                selected, count = value, votesForValue
            end
        end
        return selected, math.max(count, 0)
    end
    local fruitTypeIndex, fruitCount = dominant(fruitVotes)
    -- Requiring two supporting points prevents one volunteer plant from
    -- turning a genuinely bare field into a growing preset.
    if fruitCount < math.min(2, samples) then fruitTypeIndex = nil end
    local growthState = fruitTypeIndex ~= nil
        and dominant(growthVotes[fruitTypeIndex]) or nil
    local groundType = dominant(groundVotes)
    if groundType == nil then return nil end
    return {
        groundType=groundType, plowLevel=0, rollerLevel=0,
        fruitTypeIndex=fruitTypeIndex, growthState=growthState,
        liveSampleCount=samples, liveFruitSampleCount=fruitCount,
        source="liveDensity"
    }
end

function TerraLogicSoilManager:getNpcFieldDescriptor(
        field, includeGeometry, useLiveOwnedState)
    if field == nil then return nil end
    local state = nil
    if useLiveOwnedState == true then
        state = self:getLiveOwnedFieldState(field)
    elseif field.getFieldState ~= nil then
        local ok, result = pcall(field.getFieldState, field)
        if ok then state = result end
    end
    if state == nil and useLiveOwnedState ~= true then
        state = field.fieldState
    end
    if state == nil or state.isValid == false then return nil end
    local farmlandId = tonumber(field.farmland ~= nil and field.farmland.id)
    if farmlandId == nil then return nil end
    local groundType = tonumber(state.groundType) or 0
    local plowLevel = tonumber(state.plowLevel) or 0
    local rollerLevel = tonumber(state.rollerLevel) or 0
    local fruitTypeIndex = tonumber(state.fruitTypeIndex)
    local unknownFruit = FruitType ~= nil
        and tonumber(FruitType.UNKNOWN) or 0
    local hasFruit = fruitTypeIndex ~= nil
        and fruitTypeIndex ~= unknownFruit and fruitTypeIndex > 0
    local group, cropName = self:getCropGroup(fruitTypeIndex)
    if not hasFruit then group, cropName = CROP_GROUP.NONE, "none" end
    local presetKey, _, _, phase = getPresetKeyFromFieldState(
        groundType, plowLevel, fruitTypeIndex, state.growthState, rollerLevel)

    local base = NPC_FIELD_PRESETS[presetKey] or NPC_FIELD_PRESETS.bare
    local values = {}
    for layerId, value in pairs(base) do values[layerId] = value end
    local phaseScale = ({[0]=0, [1]=0.20, [2]=0.45,
        [3]=0.75, [4]=1.00})[phase] or 1
    if presetKey == "harvested" then phaseScale = 0.75 end
    local cropModifier = NPC_CROP_MODIFIERS[group]
    if cropModifier ~= nil then
        for layerId, offset in pairs(cropModifier) do
            values[layerId] = clamp01((values[layerId] or 0)
                + offset * phaseScale)
        end
    end
    local signature = table.concat({tostring(self.NPC_PRESET_VERSION), presetKey,
        tostring(fruitTypeIndex or 0), tostring(phase),
        tostring(groundType), tostring(plowLevel > 0 and 1 or 0),
        tostring(state.source or "fieldState")}, "|")
    if includeGeometry == false then
        local fieldKey, fieldId = getNpcFieldKey(field, farmlandId)
        return {field=field, fieldKey=fieldKey, fieldId=fieldId,
            farmlandId=farmlandId,
            presetKey=presetKey, signature=signature}
    end
    local polygon, bounds = getNpcFieldPolygon(field)
    if polygon == nil then return nil end
    local fieldKey, fieldId = getNpcFieldKey(field, farmlandId)
    local seed = npcHashString(tostring(farmlandId) .. ":" .. signature)
    for layerId, variation in pairs(NPC_FIELD_VARIATION) do
        values[layerId] = clamp01((values[layerId] or 0)
            + npcSignedNoise(seed, 0, 0, variation.salt)
                * variation.field)
    end
    return {
        field=field, fieldKey=fieldKey, fieldId=fieldId,
        farmlandId=farmlandId,
        presetKey=presetKey, fruitTypeIndex=fruitTypeIndex or 0,
        cropGroup=group, cropName=cropName, growthPhase=phase,
        groundType=groundType, plowLevel=plowLevel,
        stateSource=state.source or "fieldState",
        liveSampleCount=tonumber(state.liveSampleCount) or 0,
        liveFruitSampleCount=tonumber(state.liveFruitSampleCount) or 0,
        signature=signature, seed=seed, values=values,
        polygon=polygon, bounds=bounds
    }
end

function TerraLogicSoilManager:queueNpcPresetScan(delayMs)
    if g_currentMission == nil or not g_currentMission:getIsServer() then return end
    local wasPending = self.npcPresetScanPending == true
    self.npcPresetScanPending = true
    local delay = math.max(tonumber(delayMs)
        or self.NPC_PRESET_SCAN_DELAY_MS, 0)
    if wasPending then
        self.npcPresetScanDelayRemaining = math.min(
            tonumber(self.npcPresetScanDelayRemaining) or delay, delay)
    else
        self.npcPresetScanDelayRemaining = delay
    end
end

function TerraLogicSoilManager:queueNpcPresetDescriptor(descriptor)
    if descriptor == nil then return false end
    self.npcPresetQueued = self.npcPresetQueued or {}
    if self.npcPresetQueued[descriptor.fieldKey] == true then return false end
    local patchSize = self.NPC_PRESET_PATCH_SIZE_M
    local bounds = descriptor.bounds
    descriptor.patchMinX = math.floor(bounds.minX / patchSize)
    descriptor.patchMaxX = math.ceil(bounds.maxX / patchSize) - 1
    descriptor.patchMinZ = math.floor(bounds.minZ / patchSize)
    descriptor.patchMaxZ = math.ceil(bounds.maxZ / patchSize) - 1
    descriptor.patchX = descriptor.patchMinX
    descriptor.patchZ = descriptor.patchMinZ
    descriptor.phase = "base"
    self.npcPresetQueue = self.npcPresetQueue or {}
    if descriptor.presetScope == "ownedBootstrap"
        or descriptor.presetScope == "ownedRepair" then
        -- Player fields should match their visible initial state before the
        -- background NPC refresh works through the rest of the map.
        table.insert(self.npcPresetQueue, 1, descriptor)
    else
        self.npcPresetQueue[#self.npcPresetQueue + 1] = descriptor
    end
    self.npcPresetQueued[descriptor.fieldKey] = true
    return true
end

function TerraLogicSoilManager:scanNpcPresetFields()
    if g_fieldManager == nil then return false end
    local fields = g_fieldManager.getFields ~= nil
        and g_fieldManager:getFields() or g_fieldManager.fields
    if type(fields) ~= "table" then return false end
    self.npcPresetSignatures = self.npcPresetSignatures or {}
    self.ownedPresetInitializedFields =
        self.ownedPresetInitializedFields or {}
    local initializeOwned = self.ownedPresetInitializationPending == true
    local foundField, waitingForState, queued = false, false, 0
    local ownedMissing, ownedQueued = false, 0
    for _, field in pairs(fields) do
        local farmlandId = tonumber(field ~= nil and field.farmland ~= nil
            and field.farmland.id)
        if farmlandId ~= nil then
            foundField = true
            local isNpc = self:getIsNpcField(field, farmlandId)
            if isNpc
                and not self:getIsNpcFieldMissionActive(field) then
                local state = self:getNpcFieldDescriptor(field, false)
                if state == nil then
                    waitingForState = true
                elseif self.npcPresetSignatures[state.fieldKey]
                        ~= state.signature then
                    local descriptor = self:getNpcFieldDescriptor(field, true)
                    if descriptor == nil then
                        waitingForState = true
                    elseif self:queueNpcPresetDescriptor(descriptor) then
                        queued = queued + 1
                    end
                end
            elseif initializeOwned
                and self:getIsPlayerOwnedField(field, farmlandId) then
                local state = self:getNpcFieldDescriptor(field, false, true)
                if state == nil then
                    waitingForState = true
                elseif self.ownedPresetInitializedFields[state.fieldKey]
                        ~= state.signature then
                    ownedMissing = true
                    local descriptor = self:getNpcFieldDescriptor(field, true, true)
                    if descriptor == nil then
                        waitingForState = true
                    else
                        descriptor.presetScope = "ownedBootstrap"
                        if self:queueNpcPresetDescriptor(descriptor) then
                            ownedQueued = ownedQueued + 1
                        end
                    end
                end
            end
        end
    end
    if queued > 0 then
        TerraLogicLogging.debug(
            "[FS25_TerraLogic] Queued %d changed NPC field preset(s)",
            queued)
    end
    if ownedQueued > 0 then
        TerraLogicLogging.debug(
            "[FS25_TerraLogic] Queued %d one-time owned-field preset(s)",
            ownedQueued)
    end
    local ownedJobActive = self.npcPresetCurrentJob ~= nil
        and self.npcPresetCurrentJob.presetScope == "ownedBootstrap"
    if not ownedJobActive then
        for _, job in ipairs(self.npcPresetQueue or {}) do
            if job.presetScope == "ownedBootstrap" then
                ownedJobActive = true
                break
            end
        end
    end
    if initializeOwned and foundField and not waitingForState
        and not ownedMissing and not ownedJobActive then
        self.ownedPresetInitializationVersion =
            self.OWNED_PRESET_INITIALIZATION_VERSION
        self.ownedPresetInitializationPending = false
        self.ownedPresetInitializedFields = {}
        TerraLogicLogging.debug(
            "[FS25_TerraLogic] One-time owned-field soil preset initialization complete")
    end
    return foundField and not waitingForState
end

local function npcPatchInsideField(job, minX, minZ, size)
    local inset = math.min(0.5, size * 0.05)
    local maxX, maxZ = minX + size, minZ + size
    return npcPointInPolygon(minX + inset, minZ + inset, job.polygon)
        and npcPointInPolygon(maxX - inset, minZ + inset, job.polygon)
        and npcPointInPolygon(minX + inset, maxZ - inset, job.polygon)
        and npcPointInPolygon(maxX - inset, maxZ - inset, job.polygon)
        and npcPointInPolygon(minX + size * 0.5,
            minZ + size * 0.5, job.polygon)
end

function TerraLogicSoilManager:writeNpcPresetBase(job)
    for _, layer in ipairs(self.layers) do
        local modifier = self.modifiers[layer.id]
        if modifier == nil then return false end
        modifier:clearPolygonPoints()
        for _, point in ipairs(job.polygon) do
            modifier:addPolygonPointWorldCoords(point.x, point.z)
        end
        modifier:executeSet(encode(
            job.values[layer.id], getLayerChannels(layer.id)))
        modifier:clearPolygonPoints()
    end
    return true
end

function TerraLogicSoilManager:getNpcPresetPatchValues(job, gridX, gridZ)
    local values = {}
    for layerId, baseValue in pairs(job.values) do
        local variation = NPC_FIELD_VARIATION[layerId]
        local coarseX, coarseZ = math.floor(gridX / 2), math.floor(gridZ / 2)
        local coarse = npcSignedNoise(
            job.seed, coarseX, coarseZ, variation.salt + 101)
        local fine = npcSignedNoise(
            job.seed, gridX, gridZ, variation.salt + 211)
        local localNoise = coarse * 0.72 + fine * 0.28
        values[layerId] = clamp01(baseValue
            + localNoise * variation.localValue)
    end
    return values
end

function TerraLogicSoilManager:writeNpcPresetPatch(job, gridX, gridZ)
    local size = self.NPC_PRESET_PATCH_SIZE_M
    local minX, minZ = gridX * size, gridZ * size
    if not npcPatchInsideField(job, minX, minZ, size) then return false end
    local values = self:getNpcPresetPatchValues(job, gridX, gridZ)
    for _, layer in ipairs(self.layers) do
        local modifier = self.modifiers[layer.id]
        if modifier ~= nil and self:setModifierToWorldRegion(
                modifier, minX, minZ, size) then
            modifier:executeSet(encode(
                values[layer.id], getLayerChannels(layer.id)))
        end
    end
    job.variedPatches = (tonumber(job.variedPatches) or 0) + 1
    return true
end

function TerraLogicSoilManager:clearNpcPresetRuntimeCaches(job)
    local bounds = job.bounds
    local function clearLayerTables(collection)
        for layerId, entries in pairs(collection or {}) do
            local cellSize = getLayerCellSize(layerId)
            for key in pairs(entries or {}) do
                local ix, iz = string.match(tostring(key),
                    "^(-?%d+):(-?%d+)$")
                ix, iz = tonumber(ix), tonumber(iz)
                if ix ~= nil then
                    local x, z = (ix + 0.5) * cellSize,
                        (iz + 0.5) * cellSize
                    if x >= bounds.minX and x <= bounds.maxX
                        and z >= bounds.minZ and z <= bounds.maxZ
                        and npcPointInPolygon(x, z, job.polygon) then
                        entries[key] = nil
                    end
                end
            end
        end
    end
    clearLayerTables(self.continuousTrafficValues)
    clearLayerTables(self.layerCells)
end

function TerraLogicSoilManager:finishNpcPresetJob(job)
    self:clearNpcPresetRuntimeCaches(job)
    self.npcPresetSignatures = self.npcPresetSignatures or {}
    self.npcPresetFarmlands = self.npcPresetFarmlands or {}
    local ownedBootstrap = job.presetScope == "ownedBootstrap"
    local ownedRepair = job.presetScope == "ownedRepair"
    if ownedBootstrap then
        self.ownedPresetInitializedFields =
            self.ownedPresetInitializedFields or {}
        self.ownedPresetInitializedFields[job.fieldKey] = job.signature
    elseif not ownedRepair then
        self.npcPresetSignatures[job.fieldKey] = job.signature
        self.npcPresetFarmlands[job.fieldKey] = job.farmlandId
    end
    self.npcPresetQueued[job.fieldKey] = nil
    self.npcPresetCurrentJob = nil
    self.layerWriteSerial = self.layerWriteSerial or {}
    for _, layer in ipairs(self.layers) do
        self.layerWriteSerial[layer.id] =
            (tonumber(self.layerWriteSerial[layer.id]) or 0) + 1
        -- Presets use polygon/patch modifier writes instead of individual
        -- cells. Mark only tiles intersecting this field's bounds so an NPC
        -- update elsewhere cannot force every client's visible map to reload.
        self:markServerNetworkRegionChanged(layer.id,
            job.bounds.minX, job.bounds.minZ,
            job.bounds.maxX, job.bounds.maxZ)
    end
    self.dirty = true
    self.visualizationDirty = true
    local now = g_currentMission ~= nil and g_currentMission.time or 0
    self.overlayRefreshTime = now + self.OVERLAY_REFRESH_DELAY_MS
    TerraLogicLogging.debug(
        "[FS25_TerraLogic] %s field preset complete: field=%s farmland=%d preset=%s crop=%s phase=%d variedPatches=%d",
        ownedBootstrap and "Initial owned"
            or (ownedRepair and "Repaired owned" or "NPC"),
        tostring(job.fieldId), job.farmlandId, tostring(job.presetKey),
        tostring(job.cropName), tonumber(job.growthPhase) or 0,
        tonumber(job.variedPatches) or 0)
    if ownedBootstrap then
        self:queueNpcPresetScan(self.NPC_PRESET_RETRY_DELAY_MS)
    end
end

function TerraLogicSoilManager:cancelNpcPresetJob(job, rescan)
    if job ~= nil and self.npcPresetQueued ~= nil then
        self.npcPresetQueued[job.fieldKey] = nil
    end
    self.npcPresetCurrentJob = nil
    if rescan == true then
        self:queueNpcPresetScan(self.NPC_PRESET_RETRY_DELAY_MS)
    end
end

function TerraLogicSoilManager:updateNpcPresets(dt)
    if g_currentMission == nil or not g_currentMission:getIsServer()
        or not self.rasterReady or self.deepMapMigration ~= nil then return end
    -- A developer-requested full reset is committed only between jobs. This
    -- prevents a field whose base polygon was already written from being left
    -- half initialized when the request arrives. Queued-but-not-started jobs
    -- are safely discarded and rebuilt from the current live field state.
    if self.fullPresetReinitializationPending == true
        and self.npcPresetCurrentJob == nil
        and self.recoveryPending ~= true and self.recoveryJob == nil then
        self.npcPresetQueue = {}
        self.npcPresetQueued = {}
        self.npcPresetSignatures = {}
        self.npcPresetFarmlands = {}
        self.ownedPresetInitializedFields = {}
        self.ownedPresetInitializationVersion = 0
        self.ownedPresetInitializationPending = true
        self.npcPresetScanPending = false
        self.npcPresetScanDelayRemaining = 0
        self.fullPresetReinitializationPending = false
        self.dirty = true
        self:queueNpcPresetScan(0)
        Logging.info(
            "[FS25_TerraLogic] Full field-preset reinitialization started (NPC and player-owned standard fields)")
    end
    if self.npcPresetScanPending == true then
        self.npcPresetScanDelayRemaining = math.max(
            (tonumber(self.npcPresetScanDelayRemaining) or 0)
                - (tonumber(dt) or 0), 0)
        if self.npcPresetScanDelayRemaining <= 0 then
            local fieldTasks = g_fieldManager ~= nil
                and g_fieldManager.updateTasks or nil
            if type(fieldTasks) == "table" and #fieldTasks > 0 then
                self.npcPresetScanDelayRemaining =
                    self.NPC_PRESET_RETRY_DELAY_MS
            else
                self.npcPresetScanPending = false
                if not self:scanNpcPresetFields() then
                    self:queueNpcPresetScan(self.NPC_PRESET_RETRY_DELAY_MS)
                end
            end
        end
    end

    -- Complete the period's physical/biological recovery snapshot first.
    -- Presets then describe the new Vanilla NPC state without two writers
    -- touching the same raster cells during one frame window.
    if self.recoveryPending == true or self.recoveryJob ~= nil then return end

    local job = self.npcPresetCurrentJob
    if job == nil and #(self.npcPresetQueue or {}) > 0 then
        job = table.remove(self.npcPresetQueue, 1)
        self.npcPresetCurrentJob = job
    end
    if job == nil then return end
    local ownedBootstrap = job.presetScope == "ownedBootstrap"
    local ownedRepair = job.presetScope == "ownedRepair"
    local ownedJob = ownedBootstrap or ownedRepair
    local invalidOwner = ownedBootstrap
        and (self.ownedPresetInitializationPending ~= true
            or not self:getIsPlayerOwnedField(job.field, job.farmlandId))
        or ownedRepair
            and not self:getIsPlayerOwnedField(job.field, job.farmlandId)
        or (not ownedJob
            and not self:getIsNpcField(job.field, job.farmlandId))
    if invalidOwner or self:getIsNpcFieldMissionActive(job.field) then
        self:cancelNpcPresetJob(job, false)
        if ownedBootstrap then
            self:queueNpcPresetScan(self.NPC_PRESET_RETRY_DELAY_MS)
        end
        return
    end
    local now = g_currentMission.time or 0
    if now >= (tonumber(job.nextStateCheckTime) or 0) then
        local current = self:getNpcFieldDescriptor(job.field, false,
            job.stateSource == "liveDensity")
        job.nextStateCheckTime = now + 1000
        if current == nil then
            self:cancelNpcPresetJob(job, true)
            return
        elseif current.signature ~= job.signature then
            self:cancelNpcPresetJob(job, true)
            return
        end
    end

    if job.phase == "base" then
        if not self:writeNpcPresetBase(job) then
            self:cancelNpcPresetJob(job, true)
            return
        end
        job.phase = "variation"
    end

    local processed = 0
    while job.patchZ <= job.patchMaxZ
        and processed < self.NPC_PRESET_PATCHES_PER_FRAME do
        self:writeNpcPresetPatch(job, job.patchX, job.patchZ)
        processed = processed + 1
        job.patchX = job.patchX + 1
        if job.patchX > job.patchMaxX then
            job.patchX = job.patchMinX
            job.patchZ = job.patchZ + 1
        end
    end
    if job.patchZ > job.patchMaxZ then self:finishNpcPresetJob(job) end
end

function TerraLogicSoilManager:queueOwnedFieldPresetRepairAtWorldPosition(x, z)
    if g_server == nil or self.rasterReady ~= true
        or g_farmlandManager == nil or g_fieldManager == nil
        or g_farmlandManager.getFarmlandAtWorldPosition == nil then
        return false, "server soil raster unavailable"
    end
    x, z = tonumber(x), tonumber(z)
    if x == nil or z == nil then return false, "position unavailable" end
    local farmland = g_farmlandManager:getFarmlandAtWorldPosition(x, z)
    if farmland == nil then return false, "no farmland at this position" end
    local mapped = (g_fieldManager.farmlandIdFieldMapping or {})[farmland.id]
    local candidates = type(mapped) == "table" and mapped[1] ~= nil
        and mapped.getPolygonPoints == nil and mapped or {mapped}
    local field = nil
    for _, candidate in ipairs(candidates) do
        local polygon = getNpcFieldPolygon(candidate)
        if polygon ~= nil and npcPointInPolygon(x, z, polygon) then
            field = candidate
            break
        end
    end
    if field == nil then return false, "no standard field polygon found" end
    if not self:getIsPlayerOwnedField(field, farmland.id) then
        return false, "field is not player-owned"
    end
    local descriptor = self:getNpcFieldDescriptor(field, true, true)
    if descriptor == nil then
        return false, "live field state is not ready"
    end
    descriptor.presetScope = "ownedRepair"
    if not self:queueNpcPresetDescriptor(descriptor) then
        return false, "field preset is already queued"
    end
    Logging.info(
        "[FS25_TerraLogic] Queued live owned-field preset repair: field=%s farmland=%d preset=%s samples=%d fruitSamples=%d",
        tostring(descriptor.fieldId), tonumber(descriptor.farmlandId) or -1,
        tostring(descriptor.presetKey),
        tonumber(descriptor.liveSampleCount) or 0,
        tonumber(descriptor.liveFruitSampleCount) or 0)
    return true, string.format("field %s queued as %s",
        tostring(descriptor.fieldId), tostring(descriptor.presetKey))
end

function TerraLogicSoilManager:requestAllFieldPresetReinitialization()
    if g_server == nil or g_currentMission == nil
        or self.rasterReady ~= true then
        return false, "server soil raster unavailable"
    end
    if self.fullPresetReinitializationPending == true then
        return false, "full reinitialization is already pending"
    end
    self.fullPresetReinitializationPending = true
    return true, "all NPC and player-owned field presets queued"
end

function TerraLogicSoilManager:onFarmlandOwnerChanged(
        farmlandId, farmId, loadFromSavegame)
    farmlandId = tonumber(farmlandId)
    if farmlandId == nil then return end
    local noOwner = FarmlandManager ~= nil
        and tonumber(FarmlandManager.NO_OWNER_FARM_ID) or 0
    if tonumber(farmId) == noOwner then
        self.npcPresetSignatures = self.npcPresetSignatures or {}
        self.npcPresetFarmlands = self.npcPresetFarmlands or {}
        for fieldKey, storedFarmlandId in pairs(self.npcPresetFarmlands) do
            if tonumber(storedFarmlandId) == farmlandId then
                self.npcPresetSignatures[fieldKey] = nil
                self.npcPresetFarmlands[fieldKey] = nil
            end
        end
        self:queueNpcPresetScan(self.NPC_PRESET_SCAN_DELAY_MS)
    else
        local retained = {}
        for _, job in ipairs(self.npcPresetQueue or {}) do
            if job.farmlandId ~= farmlandId then
                retained[#retained + 1] = job
            end
        end
        self.npcPresetQueue = retained
        self.npcPresetQueued = self.npcPresetQueued or {}
        self.npcPresetQueued = {}
        for _, job in ipairs(self.npcPresetQueue) do
            self.npcPresetQueued[job.fieldKey] = true
        end
        if self.npcPresetCurrentJob ~= nil then
            self.npcPresetQueued[
                self.npcPresetCurrentJob.fieldKey] = true
        end
    end
    if self.npcPresetCurrentJob ~= nil
        and self.npcPresetCurrentJob.farmlandId == farmlandId
        and tonumber(farmId) ~= noOwner then
        self:cancelNpcPresetJob(self.npcPresetCurrentJob, false)
    end
    if self.ownedPresetInitializationPending == true then
        self:queueNpcPresetScan(self.NPC_PRESET_RETRY_DELAY_MS)
    end
end

local function getRawMapPointAtWorldPosition(
        map, firstChannel, numChannels, terrainSize, x, z)
    if map == nil or getBitVectorMapPoint == nil then return nil end
    local sizeX, sizeZ = getBitVectorMapSize(map)
    sizeX = tonumber(sizeX) or 0
    sizeZ = tonumber(sizeZ) or sizeX
    if sizeX <= 0 or sizeZ <= 0 then return nil end
    terrainSize = tonumber(terrainSize) or 2048
    local px = math.max(0, math.min(math.floor(
        ((tonumber(x) or 0) / terrainSize + 0.5) * sizeX),
        sizeX - 1))
    local pz = math.max(0, math.min(math.floor(
        ((tonumber(z) or 0) / terrainSize + 0.5) * sizeZ),
        sizeZ - 1))
    local ok, value = pcall(getBitVectorMapPoint,
        map, px, pz, tonumber(firstChannel) or 0,
        tonumber(numChannels) or 1)
    return ok and tonumber(value) or nil
end

function TerraLogicSoilManager:getRecoveryAgeAtWorldPosition(x, z)
    local raw = getRawMapPointAtWorldPosition(
        self.recoveryAgeMap, 0, RECOVERY_AGE_CHANNELS,
        self.terrainSize, x, z) or 0
    if raw > 0 then
        return math.clamp((raw - 1) / RECOVERY_AGE_SCALE,
            0, self.RECOVERY_AGE_MAX)
    end
    return math.clamp(getRawMapPointAtWorldPosition(
        self.recoveryAgeLegacyMap, 0, 4, self.terrainSize, x, z) or 0,
        0, self.RECOVERY_AGE_MAX)
end

function TerraLogicSoilManager:setRecoveryAgeCell(ix, iz, age)
    if self.recoveryAgeModifier == nil then return false end
    local cellSize = self.RECOVERY_CELL_SIZE
    if not self:setModifierToWorldRegion(self.recoveryAgeModifier,
            ix * cellSize, iz * cellSize, cellSize) then return false end
    self.recoveryAgeModifier:executeSet(1 + math.floor(math.clamp(
        tonumber(age) or 0, 0, self.RECOVERY_AGE_MAX) * RECOVERY_AGE_SCALE + 0.5))
    self.dirty = true
    return true
end

function TerraLogicSoilManager:getGroundTypeAtWorldPosition(x, z)
    local mission = g_currentMission
    if mission == nil or mission.fieldGroundSystem == nil
        or FieldDensityMap == nil or FieldDensityMap.GROUND_TYPE == nil then
        return nil
    end
    local data = self.groundTypeDensityData
    if data == nil or data.system ~= mission.fieldGroundSystem then
        local ok, mapId, firstChannel, numChannels = pcall(
            mission.fieldGroundSystem.getDensityMapData,
            mission.fieldGroundSystem, FieldDensityMap.GROUND_TYPE)
        if not ok or mapId == nil or mapId == 0 then return nil end
        data = {
            system=mission.fieldGroundSystem,
            mapId=mapId,
            firstChannel=math.max(
                math.floor(tonumber(firstChannel) or 0), 0),
            numChannels=math.max(
                math.floor(tonumber(numChannels) or 0), 0),
            terrainNode=getTerrainDataNode()
        }
        self.groundTypeDensityData = data
    end
    local mapId = data.mapId
    local firstChannel = data.firstChannel
    local numChannels = data.numChannels
    if mapId == nil or mapId == 0
        or getDensityAtWorldPos == nil or bit32 == nil then return nil end
    -- GROUND_TYPE is a terrain density map, not a BitVectorMap. Query its
    -- packed channels exactly like the base game's WheelPhysics does.
    local terrainY = 0
    local terrainNode = data.terrainNode
    if terrainNode == nil then
        terrainNode = getTerrainDataNode()
        data.terrainNode = terrainNode
    end
    if terrainNode ~= nil and getTerrainHeightAtWorldPos ~= nil then
        local heightOk, height = pcall(
            getTerrainHeightAtWorldPos, terrainNode, x, 0, z)
        if heightOk and tonumber(height) ~= nil then terrainY = height end
    end
    local densityOk, densityBits = pcall(
        getDensityAtWorldPos, mapId, x, terrainY, z)
    if not densityOk or tonumber(densityBits) == nil
        or numChannels <= 0 then return nil end
    local mask = 2 ^ numChannels - 1
    return bit32.band(bit32.rshift(
        math.floor(tonumber(densityBits)), firstChannel), mask)
end

function TerraLogicSoilManager:getGroundCoverSets()
    if self.recoveryGroundCoverSets ~= nil then
        return self.recoveryGroundCoverSets
    end
    local sets = {residue={}, sown={}}
    local function add(target, names)
        if FieldGroundType == nil or FieldGroundType.getValueByType == nil then
            return
        end
        for _, name in ipairs(names) do
            local typeId = FieldGroundType[name]
            if typeId ~= nil then
                local ok, value = pcall(
                    FieldGroundType.getValueByType, typeId)
                if ok and value ~= nil then target[tonumber(value)] = true end
            end
        end
    end
    add(sets.residue, {
        "STUBBLE_TILLAGE", "GRASS_CUT", "MULCHED", "HARVESTED"
    })
    add(sets.sown, {"SOWN", "DIRECT_SOWN"})
    self.recoveryGroundCoverSets = sets
    return sets
end

-- Build a semantic state map from the live FruitTypeDesc instead of assuming
-- that every state whose name contains "harvested" is terminal. FS25 spinach,
-- for example, regrows from its first harvested state but not from the second.
-- The growth XML is read once per fruit type to identify cut states which have
-- a genuine future transition back into a living state. This also supports
-- mod fruits without hard-coding SPINACH or a fixed number of harvests.
function TerraLogicSoilManager:getRecoveryFruitStateInfo(fruitTypeIndex)
    fruitTypeIndex = tonumber(fruitTypeIndex)
    self.recoveryFruitStateInfoCache = self.recoveryFruitStateInfoCache or {}
    local cached = self.recoveryFruitStateInfoCache[fruitTypeIndex]
    if cached ~= nil then return cached end
    local info = {withered={}, cut={}, regrowthSources={}}
    local desc = fruitTypeIndex ~= nil and g_fruitTypeManager ~= nil
        and g_fruitTypeManager:getFruitTypeByIndex(fruitTypeIndex) or nil
    if desc == nil then
        self.recoveryFruitStateInfoCache[fruitTypeIndex or 0] = info
        return info
    end

    for state, name in pairs(desc.growthStateToName or {}) do
        state = tonumber(state)
        local normalized = normalizeCropName(name)
        if state ~= nil then
            local isWithered = false
            if desc.getIsWithered ~= nil then
                local ok, result = pcall(desc.getIsWithered, desc, state)
                isWithered = ok and result == true
            end
            if not isWithered and tonumber(desc.witheredState) == state then
                isWithered = true
            end
            if not isWithered and containsAny(
                    normalized, {"withered", "dead"}) then
                isWithered = true
            end
            info.withered[state] = isWithered

            local isCut = false
            if desc.getIsCut ~= nil then
                local ok, result = pcall(desc.getIsCut, desc, state)
                isCut = ok and result == true
            end
            if not isCut and desc.cutStates ~= nil
                    and desc.cutStates[state] == true then
                isCut = true
            end
            if not isCut and containsAny(
                    normalized, {"harvested", "cut"}) then
                isCut = true
            end
            info.cut[state] = isCut
        end
    end

    local function getStateByName(name)
        if name == nil then return nil end
        if desc.getGrowthStateByName ~= nil then
            local ok, state = pcall(desc.getGrowthStateByName, desc, name)
            if ok and tonumber(state) ~= nil then return tonumber(state) end
        end
        return desc.nameToGrowthState ~= nil
            and tonumber(desc.nameToGrowthState[string.upper(name)]) or nil
    end
    local filename = desc.xmlFilename
    if filename ~= nil and XMLFile ~= nil
            and XMLFile.loadIfExists ~= nil then
        local ok, xml = pcall(
            XMLFile.loadIfExists, "terraLogicRecoveryFruit", filename)
        if ok and xml ~= nil then
            local function inspectUpdate(_, key)
                local sourceState = getStateByName(
                    xml:getString(key .. "#startState"))
                local targetState = getStateByName(
                    xml:getString(key .. "#endState"))
                if sourceState ~= nil and targetState ~= nil
                        and info.withered[targetState] ~= true
                        and info.cut[targetState] ~= true then
                    info.regrowthSources[sourceState] = true
                end
            end
            pcall(function()
                xml:iterate("foliageType.growth.seasonal.period",
                    function(_, periodKey)
                        xml:iterate(periodKey .. ".update", inspectUpdate)
                    end)
                xml:iterate("foliageType.growth.nonSeasonal.update",
                    inspectUpdate)
            end)
            xml:delete()
        end
    end
    self.recoveryFruitStateInfoCache[fruitTypeIndex] = info
    return info
end

function TerraLogicSoilManager:getRecoveryCoverAtWorldPosition(x, z)
    local fruitTypeIndex, growthState = nil, nil
    if FSDensityMapUtil ~= nil
        and FSDensityMapUtil.getFruitTypeIndexAtWorldPos ~= nil then
        local ok, fruit, state = pcall(
            FSDensityMapUtil.getFruitTypeIndexAtWorldPos, x, z)
        if ok then
            fruitTypeIndex, growthState = tonumber(fruit), tonumber(state)
        end
    end
    if fruitTypeIndex ~= nil and (FruitType == nil
        or FruitType.UNKNOWN == nil or fruitTypeIndex ~= FruitType.UNKNOWN) then
        local group, cropName = self:getCropGroup(fruitTypeIndex)
        local livingCover = "annual"
        if group == CROP_GROUP.PERENNIAL then
            livingCover = containsAny(cropName, {"alfalfa", "clover"})
                and "deepPerennial" or "perennial"
        elseif group == CROP_GROUP.ROOT then
            livingCover = containsAny(cropName,
                {"sugarbeet", "beetroot", "carrot", "parsnip"})
                and "deepRoot" or "rootCrop"
        elseif DEEP_ROOT_GROUP[group] then
            livingCover = "deepRoot"
        end
        local desc = g_fruitTypeManager ~= nil
            and g_fruitTypeManager:getFruitTypeByIndex(fruitTypeIndex) or nil
        local stateName = desc ~= nil and desc.growthStateToName ~= nil
            and desc.growthStateToName[growthState] or ""
        stateName = normalizeCropName(stateName)
        local stateInfo = self:getRecoveryFruitStateInfo(fruitTypeIndex)
        if growthState ~= nil
                and stateInfo.withered[growthState] == true then
            return "residue"
        end
        if containsAny(stateName,
                {"invisible", "seed", "germinat"}) then
            return "sown"
        end
        -- A cut perennial remains a living stand (grass regrowth), whereas a
        -- cut annual is residue unless its loaded growth graph proves another
        -- living growth phase. This keeps two-cut spinach annual and living
        -- after harvest one, but residue after its terminal second harvest.
        if group == CROP_GROUP.PERENNIAL then return livingCover end
        if growthState ~= nil and stateInfo.cut[growthState] == true then
            if stateInfo.regrowthSources[growthState] == true then
                return livingCover
            end
            return "residue"
        end
        return livingCover
    end
    local groundType = self:getGroundTypeAtWorldPosition(x, z)
    local sets = self:getGroundCoverSets()
    if groundType ~= nil and sets.residue[groundType] then return "residue" end
    if groundType ~= nil and sets.sown[groundType] then return "sown" end
    return "bare"
end

function TerraLogicSoilManager:getRecoveryMoistureFactor(x, z)
    if TerraLogicSoilMoistureManager == nil then return 1 end
    local moisture = TerraLogicSoilMoistureManager:getStateAtWorldPosition(x, z)
    local value = clamp01((moisture.surface * 0.35)
        + (moisture.subsoil * 0.65))
    local dryActivity = smoothStep01((value - 0.12) / 0.38)
    local waterlogging = smoothStep01((value - 0.82) / 0.16)
    return math.clamp(0.40 + 0.75 * dryActivity
        - 0.30 * waterlogging, 0.35, 1.15)
end

function TerraLogicSoilManager:getRecoveryEnvironmentFactors(
        x, z, soilTypeIndex, temperatureOverride)
    local moisture = {surface=0.50, subsoil=0.55, profileName="Generic"}
    if TerraLogicSoilMoistureManager ~= nil then
        if soilTypeIndex ~= nil then
            local surface, subsoil, _, profile =
                TerraLogicSoilMoistureManager:getProfileState(soilTypeIndex)
            moisture = {surface=surface, subsoil=subsoil,
                profileName=profile.name}
        else
            moisture = TerraLogicSoilMoistureManager:
                getStateAtWorldPosition(x, z)
        end
    end
    -- Inline the public moisture response here so a full monthly raster scan
    -- performs only one PF texture lookup per 8 m recovery cell.
    local rootMoisture = clamp01((moisture.surface * 0.35)
        + (moisture.subsoil * 0.65))
    local dryActivity = smoothStep01((rootMoisture - 0.12) / 0.38)
    local waterlogging = smoothStep01((rootMoisture - 0.82) / 0.16)
    local moistureFactor = math.clamp(0.40 + 0.75 * dryActivity
        - 0.30 * waterlogging, 0.35, 1.15)
    local temperature = temperatureOverride
        or (TerraLogicSoilTemperatureManager ~= nil
        and TerraLogicSoilTemperatureManager:getState() or nil
        )
    local surfaceTemperature = temperature ~= nil
        and tonumber(temperature.surfaceTemperatureC) or 10
    local subsoilTemperature = temperature ~= nil
        and tonumber(temperature.subsoilTemperatureC) or 10
    local biologicalTemperature = surfaceTemperature * 0.45
        + subsoilTemperature * 0.55
    local warmth = smoothStep01((biologicalTemperature - 1.5) / 14.5)
    local heatStress = 1 - 0.45
        * smoothStep01((biologicalTemperature - 28) / 12)
    local biological = math.clamp(
        moistureFactor * warmth * heatStress, 0.02, 1.15)

    -- Frost is accumulated by the temperature manager, but acts exactly once
    -- after a hysteretic thaw transition. Moist soil transmits the effect;
    -- dry freezing no longer creates fictitious monthly loosening.
    local surfaceFrostMoisture = smoothStep01(
        ((tonumber(moisture.surface) or 0.5) - 0.18) / 0.42)
    local deepFrostMoisture = smoothStep01(
        ((tonumber(moisture.subsoil) or 0.55) - 0.22) / 0.43)
    local surfaceThawPulse = math.max(tonumber(temperature ~= nil
        and (temperature.freezeThawSurfacePulse
            or temperature.pendingSurfaceThawPulse)) or 0, 0)
    local deepThawPulse = math.max(tonumber(temperature ~= nil
        and (temperature.freezeThawDeepPulse
            or temperature.pendingDeepThawPulse)) or 0, 0)
    local surfaceFrost = surfaceThawPulse * surfaceFrostMoisture
    local deepFrost = deepThawPulse * deepFrostMoisture
    local physicalSurface = math.clamp(
        moistureFactor * (0.32 + 0.68 * warmth)
            + 0.38 * surfaceFrost, 0.20, 1.35)
    local physicalDeep = math.clamp(
        moistureFactor * (0.45 + 0.55 * warmth)
            + 0.16 * deepFrost, 0.25, 1.20)
    return {
        moistureFactor=moistureFactor,
        biologicalFactor=biological,
        physicalSurfaceFactor=physicalSurface,
        physicalDeepFactor=physicalDeep,
        surfaceFrostFactor=surfaceFrost,
        deepFrostFactor=deepFrost,
        surfaceThawPulse=surfaceThawPulse,
        deepThawPulse=deepThawPulse,
        surfaceTemperatureC=surfaceTemperature,
        subsoilTemperatureC=subsoilTemperature,
        surfaceMoisture=tonumber(moisture.surface) or 0.5,
        subsoilMoisture=tonumber(moisture.subsoil) or 0.55,
        moistureProfileName=moisture.profileName or "Generic"
    }
end

-- Integrate recovery suitability with actual elapsed game hours. A one-day
-- month therefore contributes 24 representative hours and a 28-day month
-- contributes 672, but both still produce one calendar-month recovery pass.
-- This removes the former midnight-temperature bias without changing the
-- selected 1x/4x/8x biological rate.
function TerraLogicSoilManager:updateRecoveryEnvironmentAccumulator()
    local mission = g_currentMission
    local temperatureManager = TerraLogicSoilTemperatureManager
    if mission == nil or not mission:getIsServer()
        or temperatureManager == nil
        or temperatureManager.initialized ~= true then return end
    local currentHours = math.max(
        tonumber(temperatureManager.simulatedGameHours) or 0, 0)
    local previousHours = tonumber(self.recoveryLastIntegratedGameHours)
    self.recoveryLastIntegratedGameHours = currentHours
    if previousHours == nil or currentHours < previousHours then return end
    local elapsedHours = currentHours - previousHours
    if elapsedHours <= 0 then return end

    local accumulator = self.recoveryEnvironmentAccumulator
        or newRecoveryAccumulator()
    self.recoveryEnvironmentAccumulator = accumulator
    local temperature = temperatureManager:getState()
    -- Thaw pulses are discrete events assigned to the month snapshot below;
    -- they must not be averaged into every frame after the thaw occurred.
    local temperatureWithoutPulse = {}
    for key, value in pairs(temperature) do
        temperatureWithoutPulse[key] = value
    end
    temperatureWithoutPulse.freezeThawSurfacePulse = 0
    temperatureWithoutPulse.freezeThawDeepPulse = 0
    temperatureWithoutPulse.pendingSurfaceThawPulse = 0
    temperatureWithoutPulse.pendingDeepThawPulse = 0

    accumulator.hours = (accumulator.hours or 0) + elapsedHours
    accumulator.surfaceTemperatureSum =
        (accumulator.surfaceTemperatureSum or 0)
        + (tonumber(temperature.surfaceTemperatureC) or 10) * elapsedHours
    accumulator.subsoilTemperatureSum =
        (accumulator.subsoilTemperatureSum or 0)
        + (tonumber(temperature.subsoilTemperatureC) or 10) * elapsedHours
    accumulator.airTemperatureSum =
        (accumulator.airTemperatureSum or 0)
        + (tonumber(temperature.airTemperatureC) or 10) * elapsedHours
    accumulator.daysPerPeriod = tonumber(temperature.daysPerPeriod) or 1
    accumulator.calendarScale = tonumber(temperature.calendarScale) or 1

    for _, profileIndex in ipairs(getRecoveryProfileOrder()) do
        local environment = self:getRecoveryEnvironmentFactors(
            0, 0, profileIndex, temperatureWithoutPulse)
        local sums = accumulator.profiles[profileIndex]
        if sums == nil then
            sums = {hours=0, moistureFactor=0, biologicalFactor=0,
                physicalSurfaceFactor=0, physicalDeepFactor=0,
                surfaceMoisture=0, subsoilMoisture=0}
            accumulator.profiles[profileIndex] = sums
        end
        sums.hours = sums.hours + elapsedHours
        for _, name in ipairs({"moistureFactor", "biologicalFactor",
                "physicalSurfaceFactor", "physicalDeepFactor",
                "surfaceMoisture", "subsoilMoisture"}) do
            sums[name] = (sums[name] or 0)
                + (tonumber(environment[name]) or 0) * elapsedHours
        end
    end
end

function TerraLogicSoilManager:createRecoveryEnvironmentSnapshot()
    local accumulator = self.recoveryEnvironmentAccumulator
        or newRecoveryAccumulator()
    local hours = math.max(tonumber(accumulator.hours) or 0, 0)
    local temperature = TerraLogicSoilTemperatureManager ~= nil
        and TerraLogicSoilTemperatureManager:getState() or {}
    local surfacePulse, deepPulse = 0, 0
    if TerraLogicSoilTemperatureManager ~= nil
        and TerraLogicSoilTemperatureManager.consumeFreezeThawPulses
            ~= nil then
        surfacePulse, deepPulse =
            TerraLogicSoilTemperatureManager:consumeFreezeThawPulses()
    end
    self.recoveryCompletedPeriods =
        (tonumber(self.recoveryCompletedPeriods) or 0) + 1
    local snapshot = {
        version=self.RECOVERY_SNAPSHOT_VERSION,
        serial=self.recoveryCompletedPeriods,
        hours=hours,
        daysPerPeriod=tonumber(accumulator.daysPerPeriod)
            or tonumber(temperature.daysPerPeriod) or 1,
        calendarScale=tonumber(accumulator.calendarScale)
            or tonumber(temperature.calendarScale) or 1,
        developmentSpeed=getSoilDevelopmentSpeed(),
        surfaceTemperatureC=hours > 0
            and (accumulator.surfaceTemperatureSum or 0) / hours
            or tonumber(temperature.dailyMeanTemperatureC)
            or tonumber(temperature.surfaceTemperatureC) or 10,
        subsoilTemperatureC=hours > 0
            and (accumulator.subsoilTemperatureSum or 0) / hours
            or tonumber(temperature.subsoilTemperatureC) or 10,
        airTemperatureC=hours > 0
            and (accumulator.airTemperatureSum or 0) / hours
            or tonumber(temperature.dailyMeanTemperatureC)
            or tonumber(temperature.airTemperatureC) or 10,
        surfaceThawPulse=math.max(tonumber(surfacePulse) or 0, 0),
        deepThawPulse=math.max(tonumber(deepPulse) or 0, 0),
        profiles={}, source=hours > 0 and "periodAverage" or "dailyMeanFallback"
    }
    for _, profileIndex in ipairs(getRecoveryProfileOrder()) do
        local sums = accumulator.profiles[profileIndex]
        local sampleHours = sums ~= nil
            and math.max(tonumber(sums.hours) or 0, 0) or 0
        if sampleHours > 0 then
            snapshot.profiles[profileIndex] = {}
            for _, name in ipairs({"moistureFactor", "biologicalFactor",
                    "physicalSurfaceFactor", "physicalDeepFactor",
                    "surfaceMoisture", "subsoilMoisture"}) do
                snapshot.profiles[profileIndex][name] =
                    (tonumber(sums[name]) or 0) / sampleHours
            end
        else
            local noPulse = {}
            for key, value in pairs(temperature) do noPulse[key] = value end
            noPulse.pendingSurfaceThawPulse = 0
            noPulse.pendingDeepThawPulse = 0
            local environment = self:getRecoveryEnvironmentFactors(
                0, 0, profileIndex, noPulse)
            snapshot.profiles[profileIndex] = environment
        end
    end
    self.recoveryEnvironmentAccumulator = newRecoveryAccumulator()
    self.recoveryLastSnapshot = snapshot
    return snapshot
end

function TerraLogicSoilManager:getRecoveryEnvironmentFromSnapshot(
        snapshot, soilTypeIndex)
    if snapshot == nil or snapshot.profiles == nil then return nil end
    local index = tonumber(soilTypeIndex)
    local stored = index ~= nil and snapshot.profiles[index] or nil
    stored = stored
        or snapshot.profiles[0] or snapshot.profiles[2]
    if stored == nil then return nil end
    local surfaceMoisture = tonumber(stored.surfaceMoisture) or 0.5
    local subsoilMoisture = tonumber(stored.subsoilMoisture) or 0.55
    local surfaceFrost = math.max(
        tonumber(snapshot.surfaceThawPulse) or 0, 0)
        * smoothStep01((surfaceMoisture - 0.18) / 0.42)
    local deepFrost = math.max(
        tonumber(snapshot.deepThawPulse) or 0, 0)
        * smoothStep01((subsoilMoisture - 0.22) / 0.43)
    return {
        moistureFactor=tonumber(stored.moistureFactor) or 1,
        biologicalFactor=tonumber(stored.biologicalFactor) or 1,
        physicalSurfaceFactor=math.clamp(
            (tonumber(stored.physicalSurfaceFactor) or 1)
                + 0.38 * surfaceFrost, 0.20, 1.35),
        physicalDeepFactor=math.clamp(
            (tonumber(stored.physicalDeepFactor) or 1)
                + 0.16 * deepFrost, 0.25, 1.20),
        surfaceFrostFactor=surfaceFrost,
        deepFrostFactor=deepFrost,
        surfaceThawPulse=tonumber(snapshot.surfaceThawPulse) or 0,
        deepThawPulse=tonumber(snapshot.deepThawPulse) or 0,
        surfaceTemperatureC=tonumber(snapshot.surfaceTemperatureC) or 10,
        subsoilTemperatureC=tonumber(snapshot.subsoilTemperatureC) or 10,
        surfaceMoisture=surfaceMoisture,
        subsoilMoisture=subsoilMoisture,
        moistureProfileName=tostring(stored.profileName or index or "Generic")
    }
end

function TerraLogicSoilManager:getNaturalRecoveryDebugAtWorldPosition(x, z)
    local age = self:getRecoveryAgeAtWorldPosition(x, z)
    local coverKey = self:getRecoveryCoverAtWorldPosition(x, z)
    local cover = RECOVERY_COVER[coverKey] or RECOVERY_COVER.bare
    local speed = getSoilDevelopmentSpeed()
    local soilTypeIndex = self:getPFSoilTypeAtWorldPosition(x, z)
    local environment = self:getRecoveryEnvironmentFactors(
        x, z, soilTypeIndex)
    local snapshot = self.recoveryJob ~= nil
        and self.recoveryJob.snapshot or self.recoveryLastSnapshot
    return {
        ageMonths=age,
        ageMature=age >= self.RECOVERY_AGE_MAX,
        coverKey=coverKey,
        developmentSpeed=speed,
        resilienceDevelopmentSpeed=getResilienceDevelopmentSpeed(speed),
        physicalDevelopmentSpeed=PHYSICAL_DEVELOPMENT_SPEED,
        restFactor=getBiologicalContinuityFromAge(age),
        surfaceTarget=cover.surfaceTarget,
        deepTarget=cover.deepTarget,
        resilienceCeiling=cover.resilienceCeiling,
        tilthTarget=cover.tilthTarget,
        settlingTarget=cover.settlingTarget,
        settlementCompactionFloor=cover.settlementCompactionFloor,
        biologicalFactor=environment.biologicalFactor,
        physicalSurfaceFactor=environment.physicalSurfaceFactor,
        physicalDeepFactor=environment.physicalDeepFactor,
        surfaceFrostFactor=environment.surfaceFrostFactor,
        deepFrostFactor=environment.deepFrostFactor,
        surfaceThawPulse=environment.surfaceThawPulse,
        deepThawPulse=environment.deepThawPulse,
        moistureFactor=environment.moistureFactor,
        surfaceTemperatureC=environment.surfaceTemperatureC,
        subsoilTemperatureC=environment.subsoilTemperatureC,
        surfaceMoisture=environment.surfaceMoisture,
        subsoilMoisture=environment.subsoilMoisture,
        moistureProfileName=environment.moistureProfileName,
        completedPeriods=tonumber(self.recoveryCompletedPeriods) or 0,
        pendingPeriods=#(self.recoverySnapshotQueue or {}),
        recoveryRunning=self.recoveryJob ~= nil,
        accumulatorHours=tonumber(
            self.recoveryEnvironmentAccumulator ~= nil
                and self.recoveryEnvironmentAccumulator.hours) or 0,
        snapshotHours=tonumber(snapshot ~= nil and snapshot.hours) or 0,
        snapshotDaysPerPeriod=tonumber(
            snapshot ~= nil and snapshot.daysPerPeriod) or 0,
        snapshotDevelopmentSpeed=tonumber(
            snapshot ~= nil and snapshot.developmentSpeed) or 0,
        snapshotSurfaceTemperatureC=tonumber(
            snapshot ~= nil and snapshot.surfaceTemperatureC) or 0,
        snapshotSubsoilTemperatureC=tonumber(
            snapshot ~= nil and snapshot.subsoilTemperatureC) or 0,
        snapshotSource=snapshot ~= nil and snapshot.source or "none"
    }
end

-- Player-facing representation of the uninterrupted biological structure.
-- Resilience is the accumulated condition; continuity controls how efficiently
-- current cover and roots can continue rebuilding it after a disturbance.
function TerraLogicSoilManager:getBiologicalContinuityAtWorldPosition(x, z)
    return getBiologicalContinuityFromAge(
        self:getRecoveryAgeAtWorldPosition(x, z))
end

local function recoveryRandom(ix, iz, serial, salt)
    local value = (ix * 73856093 + iz * 19349663
        + (tonumber(serial) or 0) * 83492791
        + (tonumber(salt) or 0) * 2654435761) % 104729
    return value / 104729
end

function TerraLogicSoilManager:applyRecoveryStepToBlock(
        layerId, recoveryIx, recoveryIz, target, direction, stepCount)
    local layerCellSize = getLayerCellSize(layerId)
    local cellsPerSide = math.max(math.floor(
        self.RECOVERY_CELL_SIZE / layerCellSize + 0.5), 1)
    local startIx = recoveryIx * cellsPerSide
    local startIz = recoveryIz * cellsPerSide
    local step = 1 / math.max(2 ^ getLayerChannels(layerId) - 2, 1)
    stepCount = math.max(math.floor(tonumber(stepCount) or 1), 1)
    local movement = step * stepCount
    local changed = 0
    for localZ=0,cellsPerSide-1 do
        for localX=0,cellsPerSide-1 do
            local ix, iz = startIx + localX, startIz + localZ
            local x = (ix + 0.5) * layerCellSize
            local z = (iz + 0.5) * layerCellSize
            local current = self:getValueAtWorldPosition(layerId, x, z)
            local nextValue = current
            if direction < 0 and current > target + step * 0.25 then
                nextValue = math.max(current - movement, target)
            elseif direction > 0 and current < target - step * 0.25 then
                nextValue = math.min(current + movement, target)
            end
            if math.abs(nextValue - current) > 0.0001 then
                self:setStateCell(layerId, ix, iz, nextValue)
                changed = changed + 1
            end
        end
    end
    return changed
end

local function getRecoveryStepCount(expectedDelta, quantStep, randomValue)
    local expectedSteps = math.max(tonumber(expectedDelta) or 0, 0)
        / math.max(tonumber(quantStep) or 0, 0.000001)
    local whole = math.floor(expectedSteps)
    if (tonumber(randomValue) or 1) < expectedSteps - whole then
        whole = whole + 1
    end
    return whole
end

function TerraLogicSoilManager:processNaturalRecoveryCell(job, index)
    if g_server == nil then return end
    local size = job.size
    local half = math.floor(size / 2)
    local recoveryIx = index % size - half
    local recoveryIz = math.floor(index / size) - half
    local x = (recoveryIx + 0.5) * self.RECOVERY_CELL_SIZE
    local z = (recoveryIz + 0.5) * self.RECOVERY_CELL_SIZE
    local surface = TerraLogicQualityManager ~= nil
        and TerraLogicQualityManager:getSurfaceTypeAtWorldPosition(x, z) or nil
    if surface ~= "field" and surface ~= "grassField" then return end
    job.fieldCells = job.fieldCells + 1

    local age = self:getRecoveryAgeAtWorldPosition(x, z)
    local nextAge = math.min(age + 1, self.RECOVERY_AGE_MAX)
    if nextAge ~= age and self:setRecoveryAgeCell(
            recoveryIx, recoveryIz, nextAge) then
        job.ageChanges = job.ageChanges + 1
    end
    age = nextAge
    local coverKey = self:getRecoveryCoverAtWorldPosition(x, z)
    local cover = RECOVERY_COVER[coverKey] or RECOVERY_COVER.bare
    job.coverCounts[coverKey] = (job.coverCounts[coverKey] or 0) + 1
    local soilTypeIndex = self:getPFSoilTypeAtWorldPosition(x, z)
    local texture = RECOVERY_TEXTURE[soilTypeIndex] or RECOVERY_TEXTURE[2]
    local developmentSpeed = tonumber(job.developmentSpeed)
        or getSoilDevelopmentSpeed()
    local resilienceDevelopmentSpeed = getResilienceDevelopmentSpeed(
        developmentSpeed)
    local restFactor = getBiologicalContinuityFromAge(age)
    local environment = self:getRecoveryEnvironmentFromSnapshot(
        job.snapshot, soilTypeIndex)
    if environment == nil then
        -- Compatibility fallback for a v78 job resumed without a persisted
        -- snapshot. New v79 passes never use an instantaneous month value.
        environment = self:getRecoveryEnvironmentFactors(
            x, z, soilTypeIndex, nil)
    end
    job.biologicalFactorSum = job.biologicalFactorSum
        + environment.biologicalFactor
    job.physicalSurfaceFactorSum = job.physicalSurfaceFactorSum
        + environment.physicalSurfaceFactor
    job.physicalDeepFactorSum = job.physicalDeepFactorSum
        + environment.physicalDeepFactor
    job.surfaceFrostFactorSum = job.surfaceFrostFactorSum
        + environment.surfaceFrostFactor
    job.deepFrostFactorSum = job.deepFrostFactorSum
        + environment.deepFrostFactor
    job.environmentSamples = job.environmentSamples + 1
    local state = self:getStateAtWorldPosition(x, z)

    local function tryMove(layerId, target, direction, baseRate,
            environmentFactor, textureFactor, activity, salt,
            severityExponent)
        local current = clamp01(state[layerId])
        if direction == nil or direction == 0 then
            direction = current < target and 1 or -1
        end
        if (direction < 0 and current <= target)
            or (direction > 0 and current >= target) then return 0 end
        local accessibility = 1
        if severityExponent ~= nil then
            accessibility = 0.20 + 0.80
                * (1 - current) ^ severityExponent
        end
        local processStrength = scaleEnvironmentalStrength(
            baseRate, environmentFactor, PHYSICAL_DEVELOPMENT_SPEED)
        local expectedDelta = math.abs(current - target)
            * processStrength * (tonumber(activity) or 1) * restFactor
            * (tonumber(textureFactor) or 1) * accessibility
        local quantStep = 1 / math.max(
            2 ^ getLayerChannels(layerId) - 2, 1)
        local steps = getRecoveryStepCount(expectedDelta, quantStep,
            recoveryRandom(recoveryIx, recoveryIz, job.serial, salt))
        if steps <= 0 then return 0 end
        local changed = self:applyRecoveryStepToBlock(
            layerId, recoveryIx, recoveryIz, target, direction, steps)
        job[layerId .. "Changes"] = job[layerId .. "Changes"] + changed
        return changed
    end
    local surfaceRecoveryFactor = environment.physicalSurfaceFactor
        * (0.55 + 0.45 * environment.biologicalFactor)
    local deepRecoveryFactor = environment.physicalDeepFactor
        * (0.35 + 0.65 * environment.biologicalFactor)
    -- Only established living cover earns extra biological deep recovery.
    -- Bare soil/residue and the separate frost process retain their rates.
    local livingCover = coverKey == "annual" or coverKey == "rootCrop"
        or coverKey == "deepRoot" or coverKey == "perennial"
        or coverKey == "deepPerennial"
    local deepBiologyBoost = livingCover
        and (1 + 0.50 * restFactor * clamp01(environment.biologicalFactor)) or 1
    -- Established, undisturbed living cover strengthens monthly recovery.
    -- Keep root-growth events, targets and bare/residue recovery unchanged.
    local surfaceRecoveryBoost = livingCover and (1 + 0.25 * restFactor) or 1
    local deepRecoveryBoost = livingCover and (1 + 0.35 * restFactor) or 1
    tryMove("surfaceCompaction", cover.surfaceTarget, -1, 0.0060,
        surfaceRecoveryFactor, texture.surface,
        cover.activity * surfaceRecoveryBoost, 11, 1.20)
    tryMove("deepCompaction", cover.deepTarget, -1, 0.0018,
        deepRecoveryFactor, texture.deep,
        cover.activity * deepBiologyBoost * deepRecoveryBoost, 23, 1.60)

    -- Covered soil can slowly rebuild an intermediate crumb structure from
    -- either coarse clods or an over-pulverized state. Bare soil receives only
    -- physical fragmentation of very coarse clods; very wet unprotected soil
    -- may instead slake toward a fine/sealed state.
    local aggregate = clamp01(state.aggregateSize)
    local tilthEnvironment = environment.physicalSurfaceFactor
        * (coverKey == "bare" and 1
            or (0.35 + 0.65 * environment.biologicalFactor))
    if cover.tilthTarget ~= nil then
        tryMove("aggregateSize", cover.tilthTarget, 0, 0.0045,
            tilthEnvironment, texture.tilth,
            cover.tilthActivity, 41)
    elseif aggregate < 0.38 then
        tryMove("aggregateSize", 0.38, 1, 0.0030,
            environment.physicalSurfaceFactor, texture.tilth,
            cover.tilthActivity, 43)
    elseif aggregate > 0.62 then
        local slaking = smoothStep01(
            (environment.surfaceMoisture - 0.78) / 0.18)
            * (1 - (cover.protection or 0))
        if slaking > 0 then
            tryMove("aggregateSize", 0.78, 1, 0.0025,
                slaking, texture.tilth, 1, 47)
        end
    end

    -- Rainfall and gravity settle only pronounced roughness. This is not a
    -- free levelling pass: a small reconsolidation floor accompanies settling.
    local roughness = clamp01(state.roughness)
    local settlingSeverity = smoothStep01(
        (roughness - cover.settlingTarget) / 0.45)
    if settlingSeverity > 0 then
        local settlingEnvironment = environment.physicalSurfaceFactor
            * (0.70 + 0.30 * environment.surfaceMoisture)
        tryMove("roughness", cover.settlingTarget, -1, 0.0120,
            settlingEnvironment, texture.settling,
            cover.settlingActivity, 53)
        tryMove("surfaceCompaction", cover.settlementCompactionFloor,
            1, 0.0018, settlingEnvironment * settlingSeverity,
            texture.surface, cover.settlingActivity, 59)
    end

    local resilience = clamp01(state.resilience)
    local resilienceTarget, direction, rate
    if resilience < cover.resilienceCeiling then
        resilienceTarget, direction, rate = cover.resilienceCeiling, 1,
            cover.resilienceRate
    elseif cover.resilienceDecay ~= nil
        and resilience > cover.resilienceCeiling then
        resilienceTarget, direction, rate = cover.resilienceCeiling, -1,
            cover.resilienceDecay
    end
    if direction ~= nil and rate ~= nil and rate > 0 then
        local expectedDelta = math.abs(resilienceTarget - resilience)
            * scaleEnvironmentalStrength(rate,
                environment.biologicalFactor, resilienceDevelopmentSpeed)
            * restFactor * texture.resilience
        local quantStep = 1 / 254
        local steps = getRecoveryStepCount(expectedDelta, quantStep,
            recoveryRandom(recoveryIx, recoveryIz, job.serial, 37))
        if steps > 0 then
            local changed = self:applyRecoveryStepToBlock("resilience",
                recoveryIx, recoveryIz, resilienceTarget, direction, steps)
            job.resilienceChanges = job.resilienceChanges + changed
            if direction > 0 then
                job.resilienceGainCells = job.resilienceGainCells + changed
            else
                job.resilienceDecayCells = job.resilienceDecayCells + changed
            end
        end
    end
end

function TerraLogicSoilManager:createRecoveryJob(
        snapshot, startIndex, developmentSpeed)
    return {
        size=self.recoveryAgeMapSize, index=math.max(
            math.floor(tonumber(startIndex) or 0), 0),
        serial=tonumber(snapshot ~= nil and snapshot.serial)
            or (self.recoverySerial or 0),
        snapshot=snapshot,
        fieldCells=0, ageChanges=0,
        surfaceCompactionChanges=0, deepCompactionChanges=0,
        aggregateSizeChanges=0, roughnessChanges=0,
        resilienceChanges=0, resilienceGainCells=0,
        resilienceDecayCells=0, coverCounts={},
        biologicalFactorSum=0, physicalSurfaceFactorSum=0,
        physicalDeepFactorSum=0, surfaceFrostFactorSum=0,
        deepFrostFactorSum=0, environmentSamples=0,
        developmentSpeed=math.clamp(
            tonumber(developmentSpeed) or getSoilDevelopmentSpeed(), 1, 8)
    }
end

function TerraLogicSoilManager:onPeriodChanged()
    if g_currentMission == nil or not g_currentMission:getIsServer() then return end
    -- Vanilla updates NPC FieldState asynchronously after the period event.
    -- Scan only after its field-update queue has settled; unchanged semantic
    -- states retain their existing TerraLogic maps and mission scars.
    self:queueNpcPresetScan(self.NPC_PRESET_SCAN_DELAY_MS)
    -- Preserve the period that just ended. With short one-day months another
    -- transition may arrive while an earlier raster scan is still running;
    -- each queued pass therefore owns its exact temperature/moisture average.
    self.recoverySnapshotQueue = self.recoverySnapshotQueue or {}
    self.recoverySnapshotQueue[#self.recoverySnapshotQueue + 1] =
        self:createRecoveryEnvironmentSnapshot()
    self.recoveryPendingPasses = #self.recoverySnapshotQueue
    if self.recoveryJob == nil and self.recoveryPending ~= true then
        self.recoveryPending = true
        self.recoveryDelayRemaining = self.RECOVERY_DELAY_MS
    end
end

function TerraLogicSoilManager:startNaturalRecovery()
    if not self.rasterReady or self.recoveryAgeMapSize == nil then return false end
    local queue = self.recoverySnapshotQueue or {}
    if #queue <= 0 then
        self.recoveryPending = false
        self.recoveryPendingPasses = 0
        return false
    end
    local snapshot = table.remove(queue, 1)
    self.recoveryPendingPasses = #queue
    self.recoverySerial = (self.recoverySerial or 0) + 1
    self.recoveryPending = false
    self.recoveryJob = self:createRecoveryJob(
        snapshot, 0, snapshot.developmentSpeed)
    return true
end

function TerraLogicSoilManager:finishNaturalRecovery(job)
    if TerraLogicTutorialManager ~= nil then
        TerraLogicTutorialManager:observeRecovery(job)
    end
    local physicalChanges = job.surfaceCompactionChanges
        + job.deepCompactionChanges + job.aggregateSizeChanges
        + job.roughnessChanges + job.resilienceChanges
    if physicalChanges > 0 then
        self.dirty = true
        local now = g_currentMission ~= nil and g_currentMission.time or 0
        if not self.visualizationDirty then
            self.overlayRefreshTime = now + self.OVERLAY_REFRESH_DELAY_MS
        end
        self.visualizationDirty = true
    end
    local samples = math.max(job.environmentSamples or 0, 1)
    TerraLogicLogging.debug(
        "[FS25_TerraLogic] Natural recovery pass: setting=%dx resilience=%dx physical=%dx fieldCells=%d age=%d surface/deep/tilth/evenness=%d/%d/%d/%d resilience(gain/decay)=%d/%d env(bio/surface/deep/thawSurface/thawDeep)=%.3f/%.3f/%.3f/%.3f/%.3f pending=%d cover(bare/sown/residue/annual/rootCrop/deepRoot/perennial/deepPerennial)=%d/%d/%d/%d/%d/%d/%d/%d",
        job.developmentSpeed,
        getResilienceDevelopmentSpeed(job.developmentSpeed),
        PHYSICAL_DEVELOPMENT_SPEED, job.fieldCells, job.ageChanges,
        job.surfaceCompactionChanges,
        job.deepCompactionChanges, job.aggregateSizeChanges,
        job.roughnessChanges, job.resilienceGainCells,
        job.resilienceDecayCells,
        job.biologicalFactorSum / samples,
        job.physicalSurfaceFactorSum / samples,
        job.physicalDeepFactorSum / samples,
        job.surfaceFrostFactorSum / samples,
        job.deepFrostFactorSum / samples,
        #(self.recoverySnapshotQueue or {}),
        job.coverCounts.bare or 0, job.coverCounts.sown or 0,
        job.coverCounts.residue or 0, job.coverCounts.annual or 0,
        job.coverCounts.rootCrop or 0, job.coverCounts.deepRoot or 0,
        job.coverCounts.perennial or 0,
        job.coverCounts.deepPerennial or 0)
    local snapshot = job.snapshot or {}
    TerraLogicLogging.debug(
        "[FS25_TerraLogic] Recovery snapshot: serial=%d source=%s observed=%.2f gameHours daysPerPeriod=%g meanSoil=%.2f/%.2fC thaw=%.3f/%.3f queue=%d",
        tonumber(snapshot.serial) or 0, tostring(snapshot.source or "legacy"),
        tonumber(snapshot.hours) or 0,
        tonumber(snapshot.daysPerPeriod) or 0,
        tonumber(snapshot.surfaceTemperatureC) or 0,
        tonumber(snapshot.subsoilTemperatureC) or 0,
        tonumber(snapshot.surfaceThawPulse) or 0,
        tonumber(snapshot.deepThawPulse) or 0,
        #(self.recoverySnapshotQueue or {}))
    self.recoveryJob = nil
    self.recoveryPendingPasses = #(self.recoverySnapshotQueue or {})
    if self.recoveryPendingPasses > 0 then
        self.recoveryPending = true
        -- The first request keeps the density-map settling delay. Backlogged
        -- periods already occurred, so only yield briefly between full scans.
        self.recoveryDelayRemaining = 250
    end
end

function TerraLogicSoilManager:updateNaturalRecovery(dt)
    if g_currentMission == nil or not g_currentMission:getIsServer() then return end
    if self.deepMapMigration ~= nil then return end
    if self.recoveryPending then
        self.recoveryDelayRemaining = math.max(
            (self.recoveryDelayRemaining or 0) - (tonumber(dt) or 0), 0)
        local growthBusy = TerraLogicQualityManager ~= nil
            and (TerraLogicQualityManager.plowGrowthPending == true
                or TerraLogicQualityManager.plowGrowthJob ~= nil)
        if self.recoveryDelayRemaining <= 0 and not growthBusy then
            self:startNaturalRecovery()
        end
    end
    local job = self.recoveryJob
    if job == nil then return end
    local total = job.size * job.size
    local stop = math.min(job.index + self.RECOVERY_CELLS_PER_FRAME, total)
    while job.index < stop do
        self:processNaturalRecoveryCell(job, job.index)
        job.index = job.index + 1
    end
    if job.index >= total then self:finishNaturalRecovery(job) end
end

local function decodeRotationState(raw)
    raw = math.max(0, math.min(math.floor(tonumber(raw) or 0), 255))
    return raw % 8, math.floor(raw / 8) % 8,
        math.floor(raw / 64) % 4
end

local function encodeRotationState(lastGroup, currentGroup, phase)
    return math.max(0, math.min(
        (tonumber(lastGroup) or 0) % 8
        + ((tonumber(currentGroup) or 0) % 8) * 8
        + ((tonumber(phase) or 0) % 4) * 64,
        255))
end

function TerraLogicSoilManager:getRotationRawAtWorldPosition(x, z)
    local map = self.rotationMap
    if map == nil or getBitVectorMapPoint == nil then return 0 end
    local sizeX, sizeZ = getBitVectorMapSize(map)
    sizeX, sizeZ = tonumber(sizeX) or 0, tonumber(sizeZ) or tonumber(sizeX) or 0
    if sizeX <= 0 or sizeZ <= 0 then return 0 end
    local terrainSize = tonumber(self.terrainSize) or 2048
    local px = math.max(0, math.min(math.floor(
        ((tonumber(x) or 0) / terrainSize + 0.5) * sizeX),
        sizeX - 1))
    local pz = math.max(0, math.min(math.floor(
        ((tonumber(z) or 0) / terrainSize + 0.5) * sizeZ),
        sizeZ - 1))
    return tonumber(getBitVectorMapPoint(
        map, px, pz, 0, ROTATION_CHANNELS)) or 0
end

function TerraLogicSoilManager:getRotationDebugAtWorldPosition(x, z)
    local groupNames = {
        [0]="none", [1]="cereal", [2]="legume", [3]="oilseed",
        [4]="root", [5]="maize", [6]="other", [7]="perennial"
    }
    local phaseNames = {
        [ROTATION_PHASE_UNKNOWN]="unknown",
        [ROTATION_PHASE_PLANTED]="planted",
        [ROTATION_PHASE_COMPLETED]="completed"
    }
    local raw = self:getRotationRawAtWorldPosition(x, z)
    local lastGroup, currentGroup, phase = decodeRotationState(raw)
    return {raw=raw, lastGroup=lastGroup, currentGroup=currentGroup,
        phase=phase, lastGroupName=groupNames[lastGroup] or "unknown",
        currentGroupName=groupNames[currentGroup] or "unknown",
        phaseName=phaseNames[phase] or "unknown",
        diverse=lastGroup > 0 and currentGroup > 0
            and lastGroup ~= currentGroup}
end

function TerraLogicSoilManager:setRotationStateAtWorldPosition(
        x, z, lastGroup, currentGroup, phase)
    if self.rotationModifier == nil then return false end
    local cellSize = self.RESILIENCE_CELL_SIZE
    local ix = math.floor((tonumber(x) or 0) / cellSize)
    local iz = math.floor((tonumber(z) or 0) / cellSize)
    if not self:setModifierToWorldRegion(
            self.rotationModifier, ix * cellSize, iz * cellSize,
            cellSize) then return false end
    self.rotationModifier:executeSet(encodeRotationState(
        lastGroup, currentGroup, phase))
    self.dirty = true
    return true
end

function TerraLogicSoilManager:markCropSownAtWorldPosition(x, z, fruitTypeIndex)
    if g_server == nil then return false end
    local group = self:getCropGroup(fruitTypeIndex)
    if group == CROP_GROUP.NONE then return false end
    local lastGroup, currentGroup, phase = decodeRotationState(
        self:getRotationRawAtWorldPosition(x, z))
    if phase == ROTATION_PHASE_PLANTED and currentGroup == group then
        return false
    end
    return self:setRotationStateAtWorldPosition(
        x, z, lastGroup, group, ROTATION_PHASE_PLANTED)
end

function TerraLogicSoilManager:markSownQualityCells(
        positions, allowedCellKeys, fruitTypeIndex, sourceCellSize)
    if positions == nil then return 0 end
    sourceCellSize = tonumber(sourceCellSize) or 4
    local changed = 0
    for _, position in ipairs(positions) do
        local key = getCellKey(position.ix, position.iz)
        if allowedCellKeys == nil or allowedCellKeys[key] == true then
            local x = (position.ix + 0.5) * sourceCellSize
            local z = (position.iz + 0.5) * sourceCellSize
            if self:markCropSownAtWorldPosition(x, z, fruitTypeIndex) then
                changed = changed + 1
            end
        end
    end
    return changed
end

local CROP_RESILIENCE_GAIN = {
    [CROP_GROUP.CEREAL]=0.006,
    [CROP_GROUP.LEGUME]=0.014,
    [CROP_GROUP.OILSEED]=0.011,
    [CROP_GROUP.ROOT]=0.007,
    [CROP_GROUP.MAIZE]=0.007,
    [CROP_GROUP.OTHER]=0.006,
    [CROP_GROUP.PERENNIAL]=0.018
}

-- Roots act slowly and only when the game reports a real forward growth
-- transition. Total strengths describe one complete three-window crop cycle;
-- the caller converts them to equal exponential stage shares. Deep-rooting
-- oilseeds and legumes have the strongest ordinary subsoil response. Grass is
-- mainly a topsoil builder; named alfalfa/clover profiles reach deeper.
-- This is functional biological loosening, not a substitute for a subsoiler:
-- targets stop above the mechanical optimum and annual changes remain small.
local ROOT_GROWTH_RESPONSE = {
    [CROP_GROUP.CEREAL]={surface=0.014, deep=0.005,
        surfaceTarget=0.26, deepTarget=0.25,
        resilienceCeiling=0.62, tilth=0.008},
    [CROP_GROUP.LEGUME]={surface=0.024, deep=0.016,
        surfaceTarget=0.22, deepTarget=0.19,
        resilienceCeiling=0.75, tilth=0.014},
    [CROP_GROUP.OILSEED]={surface=0.020, deep=0.020,
        surfaceTarget=0.23, deepTarget=0.18,
        resilienceCeiling=0.72, tilth=0.012},
    [CROP_GROUP.ROOT]={surface=0.016, deep=0.009,
        surfaceTarget=0.24, deepTarget=0.23,
        resilienceCeiling=0.66, tilth=0.010},
    [CROP_GROUP.MAIZE]={surface=0.017, deep=0.010,
        surfaceTarget=0.25, deepTarget=0.22,
        resilienceCeiling=0.65, tilth=0.009},
    [CROP_GROUP.OTHER]={surface=0.011, deep=0.005,
        surfaceTarget=0.27, deepTarget=0.26,
        resilienceCeiling=0.60, tilth=0.007},
    [CROP_GROUP.PERENNIAL]={surface=0.028, deep=0.012,
        surfaceTarget=0.20, deepTarget=0.21,
        resilienceCeiling=0.84, tilth=0.018}
}

local function getRootGrowthResponse(group, cropName)
    local base = ROOT_GROWTH_RESPONSE[group]
    if base == nil then return nil end
    local response = {}
    for key, value in pairs(base) do response[key] = value end
    cropName = tostring(cropName or "")
    if group == CROP_GROUP.PERENNIAL
        and containsAny(cropName, {"alfalfa", "clover"}) then
        response.deep = 0.024
        response.deepTarget = 0.16
        response.resilienceCeiling = 0.88
    elseif group == CROP_GROUP.ROOT then
        if containsAny(cropName,
                {"sugarbeet", "beetroot", "carrot", "parsnip"}) then
            response.deep = 0.015
            response.deepTarget = 0.19
            response.resilienceCeiling = 0.70
        elseif containsAny(cropName, {"potato"}) then
            response.deep = 0.007
            response.deepTarget = 0.24
        end
    elseif isCoverCropName(cropName) then
        -- A deliberately established catch crop keeps living roots between
        -- cash crops and is credited slightly more than an ordinary oilseed.
        response.surface = response.surface * 1.15
        response.deep = response.deep * 1.15
        response.tilth = response.tilth * 1.20
        response.resilienceCeiling = math.min(
            response.resilienceCeiling + 0.02, 0.76)
    end
    return response
end

function TerraLogicSoilManager:applyRootGrowthAtWorldPosition(
        x, z, fruitTypeIndex, stages, eventToken, cropCoverage)
    if g_server == nil then return false end
    if self.deepMapMigration ~= nil then return false end
    stages = math.clamp(math.floor(tonumber(stages) or 0), 0, 3)
    if stages <= 0 then return false end
    local group, cropName = self:getCropGroup(fruitTypeIndex)
    local response = getRootGrowthResponse(group, cropName)
    if response == nil then return false end
    cropCoverage = math.clamp(tonumber(cropCoverage) or 1, 0, 1)
    if cropCoverage <= 0 then return false end
    local biologyKey = getCellKey(
        math.floor(x / self.RESILIENCE_CELL_SIZE),
        math.floor(z / self.RESILIENCE_CELL_SIZE))
    local signature = tostring(fruitTypeIndex) .. ":" .. tostring(eventToken)
    self.rootGrowthRecent = self.rootGrowthRecent or {}
    -- Resilience is an 8 m layer and must be credited only once per block.
    -- Root loosening and tilth, however, are driven by each 4 m crop-history
    -- cell. The former shared early return accidentally limited those physical
    -- effects to one quarter of every 8 m block.
    local resilienceAlreadyCredited =
        self.rootGrowthRecent[biologyKey] == signature
    if not resilienceAlreadyCredited then
        self.rootGrowthRecent[biologyKey] = signature
    end
    local previousGroup, _, phase = decodeRotationState(
        self:getRotationRawAtWorldPosition(x, z))

    local cycleGain = CROP_RESILIENCE_GAIN[group] or 0.006
    if previousGroup == group then
        -- Repeated annual crops maintain some living pores but receive only a
        -- fraction of the diverse-crop response. Established perennial grass
        -- earns a small contribution on every genuine regrowth cycle.
        cycleGain = group == CROP_GROUP.PERENNIAL
            and 0.010 or cycleGain * 0.35
    elseif phase ~= ROTATION_PHASE_PLANTED then
        -- Old/external fields without a known sowing marker get the cautious
        -- monoculture share until their first complete TerraLogic cycle.
        cycleGain = cycleGain * 0.35
    end
    if isCoverCropName(cropName) then
        cycleGain = cycleGain + COVER_CROP_RESILIENCE_BONUS
    end
    local resilienceDevelopmentSpeed = getResilienceDevelopmentSpeed()
    local environment = self:getRecoveryEnvironmentFactors(x, z)
    -- A real game growth transition proves that roots were active during the
    -- period, so an unlucky cold sampling instant may reduce but never erase
    -- the already completed biological contribution.
    local rootActivity = 0.20 + 0.80 * environment.biologicalFactor
    -- Recently inverted soil still benefits from roots, but it cannot turn a
    -- new crop into an immediate replacement for mature pores and soil life.
    -- The retained 55% floor avoids an artificial dead season.
    local continuity = self:getBiologicalContinuityAtWorldPosition(x, z)
    cycleGain = cycleGain * (0.55 + 0.45 * continuity) * cropCoverage
    cycleGain = scaleEnvironmentalStrength(
        cycleGain, rootActivity, resilienceDevelopmentSpeed)
    local stageGain = 1 - (1 - cycleGain) ^ (1 / 3)
    local combinedGain = 1 - (1 - stageGain) ^ stages
    local resilienceBefore = self:getValueAtWorldPosition("resilience", x, z)
    local resilienceAfter = resilienceBefore
    if not resilienceAlreadyCredited
        and resilienceBefore < response.resilienceCeiling then
        resilienceAfter = math.min(response.resilienceCeiling,
            clamp01(resilienceBefore
                + combinedGain * (1 - resilienceBefore)))
    end
    local changed = false
    if math.abs(resilienceAfter - resilienceBefore) > 0.0001 then
        self:setStateAtWorldPosition("resilience", x, z, resilienceAfter)
        self.continuousTrafficValues = self.continuousTrafficValues or {}
        self.continuousTrafficValues.resilience =
            self.continuousTrafficValues.resilience or {}
        self.continuousTrafficValues.resilience[biologyKey] = resilienceAfter
        self:markResilienceChanged()
        changed = true
    end

    local function rememberContinuous(layerId, value, sampleX, sampleZ)
        self.continuousTrafficValues = self.continuousTrafficValues or {}
        self.continuousTrafficValues[layerId] =
            self.continuousTrafficValues[layerId] or {}
        local cellSize = getLayerCellSize(layerId)
        self.continuousTrafficValues[layerId][getCellKey(
            math.floor((sampleX or x) / cellSize),
            math.floor((sampleZ or z) / cellSize))] = value
    end
    local function relax(layerId, target, cycleStrength)
        cycleStrength = cycleStrength * cropCoverage
        cycleStrength = scaleEnvironmentalStrength(
            cycleStrength, rootActivity, ROOT_LOOSENING_SPEED)
        -- Scale the completed-cycle response, not each assessment separately.
        -- This preserves equivalence when accelerated time batches stages.
        if layerId == "deepCompaction" then
            cycleStrength = math.min(cycleStrength * (1 + 0.50 * continuity), 1)
        end
        local stageStrength = 1 - (1 - cycleStrength) ^ (1 / 3)
        local strength = 1 - (1 - stageStrength) ^ stages
        local positions = {{x=x, z=z}}
        if layerId == "deepCompaction" then
            -- One crop-history cell represents 4x4 m. The former 4 m deep map
            -- changed that complete area with one write; preserve the same
            -- physical coverage by updating all four new 2 m children.
            positions = {}
            local areaSize = TerraLogicQualityManager ~= nil
                and tonumber(TerraLogicQualityManager.CELL_SIZE) or 4
            local cellSize = getLayerCellSize(layerId)
            local cellsPerSide = math.max(math.floor(
                areaSize / cellSize + 0.5), 1)
            local minX, minZ = x - areaSize * 0.5, z - areaSize * 0.5
            for localZ=0,cellsPerSide-1 do
                for localX=0,cellsPerSide-1 do
                    positions[#positions + 1] = {
                        x=minX + (localX + 0.5) * cellSize,
                        z=minZ + (localZ + 0.5) * cellSize
                    }
                end
            end
        end
        for _, position in ipairs(positions) do
            local current = self:getValueAtWorldPosition(
                layerId, position.x, position.z)
            if current > target then
                local nextValue = clamp01(
                    current + (target - current) * strength)
                if math.abs(nextValue - current) > 0.0001 then
                    self:setStateAtWorldPosition(
                        layerId, position.x, position.z, nextValue)
                    -- Retain sub-byte progress during the running session.
                    rememberContinuous(
                        layerId, nextValue, position.x, position.z)
                    changed = true
                end
            end
        end
    end
    local function relaxTilth(target, cycleStrength)
        local current = self:getValueAtWorldPosition("aggregateSize", x, z)
        cycleStrength = cycleStrength * cropCoverage
        cycleStrength = scaleEnvironmentalStrength(
            cycleStrength, rootActivity, ROOT_LOOSENING_SPEED)
        local stageStrength = 1 - (1 - cycleStrength) ^ (1 / 3)
        local strength = 1 - (1 - stageStrength) ^ stages
        local nextValue = clamp01(current + (target - current) * strength)
        if math.abs(nextValue - current) <= 0.0001 then return end
        self:setStateAtWorldPosition("aggregateSize", x, z, nextValue)
        rememberContinuous("aggregateSize", nextValue)
        changed = true
    end
    relax("surfaceCompaction", response.surfaceTarget, response.surface)
    relax("deepCompaction", response.deepTarget, response.deep)
    relaxTilth(0.50, response.tilth)
    if changed and TerraLogicLogging ~= nil
        and TerraLogicLogging.verbose == true then
        TerraLogicLogging.debug(
            "[FS25_TerraLogic] Root growth: crop=%s stages=%d resilienceSpeed=%dx physicalSpeed=%dx bio=%.3f targets=%.2f/%.2f resilience=%.3f->%.3f ceiling=%.2f",
            tostring(cropName), stages, resilienceDevelopmentSpeed,
            ROOT_LOOSENING_SPEED,
            environment.biologicalFactor,
            response.surfaceTarget, response.deepTarget,
            resilienceBefore, resilienceAfter,
            response.resilienceCeiling)
    end
    return changed
end

function TerraLogicSoilManager:markResilienceChanged()
    self.dirty = true
    local active = self.layers[self.activeMapMode]
    if active ~= nil and active.id == "resilience" then
        local now = g_currentMission ~= nil and g_currentMission.time or 0
        if not self.visualizationDirty then
            self.overlayRefreshTime = now + self.OVERLAY_REFRESH_DELAY_MS
        end
        self.visualizationDirty = true
    end
end

function TerraLogicSoilManager:completeCropCycleAtWorldPosition(
        x, z, fruitTypeIndex, growthCredited)
    if g_server == nil then return false end
    local group, cropName = self:getCropGroup(fruitTypeIndex)
    if group == CROP_GROUP.NONE then return false end
    local response = getRootGrowthResponse(group, cropName)
    local lastGroup, currentGroup, phase = decodeRotationState(
        self:getRotationRawAtWorldPosition(x, z))
    -- All 4 m harvest cells inside the same 8 m biology cell converge here.
    -- COMPLETED therefore means this crop cycle has already been credited.
    if phase == ROTATION_PHASE_COMPLETED and lastGroup == group then
        return false
    end
    local plantedMatch = phase == ROTATION_PHASE_PLANTED
        and currentGroup == group
    local previousGroup = lastGroup
    local resilienceCeiling = response ~= nil
        and response.resilienceCeiling or 0.60
    local gain = CROP_RESILIENCE_GAIN[group] or 0.006
    if growthCredited == true then
        -- Living roots were already credited at the actual growth events.
        -- Harvest adds only the diversity bonus, never the crop base twice.
        gain = 0
        if previousGroup ~= CROP_GROUP.NONE and previousGroup ~= group then
            gain = 0.006
            if previousGroup == CROP_GROUP.LEGUME
                or group == CROP_GROUP.LEGUME then gain = gain + 0.003 end
        end
    elseif previousGroup == group then
        -- Ordinary monoculture maintains roots but cannot farm resilience by
        -- repeating the same cheap crop forever. Perennial stands are the one
        -- exception because several undisturbed years really do build pores.
        gain = group == CROP_GROUP.PERENNIAL and 0.010 or 0
    elseif previousGroup ~= CROP_GROUP.NONE then
        gain = gain + 0.006
        if previousGroup == CROP_GROUP.LEGUME or group == CROP_GROUP.LEGUME then
            gain = gain + 0.003
        end
    end
    if growthCredited ~= true and isCoverCropName(cropName) then
        gain = gain + COVER_CROP_RESILIENCE_BONUS
    end
    if previousGroup ~= CROP_GROUP.NONE and previousGroup ~= group then
        resilienceCeiling = math.min(resilienceCeiling + 0.04, 0.88)
    end
    local continuity = self:getBiologicalContinuityAtWorldPosition(x, z)
    gain = gain * (0.55 + 0.45 * continuity)
    gain = scaleSlowStrength(gain, getResilienceDevelopmentSpeed())
    -- A crop first seen only at harvest (old savegame or externally planted)
    -- still receives its root contribution once. A known planted cycle uses
    -- the same path; the phase marker is what prevents callback multiplication.
    local current = self:getValueAtWorldPosition("resilience", x, z)
    local nextValue = current
    if current < resilienceCeiling then
        nextValue = math.min(resilienceCeiling,
            clamp01(current + gain * (1 - current)))
    end
    if math.abs(nextValue - current) > 0.001 then
        self:setStateAtWorldPosition("resilience", x, z, nextValue)
        self:markResilienceChanged()
    end
    self:setRotationStateAtWorldPosition(
        x, z, group, 0, ROTATION_PHASE_COMPLETED)
    if TerraLogicLogging ~= nil and TerraLogicLogging.verbose == true then
        TerraLogicLogging.debug(
            "[FS25_TerraLogic] Crop resilience: crop=%s group=%d previous=%d planted=%s value=%.3f->%.3f gain=%.4f ceiling=%.2f",
            tostring(cropName), group, previousGroup,
            tostring(plantedMatch), current, nextValue, gain,
            resilienceCeiling)
    end
    return true
end

function TerraLogicSoilManager:completeCropCycleAtQualityCell(
        ix, iz, fruitTypeIndex, sourceCellSize, growthCredited)
    sourceCellSize = tonumber(sourceCellSize) or 4
    return self:completeCropCycleAtWorldPosition(
        (ix + 0.5) * sourceCellSize,
        (iz + 0.5) * sourceCellSize,
        fruitTypeIndex, growthCredited)
end

function TerraLogicSoilManager:getStateAtWorldPosition(x, z)
    local result = {}
    for _, layer in ipairs(self.layers) do
        result[layer.id] = self:getValueAtWorldPosition(layer.id, x, z)
    end
    return result
end

-- Compact read-only diagnostics for the balancing HUD. The effective value
-- may temporarily be more precise than the persisted raster while wheel
-- traffic accumulates sub-quantization changes. Exposing both authoritative
-- maps makes those intentional differences distinguishable from failed map
-- writes or a missing display mask.
function TerraLogicSoilManager:getLayerDebugAtWorldPosition(layerId, x, z)
    local layer = getLayerDefinition(layerId)
    if layer == nil then return nil end
    local cellSize = getLayerCellSize(layerId)
    local channels = getLayerChannels(layerId)
    local ix = math.floor((tonumber(x) or 0) / cellSize)
    local iz = math.floor((tonumber(z) or 0) / cellSize)
    local key = getCellKey(ix, iz)
    local continuous = self.continuousTrafficValues ~= nil
        and self.continuousTrafficValues[layerId] ~= nil
        and self.continuousTrafficValues[layerId][key] or nil
    local cached = self.layerCells ~= nil
        and self.layerCells[layerId] ~= nil
        and self.layerCells[layerId][key] or nil
    local raw = self:getRawAtWorldPosition(layerId, x, z)
    local rasterValue = decode(raw,
        TerraLogicSoilProfiles.DEFAULTS[layerId], channels)
    local effective = self:getValueAtWorldPosition(layerId, x, z)
    local expectedRaw = encode(effective, channels)

    local visualMaskRaw, visualRaw, visualValue = 0, 0, nil
    local visualMap = self.visualizationMaps ~= nil
        and self.visualizationMaps[layerId] or nil
    if visualMap ~= nil and getBitVectorMapPoint ~= nil then
        local sizeX, sizeZ = getBitVectorMapSize(visualMap)
        sizeX = tonumber(sizeX) or 0
        sizeZ = tonumber(sizeZ) or sizeX
        if sizeX > 0 and sizeZ > 0 then
            local terrainSize = tonumber(self.terrainSize) or 2048
            local px = math.floor(((tonumber(x) or 0) / terrainSize + 0.5)
                * sizeX)
            local pz = math.floor(((tonumber(z) or 0) / terrainSize + 0.5)
                * sizeZ)
            px = math.max(0, math.min(px, sizeX - 1))
            pz = math.max(0, math.min(pz, sizeZ - 1))
            visualMaskRaw = tonumber(getBitVectorMapPoint(
                visualMap, px, pz, 0, 1)) or 0
            if visualMaskRaw > 0 then
                -- The overlay now reads this authoritative raw state directly.
                visualRaw = raw
                visualValue = rasterValue
            end
        end
    end
    local expectedVisualRaw = expectedRaw
    return {
        id=layerId, cellSize=cellSize, channels=channels,
        ix=ix, iz=iz, effective=effective,
        raw=raw, rasterValue=rasterValue, expectedRaw=expectedRaw,
        rasterMatches=raw == expectedRaw,
        visualMaskRaw=visualMaskRaw,
        visualRaw=visualRaw, visualValue=visualValue,
        expectedVisualRaw=expectedVisualRaw,
        visualMatches=visualMaskRaw > 0 and visualRaw == expectedVisualRaw,
        continuousValue=continuous,
        cachedValue=cached ~= nil and cached.value or nil,
        source=continuous ~= nil and "traffic accumulator"
            or (cached ~= nil and "write cache" or "raster"),
        writeSerial=self.layerWriteSerial ~= nil
            and tonumber(self.layerWriteSerial[layerId]) or 0
    }
end

function TerraLogicSoilManager:writeRasterCell(
        layerId, ix, iz, value, suppressNetworkRevision)
    local modifier = self.modifiers[layerId]
    if not self:setModifierToCell(modifier, layerId, ix, iz) then return false end
    modifier:executeSet(encode(value, getLayerChannels(layerId)))
    if suppressNetworkRevision ~= true then
        self:markServerNetworkTileChanged(layerId, ix, iz)
    end
    return true
end

-- Client tile replication already carries the exact encoded raster value.
-- Writing it directly avoids a decode/re-encode round trip and, unlike the
-- authoritative setStateCell boundary, does not mark savegame data dirty or
-- rebuild the overlay once per individual pixel.
function TerraLogicSoilManager:writeNetworkRasterCell(
        layerId, ix, iz, rawValue)
    local modifier = self.modifiers[layerId]
    if not self:setModifierToCell(modifier, layerId, ix, iz) then return false end
    local maximum = 2 ^ getLayerChannels(layerId) - 1
    modifier:executeSet(math.clamp(
        math.floor(tonumber(rawValue) or 0), 0, maximum))
    return true
end

function TerraLogicSoilManager:getVisualizationRawAtWorldPosition(layerId, x, z)
    local map = self.visualizationMaps ~= nil
        and self.visualizationMaps[layerId] or nil
    local size = self.visualizationMapSizes ~= nil
        and self.visualizationMapSizes[layerId] or nil
    return getRawFromBitVectorMap(
        map, 1, tonumber(self.terrainSize) or 2048, x, z,
        size ~= nil and size.x or nil, size ~= nil and size.z or nil)
end

function TerraLogicSoilManager:writeNetworkVisualizationCell(
        layerId, ix, iz, rawValue)
    local modifier = self.visualizationModifiers ~= nil
        and self.visualizationModifiers[layerId] or nil
    if not self:setModifierToCell(modifier, layerId, ix, iz) then return false end
    modifier:executeSet((tonumber(rawValue) or 0) > 0 and 1 or 0)
    return true
end

function TerraLogicSoilManager:writeVisualizationCell(
        layerId, ix, iz, value, suppressNetworkRevision, coverageConfirmed)
    local modifier = self.visualizationModifiers ~= nil
        and self.visualizationModifiers[layerId] or nil
    if modifier == nil then return false end
    local cellSize = getLayerCellSize(layerId)
    local centerX, centerZ = (ix+0.5)*cellSize, (iz+0.5)*cellSize
    -- Only reject a cell when the decoded GIANTS ground type positively says
    -- that no field surface remains. An unavailable density query must not
    -- erase valid coverage, especially on remote/dedicated-server clients.
    local alreadyVisible = self:getVisualizationRawAtWorldPosition(
        layerId, centerX, centerZ) > 0
    if alreadyVisible then return true end
    if not self:setModifierToCell(modifier, layerId, ix, iz) then return false end
    if not alreadyVisible and coverageConfirmed ~= true
        and self:isCultivatableTerrainCell(layerId, ix, iz) == false then
        modifier:executeSet(0)
        if suppressNetworkRevision ~= true then
            self:markServerNetworkTileChanged(layerId, ix, iz)
        end
        return true
    end
    -- The authoritative map itself is rendered. This derived map only marks
    -- the affected cell as visible and can therefore never hold a stale soil
    -- value. It also makes newly created fields visible after their first
    -- TerraLogic write.
    modifier:executeSet(1)
    if suppressNetworkRevision ~= true then
        self:markServerNetworkTileChanged(layerId, ix, iz)
    end
    return true
end

function TerraLogicSoilManager:clearVisualizationCell(
        layerId, ix, iz, suppressNetworkRevision)
    local modifier = self.visualizationModifiers ~= nil
        and self.visualizationModifiers[layerId] or nil
    if not self:setModifierToCell(modifier, layerId, ix, iz) then return false end
    modifier:executeSet(0)
    if suppressNetworkRevision ~= true then
        self:markServerNetworkTileChanged(layerId, ix, iz)
    end
    return true
end

function TerraLogicSoilManager:isCultivatableTerrainAtWorldPosition(x, z)
    local value = self:getGroundTypeAtWorldPosition(x, z)
    if value == nil then return nil end
    if FieldGroundType ~= nil
        and FieldGroundType.getTypeByValue ~= nil
        and FieldGroundType.NONE ~= nil then
        local ok, groundType = pcall(FieldGroundType.getTypeByValue, value)
        if ok then return groundType ~= FieldGroundType.NONE, value end
    end
    -- Older/custom maps may not expose the converter. The decoded GROUND_TYPE
    -- value still uses zero for NONE, unlike the former raw terrainDetailId
    -- query which mixed all packed terrain channels together.
    return tonumber(value) ~= 0, value
end

function TerraLogicSoilManager:getCultivatableTerrainCoverage(
        cellSize, ix, iz)
    cellSize = math.max(tonumber(cellSize) or self.WHEEL_CELL_SIZE, 0.25)
    -- One-metre cells need more than their centre point: a diagonal native
    -- field edge can otherwise authorize a complete square although only a
    -- thin corner is arable. Coarser layer masks sample up to a 4x4 grid so
    -- all layers use the same live-ground majority rule without an expensive
    -- full-resolution scan of every eight-metre resilience cell.
    local subdivisions = cellSize <= 1.01
        and self.COVERAGE_FINE_SAMPLE_GRID
        or math.min(math.max(math.ceil(cellSize / 2), 2),
            self.COVERAGE_COARSE_SAMPLE_GRID_MAX)
    local step = cellSize / subdivisions
    local originX, originZ = ix * cellSize, iz * cellSize
    local cultivatableCount, knownCount = 0, 0
    for sampleZ=0,subdivisions-1 do
        for sampleX=0,subdivisions-1 do
            local result = self:isCultivatableTerrainAtWorldPosition(
                originX + (sampleX + 0.5) * step,
                originZ + (sampleZ + 0.5) * step)
            if result ~= nil then
                knownCount = knownCount + 1
                if result == true then
                    cultivatableCount = cultivatableCount + 1
                end
            end
        end
    end
    if knownCount <= 0 then return nil end
    return cultivatableCount / knownCount
end

function TerraLogicSoilManager:isCultivatableTerrainRegion(
        cellSize, ix, iz)
    local coverage = self:getCultivatableTerrainCoverage(cellSize, ix, iz)
    if coverage == nil then return nil end
    return coverage >= self.COVERAGE_VISIBLE_MIN_FRACTION
end

function TerraLogicSoilManager:isCultivatableTerrainCell(layerId, ix, iz)
    return self:isCultivatableTerrainRegion(
        getLayerCellSize(layerId), ix, iz)
end

local function getCoverageTileKey(tileX, tileZ)
    return tostring(tileX) .. ":" .. tostring(tileZ)
end

function TerraLogicSoilManager:queueCoverageTile(tileX, tileZ)
    if g_server == nil or self.rasterReady ~= true then return false end
    tileX, tileZ = math.floor(tonumber(tileX) or 0),
        math.floor(tonumber(tileZ) or 0)
    self.coverageReconcileJobs = self.coverageReconcileJobs or {}
    self.coverageReconcilePending = self.coverageReconcilePending or {}
    local key = getCoverageTileKey(tileX, tileZ)
    if self.coverageReconcilePending[key] == true then return false end
    if #self.coverageReconcileJobs >= self.COVERAGE_RECONCILE_MAX_JOBS then
        return false
    end
    local size = self.COVERAGE_RECONCILE_TILE_SIZE_M
    local half = (tonumber(self.terrainSize) or 2048) * 0.5
    local minX, minZ = tileX * size, tileZ * size
    if minX >= half or minZ >= half
        or minX + size <= -half or minZ + size <= -half then return false end
    self.coverageReconcilePending[key] = true
    self.coverageReconcileJobs[#self.coverageReconcileJobs + 1] = {
        key=key, tileX=tileX, tileZ=tileZ,
        minX=minX, minZ=minZ, index=0,
        sampleStep=self.COVERAGE_AUTHORITY_SAMPLE_M,
        samplesPerSide=math.max(math.floor(
            size/self.COVERAGE_AUTHORITY_SAMPLE_M + 0.5), 1),
        phase="sample", changed=false, coverageCells={},
        applyCells=nil, applyIndex=1
    }
    return true
end

function TerraLogicSoilManager:queueCoverageRegion(minX, minZ, maxX, maxZ)
    if g_server == nil then return false end
    minX, minZ = tonumber(minX) or 0, tonumber(minZ) or 0
    maxX, maxZ = tonumber(maxX) or minX, tonumber(maxZ) or minZ
    if minX > maxX then minX, maxX = maxX, minX end
    if minZ > maxZ then minZ, maxZ = maxZ, minZ end
    local maximum = self.COVERAGE_RECONCILE_MAX_REGION_M
    maxX, maxZ = math.min(maxX, minX + maximum),
        math.min(maxZ, minZ + maximum)
    local size = self.COVERAGE_RECONCILE_TILE_SIZE_M
    local queued = false
    for tileZ=math.floor(minZ/size),math.floor((maxZ-0.001)/size) do
        for tileX=math.floor(minX/size),math.floor((maxX-0.001)/size) do
            queued = self:queueCoverageTile(tileX, tileZ) or queued
        end
    end
    return queued
end

function TerraLogicSoilManager:processCoverageReconcileJobs(jobs, budget)
    budget = tonumber(budget) or self.COVERAGE_RECONCILE_CELLS_PER_FRAME
    if g_server == nil or self.rasterReady ~= true then return budget end
    jobs = jobs or self.coverageReconcileJobs or {}
    while budget > 0 and #jobs > 0 do
        local job = jobs[1]
        if job.phase == "sample" then
            local side = job.samplesPerSide
            local localX = job.index % side
            local localZ = math.floor(job.index / side)
            local step = job.sampleStep
            local x, z = job.minX + (localX+0.5)*step,
                job.minZ + (localZ+0.5)*step
            -- Query the live half-metre authority once, then reuse that result
            -- for all five layer masks. This is both more accurate and much
            -- cheaper than independently resampling each 1/2/8 m mask cell.
            local cultivatable = self:isCultivatableTerrainAtWorldPosition(x, z)
            if cultivatable ~= nil then
                for _, layer in ipairs(self.layers) do
                    local cellSize = getLayerCellSize(layer.id)
                    local ix, iz = math.floor(x/cellSize), math.floor(z/cellSize)
                    local cellKey = layer.id .. ":" .. tostring(ix) .. ":"
                        .. tostring(iz)
                    local entry = job.coverageCells[cellKey]
                    if entry == nil then
                        entry = {layerId=layer.id, ix=ix, iz=iz,
                            known=0, cultivatable=0}
                        job.coverageCells[cellKey] = entry
                    end
                    entry.known = entry.known + 1
                    if cultivatable then
                        entry.cultivatable = entry.cultivatable + 1
                    end
                end
            end
            job.index = job.index + 1
            budget = budget - 1
            if job.index >= side*side then
                job.applyCells = {}
                for _, entry in pairs(job.coverageCells) do
                    job.applyCells[#job.applyCells+1] = entry
                end
                job.phase, job.applyIndex = "apply", 1
            end
        else
            local entry = job.applyCells[job.applyIndex]
            if entry ~= nil and entry.known > 0 then
                local cultivatable = entry.cultivatable/entry.known
                    >= self.COVERAGE_VISIBLE_MIN_FRACTION
                local cellSize = getLayerCellSize(entry.layerId)
                local centerX, centerZ = (entry.ix+0.5)*cellSize,
                    (entry.iz+0.5)*cellSize
                local visible = self:getVisualizationRawAtWorldPosition(
                    entry.layerId, centerX, centerZ) > 0
                if cultivatable ~= visible then
                    if cultivatable then
                        self:writeVisualizationCell(entry.layerId,
                            entry.ix, entry.iz, 1, false, true)
                    else
                        self:clearVisualizationCell(
                            entry.layerId, entry.ix, entry.iz)
                    end
                    job.changed = true
                end
            end
            job.applyIndex = job.applyIndex + 1
            budget = budget - 1
        end
        if job.phase == "apply"
            and job.applyIndex > #(job.applyCells or {}) then
            table.remove(jobs, 1)
            self.coverageReconcilePending[job.key] = nil
            TerraLogicMapMaintenance:onCompleted(job)
            if job.changed then
                self.dirty = true
                self.visualizationDirty = true
                self.overlayRefreshTime = (g_currentMission.time or 0)
                    + self.OVERLAY_REFRESH_DELAY_MS
            end
        end
    end
    return budget
end

function TerraLogicSoilManager:requestCoverageRegion(minX, minZ, maxX, maxZ)
    if g_server ~= nil then
        return self:queueCoverageRegion(minX, minZ, maxX, maxZ)
    end
    if g_client ~= nil then
        local connection = g_client:getServerConnection()
        if connection ~= nil and TerraLogicCoverageReconcileEvent ~= nil then
            connection:sendEvent(TerraLogicCoverageReconcileEvent.new(
                minX, minZ, maxX, maxZ))
            return true
        end
    end
    return false
end

function TerraLogicSoilManager:updateNearbyCoverageReconcile(now)
    if now < (tonumber(self.coverageReconcileNextRequestTime) or 0) then return end
    if g_localPlayer == nil or getWorldTranslation == nil then return end
    local vehicle = g_localPlayer.getCurrentVehicle ~= nil
        and g_localPlayer:getCurrentVehicle() or nil
    local node = vehicle ~= nil and (vehicle.rootNode
        or (vehicle.components ~= nil and vehicle.components[1] ~= nil
            and vehicle.components[1].node)) or g_localPlayer.rootNode
    if node == nil or node == 0 then return end
    local x, _, z = getWorldTranslation(node)
    if x == nil then return end
    local radius = tonumber(self.coverageViewportRadius) or 96
    if g_server ~= nil then
        TerraLogicMapMaintenance:setInterest("local", x, z, radius)
    elseif g_client ~= nil then
        local connection = g_client:getServerConnection()
        if connection ~= nil then
            connection:sendEvent(TerraLogicCoverageReconcileEvent.new(
                x-radius, z-radius, x+radius, z+radius, true))
        end
    end
    self.coverageReconcileNextRequestTime = now + 3000
end

function TerraLogicSoilManager:recordConstructionCoveragePosition(screen)
    local cursor = screen ~= nil and screen.cursor or nil
    local node = cursor ~= nil and (cursor.rootNode or cursor.node) or nil
    node = node or (screen ~= nil and screen.cursorNode or nil)
    if node == nil or node == 0 or getWorldTranslation == nil then return end
    local x, _, z = getWorldTranslation(node)
    local size = self.COVERAGE_RECONCILE_TILE_SIZE_M
    self.constructionCoverageTiles = self.constructionCoverageTiles or {}
    local centerX, centerZ = math.floor(x/size), math.floor(z/size)
    -- One surrounding tile covers even the larger landscaping brushes while
    -- keeping the request bounded and independent of undocumented brush data.
    for dz=-1,1 do
        for dx=-1,1 do
            local tileX, tileZ = centerX+dx, centerZ+dz
            self.constructionCoverageTiles[
                getCoverageTileKey(tileX, tileZ)] = {x=tileX, z=tileZ}
        end
    end
end

function TerraLogicSoilManager:flushConstructionCoverage()
    local minTileX, minTileZ, maxTileX, maxTileZ =
        math.huge, math.huge, -math.huge, -math.huge
    for _, tile in pairs(self.constructionCoverageTiles or {}) do
        minTileX, minTileZ = math.min(minTileX, tile.x),
            math.min(minTileZ, tile.z)
        maxTileX, maxTileZ = math.max(maxTileX, tile.x),
            math.max(maxTileZ, tile.z)
    end
    if minTileX ~= math.huge then
        local size = self.COVERAGE_RECONCILE_TILE_SIZE_M
        self:requestCoverageRegion(minTileX*size, minTileZ*size,
            (maxTileX+1)*size, (maxTileZ+1)*size)
    end
    self.constructionCoverageTiles = {}
end

function TerraLogicSoilManager:installConstructionCoverageHook()
    if ConstructionScreen == nil or Utils == nil then return false end
    if ConstructionScreen.terraLogicCoverageHookInstalled == true then
        self.constructionCoverageHookInstalled = true
        return true
    end
    if ConstructionScreen.onButtonPrimaryDrag ~= nil then
        ConstructionScreen.onButtonPrimaryDrag = Utils.appendedFunction(
            ConstructionScreen.onButtonPrimaryDrag, function(screen)
                if TerraLogicSoilManager ~= nil then
                    TerraLogicSoilManager:recordConstructionCoveragePosition(screen)
                end
            end)
    end
    if ConstructionScreen.onClose ~= nil then
        ConstructionScreen.onClose = Utils.prependedFunction(
            ConstructionScreen.onClose, function(screen)
                if TerraLogicSoilManager ~= nil then
                    TerraLogicSoilManager:recordConstructionCoveragePosition(screen)
                    TerraLogicSoilManager:flushConstructionCoverage()
                end
            end)
    end
    ConstructionScreen.terraLogicCoverageHookInstalled = true
    self.constructionCoverageHookInstalled = true
    return true
end

-- A native field polygon is only an initial display seed. Player-created
-- fields have no Field object, so expose a successfully worked raster cell the
-- first time it is encountered even when its soil value already equals the
-- operation target. The read guard avoids rebuilding the overlay on every
-- repeat pass over an already visible field.
function TerraLogicSoilManager:ensureVisualizationCellVisible(layerId, ix, iz)
    local cellSize = getLayerCellSize(layerId)
    local x = (ix + 0.5) * cellSize
    local z = (iz + 0.5) * cellSize
    if self:getVisualizationRawAtWorldPosition(layerId, x, z) > 0 then
        return false
    end
    return self:writeVisualizationCell(layerId, ix, iz, 1)
end

function TerraLogicSoilManager:setStateCell(
        layerId, ix, iz, value, suppressNetworkRevision)
    local key = getCellKey(ix, iz)
    local normalized = clamp01(value)
    if self.continuousTrafficValues ~= nil
        and self.continuousTrafficValues[layerId] ~= nil then
        -- Any implement/tillage write supersedes an accumulated wheel value.
        self.continuousTrafficValues[layerId][key] = nil
    end
    local rasterWritten = self:writeRasterCell(
        layerId, ix, iz, normalized, suppressNetworkRevision)
    local visualWritten = self:writeVisualizationCell(
        layerId, ix, iz, normalized, true)
    self.layerCells[layerId] = self.layerCells[layerId] or {}
    self.layerWriteSerial = self.layerWriteSerial or {}
    self.layerWriteSerial[layerId] =
        (tonumber(self.layerWriteSerial[layerId]) or 0) + 1
    if rasterWritten and visualWritten then
        self.layerCells[layerId][key] = nil
    else
        -- Short-lived fallback for changes or migration data received before
        -- terrain-backed modifiers are available.
        self.layerCells[layerId][key] = {
            ix=ix, iz=iz, value=normalized
        }
    end
    -- Every persisted soil write invalidates the currently generated overlay
    -- when that layer is visible. Keeping this at the storage boundary also
    -- covers biological/root-growth paths that change several layers without
    -- a device-pass callback to mark the display dirty.
    self.dirty = true
    local activeLayer = self.layers[self.activeMapMode]
    if activeLayer ~= nil and activeLayer.id == layerId then
        local now = g_currentMission ~= nil and g_currentMission.time or 0
        if not self.visualizationDirty then
            self.overlayRefreshTime = now + self.OVERLAY_REFRESH_DELAY_MS
        end
        self.visualizationDirty = true
    end
    return true
end

function TerraLogicSoilManager:setStateAtWorldPosition(layerId, x, z, value)
    local cellSize = getLayerCellSize(layerId)
    local ix = math.floor((tonumber(x) or 0) / cellSize)
    local iz = math.floor((tonumber(z) or 0) / cellSize)
    return self:setStateCell(layerId, ix, iz, value), ix, iz
end

-- Session-only comparison soil. This changes only which physical response
-- TerraLogic reads; it never writes Precision Farming's soil, pH, nitrogen or
-- yield maps. Reloading the save restores automatic PF detection.
function TerraLogicSoilManager:setTestSoilTypeOverride(name)
    if g_server == nil then return false, "server unavailable" end
    local normalized = string.lower(tostring(name or ""))
        :gsub("[%s_%-]", "")
    local types = {
        ["1"]=1, loamysand=1,
        ["2"]=2, sandyloam=2,
        ["3"]=3, loam=3,
        ["4"]=4, siltyclay=4
    }
    if normalized == "" or normalized == "auto" or normalized == "off"
        or normalized == "natural" then
        self.auditSoilTypeOverride = nil
        self.auditSoilTypeOverrideName = nil
        if TerraLogicAuditManager ~= nil then
            TerraLogicAuditManager.metadata =
                TerraLogicAuditManager.metadata or {}
            TerraLogicAuditManager.metadata.soilTypeOverride = "auto"
        end
        return true, "automatic Precision Farming soil detection restored"
    end
    local index = types[normalized]
    if index == nil then
        return false, "unknown soil; use loamySand, sandyLoam, loam, siltyClay or auto"
    end
    self.auditSoilTypeOverride = index
    local response = TerraLogicSoilProfiles ~= nil
        and TerraLogicSoilProfiles.PF_SOIL_RESPONSES ~= nil
        and TerraLogicSoilProfiles.PF_SOIL_RESPONSES[index] or nil
    local label = response ~= nil and response.name
        or ({"Loamy Sand", "Sandy Loam", "Loam", "Silty Clay"})[index]
    self.auditSoilTypeOverrideName = label
    if TerraLogicAuditManager ~= nil then
        TerraLogicAuditManager.metadata =
            TerraLogicAuditManager.metadata or {}
        TerraLogicAuditManager.metadata.soilTypeOverride = label
    end
    return true, string.format(
        "%s used for TerraLogic physics until reload; PF maps remain unchanged",
        tostring(label))
end

TerraLogicSoilManager.TEST_SECTION_SCAN_CELL_SIZE = 2
TerraLogicSoilManager.TEST_SECTION_MAX_CELLS = 8192

local function getTestSectionKey(ix, iz)
    return tostring(ix) .. ":" .. tostring(iz)
end

local function isTestSectionCell(manager, ix, iz)
    local size = manager.TEST_SECTION_SCAN_CELL_SIZE
    local x, z = (ix + 0.5) * size, (iz + 0.5) * size
    if manager:getVisualizationRawAtWorldPosition(
            "surfaceCompaction", x, z) <= 0 then
        return false
    end
    return manager:isCultivatableTerrainRegion(size, ix, iz) == true
end

local function isTestSectionEdgeConnected(manager, ix, iz, nx, nz)
    local size = manager.TEST_SECTION_SCAN_CELL_SIZE
    local dx, dz = nx - ix, nz - iz
    local edgeX = (ix + 0.5 + dx * 0.5) * size
    local edgeZ = (iz + 0.5 + dz * 0.5) * size
    local sideX, sideZ = -dz * size, dx * size
    for _, offset in ipairs({-0.25, 0, 0.25}) do
        local x, z = edgeX + sideX * offset, edgeZ + sideZ * offset
        if manager:getVisualizationRawAtWorldPosition(
                "surfaceCompaction", x, z) > 0
            and manager:isCultivatableTerrainAtWorldPosition(x, z) == true then
            return true
        end
    end
    return false
end

-- Developer presets replace authoritative soil values immediately. Runtime
-- WorkArea occupancy belongs to the values that existed before that reset and
-- must therefore be discarded as well. Otherwise the still-attached implement
-- can regard the freshly reset field as already worked for several minutes.
function TerraLogicSoilManager:clearRuntimeSoilPassCaches()
    local vehicles = g_currentMission ~= nil
        and g_currentMission.vehicleSystem ~= nil
        and g_currentMission.vehicleSystem.vehicles or {}
    local cleared = 0
    for _, vehicle in pairs(vehicles or {}) do
        local spec = vehicle ~= nil and vehicle.spec_terraLogic or nil
        if spec ~= nil then
            if next(spec.soilRecentCells or {}) ~= nil
                or next(spec.soilPreviousWorkAreaGeometry or {}) ~= nil
                or spec.soilContactPassArmed == true then
                cleared = cleared + 1
            end
            spec.soilRecentCells = {}
            spec.soilPreviousWorkAreaGeometry = {}
            spec.soilContactPassArmed = false
        end
    end
    self.lastPass = nil
    self.lastRejectedPass = nil
    self.lastWrite = nil
    return cleared
end

-- Resets one isolated, live cultivatable component rather than a complete
-- native Field polygon. The complete component is discovered before the first
-- write, so the safety cap can abort atomically on a large/connected field.
function TerraLogicSoilManager:setTestSectionBaselineAtWorldPosition(x, z)
    if g_server == nil or self.rasterReady ~= true then
        return false, "server soil raster unavailable"
    end
    local size = self.TEST_SECTION_SCAN_CELL_SIZE
    local startX, startZ = math.floor(x / size), math.floor(z / size)
    if not isTestSectionCell(self, startX, startZ) then
        local found = false
        for radius=1,2 do
            for dz=-radius,radius do
                for dx=-radius,radius do
                    if not found and isTestSectionCell(
                            self, startX + dx, startZ + dz) then
                        startX, startZ = startX + dx, startZ + dz
                        found = true
                    end
                end
            end
            if found then break end
        end
        if not found then
            return false, "stand on a visible, cultivatable TerraLogic soil section"
        end
    end

    local queue = {{ix=startX, iz=startZ}}
    local visited = {[getTestSectionKey(startX, startZ)]=true}
    local cells, cursor = {}, 1
    local directions = {{1,0},{-1,0},{0,1},{0,-1}}
    while cursor <= #queue do
        local cell = queue[cursor]
        cursor = cursor + 1
        cells[#cells + 1] = cell
        for _, direction in ipairs(directions) do
            local nx, nz = cell.ix + direction[1], cell.iz + direction[2]
            local key = getTestSectionKey(nx, nz)
            if not visited[key] then
                visited[key] = true
                if isTestSectionCell(self, nx, nz)
                    and isTestSectionEdgeConnected(
                        self, cell.ix, cell.iz, nx, nz) then
                    if #queue >= self.TEST_SECTION_MAX_CELLS then
                        return false, string.format(
                            "connected section exceeds %.1f ha safety limit; separate a smaller test plot with at least 10 m non-field ground",
                            self.TEST_SECTION_MAX_CELLS * size * size / 10000)
                    end
                    queue[#queue + 1] = {ix=nx, iz=nz}
                end
            end
        end
    end

    local baseline = {
        surfaceCompaction=0.28, deepCompaction=0.26,
        aggregateSize=0.50, roughness=0.25, resilience=0.50
    }
    local layerCellSets = {}
    for _, layer in ipairs(self.layers) do layerCellSets[layer.id] = {} end
    for _, cell in ipairs(cells) do
        local originX, originZ = cell.ix * size, cell.iz * size
        for _, layer in ipairs(self.layers) do
            local layerSize = getLayerCellSize(layer.id)
            local firstX = math.floor(originX / layerSize)
            local lastX = math.ceil((originX + size) / layerSize) - 1
            local firstZ = math.floor(originZ / layerSize)
            local lastZ = math.ceil((originZ + size) / layerSize) - 1
            local set = layerCellSets[layer.id]
            for iz=firstZ,lastZ do
                for ix=firstX,lastX do
                    local key = getCellKey(ix, iz)
                    if set[key] == nil
                        and self:isCultivatableTerrainCell(
                            layer.id, ix, iz) == true then
                        set[key] = {ix=ix, iz=iz}
                    end
                end
            end
        end
    end

    local minimumX, minimumZ = math.huge, math.huge
    local maximumX, maximumZ = -math.huge, -math.huge
    local writes = 0
    for _, layer in ipairs(self.layers) do
        local layerSize = getLayerCellSize(layer.id)
        for _, cell in pairs(layerCellSets[layer.id]) do
            self:setStateCell(layer.id, cell.ix, cell.iz,
                baseline[layer.id], true)
            minimumX = math.min(minimumX, cell.ix * layerSize)
            minimumZ = math.min(minimumZ, cell.iz * layerSize)
            maximumX = math.max(maximumX, (cell.ix + 1) * layerSize)
            maximumZ = math.max(maximumZ, (cell.iz + 1) * layerSize)
            writes = writes + 1
        end
    end
    if writes <= 0 then return false, "no writable soil cells found" end
    for _, layer in ipairs(self.layers) do
        self:markServerNetworkRegionChanged(
            layer.id, minimumX, minimumZ, maximumX, maximumZ)
    end
    self.dirty = true
    self.visualizationDirty = true
    self.overlayRefreshTime = 0
    self:clearRuntimeSoilPassCaches()
    if TerraLogicAuditManager ~= nil then
        TerraLogicAuditManager.runtimeSoilPreset = "sectionBaseline"
    end
    return true, string.format(
        "%.2f ha section reset to surface/deep 28/26%%, tilth/evenness 50/75%% and resilience 50%% (%d raster cells)",
        #cells * size * size / 10000, writes)
end

-- Developer-only audit helper. It writes a complete native field polygon in
-- one density-map operation per layer, preserving the different 1/2/8 metre
-- map resolutions and their ordinary quantization. Values use the public
-- player terminology; evenness is converted back to stored roughness.
function TerraLogicSoilManager:setAuditFieldStateAtWorldPosition(x, z, values)
    if g_server == nil or self.rasterReady ~= true or values == nil
        or g_farmlandManager == nil or g_fieldManager == nil
        or g_farmlandManager.getFarmlandAtWorldPosition == nil then
        return false, "soil raster or field manager unavailable"
    end
    local farmland = g_farmlandManager:getFarmlandAtWorldPosition(x, z)
    local mapping = g_fieldManager.farmlandIdFieldMapping or {}
    local mapped = farmland ~= nil and mapping[farmland.id] or nil
    local candidates = type(mapped) == "table" and mapped[1] ~= nil
        and mapped.getPolygonPoints == nil and mapped or {mapped}
    local field, points = nil, nil
    for _, candidate in ipairs(candidates) do
        if candidate ~= nil and candidate.getPolygonPoints ~= nil then
            local ok, polygonNodes = pcall(
                candidate.getPolygonPoints, candidate)
            if ok and type(polygonNodes) == "table" then
                local polygon = {}
                for _, node in ipairs(polygonNodes) do
                    if node ~= nil and node ~= 0 and entityExists(node) then
                        local px, _, pz = getWorldTranslation(node)
                        polygon[#polygon + 1] = {x=px, z=pz}
                    end
                end
                if #polygon >= 3 and npcPointInPolygon(x, z, polygon) then
                    field, points = candidate, polygon
                    break
                end
            end
        end
    end
    if field == nil or points == nil then
        return false, "no native field polygon at the player position"
    end
    local minimumX, minimumZ = math.huge, math.huge
    local maximumX, maximumZ = -math.huge, -math.huge
    for _, point in ipairs(points) do
        minimumX, minimumZ = math.min(minimumX, point.x),
            math.min(minimumZ, point.z)
        maximumX, maximumZ = math.max(maximumX, point.x),
            math.max(maximumZ, point.z)
    end
    local stored = {
        surfaceCompaction=values.surfaceCompaction,
        deepCompaction=values.deepCompaction,
        aggregateSize=values.aggregateSize,
        roughness=1 - clamp01(values.evenness),
        resilience=values.resilience
    }
    for _, layer in ipairs(self.layers) do
        local modifier = self.modifiers[layer.id]
        if modifier == nil then
            return false, "modifier missing for " .. tostring(layer.id)
        end
        modifier:clearPolygonPoints()
        for _, point in ipairs(points) do
            modifier:addPolygonPointWorldCoords(point.x, point.z)
        end
        modifier:executeSet(encode(
            clamp01(stored[layer.id]), getLayerChannels(layer.id)))
        modifier:clearPolygonPoints()
        self.layerWriteSerial[layer.id] =
            (tonumber(self.layerWriteSerial[layer.id]) or 0) + 1
        self:markServerNetworkRegionChanged(layer.id,
            minimumX, minimumZ, maximumX, maximumZ)
        self.layerCells[layer.id] = {}
        if self.continuousTrafficValues ~= nil
            and self.continuousTrafficValues[layer.id] ~= nil then
            self.continuousTrafficValues[layer.id] = {}
        end
    end
    self.dirty = true
    self.visualizationDirty = true
    self.overlayRefreshTime = 0
    self:clearRuntimeSoilPassCaches()
    return true, string.format("field %s updated",
        tostring(field.fieldId or field.id or "unknown"))
end

-- Reproducible traffic-calibration baseline. This intentionally resets the
-- complete native field beneath the caller; it never runs automatically and
-- is available only through the explicit developer console command.
function TerraLogicSoilManager:applyTrafficTestPresetAtWorldPosition(
        x, z, presetName)
    if g_server == nil then return false, "server unavailable" end
    local name = string.lower(tostring(presetName or ""))
    if name == "natural" or name == "off" then
        local moistureOk, moistureMessage =
            TerraLogicSoilMoistureManager:setAuditPreset("natural")
        local temperatureOk, temperatureMessage =
            TerraLogicSoilTemperatureManager:setAuditPreset("natural")
        if TerraLogicAuditManager ~= nil then
            TerraLogicAuditManager.runtimeEnvironmentPreset = nil
            TerraLogicAuditManager.runtimeSoilPreset = nil
        end
        return moistureOk and temperatureOk,
            tostring(moistureMessage) .. "; " .. tostring(temperatureMessage)
    end
    if name ~= "dry" and name ~= "normal" and name ~= "wet"
        and name ~= "frozen" then
        return false, "unknown preset; use dry, normal, wet, frozen or natural"
    end
    local soilOk, soilMessage = self:setAuditFieldStateAtWorldPosition(
        x, z, {surfaceCompaction=0.28, deepCompaction=0.26,
            aggregateSize=0.50, evenness=0.75, resilience=0.50})
    if not soilOk then return false, soilMessage end
    local moistureOk, moistureMessage =
        TerraLogicSoilMoistureManager:setAuditPreset(name)
    local temperatureOk, temperatureMessage =
        TerraLogicSoilTemperatureManager:setAuditPreset(name)
    if not moistureOk or not temperatureOk then
        return false, tostring(moistureMessage) .. "; "
            .. tostring(temperatureMessage)
    end
    if TerraLogicAuditManager ~= nil then
        TerraLogicAuditManager.runtimeEnvironmentPreset = name
        TerraLogicAuditManager.runtimeSoilPreset = "trafficBaseline"
    end
    return true, string.format(
        "%s traffic baseline applied (surface/deep 28/26%%, tilth/evenness 50/75%%, resilience 50%%); %s; %s",
        name, tostring(moistureMessage), tostring(temperatureMessage))
end

TerraLogicSoilManager.VIRTUAL_PASS_CELLS_PER_FRAME = 192

local function getVirtualPassEngagement(classKey, speedKph, shopSpeedKph)
    local profile = TerraLogicImplementProfiles ~= nil
        and TerraLogicImplementProfiles.PROFILES[classKey] or nil
    local shop = math.max(tonumber(shopSpeedKph) or 0, 0)
    local speed = math.max(tonumber(speedKph) or 0, 0)
    local engagementProfile = profile ~= nil and profile.engagement or nil
    if engagementProfile == nil or shop <= 0 then return 1 end
    local shopRatio = speed / shop
    local startRatio = math.max(
        tonumber(engagementProfile.startRatio) or 1.5, 1)
    local failedRatio = math.max(
        tonumber(engagementProfile.failedRatio) or 2.5,
        startRatio + 0.05)
    local progress = clamp01(
        (shopRatio - startRatio) / (failedRatio - startRatio))
    local smooth = progress * progress * (3 - 2 * progress)
    local minimum = math.clamp(
        tonumber(engagementProfile.minimum) or 0.20, 0.02, 1)
    return 1 - (1 - minimum) * smooth
end

local function getVirtualPassFieldAtPosition(x, z)
    if g_farmlandManager == nil or g_fieldManager == nil
        or g_farmlandManager.getFarmlandAtWorldPosition == nil then
        return nil, nil, "field manager unavailable"
    end
    local farmland = g_farmlandManager:getFarmlandAtWorldPosition(x, z)
    local mapped = farmland ~= nil
        and (g_fieldManager.farmlandIdFieldMapping or {})[farmland.id] or nil
    local candidates = type(mapped) == "table" and mapped[1] ~= nil
        and mapped.getPolygonPoints == nil and mapped or {mapped}
    for _, field in ipairs(candidates) do
        if field ~= nil and field.getPolygonPoints ~= nil then
            local ok, nodes = pcall(field.getPolygonPoints, field)
            if ok and type(nodes) == "table" then
                local polygon = {}
                for _, node in ipairs(nodes) do
                    if node ~= nil and node ~= 0 and entityExists(node) then
                        local px, _, pz = getWorldTranslation(node)
                        polygon[#polygon + 1] = {x=px, z=pz}
                    end
                end
                if #polygon >= 3 and npcPointInPolygon(x, z, polygon) then
                    return field, polygon, nil
                end
            end
        end
    end
    return nil, nil, "no native field polygon at the player position"
end

-- Queues a developer-only virtual implement pass. The job is deliberately
-- incremental: large fields are evaluated over many frames, preventing the
-- command from creating the very hitch it is intended to avoid during tests.
function TerraLogicSoilManager:queueVirtualImplementPassAtWorldPosition(
        x, z, classKey, speedKph, shopSpeedKph)
    if g_server == nil or self.rasterReady ~= true then
        return false, "server soil raster unavailable"
    end
    if self.virtualPassJob ~= nil then
        return false, "another virtual implement pass is still running"
    end
    local profile = TerraLogicSoilProfiles ~= nil
        and TerraLogicSoilProfiles:getProfile(classKey) or nil
    local implementProfile = TerraLogicImplementProfiles ~= nil
        and TerraLogicImplementProfiles.PROFILES[classKey] or nil
    if profile == nil or implementProfile == nil then
        return false, "unsupported implement class " .. tostring(classKey)
    end
    local speed = tonumber(speedKph)
    local shop = tonumber(shopSpeedKph)
    if speed == nil or speed < self.MIN_SOIL_PASS_SPEED_KPH then
        return false, "speed must be at least 0.5 km/h"
    end
    if shop == nil or shop <= 0 then
        return false, "shop speed must be greater than zero"
    end
    local field, polygon, fieldError = getVirtualPassFieldAtPosition(x, z)
    if field == nil then return false, fieldError end
    local minX, minZ, maxX, maxZ = math.huge, math.huge, -math.huge, -math.huge
    for _, point in ipairs(polygon) do
        minX, minZ = math.min(minX, point.x), math.min(minZ, point.z)
        maxX, maxZ = math.max(maxX, point.x), math.max(maxZ, point.z)
    end
    local jobLayers = {}
    for _, layer in ipairs(self.layers) do
        if profile[layer.id] ~= nil
            or (layer.id == "resilience"
                and RESILIENCE_TILLAGE[classKey] ~= nil) then
            local cellSize = getLayerCellSize(layer.id)
            jobLayers[#jobLayers + 1] = {
                id=layer.id, cellSize=cellSize,
                minIx=math.floor(minX/cellSize),
                maxIx=math.ceil(maxX/cellSize)-1,
                minIz=math.floor(minZ/cellSize),
                maxIz=math.ceil(maxZ/cellSize)-1
            }
        end
    end
    if RECOVERY_AGE_WORK[classKey] ~= nil then
        local cellSize = self.RECOVERY_CELL_SIZE
        jobLayers[#jobLayers + 1] = {
            id="recoveryAge", cellSize=cellSize,
            minIx=math.floor(minX/cellSize),
            maxIx=math.ceil(maxX/cellSize)-1,
            minIz=math.floor(minZ/cellSize),
            maxIz=math.ceil(maxZ/cellSize)-1
        }
    end
    if #jobLayers == 0 then
        return false, "implement class has no persistent soil effect"
    end
    local totalCandidateCells = 0
    for _, layer in ipairs(jobLayers) do
        totalCandidateCells = totalCandidateCells
            + (layer.maxIx-layer.minIx+1) * (layer.maxIz-layer.minIz+1)
    end
    local fieldId = getNpcFieldId(field, nil)
    self.virtualPassJob = {
        classKey=classKey, speedKph=speed, shopSpeedKph=shop,
        workDepthCm=implementProfile.work ~= nil
            and tonumber(implementProfile.work.depthCm) or 0,
        fieldId=fieldId, polygon=polygon, bounds={minX=minX, minZ=minZ,
            maxX=maxX, maxZ=maxZ}, layers=jobLayers, layerIndex=1,
        ix=jobLayers[1].minIx, iz=jobLayers[1].minIz,
        totalCandidateCells=totalCandidateCells,
        testedCells=0, fieldCells=0, changedCells=0,
        changedLayers={}
    }
    local optimum = select(1, TerraLogicImplementProfiles.getOptimalSpeed(
        shop, classKey, implementProfile))
    Logging.info(
        "[FS25_TerraLogic] Virtual pass queued: field=%s class=%s speed=%.1f shop=%.1f optimum=%.1f",
        tostring(fieldId), tostring(classKey), speed, shop,
        tonumber(optimum) or shop)
    return true, string.format(
        "field %s queued: %s at %.1f km/h (shop %.1f)",
        tostring(fieldId), tostring(classKey), speed, shop)
end

function TerraLogicSoilManager:updateVirtualImplementPass()
    local job = self.virtualPassJob
    if job == nil or self.rasterReady ~= true then return end
    local budget = self.VIRTUAL_PASS_CELLS_PER_FRAME
    while budget > 0 and job.layerIndex <= #job.layers do
        local layer = job.layers[job.layerIndex]
        local ix, iz = job.ix, job.iz
        local x = (ix + 0.5) * layer.cellSize
        local z = (iz + 0.5) * layer.cellSize
        job.testedCells = job.testedCells + 1
        if npcPointInPolygon(x, z, job.polygon) then
            local surface = TerraLogicQualityManager ~= nil
                and TerraLogicQualityManager:getSurfaceTypeAtWorldPosition(x, z)
                or "field"
            if surface == "field" or surface == "grassField" then
                job.fieldCells = job.fieldCells + 1
                if layer.id == "recoveryAge" then
                    local rule = RECOVERY_AGE_WORK[job.classKey]
                    local age = self:getRecoveryAgeAtWorldPosition(x, z)
                    local engagement = getVirtualPassEngagement(
                        job.classKey, job.speedKph, job.shopSpeedKph)
                    local continuity = getBiologicalContinuityFromAge(age)
                    local nextContinuity = self:applyContinuityRule(
                        continuity, job.classKey, engagement)
                    local nextAge = nextContinuity < continuity
                        and getAgeFromBiologicalContinuity(nextContinuity) or age
                    if nextAge ~= age
                        and self:setRecoveryAgeCell(ix, iz, nextAge) then
                        job.changedCells = job.changedCells + 1
                    end
                else
                    local state = self:getStateAtWorldPosition(x, z)
                    local soilType = self:getPFSoilTypeAtWorldPosition(x, z)
                    local projected = self:previewOperationFromState(
                        state, soilType, job.classKey, job.workDepthCm,
                        job.speedKph, job.shopSpeedKph, ix, iz)
                    local nextValue = projected[layer.id]
                    local current = state[layer.id]
                    if nextValue ~= nil and math.abs(
                            (tonumber(nextValue) or 0)-(tonumber(current) or 0))
                        >= 0.0001 then
                        -- One revision per affected network tile is emitted
                        -- after the bulk job. Incrementing it for every cell
                        -- would create avoidable traffic and rapid overflow.
                        self:setStateCell(
                            layer.id, ix, iz, nextValue, true)
                        job.changedLayers[layer.id] = true
                        job.changedCells = job.changedCells + 1
                    end
                end
            end
        end
        budget = budget - 1
        job.ix = job.ix + 1
        if job.ix > layer.maxIx then
            job.ix = layer.minIx
            job.iz = job.iz + 1
        end
        if job.iz > layer.maxIz then
            job.layerIndex = job.layerIndex + 1
            local nextLayer = job.layers[job.layerIndex]
            if nextLayer ~= nil then
                job.ix, job.iz = nextLayer.minIx, nextLayer.minIz
            end
        end
    end
    if job.layerIndex > #job.layers then
        for layerId in pairs(job.changedLayers) do
            self:markServerNetworkRegionChanged(layerId,
                job.bounds.minX, job.bounds.minZ,
                job.bounds.maxX, job.bounds.maxZ)
        end
        self.virtualPassLastResult = {
            fieldId=job.fieldId, classKey=job.classKey,
            speedKph=job.speedKph, shopSpeedKph=job.shopSpeedKph,
            testedCells=job.testedCells, fieldCells=job.fieldCells,
            changedCells=job.changedCells
        }
        self.virtualPassJob = nil
        self.dirty, self.visualizationDirty = true, true
        self.overlayRefreshTime = 0
        Logging.info(
            "[FS25_TerraLogic] Virtual pass complete: field=%s class=%s speed=%.1f shop=%.1f tested=%d field=%d changed=%d",
            tostring(job.fieldId), tostring(job.classKey), job.speedKph,
            job.shopSpeedKph, job.testedCells, job.fieldCells,
            job.changedCells)
    end
end

function TerraLogicSoilManager:getVirtualImplementPassStatus()
    local job = self.virtualPassJob
    if job ~= nil then
        local totalLayers = math.max(#job.layers, 1)
        local progress = math.clamp(job.testedCells
            / math.max(tonumber(job.totalCandidateCells) or 1, 1), 0, 0.99)
        return string.format(
            "running: field %s, %s %.1f/%.1f km/h, layer %d/%d (~%.0f%%)",
            tostring(job.fieldId), tostring(job.classKey), job.speedKph,
            job.shopSpeedKph, job.layerIndex, totalLayers, progress*100)
    end
    local last = self.virtualPassLastResult
    if last ~= nil then
        return string.format(
            "idle; last: field %s, %s %.1f/%.1f km/h, %d cells changed",
            tostring(last.fieldId), tostring(last.classKey), last.speedKph,
            last.shopSpeedKph, last.changedCells)
    end
    return "idle; no virtual pass run this session"
end

-- Applies one already de-duplicated wheel/axle passage to a soil cell. Wheel
-- sampling and vehicle physics remain in their own manager; this function is
-- the single persistence boundary for wheel-induced soil changes.  Validate
-- every cell centre independently: a wheel contact confirmed on-field must
-- never authorize neighbouring or interpolated non-field cells.
-- Shared soil susceptibility, excluding load, coverage and distance to target.
-- Moisture's target shifts remain separate; frost only reduces the impulse.
local NEUTRAL_TRAFFIC_TEXTURE = {surface=1, deep=1}
function TerraLogicSoilManager:getTrafficSensitivityFactors(
        soilType, resilience, surfaceMoisture, deepMoisture,
        surfaceFrozen, deepFrozen, texture)
    texture = texture or TerraLogicSoilProfiles:getPFTrafficResponse(soilType)
        or NEUTRAL_TRAFFIC_TEXTURE
    local biology = 1.30 - 0.60 * clamp01(resilience or 0.50)
    return (texture.surface or 1) * biology * (surfaceMoisture or 1)
            * (surfaceFrozen and 0.20 or 1),
        (texture.deep or 1) * biology * (deepMoisture or 1)
            * (deepFrozen and 0.35 or 1) * self.DEEP_TRAFFIC_RATE
end

function TerraLogicSoilManager:applyWheelCompactionCell(ix, iz, impact)
    if g_server == nil or impact == nil then return false end
    if self.deepMapMigration ~= nil then return false end
    local inputCellSize = tonumber(impact.cellSize) or self.WHEEL_CELL_SIZE
    local x = (ix + 0.5) * inputCellSize
    local z = (iz + 0.5) * inputCellSize
    local surface = TerraLogicQualityManager ~= nil
        and TerraLogicQualityManager:getSurfaceTypeAtWorldPosition(x, z) or nil
    if surface ~= "field" and surface ~= "grassField" then return false end

    local state = self:getStateAtWorldPosition(x, z)
    local beforeState = {
        surfaceCompaction=state.surfaceCompaction,
        deepCompaction=state.deepCompaction,
        aggregateSize=state.aggregateSize,
        roughness=state.roughness,
        resilience=state.resilience
    }
    local surfaceBefore = state.surfaceCompaction
    local deepBefore = state.deepCompaction
    -- Biological structure changes susceptibility, never the physical target.
    -- Resilience remains a bounded susceptibility modifier and never replaces
    -- axle load or ground contact pressure. The steeper 0.70..1.30 range makes several
    -- seasons of biological progress tangible while preserving hierarchy.
    local resilience = clamp01(state.resilience
        or TerraLogicSoilProfiles.DEFAULTS.resilience)
    local resilienceTrafficMultiplier = 1.30 - 0.60 * resilience
    local moistureSoilType = self:getPFSoilTypeAtWorldPosition(x, z)
    local trafficResponse = TerraLogicSoilProfiles:getPFTrafficResponse(
        moistureSoilType)
    local moistureSurfaceMultiplier, moistureDeepMultiplier = 1, 1
    local moistureState = nil
    local moistureMechanics = nil
    if TerraLogicSoilMoistureManager ~= nil then
        moistureSurfaceMultiplier, moistureDeepMultiplier =
            TerraLogicSoilMoistureManager:getTrafficMultipliers(
                moistureSoilType)
        moistureState = TerraLogicSoilMoistureManager:getStateAtWorldPosition(
            x, z)
        moistureMechanics =
            TerraLogicSoilMoistureManager:getMechanicalResponse(
                moistureSoilType, nil, 5)
    end
    local changed = false
    local changedLayerIds, changedLayerCount = {}, 0
    local activeLayer = self.layers[self.activeMapMode]
    local activeLayerId = activeLayer ~= nil and activeLayer.id or nil
    local activeLayerChanged = false
    local structureMode = "none"
    local structureAggregateTarget, structureAggregateStrength = nil, 0
    local structureRoughnessTarget, structureRoughnessStrength = nil, 0

    local function moveTowards(layerId, target, strength)
        if target == nil or strength == nil or strength <= 0 then return end
        local current = state[layerId]
        -- Traffic can only worsen these four states. A light wheel must never
        -- "repair" soil that was previously compacted or smeared more heavily.
        if target <= current then return end
        local nextValue = clamp01(current
            + (clamp01(target) - current) * clamp01(strength))
        -- Deep traffic and the continuous sub-50-kPa surface response can be
        -- smaller than one visible raster step. Preserve those changes in the
        -- existing in-session precision cache so repeated light passes build
        -- up instead of disappearing. Standard surface traffic retains its
        -- established one-thousandth write threshold.
        local preserveWeakTraffic = layerId == "deepCompaction"
            or (layerId == "surfaceCompaction"
                and impact.surfaceLowPressureResponse == true)
        local minimumDelta = preserveWeakTraffic and 0.000001 or 0.001
        if math.abs(nextValue - current) > minimumDelta then
            local _, layerIx, layerIz = self:setStateAtWorldPosition(
                layerId, x, z, nextValue)
            state[layerId] = nextValue
            if preserveWeakTraffic then
                self.continuousTrafficValues = self.continuousTrafficValues
                    or {}
                self.continuousTrafficValues[layerId] =
                    self.continuousTrafficValues[layerId] or {}
                self.continuousTrafficValues[layerId][
                    getCellKey(layerIx, layerIz)] = nextValue
            end
            changed = true
            if not changedLayerIds[layerId] then
                changedLayerIds[layerId] = true
                changedLayerCount = changedLayerCount + 1
            end
            activeLayerChanged = activeLayerChanged or layerId == activeLayerId
            self.lastWrite = {
                classKey = "wheelCompaction", layerId = layerId,
                ix = layerIx, iz = layerIz, beforeValue = current,
                value = nextValue, delta = nextValue - current,
                sourceName = impact.sourceVehicleName,
                sourceConfigFileName = impact.sourceConfigFileName,
                time = g_currentMission ~= nil and g_currentMission.time or 0
            }
        end
    end

    local function moveStructureTowards(layerId, target, strength)
        if target == nil or strength == nil or strength <= 0 then return end
        local current = state[layerId]
        local nextValue = clamp01(current
            + (clamp01(target) - current) * clamp01(strength))
        if math.abs(nextValue - current) > 0.001 then
            local _, layerIx, layerIz = self:setStateAtWorldPosition(
                layerId, x, z, nextValue)
            state[layerId] = nextValue
            -- Aggregate and roughness use a six-bit raster. Keep the exact
            -- in-session value as well, otherwise a realistic weak tyre pass
            -- below one raster step would disappear instead of accumulating
            -- over repeated traffic. Saving still rounds to the authoritative
            -- raster and therefore does not add savegame or network payload.
            self.continuousTrafficValues = self.continuousTrafficValues or {}
            self.continuousTrafficValues[layerId] =
                self.continuousTrafficValues[layerId] or {}
            self.continuousTrafficValues[layerId][
                getCellKey(layerIx, layerIz)] = nextValue
            changed = true
            if not changedLayerIds[layerId] then
                changedLayerIds[layerId] = true
                changedLayerCount = changedLayerCount + 1
            end
            activeLayerChanged = activeLayerChanged or layerId == activeLayerId
            self.lastWrite = {
                classKey = "wheelStructure", layerId = layerId,
                ix = layerIx, iz = layerIz, beforeValue = current,
                value = nextValue, delta = nextValue - current,
                sourceName = impact.sourceVehicleName,
                sourceConfigFileName = impact.sourceConfigFileName,
                time = g_currentMission ~= nil and g_currentMission.time or 0
            }
        end
    end

    local textureSurfaceMultiplier = trafficResponse ~= nil
        and trafficResponse.surface or 1
    local textureDeepMultiplier = trafficResponse ~= nil
        and trafficResponse.deep or 1
    -- Moisture changes soil strength and therefore both the immediate impulse
    -- and the load-dependent equilibrium. Previously it only multiplied the
    -- impulse, which meant wet soil reached exactly the same modest ceiling as
    -- dry soil. The asymmetric shifts keep dry ground protective without
    -- making it immune, while allowing ordinary heavy vehicles to create
    -- severe compaction under genuinely wet conditions.
    local function moistureAdjustedTarget(baseTarget, multiplier,
            wetShift, dryShift)
        if baseTarget == nil then return nil end
        -- Traffic moisture impulses retain their 50% moderation. Recover the
        -- original positive moisture excursion for targets only; dry shifts
        -- and neutral targets must remain bit-for-bit unchanged.
        local wet = clamp01(((tonumber(multiplier) or 1) - 1) * 2 / 0.58)
        local dry = clamp01((1 - (tonumber(multiplier) or 1)) / 0.28)
        return clamp01(baseTarget + wetShift * wet - dryShift * dry)
    end
    local appliedSurfaceTarget = moistureAdjustedTarget(
        impact.surfaceTarget, moistureSurfaceMultiplier, 0.18, 0.08)
    local appliedDeepTarget = moistureAdjustedTarget(
        impact.deepTarget, moistureDeepMultiplier, 0.15, 0.06)
    local surfaceFrostProtection = moistureState ~= nil
        and moistureState.surfaceFrozen and 0.20 or 1
    local deepFrostProtection = moistureState ~= nil
        and moistureState.subsoilFrozen and 0.35 or 1
    local surfaceSensitivity, deepSensitivity = self:getTrafficSensitivityFactors(
        moistureSoilType, resilience, moistureSurfaceMultiplier, moistureDeepMultiplier,
        surfaceFrostProtection < 1, deepFrostProtection < 1, trafficResponse)
    -- A one-metre surface cell stores its mean state. The wheel manager
    -- supplies the union of the projected tyre/belt strips inside that cell;
    -- narrow support wheels therefore retain their local pressure target but
    -- no longer compact an entire one-metre-wide strip at full strength.
    local surfaceCoverage = impact.surfaceTarget ~= nil
        and clamp01(tonumber(impact.surfaceCoverage) or 1) or 0
    local appliedSurfaceStrength = (tonumber(impact.surfaceStrength) or 0)
        * surfaceSensitivity * surfaceCoverage
    -- A two-metre deep-compaction cell stores the mean state of 4 m2. The
    -- wheel manager supplies the union of the axle's projected subsoil stress
    -- bands inside that cell.  Legacy callers without this field retain the
    -- former full-cell behaviour.
    local deepCoverage = impact.deepTarget ~= nil
        and clamp01(tonumber(impact.deepCoverage) or 1) or 0
    local appliedDeepStrength = (tonumber(impact.deepStrength) or 0)
        * deepSensitivity * deepCoverage
    moveTowards("surfaceCompaction", appliedSurfaceTarget,
        appliedSurfaceStrength)
    moveTowards("deepCompaction", appliedDeepTarget,
        appliedDeepStrength)

    -- Normal rolling acts on the two-metre seedbed cell only once per physical
    -- pass. Contact pressure supplies the mechanical driver; texture,
    -- resilience and liquid moisture decide whether the result is useful
    -- crumbling, dry pulverization, smoothing or wet clodding/rutting.
    if impact.structurePass == true and surface == "field" then
        local pressureDriver = clamp01(impact.structurePressureDriver)
        local drySeverity = moistureMechanics ~= nil
            and clamp01(moistureMechanics.drySeverity) or 0
        local wetSeverity = moistureMechanics ~= nil
            and clamp01(moistureMechanics.wetSeverity) or 0
        local structureResilienceMultiplier = 1.10 - 0.20 * resilience
        local baseStrength = (0.018 + 0.075 * pressureDriver)
            * textureSurfaceMultiplier * structureResilienceMultiplier
            * (moistureState ~= nil and moistureState.surfaceFrozen
                and 0.15 or 1)
        local aggregate = state.aggregateSize
        if wetSeverity > 0.15 then
            structureMode = "wet clodding/rutting"
            structureAggregateTarget = 0.38
            structureAggregateStrength = baseStrength
                * (0.25 + 0.45 * wetSeverity)
        elseif aggregate < 0.50 then
            structureMode = drySeverity > 0.20
                and "dry clod crushing" or "clod crumbling"
            structureAggregateTarget = 0.50
                + 0.12 * drySeverity * pressureDriver
            structureAggregateStrength = baseStrength
                * (0.80 + 0.35 * drySeverity)
        elseif drySeverity > 0.20 and pressureDriver > 0.20 then
            structureMode = "dry pulverization"
            structureAggregateTarget = 0.62
            structureAggregateStrength = baseStrength
                * 0.35 * drySeverity
        else
            structureMode = moistureState ~= nil
                and moistureState.surfaceFrozen
                and "frozen surface (limited)" or "surface smoothing"
        end
        if wetSeverity > 0.25 then
            structureRoughnessTarget = 0.62
            structureRoughnessStrength = baseStrength
                * (0.35 + 0.65 * wetSeverity)
        else
            structureRoughnessTarget = 0.08
            structureRoughnessStrength = baseStrength
                * (0.65 + 0.20 * drySeverity)
        end
        if moistureState ~= nil and moistureState.surfaceFrozen then
            structureMode = "frozen surface (limited)"
        end
        moveStructureTowards("aggregateSize",
            structureAggregateTarget, structureAggregateStrength)
        moveStructureTowards("roughness",
            structureRoughnessTarget, structureRoughnessStrength)
    end

    -- Deep increments already include coverage. Integrate their area into
    -- the biology cell; no second coverage multiplier or per-sample minimum.
    local deepIncrease = math.max(
        (state.deepCompaction or deepBefore) - deepBefore, 0)
    local surfaceIncrease = math.max(
        (state.surfaceCompaction or surfaceBefore) - surfaceBefore, 0)
    if deepIncrease > 0 then
        local resilienceIx = math.floor(x / self.RESILIENCE_CELL_SIZE)
        local resilienceIz = math.floor(z / self.RESILIENCE_CELL_SIZE)
        local resilienceKey = getCellKey(resilienceIx, resilienceIz)
        local areaShare = math.min(inputCellSize * inputCellSize
            / (self.RESILIENCE_CELL_SIZE * self.RESILIENCE_CELL_SIZE), 1)
        -- Calibrated to the former local response at a 1 pp deep increment.
        -- Exponential integration preserves subdivision invariance.
        local exposure = 0.35 * deepIncrease * areaShare
        local currentResilience = state.resilience
        local nextResilience = clamp01(currentResilience * math.exp(-exposure))
        if nextResilience < currentResilience then
            local channels = getLayerChannels("resilience")
            if encode(nextResilience, channels) ~= encode(currentResilience, channels) then
                self:setStateCell("resilience", resilienceIx, resilienceIz,
                    nextResilience)
                activeLayerChanged = activeLayerChanged
                    or activeLayerId == "resilience"
                self:markResilienceChanged()
            end
            -- Retain sub-raster changes without map/network invalidations.
            self.continuousTrafficValues = self.continuousTrafficValues or {}
            self.continuousTrafficValues.resilience =
                self.continuousTrafficValues.resilience or {}
            self.continuousTrafficValues.resilience[resilienceKey] = nextResilience
            state.resilience = nextResilience
            changed = true
            if not changedLayerIds.resilience then
                changedLayerIds.resilience = true
                changedLayerCount = changedLayerCount + 1
            end
        end
    end

    -- Wheel traffic retains its compaction and resilience effects above.
    -- Biological continuity is interrupted by implement work, not wheel contact.

    -- Excessive slip smears and shears the seedbed. It is intentionally a
    -- topsoil effect: it makes structure too fine and the surface uneven, but
    -- does not create artificial deep compaction.
    local slip = clamp01(impact.slipSeverity)
    if slip > 0 then
        structureMode = "wheel slip/shear"
        local slipStructureMultiplier = textureSurfaceMultiplier
            * (1.10 - 0.20 * resilience)
            * (moistureState ~= nil and moistureState.surfaceFrozen
                and 0.20 or 1)
        if surface == "field" then
            structureAggregateTarget = 0.88
            structureAggregateStrength = (0.08 + 0.24 * slip)
                * slipStructureMultiplier
        else
            structureAggregateTarget = nil
            structureAggregateStrength = 0
        end
        structureRoughnessTarget = 0.72
        structureRoughnessStrength = (0.07 + 0.25 * slip)
            * slipStructureMultiplier
        moveStructureTowards("aggregateSize",
            structureAggregateTarget, structureAggregateStrength)
        moveStructureTowards("roughness",
            structureRoughnessTarget, structureRoughnessStrength)
    end

    if changed then
        self.dirty = true
        self.lastPass = {
            classKey = "wheelCompaction", coverage = 0,
            touchedCells = 1, eligibleCells = 1,
            changedCells = 1, changedLayers = changedLayerCount,
            time = g_currentMission ~= nil and g_currentMission.time or 0
        }
    end
    if activeLayerChanged then
        local now = g_currentMission ~= nil and g_currentMission.time or 0
        if not self.visualizationDirty then
            self.overlayRefreshTime = now + self.OVERLAY_REFRESH_DELAY_MS
        end
        self.visualizationDirty = true
    end
    local afterState = {
        surfaceCompaction=state.surfaceCompaction,
        deepCompaction=state.deepCompaction,
        aggregateSize=state.aggregateSize,
        roughness=state.roughness,
        resilience=state.resilience
    }
    local detail = {
        time=g_currentMission ~= nil and g_currentMission.time or 0,
        x=x, z=z, inputCellSize=inputCellSize,
        fieldConfirmed=impact.fieldConfirmed == true,
        soilTypeIndex=tonumber(moistureSoilType) or 0,
        soilName=moistureState ~= nil
            and moistureState.profileName or "Generic",
        pfActive=moistureState ~= nil and moistureState.pfActive == true,
        moistureSurface=moistureState ~= nil
            and moistureState.surface or 0.5,
        moistureSubsoil=moistureState ~= nil
            and moistureState.subsoil or 0.5,
        liquidSurface=moistureState ~= nil
            and moistureState.liquidSurface or 0.5,
        surfaceFrozen=moistureState ~= nil
            and moistureState.surfaceFrozen == true,
        drySeverity=moistureMechanics ~= nil
            and moistureMechanics.drySeverity or 0,
        wetSeverity=moistureMechanics ~= nil
            and moistureMechanics.wetSeverity or 0,
        trafficSurfaceMultiplier=moistureSurfaceMultiplier,
        trafficDeepMultiplier=moistureDeepMultiplier,
        surfaceTrafficSensitivity=surfaceSensitivity,
        deepTrafficSensitivity=deepSensitivity,
        textureSurfaceMultiplier=textureSurfaceMultiplier,
        textureDeepMultiplier=textureDeepMultiplier,
        resilience=resilience,
        resilienceTrafficMultiplier=resilienceTrafficMultiplier,
        surfaceBaseTarget=tonumber(impact.surfaceTarget) or 0,
        surfaceTarget=tonumber(appliedSurfaceTarget) or 0,
        surfaceBaseStrength=tonumber(impact.surfaceStrength) or 0,
        surfaceCoverage=surfaceCoverage,
        surfaceAppliedStrength=appliedSurfaceStrength,
        surfaceLowPressureResponse=
            impact.surfaceLowPressureResponse == true,
        deepBaseTarget=tonumber(impact.deepTarget) or 0,
        deepTarget=tonumber(appliedDeepTarget) or 0,
        deepBaseStrength=tonumber(impact.deepStrength) or 0,
        deepCoverage=deepCoverage,
        deepCoveredWidthM=tonumber(impact.deepCoveredWidthM) or 0,
        deepAppliedStrength=appliedDeepStrength,
        structurePass=impact.structurePass == true,
        structureMode=structureMode,
        structurePressureDriver=tonumber(
            impact.structurePressureDriver) or 0,
        pressureKPa=tonumber(impact.structurePressureKPa)
            or tonumber(impact.surfacePressureKPa) or 0,
        wheelLoadT=tonumber(impact.structureWheelLoadT)
            or tonumber(impact.surfaceWheelLoadT) or 0,
        tireWidthM=tonumber(impact.structureWidthM)
            or tonumber(impact.surfaceWidthM) or 0,
        tireDiameterM=tonumber(impact.structureDiameterM)
            or tonumber(impact.surfaceDiameterM) or 0,
        contactLengthM=tonumber(impact.structureContactLengthM)
            or tonumber(impact.surfaceContactLengthM) or 0,
        tireCount=tonumber(impact.structureTireCount)
            or tonumber(impact.surfaceTireCount) or 0,
        crawler=impact.structureCrawler == true
            or impact.surfaceCrawler == true,
        wheelIndex=tonumber(impact.surfaceWheelIndex) or 0,
        wheelNodeName=tostring(impact.surfaceWheelNodeName or ""),
        wheelExternalFilename=tostring(
            impact.surfaceWheelExternalFilename or ""),
        wheelVisualCount=tonumber(impact.surfaceWheelVisualCount) or 0,
        wheelRestLoadT=tonumber(impact.surfaceWheelRestLoadT) or 0,
        workingImplementSurfaceSuppressed=
            impact.workingImplementSurfaceSuppressed == true,
        suppressedSurfaceContacts=tonumber(
            impact.suppressedSurfaceContacts) or 0,
        maxSuppressedSurfaceTarget=tonumber(
            impact.maxSuppressedSurfaceTarget) or 0,
        maxSuppressedSurfaceStrength=tonumber(
            impact.maxSuppressedSurfaceStrength) or 0,
        maxSuppressedPressureKPa=tonumber(
            impact.maxSuppressedPressureKPa) or 0,
        maxSuppressedWheelLoadT=tonumber(
            impact.maxSuppressedWheelLoadT) or 0,
        maxSuppressedWheelIndex=tonumber(
            impact.maxSuppressedWheelIndex) or 0,
        maxSuppressedWheelNodeName=tostring(
            impact.maxSuppressedWheelNodeName or ""),
        maxSuppressedWheelExternalFilename=tostring(
            impact.maxSuppressedWheelExternalFilename or ""),
        maxSuppressedWheelRestLoadT=tonumber(
            impact.maxSuppressedWheelRestLoadT) or 0,
        maxSuppressedWheelVisualCount=tonumber(
            impact.maxSuppressedWheelVisualCount) or 0,
        implementRuntimeState=impact.implementRuntimeState,
        vehicleName=tostring(impact.sourceVehicleName or "vehicle"),
        configFileName=tostring(impact.sourceConfigFileName or ""),
        vehicleMassT=tonumber(impact.sourceVehicleMassT) or 0,
        supportedLoadT=tonumber(impact.sourceSupportedLoadT) or 0,
        wheelCount=tonumber(impact.sourceWheelCount) or 0,
        axleCount=tonumber(impact.sourceAxleCount) or 0,
        maxAxleLoadT=tonumber(impact.sourceMaxAxleLoadT) or 0,
        meanAxleLoadT=tonumber(impact.sourceMeanAxleLoadT) or 0,
        meanPressureKPa=tonumber(impact.sourceMeanPressureKPa) or 0,
        maxPressureKPa=tonumber(impact.sourceMaxPressureKPa) or 0,
        slipSeverity=slip,
        correctedSlip=tonumber(impact.correctedSlip) or 0,
        rawSlip=tonumber(impact.rawSlip) or 0,
        aggregateTarget=structureAggregateTarget,
        aggregateStrength=structureAggregateStrength,
        roughnessTarget=structureRoughnessTarget,
        roughnessStrength=structureRoughnessStrength,
        before=beforeState, after=afterState,
        changed=changed, changedLayers=changedLayerIds,
        changedLayerCount=changedLayerCount
    }
    detail.delta = {
        surfaceCompaction=afterState.surfaceCompaction
            - beforeState.surfaceCompaction,
        deepCompaction=afterState.deepCompaction
            - beforeState.deepCompaction,
        aggregateSize=afterState.aggregateSize-beforeState.aggregateSize,
        roughness=afterState.roughness-beforeState.roughness,
        resilience=afterState.resilience-beforeState.resilience
    }
    self.lastWheelImpactDebug = detail
    return changed, detail
end

local function applyRule(current, rule, strengthMultiplier, targetOffset)
    if rule == nil then return current end
    local target = clamp01((tonumber(rule.target) or 0)
        + (tonumber(targetOffset) or 0))
    if rule.mode == "reduceOnly" and current <= target then return current end
    if rule.mode == "increaseOnly" and current >= target then return current end
    local strength = clamp01(clamp01(rule.strength)
        * math.max(tonumber(strengthMultiplier) or 1, 0))
    local delta = (target - current) * strength
    if rule.maxDelta ~= nil then
        local cap = math.max(tonumber(rule.maxDelta) or 0, 0)
            * clamp01(tonumber(strengthMultiplier) or 1)
        delta = math.max(-cap, math.min(cap, delta))
    end
    return clamp01(current + delta)
end

-- Applies the environmental soil reaction once and caps its per-pass delta.
-- Keeping this helper shared is important: Planner/virtual-pass previews and
-- actual WorkArea writes must never disagree about moisture consequences.
local function applyMoistureSoilReaction(
        classKey, layerId, nextValue, response, engagement)
    local rule, severity, maximumDelta = getMoistureAdverseRule(
        classKey, layerId, response)
    if rule == nil or severity <= 0 then return nextValue end
    local engaged = clamp01(engagement or 1)
    local reacted = applyRule(nextValue, rule, severity * engaged)
    local cap = math.max(tonumber(maximumDelta) or 0, 0)
        * severity * engaged
    if cap > 0 then
        reacted = math.max(nextValue - cap,
            math.min(nextValue + cap, reacted))
    end
    return clamp01(reacted)
end

-- Stable cell noise models irregular local effects of an uncontrolled fast
-- pass without allocating another density map. Server, clients and a reloaded
-- save therefore resolve the same local pattern.
local function getOperationCellVariation(ix, iz, layerId)
    local salt = layerId == "aggregateSize" and 193
        or (layerId == "rollerImpact" and 617 or 389)
    local value = (math.abs(ix) * 73856093 + math.abs(iz) * 19349663
        + salt * 83492791) % 104729
    return value / 104729 * 2 - 1
end

-- Primary inversion can expose coherent furrow slices from below and may
-- therefore make an over-fine surface physically coarser again. It does not,
-- however, recreate stable crumbs in one pass. Bound that reverse transition
-- by texture, current moisture and resilience. Secondary tools never call
-- this helper: their aggregate rules are strictly fragmentation-only.
local INVERSION_COARSENING_LIMIT = {
    [0]=0.16, -- generic fallback
    [1]=0.08, -- loamy sand: little cohesion, few newly formed clods
    [2]=0.14, -- sandy loam
    [3]=0.20, -- loam
    [4]=0.28  -- silty clay can lift coherent blocks/furrow slices
}

local function getBoundedInversionRule(
        classKey, layerId, current, rule, targetOffset,
        soilTypeIndex, moistureResponse, resilience)
    if layerId ~= "aggregateSize"
        or (classKey ~= "plow" and classKey ~= "spader")
        or current <= 0.50 or rule == nil then
        return rule, targetOffset, false
    end
    local texture = tonumber(soilTypeIndex) or 0
    local maximumShift = INVERSION_COARSENING_LIMIT[texture]
        or INVERSION_COARSENING_LIMIT[0]
    local dry = moistureResponse ~= nil
        and clamp01(moistureResponse.drySeverity) or 0
    local wet = moistureResponse ~= nil
        and clamp01(moistureResponse.wetSeverity) or 0
    local cohesion = texture == 4 and 1
        or (texture == 3 and 0.65 or (texture == 2 and 0.35 or 0.10))
    -- Cohesive soils can form hard dry or plastic wet clods. Sandy soils do
    -- not gain the same reverse transition merely because they are extreme.
    local moistureFactor = 1
        + dry * (0.18 * cohesion - 0.04)
        + wet * (0.24 * cohesion - 0.03)
    local stabilityFactor = 0.82 + 0.18 * clamp01(resilience)
    maximumShift = math.max(maximumShift
        * moistureFactor * stabilityFactor, 0.03)
    local physicalTarget = clamp01((tonumber(rule.target) or 0)
        + (tonumber(targetOffset) or 0))
    local boundedTarget = math.max(physicalTarget,
        current - maximumShift)
    local boundedRule = {}
    for key, value in pairs(rule) do boundedRule[key] = value end
    boundedRule.target = boundedTarget
    return boundedRule, 0, true
end

local function getVirtualPassSpeedState(classKey, speedKph, shopSpeedKph)
    local profile = TerraLogicImplementProfiles ~= nil
        and TerraLogicImplementProfiles.PROFILES[classKey] or nil
    local shop = math.max(tonumber(shopSpeedKph) or 0, 0)
    local speed = math.max(tonumber(speedKph) or 0, 0)
    if profile == nil or shop <= 0 then return 0, 1, 0, shop end
    local optimum = select(1, TerraLogicImplementProfiles.getOptimalSpeed(
        shop, classKey, profile))
    optimum = math.max(tonumber(optimum) or shop, 0.01)
    local speedRatio = speed / optimum
    local severity = 0
    if speedRatio > 1 then
        local t = clamp01((speedRatio - 1) / 1.5)
        local base = t * t * (3 - 2 * t)
        severity = 1 - (1 - base) ^ 1.35
    end
    local engagement = getVirtualPassEngagement(
        classKey, speedKph, shopSpeedKph)
    return severity, engagement, speedRatio, optimum
end

-- Read-only one-pass preview used by Field Analysis and the virtual-pass audit
-- command. It deliberately reuses normal targets, PF texture, moisture/frost,
-- bounded inversion and (when supplied) speed/engagement consequences. Wear is
-- assumed to be zero and vehicle traffic remains separate.
function TerraLogicSoilManager:previewOperationFromState(
        state, soilTypeIndex, classKey, workDepthCm,
        speedKph, shopSpeedKph, variationIx, variationIz)
    local projected = {}
    for _, layerId in ipairs({"surfaceCompaction", "deepCompaction",
            "aggregateSize", "roughness", "resilience"}) do
        projected[layerId] = clamp01(state ~= nil and state[layerId] or 0.5)
    end
    local profile = TerraLogicSoilProfiles ~= nil
        and TerraLogicSoilProfiles:getProfile(classKey) or nil
    if profile == nil then return projected end
    local overspeedSeverity, engagement = getVirtualPassSpeedState(
        classKey, speedKph, shopSpeedKph)
    local rollerContact = classKey == "roller"
        and TerraLogicSoilProfiles:getRollerContactEfficiency(
            projected, speedKph, shopSpeedKph) or 1
    local overspeed = profile.overspeed
    for _, layerId in ipairs({"surfaceCompaction", "deepCompaction",
            "aggregateSize", "roughness"}) do
        local rule = profile[layerId]
        if rule ~= nil then
            local current = projected[layerId]
            local moistureResponse = TerraLogicSoilMoistureManager ~= nil
                and TerraLogicSoilMoistureManager:getMechanicalResponse(
                    soilTypeIndex, classKey, workDepthCm or 0) or nil
            local soilResponse = TerraLogicSoilProfiles:getPFSoilResponse(
                soilTypeIndex, classKey)
            local textureStrength = soilResponse ~= nil
                and tonumber(soilResponse.strength[layerId]) or 1
            local effectiveness = moistureResponse ~= nil
                and tonumber(moistureResponse.soilEffectiveness) or 1
            local minimumStrength = overspeed ~= nil
                and overspeed.strengthScale ~= nil
                and tonumber(overspeed.strengthScale[layerId]) or 1
            local speedStrength = 1 - overspeedSeverity
                * (1 - clamp01(minimumStrength))
            local targetOffset = soilResponse ~= nil
                and tonumber(soilResponse.targetOffset[layerId]) or 0
            local effectiveRule, effectiveOffset, inversionBounded =
                getBoundedInversionRule(classKey, layerId, current, rule,
                    targetOffset, soilTypeIndex, moistureResponse,
                    projected.resilience)
            local nextValue = applyRule(current, effectiveRule,
                textureStrength * effectiveness * speedStrength * engagement
                    * rollerContact,
                effectiveOffset)
            if inversionBounded and nextValue < 0.50
                and math.abs(nextValue - 0.50)
                    < math.abs(current - 0.50) then
                nextValue = clamp01(1 - current)
            end
            local speedRule = overspeedSeverity > 0 and overspeed ~= nil
                and overspeed.effects ~= nil and overspeed.effects[layerId]
                or nil
            if speedRule ~= nil then
                local effectSeverity = overspeedSeverity ^ math.max(
                    tonumber(overspeed.effectSeverityExponent) or 1, 0.25)
                nextValue = applyRule(nextValue, speedRule,
                    effectSeverity * textureStrength * engagement ^ 0.75)
            end
            if classKey == "roller" and layerId == "surfaceCompaction"
                and overspeedSeverity > 0
                and variationIx ~= nil and variationIz ~= nil then
                -- Fast rolling does not uniformly compact the whole field
                -- harder. Intermittent re-contact instead creates small local
                -- load peaks, strongest on a rough surface. Keep them modest
                -- and deterministic so previews and real passes agree without
                -- forming a repeating travel-direction stripe.
                local positiveNoise = math.max(getOperationCellVariation(
                    variationIx, variationIz, "rollerImpact"), 0)
                local spike = 0.025 * overspeedSeverity
                    * (1 - rollerContact) * positiveNoise * positiveNoise
                nextValue = clamp01(nextValue + spike * (1 - nextValue))
            end
            local variability = overspeed ~= nil
                and overspeed.variability ~= nil
                and tonumber(overspeed.variability[layerId]) or 0
            if classKey == "plow" and variability > 0
                and overspeedSeverity > 0
                and variationIx ~= nil and variationIz ~= nil then
                local variation = getOperationCellVariation(
                    variationIx, variationIz, layerId)
                local amplitude = variability * math.sqrt(overspeedSeverity)
                    * math.sqrt(engagement)
                    * (0.75 + 0.25 * textureStrength)
                nextValue = clamp01(nextValue + variation * amplitude)
            end
            nextValue = applyMoistureSoilReaction(
                classKey, layerId, nextValue, moistureResponse, engagement)
            projected[layerId] = nextValue
        end
    end
    local resilienceResponse = RESILIENCE_TILLAGE[classKey]
    if resilienceResponse ~= nil and resilienceResponse < 0 then
        resilienceResponse = -scaleSlowStrength(
            -resilienceResponse, getResilienceTillageLossScale())
    end
    if resilienceResponse ~= nil then
        resilienceResponse = resilienceResponse * engagement
        local current = projected.resilience
        projected.resilience = resilienceResponse >= 0
            and clamp01(current + resilienceResponse * (1-current))
            or clamp01(current + resilienceResponse * current)
    end
    return projected
end

-- Soil-speed consequences are deliberately independent from Work Quality.
-- The agronomic class speed is the no-penalty reference; effects then rise
-- smoothly and reach their configured maximum at 2.5 times that speed. This
-- keeps a small speed-control fluctuation harmless while making extreme
-- unlocked speeds physically visible in the persistent soil state.
local function getSoilOverspeed(implement)
    local spec = implement ~= nil and implement.spec_terraLogic or nil
    local referenceSpeed = spec ~= nil
        and tonumber(spec.optimalSpeed or spec.ratedSpeed) or nil
    local speed = implement ~= nil and implement.getLastSpeed ~= nil
        and math.abs(tonumber(implement:getLastSpeed(true)) or 0) or 0
    if referenceSpeed == nil or referenceSpeed <= 0 or speed <= referenceSpeed then
        return 0, speed, referenceSpeed or 0,
            referenceSpeed ~= nil and speed / math.max(referenceSpeed, 0.01) or 0
    end
    local ratio = speed / referenceSpeed
    local t = clamp01((ratio - 1) / 1.5)
    local baseSeverity = t * t * (3 - 2 * t)
    -- Make soil-state consequences readable before the former curve was
    -- almost saturated, while preserving zero at rated speed and the same
    -- hard maximum at 2.5x speed. Class profiles still determine which
    -- parameters fail and how strongly.
    local severity = 1 - (1 - baseSeverity) ^ 1.35
    return severity, speed, referenceSpeed, ratio
end

-- Physical WorkAreas are projected onto several map-aligned soil rasters.
-- Treating every touched cell as a complete pass made a narrow overlap at the
-- edge of two bout lines apply the full target twice (most visibly as regular
-- stripes in the 2 m Evenness map).  A compact 7x7 occupancy mask retains the
-- actual covered share of each cell.  The 49-bit value is exactly representable
-- by Lua's number type and can also be unioned across split/overlapping
-- WorkAreas without allocating one table per sub-sample.
local WORK_AREA_COVERAGE_SUBDIVISIONS = 7
local WORK_AREA_COVERAGE_SAMPLES =
    WORK_AREA_COVERAGE_SUBDIVISIONS * WORK_AREA_COVERAGE_SUBDIVISIONS
-- Adjacent bouts on a long field can reach the same raster cell several
-- minutes later. Keep complete and incomplete occupancy masks for the whole
-- operation window. Expiring complete cells on the short callback cooldown
-- made the small overlap of the next GPS bout look like a second complete soil
-- pass and produced regular stripes along otherwise seamless bout joins.
local WORK_AREA_COVERAGE_RETENTION_MS = 600000
-- GIANTS rasterizes the visible ground operation with a small edge tolerance.
-- The physical polygon used by TerraLogic used to end exactly at the WorkArea
-- nodes, leaving sub-cell seams between exact GPS bouts and a weak final row at
-- field exit. Ten centimetres matches that raster tolerance without widening
-- the actual implement in a meaningful way. Live cultivatable-area clipping
-- below still prevents this tolerance from creating soil outside real fields.
local WORK_AREA_COVERAGE_PADDING_M = 0.10
-- Soil rasters must receive the complete distance travelled between two
-- WorkArea callbacks. Sampling only the instantaneous (often very shallow)
-- implement rectangle can jump over some 7x7 sub-samples during a frame drop
-- even though GIANTS writes one continuous ground texture. A short, bounded
-- sweep joins consecutive positions without ever bridging a raised implement,
-- a vehicle switch or a teleport.
local WORK_AREA_SWEEP_MAX_AGE_MS = 1000
local WORK_AREA_SWEEP_DISTANCE_MARGIN_M = 0.75
local WORK_AREA_SWEEP_SPEED_FACTOR = 1.75
local WORK_AREA_SWEEP_ABSOLUTE_LIMIT_M = 8.0
-- WorkArea callbacks commonly arrive once per rendered frame even though the
-- implement has moved only a few centimetres. Rasterizing the same 7x7 masks
-- at that rate is expensive and adds no spatial information. Accumulate a
-- short distance and let the existing swept polygon cover it in one pass.
-- The time limit keeps very slow work responsive, while corner displacement
-- still forces prompt updates during steering and folding motion.
local WORK_AREA_PROCESS_DISTANCE_M = 0.35
local WORK_AREA_PROCESS_INTERVAL_MS = 200

-- A 49-bit occupancy mask is exactly representable by Lua's number type, but
-- walking all 49 bits for every union/intersection dominated active tillage.
-- Split it into 24 low and 25 high bits so GIANTS' Lua bit32 operations can
-- calculate the identical result. The compact fallback retains compatibility
-- with runtimes that do not expose bit32.
local COVERAGE_MASK_LOW_BITS = 24
local COVERAGE_MASK_LOW_BASE = 2 ^ COVERAGE_MASK_LOW_BITS
local COVERAGE_FULL_MASK = 2 ^ WORK_AREA_COVERAGE_SAMPLES - 1
local COVERAGE_BIT_VALUES = {}
for index=0,WORK_AREA_COVERAGE_SAMPLES-1 do
    COVERAGE_BIT_VALUES[index] = 2 ^ index
end
local COVERAGE_BYTE_COUNTS = {}
for value=0,255 do
    local count, remaining = 0, value
    while remaining > 0 do
        count = count + remaining % 2
        remaining = math.floor(remaining / 2)
    end
    COVERAGE_BYTE_COUNTS[value] = count
end

local function splitCoverageMask(mask)
    local value = math.max(math.floor((tonumber(mask) or 0) + 0.5), 0)
    local low = value % COVERAGE_MASK_LOW_BASE
    return low, math.floor(value / COVERAGE_MASK_LOW_BASE)
end

local function joinCoverageMask(low, high)
    return (tonumber(low) or 0)
        + (tonumber(high) or 0) * COVERAGE_MASK_LOW_BASE
end

local function countCoverageWord(value)
    local remaining = tonumber(value) or 0
    local count = 0
    for _=1,4 do
        local byte = remaining % 256
        count = count + COVERAGE_BYTE_COUNTS[byte]
        remaining = math.floor(remaining / 256)
    end
    return count
end

local function coverageMaskContains(mask, bitValue)
    if bit32 ~= nil and bit32.band ~= nil then
        -- All callers use the precomputed powers of two. Recovering the half
        -- from its magnitude avoids splitting a 49-bit number through bit32.
        if bitValue < COVERAGE_MASK_LOW_BASE then
            local low = (tonumber(mask) or 0) % COVERAGE_MASK_LOW_BASE
            return bit32.band(low, bitValue) ~= 0
        end
        local high = math.floor((tonumber(mask) or 0)
            / COVERAGE_MASK_LOW_BASE)
        return bit32.band(high,
            bitValue / COVERAGE_MASK_LOW_BASE) ~= 0
    end
    return math.floor((tonumber(mask) or 0) / bitValue) % 2 >= 1
end

local function mergeCoverageMask(existingMask, incomingMask)
    if bit32 ~= nil and bit32.band ~= nil and bit32.bor ~= nil
        and bit32.bnot ~= nil then
        local existingLow, existingHigh = splitCoverageMask(existingMask)
        local incomingLow, incomingHigh = splitCoverageMask(incomingMask)
        local addedLow = bit32.band(incomingLow, bit32.bnot(existingLow))
        local addedHigh = bit32.band(incomingHigh, bit32.bnot(existingHigh))
        return joinCoverageMask(
                bit32.bor(existingLow, incomingLow),
                bit32.bor(existingHigh, incomingHigh)),
            countCoverageWord(addedLow) + countCoverageWord(addedHigh)
    end
    local merged = tonumber(existingMask) or 0
    local added = 0
    for index=0,WORK_AREA_COVERAGE_SAMPLES-1 do
        local bitValue = COVERAGE_BIT_VALUES[index]
        if coverageMaskContains(incomingMask, bitValue)
            and not coverageMaskContains(merged, bitValue) then
            merged = merged + bitValue
            added = added + 1
        end
    end
    return merged, added
end

local function intersectCoverageMask(a, b)
    if bit32 ~= nil and bit32.band ~= nil then
        local aLow, aHigh = splitCoverageMask(a)
        local bLow, bHigh = splitCoverageMask(b)
        local low = bit32.band(aLow, bLow)
        local high = bit32.band(aHigh, bHigh)
        return joinCoverageMask(low, high),
            countCoverageWord(low) + countCoverageWord(high)
    end
    local result, count = 0, 0
    for index=0,WORK_AREA_COVERAGE_SAMPLES-1 do
        local bitValue = COVERAGE_BIT_VALUES[index]
        if coverageMaskContains(a, bitValue)
            and coverageMaskContains(b, bitValue) then
            result = result + bitValue
            count = count + 1
        end
    end
    return result, count
end

local function subtractCoverageMask(a, b)
    if bit32 ~= nil and bit32.band ~= nil and bit32.bnot ~= nil then
        local aLow, aHigh = splitCoverageMask(a)
        local bLow, bHigh = splitCoverageMask(b)
        local low = bit32.band(aLow, bit32.bnot(bLow))
        local high = bit32.band(aHigh, bit32.bnot(bHigh))
        return joinCoverageMask(low, high),
            countCoverageWord(low) + countCoverageWord(high)
    end
    local result, count = 0, 0
    for index=0,WORK_AREA_COVERAGE_SAMPLES-1 do
        local bitValue = COVERAGE_BIT_VALUES[index]
        if coverageMaskContains(a, bitValue)
            and not coverageMaskContains(b, bitValue) then
            result = result + bitValue
            count = count + 1
        end
    end
    return result, count
end

-- A raster cell at a real field boundary may contain both cultivatable and
-- non-field ground. Physical strength must describe how much of its *field
-- share* the implement covered, not how much of the complete square it
-- covered. Otherwise a tool that completely works the remaining half of a
-- boundary cell receives only half strength and leaves a visible weak rim.
-- Keep the same 7x7 sample lattice as the WorkArea mask so the intersection is
-- exact and no sample outside the live GIANTS field surface can authorize a
-- TerraLogic write.
local function normalizeCellsToCultivatableArea(manager, cells, cellSize)
    if manager == nil then return cells or {} end
    local result = {}
    local subdivisions = WORK_AREA_COVERAGE_SUBDIVISIONS
    for _, cell in ipairs(cells or {}) do
        local workCoverage = clamp01(cell.coverage)
        cell.rawCoverage = workCoverage
        cell.rawCoverageMask = cell.coverageMask
        cell.rawCoveredSamples = math.floor(
            workCoverage * WORK_AREA_COVERAGE_SAMPLES + 0.5)
        cell.rawPhysicalCoverageMask = cell.physicalCoverageMask
            or cell.coverageMask
        cell.rawPhysicalCoveredSamples = tonumber(
            cell.physicalCoveredSamples) or cell.rawCoveredSamples
        local centerX = (cell.ix + 0.5) * cellSize
        local centerZ = (cell.iz + 0.5) * cellSize
        local centerCultivatable =
            manager:isCultivatableTerrainAtWorldPosition(centerX, centerZ)

        -- Interior cells remain on the cheap path. Partial WorkArea cells and
        -- cells whose centre lies outside are the only ones that can need a
        -- field-share denominator.
        if workCoverage >= 0.999 and centerCultivatable == true then
            cell.coverageDenominator = WORK_AREA_COVERAGE_SAMPLES
            cell.fieldSamples = WORK_AREA_COVERAGE_SAMPLES
            cell.workedFieldSamples = cell.rawCoveredSamples
            cell.physicalWorkedFieldSamples =
                cell.rawPhysicalCoveredSamples
            cell.physicalCoverage =
                cell.rawPhysicalCoveredSamples / WORK_AREA_COVERAGE_SAMPLES
            cell.cultivatableCoverage = 1
            result[#result + 1] = cell
        else
            local fieldSamples, workedFieldSamples = 0, 0
            local intersectionMask = 0
            local physicalIntersectionMask = 0
            local physicalWorkedFieldSamples = 0
            local knownSamples = 0
            local coverageLow, coverageHigh = splitCoverageMask(
                cell.coverageMask)
            local physicalLow, physicalHigh = splitCoverageMask(
                cell.physicalCoverageMask or cell.coverageMask)
            for sampleZ=0,subdivisions-1 do
                local z = (cell.iz + (sampleZ + 0.5) / subdivisions)
                    * cellSize
                for sampleX=0,subdivisions-1 do
                    local x = (cell.ix + (sampleX + 0.5) / subdivisions)
                        * cellSize
                    local cultivatable =
                        manager:isCultivatableTerrainAtWorldPosition(x, z)
                    if cultivatable ~= nil then
                        knownSamples = knownSamples + 1
                    end
                    if cultivatable == true then
                        fieldSamples = fieldSamples + 1
                        local index = sampleZ * subdivisions + sampleX
                        local bitValue = COVERAGE_BIT_VALUES[index]
                        local coverageSet = nil
                        local physicalSet = nil
                        if bit32 ~= nil and bit32.band ~= nil then
                            if index < COVERAGE_MASK_LOW_BITS then
                                coverageSet = bit32.band(
                                    coverageLow, bitValue) ~= 0
                                physicalSet = bit32.band(
                                    physicalLow, bitValue) ~= 0
                            else
                                local highBit = bitValue
                                    / COVERAGE_MASK_LOW_BASE
                                coverageSet = bit32.band(
                                    coverageHigh, highBit) ~= 0
                                physicalSet = bit32.band(
                                    physicalHigh, highBit) ~= 0
                            end
                        else
                            coverageSet = coverageMaskContains(
                                cell.coverageMask, bitValue)
                            physicalSet = coverageMaskContains(
                                cell.physicalCoverageMask
                                    or cell.coverageMask, bitValue)
                        end
                        if coverageSet then
                            intersectionMask = intersectionMask + bitValue
                            workedFieldSamples = workedFieldSamples + 1
                        end
                        if physicalSet then
                            physicalIntersectionMask =
                                physicalIntersectionMask + bitValue
                            physicalWorkedFieldSamples =
                                physicalWorkedFieldSamples + 1
                        end
                    end
                end
            end

            cell.fieldSamples = fieldSamples
            cell.workedFieldSamples = workedFieldSamples
            cell.cultivatableCoverage = knownSamples > 0
                and fieldSamples / knownSamples or nil
            if knownSamples <= 0 then
                -- A custom map without a readable ground-type channel keeps
                -- the previous conservative WorkArea behaviour.
                cell.coverageDenominator = WORK_AREA_COVERAGE_SAMPLES
                cell.fieldSamples = "unknown"
                cell.workedFieldSamples = cell.rawCoveredSamples
                cell.physicalWorkedFieldSamples =
                    cell.rawPhysicalCoveredSamples
                cell.physicalCoverage =
                    cell.rawPhysicalCoveredSamples
                        / WORK_AREA_COVERAGE_SAMPLES
                result[#result + 1] = cell
            elseif fieldSamples > 0 and workedFieldSamples > 0 then
                cell.coverageMask = intersectionMask
                cell.physicalCoverageMask = physicalIntersectionMask
                cell.coverageDenominator = fieldSamples
                cell.coverage = workedFieldSamples / fieldSamples
                cell.physicalWorkedFieldSamples =
                    physicalWorkedFieldSamples
                cell.physicalCoverage =
                    physicalWorkedFieldSamples / fieldSamples
                cell.cultivatableCoverage = fieldSamples / knownSamples
                result[#result + 1] = cell
            end
        end
    end
    return result
end

local function captureWorkAreaGeometry(workArea)
    if workArea == nil or workArea.start == nil or workArea.width == nil
        or workArea.height == nil then return nil end
    local sx, _, sz = getWorldTranslation(workArea.start)
    local wx, _, wz = getWorldTranslation(workArea.width)
    local hx, _, hz = getWorldTranslation(workArea.height)
    local widthX, widthZ = wx - sx, wz - sz
    local heightX, heightZ = hx - sx, hz - sz
    local widthLength = math.sqrt(widthX * widthX + widthZ * widthZ)
    local heightLength = math.sqrt(heightX * heightX + heightZ * heightZ)
    local determinant = widthX * heightZ - widthZ * heightX
    if math.abs(determinant) < 0.000001 then return nil end
    return {
        sx=sx, sz=sz, widthX=widthX, widthZ=widthZ,
        heightX=heightX, heightZ=heightZ,
        widthLength=widthLength, heightLength=heightLength
    }
end

local function getWorkAreaCorners(geometry, paddingM)
    if geometry == nil then return {} end
    local padding = math.max(tonumber(paddingM) or 0, 0)
    local paddingU = padding
        / math.max(geometry.widthLength, 0.01)
    local paddingV = padding
        / math.max(geometry.heightLength, 0.01)
    local sx, sz = geometry.sx, geometry.sz
    local widthX, widthZ = geometry.widthX, geometry.widthZ
    local heightX, heightZ = geometry.heightX, geometry.heightZ
    return {
        {x=sx - widthX * paddingU - heightX * paddingV,
            z=sz - widthZ * paddingU - heightZ * paddingV},
        {x=sx + widthX * (1 + paddingU) - heightX * paddingV,
            z=sz + widthZ * (1 + paddingU) - heightZ * paddingV},
        {x=sx + widthX * (1 + paddingU) + heightX * (1 + paddingV),
            z=sz + widthZ * (1 + paddingU) + heightZ * (1 + paddingV)},
        {x=sx - widthX * paddingU + heightX * (1 + paddingV),
            z=sz - widthZ * paddingU + heightZ * (1 + paddingV)}
    }
end

local function getPaddedWorkAreaCorners(geometry)
    return getWorkAreaCorners(geometry, WORK_AREA_COVERAGE_PADDING_M)
end

local function getConvexHull(points)
    if points == nil or #points <= 3 then return points or {} end
    local sorted = {}
    for _, point in ipairs(points) do
        sorted[#sorted + 1] = {x=point.x, z=point.z}
    end
    table.sort(sorted, function(a, b)
        return a.x < b.x or (a.x == b.x and a.z < b.z)
    end)
    local function cross(o, a, b)
        return (a.x-o.x)*(b.z-o.z) - (a.z-o.z)*(b.x-o.x)
    end
    local lower = {}
    for _, point in ipairs(sorted) do
        while #lower >= 2
            and cross(lower[#lower-1], lower[#lower], point) <= 0 do
            table.remove(lower)
        end
        lower[#lower + 1] = point
    end
    local upper = {}
    for index=#sorted,1,-1 do
        local point = sorted[index]
        while #upper >= 2
            and cross(upper[#upper-1], upper[#upper], point) <= 0 do
            table.remove(upper)
        end
        upper[#upper + 1] = point
    end
    table.remove(lower)
    table.remove(upper)
    for _, point in ipairs(upper) do lower[#lower + 1] = point end
    return lower
end

local function prepareConvexPolygon(points)
    if points == nil or #points < 3 then return nil end
    local signedArea = 0
    for index=1,#points do
        local a = points[index]
        local b = points[index % #points + 1]
        signedArea = signedArea + a.x * b.z - b.x * a.z
    end
    local orientation = signedArea >= 0 and 1 or -1
    local edges = {}
    for index=1,#points do
        local a = points[index]
        local b = points[index % #points + 1]
        local dx, dz = b.x-a.x, b.z-a.z
        edges[index] = {
            a=-dz*orientation,
            b=dx*orientation,
            c=(dz*a.x-dx*a.z)*orientation
        }
    end
    return edges
end

local function isPointInPreparedConvexPolygon(edges, x, z)
    if edges == nil then return false end
    for index=1,#edges do
        local edge = edges[index]
        if edge.a*x + edge.b*z + edge.c < -0.000001 then
            return false
        end
    end
    return true
end

local function isCellInsidePreparedConvexPolygon(
        edges, minX, minZ, maxX, maxZ)
    return isPointInPreparedConvexPolygon(edges, minX, minZ)
        and isPointInPreparedConvexPolygon(edges, maxX, minZ)
        and isPointInPreparedConvexPolygon(edges, maxX, maxZ)
        and isPointInPreparedConvexPolygon(edges, minX, maxZ)
end

local function getWorkAreaGeometryDistance(a, b)
    if a == nil or b == nil then return math.huge end
    local maximum = 0
    for _, suffix in ipairs({"s", "w", "h", "o"}) do
        local ax, az, bx, bz
        if suffix == "s" then
            ax, az, bx, bz = a.sx, a.sz, b.sx, b.sz
        elseif suffix == "w" then
            ax, az = a.sx+a.widthX, a.sz+a.widthZ
            bx, bz = b.sx+b.widthX, b.sz+b.widthZ
        elseif suffix == "h" then
            ax, az = a.sx+a.heightX, a.sz+a.heightZ
            bx, bz = b.sx+b.heightX, b.sz+b.heightZ
        else
            ax, az = a.sx+a.widthX+a.heightX,
                a.sz+a.widthZ+a.heightZ
            bx, bz = b.sx+b.widthX+b.heightX,
                b.sz+b.widthZ+b.heightZ
        end
        maximum = math.max(maximum,
            math.sqrt((ax-bx)*(ax-bx) + (az-bz)*(az-bz)))
    end
    return maximum
end

local function prepareWorkAreaCoverageGeometry(
        currentGeometry, previousGeometry)
    if currentGeometry == nil then return nil end
    local polygonPoints = getPaddedWorkAreaCorners(currentGeometry)
    local physicalPoints = getWorkAreaCorners(currentGeometry, 0)
    if previousGeometry ~= nil then
        for _, point in ipairs(getPaddedWorkAreaCorners(previousGeometry)) do
            polygonPoints[#polygonPoints + 1] = point
        end
        for _, point in ipairs(getWorkAreaCorners(previousGeometry, 0)) do
            physicalPoints[#physicalPoints + 1] = point
        end
    end
    local hull = getConvexHull(polygonPoints)
    local physicalHull = getConvexHull(physicalPoints)
    if #hull < 3 then return nil end
    local preparedHull = prepareConvexPolygon(hull)
    local preparedPhysicalHull = prepareConvexPolygon(physicalHull)
    local minX, maxX = math.huge, -math.huge
    local minZ, maxZ = math.huge, -math.huge
    for _, point in ipairs(hull) do
        minX, maxX = math.min(minX, point.x), math.max(maxX, point.x)
        minZ, maxZ = math.min(minZ, point.z), math.max(maxZ, point.z)
    end
    return {
        preparedHull=preparedHull,
        preparedPhysicalHull=preparedPhysicalHull,
        minX=minX, maxX=maxX, minZ=minZ, maxZ=maxZ
    }
end

local function getTouchedSoilCells(
        workArea, cellSize, previousGeometry, preparedGeometry)
    local geometry = preparedGeometry
    if geometry == nil then
        geometry = prepareWorkAreaCoverageGeometry(
            captureWorkAreaGeometry(workArea), previousGeometry)
    end
    if geometry == nil then return {} end
    local preparedHull = geometry.preparedHull
    local preparedPhysicalHull = geometry.preparedPhysicalHull
    local minX, maxX = geometry.minX, geometry.maxX
    local minZ, maxZ = geometry.minZ, geometry.maxZ
    local epsilon = math.max(cellSize * 0.000001, 0.000001)
    local minIx = math.floor((minX + epsilon) / cellSize)
    local maxIx = math.floor((maxX - epsilon) / cellSize)
    local minIz = math.floor((minZ + epsilon) / cellSize)
    local maxIz = math.floor((maxZ - epsilon) / cellSize)
    if maxIx < minIx then minIx, maxIx = maxIx, minIx end
    if maxIz < minIz then minIz, maxIz = maxIz, minIz end

    local result = {}
    local subdivisions = WORK_AREA_COVERAGE_SUBDIVISIONS
    for iz=minIz,maxIz do
        for ix=minIx,maxIx do
            local mask, covered = 0, 0
            local physicalMask, physicalCovered = 0, 0
            local cellMinX, cellMinZ = ix*cellSize, iz*cellSize
            local cellMaxX, cellMaxZ = cellMinX+cellSize,
                cellMinZ+cellSize
            local effectFull = isCellInsidePreparedConvexPolygon(
                preparedHull, cellMinX, cellMinZ, cellMaxX, cellMaxZ)
            local physicalFull = isCellInsidePreparedConvexPolygon(
                preparedPhysicalHull,
                cellMinX, cellMinZ, cellMaxX, cellMaxZ)
            if effectFull then
                mask, covered = COVERAGE_FULL_MASK,
                    WORK_AREA_COVERAGE_SAMPLES
            end
            if physicalFull then
                physicalMask, physicalCovered = COVERAGE_FULL_MASK,
                    WORK_AREA_COVERAGE_SAMPLES
            end
            if not effectFull or not physicalFull then
                for sampleZ=0,subdivisions-1 do
                    local z = (iz + (sampleZ + 0.5) / subdivisions)
                        * cellSize
                    for sampleX=0,subdivisions-1 do
                        local x = (ix + (sampleX + 0.5) / subdivisions)
                            * cellSize
                        local effectInside = effectFull
                            or isPointInPreparedConvexPolygon(
                                preparedHull, x, z)
                        if effectInside then
                            local index = sampleZ * subdivisions + sampleX
                            if not effectFull then
                                mask = mask + COVERAGE_BIT_VALUES[index]
                                covered = covered + 1
                            end
                            -- The physical polygon is always contained in the
                            -- padded closure polygon. Avoid its test for every
                            -- sample that missed the latter or belongs to a
                            -- cell already proven to be completely physical.
                            if not physicalFull
                                and isPointInPreparedConvexPolygon(
                                    preparedPhysicalHull, x, z) then
                                physicalMask = physicalMask
                                    + COVERAGE_BIT_VALUES[index]
                                physicalCovered = physicalCovered + 1
                            end
                        end
                    end
                end
            end
            if covered > 0 then
                result[#result + 1] = {
                    ix=ix, iz=iz, coverageMask=mask,
                    coverage=covered / WORK_AREA_COVERAGE_SAMPLES,
                    physicalCoverageMask=physicalMask,
                    physicalCoveredSamples=physicalCovered,
                    physicalCoverage=
                        physicalCovered / WORK_AREA_COVERAGE_SAMPLES
                }
            end
        end
    end
    return result
end

-- Reusing the existing per-implement table keeps split WorkAreas and SKY/Vredo
-- fallback callbacks on the same deduplication path. All masks live long enough
-- for a neighbouring bout to arrive; otherwise a completed edge cell would be
-- reset and receive the overlapping strip twice. Periodic pruning prevents this
-- session-only cache from growing with every worked field cell.
local function pruneRecentSoilCoverage(spec, now, cooldown)
    if now < (tonumber(spec.nextSoilRecentCellsPruneTime) or 0) then return end
    spec.nextSoilRecentCellsPruneTime = now + math.max(cooldown * 2, 10000)
    for key, entry in pairs(spec.soilRecentCells or {}) do
        local lastSeen = type(entry) == "table"
            and tonumber(entry.lastSeen) or tonumber(entry)
        if lastSeen == nil
            or now - lastSeen >= WORK_AREA_COVERAGE_RETENTION_MS then
            spec.soilRecentCells[key] = nil
        end
    end
end

local function getCoverageEntry(
        spec, key, cell, now, cooldown, baseValue, collectDiagnostics)
    spec.soilRecentCells = spec.soilRecentCells or {}
    local entry = spec.soilRecentCells[key]
    local lastSeen = type(entry) == "table"
        and tonumber(entry.lastSeen) or tonumber(entry)
    local cacheState = "existing"
    if type(entry) ~= "table" or lastSeen == nil
        or now - lastSeen >= WORK_AREA_COVERAGE_RETENTION_MS then
        cacheState = type(entry) == "table" and "expired" or "new"
        entry = {
            lastSeen=now, workedMask=0, physicalMask=0,
            coverageMask=0, coverage=0, repeatCoverage=0,
            coverageDenominator=math.max(tonumber(
                cell.coverageDenominator) or WORK_AREA_COVERAGE_SAMPLES, 1),
            baseValue=baseValue, lastModelValue=baseValue,
            lastAppliedValue=baseValue
        }
        spec.soilRecentCells[key] = entry
    end
    local gapBeforeTouch = math.max(now
        - (tonumber(entry.lastSeen) or now), 0)
    local coverageDenominator = math.max(tonumber(
        cell.coverageDenominator)
        or tonumber(entry.coverageDenominator)
        or WORK_AREA_COVERAGE_SAMPLES, 1)
    entry.coverageDenominator = coverageDenominator
    entry.workedMask = tonumber(entry.workedMask)
        or tonumber(entry.coverageMask) or 0
    entry.physicalMask = tonumber(entry.physicalMask)
        or tonumber(entry.workedMask) or 0

    local incomingEffectMask = tonumber(cell.coverageMask) or 0
    local incomingPhysicalMask = tonumber(cell.physicalCoverageMask)
        or incomingEffectMask
    local newVisit = gapBeforeTouch >= cooldown

    -- A visit is one continuous traversal of this cell. Split WorkAreas and
    -- callback fragments arrive well inside the normal callback cooldown and
    -- are unioned. Returning on a neighbouring GPS bout starts a fresh visit.
    -- Unlike the former threshold logic, a real repeated share is applied
    -- immediately and proportionally instead of suddenly promoting a whole
    -- cell after an arbitrary percentage was reached.
    if newVisit then
        entry.visitPriorPhysicalMask = entry.physicalMask
        entry.coverageMask = 0
        entry.coverage = 0
        entry.repeatMask = 0
        entry.repeatCoverage = 0
        entry.baseValue = baseValue
        entry.lastModelValue = baseValue
        entry.lastAppliedValue = baseValue
        cacheState = "new_visit"
    end

    local newFirstMask, newFirstSamples = subtractCoverageMask(
        incomingEffectMask, entry.workedMask)
    local repeatMask = 0
    if entry.visitPriorPhysicalMask ~= nil then
        repeatMask = select(1, intersectCoverageMask(
            incomingPhysicalMask, entry.visitPriorPhysicalMask))
    end
    local newRepeatMask, newRepeatSamples = subtractCoverageMask(
        repeatMask, entry.repeatMask or 0)

    -- Closure-only samples may complete the first visual pass, but they never
    -- qualify as repeated physical work. A later real WorkArea can upgrade
    -- such a sample to physical history without receiving a false second pass.
    local applicationMask = newFirstMask
    applicationMask = select(1, mergeCoverageMask(
        applicationMask, newRepeatMask))
    local mergedVisitMask, addedSamples = mergeCoverageMask(
        entry.coverageMask, applicationMask)
    local previousCoverage = tonumber(entry.coverage) or 0
    entry.coverageMask = mergedVisitMask
    entry.coverage = math.min(previousCoverage
        + addedSamples / coverageDenominator, 1)
    entry.repeatMask = select(1, mergeCoverageMask(
        entry.repeatMask, newRepeatMask))
    entry.workedMask = select(1, mergeCoverageMask(
        entry.workedMask, incomingEffectMask))
    entry.physicalMask = select(1, mergeCoverageMask(
        entry.physicalMask, incomingPhysicalMask))
    entry.lastSeen = now

    if not collectDiagnostics then
        return entry, addedSamples > 0, previousCoverage, nil
    end
    local visitRepeatSamples = countCoverageWord(
        select(1, splitCoverageMask(entry.repeatMask)))
        + countCoverageWord(select(2, splitCoverageMask(entry.repeatMask)))
    entry.repeatCoverage = math.min(
        visitRepeatSamples / coverageDenominator, 1)
    local toleranceMask = select(1, subtractCoverageMask(
        incomingEffectMask, incomingPhysicalMask))
    local _, toleranceAddedSamples = intersectCoverageMask(
        newFirstMask, toleranceMask)
    local _, physicalFirstAddedSamples = intersectCoverageMask(
        newFirstMask, incomingPhysicalMask)
    local state = "duplicate"
    if addedSamples > 0 then
        if newRepeatSamples > 0 then
            state = "repeat_physical"
        elseif newFirstSamples > 0 and toleranceAddedSamples > 0 then
            state = "first_with_tolerance"
        else
            state = cacheState == "new_visit" and "new_visit" or cacheState
        end
    end
    return entry, addedSamples > 0, previousCoverage, {
        state=state,
        gapMs=gapBeforeTouch, addedSamples=addedSamples,
        firstAddedSamples=newFirstSamples,
        repeatAddedSamples=newRepeatSamples,
        physicalFirstAddedSamples=physicalFirstAddedSamples,
        physicalSamples=tonumber(cell.physicalWorkedFieldSamples)
            or tonumber(cell.physicalCoveredSamples) or 0,
        toleranceSamples=toleranceAddedSamples,
        previousCoverage=previousCoverage,
        afterCoverage=entry.coverage,
        repeatCoverage=entry.repeatCoverage,
        repeatThreshold=0
    }
end

function TerraLogicSoilManager:applyResilienceWorkArea(
        implement, workArea, classKey, successfulArea, now, engagement,
        touchedCells)
    if g_server == nil then return 0 end
    local response = RESILIENCE_TILLAGE[classKey]
    if response ~= nil and response < 0 then
        response = -scaleSlowStrength(
            -response, getResilienceTillageLossScale())
    end
    if response == nil or (tonumber(successfulArea) or 0) <= 0
        or TerraLogicQualityManager == nil then return 0 end
    response = response * math.clamp(tonumber(engagement) or 1, 0, 1)
    if math.abs(response) < 0.00001 then return 0 end
    local spec = implement ~= nil and implement.spec_terraLogic or nil
    if spec == nil then return 0 end
    spec.soilRecentCells = spec.soilRecentCells or {}
    pruneRecentSoilCoverage(spec, now, self.PASS_COOLDOWN_MS)
    local changed = 0
    for _, cell in ipairs(touchedCells or getTouchedSoilCells(
            workArea, self.RESILIENCE_CELL_SIZE)) do
        -- One physical implement may expose consecutive work components, for
        -- example a plough followed by an integrated cultivator/packer. Keep
        -- overlapping WorkAreas of the same component deduplicated while
        -- allowing the secondary component to act on the freshly ploughed
        -- cell during the same pass.
        local key = "resilienceWork:" .. tostring(classKey) .. ":"
            .. getCellKey(cell.ix, cell.iz)
        local x = (cell.ix + 0.5) * self.RESILIENCE_CELL_SIZE
        local z = (cell.iz + 0.5) * self.RESILIENCE_CELL_SIZE
        local current = self:getValueAtWorldPosition("resilience", x, z)
        local entry, coverageChanged = getCoverageEntry(
            spec, key, cell, now, self.PASS_COOLDOWN_MS, current)
        if coverageChanged then
            local cultivatable = (tonumber(
                cell.cultivatableCoverage) or 0) > 0
            if not cultivatable then
                local surface = TerraLogicQualityManager:
                    getSurfaceTypeAtWorldPosition(x, z)
                cultivatable = surface == "field"
                    or surface == "grassField"
            end
            if cultivatable then
                local base = clamp01(entry.baseValue)
                local weightedResponse = response * clamp01(entry.coverage)
                local modelValue = weightedResponse >= 0
                    and base + weightedResponse * (1 - base)
                    or base + weightedResponse * base
                modelValue = clamp01(modelValue)
                -- Anchor the next result to the value that the raster really
                -- stored, not to the unquantized floating-point model. This
                -- prevents a different rounding residue on every tiny
                -- coverage increment while still preserving changes made by
                -- another sequential component between callbacks.
                local previousApplied = clamp01(
                    entry.lastAppliedValue ~= nil
                        and entry.lastAppliedValue or entry.baseValue)
                local nextValue = clamp01(modelValue
                    + current - previousApplied)
                if math.abs(nextValue - current) > 0.001
                    and self:setStateCell(
                        "resilience", cell.ix, cell.iz, nextValue) then
                    entry.lastModelValue = modelValue
                    entry.lastAppliedValue = self:getValueAtWorldPosition(
                        "resilience", x, z)
                    changed = changed + 1
                end
            end
        end
    end
    if changed > 0 then self:markResilienceChanged() end
    return changed
end

function TerraLogicSoilManager:applyRecoveryAgeWorkArea(
        implement, workArea, classKey, successfulArea, now, engagement,
        touchedCells)
    local rule = RECOVERY_AGE_WORK[classKey]
    if rule == nil or (tonumber(successfulArea) or 0) <= 0
        or TerraLogicQualityManager == nil then return 0 end
    local spec = implement ~= nil and implement.spec_terraLogic or nil
    if spec == nil then return 0 end
    engagement = math.clamp(tonumber(engagement) or 1, 0, 1)
    spec.soilRecentCells = spec.soilRecentCells or {}
    pruneRecentSoilCoverage(spec, now, self.PASS_COOLDOWN_MS)
    local changed = 0
    for _, cell in ipairs(touchedCells or getTouchedSoilCells(
            workArea, self.RECOVERY_CELL_SIZE)) do
        local key = "recoveryAgeWork:" .. tostring(classKey) .. ":"
            .. getCellKey(cell.ix, cell.iz)
        local x = (cell.ix + 0.5) * self.RECOVERY_CELL_SIZE
        local z = (cell.iz + 0.5) * self.RECOVERY_CELL_SIZE
        local age = self:getRecoveryAgeAtWorldPosition(x, z)
        local entry, coverageChanged = getCoverageEntry(
            spec, key, cell, now, self.PASS_COOLDOWN_MS,
            getBiologicalContinuityFromAge(age))
        if coverageChanged then
            local cultivatable = (tonumber(
                cell.cultivatableCoverage) or 0) > 0
            if not cultivatable then
                local surface = TerraLogicQualityManager:
                    getSurfaceTypeAtWorldPosition(x, z)
                cultivatable = surface == "field"
                    or surface == "grassField"
            end
            if cultivatable then
                local weightedEngagement = engagement * clamp01(entry.coverage)
                local baseContinuity = entry.baseValue
                local modelContinuity = self:applyContinuityRule(
                    baseContinuity, classKey, weightedEngagement)
                local lastContinuity = entry.lastModelValue or baseContinuity
                local currentContinuity = getBiologicalContinuityFromAge(age)
                local nextContinuity = math.max(rule.target,
                    currentContinuity + modelContinuity - lastContinuity)
                nextContinuity = math.min(currentContinuity, nextContinuity)
                local nextAge = nextContinuity < currentContinuity
                    and getAgeFromBiologicalContinuity(nextContinuity) or age
                if nextAge ~= age
                    and self:setRecoveryAgeCell(cell.ix, cell.iz, nextAge) then
                    entry.lastModelValue = modelContinuity
                    changed = changed + 1
                end
            end
        end
    end
    return changed
end

function TerraLogicSoilManager:applyWorkArea(
        implement, workArea, classKey, changedArea, totalArea)
    local rawChangedArea = math.max(tonumber(changedArea) or 0, 0)
    local rawTotalArea = totalArea ~= nil
        and math.max(tonumber(totalArea) or 0, 0) or rawChangedArea
    local successfulArea = math.max(rawChangedArea, rawTotalArea)
    if g_server == nil then return false end
    if self.deepMapMigration ~= nil then return false end
    local profile = TerraLogicSoilProfiles:getProfile(classKey)
    if profile == nil or TerraLogicQualityManager == nil then return false end
    local spec = implement ~= nil and implement.spec_terraLogic or nil
    if spec == nil then return false end
    local now = g_currentMission ~= nil and g_currentMission.time or 0
    local currentWorkAreaGeometry = captureWorkAreaGeometry(workArea)
    local traceLogger = TerraLogicMain ~= nil
        and TerraLogicMain.soilTraceLogger or nil
    local traceActive = traceLogger ~= nil and traceLogger.active == true
        and TerraLogicMain.writeSoilTraceRecord ~= nil
    local coverageDiagnosticsActive = traceActive
        or (TerraLogicMain ~= nil
            and TerraLogicMain.debugEnabled == true
            and (TerraLogicMain.debugMode == "soilprocess"
                or TerraLogicMain.debugMode == "audit_fieldwork"))
    local traceCallbackId = 0
    if traceActive then
        traceLogger.callbackId = (traceLogger.callbackId or 0) + 1
        traceCallbackId = traceLogger.callbackId
    end
    local traceImplementName = implement.getFullName ~= nil
        and tostring(implement:getFullName())
        or (implement.getName ~= nil and tostring(implement:getName())
            or tostring(classKey))
    local function traceRecord(eventName, values)
        if not traceActive then return end
        values = values or {}
        values.event = eventName
        values.callback_id = traceCallbackId
        values.class = classKey
        values.implement = traceImplementName
        values.work_area = tostring(workArea)
        values.raw_changed_area = rawChangedArea
        values.raw_total_area = rawTotalArea
        values.successful_area = successfulArea
        if currentWorkAreaGeometry ~= nil then
            values.geometry_sx = currentWorkAreaGeometry.sx
            values.geometry_sz = currentWorkAreaGeometry.sz
            values.geometry_width_x = currentWorkAreaGeometry.widthX
            values.geometry_width_z = currentWorkAreaGeometry.widthZ
            values.geometry_height_x = currentWorkAreaGeometry.heightX
            values.geometry_height_z = currentWorkAreaGeometry.heightZ
        end
        TerraLogicMain:writeSoilTraceRecord(values)
    end
    local groundContactActive = implement.getIsOverSpeedGroundContactActive ~= nil
        and implement:getIsOverSpeedGroundContactActive() == true
    spec.soilPreviousWorkAreaGeometry =
        spec.soilPreviousWorkAreaGeometry or {}
    if not groundContactActive then
        spec.soilPreviousWorkAreaGeometry[workArea] = nil
    end
    if successfulArea > 0 then
        -- Vanilla has proved a genuine soil operation. Keep this physical pass
        -- armed until its moving WorkArea has completely left the final live
        -- field cell. This follows implement geometry rather than tractor
        -- position or an arbitrary time window.
        spec.soilContactPassArmed = true
    elseif not groundContactActive then
        spec.soilContactPassArmed = false
    end
    local exitGeometryActive = successfulArea <= 0
        and spec.soilContactPassArmed == true
        and groundContactActive
        and implement.getLastSpeed ~= nil
        and math.abs(implement:getLastSpeed(true) or 0)
            > self.MIN_SOIL_PASS_SPEED_KPH
    if successfulArea <= 0 and not exitGeometryActive then
        -- Remember a lowered, moving WorkArea immediately before it reaches
        -- the field. The first positive Vanilla callback otherwise starts
        -- only after part of the leading footprint has crossed the boundary,
        -- which makes field entry weaker than the interior of the same bout.
        local trackingSpeed = implement.getLastSpeed ~= nil
            and math.abs(implement:getLastSpeed(true) or 0) or 0
        if groundContactActive
            and trackingSpeed > self.MIN_SOIL_PASS_SPEED_KPH
            and currentWorkAreaGeometry ~= nil then
            local history = spec.soilPreviousWorkAreaGeometry[workArea]
            if type(history) ~= "table" or history.geometry ~= nil then
                history = {}
                spec.soilPreviousWorkAreaGeometry[workArea] = history
            end
            history[classKey] = {
                geometry=currentWorkAreaGeometry,
                classKey=classKey, time=now
            }
        end
        traceRecord("callback_rejected", {
            ground_contact=groundContactActive and 1 or 0,
            armed=spec.soilContactPassArmed == true and 1 or 0,
            exit_geometry=0, reason="no successful area",
            speed_kph=trackingSpeed
        })
        return false
    end
    if exitGeometryActive then successfulArea = 1 end
    -- A combination implement can execute several central profiles in one
    -- pass. Mechanical soil response must use the depth of the component being
    -- applied, not the primary HUD class cached on the complete implement.
    local implementProfile = TerraLogicImplementProfiles ~= nil
        and TerraLogicImplementProfiles.PROFILES ~= nil
        and TerraLogicImplementProfiles.PROFILES[classKey] or nil
    local operationWorkDepthCm = implementProfile ~= nil
        and implementProfile.work ~= nil
        and tonumber(implementProfile.work.depthCm)
        or tonumber(spec.workDepthCm) or 0
    -- A WorkArea callback alone does not prove deliberate field work. Detached
    -- implements can wake when the player approaches, jitter a few centimetres
    -- while embedded in uneven ground and make Vanilla return a positive (and
    -- occasionally map-sized) totalArea. Vanilla itself only marks these soil
    -- tools as working above 0.5 km/h. Applying the same universal threshold
    -- rejects that physics artefact without any vehicle/model whitelist and
    -- therefore remains compatible with AI, multiplayer and mod implements.
    local hasSpeedSignal = implement ~= nil
        and implement.getLastSpeed ~= nil
    local passSpeedKph = hasSpeedSignal
        and math.abs(implement:getLastSpeed(true) or 0) or nil
    if hasSpeedSignal
        and passSpeedKph <= self.MIN_SOIL_PASS_SPEED_KPH then
        local now = g_currentMission ~= nil and g_currentMission.time or 0
        self.lastRejectedPass = {
            classKey=classKey, changedArea=rawChangedArea,
            totalArea=rawTotalArea, speedKph=passSpeedKph,
            reason="below Vanilla working speed", time=now
        }
        if TerraLogicLogging ~= nil
            and (spec.soilRejectedPassLogTime == nil
                or now - spec.soilRejectedPassLogTime >= 5000) then
            spec.soilRejectedPassLogTime = now
            TerraLogicLogging.debug(
                "[FS25_TerraLogic] Ignored inactive soil pass %s: changedArea=%.3f totalArea=%.3f speed=%.3f kph threshold=%.3f",
                tostring(classKey), rawChangedArea, rawTotalArea,
                passSpeedKph, self.MIN_SOIL_PASS_SPEED_KPH)
        end
        traceRecord("callback_rejected", {
            ground_contact=groundContactActive and 1 or 0,
            armed=spec.soilContactPassArmed == true and 1 or 0,
            exit_geometry=exitGeometryActive and 1 or 0,
            reason="below Vanilla working speed", speed_kph=passSpeedKph
        })
        return false
    end
    spec.soilRecentCells = spec.soilRecentCells or {}
    pruneRecentSoilCoverage(spec, now, self.PASS_COOLDOWN_MS)
    local touchedCellCount = 0
    local eligibleCells, changedCells, changedLayers = 0, 0, 0
    local touchedCoverageSum, newlyAppliedCoverageSum = 0, 0
    local overlapPhysicalCoverageSum = 0
    local overlapToleranceCoverageSum = 0
    local overlapRepeatCoverageSum = 0
    local moistureSum, moistureEffectSum, moistureDraftSum = 0, 0, 0
    local frostSeveritySum, frostDraftSum = 0, 0
    local frostQualitySum, frostPenetrationSum = 0, 0
    local moistureSampleCount = 0
    local changedLayerIds = {}
    local overspeed = profile.overspeed
    local overspeedSeverity, speedKph, speedReferenceKph, speedRatio =
        getSoilOverspeed(implement)
    local previousWorkAreaGeometry = nil
    local workAreaSweepAgeMs, workAreaSweepDistanceM = 0, 0
    local workAreaSweepMaximumDistanceM = 0
    local workAreaHistory = spec.soilPreviousWorkAreaGeometry[workArea]
    if type(workAreaHistory) == "table"
        and workAreaHistory.geometry ~= nil then
        -- Session-only migration from the former single-class entry.
        workAreaHistory = {[workAreaHistory.classKey or classKey]=
            workAreaHistory}
        spec.soilPreviousWorkAreaGeometry[workArea] = workAreaHistory
    end
    local previousWorkAreaEntry = type(workAreaHistory) == "table"
        and workAreaHistory[classKey] or nil
    if currentWorkAreaGeometry ~= nil
        and type(previousWorkAreaEntry) == "table"
        and previousWorkAreaEntry.classKey == classKey
        and previousWorkAreaEntry.geometry ~= nil then
        workAreaSweepAgeMs = math.max(now
            - (tonumber(previousWorkAreaEntry.time) or now), 0)
        workAreaSweepDistanceM = getWorkAreaGeometryDistance(
            currentWorkAreaGeometry, previousWorkAreaEntry.geometry)
        if not traceActive and not exitGeometryActive
            and workAreaSweepAgeMs < WORK_AREA_PROCESS_INTERVAL_MS
            and workAreaSweepDistanceM < WORK_AREA_PROCESS_DISTANCE_M then
            -- Keep the last processed geometry untouched. The next accepted
            -- callback sweeps from it to the new position, so no worked area
            -- is lost and results remain distance-based instead of FPS-based.
            return false
        end
        local expectedDistance = math.max(tonumber(speedKph) or 0, 0)
            / 3.6 * workAreaSweepAgeMs / 1000
        local maximumDistance = math.min(
            WORK_AREA_SWEEP_DISTANCE_MARGIN_M
                + expectedDistance * WORK_AREA_SWEEP_SPEED_FACTOR,
            WORK_AREA_SWEEP_ABSOLUTE_LIMIT_M)
        workAreaSweepMaximumDistanceM = maximumDistance
        if workAreaSweepAgeMs <= WORK_AREA_SWEEP_MAX_AGE_MS
            and workAreaSweepDistanceM <= maximumDistance then
            previousWorkAreaGeometry = previousWorkAreaEntry.geometry
        end
    end
    if currentWorkAreaGeometry ~= nil then
        workAreaHistory = spec.soilPreviousWorkAreaGeometry[workArea]
        if type(workAreaHistory) ~= "table"
            or workAreaHistory.geometry ~= nil then
            workAreaHistory = {}
            spec.soilPreviousWorkAreaGeometry[workArea] = workAreaHistory
        end
        workAreaHistory[classKey] = {
            geometry=currentWorkAreaGeometry, classKey=classKey, time=now
        }
    end
    traceRecord("callback_active", {
        ground_contact=groundContactActive and 1 or 0,
        armed=spec.soilContactPassArmed == true and 1 or 0,
        exit_geometry=exitGeometryActive and 1 or 0,
        reason=exitGeometryActive and "field exit continuation"
            or "vanilla successful area",
        speed_kph=speedKph,
        previous_age_ms=workAreaSweepAgeMs,
        sweep_distance_m=workAreaSweepDistanceM,
        sweep_max_distance_m=workAreaSweepMaximumDistanceM,
        sweep_accepted=previousWorkAreaGeometry ~= nil and 1 or 0
    })
    local engagement, engagementDraftRetention, engagementAbrasionContact,
        engagementRatio, engagementState = 1, 1, 1, speedRatio, "notApplicable"
    if TerraLogic ~= nil and TerraLogic.getExtremeEngagement ~= nil then
        engagement, engagementDraftRetention, engagementAbrasionContact,
            engagementRatio, engagementState =
            TerraLogic.getExtremeEngagement(implement, speedKph)
    end
    local damage = implement.getDamageAmount ~= nil
        and math.clamp(tonumber(implement:getDamageAmount()) or 0, 0, 1) or 0
    local wearResponse = TerraLogicImplementProfiles ~= nil
        and TerraLogicImplementProfiles.getWearResponse ~= nil
        and TerraLogicImplementProfiles.getWearResponse(classKey) or nil
    local wearProgression = TerraLogic ~= nil
        and TerraLogic.getWearProgression ~= nil
        and TerraLogic.getWearProgression(damage) or damage
    local wearEffectLoss = wearResponse ~= nil
        and math.clamp(tonumber(wearResponse.soilEffectLoss) or 0, 0, 0.50) or 0
    local wearStrengthMultiplier = 1 - wearEffectLoss * wearProgression
    local activeLayer = self.layers[self.activeMapMode]
    local activeLayerId = activeLayer ~= nil and activeLayer.id or nil
    local activeLayerChanged = false
    local plowParameters = classKey == "plow" and implement.spec_plow ~= nil
        and implement.spec_plow.workAreaParameters or nil
    -- Vanilla updates the ground density before this callback. In create-field
    -- mode the centre of a coarse TerraLogic cell can nevertheless still lie
    -- just outside the narrow new strip. A positive changed area proves that
    -- Vanilla accepted this owned-land pass, so those touched cells may seed
    -- the dynamic field mask as well.
    local createsNewField = classKey == "plow"
        and plowParameters ~= nil
        and plowParameters.limitToField == false
        and rawChangedArea > 0
    if createsNewField and currentWorkAreaGeometry~=nil and TerraLogicFieldCatalog~=nil then
        local geometry=currentWorkAreaGeometry
        TerraLogicFieldCatalog:markTopologyDirty(geometry.sx+geometry.widthX*.5+geometry.heightX*.5,
            geometry.sz+geometry.widthZ*.5+geometry.heightZ*.5)
    end
    -- Surface, deep, aggregate, roughness and recovery share only three raster
    -- resolutions. Rasterize each size once per callback; the finer occupancy
    -- sampling therefore does not multiply work for every individual layer.
    local touchedCellsBySize = {}
    local mechanicalContextBySoilType = {}
    local preparedCoverageGeometry = prepareWorkAreaCoverageGeometry(
        currentWorkAreaGeometry, previousWorkAreaGeometry)
    local aggregateCellSize = 2
    for _, candidateLayer in ipairs(self.layers or {}) do
        if candidateLayer.id == "aggregateSize" then
            aggregateCellSize = candidateLayer.cellSize
            break
        end
    end
    local exitGeometryTouchesField = false
    local function getPassCells(cellSize)
        local key = tostring(cellSize)
        if touchedCellsBySize[key] == nil then
            local cells = getTouchedSoilCells(
                workArea, cellSize, previousWorkAreaGeometry,
                preparedCoverageGeometry)
            -- During create-field passes Vanilla may expose the new ground
            -- type one callback later. Preserve that dedicated seeding path;
            -- normal fieldwork is clipped and normalized against the current
            -- live field surface here.
            local normalizedCells = createsNewField and cells
                or normalizeCellsToCultivatableArea(self, cells, cellSize)
            touchedCellsBySize[key] = normalizedCells
            if traceActive and math.abs(cellSize-aggregateCellSize) < 0.001 then
                local retained = {}
                for _, retainedCell in ipairs(normalizedCells) do
                    retained[getCellKey(retainedCell.ix,
                        retainedCell.iz)] = true
                end
                for _, rawCell in ipairs(cells) do
                    if retained[getCellKey(rawCell.ix, rawCell.iz)] ~= true then
                        traceRecord("cell_clipped", {
                            layer="aggregateSize", cell_x=rawCell.ix,
                            cell_z=rawCell.iz,
                            raw_coverage=rawCell.rawCoverage
                                or rawCell.coverage,
                            raw_samples=rawCell.rawCoveredSamples
                                or math.floor(clamp01(rawCell.coverage)
                                    * WORK_AREA_COVERAGE_SAMPLES + 0.5),
                            field_samples=rawCell.fieldSamples or 0,
                            worked_samples=rawCell.workedFieldSamples or 0,
                            normalized_coverage=0,
                            cultivatable_coverage=rawCell.cultivatableCoverage
                                or 0,
                            reason="live cultivatable mask rejected cell",
                            eligible=0, write_applied=0
                        })
                    end
                end
            end
            if exitGeometryActive and #touchedCellsBySize[key] > 0 then
                exitGeometryTouchesField = true
            end
        end
        return touchedCellsBySize[key]
    end
    if createsNewField then
        -- Deep compaction and resilience are intentionally not direct plough
        -- effects, but their default/current values still belong to the newly
        -- created field and must therefore receive display coverage.
        for _, displayLayer in ipairs(self.layers) do
            for _, displayCell in ipairs(getPassCells(
                    displayLayer.cellSize)) do
                if self:ensureVisualizationCellVisible(
                        displayLayer.id, displayCell.ix, displayCell.iz)
                    and displayLayer.id == activeLayerId then
                    activeLayerChanged = true
                end
            end
        end
    end
    for _, layer in ipairs(self.layers) do
        local rule = profile[layer.id]
        if rule ~= nil then
            local touchedCells = getPassCells(layer.cellSize)
            touchedCellCount = touchedCellCount + #touchedCells
            for _, cell in ipairs(touchedCells) do
                -- Cool down one functional soil pass, not the whole vehicle.
                -- This preserves overlap protection for split WorkAreas of a
                -- single plough/packer while allowing integrated sequential
                -- components to apply their distinct targets to the same cell.
                local key = tostring(classKey) .. ":" .. layer.id .. ":"
                    .. getCellKey(cell.ix, cell.iz)
                touchedCoverageSum = touchedCoverageSum
                    + clamp01(cell.coverage)
                local x = (cell.ix + 0.5) * layer.cellSize
                local z = (cell.iz + 0.5) * layer.cellSize
                local current = self:getValueAtWorldPosition(layer.id, x, z)
                local coverageEntry, coverageChanged, previousCoverage,
                    coverageDebug =
                    getCoverageEntry(spec, key, cell, now,
                        self.PASS_COOLDOWN_MS, current,
                        coverageDiagnosticsActive)
                local traceSurface, traceEligible = "not evaluated", false
                local traceModelValue, traceAfterValue = nil, current
                local traceWriteApplied = false
                local traceDetails = traceActive
                    and (layer.id == "aggregateSize" or layer.id == "roughness")
                    and {
                        build="1.2.0.254",
                        base_value=coverageEntry.baseValue,
                        last_applied_value=coverageEntry.lastAppliedValue,
                        last_model_value=coverageEntry.lastModelValue,
                        speed_kph=speedKph,
                        rated_speed_kph=spec.ratedSpeed,
                        overspeed_severity=overspeedSeverity,
                        engagement=engagement
                    } or nil
                if coverageDiagnosticsActive
                    and layer.id == "aggregateSize" then
                    local denominator = math.max(tonumber(
                        cell.coverageDenominator)
                        or WORK_AREA_COVERAGE_SAMPLES, 1)
                    local physicalCoverage =
                        (tonumber(coverageDebug.physicalSamples) or 0)
                            / denominator
                    local toleranceCoverage =
                        (tonumber(coverageDebug.toleranceSamples) or 0)
                            / denominator
                    local physicalFirstCoverage =
                        (tonumber(
                            coverageDebug.physicalFirstAddedSamples) or 0)
                            / denominator
                    local repeatedCoverage =
                        (tonumber(coverageDebug.repeatAddedSamples) or 0)
                            / denominator
                    local firstCoverage =
                        (tonumber(coverageDebug.firstAddedSamples) or 0)
                            / denominator
                    overlapPhysicalCoverageSum =
                        overlapPhysicalCoverageSum
                        + physicalCoverage
                    overlapToleranceCoverageSum =
                        overlapToleranceCoverageSum
                        + toleranceCoverage
                    overlapRepeatCoverageSum =
                        overlapRepeatCoverageSum
                        + repeatedCoverage

                    -- The one-second audit panel can sample between two
                    -- WorkArea callbacks, after another component or a wheel
                    -- impact already replaced lastPass. Preserve compact
                    -- cumulative totals on the implement so a CSV can compare
                    -- its first and last row without a second recorder.
                    local audit = spec.soilOverlapAudit or {
                        physicalFirstCoverage=0, toleranceOnlyCoverage=0,
                        firstCoverage=0, repeatedPhysicalCoverage=0,
                        appliedCoverage=0, sampledCells=0
                    }
                    spec.soilOverlapAudit = audit
                    audit.physicalFirstCoverage =
                        audit.physicalFirstCoverage + physicalFirstCoverage
                    audit.toleranceOnlyCoverage =
                        audit.toleranceOnlyCoverage + toleranceCoverage
                    audit.firstCoverage = audit.firstCoverage + firstCoverage
                    audit.repeatedPhysicalCoverage =
                        audit.repeatedPhysicalCoverage + repeatedCoverage
                    audit.appliedCoverage = audit.appliedCoverage
                        + (tonumber(coverageDebug.addedSamples) or 0)
                            / denominator
                    audit.sampledCells = audit.sampledCells + 1
                    audit.lastTime = now
                end
                if coverageChanged then
                    local coverage = clamp01(coverageEntry.coverage)
                    local coverageDelta = math.max(
                        coverage - (tonumber(previousCoverage) or 0), 0)
                    newlyAppliedCoverageSum = newlyAppliedCoverageSum
                        + coverageDelta
                    local cultivatableCoverage = tonumber(
                        cell.cultivatableCoverage)
                    local surface = nil
                    local cellIsCultivatable = createsNewField
                        or (cultivatableCoverage or 0) > 0
                    -- normalizeCellsToCultivatableArea has already sampled
                    -- and clipped ordinary cells. Avoid repeating the native
                    -- terrain-density lookup once for every affected layer.
                    if not cellIsCultivatable then
                        surface = TerraLogicQualityManager:
                            getSurfaceTypeAtWorldPosition(x, z)
                        cellIsCultivatable = surface == "field"
                            or surface == "grassField"
                    end
                    traceSurface = surface ~= nil
                        and tostring(surface) or "normalizedField"
                    if cellIsCultivatable then
                        traceEligible = true
                        eligibleCells = eligibleCells + 1
                        local visibilityEnsured = self:ensureVisualizationCellVisible(
                            layer.id, cell.ix, cell.iz)
                        if traceDetails ~= nil then
                            traceDetails.visibility_ensured = visibilityEnsured and 1 or 0
                        end
                        if visibilityEnsured and layer.id == activeLayerId then
                            activeLayerChanged = true
                        end
                        -- Re-evaluate the accumulated fraction from the state
                        -- at which this physical pass first entered the cell.
                        -- Only its delta over the last modelled fraction is
                        -- added to the live value, preserving a different
                        -- component (for example an integrated packer) that
                        -- may have acted between two callbacks.
                        local modelCurrent = clamp01(
                            coverageEntry.baseValue)
                        local soilTypeIndex =
                            self:getPFSoilTypeAtWorldPosition(x, z)
                        local contextKey = tostring(soilTypeIndex or "default")
                        local mechanicalContext =
                            mechanicalContextBySoilType[contextKey]
                        if mechanicalContext == nil then
                            local moistureResponse =
                                TerraLogicSoilMoistureManager ~= nil
                                and TerraLogicSoilMoistureManager:
                                    getMechanicalResponse(
                                        soilTypeIndex, classKey,
                                        operationWorkDepthCm) or nil
                            mechanicalContext = {
                                soilTypeIndex=soilTypeIndex,
                                moistureResponse=moistureResponse,
                                soilResponse=TerraLogicSoilProfiles:
                                    getPFSoilResponse(soilTypeIndex, classKey)
                            }
                            mechanicalContextBySoilType[contextKey] =
                                mechanicalContext
                        end
                        soilTypeIndex = mechanicalContext.soilTypeIndex
                        local moistureResponse =
                            mechanicalContext.moistureResponse
                        local moistureEffectiveness = moistureResponse ~= nil
                            and tonumber(moistureResponse.soilEffectiveness) or 1
                        moistureSum = moistureSum + (moistureResponse ~= nil
                            and tonumber(moistureResponse.effective) or 0.5)
                        moistureEffectSum = moistureEffectSum
                            + moistureEffectiveness
                        moistureDraftSum = moistureDraftSum
                            + (moistureResponse ~= nil
                                and tonumber(moistureResponse.draftMultiplier) or 1)
                        frostSeveritySum = frostSeveritySum
                            + (moistureResponse ~= nil
                                and tonumber(moistureResponse.frostSeverity) or 0)
                        frostDraftSum = frostDraftSum
                            + (moistureResponse ~= nil
                                and tonumber(moistureResponse.frostDraftMultiplier) or 1)
                        frostQualitySum = frostQualitySum
                            + (moistureResponse ~= nil
                                and tonumber(moistureResponse.frostQualityFactor) or 1)
                        frostPenetrationSum = frostPenetrationSum
                            + (moistureResponse ~= nil
                                and tonumber(moistureResponse.penetrationFactor) or 1)
                        moistureSampleCount = moistureSampleCount + 1
                        local soilResponse = mechanicalContext.soilResponse
                        local minimumStrength = overspeed ~= nil
                            and overspeed.strengthScale ~= nil
                            and tonumber(overspeed.strengthScale[layer.id]) or 1
                        local strengthMultiplier = 1
                            - overspeedSeverity * (1 - clamp01(minimumStrength))
                        local textureStrength = soilResponse ~= nil
                            and tonumber(soilResponse.strength[layer.id]) or 1
                        strengthMultiplier = strengthMultiplier
                            * textureStrength * wearStrengthMultiplier
                            * engagement
                            * moistureEffectiveness * coverage
                        local rollerContact = 1
                        if classKey == "roller" then
                            local rollerRoughness = layer.id == "roughness"
                                and modelCurrent or self:getValueAtWorldPosition(
                                    "roughness", x, z)
                            rollerContact = TerraLogicSoilProfiles:getRollerContactEfficiency(
                                    {roughness=rollerRoughness},
                                    speedKph,
                                    spec ~= nil and spec.ratedSpeed or 0)
                            strengthMultiplier = strengthMultiplier
                                * rollerContact
                        end
                        local targetOffset = soilResponse ~= nil
                            and tonumber(soilResponse.targetOffset[layer.id]) or 0
                        local effectiveRule, effectiveTargetOffset,
                            inversionBounded = getBoundedInversionRule(
                                classKey, layer.id, modelCurrent, rule,
                                targetOffset, soilTypeIndex, moistureResponse,
                                layer.id == "aggregateSize"
                                    and self:getValueAtWorldPosition(
                                        "resilience", x, z) or 0.5)
                        local modelNextValue = applyRule(
                            modelCurrent, effectiveRule, strengthMultiplier,
                            effectiveTargetOffset)
                        if traceDetails ~= nil then
                            traceDetails.target_value = clamp01(
                                (tonumber(effectiveRule.target) or 0)
                                    + (tonumber(effectiveTargetOffset) or 0))
                            traceDetails.rule_mode = effectiveRule.mode or "both"
                            traceDetails.effective_strength = clamp01(
                                clamp01(effectiveRule.strength) * strengthMultiplier)
                            traceDetails.roller_contact = rollerContact
                            traceDetails.moisture_effectiveness = moistureEffectiveness
                            traceDetails.soil_type = soilTypeIndex
                            traceDetails.after_rule_value = modelNextValue
                        end
                        -- Crossing from the fine/structureless bad side to
                        -- coarse clods must not briefly pass through a better
                        -- crumb score. Preserve at least the previous distance
                        -- from the 0.50 optimum when inversion crosses sides.
                        if inversionBounded and modelNextValue < 0.50
                            and math.abs(modelNextValue - 0.50)
                                < math.abs(modelCurrent - 0.50) then
                            modelNextValue = clamp01(1 - modelCurrent)
                        end
                        local speedRule = overspeedSeverity > 0
                            and overspeed ~= nil and overspeed.effects ~= nil
                            and overspeed.effects[layer.id] or nil
                        if speedRule ~= nil then
                            local effectSeverity = overspeedSeverity
                                ^ math.max(tonumber(
                                    overspeed.effectSeverityExponent) or 1,
                                    0.25)
                            modelNextValue = applyRule(
                                modelNextValue, speedRule,
                                effectSeverity * textureStrength
                                    * engagement ^ 0.75 * coverage)
                        end
                        if classKey == "roller"
                            and layer.id == "surfaceCompaction"
                            and overspeedSeverity > 0 then
                            local positiveNoise = math.max(
                                getOperationCellVariation(
                                    cell.ix, cell.iz, "rollerImpact"), 0)
                            local spike = 0.025 * overspeedSeverity
                                * (1 - rollerContact)
                                * positiveNoise * positiveNoise
                            modelNextValue = clamp01(modelNextValue
                                + spike * coverage * (1 - modelNextValue))
                        end
                        local variability = overspeed ~= nil
                            and overspeed.variability ~= nil
                            and tonumber(overspeed.variability[layer.id]) or 0
                        if classKey == "plow" and variability > 0
                            and overspeedSeverity > 0 then
                            local variation = getOperationCellVariation(
                                cell.ix, cell.iz, layer.id)
                            local amplitude = variability
                                * math.sqrt(overspeedSeverity)
                                * math.sqrt(engagement)
                                * (0.75 + 0.25 * textureStrength)
                            modelNextValue = clamp01(modelNextValue
                                + variation * amplitude * coverage)
                        end
                        if traceDetails ~= nil then
                            traceDetails.after_speed_value = modelNextValue
                        end
                        modelNextValue = applyMoistureSoilReaction(
                            classKey, layer.id, modelNextValue,
                            moistureResponse, engagement * coverage)
                        traceModelValue = modelNextValue
                        -- The GRLE stores a quantized value. Adding every new
                        -- floating-point model delta to that rounded value
                        -- made the final result depend on how many callback
                        -- fragments happened to cross the cell. Anchor the
                        -- cumulative model to the last value actually stored
                        -- in the raster. A genuine change by a different
                        -- component remains present as current-lastApplied.
                        local lastAppliedValue = clamp01(
                            coverageEntry.lastAppliedValue ~= nil
                                and coverageEntry.lastAppliedValue
                                or coverageEntry.baseValue)
                        local nextValue = clamp01(modelNextValue
                            + current - lastAppliedValue)
                        -- Keep actual stored and proposed values separate,
                        -- including changes below the write threshold.
                        if traceDetails ~= nil then
                            traceDetails.proposed_value = nextValue
                        end
                        if math.abs(nextValue - current) > 0.002 then
                            if self:setStateCell(
                                    layer.id, cell.ix, cell.iz, nextValue) then
                                coverageEntry.lastModelValue = modelNextValue
                                -- DensityMapModifier stores the same encoded
                                -- integer produced here. Decode that exact
                                -- quantized value instead of reading the map
                                -- back immediately after every write.
                                coverageEntry.lastAppliedValue = decode(
                                    encode(nextValue,
                                        getLayerChannels(layer.id)),
                                    TerraLogicSoilProfiles.DEFAULTS[layer.id],
                                    getLayerChannels(layer.id))
                                traceAfterValue =
                                    coverageEntry.lastAppliedValue
                                traceWriteApplied = true
                                changedCells = changedCells + 1
                                if not changedLayerIds[layer.id] then
                                    changedLayerIds[layer.id] = true
                                    changedLayers = changedLayers + 1
                                end
                                if layer.id == activeLayerId then
                                    activeLayerChanged = true
                                end
                                self.lastWrite = {
                                    classKey = classKey,
                                    layerId = layer.id,
                                    ix = cell.ix,
                                    iz = cell.iz,
                                    beforeValue = current,
                                    value = nextValue,
                                    delta = nextValue - current,
                                    sourceName = implement.getFullName ~= nil
                                        and tostring(implement:getFullName())
                                        or (implement.getName ~= nil
                                            and tostring(implement:getName())
                                            or tostring(classKey)),
                                    sourceConfigFileName = tostring(
                                        implement.configFileName or ""),
                                    time = now
                                }
                            end
                        end
                    end
                end
                if traceDetails ~= nil then
                    coverageDebug = coverageDebug or {}
                    local record = {
                        layer=layer.id, cell_x=cell.ix, cell_z=cell.iz,
                        raw_coverage=cell.rawCoverage or cell.coverage,
                        raw_samples=cell.rawCoveredSamples or 0,
                        field_samples=cell.fieldSamples
                            or cell.coverageDenominator,
                        worked_samples=cell.workedFieldSamples
                            or math.floor(clamp01(cell.coverage)
                                * (cell.coverageDenominator
                                    or WORK_AREA_COVERAGE_SAMPLES) + 0.5),
                        normalized_coverage=cell.coverage,
                        cultivatable_coverage=cell.cultivatableCoverage or 1,
                        cache_state=coverageDebug.state or "unknown",
                        cache_gap_ms=coverageDebug.gapMs or 0,
                        cache_added_samples=coverageDebug.addedSamples or 0,
                        cache_first_added_samples=
                            coverageDebug.firstAddedSamples or 0,
                        cache_repeat_added_samples=
                            coverageDebug.repeatAddedSamples or 0,
                        physical_samples=coverageDebug.physicalSamples or 0,
                        tolerance_samples=coverageDebug.toleranceSamples or 0,
                        cache_previous_coverage=
                            coverageDebug.previousCoverage or 0,
                        cache_after_coverage=coverageDebug.afterCoverage or 0,
                        cache_repeat_coverage=
                            coverageDebug.repeatCoverage or 0,
                        cache_repeat_threshold=
                            coverageDebug.repeatThreshold or 0,
                        surface=traceSurface,
                        eligible=traceEligible and 1 or 0,
                        before_value=current,
                        model_value=traceModelValue,
                        after_value=traceAfterValue,
                        delta=traceAfterValue-current,
                        write_applied=traceWriteApplied and 1 or 0
                    }
                    for name, value in pairs(traceDetails) do record[name] = value end
                    if layer.id == "roughness" then
                        record.evenness_before_pct = (1-current)*100
                        record.evenness_after_pct = (1-traceAfterValue)*100
                    end
                    traceRecord("cell", record)
                end
            end
        end
    end
    local resilienceChanged = self:applyResilienceWorkArea(
        implement, workArea, classKey, successfulArea, now, engagement,
        getPassCells(self.RESILIENCE_CELL_SIZE))
    if resilienceChanged > 0 then
        changedCells = changedCells + resilienceChanged
        if not changedLayerIds.resilience then
            changedLayerIds.resilience = true
            changedLayers = changedLayers + 1
        end
        activeLayerChanged = activeLayerChanged
            or activeLayerId == "resilience"
    end
    self:applyRecoveryAgeWorkArea(
        implement, workArea, classKey, successfulArea, now, engagement,
        getPassCells(self.RECOVERY_CELL_SIZE))
    if exitGeometryActive and not exitGeometryTouchesField then
        spec.soilContactPassArmed = false
    end
    -- Do not overwrite a meaningful pass with the same WorkArea's per-frame
    -- cooldown callbacks. This keeps tlSoil useful after the implement stops.
    if eligibleCells > 0 or self.lastPass == nil then
        self.lastPass = {
            classKey = classKey,
            implementName = implement.getFullName ~= nil
                and tostring(implement:getFullName())
                or (implement.getName ~= nil
                    and tostring(implement:getName()) or tostring(classKey)),
            configFileName = tostring(implement.configFileName or ""),
            coverage = tonumber(successfulArea) or 0,
            changedArea = rawChangedArea,
            totalArea = rawTotalArea,
            touchedCells = touchedCellCount,
            touchedCoverage = touchedCoverageSum,
            newlyAppliedCoverage = newlyAppliedCoverageSum,
            physicalCoverage = overlapPhysicalCoverageSum,
            toleranceOnlyCoverage = overlapToleranceCoverageSum,
            repeatedPhysicalCoverage = overlapRepeatCoverageSum,
            coverageSubdivisions = WORK_AREA_COVERAGE_SUBDIVISIONS,
            sweepActive = previousWorkAreaGeometry ~= nil,
            sweepAgeMs = workAreaSweepAgeMs,
            sweepDistanceM = workAreaSweepDistanceM,
            eligibleCells = eligibleCells,
            changedCells = changedCells,
            changedLayers = changedLayers,
            speedKph = speedKph,
            speedReferenceKph = speedReferenceKph,
            speedRatio = speedRatio,
            overspeedSeverity = overspeedSeverity,
            engagement = engagement,
            engagementDraftRetention = engagementDraftRetention,
            engagementAbrasionContact = engagementAbrasionContact,
            engagementRatio = engagementRatio,
            engagementState = engagementState,
            damage = damage,
            wearStrengthMultiplier = wearStrengthMultiplier,
            moisture = moistureSampleCount > 0
                and moistureSum / moistureSampleCount or 0.5,
            moistureSoilEffectiveness = moistureSampleCount > 0
                and moistureEffectSum / moistureSampleCount or 1,
            moistureDraftMultiplier = moistureSampleCount > 0
                and moistureDraftSum / moistureSampleCount or 1,
            frostSeverity = moistureSampleCount > 0
                and frostSeveritySum / moistureSampleCount or 0,
            frostDraftMultiplier = moistureSampleCount > 0
                and frostDraftSum / moistureSampleCount or 1,
            frostQualityFactor = moistureSampleCount > 0
                and frostQualitySum / moistureSampleCount or 1,
            frostPenetrationFactor = moistureSampleCount > 0
                and frostPenetrationSum / moistureSampleCount or 1,
            time = now
        }
        if TerraLogicTutorialManager ~= nil then
            TerraLogicTutorialManager:observeWork(implement, self.lastPass)
        end
    end
    if changedCells > 0 then
        self.dirty = true
    end
    if activeLayerChanged then
        if not self.visualizationDirty then
            self.overlayRefreshTime = now + self.OVERLAY_REFRESH_DELAY_MS
        end
        self.visualizationDirty = true
    end
    spec.soilLastClass = classKey
    spec.soilLastChangedCells = changedCells
    spec.soilLastSpeedKph = speedKph
    spec.soilLastSpeedReferenceKph = speedReferenceKph
    spec.soilLastSpeedRatio = speedRatio
    spec.soilLastOverspeedSeverity = overspeedSeverity
    spec.soilLastWearStrengthMultiplier = wearStrengthMultiplier
    spec.soilLastMoisture = moistureSampleCount > 0
        and moistureSum / moistureSampleCount or nil
    spec.soilLastMoistureEffectiveness = moistureSampleCount > 0
        and moistureEffectSum / moistureSampleCount or nil
    spec.soilLastFrostSeverity = moistureSampleCount > 0
        and frostSeveritySum / moistureSampleCount or nil
    spec.soilLastFrostDraftMultiplier = moistureSampleCount > 0
        and frostDraftSum / moistureSampleCount or nil
    spec.soilLastFrostQualityFactor = moistureSampleCount > 0
        and frostQualitySum / moistureSampleCount or nil
    spec.soilLastFrostPenetrationFactor = moistureSampleCount > 0
        and frostPenetrationSum / moistureSampleCount or nil
    if TerraLogicLogging.verbose and eligibleCells > 0 and (spec.soilPassLogTime == nil
            or now - spec.soilPassLogTime >= 5000) then
        spec.soilPassLogTime = now
        TerraLogicLogging.debug(
            "[FS25_TerraLogic] Soil pass %s: vanillaArea(changed/total)=%.3f/%.3f touched=%d field=%d changed=%d/%d speed=%.1f/%.1f ratio=%.2f overspeed=%.2f wearStrength=%.3f moisture=%.3f effect=%.3f frost=%.3f penetration=%.3f",
            tostring(classKey), rawChangedArea, rawTotalArea,
            touchedCellCount, eligibleCells, changedCells, changedLayers,
            speedKph, speedReferenceKph, speedRatio, overspeedSeverity,
            wearStrengthMultiplier,
            moistureSampleCount > 0 and moistureSum / moistureSampleCount or 0.5,
            moistureSampleCount > 0
                and moistureEffectSum / moistureSampleCount or 1,
            moistureSampleCount > 0
                and frostSeveritySum / moistureSampleCount or 0,
            moistureSampleCount > 0
                and frostPenetrationSum / moistureSampleCount or 1)
    end
    return true
end

function TerraLogicSoilManager:getDisplayValue(layerId, value)
    -- Compaction is deliberately exposed in its native direction everywhere:
    -- 0 is loose/good and 1 is severely compacted/bad. Aggregate quality is
    -- best around 0.50; stored roughness is inverted into displayed evenness.
    if layerId == "aggregateSize" then
        return 1 - math.min(math.abs(value - 0.50) / 0.50, 1)
    end
    if layerId == "surfaceCompaction" or layerId == "deepCompaction" then
        return clamp01(value)
    end
    if layerId == "resilience" then return clamp01(value) end
    return 1 - clamp01(value)
end

function TerraLogicSoilManager:getCompactionDisplayThresholds(layerId)
    return compactionThresholds(layerId)
end

function TerraLogicSoilManager:getCompactionYieldLoss(layerId, value)
    local profile = TerraLogicSoilProfiles ~= nil
        and TerraLogicSoilProfiles.ROOT_YIELD ~= nil
        and TerraLogicSoilProfiles.ROOT_YIELD[layerId] or nil
    local good = clamp01(profile ~= nil and profile.good
        or (layerId == "deepCompaction" and 0.10 or 0.30))
    local maximum = clamp01(profile ~= nil and profile.maximumLoss
        or (layerId == "deepCompaction" and 0.26 or 0.15))
    local exponent = math.max(tonumber(profile ~= nil
        and profile.exponent) or (layerId == "deepCompaction" and 1.45 or 1.40),
        1)
    local normalized = clamp01((clamp01(value)-good)
        / math.max(1-good, 0.0001))
    return maximum * normalized ^ exponent
end

-- Current soil-condition summary shown as the dynamic Tillage/Soil entry.
-- It is descriptive only and is never used as one monolithic yield factor.
function TerraLogicSoilManager:getTillageQualityFromState(state)
    if state == nil then return nil end
    local shallow = 1 - clamp01(state.surfaceCompaction)
    local deep = 1 - clamp01(state.deepCompaction)
    local tilth = self:getDisplayValue(
        "aggregateSize", clamp01(state.aggregateSize))
    local levelness = 1 - clamp01(state.roughness)
    return clamp01(shallow * 0.30 + deep * 0.30
        + tilth * 0.25 + levelness * 0.15), {
        shallow = shallow,
        deep = deep,
        tilth = tilth,
        levelness = levelness
    }
end

function TerraLogicSoilManager:getTillageQualityAtWorldPosition(x, z)
    return self:getTillageQualityFromState(
        self:getStateAtWorldPosition(x, z))
end

-- Only root-zone consequences reach harvest directly. Seedbed tilth and
-- levelness already act through seeding Work Quality and physical emergence
-- gaps. The best practical plough/subsoiler targets are yield-neutral; values
-- below them do not invent a bonus. Above those targets, mildly convex curves
-- make small misses visible while deep compaction remains dominant.
function TerraLogicSoilManager:getRootYieldFactorFromState(state)
    if state == nil then return 1, 0, 0 end
    local balance = TerraLogicSoilProfiles ~= nil
        and TerraLogicSoilProfiles.ROOT_YIELD or nil
    local shallow = balance ~= nil and balance.surfaceCompaction or nil
    local deep = balance ~= nil and balance.deepCompaction or nil
    local function getLoss(value, profile, fallbackMaximum, fallbackExponent)
        local good = clamp01(profile ~= nil and profile.good or 0)
        local normalized = clamp01(
            (clamp01(value) - good) / math.max(1 - good, 0.0001))
        local exponent = math.max(profile ~= nil
            and tonumber(profile.exponent) or fallbackExponent, 1)
        local maximum = clamp01(profile ~= nil
            and profile.maximumLoss or fallbackMaximum)
        return maximum * normalized ^ exponent
    end
    local shallowLoss = getLoss(
        state.surfaceCompaction, shallow, 0.15, 1.40)
    local deepLoss = getLoss(
        state.deepCompaction, deep, 0.26, 1.45)
    return clamp01((1 - shallowLoss) * (1 - deepLoss)),
        shallowLoss, deepLoss
end

function TerraLogicSoilManager:getRootYieldFactorAtWorldPosition(x, z)
    return self:getRootYieldFactorFromState(
        self:getStateAtWorldPosition(x, z))
end

-- Legacy comparison retained for the yield audit. It reproduces the v215
-- calculation exactly: one topsoil sample at the centre and every 2 m deep
-- cell inside the 4 m crop-history footprint.
function TerraLogicSoilManager:getRootYieldFactorForAreaLegacy(
        centerX, centerZ, areaSize)
    areaSize = math.max(tonumber(areaSize) or self.CELL_SIZE, 0.01)
    local deepCellSize = getLayerCellSize("deepCompaction")
    local cellsPerSide = math.max(math.floor(
        areaSize / deepCellSize + 0.5), 1)
    if cellsPerSide <= 1 then
        return self:getRootYieldFactorAtWorldPosition(centerX, centerZ)
    end
    local baseState = self:getStateAtWorldPosition(centerX, centerZ)
    local sampleStep = areaSize / cellsPerSide
    local minX = centerX - areaSize * 0.5
    local minZ = centerZ - areaSize * 0.5
    local factorSum, deepLossSum, surfaceLoss = 0, 0, nil
    local samples = 0
    for sampleZ=0,cellsPerSide-1 do
        for sampleX=0,cellsPerSide-1 do
            local state = {
                surfaceCompaction=baseState.surfaceCompaction,
                deepCompaction=self:getValueAtWorldPosition(
                    "deepCompaction",
                    minX + (sampleX + 0.5) * sampleStep,
                    minZ + (sampleZ + 0.5) * sampleStep)
            }
            local factor, localSurfaceLoss, deepLoss =
                self:getRootYieldFactorFromState(state)
            factorSum = factorSum + factor
            deepLossSum = deepLossSum + deepLoss
            surfaceLoss = surfaceLoss or localSurfaceLoss
            samples = samples + 1
        end
    end
    return factorSum / math.max(samples, 1),
        surfaceLoss or 0, deepLossSum / math.max(samples, 1)
end

-- Work Quality and crop history remain stored in 4 m cells, while surface and
-- deep compaction already exist at 1 m and 2 m. Integrate the finest physical
-- layer across the complete history footprint and read both compaction layers
-- at every sub-cell centre. This preserves the spatial relationship between a
-- tyre track and the deep soil below it. The nonlinear local retained-yield
-- factors are averaged only afterwards; averaging raw compaction first would
-- change the established damage curve and therefore the balancing.
function TerraLogicSoilManager:getRootYieldFactorForArea(
        centerX, centerZ, areaSize)
    areaSize = math.max(tonumber(areaSize) or self.CELL_SIZE, 0.01)
    local surfaceCellSize = getLayerCellSize("surfaceCompaction")
    local cellsPerSide = math.max(math.floor(
        areaSize / surfaceCellSize + 0.5), 1)
    if cellsPerSide <= 1 then
        return self:getRootYieldFactorAtWorldPosition(centerX, centerZ)
    end
    local sampleStep = areaSize / cellsPerSide
    local minX = centerX - areaSize * 0.5
    local minZ = centerZ - areaSize * 0.5
    local factorSum, surfaceLossSum, deepLossSum = 0, 0, 0
    local samples = 0
    for sampleZ=0,cellsPerSide-1 do
        for sampleX=0,cellsPerSide-1 do
            local sampleWorldX = minX + (sampleX + 0.5) * sampleStep
            local sampleWorldZ = minZ + (sampleZ + 0.5) * sampleStep
            local state = {
                surfaceCompaction=self:getValueAtWorldPosition(
                    "surfaceCompaction", sampleWorldX, sampleWorldZ),
                deepCompaction=self:getValueAtWorldPosition(
                    "deepCompaction", sampleWorldX, sampleWorldZ)
            }
            local factor, localSurfaceLoss, deepLoss =
                self:getRootYieldFactorFromState(state)
            factorSum = factorSum + factor
            surfaceLossSum = surfaceLossSum + localSurfaceLoss
            deepLossSum = deepLossSum + deepLoss
            samples = samples + 1
        end
    end
    return factorSum / math.max(samples, 1),
        surfaceLossSum / math.max(samples, 1),
        deepLossSum / math.max(samples, 1)
end

function TerraLogicSoilManager:getColor(layerId, value)
    if layerId == "aggregateSize" then
        return tilthGradient(value)
    end
    if layerId == "surfaceCompaction" or layerId == "deepCompaction" then
        -- Maps and the on-foot bars retain the fine continuous scale. Only
        -- Field Analysis text uses the discrete agronomic traffic light.
        return gradient(clamp01(value))
    end
    if layerId == "resilience" then
        -- The dedicated palette is monotonic, so every persisted 8-bit step
        -- can be shown truthfully without the misleading colour reversal that
        -- originally motivated coarse two-percent display bands.
        return resilienceGradient(value)
    end
    return gradient(1 - self:getDisplayValue(layerId, value))
end

function TerraLogicSoilManager:buildOverlay(mode)
    local layer = self.layers[mode]
    local sourceMap = layer ~= nil and self.maps ~= nil
        and self.maps[layer.id] or nil
    local fieldMaskMap = layer ~= nil and self.visualizationMaps ~= nil
        and self.visualizationMaps[layer.id] or nil
    if not self.rasterReady or layer == nil or sourceMap == nil
        or fieldMaskMap == nil then
        return
    end
    local sourceSize = getBitVectorMapSize(sourceMap)
    -- The engine does not reliably upsample small custom source maps while a
    -- compare map is active. Deep compaction and resilience were
    -- therefore blank when a minimum 1024-pixel overlay was forced. Use the
    -- native source resolution for smaller layers and cap only oversized maps.
    local overlaySize = math.min(
        math.max(tonumber(sourceSize) or 1, 1),
        self.MAX_OVERLAY_RESOLUTION)
    if self.overlay ~= nil and self.overlayResolution ~= overlaySize then
        if delete ~= nil then delete(self.overlay) end
        self.overlay = nil
        self.overlayReady = false
        self.overlayPending = false
    end
    if self.overlay == nil then
        self.overlay = createDensityMapVisualizationOverlay(
            "terraLogicSoilOverlay", overlaySize, overlaySize)
        self.overlayResolution = overlaySize
    end
    -- TerraLogic owns this visualization handle and renders it directly.
    setOverlayColor(self.overlay, 1, 1, 1, 0.82)
    resetDensityMapVisualizationOverlay(self.overlay)
    -- The one-bit field mask deliberately has the exact same resolution as
    -- the source. This satisfies the overlay generator's compare-map contract
    -- while the displayed values always come straight from authoritative soil.
    local compareMap, compareMask = fieldMaskMap, 1
    local sourceChannels = getLayerChannels(layer.id)

    local default = TerraLogicSoilProfiles.DEFAULTS[layer.id]
    for state=1,2 ^ sourceChannels - 1 do
        local value = decode(state, default, sourceChannels)
        local r, g, b = self:getColor(layer.id, value)
        setDensityMapVisualizationOverlayStateColor(
            self.overlay, sourceMap, compareMap, compareMask,
            0, sourceChannels, state, r,g,b)
    end
    generateDensityMapVisualizationOverlay(self.overlay)
    self.overlayPending = true
    self.visualizationDirty = false
    if TerraLogicLogging.verbose and self.overlayLoggedMode ~= mode then
        self.overlayLoggedMode = mode
        TerraLogicLogging.debug(
            "[FS25_TerraLogic] Soil overlay active: mode=%d layer=%s handle=%s map=%s",
            mode, tostring(layer.id), tostring(self.overlay),
            tostring(sourceMap))
    end
end

-- Remember PF's live requester state even while its minimap layer is hidden.
-- This lets switching TerraLogic to Off restore exactly the map that the
-- selected implement currently needs, instead of guessing from vehicle type.
function TerraLogicSoilManager:recordPrecisionFarmingMinimapRequest(
        valueMap, isRequired, requester, isSelected)
    if valueMap == nil then return end
    local requests = self.pfMinimapRequests[valueMap]
    if requests == nil then
        requests = {}
        self.pfMinimapRequests[valueMap] = requests
    end
    local key = requester ~= nil and requester or PF_NIL_REQUESTER
    if isRequired == true then
        requests[key] = {
            requester = requester,
            isSelected = isSelected
        }
    else
        requests[key] = nil
        if next(requests) == nil then
            self.pfMinimapRequests[valueMap] = nil
        end
    end
end

-- TerraLogic only owns the small gameplay HUD minimap. Precision Farming also
-- routes full-screen map tools such as the tramline preview through its
-- ValueMap minimap requester API. Hiding those requests while a GUI is open
-- makes PF report "no field detected for preview", even though the field is
-- valid. Always release PF maps in menus and dialogs, then restore the
-- requested HUD suppression automatically when gameplay resumes.
function TerraLogicSoilManager:isPrecisionFarmingMinimapSuppressionAllowed()
    if g_gui == nil then return true end
    if g_gui.getIsGuiVisible ~= nil then
        local ok, visible = pcall(g_gui.getIsGuiVisible, g_gui)
        if ok then return visible ~= true end
    end
    if g_gui.currentGui ~= nil then return false end
    if g_gui.getIsDialogVisible ~= nil then
        local ok, visible = pcall(g_gui.getIsDialogVisible, g_gui)
        if ok and visible == true then return false end
    end
    return true
end

function TerraLogicSoilManager:applyPrecisionFarmingMinimapSuppression(
        suppressed)
    suppressed = suppressed == true
    if self.pfMinimapSuppressed == suppressed then return false end
    self.pfMinimapSuppressed = suppressed

    local valueMapClass = self.pfValueMapClass
        or getPrecisionFarmingValueMapClass()
    local nativeSetRequired = valueMapClass ~= nil
        and valueMapClass.terraLogicNativeSetRequireMinimapDisplay or nil
    if nativeSetRequired == nil then return false end

    local restored = 0
    for valueMap, requests in pairs(self.pfMinimapRequests or {}) do
        for _, request in pairs(requests) do
            -- Calling the saved PF implementation directly avoids feeding our
            -- own suppression/replay calls back into the request ledger.
            local ok = pcall(nativeSetRequired, valueMap,
                not suppressed, request.requester, request.isSelected)
            if ok then restored = restored + 1 end
        end
    end
    TerraLogicLogging.debug(
        "[FS25_TerraLogic] Precision Farming minimap %s (%d live requests)",
        suppressed and "suppressed" or "restored", restored)
    return true
end

function TerraLogicSoilManager:setPrecisionFarmingMinimapSuppressed(suppressed)
    self.pfMinimapSuppressionRequested = suppressed == true
    local effective = self.pfMinimapSuppressionRequested
        and self:isPrecisionFarmingMinimapSuppressionAllowed()
    return self:applyPrecisionFarmingMinimapSuppression(effective)
end

function TerraLogicSoilManager:refreshPrecisionFarmingMinimapSuppression()
    local effective = self.pfMinimapSuppressionRequested == true
        and self:isPrecisionFarmingMinimapSuppressionAllowed()
    return self:applyPrecisionFarmingMinimapSuppression(effective)
end

function TerraLogicSoilManager:installPrecisionFarmingMinimapHook()
    local valueMapClass = getPrecisionFarmingValueMapClass()
    if valueMapClass == nil
        or valueMapClass.setRequireMinimapDisplay == nil then
        return false
    end
    -- Version the global wrapper because PF's class can survive an ordinary
    -- mission reload inside the same game process. A new TerraLogic build must
    -- be able to replace an older wrapper without stacking another closure.
    local wrapperVersion = 2
    if valueMapClass.terraLogicMinimapWrapperVersion ~= wrapperVersion then
        local nativeSetRequired =
            valueMapClass.terraLogicNativeSetRequireMinimapDisplay
            or valueMapClass.setRequireMinimapDisplay
        valueMapClass.terraLogicNativeSetRequireMinimapDisplay = nativeSetRequired
        valueMapClass.setRequireMinimapDisplay = function(
                valueMap, isRequired, requester, isSelected)
            local manager = TerraLogicSoilManager
            if manager ~= nil
                and manager.recordPrecisionFarmingMinimapRequest ~= nil then
                manager:recordPrecisionFarmingMinimapRequest(
                    valueMap, isRequired, requester, isSelected)
                -- A dialog can become visible before TerraLogic's next update
                -- tick. Check the GUI directly here as well, so the very first
                -- tramline-preview request is never converted to false.
                if manager.pfMinimapSuppressed == true
                    and manager:isPrecisionFarmingMinimapSuppressionAllowed()
                    and isRequired == true then
                    -- PF still receives the matching false call, so an
                    -- already visible layer disappears immediately.
                    return nativeSetRequired(
                        valueMap, false, requester, isSelected)
                end
            end
            return nativeSetRequired(
                valueMap, isRequired, requester, isSelected)
        end
        valueMapClass.terraLogicMinimapWrapperInstalled = true
        valueMapClass.terraLogicMinimapWrapperVersion = wrapperVersion
    end
    self.pfValueMapClass = valueMapClass
    self.pfMinimapHookInstalled = true
    TerraLogicLogging.debug(
        "[FS25_TerraLogic] Precision Farming minimap arbitration installed")
    return true
end

function TerraLogicSoilManager:applyMapModeState(mode)
    self.activeMapMode = math.max(0,
        math.min(math.floor(tonumber(mode) or 0), #self.layers))
    self.minimapDrawLoggedMode = nil
    self.overlayLoggedMode = nil
    if self.activeMapMode > 0 then
        self.visualizationDirty = true
        self.overlayRefreshTime = g_currentMission ~= nil
            and g_currentMission.time or 0
    end
    TerraLogicLogging.debug(
        "[FS25_TerraLogic] Soil minimap mode %d (hook=%s)",
        self.activeMapMode,
        tostring(self.minimapHookInstalled == true))
end

-- Never run PF's native minimap animation and TerraLogic's local zoom in the
-- same interval. TL -> Off first completes the TL zoom-out while PF remains
-- suppressed. Off -> TL first lets PF finish disappearing, then starts TL.
function TerraLogicSoilManager:setMapMode(mode)
    mode = math.max(0,
        math.min(math.floor(tonumber(mode) or 0), #self.layers))
    local now = g_currentMission ~= nil and g_currentMission.time or 0
    self.pendingMapMode = nil
    self.mapModeTransitionPhase = nil
    self.mapModeTransitionEndTime = nil

    if self.activeMapMode > 0 and mode == 0 then
        self.pendingMapMode = 0
        self.mapModeTransitionPhase = "terraOut"
        self.mapModeTransitionEndTime = now
            + self.MINIMAP_ZOOM_TRANSITION_MS
        self:setPrecisionFarmingMinimapSuppressed(true)
        self:setMinimapZoomTarget(1)
        TerraLogicLogging.debug(
            "[FS25_TerraLogic] Soil minimap transition TL -> PF queued")
        return
    end
    if self.activeMapMode == 0 and mode > 0 then
        self.pendingMapMode = mode
        self.mapModeTransitionPhase = "pfOut"
        self.mapModeTransitionEndTime = now
            + self.PF_MINIMAP_TRANSITION_MS
        self:setMinimapZoomTarget(1)
        self:setPrecisionFarmingMinimapSuppressed(true)
        TerraLogicLogging.debug(
            "[FS25_TerraLogic] Soil minimap transition PF -> TL mode %d queued",
            mode)
        return
    end

    self:applyMapModeState(mode)
    self:setPrecisionFarmingMinimapSuppressed(mode > 0)
    self:setMinimapZoomTarget(self:getRequestedMinimapZoom())
end

function TerraLogicSoilManager:updateMapModeTransition(now)
    local phase = self.mapModeTransitionPhase
    if phase == nil or now < (self.mapModeTransitionEndTime or 0) then
        return
    end
    local mode = tonumber(self.pendingMapMode) or 0
    self.pendingMapMode = nil
    self.mapModeTransitionPhase = nil
    self.mapModeTransitionEndTime = nil
    if phase == "terraOut" then
        self:applyMapModeState(0)
        self:setMinimapZoomTarget(1)
        -- This native PF call starts only after TL has reached 1x.
        self:setPrecisionFarmingMinimapSuppressed(false)
    elseif phase == "pfOut" then
        -- PF has had its complete native transition window. Keep it hidden
        -- and only now start TerraLogic's independent zoom-in.
        self:applyMapModeState(mode)
        self:setPrecisionFarmingMinimapSuppressed(true)
        self:setMinimapZoomTarget(self:getRequestedMinimapZoom())
    end
end

function TerraLogicSoilManager:getRequestedMinimapZoom()
    if self.mapModeTransitionPhase == "terraOut"
        or self.mapModeTransitionPhase == "pfOut" then return 1 end
    if self.activeMapMode <= 0 then return 1 end
    local configured = TerraLogicSettings ~= nil
        and TerraLogicSettings.getSoilMinimapZoom ~= nil
        and TerraLogicSettings:getSoilMinimapZoom() or 0
    return math.max(tonumber(configured) or 0, 1)
end

function TerraLogicSoilManager:getAnimatedMinimapZoom(now)
    now = tonumber(now) or (g_currentMission ~= nil
        and g_currentMission.time or 0)
    if self.minimapZoomFactor == nil then
        self.minimapZoomFactor = 1
        self.minimapZoomFromFactor = 1
        self.minimapZoomTarget = 1
        self.minimapZoomStartTime = now
        self.minimapZoomEndTime = now
    end
    local startTime = tonumber(self.minimapZoomStartTime) or now
    local endTime = tonumber(self.minimapZoomEndTime) or startTime
    if endTime > startTime and now < endTime then
        local progress = smoothStep01(
            (now - startTime) / (endTime - startTime))
        self.minimapZoomFactor = self.minimapZoomFromFactor
            + (self.minimapZoomTarget - self.minimapZoomFromFactor) * progress
    else
        self.minimapZoomFactor = tonumber(self.minimapZoomTarget) or 1
    end
    return math.max(self.minimapZoomFactor, 1)
end

function TerraLogicSoilManager:setMinimapZoomTarget(target)
    target = math.max(tonumber(target) or 1, 1)
    local now = g_currentMission ~= nil and g_currentMission.time or 0
    if math.abs(target - (tonumber(self.minimapZoomTarget) or 1))
            < 0.0001 then
        return
    end
    self.minimapZoomFromFactor = tonumber(self.minimapZoomFactor)
        or tonumber(self.minimapZoomTarget) or 1
    self.minimapZoomTarget = target
    self.minimapZoomStartTime = now
    self.minimapZoomEndTime = now + self.MINIMAP_ZOOM_TRANSITION_MS
end

local function getLocalSoilNetworkPosition()
    if g_localPlayer == nil then return nil, nil end
    local vehicle = g_localPlayer.getCurrentVehicle ~= nil
        and g_localPlayer:getCurrentVehicle() or nil
    local node = vehicle ~= nil and (vehicle.rootNode
        or (vehicle.components ~= nil and vehicle.components[1] ~= nil
            and vehicle.components[1].node)) or g_localPlayer.rootNode
    if node == nil or node == 0 then return nil, nil end
    local x, _, z = getWorldTranslation(node)
    return x, z
end

local function getNetworkTileKey(layerIndex, tileX, tileZ)
    return string.format("%d:%d:%d", layerIndex, tileX, tileZ)
end

local function getNetworkLayerIndex(layerId)
    for index, layer in ipairs(TerraLogicSoilManager.layers) do
        if layer.id == layerId then return index end
    end
    return nil
end

local function getNetworkTileCoordinateKey(tileX, tileZ)
    return string.format("%d:%d", tileX, tileZ)
end

function TerraLogicSoilManager:clearClientNetworkLayerRevision(layerIndex)
    local prefix = tostring(layerIndex) .. ":"
    for _, collection in ipairs({
            self.clientNetworkTileKnownRevision,
            self.clientNetworkTileFresh,
            self.clientNetworkTilePending}) do
        for key in pairs(collection or {}) do
            if string.sub(key, 1, #prefix) == prefix then
                collection[key] = nil
            end
        end
    end
    for index=#(self.clientNetworkTileJobs or {}),1,-1 do
        if self.clientNetworkTileJobs[index].layerIndex == layerIndex then
            table.remove(self.clientNetworkTileJobs, index)
        end
    end
    self.clientNetworkTileNextTime = 0
    self.clientNetworkTileFastUntil = (g_currentMission ~= nil
        and g_currentMission.time or 0) + self.NETWORK_TILE_FAST_MODE_MS
end

function TerraLogicSoilManager:resetServerNetworkLayerRevision(layerIndex)
    if g_server == nil or self.layers[layerIndex] == nil then return end
    self.serverNetworkTileLayerGeneration =
        self.serverNetworkTileLayerGeneration or {}
    self.serverNetworkTileRevisions = self.serverNetworkTileRevisions or {}
    self.serverNetworkTileLayerGeneration[layerIndex] = 1
    self.serverNetworkTileRevisions[layerIndex] = {}
    if TerraLogicSoilTileRevisionResetEvent ~= nil then
        g_server:broadcastEvent(
            TerraLogicSoilTileRevisionResetEvent.new(layerIndex))
    end
    TerraLogicLogging.debug(
        "[FS25_TerraLogic] Soil tile revision generation safely reset for layer %d",
        layerIndex)
end

function TerraLogicSoilManager:invalidateServerNetworkLayer(layerId)
    if g_server == nil then return end
    local layerIndex = type(layerId) == "number"
        and layerId or getNetworkLayerIndex(layerId)
    if layerIndex == nil then return end
    self.serverNetworkTileLayerGeneration =
        self.serverNetworkTileLayerGeneration or {}
    self.serverNetworkTileRevisions = self.serverNetworkTileRevisions or {}
    local generation = tonumber(
        self.serverNetworkTileLayerGeneration[layerIndex]) or 1
    if generation >= self.NETWORK_TILE_GENERATION_MAX then
        self:resetServerNetworkLayerRevision(layerIndex)
    else
        self.serverNetworkTileLayerGeneration[layerIndex] = generation + 1
        self.serverNetworkTileRevisions[layerIndex] = {}
    end
end

function TerraLogicSoilManager:markServerNetworkTileCoordinateChanged(
        layerId, tileX, tileZ)
    if g_server == nil then return end
    local layerIndex = getNetworkLayerIndex(layerId)
    if layerIndex == nil then return end
    self.serverNetworkTileLayerGeneration =
        self.serverNetworkTileLayerGeneration or {}
    self.serverNetworkTileRevisions = self.serverNetworkTileRevisions or {}
    local revisions = self.serverNetworkTileRevisions[layerIndex]
    if revisions == nil then
        revisions = {}
        self.serverNetworkTileRevisions[layerIndex] = revisions
    end
    local coordinateKey = getNetworkTileCoordinateKey(tileX, tileZ)
    local revision = tonumber(revisions[coordinateKey]) or 1
    if revision >= self.NETWORK_TILE_REVISION_MAX then
        self:invalidateServerNetworkLayer(layerIndex)
        revisions = self.serverNetworkTileRevisions[layerIndex]
        revision = 1
    end
    revisions[coordinateKey] = revision + 1
    TerraLogicMapMaintenance:markChanged(tileX, tileZ)
end

function TerraLogicSoilManager:markServerNetworkTileChanged(layerId, ix, iz)
    local cellSize = getLayerCellSize(layerId)
    local tileSize = self.NETWORK_TILE_WORLD_SIZE_M
    self:markServerNetworkTileCoordinateChanged(layerId,
        math.floor(((tonumber(ix) or 0) + 0.5) * cellSize / tileSize),
        math.floor(((tonumber(iz) or 0) + 0.5) * cellSize / tileSize))
end

function TerraLogicSoilManager:markServerNetworkRegionChanged(
        layerId, minX, minZ, maxX, maxZ)
    if g_server == nil then return end
    local tileSize = self.NETWORK_TILE_WORLD_SIZE_M
    local firstX = math.floor(math.min(minX, maxX) / tileSize)
    local firstZ = math.floor(math.min(minZ, maxZ) / tileSize)
    local lastX = math.floor((math.max(minX, maxX) - 0.001) / tileSize)
    local lastZ = math.floor((math.max(minZ, maxZ) - 0.001) / tileSize)
    for tileZ=firstZ,lastZ do
        for tileX=firstX,lastX do
            self:markServerNetworkTileCoordinateChanged(
                layerId, tileX, tileZ)
        end
    end
end

function TerraLogicSoilManager:getServerNetworkTileRevision(
        layerIndex, tileX, tileZ)
    local generation = tonumber((self.serverNetworkTileLayerGeneration or {})[
        layerIndex]) or 1
    local revisions = (self.serverNetworkTileRevisions or {})[layerIndex]
    local revision = revisions ~= nil and tonumber(revisions[
        getNetworkTileCoordinateKey(tileX, tileZ)]) or 1
    return generation, revision
end

function TerraLogicSoilManager:buildNetworkSample(x, z)
    local values = {}
    for _, layer in ipairs(self.layers) do
        values[layer.id] = self:getValueAtWorldPosition(layer.id, x, z)
    end
    return values
end

function TerraLogicSoilManager:applyNetworkSample(x, z, values)
    if g_client == nil or g_server ~= nil or values == nil then return end
    self.clientNetworkSample = {
        x=tonumber(x) or 0, z=tonumber(z) or 0,
        values=values,
        time=g_currentMission ~= nil and g_currentMission.time or 0
    }
    self.networkStats.samplesReceived =
        (tonumber(self.networkStats.samplesReceived) or 0) + 1
end

-- Dedicated servers build requested tiles incrementally. Even if many clients
-- open the map simultaneously, only a fixed number of cheap BitVector reads is
-- performed in one frame; completed packets are sent afterwards.
function TerraLogicSoilManager:queueServerNetworkTile(
        connection, layerIndex, tileX, tileZ,
        knownGeneration, knownRevision)
    if g_server == nil or connection == nil then return false end
    self.serverNetworkTileJobs = self.serverNetworkTileJobs or {}
    if #self.serverNetworkTileJobs
        >= self.NETWORK_SERVER_TILE_MAX_PENDING_JOBS then return false end
    local layer = self.layers[tonumber(layerIndex) or 0]
    if layer == nil or self.rasterReady ~= true then return false end
    local tileSize = self.NETWORK_TILE_WORLD_SIZE_M
    local minimumX, minimumZ = tileX * tileSize, tileZ * tileSize
    local halfTerrain = (tonumber(self.terrainSize) or 2048) * 0.5
    if minimumX >= halfTerrain or minimumZ >= halfTerrain
        or minimumX + tileSize <= -halfTerrain
        or minimumZ + tileSize <= -halfTerrain then return false end
    self.serverNetworkTilePending = self.serverNetworkTilePending
        or setmetatable({}, {__mode="k"})
    local cellSize = getLayerCellSize(layer.id)
    local cellsPerSide = math.max(math.floor(tileSize / cellSize + 0.5), 1)
    local key = getNetworkTileKey(layerIndex, tileX, tileZ)
    local pending = self.serverNetworkTilePending[connection]
    if pending == nil then
        pending = {}
        self.serverNetworkTilePending[connection] = pending
    end
    if pending[key] == true then return false end
    local pendingCount = 0
    for _ in pairs(pending) do pendingCount = pendingCount + 1 end
    if pendingCount >= self.NETWORK_TILE_MAX_INFLIGHT_REQUESTS then
        return false
    end
    local generation, revision = self:getServerNetworkTileRevision(
        layerIndex, tileX, tileZ)
    if generation == (tonumber(knownGeneration) or 0)
        and revision == (tonumber(knownRevision) or 0) then
        if connection.sendEvent ~= nil
            and TerraLogicSoilTileSyncEvent ~= nil then
            connection:sendEvent(TerraLogicSoilTileSyncEvent.new(
                layerIndex, tileX, tileZ, generation, revision,
                false, 0, {}, {}))
            self.networkStats.tileAcksSent =
                (tonumber(self.networkStats.tileAcksSent) or 0) + 1
        end
        return true
    end
    pending[key] = true
    self.serverNetworkTileJobs[#self.serverNetworkTileJobs + 1] = {
        connection=connection, key=key, layerIndex=layerIndex,
        tileX=tileX, tileZ=tileZ, layerId=layer.id,
        generation=generation, revision=revision,
        cellsPerSide=cellsPerSide,
        startIx=math.floor(minimumX / cellSize),
        startIz=math.floor(minimumZ / cellSize),
        cellSize=cellSize, offset=1, values={}, masks={}
    }
    self.networkStats.tilesQueued =
        (tonumber(self.networkStats.tilesQueued) or 0) + 1
    self.networkStats.serverQueuePeak = math.max(
        tonumber(self.networkStats.serverQueuePeak) or 0,
        #self.serverNetworkTileJobs)
    return true
end

function TerraLogicSoilManager:processServerNetworkTileJobs()
    if g_server == nil or self.serverNetworkTileJobs == nil then return end
    local budget = self.NETWORK_SERVER_TILE_CELLS_PER_FRAME
    while budget > 0 and #self.serverNetworkTileJobs > 0 do
        local job = self.serverNetworkTileJobs[1]
        local cellOffset = job.offset - 1
        local localX = cellOffset % job.cellsPerSide
        local localZ = math.floor(cellOffset / job.cellsPerSide)
        local x = (job.startIx + localX + 0.5) * job.cellSize
        local z = (job.startIz + localZ + 0.5) * job.cellSize
        job.values[job.offset] = self:getRawAtWorldPosition(job.layerId, x, z)
        job.masks[job.offset] = self:getVisualizationRawAtWorldPosition(
            job.layerId, x, z)
        job.offset = job.offset + 1
        budget = budget - 1
        if job.offset > job.cellsPerSide*job.cellsPerSide then
            local generation, revision = self:getServerNetworkTileRevision(
                job.layerIndex, job.tileX, job.tileZ)
            local responseGeneration, responseRevision =
                job.generation, job.revision
            if generation ~= job.generation or revision ~= job.revision then
                -- A continuously worked centre tile can change every frame.
                -- Mark this bounded snapshot as stale instead of restarting it
                -- and starving every queued client behind it. Revision 0 never
                -- equals an authoritative tile and therefore guarantees a
                -- clean follow-up request.
                responseGeneration, responseRevision = 0, 0
            end
            table.remove(self.serverNetworkTileJobs, 1)
            local pending = self.serverNetworkTilePending[job.connection]
            if pending ~= nil then
                pending[job.key] = nil
                if next(pending) == nil then
                    self.serverNetworkTilePending[job.connection] = nil
                end
            end
            if job.connection.sendEvent ~= nil
                and TerraLogicSoilTileSyncEvent ~= nil then
                local event = TerraLogicSoilTileSyncEvent.new(
                    job.layerIndex, job.tileX, job.tileZ,
                    responseGeneration, responseRevision, true,
                    job.cellsPerSide, job.values, job.masks)
                local ok = pcall(job.connection.sendEvent,
                    job.connection, event)
                if ok then
                    self.networkStats.tilesSent =
                        (tonumber(self.networkStats.tilesSent) or 0) + 1
                end
                if not ok then
                    -- A player may disconnect while a multi-frame surface tile
                    -- is being assembled. Dropping that response is harmless.
                end
            end
        end
    end
end

function TerraLogicSoilManager:queueNetworkTile(
        layerIndex, tileX, tileZ, generation, revision,
        values, masks, cellsPerSide)
    if g_client == nil or g_server ~= nil or values == nil or masks == nil then return end
    local layer = self.layers[tonumber(layerIndex) or 0]
    cellsPerSide = math.floor(tonumber(cellsPerSide) or 0)
    if layer == nil or cellsPerSide < 1 or cellsPerSide > 32
        or #values ~= cellsPerSide*cellsPerSide
        or #masks ~= cellsPerSide*cellsPerSide then return end
    local key = getNetworkTileKey(layerIndex, tileX, tileZ)
    -- Keep the tile pending until its cells have actually been applied. This
    -- prevents a low-FPS client from requesting the same center tile again and
    -- repeatedly resetting its own partially completed job.
    self.clientNetworkTilePending[key] = g_currentMission ~= nil
        and g_currentMission.time or 0
    -- Replace an older queued copy of the same tile instead of growing the
    -- apply queue while the client has a temporary low frame rate.
    for index=#self.clientNetworkTileJobs,1,-1 do
        if self.clientNetworkTileJobs[index].key == key then
            table.remove(self.clientNetworkTileJobs, index)
        end
    end
    self.clientNetworkTileJobs[#self.clientNetworkTileJobs + 1] = {
        key=key, layerIndex=layerIndex, tileX=tileX, tileZ=tileZ,
        generation=generation, revision=revision,
        values=values, masks=masks, cellsPerSide=cellsPerSide, offset=1
    }
    self.networkStats.tilesReceived =
        (tonumber(self.networkStats.tilesReceived) or 0) + 1
end

function TerraLogicSoilManager:acknowledgeNetworkTile(
        layerIndex, tileX, tileZ, generation, revision)
    if g_client == nil or g_server ~= nil then return end
    local key = getNetworkTileKey(layerIndex, tileX, tileZ)
    local now = g_currentMission ~= nil and g_currentMission.time or 0
    self.clientNetworkTilePending[key] = nil
    self.clientNetworkTileFresh[key] = now
    self.clientNetworkTileKnownRevision[key] = {
        generation=tonumber(generation) or 0,
        revision=tonumber(revision) or 0
    }
    self.networkStats.tileAcksReceived =
        (tonumber(self.networkStats.tileAcksReceived) or 0) + 1
end

function TerraLogicSoilManager:processNetworkTileJobs()
    if g_client == nil or g_server ~= nil or self.rasterReady ~= true then return end
    local budget = self.NETWORK_TILE_APPLY_CELLS_PER_FRAME
    while budget > 0 and #self.clientNetworkTileJobs > 0 do
        local job = self.clientNetworkTileJobs[1]
        local layer = self.layers[job.layerIndex]
        if layer == nil then
            table.remove(self.clientNetworkTileJobs, 1)
        else
            local cellSize = getLayerCellSize(layer.id)
            local startIx = math.floor(
                job.tileX * self.NETWORK_TILE_WORLD_SIZE_M / cellSize)
            local startIz = math.floor(
                job.tileZ * self.NETWORK_TILE_WORLD_SIZE_M / cellSize)
            local cellOffset = job.offset - 1
            local localX = cellOffset % job.cellsPerSide
            local localZ = math.floor(cellOffset / job.cellsPerSide)
            if not self:writeNetworkRasterCell(
                    layer.id, startIx + localX, startIz + localZ,
                    job.values[job.offset]) then
                return
            end
            if not self:writeNetworkVisualizationCell(
                    layer.id, startIx + localX, startIz + localZ,
                    job.masks[job.offset]) then
                return
            end
            if self.layerCells[layer.id] ~= nil then
                self.layerCells[layer.id][getCellKey(
                    startIx + localX, startIz + localZ)] = nil
            end
            job.offset = job.offset + 1
            budget = budget - 1
            if job.offset > #job.values then
                table.remove(self.clientNetworkTileJobs, 1)
                local now = g_currentMission ~= nil
                    and g_currentMission.time or 0
                self.clientNetworkTilePending[job.key] = nil
                self.clientNetworkTileFresh[job.key] = now
                self.clientNetworkTileKnownRevision[job.key] = {
                    generation=tonumber(job.generation) or 0,
                    revision=tonumber(job.revision) or 0
                }
                self.networkStats.tilesApplied =
                    (tonumber(self.networkStats.tilesApplied) or 0) + 1
                self.layerWriteSerial[layer.id] =
                    (tonumber(self.layerWriteSerial[layer.id]) or 0) + 1
                if self.activeMapMode == job.layerIndex then
                    if self.visualizationDirty ~= true then
                        self.overlayRefreshTime = now
                            + self.NETWORK_OVERLAY_REFRESH_DELAY_MS
                    end
                    self.visualizationDirty = true
                end
            end
        end
    end
end

function TerraLogicSoilManager:updateClientNetworkSync()
    if g_client == nil or g_server ~= nil or g_currentMission == nil then return end
    local connection = g_client.getServerConnection ~= nil
        and g_client:getServerConnection() or nil
    local x, z = getLocalSoilNetworkPosition()
    if connection == nil or x == nil then return end
    local now = g_currentMission.time or 0

    if now >= (self.clientNetworkSampleNextTime or 0)
        and TerraLogicSoilSampleRequestEvent ~= nil then
        self.clientNetworkSampleNextTime = now
            + self.NETWORK_SAMPLE_INTERVAL_MS
        connection:sendEvent(TerraLogicSoilSampleRequestEvent.new(x, z))
    end

    local layerIndex = math.floor(tonumber(self.activeMapMode) or 0)
    if layerIndex < 1 or self.layers[layerIndex] == nil
        or now - (self.mapViewportLastDraw or -10000) > 1500
        or self.rasterReady ~= true
        or now < (self.clientNetworkTileNextTime or 0)
        or #self.clientNetworkTileJobs >= self.NETWORK_TILE_MAX_PENDING_JOBS
        or TerraLogicSoilTileRequestEvent == nil then return end
    local previousLayerIndex = self.clientNetworkTileLayer
    self.clientNetworkTileLayer = layerIndex

    -- Bound requests which are travelling, being assembled by the server or
    -- waiting in the local apply queue. Stale entries are purged globally so
    -- a rejected request from an old layer can never stall the active layer.
    local inflight = 0
    for key, pendingTime in pairs(self.clientNetworkTilePending) do
        if now - pendingTime >= self.NETWORK_TILE_REQUEST_TIMEOUT_MS then
            self.clientNetworkTilePending[key] = nil
        else
            inflight = inflight + 1
        end
    end
    if inflight >= self.NETWORK_TILE_MAX_INFLIGHT_REQUESTS then return end

    local tileSize = self.NETWORK_TILE_WORLD_SIZE_M
    local centerX, centerZ = math.floor(x / tileSize), math.floor(z / tileSize)
    local playerTileX, playerTileZ = centerX, centerZ
    if self.mapViewportFull == true then centerX, centerZ = 0, 0 end
    local maxRadius = math.ceil((tonumber(self.terrainSize) or 2048)
        / tileSize * 0.72) + 2
    local radius = math.clamp(math.floor(tonumber(
        self.clientNetworkTileViewportRadius) or self.NETWORK_TILE_RADIUS),
        self.NETWORK_TILE_RADIUS, maxRadius)
    local centerChanged = self.clientNetworkTileCenterX ~= centerX
        or self.clientNetworkTileCenterZ ~= centerZ
    local layerChanged = previousLayerIndex ~= layerIndex
    local signature = string.format("%d:%d:%d:%d",
        layerIndex, centerX, centerZ, radius)
    if self.clientNetworkTileViewportSignature ~= signature then
        self.clientNetworkTileCenterX = centerX
        self.clientNetworkTileCenterZ = centerZ
        self.clientNetworkTileViewportSignature = signature
        self.clientNetworkTileCursor = 0
        self.clientNetworkTileVisible = {}
        local halfTerrain = (tonumber(self.terrainSize) or 2048) * 0.5
        local minTile = math.floor(-halfTerrain/tileSize)
        local maxTile = math.ceil(halfTerrain/tileSize)-1
        for dz=math.max(-radius,minTile-centerZ),math.min(radius,maxTile-centerZ) do
            for dx=math.max(-radius,minTile-centerX),math.min(radius,maxTile-centerX) do
                -- The standalone minimap is circular. One half-tile margin
                -- avoids holes along its edge without filling an entire square
                -- that can never be seen.
                if dx*dx + dz*dz <= (radius + 0.75)^2 then
                    local tileX, tileZ = centerX + dx, centerZ + dz
                    local minimumX, minimumZ = tileX*tileSize, tileZ*tileSize
                    if minimumX < halfTerrain and minimumZ < halfTerrain
                        and minimumX + tileSize > -halfTerrain
                        and minimumZ + tileSize > -halfTerrain then
                        self.clientNetworkTileVisible[
                            #self.clientNetworkTileVisible + 1] = {
                                x=tileX, z=tileZ,
                                distanceSquared=(tileX-playerTileX)^2 + (tileZ-playerTileZ)^2
                            }
                    end
                end
            end
        end
        table.sort(self.clientNetworkTileVisible, function(a, b)
            if a.distanceSquared == b.distanceSquared then
                if a.z == b.z then return a.x < b.x end
                return a.z < b.z
            end
            return a.distanceSquared < b.distanceSquared
        end)
        if layerChanged then
            self.clientNetworkTileFastUntil = now
                + self.NETWORK_TILE_FAST_MODE_MS
        elseif centerChanged then
            self.clientNetworkTileFastUntil = math.max(
                tonumber(self.clientNetworkTileFastUntil) or 0,
                now + self.NETWORK_TILE_MOVE_FAST_MODE_MS)
        else
            -- A changed radius means that the player changed zoom or that the
            -- real viewport became available after the first rendered frame.
            self.clientNetworkTileFastUntil = now
                + self.NETWORK_TILE_FAST_MODE_MS
        end
    end
    local selectedX, selectedZ, selectedKey = nil, nil, nil
    local selectedWasUnseen = false
    local function tileIsDue(tileX, tileZ, refresh)
        local key = getNetworkTileKey(layerIndex, tileX, tileZ)
        local pendingTime = self.clientNetworkTilePending[key]
        if pendingTime ~= nil
            and now - pendingTime >= self.NETWORK_TILE_REQUEST_TIMEOUT_MS then
            self.clientNetworkTilePending[key] = nil
            pendingTime = nil
        end
        local freshness = self.clientNetworkTileFresh[key]
        if pendingTime == nil
            and (freshness == nil or now - freshness >= refresh) then
            return key
        end
        return nil
    end

    -- Keep the player's current tile responsive, but do not restart the
    -- neighbour search at radius zero after every response. The old nested
    -- radius scan repeatedly refreshed inner rings before it ever reached the
    -- outer visible fields.
    selectedKey = tileIsDue(playerTileX, playerTileZ,
        self.NETWORK_TILE_CENTER_REFRESH_MS)
    if selectedKey ~= nil then
        selectedX, selectedZ = playerTileX, playerTileZ
    else
        local visible = self.clientNetworkTileVisible or {}
        -- First fill never-seen visible tiles from the centre outwards. This
        -- makes a newly selected layer useful immediately at every zoom.
        for _, tile in ipairs(visible) do
            local key = getNetworkTileKey(layerIndex, tile.x, tile.z)
            if self.clientNetworkTileFresh[key] == nil
                and self.clientNetworkTilePending[key] == nil then
                selectedX, selectedZ, selectedKey = tile.x, tile.z, key
                selectedWasUnseen = true
                break
            end
        end
        -- Once the viewport is populated, refresh it fairly instead of always
        -- restarting at the inner ring. Unchanged revisions receive only the
        -- tiny acknowledgement packet from the server.
        if selectedKey == nil and #visible > 0 then
            local count = #visible
            local cursor = math.floor(tonumber(
                self.clientNetworkTileCursor) or 0) % count
            for _=1,count do
                local index = cursor + 1
                cursor = (cursor + 1) % count
                local tile = visible[index]
                if tile.x ~= playerTileX or tile.z ~= playerTileZ then
                    local key = tileIsDue(tile.x, tile.z,
                        self.NETWORK_TILE_REFRESH_MS)
                    if key ~= nil then
                        selectedX, selectedZ, selectedKey =
                            tile.x, tile.z, key
                        break
                    end
                end
            end
            self.clientNetworkTileCursor = cursor
        end
    end
    if selectedKey ~= nil then
        local fast = selectedWasUnseen
            or now < (tonumber(self.clientNetworkTileFastUntil) or 0)
        self.clientNetworkTileNextTime = now
            + (fast and self.NETWORK_TILE_FAST_REQUEST_INTERVAL_MS
                or self.NETWORK_TILE_REQUEST_INTERVAL_MS)
        self.clientNetworkTilePending[selectedKey] = now
        local known = self.clientNetworkTileKnownRevision[selectedKey] or {}
        connection:sendEvent(TerraLogicSoilTileRequestEvent.new(
            layerIndex, selectedX, selectedZ,
            known.generation, known.revision))
    end
end

function TerraLogicSoilManager:getNetworkDebugData()
    local stats = self.networkStats or {}
    return {
        role=g_server ~= nil and "server"
            or (g_client ~= nil and "remoteClient" or "offline"),
        samplesReceived=tonumber(stats.samplesReceived) or 0,
        tilesQueued=tonumber(stats.tilesQueued) or 0,
        tilesSent=tonumber(stats.tilesSent) or 0,
        tilesReceived=tonumber(stats.tilesReceived) or 0,
        tilesApplied=tonumber(stats.tilesApplied) or 0,
        tileAcksSent=tonumber(stats.tileAcksSent) or 0,
        tileAcksReceived=tonumber(stats.tileAcksReceived) or 0,
        viewportRadius=tonumber(self.clientNetworkTileViewportRadius)
            or self.NETWORK_TILE_RADIUS,
        visibleTiles=#(self.clientNetworkTileVisible or {}),
        serverQueue=#(self.serverNetworkTileJobs or {}),
        serverQueuePeak=tonumber(stats.serverQueuePeak) or 0,
        clientApplyQueue=#(self.clientNetworkTileJobs or {})
    }
end

function TerraLogicSoilManager:update(dt)
    local now = g_currentMission ~= nil and g_currentMission.time or 0
    if self.deepMapMigration ~= nil and self.rasterReady then
        self:updateDeepMapMigration()
    end
    self:updateRecoveryEnvironmentAccumulator()
    self:updateNaturalRecovery(dt)
    self:updateMapModeTransition(now)
    if not self.rasterReady and now >= (self.rasterInitRetryTime or 0) then
        self.rasterInitRetryTime = now + 250
        self:tryInitializeRaster()
    end
    self:updateNpcPresets(dt)
    self:updateVirtualImplementPass()
    self:updateNearbyCoverageReconcile(now)
    TerraLogicMapMaintenance:update()
    self:processServerNetworkTileJobs()
    self:processNetworkTileJobs()
    self:updateClientNetworkSync()
    if self.minimapHookInstalled ~= true then
        self:installMinimapHook()
    end
    if self.minimapHookMap ~= nil then
        -- loadMap may replace the base HUDElement after the main hook exists.
        self:installMinimapBaseLayerHook(self.minimapHookMap)
    end
    if self.pfMinimapHookInstalled ~= true then
        self:installPrecisionFarmingMinimapHook()
    end
    self:refreshPrecisionFarmingMinimapSuppression()
    if self.constructionCoverageHookInstalled ~= true then
        self:installConstructionCoverageHook()
    end

    if self.overlayPending == true and self.overlay ~= nil
        and getIsDensityMapVisualizationOverlayReady ~= nil
        and getIsDensityMapVisualizationOverlayReady(self.overlay) then
        self.overlayPending = false
        self.overlayReady = true
    end
    if self.activeMapMode > 0 and self.rasterReady
        and self.visualizationDirty == true
        and self.overlayPending ~= true
        and now >= (self.overlayRefreshTime or 0) then
        self:buildOverlay(self.activeMapMode)
    end
end

-- Applies an additional local zoom to the same extension transform used by
-- the base minimap. Restoring the prior transform at the start of the next
-- draw prevents multiplication from accumulating frame by frame. If the
-- engine has recalculated the map in between, that new transform becomes the
-- fresh base instead of being overwritten with stale coordinates.
function TerraLogicSoilManager:prepareMinimapZoom(ingameMap)
    if ingameMap == nil then return end
    local scale = tonumber(ingameMap.mapExtensionScaleFactor)
    local offsetX = tonumber(ingameMap.mapExtensionOffsetX)
    local offsetZ = tonumber(ingameMap.mapExtensionOffsetZ)
    if scale == nil or offsetX == nil or offsetZ == nil then return end

    local state = ingameMap.terraLogicSoilZoomState
    if state ~= nil and state.applied == true then
        local unchanged = math.abs(scale - state.appliedScale) < 0.000001
            and math.abs(offsetX - state.appliedOffsetX) < 0.000001
            and math.abs(offsetZ - state.appliedOffsetZ) < 0.000001
        if unchanged then
            scale, offsetX, offsetZ = state.baseScale,
                state.baseOffsetX, state.baseOffsetZ
            ingameMap.mapExtensionScaleFactor = scale
            ingameMap.mapExtensionOffsetX = offsetX
            ingameMap.mapExtensionOffsetZ = offsetZ
        end
        state.applied = false
    end

    local layout = ingameMap.layout
    if not isRoundMinimapLayout(layout) then
        local now = g_currentMission ~= nil and g_currentMission.time or 0
        self.minimapZoomFactor = 1
        self.minimapZoomFromFactor = 1
        self.minimapZoomTarget = 1
        self.minimapZoomStartTime = now
        self.minimapZoomEndTime = now
        return
    end
    -- Square minimaps already provide their own enlarged projection and
    -- clipping. Keep their native transform; the extra circle zoom would
    -- otherwise suppress or displace both the PDA texture and the soil map.
    local requestedTarget = self:getRequestedMinimapZoom()
    if math.abs(requestedTarget
            - (tonumber(self.minimapZoomTarget) or 1)) > 0.0001 then
        self:setMinimapZoomTarget(requestedTarget)
    end
    local requestedZoom = self:getAnimatedMinimapZoom()
    if math.abs(requestedZoom - 1) <= 0.0001 then return end

    if layout == nil or layout.getMapSize == nil
        or layout.getMapPivot == nil then return end
    local mapWidth, mapHeight = layout:getMapSize()
    local pivotX, pivotY = layout:getMapPivot()
    if mapWidth == nil or mapWidth <= 0 or mapHeight == nil or mapHeight <= 0
        or pivotX == nil or pivotY == nil then return end

    -- The soil raster uses the layout's texture pivot. This is the stable
    -- transform used through v44; hotspot positions are zoomed separately in
    -- screen space because FS25 applies another projection to that layer.
    local pivotRatioX = pivotX / mapWidth
    local pivotRatioZ = pivotY / mapHeight
    local appliedScale = scale * requestedZoom
    local appliedOffsetX = pivotRatioX
        + (offsetX - pivotRatioX) * requestedZoom
    local appliedOffsetZ = pivotRatioZ
        + (offsetZ - pivotRatioZ) * requestedZoom
    state = state or {}
    state.baseScale, state.baseOffsetX, state.baseOffsetZ =
        scale, offsetX, offsetZ
    state.appliedScale, state.appliedOffsetX, state.appliedOffsetZ =
        appliedScale, appliedOffsetX, appliedOffsetZ
    state.applied = true
    ingameMap.terraLogicSoilZoomState = state
    ingameMap.mapExtensionScaleFactor = appliedScale
    ingameMap.mapExtensionOffsetX = appliedOffsetX
    ingameMap.mapExtensionOffsetZ = appliedOffsetZ
end

function TerraLogicSoilManager:restoreMinimapZoom(ingameMap)
    local state = ingameMap ~= nil and ingameMap.terraLogicSoilZoomState or nil
    if state == nil or state.applied ~= true then return end
    ingameMap.mapExtensionScaleFactor = state.baseScale
    ingameMap.mapExtensionOffsetX = state.baseOffsetX
    ingameMap.mapExtensionOffsetZ = state.baseOffsetZ
    state.applied = false
end

-- Roads, buildings and terrain live in a separate PDA HUDElement. Do not
-- mutate its position or dimensions: the native layout updates those while
-- following the player and competing writes make the texture jump. Suppress
-- only its native minimap draw while a TL layer is active; drawMinimapOverlay
-- renders the same texture through the stable soil transform instead.
function TerraLogicSoilManager:drawZoomedMinimapBaseLayer(
        nativeDraw, ingameMap, element, ...)
    local layout = ingameMap ~= nil and ingameMap.layout or nil
    if self.activeMapMode > 0 and isRoundMinimapLayout(layout) then
        return
    end
    return nativeDraw(element, ...)
end

function TerraLogicSoilManager:drawMinimapBaseTexture(
        ingameMap, layout, renderX, renderY, renderW, renderH,
        rotationOffsetX, rotationOffsetY)
    local base = ingameMap ~= nil and ingameMap.mapOverlay or nil
    local overlayId = base ~= nil and base.overlayId or nil
    if overlayId == nil or overlayId == 0 then return false end
    local uvs = base.uvs or Overlay.DEFAULT_UVS
    local drawX, drawY, drawW, drawH = renderX, renderY, renderW, renderH
    local clipped = false
    if ingameMap.clipX1 ~= nil then
        local u1, v1, u2, v2, u3, v3, u4, v4
        drawX, drawY, drawW, drawH, u1, v1, u2, v2, u3, v3, u4, v4 =
            Overlay.getClippingUVs(
            uvs, renderX, renderY, renderW, renderH,
            ingameMap.clipX1, ingameMap.clipY1,
            ingameMap.clipX2, ingameMap.clipY2)
        if drawW == nil or drawW <= 0 or drawH == nil or drawH <= 0
            or u1 == nil then return false end
        setOverlayUVs(overlayId, u1, v1, u2, v2, u3, v3, u4, v4)
        clipped = true
    else
        setOverlayUVs(overlayId, unpack(uvs))
    end
    local originalRotation = tonumber(base.rotation) or 0
    local originalCenterX = tonumber(base.rotationCenterX) or 0
    local originalCenterY = tonumber(base.rotationCenterY) or 0
    local originalR, originalG = tonumber(base.r) or 1, tonumber(base.g) or 1
    local originalB, originalA = tonumber(base.b) or 1, tonumber(base.a) or 1
    -- Clipping moves the rendered rectangle. Keep the rotation pivot at the
    -- same absolute screen position instead of moving it with the clipped
    -- lower-left corner.
    local clippedRotationOffsetX = rotationOffsetX + renderX - drawX
    local clippedRotationOffsetY = rotationOffsetY + renderY - drawY
    setOverlayRotation(overlayId, layout:getMapRotation(),
        clippedRotationOffsetX, clippedRotationOffsetY)
    setOverlayColor(overlayId,
        originalR, originalG, originalB,
        originalA * math.sqrt(layout:getMapAlpha()))
    renderOverlay(overlayId, drawX, drawY, drawW, drawH)
    if clipped then setOverlayUVs(overlayId, unpack(uvs)) end
    setOverlayRotation(overlayId, originalRotation,
        originalCenterX, originalCenterY)
    setOverlayColor(overlayId,
        originalR, originalG, originalB, originalA)
    return true
end

function TerraLogicSoilManager:installMinimapBaseLayerHook(ingameMap)
    local element = ingameMap ~= nil and ingameMap.mapElement or nil
    if element == nil or element.draw == nil then return false end
    if self.minimapBaseHookElement == element then return true end
    local nativeDraw = element.draw
    element.draw = function(baseElement, ...)
        return TerraLogicSoilManager:drawZoomedMinimapBaseLayer(
            nativeDraw, ingameMap, baseElement, ...)
    end
    self.minimapBaseHookElement = element
    TerraLogicLogging.debug(
        "[FS25_TerraLogic] Minimap base texture joined to soil zoom")
    return true
end

function TerraLogicSoilManager:drawMinimapOverlay(ingameMap)
    self.minimapUiVisible = false
    if self.activeMapMode <= 0 then
        self:restoreMinimapZoom(ingameMap)
        return
    end
    local layout = ingameMap.layout
    if not isMinimapLayout(layout) or layout.getMapSize == nil then
        self:restoreMinimapZoom(ingameMap)
        return
    end
    -- Visibility is now controlled exclusively by ALT+T. The underlying
    -- minimap already follows the local player/vehicle, so no field probe or
    -- controlled-vehicle requirement is needed here.
    self.minimapUiVisible = true
    local canDrawOverlay = self.overlay ~= nil and self.overlayReady == true
    if TerraLogicLogging.verbose and canDrawOverlay
        and self.minimapDrawLoggedMode ~= self.activeMapMode then
        self.minimapDrawLoggedMode = self.activeMapMode
        TerraLogicLogging.debug(
            "[FS25_TerraLogic] Standalone soil minimap draw mode=%d overlay=%s",
            self.activeMapMode, tostring(self.overlay))
    end

    local mapWidth, mapHeight = layout:getMapSize()
    local mapX, mapY = layout:getMapPosition()
    local pivotX, pivotY = layout:getMapPivot()
    local renderX = mapX + mapWidth * ingameMap.mapExtensionOffsetX
    local renderY = mapY + mapHeight * ingameMap.mapExtensionOffsetZ
    local offsetX = pivotX + mapX - renderX
    local offsetY = pivotY + mapY - renderY
    local renderW = mapWidth * ingameMap.mapExtensionScaleFactor
    local renderH = mapHeight * ingameMap.mapExtensionScaleFactor
    -- One full terrain texture spans renderW/renderH. The clipped minimap
    -- diameter is mapWidth/mapHeight, so their ratio gives the actual visible
    -- world radius. Network requests can therefore follow zoom without relying
    -- on a second, error-prone map resolution.
    local extensionScale = math.max(math.abs(tonumber(
        ingameMap.mapExtensionScaleFactor) or 1), 0.0001)
    local visibleWorldRadius = (tonumber(self.terrainSize) or 2048)
        * 0.5 / extensionScale
    -- mapExtensionScaleFactor already includes TerraLogic zoom here.
    -- Square/full layouts need their corners too; do not clamp them to 512 m.
    self.mapViewportLastDraw = g_currentMission.time or 0
    self.mapViewportFull = IngameMapLayoutSquareLarge ~= nil
        and layout:isa(IngameMapLayoutSquareLarge)
    if self.mapViewportFull then
        visibleWorldRadius = (tonumber(self.terrainSize) or 2048)*0.72
    else
        if not isRoundMinimapLayout(layout) then
            visibleWorldRadius = visibleWorldRadius*math.sqrt(2)
        end
        self.coverageViewportRadius = visibleWorldRadius + self.NETWORK_TILE_WORLD_SIZE_M
    end
    self.clientNetworkTileViewportRadius = math.max(self.NETWORK_TILE_RADIUS,
        math.ceil(visibleWorldRadius / self.NETWORK_TILE_WORLD_SIZE_M) + 1)
    -- Only the circular layout needs its PDA texture redrawn. The PDA texture
    -- contains Vanilla's padded map border, whereas a density visualization is
    -- terrain-only and occupies mapExtensionScaleFactor/mapExtensionOffset.
    -- Reusing the smaller soil rectangle for the PDA texture double-applied
    -- that conversion and selected trees/roads from the wrong world position.
    -- Zoom the full native PDA rectangle around the exact same screen pivot;
    -- the soil rectangle below keeps its extension transform.
    if isRoundMinimapLayout(layout) then
        local zoom = tonumber(self.minimapZoomFactor) or 1
        local anchorX, anchorY = mapX + pivotX, mapY + pivotY
        local baseRenderX = anchorX + (mapX - anchorX) * zoom
        local baseRenderY = anchorY + (mapY - anchorY) * zoom
        local baseRenderW = mapWidth * zoom
        local baseRenderH = mapHeight * zoom
        self:drawMinimapBaseTexture(ingameMap, layout,
            baseRenderX, baseRenderY, baseRenderW, baseRenderH,
            anchorX - baseRenderX, anchorY - baseRenderY)
    end

    if canDrawOverlay then
        local drawX, drawY, drawW, drawH = renderX, renderY, renderW, renderH
        if ingameMap.clipX1 ~= nil then
            local u1, v1, u2, v2, u3, v3, u4, v4
            drawX, drawY, drawW, drawH, u1, v1, u2, v2, u3, v3, u4, v4 =
                Overlay.getClippingUVs(
                Overlay.DEFAULT_UVS, renderX, renderY, renderW, renderH,
                ingameMap.clipX1, ingameMap.clipY1,
                ingameMap.clipX2, ingameMap.clipY2)
            if drawW ~= nil and drawW > 0 and drawH ~= nil and drawH > 0
                    and u1 ~= nil then
                setOverlayUVs(self.overlay,
                    u1, v1, u2, v2, u3, v3, u4, v4)
            else
                canDrawOverlay = false
            end
        end
        if canDrawOverlay then
            local clippedOffsetX = offsetX + renderX - drawX
            local clippedOffsetY = offsetY + renderY - drawY
            setOverlayRotation(self.overlay,
                layout:getMapRotation(), clippedOffsetX, clippedOffsetY)
            setOverlayColor(self.overlay, 1, 1, 1,
                math.sqrt(layout:getMapAlpha()))
            renderOverlay(self.overlay, drawX, drawY, drawW, drawH)
            if ingameMap.clipX1 ~= nil then
                setOverlayUVs(self.overlay, unpack(Overlay.DEFAULT_UVS))
            end
        end
    end

    -- Native hotspots are drawn later and have their own screen-space zoom.
    -- Restore the map texture transform before FS25 projects those hotspots.
    self:restoreMinimapZoom(ingameMap)

end

-- Draw fixed TerraLogic UI only after the complete native minimap, including
-- its vehicle and helper icons, has finished using the temporary map zoom.
function TerraLogicSoilManager:drawMinimapUi(ingameMap)
    if self.activeMapMode <= 0 or self.minimapUiVisible ~= true then return end
    local layout = ingameMap ~= nil and ingameMap.layout or nil
    if not isMinimapLayout(layout) then return end
    local background = layout.background
    local frameLeft, frameRight, frameBottom, frameTop
    if background ~= nil then
        frameLeft, frameRight = background.x,
            background.x + background.width
        frameBottom, frameTop = background.y,
            background.y + background.height
    end
    if ingameMap.clipX1 ~= nil then
        frameLeft = frameLeft ~= nil
            and math.max(frameLeft, ingameMap.clipX1) or ingameMap.clipX1
        frameRight = frameRight ~= nil
            and math.min(frameRight, ingameMap.clipX2) or ingameMap.clipX2
        frameBottom = frameBottom ~= nil
            and math.max(frameBottom, ingameMap.clipY1) or ingameMap.clipY1
        frameTop = frameTop ~= nil
            and math.min(frameTop, ingameMap.clipY2) or ingameMap.clipY2
    end
    if g_i18n ~= nil and frameLeft ~= nil and frameRight > frameLeft
        and frameTop > frameBottom then
        local _, preferredTextSize = getNormalizedScreenValues(0, 10)
        local titlePadding = getNormalizedScreenValues(10, 0)
        local _, titleTopInset = getNormalizedScreenValues(0, 30)
        local title = getLocalizedCompactSoilMapLabel(self.activeMapMode)
        local textSize = fitTextSize(title, preferredTextSize,
            math.max(frameRight - frameLeft - titlePadding * 2, 0.001), 0.70)
        local titleX = (frameLeft + frameRight) * 0.5
        local titleY = frameTop - titleTopInset
        setTextAlignment(RenderText.ALIGN_CENTER)
        setTextBold(true)
        setTextColor(0,0,0,0.9)
        renderText(titleX + g_pixelSizeX, titleY - g_pixelSizeY,
            textSize, title)
        setTextColor(1,1,1,1)
        renderText(titleX, titleY,
            textSize, title)
        setTextBold(false)
        setTextAlignment(RenderText.ALIGN_LEFT)
    end

    -- Compact condition legend using the engine's shared one-pixel overlay,
    -- so TerraLogic needs no external UI texture.
    if GuiElement ~= nil and GuiElement.debugOverlay ~= nil
        and frameLeft ~= nil and frameRight > frameLeft
        and frameTop > frameBottom then
        local preferredLegendWidth, legendHeight =
            getNormalizedScreenValues(124, 4)
        local horizontalPadding = getNormalizedScreenValues(12, 0)
        local availableWidth = math.max(
            frameRight - frameLeft - horizontalPadding * 2, 0.001)
        -- Keep the scale inside the safe central chord of round minimaps.
        local legendWidth = math.min(preferredLegendWidth,
            availableWidth * 0.68)
        local _, preferredLegendTextSize = getNormalizedScreenValues(0, 10)
        local _, legendTextBottom = getNormalizedScreenValues(0, 38)
        local _, legendBarGap = getNormalizedScreenValues(0, 3)
        local legendX = (frameLeft + frameRight - legendWidth) * 0.5
        local legendTextY = frameBottom + legendTextBottom
        local legendY = legendTextY + preferredLegendTextSize + legendBarGap
        local activeLayer = self.layers[self.activeMapMode]
        local aggregateMode = activeLayer ~= nil
            and activeLayer.id == "aggregateSize"
        local leftLabel = aggregateMode
            and (g_i18n:getText("terraLogic_soilTilthScaleCoarse"))
            or (g_i18n:getText("terraLogic_soilScaleBad"))
        local centerLabel = aggregateMode
            and (g_i18n:getText("terraLogic_soilTilthScaleOptimal")) or nil
        local rightLabel = aggregateMode
            and (g_i18n:getText("terraLogic_soilTilthScaleFine"))
            or (g_i18n:getText("terraLogic_soilScaleGood"))
        local sideWidthShare = aggregateMode and 0.34 or 0.48
        local legendTextSize = math.min(
            fitTextSize(leftLabel, preferredLegendTextSize,
                legendWidth * sideWidthShare, 0.70),
            fitTextSize(rightLabel, preferredLegendTextSize,
                legendWidth * sideWidthShare, 0.70))
        if centerLabel ~= nil then
            legendTextSize = math.min(legendTextSize,
                fitTextSize(centerLabel, preferredLegendTextSize,
                    legendWidth * 0.28, 0.70))
        end
        -- Align the bar to the fitted label height as well.
        legendY = legendTextY + legendTextSize + legendBarGap
        local segments = 24
        local segmentWidth = legendWidth / segments
        for index=0,segments-1 do
            local t = index / (segments - 1)
            local layer = self.layers[self.activeMapMode]
            -- Normal layers are displayed as 0=bad, 1=good although their
            -- stored density value uses the inverse convention. Tilth keeps
            -- its directional raw scale from coarse to fine.
            local legendValue = layer ~= nil
                and (layer.id == "aggregateSize"
                    or layer.id == "resilience") and t or (1 - t)
            local r, g, b = self:getColor(
                layer ~= nil and layer.id or "surfaceCompaction", legendValue)
            setOverlayColor(GuiElement.debugOverlay, r, g, b, 0.95)
            renderOverlay(GuiElement.debugOverlay,
                legendX + segmentWidth * index, legendY,
                segmentWidth + g_pixelSizeX, legendHeight)
        end
        setOverlayColor(GuiElement.debugOverlay, 1, 1, 1, 1)
        setTextBold(false)
        setTextColor(0, 0, 0, 1)
        setTextAlignment(RenderText.ALIGN_LEFT)
        renderText(legendX + g_pixelSizeX,
            legendTextY - g_pixelSizeY, legendTextSize, leftLabel)
        if centerLabel ~= nil then
            setTextAlignment(RenderText.ALIGN_CENTER)
            renderText(legendX + legendWidth * 0.5 + g_pixelSizeX,
                legendTextY - g_pixelSizeY,
                legendTextSize, centerLabel)
        end
        setTextAlignment(RenderText.ALIGN_RIGHT)
        renderText(legendX + legendWidth + g_pixelSizeX,
            legendTextY - g_pixelSizeY, legendTextSize, rightLabel)
        setTextColor(1, 1, 1, 1)
        setTextAlignment(RenderText.ALIGN_LEFT)
        renderText(legendX, legendTextY,
            legendTextSize, leftLabel)
        if centerLabel ~= nil then
            setTextAlignment(RenderText.ALIGN_CENTER)
            renderText(legendX + legendWidth * 0.5,
                legendTextY, legendTextSize, centerLabel)
        end
        setTextAlignment(RenderText.ALIGN_RIGHT)
        renderText(legendX + legendWidth,
            legendTextY, legendTextSize, rightLabel)
        setTextAlignment(RenderText.ALIGN_LEFT)
    end
end

-- FS25 uses more than drawHotspot for minimap objects. In particular the
-- blinking destination marker is projected from a separate render path. Wrap
-- the layout projection for the complete minimap draw so every native icon
-- receives the same screen-space zoom. Only persistent navigation markers
-- may stay on the rim; ordinary objects must obey the zoomed visible area.
function TerraLogicSoilManager:prepareMinimapHotspotZoom(ingameMap)
    local requestedZoom = tonumber(self.minimapZoomFactor) or 1
    local layout = ingameMap ~= nil and ingameMap.layout or nil
    if math.abs(requestedZoom - 1) <= 0.0001
        or not isMinimapLayout(layout)
        or layout.getMapObjectPosition == nil
        or layout.getMapPosition == nil or layout.getMapPivot == nil
        or layout.getMapSize == nil then
        return false
    end
    if self.minimapHotspotZoomLayout == layout then return true end

    local mapX, mapY = layout:getMapPosition()
    local pivotX, pivotY = layout:getMapPivot()
    local mapWidth, mapHeight = layout:getMapSize()
    if mapX == nil or mapY == nil or pivotX == nil or pivotY == nil
        or mapWidth == nil or mapWidth <= 0
        or mapHeight == nil or mapHeight <= 0 then
        return false
    end
    local anchorX, anchorY = mapX + pivotX, mapY + pivotY
    -- getMapSize describes the projected map canvas, which can be larger than
    -- the visible round HUD. The background/clip rectangle is the authoritative
    -- rim for persistent targets.
    local clampCenterX, clampCenterY = anchorX, anchorY
    local clampWidth, clampHeight = mapWidth, mapHeight
    local background = layout.background
    if background ~= nil and tonumber(background.x) ~= nil
        and tonumber(background.y) ~= nil
        and tonumber(background.width) ~= nil
        and tonumber(background.height) ~= nil
        and background.width > 0 and background.height > 0 then
        clampCenterX = background.x + background.width * 0.5
        clampCenterY = background.y + background.height * 0.5
        clampWidth, clampHeight = background.width, background.height
    elseif ingameMap.clipX1 ~= nil and ingameMap.clipX2 ~= nil
        and ingameMap.clipY1 ~= nil and ingameMap.clipY2 ~= nil then
        clampWidth = ingameMap.clipX2 - ingameMap.clipX1
        clampHeight = ingameMap.clipY2 - ingameMap.clipY1
        clampCenterX = ingameMap.clipX1 + clampWidth * 0.5
        clampCenterY = ingameMap.clipY1 + clampHeight * 0.5
    end
    local nativeGetMapObjectPosition = layout.getMapObjectPosition
    local round = isRoundMinimapLayout(layout)
    local function boundaryDistance(dx, dy, radiusX, radiusY)
        local nx, ny = dx/radiusX, dy/radiusY
        return round and math.sqrt(nx*nx+ny*ny)
            or math.max(math.abs(nx), math.abs(ny))
    end
    layout.getMapObjectPosition = function(activeLayout,
        objectX, objectZ, width, height, rotation, persistent)
        local x, y, yRot, visible = nativeGetMapObjectPosition(activeLayout,
            objectX, objectZ, width, height, rotation, persistent)
        if x ~= nil and y ~= nil then
            local iconWidth, iconHeight = width or 0, height or 0
            local centerX = x + iconWidth * 0.5
            local centerY = y + iconHeight * 0.5
            local radiusX = math.max(
                clampWidth * 0.5-iconWidth * 0.5, 0.0001)
            local radiusY = math.max(
                clampHeight * 0.5-iconHeight * 0.5, 0.0001)
            local nativeDx = centerX-clampCenterX
            local nativeDy = centerY-clampCenterY
            local nativeRadial = boundaryDistance(
                nativeDx, nativeDy, radiusX, radiusY)
            -- Persistent navigation targets are already clamped by Vanilla.
            -- Keep a point sitting on that rim at its native position; scaling
            -- an already-clamped point is what sent the turquoise marker into
            -- the 3D view. In-range targets still follow the enlarged map.
            local alreadyClamped = persistent == true
                and nativeRadial >= 0.94
            if not alreadyClamped then
                centerX = anchorX + (centerX-anchorX) * requestedZoom
                centerY = anchorY + (centerY-anchorY) * requestedZoom
            end
            -- Native visibility was calculated for the unzoomed map. Recheck
            -- after zooming, without ever resurrecting a natively hidden icon.
            local dx, dy = centerX-clampCenterX, centerY-clampCenterY
            local radial = boundaryDistance(dx, dy, radiusX, radiusY)
            if radial > 1 then
                if persistent == true then
                    centerX = clampCenterX + dx/radial
                    centerY = clampCenterY + dy/radial
                else
                    visible = false
                end
            end
            x = centerX - iconWidth * 0.5
            y = centerY - iconHeight * 0.5
        end
        return x, y, yRot, visible
    end
    self.minimapHotspotZoomLayout = layout
    self.minimapHotspotNativeProjection = nativeGetMapObjectPosition
    return true
end

function TerraLogicSoilManager:restoreMinimapHotspotZoom()
    local layout = self.minimapHotspotZoomLayout
    local nativeProjection = self.minimapHotspotNativeProjection
    if layout ~= nil and nativeProjection ~= nil then
        layout.getMapObjectPosition = nativeProjection
    end
    self.minimapHotspotZoomLayout = nil
    self.minimapHotspotNativeProjection = nil
end

function TerraLogicSoilManager:drawZoomedMinimapHotspot(
    nativeDrawHotspot, ingameMap, hotspot, smallVersion, scale, doDebug)
    -- The normal map.draw wrapper covers every hotspot path. Retain this
    -- fallback for unusual custom minimaps that expose drawHotspot but no draw.
    local layout = ingameMap ~= nil and ingameMap.layout or nil
    if self.minimapHotspotZoomLayout == layout then
        return nativeDrawHotspot(ingameMap, hotspot,
            smallVersion, scale, doDebug)
    end
    self:prepareMinimapHotspotZoom(ingameMap)
    local results = {nativeDrawHotspot(ingameMap, hotspot,
        smallVersion, scale, doDebug)}
    self:restoreMinimapHotspotZoom()
    return unpack(results)
end

function TerraLogicSoilManager:installMinimapHook()
    local map = g_currentMission ~= nil and g_currentMission.hud ~= nil and g_currentMission.hud.ingameMap or nil
    if map == nil then return false end
    self:installMinimapBaseLayerHook(map)
    if self.minimapHookInstalled == true and self.minimapHookMap == map then
        self.minimapHookInstalled = true
        return true
    end
    if map.drawFields == nil then return false end
    -- Apply the texture zoom before the native minimap draw. drawFields adds
    -- the soil raster and restores that transform before native hotspots;
    -- those are zoomed independently in screen space below.
    if map.draw ~= nil then
        local nativeDraw = map.draw
        map.draw = function(ingameMap, ...)
            TerraLogicSoilManager:prepareMinimapZoom(ingameMap)
            TerraLogicSoilManager:prepareMinimapHotspotZoom(ingameMap)
            local results = {nativeDraw(ingameMap, ...)}
            TerraLogicSoilManager:restoreMinimapHotspotZoom()
            TerraLogicSoilManager:restoreMinimapZoom(ingameMap)
            TerraLogicSoilManager:drawMinimapUi(ingameMap)
            return unpack(results)
        end
        map.drawFields = Utils.appendedFunction(map.drawFields,
            function(ingameMap)
                TerraLogicSoilManager:drawMinimapOverlay(ingameMap)
            end)
    else
        -- Compatibility fallback for an unusual custom map implementation.
        map.drawFields = Utils.prependedFunction(
            map.drawFields, function(ingameMap)
                TerraLogicSoilManager:prepareMinimapZoom(ingameMap)
            end)
        map.drawFields = Utils.appendedFunction(map.drawFields,
            function(ingameMap)
                TerraLogicSoilManager:drawMinimapOverlay(ingameMap)
                TerraLogicSoilManager:restoreMinimapZoom(ingameMap)
                TerraLogicSoilManager:drawMinimapUi(ingameMap)
            end)
    end
    if map.drawHotspot ~= nil then
        local nativeDrawHotspot = map.drawHotspot
        map.drawHotspot = function(ingameMap, hotspot,
            smallVersion, scale, doDebug)
            return TerraLogicSoilManager:drawZoomedMinimapHotspot(
                nativeDrawHotspot, ingameMap, hotspot,
                smallVersion, scale, doDebug)
        end
    end
    self.minimapHookMethod = map.draw ~= nil
        and "draw-wrapper+drawFields-overlay+screen-hotspots"
        or "drawFields-fallback-overlay+screen-hotspots"
    map.terraLogicSoilHook = true
    self.minimapHookInstalled = true
    self.minimapHookMap = map
    TerraLogicLogging.debug("[FS25_TerraLogic] Soil minimap hook installed (%s)",
        tostring(self.minimapHookMethod))
    return true
end

-- Multiplayer soil synchronization -----------------------------------------
-- Gameplay writes stay server-only. Remote clients pull one compact point
-- sample for their HUD and small tiles only for the currently visible map.

local function getConnectionCanUseSoilDeveloperCommands(connection)
    if connection == nil or connection:getIsServer() then return false end
    if connection.getIsMasterUser ~= nil then
        local ok, result = pcall(
            connection.getIsMasterUser, connection)
        if ok then return result == true end
    end
    local userManager = g_currentMission ~= nil
        and g_currentMission.userManager or nil
    if userManager ~= nil and userManager.getIsUserIdMasterUser ~= nil
        and connection.getUserId ~= nil then
        local idOk, userId = pcall(connection.getUserId, connection)
        if idOk then
            local ok, result = pcall(
                userManager.getIsUserIdMasterUser, userManager, userId)
            if ok then return result == true end
        end
    end
    -- Some listen-server builds expose neither API on the connection object.
    -- Console access is already a developer feature; retain compatibility
    -- there while logging the otherwise unverifiable request.
    Logging.warning(
        "[FS25_TerraLogic] Could not verify multiplayer master-user status for a soil developer-command request")
    return true
end

TerraLogicVirtualImplementPassEvent = {}
local TerraLogicVirtualImplementPassEvent_mt = Class(
    TerraLogicVirtualImplementPassEvent, Event)
InitEventClass(TerraLogicVirtualImplementPassEvent,
    "TerraLogicVirtualImplementPassEvent")

function TerraLogicVirtualImplementPassEvent.emptyNew()
    return Event.new(TerraLogicVirtualImplementPassEvent_mt)
end

function TerraLogicVirtualImplementPassEvent.new(
        x, z, classKey, speedKph, shopSpeedKph)
    local self = TerraLogicVirtualImplementPassEvent.emptyNew()
    self.x, self.z = tonumber(x) or 0, tonumber(z) or 0
    self.classKey = tostring(classKey or "")
    self.speedKph = tonumber(speedKph) or 0
    self.shopSpeedKph = tonumber(shopSpeedKph) or 0
    return self
end

function TerraLogicVirtualImplementPassEvent:readStream(streamId, connection)
    self.x = streamReadFloat32(streamId)
    self.z = streamReadFloat32(streamId)
    self.classKey = streamReadString(streamId)
    self.speedKph = streamReadFloat32(streamId)
    self.shopSpeedKph = streamReadFloat32(streamId)
    self:run(connection)
end

function TerraLogicVirtualImplementPassEvent:writeStream(streamId, connection)
    streamWriteFloat32(streamId, self.x)
    streamWriteFloat32(streamId, self.z)
    streamWriteString(streamId, self.classKey)
    streamWriteFloat32(streamId, self.speedKph)
    streamWriteFloat32(streamId, self.shopSpeedKph)
end

function TerraLogicVirtualImplementPassEvent:run(connection)
    if g_server == nil
        or not getConnectionCanUseSoilDeveloperCommands(connection) then
        return
    end
    local ok, message = TerraLogicSoilManager:
        queueVirtualImplementPassAtWorldPosition(
            self.x, self.z, self.classKey,
            self.speedKph, self.shopSpeedKph)
    if not ok then
        Logging.warning(
            "[FS25_TerraLogic] Multiplayer virtual pass rejected: %s",
            tostring(message))
    end
end

TerraLogicTrafficTestPresetEvent = {}
local TerraLogicTrafficTestPresetEvent_mt = Class(
    TerraLogicTrafficTestPresetEvent, Event)
InitEventClass(TerraLogicTrafficTestPresetEvent,
    "TerraLogicTrafficTestPresetEvent")

function TerraLogicTrafficTestPresetEvent.emptyNew()
    return Event.new(TerraLogicTrafficTestPresetEvent_mt)
end

function TerraLogicTrafficTestPresetEvent.new(x, z, presetName)
    local self = TerraLogicTrafficTestPresetEvent.emptyNew()
    self.x, self.z = tonumber(x) or 0, tonumber(z) or 0
    self.presetName = tostring(presetName or "")
    return self
end

function TerraLogicTrafficTestPresetEvent:readStream(streamId, connection)
    self.x = streamReadFloat32(streamId)
    self.z = streamReadFloat32(streamId)
    self.presetName = streamReadString(streamId)
    self:run(connection)
end

function TerraLogicTrafficTestPresetEvent:writeStream(streamId, connection)
    streamWriteFloat32(streamId, self.x)
    streamWriteFloat32(streamId, self.z)
    streamWriteString(streamId, self.presetName)
end

function TerraLogicTrafficTestPresetEvent:run(connection)
    if g_server == nil
        or not getConnectionCanUseSoilDeveloperCommands(connection) then
        return
    end
    local ok, message = TerraLogicSoilManager:
        applyTrafficTestPresetAtWorldPosition(
            self.x, self.z, self.presetName)
    if not ok then
        Logging.warning(
            "[FS25_TerraLogic] Multiplayer traffic preset rejected: %s",
            tostring(message))
    end
end

TerraLogicOwnedFieldPresetRepairEvent = {}
local TerraLogicOwnedFieldPresetRepairEvent_mt = Class(
    TerraLogicOwnedFieldPresetRepairEvent, Event)
InitEventClass(TerraLogicOwnedFieldPresetRepairEvent,
    "TerraLogicOwnedFieldPresetRepairEvent")

function TerraLogicOwnedFieldPresetRepairEvent.emptyNew()
    return Event.new(TerraLogicOwnedFieldPresetRepairEvent_mt)
end

function TerraLogicOwnedFieldPresetRepairEvent.new(x, z)
    local self = TerraLogicOwnedFieldPresetRepairEvent.emptyNew()
    self.x, self.z = tonumber(x) or 0, tonumber(z) or 0
    return self
end

function TerraLogicOwnedFieldPresetRepairEvent:readStream(streamId, connection)
    self.x = streamReadFloat32(streamId)
    self.z = streamReadFloat32(streamId)
    self:run(connection)
end

function TerraLogicOwnedFieldPresetRepairEvent:writeStream(streamId, connection)
    streamWriteFloat32(streamId, self.x)
    streamWriteFloat32(streamId, self.z)
end

function TerraLogicOwnedFieldPresetRepairEvent:run(connection)
    if g_server == nil
        or not getConnectionCanUseSoilDeveloperCommands(connection) then return end
    TerraLogicSoilManager:queueOwnedFieldPresetRepairAtWorldPosition(
        self.x, self.z)
end

TerraLogicAllFieldPresetReinitializationEvent = {}
local TerraLogicAllFieldPresetReinitializationEvent_mt = Class(
    TerraLogicAllFieldPresetReinitializationEvent, Event)
InitEventClass(TerraLogicAllFieldPresetReinitializationEvent,
    "TerraLogicAllFieldPresetReinitializationEvent")

function TerraLogicAllFieldPresetReinitializationEvent.emptyNew()
    return Event.new(TerraLogicAllFieldPresetReinitializationEvent_mt)
end

function TerraLogicAllFieldPresetReinitializationEvent.new()
    return TerraLogicAllFieldPresetReinitializationEvent.emptyNew()
end

function TerraLogicAllFieldPresetReinitializationEvent:readStream(
        streamId, connection)
    self:run(connection)
end

function TerraLogicAllFieldPresetReinitializationEvent:writeStream(
        streamId, connection)
end

function TerraLogicAllFieldPresetReinitializationEvent:run(connection)
    if g_server == nil
        or not getConnectionCanUseSoilDeveloperCommands(connection) then return end
    TerraLogicSoilManager:requestAllFieldPresetReinitialization()
end

TerraLogicSoilSampleRequestEvent = {}
local TerraLogicSoilSampleRequestEvent_mt = Class(
    TerraLogicSoilSampleRequestEvent, Event)
InitEventClass(TerraLogicSoilSampleRequestEvent,
    "TerraLogicSoilSampleRequestEvent")

function TerraLogicSoilSampleRequestEvent.emptyNew()
    return Event.new(TerraLogicSoilSampleRequestEvent_mt)
end

function TerraLogicSoilSampleRequestEvent.new(x, z)
    local self = TerraLogicSoilSampleRequestEvent.emptyNew()
    self.x, self.z = tonumber(x) or 0, tonumber(z) or 0
    return self
end

function TerraLogicSoilSampleRequestEvent:readStream(streamId, connection)
    self.x = streamReadFloat32(streamId)
    self.z = streamReadFloat32(streamId)
    self:run(connection)
end

function TerraLogicSoilSampleRequestEvent:writeStream(streamId, connection)
    streamWriteFloat32(streamId, self.x)
    streamWriteFloat32(streamId, self.z)
end

function TerraLogicSoilSampleRequestEvent:run(connection)
    if connection:getIsServer() or g_server == nil then return end
    local manager = TerraLogicSoilManager
    manager.serverNetworkSampleCooldowns =
        manager.serverNetworkSampleCooldowns
        or setmetatable({}, {__mode="k"})
    local now = g_currentMission ~= nil and g_currentMission.time or 0
    local last = manager.serverNetworkSampleCooldowns[connection] or -100000
    if now - last < manager.NETWORK_SERVER_SAMPLE_COOLDOWN_MS then return end
    manager.serverNetworkSampleCooldowns[connection] = now
    local half = (tonumber(manager.terrainSize) or 2048) * 0.5
    local x = math.clamp(tonumber(self.x) or 0, -half, half)
    local z = math.clamp(tonumber(self.z) or 0, -half, half)
    connection:sendEvent(TerraLogicSoilSampleSyncEvent.new(
        x, z, manager:buildNetworkSample(x, z)))
end

TerraLogicSoilSampleSyncEvent = {}
local TerraLogicSoilSampleSyncEvent_mt = Class(
    TerraLogicSoilSampleSyncEvent, Event)
InitEventClass(TerraLogicSoilSampleSyncEvent,
    "TerraLogicSoilSampleSyncEvent")

function TerraLogicSoilSampleSyncEvent.emptyNew()
    return Event.new(TerraLogicSoilSampleSyncEvent_mt)
end

function TerraLogicSoilSampleSyncEvent.new(x, z, values)
    local self = TerraLogicSoilSampleSyncEvent.emptyNew()
    self.x, self.z, self.values = x, z, values or {}
    return self
end

function TerraLogicSoilSampleSyncEvent:readStream(streamId, connection)
    self.x = streamReadFloat32(streamId)
    self.z = streamReadFloat32(streamId)
    self.values = {}
    for _, layer in ipairs(TerraLogicSoilManager.layers) do
        self.values[layer.id] = streamReadFloat32(streamId)
    end
    self:run(connection)
end

function TerraLogicSoilSampleSyncEvent:writeStream(streamId, connection)
    streamWriteFloat32(streamId, self.x)
    streamWriteFloat32(streamId, self.z)
    for _, layer in ipairs(TerraLogicSoilManager.layers) do
        streamWriteFloat32(streamId,
            tonumber(self.values[layer.id])
                or TerraLogicSoilProfiles.DEFAULTS[layer.id])
    end
end

function TerraLogicSoilSampleSyncEvent:run(connection)
    if not connection:getIsServer() then return end
    TerraLogicSoilManager:applyNetworkSample(self.x, self.z, self.values)
end

TerraLogicSoilTileRequestEvent = {}
local TerraLogicSoilTileRequestEvent_mt = Class(
    TerraLogicSoilTileRequestEvent, Event)
InitEventClass(TerraLogicSoilTileRequestEvent,
    "TerraLogicSoilTileRequestEvent")

function TerraLogicSoilTileRequestEvent.emptyNew()
    return Event.new(TerraLogicSoilTileRequestEvent_mt)
end

function TerraLogicSoilTileRequestEvent.new(
        layerIndex, tileX, tileZ, knownGeneration, knownRevision)
    local self = TerraLogicSoilTileRequestEvent.emptyNew()
    self.layerIndex = math.clamp(math.floor(
        tonumber(layerIndex) or 1), 1, #TerraLogicSoilManager.layers)
    self.tileX = math.floor(tonumber(tileX) or 0)
    self.tileZ = math.floor(tonumber(tileZ) or 0)
    self.knownGeneration = math.clamp(math.floor(
        tonumber(knownGeneration) or 0), 0, 65535)
    self.knownRevision = math.clamp(math.floor(
        tonumber(knownRevision) or 0), 0, 65535)
    return self
end

function TerraLogicSoilTileRequestEvent:readStream(streamId, connection)
    self.layerIndex = streamReadUIntN(streamId, 3) + 1
    self.tileX = streamReadInt32(streamId)
    self.tileZ = streamReadInt32(streamId)
    self.knownGeneration = streamReadUIntN(streamId, 16)
    self.knownRevision = streamReadUIntN(streamId, 16)
    self:run(connection)
end

function TerraLogicSoilTileRequestEvent:writeStream(streamId, connection)
    streamWriteUIntN(streamId, self.layerIndex - 1, 3)
    streamWriteInt32(streamId, self.tileX)
    streamWriteInt32(streamId, self.tileZ)
    streamWriteUIntN(streamId, self.knownGeneration, 16)
    streamWriteUIntN(streamId, self.knownRevision, 16)
end

function TerraLogicSoilTileRequestEvent:run(connection)
    if connection:getIsServer() or g_server == nil then return end
    local manager = TerraLogicSoilManager
    if manager.layers[self.layerIndex] == nil then return end
    manager.serverNetworkTileCooldowns = manager.serverNetworkTileCooldowns
        or setmetatable({}, {__mode="k"})
    local now = g_currentMission ~= nil and g_currentMission.time or 0
    local last = manager.serverNetworkTileCooldowns[connection] or -100000
    if now - last < manager.NETWORK_SERVER_TILE_COOLDOWN_MS then return end
    manager.serverNetworkTileCooldowns[connection] = now
    manager:queueServerNetworkTile(
        connection, self.layerIndex, self.tileX, self.tileZ,
        self.knownGeneration, self.knownRevision)
end

TerraLogicSoilTileSyncEvent = {}
local TerraLogicSoilTileSyncEvent_mt = Class(
    TerraLogicSoilTileSyncEvent, Event)
InitEventClass(TerraLogicSoilTileSyncEvent,
    "TerraLogicSoilTileSyncEvent")

function TerraLogicSoilTileSyncEvent.emptyNew()
    return Event.new(TerraLogicSoilTileSyncEvent_mt)
end

function TerraLogicSoilTileSyncEvent.new(
        layerIndex, tileX, tileZ, generation, revision,
        hasPayload, cellsPerSide, values, masks)
    local self = TerraLogicSoilTileSyncEvent.emptyNew()
    self.layerIndex, self.tileX, self.tileZ = layerIndex, tileX, tileZ
    self.generation, self.revision = generation, revision
    self.hasPayload = hasPayload == true
    self.cellsPerSide, self.values = cellsPerSide, values or {}
    self.masks = masks or {}
    return self
end

function TerraLogicSoilTileSyncEvent:readStream(streamId, connection)
    self.layerIndex = streamReadUIntN(streamId, 3) + 1
    self.tileX = streamReadInt32(streamId)
    self.tileZ = streamReadInt32(streamId)
    self.generation = streamReadUIntN(streamId, 16)
    self.revision = streamReadUIntN(streamId, 16)
    self.hasPayload = streamReadBool(streamId)
    if not self.hasPayload then
        self.cellsPerSide, self.values, self.masks = 0, {}, {}
        self:run(connection)
        return
    end
    self.cellsPerSide = streamReadUIntN(streamId, 6)
    local count = streamReadUIntN(streamId, 11)
    local layer = TerraLogicSoilManager.layers[self.layerIndex]
    if layer == nil or count > 1024
        or count ~= self.cellsPerSide*self.cellsPerSide then
        -- A TerraLogic server always sends a valid fixed-size tile. Refuse a
        -- malformed payload before allocating an unbounded client table.
        self.values, self.masks = nil, nil
        return
    end
    local channels = getLayerChannels(layer.id)
    self.values, self.masks = {}, {}
    for index=1,count do
        self.values[index] = streamReadUIntN(streamId, channels)
        self.masks[index] = streamReadBool(streamId) and 1 or 0
    end
    self:run(connection)
end

function TerraLogicSoilTileSyncEvent:writeStream(streamId, connection)
    local layer = TerraLogicSoilManager.layers[self.layerIndex]
    local channels = layer ~= nil and getLayerChannels(layer.id) or 6
    local count = math.min(#self.values, 1024)
    streamWriteUIntN(streamId, self.layerIndex - 1, 3)
    streamWriteInt32(streamId, self.tileX)
    streamWriteInt32(streamId, self.tileZ)
    streamWriteUIntN(streamId, self.generation, 16)
    streamWriteUIntN(streamId, self.revision, 16)
    streamWriteBool(streamId, self.hasPayload)
    if not self.hasPayload then return end
    streamWriteUIntN(streamId, self.cellsPerSide, 6)
    streamWriteUIntN(streamId, count, 11)
    for index=1,count do
        streamWriteUIntN(streamId, self.values[index], channels)
        streamWriteBool(streamId, (tonumber(self.masks[index]) or 0) > 0)
    end
end

function TerraLogicSoilTileSyncEvent:run(connection)
    if not connection:getIsServer() then return end
    if not self.hasPayload then
        TerraLogicSoilManager:acknowledgeNetworkTile(
            self.layerIndex, self.tileX, self.tileZ,
            self.generation, self.revision)
        return
    end
    if self.values == nil or self.masks == nil then return end
    TerraLogicSoilManager:queueNetworkTile(
        self.layerIndex, self.tileX, self.tileZ,
        self.generation, self.revision,
        self.values, self.masks, self.cellsPerSide)
end

TerraLogicSoilTileRevisionResetEvent = {}
local TerraLogicSoilTileRevisionResetEvent_mt = Class(
    TerraLogicSoilTileRevisionResetEvent, Event)
InitEventClass(TerraLogicSoilTileRevisionResetEvent,
    "TerraLogicSoilTileRevisionResetEvent")

function TerraLogicSoilTileRevisionResetEvent.emptyNew()
    return Event.new(TerraLogicSoilTileRevisionResetEvent_mt)
end

function TerraLogicSoilTileRevisionResetEvent.new(layerIndex)
    local self = TerraLogicSoilTileRevisionResetEvent.emptyNew()
    self.layerIndex = math.clamp(math.floor(
        tonumber(layerIndex) or 1), 1, #TerraLogicSoilManager.layers)
    return self
end

function TerraLogicSoilTileRevisionResetEvent:readStream(streamId, connection)
    self.layerIndex = streamReadUIntN(streamId, 3) + 1
    self:run(connection)
end

function TerraLogicSoilTileRevisionResetEvent:writeStream(streamId, connection)
    streamWriteUIntN(streamId, self.layerIndex - 1, 3)
end

function TerraLogicSoilTileRevisionResetEvent:run(connection)
    if not connection:getIsServer() then return end
    TerraLogicSoilManager:clearClientNetworkLayerRevision(self.layerIndex)
end

TerraLogicCoverageReconcileEvent = {}
local TerraLogicCoverageReconcileEvent_mt = Class(
    TerraLogicCoverageReconcileEvent, Event)
InitEventClass(TerraLogicCoverageReconcileEvent,
    "TerraLogicCoverageReconcileEvent")

function TerraLogicCoverageReconcileEvent.emptyNew()
    return Event.new(TerraLogicCoverageReconcileEvent_mt)
end

function TerraLogicCoverageReconcileEvent.new(minX, minZ, maxX, maxZ, interest)
    local self = TerraLogicCoverageReconcileEvent.emptyNew()
    self.interest = interest == true
    self.minX, self.minZ = tonumber(minX) or 0, tonumber(minZ) or 0
    self.maxX, self.maxZ = tonumber(maxX) or self.minX,
        tonumber(maxZ) or self.minZ
    return self
end

function TerraLogicCoverageReconcileEvent:readStream(streamId, connection)
    self.minX, self.minZ = streamReadFloat32(streamId), streamReadFloat32(streamId)
    self.maxX, self.maxZ = streamReadFloat32(streamId), streamReadFloat32(streamId)
    self.interest = streamReadBool(streamId)
    self:run(connection)
end

function TerraLogicCoverageReconcileEvent:writeStream(streamId, connection)
    streamWriteFloat32(streamId, self.minX); streamWriteFloat32(streamId, self.minZ)
    streamWriteFloat32(streamId, self.maxX); streamWriteFloat32(streamId, self.maxZ)
    streamWriteBool(streamId, self.interest == true)
end

function TerraLogicCoverageReconcileEvent:run(connection)
    if connection:getIsServer() or g_server == nil then return end
    local manager = TerraLogicSoilManager
    manager.coverageReconcileCooldowns = manager.coverageReconcileCooldowns
        or setmetatable({}, {__mode="k"})
    local now = g_currentMission ~= nil and g_currentMission.time or 0
    local last = manager.coverageReconcileCooldowns[connection] or -100000
    if now-last < manager.COVERAGE_RECONCILE_SERVER_COOLDOWN_MS then return end
    manager.coverageReconcileCooldowns[connection] = now
    if self.interest then
        TerraLogicMapMaintenance:setInterest(connection,
            (self.minX+self.maxX)/2, (self.minZ+self.maxZ)/2,
            math.max(self.maxX-self.minX,self.maxZ-self.minZ)/2)
    else
        manager:queueCoverageRegion(self.minX, self.minZ, self.maxX, self.maxZ)
    end
end
