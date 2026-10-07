--[[
    TerraLogicSoilTemperatureManager.lua

    Server-authoritative, map-wide soil temperature and freeze/thaw model.
    Temperature drives moisture evaporation and natural recovery. Persistent
    hysteretic frost states turn sufficiently long cold periods into one-shot
    thaw pulses; merely remaining frozen never repeats the benefit.

    The upper value represents the thermally active seedbed near 10 cm.  Its
    eight-hour first-order response reproduces the approximate daily damping
    expected from the one-dimensional heat equation at a representative soil
    diffusivity of 0.5e-6 m2/s (daily damping depth about 11.7 cm).

    The lower value represents the 15-60 cm working/root zone near 35 cm.
    Daily oscillation there is small, so it follows a game-day mean boundary.
    A four-day response combined with the daily/climate filters produces about
    8.8 days of annual phase lag and 0.856 amplitude at that depth, closely
    matching conductive theory.  Slow seasonal transport is scaled by calendar
    compression; the upper daily response is not, preserving a realistic
    day/night cycle.
]]

TerraLogicSoilTemperatureManager = {
    SOURCE_FINGERPRINT = 1.200223,
    SAVE_FILE = "terraLogicSoilTemperature.xml",
    SAVE_VERSION = 2,

    SURFACE_DEPTH_CM = 10,
    SUBSOIL_DEPTH_CM = 35,
    SURFACE_TAU_HOURS = 8,
    DAILY_WINDOW_HOURS = 24,
    SUBSOIL_TAU_CLIMATE_DAYS = 4,
    CLIMATE_MEAN_TAU_DAYS = 120,
    SUBSOIL_SEASONAL_AMPLITUDE = 0.82,
    NOMINAL_DAYS_PER_PERIOD = 30,
    SPINUP_CLIMATE_DAYS = 30,

    SURFACE_FREEZE_ENTER_C = -0.50,
    SURFACE_THAW_EXIT_C = 0.75,
    SURFACE_MIN_FROZEN_HOURS = 6,
    SURFACE_REFERENCE_FROZEN_HOURS = 36,
    SURFACE_REFERENCE_COLD_C = 5.5,
    SUBSOIL_FREEZE_ENTER_C = -0.25,
    SUBSOIL_THAW_EXIT_C = 0.50,
    SUBSOIL_MIN_FROZEN_HOURS = 18,
    SUBSOIL_REFERENCE_FROZEN_HOURS = 120,
    SUBSOIL_REFERENCE_COLD_C = 3.75,
    MAX_PENDING_THAW_PULSE = 2,

    MIN_TEMPERATURE_C = -50,
    MAX_TEMPERATURE_C = 60,
    MAX_GAME_HOURS_PER_UPDATE = 24,
    SYNC_INTERVAL_MS = 5000,
    SYNC_TEMPERATURE_THRESHOLD_C = 0.05,
    SYNC_KEEPALIVE_MS = 60000
}

local AUDIT_TEMPERATURE_PRESETS = {
    dry={air=22, surface=20, subsoil=15, frozen=false},
    normal={air=15, surface=14, subsoil=12, frozen=false},
    wet={air=11, surface=11, subsoil=10, frozen=false},
    frozen={air=-7, surface=-5, subsoil=-2, frozen=true}
}

local function clampTemperature(value, fallback)
    value = tonumber(value)
    if value == nil or value ~= value or value == math.huge
        or value == -math.huge then
        value = tonumber(fallback) or 10
    end
    return math.max(
        TerraLogicSoilTemperatureManager.MIN_TEMPERATURE_C,
        math.min(value,
            TerraLogicSoilTemperatureManager.MAX_TEMPERATURE_C))
end

local function approachExponential(value, target, elapsedHours, tauHours)
    value = tonumber(value) or tonumber(target) or 0
    target = tonumber(target) or value
    elapsedHours = math.max(tonumber(elapsedHours) or 0, 0)
    tauHours = math.max(tonumber(tauHours) or 0, 0.0001)
    if elapsedHours <= 0 then return value end
    local fraction = 1 - math.exp(-elapsedHours / tauHours)
    return value + (target - value) * fraction
end

local function smoothStep01(value)
    value = math.max(0, math.min(tonumber(value) or 0, 1))
    return value * value * (3 - 2 * value)
end

local function getSavePath()
    local info = g_currentMission ~= nil
        and g_currentMission.missionInfo or nil
    local directory = info ~= nil and info.savegameDirectory or nil
    if directory == nil or directory == "" then return nil end
    return directory .. "/"
        .. TerraLogicSoilTemperatureManager.SAVE_FILE
end

function TerraLogicSoilTemperatureManager:getWeatherTemperature()
    local environment = g_currentMission ~= nil
        and g_currentMission.environment or nil
    local weather = environment ~= nil and environment.weather or nil
    if weather == nil or type(weather.getCurrentTemperature) ~= "function" then
        return nil, "weather API unavailable"
    end
    local ok, temperature = pcall(
        weather.getCurrentTemperature, weather)
    temperature = tonumber(temperature)
    if not ok or temperature == nil or temperature ~= temperature then
        return nil, "weather temperature invalid"
    end
    return clampTemperature(temperature, 10), "weather:getCurrentTemperature"
end

