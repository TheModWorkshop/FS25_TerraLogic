--[[
    TerraLogicSoilMoistureManager.lua

    Global fallback stores per texture and position-aware public water API.
    Known fields use FieldWaterManager stores/history, including crop yields.
    Relative FS rain is mapped to calibrated, approximate mm/h, not measured
    precipitation. No terrain maps, local flow or groundwater are simulated.
]]

TerraLogicSoilMoistureManager = {
    SOURCE_FINGERPRINT = 1.200513,
    SAVE_FILE = "terraLogicSoilMoisture.xml",
    SAVE_VERSION = 7,

    SURFACE_DEPTH_CM = 15,
    SUBSOIL_DEPTH_CM = 60,
    MAX_GAME_HOURS_PER_UPDATE = 24,
    MAX_STEP_HOURS = 1 / 60,
    -- Calibrated gameplay input: FS exposes relative rain, not measured mm/h.
    RAIN_MM_PER_HOUR = 6,
    SNOW_MM_PER_HOUR = 2,
    MELT_MM_PER_DEGREE_DAY = 3,
    -- Compressed-calendar calibration against the recorded default weather:
    -- preserve storm input/drainage while allowing meaningful dry intervals.
    -- Root extraction remains a global vegetation proxy, not local crop use.
    EVAPORATION_MM_PER_HOUR = 0.275,
    ROOT_EXTRACTION_MM_PER_HOUR = 0.32,
    -- Water stores are mm over 150/450 mm of soil. Public moisture is m3/m3.
    -- Texture anchors use FAO-56 table 19; conductivity, pore volume and
    -- retention-curve interpolation are representative model assumptions.
    LEGACY_CAPACITIES = {[0]={66,198}, [1]={60,180}, [2]={63,189},
        [3]={69,207}, [4]={75,225}},
    V4_CAPACITIES = {[0]={24,100}, [1]={20,80}, [2]={22,90},
        [3]={26,110}, [4]={30,120}},
    V5_CAPACITIES = {[0]={24,70}, [1]={20,55}, [2]={22,65},
        [3]={26,80}, [4]={30,95}},
    V6_CAPACITIES = {[0]={24,49}, [1]={20,38.5}, [2]={22,45.5},
        [3]={26,56}, [4]={30,66.5}},
    LEGACY_ANCHORS = {
        [0]={.20,.55,.60,1,1}, [1]={.14,.44,.49,.82,.84},
        [2]={.18,.50,.55,1,1}, [3]={.24,.60,.63,1.08,1.10},
        [4]={.32,.68,.68,1.16,1.18}},
    HYDRAULICS = {
        [0]={saturation=.45, residual=.035, wilt=.11, fieldCapacity=.25, suctionFC=15, infiltration=18, transfer=5, drainHours=12, capillary=.040},
        [1]={saturation=.41, residual=.025, wilt=.06, fieldCapacity=.15, suctionFC=10, infiltration=35, transfer=10, drainHours=6, capillary=.008},
        [2]={saturation=.43, residual=.035, wilt=.11, fieldCapacity=.23, suctionFC=15, infiltration=25, transfer=6, drainHours=10, capillary=.030},
        [3]={saturation=.46, residual=.050, wilt=.12, fieldCapacity=.27, suctionFC=20, infiltration=15, transfer=4, drainHours=16, capillary=.045},
        [4]={saturation=.50, residual=.090, wilt=.23, fieldCapacity=.36, suctionFC=25, infiltration=7, transfer=2, drainHours=24, capillary=.025}
    },
    SYNC_INTERVAL_MS = 5000,
    SYNC_CHANGE_THRESHOLD = 0.002,
    SYNC_KEEPALIVE_MS = 60000,
    HISTORY_LENGTH = 48,
    MIN_PERIOD_OBSERVATION_SHARE = 0.50,
    MIN_VALID_WEATHER_SHARE = 0.80,

    -- Public physical anchors are derived from HYDRAULICS below.
    PROFILE_ORDER = {0, 1, 2, 3, 4},
    PROFILES = {
        [0] = {name="Generic", wetDraftTexture=1.00},
        [1] = {name="Loamy Sand", wetDraftTexture=0.82},
        [2] = {name="Sandy Loam", wetDraftTexture=1.00},
        [3] = {name="Loam", wetDraftTexture=1.14},
        [4] = {name="Silty Clay", wetDraftTexture=1.28}
    },

    -- Maximum response at the dry/wet endpoints. Values remain conservative:
    -- XML maxForce already describes ordinary soil and persistent TerraLogic
    -- state supplies compaction/tilth. Non-soil application tools are absent.
    IMPLEMENT_RESPONSE = {
        plow={dryDraft=0.12, wetDraft=0.15, dryQuality=0.08, wetQuality=0.14,
            dryEffect=0.12, wetEffect=0.18},
        subsoiler={dryDraft=0.18, wetDraft=0.12, dryQuality=0.10, wetQuality=0.12,
            dryEffect=0.18, wetEffect=0.15},
        cultivator={dryDraft=0.14, wetDraft=0.18, dryQuality=0.12, wetQuality=0.20,
            dryEffect=0.15, wetEffect=0.22},
        shallowCultivator={dryDraft=0.10, wetDraft=0.16, dryQuality=0.10, wetQuality=0.18,
            dryEffect=0.12, wetEffect=0.20},
        discHarrow={dryDraft=0.08, wetDraft=0.10, dryQuality=0.11, wetQuality=0.19,
            dryEffect=0.10, wetEffect=0.20},
        powerHarrow={dryDraft=0.10, wetDraft=0.14, dryQuality=0.12, wetQuality=0.22,
            dryEffect=0.12, wetEffect=0.25},
        spader={dryDraft=0.13, wetDraft=0.17, dryQuality=0.11, wetQuality=0.20,
            dryEffect=0.14, wetEffect=0.22},
        sowingMachine={dryDraft=0.04, wetDraft=0.06, dryQuality=0.14, wetQuality=0.22,
            dryEffect=0.08, wetEffect=0.15, dryDropout=0.08, wetDropout=0.13},
        directDrill={dryDraft=0.07, wetDraft=0.10, dryQuality=0.10, wetQuality=0.15,
            dryEffect=0.08, wetEffect=0.12, dryDropout=0.05, wetDropout=0.08},
        precisionPlanter={dryDraft=0.05, wetDraft=0.08, dryQuality=0.16, wetQuality=0.25,
            dryEffect=0.10, wetEffect=0.18, dryDropout=0.10, wetDropout=0.16},
        precisionDirectDrill={dryDraft=0.06, wetDraft=0.09,
            dryQuality=0.13, wetQuality=0.20,
            dryEffect=0.09, wetEffect=0.15,
            dryDropout=0.07, wetDropout=0.11},
        roller={dryDraft=0.01, wetDraft=0.04, dryQuality=0.07, wetQuality=0.20,
            dryEffect=0.05, wetEffect=0.25},
        stonePicker={dryDraft=0.05, wetDraft=0.08, dryQuality=0.05, wetQuality=0.10,
            dryEffect=0.10, wetEffect=0.18},
        weeder={dryDraft=0.03, wetDraft=0.05, dryQuality=0.08, wetQuality=0.12,
            dryEffect=0.12, wetEffect=0.20, dryDropout=0.04, wetDropout=0.06},
        hoe={dryDraft=0.04, wetDraft=0.07, dryQuality=0.09, wetQuality=0.14,
            dryEffect=0.14, wetEffect=0.23, dryDropout=0.05, wetDropout=0.08},
        -- Injection shoes and discs genuinely enter the soil; surface splash
        -- plates, tanks and ordinary sprayers remain intentionally absent.
        slurryApplicator={dryDraft=0.06, wetDraft=0.10,
            dryQuality=0.06, wetQuality=0.12,
            dryEffect=0.12, wetEffect=0.20,
            dryDropout=0.03, wetDropout=0.06},
        slurryInjector={dryDraft=0.06, wetDraft=0.10,
            dryQuality=0.06, wetQuality=0.12,
            dryEffect=0.12, wetEffect=0.20,
            dryDropout=0.03, wetDropout=0.06}
    },

    -- Frozen soil is a separate mechanical state, not another dry endpoint.
    -- Values are maximum changes at a fully developed, moist freeze through
    -- the implement's effective work depth. Real frozen soil can become
    -- practically untillable; these conservative bounds preserve gameplay
    -- while still making penetration failure the dominant consequence.
    FROST_RESPONSE = {
        plow={draft=0.45, qualityLoss=0.20, penetrationLoss=0.45},
        subsoiler={draft=0.38, qualityLoss=0.22, penetrationLoss=0.50},
        cultivator={draft=0.52, qualityLoss=0.27, penetrationLoss=0.55},
        shallowCultivator={draft=0.62, qualityLoss=0.30, penetrationLoss=0.62},
        discHarrow={draft=0.55, qualityLoss=0.30, penetrationLoss=0.56},
        powerHarrow={draft=0.48, qualityLoss=0.34, penetrationLoss=0.65},
        spader={draft=0.45, qualityLoss=0.26, penetrationLoss=0.50},
        sowingMachine={draft=0.28, qualityLoss=0.34,
            penetrationLoss=0.48, dropout=0.22},
        directDrill={draft=0.32, qualityLoss=0.25,
            penetrationLoss=0.35, dropout=0.14},
        precisionPlanter={draft=0.30, qualityLoss=0.40,
            penetrationLoss=0.52, dropout=0.28},
        precisionDirectDrill={draft=0.31, qualityLoss=0.32,
            penetrationLoss=0.43, dropout=0.20},
        roller={draft=0.04, qualityLoss=0.16, penetrationLoss=0.78},
        stonePicker={draft=0.16, qualityLoss=0.18, penetrationLoss=0.45},
        weeder={draft=0.20, qualityLoss=0.26,
            penetrationLoss=0.62, dropout=0.15},
        hoe={draft=0.26, qualityLoss=0.30,
            penetrationLoss=0.58, dropout=0.18},
        slurryApplicator={draft=0.28, qualityLoss=0.24,
            penetrationLoss=0.50, dropout=0.14},
        slurryInjector={draft=0.28, qualityLoss=0.24,
            penetrationLoss=0.50, dropout=0.14}
    }
}

