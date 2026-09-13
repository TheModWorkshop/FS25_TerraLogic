-- Special crops reuse the existing soil, quality and network machinery.
-- Loaded after the profile tables, before the vehicle specialization.
TerraLogicSpecialImplements = {}
local S = TerraLogicSpecialImplements

local function copy(value)
    if type(value) ~= "table" then return value end
    local result = {}
    for k, v in pairs(value) do result[k] = copy(v) end
    return result
end

S.SEED_CLASSES = {potatoPlanter=true, vegetablePlanter=true, sugarcanePlanter=true}

function S.getSeedClass(vehicle, category)
    local spec = vehicle ~= nil and vehicle.spec_sowingMachine or nil
    if spec == nil then return nil end
    category = string.lower(tostring(category or ""))
    -- Do not infer new support from a filename, translated title or fill type.
    if category == "potatoplanting" then return "potatoPlanter" end
    if category == "sugarcaneplanters" then return "sugarcanePlanter" end
    if category == "vegetableplanters" or category == "onionplanters"
        or spec.ridgeSeeding == true then return "vegetablePlanter" end
    return nil
end

function S.getToolClass(vehicle)
    if vehicle == nil or vehicle.spec_motorized ~= nil
        or vehicle.spec_cutter ~= nil or vehicle.spec_combine ~= nil
        or vehicle.spec_treePlanter ~= nil then return nil end
    if vehicle.spec_sowingMachine == nil and vehicle.spec_ridgeFormer ~= nil
        and vehicle.processRidgeFormerArea ~= nil then return "ridgeFormer" end
    if vehicle.spec_sowingMachine == nil and vehicle.spec_fruitPreparer ~= nil
        and vehicle.processFruitPreparerArea ~= nil then
        for _, area in ipairs(vehicle.spec_workArea ~= nil
                and vehicle.spec_workArea.workAreas or {}) do
            -- A separate output rectangle cannot safely inherit a segmented
            -- input footprint. Such custom machines keep native behaviour.
            if area.functionName == "processFruitPreparerArea"
                and area.dropWorkAreaIndex ~= nil then return nil end
        end
        return "defoliator"
    end
    return nil
end

-- This is an exception to an existing turn-on guard, never an admission gate.
-- An absent/unknown needsActivation keeps legacy behaviour. A combined
-- sprayer is deliberately not enabled by this seed-function exception.
function S.isPassiveSeedFunction(vehicle)
    local tl = vehicle ~= nil and vehicle.spec_terraLogic or nil
    local spec = vehicle ~= nil and vehicle.spec_sowingMachine or nil
    local key = tl ~= nil and tl.implementClassKey or nil
    return key ~= nil and spec ~= nil and spec.needsActivation == false
        and (S.SEED_CLASSES[key] or key == "sowingMachine"
            or key == "directDrill" or key == "precisionPlanter"
            or key == "precisionDirectDrill") == true
end

function S.isRidgeGround(rawGround)
    if rawGround == nil or FieldGroundType == nil
        or FieldGroundType.getValueByType == nil then return false end
    return (FieldGroundType.RIDGE ~= nil
        and rawGround == FieldGroundType.getValueByType(FieldGroundType.RIDGE))
        or (FieldGroundType.RIDGE_SOWN ~= nil
        and rawGround == FieldGroundType.getValueByType(FieldGroundType.RIDGE_SOWN))
end

local I = TerraLogicImplementProfiles
local P = TerraLogicSoilProfiles
local M = TerraLogicSoilMoistureManager
local definitions = {
    potatoPlanter={base="sowingMachine", name="Potato planter", depth=15,
        abrasion=0.50, optimum=0.86, reference=10.32},
    vegetablePlanter={base="precisionPlanter", name="Vegetable planter", depth=5,
        abrasion=0.25, optimum=0.86, reference=8.60},
    sugarcanePlanter={base="sowingMachine", name="Sugarcane planter", depth=15,
        abrasion=0.45, optimum=0.86, reference=8.60},
    ridgeFormer={base="powerHarrow", name="Ridge former", depth=15,
        abrasion=0.65, optimum=0.80, reference=9.60},
    defoliator={base="mower", name="Defoliator", depth=0,
        abrasion=0, optimum=0.90, reference=9.00}
}
for key, d in pairs(definitions) do
    local profile = copy(I.PROFILES[d.base])
    profile.name = d.name
    profile.work.depthCm = d.depth
    profile.work.optimalSpeedFactor = d.optimum
    profile.work.optimalSpeedKph = nil
    profile.wear.abrasionFactor = d.abrasion
    I.PROFILES[key] = profile
    for _, tableName in ipairs({"REAL_SPEED_KPH", "ABRASION_FACTOR",
        "SOIL_DRAFT_RESPONSE", "WEAR_RESPONSE", "LOAD_RESPONSE", "YIELD_QUALITY",
        "DROPOUT_DEPENDENT_SPEED_CLASSES"}) do
        I[tableName][key] = copy(I[tableName][d.base])
    end
    I.ABRASION_FACTOR[key] = d.abrasion
    I.REAL_SPEED_KPH[key] = d.reference
    I.OPTIMAL_SPEED_FACTOR[key] = d.optimum
    M.IMPLEMENT_RESPONSE[key] = copy(M.IMPLEMENT_RESPONSE[d.base])
    M.FROST_RESPONSE[key] = copy(M.FROST_RESPONSE[d.base])
    P.SUITABILITY[key] = copy(P.SUITABILITY[d.base])
end

-- No agronomic quality ledger, seed rescue, soil penetration or underground
-- damage for tops cut above ground. Native harvesting owns the consequence.
I.PROFILES.defoliator.dropoutProfile = "defoliatorPatch"
I.PROFILES.defoliator.yield = {weight=0, maxPenalty=0}
I.PROFILES.defoliator.impacts = {underground=false, vanilla=false,
    workSpeed=false, rotation=true}