function TerraLogicSoilTemperatureManager:getDaysPerPeriod()
    local mission = g_currentMission
    local environment = mission ~= nil and mission.environment or nil
    if environment ~= nil
        and type(environment.getDaysPerPeriod) == "function" then
        local ok, value = pcall(
            environment.getDaysPerPeriod, environment)
        value = tonumber(value)
        if ok and value ~= nil and value > 0 then
            return value, "environment:getDaysPerPeriod"
        end
    end
    local value = environment ~= nil
        and tonumber(environment.daysPerPeriod) or nil
    if value ~= nil and value > 0 then
        return value, "environment.daysPerPeriod"
    end
    local info = mission ~= nil and mission.missionInfo or nil
    value = info ~= nil and tonumber(info.daysPerPeriod) or nil
    if value ~= nil and value > 0 then
        return value, "missionInfo.daysPerPeriod"
    end
    -- A missing calendar API is safer at real-time scale than an invented
    -- compression factor.  The diagnostic command exposes this fallback.
    return self.NOMINAL_DAYS_PER_PERIOD, "unavailable/no compression"
end

function TerraLogicSoilTemperatureManager:getEffectiveTimeScale()
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

function TerraLogicSoilTemperatureManager:load()
    self:delete(false)
    local airTemperature, source = self:getWeatherTemperature()
    airTemperature = airTemperature or 10
    self.airTemperatureC = airTemperature
    self.surfaceTemperatureC = airTemperature
    self.subsoilTemperatureC = airTemperature
    self.dailyMeanTemperatureC = airTemperature
    self.climateMeanTemperatureC = airTemperature
    self.dailyTemperatureWeightedSum = 0
    self.dailyTemperatureHours = 0
    self.spinupClimateDays = 0
    self.simulatedGameHours = 0
    self.surfaceFrozen = false
    self.subsoilFrozen = false
    self.surfaceFrozenHours = 0
    self.subsoilFrozenHours = 0
    self.surfaceFreezeMinimumC = airTemperature
    self.subsoilFreezeMinimumC = airTemperature
    self.pendingSurfaceThawPulse = 0
    self.pendingDeepThawPulse = 0
    self.surfaceFreezeThawCycles = 0
    self.deepFreezeThawCycles = 0
    self.loadedFromSave = false
    self.temperatureSource = source
    self.initialized = true
    self.syncTimerMs = 0
    self.syncKeepaliveMs = 0
    self.lastSyncSurfaceC = nil
    self.lastSyncSubsoilC = nil
    self.frostRevision = 0
    self.lastSyncFrostRevision = nil

    local mission = g_currentMission
    if mission ~= nil and mission:getIsServer() then
        local path = getSavePath()
        if path ~= nil and fileExists(path) then
            local xml = loadXMLFile("terraLogicSoilTemperature", path)
            if xml ~= nil and xml ~= 0 then
                local root = "soilTemperature"
                self.surfaceTemperatureC = clampTemperature(
                    getXMLFloat(xml, root .. "#surfaceC"), airTemperature)
                self.subsoilTemperatureC = clampTemperature(
                    getXMLFloat(xml, root .. "#subsoilC"),
                    self.surfaceTemperatureC)
                self.dailyMeanTemperatureC = clampTemperature(
                    getXMLFloat(xml, root .. "#dailyMeanC"),
                    self.surfaceTemperatureC)
                self.climateMeanTemperatureC = clampTemperature(
                    getXMLFloat(xml, root .. "#climateMeanC"),
                    self.subsoilTemperatureC)
                self.dailyTemperatureWeightedSum = tonumber(
                    getXMLFloat(xml, root .. "#dailyWeightedSum")) or 0
                self.dailyTemperatureHours = math.max(tonumber(
                    getXMLFloat(xml, root .. "#dailyHours")) or 0, 0)
                if self.dailyTemperatureHours >= self.DAILY_WINDOW_HOURS
                    or self.dailyTemperatureWeightedSum
                        ~= self.dailyTemperatureWeightedSum then
                    self.dailyTemperatureWeightedSum = 0
                    self.dailyTemperatureHours = 0
                end
                self.spinupClimateDays = math.max(tonumber(
                    getXMLFloat(xml, root .. "#spinupClimateDays")) or 0, 0)
                self.simulatedGameHours = math.max(tonumber(
                    getXMLFloat(xml, root .. "#simulatedGameHours")) or 0, 0)
                local version = tonumber(getXMLInt(xml, root .. "#version")) or 1
                if version >= 2 then
                    self.surfaceFrozen = (tonumber(getXMLInt(xml,
                        root .. "#surfaceFrozen")) or 0) == 1
                    self.subsoilFrozen = (tonumber(getXMLInt(xml,
                        root .. "#subsoilFrozen")) or 0) == 1
                    self.surfaceFrozenHours = math.max(tonumber(getXMLFloat(xml,
                        root .. "#surfaceFrozenHours")) or 0, 0)
                    self.subsoilFrozenHours = math.max(tonumber(getXMLFloat(xml,
                        root .. "#subsoilFrozenHours")) or 0, 0)
                    self.surfaceFreezeMinimumC = clampTemperature(getXMLFloat(xml,
                        root .. "#surfaceFreezeMinimumC"), self.surfaceTemperatureC)
                    self.subsoilFreezeMinimumC = clampTemperature(getXMLFloat(xml,
                        root .. "#subsoilFreezeMinimumC"), self.subsoilTemperatureC)
                    self.pendingSurfaceThawPulse = math.max(0, math.min(
                        tonumber(getXMLFloat(xml, root .. "#pendingSurfaceThawPulse")) or 0,
                        self.MAX_PENDING_THAW_PULSE))
                    self.pendingDeepThawPulse = math.max(0, math.min(
                        tonumber(getXMLFloat(xml, root .. "#pendingDeepThawPulse")) or 0,
                        self.MAX_PENDING_THAW_PULSE))
                    self.surfaceFreezeThawCycles = math.max(0, math.floor(
                        tonumber(getXMLFloat(xml, root .. "#surfaceFreezeThawCycles")) or 0))
                    self.deepFreezeThawCycles = math.max(0, math.floor(
                        tonumber(getXMLFloat(xml, root .. "#deepFreezeThawCycles")) or 0))
                else
                    -- Old saves have temperatures but no frost history. Start
                    -- a cold phase without inventing elapsed frost or a pulse.
                    self.surfaceFrozen = self.surfaceTemperatureC
                        <= self.SURFACE_FREEZE_ENTER_C
                    self.subsoilFrozen = self.subsoilTemperatureC
                        <= self.SUBSOIL_FREEZE_ENTER_C
                    self.surfaceFreezeMinimumC = self.surfaceTemperatureC
                    self.subsoilFreezeMinimumC = self.subsoilTemperatureC
                end
                self.loadedFromSave = true
                delete(xml)
            end
        end
    end

    self.daysPerPeriod, self.daysPerPeriodSource = self:getDaysPerPeriod()
    self.calendarScale = self.NOMINAL_DAYS_PER_PERIOD
        / math.max(self.daysPerPeriod, 1)
    self.calendarScale = math.max(1, math.min(self.calendarScale, 30))
    TerraLogicLogging.debug(
        "[FS25_TerraLogic] Soil temperature loaded: air=%.2f C surface@%dcm=%.2f C subsoil@%dcm=%.2f C frost=%s/%s pendingThaw=%.3f/%.3f calendar=%g days/period x%.2f (%s, %s)",
        self.airTemperatureC, self.SURFACE_DEPTH_CM,
        self.surfaceTemperatureC, self.SUBSOIL_DEPTH_CM,
        self.subsoilTemperatureC,
        self.surfaceFrozen and "frozen" or "open",
        self.subsoilFrozen and "frozen" or "open",
        self.pendingSurfaceThawPulse, self.pendingDeepThawPulse,
        self.daysPerPeriod,
        self.calendarScale, tostring(self.daysPerPeriodSource),
        self.loadedFromSave and "save" or "new/spin-up")
