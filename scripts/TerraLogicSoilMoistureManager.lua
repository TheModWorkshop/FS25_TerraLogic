--[[
    TerraLogicSoilMoistureManager.lua

    Server-authoritative robust two-timescale model. Fast surface wetness drives
    traffic and implements; slow root-zone moisture drives crop yield and soil
    biology. Rain is treated as a relative weather signal, not fictitious mm.
    PF textures transform the two global states instead of maintaining five
    divergent water balances. This remains stable without PF and on custom
    weather XMLs while preserving deliberately arid or wet map climates.
]]

TerraLogicSoilMoistureManager = {
    SOURCE_FINGERPRINT = 1.200230,
    SAVE_FILE = "terraLogicSoilMoisture.xml",
    SAVE_VERSION = 2,

    SURFACE_DEPTH_CM = 15,
    SUBSOIL_DEPTH_CM = 60,
    MAX_GAME_HOURS_PER_UPDATE = 24,
    MAX_STEP_HOURS = 0.25,
    SYNC_INTERVAL_MS = 5000,
    SYNC_CHANGE_THRESHOLD = 0.002,
    SYNC_KEEPALIVE_MS = 60000,
    HISTORY_LENGTH = 48,
    SURFACE_WETTING_RATE = 1.10,
    SURFACE_DRY_HALF_LIFE_HOURS = 10,
    SURFACE_DRY_FLOOR = 0.04,
    REFERENCE_RAIN_HOURS_PER_DAY = 0.12,
    CLIMATE_TARGET_PERIOD_BLEND = 0.35,
    ROOT_PERIOD_RESPONSE = 0.24,
    ROOT_MAX_DRYING_PER_PERIOD = 0.065,
    ROOT_MAX_WETTING_PER_PERIOD = 0.10,
    MIN_PERIOD_OBSERVATION_SHARE = 0.50,
    MIN_VALID_WEATHER_SHARE = 0.80,

    -- One global weather state is transformed into texture-specific effective
    -- values. PF therefore changes soil response without maintaining five
    -- divergent and map-weather-sensitive water balances.
    PROFILE_ORDER = {0, 1, 2, 3, 4},
    PROFILES = {
        [0] = {name="Generic", initialSurface=0.46, initialSubsoil=0.54,
            fieldCapacitySurface=0.62, fieldCapacitySubsoil=0.68,
            wetOnset=0.70,
            wetDraftTexture=1.00, surfaceResponse=1.00, rootResponse=1.00},
        [1] = {name="Loamy Sand", initialSurface=0.39, initialSubsoil=0.45,
            fieldCapacitySurface=0.48, fieldCapacitySubsoil=0.54,
            wetOnset=0.75,
            wetDraftTexture=0.82, surfaceResponse=0.82, rootResponse=0.84},
        [2] = {name="Sandy Loam", initialSurface=0.45, initialSubsoil=0.52,
            fieldCapacitySurface=0.58, fieldCapacitySubsoil=0.63,
            wetOnset=0.72,
            wetDraftTexture=1.00, surfaceResponse=1.00, rootResponse=1.00},
        [3] = {name="Loam", initialSurface=0.51, initialSubsoil=0.59,
            fieldCapacitySurface=0.68, fieldCapacitySubsoil=0.73,
            wetOnset=0.68,
            wetDraftTexture=1.14, surfaceResponse=1.08, rootResponse=1.10},
        [4] = {name="Silty Clay", initialSurface=0.57, initialSubsoil=0.65,
            fieldCapacitySurface=0.76, fieldCapacitySubsoil=0.81,
            wetOnset=0.64,
            wetDraftTexture=1.28, surfaceResponse=1.16, rootResponse=1.18}
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
        surfaceMoisture, texture,
        temperature ~= nil and temperature.SURFACE_REFERENCE_FROZEN_HOURS or 36)
    local subsoilSeverity = getFrozenLayerSeverity(
        temperature ~= nil and temperature.subsoilFrozen == true,
        temperature ~= nil and temperature.subsoilTemperatureC or 10,
        temperature ~= nil and temperature.subsoilFrozenHours or 0,
        subsoilMoisture, texture,
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
        self.states[index].surface = clamp01(
            surface * (profile.surfaceResponse or 1))
        self.states[index].subsoil = clamp01(
            root * (profile.rootResponse or 1))
    end
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
    self.surfaceWetness = clamp01(0.42 + groundWetness * 0.35)
    self.rootMoisture = 0.54
    self.climateMoistureTarget = self.rootMoisture
    self.periodAccumulator = newPeriodAccumulator()
    self.periodHistory = {}
    self.periodSerial = 0
    self.lastPeriodSnapshot = nil
    self.rainScale = 0
    self.groundWetness = groundWetness
    self.liquidPrecipitationFactor = 1
    self.evaporationFactor = 1
    self.calendarScale = 1
    self.weatherSource = source
    self.weatherDataValid = weatherValid == true
    self.loadedFromSave = false
    self.migratedFromBucketModel = false
    self.simulatedGameHours = 0
    self.initialized = true
    self.syncTimerMs = 0
    self.syncKeepaliveMs = 0
    self.lastSyncValues = nil

    local mission = g_currentMission
    if mission ~= nil and mission:getIsServer() then
        local path = getSavePath()
        if path ~= nil and fileExists(path) then
            local xml = loadXMLFile("terraLogicSoilMoisture", path)
            if xml ~= nil and xml ~= 0 then
                local version = tonumber(getXMLInt(
                    xml, "soilMoisture#version")) or 1
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
                self.loadedFromSave = true
                delete(xml)
            end
        end
    end
    self:refreshDerivedStates()
    if g_messageCenter ~= nil and MessageType ~= nil
        and MessageType.PERIOD_CHANGED ~= nil then
        g_messageCenter:subscribe(MessageType.PERIOD_CHANGED,
            self.onPeriodChanged, self)
    end
    TerraLogicLogging.debug(
        "[FS25_TerraLogic] Robust moisture loaded: surface/root %.1f/%.1f%%, PF responses=%d, history=%d, source=%s (%s%s)",
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
    if valid then
        local rainSaturation = 1 - math.exp(-rainPerDay
            / self.REFERENCE_RAIN_HOURS_PER_DAY)
        local observedTarget = 0.18 + 0.68 * rainSaturation
        local meanTemperature = hours > 0
            and (accumulator.temperatureSum or 0) / hours or 12
        local heatStress = smoothStep(24, 36, meanTemperature)
        observedTarget = math.clamp(
            observedTarget - 0.10 * heatStress, 0.16, 0.86)
        -- Rain is normalized per observed day, but every calendar period has
        -- the same slow-memory weight. The player's days-per-period setting
        -- therefore improves sampling density without becoming a yield rate.
        -- No neutral rainfall is invented: repeated valid dry periods still
        -- converge to the deliberately arid target selected by the map.
        local reliability = self.CLIMATE_TARGET_PERIOD_BLEND
        self.climateMoistureTarget = clamp01(
            self.climateMoistureTarget * (1 - reliability)
                + observedTarget * reliability)
        local requested = (self.climateMoistureTarget - previousRoot)
            * self.ROOT_PERIOD_RESPONSE
        requested = math.clamp(requested,
            -self.ROOT_MAX_DRYING_PER_PERIOD,
            self.ROOT_MAX_WETTING_PER_PERIOD)
        self.rootMoisture = clamp01(previousRoot + requested)
    end
    self.periodSerial = (tonumber(self.periodSerial) or 0) + 1
    local snapshot = {
        serial=self.periodSerial,
        rootMean=(previousRoot + self.rootMoisture) * 0.5,
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
    self:addHistorySnapshot(snapshot)
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
    local liquidFactor = smoothStep(-0.5, 1.5,
        math.min(air, surfaceTemperature + 1.0))
    local liquidRain = weatherValid and rain * liquidFactor or 0
    self.liquidPrecipitationFactor = liquidFactor
    local temperatureFactor = math.clamp((air + 5) / 25, 0.20, 1.60)
    local atmosphericDryness = 0.30 + 0.70 * (1 - groundWetness)
    self.evaporationFactor = temperatureFactor * atmosphericDryness

    if gameHours > 0 then
        if not weatherValid then
            local retention = 2 ^ (-gameHours / 48)
            self.surfaceWetness = 0.45
                + (self.surfaceWetness - 0.45) * retention
        elseif liquidRain > 0 then
            local wetting = 1 - math.exp(
                -self.SURFACE_WETTING_RATE * liquidRain * gameHours)
            self.surfaceWetness = clamp01(self.surfaceWetness
                + (1 - self.surfaceWetness) * wetting)
        else
            local halfLife = self.SURFACE_DRY_HALF_LIFE_HOURS
                / math.max(self.evaporationFactor, 0.25)
            local retention = 2 ^ (-gameHours / halfLife)
            self.surfaceWetness = self.SURFACE_DRY_FLOOR
                + (self.surfaceWetness - self.SURFACE_DRY_FLOOR) * retention
        end
        if weatherValid then
            -- Vanilla ground wetness also rises under snow. Only its liquid
            -- share may establish a wet-soil floor; frozen precipitation is
            -- retained by the weather system and becomes available naturally
            -- when the temperature-derived liquid factor rises during thaw.
            self.surfaceWetness = math.max(
                self.surfaceWetness,
                groundWetness * 0.85 * liquidFactor)
        end
        self.surfaceWetness = clamp01(self.surfaceWetness)

        local accumulator = self.periodAccumulator
            or newPeriodAccumulator()
        self.periodAccumulator = accumulator
        accumulator.hours = accumulator.hours + gameHours
        accumulator.rootSum = accumulator.rootSum
            + self.rootMoisture * gameHours
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

function TerraLogicSoilMoistureManager:getProfileState(soilTypeIndex)
    local index = self:getProfileIndex(soilTypeIndex)
    local state = self.states ~= nil and self.states[index] or nil
    local profile = self.PROFILES[index]
    if state == nil then
        return profile.initialSurface, profile.initialSubsoil, index, profile
    end
    return clamp01(state.surface), clamp01(state.subsoil), index, profile
end

function TerraLogicSoilMoistureManager:getStateAtWorldPosition(x, z)
    local soilTypeIndex = TerraLogicSoilManager ~= nil
        and TerraLogicSoilManager.getPFSoilTypeAtWorldPosition ~= nil
        and TerraLogicSoilManager:getPFSoilTypeAtWorldPosition(x, z) or nil
    local surface, subsoil, index, profile =
        self:getProfileState(soilTypeIndex)
    -- Read the synchronized manager fields directly. These queries run for
    -- many WorkArea cells, so allocating a complete temperature-state table
    -- per cell would be needless CPU and garbage-collector pressure.
    local surfaceFrozen = TerraLogicSoilTemperatureManager ~= nil
        and TerraLogicSoilTemperatureManager.surfaceFrozen == true
    local subsoilFrozen = TerraLogicSoilTemperatureManager ~= nil
        and TerraLogicSoilTemperatureManager.subsoilFrozen == true
    return {surface=surface, subsoil=subsoil, profileIndex=index,
        profileName=profile.name, pfActive=index > 0,
        liquidSurface=surfaceFrozen and 0 or surface,
        liquidSubsoil=subsoilFrozen and 0 or subsoil,
        surfaceFrozen=surfaceFrozen, subsoilFrozen=subsoilFrozen}
end

function TerraLogicSoilMoistureManager:getMechanicalResponse(
        soilTypeIndex, classKey, workDepthCm)
    local surface, subsoil, index, profile =
        self:getProfileState(soilTypeIndex)
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
    local drySurface = surfaceFrozen and math.max(surface, 0.32) or surface
    local drySubsoil = subsoilFrozen and math.max(subsoil, 0.32) or subsoil
    local liquidEffective = liquidSurface * (1 - deepWeight)
        + liquidSubsoil * deepWeight
    local dryEffective = drySurface * (1 - deepWeight)
        + drySubsoil * deepWeight
    local drySeverity = 1 - smoothStep(0.10, 0.32, dryEffective)
    local wetSeverity = smoothStep(
        profile.wetOnset, 0.96, liquidEffective)
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

function TerraLogicSoilMoistureManager:getTrafficMultipliers(soilTypeIndex)
    local surface, subsoil, index, profile =
        self:getProfileState(soilTypeIndex)
    local surfaceFrozen = TerraLogicSoilTemperatureManager ~= nil
        and TerraLogicSoilTemperatureManager.surfaceFrozen == true
    local subsoilFrozen = TerraLogicSoilTemperatureManager ~= nil
        and TerraLogicSoilTemperatureManager.subsoilFrozen == true
    local function response(value, wetOnset, frozen)
        if frozen then return 1 end
        local dry = 1 - smoothStep(0.10, 0.32, value)
        local wet = smoothStep(wetOnset - 0.06, 0.94, value)
        local multiplier = math.clamp(1 - 0.25 * dry
            + 0.48 * wet * (profile.wetDraftTexture or 1), 0.72, 1.58)
        -- Halve only the extra wet-soil traffic response. Keep the neutral
        -- point, dry protection and frost handling unchanged. The soil map's
        -- target adjustment uses this same multiplier (and its original .58
        -- reference range), so wet target shifts are reduced equally.
        return multiplier > 1 and 1 + (multiplier - 1) * 0.5 or multiplier
    end
    return response(surface, profile.wetOnset, surfaceFrozen),
        response(subsoil, math.min(profile.wetOnset + 0.04, 0.82),
            subsoilFrozen), index
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
-- global slow root state is transformed by texture, while the intentionally
-- conservative 8/5 percent caps keep uncontrollable weather subordinate to
-- field work, compaction and the player's agronomic decisions.
function TerraLogicSoilMoistureManager:getCropYieldResponseForRoot(
        masterRootMoisture, soilTypeIndex, fruitTypeIndex, stage,
        forceWeatherValid)
    local index = self:getProfileIndex(soilTypeIndex)
    local profile = self.PROFILES[index]
    local rootMoisture = clamp01((tonumber(masterRootMoisture)
        or self.rootMoisture or 0.54) * (profile.rootResponse or 1))
    stage = math.clamp(math.floor(tonumber(stage) or 1), 1, 3)
    local fieldCapacity = profile.fieldCapacitySubsoil
    local relative = rootMoisture / math.max(fieldCapacity, 0.05)
    local drySeverity = 1 - smoothStep(0.32, 0.70, relative)
    local wetSeverity = smoothStep(
        math.min((profile.wetOnset or 0.70) + 0.05, 0.84),
        0.97, rootMoisture)
    local weights, sensitivity = getCropWaterWeights(fruitTypeIndex)
    local dryLoss = 0.08 * sensitivity * drySeverity
    local wetLoss = 0.05 * sensitivity * wetSeverity
    local weatherFallback = forceWeatherValid ~= true
        and self.weatherDataValid ~= true
    return {
        factor=weatherFallback and 1
            or math.clamp(1 - dryLoss - wetLoss, 0.90, 1),
        stageWeight=weights[stage],
        surface=self.states ~= nil and self.states[index] ~= nil
            and self.states[index].surface or self.surfaceWetness,
        subsoil=rootMoisture,
        rootMoisture=rootMoisture, relativeToFieldCapacity=relative,
        drySeverity=drySeverity, wetSeverity=wetSeverity,
        profileIndex=index, profileName=profile.name,
        weatherFallback=weatherFallback
    }
end

function TerraLogicSoilMoistureManager:getCropYieldResponse(
        soilTypeIndex, fruitTypeIndex, stage)
    return self:getCropYieldResponseForRoot(
        self.rootMoisture, soilTypeIndex, fruitTypeIndex, stage)
end

-- Average every calendar period belonging to the completed growth window.
-- Days-per-period never become an additional yield weight. Long crops see
-- more weather periods, but identical weather produces the same mean.
function TerraLogicSoilMoistureManager:getCropYieldResponseForPeriodRange(
        startSerial, endSerial, soilTypeIndex, fruitTypeIndex, stage)
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
                snapshot.rootMean, soilTypeIndex, fruitTypeIndex, stage, true)
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
        modelName="robustTwoTimescale",
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
    self.surfaceWetness = preset.surface
    self.rootMoisture = preset.subsoil
    self.climateMoistureTarget = preset.subsoil
    self.rainScale = name == "wet" and 1 or 0
    self.groundWetness = preset.surface
    self.liquidPrecipitationFactor = name == "frozen" and 0 or 1
    self.evaporationFactor = 1
    self:refreshDerivedStates()
    -- Keep identical normalized moisture in every PF profile. Texture still
    -- changes bearing response through its own wet onset and soil multipliers.
    for _, index in ipairs(self.PROFILE_ORDER) do
        self.states[index].surface = preset.surface
        self.states[index].subsoil = preset.subsoil
    end
    self.auditOverrideActive = true
    self.auditOverridePreset = name
    self:sendState(nil)
    return true, string.format("%s moisture: %.0f/%.0f%%",
        name, preset.surface*100, preset.subsoil*100)
end

function TerraLogicSoilMoistureManager:applyNetworkState(values, rainScale,
        groundWetness, liquidFactor, evaporationFactor, calendarScale)
    self.states = self.states or {}
    for position, index in ipairs(self.PROFILE_ORDER) do
        self.states[index] = {surface=clamp01(values[position * 2 - 1]),
            subsoil=clamp01(values[position * 2])}
    end
    local standard = self.states[2] or self.states[0]
    self.surfaceWetness = standard ~= nil and standard.surface or 0.45
    self.rootMoisture = standard ~= nil and standard.subsoil or 0.54
    self.climateMoistureTarget = self.rootMoisture
    self.rainScale = clamp01(rainScale)
    self.groundWetness = clamp01(groundWetness)
    self.liquidPrecipitationFactor = clamp01(liquidFactor)
    self.evaporationFactor = math.max(tonumber(evaporationFactor) or 0, 0)
    self.calendarScale = math.max(tonumber(calendarScale) or 1, 1)
    self.weatherSource = "server synchronization"
    self.weatherDataValid = true
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
    local event = TerraLogicSoilMoistureSyncEvent.new(values,
        self.rainScale, self.groundWetness,
        self.liquidPrecipitationFactor, self.evaporationFactor,
        self.calendarScale)
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
        groundWetness, liquidFactor, evaporationFactor, calendarScale)
    local self = TerraLogicSoilMoistureSyncEvent.emptyNew()
    self.values, self.rainScale = values, rainScale
    self.groundWetness, self.liquidFactor = groundWetness, liquidFactor
    self.evaporationFactor, self.calendarScale =
        evaporationFactor, calendarScale
    return self
end

function TerraLogicSoilMoistureSyncEvent:readStream(streamId, connection)
    self.values = {}
    for index=1,10 do self.values[index] = streamReadFloat32(streamId) end
    self.rainScale = streamReadFloat32(streamId)
    self.groundWetness = streamReadFloat32(streamId)
    self.liquidFactor = streamReadFloat32(streamId)
    self.evaporationFactor = streamReadFloat32(streamId)
    self.calendarScale = streamReadFloat32(streamId)
    self:run(connection)
end

function TerraLogicSoilMoistureSyncEvent:writeStream(streamId, connection)
    for index=1,10 do streamWriteFloat32(streamId, self.values[index]) end
    streamWriteFloat32(streamId, self.rainScale)
    streamWriteFloat32(streamId, self.groundWetness)
    streamWriteFloat32(streamId, self.liquidFactor)
    streamWriteFloat32(streamId, self.evaporationFactor)
    streamWriteFloat32(streamId, self.calendarScale)
end

function TerraLogicSoilMoistureSyncEvent:run(connection)
    if not connection:getIsServer() then return end
    TerraLogicSoilMoistureManager:applyNetworkState(self.values,
        self.rainScale, self.groundWetness, self.liquidFactor,
        self.evaporationFactor, self.calendarScale)
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
