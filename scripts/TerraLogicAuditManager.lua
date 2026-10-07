-- TerraLogic structured diagnostic panels for the shared CSV recorder.

TerraLogicAuditManager = {
    SOURCE_FINGERPRINT = 1.200230,
    VIEWS = {
        audit_fieldwork=true, audit_traffic=true, audit_weather=true,
        audit_recovery=true, audit_yield=true, audit_damage=true
    },
    metadata = {},
    eventState = {},
    active = false
}

local CROP_ALIASES = {
    weizen="wheat", wheat="wheat", gerste="barley", barley="barley",
    hafer="oat", oat="oat", raps="canola", rapeseed="canola",
    canola="canola", mais="maize", corn="maize", maize="maize",
    soja="soybean", soybean="soybean", sonnenblume="sunflower",
    sunflower="sunflower", kartoffel="potato", potato="potato",
    zuckerruebe="sugarbeet", ["zuckerrübe"]="sugarbeet",
    sugarbeet="sugarbeet", gras="grass", grass="grass"
}

local function normalized(value)
    return string.lower(tostring(value or "")):gsub("[^%wäöüß]", "")
end

local function sanitize(value, maximum)
    local result = tostring(value or ""):gsub("[^%w_-]", "_")
    result = result:gsub("_+", "_"):gsub("^_+", ""):gsub("_+$", "")
    return string.sub(result, 1, maximum or 64)
end

local function number(value, fallback)
    value = tonumber(value)
    return value ~= nil and value or fallback
end

local function boolText(value)
    return value == true and "true" or "false"
end

local function fmt(value, decimals)
    value = tonumber(value)
    if value == nil or value ~= value then return "n/a" end
    return string.format("%." .. tostring(decimals or 3) .. "f", value)
end