end

function TerraLogicSoilTemperatureManager:save()
    local mission = g_currentMission
    if mission == nil or not mission:getIsServer()
        or self.initialized ~= true then return end
    local path = getSavePath()
    if path == nil then return end
    local xml = createXMLFile(
        "terraLogicSoilTemperature", path, "soilTemperature")
    if xml == nil or xml == 0 then return end
    local root = "soilTemperature"
    local persisted = self.auditOverrideActive
        and self.auditOverrideSnapshot or self
    setXMLInt(xml, root .. "#version", self.SAVE_VERSION)
    setXMLFloat(xml, root .. "#surfaceC", persisted.surfaceTemperatureC)
    setXMLFloat(xml, root .. "#subsoilC", persisted.subsoilTemperatureC)
    setXMLFloat(xml, root .. "#dailyMeanC", persisted.dailyMeanTemperatureC)
    setXMLFloat(xml, root .. "#climateMeanC", persisted.climateMeanTemperatureC)
    setXMLFloat(xml, root .. "#dailyWeightedSum",
        self.dailyTemperatureWeightedSum)
    setXMLFloat(xml, root .. "#dailyHours", self.dailyTemperatureHours)
    setXMLFloat(xml, root .. "#spinupClimateDays", self.spinupClimateDays)
    setXMLFloat(xml, root .. "#simulatedGameHours", self.simulatedGameHours)
    setXMLInt(xml, root .. "#surfaceFrozen",
        persisted.surfaceFrozen and 1 or 0)
    setXMLInt(xml, root .. "#subsoilFrozen",
        persisted.subsoilFrozen and 1 or 0)
    setXMLFloat(xml, root .. "#surfaceFrozenHours",
        persisted.surfaceFrozenHours)
    setXMLFloat(xml, root .. "#subsoilFrozenHours",
        persisted.subsoilFrozenHours)
    setXMLFloat(xml, root .. "#surfaceFreezeMinimumC",
        persisted.surfaceFreezeMinimumC)
    setXMLFloat(xml, root .. "#subsoilFreezeMinimumC",
        persisted.subsoilFreezeMinimumC)
    setXMLFloat(xml, root .. "#pendingSurfaceThawPulse",
        persisted.pendingSurfaceThawPulse)
    setXMLFloat(xml, root .. "#pendingDeepThawPulse",
        persisted.pendingDeepThawPulse)
    setXMLFloat(xml, root .. "#surfaceFreezeThawCycles", self.surfaceFreezeThawCycles)
    setXMLFloat(xml, root .. "#deepFreezeThawCycles", self.deepFreezeThawCycles)
    saveXMLFile(xml)
    delete(xml)