I.PROFILES.defoliator.stones = nil
I.YIELD_QUALITY.defoliator = {weight=0, maxPenalty=0}
P.SUITABILITY.defoliator = {qualityFloor=1, factors={}}
local D = TerraLogicDropoutManager
D.PROFILES.defoliatorPatch = copy(D.PROFILES.mowerPatch)
D.PROFILES.defoliatorPatch.patternSalt = 28511
D.PROFILES.defoliatorPatch.maximumFailureFraction = 0.50
D.PROFILES.defoliatorPatch.onsetFailureFractionPerKph = 0.014
-- Double the complete speed-only response, including its initial toe. The
-- existing 50% cap and separate condition penalty remain unchanged.
D.PROFILES.defoliatorPatch.failureFractionMultiplier = 2.0
-- Larger contiguous misses survive deep, overlapping work areas better.
-- Scale spacing with radius to retain the nominal area demand and the same
-- neighbour-search budget. Only the copied defoliator profile is changed.
D.PROFILES.defoliatorPatch.minimumIslandRadiusM = 1.275
D.PROFILES.defoliatorPatch.maximumIslandRadiusM = 2.25
D.PROFILES.defoliatorPatch.islandRadiusOffsetM = 0.375
D.PROFILES.defoliatorPatch.islandSpacingM = 5.025

-- Targets refer to full worked area; strengths include the average fraction
-- actually disturbed by opener rows. Wheel effects are never duplicated here.
P.PROFILES.potatoPlanter = {
    surfaceCompaction={target=0.32, strength=0.34, mode="reduceOnly"},
    aggregateSize={target=0.55, strength=0.25, mode="increaseOnly"},
    roughness={target=0.73, strength=0.88},
    overspeed={strengthScale={surfaceCompaction=0.55, aggregateSize=0.55, roughness=0.60},
        effects={roughness={target=0.94, strength=0.25, mode="increaseOnly"}}}
}
P.PROFILES.ridgeFormer = {
    surfaceCompaction={target=0.30, strength=0.46, mode="reduceOnly"},
    aggregateSize={target=0.62, strength=0.45, mode="increaseOnly"},
    roughness={target=0.74, strength=0.90},
    overspeed={strengthScale={surfaceCompaction=0.65, aggregateSize=0.45, roughness=0.60},
        effects={roughness={target=0.97, strength=0.30, mode="increaseOnly"}}}
}
P.PROFILES.vegetablePlanter = {
    surfaceCompaction={target=0.48, strength=0.10, mode="increaseOnly"},
    aggregateSize={target=0.50, strength=0.025, mode="increaseOnly"}
    -- No full-width roughness change: row units preserve existing ridges.
}
P.PROFILES.sugarcanePlanter = {
    surfaceCompaction={target=0.36, strength=0.18, mode="reduceOnly"},
    aggregateSize={target=0.55, strength=0.08, mode="increaseOnly"},
    roughness={target=0.18, strength=0.04, mode="reduceOnly"},
    overspeed={strengthScale={surfaceCompaction=0.60, aggregateSize=0.60, roughness=0.40},
        effects={roughness={target=0.50, strength=0.06, mode="increaseOnly"}}}
}
-- No PROFILES.defoliator: cutting tops does not write soil maps.

local potato = P.SUITABILITY.potatoPlanter
potato.factors.aggregateSize.goodRadius = 0.24
potato.factors.roughness = {shape="low", good=0.45, bad=1,
    qualityWeight=2, dropoutWeight=2}
potato.dropoutMax = 0.16
local cane = P.SUITABILITY.sugarcanePlanter
cane.factors.aggregateSize.goodRadius = 0.25
cane.factors.roughness = {shape="low", good=0.38, bad=0.95,
    qualityWeight=2, dropoutWeight=2}
cane.dropoutMax = 0.16
P.SUITABILITY.ridgeFormer = copy(P.SUITABILITY.powerHarrow)
S.RIDGE_ROUGHNESS = {shape="low", good=0.82, bad=1,
    qualityWeight=2, dropoutWeight=2}

-- Biology uses existing target/approach rules; no extra persistent map.
S.BIOLOGY = {
    potatoPlanter={resilience=-0.004, target=0.45, strength=0.55},
    ridgeFormer={resilience=-0.009, target=0.50, strength=0.85},
    vegetablePlanter={resilience=0, target=0.90, strength=0.50},
    sugarcanePlanter={resilience=-0.002, target=0.60, strength=0.45}
}

-- Only these classes qualify for ridge-aware pre-pass sampling. Use the raw
-- ground value from the field check already performed by the soil manager.
function S.getSuitabilityFactor(classKey, layer, factor, rawGround)
    if layer == "roughness" and (classKey == "potatoPlanter"
        or classKey == "vegetablePlanter") and S.isRidgeGround(rawGround) then
        return S.RIDGE_ROUGHNESS
    end
    return factor
end

function S.getWarning(classKey, cause)
    local group = ({potatoPlanter="Planting", sugarcanePlanter="Planting",
        vegetablePlanter="Vegetable", ridgeFormer="Ridge", defoliator="Tops"})[classKey]
    if group == nil then return nil end
    local suffix = ({overspeed="Speed", condition="Wear", uneven="Uneven",
        soil="Soil", wet="Wet", dry="Dry", frost="Frost"})[cause]
    if suffix == nil then return nil end
    local key = "terraLogic_special"..group..suffix
    if g_i18n ~= nil and g_i18n:hasText(key) then return g_i18n:getText(key) end
    return nil
end