local AUDIT_MOISTURE_PRESETS = {
    dry={surface=0.18, subsoil=0.32},
    normal={surface=0.52, subsoil=0.55},
    wet={surface=0.86, subsoil=0.78},
    frozen={surface=0.70, subsoil=0.66}
}

local function clamp01(value)
    return math.max(0, math.min(tonumber(value) or 0, 1))
end

local function smoothStep(edge0, edge1, value)
    if edge1 <= edge0 then return value >= edge1 and 1 or 0 end
    local t = clamp01(((tonumber(value) or 0) - edge0) / (edge1 - edge0))
    return t * t * (3 - 2 * t)
end

-- Existing soil ecology stores a dimensionless wetness index. Keep that
-- contract explicit; raw volume fractions must never reach its old thresholds.
function TerraLogicSoilMoistureManager:getResponseMoisture(value, soilTypeIndex)
    local h = self.HYDRAULICS[self:getProfileIndex(soilTypeIndex)]
    value = math.clamp(tonumber(value) or h.fieldCapacity, 0, h.saturation)
    if value <= h.wilt then return .20 * value / h.wilt end
    if value <= h.fieldCapacity then
        return .20 + .45 * (value-h.wilt)/(h.fieldCapacity-h.wilt)
    end
    return .65 + .35 * (value-h.fieldCapacity)/(h.saturation-h.fieldCapacity)
end

function TerraLogicSoilMoistureManager:legacyToVolume(value, index, deep)
    local h, a = self.HYDRAULICS[index], self.LEGACY_ANCHORS[index]
    local fc = deep and a[3] or a[2]
    value = clamp01(value)
    if value <= a[1] then return h.wilt * value / a[1] end
    if value <= fc then return h.wilt + (h.fieldCapacity-h.wilt)*(value-a[1])/(fc-a[1]) end
    return h.fieldCapacity + (h.saturation-h.fieldCapacity)*(value-fc)/(1-fc)
end

function TerraLogicSoilMoistureManager:getAvailableWater(value, soilTypeIndex)
    local h = self.HYDRAULICS[self:getProfileIndex(soilTypeIndex)]
    return clamp01((value-h.wilt)/(h.fieldCapacity-h.wilt))
end

function TerraLogicSoilMoistureManager:getMatricSuction(value, soilTypeIndex)
    local h = self.HYDRAULICS[self:getProfileIndex(soilTypeIndex)]
    value = math.clamp(value, h.residual+.0001, h.saturation)
    if value >= h.fieldCapacity then
        return h.suctionFC * ((h.saturation-value)/(h.saturation-h.fieldCapacity))^2
    end
    return math.min(h.suctionFC * (h.fieldCapacity/value)^h.retentionExponent, 100000)
end

-- Set the storage geometry and physical public anchors once at load time.
for index, h in pairs(TerraLogicSoilMoistureManager.HYDRAULICS) do
    h.upper = h.saturation * 150
    h.lower = h.saturation * 450
    h.retentionExponent = math.log(1500/h.suctionFC) / math.log(h.fieldCapacity/h.wilt)
    local p = TerraLogicSoilMoistureManager.PROFILES[index]
    p.initialSurface, p.initialSubsoil = h.fieldCapacity*.85, h.fieldCapacity*.95
    p.fieldCapacitySurface, p.fieldCapacitySubsoil = h.fieldCapacity, h.fieldCapacity
    p.wetOnset = h.fieldCapacity + .15*(h.saturation-h.fieldCapacity)
end

local FROST_TEXTURE_STRENGTH = {
    [0]=1.00, -- generic / no Precision Farming
    [1]=0.78, -- loamy sand: little ice cementation
    [2]=0.92, -- sandy loam
    [3]=1.06, -- loam
    [4]=1.14  -- silty clay: cohesive and water-retentive
}

local function getFrozenLayerSeverity(
        frozen, temperatureC, frozenHours, moisture, textureStrength,
        referenceHours)
    if frozen ~= true then return 0 end
    -- Most strength gain in warm frozen agricultural soil occurs during the
    -- first few degrees below zero. Hysteresis may retain the frozen state
    -- briefly during warming, so the small 0.10 floor represents residual ice
    -- without pretending that +0.5 C soil is still fully cemented.
    local coldProgress = math.clamp(
        (-0.25 - (tonumber(temperatureC) or 10)) / 3.75, 0, 1)
    local cold = coldProgress ^ 0.65
    local coldStrength = 0.10 + 0.90 * cold
    local maturity = 0.30 + 0.70 * smoothStep(
        0, math.max(tonumber(referenceHours) or 24, 1), frozenHours)
    -- A very dry mineral soil has little pore ice. It can still carry a weak
    -- frozen crust, while wetter and finer soil develops much stronger ice
    -- bonds. The profile factor is applied last and the result remains bounded.
    local iceAvailability = 0.14 + 0.86 * smoothStep(0.12, 0.72, moisture)
    return math.clamp(coldStrength * maturity * iceAvailability
        * math.max(tonumber(textureStrength) or 1, 0), 0, 1)
end

local function getFrostDepthWeights(workDepthCm)
    local depth = math.max(tonumber(workDepthCm) or 0, 0)
    if depth <= 0 then return 0, 0 end
    -- Up to 10 cm the operation is governed by the seedbed. Deeper tools still
    -- have to enter through the crust, but the 35 cm state increasingly owns
    -- the response. Keeping at least 35% surface weight avoids a deep tool
    -- unrealistically ignoring a frozen upper layer.
    local deepWeight = math.clamp((depth - 10) / 40, 0, 0.65)
    return 1 - deepWeight, deepWeight
end

function TerraLogicSoilMoistureManager:getFrostMechanicalResponse(
        soilTypeIndex, classKey, workDepthCm, surfaceMoisture, subsoilMoisture)
    local definition = self.FROST_RESPONSE[classKey]
    local surfaceWeight, deepWeight = getFrostDepthWeights(workDepthCm)
    if definition == nil or surfaceWeight + deepWeight <= 0 then
        return {severity=0, surfaceSeverity=0, subsoilSeverity=0,
            surfaceWeight=surfaceWeight, subsoilWeight=deepWeight,
            draftMultiplier=1, qualityFactor=1, penetrationFactor=1,
            dropoutFraction=0}
    end
    local temperature = TerraLogicSoilTemperatureManager
    local texture = FROST_TEXTURE_STRENGTH[
        self:getProfileIndex(soilTypeIndex)] or 1
    local surfaceSeverity = getFrozenLayerSeverity(
        temperature ~= nil and temperature.surfaceFrozen == true,
        temperature ~= nil and temperature.surfaceTemperatureC or 10,
        temperature ~= nil and temperature.surfaceFrozenHours or 0,
        self:getResponseMoisture(surfaceMoisture, soilTypeIndex), texture,
        temperature ~= nil and temperature.SURFACE_REFERENCE_FROZEN_HOURS or 36)
    local subsoilSeverity = getFrozenLayerSeverity(
        temperature ~= nil and temperature.subsoilFrozen == true,
        temperature ~= nil and temperature.subsoilTemperatureC or 10,
        temperature ~= nil and temperature.subsoilFrozenHours or 0,
        self:getResponseMoisture(subsoilMoisture, soilTypeIndex), texture,
        temperature ~= nil and temperature.SUBSOIL_REFERENCE_FROZEN_HOURS or 120)
    local severity = math.clamp(surfaceSeverity * surfaceWeight
        + subsoilSeverity * deepWeight, 0, 1)
    return {
        severity=severity,
        surfaceSeverity=surfaceSeverity,
        subsoilSeverity=subsoilSeverity,
        surfaceWeight=surfaceWeight,
        subsoilWeight=deepWeight,
        draftMultiplier=1 + severity * (definition.draft or 0),
        qualityFactor=1 - severity * (definition.qualityLoss or 0),
        penetrationFactor=1 - severity
            * (definition.penetrationLoss or 0),
        dropoutFraction=severity * (definition.dropout or 0)
    }
end

local function getSavePath()
    local info = g_currentMission ~= nil and g_currentMission.missionInfo or nil
    local directory = info ~= nil and info.savegameDirectory or nil
    if directory == nil or directory == "" then return nil end
    return directory .. "/" .. TerraLogicSoilMoistureManager.SAVE_FILE
end

function TerraLogicSoilMoistureManager:getEffectiveTimeScale()
    local mission = g_currentMission
    if mission == nil then return 0 end
    if type(mission.getEffectiveTimeScale) == "function" then
        local ok, value = pcall(mission.getEffectiveTimeScale, mission)
        value = tonumber(value)
        if ok and value ~= nil and value >= 0 then return value end
    end
    return math.max(tonumber(mission.missionInfo ~= nil
        and mission.missionInfo.timeScale) or 0, 0)
end

function TerraLogicSoilMoistureManager:getWeatherState()
    local environment = g_currentMission ~= nil
        and g_currentMission.environment or nil
    local weather = environment ~= nil and environment.weather or nil
    if weather == nil then
        return 0, 0, "weather API unavailable", false
    end
    local rain, wetness = 0, 0
    local rainValid, wetnessValid = false, false
    if type(weather.getRainFallScale) == "function" then
        local ok, value = pcall(weather.getRainFallScale, weather)
        value = tonumber(value)
        if ok and value ~= nil and value == value
            and math.abs(value) < 100000 then
            rain, rainValid = clamp01(value), true
        end
    end
    if type(weather.getGroundWetness) == "function" then
        local ok, value = pcall(weather.getGroundWetness, weather)
        value = tonumber(value)
        if ok and value ~= nil and value == value
            and math.abs(value) < 100000 then
            wetness, wetnessValid = clamp01(value), true
        end
    end
    return rain, wetness,
        "weather:getRainFallScale/getGroundWetness",
        rainValid and wetnessValid
end

-- Foliar herbicides need time to dry and enter the plant. FS does not expose
-- the selected active ingredient or a product-specific rainfast interval, so
-- TerraLogic deliberately reacts only to liquid precipitation that is falling
-- during the pass. Stored soil moisture is not an herbicide-quality input.
function TerraLogicSoilMoistureManager:getHerbicideRainResponse()
    local rain = clamp01(tonumber(self.rainScale) or 0)
    local liquidFactor = clamp01(
        tonumber(self.liquidPrecipitationFactor) or 1)
    local liquidRain = rain * liquidFactor
    local severity = smoothStep(0.02, 0.55, liquidRain)
    return {
        rainIntensity=liquidRain,
        severity=severity,
        qualityFactor=1-0.55*severity,
        dropoutFraction=0.45*severity,
        active=severity > 0.001
    }