end

local function updateFreezeLayer(manager, prefix, temperatureC, elapsedHours,
        freezeEnterC, thawExitC, minimumHours, referenceHours,
        referenceColdC, pendingKey, cycleKey)
    local frozenKey = prefix .. "Frozen"
    local hoursKey = prefix .. "FrozenHours"
    local minimumKey = prefix .. "FreezeMinimumC"
    local frozen = manager[frozenKey] == true
    temperatureC = tonumber(temperatureC) or thawExitC
    elapsedHours = math.max(tonumber(elapsedHours) or 0, 0)

    if not frozen then
        if temperatureC <= freezeEnterC then
            manager[frozenKey] = true
            manager[hoursKey] = elapsedHours
            manager[minimumKey] = temperatureC
            manager.frostRevision = (manager.frostRevision or 0) + 1
        end
        return
    end

    manager[hoursKey] = math.max(tonumber(manager[hoursKey]) or 0, 0)
        + elapsedHours
    manager[minimumKey] = math.min(
        tonumber(manager[minimumKey]) or temperatureC, temperatureC)
    if temperatureC < thawExitC then return end

    local frozenHours = manager[hoursKey]
    local minimumC = manager[minimumKey]
    local durationStrength = smoothStep01(
        (frozenHours - minimumHours)
            / math.max(referenceHours - minimumHours, 0.001))
    local coldStrength = smoothStep01(
        (freezeEnterC - minimumC) / math.max(referenceColdC, 0.001))
    local pulse = durationStrength * coldStrength
    manager[pendingKey] = math.min(
        (tonumber(manager[pendingKey]) or 0) + pulse,
        manager.MAX_PENDING_THAW_PULSE)
    manager[cycleKey] = (tonumber(manager[cycleKey]) or 0) + 1
    manager[frozenKey] = false
    manager[hoursKey] = 0
    manager[minimumKey] = temperatureC
    manager.frostRevision = (manager.frostRevision or 0) + 1
end

function TerraLogicSoilTemperatureManager:updateFreezeThaw(gameHours)
    updateFreezeLayer(self, "surface", self.surfaceTemperatureC, gameHours,
        self.SURFACE_FREEZE_ENTER_C, self.SURFACE_THAW_EXIT_C,
        self.SURFACE_MIN_FROZEN_HOURS,
        self.SURFACE_REFERENCE_FROZEN_HOURS,
        self.SURFACE_REFERENCE_COLD_C,
        "pendingSurfaceThawPulse", "surfaceFreezeThawCycles")
    updateFreezeLayer(self, "subsoil", self.subsoilTemperatureC, gameHours,
        self.SUBSOIL_FREEZE_ENTER_C, self.SUBSOIL_THAW_EXIT_C,
        self.SUBSOIL_MIN_FROZEN_HOURS,
        self.SUBSOIL_REFERENCE_FROZEN_HOURS,
        self.SUBSOIL_REFERENCE_COLD_C,
        "pendingDeepThawPulse", "deepFreezeThawCycles")
end

function TerraLogicSoilTemperatureManager:consumeFreezeThawPulses()
    local mission = g_currentMission
    if mission == nil or not mission:getIsServer() then return 0, 0 end
    local surface = math.max(tonumber(self.pendingSurfaceThawPulse) or 0, 0)
    local deep = math.max(tonumber(self.pendingDeepThawPulse) or 0, 0)
    if surface > 0 or deep > 0 then
        self.pendingSurfaceThawPulse = 0
        self.pendingDeepThawPulse = 0
        self.frostRevision = (self.frostRevision or 0) + 1
    end
    return surface, deep
end