local function fmtList(values, decimals)
    local result = {}
    for _, value in ipairs(values or {}) do
        result[#result + 1] = fmt(value, decimals)
    end
    return #result > 0 and table.concat(result, ",") or "n/a"
end

local function getPosition()
    local player = g_localPlayer
    if player ~= nil and player.getPositionData ~= nil then
        local x, _, z = player:getPositionData()
        if x ~= nil then return x, z end
    end
    local vehicle = player ~= nil and player.getCurrentVehicle ~= nil
        and player:getCurrentVehicle() or nil
    local node = vehicle ~= nil and (vehicle.rootNode
        or vehicle.components ~= nil and vehicle.components[1] ~= nil
            and vehicle.components[1].node) or player ~= nil and player.rootNode
    if node == nil then return nil, nil end
    local x, _, z = getWorldTranslation(node)
    return x, z
end

local function getControlledVehicle()
    if g_localPlayer ~= nil and g_localPlayer.getCurrentVehicle ~= nil then
        local vehicle = g_localPlayer:getCurrentVehicle()
        if vehicle ~= nil then return vehicle end
    end
    return g_currentMission ~= nil and g_currentMission.controlledVehicle or nil
end

local function objectName(object)
    if object == nil then return "none" end
    if object.getName ~= nil then
        local ok, value = pcall(object.getName, object)
        if ok and value ~= nil and value ~= "" then return tostring(value) end
    end
    return tostring(object.configFileName or object.typeName or "unknown")
end

local normalizeCrop

local function getFruitAt(x, z)
    if x == nil or TerraLogicQualityManager == nil then
        return {index=-1, name="none", growth=-1}
    end
    local size = tonumber(TerraLogicQualityManager.CELL_SIZE) or 4
    local index, growth = TerraLogicQualityManager:getGrowthStateAtCell(
        math.floor(x / size), math.floor(z / size))
    local desc = index ~= nil and g_fruitTypeManager ~= nil
        and g_fruitTypeManager:getFruitTypeByIndex(index) or nil
    return {index=number(index,-1), growth=number(growth,-1),
        name=tostring(desc ~= nil and (desc.name or desc.title) or "none")}
end

local function getFruitState(x, z)
    local localState = getFruitAt(x, z)
    local counts, names = {}, {}
    if x ~= nil then
        for row=-2,2 do
            for column=-2,2 do
                local state = getFruitAt(x+column*8,z+row*8)
                local key = normalizeCrop(state.name)
                if key ~= "" and key ~= "none" then
                    counts[key]=(counts[key] or 0)+1
                    names[key]=state.name
                end
            end
        end
    end
    local majorityKey, majorityCount, total = "none", 0, 0
    local mix = {}
    for key, count in pairs(counts) do
        total=total+count
        if count > majorityCount then majorityKey,majorityCount=key,count end
    end
    for key, count in pairs(counts) do
        mix[#mix+1]=string.format("%s:%d",names[key] or key,count)
    end
    table.sort(mix)
    localState.majorityName = names[majorityKey] or "none"
    localState.majorityCount = majorityCount
    localState.sampleCount = total
    localState.mix = table.concat(mix,",")
    return localState
end

normalizeCrop = function(value)
    local key = normalized(value)
    return CROP_ALIASES[key] or key
end

local function append(lines, key, value)
    lines[#lines + 1] = tostring(key) .. "=" .. tostring(value == nil and "" or value)
end

local function collectFill(object, result, visited)
    if object == nil or visited[object] then return end
    visited[object] = true
    local spec = object.spec_fillUnit
    for index, unit in ipairs(spec ~= nil and spec.fillUnits or {}) do
        local level = object.getFillUnitFillLevel ~= nil
            and object:getFillUnitFillLevel(index) or number(unit.fillLevel,0)
        local capacity = object.getFillUnitCapacity ~= nil
            and object:getFillUnitCapacity(index) or number(unit.capacity,0)
        result.level = result.level + math.max(number(level,0),0)
        result.capacity = result.capacity + math.max(number(capacity,0),0)
        result.units = result.units + 1
    end
    if object.getAttachedImplements ~= nil then
        for _, entry in ipairs(object:getAttachedImplements() or {}) do
            collectFill(entry.object, result, visited)
        end
    end
end

local function getFillSummary(vehicle)
    local result = {level=0, capacity=0, units=0}
    collectFill(vehicle, result, {})
    result.percent = result.capacity > 0 and result.level/result.capacity*100 or 0
    return result
end

local function collectConnectedObjects(object, result, visited)
    if object == nil or visited[object] then return end
    visited[object] = true
    result[#result + 1] = object
    if object.getAttachedImplements ~= nil then
        for _, entry in ipairs(object:getAttachedImplements() or {}) do
            collectConnectedObjects(entry.object, result, visited)
        end
    end
end

function TerraLogicAuditManager:isAuditView(view)
    return self.VIEWS[tostring(view or "")] == true
end

-- Initializes only the context needed by the retained structured panels. It
-- does not apply presets, change the savegame or start a second logger.
function TerraLogicAuditManager:beginPanelCapture(name, view)
    self.metadata = {
        testId=sanitize(name),
        soilTypeOverride=TerraLogicSoilManager ~= nil
            and TerraLogicSoilManager.auditSoilTypeOverrideName or "auto"
    }
    self.active = false
    self.activeView = view
    self.panelCache = nil
    self.startState = nil
    local x, z = getPosition()
    if x ~= nil and TerraLogicSoilManager ~= nil then
        self.startState = TerraLogicSoilManager:getStateAtWorldPosition(x, z)
    end
end

function TerraLogicAuditManager:endPanelCapture()
    self.active = false
    self.activeView = nil
    self.startState = nil
    self.panelCache = nil
    self.metadata = {soilTypeOverride="auto"}
end

function TerraLogicAuditManager:buildCommonLines(view)
    local x, z = getPosition()
    local fruit = getFruitState(x, z)
    local declared = self.metadata.crop or ""
    local detectedForMatch = fruit.majorityName ~= "none"
        and fruit.majorityName or fruit.name
    local cropMatch = declared == "" and "not_declared"
        or normalizeCrop(declared) == normalizeCrop(detectedForMatch)
            and "true" or "false"
    local lines = {"TerraLogic " .. string.upper(view)}
    append(lines,"audit_test_id",self.metadata.testId or "")
    append(lines,"audit_treatment",self.metadata.treatment or "")
    append(lines,"audit_operation",self.metadata.operation or "")
    append(lines,"audit_pass",self.metadata.pass or "")
    append(lines,"audit_year",self.metadata.year or "")
    append(lines,"audit_note",self.metadata.note or "")
    append(lines,"position_x",fmt(x,2)); append(lines,"position_z",fmt(z,2))
    append(lines,"declared_crop",declared)
    append(lines,"detected_crop_local",fruit.name)
    append(lines,"detected_crop_sampled_majority",fruit.majorityName)
    append(lines,"detected_crop_sample_count",fruit.sampleCount)
    append(lines,"detected_crop_sample_mix",fruit.mix)
    append(lines,"detected_crop_index",fruit.index)
    append(lines,"detected_growth_state",fruit.growth)
    append(lines,"crop_match",cropMatch)
    append(lines,"environment_override",self.metadata.environmentPreset
        or self.runtimeEnvironmentPreset or "natural")
    append(lines,"soil_preset",self.metadata.soilPreset
        or self.runtimeSoilPreset or "natural")
    append(lines,"soil_type_override",
        TerraLogicSoilManager ~= nil
            and TerraLogicSoilManager.auditSoilTypeOverrideName
            or self.metadata.soilTypeOverride or "auto")
    return lines, x, z, fruit
end

local function appendSoil(lines, x, z, prefix)
    if x == nil then return nil end
    local state = TerraLogicSoilManager:getStateAtWorldPosition(x,z)
    prefix = prefix or "soil"
    append(lines,prefix.."_surface_compaction_pct",fmt(state.surfaceCompaction*100,3))
    append(lines,prefix.."_deep_compaction_pct",fmt(state.deepCompaction*100,3))
    append(lines,prefix.."_tilth_raw_pct",fmt(state.aggregateSize*100,3))
    append(lines,prefix.."_evenness_pct",fmt((1-state.roughness)*100,3))
    append(lines,prefix.."_resilience_pct",fmt(state.resilience*100,3))
    local root, surfaceLoss, deepLoss = TerraLogicSoilManager:getRootYieldFactorFromState(state)
    append(lines,prefix.."_root_yield_factor",fmt(root,5))
    append(lines,prefix.."_surface_yield_loss_pct",fmt(surfaceLoss*100,4))
    append(lines,prefix.."_deep_yield_loss_pct",fmt(deepLoss*100,4))
    return state
end

local function appendEnvironment(lines, x, z)
    local temperature = TerraLogicSoilTemperatureManager:getState()
    local moisture = x ~= nil and TerraLogicSoilMoistureManager:getStateAtWorldPosition(x,z) or nil
    append(lines,"temperature_surface_c",fmt(temperature.surfaceTemperatureC,3))
    append(lines,"temperature_deep_c",fmt(temperature.subsoilTemperatureC,3))
    append(lines,"frozen_surface",boolText(temperature.surfaceFrozen))
    append(lines,"frozen_deep",boolText(temperature.subsoilFrozen))
    append(lines,"frozen_hours_surface",fmt(temperature.surfaceFrozenHours,2))
    append(lines,"frozen_hours_deep",fmt(temperature.subsoilFrozenHours,2))
    if moisture ~= nil then
        append(lines,"moisture_profile",moisture.profileName)
        append(lines,"moisture_surface_pct",fmt(moisture.surface*100,3))
        append(lines,"moisture_root_pct",fmt(moisture.subsoil*100,3))
        append(lines,"liquid_surface_pct",fmt(moisture.liquidSurface*100,3))
        append(lines,"liquid_root_pct",fmt(moisture.liquidSubsoil*100,3))
    end
end

function TerraLogicAuditManager:buildFieldworkLines(main)
    local lines, x, z = self:buildCommonLines("audit_fieldwork")
    local implement = main:getDebugImplement(true)
    append(lines,"implement_name",objectName(implement))
    if implement == nil or implement.getOverSpeedDebugData == nil then
        append(lines,"status","no_supported_implement")
        appendSoil(lines,x,z); appendEnvironment(lines,x,z)
        return lines
    end
    local data = implement:getOverSpeedDebugData()
    local spec = implement.spec_terraLogic or {}
    append(lines,"implement_class",data.implementClassKey or spec.implementClassKey or data.groundToolType)
    append(lines,"classification_source",data.classificationSource)
    append(lines,"nexat_module",boolText(data.isNexatModule))
    append(lines,"nexat_module_kind",data.nexatModuleKind)
    append(lines,"vredo_implement_kind",data.vredoImplementKind)
    append(lines,"work_active",boolText(data.telemetryWorking))
    append(lines,"working_width_m",fmt(data.workingWidth,3))
    append(lines,"work_depth_cm",fmt(data.workDepthCm,2))
    append(lines,"speed_kph",fmt(data.speed,3))
    append(lines,"recommended_speed_kph",fmt(data.optimalSpeed,3))
    append(lines,"shop_speed_kph",fmt(data.ratedSpeed,3))
    append(lines,"speed_ratio_shop",fmt(number(data.speed,0)/math.max(number(data.ratedSpeed,0.01),0.01),4))
    append(lines,"engagement_state",data.engagementState or "notApplicable")
    append(lines,"engagement_speed_ratio",fmt(data.engagementSpeedRatio,4))
    append(lines,"engagement_factor_pct",fmt(number(data.engagementFactor,1)*100,3))
    append(lines,"engagement_draft_retention_pct",
        fmt(number(data.engagementDraftRetention,1)*100,3))
    append(lines,"engagement_abrasion_contact_pct",
        fmt(number(data.engagementAbrasionContact,1)*100,3))
    append(lines,"damage_pct",fmt(data.damagePercent,3))
    append(lines,"draft_pf_texture",fmt(data.soilResistanceMultiplier,5))
    append(lines,"draft_persistent_soil",fmt(data.persistentSoilDraftMultiplier,5))
    append(lines,"draft_moisture",fmt(data.moistureAppliedDraftMultiplier,5))
    append(lines,"draft_frost",fmt(data.frostDraftMultiplier,5))
    append(lines,"draft_damage",fmt(data.damageResistanceMultiplier,5))
    append(lines,"draft_speed",fmt(data.speedDraftMultiplier,5))
    append(lines,"draft_final_force_kn",fmt(data.projectedMaxForce,4))
    append(lines,"draft_applied_force_kn",fmt(data.appliedDraftForceKn,4))
    append(lines,"draft_power_multiplier_vanilla",
        fmt(data.powerMultiplierVanilla,5))
    append(lines,"draft_power_multiplier_effective",
        fmt(data.powerMultiplierEffective,5))
    append(lines,"draft_power_multiplier_contact_reference",
        fmt(data.physicalContactPowerMultiplier,5))
    append(lines,"draft_contact_override",
        boolText(data.powerMultiplierContactOverride))
    append(lines,"draft_contact_surface",
        data.powerMultiplierSurface or "unknown")
    append(lines,"draft_environment_contact_reference",
        fmt(data.physicalFieldEnvironmentResistance,5))
    append(lines,"draft_environment_contact_held",
        boolText(data.physicalDraftContextHeld))
    append(lines,"draft_environment_contact_surface",
        data.physicalDraftContextSurface or "unknown")
    local width = math.max(number(data.workingWidth,0),0.01)
    append(lines,"draft_final_kn_per_m",fmt(number(data.projectedMaxForce,0)/width,4))
    append(lines,"draft_power_proxy_kw",fmt(number(data.projectedMaxForce,0)
        * number(data.speed,0)/3.6,3))
    local classKey = spec.implementClassKey
    local component = classKey == "plow" and "soilPlow"
        or (classKey == "sowingMachine" or classKey == "directDrill"
            or classKey == "precisionPlanter"
            or classKey == "precisionDirectDrill") and "seed"
        or classKey == "roller" and "roller"
        or classKey == "mulcher" and "mulch"
        or classKey == "mower" and "mower"
        or (classKey == "liquidSprayer" or classKey == "fertilizerSpreader"
            or classKey == "manureSpreader" or classKey == "slurrySpreader"
            or classKey == "slurryApplicator"
            or classKey == "slurryInjector") and
            (TerraLogic.getApplicationComponentForVehicle ~= nil
                and TerraLogic.getApplicationComponentForVehicle(implement)
                or spec.applicationQualityComponent or "fertilizer")
        or (classKey == "weeder" or classKey == "hoe") and "herbicide"
        or (classKey == "cultivator" or classKey == "shallowCultivator"
            or classKey == "discHarrow" or classKey == "powerHarrow"
            or classKey == "spader" or classKey == "subsoiler")
            and "soilCultivate" or nil
    append(lines,"quality_component",component or "physical_only")
    local overlapAudit = spec.soilOverlapAudit or {}
    append(lines,"overlap_audit_cumulative_physical_first_coverage_cells",
        fmt(number(overlapAudit.physicalFirstCoverage,0),5))
    append(lines,"overlap_audit_cumulative_tolerance_only_coverage_cells",
        fmt(number(overlapAudit.toleranceOnlyCoverage,0),5))
    append(lines,"overlap_audit_cumulative_first_coverage_cells",
        fmt(number(overlapAudit.firstCoverage,0),5))
    append(lines,"overlap_audit_cumulative_repeated_physical_coverage_cells",
        fmt(number(overlapAudit.repeatedPhysicalCoverage,0),5))
    append(lines,"overlap_audit_cumulative_applied_coverage_cells",
        fmt(number(overlapAudit.appliedCoverage,0),5))
    append(lines,"overlap_audit_cumulative_sampled_cells",
        number(overlapAudit.sampledCells,0))
    if classKey == "roller" then
        append(lines,"roller_physical_contact",
            boolText(spec.rollerPhysicalContact))
        append(lines,"roller_physical_fallback",
            boolText(spec.rollerPhysicalFallback))
        append(lines,"roller_physical_contact_cells",
            number(spec.rollerPhysicalContactCells,0))
        append(lines,"roller_vanilla_successful_area",
            fmt(spec.rollerSuccessfulArea,4))
        append(lines,"roller_physical_total_area",
            fmt(spec.rollerPhysicalTotalArea,4))
        append(lines,"roller_seed_rescue_cells",
            number(spec.rollerRescuedSeedCells,0))
    end
    if component ~= nil then
        local quality, penalty, model = TerraLogicQualityManager:getWorkQualityModel(
            implement, number(data.speed,0), component, nil)
        append(lines,"quality_speed_before_condition_pct",fmt(number(model.qualityBeforeCondition,1)*100,3))
        append(lines,"quality_condition_ceiling_pct",fmt(number(model.conditionQualityFactor,1)*100,3))
        append(lines,"quality_soil_factor_pct",fmt(number(model.soilQualityFactor,1)*100,3))
        append(lines,"quality_moisture_factor_pct",fmt(number(data.moistureQualityFactor,1)*100,3))
        append(lines,"quality_frost_factor_pct",fmt(number(data.frostQualityFactor,1)*100,3))
        append(lines,"quality_final_pct",fmt(quality*100,3))
        append(lines,"quality_yield_penalty_pct",fmt(penalty*100,4))
        local suitability = spec.soilSuitabilityContext or {}
        append(lines,"soil_safe_speed_kph",
            fmt(number(suitability.safeSpeedKph, data.ratedSpeed),3))
        append(lines,"soil_safe_speed_ratio",
            fmt(number(suitability.safeSpeedRatio,1),4))
        append(lines,"soil_contact_risk_pct",
            fmt(number(suitability.dropoutRisk,0)*100,3))
        append(lines,"soil_dropout_speed_activation_pct",
            fmt(number(suitability.suitabilitySpeedActivation,0)*100,3))
        append(lines,"soil_slow_quality_recovery_pct",
            fmt(number(suitability.suitabilitySlowRecovery,0)*100,3))
        -- soilDropoutFraction is already the combined ground-condition result.
        -- Keep the contributing weather terms separate so the audit never
        -- presents their influence twice as one forecast.
        append(lines,"expected_missed_area_pct",fmt(number(model.soilDropoutFraction,0)*100,4))
        append(lines,"missed_area_moisture_component_pct",
            fmt(number(data.moistureDropoutFraction,0)*100,4))
        append(lines,"missed_area_frost_component_pct",
            fmt(number(data.frostDropoutFraction,0)*100,4))
    end
    appendSoil(lines,x,z); appendEnvironment(lines,x,z)
    local pass = TerraLogicSoilManager.lastPass
    if pass ~= nil then
        append(lines,"last_pass_class",pass.classKey)
        append(lines,"last_pass_changed_cells",pass.changedCells)
        append(lines,"last_pass_changed_layers",pass.changedLayers)
        append(lines,"last_pass_touched_cells",pass.touchedCells or 0)
        append(lines,"last_pass_touched_coverage_cells",
            fmt(number(pass.touchedCoverage,0),4))
        append(lines,"last_pass_new_coverage_cells",
            fmt(number(pass.newlyAppliedCoverage,0),4))
        append(lines,"last_pass_physical_coverage_cells",
            fmt(number(pass.physicalCoverage,0),4))
        append(lines,"last_pass_tolerance_only_coverage_cells",
            fmt(number(pass.toleranceOnlyCoverage,0),4))
        append(lines,"last_pass_repeated_physical_coverage_cells",
            fmt(number(pass.repeatedPhysicalCoverage,0),4))
        append(lines,"last_pass_coverage_subdivisions",
            pass.coverageSubdivisions or 0)
        append(lines,"last_pass_sweep_active",
            pass.sweepActive == true and "yes" or "no")
        append(lines,"last_pass_sweep_age_ms",
            fmt(number(pass.sweepAgeMs,0),1))
        append(lines,"last_pass_sweep_distance_m",
            fmt(number(pass.sweepDistanceM,0),4))
        append(lines,"last_pass_speed_ratio",fmt(pass.speedRatio,4))
        append(lines,"last_pass_overspeed_severity",fmt(pass.overspeedSeverity,4))
        append(lines,"last_pass_engagement_state",pass.engagementState or "notApplicable")
        append(lines,"last_pass_engagement_pct",fmt(number(pass.engagement,1)*100,3))
        append(lines,"last_pass_soil_effect_pct",fmt(number(pass.moistureSoilEffectiveness,1)*100,3))
        append(lines,"last_pass_frost_penetration_pct",fmt(number(pass.frostPenetrationFactor,1)*100,3))
    end
    -- The vehicle position is normally ahead of a rear-mounted WorkArea.
    -- Record the most recent authoritative raster write as well, so a moving
    -- fieldwork capture exposes the actual cell delta instead of requiring
    -- the tester to drive back over and contaminate the worked strip.
    local write = TerraLogicSoilManager.lastWrite
    if write ~= nil then
        append(lines,"last_write_class",write.classKey)
        append(lines,"last_write_layer",write.layerId)
        append(lines,"last_write_cell_x",write.ix)
        append(lines,"last_write_cell_z",write.iz)
        append(lines,"last_write_before_pct",
            fmt(number(write.beforeValue,0)*100,4))
        append(lines,"last_write_after_pct",
            fmt(number(write.value,0)*100,4))
        append(lines,"last_write_delta_pp",
            fmt(number(write.delta,0)*100,5))
    end
    return lines
end

function TerraLogicAuditManager:buildTrafficLines()
    local lines, x, z = self:buildCommonLines("audit_traffic")
    local vehicle = getControlledVehicle()
    local connected = {}
    collectConnectedObjects(vehicle, connected, {})
    local diagnostic = nil
    for index, object in ipairs(connected) do
        local unitDiagnostic = TerraLogicWheelCompactionManager.diagnostics ~= nil
            and TerraLogicWheelCompactionManager.diagnostics[object] or nil
        append(lines,"connected_"..index.."_name",objectName(object))
        if TerraLogicWheelCompactionManager.getEligibilityAudit ~= nil then
            local ok, probe = pcall(TerraLogicWheelCompactionManager.getEligibilityAudit,
                TerraLogicWheelCompactionManager, object)
            if ok then
                for _, entry in ipairs(probe) do
                    lines[#lines + 1] = "connected_" .. index .. "_probe_" .. entry
                end
            else
                append(lines,"connected_"..index.."_probe_error",tostring(probe))
            end
        end
        if unitDiagnostic ~= nil then
            append(lines,"connected_"..index.."_mass_t",fmt(unitDiagnostic.vehicleMass,4))
            append(lines,"connected_"..index.."_supported_load_t",fmt(unitDiagnostic.totalLoad,4))
            append(lines,"connected_"..index.."_supported_load_pct",
                fmt(number(unitDiagnostic.supportedLoadRatio,0)*100,3))
            append(lines,"connected_"..index.."_wheel_contacts",unitDiagnostic.wheelCount)
            append(lines,"connected_"..index.."_peak_axle_t",fmt(unitDiagnostic.maxAxleLoad,4))
            append(lines,"connected_"..index.."_peak_pressure_kpa",fmt(unitDiagnostic.maxPressure,3))
            if diagnostic == nil or number(unitDiagnostic.time,0)
                    > number(diagnostic.time,0) then
                diagnostic = unitDiagnostic
            end
        else
            append(lines,"connected_"..index.."_diagnostic","not_sampled")
        end
    end
    append(lines,"connected_unit_count",#connected)
    local fill = getFillSummary(vehicle)
    append(lines,"vehicle_name",objectName(vehicle))
    append(lines,"fill_level_l",fmt(fill.level,2))
    append(lines,"fill_capacity_l",fmt(fill.capacity,2))
    append(lines,"fill_pct",fmt(fill.percent,3))
    append(lines,"fill_units",fill.units)
    appendSoil(lines,x,z); appendEnvironment(lines,x,z)
    if diagnostic == nil then append(lines,"status","no_wheel_sample"); return lines end
    local impact = diagnostic.lastImpact or {}
    append(lines,"sampled_wheel_entity_name",diagnostic.vehicleName or "unknown")
    append(lines,"wheel_sample_age_ms",fmt(math.max(number(
        g_currentMission ~= nil and g_currentMission.time,0)
        - number(diagnostic.time,0),0),0))
    append(lines,"speed_kph",fmt(diagnostic.speed,3))
    append(lines,"vehicle_mass_t",fmt(diagnostic.vehicleMass,4))
    append(lines,"supported_load_t",fmt(diagnostic.totalLoad,4))
    append(lines,"supported_load_pct",fmt(number(diagnostic.supportedLoadRatio,0)*100,3))
    append(lines,"wheel_contacts",diagnostic.wheelCount)
    append(lines,"field_contacts",diagnostic.fieldContactCount)
    append(lines,"effective_surface_footprints",
        diagnostic.effectiveFootprintCount or diagnostic.wheelCount)
    append(lines,"crawler_contacts",diagnostic.crawlerCount or 0)
    append(lines,"crawler_modules",diagnostic.crawlerModuleCount or 0)
    append(lines,"crawler_unmatched_contacts",
        diagnostic.unmatchedCrawlerCount or 0)
    append(lines,"crawler_module_loads_t",fmtList(
        diagnostic.crawlerModuleLoads,4))
    append(lines,"crawler_module_widths_m",fmtList(
        diagnostic.crawlerModuleWidths,4))
    append(lines,"crawler_module_contact_spacing_m",fmtList(
        diagnostic.crawlerModuleContactSpacings,4))
    append(lines,"crawler_module_contact_length_m",fmtList(
        diagnostic.crawlerModuleContactLengths,4))
    append(lines,"crawler_module_pressure_kpa",fmtList(
        diagnostic.crawlerModulePressures,3))
    append(lines,"crawler_module_local_x_m",fmtList(
        diagnostic.crawlerModuleLocalX,4))
    append(lines,"crawler_module_local_z_m",fmtList(
        diagnostic.crawlerModuleLocalZ,4))
    append(lines,"axle_count",diagnostic.axleCount)
    append(lines,"axle_loads_t",fmtList(diagnostic.axleLoads,4))
    append(lines,"axle_local_z_m",fmtList(
        diagnostic.axleLocalPositions,4))
    append(lines,"axle_position_spread_m",fmtList(
        diagnostic.axlePositionSpreads,5))
    append(lines,"wheel_load_mean_t",fmt(diagnostic.meanWheelLoad,4))
    append(lines,"wheel_load_max_t",fmt(diagnostic.maxWheelLoad,4))
    append(lines,"axle_load_mean_t",fmt(diagnostic.meanAxleLoad,4))
    append(lines,"axle_load_max_t",fmt(diagnostic.maxAxleLoad,4))
    append(lines,"tyre_width_mean_m",fmt(diagnostic.meanWidth,4))
    append(lines,"contact_length_mean_m",fmt(diagnostic.meanContactLength,4))
    append(lines,"pressure_mean_kpa",fmt(diagnostic.meanPressure,3))
    append(lines,"pressure_peak_kpa",fmt(diagnostic.maxPressure,3))
    append(lines,"slip_corrected_pct",fmt(number(diagnostic.maxSlip,0)*100,3))
    append(lines,"soil_type",impact.soilName or "unknown")
    append(lines,"traffic_surface_multiplier",fmt(impact.trafficSurfaceMultiplier,5))
    append(lines,"traffic_deep_multiplier",fmt(impact.trafficDeepMultiplier,5))
    append(lines,"resilience_multiplier",fmt(impact.resilienceTrafficMultiplier,5))
    append(lines,"surface_base_target_pct",fmt(number(
        impact.surfaceBaseTarget,number(impact.surfaceTarget,0))*100,4))
    append(lines,"surface_target_pct",fmt(number(impact.surfaceTarget,0)*100,4))
    append(lines,"deep_base_target_pct",fmt(number(
        impact.deepBaseTarget,number(impact.deepTarget,0))*100,4))
    append(lines,"deep_target_pct",fmt(number(impact.deepTarget,0)*100,4))
    append(lines,"surface_strength",fmt(impact.surfaceAppliedStrength,6))
    append(lines,"surface_coverage_pct",fmt(number(
        impact.surfaceCoverage,0)*100,4))
    append(lines,"deep_strength",fmt(impact.deepAppliedStrength,6))
    append(lines,"deep_coverage_pct",fmt(number(impact.deepCoverage,0)*100,4))
    for _, key in ipairs({"surfaceCompaction","deepCompaction","aggregateSize","roughness","resilience"}) do
        append(lines,"impact_before_"..key.."_pct",fmt(number(impact.before and impact.before[key],0)*100,4))
        append(lines,"impact_after_"..key.."_pct",fmt(number(impact.after and impact.after[key],0)*100,4))
        append(lines,"impact_delta_"..key.."_pp",fmt(number(impact.delta and impact.delta[key],0)*100,5))
    end
    local changedNow = diagnostic.changedByLayer or {}
    local changedTotal = diagnostic.totalChangedByLayer or {}
    local deltaNow = diagnostic.deltaByLayer or {}
    local deltaTotal = diagnostic.totalDeltaByLayer or {}
    local maximumNow = diagnostic.maximumDeltaByLayer or {}
    local maximumTotal = diagnostic.sessionMaximumDeltaByLayer or {}
    append(lines,"traffic_impact_cells_now",diagnostic.impactCount or 0)
    append(lines,"traffic_impact_cells_session",diagnostic.totalImpactCells or 0)
    append(lines,"traffic_changed_cells_now",diagnostic.changedCells or 0)
    append(lines,"traffic_changed_cells_session",diagnostic.totalChangedCells or 0)
    for _, key in ipairs({"surfaceCompaction","deepCompaction"}) do
        append(lines,"traffic_"..key.."_changed_cells_now",
            number(changedNow[key],0))
        append(lines,"traffic_"..key.."_changed_cells_session",
            number(changedTotal[key],0))
        append(lines,"traffic_"..key.."_delta_sum_now_pp",
            fmt(number(deltaNow[key],0)*100,5))
        append(lines,"traffic_"..key.."_delta_sum_session_pp",
            fmt(number(deltaTotal[key],0)*100,5))
        append(lines,"traffic_"..key.."_max_cell_delta_now_pp",
            fmt(number(maximumNow[key],0)*100,5))
        append(lines,"traffic_"..key.."_max_cell_delta_session_pp",
            fmt(number(maximumTotal[key],0)*100,5))
    end
    local missionTime = number(
        g_currentMission ~= nil and g_currentMission.time,0)
    local function appendRepresentative(prefix, cell, layerId)
        cell = cell or {}
        append(lines,prefix.."_age_ms",fmt(math.max(
            missionTime-number(cell.time,missionTime),0),0))
        append(lines,prefix.."_x",fmt(cell.x,3))
        append(lines,prefix.."_z",fmt(cell.z,3))
        append(lines,prefix.."_target_pct",fmt(number(
            cell[layerId == "surfaceCompaction"
                and "surfaceTarget" or "deepTarget"],0)*100,4))
        append(lines,prefix.."_strength",fmt(number(
            cell[layerId == "surfaceCompaction"
                and "surfaceAppliedStrength" or "deepAppliedStrength"],0),6))
        append(lines,prefix.."_before_pct",fmt(number(
            cell.before and cell.before[layerId],0)*100,4))
        append(lines,prefix.."_after_pct",fmt(number(
            cell.after and cell.after[layerId],0)*100,4))
        append(lines,prefix.."_delta_pp",fmt(number(
            cell.delta and cell.delta[layerId],0)*100,5))
    end
    appendRepresentative("surface_cell",
        diagnostic.representativeSurfaceImpact, "surfaceCompaction")
    appendRepresentative("deep_cell",
        diagnostic.representativeDeepImpact, "deepCompaction")
    return lines
end

function TerraLogicAuditManager:buildWeatherLines()
    local lines, x, z = self:buildCommonLines("audit_weather")
    appendEnvironment(lines,x,z)
    local moisture = TerraLogicSoilMoistureManager:getState()
    local temperature = TerraLogicSoilTemperatureManager:getState()
    append(lines,"weather_source",moisture.weatherSource)
    append(lines,"weather_valid",boolText(moisture.weatherDataValid))
    append(lines,"rain_scale",fmt(moisture.rainScale,5))
    append(lines,"ground_wetness",fmt(moisture.groundWetness,5))
    append(lines,"liquid_precipitation",fmt(moisture.liquidPrecipitationFactor,5))
    append(lines,"evaporation_factor",fmt(moisture.evaporationFactor,5))
    append(lines,"surface_weather_state",fmt(moisture.surfaceWetness,5))
    append(lines,"root_weather_state",fmt(moisture.rootMoisture,5))
    append(lines,"period_serial",moisture.periodSerial)
    append(lines,"period_observed_hours",fmt(moisture.periodObservedHours,3))
    append(lines,"period_liquid_rain_hours",fmt(moisture.periodLiquidRainHours,4))
    append(lines,"simulated_game_hours",fmt(moisture.simulatedGameHours,3))
    append(lines,"dropped_game_hours",fmt(moisture.droppedGameHours,3))
    append(lines,"air_temperature_c",fmt(temperature.airTemperatureC,3))
    append(lines,"daily_mean_temperature_c",fmt(temperature.dailyMeanTemperatureC,3))
    append(lines,"climate_mean_temperature_c",fmt(temperature.climateMeanTemperatureC,3))
    for index=0,4 do
        local profile = moisture.profiles[index]
        if profile ~= nil then
            append(lines,"profile_"..index.."_name",profile.name)
            append(lines,"profile_"..index.."_surface_pct",fmt(profile.surface*100,3))
            append(lines,"profile_"..index.."_root_pct",fmt(profile.subsoil*100,3))
        end
    end
    return lines
end

function TerraLogicAuditManager:buildRecoveryLines()
    local lines, x, z = self:buildCommonLines("audit_recovery")
    local current = appendSoil(lines,x,z)
    appendEnvironment(lines,x,z)
    if x == nil then return lines end
    local recovery = TerraLogicSoilManager:getNaturalRecoveryDebugAtWorldPosition(x,z)
    local rotation = TerraLogicSoilManager:getRotationDebugAtWorldPosition(x,z)
    append(lines,"cover_key",recovery.coverKey)
    append(lines,"cover_age_months",recovery.ageMonths)
    append(lines,"resilience_speed_internal",recovery.resilienceDevelopmentSpeed)
    append(lines,"physical_speed_internal",recovery.physicalDevelopmentSpeed)
    append(lines,"rest_factor",fmt(recovery.restFactor,5))
    append(lines,"rotation_last_group",rotation.lastGroupName)
    append(lines,"rotation_current_group",rotation.currentGroupName)
    append(lines,"rotation_phase",rotation.phaseName)
    append(lines,"rotation_diverse",boolText(rotation.diverse))
    append(lines,"recovery_completed_periods",recovery.completedPeriods)
    append(lines,"recovery_pending_periods",recovery.pendingPeriods)
    append(lines,"recovery_running",boolText(recovery.recoveryRunning))
    append(lines,"biology_factor",fmt(recovery.biologicalFactor,5))
    append(lines,"moisture_factor",fmt(recovery.moistureFactor,5))
    append(lines,"physical_surface_factor",fmt(recovery.physicalSurfaceFactor,5))
    append(lines,"physical_deep_factor",fmt(recovery.physicalDeepFactor,5))
    append(lines,"thaw_surface_factor",fmt(recovery.surfaceFrostFactor,5))
    append(lines,"thaw_deep_factor",fmt(recovery.deepFrostFactor,5))
    append(lines,"target_surface_pct",fmt(recovery.surfaceTarget*100,3))
    append(lines,"target_deep_pct",fmt(recovery.deepTarget*100,3))
    append(lines,"resilience_ceiling_pct",fmt(recovery.resilienceCeiling*100,3))
    local start = self.startState
    if start ~= nil and current ~= nil then
        append(lines,"audit_delta_surface_pp",fmt((current.surfaceCompaction-start.surfaceCompaction)*100,5))
        append(lines,"audit_delta_deep_pp",fmt((current.deepCompaction-start.deepCompaction)*100,5))
        append(lines,"audit_delta_tilth_pp",fmt((current.aggregateSize-start.aggregateSize)*100,5))
        append(lines,"audit_delta_evenness_pp",fmt(((1-current.roughness)-(1-start.roughness))*100,5))
        append(lines,"audit_delta_resilience_pp",fmt((current.resilience-start.resilience)*100,5))
    end
    return lines
end

function TerraLogicAuditManager:buildYieldLines()
    local lines, x, z = self:buildCommonLines("audit_yield")
    appendSoil(lines,x,z); appendEnvironment(lines,x,z)
    if x ~= nil then
        local ix = math.floor(x/(TerraLogicQualityManager.CELL_SIZE or 4))
        local iz = math.floor(z/(TerraLogicQualityManager.CELL_SIZE or 4))
        local moistureFactor, moistureSamples = TerraLogicQualityManager:
            getGrowthMoistureYieldFactor({ix=ix,iz=iz},false,true)
        local storedRootFactor, rootCompletedSteps = TerraLogicQualityManager:
            getGrowthRootYieldFactor({ix=ix,iz=iz},false,false)
        local cellSize = TerraLogicQualityManager.CELL_SIZE or 4
        local cellCenterX = (ix + 0.5) * cellSize
        local cellCenterZ = (iz + 0.5) * cellSize
        local integratedRootFactor, integratedSurfaceLoss,
            integratedDeepLoss = TerraLogicSoilManager:
                getRootYieldFactorForArea(cellCenterX,cellCenterZ,cellSize)
        local legacyRootFactor, legacySurfaceLoss, legacyDeepLoss =
            TerraLogicSoilManager:getRootYieldFactorForAreaLegacy(
                cellCenterX,cellCenterZ,cellSize)
        local fruitTypeIndex = TerraLogicQualityManager:getGrowthStateAtCell(
            ix, iz)
        local cropWeightedRootFactor, cropCoverage, cropWeightingValid,
            cropWeightedSurfaceLoss, cropWeightedDeepLoss,
            occupiedQuadrants = TerraLogicQualityManager:
                getCropWeightedRootYieldFactor(ix,iz,fruitTypeIndex)
        local rootFactor = TerraLogicQualityManager:
            getGrowthRootYieldFactor({ix=ix,iz=iz},false,true,
                cropWeightedRootFactor)
        local overall, entries = TerraLogicQualityManager:getSummaryAtWorldPosition(x,z)
        local resilience = TerraLogicSoilManager ~= nil
            and TerraLogicSoilManager:getValueAtWorldPosition(
                "resilience",x,z) or 0.50
        local finalFactor, finalDetail = TerraLogicQualityManager:
            getTerraLogicYieldFactor(entries or {},rootFactor or 1,
                moistureFactor or 1,
                TerraLogicSettings == nil
                    or TerraLogicSettings:getMoistureYieldEnabled(),
                1,resilience)
        append(lines,"stored_work_quality_mean_pct",fmt(number(overall,1)*100,3))
        append(lines,"stored_work_yield_factor",fmt(TerraLogicQualityManager:getEffectiveYieldFactor(entries or {},true),6))
        append(lines,"terralogic_final_yield_factor",fmt(finalFactor,6))
        append(lines,"terralogic_positive_potential_pct",fmt(number(finalDetail.positivePotential,0)*100,4))
        append(lines,"terralogic_soil_deduction_pp",fmt(number(finalDetail.soilDeduction,0)*100,4))
        append(lines,"terralogic_water_deduction_pp",fmt(number(finalDetail.waterDeduction,0)*100,4))
        append(lines,"terralogic_work_deduction_pp",fmt(number(finalDetail.workDeduction,0)*100,4))
        append(lines,"terralogic_resilience_penalty_pct",fmt(number(finalDetail.resiliencePenalty,0)*100,4))
        append(lines,"growth_root_yield_factor",fmt(rootFactor,6))
        append(lines,"growth_root_completed_steps",rootCompletedSteps or 0)
        append(lines,"growth_root_stored_factor",fmt(storedRootFactor,6))
        append(lines,"growth_root_projected_factor",fmt(rootFactor,6))
        append(lines,"root_crop_coverage_pct",fmt(
            number(cropCoverage,0)*100,4))
        append(lines,"root_crop_weighting_valid",
            cropWeightingValid == true and 1 or 0)
        append(lines,"root_crop_occupied_quadrants",occupiedQuadrants or 0)
        append(lines,"root_crop_weighted_factor",fmt(
            cropWeightedRootFactor,6))
        append(lines,"root_crop_weighted_surface_loss_pct",fmt(
            number(cropWeightedSurfaceLoss,0)*100,5))
        append(lines,"root_crop_weighted_deep_loss_pct",fmt(
            number(cropWeightedDeepLoss,0)*100,5))
        append(lines,"root_spatial_legacy_factor",fmt(legacyRootFactor,6))
        append(lines,"root_spatial_integrated_factor",fmt(integratedRootFactor,6))
        append(lines,"root_spatial_delta_pp",fmt(
            (integratedRootFactor-legacyRootFactor)*100,5))
        append(lines,"root_spatial_legacy_surface_loss_pct",fmt(
            number(legacySurfaceLoss,0)*100,5))
        append(lines,"root_spatial_integrated_surface_loss_pct",fmt(
            number(integratedSurfaceLoss,0)*100,5))
        append(lines,"root_spatial_legacy_deep_loss_pct",fmt(
            number(legacyDeepLoss,0)*100,5))
        append(lines,"root_spatial_integrated_deep_loss_pct",fmt(
            number(integratedDeepLoss,0)*100,5))
        append(lines,"growth_moisture_yield_factor",fmt(moistureFactor,6))
        append(lines,"growth_moisture_samples",moistureSamples)
        for _, entry in ipairs(entries or {}) do
            append(lines,"work_"..tostring(entry.name).."_quality_pct",fmt(number(entry.quality,1)*100,3))
            append(lines,"work_"..tostring(entry.name).."_yield_loss_pct",fmt(number(entry.yieldPenalty,0)*100,4))
        end
    end
    local harvest = TerraLogicQualityManager.lastHarvestDebug
    if harvest ~= nil then
        append(lines,"harvest_time",harvest.time)
        append(lines,"harvest_base_multiplier",fmt(harvest.baseMultiplier,6))
        append(lines,"harvest_final_multiplier",fmt(harvest.finalMultiplier,6))
        append(lines,"harvest_terralogic_factor",fmt(harvest.averageFactor,6))
        append(lines,"harvest_relative_change_pct",fmt(number(harvest.relativeChange,0)*100,4))
        append(lines,"harvest_relative_loss_pct",fmt(number(harvest.relativeLoss,0)*100,4))
        append(lines,"harvest_relative_gain_pct",fmt(number(harvest.relativeGain,0)*100,4))
        append(lines,"harvest_positive_potential_pct",fmt(number(harvest.averagePositivePotential,0)*100,4))
        append(lines,"harvest_resilience_penalty_pct",fmt(number(harvest.averageResiliencePenalty,0)*100,4))
        append(lines,"harvest_root_loss_pct",fmt(number(harvest.averageRootLoss,0)*100,4))
        append(lines,"harvest_moisture_loss_pct",fmt(number(harvest.averageMoistureLoss,0)*100,4))
        append(lines,"harvest_samples",harvest.samples)
        append(lines,"harvest_area",fmt(number(harvest.harvestedArea,0),6))
        append(lines,"harvest_spatial_captured_area",fmt(number(harvest.capturedArea,0),6))
        append(lines,"harvest_spatial_captured_multiplier_area",fmt(number(harvest.capturedMultiplierArea,0),6))
        append(lines,"harvest_spatial_weight_sum",fmt(number(harvest.weightSum,0),6))
        append(lines,"harvest_workareas_configured",harvest.configuredWorkAreas or 0)
        append(lines,"harvest_workareas_processed",harvest.processedWorkAreas or 0)
        append(lines,"harvest_workareas_with_crop",harvest.successfulWorkAreas or 0)
        append(lines,"harvest_spatial_touched_cells",harvest.touchedCells or 0)
        append(lines,"harvest_spatial_weighted_cells",harvest.weightedCells or 0)
        append(lines,"harvest_spatial_probe_samples",harvest.probeSamples or 0)
        append(lines,"harvest_spatial_crop_probe_samples",harvest.cropProbeSamples or 0)
        append(lines,"harvest_spatial_valid_fruit_samples",harvest.validFruitSamples or 0)
        append(lines,"harvest_spatial_no_fruit_samples",harvest.noFruitSamples or 0)
        append(lines,"harvest_spatial_disallowed_fruit_samples",harvest.disallowedFruitSamples or 0)
        append(lines,"harvest_spatial_missing_growth_samples",harvest.missingGrowthSamples or 0)
        append(lines,"harvest_spatial_unharvestable_samples",harvest.unharvestableSamples or 0)
        append(lines,"harvest_spatial_query_error_samples",harvest.queryErrorSamples or 0)
        append(lines,"harvest_spatial_legacy_factor",fmt(number(harvest.legacyAverageFactor,1),6))
        append(lines,"harvest_spatial_weighted_factor",fmt(number(harvest.averageFactor,1),6))
        append(lines,"harvest_spatial_delta_pp",fmt(number(harvest.spatialFactorDelta,0)*100,5))
        append(lines,"harvest_spatial_fallback",harvest.fallbackUsed == true and "yes" or "no")
        append(lines,"harvest_spatial_fallback_reason",harvest.fallbackReason or "none")
    end
    return lines
end

function TerraLogicAuditManager:buildDamageLines(main)
    local lines, x, z = self:buildCommonLines("audit_damage")
    local implement = main:getDebugImplement(true)
    append(lines,"implement_name",objectName(implement))
    if implement == nil or implement.getOverSpeedDebugData == nil then
        append(lines,"status","no_supported_implement"); return lines
    end
    local data = implement:getOverSpeedDebugData()
    local damage = data.damageAnalysis or {}
    append(lines,"speed_kph",fmt(data.speed,3))
    append(lines,"engagement_state",data.engagementState or "notApplicable")
    append(lines,"engagement_factor_pct",fmt(number(data.engagementFactor,1)*100,3))
    append(lines,"engagement_abrasion_contact_pct",
        fmt(number(data.engagementAbrasionContact,1)*100,3))
    append(lines,"damage_total_pct",fmt(number(data.damageAnalysisTotal,0)*100,5))
    for _, key in ipairs({"generalWear","soilAbrasion","overspeedWear",
            "structuralOverload",
            "undergroundSmall","undergroundMedium","undergroundBig",
            "mapSmall","mapMedium","mapBig"}) do
        append(lines,"damage_"..key.."_pct",fmt(number(damage[key],0)*100,6))
    end
    for _, entry in ipairs({
            {"undergroundSmall","impact_underground_small_count"},
            {"undergroundMedium","impact_underground_medium_count"},
            {"undergroundBig","impact_underground_big_count"},
            {"mapSmall","stone_map_small_contact_count"},
            {"mapMedium","stone_map_medium_contact_count"},
            {"mapBig","stone_map_big_contact_count"}}) do
        append(lines,entry[2],
            tostring(math.floor(number(damage[entry[1].."Count"],0))))
    end
    append(lines,"stone_map_result_small_count",
        tostring(math.floor(number(data.stoneVisibleResultSmallCount,0))))
    append(lines,"stone_map_result_medium_count",
        tostring(math.floor(number(data.stoneVisibleResultMediumCount,0))))
    append(lines,"stone_map_result_big_count",
        tostring(math.floor(number(data.stoneVisibleResultBigCount,0))))
    append(lines,"last_stone_event_source",data.lastStoneEventSource)
    append(lines,"last_stone_event_damage_pct",
        fmt(data.lastStoneEventDamagePercent,6))
    append(lines,"last_stone_event_age_s",
        fmt(data.lastStoneEventSecondsAgo,3))
    append(lines,"stone_warning_surface_min_damage_pct",
        fmt(data.stoneWarningSurfaceMinimumDamagePercent,3))
    append(lines,"stone_warning_underground_min_damage_pct",
        fmt(data.stoneWarningUndergroundMinimumDamagePercent,3))
    append(lines,"stone_impacts_enabled",
        tostring(data.stoneImpactsEnabled == true))
    append(lines,"damage_per_ha_pct",fmt(number(data.projectedDamagePerHectare,0)*100,5))
    append(lines,"force_source",data.mechanicalForceSource)
    append(lines,"load_model",data.mechanicalLoadModel)
    append(lines,"load_limit_source",data.mechanicalLoadSource)
    append(lines,"hud_severe_damage_rate_pct_per_min",
        fmt(data.structuralWarningSevereRatePercentPerMinute,3))
    append(lines,"friction_candidate_kn",fmt(data.frictionCandidateKn,4))
    append(lines,"base_max_force_kn",fmt(data.baseMaxForce,4))
    append(lines,"live_max_force_kn",fmt(data.modifiedMaxForce,4))
    append(lines,"applied_draft_force_kn",fmt(data.appliedDraftForceKn,4))
    append(lines,"smoothed_draft_force_kn",fmt(data.smoothedDraftForceKn,4))
    append(lines,"force_ratio",fmt(data.mechanicalForceRatio,6))
    append(lines,"speed_ratio",fmt(data.mechanicalSpeedRatio,6))
    append(lines,"drawbar_power_kw",fmt(data.drawbarPowerKw,4))
    append(lines,"reference_drawbar_power_kw",fmt(data.referenceDrawbarPowerKw,4))
    append(lines,"mechanical_load_ratio",fmt(data.mechanicalLoadRatio,6))
    append(lines,"warning_load_ratio",fmt(data.mechanicalWarningRatio,6))
    append(lines,"upper_load_ratio",fmt(data.mechanicalUpperRatio,6))
    append(lines,"overload_ratio",fmt(data.mechanicalOverloadRatio,6))
    append(lines,"load_wear_multiplier",fmt(data.loadWearMultiplier,6))
    append(lines,"load_wear_model","measured_force_and_throughput")
    append(lines,"structural_damage_pct_per_min",
        fmt(data.structuralDamagePercentPerMinute,6))
    append(lines,"structural_curve_quadratic",
        fmt(data.structuralDamageQuadratic,3))
    append(lines,"structural_curve_cubic",
        fmt(data.structuralDamageCubic,3))
    append(lines,"structural_damage_cap_pct_per_min",
        fmt(data.structuralDamageCapPercentPerMinute,3))
    append(lines,"structural_damage_total_pct",
        fmt(data.structuralDamageTotalPercent,6))
    append(lines,"stone_existing_coverage_pct",fmt(data.stoneEffectiveCoveragePercent,4))
    append(lines,"stone_generated_area_ha",fmt(data.stoneGeneratedWeightedHaLastSecond,6))
    appendSoil(lines,x,z); appendEnvironment(lines,x,z)
    return lines
end

function TerraLogicAuditManager:getPanelLines(view, main)
    local now = g_currentMission ~= nil and number(g_currentMission.time,0) or 0
    if self.panelCache ~= nil and self.panelCache.view == view
        and now < self.panelCache.nextRefresh then return self.panelCache.lines end
    local lines
    if view == "audit_fieldwork" then lines=self:buildFieldworkLines(main)
    elseif view == "audit_traffic" then lines=self:buildTrafficLines()
    elseif view == "audit_weather" then lines=self:buildWeatherLines()
    elseif view == "audit_recovery" then lines=self:buildRecoveryLines()
    elseif view == "audit_yield" then lines=self:buildYieldLines()
    elseif view == "audit_damage" then lines=self:buildDamageLines(main)
    else lines={"TerraLogic AUDIT","unknown audit view"} end
    self.panelCache={view=view,lines=lines,nextRefresh=now+1000}
    return lines
end

function TerraLogicAuditManager:update(dt, main)
    -- Panel data is sampled by TerraLogicMain's single one-second logger.
end

function TerraLogicAuditManager:load(main)
    self.main = main
    self.active = false
    self.activeView = nil
    self.metadata = {soilTypeOverride="auto"}
    self.eventState = {}
    self.startState = nil
    self.panelCache = nil
    TerraLogicSoilManager.auditSoilTypeOverride = nil
    for view in pairs(self.VIEWS) do main.DEBUG_VIEWS[view] = true end
    if main.auditHelpInstalled ~= true then
        for _, entry in ipairs({
            {name="audit_fieldwork",description="logging: complete field operation"},
            {name="audit_traffic",description="logging: vehicle load and soil traffic"},
            {name="audit_weather",description="logging: weather, moisture and temperature"},
            {name="audit_recovery",description="logging: roots, rotation and recovery"},
            {name="audit_yield",description="logging: predicted and applied yield"},
            {name="audit_damage",description="logging: wear, impacts and stones"}
        }) do main.DEBUG_VIEW_HELP[#main.DEBUG_VIEW_HELP+1]=entry end
        main.auditHelpInstalled=true
    end
    -- The structured audit panels remain available to the lightweight
    -- tlTestStart recorder. The former deterministic audit command suite was
    -- intentionally retired: it duplicated the ordinary panel logger and made
    -- spontaneous gameplay recordings unnecessarily difficult.
end

function TerraLogicAuditManager:delete(main)
    if TerraLogicSoilManager ~= nil then
        TerraLogicSoilManager.auditSoilTypeOverride = nil
    end
    self.active=false; self.main=nil
end