end

function TerraLogicSoilMoistureManager:getTemperatureState()
    local state = TerraLogicSoilTemperatureManager ~= nil
        and TerraLogicSoilTemperatureManager.getState ~= nil
        and TerraLogicSoilTemperatureManager:getState() or nil
    return state ~= nil and tonumber(state.airTemperatureC) or 10,
        state ~= nil and tonumber(state.surfaceTemperatureC) or 10,
        state ~= nil and tonumber(state.calendarScale) or 1
end

local function newPeriodAccumulator()
    return {hours=0, rootSum=0, surfaceSum=0, temperatureSum=0,
        liquidRainHours=0, rainHours=0, validHours=0, invalidHours=0,
        daysPerPeriod=1}
end

function TerraLogicSoilMoistureManager:refreshDerivedStates()
    self.states = self.states or {}
    local surface = clamp01(self.surfaceWetness or 0.45)
    local root = clamp01(self.rootMoisture or 0.54)
    for _, index in ipairs(self.PROFILE_ORDER) do
        local profile = self.PROFILES[index]
        self.states[index] = self.states[index] or {}
        local water = self.waterStores ~= nil and self.waterStores[index]
        local hydraulic = self.HYDRAULICS[index]
        self.states[index].surface = water ~= nil
            and math.clamp(water.upper / 150, 0, hydraulic.saturation)
            or profile.initialSurface
        self.states[index].subsoil = water ~= nil
            and math.clamp(water.lower / 450, 0, hydraulic.saturation)
            or profile.initialSubsoil
        self.states[index].msWaterSource=water and water.msWaterSource or 0
    end
end

function TerraLogicSoilMoistureManager:initializeWaterStores()
    self.waterStores = self.waterStores or {}
    for _, index in ipairs(self.PROFILE_ORDER) do
        local h, p = self.HYDRAULICS[index], self.PROFILES[index]
        self.waterStores[index] = self.waterStores[index] or {
            upper=p.initialSurface * 150,
            lower=p.initialSubsoil * 450}
    end
end

-- Conservative two-reservoir approximation, not a Richards-equation solver.
-- Field capacity softens drainage; it is not an impermeable threshold.
-- Optional APIs never turn missing observations into measured zeroes.
local function optionalNumber(object, method)
    if object ~= nil and type(object[method]) == "function" then
        local ok, value = pcall(object[method], object)
        if ok and type(value) == "number" and value == value
            and math.abs(value) < math.huge then return value end
    end
end

function TerraLogicSoilMoistureManager:getSnowHeight()
    local system = g_currentMission and g_currentMission.snowSystem
    local height = optionalNumber(system, "getHeight")
    if height == nil and system ~= nil then height = system.height end
    if type(height) == "number" and height == height and math.abs(height) < math.huge then
        return math.max(height, 0)
    end
end

function TerraLogicSoilMoistureManager:stepWaterBalance(hours, rain, evaporation)
    local temperature = TerraLogicSoilTemperatureManager or {}
    local upperFlow = .05 + .95 * smoothStep(-1, 1, temperature.surfaceTemperatureC or self.modelSurfaceTemperature or 10)
    local lowerFlow = .05 + .95 * smoothStep(-1, 1, temperature.subsoilTemperatureC or 10)
    local liquidFactor = self.liquidPrecipitationFactor or 1
    local setting=TerraLogicSettings and TerraLogicSettings.precipitationState or 2
    local factor=TerraLogicFieldWaterManager and TerraLogicFieldWaterManager.PRECIPITATION_FACTORS[setting] or 1
    if TerraLogicMoistureSystemAdapter:isUsingMS() then factor=1 end
    local other = factor * (rain + (self.hailScale or 0)) * self.RAIN_MM_PER_HOUR * hours
    local solid = factor * (self.snowScale or 0) * self.SNOW_MM_PER_HOUR * hours + other * (1-liquidFactor)
    self.snowWaterMm = (self.snowWaterMm or 0) + solid
    local melt = math.min(self.snowWaterMm,
        self.MELT_MM_PER_DEGREE_DAY / 24 * math.max(self.modelAirTemperature or 10, 0) * hours)
    self.snowWaterMm = self.snowWaterMm - melt
    local totalRain = other * liquidFactor + melt
    local logger = TerraLogicWeatherLogger
    if logger ~= nil and logger.active then
        logger:recordSnowFlux(solid, melt, other + factor*(self.snowScale or 0)*self.SNOW_MM_PER_HOUR*hours)
    end
    if TerraLogicFieldWaterManager and TerraLogicFieldWaterManager.initialized then
        TerraLogicFieldWaterManager:step(hours,totalRain,evaporation,upperFlow,lowerFlow,self.snowWaterMm)
    end
    for _, index in ipairs(self.PROFILE_ORDER) do
        local w,h=self.waterStores[index],self.HYDRAULICS[index]
        local infiltration,transfer,drainage,evaporated,uptake,u,d=
            TerraLogicMoistureSystemAdapter:step(w,h,hours,totalRain,evaporation,upperFlow,lowerFlow,
                self.snowWaterMm,nil,self,nil,index)
        if logger and logger.active then logger:recordFlux(index,w.lastInputMm,infiltration,
            transfer,drainage,evaporated,uptake,u,d,w.lastBalanceError) end
    end
    self.surfaceWetness = self.waterStores[0].upper / 150
end

-- Crop/yield sees a daily mean, never the instantaneous mechanical wetness.
function TerraLogicSoilMoistureManager:onDayChanged()
    if self.initialized ~= true or self.auditOverrideActive == true
        or g_currentMission == nil or not g_currentMission:getIsServer() then return end
    if TerraLogicFieldWaterManager then TerraLogicFieldWaterManager:onDayChanged() end
    local day = self.dayAccumulator or {hours=0, rootSum=0}
    if day.hours >= 12 then
        self.rootMoisture = clamp01(day.rootSum / day.hours)
        self.climateMoistureTarget = self.rootMoisture
        self.dailyProfileMeans = self.dailyProfileMeans or {}
        for _, i in ipairs(self.PROFILE_ORDER) do
            local upper, lower = day['soil'..i..'UpperSum'], day['soil'..i..'LowerSum']
            if upper ~= nil and lower ~= nil then
                self.dailyProfileMeans[i] = {surface=upper/day.hours, subsoil=lower/day.hours}
            end
        end
        self.lastSyncValues=nil
    end
    self.dayAccumulator = {hours=0, rootSum=0}
end