function TerraLogicSoilTemperatureManager:applyNetworkState(
        airTemperatureC, surfaceTemperatureC, subsoilTemperatureC,
        dailyMeanTemperatureC, climateMeanTemperatureC,
        spinupClimateDays, daysPerPeriod, calendarScale,
        dailyTemperatureHours, surfaceFrozen, subsoilFrozen,
        surfaceFrozenHours, subsoilFrozenHours,
        surfaceFreezeMinimumC, subsoilFreezeMinimumC,
        pendingSurfaceThawPulse, pendingDeepThawPulse,
        surfaceFreezeThawCycles, deepFreezeThawCycles)
    self.airTemperatureC = clampTemperature(airTemperatureC, 10)
    self.surfaceTemperatureC = clampTemperature(
        surfaceTemperatureC, self.airTemperatureC)
    self.subsoilTemperatureC = clampTemperature(
        subsoilTemperatureC, self.surfaceTemperatureC)
    self.dailyMeanTemperatureC = clampTemperature(
        dailyMeanTemperatureC, self.surfaceTemperatureC)
    self.climateMeanTemperatureC = clampTemperature(
        climateMeanTemperatureC, self.subsoilTemperatureC)
    self.spinupClimateDays = math.max(
        tonumber(spinupClimateDays) or 0, 0)
    self.daysPerPeriod = math.max(tonumber(daysPerPeriod)
        or self.NOMINAL_DAYS_PER_PERIOD, 1)
    self.calendarScale = math.max(
        tonumber(calendarScale) or 1, 1)
    self.dailyTemperatureHours = math.max(math.min(
        tonumber(dailyTemperatureHours) or 0,
        self.DAILY_WINDOW_HOURS), 0)
    self.dailyTemperatureWeightedSum = 0
    self.surfaceFrozen = surfaceFrozen == true
    self.subsoilFrozen = subsoilFrozen == true
    self.surfaceFrozenHours = math.max(tonumber(surfaceFrozenHours) or 0, 0)
    self.subsoilFrozenHours = math.max(tonumber(subsoilFrozenHours) or 0, 0)
    self.surfaceFreezeMinimumC = clampTemperature(
        surfaceFreezeMinimumC, self.surfaceTemperatureC)
    self.subsoilFreezeMinimumC = clampTemperature(
        subsoilFreezeMinimumC, self.subsoilTemperatureC)
    self.pendingSurfaceThawPulse = math.max(0, math.min(
        tonumber(pendingSurfaceThawPulse) or 0, self.MAX_PENDING_THAW_PULSE))
    self.pendingDeepThawPulse = math.max(0, math.min(
        tonumber(pendingDeepThawPulse) or 0, self.MAX_PENDING_THAW_PULSE))
    self.surfaceFreezeThawCycles = math.max(0,
        tonumber(surfaceFreezeThawCycles) or 0)
    self.deepFreezeThawCycles = math.max(0,
        tonumber(deepFreezeThawCycles) or 0)
    self.temperatureSource = "server synchronization"
    self.daysPerPeriodSource = "server synchronization"
    self.initialized = true
end

function TerraLogicSoilTemperatureManager:sendState(connection)
    if g_server == nil or self.initialized ~= true then return end
    local event = TerraLogicSoilTemperatureSyncEvent.new(
        self.airTemperatureC,
        self.surfaceTemperatureC,
        self.subsoilTemperatureC,
        self.dailyMeanTemperatureC,
        self.climateMeanTemperatureC,
        self.spinupClimateDays,
        self.daysPerPeriod,
        self.calendarScale,
        self.dailyTemperatureHours,
        self.surfaceFrozen,
        self.subsoilFrozen,
        self.surfaceFrozenHours,
        self.subsoilFrozenHours,
        self.surfaceFreezeMinimumC,
        self.subsoilFreezeMinimumC,
        self.pendingSurfaceThawPulse,
        self.pendingDeepThawPulse,
        self.surfaceFreezeThawCycles,
        self.deepFreezeThawCycles)
    if connection ~= nil then
        connection:sendEvent(event)
    else
        g_server:broadcastEvent(event)
    end
    self.lastSyncSurfaceC = self.surfaceTemperatureC
    self.lastSyncSubsoilC = self.subsoilTemperatureC
    self.lastSyncFrostRevision = self.frostRevision or 0
    self.syncKeepaliveMs = 0
end

function TerraLogicSoilTemperatureManager:update(dt)
    local mission = g_currentMission
    if mission == nil or not mission:getIsServer()
        or self.initialized ~= true then return end
    -- Keep a complete, internally consistent frost state fixed during an
    -- audit preset. Ordinary gameplay never sets this runtime-only flag.
    if self.auditOverrideActive == true then return end

    local airTemperature, source = self:getWeatherTemperature()
    if airTemperature == nil then
        self.temperatureSource = source
        return
    end
    self.airTemperatureC = airTemperature
    self.temperatureSource = source

    local realDtMs = math.max(tonumber(dt) or 0, 0)
    local timeScale = self:getEffectiveTimeScale()
    local gameHours = math.min(
        realDtMs * timeScale / 3600000,
        self.MAX_GAME_HOURS_PER_UPDATE)
    if gameHours > 0 then
        self.daysPerPeriod, self.daysPerPeriodSource =
            self:getDaysPerPeriod()
        self.calendarScale = self.NOMINAL_DAYS_PER_PERIOD
            / math.max(self.daysPerPeriod, 1)
        self.calendarScale = math.max(
            1, math.min(self.calendarScale, 30))

        self.surfaceTemperatureC = clampTemperature(
            approachExponential(
                self.surfaceTemperatureC,
                airTemperature,
                gameHours,
                self.SURFACE_TAU_HOURS),
            airTemperature)

        -- Average the actual air boundary over one complete game day.  Slow
        -- conduction is advanced only with that mean, so a short FS calendar
        -- does not turn the day/night wave into a fictitious monthly heat wave.
        local remainingHours = gameHours
        while remainingHours > 0.000001 do
            local availableHours = self.DAILY_WINDOW_HOURS
                - self.dailyTemperatureHours
            local sliceHours = math.min(remainingHours, availableHours)
            self.dailyTemperatureWeightedSum =
                self.dailyTemperatureWeightedSum
                    + airTemperature * sliceHours
            self.dailyTemperatureHours = self.dailyTemperatureHours
                + sliceHours
            remainingHours = remainingHours - sliceHours
            if self.dailyTemperatureHours
                >= self.DAILY_WINDOW_HOURS - 0.000001 then
                self.dailyMeanTemperatureC = clampTemperature(
                    self.dailyTemperatureWeightedSum
                        / math.max(self.dailyTemperatureHours, 0.0001),
                    airTemperature)
                local climateHours = self.DAILY_WINDOW_HOURS
                    * self.calendarScale
                self.climateMeanTemperatureC = clampTemperature(
                    approachExponential(
                        self.climateMeanTemperatureC,
                        self.dailyMeanTemperatureC,
                        climateHours,
                        self.CLIMATE_MEAN_TAU_DAYS * 24),
                    self.dailyMeanTemperatureC)
                local subsoilTarget = self.climateMeanTemperatureC
                    + self.SUBSOIL_SEASONAL_AMPLITUDE
                    * (self.dailyMeanTemperatureC
                        - self.climateMeanTemperatureC)
                self.subsoilTemperatureC = clampTemperature(
                    approachExponential(
                        self.subsoilTemperatureC,
                        subsoilTarget,
                        climateHours,
                        self.SUBSOIL_TAU_CLIMATE_DAYS * 24),
                    subsoilTarget)
                self.spinupClimateDays = self.spinupClimateDays
                    + climateHours / 24
                self.dailyTemperatureWeightedSum = 0
                self.dailyTemperatureHours = 0
            end
        end
        self.simulatedGameHours = self.simulatedGameHours + gameHours
        self:updateFreezeThaw(gameHours)
    end

    self.syncTimerMs = (tonumber(self.syncTimerMs) or 0) - realDtMs
    self.syncKeepaliveMs = (tonumber(self.syncKeepaliveMs) or 0)
        + realDtMs
    if self.syncTimerMs <= 0 then
        self.syncTimerMs = self.SYNC_INTERVAL_MS
        local changed = self.lastSyncSurfaceC == nil
            or math.abs(self.surfaceTemperatureC
                - self.lastSyncSurfaceC)
                >= self.SYNC_TEMPERATURE_THRESHOLD_C
            or math.abs(self.subsoilTemperatureC
                - self.lastSyncSubsoilC)
                >= self.SYNC_TEMPERATURE_THRESHOLD_C
            or (self.frostRevision or 0)
                ~= (self.lastSyncFrostRevision or -1)
        if changed or self.syncKeepaliveMs >= self.SYNC_KEEPALIVE_MS then
            self:sendState(nil)
        end
    end
end

function TerraLogicSoilTemperatureManager:getState()
    local spinup = math.min(
        (tonumber(self.spinupClimateDays) or 0)
            / self.SPINUP_CLIMATE_DAYS,
        1)
    return {
        initialized = self.initialized == true,
        auditOverrideActive = self.auditOverrideActive == true,
        auditOverridePreset = self.auditOverridePreset,
        airTemperatureC = tonumber(self.airTemperatureC) or 0,
        surfaceTemperatureC = tonumber(self.surfaceTemperatureC) or 0,
        subsoilTemperatureC = tonumber(self.subsoilTemperatureC) or 0,
        dailyMeanTemperatureC = tonumber(self.dailyMeanTemperatureC) or 0,
        climateMeanTemperatureC = tonumber(self.climateMeanTemperatureC) or 0,
        surfaceDepthCm = self.SURFACE_DEPTH_CM,
        subsoilDepthCm = self.SUBSOIL_DEPTH_CM,
        surfaceLagHours = self.SURFACE_TAU_HOURS,
        subsoilResponseClimateDays = self.SUBSOIL_TAU_CLIMATE_DAYS,
        daysPerPeriod = tonumber(self.daysPerPeriod)
            or self.NOMINAL_DAYS_PER_PERIOD,
        calendarScale = tonumber(self.calendarScale) or 1,
        dailySampleFraction = math.min(
            math.max(tonumber(self.dailyTemperatureHours) or 0, 0)
                / self.DAILY_WINDOW_HOURS,
            1),
        spinupFraction = spinup,
        spinupComplete = spinup >= 1,
        surfaceFrozen = self.surfaceFrozen == true,
        subsoilFrozen = self.subsoilFrozen == true,
        surfaceFrozenHours = math.max(
            tonumber(self.surfaceFrozenHours) or 0, 0),
        subsoilFrozenHours = math.max(
            tonumber(self.subsoilFrozenHours) or 0, 0),
        surfaceFreezeMinimumC = tonumber(self.surfaceFreezeMinimumC)
            or tonumber(self.surfaceTemperatureC) or 0,
        subsoilFreezeMinimumC = tonumber(self.subsoilFreezeMinimumC)
            or tonumber(self.subsoilTemperatureC) or 0,
        pendingSurfaceThawPulse = math.max(
            tonumber(self.pendingSurfaceThawPulse) or 0, 0),
        pendingDeepThawPulse = math.max(
            tonumber(self.pendingDeepThawPulse) or 0, 0),
        surfaceFreezeThawCycles = math.max(
            tonumber(self.surfaceFreezeThawCycles) or 0, 0),
        deepFreezeThawCycles = math.max(
            tonumber(self.deepFreezeThawCycles) or 0, 0),
        gameplayEffectsActive = true,
        loadedFromSave = self.loadedFromSave == true,
        temperatureSource = self.temperatureSource or "unknown",
        daysPerPeriodSource = self.daysPerPeriodSource or "unknown"
    }
end