function TerraLogicSoilMoistureManager:addHistorySnapshot(snapshot)
    if snapshot == nil then return end
    self.periodHistory = self.periodHistory or {}
    self.periodHistory[#self.periodHistory + 1] = snapshot
    while #self.periodHistory > self.HISTORY_LENGTH do
        table.remove(self.periodHistory, 1)
    end
    self.lastPeriodSnapshot = snapshot
end

function TerraLogicSoilMoistureManager:load()
    self:delete(false)
    local _, groundWetness, source, weatherValid = self:getWeatherState()
    self.surfaceWetness = self.HYDRAULICS[0].fieldCapacity*.85
    self.rootMoisture = self.HYDRAULICS[0].fieldCapacity*.95
    self.climateMoistureTarget = self.rootMoisture
    self.periodAccumulator = newPeriodAccumulator()
    self.dayAccumulator = {hours=0, rootSum=0}
    self.periodHistory = {}
    self.dailyProfileMeans = {}
    self.periodSerial = 0
    self.lastPeriodSnapshot = nil
    self.rainScale = 0
    self.snowScale, self.hailScale = 0, 0
    self.groundWetness = groundWetness
    self.liquidPrecipitationFactor = 1
    self.evaporationFactor = 1
    self.calendarScale = 1
    self.weatherSource = source
    self.weatherDataValid = weatherValid == true
    self.loadedFromSave = false
    self.snowWaterMm = 0
    self.snowInitialized = false
    self.snowInitialization = "pending"
    self.migratedFromBucketModel = false
    self.simulatedGameHours = 0
    self.initialized = true
    self.syncTimerMs = 0
    self.syncKeepaliveMs = 0
    self.lastSyncValues = nil

    local savedVersion = self.SAVE_VERSION
    local mission = g_currentMission
    if mission ~= nil and mission:getIsServer() then
        local path = getSavePath()
        if path ~= nil and fileExists(path) then
            local xml = loadXMLFile("terraLogicSoilMoisture", path)
            if xml ~= nil and xml ~= 0 then
                local version = tonumber(getXMLInt(
                    xml, "soilMoisture#version")) or 1
                savedVersion = version
                if version >= 2 then
                    self.surfaceWetness = clamp01(tonumber(getXMLFloat(
                        xml, "soilMoisture#surfaceWetness"))
                        or self.surfaceWetness)
                    self.rootMoisture = clamp01(tonumber(getXMLFloat(
                        xml, "soilMoisture#rootMoisture"))
                        or self.rootMoisture)
                    self.climateMoistureTarget = clamp01(tonumber(getXMLFloat(
                        xml, "soilMoisture#climateTarget"))
                        or self.rootMoisture)
                    self.periodSerial = math.max(tonumber(getXMLInt(
                        xml, "soilMoisture#periodSerial")) or 0, 0)
                    local accumulator = newPeriodAccumulator()
                    for _, name in ipairs({"hours", "rootSum", "surfaceSum",
                            "temperatureSum", "liquidRainHours", "rainHours",
                            "validHours", "invalidHours", "daysPerPeriod"}) do
                        accumulator[name] = tonumber(getXMLFloat(xml,
                            "soilMoisture.accumulator#" .. name))
                            or accumulator[name]
                    end
                    self.periodAccumulator = accumulator
                    local index = 0
                    while hasXMLProperty(xml, string.format(
                            "soilMoisture.history.period(%d)", index)) do
                        local key = string.format(
                            "soilMoisture.history.period(%d)", index)
                        self:addHistorySnapshot({
                            serial=tonumber(getXMLInt(xml, key .. "#serial")) or 0,
                            rootMean=clamp01(getXMLFloat(xml, key .. "#rootMean")),
                            surfaceMean=clamp01(getXMLFloat(
                                xml, key .. "#surfaceMean")),
                            rainHoursPerDay=math.max(tonumber(getXMLFloat(
                                xml, key .. "#rainHoursPerDay")) or 0, 0),
                            daysPerPeriod=math.max(tonumber(getXMLFloat(
                                xml, key .. "#daysPerPeriod")) or 1, 1),
                            observedHours=math.max(tonumber(getXMLFloat(
                                xml, key .. "#observedHours")) or 0, 0),
                            observationShare=math.max(tonumber(getXMLFloat(
                                xml, key .. "#observationShare")) or 0, 0),
                            validWeatherShare=math.max(tonumber(getXMLFloat(
                                xml, key .. "#validWeatherShare")) or 0, 0),
                            weatherValid=getXMLBool(xml, key .. "#weatherValid")
                                ~= false
                        })
                        index = index + 1
                    end
                else
                    -- v79 stored five independent buckets. Preserve the
                    -- neutral/PF-standard Sandy Loam state as the v80 master
                    -- instead of resetting an established savegame.
                    local key = "soilMoisture.profile(2)"
                    self.surfaceWetness = clamp01(tonumber(getXMLFloat(
                        xml, key .. "#surface")) or self.surfaceWetness)
                    self.rootMoisture = clamp01(tonumber(getXMLFloat(
                        xml, key .. "#subsoil")) or self.rootMoisture)
                    self.climateMoistureTarget = self.rootMoisture
                    self.migratedFromBucketModel = true
                end
                self.simulatedGameHours = math.max(tonumber(getXMLFloat(
                    xml, "soilMoisture#simulatedGameHours")) or 0, 0)
                if version >= 3 then
                    self.waterStores = {}
                    for _, index in ipairs(self.PROFILE_ORDER) do
                        local key = string.format("soilMoisture.water(%d)", index)
                        local upper = getXMLFloat(xml, key .. "#upper")
                        local lower = getXMLFloat(xml, key .. "#lower")
                        local h = self.HYDRAULICS[index]
                        local legacy = self.LEGACY_CAPACITIES[index]
                        if upper ~= nil and lower ~= nil then
                            -- Preserve displayed moisture when changing the
                            -- effective storage scale of a v3 test save.
                            local caps = version == 3 and legacy or version == 4 and self.V4_CAPACITIES[index]
                                or version == 5 and self.V5_CAPACITIES[index] or self.V6_CAPACITIES[index]
                            self.waterStores[index] = version >= 7 and {
                                upper=math.clamp(upper,0,h.upper), lower=math.clamp(lower,0,h.lower)} or {
                                upper=self:legacyToVolume(upper/caps[1],index,false)*150,
                                lower=self:legacyToVolume(lower/caps[2],index,true)*450}
                            if version>=7 then
                                TerraLogicMoistureSystemAdapter:loadStore(xml,key,self.waterStores[index],h)
                            end
                        end
                    end
                    self.dayAccumulator = {
                        hours=math.max(getXMLFloat(xml, "soilMoisture.day#hours") or 0, 0),
                        rootSum=math.max(getXMLFloat(xml, "soilMoisture.day#rootSum") or 0, 0)}
                    if version >= 7 then
                        for _, i in ipairs(self.PROFILE_ORDER) do
                            local stem = 'soil'..i
                            self.dailyProfileMeans[i] = {
                                surface=getXMLFloat(xml,'soilMoisture.daily.'..stem..'#surface'),
                                subsoil=getXMLFloat(xml,'soilMoisture.daily.'..stem..'#subsoil')}
                            for _, layer in ipairs({'Upper','Lower'}) do
                                local sumKey=stem..layer..'Sum'
                                self.dayAccumulator[sumKey]=getXMLFloat(xml,'soilMoisture.day#'..sumKey) or 0
                                self.periodAccumulator[sumKey]=getXMLFloat(xml,'soilMoisture.accumulator#'..sumKey) or 0
                                for n,snapshot in ipairs(self.periodHistory) do
                                    snapshot[stem..layer..'Mean']=getXMLFloat(xml,string.format(
                                        'soilMoisture.history.period(%d)#%s%sMean',n-1,stem,layer))
                                end
                            end
                        end
                    end
                end
                local savedSnow = version >= 5 and getXMLFloat(xml, "soilMoisture#snowWaterMm") or nil
                if savedSnow ~= nil then
                    self.snowWaterMm = math.max(savedSnow,0)
                    self.snowInitialized = true
                    self.snowInitialization = "save"
                end
                self.loadedFromSave = true
                delete(xml)
            end
        end
    end
    if savedVersion < 7 then
        -- Old bucket fractions map by wilting/retention anchors, never by
        -- reinterpreting e.g. 70% as 70 vol-% water.
        if savedVersion < 3 then
            self.waterStores = {}
            for _, i in ipairs(self.PROFILE_ORDER) do
                local a=self.LEGACY_ANCHORS[i]
                self.waterStores[i]={upper=self:legacyToVolume(self.surfaceWetness*a[4],i,false)*150,
                    lower=self:legacyToVolume(self.rootMoisture*a[5],i,true)*450}
            end
        end
        for _, snapshot in ipairs(self.periodHistory) do
            for _, i in ipairs(self.PROFILE_ORDER) do
                local a=self.LEGACY_ANCHORS[i]
                snapshot['soil'..i..'UpperMean']=self:legacyToVolume(snapshot.surfaceMean*a[4],i,false)
                snapshot['soil'..i..'LowerMean']=self:legacyToVolume(snapshot.rootMean*a[5],i,true)
            end
            snapshot.rootMean=self:legacyToVolume(snapshot.rootMean,0,true)
            snapshot.surfaceMean=self:legacyToVolume(snapshot.surfaceMean,0,false)
        end
        self.dayAccumulator={hours=0,rootSum=0}
        self.periodAccumulator=newPeriodAccumulator()
        self.rootMoisture=self:legacyToVolume(self.rootMoisture,0,true)
        self.surfaceWetness=self:legacyToVolume(self.surfaceWetness,0,false)
        self.climateMoistureTarget=self.rootMoisture
    end
    self:initializeWaterStores()
    self:refreshDerivedStates()
    for _, i in ipairs(self.PROFILE_ORDER) do
        local d=self.dailyProfileMeans[i]
        if d==nil or d.surface==nil or d.subsoil==nil then
            self.dailyProfileMeans[i]={surface=self.states[i].surface,subsoil=self.states[i].subsoil}
        end
    end
    if g_messageCenter ~= nil and MessageType ~= nil and MessageType.DAY_CHANGED ~= nil then
        g_messageCenter:subscribe(MessageType.DAY_CHANGED, self.onDayChanged, self)
    end
    if g_messageCenter ~= nil and MessageType ~= nil
        and MessageType.PERIOD_CHANGED ~= nil then
        g_messageCenter:subscribe(MessageType.PERIOD_CHANGED,
            self.onPeriodChanged, self)
    end
    TerraLogicLogging.debug(
        "[FS25_TerraLogic] Live two-layer moisture loaded: surface/daily crop %.1f/%.1f%%, PF profiles=%d, history=%d, source=%s (%s%s)",
        self.surfaceWetness * 100, self.rootMoisture * 100,
        #self.PROFILE_ORDER - 1, #self.periodHistory, tostring(source),
        self.loadedFromSave and "save" or "weather initialization",
        self.migratedFromBucketModel and ", v79 migration" or "")
end

function TerraLogicSoilMoistureManager:save()
    local mission = g_currentMission
    if mission == nil or not mission:getIsServer()
        or self.initialized ~= true then return end
    local path = getSavePath()
    if path == nil then return end
    local xml = createXMLFile("terraLogicSoilMoisture", path, "soilMoisture")
    if xml == nil or xml == 0 then return end
    setXMLInt(xml, "soilMoisture#version", self.SAVE_VERSION)
    if self.snowInitialized then
        setXMLFloat(xml, "soilMoisture#snowWaterMm", self.snowWaterMm or 0)
    end
    setXMLFloat(xml, "soilMoisture#simulatedGameHours",
        self.simulatedGameHours or 0)
    local persisted = self.auditOverrideActive
        and self.auditOverrideSnapshot or self
    setXMLFloat(xml, "soilMoisture#surfaceWetness",
        persisted.surfaceWetness)
    setXMLFloat(xml, "soilMoisture#rootMoisture", persisted.rootMoisture)
    setXMLFloat(xml, "soilMoisture#climateTarget",
        persisted.climateMoistureTarget)
    setXMLInt(xml, "soilMoisture#periodSerial", self.periodSerial or 0)
    for _, index in ipairs(self.PROFILE_ORDER) do
        local w = self.waterStores[index]
        local key = string.format("soilMoisture.water(%d)", index)
        setXMLFloat(xml, key .. "#upper", w.upper)
        setXMLFloat(xml, key .. "#lower", w.lower)
        TerraLogicMoistureSystemAdapter:saveStore(xml,key,w)
    end
    setXMLFloat(xml, "soilMoisture.day#hours", self.dayAccumulator.hours)
    setXMLFloat(xml, "soilMoisture.day#rootSum", self.dayAccumulator.rootSum)
    for _, i in ipairs(self.PROFILE_ORDER) do
        local stem='soil'..i
        local d=self.dailyProfileMeans[i] or self.states[i]
        setXMLFloat(xml,'soilMoisture.daily.'..stem..'#surface',d.surface)
        setXMLFloat(xml,'soilMoisture.daily.'..stem..'#subsoil',d.subsoil)
        for _, layer in ipairs({'Upper','Lower'}) do
            local sumKey=stem..layer..'Sum'
            setXMLFloat(xml,'soilMoisture.day#'..sumKey,self.dayAccumulator[sumKey] or 0)
        end
    end
    for name, value in pairs(self.periodAccumulator or {}) do
        if type(value) == "number" then
            setXMLFloat(xml, "soilMoisture.accumulator#" .. name, value)
        end
    end
    for index, snapshot in ipairs(self.periodHistory or {}) do
        local key = string.format(
            "soilMoisture.history.period(%d)", index - 1)
        setXMLInt(xml, key .. "#serial", snapshot.serial or 0)
        setXMLFloat(xml, key .. "#rootMean", snapshot.rootMean or 0.54)
        setXMLFloat(xml, key .. "#surfaceMean",
            snapshot.surfaceMean or 0.45)
        setXMLFloat(xml, key .. "#rainHoursPerDay",
            snapshot.rainHoursPerDay or 0)
        setXMLFloat(xml, key .. "#daysPerPeriod",
            snapshot.daysPerPeriod or 1)
        setXMLFloat(xml, key .. "#observedHours",
            snapshot.observedHours or 0)
        setXMLFloat(xml, key .. "#observationShare",
            snapshot.observationShare or 0)
        setXMLFloat(xml, key .. "#validWeatherShare",
            snapshot.validWeatherShare or 0)
        setXMLBool(xml, key .. "#weatherValid",
            snapshot.weatherValid ~= false)
        for _, i in ipairs(self.PROFILE_ORDER) do
            for _, layer in ipairs({'Upper','Lower'}) do
                local meanKey='soil'..i..layer..'Mean'
                if snapshot[meanKey]~=nil then setXMLFloat(xml,key..'#'..meanKey,snapshot[meanKey]) end
            end
        end
    end
    saveXMLFile(xml)
    delete(xml)
end

function TerraLogicSoilMoistureManager:onPeriodChanged()
    local mission = g_currentMission
    if mission == nil or not mission:getIsServer()
        or self.initialized ~= true then return end
    local accumulator = self.periodAccumulator or newPeriodAccumulator()
    local hours = math.max(tonumber(accumulator.hours) or 0, 0)
    local days = math.max(tonumber(accumulator.daysPerPeriod) or 1, 1)
    local validHours = math.max(tonumber(accumulator.validHours) or 0, 0)
    local expectedHours = days * 24
    local observationShare = hours / math.max(expectedHours, 1)
    local validShare = validHours / math.max(hours, 0.0001)
    -- A partial first period after installing/loading must not masquerade as
    -- a complete drought. This only rejects insufficient telemetry; a fully
    -- observed period with zero rain remains deliberately and validly dry.
    local valid = observationShare >= self.MIN_PERIOD_OBSERVATION_SHARE
        and validShare >= self.MIN_VALID_WEATHER_SHARE
    local previousRoot = clamp01(self.rootMoisture)
    local rainPerDay = math.max(
        (tonumber(accumulator.liquidRainHours) or 0) / days, 0)
    -- Crop-cycle markers remain calendar-period based. Integrating the same
    -- samples as the daily mean avoids an extra day's lag at month boundaries.
    self.periodSerial = (tonumber(self.periodSerial) or 0) + 1
    local snapshot = {
        serial=self.periodSerial,
        rootMean=hours > 0 and accumulator.rootSum / hours or previousRoot,
        surfaceMean=hours > 0
            and (accumulator.surfaceSum or 0) / hours
            or self.surfaceWetness,
        rainHoursPerDay=rainPerDay,
        daysPerPeriod=days,
        weatherValid=valid,
        observedHours=hours,
        observationShare=observationShare,
        validWeatherShare=validShare
    }
    for _, i in ipairs(self.PROFILE_ORDER) do
        for _, layer in ipairs({'Upper','Lower'}) do
            local stem='soil'..i..layer
            snapshot[stem..'Mean']=hours>0 and (accumulator[stem..'Sum'] or 0)/hours
                or (layer=='Upper' and self.states[i].surface or self.states[i].subsoil)
        end
    end
    self:addHistorySnapshot(snapshot)
    if TerraLogicFieldWaterManager then TerraLogicFieldWaterManager:onPeriodChanged(snapshot.serial,snapshot.daysPerPeriod) end
    self.periodAccumulator = newPeriodAccumulator()
    self:refreshDerivedStates()
end

function TerraLogicSoilMoistureManager:update(dt)
    local mission = g_currentMission
    if mission == nil or not mission:getIsServer()
        or self.initialized ~= true then return end
    -- Audit presets deliberately hold the primary moisture state constant.
    -- Derived mechanics still use the ordinary public getters, so no draft,
    -- quality, traffic or yield result is bypassed by the test harness.
    if self.auditOverrideActive == true then return end
    local realDtMs = math.max(tonumber(dt) or 0, 0)
    local rain, groundWetness, source, weatherValid = self:getWeatherState()
    local air, surfaceTemperature, calendarScale = self:getTemperatureState()
    self.rainScale, self.groundWetness = rain, groundWetness
    self.weatherSource, self.calendarScale = source, calendarScale
    self.weatherDataValid = weatherValid == true
    local uncappedHours = realDtMs * self:getEffectiveTimeScale() / 3600000
    local gameHours = math.min(uncappedHours, self.MAX_GAME_HOURS_PER_UPDATE)
    self.droppedGameHours = (self.droppedGameHours or 0)
        + math.max(uncappedHours - gameHours, 0)
    self.modelAirTemperature, self.modelSurfaceTemperature = air, surfaceTemperature
    local weather = mission.environment and mission.environment.weather
    self.snowScaleObserved = optionalNumber(weather, "getSnowFallScale")
    self.hailScaleObserved = optionalNumber(weather, "getHailFallScale")
    self.snowScale, self.hailScale = clamp01(self.snowScaleObserved or 0), clamp01(self.hailScaleObserved or 0)
    self.observedSnowHeight = self:getSnowHeight()
    if not self.snowInitialized and gameHours > 0 and weatherValid then
        -- Existing snow on first installation: explicit approximate 100 kg/m3.
        -- Never add height changes later: clearing/tyres/settings are not melt.
        self.snowWaterMm = (self.observedSnowHeight or 0) * 100
        self.snowInitialized = true
        self.snowInitialization = self.observedSnowHeight ~= nil and "height_estimate" or "empty_no_height"
    end
    local liquidFactor = smoothStep(-0.5, 1.5, air)
    local liquidRain = weatherValid and rain * liquidFactor or 0
    self.liquidPrecipitationFactor = liquidFactor
    local temperatureFactor = clamp01((air + 2) / 27)
    local atmosphericDryness = 0.35 + 0.65 * (1 - groundWetness)
    self.evaporationFactor = temperatureFactor * atmosphericDryness

    if gameHours > 0 then
        local integratedRoot = self.rootMoisture * gameHours
        if weatherValid then
            integratedRoot = 0
            local remaining = gameHours
            while remaining > 0.000000001 do
                local step = math.min(remaining, self.MAX_STEP_HOURS)
                local before = self.waterStores[0].lower / 450
                for _, i in ipairs(self.PROFILE_ORDER) do
                    local w=self.waterStores[i]
                    w.beforeUpper, w.beforeLower=w.upper/150,w.lower/450
                end
                self:stepWaterBalance(step, rain, self.evaporationFactor)
                local after = self.waterStores[0].lower / 450
                for _, i in ipairs(self.PROFILE_ORDER) do
                    local w=self.waterStores[i]
                    local u=(w.beforeUpper+w.upper/150)*.5*step
                    local d=(w.beforeLower+w.lower/450)*.5*step
                    local uk,dk='soil'..i..'UpperSum','soil'..i..'LowerSum'
                    self.dayAccumulator[uk]=(self.dayAccumulator[uk] or 0)+u
                    self.dayAccumulator[dk]=(self.dayAccumulator[dk] or 0)+d
                    self.periodAccumulator[uk]=(self.periodAccumulator[uk] or 0)+u
                    self.periodAccumulator[dk]=(self.periodAccumulator[dk] or 0)+d
                end
                self.dayAccumulator.hours = self.dayAccumulator.hours + step
                self.dayAccumulator.rootSum = self.dayAccumulator.rootSum
                    + (before + after) * 0.5 * step
                integratedRoot = integratedRoot + (before + after) * 0.5 * step
                remaining = remaining - step
            end
        else
            -- Missing weather holds the live state. A partially observed
            -- period must not dilute its per-texture averages toward zero.
            for _, i in ipairs(self.PROFILE_ORDER) do
                local w=self.waterStores[i]
                local uk,dk='soil'..i..'UpperSum','soil'..i..'LowerSum'
                self.periodAccumulator[uk]=(self.periodAccumulator[uk] or 0)+w.upper/150*gameHours
                self.periodAccumulator[dk]=(self.periodAccumulator[dk] or 0)+w.lower/450*gameHours
            end
        end
        self.surfaceWetness = clamp01(self.surfaceWetness)

        local accumulator = self.periodAccumulator
            or newPeriodAccumulator()
        self.periodAccumulator = accumulator
        accumulator.hours = accumulator.hours + gameHours
        accumulator.rootSum = accumulator.rootSum + integratedRoot
        accumulator.surfaceSum = accumulator.surfaceSum
            + self.surfaceWetness * gameHours
        accumulator.temperatureSum = accumulator.temperatureSum
            + surfaceTemperature * gameHours
        accumulator.rainHours = accumulator.rainHours
            + (weatherValid and rain or 0) * gameHours
        accumulator.liquidRainHours = accumulator.liquidRainHours
            + liquidRain * gameHours
        if weatherValid then
            accumulator.validHours = accumulator.validHours + gameHours
        else
            accumulator.invalidHours = accumulator.invalidHours + gameHours
        end
        local temperatureState = TerraLogicSoilTemperatureManager ~= nil
            and TerraLogicSoilTemperatureManager:getState() or nil
        accumulator.daysPerPeriod = temperatureState ~= nil
            and tonumber(temperatureState.daysPerPeriod) or 1
        self.simulatedGameHours = (self.simulatedGameHours or 0) + gameHours
        self:refreshDerivedStates()
    end

    self.syncTimerMs = (self.syncTimerMs or 0) - realDtMs
    self.syncKeepaliveMs = (self.syncKeepaliveMs or 0) + realDtMs
    if self.syncTimerMs <= 0 then
        self.syncTimerMs = self.SYNC_INTERVAL_MS
        local changed = self.lastSyncValues == nil
        if not changed then
            for _, index in ipairs(self.PROFILE_ORDER) do
                local old, state = self.lastSyncValues[index], self.states[index]
                if old == nil or math.abs(state.surface - old.surface)
                        >= self.SYNC_CHANGE_THRESHOLD
                    or math.abs(state.subsoil - old.subsoil)
                        >= self.SYNC_CHANGE_THRESHOLD then
                    changed = true
                    break
                end
            end
        end
        if changed or self.syncKeepaliveMs >= self.SYNC_KEEPALIVE_MS then
            self:sendState(nil)
        end
    end
end

function TerraLogicSoilMoistureManager:getProfileIndex(soilTypeIndex)
    local index = tonumber(soilTypeIndex)
    return self.PROFILES[index] ~= nil and index or 0
end

function TerraLogicSoilMoistureManager:getProfileState(soilTypeIndex, x, z)
    local index = self:getProfileIndex(soilTypeIndex)
    local state = self.states ~= nil and self.states[index] or nil
    local profile = self.PROFILES[index]
    if x ~= nil and z ~= nil and TerraLogicFieldWaterManager and not self.auditOverrideActive then
        local w=TerraLogicFieldWaterManager:getStore(x,z,index)
        if w then return w.upper/150,w.lower/450,index,profile,w.msWaterSource or 0 end
    end
    if state == nil then
        return profile.initialSurface, profile.initialSubsoil, index, profile
    end
    local source=state.msWaterSource
    if source==nil then source=self.waterStores and self.waterStores[index]
        and self.waterStores[index].msWaterSource or 0 end
    return clamp01(state.surface), clamp01(state.subsoil), index, profile,source
end

function TerraLogicSoilMoistureManager:getStateAtWorldPosition(x, z)
    local soilTypeIndex = TerraLogicSoilManager ~= nil
        and TerraLogicSoilManager.getPFSoilTypeAtWorldPosition ~= nil
        and TerraLogicSoilManager:getPFSoilTypeAtWorldPosition(x, z) or nil
    local surface, subsoil, index, profile, moistureSource =
        self:getProfileState(soilTypeIndex, x, z)
    -- Read the synchronized manager fields directly. These queries run for
    -- many WorkArea cells, so allocating a complete temperature-state table
    -- per cell would be needless CPU and garbage-collector pressure.
    local surfaceFrozen = TerraLogicSoilTemperatureManager ~= nil
        and TerraLogicSoilTemperatureManager.surfaceFrozen == true
    local subsoilFrozen = TerraLogicSoilTemperatureManager ~= nil
        and TerraLogicSoilTemperatureManager.subsoilFrozen == true
    return {surface=surface, subsoil=subsoil, profileIndex=index,moistureSource=moistureSource or 0,
        profileName=profile.name, pfActive=index > 0,
        liquidSurface=surfaceFrozen and 0 or surface,
        liquidSubsoil=subsoilFrozen and 0 or subsoil,
        surfaceFrozen=surfaceFrozen, subsoilFrozen=subsoilFrozen}
end

function TerraLogicSoilMoistureManager:getMechanicalResponse(
        soilTypeIndex, classKey, workDepthCm, x, z)
    local surface, subsoil, index, profile =
        self:getProfileState(soilTypeIndex, x, z)
    local surfaceFrozen = TerraLogicSoilTemperatureManager ~= nil
        and TerraLogicSoilTemperatureManager.surfaceFrozen == true
    local subsoilFrozen = TerraLogicSoilTemperatureManager ~= nil
        and TerraLogicSoilTemperatureManager.subsoilFrozen == true
    local depth = math.max(tonumber(workDepthCm) or 0, 0)
    local deepWeight = math.clamp((depth - 10) / 50, 0, 0.72)
    local effective = surface * (1 - deepWeight) + subsoil * deepWeight
    -- Frozen water is neither traffic-sensitive mud nor agronomic drought.
    -- Preserve the hydrological state for thaw and crop history, but remove a
    -- frozen layer from both liquid-wet and dry implement penalties. Frost
    -- and thaw retain their own explicit soil-process path.
    local liquidSurface = surfaceFrozen and 0 or surface
    local liquidSubsoil = subsoilFrozen and 0 or subsoil
    local h = self.HYDRAULICS[index]
    local drySurface = surfaceFrozen and h.fieldCapacity or surface
    local drySubsoil = subsoilFrozen and h.fieldCapacity or subsoil
    local liquidEffective = liquidSurface * (1 - deepWeight)
        + liquidSubsoil * deepWeight
    local dryEffective = drySurface * (1 - deepWeight)
        + drySubsoil * deepWeight
    local drySeverity = 1 - smoothStep(h.wilt, h.wilt+.55*(h.fieldCapacity-h.wilt), dryEffective)
    local wetSeverity = smoothStep(
        profile.wetOnset, h.fieldCapacity+.85*(h.saturation-h.fieldCapacity), liquidEffective)
    local definition = self.IMPLEMENT_RESPONSE[classKey]
    local frost = self:getFrostMechanicalResponse(
        soilTypeIndex, classKey, workDepthCm, surface, subsoil)
    if definition == nil then
        return {surface=surface, subsoil=subsoil, effective=effective,
            hydrologicEffective=effective, liquidEffective=liquidEffective,
            liquidSurface=liquidSurface, liquidSubsoil=liquidSubsoil,
            surfaceFrozen=surfaceFrozen, subsoilFrozen=subsoilFrozen,
            profileIndex=index, profileName=profile.name,
            drySeverity=drySeverity, wetSeverity=wetSeverity,
            implementMoistureActive=false,
            dryQualityLoss=0, wetQualityLoss=0,
            frostSeverity=frost.severity,
            frostSurfaceSeverity=frost.surfaceSeverity,
            frostSubsoilSeverity=frost.subsoilSeverity,
            frostSurfaceWeight=frost.surfaceWeight,
            frostSubsoilWeight=frost.subsoilWeight,
            frostDraftMultiplier=frost.draftMultiplier,
            frostQualityFactor=frost.qualityFactor,
            penetrationFactor=frost.penetrationFactor,
            frostDropoutFraction=frost.dropoutFraction,
            draftMultiplier=1, qualityFactor=frost.qualityFactor,
            soilEffectiveness=frost.penetrationFactor,
            dropoutFraction=frost.dropoutFraction,
            trafficSurfaceMultiplier=1,
            trafficDeepMultiplier=1}
    end
    local wetTexture = profile.wetDraftTexture or 1
    local draft = 1 + drySeverity * (definition.dryDraft or 0)
        + wetSeverity * (definition.wetDraft or 0) * wetTexture
    local quality = 1 - drySeverity * (definition.dryQuality or 0)
        - wetSeverity * (definition.wetQuality or 0)
    local effectiveness = 1 - drySeverity * (definition.dryEffect or 0)
        - wetSeverity * (definition.wetEffect or 0)
    local dropout = drySeverity * (definition.dryDropout or 0)
        + wetSeverity * (definition.wetDropout or 0)
    -- Frost and liquid-moisture mechanics describe the same failed
    -- penetration/placement outcome. Use the stricter ceiling for quality and
    -- soil effectiveness instead of multiplying two agronomic penalties.
    quality = math.min(quality, frost.qualityFactor)
    effectiveness = math.min(effectiveness, frost.penetrationFactor)
    dropout = math.max(dropout, frost.dropoutFraction)
    return {surface=surface, subsoil=subsoil, effective=effective,
        hydrologicEffective=effective, liquidEffective=liquidEffective,
        liquidSurface=liquidSurface, liquidSubsoil=liquidSubsoil,
        surfaceFrozen=surfaceFrozen, subsoilFrozen=subsoilFrozen,
        profileIndex=index, profileName=profile.name,
        drySeverity=drySeverity, wetSeverity=wetSeverity,
        implementMoistureActive=true,
        dryQualityLoss=drySeverity * (definition.dryQuality or 0),
        wetQualityLoss=wetSeverity * (definition.wetQuality or 0),
        frostSeverity=frost.severity,
        frostSurfaceSeverity=frost.surfaceSeverity,
        frostSubsoilSeverity=frost.subsoilSeverity,
        frostSurfaceWeight=frost.surfaceWeight,
        frostSubsoilWeight=frost.subsoilWeight,
        frostDraftMultiplier=frost.draftMultiplier,
        frostQualityFactor=frost.qualityFactor,
        penetrationFactor=frost.penetrationFactor,
        frostDropoutFraction=frost.dropoutFraction,
        draftMultiplier=math.clamp(draft, 1, 1.35),
        qualityFactor=math.clamp(quality,
            frost.severity > 0 and 0.60 or 0.68, 1),
        soilEffectiveness=math.clamp(effectiveness,
            frost.severity > 0 and 0.22 or 0.52, 1),
        dropoutFraction=math.clamp(dropout, 0, 0.28)}
end

function TerraLogicSoilMoistureManager:getTrafficMultipliers(soilTypeIndex, x, z)
    local surface, subsoil, index, profile =
        self:getProfileState(soilTypeIndex, x, z)
    local surfaceFrozen = TerraLogicSoilTemperatureManager ~= nil
        and TerraLogicSoilTemperatureManager.surfaceFrozen == true
    local subsoilFrozen = TerraLogicSoilTemperatureManager ~= nil
        and TerraLogicSoilTemperatureManager.subsoilFrozen == true
    local h = self.HYDRAULICS[index]
    local function response(value, frozen)
        if frozen then return 1 end
        -- Smooth strength proxy from suction. At FC x1.11, near saturation
        -- x1.50, dry soil approaches x0.72. This is a bounded model response,
        -- not a certified load-bearing capacity in kPa. Texture/load remain
        -- explicit inputs to the actual wheel-compaction calculation.
        local suction = self:getMatricSuction(value,index)
        return .72 + .78 / (1 + (suction/h.suctionFC)^.8)
    end
    return response(surface, surfaceFrozen), response(subsoil, subsoilFrozen), index
end

function TerraLogicSoilMoistureManager:getPeriodSerial()
    return math.max(math.floor(tonumber(self.periodSerial) or 0), 0)
end

-- One byte is enough because a crop cycle cannot realistically span 255
-- calendar periods. Decode against the current absolute serial after reload.
function TerraLogicSoilMoistureManager:encodePeriodMarker(serial)
    return math.floor(math.max(tonumber(serial) or 0, 0)) % 255 + 1
end

function TerraLogicSoilMoistureManager:decodePeriodMarker(marker)
    marker = math.floor(tonumber(marker) or 0)
    if marker <= 0 then return nil end
    local current = self:getPeriodSerial()
    local modulo = (marker - 1) % 255
    return current - ((current - modulo) % 255)
end

local function getCropWaterWeights(fruitTypeIndex)
    local name = ""
    if fruitTypeIndex ~= nil and g_fruitTypeManager ~= nil
        and g_fruitTypeManager.getFruitTypeByIndex ~= nil then
        local desc = g_fruitTypeManager:getFruitTypeByIndex(fruitTypeIndex)
        name = string.lower(tostring(desc ~= nil
            and (desc.name or desc.title) or ""))
    end
    local weights, sensitivity = {0.34, 0.33, 0.33}, 1.0
    if string.find(name, "maize", 1, true) ~= nil
        or string.find(name, "corn", 1, true) ~= nil then
        weights, sensitivity = {0.20, 0.45, 0.35}, 1.10
    elseif string.find(name, "potato", 1, true) ~= nil
        or string.find(name, "beet", 1, true) ~= nil
        or string.find(name, "carrot", 1, true) ~= nil
        or string.find(name, "parsnip", 1, true) ~= nil then
        weights, sensitivity = {0.20, 0.30, 0.50}, 1.05
    elseif string.find(name, "grass", 1, true) ~= nil then
        weights, sensitivity = {0.34, 0.33, 0.33}, 0.85
    elseif string.find(name, "spinach", 1, true) ~= nil
        or string.find(name, "pea", 1, true) ~= nil
        or string.find(name, "bean", 1, true) ~= nil then
        weights, sensitivity = {0.30, 0.40, 0.30}, 0.95
    end
    return weights, sensitivity
end

-- Returns the retained crop-yield share for one semantic growth window. The
-- daily two-layer water reserve is evaluated per texture, while the
-- conservative 8/5 percent caps keep uncontrollable weather subordinate to
-- field work, compaction and the player's agronomic decisions.
function TerraLogicSoilMoistureManager:getCropYieldResponseForRoot(
        masterRootMoisture, soilTypeIndex, fruitTypeIndex, stage,
        forceWeatherValid, surfaceMean, subsoilMean)
    local index = self:getProfileIndex(soilTypeIndex)
    local profile = self.PROFILES[index]
    local h = self.HYDRAULICS[index]
    local daily = self.auditOverrideActive and self.states[index]
        or self.dailyProfileMeans and self.dailyProfileMeans[index]
    local upper = surfaceMean or (daily and daily.surface) or profile.initialSurface
    local lower = subsoilMean or (daily and daily.subsoil) or masterRootMoisture or profile.initialSubsoil
    local name=''
    if g_fruitTypeManager ~= nil and g_fruitTypeManager.getFruitTypeByIndex ~= nil then
        local desc=g_fruitTypeManager:getFruitTypeByIndex(fruitTypeIndex)
        name=string.lower(tostring(desc and (desc.name or desc.title) or ''))
    end
    -- FAO-56 depletion fractions. Roots below 60 cm are outside this model;
    -- cap the effective depth rather than inventing an unobserved third layer.
    local rootDepth,p=.60,.50
    if string.find(name,'potato',1,true) then rootDepth,p=.45,.35
    elseif string.find(name,'grass',1,true) then rootDepth,p=.60,.40
    elseif string.find(name,'maize',1,true) or string.find(name,'corn',1,true)
        or string.find(name,'wheat',1,true) or string.find(name,'barley',1,true)
        or string.find(name,'beet',1,true) then p=.55 end
    if TerraLogicCropWaterProfiles then
        local crop=TerraLogicCropWaterProfiles:get(fruitTypeIndex)
        rootDepth,p=math.min(.60,crop.depth),crop.depletion
    end
    local upperWeight=.15/rootDepth
    local rootMoisture=upper*upperWeight+lower*(1-upperWeight)
    stage = math.clamp(math.floor(tonumber(stage) or 1), 1, 3)
    local available = self:getAvailableWater(upper,index)*upperWeight
        + self:getAvailableWater(lower,index)*(1-upperWeight)
    local drySeverity = clamp01(((1-available)-p)/(1-p))
    local wetSeverity = smoothStep(h.saturation-.10,h.saturation-.02,upper)*upperWeight
        + smoothStep(h.saturation-.10,h.saturation-.02,lower)*(1-upperWeight)
    local relative = rootMoisture / h.fieldCapacity
    local weights, sensitivity = getCropWaterWeights(fruitTypeIndex)
    local dryLoss = 0.08 * sensitivity * drySeverity
    local wetLoss = 0.05 * sensitivity * wetSeverity
    -- Flooded rice is adapted to a ponded root zone. Its irrigation supply
    -- comes from the actual rice-field water plane, never its crop name alone.
    if TerraLogicCropWaterProfiles and TerraLogicCropWaterProfiles:get(fruitTypeIndex).paddy then wetLoss=0 end
    local weatherFallback = forceWeatherValid ~= true
        and self.weatherDataValid ~= true
    return {
        factor=weatherFallback and 1
            or math.clamp(1 - dryLoss - wetLoss, 0.90, 1),
        stageWeight=weights[stage],
        surface=upper, subsoil=lower,
        availableWaterFraction=available, depletionFraction=1-available,
        rootDepthM=rootDepth, stressDepletionFraction=p,
        rootMoisture=rootMoisture, relativeToFieldCapacity=relative,
        drySeverity=drySeverity, wetSeverity=wetSeverity,
        profileIndex=index, profileName=profile.name,
        weatherFallback=weatherFallback
    }
end

function TerraLogicSoilMoistureManager:getCropYieldResponse(
        soilTypeIndex, fruitTypeIndex, stage, x, z)
    if x and z and TerraLogicFieldWaterManager and not self.auditOverrideActive then
        local response=TerraLogicFieldWaterManager:getYieldResponse(x,z,self:getProfileIndex(soilTypeIndex),fruitTypeIndex,stage)
        if response then return response end
    end
    return self:getCropYieldResponseForRoot(
        self.rootMoisture, soilTypeIndex, fruitTypeIndex, stage)
end

-- Average every calendar period belonging to the completed growth window.
-- Days-per-period never become an additional yield weight. Long crops see
-- more weather periods, but identical weather produces the same mean.
function TerraLogicSoilMoistureManager:getCropYieldResponseForPeriodRange(
        startSerial, endSerial, soilTypeIndex, fruitTypeIndex, stage, x, z)
    if x and z and TerraLogicFieldWaterManager and not self.auditOverrideActive then
        local response,count=TerraLogicFieldWaterManager:getYieldResponse(x,z,self:getProfileIndex(soilTypeIndex),fruitTypeIndex,stage,startSerial,endSerial)
        if response then return response,count end
    end
    startSerial, endSerial = tonumber(startSerial), tonumber(endSerial)
    if startSerial == nil or endSerial == nil or endSerial <= startSerial then
        return self:getCropYieldResponse(
            soilTypeIndex, fruitTypeIndex, stage), 0
    end
    local factorSum, rootSum, count = 0, 0, 0
    local representative = nil
    for _, snapshot in ipairs(self.periodHistory or {}) do
        local serial = tonumber(snapshot.serial) or 0
        if serial > startSerial and serial <= endSerial
            and snapshot.weatherValid ~= false then
            local response = self:getCropYieldResponseForRoot(
                snapshot.rootMean, soilTypeIndex, fruitTypeIndex, stage, true,
                snapshot['soil'..self:getProfileIndex(soilTypeIndex)..'UpperMean'],
                snapshot['soil'..self:getProfileIndex(soilTypeIndex)..'LowerMean'])
            representative = response
            factorSum = factorSum + response.factor
            rootSum = rootSum + (tonumber(snapshot.rootMean) or 0.54)
            count = count + 1
        end
    end
    if count <= 0 then
        return self:getCropYieldResponse(
            soilTypeIndex, fruitTypeIndex, stage), 0
    end
    representative.factor = factorSum / count
    representative.historyRootMean = rootSum / count
    representative.historyPeriods = count
    return representative, count
end

function TerraLogicSoilMoistureManager:getState()
    local profiles = {}
    for _, index in ipairs(self.PROFILE_ORDER) do
        local surface, subsoil, _, profile = self:getProfileState(index)
        profiles[index] = {name=profile.name, surface=surface, subsoil=subsoil}
    end
    local accumulator = self.periodAccumulator or newPeriodAccumulator()
    local snapshot = self.lastPeriodSnapshot or {}
    return {initialized=self.initialized == true, profiles=profiles,
        auditOverrideActive=self.auditOverrideActive == true,
        auditOverridePreset=self.auditOverridePreset,
        rainScale=tonumber(self.rainScale) or 0,
        groundWetness=tonumber(self.groundWetness) or 0,
        liquidGroundWetness=(tonumber(self.groundWetness) or 0)
            * (tonumber(self.liquidPrecipitationFactor) or 0),
        liquidPrecipitationFactor=tonumber(self.liquidPrecipitationFactor) or 0,
        evaporationFactor=tonumber(self.evaporationFactor) or 0,
        calendarScale=tonumber(self.calendarScale) or 1,
        surfaceWetness=tonumber(self.surfaceWetness) or 0,
        rootMoisture=tonumber(self.rootMoisture) or 0,
        climateMoistureTarget=tonumber(self.climateMoistureTarget) or 0,
        periodSerial=self:getPeriodSerial(),
        historyCount=#(self.periodHistory or {}),
        periodObservedHours=tonumber(accumulator.hours) or 0,
        periodRainHours=tonumber(accumulator.rainHours) or 0,
        periodLiquidRainHours=tonumber(accumulator.liquidRainHours) or 0,
        lastRainHoursPerDay=tonumber(snapshot.rainHoursPerDay) or 0,
        lastRootMean=tonumber(snapshot.rootMean) or 0,
        lastSurfaceMean=tonumber(snapshot.surfaceMean) or 0,
        lastObservationShare=tonumber(snapshot.observationShare) or 0,
        lastValidWeatherShare=tonumber(snapshot.validWeatherShare) or 0,
        weatherDataValid=self.weatherDataValid == true,
        droppedGameHours=tonumber(self.droppedGameHours) or 0,
        simulatedGameHours=tonumber(self.simulatedGameHours) or 0,
        modelName="volumetricTwoLayerDailyCrop",
        moistureUnit="m3/m3",
        loadedFromSave=self.loadedFromSave == true,
        gameplayEffectsActive=true,
        weatherSource=self.weatherSource or "unknown",
        surfaceDepthCm=self.SURFACE_DEPTH_CM,
        subsoilDepthCm=self.SUBSOIL_DEPTH_CM}
end

-- Runtime-only deterministic environments for repeatable developer tests.
-- They are never saved and ordinary gameplay never activates them.
function TerraLogicSoilMoistureManager:setAuditPreset(presetName)
    if g_server == nil or self.initialized ~= true then
        return false, "moisture manager unavailable"
    end
    local name = string.lower(tostring(presetName or ""))
    if name == "natural" or name == "off" then
        local snapshot = self.auditOverrideSnapshot
        if snapshot ~= nil then
            self.surfaceWetness = snapshot.surfaceWetness
            self.rootMoisture = snapshot.rootMoisture
            self.climateMoistureTarget = snapshot.climateMoistureTarget
            self.rainScale = snapshot.rainScale
            self.groundWetness = snapshot.groundWetness
            self.liquidPrecipitationFactor = snapshot.liquidFactor
            self.evaporationFactor = snapshot.evaporationFactor
            self:refreshDerivedStates()
        end
        self.auditOverrideActive = false
        self.auditOverridePreset = nil
        self.auditOverrideSnapshot = nil
        self:sendState(nil)
        return true, "natural moisture simulation restored"
    end
    local preset = AUDIT_MOISTURE_PRESETS[name]
    if preset == nil then return false, "unknown moisture preset" end
    if self.auditOverrideSnapshot == nil then
        self.auditOverrideSnapshot = {
            surfaceWetness=self.surfaceWetness,
            rootMoisture=self.rootMoisture,
            climateMoistureTarget=self.climateMoistureTarget,
            rainScale=self.rainScale,
            groundWetness=self.groundWetness,
            liquidFactor=self.liquidPrecipitationFactor,
            evaporationFactor=self.evaporationFactor
        }
    end
    self.surfaceWetness = self:legacyToVolume(preset.surface,0,false)
    self.rootMoisture = self:legacyToVolume(preset.subsoil,0,true)
    self.climateMoistureTarget = self.rootMoisture
    self.rainScale = name == "wet" and 1 or 0
    self.groundWetness = preset.surface
    self.liquidPrecipitationFactor = name == "frozen" and 0 or 1
    self.evaporationFactor = 1
    self:refreshDerivedStates()
    -- Audit inputs retain their old semantic bucket scale, then convert each
    -- texture to physical water content before entering ordinary mechanics.
    for _, index in ipairs(self.PROFILE_ORDER) do
        self.states[index].surface = self:legacyToVolume(preset.surface,index,false)
        self.states[index].subsoil = self:legacyToVolume(preset.subsoil,index,true)
    end
    self.auditOverrideActive = true
    self.auditOverridePreset = name
    self:sendState(nil)
    return true, string.format("%s moisture: %.0f/%.0f%%",
        name, preset.surface*100, preset.subsoil*100)
end

function TerraLogicSoilMoistureManager:applyNetworkState(values, rainScale,
        groundWetness, liquidFactor, evaporationFactor, calendarScale, rootMoisture, weatherValid)
    self.states = self.states or {}
    self.dailyProfileMeans = self.dailyProfileMeans or {}
    for position, index in ipairs(self.PROFILE_ORDER) do
        self.states[index] = {surface=clamp01(values[position * 2 - 1]),
            subsoil=clamp01(values[position * 2]),msWaterSource=values[20+position] or 0}
        self.dailyProfileMeans[index] = {
            surface=clamp01(values[10+position*2-1] or self.states[index].surface),
            subsoil=clamp01(values[10+position*2] or self.states[index].subsoil)}
    end
    local standard = self.states[0]
    self.surfaceWetness = standard ~= nil and standard.surface or 0.45
    self.rootMoisture = clamp01(rootMoisture or 0.54)
    self.climateMoistureTarget = self.rootMoisture
    self.rainScale = clamp01(rainScale)
    self.groundWetness = clamp01(groundWetness)
    self.liquidPrecipitationFactor = clamp01(liquidFactor)
    self.evaporationFactor = math.max(tonumber(evaporationFactor) or 0, 0)
    self.calendarScale = math.max(tonumber(calendarScale) or 1, 1)
    self.weatherSource = "server synchronization"
    self.weatherDataValid = weatherValid == true
    self.loadedFromSave = true
    self.initialized = true
end

function TerraLogicSoilMoistureManager:sendState(connection)
    if g_server == nil or self.initialized ~= true then return end
    local values, snapshot = {}, {}
    for _, index in ipairs(self.PROFILE_ORDER) do
        values[#values + 1] = self.states[index].surface
        values[#values + 1] = self.states[index].subsoil
        snapshot[index] = {surface=self.states[index].surface,
            subsoil=self.states[index].subsoil}
    end
    for _, index in ipairs(self.PROFILE_ORDER) do
        local d=self.dailyProfileMeans[index] or self.states[index]
        values[#values+1]=d.surface;values[#values+1]=d.subsoil
    end
    for _,index in ipairs(self.PROFILE_ORDER)do
        values[#values+1]=self.waterStores and self.waterStores[index]
            and self.waterStores[index].msWaterSource or 0
    end
    local event = TerraLogicSoilMoistureSyncEvent.new(values,
        self.rainScale, self.groundWetness,
        self.liquidPrecipitationFactor, self.evaporationFactor,
        self.calendarScale, self.rootMoisture, self.weatherDataValid)
    if connection ~= nil then connection:sendEvent(event)
    else g_server:broadcastEvent(event) end
    self.lastSyncValues = snapshot
    self.syncKeepaliveMs = 0
end

function TerraLogicSoilMoistureManager:delete(saveFirst)
    if saveFirst == true then self:save() end
    if g_messageCenter ~= nil then g_messageCenter:unsubscribeAll(self) end
    self.initialized = false
    self.states = nil
    self.waterStores = nil
    self.snowWaterMm, self.snowInitialized, self.observedSnowHeight = nil, nil, nil
    self.dayAccumulator = nil
    self.dailyProfileMeans = nil
    self.surfaceWetness = nil
    self.rootMoisture = nil
    self.climateMoistureTarget = nil
    self.periodAccumulator = nil
    self.periodHistory = nil
    self.lastPeriodSnapshot = nil
    self.lastSyncValues = nil
    self.syncTimerMs = nil
    self.syncKeepaliveMs = nil
    self.auditOverrideActive = nil
    self.auditOverridePreset = nil
    self.auditOverrideSnapshot = nil
end

-- Multiplayer synchronization ----------------------------------------------

TerraLogicSoilMoistureSyncEvent = {}
local TerraLogicSoilMoistureSyncEvent_mt = Class(
    TerraLogicSoilMoistureSyncEvent, Event)
InitEventClass(TerraLogicSoilMoistureSyncEvent,
    "TerraLogicSoilMoistureSyncEvent")

function TerraLogicSoilMoistureSyncEvent.emptyNew()
    return Event.new(TerraLogicSoilMoistureSyncEvent_mt)
end

function TerraLogicSoilMoistureSyncEvent.new(values, rainScale,
        groundWetness, liquidFactor, evaporationFactor, calendarScale, rootMoisture, weatherValid)
    local self = TerraLogicSoilMoistureSyncEvent.emptyNew()
    self.values, self.rainScale = values, rainScale
    self.groundWetness, self.liquidFactor = groundWetness, liquidFactor
    self.evaporationFactor, self.calendarScale =
        evaporationFactor, calendarScale
    self.rootMoisture, self.weatherValid = rootMoisture, weatherValid
    return self
end

function TerraLogicSoilMoistureSyncEvent:readStream(streamId, connection)
    self.values = {}
    for index=1,20 do self.values[index] = streamReadFloat32(streamId) end
    for index=21,25 do self.values[index]=streamReadUIntN(streamId,2)end
    self.rainScale = streamReadFloat32(streamId)
    self.groundWetness = streamReadFloat32(streamId)
    self.liquidFactor = streamReadFloat32(streamId)
    self.evaporationFactor = streamReadFloat32(streamId)
    self.calendarScale = streamReadFloat32(streamId)
    self.rootMoisture = streamReadFloat32(streamId)
    self.weatherValid = streamReadBool(streamId)
    self:run(connection)
end

function TerraLogicSoilMoistureSyncEvent:writeStream(streamId, connection)
    for index=1,20 do streamWriteFloat32(streamId, self.values[index]) end
    for index=21,25 do streamWriteUIntN(streamId,self.values[index] or 0,2)end
    streamWriteFloat32(streamId, self.rainScale)
    streamWriteFloat32(streamId, self.groundWetness)
    streamWriteFloat32(streamId, self.liquidFactor)
    streamWriteFloat32(streamId, self.evaporationFactor)
    streamWriteFloat32(streamId, self.calendarScale)
    streamWriteFloat32(streamId, self.rootMoisture)
    streamWriteBool(streamId, self.weatherValid)
end

function TerraLogicSoilMoistureSyncEvent:run(connection)
    if not connection:getIsServer() then return end
    TerraLogicSoilMoistureManager:applyNetworkState(self.values,
        self.rainScale, self.groundWetness, self.liquidFactor,
        self.evaporationFactor, self.calendarScale, self.rootMoisture, self.weatherValid)
end

if FSBaseMission ~= nil and FSBaseMission.sendInitialClientState ~= nil
    and FSBaseMission.terraLogicSoilMoistureSyncHookInstalled ~= true then
    FSBaseMission.terraLogicSoilMoistureSyncHookInstalled = true
    FSBaseMission.sendInitialClientState = Utils.appendedFunction(
        FSBaseMission.sendInitialClientState,
        function(_, connection)
            if g_server ~= nil
                and TerraLogicSoilMoistureManager.initialized == true then
                TerraLogicSoilMoistureManager:sendState(connection)
            end
        end)
end