function TerraLogicSoilTemperatureManager:setAuditPreset(presetName)
    if g_server == nil or self.initialized ~= true then
        return false, "temperature manager unavailable"
    end
    local name = string.lower(tostring(presetName or ""))
    if name == "natural" or name == "off" then
        local snapshot = self.auditOverrideSnapshot
        if snapshot ~= nil then
            for key, value in pairs(snapshot) do self[key] = value end
        end
        self.auditOverrideActive = false
        self.auditOverridePreset = nil
        self.auditOverrideSnapshot = nil
        self.frostRevision = (tonumber(self.frostRevision) or 0) + 1
        self:sendState(nil)
        return true, "natural temperature simulation restored"
    end
    local preset = AUDIT_TEMPERATURE_PRESETS[name]
    if preset == nil then return false, "unknown temperature preset" end
    if self.auditOverrideSnapshot == nil then
        self.auditOverrideSnapshot = {}
        for _, key in ipairs({"airTemperatureC", "surfaceTemperatureC",
                "subsoilTemperatureC", "dailyMeanTemperatureC",
                "climateMeanTemperatureC", "surfaceFrozen",
                "subsoilFrozen", "surfaceFrozenHours",
                "subsoilFrozenHours", "surfaceFreezeMinimumC",
                "subsoilFreezeMinimumC", "pendingSurfaceThawPulse",
                "pendingDeepThawPulse"}) do
            self.auditOverrideSnapshot[key] = self[key]
        end
    end
    self.airTemperatureC = preset.air
    self.surfaceTemperatureC = preset.surface
    self.subsoilTemperatureC = preset.subsoil
    self.dailyMeanTemperatureC = preset.air
    self.climateMeanTemperatureC = preset.subsoil
    self.surfaceFrozen = preset.frozen
    self.subsoilFrozen = preset.frozen
    self.surfaceFrozenHours = preset.frozen and 48 or 0
    self.subsoilFrozenHours = preset.frozen and 144 or 0
    self.surfaceFreezeMinimumC = preset.surface
    self.subsoilFreezeMinimumC = preset.subsoil
    self.pendingSurfaceThawPulse = 0
    self.pendingDeepThawPulse = 0
    self.auditOverrideActive = true
    self.auditOverridePreset = name
    self.frostRevision = (tonumber(self.frostRevision) or 0) + 1
    self:sendState(nil)
    return true, string.format("%s temperature: %.1f/%.1f C",
        name, preset.surface, preset.subsoil)
end

function TerraLogicSoilTemperatureManager:delete(saveFirst)
    if saveFirst == true then self:save() end
    self.initialized = false
    self.airTemperatureC = nil
    self.surfaceTemperatureC = nil
    self.subsoilTemperatureC = nil
    self.dailyMeanTemperatureC = nil
    self.climateMeanTemperatureC = nil
    self.dailyTemperatureWeightedSum = nil
    self.dailyTemperatureHours = nil
    self.spinupClimateDays = nil
    self.simulatedGameHours = nil
    self.surfaceFrozen = nil
    self.subsoilFrozen = nil
    self.surfaceFrozenHours = nil
    self.subsoilFrozenHours = nil
    self.surfaceFreezeMinimumC = nil
    self.subsoilFreezeMinimumC = nil
    self.pendingSurfaceThawPulse = nil
    self.pendingDeepThawPulse = nil
    self.surfaceFreezeThawCycles = nil
    self.deepFreezeThawCycles = nil
    self.frostRevision = nil
    self.lastSyncFrostRevision = nil
    self.syncTimerMs = nil
    self.syncKeepaliveMs = nil
    self.auditOverrideActive = nil
    self.auditOverridePreset = nil
    self.auditOverrideSnapshot = nil
end

-- Multiplayer synchronization ----------------------------------------------

TerraLogicSoilTemperatureSyncEvent = {}
local TerraLogicSoilTemperatureSyncEvent_mt = Class(
    TerraLogicSoilTemperatureSyncEvent, Event)
InitEventClass(
    TerraLogicSoilTemperatureSyncEvent,
    "TerraLogicSoilTemperatureSyncEvent")

function TerraLogicSoilTemperatureSyncEvent.emptyNew()
    return Event.new(TerraLogicSoilTemperatureSyncEvent_mt)
end

function TerraLogicSoilTemperatureSyncEvent.new(
        airTemperatureC, surfaceTemperatureC, subsoilTemperatureC,
        dailyMeanTemperatureC, climateMeanTemperatureC,
        spinupClimateDays, daysPerPeriod, calendarScale,
        dailyTemperatureHours, surfaceFrozen, subsoilFrozen,
        surfaceFrozenHours, subsoilFrozenHours,
        surfaceFreezeMinimumC, subsoilFreezeMinimumC,
        pendingSurfaceThawPulse, pendingDeepThawPulse,
        surfaceFreezeThawCycles, deepFreezeThawCycles)
    local self = TerraLogicSoilTemperatureSyncEvent.emptyNew()
    self.airTemperatureC = airTemperatureC
    self.surfaceTemperatureC = surfaceTemperatureC
    self.subsoilTemperatureC = subsoilTemperatureC
    self.dailyMeanTemperatureC = dailyMeanTemperatureC
    self.climateMeanTemperatureC = climateMeanTemperatureC
    self.spinupClimateDays = spinupClimateDays
    self.daysPerPeriod = daysPerPeriod
    self.calendarScale = calendarScale
    self.dailyTemperatureHours = dailyTemperatureHours
    self.surfaceFrozen = surfaceFrozen
    self.subsoilFrozen = subsoilFrozen
    self.surfaceFrozenHours = surfaceFrozenHours
    self.subsoilFrozenHours = subsoilFrozenHours
    self.surfaceFreezeMinimumC = surfaceFreezeMinimumC
    self.subsoilFreezeMinimumC = subsoilFreezeMinimumC
    self.pendingSurfaceThawPulse = pendingSurfaceThawPulse
    self.pendingDeepThawPulse = pendingDeepThawPulse
    self.surfaceFreezeThawCycles = surfaceFreezeThawCycles
    self.deepFreezeThawCycles = deepFreezeThawCycles
    return self
end

function TerraLogicSoilTemperatureSyncEvent:readStream(
        streamId, connection)
    self.airTemperatureC = streamReadFloat32(streamId)
    self.surfaceTemperatureC = streamReadFloat32(streamId)
    self.subsoilTemperatureC = streamReadFloat32(streamId)
    self.dailyMeanTemperatureC = streamReadFloat32(streamId)
    self.climateMeanTemperatureC = streamReadFloat32(streamId)
    self.spinupClimateDays = streamReadFloat32(streamId)
    self.daysPerPeriod = streamReadFloat32(streamId)
    self.calendarScale = streamReadFloat32(streamId)
    self.dailyTemperatureHours = streamReadFloat32(streamId)
    self.surfaceFrozen = streamReadBool(streamId)
    self.subsoilFrozen = streamReadBool(streamId)
    self.surfaceFrozenHours = streamReadFloat32(streamId)
    self.subsoilFrozenHours = streamReadFloat32(streamId)
    self.surfaceFreezeMinimumC = streamReadFloat32(streamId)
    self.subsoilFreezeMinimumC = streamReadFloat32(streamId)
    self.pendingSurfaceThawPulse = streamReadFloat32(streamId)
    self.pendingDeepThawPulse = streamReadFloat32(streamId)
    self.surfaceFreezeThawCycles = streamReadFloat32(streamId)
    self.deepFreezeThawCycles = streamReadFloat32(streamId)
    self:run(connection)
end

function TerraLogicSoilTemperatureSyncEvent:writeStream(
        streamId, connection)
    streamWriteFloat32(streamId, self.airTemperatureC)
    streamWriteFloat32(streamId, self.surfaceTemperatureC)
    streamWriteFloat32(streamId, self.subsoilTemperatureC)
    streamWriteFloat32(streamId, self.dailyMeanTemperatureC)
    streamWriteFloat32(streamId, self.climateMeanTemperatureC)
    streamWriteFloat32(streamId, self.spinupClimateDays)
    streamWriteFloat32(streamId, self.daysPerPeriod)
    streamWriteFloat32(streamId, self.calendarScale)
    streamWriteFloat32(streamId, self.dailyTemperatureHours)
    streamWriteBool(streamId, self.surfaceFrozen == true)
    streamWriteBool(streamId, self.subsoilFrozen == true)
    streamWriteFloat32(streamId, self.surfaceFrozenHours)
    streamWriteFloat32(streamId, self.subsoilFrozenHours)
    streamWriteFloat32(streamId, self.surfaceFreezeMinimumC)
    streamWriteFloat32(streamId, self.subsoilFreezeMinimumC)
    streamWriteFloat32(streamId, self.pendingSurfaceThawPulse)
    streamWriteFloat32(streamId, self.pendingDeepThawPulse)
    streamWriteFloat32(streamId, self.surfaceFreezeThawCycles)
    streamWriteFloat32(streamId, self.deepFreezeThawCycles)
end

function TerraLogicSoilTemperatureSyncEvent:run(connection)
    if not connection:getIsServer() then return end
    TerraLogicSoilTemperatureManager:applyNetworkState(
        self.airTemperatureC,
        self.surfaceTemperatureC,
        self.subsoilTemperatureC,
        self.dailyMeanTemperatureC,
        self.climateMeanTemperatureC,
        self.spinupClimateDays,
        self.daysPerPeriod,
        self.calendarScale,
        self.dailyTemperatureHours,
        self.surfaceFrozen,
        self.subsoilFrozen,
        self.surfaceFrozenHours,
        self.subsoilFrozenHours,
        self.surfaceFreezeMinimumC,
        self.subsoilFreezeMinimumC,
        self.pendingSurfaceThawPulse,
        self.pendingDeepThawPulse,
        self.surfaceFreezeThawCycles,
        self.deepFreezeThawCycles)
end

if FSBaseMission ~= nil and FSBaseMission.sendInitialClientState ~= nil
    and FSBaseMission.terraLogicSoilTemperatureSyncHookInstalled ~= true then
    FSBaseMission.terraLogicSoilTemperatureSyncHookInstalled = true
    FSBaseMission.sendInitialClientState = Utils.appendedFunction(
        FSBaseMission.sendInitialClientState,
        function(_, connection)
            if g_server ~= nil
                and TerraLogicSoilTemperatureManager.initialized == true then
                TerraLogicSoilTemperatureManager:sendState(connection)
            end
        end)
end
