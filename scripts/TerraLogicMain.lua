--[[
    TerraLogicMain.lua
    Mission lifecycle, console tools, HUD rendering and debug interfaces.

    Copyright (c) 2026 The Mod Workshop. All rights reserved.
    Unauthorized copying, modification, or redistribution is prohibited
    except where expressly permitted by the copyright owner.

    Source fingerprint: TMW-TL-MAIN-1.200311
]]

TerraLogicMain = {}
OverSpeedDamageMain = TerraLogicMain
-- Numeric source signature only; it is deliberately excluded from gameplay math.
TerraLogicMain.SOURCE_FINGERPRINT = 1.200242

local MOD_NAME = g_currentModName
local MOD_DIR = g_currentModDirectory
local SPEC_NAME = "terraLogic"

TerraLogicMain.debugEnabled = false
TerraLogicMain.debugMode = "overview"
TerraLogicMain.PANEL_LOG_INTERVAL_MS = 1000
TerraLogicMain.PANEL_LOG_LINE_COLUMNS = 160
TerraLogicMain.NORMALIZED_REFERENCE_WIDTH_M = 3.00
TerraLogicMain.SPEED_HUD_VEHICLE_NAME_DELAY_MS = 5000
TerraLogicMain.SPEED_HUD_FADE_DURATION_MS = 500
-- Communication threshold only. Structural damage itself remains a continuous
-- curve from zero; the red warning is reserved for a clearly material rate.
TerraLogicMain.WORK_HUD_SEVERE_DAMAGE_RATE_PCT_PER_MIN = 1.0
TerraLogicMain.WORK_HUD_WARNING_SLOT_MS = 5000
TerraLogicMain.WORK_HUD_WARNING_CONFIRM_MS = 650
TerraLogicMain.WORK_HUD_WARNING_CLEAR_GRACE_MS = 1200
TerraLogicMain.WORK_HUD_WARNING_EVENT_LIFETIME_MS = 30000
TerraLogicMain.WORK_HUD_WARNING_MAX_QUEUE = 5
-- Display hysteresis only. The continuous wear and structural-damage curves
-- remain untouched: a nominal-load warning enters five percentage points
-- above its reference and clears only after load falls below that reference.
TerraLogicMain.WORK_HUD_MECHANICAL_WARNING_ENTER_MARGIN = 0.05
-- Tiny numerical losses remain fully simulated but are not useful enough to
-- interrupt field work. The HUD starts explaining a cause once it costs five
-- quality points or one percent of real processed area. Smaller quality
-- deviations remain fully simulated and visible in the percentage, but do not
-- pin the dynamic HUD open as though the operation were already failing.
TerraLogicMain.WORK_HUD_QUALITY_WARNING_LOSS = 0.05
TerraLogicMain.WORK_HUD_DROPOUT_WARNING_FRACTION = 0.01
local SPEED_HUD_CAUTION_COLOR = {1, 0.4287, 0.0006, 1}
local SPEED_HUD_CRITICAL_COLOR = {1, 0.18, 0.10, 1}

local function getWorkHudDisplayRecommendedSpeed(recommendedSpeed, shopSpeed)
    shopSpeed = math.max(tonumber(shopSpeed) or 0, 0)
    local lower = math.clamp(tonumber(recommendedSpeed) or shopSpeed,
        0, shopSpeed)
    -- Some non-ground tools legitimately report one reference speed, e.g.
    -- 12-12 km/h for a sprayer. A tenth-wide scale amplifies normal physics
    -- jitter into a flashing full-bar movement. Give such tools a modest
    -- efficiency band below shop speed without changing gameplay physics.
    local minimumRange = math.clamp(shopSpeed*0.15, 2, 4)
    if shopSpeed-lower < 0.5 then
        lower = math.max(shopSpeed-minimumRange, 0.5)
    end
    return lower
end

local function updateWorkHudMechanicalWarningState(
        spec, isMechanicalActive)
    if spec == nil or isMechanicalActive ~= true
        or spec.mechanicalLoadModel == "none" then
        if spec ~= nil then spec.workHudMechanicalWarningActive = false end
        return false
    end
    local reference = tonumber(spec.mechanicalWarningRatio) or math.huge
    if reference == math.huge then
        spec.workHudMechanicalWarningActive = false
        return false
    end
    local loadRatio = math.max(tonumber(spec.mechanicalLoadRatio) or 0, 0)
    local active = spec.workHudMechanicalWarningActive == true
    if active then
        active = loadRatio >= reference
    else
        active = loadRatio >= reference
            + TerraLogicMain.WORK_HUD_MECHANICAL_WARNING_ENTER_MARGIN
    end
    spec.workHudMechanicalWarningActive = active
    return active
end
TerraLogicMain.DEBUG_VIEWS = {
    overview = true,
    wear = true,
    economy = true,
    draft = true,
    impacts = true,
    damageanalysis = true,
    quality = true,
    balancing = true,
    workquality = true,
    soil = true,
    soilprocess = true,
    traffic = true,
    technical = true
}
TerraLogicMain.DEBUG_VIEW_HELP = {
    {name = "overview", description = "compact overall status"},
    {name = "wear", description = "wear curve, damage rates and normalization"},
    {name = "economy", description = "repair costs and remaining service life"},
    {name = "draft", description = "draft, MaxForce and Precision Farming soil"},
    {name = "impacts", description = "random impacts and real stone contacts"},
    {name = "damageanalysis", description = "session damage split by exact source"},
    {name = "quality", description = "sowing/application quality and missed areas"},
    {name = "balancing", description = "live time saving, quality and yield trade-off"},
    {name = "workquality", description = "stored work quality and real yield deductions"},
    {name = "soil", description = "live soil state, temperature and moisture"},
    {name = "soilprocess", description = "five soil maps, deltas, writes and recovery"},
    {name = "traffic", description = "vehicle loads, tyres and five-layer soil response"},
    {name = "technical", description = "recognition and internal diagnostics"}
}
-- Short, player-facing names for the panels normally used when recording an
-- unexpected gameplay situation. Exact tlView names remain valid as well.
TerraLogicMain.TEST_PANEL_ALIASES = {
    fieldwork = "soilprocess",
    soilprocess = "soilprocess",
    compaction = "traffic",
    traffic = "traffic",
    weather = "audit_weather",
    recovery = "audit_recovery",
    yield = "audit_yield",
    workquality = "workquality",
    gaps = "workquality",
    draft = "draft",
    damage = "audit_damage",
    stones = "audit_damage",
    economy = "economy",
    overview = "overview"
}
TerraLogicMain.TEST_PANEL_HELP = {
    {name="soilprocess", description="implement effects and changes to all five soil values"},
    {name="traffic", description="vehicle mass, wheel loads, tyres and compaction"},
    {name="weather", description="rain, moisture, soil temperature and frost"},
    {name="recovery", description="natural recovery, roots, crop rotation and resilience"},
    {name="yield", description="soil, moisture, work quality and resulting yield"},
    {name="workquality", description="work quality and missed or damaged areas"},
    {name="draft", description="draft from soil, moisture, frost and speed"},
    {name="damage", description="wear, impacts and stone damage"},
    {name="economy", description="speed, productivity, wear and economic trade-off"},
    {name="overview", description="broad implement overview"}
}
TerraLogicMain.enabled = true
TerraLogicMain.abrasionOverride = 0
TerraLogicMain.resistanceOverride = 0
TerraLogicMain.precisionFarmingMode = "auto"
TerraLogicMain.wearPolicy = "normalize"
TerraLogicMain.draftEnabled = true
TerraLogicMain.randomImpactsEnabled = true
TerraLogicMain.stoneImpactsEnabled = true
-- Runtime-only diagnostic switch. Physical mower dropouts remain active so
-- their conserved grass volume can be compared without the live speed loss.
TerraLogicMain.mowerQualityEnabled = false
TerraLogicMain.BALANCE_DEFAULTS = {
    wear = 1,
    draft = 1,
    damageResistance = 1,
    randomFrequency = 1,
    randomDamage = 1,
    stoneSurface = 1,
    stoneGenerated = 1
}
TerraLogicMain.BALANCE_NAMES = {
    wear = "wear",
    draft = "draft",
    damageresistance = "damageResistance",
    randomfrequency = "randomFrequency",
    randomdamage = "randomDamage",
    stonesurface = "stoneSurface",
    stonegenerated = "stoneGenerated"
}
TerraLogicMain.balanceMultipliers = {}
for name, value in pairs(TerraLogicMain.BALANCE_DEFAULTS) do
    TerraLogicMain.balanceMultipliers[name] = value
end

-- Safely calls an optional method while supporting different PF API versions.
local function resolveObjectMethod(object, methodName, ...)
    if object == nil then
        return nil, "object missing"
    end

    local directMethod = object[methodName]
    if type(directMethod) == "function" then
        return directMethod, "instance"
    end

    local mt = getmetatable(object)
    if mt ~= nil and type(mt.__index) == "table" then
        local metaMethod = mt.__index[methodName]
        if type(metaMethod) == "function" then
            return metaMethod, "metatable"
        end
    end

    for i = 1, select("#", ...) do
        local classObject = select(i, ...)
        if type(classObject) == "table" and type(classObject[methodName]) == "function" then
            return classObject[methodName], "class"
        end
    end

    return nil, "method missing"
end

-- Finds the active Precision Farming soil map without requiring PF to be loaded.
function TerraLogicMain:getPrecisionFarmingSoilMap()
    local pfEnvironment = FS25_precisionFarming
    local pfController = pfEnvironment ~= nil and pfEnvironment.g_precisionFarming or nil
    local candidates = {
        {object = pfController ~= nil and pfController.soilMap or nil, source = "FS25_precisionFarming.g_precisionFarming.soilMap"},
        {object = g_precisionFarming ~= nil and g_precisionFarming.soilMap or nil, source = "g_precisionFarming.soilMap"},
        {object = g_currentMission ~= nil and g_currentMission.precisionFarming ~= nil and g_currentMission.precisionFarming.soilMap or nil, source = "mission.precisionFarming.soilMap"},
        {object = g_currentMission ~= nil and g_currentMission.precisionFarmingSoilMap or nil, source = "mission.precisionFarmingSoilMap"},
        {object = g_currentMission ~= nil and g_currentMission.soilMap or nil, source = "mission.soilMap"}
    }

    local methodNames = {
        "getTypeIndexAtWorldPos",
        "getSoilTypeIndexAtWorldPos",
        "getSoilTypeAtWorldPos",
        "getTypeIndexAtWorldPosition"
    }

    for _, candidate in ipairs(candidates) do
        if candidate.object ~= nil then
            for _, methodName in ipairs(methodNames) do
                local method, methodSource = resolveObjectMethod(
                    candidate.object,
                    methodName,
                    pfEnvironment ~= nil and pfEnvironment.SoilMap or nil,
                    pfEnvironment ~= nil and pfEnvironment.PrecisionFarmingSoilMap or nil,
                    SoilMap,
                    PrecisionFarmingSoilMap
                )
                if method ~= nil then
                    return candidate.object, method,
                        candidate.source .. "/" .. methodSource .. "." .. methodName
                end
            end
        end
    end

    if pfEnvironment ~= nil then
        if pfController == nil then
            return nil, nil, "FS25_precisionFarming environment present, controller missing"
        end
        if pfController.soilMap == nil then
            return nil, nil, "PF controller present, soilMap missing"
        end
        return nil, nil, "PF cross-mod soilMap present, compatible method missing"
    end

    return nil, nil, g_precisionFarming ~= nil
        and "local PF global present, compatible soil map method missing"
        or "PF mod environment missing"
end

-- Installed is not the same as active in the current savegame. Requiring the
-- live controller/map prevents PF wording and PF balance from leaking into a
-- save that merely has the downloadable mod present on disk.
-- Returns true only when Precision Farming is active in this savegame.
function TerraLogicMain:isPrecisionFarmingActive()
    local loaded = g_modIsLoaded == nil
        or g_modIsLoaded["FS25_precisionFarming"] == true
    if not loaded then return false end
    local environment = FS25_precisionFarming
    local controller = environment ~= nil
        and environment.g_precisionFarming or g_precisionFarming
    if controller == nil and g_currentMission ~= nil then
        controller = g_currentMission.precisionFarming
    end
    if controller == nil then return false end
    return controller.soilMap ~= nil
        or controller.nitrogenMap ~= nil
        or controller.pHMap ~= nil
        or (g_currentMission ~= nil
            and g_currentMission.precisionFarmingSoilMap ~= nil)
end

-- Initializes persistent quality data, settings and console commands per mission.
function TerraLogicMain:loadMap(mapNode, mapFile)
    if self.panelLogger ~= nil and self.panelLogger.active == true then
        self:stopPanelLogger("map reload")
    end
    self.panelLogger = nil
    TerraLogicSettings:load()
    TerraLogicQualityManager:load()
    TerraLogicGrassGapManager:load()
    TerraLogicSoilTemperatureManager:load()
    TerraLogicSoilMoistureManager:load()
    TerraLogicSoilManager:load()
    TerraLogicWheelCompactionManager:load()
    TerraLogicTrafficWarnings:load()
    TerraLogicTutorialManager:load()
    if self:isPrecisionFarmingActive() then
        Logging.info(
            "[FS25_TerraLogic] Precision Farming active: soil-specific TerraLogic responses enabled")
    else
        Logging.info(
            "[FS25_TerraLogic] Precision Farming not active: generic TerraLogic soil profile enabled; all core systems remain active")
    end
    if TerraLogicAuditManager ~= nil then
        TerraLogicAuditManager:load(self)
    end
    if g_client ~= nil then
        TerraLogicSoilManager:setMapMode(
            tonumber(TerraLogicSettings.vehicleSoilMapMode) or 0)
    end
    -- Physical mowing gaps are the default and sole live overspeed penalty.
    -- The console command remains available for explicit comparison tests.
    self.mowerQualityEnabled = false
    local commands = {
        {"tlDebug", "TerraLogic debug toggle/view: tlDebug [view|on|off]", "consoleCommandDebug"},
        {"tlView", "Open TerraLogic debug/audit view; use tlViews for the complete list", "consoleCommandDebugView"},
        {"tlViews", "List TerraLogic debug views", "consoleCommandDebugViews"},
        {"tlDebugClose", "Close the active TerraLogic debug view", "consoleCommandDebugClose"},
        {"tlSetDamage", "Set selected implement damage: tlSetDamage <0-100>", "consoleCommandSetDamage"},
        {"tlDamageAnalysis", "Open/reset damage analysis: tlDamageAnalysis [reset]", "consoleCommandDamageAnalysis"},
        {"tlPF", "Precision Farming mode: tlPF [auto|on|off]", "consoleCommandPrecisionFarming"},
        {"tlPFInspect", "Inspect Precision Farming runtime objects", "consoleCommandPrecisionFarmingInspect"},
        {"tlEnable", "Enable/disable TerraLogic: tlEnable [on|off]", "consoleCommandEnable"},
        {"tlWearPolicy", "XML wear policy: tlWearPolicy [respect|normalize|forceVanilla]", "consoleCommandWearPolicy"},
        {"tlAbrasion", "Temporary abrasion override: tlAbrasion <multiplier|0>", "consoleCommandAbrasion"},
        {"tlResistance", "Temporary resistance override: tlResistance <multiplier|0>", "consoleCommandResistance"},
        {"tlDraft", "Enable/disable additional draft: tlDraft [on|off]", "consoleCommandDraft"},
        {"tlImpacts", "Enable/disable random impacts: tlImpacts [on|off]", "consoleCommandRandomImpacts"},
        {"tlStones", "Enable/disable stone-map damage: tlStones [on|off]", "consoleCommandStoneImpacts"},
        {"tlMowerQuality", g_i18n:getText("terraLogic_consoleMowerQualityHelp"), "consoleCommandMowerQuality"},
        {"tlMultiplier", "Runtime balance multiplier: tlMultiplier <name> <value|reset>", "consoleCommandMultiplier"},
        {"tlBalanceReset", "Reset temporary TerraLogic balance settings", "consoleCommandBalanceReset"},
        {"tlPrintBalance", "Print TerraLogic balance settings to log", "consoleCommandPrintBalance"},
        {"tlLog", "Verbose diagnostics: tlLog [on|off]", "consoleCommandLogging"},
        {"tlDraftModel", "Synchronized draft model: tlDraftModel [terralogic|mr]", "consoleCommandDraftModel"},
        {"tlTestStart", "Open and record one panel: tlTestStart <panel> <name>", "consoleCommandCaptureTestStart"},
        {"tlTestStop", "Write the final sample and stop the active test CSV", "consoleCommandCaptureTestStop"},
        {"tlTestStatus", "Show the active test recording", "consoleCommandCaptureTestStatus"},
        {"tlTestPanels", "List recommended panels for tlTestStart", "consoleCommandCaptureTestPanels"},
        {"tlSoilTrace", "Detailed WorkArea soil trace: tlSoilTrace <start [name]|stop|status>", "consoleCommandSoilTrace"},
        {"tlSoil", "Inspect TerraLogic soil values at the player", "consoleCommandSoil"},
        {"tlSimulatePass", "Simulate one soil pass: tlSimulatePass <implement> <speedKph> <shopSpeedKph>", "consoleCommandSimulatePass"},
        {"tlTrafficPreset", "Traffic test field/environment: tlTrafficPreset <dry|normal|wet|frozen|natural> [confirm]", "consoleCommandTrafficPreset"},
        {"tlTestEnvironment", "Session-only environment, no soil reset: tlTestEnvironment <dry|normal|wet|frozen|natural|status>", "consoleCommandTestEnvironment"},
        {"tlTestSoilType", "Session-only TerraLogic comparison soil: tlTestSoilType <loamySand|sandyLoam|loam|siltyClay|auto>", "consoleCommandTestSoilType"},
        {"tlTestSectionPreset", "Reset one isolated test section: tlTestSectionPreset confirm", "consoleCommandTestSectionPreset"},
        {"tlRepairFieldPreset", "Reinitialize only the current owned field from its live state", "consoleCommandRepairFieldPreset"},
        {"tlReinitializeFieldPresets", "Reset every standard field preset: tlReinitializeFieldPresets confirm", "consoleCommandReinitializeFieldPresets"},
        {"tlWheel", "Inspect TerraLogic wheel-load compaction", "consoleCommandWheelCompaction"},
        {"tlTutorialStatus", "Show TerraLogic tutorial status", "consoleCommandTutorialStatus"},
        {"tlTutorialReset", "Reset all TerraLogic tutorials", "consoleCommandTutorialReset"},
        {"tlTutorialShow", "Show one tutorial: tlTutorialShow <id>", "consoleCommandTutorialShow"}
    }
    for _, command in ipairs(commands) do
        addConsoleCommand(command[1], command[2], command[3], self)
    end
end

-- Saves both the quality ledger and the server-controlled settings.
function TerraLogicMain.saveWorkQualityData()
    TerraLogicQualityManager:save()
    TerraLogicGrassGapManager:save()
    TerraLogicSoilTemperatureManager:save()
    TerraLogicSoilMoistureManager:save()
    TerraLogicSoilManager:save()
    TerraLogicSettings:save()
end

-- Performs small deferred maintenance tasks without creating frame-time spikes.
function TerraLogicMain:update(dt)
    if TerraLogicPFYieldBridge ~= nil then TerraLogicPFYieldBridge:tick() end
    if TerraLogicPFHarvestTrace ~= nil and TerraLogicPFHarvestTrace.active ~= nil then
        TerraLogicPFHarvestTrace.safe("tick")
    end
    -- Old saves are cleaned incrementally to avoid a load-time density-map
    -- spike on large maps. The smaller budget changes only cleanup duration,
    -- never the stored quality result.
    TerraLogicQualityManager:processStoredCellPrune(16, 512)
    TerraLogicQualityManager:flushPendingMowerClears()
    TerraLogicQualityManager:flushPendingHarvestClears(nil, 4)
    TerraLogicQualityManager:updatePlowGrowthRecovery(dt)
    TerraLogicGrassGapManager:update(dt)
    TerraLogicSoilTemperatureManager:update(dt)
    TerraLogicSoilMoistureManager:update(dt)
    TerraLogicSoilManager:update(dt)
    TerraLogicWheelCompactionManager:update(dt)
    TerraLogicTrafficWarnings:update(dt)
    TerraLogicTutorialManager:update(dt)
    if TerraLogicAuditManager ~= nil then
        TerraLogicAuditManager:update(dt, self)
    end
    self:updatePanelLogger(dt)
    self:updateSoilDisplayBindings()
    TerraLogicSettings:tryInstallMenu()
end

local function getLocalControlledVehicle()
    if g_localPlayer ~= nil and g_localPlayer.getCurrentVehicle ~= nil then
        local vehicle = g_localPlayer:getCurrentVehicle()
        if vehicle ~= nil then return vehicle, "player" end
    end
    if g_currentMission ~= nil then
        if g_currentMission.controlledVehicle ~= nil then
            return g_currentMission.controlledVehicle, "mission"
        end
        if g_currentMission.getControlledVehicle ~= nil then
            local vehicle = g_currentMission:getControlledVehicle()
            if vehicle ~= nil then return vehicle, "missionMethod" end
        end
    end
    return nil, "foot"
end

function TerraLogicMain:setSoilDisplayMode(mode)
    local controlledVehicle, controlSource = getLocalControlledVehicle()
    mode = math.clamp(tonumber(mode) or 0, 0,
        #TerraLogicSoilManager.layers)
    TerraLogicSettings.vehicleSoilMapMode = mode
    TerraLogicSoilManager:setMapMode(mode)
    TerraLogicLogging.debug(
        "[FS25_TerraLogic] Soil display input: vehicle=%s source=%s mode=%d",
        tostring(controlledVehicle), tostring(controlSource), mode)
    local keys = {
        "terraLogic_soilMapOff", "terraLogic_soilMapSurface",
        "terraLogic_soilMapDeep", "terraLogic_soilMapAggregate",
        "terraLogic_soilMapRoughness", "terraLogic_soilMapResilience"
    }
    local message = g_i18n:getText(keys[mode + 1])
    TerraLogicSettings:saveLocal()
    if g_currentMission ~= nil and g_currentMission.addIngameNotification ~= nil
        and FSBaseMission ~= nil then
        g_currentMission:addIngameNotification(
            FSBaseMission.INGAME_NOTIFICATION_INFO, message)
    end
end

function TerraLogicMain:onToggleSoilDisplay()
    -- ALT+T controls one persistent minimap state everywhere. Leaving a
    -- vehicle or stepping off the field must not silently switch the action
    -- to the unrelated field-info HUD.
    local mode = (tonumber(TerraLogicSettings.vehicleSoilMapMode) or 0) + 1
    if mode > #TerraLogicSoilManager.layers then mode = 0 end
    self:setSoilDisplayMode(mode)
end

function TerraLogicMain:onCycleSoilDisplayBack()
    local mode = (tonumber(TerraLogicSettings.vehicleSoilMapMode) or 0) - 1
    if mode < 0 then mode = #TerraLogicSoilManager.layers end
    self:setSoilDisplayMode(mode)
end

function TerraLogicMain:toggleSoilDisplayMode(mode)
    local current = tonumber(TerraLogicSettings.vehicleSoilMapMode) or 0
    self:setSoilDisplayMode(current == mode and 0 or mode)
end

function TerraLogicMain:onShowSoilSurface() self:toggleSoilDisplayMode(1) end
function TerraLogicMain:onShowSoilDeep() self:toggleSoilDisplayMode(2) end
function TerraLogicMain:onShowSoilTilth() self:toggleSoilDisplayMode(3) end
function TerraLogicMain:onShowSoilEvenness() self:toggleSoilDisplayMode(4) end
function TerraLogicMain:onShowSoilResilience() self:toggleSoilDisplayMode(5) end


local SOIL_DISPLAY_ACTIONS = {
    {name="TERRALOGIC_TOGGLE_SOIL_DISPLAY",
        callback=TerraLogicMain.onToggleSoilDisplay, showHelp=true},
    {name="TERRALOGIC_CYCLE_SOIL_DISPLAY_BACK",
        callback=TerraLogicMain.onCycleSoilDisplayBack, showHelp=true},
    {name="TERRALOGIC_SHOW_SOIL_SURFACE",
        callback=TerraLogicMain.onShowSoilSurface},
    {name="TERRALOGIC_SHOW_SOIL_DEEP",
        callback=TerraLogicMain.onShowSoilDeep},
    {name="TERRALOGIC_SHOW_SOIL_TILTH",
        callback=TerraLogicMain.onShowSoilTilth},
    {name="TERRALOGIC_SHOW_SOIL_EVENNESS",
        callback=TerraLogicMain.onShowSoilEvenness},
    {name="TERRALOGIC_SHOW_SOIL_RESILIENCE",
        callback=TerraLogicMain.onShowSoilResilience}
}

local function configureSoilDisplayActionEvent(eventId, definition)
    if eventId == nil then return end
    g_inputBinding:setActionEventText(eventId,
        g_i18n:getText("input_" .. definition.name))
    g_inputBinding:setActionEventTextPriority(eventId, GS_PRIO_LOW)
    g_inputBinding:setActionEventTextVisibility(eventId,
        definition.showHelp == true)
end

function TerraLogicMain.registerSoilDisplayActionEvent()
    if g_inputBinding == nil or InputAction == nil then return end
    TerraLogicMain.soilDisplayActionEventIds = {}
    for _, definition in ipairs(SOIL_DISPLAY_ACTIONS) do
        local inputAction = InputAction[definition.name]
        if inputAction ~= nil then
            local _, eventId = g_inputBinding:registerActionEvent(
                inputAction, TerraLogicMain, definition.callback,
                false, true, false, true, nil, true)
            if eventId ~= nil then
                table.insert(TerraLogicMain.soilDisplayActionEventIds, eventId)
                configureSoilDisplayActionEvent(eventId, definition)
            end
        end
    end
    TerraLogicLogging.debug(
        "[FS25_TerraLogic] Soil display actions registered in player context: %d",
        #TerraLogicMain.soilDisplayActionEventIds)
end

-- FS25 owns separate action-event contexts for the player and the controlled
-- vehicle. A mission-global registration is discarded when either context is
-- rebuilt, which is why the binding appeared in the menu but never fired.
function TerraLogicMain.registerPlayerSoilDisplayActionEvent(inputComponent)
    if inputComponent == nil or inputComponent.player == nil
        or not inputComponent.player.isOwner then return end
    g_inputBinding:beginActionEventsModification(
        PlayerInputComponent.INPUT_CONTEXT_NAME)
    TerraLogicMain.registerSoilDisplayActionEvent()
    g_inputBinding:endActionEventsModification()
end

function TerraLogicMain.registerVehicleSoilDisplayActionEvent(
        vehicle, isActiveForInput, isActiveForInputIgnoreSelection)
    -- Enterable is still inside the engine's registration transaction here.
    -- Queue our own bindings; do not nest a registration context or request
    -- a full vehicle rebuild while a third-party HUD owns input.
    local player = g_localPlayer
    local controlled = player ~= nil and player.getCurrentVehicle ~= nil
        and player:getCurrentVehicle() or nil
    if vehicle == nil or vehicle ~= controlled then return end
    TerraLogicMain.soilDisplayBindingsPending = true
    TerraLogicLogging.debug(
        "[FS25_TerraLogic] Soil bindings queued (active=%s ignoreSelection=%s)",
        tostring(isActiveForInput), tostring(isActiveForInputIgnoreSelection))
end

function TerraLogicMain:clearVehicleSoilDisplayBindings()
    if g_inputBinding ~= nil then
        for _, eventId in ipairs(self.soilDisplayVehicleEventIds or {}) do
            g_inputBinding:removeActionEvent(eventId)
        end
    end
    self.soilDisplayVehicleEventIds = nil
end

function TerraLogicMain:updateSoilDisplayBindings()
    if g_inputBinding == nil or InputAction == nil or Vehicle == nil then return end
    local player = g_localPlayer
    local controlled = player ~= nil and player.getCurrentVehicle ~= nil
        and player:getCurrentVehicle() or nil
    local context = g_inputBinding:getContextName()
    local changedVehicle = controlled ~= self.soilDisplayBindingVehicle
    local returnedToVehicle = context == Vehicle.INPUT_CONTEXT_NAME
        and self.soilDisplayBindingContext ~= context
    if changedVehicle then
        self:clearVehicleSoilDisplayBindings()
        self.soilDisplayBindingVehicle = controlled
        self.soilDisplayBindingsPending = controlled ~= nil
    end
    if returnedToVehicle and controlled ~= nil then
        self.soilDisplayBindingsPending = true
    end
    if changedVehicle or context ~= self.soilDisplayBindingContext then
        TerraLogicLogging.debug(
            "[FS25_TerraLogic] Soil binding context: %s vehicle=%s pending=%s",
            tostring(context), tostring(controlled),
            tostring(self.soilDisplayBindingsPending == true))
    end
    self.soilDisplayBindingContext = context
    if controlled == nil or not self.soilDisplayBindingsPending
        or context ~= Vehicle.INPUT_CONTEXT_NAME then return end
    if controlled.getIsEntered == nil or not controlled:getIsEntered() then return end
    if g_gui ~= nil and g_gui.getIsGuiVisible ~= nil
        and g_gui:getIsGuiVisible() then return end

    -- Only replace our seven bindings, once per rebuild/context return.
    -- Never switch input contexts, remove foreign events or touch Enterable's
    -- actionEvents table. No timer competes with QuickSelector's entry timer.
    g_inputBinding:beginActionEventsModification(Vehicle.INPUT_CONTEXT_NAME)
    self:clearVehicleSoilDisplayBindings()
    self.soilDisplayVehicleEventIds = {}
    local registered = 0
    for _, definition in ipairs(SOIL_DISPLAY_ACTIONS) do
        local inputAction = InputAction[definition.name]
        if inputAction ~= nil then
            local _, eventId = g_inputBinding:registerActionEvent(
                inputAction,
                TerraLogicMain, definition.callback,
                false, true, false, true, nil, true)
            if eventId ~= nil then
                registered = registered + 1
                table.insert(self.soilDisplayVehicleEventIds, eventId)
                configureSoilDisplayActionEvent(eventId, definition)
            end
        end
    end
    g_inputBinding:endActionEventsModification()
    self.soilDisplayBindingsPending = false
    TerraLogicLogging.debug(
        "[FS25_TerraLogic] Soil bindings ready: %d/7 vehicle=%s context=%s",
        registered, tostring(controlled), tostring(g_inputBinding:getContextName()))
end

local function getIsLocalControlledImplement(implement)
    local controlledVehicle = g_localPlayer ~= nil
        and g_localPlayer:getCurrentVehicle() or nil
    local rootVehicle = implement ~= nil
        and (implement.rootVehicle or implement) or nil
    return controlledVehicle ~= nil and rootVehicle ~= nil
        and (controlledVehicle == implement or controlledVehicle == rootVehicle
            or controlledVehicle.rootVehicle == rootVehicle)
end

function TerraLogicMain:queueWorkHudWarning(
        implement, priority, durationMs, titleKey, titleFallback,
        detailKey, detailFallback, detailValue, severity)
    if not getIsLocalControlledImplement(implement) then return end
    local now = g_currentMission ~= nil and (g_currentMission.time or 0) or 0
    local title = TerraLogicQualityManager ~= nil
        and TerraLogicQualityManager:getText(titleKey, titleFallback)
        or titleFallback
    local detail = TerraLogicQualityManager ~= nil
        and TerraLogicQualityManager:getText(detailKey, detailFallback)
        or detailFallback
    if detailValue ~= nil then
        local ok, formatted = pcall(TerraLogicI18n.format, detail, detailValue)
        if ok then detail = formatted end
    end
    -- Discrete events join the same queue as continuous causes. Repeated stone
    -- contacts of the same kind update one pending entry instead of producing
    -- a popup cascade. A generous lifetime guarantees that a queued event is
    -- still shown once even when several more important causes are ahead of it.
    self.workHudEventWarnings = self.workHudEventWarnings or {}
    local id = "event:" .. tostring(titleKey or titleFallback or "warning")
    self.workHudEventWarnings[id] = {
        id = id,
        implement = implement,
        priority = priority or 0,
        severity = severity or "caution",
        title = title,
        detail = detail,
        oneShot = true,
        createdAt = now,
        expiresAt = now + math.max(
            tonumber(durationMs) or 5000,
            self.WORK_HUD_WARNING_EVENT_LIFETIME_MS,
            (TerraLogicSettings ~= nil
                and TerraLogicSettings.getWarningDisplayDurationMs ~= nil
                and TerraLogicSettings:getWarningDisplayDurationMs()
                or self.WORK_HUD_WARNING_SLOT_MS)
                * (tonumber(self.WORK_HUD_WARNING_MAX_QUEUE) or 5) + 5000)
    }
end

function TerraLogicMain:handleConditionWarningActivation(implement)
    local spec = implement ~= nil and implement.spec_terraLogic or nil
    if self.enabled == false or spec == nil or implement.getDamageAmount == nil then
        return
    end
    if not getIsLocalControlledImplement(implement) then return end

    -- Previous blinking 75/90/100-percent notifications are intentionally
    -- retired.  The fixed work HUD colors condition continuously and renders a
    -- persistent repair warning at complete damage without notification spam.
end

function TerraLogicMain:handleStoneImpactWarning(implement)
    if self.enabled == false or not getIsLocalControlledImplement(implement) then
        return
    end
    if TerraLogicSettings ~= nil
        and TerraLogicSettings.getDamageWarningsEnabled ~= nil
        and not TerraLogicSettings:getDamageWarningsEnabled() then return end
    local spec = implement ~= nil and implement.spec_terraLogic or nil
    TerraLogicTutorialManager:observeStone(implement)
    local underground = spec == nil
        or spec.damageWarningStoneSource ~= "surface"
    local damage = math.max(tonumber(spec ~= nil
        and spec.damageWarningStoneDamage) or 0, 0)
    local severity = damage >= 0.005 and "critical" or "caution"
    self:queueWorkHudWarning(
        implement, severity == "critical" and 90 or 77, 4500,
        underground and "terraLogic_workHudUndergroundStoneTitle"
            or "terraLogic_workHudSurfaceStoneTitle",
        underground and "UNDERGROUND STONE IMPACT" or "STONE IMPACT",
        "terraLogic_workHudStoneDetail",
        "Implement damage +%.1f %%",
        damage * 100,
        severity)
end

function TerraLogicMain:handleHighDamagePerHectareWarning(implement)
    -- Retired: a per-hectare popup mixed continuous wear with contextual
    -- events and was easy to misread. The new HUD shows load and wear state.
end

-- Flushes data and releases HUD resources when leaving a mission.
function TerraLogicMain:deleteMap()
    if TerraLogicPFYieldBridge ~= nil then TerraLogicPFYieldBridge:delete() end
    if TerraLogicWarningEpisodes ~= nil then TerraLogicWarningEpisodes.vehicles = nil end
    if TerraLogicPFHarvestTrace ~= nil and TerraLogicPFHarvestTrace.active ~= nil then
        TerraLogicPFHarvestTrace.active:stop("mission closed")
    end
    if self.soilTraceLogger ~= nil
        and self.soilTraceLogger.active == true then
        self:stopSoilTrace("mission closed")
    end
    if self.panelLogger ~= nil and self.panelLogger.active == true then
        self:stopPanelLogger("mission closed")
    end
    -- FSBaseMission.saveSavegame already persists every TerraLogic manager on
    -- manual save and autosave. Do not save again merely because the player
    -- leaves the mission: "quit without saving" must also roll back developer
    -- presets and soil changes, just like the base game's field work.
    TerraLogicGrassGapManager:delete(false)
    if TerraLogicAuditManager ~= nil then
        TerraLogicAuditManager:delete(self)
    end
    TerraLogicSoilTemperatureManager:delete(false)
    TerraLogicSoilMoistureManager:delete(false)
    TerraLogicWheelCompactionManager:delete()
    TerraLogicTrafficWarnings:delete()
    TerraLogicTutorialManager:delete()
    TerraLogicSoilManager:delete(false)
    if g_inputBinding ~= nil then
        for _, eventId in ipairs(self.soilDisplayActionEventIds or {}) do
            g_inputBinding:removeActionEvent(eventId)
        end
    end
    self.soilDisplayActionEventIds = nil
    self:clearVehicleSoilDisplayBindings()
    self.soilDisplayBindingVehicle = nil
    self.soilDisplayBindingContext = nil
    self.soilDisplayBindingsPending = nil
    self:deleteSpeedHudOverlays()
    self:clearQualityFieldInfoRows()
    if self.qualityInfoBox ~= nil and g_currentMission ~= nil
        and g_currentMission.hud ~= nil
        and g_currentMission.hud.infoDisplay ~= nil then
        g_currentMission.hud.infoDisplay:destroyBox(self.qualityInfoBox)
    end
    self.qualityInfoBox = nil
    if self.soilInfoBox ~= nil and g_currentMission ~= nil
        and g_currentMission.hud ~= nil
        and g_currentMission.hud.infoDisplay ~= nil then
        g_currentMission.hud.infoDisplay:destroyBox(self.soilInfoBox)
    end
    self.soilInfoBox = nil
    if self.balanceTestImplement ~= nil then
        local spec = self.balanceTestImplement.spec_terraLogic
        if spec ~= nil and spec.balanceTest ~= nil then
            spec.balanceTest.active = false
        end
        self.balanceTestImplement = nil
    end
    for _, name in ipairs({
            "tlDebug", "tlView", "tlViews", "tlDebugClose", "tlSetDamage", "tlDamageAnalysis",
            "tlPF", "tlPFInspect", "tlEnable", "tlWearPolicy", "tlAbrasion",
            "tlResistance", "tlDraft", "tlImpacts", "tlStones", "tlMowerQuality", "tlMultiplier",
            "tlBalanceReset", "tlPrintBalance", "tlLog", "tlDraftModel",
            "tlTestStart", "tlTestStop", "tlTestStatus", "tlTestPanels",
            "tlSoilTrace", "tlSoil",
            "tlSimulatePass", "tlTrafficPreset", "tlTestSoilType",
            "tlTestSectionPreset", "tlTestEnvironment",
            "tlRepairFieldPreset", "tlReinitializeFieldPresets", "tlWheel",
            "tlTutorialStatus", "tlTutorialReset", "tlTutorialShow"
        }) do
        removeConsoleCommand(name)
    end
end

function TerraLogicMain:consoleCommandTutorialStatus()
    return TerraLogicTutorialManager:consoleStatus()
end

function TerraLogicMain:consoleCommandTutorialReset()
    TerraLogicTutorialManager:requestReset()
    return "TerraLogic tutorial reset requested"
end

function TerraLogicMain:consoleCommandTutorialShow(id)
    return TerraLogicTutorialManager:consoleShow(id)
end

-- Console command helpers ----------------------------------------------------

-- Converts common textual on/off values into a boolean.
local function parseEnabled(value)
    value = value ~= nil and string.lower(tostring(value)) or ""
    if value == "on" or value == "true" or value == "1" then
        return true
    end
    if value == "off" or value == "false" or value == "0" then
        return false
    end
    return nil
end

local VIRTUAL_PASS_CLASS_ALIASES = {
    plow="plow", plough="plow", pflug="plow",
    subsoiler="subsoiler", tiefenlockerer="subsoiler",
    cultivator="cultivator", grubber="cultivator",
    shallowcultivator="shallowCultivator", flachgrubber="shallowCultivator",
    discharrow="discHarrow", scheibenegge="discHarrow",
    powerharrow="powerHarrow", kreiselegge="powerHarrow",
    spader="spader", spatenmaschine="spader",
    roller="roller", walze="roller",
    sowingmachine="sowingMachine", seeder="sowingMachine",
    saemaschine="sowingMachine", ["sämaschine"]="sowingMachine",
    directdrill="directDrill", direktsaat="directDrill",
    precisionplanter="precisionPlanter", planter="precisionPlanter",
    einzelkorn="precisionPlanter",
    precisiondirectdrill="precisionDirectDrill",
    einzelkorndirektsaat="precisionDirectDrill"
}

local function getConsolePlayerPosition()
    local node = g_localPlayer ~= nil and g_localPlayer.rootNode or nil
    local vehicle = g_localPlayer ~= nil
        and g_localPlayer:getCurrentVehicle() or nil
    if vehicle ~= nil then
        node = vehicle.rootNode or (vehicle.components ~= nil
            and vehicle.components[1] ~= nil and vehicle.components[1].node)
    end
    if node == nil then return nil, nil end
    local x, _, z = getWorldTranslation(node)
    return x, z
end

function TerraLogicMain:consoleCommandSimulatePass(
        implementName, speedKph, shopSpeedKph)
    local token = string.lower(tostring(implementName or ""))
    if token == "" or token == "status" then
        return "Usage: tlSimulatePass <implement> <speedKph> <shopSpeedKph> | "
            .. TerraLogicSoilManager:getVirtualImplementPassStatus()
    end
    if token == "list" then
        return "Implements: plow, subsoiler, cultivator, shallowCultivator, "
            .. "discHarrow, powerHarrow, spader, roller, sowingMachine, "
            .. "directDrill, precisionPlanter, precisionDirectDrill"
    end
    local classKey = VIRTUAL_PASS_CLASS_ALIASES[token]
    if classKey == nil then
        return "TerraLogic virtual pass: unknown implement '"
            .. tostring(implementName) .. "'; use tlSimulatePass list"
    end
    local speed, shop = tonumber(speedKph), tonumber(shopSpeedKph)
    if speed == nil or shop == nil then
        return "Usage: tlSimulatePass <implement> <speedKph> <shopSpeedKph>"
    end
    local x, z = getConsolePlayerPosition()
    if x == nil then
        return "TerraLogic virtual pass: player position unavailable"
    end
    if g_server ~= nil then
        local ok, message = TerraLogicSoilManager:
            queueVirtualImplementPassAtWorldPosition(
                x, z, classKey, speed, shop)
        return "TerraLogic virtual pass: "
            .. (ok and "OK - " or "FAILED - ") .. tostring(message)
    end
    local connection = g_client ~= nil and g_client.getServerConnection ~= nil
        and g_client:getServerConnection() or nil
    if connection == nil or TerraLogicVirtualImplementPassEvent == nil then
        return "TerraLogic virtual pass: server connection unavailable"
    end
    connection:sendEvent(TerraLogicVirtualImplementPassEvent.new(
        x, z, classKey, speed, shop))
    return string.format(
        "TerraLogic virtual pass requested: %s %.1f km/h (shop %.1f)",
        classKey, speed, shop)
end

-- Deliberately separate from traffic presets: never calls a soil, crop,
-- history or field-reset operation. Existing managers own the session-only
-- overrides and their normal network/save behavior.
function TerraLogicMain:consoleCommandTestEnvironment(presetName)
    local name = string.lower(tostring(presetName or "status"))
    local moisture = TerraLogicSoilMoistureManager
    local temperature = TerraLogicSoilTemperatureManager
    if name == "" or name == "status" then
        return string.format("TerraLogic test environment: moisture=%s; temperature=%s. Session-only; reapply after loading. Soil values are not reset.",
            moisture ~= nil and moisture.auditOverridePreset or "natural",
            temperature ~= nil and temperature.auditOverridePreset or "natural")
    end
    if name == "off" then name = "natural" end
    if name ~= "dry" and name ~= "normal" and name ~= "wet"
        and name ~= "frozen" and name ~= "natural" then
        return "Usage: tlTestEnvironment <dry|normal|wet|frozen|natural|status> (no soil reset)"
    end
    if g_server == nil then
        return "TerraLogic test environment: run this command on the server/host"
    end
    -- Validate both managers before changing either override.
    if moisture == nil or temperature == nil
        or moisture.initialized ~= true or temperature.initialized ~= true
        or moisture.setAuditPreset == nil or temperature.setAuditPreset == nil then
        return "TerraLogic test environment: managers not ready; no changes applied"
    end
    local moistureOk, moistureMessage = moisture:setAuditPreset(name)
    local temperatureOk, temperatureMessage = temperature:setAuditPreset(name)
    if not moistureOk or not temperatureOk then
        return "TerraLogic test environment: FAILED - "
            .. tostring(moistureMessage) .. "; " .. tostring(temperatureMessage)
    end
    if TerraLogicAuditManager ~= nil then
        TerraLogicAuditManager.runtimeEnvironmentPreset = name ~= "natural" and name or nil
        TerraLogicAuditManager.panelCache = nil
    end
    return "TerraLogic test environment: " .. name .. " - "
        .. tostring(moistureMessage) .. "; " .. tostring(temperatureMessage)
        .. ". Soil/crops/history unchanged. Session-only; reapply after loading."
end

function TerraLogicMain:consoleCommandTrafficPreset(presetName, confirmation)
    local name = string.lower(tostring(presetName or ""))
    if name == "" or name == "list" then
        return "TerraLogic traffic presets: dry, normal, wet, frozen, natural. "
            .. "A test preset resets the complete native field beneath the "
            .. "player; use: tlTrafficPreset <name> confirm"
    end
    if name ~= "natural" and name ~= "off"
        and string.lower(tostring(confirmation or "")) ~= "confirm" then
        return "TerraLogic: this resets the complete native field beneath "
            .. "the player. Use: tlTrafficPreset " .. name .. " confirm"
    end
    local x, z = getConsolePlayerPosition()
    if x == nil then
        return "TerraLogic traffic preset: player position unavailable"
    end
    if g_server ~= nil then
        local ok, message = TerraLogicSoilManager:
            applyTrafficTestPresetAtWorldPosition(x, z, name)
        return "TerraLogic traffic preset: "
            .. (ok and "OK - " or "FAILED - ") .. tostring(message)
    end
    local connection = g_client ~= nil and g_client.getServerConnection ~= nil
        and g_client:getServerConnection() or nil
    if connection == nil or TerraLogicTrafficTestPresetEvent == nil then
        return "TerraLogic traffic preset: server connection unavailable"
    end
    connection:sendEvent(
        TerraLogicTrafficTestPresetEvent.new(x, z, name))
    if TerraLogicAuditManager ~= nil then
        local natural = name == "natural" or name == "off"
        TerraLogicAuditManager.runtimeEnvironmentPreset =
            natural and nil or name
        TerraLogicAuditManager.runtimeSoilPreset =
            natural and nil or "trafficBaseline"
    end
    return "TerraLogic traffic preset requested from server: " .. name
end

function TerraLogicMain:consoleCommandTestSoilType(name)
    if g_server == nil then
        return "TerraLogic comparison soil: run this command on the server/host"
    end
    local ok, message = TerraLogicSoilManager:
        setTestSoilTypeOverride(name)
    return "TerraLogic comparison soil: "
        .. (ok and "OK - " or "FAILED - ") .. tostring(message)
end

function TerraLogicMain:consoleCommandTestSectionPreset(confirmation)
    if string.lower(tostring(confirmation or "")) ~= "confirm" then
        return "TerraLogic: this resets only the connected, cultivatable test section beneath the player. Separate plots with at least 10 m of non-field ground. Use: tlTestSectionPreset confirm"
    end
    if g_server == nil then
        return "TerraLogic section preset: run this command on the server/host"
    end
    local x, z = getConsolePlayerPosition()
    if x == nil then
        return "TerraLogic section preset: player position unavailable"
    end
    local ok, message = TerraLogicSoilManager:
        setTestSectionBaselineAtWorldPosition(x, z)
    return "TerraLogic section preset: "
        .. (ok and "OK - " or "FAILED - ") .. tostring(message)
end

function TerraLogicMain:consoleCommandRepairFieldPreset()
    local node = g_localPlayer ~= nil and g_localPlayer.rootNode or nil
    local vehicle = g_localPlayer ~= nil
        and g_localPlayer:getCurrentVehicle() or nil
    if vehicle ~= nil then
        node = vehicle.rootNode or (vehicle.components ~= nil
            and vehicle.components[1] ~= nil and vehicle.components[1].node)
    end
    if node == nil then
        return "TerraLogic field preset repair: player position unavailable"
    end
    local x, _, z = getWorldTranslation(node)
    if g_server ~= nil then
        local ok, message = TerraLogicSoilManager:
            queueOwnedFieldPresetRepairAtWorldPosition(x, z)
        return "TerraLogic field preset repair: "
            .. (ok and "OK - " or "FAILED - ") .. tostring(message)
    end
    local connection = g_client ~= nil and g_client.getServerConnection ~= nil
        and g_client:getServerConnection() or nil
    if connection == nil or TerraLogicOwnedFieldPresetRepairEvent == nil then
        return "TerraLogic field preset repair: server connection unavailable"
    end
    connection:sendEvent(
        TerraLogicOwnedFieldPresetRepairEvent.new(x, z))
    return "TerraLogic field preset repair requested from server"
end

function TerraLogicMain:consoleCommandReinitializeFieldPresets(confirmation)
    if string.lower(tostring(confirmation or "")) ~= "confirm" then
        return "TerraLogic: this replaces the soil history of every standard "
            .. "NPC and player field. Use: tlReinitializeFieldPresets confirm"
    end
    if g_server ~= nil then
        local ok, message = TerraLogicSoilManager:
            requestAllFieldPresetReinitialization()
        return "TerraLogic full field-preset reinitialization: "
            .. (ok and "OK - " or "FAILED - ") .. tostring(message)
    end
    local connection = g_client ~= nil and g_client.getServerConnection ~= nil
        and g_client:getServerConnection() or nil
    if connection == nil
        or TerraLogicAllFieldPresetReinitializationEvent == nil then
        return "TerraLogic full field-preset reinitialization: "
            .. "server connection unavailable"
    end
    connection:sendEvent(
        TerraLogicAllFieldPresetReinitializationEvent.new())
    return "TerraLogic full field-preset reinitialization requested from server"
end

function TerraLogicMain:consoleCommandSoil()
    local node = g_localPlayer ~= nil and g_localPlayer.rootNode or nil
    local vehicle = g_localPlayer ~= nil and g_localPlayer:getCurrentVehicle() or nil
    if vehicle ~= nil then
        node = vehicle.rootNode or (vehicle.components ~= nil
            and vehicle.components[1] ~= nil and vehicle.components[1].node)
    end
    if node == nil then return "TerraLogic soil: player position unavailable" end
    local x, _, z = getWorldTranslation(node)
    local state = TerraLogicSoilManager:getStateAtWorldPosition(x, z)
    local recoveryAge = TerraLogicSoilManager:getRecoveryAgeAtWorldPosition(
        x, z)
    local recoveryCover = TerraLogicSoilManager:getRecoveryCoverAtWorldPosition(
        x, z)
    local temperature = TerraLogicSoilTemperatureManager:getState()
    local moisture = TerraLogicSoilMoistureManager:getStateAtWorldPosition(x, z)
    local moistureSystem = TerraLogicSoilMoistureManager:getState()
    local developmentSpeed = TerraLogicSettings:getSoilDevelopmentSpeed()
    local recovery = TerraLogicSoilManager:
        getNaturalRecoveryDebugAtWorldPosition(x, z)
    local raw = {}
    for _, layer in ipairs(TerraLogicSoilManager.layers) do
        raw[#raw + 1] = TerraLogicSoilManager:getRawAtWorldPosition(
            layer.id, x, z)
    end
    local cellCoordinates = {}
    for _, layer in ipairs(TerraLogicSoilManager.layers) do
        local size = tonumber(layer.cellSize) or TerraLogicSoilManager.CELL_SIZE
        cellCoordinates[#cellCoordinates + 1] = string.format(
            "%s=%d:%d@%gm", string.sub(layer.id, 1, 1),
            math.floor(x / size), math.floor(z / size), size)
    end
    local lastPass = TerraLogicSoilManager.lastPass
    local lastWrite = TerraLogicSoilManager.lastWrite
    local diagnostic = lastPass ~= nil and string.format(
        " | last %s: coverage %.1f, touched %d, field %d, changed %d cells/%d layers, speed %.1f/%.1f km/h (x%.2f), soil overspeed %.0f%%",
        tostring(lastPass.classKey), tonumber(lastPass.coverage) or 0,
        tonumber(lastPass.touchedCells) or 0,
        tonumber(lastPass.eligibleCells) or 0,
        tonumber(lastPass.changedCells) or 0,
        tonumber(lastPass.changedLayers) or 0,
        tonumber(lastPass.speedKph) or 0,
        tonumber(lastPass.speedReferenceKph) or 0,
        tonumber(lastPass.speedRatio) or 0,
        (tonumber(lastPass.overspeedSeverity) or 0) * 100)
        or " | no soil pass recorded"
    if lastWrite ~= nil then
        diagnostic = diagnostic .. string.format(
            " | last write %s cell %d:%d = %.3f",
            tostring(lastWrite.layerId), tonumber(lastWrite.ix) or 0,
            tonumber(lastWrite.iz) or 0, tonumber(lastWrite.value) or 0)
    end
    diagnostic = diagnostic .. string.format(
        " | recovery queue %d%s",
        tonumber(TerraLogicSoilManager.recoveryPendingPasses) or 0,
        TerraLogicSoilManager.recoveryJob ~= nil and "+running"
            or (TerraLogicSoilManager.recoveryPending == true
                and "+waiting" or ""))
    diagnostic = diagnostic .. string.format(
        " | temperature air %.2fC, soil %.2fC@%dcm / %.2fC@%dcm, last day %.2fC (next %.0f%%), climate %.2fC, calendar %g d/period x%.2f, spin-up %.0f%% (%s)",
        temperature.airTemperatureC,
        temperature.surfaceTemperatureC,
        temperature.surfaceDepthCm,
        temperature.subsoilTemperatureC,
        temperature.subsoilDepthCm,
        temperature.dailyMeanTemperatureC,
        temperature.dailySampleFraction * 100,
        temperature.climateMeanTemperatureC,
        temperature.daysPerPeriod,
        temperature.calendarScale,
        temperature.spinupFraction * 100,
        temperature.temperatureSource)
    diagnostic = diagnostic .. string.format(
        " | moisture %s%s: %.1f%%@%dcm / %.1f%%@%dcm, rain %.1f%%, game wetness %.1f%%, liquid %.1f%%, evap x%.2f (%s)",
        moisture.profileName, moisture.pfActive and "/PF" or "/fallback",
        moisture.surface * 100, moistureSystem.surfaceDepthCm,
        moisture.subsoil * 100, moistureSystem.subsoilDepthCm,
        moistureSystem.rainScale * 100,
        moistureSystem.groundWetness * 100,
        moistureSystem.liquidPrecipitationFactor * 100,
        moistureSystem.evaporationFactor,
        moistureSystem.weatherSource)
    diagnostic = diagnostic .. string.format(
        " | robust moisture surface/root/target %.1f/%.1f/%.1f%% period=%d history=%d observed/rain=%.1f/%.2fh last(root/rainDay/coverage)=%.1f%%/%.3fh/%.0f%% valid=%s dropped=%.2fh",
        moistureSystem.surfaceWetness * 100,
        moistureSystem.rootMoisture * 100,
        moistureSystem.climateMoistureTarget * 100,
        moistureSystem.periodSerial, moistureSystem.historyCount,
        moistureSystem.periodObservedHours,
        moistureSystem.periodLiquidRainHours,
        moistureSystem.lastRootMean * 100,
        moistureSystem.lastRainHoursPerDay,
        moistureSystem.lastObservationShare * 100,
        moistureSystem.weatherDataValid and "yes" or "NO",
        moistureSystem.droppedGameHours)
    local qualityIx = math.floor(x / TerraLogicQualityManager.CELL_SIZE)
    local qualityIz = math.floor(z / TerraLogicQualityManager.CELL_SIZE)
    local fruitTypeIndex, growthState = TerraLogicQualityManager:
        getGrowthStateAtCell(qualityIx, qualityIz)
    local growthStage = TerraLogicQualityManager:getSemanticPlowGrowthStage(
        fruitTypeIndex, growthState, nil)
    local soilTypeIndex = TerraLogicSoilManager:
        getPFSoilTypeAtWorldPosition(x, z)
    local moistureYield = TerraLogicSoilMoistureManager:
        getCropYieldResponse(soilTypeIndex, fruitTypeIndex,
            math.max(growthStage, 1))
    local position = {ix=qualityIx, iz=qualityIz}
    local storedRoot, storedSteps = TerraLogicQualityManager:
        getGrowthRootYieldFactor(position, false, true)
    local storedMoisture = TerraLogicQualityManager:
        getGrowthMoistureYieldFactor(position, false, true)
    diagnostic = diagnostic .. string.format(
        " | crop water yield %s: stage %d/3 sampled %d, current x%.3f (dry %.0f%% wet %.0f%% root/fc %.2f), projected moisture/root x%.3f/x%.3f",
        TerraLogicSettings:getMoistureYieldEnabled() and "ACTIVE" or "OFF",
        growthStage, storedSteps or 0, moistureYield.factor,
        moistureYield.drySeverity * 100, moistureYield.wetSeverity * 100,
        moistureYield.relativeToFieldCapacity,
        tonumber(storedMoisture) or 1, tonumber(storedRoot) or 1)
    diagnostic = diagnostic .. string.format(
        " | frost surface/deep %s/%s, duration %.1f/%.1fh, minimum %.2f/%.2fC, pending thaw %.3f/%.3f, cycles %.0f/%.0f | weather effects ACTIVE",
        temperature.surfaceFrozen and "FROZEN" or "open",
        temperature.subsoilFrozen and "FROZEN" or "open",
        temperature.surfaceFrozenHours, temperature.subsoilFrozenHours,
        temperature.surfaceFreezeMinimumC, temperature.subsoilFreezeMinimumC,
        temperature.pendingSurfaceThawPulse,
        temperature.pendingDeepThawPulse,
        temperature.surfaceFreezeThawCycles,
        temperature.deepFreezeThawCycles)
    diagnostic = diagnostic .. string.format(
        " | natural recovery %s age=%s setting=%dx resilience=%dx physical=%dx rest=%.3f env moisture/bio/surface/deep/thawS/thawD=%.3f/%.3f/%.3f/%.3f/%.3f/%.3f targets surface/deep/resilience=%.2f/%.2f/%.2f tilth=%s settling=%.2f",
        tostring(recovery.coverKey), recovery.ageMature
            and "15+" or tostring(recovery.ageMonths),
        recovery.developmentSpeed, recovery.resilienceDevelopmentSpeed,
        recovery.physicalDevelopmentSpeed, recovery.restFactor,
        recovery.moistureFactor, recovery.biologicalFactor,
        recovery.physicalSurfaceFactor, recovery.physicalDeepFactor,
        recovery.surfaceFrostFactor,
        recovery.deepFrostFactor,
        recovery.surfaceTarget, recovery.deepTarget,
        recovery.resilienceCeiling,
        recovery.tilthTarget ~= nil
            and string.format("%.2f", recovery.tilthTarget) or "physical-only",
        recovery.settlingTarget)
    diagnostic = diagnostic .. string.format(
        " | recovery history completed=%d pending=%d%s accumulating=%.1fh snapshot=%.1fh/%g days at %dx %.2f/%.2fC (%s)",
        recovery.completedPeriods, recovery.pendingPeriods,
        recovery.recoveryRunning and "+running" or "",
        recovery.accumulatorHours, recovery.snapshotHours,
        recovery.snapshotDaysPerPeriod,
        recovery.snapshotDevelopmentSpeed,
        recovery.snapshotSurfaceTemperatureC,
        recovery.snapshotSubsoilTemperatureC,
        tostring(recovery.snapshotSource))
    local network = TerraLogicSoilManager:getNetworkDebugData()
    diagnostic = diagnostic .. string.format(
        " | MP soil %s samples=%d tiles queued/sent/received/applied=%d/%d/%d/%d ack sent/received=%d/%d viewport radius/tiles=%d/%d server queue=%d peak=%d client apply=%d",
        tostring(network.role), network.samplesReceived,
        network.tilesQueued, network.tilesSent,
        network.tilesReceived, network.tilesApplied,
        network.tileAcksSent, network.tileAcksReceived,
        network.viewportRadius, network.visibleTiles,
        network.serverQueue, network.serverQueuePeak,
        network.clientApplyQueue)
    diagnostic = diagnostic .. TerraLogicMapMaintenance:getDebugText()
    local suitability = vehicle ~= nil and vehicle.spec_terraLogic ~= nil
        and vehicle.spec_terraLogic.soilSuitabilityContext or nil
    if suitability ~= nil then
        diagnostic = diagnostic .. string.format(
            " | suitability %s: WQ x%.3f (structure %.3f, environment %.3f), dropout %.1f%% (structure %.1f, environment %.1f), frost severity %.1f%% penetration %.1f%% WQ %.1f%% dropout %.1f%%, cells %d",
            tostring(suitability.classKey),
            tonumber(suitability.qualityFactor) or 1,
            tonumber(suitability.structuralQualityFactor) or 1,
            tonumber(suitability.moistureQualityFactor) or 1,
            (tonumber(suitability.dropoutFraction) or 0) * 100,
            (tonumber(suitability.structuralDropoutFraction) or 0) * 100,
            (tonumber(suitability.moistureDropoutFraction) or 0) * 100,
            (tonumber(suitability.frostSeverity) or 0) * 100,
            (tonumber(suitability.frostPenetrationFactor) or 1) * 100,
            (tonumber(suitability.frostQualityFactor) or 1) * 100,
            (tonumber(suitability.frostDropoutFraction) or 0) * 100,
            tonumber(suitability.eligibleCells) or 0)
    end
    local text = string.format(
        "TerraLogic soil @ %.1f %.1f cells %s | surface %.3f | deep %.3f | aggregate %.3f | roughness %.3f | resilience %.3f | recovery %s months/%s setting %dx resilience %dx physical %dx | raster %d/%d/%d/%d/%d%s",
        x, z, table.concat(cellCoordinates, " "),
        state.surfaceCompaction, state.deepCompaction,
        state.aggregateSize, state.roughness, state.resilience,
        recovery.ageMature and "15+" or tostring(recoveryAge),
        tostring(recoveryCover), developmentSpeed,
        recovery.resilienceDevelopmentSpeed,
        recovery.physicalDevelopmentSpeed,
        raw[1] or 0, raw[2] or 0, raw[3] or 0, raw[4] or 0,
        raw[5] or 0,
        diagnostic)
    Logging.info("[FS25_TerraLogic] %s", text)
    return text
end

function TerraLogicMain:consoleCommandWheelCompaction()
    local vehicle = g_localPlayer ~= nil
        and g_localPlayer:getCurrentVehicle() or nil
    local text = TerraLogicWheelCompactionManager:getDiagnosticText(vehicle)
    Logging.info("[FS25_TerraLogic] %s", text)
    return text
end

function TerraLogicMain:consoleCommandLogging(value)
    local parsed = parseEnabled(value)
    if parsed ~= nil then
        if not TerraLogicSettings:isLocalAdmin() then
            return "TerraLogic: only the server administrator may change debug logging"
        end
        if not TerraLogicSettings:setDebugEnabledFromMenu(parsed) then
            return "TerraLogic: debug logging could not be changed"
        end
        if g_server == nil then
            return string.format("TerraLogic debug logging change requested: %s",
                parsed and "ON" or "OFF")
        end
    end
    return string.format("TerraLogic verbose logging: %s",
        TerraLogicSettings:getDebugEnabled() and "ON" or "OFF")
end

function TerraLogicMain:consoleCommandDraftModel(value)
    value = string.lower(tostring(value or ""))
    if value == "terralogic" or value == "tl" then
        value = "terraLogic"
    end
    if value == "terraLogic" or value == "mr" then
        if not TerraLogicSettings:isLocalAdmin() then
            return "TerraLogic: only the server administrator may change the draft model"
        end
        TerraLogicSettings:setFromMenu(value)
    end
    local effective = TerraLogicSettings:getEffectiveDraftModel()
    local suffix = TerraLogicSettings.draftModel == "mr"
        and effective ~= "mr" and " (More Realistic unavailable; TerraLogic fallback)" or ""
    local displayName = effective == "mr" and "More Realistic" or "TerraLogic"
    return string.format("TerraLogic draft model: %s%s", displayName, suffix)
end

-- Balance-test helpers -------------------------------------------------------

-- Returns a readable vehicle or implement name for diagnostics.
local function getObjectName(object, fallback)
    if object ~= nil then
        if object.getFullName ~= nil then
            return tostring(object:getFullName())
        end
        if object.getName ~= nil then
            return tostring(object:getName())
        end
    end
    return fallback or "unknown"
end

local function getStoreSpecNumber(object, ...)
    if object == nil or g_storeManager == nil or object.configFileName == nil then
        return nil
    end
    local item = g_storeManager:getItemByXMLFilename(object.configFileName)
    local specs = item ~= nil and item.specs or nil
    if specs == nil then
        return nil
    end
    for index = 1, select("#", ...) do
        local value = tonumber(specs[select(index, ...)])
        if value ~= nil then
            return value
        end
    end
    return nil
end

local function getVehicleXmlNumber(object, key)
    if object == nil or object.xmlFile == nil
        or type(object.xmlFile.getValue) ~= "function" then
        return nil
    end
    local ok, value = pcall(object.xmlFile.getValue, object.xmlFile, key)
    if ok then
        return tonumber(value)
    end
    return nil
end

local function getActiveMotorShopHp(object, runtimeHp)
    local motorConfigIndex = 1
    if object ~= nil and object.configurations ~= nil
        and object.configurations.motor ~= nil then
        motorConfigIndex = math.max(tonumber(object.configurations.motor) or 1, 1)
    end
    local key = string.format(
        "vehicle.motorized.motorConfigurations.motorConfiguration(%d)#hp",
        motorConfigIndex - 1
    )
    local configuredHp = getVehicleXmlNumber(object, key)
    if configuredHp ~= nil then
        return configuredHp
    end
    if runtimeHp ~= nil and runtimeHp > 0 then
        return math.floor(runtimeHp + 0.5)
    end
    return getStoreSpecNumber(object, "power", "maxPower")
end

local function getImplementNeededHp(object)
    return getVehicleXmlNumber(object, "vehicle.storeData.specs.neededPower")
        or getStoreSpecNumber(object, "neededPower", "powerNeeded")
end

local function getVanillaAgeUsageData(object)
    local age = tonumber(object ~= nil and object.age) or 0
    local lifetime = tonumber(object ~= nil and object.lifetime) or 0
    local operatingHours = (tonumber(object ~= nil and object.operatingTime) or 0)
        / 3600000
    local factor = 1
    if lifetime ~= 0 then
        local ageMultiplier = 0.15 * math.min(age / lifetime, 1)
        local lifetimeOperatingRatio = EconomyManager ~= nil
            and tonumber(EconomyManager.LIFETIME_OPERATINGTIME_RATIO) or 0.08333
        local operatingTimeMultiplier = 0.85 * math.min(
            operatingHours / math.max(lifetime * lifetimeOperatingRatio, 0.0001),
            1
        )
        local maximumMultiplier = EconomyManager ~= nil
            and tonumber(EconomyManager.MAX_DAILYUPKEEP_MULTIPLIER) or 4
        factor = 1 + maximumMultiplier
            * (ageMultiplier + operatingTimeMultiplier)
    end
    local adjustedFactor = TerraLogic ~= nil
        and TerraLogic.getAdjustedAgeUsageFactor ~= nil
        and TerraLogic.getAdjustedAgeUsageFactor(object) or factor
    return age, lifetime, operatingHours, factor, adjustedFactor
end

local function getEconomyData()
    local difficulty = g_currentMission ~= nil and g_currentMission.missionInfo ~= nil
        and tonumber(g_currentMission.missionInfo.economicDifficulty) or nil
    local names = {[1] = "easy", [2] = "normal", [3] = "hard"}
    local costMultiplier = nil
    local priceMultiplier = nil
    if EconomyManager ~= nil and type(EconomyManager.getCostMultiplier) == "function" then
        local ok, value = pcall(EconomyManager.getCostMultiplier)
        costMultiplier = ok and tonumber(value) or nil
    end
    if EconomyManager ~= nil and type(EconomyManager.getPriceMultiplier) == "function" then
        local ok, value = pcall(EconomyManager.getPriceMultiplier)
        priceMultiplier = ok and tonumber(value) or nil
    end
    return difficulty, names[difficulty] or "unknown", costMultiplier, priceMultiplier
end

local function percentOrZero(value)
    return (tonumber(value) or 0) * 100
end

function TerraLogicMain:consoleCommandTestStart(label, revenuePerHa)
    if g_currentMission == nil or not g_currentMission:getIsServer() then
        return "TerraLogic: balance tests must be started on the server/host"
    end
    if self.balanceTestImplement ~= nil then
        local oldSpec = self.balanceTestImplement.spec_terraLogic
        if oldSpec ~= nil and oldSpec.balanceTest ~= nil
            and oldSpec.balanceTest.active == true then
            return "TerraLogic: a balance test is already active; use tlTestStop or tlTestCancel"
        end
    end

    local implement = self:getDebugImplement(true)
    if implement == nil or implement.spec_terraLogic == nil then
        return "TerraLogic: no supported implement selected or attached"
    end

    local revenue = nil
    if revenuePerHa ~= nil and revenuePerHa ~= "" then
        revenue = tonumber(revenuePerHa)
    end
    if (revenuePerHa ~= nil and revenuePerHa ~= "" and revenue == nil)
        or (revenue ~= nil and revenue < 0) then
        return "TerraLogic usage: tlTestStart <label> [revenuePerHa>=0]"
    end

    local spec = implement.spec_terraLogic
    local rootVehicle = implement.rootVehicle or implement
    local motor = rootVehicle.getMotor ~= nil and rootVehicle:getMotor() or nil
    local tractorRuntimeHp = motor ~= nil
        and (tonumber(motor.peakMotorPower) or 0) * 1.35962162 or 0
    local implementAge, implementLifetime, implementOperatingHours,
        vanillaAgeUsageFactor, adjustedAgeUsageFactor =
            getVanillaAgeUsageData(implement)
    local economyDifficulty, economyName, economyCostMultiplier,
        economyPriceMultiplier = getEconomyData()
    local startDamage = implement.getDamageAmount ~= nil
        and tonumber(implement:getDamageAmount()) or 0
    local price = implement.getPrice ~= nil and tonumber(implement:getPrice()) or 0
    local startRepairCost = Wearable.calculateRepairPrice(price or 0, startDamage or 0)
    local safeLabel = tostring(label or "test"):gsub("[^%w%._%-]", "_")

    spec.balanceTest = {
        active = true,
        label = safeLabel,
        startMissionTime = g_currentMission.time or 0,
        startDamage = startDamage or 0,
        price = price or 0,
        startRepairCost = startRepairCost or 0,
        revenuePerHa = revenue,
        economyDifficulty = economyDifficulty,
        economyName = economyName,
        economyCostMultiplier = economyCostMultiplier,
        economyPriceMultiplier = economyPriceMultiplier,
        implementName = getObjectName(implement, "implement"),
        implementClass = spec.implementClassKey or "unknown",
        storeCategory = spec.storeCategory or "unknown",
        tractorName = getObjectName(rootVehicle, "tractor"),
        tractorRuntimeHp = tractorRuntimeHp,
        tractorShopHp = getActiveMotorShopHp(rootVehicle, tractorRuntimeHp),
        implementNeededHp = getImplementNeededHp(implement),
        ratedSpeed = spec.ratedSpeed or 0,
        recommendedSpeed = spec.optimalSpeed or spec.ratedSpeed or 0,
        safeSpeedRatio = spec.safeSpeedRatio
            or (TerraLogic ~= nil
                and TerraLogic.WEAR_SAFE_SPEED_RATIO_DEFAULT or 0.80),
        safeSpeed = spec.safeSpeed or ((spec.ratedSpeed or 0) * (spec.safeSpeedRatio
            or (TerraLogic ~= nil
                and TerraLogic.WEAR_SAFE_SPEED_RATIO_DEFAULT or 0.80))),
        safeSpeedSource = spec.safeSpeedSource or "unknown",
        safeSpeedFallback = spec.safeSpeedFallback == true,
        shopToClassSpeedFactor = spec.shopToClassSpeedFactor,
        workingWidth = implement:getOverSpeedWorkingWidth(),
        workDepthCm = spec.workDepthCm or 0,
        structuralProtection = spec.structuralProtection or "none",
        structuralSafeRatio = spec.structuralProfile ~= nil
            and (spec.structuralProfile.safeRatio or 1) or 1,
        structuralTripRatio = spec.structuralProfile ~= nil
            and (spec.structuralProfile.tripRatio or 1) or 1,
        implementAge = implementAge,
        implementLifetime = implementLifetime,
        implementOperatingHours = implementOperatingHours,
        vanillaAgeUsageFactor = vanillaAgeUsageFactor,
        adjustedAgeUsageFactor = adjustedAgeUsageFactor,
        baseMaxForce = spec.baseMaxForce
            or (implement.spec_powerConsumer ~= nil
                and tonumber(implement.spec_powerConsumer.maxForce) or 0),
        activeMs = 0,
        areaHa = 0,
        distanceM = 0,
        speedTime = 0,
        speedMin = nil,
        speedMax = 0,
        aboveRatedMs = 0,
        aboveRatedAreaHa = 0,
        draftTime = 0,
        draftMax = 1,
        abrasionTime = 0,
        resistanceTime = 0,
        maxForceTime = 0,
        maxForceMax = 0,
        motorLoadTime = 0,
        motorLoadMax = 0,
        structuralLoadTime = 0,
        structuralLoadMax = 0,
        structuralOverloadDamage = 0,
        structuralOverloadEventCount = 0,
        vanillaDamage = 0,
        continuousDamage = 0,
        speedAdjustmentDamage = 0,
        abrasionAdjustmentDamage = 0,
        wearPolicyAdjustmentDamage = 0,
        randomImpactDamage = 0,
        stoneSurfaceDamage = 0,
        stoneGeneratedDamage = 0,
        randomImpactCount = 0,
        smallImpactCount = 0,
        mediumImpactCount = 0,
        bigImpactCount = 0,
        impactDropoutCount = 0,
        impactDropoutMissedAreaHa = 0,
        soilTime = {}
    }
    self.balanceTestImplement = implement

    Logging.info(
        "[FS25_TerraLogic] BALANCE TEST START label=%s tractor=%s implement=%s revenuePerHa=%s",
        safeLabel, spec.balanceTest.tractorName, spec.balanceTest.implementName,
        revenue ~= nil and string.format("%.2f", revenue) or "n/a"
    )
    local revenueText = revenue ~= nil and string.format("%.0f/ha", revenue) or "n/a"
    return string.format(
        "TerraLogic balance test '%s' started | %s + %s | revenue %s",
        safeLabel, spec.balanceTest.tractorName, spec.balanceTest.implementName,
        revenueText
    )
end

function TerraLogicMain:consoleCommandTestStatus()
    local implement = self.balanceTestImplement
    local spec = implement ~= nil and implement.spec_terraLogic or nil
    local test = spec ~= nil and spec.balanceTest or nil
    if test == nil or test.active ~= true then
        return "TerraLogic: no balance test active"
    end
    local activeHours = (test.activeMs or 0) / 3600000
    local averageSpeed = (test.activeMs or 0) > 0
        and (test.speedTime or 0) / test.activeMs or 0
    local averageStructuralLoad = (test.activeMs or 0) > 0
        and (test.structuralLoadTime or 0) / test.activeMs or 0
    return string.format(
        "TerraLogic test '%s' | %.3f ha | %.1f km/h avg | mechanical %.0f%% avg/%.0f%% max | structural %.2f%% (%d events) | %.1f min active",
        test.label, test.areaHa or 0, averageSpeed,
        averageStructuralLoad * 100,
        (test.structuralLoadMax or 0) * 100,
        (test.structuralOverloadDamage or 0) * 100,
        test.structuralOverloadEventCount or 0,
        activeHours * 60
    )
end

function TerraLogicMain:consoleCommandTestCancel()
    local implement = self.balanceTestImplement
    local spec = implement ~= nil and implement.spec_terraLogic or nil
    local test = spec ~= nil and spec.balanceTest or nil
    if test == nil or test.active ~= true then
        return "TerraLogic: no balance test active"
    end
    test.active = false
    self.balanceTestImplement = nil
    return string.format("TerraLogic balance test '%s' cancelled", test.label)
end

function TerraLogicMain:consoleCommandTestStop()
    local implement = self.balanceTestImplement
    local spec = implement ~= nil and implement.spec_terraLogic or nil
    local test = spec ~= nil and spec.balanceTest or nil
    if test == nil or test.active ~= true then
        return "TerraLogic: no balance test active"
    end
    test.active = false
    self.balanceTestImplement = nil

    local activeMs = test.activeMs or 0
    local activeHours = activeMs / 3600000
    local areaHa = test.areaHa or 0
    local endDamage = implement.getDamageAmount ~= nil
        and tonumber(implement:getDamageAmount()) or test.startDamage
    local actualDamage = math.max((endDamage or 0) - (test.startDamage or 0), 0)
    local stoneDamage = (test.stoneSurfaceDamage or 0) + (test.stoneGeneratedDamage or 0)
    local componentDamage = (test.continuousDamage or 0)
        + (test.structuralOverloadDamage or 0)
        + (test.randomImpactDamage or 0) + stoneDamage
    local averageSpeed = activeMs > 0 and (test.speedTime or 0) / activeMs or 0
    local averageDraft = activeMs > 0 and (test.draftTime or 0) / activeMs or 1
    local averageAbrasion = activeMs > 0 and (test.abrasionTime or 0) / activeMs or 1
    local averageResistance = activeMs > 0 and (test.resistanceTime or 0) / activeMs or 1
    local averageMaxForce = activeMs > 0 and (test.maxForceTime or 0) / activeMs or 0
    local averageMotorLoad = activeMs > 0 and (test.motorLoadTime or 0) / activeMs or 0
    local averageStructuralLoad = activeMs > 0
        and (test.structuralLoadTime or 0) / activeMs or 0
    local fieldCapacity = activeHours > 0 and areaHa / activeHours or 0
    local damagePerHa = areaHa > 0 and actualDamage / areaHa or 0
    local vanillaDamagePerHa = areaHa > 0 and (test.vanillaDamage or 0) / areaHa or 0
    local componentDamagePerHa = areaHa > 0 and componentDamage / areaHa or 0
    local referenceWidth = math.max(self.NORMALIZED_REFERENCE_WIDTH_M or 3, 0.1)
    local damagePer10Km = (test.distanceM or 0) > 0
        and actualDamage / test.distanceM * 10000 or 0
    local vanillaDamagePer10Km = (test.distanceM or 0) > 0
        and (test.vanillaDamage or 0) / test.distanceM * 10000 or 0
    local componentDamagePer10Km = (test.distanceM or 0) > 0
        and componentDamage / test.distanceM * 10000 or 0
    local normalizedDamagePerHa = damagePer10Km / referenceWidth
    local normalizedVanillaDamagePerHa = vanillaDamagePer10Km / referenceWidth
    local normalizedComponentDamagePerHa = componentDamagePer10Km / referenceWidth
    local endRepairCost = Wearable.calculateRepairPrice(test.price or 0, endDamage or 0)
    local repairCost = math.max(endRepairCost - (test.startRepairCost or 0), 0)
    local repairCostPerHa = areaHa > 0 and repairCost / areaHa or 0
    local repairCostPer10Km = (test.distanceM or 0) > 0
        and repairCost / test.distanceM * 10000 or 0
    local normalizedRepairCostPerHa = repairCostPer10Km / referenceWidth
    local vanillaEndDamage = math.min((test.startDamage or 0) + (test.vanillaDamage or 0), 1)
    local vanillaEndRepairCost = Wearable.calculateRepairPrice(test.price or 0, vanillaEndDamage)
    local vanillaRepairCost = math.max(vanillaEndRepairCost - (test.startRepairCost or 0), 0)
    local vanillaRepairCostPerHa = areaHa > 0 and vanillaRepairCost / areaHa or 0
    local extraRepairCostPerHa = repairCostPerHa - vanillaRepairCostPerHa
    local repairCostPerActiveHour = activeHours > 0 and repairCost / activeHours or 0
    local extraRepairCostPerActiveHour = activeHours > 0
        and (repairCost - vanillaRepairCost) / activeHours or 0
    local hectaresFreshToFull = damagePerHa > 0 and 1 / damagePerHa or math.huge
    local hectaresRemaining = damagePerHa > 0
        and math.max(1 - (endDamage or 0), 0) / damagePerHa or math.huge
    local hoursFreshToFull = fieldCapacity > 0 and hectaresFreshToFull / fieldCapacity or math.huge
    local hectaresPer25Damage = damagePerHa > 0 and 0.25 / damagePerHa or math.huge
    local hoursPer25Damage = fieldCapacity > 0
        and hectaresPer25Damage / fieldCapacity or math.huge
    local fullRepairCost = Wearable.calculateRepairPrice(test.price or 0, 1)
    local impactsPerHa = areaHa > 0 and (test.randomImpactCount or 0) / areaHa or 0
    local totalVsVanilla = (test.vanillaDamage or 0) > 0
        and componentDamage / test.vanillaDamage * 100 or 0
    local aboveRatedTimePercent = activeMs > 0
        and (test.aboveRatedMs or 0) / activeMs * 100 or 0
    local aboveRatedAreaPercent = areaHa > 0
        and (test.aboveRatedAreaHa or 0) / areaHa * 100 or 0
    local revenue = test.revenuePerHa
    local repairRevenuePercent = revenue ~= nil and revenue > 0
        and repairCostPerHa / revenue * 100 or nil

    Logging.info("[FS25_TerraLogic] ===== BALANCE TEST RESULT BEGIN =====")
    Logging.info(
        "[FS25_TerraLogic] TEST meta label=%s tractor=%s tractorRuntimeHp=%.2f tractorShopHp=%s implement=%s class=%s category=%s neededHp=%s rated=%.2f classRealistic=%.2f safe=%.2f safeRatio=%.4f safeSource=%s fallback=%s shopToClassFactor=%s width=%.2f depthCm=%.1f price=%.2f",
        test.label, test.tractorName, test.tractorRuntimeHp or 0,
        test.tractorShopHp ~= nil and string.format("%.2f", test.tractorShopHp) or "n/a",
        test.implementName, test.implementClass, test.storeCategory,
        test.implementNeededHp ~= nil and string.format("%.2f", test.implementNeededHp) or "n/a",
        test.ratedSpeed or 0, test.recommendedSpeed or 0,
        test.safeSpeed or 0, test.safeSpeedRatio or 0,
        tostring(test.safeSpeedSource or "unknown"),
        tostring(test.safeSpeedFallback == true),
        test.shopToClassSpeedFactor ~= nil
            and string.format("%.4f", test.shopToClassSpeedFactor) or "n/a",
        test.workingWidth or 0, test.workDepthCm or 0, test.price or 0
    )
    Logging.info(
        "[FS25_TerraLogic] TEST context economyDifficulty=%s economyName=%s economyCostMultiplier=%s economyPriceMultiplier=%s implementAge=%.3f implementLifetime=%.3f implementOperatingHours=%.3f vanillaAgeUsageFactor=%.4f adjustedAgeUsageFactor=%.4f wearPolicy=%s xmlWearMinutes=%.3f xmlWearRateFactor=%.6f implementAbrasion=%.4f soilAbrasion=%.4f baselineAbrasion=%.4f",
        test.economyDifficulty ~= nil and tostring(test.economyDifficulty) or "n/a",
        test.economyName or "unknown",
        test.economyCostMultiplier ~= nil
            and string.format("%.4f", test.economyCostMultiplier) or "n/a",
        test.economyPriceMultiplier ~= nil
            and string.format("%.4f", test.economyPriceMultiplier) or "n/a",
        test.implementAge or 0, test.implementLifetime or 0,
        test.implementOperatingHours or 0, test.vanillaAgeUsageFactor or 1,
        test.adjustedAgeUsageFactor or test.vanillaAgeUsageFactor or 1,
        tostring(test.wearPolicy or "unknown"),
        test.xmlWearDurationMinutes or 0,
        test.xmlWearRateFactor or 0,
        test.implementAbrasionFactor or 0,
        test.soilAbrasionFactor or 1,
        test.baselineAbrasionMultiplier or 1
    )
    Logging.info(
        "[FS25_TerraLogic] TEST work areaHa=%.6f distanceM=%.2f activeMinutes=%.3f fieldCapacityHaH=%.3f speedAvg=%.3f speedMin=%.3f speedMax=%.3f aboveRatedTimePct=%.2f aboveRatedAreaPct=%.2f",
        areaHa, test.distanceM or 0, activeHours * 60, fieldCapacity,
        averageSpeed, test.speedMin or 0, test.speedMax or 0,
        aboveRatedTimePercent, aboveRatedAreaPercent
    )
    Logging.info(
        "[FS25_TerraLogic] TEST load draftAvg=%.4f draftMax=%.4f abrasionAvg=%.4f resistanceAvg=%.4f baseMaxForce=%.4f maxForceAvg=%.4f maxForceMax=%.4f motorLoadAvgPct=%.2f motorLoadMaxPct=%.2f structuralProtection=%s structuralSafePct=%.2f structuralTripPct=%.2f structuralLoadAvgPct=%.2f structuralLoadMaxPct=%.2f",
        averageDraft, test.draftMax or 1, averageAbrasion, averageResistance,
        test.baseMaxForce or 0, averageMaxForce, test.maxForceMax or 0,
        averageMotorLoad * 100, (test.motorLoadMax or 0) * 100,
        tostring(test.structuralProtection or "none"),
        (test.structuralSafeRatio or 1) * 100,
        (test.structuralTripRatio or 1) * 100,
        averageStructuralLoad * 100,
        (test.structuralLoadMax or 0) * 100
    )
    Logging.info(
        "[FS25_TerraLogic] TEST damage startPct=%.6f endPct=%.6f actualDeltaPct=%.6f componentTotalPct=%.6f continuousWearPct=%.6f structuralOverloadPct=%.6f structuralEvents=%d vanillaPct=%.6f policyAdjustmentPct=%.6f speedAdjustmentPct=%.6f abrasionAdjustmentPct=%.6f randomImpactPct=%.6f stoneSurfacePct=%.6f stoneGeneratedPct=%.6f totalVsVanillaPct=%.2f",
        percentOrZero(test.startDamage), percentOrZero(endDamage),
        percentOrZero(actualDamage), percentOrZero(componentDamage),
        percentOrZero(test.continuousDamage),
        percentOrZero(test.structuralOverloadDamage),
        test.structuralOverloadEventCount or 0,
        percentOrZero(test.vanillaDamage),
        percentOrZero(test.wearPolicyAdjustmentDamage),
        percentOrZero(test.speedAdjustmentDamage),
        percentOrZero(test.abrasionAdjustmentDamage),
        percentOrZero(test.randomImpactDamage),
        percentOrZero(test.stoneSurfaceDamage), percentOrZero(test.stoneGeneratedDamage),
        totalVsVanilla
    )
    Logging.info(
        "[FS25_TerraLogic] TEST impacts total=%d small=%d medium=%d big=%d impactsPerHa=%.3f randomDamagePct=%.6f realStoneDamagePct=%.6f",
        test.randomImpactCount or 0, test.smallImpactCount or 0,
        test.mediumImpactCount or 0, test.bigImpactCount or 0,
        impactsPerHa, percentOrZero(test.randomImpactDamage), percentOrZero(stoneDamage)
    )
    Logging.info(
        "[FS25_TerraLogic] TEST mechanicalDropouts triggers=%d missedAreaHa=%.6f missedPctOfWorkedArea=%.3f",
        test.impactDropoutCount or 0,
        test.impactDropoutMissedAreaHa or 0,
        areaHa > 0 and (test.impactDropoutMissedAreaHa or 0) / areaHa * 100 or 0
    )
    Logging.info(
        "[FS25_TerraLogic] TEST normalized damagePerHaPct=%.6f componentDamagePerHaPct=%.6f vanillaDamagePerHaPct=%.6f repairCost=%.2f repairCostPerHa=%.2f vanillaRepairCostPerHa=%.2f extraRepairCostPerHa=%.2f repairCostPerActiveHour=%.2f extraRepairCostPerActiveHour=%.2f hectaresFreshTo100=%s hectaresRemaining=%s hoursFreshTo100=%s",
        damagePerHa * 100, componentDamagePerHa * 100, vanillaDamagePerHa * 100,
        repairCost, repairCostPerHa, vanillaRepairCostPerHa,
        extraRepairCostPerHa, repairCostPerActiveHour,
        extraRepairCostPerActiveHour,
        hectaresFreshToFull < math.huge and string.format("%.3f", hectaresFreshToFull) or "n/a",
        hectaresRemaining < math.huge and string.format("%.3f", hectaresRemaining) or "n/a",
        hoursFreshToFull < math.huge and string.format("%.3f", hoursFreshToFull) or "n/a"
    )
    Logging.info(
        "[FS25_TerraLogic] TEST widthNormalized referenceWidthM=%.2f damagePer10KmPct=%.6f componentDamagePer10KmPct=%.6f vanillaDamagePer10KmPct=%.6f normalizedDamagePerHaPct=%.6f normalizedComponentDamagePerHaPct=%.6f normalizedVanillaDamagePerHaPct=%.6f repairCostPer10Km=%.2f normalizedRepairCostPerHa=%.2f",
        referenceWidth, damagePer10Km * 100, componentDamagePer10Km * 100,
        vanillaDamagePer10Km * 100, normalizedDamagePerHa * 100,
        normalizedComponentDamagePerHa * 100,
        normalizedVanillaDamagePerHa * 100, repairCostPer10Km,
        normalizedRepairCostPerHa
    )
    Logging.info(
        "[FS25_TerraLogic] TEST service hectaresPer25Damage=%s hoursPer25Damage=%s fullRepairCost=%.2f startRepairCost=%.2f endRepairCost=%.2f",
        hectaresPer25Damage < math.huge and string.format("%.3f", hectaresPer25Damage) or "n/a",
        hoursPer25Damage < math.huge and string.format("%.3f", hoursPer25Damage) or "n/a",
        fullRepairCost, test.startRepairCost or 0, endRepairCost
    )
    if revenue ~= nil then
        Logging.info(
            "[FS25_TerraLogic] TEST economics revenuePerHa=%.2f repairCostPerHa=%.2f repairShareOfRevenuePct=%.3f revenueAfterImplementRepairPerHa=%.2f",
            revenue, repairCostPerHa, repairRevenuePercent or 0,
            revenue - repairCostPerHa
        )
    else
        Logging.info(
            "[FS25_TerraLogic] TEST economics revenuePerHa=n/a repairCostPerHa=%.2f repairShareOfRevenuePct=n/a revenueAfterImplementRepairPerHa=n/a",
            repairCostPerHa
        )
    end
    for soilIndex = 0, 4 do
        local soilMs = test.soilTime ~= nil and (test.soilTime[soilIndex] or 0) or 0
        if soilMs > 0 then
            local soilData = TerraLogic ~= nil and TerraLogic.SOIL_DATA[soilIndex] or nil
            Logging.info(
                "[FS25_TerraLogic] TEST soil index=%d name=%s timePct=%.3f",
                soilIndex, soilData ~= nil and soilData.name or "Vanilla/unknown",
                activeMs > 0 and soilMs / activeMs * 100 or 0
            )
        end
    end
    Logging.info("[FS25_TerraLogic] ===== BALANCE TEST RESULT END =====")

    local economySummary = revenue ~= nil and string.format(
        "%.1f%% of %.0f revenue", repairRevenuePercent or 0, revenue
    ) or "revenue n/a"
    return string.format(
        "TerraLogic test '%s' logged | %.3f ha | %.2f%% damage/ha | %.0f repair/ha | %s",
        test.label, areaHa, damagePerHa * 100, repairCostPerHa, economySummary
    )
end

function TerraLogicMain:consoleCommandEnable(value)
    if value == nil or value == "" then
        return string.format("TerraLogic mod: %s", self.enabled and "ENABLED" or "DISABLED")
    end
    local enabled = parseEnabled(value)
    if enabled == nil then
        return "TerraLogic usage: tlEnable [on|off]"
    end
    self.enabled = enabled
    self.debugNextRefresh = 0
    return string.format("TerraLogic mod: %s", enabled and "ENABLED" or "DISABLED")
end

function TerraLogicMain:consoleCommandWearPolicy(value)
    local requested = value ~= nil and string.lower(tostring(value)) or ""
    if requested == "" then
        return string.format("TerraLogic wear policy: %s", self.wearPolicy)
    end
    local resolved = requested == "forcevanilla" and "forceVanilla" or requested
    if resolved ~= "respect" and resolved ~= "normalize"
        and resolved ~= "forceVanilla" then
        return "TerraLogic usage: tlWearPolicy <respect|normalize|forceVanilla>"
    end
    self.wearPolicy = resolved
    self.debugNextRefresh = 0
    return string.format("TerraLogic wear policy set to: %s", resolved)
end

local function setRuntimeToggle(owner, fieldName, value, label, usage)
    if value == nil or value == "" then
        return string.format("TerraLogic %s: %s", label, owner[fieldName] and "ENABLED" or "DISABLED")
    end
    local enabled = parseEnabled(value)
    if enabled == nil then
        return usage
    end
    owner[fieldName] = enabled
    owner.debugNextRefresh = 0
    return string.format("TerraLogic %s: %s", label, enabled and "ENABLED" or "DISABLED")
end

function TerraLogicMain:consoleCommandDraft(value)
    return setRuntimeToggle(self, "draftEnabled", value, "additional draft", "TerraLogic usage: tlDraft [on|off]")
end

function TerraLogicMain:consoleCommandRandomImpacts(value)
    return setRuntimeToggle(self, "randomImpactsEnabled", value, "random impacts", "TerraLogic usage: tlImpacts [on|off]")
end

function TerraLogicMain:consoleCommandStoneImpacts(value)
    return setRuntimeToggle(self, "stoneImpactsEnabled", value, "real stone impacts", "TerraLogic usage: tlStones [on|off]")
end

-- Disables only the live mower overspeed yield curve. Surface-island
-- dropouts and stored agronomic field quality deliberately stay active.
function TerraLogicMain:consoleCommandMowerQuality(value)
    if g_currentMission ~= nil and not g_currentMission:getIsServer() then
        return g_i18n:getText("terraLogic_consoleServerOnly")
    end
    if value ~= nil and value ~= "" and parseEnabled(value) == nil then
        return g_i18n:getText("terraLogic_consoleMowerQualityUsage")
    end
    if value ~= nil and value ~= "" then
        self.mowerQualityEnabled = parseEnabled(value)
        self.debugNextRefresh = 0
    end
    local stateKey = self.mowerQualityEnabled
        and "terraLogic_settingOn" or "terraLogic_settingOff"
    return string.format(
        g_i18n:getText("terraLogic_consoleMowerQualityStatus"),
        g_i18n:getText(stateKey))
end

function TerraLogicMain:getBalanceMultiplier(name)
    local value = self.balanceMultipliers ~= nil and self.balanceMultipliers[name] or nil
    return tonumber(value) or 1
end

function TerraLogicMain:resolveBalanceName(name)
    local normalized = name ~= nil and string.lower(tostring(name)) or ""
    normalized = string.gsub(normalized, "[^a-z]", "")
    return self.BALANCE_NAMES[normalized]
end

function TerraLogicMain:consoleCommandMultiplier(name, value)
    local resolvedName = self:resolveBalanceName(name)
    if resolvedName == nil then
        local names = {
            "wear", "draft", "damageResistance", "randomFrequency",
            "randomDamage", "stoneSurface", "stoneGenerated"
        }
        return "TerraLogic multiplier names: " .. table.concat(names, ", ")
            .. " | usage: tlMultiplier <name> <value|reset>"
    end

    if value == nil or value == "" then
        return string.format(
            "TerraLogic multiplier %s: x%.3f (default x%.3f)",
            resolvedName,
            self:getBalanceMultiplier(resolvedName),
            self.BALANCE_DEFAULTS[resolvedName]
        )
    end

    if string.lower(tostring(value)) == "reset" then
        self.balanceMultipliers[resolvedName] = self.BALANCE_DEFAULTS[resolvedName]
    else
        local multiplier = tonumber(value)
        if multiplier == nil or multiplier < 0 then
            return "TerraLogic usage: tlMultiplier <name> <non-negative value|reset>"
        end
        self.balanceMultipliers[resolvedName] = multiplier
    end

    self.debugNextRefresh = 0
    return string.format("TerraLogic multiplier %s: x%.3f", resolvedName, self.balanceMultipliers[resolvedName])
end

function TerraLogicMain:consoleCommandBalanceReset()
    for name, value in pairs(self.BALANCE_DEFAULTS) do
        self.balanceMultipliers[name] = value
    end
    self.draftEnabled = true
    self.randomImpactsEnabled = true
    self.stoneImpactsEnabled = true
    self.mowerQualityEnabled = false
    self.abrasionOverride = 0
    self.resistanceOverride = 0
    self.wearPolicy = "normalize"
    self.debugNextRefresh = 0
    return "TerraLogic temporary balance settings reset to defaults"
end

function TerraLogicMain:consoleCommandPrintBalance()
    Logging.info("[FS25_TerraLogic] ===== RUNTIME BALANCE START =====")
    Logging.info(
        "[FS25_TerraLogic] toggles mod=%s draft=%s randomImpacts=%s realStones=%s mowerQuality=%s PF=%s wearPolicy=%s",
        tostring(self.enabled), tostring(self.draftEnabled),
        tostring(self.randomImpactsEnabled), tostring(self.stoneImpactsEnabled),
        tostring(self.mowerQualityEnabled),
        tostring(self.precisionFarmingMode), tostring(self.wearPolicy)
    )
    for _, name in ipairs({
        "wear", "draft", "damageResistance", "randomFrequency",
        "randomDamage", "stoneSurface", "stoneGenerated"
    }) do
        Logging.info(
            "[FS25_TerraLogic] multiplier.%s=%.6f",
            name, self:getBalanceMultiplier(name)
        )
    end
    Logging.info(
        "[FS25_TerraLogic] soilOverrides abrasion=%.6f resistance=%.6f (0=automatic)",
        self.abrasionOverride or 0, self.resistanceOverride or 0
    )

    if TerraLogic ~= nil then
        Logging.info(
            "[FS25_TerraLogic] wear safeRatioFallback=%.6f classShopFactorMin=%.6f classShopFactorMax=%.6f atShop=%.6f belowShopExponent=%.6f aboveShopExponent=%.6f max=%.6f referenceMinutes=%.2f ageUsageFullHours=%.2f abrasiveShare=%.6f customWarningMin=%.6f customWarningMax=%.6f",
            TerraLogic.WEAR_SAFE_SPEED_RATIO_DEFAULT,
            TerraLogic.WEAR_CLASS_SHOP_FACTOR_MIN,
            TerraLogic.WEAR_CLASS_SHOP_FACTOR_MAX,
            TerraLogic.WEAR_AT_SHOP_SPEED,
            TerraLogic.WEAR_BELOW_SAFE_EXPONENT,
            TerraLogic.WEAR_ABOVE_SHOP_EXPONENT,
            TerraLogic.WEAR_MAX,
            TerraLogic.WEAR_REFERENCE_DURATION_MINUTES,
            TerraLogic.AGE_USAGE_MINIMUM_FULL_HOURS,
            TerraLogic.WEAR_ABRASIVE_SHARE,
            TerraLogic.WEAR_CUSTOM_RATE_WARNING_MIN,
            TerraLogic.WEAR_CUSTOM_RATE_WARNING_MAX
        )
        Logging.info(
            "[FS25_TerraLogic] draft fallbackStrength=%.6f fallbackExponent=%.6f fallbackMax=%.6f damageResistanceMax=%.6f damageResistanceFullAt=%.6f damageResistanceExponent=%.6f",
            TerraLogic.DRAFT_SPEED_STRENGTH_FALLBACK,
            TerraLogic.DRAFT_SPEED_EXPONENT_FALLBACK,
            TerraLogic.DRAFT_MAX_FALLBACK,
            TerraLogic.DAMAGE_MAX_FORCE_INCREASE,
            TerraLogic.DAMAGE_RESISTANCE_FULL_AT,
            TerraLogic.DAMAGE_RESISTANCE_EXPONENT
        )
        Logging.info(
            "[FS25_TerraLogic] random basePerHa=%.6f randomMin=%.6f randomMean=%.6f rotationEnergy=%.6f undergroundWithVisible=%.6f",
            TerraLogic.IMPACT_BASE_EVENTS_PER_HA,
            TerraLogic.IMPACT_RANDOM_MIN_FACTOR,
            TerraLogic.IMPACT_RANDOM_MEAN_FACTOR,
            TerraLogic.IMPACT_ROTATION_ENERGY,
            TerraLogic.IMPACT_UNDERGROUND_WITH_VISIBLE_STONES_FACTOR
        )
        for name, tier in pairs(TerraLogic.IMPACT_TIERS) do
            Logging.info(
                "[FS25_TerraLogic] impactTier.%s eventsPerHa=%.6f probability=%.6f baseDamage=%.6f maxDamage=%.6f",
                name, tier.eventsPerHa, tier.probability,
                tier.baseDamage, tier.maxDamage
            )
        end
        Logging.info(
            "[FS25_TerraLogic] stones localExposureEventsPerCoveredHa small=%.3f medium=%.3f big=%.3f maxEventsPerTick=%d",
            TerraLogic.STONE_VISIBLE_EVENTS_PER_COVERED_HA.small,
            TerraLogic.STONE_VISIBLE_EVENTS_PER_COVERED_HA.medium,
            TerraLogic.STONE_VISIBLE_EVENTS_PER_COVERED_HA.big,
            TerraLogic.STONE_VISIBLE_MAX_EVENTS_PER_TICK
        )
        Logging.info(
            "[FS25_TerraLogic] core soilUpdateMs=%d telemetryMs=%d stoneScanMs=%d",
            TerraLogic.SOIL_UPDATE_INTERVAL_MS,
            TerraLogic.TELEMETRY_INTERVAL_MS,
            TerraLogic.STONE_SCAN_INTERVAL_MS
        )
        for index, soil in pairs(TerraLogic.SOIL_DATA) do
            Logging.info(
                "[FS25_TerraLogic] soil.%d name=%s resistance=%.6f abrasion=%.6f randomSeverity=%.6f",
                index, soil.name, soil.resistance, soil.abrasion,
                soil.impactSeverity
            )
        end
        for name, implementClass in pairs(TerraLogic.IMPLEMENT_CLASSES) do
            local work = implementClass.work or {}
            local draft = implementClass.draft or {}
            local wear = implementClass.wear or {}
            local impacts = implementClass.impacts or {}
            local stones = implementClass.stones or {}
            Logging.info(
                "[FS25_TerraLogic] implementProfile.%s optimalSpeed=%s safeSpeedRatio=%s minimumShopFactor=%s maximumShopFactor=%s depthCm=%.1f draftDepthResponse=%.6f groundContact=%s draftEnabled=%s draftScale=%.6f impactDepth=%.6f underground=%s vanilla=%s workSpeed=%s rotation=%s overspeedOnly=%s abrasionDepthFactor=%.6f stoneMode=%s dropout=%s impactDropout=%s name=%s",
                name, tostring(work.optimalSpeedKph),
                tostring(wear.safeSpeedRatio or "default"),
                tostring(wear.minimumShopFactor or "default"),
                tostring(wear.maximumShopFactor or "default"),
                tonumber(work.depthCm) or 0,
                TerraLogic.getDraftDepthResponse(work.depthCm),
                tostring(work.groundContactTool == true),
                tostring(draft.enabled == true), tonumber(draft.overspeedScale) or 0,
                TerraLogic.getImpactDepthFactor(work.depthCm),
                tostring(impacts.underground == true),
                tostring(impacts.vanilla == true),
                tostring(impacts.workSpeed == true),
                tostring(impacts.rotation == true),
                tostring(impacts.overspeedOnly == true),
                TerraLogic.getAbrasionDepthFactor(work.depthCm),
                tostring(stones.mode or "none"),
                tostring(implementClass.dropoutProfile or "none"),
                tostring(implementClass.impactDropoutProfile or "none"),
                implementClass.name
            )
        end
        if TerraLogicImplementProfiles ~= nil
            and TerraLogicImplementProfiles.REAL_SPEED_KPH ~= nil then
            for name, speed in pairs(TerraLogicImplementProfiles.REAL_SPEED_KPH) do
                Logging.info(
                    "[FS25_TerraLogic] realSpeedReference.%s=%.2f km/h",
                    name, tonumber(speed) or 0
                )
            end
        end
        if TerraLogicImplementProfiles ~= nil
            and TerraLogicImplementProfiles.ABRASION_FACTOR ~= nil then
            for name, factor in pairs(TerraLogicImplementProfiles.ABRASION_FACTOR) do
                Logging.info(
                    "[FS25_TerraLogic] abrasionReference.%s=%.4f",
                    name, tonumber(factor) or 0
                )
            end
        end
    end
    local implement = self:getDebugImplement(true)
    if implement ~= nil and implement.getOverSpeedDebugData ~= nil then
        local data = implement:getOverSpeedDebugData()
        Logging.info(
            "[FS25_TerraLogic] activeImplement name=%s class=%s store=%s via=%s depthCm=%.1f depthFactor=%.6f speed=%.6f classRealistic=%.6f safe=%.6f safeRatio=%.6f safeSource=%s fallback=%s shopToClassFactor=%s shopRated=%.6f soil=%s soilAbrasion=%.6f implementAbrasion=%.6f baselineAbrasion=%.6f wearPolicy=%s xmlWearMinutes=%.3f xmlWearRateFactor=%.6f resistance=%.6f",
            tostring(data.name), tostring(data.implementClassKey),
            tostring(data.storeCategory), tostring(data.classificationSource),
            tonumber(data.workDepthCm) or 0, tonumber(data.impactDepthFactor) or 1,
            tonumber(data.speed) or 0, tonumber(data.optimalSpeed) or 0,
            tonumber(data.safeSpeed) or 0, tonumber(data.safeSpeedRatio) or 0,
            tostring(data.safeSpeedSource or "unknown"),
            tostring(data.safeSpeedFallback == true),
            data.shopToClassSpeedFactor ~= nil
                and string.format("%.6f", data.shopToClassSpeedFactor) or "n/a",
            tonumber(data.ratedSpeed) or 0, tostring(data.soilName),
            tonumber(data.abrasionMultiplier) or 1,
            tonumber(data.implementAbrasionFactor) or 0,
            tonumber(data.baselineAbrasionMultiplier) or 1,
            tostring(data.wearPolicy or "unknown"),
            tonumber(data.xmlWearDurationMinutes) or 0,
            tonumber(data.xmlWearRateFactor) or 0,
            tonumber(data.soilResistanceMultiplier) or 1
        )
    end
    Logging.info("[FS25_TerraLogic] ===== RUNTIME BALANCE END =====")
    return "TerraLogic: all balance settings written to log.txt"
end

local function setPositiveOverride(owner, fieldName, value, commandName)
    local multiplier = tonumber(value)
    if multiplier == nil or multiplier < 0 then
        return string.format("TerraLogic usage: %s <multiplier|0>", commandName)
    end
    owner[fieldName] = multiplier
    owner.debugNextRefresh = 0
    if multiplier == 0 then
        return string.format("TerraLogic %s override cleared; soil value is active", commandName)
    end
    return string.format("TerraLogic %s override: x%.3f", commandName, multiplier)
end

function TerraLogicMain:consoleCommandAbrasion(value)
    if value == nil or value == "" then
        return self.abrasionOverride > 0
            and string.format("TerraLogic abrasion override: x%.3f", self.abrasionOverride)
            or "TerraLogic abrasion: soil value (no override)"
    end
    return setPositiveOverride(self, "abrasionOverride", value, "abrasion")
end

function TerraLogicMain:consoleCommandResistance(value)
    if value == nil or value == "" then
        return self.resistanceOverride > 0
            and string.format("TerraLogic resistance override: x%.3f", self.resistanceOverride)
            or "TerraLogic resistance: soil value (no override)"
    end
    return setPositiveOverride(self, "resistanceOverride", value, "resistance")
end

local function terraLogicDescribeRuntimeValue(value)
    local valueType = type(value)
    if valueType == "function" then
        if debug ~= nil and debug.getinfo ~= nil then
            local ok, info = pcall(debug.getinfo, value, "S")
            if ok and info ~= nil then
                return string.format("function [%s:%s]",
                    tostring(info.short_src or info.source),
                    tostring(info.linedefined))
            end
        end
        return "function"
    elseif valueType == "string" then
        return string.format("string %q", value)
    elseif valueType == "number" or valueType == "boolean"
        or valueType == "nil" then
        return string.format("%s %s", valueType, tostring(value))
    end
    return string.format("%s %s", valueType, tostring(value))
end

local function terraLogicLogRuntimeTable(label, object)
    Logging.info("[FS25_TerraLogic] PF runtime table %s = %s",
        tostring(label), tostring(object))
    if type(object) ~= "table" then return end

    local keys = {}
    for key in pairs(object) do
        keys[#keys + 1] = key
    end
    table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
    for _, key in ipairs(keys) do
        Logging.info("[FS25_TerraLogic] PF   %s.%s = %s",
            tostring(label), tostring(key),
            terraLogicDescribeRuntimeValue(object[key]))
    end

    local metatable = getmetatable(object)
    Logging.info("[FS25_TerraLogic] PF   %s metatable = %s",
        tostring(label), tostring(metatable))
    if type(metatable) == "table" then
        local metatableKeys = {}
        for key in pairs(metatable) do
            metatableKeys[#metatableKeys + 1] = key
        end
        table.sort(metatableKeys, function(a, b)
            return tostring(a) < tostring(b)
        end)
        for _, key in ipairs(metatableKeys) do
            Logging.info("[FS25_TerraLogic] PF   %s.mt.%s = %s",
                tostring(label), tostring(key),
                terraLogicDescribeRuntimeValue(metatable[key]))
        end
        local index = rawget(metatable, "__index")
        Logging.info("[FS25_TerraLogic] PF   %s.__index = %s",
            tostring(label), tostring(index))
        if type(index) == "table" and index ~= object then
            local methodKeys = {}
            for key, value in pairs(index) do
                if type(value) == "function" then
                    methodKeys[#methodKeys + 1] = key
                end
            end
            table.sort(methodKeys, function(a, b)
                return tostring(a) < tostring(b)
            end)
            for _, key in ipairs(methodKeys) do
                Logging.info("[FS25_TerraLogic] PF   %s.__index.%s = %s",
                    tostring(label), tostring(key),
                    terraLogicDescribeRuntimeValue(index[key]))
            end
        end
    end
end

local function terraLogicLogRuntimeNestedTables(label, object)
    if type(object) ~= "table" then return end
    local parentKeys = {}
    for key, value in pairs(object) do
        if type(value) == "table" then
            parentKeys[#parentKeys + 1] = key
        end
    end
    table.sort(parentKeys, function(a, b)
        return tostring(a) < tostring(b)
    end)
    for _, parentKey in ipairs(parentKeys) do
        local child = object[parentKey]
        local childKeys = {}
        for key in pairs(child) do
            childKeys[#childKeys + 1] = key
        end
        table.sort(childKeys, function(a, b)
            return tostring(a) < tostring(b)
        end)
        -- Controller containers are generally short registration lists. The
        -- cap prevents GUI trees or caches from flooding the game log.
        local maximum = math.min(#childKeys, 40)
        Logging.info("[FS25_TerraLogic] PF nested %s.%s entries=%d",
            tostring(label), tostring(parentKey), #childKeys)
        for index=1,maximum do
            local key = childKeys[index]
            Logging.info("[FS25_TerraLogic] PF   %s.%s.%s = %s",
                tostring(label), tostring(parentKey), tostring(key),
                terraLogicDescribeRuntimeValue(child[key]))
        end
    end
end

function TerraLogicMain:consoleCommandPrecisionFarmingInspect(detail)
    local env = FS25_precisionFarming
    local controller = env ~= nil and env.g_precisionFarming or nil
    local mode = string.lower(tostring(detail or ""))
    if mode == "yield" then
        -- Explicit diagnostic only: not enabled by ordinary extended logging.
        terraLogicLogRuntimeTable("harvestExtension",
            controller ~= nil and controller.harvestExtension or nil)
        return TerraLogicPFHarvestTrace.start(controller, getLocalControlledVehicle())
    elseif mode == "yieldstop" then
        return TerraLogicPFHarvestTrace.active ~= nil
            and TerraLogicPFHarvestTrace.active:stop("console command")
            or "TerraLogic PF yield trace is not active"
    end
    local soilMap = controller ~= nil and controller.soilMap or nil
    local soilClass = env ~= nil and env.SoilMap or nil
    local resolvedMap, _, source = self:getPrecisionFarmingSoilMap()

    local result = string.format(
        "TerraLogic PF inspect | loaded=%s env=%s controller=%s soilMap=%s directMethod=%s SoilMapClass=%s classMethod=%s resolved=%s source=%s",
        g_modIsLoaded ~= nil and tostring(g_modIsLoaded["FS25_precisionFarming"]) or "n/a",
        type(env),
        type(controller),
        type(soilMap),
        soilMap ~= nil and type(soilMap.getTypeIndexAtWorldPos) or "n/a",
        type(soilClass),
        soilClass ~= nil and type(soilClass.getTypeIndexAtWorldPos) or "n/a",
        resolvedMap ~= nil and "YES" or "NO",
        tostring(source)
    )

    if detail ~= nil and string.lower(tostring(detail)) == "deep" then
        Logging.info("[FS25_TerraLogic] ===== PF VALUE MAP RUNTIME INSPECTION =====")
        terraLogicLogRuntimeTable("ValueMapClass",
            env ~= nil and env.ValueMap or ValueMap)
        terraLogicLogRuntimeTable("PrecisionFarmingClass",
            env ~= nil and env.PrecisionFarming or PrecisionFarming)
        terraLogicLogRuntimeTable("controller", controller)
        terraLogicLogRuntimeNestedTables("controller", controller)
        terraLogicLogRuntimeTable("soilMap", soilMap)
        terraLogicLogRuntimeTable("yieldMap",
            controller ~= nil and controller.yieldMap or nil)
        terraLogicLogRuntimeTable("nitrogenMap",
            controller ~= nil and controller.nitrogenMap or nil)
        terraLogicLogRuntimeTable("pHMap",
            controller ~= nil and controller.pHMap or nil)
        terraLogicLogRuntimeTable("mapFrame",
            soilMap ~= nil and soilMap.mapFrame or nil)
        Logging.info("[FS25_TerraLogic] ===== END PF VALUE MAP INSPECTION =====")
        return result .. " | deep details written to log.txt"
    end

    return result .. " | use 'tlPFInspect deep' for ValueMap details"
end

function TerraLogicMain:consoleCommandPrecisionFarming(value)
    local requestedMode = value ~= nil and string.lower(tostring(value)) or ""
    if requestedMode == "" then
        local soilMap, _, source = self:getPrecisionFarmingSoilMap()
        local detected = soilMap ~= nil
        return string.format(
            "TerraLogic PF mode: %s | PF soil map detected: %s | source: %s",
            self.precisionFarmingMode,
            detected and "YES" or "NO",
            source
        )
    end

    if requestedMode ~= "auto" and requestedMode ~= "on" and requestedMode ~= "off" then
        return "TerraLogic usage: tlPF [auto|on|off]"
    end

    self.precisionFarmingMode = requestedMode
    local soilMap, _, source = self:getPrecisionFarmingSoilMap()
    local detected = soilMap ~= nil
    return string.format(
        "TerraLogic PF mode set to %s | PF soil map detected: %s | source: %s",
        requestedMode,
        detected and "YES" or "NO",
        source
    )
end

function TerraLogicMain:consoleCommandDebugView(value)
    local view = value ~= nil and string.lower(tostring(value)) or ""
    if view == "balance" then
        view = "overview"
    elseif view == "impact" or view == "stones" then
        view = "impacts"
    elseif view == "resistance" then
        view = "draft"
    elseif view == "cost" or view == "costs" then
        view = "economy"
    elseif view == "fieldquality" or view == "yieldquality"
        or view == "yield" then
        view = "workquality"
    elseif view == "wheel" or view == "wheels" or view == "vehicle"
        or view == "compaction" then
        view = "traffic"
    end
    if self.DEBUG_VIEWS[view] ~= true then
        return "TerraLogic: unknown debug view. Use 'tlViews' to list all panels."
    end

    -- There is deliberately only one active view. Selecting another one
    -- replaces the old mode instead of stacking a second overlay.
    self.debugMode = view
    self.debugEnabled = true
    self.debugLines = nil
    self.workQualityDebugLines = nil
    self.soilProcessDebugLines = nil
    self.soilProcessDebugSnapshot = nil
    self.trafficDebugLines = nil
    self.debugNextRefresh = 0
    self.workQualityDebugNextRefresh = 0
    self.soilProcessDebugNextRefresh = 0
    self.trafficDebugNextRefresh = 0
    return string.format("TerraLogic debug view: %s", string.upper(view))
end

function TerraLogicMain:consoleCommandDebugViews()
    local lines = {
        "TerraLogic DEBUG PANELS (open with: tlView <name>)"
    }
    for _, entry in ipairs(self.DEBUG_VIEW_HELP) do
        local active = self.debugEnabled and self.debugMode == entry.name
            and " [ACTIVE]" or ""
        lines[#lines + 1] = string.format(
            "  %-10s - %s%s",
            entry.name,
            entry.description,
            active
        )
    end
    lines[#lines + 1] = "Close the active panel with: tlDebugClose"
    return table.concat(lines, "\n")
end

function TerraLogicMain:consoleCommandDebugClose()
    self.debugEnabled = false
    self.debugLines = nil
    self.soilProcessDebugLines = nil
    self.soilProcessDebugSnapshot = nil
    self.trafficDebugLines = nil
    self.debugNextRefresh = 0
    return "TerraLogic debug view: CLOSED"
end

-- Current-panel CSV logger --------------------------------------------------

local function panelCsvCell(value)
    local text = value == nil and "" or tostring(value)
    text = string.gsub(text, "\r", " ")
    text = string.gsub(text, "\n", "\\n")
    text = string.gsub(text, '"', '""')
    return '"' .. text .. '"'
end

local function getPanelLogDirectories()
    if getUserProfileAppPath == nil then return {} end
    local settings = getUserProfileAppPath() .. "modSettings"
    local base = settings .. "/FS25_TerraLogic"
    local preferred = base .. "/panelLogs"
    -- fileExists() is a file check and is not reliable for directories in the
    -- GIANTS runtime. Creating an existing folder is harmless; pcall also
    -- covers platforms that report that situation as an error.
    if createFolder ~= nil then
        pcall(createFolder, settings)
        pcall(createFolder, base)
        pcall(createFolder, preferred)
    end
    -- The first successful createFile() decides. The fallbacks keep logging
    -- usable on platforms that cannot create more deeply nested directories.
    return {preferred, base, settings}
end

function TerraLogicMain:writePanelLogHeader(logger)
    local fields = {
        "schema_version", "sample_index", "real_timestamp",
        "logger_elapsed_s", "mission_time_ms", "calendar_year",
        "monotonic_day", "period", "day_in_period", "day_time_h",
        "days_per_period", "time_scale", "panel", "panel_line_count",
        "test_name", "event_type", "event_detail"
    }
    for index=1,self.PANEL_LOG_LINE_COLUMNS do
        fields[#fields + 1] = string.format("line_%02d", index)
    end
    fields[#fields + 1] = "overflow_lines"
    local encoded = {}
    for _, field in ipairs(fields) do
        encoded[#encoded + 1] = panelCsvCell(field)
    end
    fileWrite(logger.file, table.concat(encoded, ";") .. "\n")
end

function TerraLogicMain:startPanelLogger(label)
    if g_client == nil then
        return false, "TerraLogic: panel logger requires a local game client"
    end
    if self.panelLogger ~= nil and self.panelLogger.active == true then
        return false, string.format(
            "TerraLogic panel logger already active | samples=%d | %s",
            self.panelLogger.sampleCount or 0,
            tostring(self.panelLogger.path or "unknown file"))
    end
    if self.debugEnabled ~= true or self.DEBUG_VIEWS[self.debugMode] ~= true then
        return false,
            "TerraLogic: open a debug panel with tlView <name> before starting the logger"
    end
    local stamp = getDate ~= nil and getDate("%Y%m%d_%H%M%S")
        or tostring(g_time or 0)
    local initialView = string.gsub(tostring(self.debugMode), "[^%w_-]", "_")
    local safeLabel = tostring(label or "")
    safeLabel = string.gsub(safeLabel, "[^%w_-]", "_")
    safeLabel = string.sub(safeLabel, 1, 64)
    safeLabel = string.gsub(safeLabel, "^_+", "")
    safeLabel = string.gsub(safeLabel, "_+$", "")
    local labelPart = safeLabel ~= "" and "_" .. safeLabel or ""
    if createFile == nil or FileAccess == nil or FileAccess.WRITE == nil then
        return false, "TerraLogic: GIANTS file API unavailable"
    end
    local file, path = 0, nil
    for _, directory in ipairs(getPanelLogDirectories()) do
        local candidate = string.format(
            "%s/TerraLogic_panel_%s%s_%s.csv",
            directory, initialView, labelPart, stamp)
        local ok, result = pcall(createFile, candidate, FileAccess.WRITE)
        if ok and result ~= nil and result ~= 0 then
            file, path = result, candidate
            break
        end
    end
    if file == nil or file == 0 then
        return false,
            "TerraLogic: unable to create a CSV file below the modSettings directory"
    end
    self.panelLogger = {
        active=true, file=file, path=path, initialView=initialView,
        label=safeLabel,
        elapsedMs=0, sampleTimerMs=0, sampleCount=0,
        pausedTicks=0, lastLines=nil, lastView=nil
    }
    self:writePanelLogHeader(self.panelLogger)
    Logging.info("[FS25_TerraLogic] Panel logger started: %s", path)
    return true, "TerraLogic panel logger STARTED | " .. path
end

function TerraLogicMain:stopPanelLogger(reason)
    local logger = self.panelLogger
    if logger == nil or logger.active ~= true then
        return false, "TerraLogic panel logger is not active"
    end
    logger.active = false
    if logger.file ~= nil and logger.file ~= 0 then
        delete(logger.file)
        logger.file = nil
    end
    local message = string.format(
        "TerraLogic panel logger STOPPED | samples=%d | paused ticks=%d | %s",
        logger.sampleCount or 0, logger.pausedTicks or 0,
        tostring(logger.path or "unknown file"))
    if reason ~= nil and reason ~= "" then
        message = message .. " | " .. tostring(reason)
    end
    Logging.info("[FS25_TerraLogic] %s", message)
    return true, message
end

function TerraLogicMain:consoleCommandPanelLog(value, label)
    local requested = value ~= nil and string.lower(tostring(value)) or ""
    if requested == "start" or requested == "on" then
        return select(2, self:startPanelLogger(label))
    elseif requested == "stop" or requested == "off" then
        return select(2, self:stopPanelLogger("console"))
    elseif requested == "" or requested == "status" then
        local logger = self.panelLogger
        if logger == nil or logger.active ~= true then
            return "TerraLogic panel logger: OFF | use tlPanelLog start"
        end
        return string.format(
            "TerraLogic panel logger: ON | samples=%d | current panel=%s | %s",
            logger.sampleCount or 0,
            self.debugEnabled and tostring(self.debugMode) or "CLOSED/PAUSED",
            tostring(logger.path or "unknown file"))
    end
    return "TerraLogic usage: tlPanelLog start [testId] | stop | status"
end

-- High-frequency soil WorkArea trace --------------------------------------
-- The normal audit panels deliberately sample only once per second. That is
-- ideal for balancing, but too slow to diagnose a one-frame raster seam. This
-- opt-in writer records callbacks and both Tilth and Evenness raster cells.
function TerraLogicMain:writeSoilTraceRecord(values)
    local trace = self.soilTraceLogger
    if trace == nil or trace.active ~= true
        or trace.file == nil or trace.file == 0 then return false end
    trace.rowCount = (trace.rowCount or 0) + 1
    local fields = {
        2, trace.rowCount,
        getDate ~= nil and getDate("%Y-%m-%dT%H:%M:%S") or "",
        g_currentMission ~= nil and tonumber(g_currentMission.time) or ""
    }
    for _, name in ipairs(trace.columns) do
        fields[#fields + 1] = values ~= nil and values[name] or ""
    end
    local encoded = {}
    for _, field in ipairs(fields) do
        encoded[#encoded + 1] = panelCsvCell(field)
    end
    fileWrite(trace.file, table.concat(encoded, ";") .. "\n")
    return true
end

function TerraLogicMain:startSoilTrace(label)
    if g_server == nil then
        return false, "TerraLogic: soil trace must be started on the host/server"
    end
    if self.soilTraceLogger ~= nil
        and self.soilTraceLogger.active == true then
        return false, "TerraLogic soil trace is already active"
    end
    if createFile == nil or FileAccess == nil or FileAccess.WRITE == nil then
        return false, "TerraLogic: GIANTS file API unavailable"
    end
    local safeLabel = tostring(label or "workarea")
    safeLabel = string.gsub(safeLabel, "[^%w_-]", "_")
    safeLabel = string.sub(safeLabel, 1, 64)
    if safeLabel == "" then safeLabel = "workarea" end
    local stamp = getDate ~= nil and getDate("%Y%m%d_%H%M%S")
        or tostring(g_time or 0)
    local file, path = 0, nil
    for _, directory in ipairs(getPanelLogDirectories()) do
        local candidate = string.format(
            "%s/TerraLogic_soil_trace_%s_%s.csv",
            directory, safeLabel, stamp)
        local ok, result = pcall(createFile, candidate, FileAccess.WRITE)
        if ok and result ~= nil and result ~= 0 then
            file, path = result, candidate
            break
        end
    end
    if file == nil or file == 0 then
        return false, "TerraLogic: unable to create soil trace CSV"
    end
    local columns = {
        "event", "callback_id", "class", "implement", "work_area",
        "layer", "cell_x", "cell_z", "raw_changed_area",
        "raw_total_area", "successful_area", "ground_contact", "armed",
        "exit_geometry", "reason", "speed_kph", "geometry_sx",
        "geometry_sz", "geometry_width_x", "geometry_width_z",
        "geometry_height_x", "geometry_height_z", "previous_age_ms",
        "sweep_distance_m", "sweep_max_distance_m", "sweep_accepted",
        "raw_coverage", "raw_samples", "field_samples", "worked_samples",
        "normalized_coverage", "cultivatable_coverage", "cache_state",
        "cache_gap_ms", "cache_added_samples", "cache_previous_coverage",
        "cache_first_added_samples", "cache_repeat_added_samples",
        "physical_samples", "tolerance_samples",
        "cache_after_coverage", "cache_repeat_coverage",
        "cache_repeat_threshold", "surface", "eligible", "before_value",
        "model_value", "after_value", "delta", "write_applied",
        "build", "base_value", "last_applied_value", "last_model_value",
        "target_value", "rule_mode", "effective_strength", "roller_contact",
        "moisture_effectiveness", "soil_type", "rated_speed_kph",
        "overspeed_severity", "engagement", "after_rule_value",
        "after_speed_value", "proposed_value", "visibility_ensured",
        "evenness_before_pct", "evenness_after_pct"
    }
    self.soilTraceLogger = {
        active=true, file=file, path=path, columns=columns,
        rowCount=0, callbackId=0
    }
    local header = {"schema_version", "row_index", "real_timestamp",
        "mission_time_ms"}
    for _, name in ipairs(columns) do header[#header + 1] = name end
    local encoded = {}
    for _, field in ipairs(header) do
        encoded[#encoded + 1] = panelCsvCell(field)
    end
    fileWrite(file, table.concat(encoded, ";") .. "\n")
    Logging.info("[FS25_TerraLogic] Soil trace started: %s", path)
    return true, "TerraLogic soil trace STARTED | " .. path
end

function TerraLogicMain:stopSoilTrace(reason)
    local trace = self.soilTraceLogger
    if trace == nil or trace.active ~= true then
        return false, "TerraLogic soil trace is not active"
    end
    trace.active = false
    if trace.file ~= nil and trace.file ~= 0 then
        delete(trace.file)
        trace.file = nil
    end
    local message = string.format(
        "TerraLogic soil trace STOPPED | rows=%d | %s",
        trace.rowCount or 0, tostring(trace.path or "unknown file"))
    if reason ~= nil and reason ~= "" then
        message = message .. " | " .. tostring(reason)
    end
    Logging.info("[FS25_TerraLogic] %s", message)
    return true, message
end

function TerraLogicMain:consoleCommandSoilTrace(action, label)
    local requested = string.lower(tostring(action or "status"))
    if requested == "start" or requested == "on" then
        return select(2, self:startSoilTrace(label))
    elseif requested == "stop" or requested == "off" then
        return select(2, self:stopSoilTrace("console"))
    elseif requested == "status" or requested == "" then
        local trace = self.soilTraceLogger
        if trace == nil or trace.active ~= true then
            return "TerraLogic soil trace: OFF | use tlSoilTrace start <name>"
        end
        return string.format("TerraLogic soil trace: ON | rows=%d | %s",
            trace.rowCount or 0, tostring(trace.path or "unknown file"))
    end
    return "TerraLogic usage: tlSoilTrace start [name] | stop | status"
end

-- Called by the common renderer, so these are exactly the lines visible on
-- the current tlView page rather than a second independently maintained data
-- model. Copying prevents a cached panel table from changing underneath a
-- pending one-second sample.
function TerraLogicMain:captureDebugPanelLines(lines)
    local logger = self.panelLogger
    if logger == nil or logger.active ~= true
        or self.debugEnabled ~= true or lines == nil then return end
    -- A recording has one stable schema. Opening another tlView temporarily
    -- pauses capture instead of mixing unrelated panel lines into the CSV.
    if logger.initialView ~= tostring(self.debugMode or "") then return end
    local copy = {}
    for index, line in ipairs(lines) do copy[index] = tostring(line) end
    logger.lastLines = copy
    logger.lastView = tostring(self.debugMode or "overview")
    if logger.pendingStartEvent == true then
        logger.pendingStartEvent = false
        self:writePanelLogSample(logger, "test_start", logger.testName)
    end
end

function TerraLogicMain:writePanelLogSample(logger, eventType, eventDetail)
    if logger.file == nil or logger.file == 0 then return false end
    local environment = g_currentMission ~= nil
        and g_currentMission.environment or nil
    local monotonicDay = environment ~= nil
        and tonumber(environment.currentMonotonicDay) or nil
    local dayInPeriod = nil
    if environment ~= nil and monotonicDay ~= nil
        and type(environment.getDayInPeriodFromDay) == "function" then
        local ok, value = pcall(
            environment.getDayInPeriodFromDay, environment, monotonicDay)
        if ok then dayInPeriod = tonumber(value) end
    end
    local dayTimeHours = environment ~= nil
        and (tonumber(environment.dayTime) or 0) / 3600000 or nil
    local timeScale = 0
    if g_currentMission ~= nil
        and type(g_currentMission.getEffectiveTimeScale) == "function" then
        local ok, value = pcall(
            g_currentMission.getEffectiveTimeScale, g_currentMission)
        if ok then timeScale = tonumber(value) or 0 end
    elseif g_currentMission ~= nil and g_currentMission.missionInfo ~= nil then
        timeScale = tonumber(g_currentMission.missionInfo.timeScale) or 0
    end
    logger.sampleCount = (logger.sampleCount or 0) + 1
    local lines = logger.lastLines or {}
    local fields = {
        3, logger.sampleCount,
        getDate ~= nil and getDate("%Y-%m-%dT%H:%M:%S") or "",
        string.format("%.3f", (logger.elapsedMs or 0) / 1000),
        g_currentMission ~= nil and tonumber(g_currentMission.time) or "",
        environment ~= nil and tonumber(environment.currentYear) or "",
        monotonicDay or "",
        environment ~= nil and tonumber(environment.currentPeriod) or "",
        dayInPeriod or "",
        dayTimeHours ~= nil and string.format("%.6f", dayTimeHours) or "",
        environment ~= nil and tonumber(environment.daysPerPeriod) or "",
        string.format("%.3f", timeScale),
        logger.lastView or "",
        #lines,
        logger.testName or logger.label or "",
        eventType or "sample",
        eventDetail or ""
    }
    local overflow = {}
    for index=1,self.PANEL_LOG_LINE_COLUMNS do
        fields[#fields + 1] = lines[index] or ""
    end
    for index=self.PANEL_LOG_LINE_COLUMNS + 1,#lines do
        overflow[#overflow + 1] = lines[index]
    end
    fields[#fields + 1] = table.concat(overflow, "\\n")
    local encoded = {}
    for _, field in ipairs(fields) do
        encoded[#encoded + 1] = panelCsvCell(field)
    end
    fileWrite(logger.file, table.concat(encoded, ";") .. "\n")
    return true
end

function TerraLogicMain:updatePanelLogger(dt)
    local logger = self.panelLogger
    if logger == nil or logger.active ~= true then return end
    local amount = math.max(tonumber(dt) or 0, 0)
    logger.elapsedMs = (logger.elapsedMs or 0) + amount
    logger.sampleTimerMs = (logger.sampleTimerMs or 0) + amount
    if logger.sampleTimerMs < self.PANEL_LOG_INTERVAL_MS then return end
    -- Never generate catch-up rows after a long frame. One current snapshot is
    -- more useful for balancing and keeps accelerated-year logs compact.
    logger.sampleTimerMs = logger.sampleTimerMs % self.PANEL_LOG_INTERVAL_MS
    if self.debugEnabled ~= true
        or logger.lastLines == nil
        or logger.lastView ~= tostring(self.debugMode) then
        logger.pausedTicks = (logger.pausedTicks or 0) + 1
        return
    end
    self:writePanelLogSample(logger)
end

-- One-command test recorder -----------------------------------------------

local function resolveCaptureTestPanel(main, value)
    local requested = string.lower(tostring(value or ""))
    requested = string.gsub(requested, "%s+", "")
    local resolved = main.TEST_PANEL_ALIASES[requested] or requested
    if main.DEBUG_VIEWS[resolved] == true then return resolved end
    return nil
end

function TerraLogicMain:consoleCommandCaptureTestStart(panel, name)
    local resolved = resolveCaptureTestPanel(self, panel)
    if resolved == nil then
        return "TerraLogic usage: tlTestStart <panel> <name> | use tlTestPanels"
    end
    local safeName = tostring(name or "")
    safeName = string.gsub(safeName, "[^%w_-]", "_")
    safeName = string.sub(safeName, 1, 64)
    safeName = string.gsub(safeName, "^_+", "")
    safeName = string.gsub(safeName, "_+$", "")
    if safeName == "" then
        return "TerraLogic: give this recording a name: tlTestStart "
            .. resolved .. " <name>"
    end
    if self.panelLogger ~= nil and self.panelLogger.active == true then
        return "TerraLogic: a test recording is already active; use tlTestStop first"
    end
    self:consoleCommandDebugView(resolved)
    local ok, message = self:startPanelLogger(safeName)
    if not ok then return message end
    local logger = self.panelLogger
    logger.testMode = true
    logger.testName = safeName
    logger.requestedPanel = tostring(panel or resolved)
    logger.pendingStartEvent = true
    if TerraLogicAuditManager ~= nil
        and TerraLogicAuditManager.beginPanelCapture ~= nil then
        TerraLogicAuditManager:beginPanelCapture(safeName, resolved)
    end
    return string.format(
        "TerraLogic test STARTED | panel=%s | name=%s | %s",
        resolved, safeName, tostring(logger.path or "CSV"))
end

function TerraLogicMain:consoleCommandCaptureTestStop()
    local logger = self.panelLogger
    if logger == nil or logger.active ~= true or logger.testMode ~= true then
        return "TerraLogic: no tlTest recording is active"
    end
    -- Very short recordings can be stopped before the first one-second tick.
    -- Still produce an unambiguous start/end pair in that case.
    if logger.pendingStartEvent == true then
        logger.pendingStartEvent = false
        self:writePanelLogSample(logger, "test_start", logger.testName)
    end
    self:writePanelLogSample(logger, "test_end", logger.testName)
    local message = select(2, self:stopPanelLogger("test complete"))
    if TerraLogicAuditManager ~= nil
        and TerraLogicAuditManager.endPanelCapture ~= nil then
        TerraLogicAuditManager:endPanelCapture()
    end
    return message
end

function TerraLogicMain:consoleCommandCaptureTestStatus()
    local logger = self.panelLogger
    if logger == nil or logger.active ~= true or logger.testMode ~= true then
        return "TerraLogic test recorder: OFF | use tlTestStart <panel> <name>"
    end
    local state = self.debugEnabled == true
        and tostring(self.debugMode) == tostring(logger.initialView)
        and "RECORDING" or "PAUSED (open the recorded panel again)"
    return string.format(
        "TerraLogic test recorder: %s | panel=%s | name=%s | samples=%d | %s",
        state,
        tostring(logger.initialView or "unknown"),
        tostring(logger.testName or "unnamed"),
        logger.sampleCount or 0,
        tostring(logger.path or "unknown file"))
end

function TerraLogicMain:consoleCommandCaptureTestPanels()
    local lines = {"TerraLogic TEST PANELS (tlTestStart <panel> <name>)"}
    for _, entry in ipairs(self.TEST_PANEL_HELP) do
        lines[#lines + 1] = string.format(
            "  %-12s - %s", entry.name, entry.description)
    end
    lines[#lines + 1] = "Exact tlView panel names are also accepted."
    return table.concat(lines, "\n")
end

function TerraLogicMain:consoleCommandDamageAnalysis(value)
    if g_currentMission == nil or not g_currentMission:getIsServer() then
        return "TerraLogic: damage analysis is available on the server/host"
    end
    local implement = self:getDebugImplement(true)
    if implement == nil or implement.spec_terraLogic == nil then
        return "TerraLogic: no supported implement selected or attached"
    end
    local requested = value ~= nil and string.lower(tostring(value)) or ""
    if requested ~= "" and requested ~= "reset" and requested ~= "start" then
        return "TerraLogic usage: tlDamageAnalysis [reset]"
    end
    if requested == "reset" or requested == "start" then
        implement:resetOverSpeedDamageAnalysis()
    end
    self:consoleCommandDebugView("damageanalysis")
    return requested == "reset" or requested == "start"
        and "TerraLogic damage analysis: RESET and running"
        or "TerraLogic damage analysis: OPEN (use 'tlDamageAnalysis reset' for a new session)"
end

function TerraLogicMain:consoleCommandDebug(value)
    if value == nil or value == "" then
        if self.debugEnabled then
            return self:consoleCommandDebugClose()
        end
        return self:consoleCommandDebugView(self.debugMode or "overview")
    end

    local requested = string.lower(tostring(value))
    local enabled = parseEnabled(requested)
    if enabled == false then
        return self:consoleCommandDebugClose()
    elseif enabled == true then
        return self:consoleCommandDebugView(self.debugMode or "overview")
    end
    return self:consoleCommandDebugView(requested)
end

function TerraLogicMain:consoleCommandSetDamage(value)
    if g_currentMission == nil or not g_currentMission:getIsServer() then
        return "TerraLogic: tlSetDamage must be executed on the server/host"
    end

    local damagePercent = tonumber(value)
    if damagePercent == nil or damagePercent < 0 or damagePercent > 100 then
        return "TerraLogic usage: tlSetDamage <0-100>"
    end

    local implement = self:getDebugImplement(true)
    if implement == nil or implement.setDamageAmount == nil then
        return "TerraLogic: no supported implement selected or attached"
    end

    implement:setDamageAmount(damagePercent / 100, true)
    local spec = implement.spec_terraLogic
    if spec ~= nil then
        spec.damageRatePerMs = 0
        spec.telemetryElapsedMs = 0
        spec.telemetryDistanceM = 0
        spec.telemetryVanillaDamage = 0
        spec.telemetryCurrentDamage = 0
        spec.telemetryContinuousDamage = 0
        spec.telemetryActiveMs = 0
        spec.telemetrySpeedMultiplierTime = 0
        spec.telemetryTotalMultiplierTime = 0
        spec.telemetryDraftMultiplierTime = 0
        spec.vanillaDamagePerHectare = nil
        spec.currentDamagePerHectare = nil
        spec.continuousDamagePerHectare = nil
    end

    return string.format(
        "TerraLogic: damage for '%s' set to %.2f%%",
        implement.getName ~= nil and implement:getName() or "implement",
        damagePercent
    )
end

-- HUD implement selection ---------------------------------------------------

-- Finds the selected or attached implement used by debug panels.
function TerraLogicMain:getDebugImplement(allowInactive)
    if g_localPlayer == nil or g_localPlayer:getCurrentVehicle() == nil then
        return nil
    end

    local vehicle = g_localPlayer:getCurrentVehicle()
    local vehicleSpec = vehicle.spec_terraLogic
    if vehicleSpec ~= nil
        and (vehicleSpec.isGroundTool == true or vehicleSpec.isApplicationTool == true)
        and vehicleSpec.ratedSpeed ~= nil and vehicleSpec.optimalSpeed ~= nil then
        local isWorking = (vehicle.getIsOverSpeedGroundContactActive ~= nil
                and vehicle:getIsOverSpeedGroundContactActive())
            or (vehicle.getIsOverSpeedApplicationActive ~= nil
                and vehicle:getIsOverSpeedApplicationActive())
        if allowInactive or isWorking then
            return vehicle
        end
    end
    if vehicle.getSelectedImplement ~= nil then
        local selected = vehicle:getSelectedImplement()
        if selected ~= nil and selected.object ~= nil and selected.object.spec_terraLogic ~= nil then
            local selectedSpec = selected.object.spec_terraLogic
            if (selectedSpec.isGroundTool == true or selectedSpec.isApplicationTool == true)
                and selectedSpec.ratedSpeed ~= nil
                and selectedSpec.optimalSpeed ~= nil then
                return selected.object
            end
        end
    end

    local rootVehicle = vehicle.rootVehicle or vehicle
    if rootVehicle.childVehicles ~= nil then
        for _, child in ipairs(rootVehicle.childVehicles) do
            if child ~= vehicle and child.spec_terraLogic ~= nil
                and (child.spec_terraLogic.isGroundTool == true
                    or child.spec_terraLogic.isApplicationTool == true)
                and child.spec_terraLogic.ratedSpeed ~= nil
                and child.spec_terraLogic.optimalSpeed ~= nil then
                local isWorking = (child.getIsOverSpeedGroundContactActive ~= nil
                        and child:getIsOverSpeedGroundContactActive())
                    or (child.getIsOverSpeedApplicationActive ~= nil
                        and child:getIsOverSpeedApplicationActive())
                if allowInactive or isWorking then
                    return child
                end
            end
        end
    end

    return nil
end

-- Returns the world position sampled by the standard field-information HUD.
local function getHudWorldPosition(display)
    local player = display ~= nil and display.player or g_localPlayer
    if player ~= nil and player.getPositionData ~= nil then
        local x, _, z = player:getPositionData()
        return x, z
    end
    local vehicle = player ~= nil and player:getCurrentVehicle() or nil
    local node = vehicle ~= nil and (vehicle.rootNode or vehicle.components ~= nil
        and vehicle.components[1] ~= nil and vehicle.components[1].node) or nil
    if node == nil and player ~= nil then
        node = player.rootNode
    end
    if node == nil then return nil, nil end
    local x, _, z = getWorldTranslation(node)
    return x, z
end

local function getIsGameHudVisible()
    if g_noHudModeEnabled == true or g_currentMission == nil
        or g_currentMission.hud == nil then
        return false
    end
    local hud = g_currentMission.hud
    if type(hud.getIsVisible) == "function" and not hud:getIsVisible() then
        return false
    end
    if type(hud.isVisible) == "boolean" and not hud.isVisible then
        return false
    end
    return true
end

function TerraLogicMain:getFieldInfoDisplay()
    local hud = g_currentMission ~= nil and g_currentMission.hud or nil
    local display = hud ~= nil and hud.fieldInfoDisplay or nil
    if display ~= nil and display.addCustomText ~= nil
        and display.clearCustomText ~= nil then
        return display
    end
    return nil
end

function TerraLogicMain:clearQualityFieldInfoRows()
    local display = self:getFieldInfoDisplay()
    if display ~= nil and self.qualityFieldInfoRows ~= nil then
        for _, rowIndex in ipairs(self.qualityFieldInfoRows) do
            if rowIndex ~= nil and rowIndex > 0 then
                display:clearCustomText(rowIndex)
            end
        end
    end
    self.qualityFieldInfoRows = nil
    self.qualityFieldInfoSignature = nil
end

local function getIsSpeedHudImplementReady(implement, requireWorkReady)
    local spec = implement ~= nil and implement.spec_terraLogic or nil
    if spec == nil then return false end
    -- Vehicle types may share broad GIANTS specializations (especially
    -- sprayer). Runtime classification is the final authority: unsupported
    -- water, transport or utility tools must not enter the TerraLogic HUD.
    if spec.implementClassKey == nil then return false end
    -- "Always on" describes the HUD itself, not the current work state. A
    -- recognized attached implement therefore remains selectable while raised,
    -- switched off or stationary. Dynamic mode keeps the strict live checks.
    if requireWorkReady ~= true then return true end
    if spec.isNexatModule == true then
        -- NEXAT carries its modules inside the system vehicle instead of a
        -- conventional three-point attachment.  Consequently GIANTS can
        -- report the implement chain as raised even while the electronic work
        -- mode is active.  Prefer NEXAT's synchronized turn-on/application
        -- state and recent accepted processing; normal implements retain the
        -- established lowered-chain guard below.
        local inWorkPosition = TerraLogic == nil
            or TerraLogic.getIsOverSpeedWorkAreaInWorkPosition == nil
            or TerraLogic.getIsOverSpeedWorkAreaInWorkPosition(implement) == true
        if not inWorkPosition then return false end
        if spec.actualWorkActive == true
            or spec.qualityWorkActive == true then
            return true
        end
        if spec.isApplicationTool == true
            and implement.getIsOverSpeedApplicationActive ~= nil
            and implement:getIsOverSpeedApplicationActive() == true then
            return true
        end
        if implement.spec_turnOnVehicle ~= nil
            and implement.getIsTurnedOn ~= nil then
            return implement:getIsTurnedOn() == true
        end
        -- Pure ground modules without a turn-on specialization still become
        -- eligible as soon as their own lowered state is available.  Do not
        -- assume readiness merely because a permanently mounted module has
        -- WorkAreas; that would show the dynamic HUD in transport mode.
        if spec.isGroundTool == true and implement.getIsLowered ~= nil then
            return implement:getIsLowered() == true
        end
        return false
    end
    if spec.isGroundTool == true or spec.isSurfaceForageTool == true then
        -- Dynamic readiness checks only the machine state here. Whether the
        -- pass actually changed an eligible field cell is evaluated separately
        -- for the quality label.
        local lowered = implement.getIsImplementChainLowered ~= nil
            and implement:getIsImplementChainLowered(true) == true
        if implement.getIsImplementChainLowered == nil
            and spec.isSurfaceForageTool == true then
            lowered = implement.getIsLowered == nil or implement:getIsLowered() == true
        end
        -- Call the internal helper directly. It is intentionally not registered
        -- as a vehicle function, so duplicate specialization registration by a
        -- third-party vehicle type cannot bypass the folded-roller guard.
        local inWorkPosition = TerraLogic == nil
            or TerraLogic.getIsOverSpeedWorkAreaInWorkPosition == nil
            or TerraLogic.getIsOverSpeedWorkAreaInWorkPosition(implement) == true
        local requiresTurnedOn = implement.spec_turnOnVehicle ~= nil
            or spec.isSurfaceForageTool == true
            or implement.spec_stonePicker ~= nil
        if TerraLogicSpecialImplements.isPassiveSeedFunction(implement)
            and implement.getIsLowered ~= nil
            and implement:getIsLowered() == false then return false end
        if requiresTurnedOn
            and not TerraLogicSpecialImplements.isPassiveSeedFunction(implement)
            and implement.getIsTurnedOn ~= nil then
            return lowered and inWorkPosition and implement:getIsTurnedOn() == true
        end
        return lowered and inWorkPosition
    end
    if spec.isApplicationTool == true then
        return implement.getIsOverSpeedApplicationActive ~= nil
            and implement:getIsOverSpeedApplicationActive() == true
    end
    return false
end

-- Selects the most restrictive work-ready implement for the shared speed HUD.
-- Successful density-map work is deliberately not required here: that state
-- belongs to the quality label and would make pickup tools flicker.
function TerraLogicMain:getSpeedHudImplement(requireWorkReady, currentSpeed)
    local vehicle = g_localPlayer ~= nil and g_localPlayer:getCurrentVehicle() or nil
    if vehicle == nil then return nil end
    local candidates, seen = {}, {}
    local function addCandidate(candidate)
        if candidate ~= nil and not seen[candidate]
            and getIsSpeedHudImplementReady(candidate, requireWorkReady) then
            seen[candidate] = true
            candidates[#candidates + 1] = candidate
        end
    end

    -- Include a self-propelled work vehicle and every active child in the
    -- complete attachment chain. Selection no longer decides which tool owns
    -- the HUD; the slowest active rated speed is the operational bottleneck.
    addCandidate(vehicle)
    local rootVehicle = vehicle.rootVehicle or vehicle
    for _, child in ipairs(rootVehicle.childVehicles or {}) do
        addCandidate(child)
    end
    if vehicle.getSelectedImplement ~= nil then
        local selected = vehicle:getSelectedImplement()
        addCandidate(selected ~= nil and selected.object or nil)
    end

    local limiting = nil
    for _, candidate in ipairs(candidates) do
        local spec = candidate.spec_terraLogic
        local rated = spec ~= nil and tonumber(spec.ratedSpeed) or nil
        local safe = spec ~= nil
            and (tonumber(spec.safeSpeed) or tonumber(spec.optimalSpeed)) or nil
        if rated ~= nil and rated > 0 then
            local limitingSpec = limiting ~= nil
                and limiting.spec_terraLogic or nil
            local limitingRated = limitingSpec ~= nil
                and tonumber(limitingSpec.ratedSpeed) or math.huge
            local limitingSafe = limitingSpec ~= nil
                and (tonumber(limitingSpec.safeSpeed)
                    or tonumber(limitingSpec.optimalSpeed)) or math.huge
            if rated < limitingRated - 0.001
                or (math.abs(rated - limitingRated) <= 0.001
                    and (safe or rated) < limitingSafe) then
                limiting = candidate
            end
        end
    end
    return limiting, #candidates, candidates
end

-- Legacy note: this formatter belonged to the old limiting-implement label.
-- The label was removed, so the helper is intentionally retained but unused
-- until compact implement names are needed by a future HUD or debug view.
local function getCompactImplementName(implement)
    local name = implement ~= nil and implement.getName ~= nil
        and tostring(implement:getName() or "") or ""
    if name == "" then return "Implement" end
    local maxCharacters = 18
    if utf8Strlen ~= nil and utf8Substr ~= nil then
        local okLength, length = pcall(utf8Strlen, name)
        if okLength and tonumber(length) ~= nil and length > maxCharacters then
            local okText, shortened = pcall(
                utf8Substr, name, 0, maxCharacters - 1)
            if okText and shortened ~= nil then return shortened .. "…" end
        end
        return name
    end
    return #name > maxCharacters
        and string.sub(name, 1, maxCharacters - 1) .. "..." or name
end

local function getSpeedHudWorkQualityComponent(implement)
    local spec = implement ~= nil and implement.spec_terraLogic or nil
    if spec == nil then return nil end
    if implement.spec_sowingMachine ~= nil then
        return "seed"
    elseif implement.spec_sprayer ~= nil then
        return TerraLogic ~= nil
            and TerraLogic.getApplicationComponentForVehicle ~= nil
            and TerraLogic.getApplicationComponentForVehicle(implement)
            or spec.applicationQualityComponent or "fertilizer"
    elseif implement.spec_plow ~= nil then
        return "soilPlow"
    elseif implement.spec_cultivator ~= nil or implement.spec_subsoiler ~= nil
        or spec.implementClassKey == "powerHarrow"
        or spec.implementClassKey == "discHarrow"
        or spec.implementClassKey == "ridgeFormer"
        or spec.implementClassKey == "spader" then
        return "soilCultivate"
    elseif implement.spec_roller ~= nil then
        return "roller"
    elseif implement.spec_mulcher ~= nil then
        return "mulch"
    end
    -- Remaining supported tools use only visible mechanical consequences. The
    -- HUD resolves those through their physical dropout profile below instead
    -- of pretending that they write agronomic quality into field chunks.
    return nil
end

local function getSpeedHudPhysicalQualityProfile(implement)
    local spec = implement ~= nil and implement.spec_terraLogic or nil
    local profileName = spec ~= nil and spec.dropoutProfile or nil
    local profile = profileName ~= nil and TerraLogicDropoutManager ~= nil
        and TerraLogicDropoutManager:getProfile(profileName) or nil
    -- Staged seed and application profiles already use their stored Work
    -- Quality component. Only surface-island profiles need a synthetic HUD
    -- value derived from their expected mechanically missed share.
    return profile ~= nil and profile.enabled == true
        and profile.patternType == "surfaceIslands" and profileName or nil
end

local function getIsSpeedHudQualityActive(
        implement, currentSpeed, qualityComponent, physicalProfile)
    local spec = implement ~= nil and implement.spec_terraLogic or nil
    if spec == nil or (tonumber(currentSpeed) or 0) < 0.5 then
        return false
    end
    local usesStoredQuality = qualityComponent ~= nil
    if usesStoredQuality and spec.qualityWorkActive == true then return true end
    if physicalProfile ~= nil and spec.actualWorkActive == true then return true end
    -- Same-frame listen-server fallbacks before the synchronized flags reach
    -- the HUD. These timestamps are set only after accepted chunk work or
    -- actual physical material/ground processing respectively.
    local now = g_currentMission ~= nil and (g_currentMission.time or 0) or 0
    if usesStoredQuality then
        return spec.lastQualityWorkTime ~= nil
            and now - spec.lastQualityWorkTime <= 500
    end
    return physicalProfile ~= nil and spec.lastActualWorkTime ~= nil
        and now - spec.lastActualWorkTime <= 500
end

-- Mechanical load follows physical ground contact, not successful field-map
-- work. A lowered plough still produces draft, abrasion and possible overload
-- on unowned land or away from a recognized field, while Work Quality remains
-- unavailable there because no agronomic operation was accepted.
local function getIsSpeedHudMechanicalActive(implement, currentSpeed)
    local spec = implement ~= nil and implement.spec_terraLogic or nil
    if spec == nil or spec.mechanicalLoadModel == "none"
        or (tonumber(currentSpeed) or 0) < 0.5 then return false end
    if implement.getIsOverSpeedGroundContactActive ~= nil then
        return implement:getIsOverSpeedGroundContactActive() == true
    end
    return getIsSpeedHudImplementReady(implement, true)
end

function TerraLogicMain:getSpeedHudWorkQuality(implement, currentSpeed)
    if TerraLogicQualityManager == nil then return nil end
    local component = getSpeedHudWorkQualityComponent(implement)
    if component == nil then return nil end
    -- The speed HUD describes execution quality, not PF's transient remaining
    -- N/pH gain at the exact map pixel. Using that local gain made the display
    -- jump back to 100% on already optimal ground.
    local quality, _, economy = TerraLogicQualityManager:getWorkQualityModel(
        implement, currentSpeed, component, nil)
    local spec = implement.spec_terraLogic
    local soilDropout = economy ~= nil
        and math.max(tonumber(economy.soilDropoutFraction) or 0, 0) or 0
    local dropout = 0
    local speedDropout = 0
    local conditionDropout = 0
    local rainDropout = economy ~= nil and math.max(
        tonumber(economy.herbicideRainDropoutFraction) or 0, 0) or 0
    if component == "seed" then
        dropout = math.max(
            tonumber(spec.seedQualityMissedFraction) or 0,
            tonumber(spec.seedSoilDropoutFraction) or 0)
        speedDropout = math.max(
            tonumber(spec.seedQualityPureSpeedPenalty) or 0, 0)
        -- Lane quantization can make the actually visible missed share a little
        -- larger than its continuous speed/soil target. That remainder is a
        -- spatial rounding effect, not implement wear. Seed dropouts are
        -- explicitly speed/soil driven, so use only the model's real condition
        -- contribution here (currently zero for the seed profile).
        conditionDropout = math.max(
            tonumber(spec.seedQualityDamageTolerancePenalty) or 0, 0)
    elseif spec.surfacePatchDropoutTargetFraction ~= nil then
        dropout = math.max(
            tonumber(spec.surfacePatchDropoutTargetFraction) or 0, 0)
        speedDropout = math.max(
            tonumber(spec.applicationQualityPureSpeedPenalty)
                or tonumber(spec.applicationQualitySpeedPenalty) or 0, 0)
        conditionDropout = math.max(
            tonumber(spec.applicationQualityDamageTolerancePenalty) or 0, 0)
    end
    dropout = math.max(
        dropout, speedDropout, conditionDropout, soilDropout, rainDropout)
    return quality, {
        speedLoss=economy ~= nil and math.max(
            1-(tonumber(economy.qualityBeforeCondition) or 1), 0) or 0,
        conditionLoss=economy ~= nil and math.max(
            tonumber(economy.conditionQualityLoss) or 0, 0) or 0,
        soilLoss=economy ~= nil and math.max(
            tonumber(economy.soilQualityLoss) or 0, 0) or 0,
        dropoutFraction=dropout,
        speedDropoutFraction=speedDropout,
        conditionDropoutFraction=conditionDropout,
        soilDropoutFraction=soilDropout,
        soilContext=economy ~= nil and economy.soilMitigation or nil,
        frostSeverity=economy ~= nil and economy.frostSeverity or 0,
        rainLoss=economy ~= nil and math.max(
            tonumber(economy.herbicideRainQualityLoss) or 0, 0) or 0,
        rainDropoutFraction=rainDropout,
        rainSeverity=economy ~= nil and math.max(
            tonumber(economy.herbicideRainSeverity) or 0, 0) or 0
    }
end

function TerraLogicMain:getSpeedHudPhysicalWorkQuality(
        implement, currentSpeed, profileName)
    local spec = implement ~= nil and implement.spec_terraLogic or nil
    if spec == nil or profileName == nil
        or TerraLogicDropoutManager == nil then
        return nil
    end
    local physicalDropoutsEnabled = TerraLogicSettings == nil
        or TerraLogicSettings.getPhysicalDropoutsEnabled == nil
        or TerraLogicSettings:getPhysicalDropoutsEnabled()
    if not physicalDropoutsEnabled then
        return 1, {speedLoss=0, conditionLoss=0, soilLoss=0,
            dropoutFraction=0, speedDropoutFraction=0,
            conditionDropoutFraction=0, soilDropoutFraction=0}
    end
    local speedFailureFraction =
        TerraLogicDropoutManager:getSurfacePatchFailureFraction(
            profileName,
            currentSpeed,
            tonumber(spec.ratedSpeed) or 0
        )
    local _, conditionPenalty =
        TerraLogicQualityManager:getConditionQualityModel(
            implement, currentSpeed)
    local failureFraction =
        TerraLogicDropoutManager:getSurfacePatchFailureFraction(
            profileName,
            currentSpeed,
            tonumber(spec.ratedSpeed) or 0,
            conditionPenalty
        )
    local soilQualityFactor, soilDropoutFraction, soilContext,
        soilMitigation = 1, 0, nil, nil
    if TerraLogicQualityManager ~= nil then
        soilQualityFactor, soilDropoutFraction, soilContext, soilMitigation =
            TerraLogicQualityManager:getMitigatedSoilSuitability(
                implement, currentSpeed, spec.implementClassKey)
    end
    failureFraction = 1 - (1 - math.clamp(failureFraction, 0, 1))
        * (1 - math.clamp(soilDropoutFraction, 0, 1))
    -- This is deliberately an expected execution quality, not persisted field
    -- quality. It uses the exact same target curve as the WorkArea dropout
    -- adapter, so pickup material left behind and the displayed percentage
    -- move together without frame-to-frame lane-selection flicker.
    local quality = math.clamp(1 - (tonumber(failureFraction) or 0), 0, 1)
    local speedQuality = math.clamp(
        1 - (tonumber(speedFailureFraction) or 0), 0, 1)
    return quality, {
        speedLoss=math.max(1-speedQuality, 0),
        conditionLoss=math.max(conditionPenalty, 0),
        soilLoss=math.max(soilDropoutFraction, 0),
        dropoutFraction=math.max(failureFraction, 0),
        speedDropoutFraction=math.max(speedFailureFraction, 0),
        conditionDropoutFraction=math.max(conditionPenalty, 0),
        soilDropoutFraction=math.max(soilDropoutFraction, 0),
        soilContext=soilMitigation,
        frostSeverity=soilContext ~= nil
            and (tonumber(soilContext.frostSeverity) or 0) or 0
    }
end

local function getSpeedHudScaledPixels(widthPx, heightPx)
    local hud = g_currentMission ~= nil and g_currentMission.hud or nil
    local reference = hud ~= nil and (hud.fillLevelsDisplay
        or hud.speedMeterDisplay) or nil
    if reference ~= nil
        and reference.scalePixelValuesToScreenVector ~= nil then
        return reference:scalePixelValuesToScreenVector(
            widthPx or 0, heightPx or 0)
    end
    if getNormalizedScreenValues ~= nil then
        return getNormalizedScreenValues(widthPx or 0, heightPx or 0)
    end
    return (widthPx or 0) / 1920, (heightPx or 0) / 1080
end

local function getSpeedHudDefaultTextPixels()
    return HUDElement ~= nil and HUDElement.TEXT_SIZE ~= nil
        and tonumber(HUDElement.TEXT_SIZE.DEFAULT_TEXT) or 14
end

local function setSpeedHudConditionTextColor(conditionDamage, alpha)
    alpha = math.clamp(tonumber(alpha) or 1, 0, 1)
    if conditionDamage >= 0.90 then
        setTextColor(SPEED_HUD_CRITICAL_COLOR[1],
            SPEED_HUD_CRITICAL_COLOR[2], SPEED_HUD_CRITICAL_COLOR[3], alpha)
    elseif conditionDamage >= 0.75 then
        setTextColor(SPEED_HUD_CAUTION_COLOR[1],
            SPEED_HUD_CAUTION_COLOR[2], SPEED_HUD_CAUTION_COLOR[3], alpha)
    else
        setTextColor(1, 0.82, 0.18, alpha)
    end
end

local function updateSpeedHudFade(self, now, shouldShow)
    local alpha = math.clamp(
        tonumber(self.speedHudFadeAlpha) or 0, 0, 1)
    local lastTime = tonumber(self.speedHudFadeLastTime) or now
    local elapsed = math.max(now - lastTime, 0)
    local duration = math.max(
        tonumber(TerraLogicMain.SPEED_HUD_FADE_DURATION_MS) or 0, 0)
    local step = duration > 0 and elapsed / duration or 1
    if shouldShow then
        alpha = math.min(alpha + step, 1)
    else
        alpha = math.max(alpha - step, 0)
    end
    self.speedHudFadeAlpha = alpha
    self.speedHudFadeLastTime = now
    return alpha
end

-- Creates reusable overlays once; no textures are allocated during rendering.
function TerraLogicMain:ensureSpeedHudOverlays()
    if self.speedHudOverlays ~= nil then
        return self.speedHudOverlays.available == true
    end
    local state = {available = false, background = {}, bars = {}}
    self.speedHudOverlays = state
    if g_overlayManager == nil or ThreePartOverlay == nil then return false end

    local ok = pcall(function()
        state.background.left = g_overlayManager:createOverlay(
            "gui.filltypes_left", 0, 0, 0, 0)
        state.background.middle = g_overlayManager:createOverlay(
            "gui.filltypes_middle", 0, 0, 0, 0)
        state.background.right = g_overlayManager:createOverlay(
            "gui.filltypes_right", 0, 0, 0, 0)
        local background = HUD ~= nil and HUD.COLOR ~= nil
            and HUD.COLOR.BACKGROUND or {0.01, 0.01, 0.01, 0.58}
        for _, overlay in pairs(state.background) do
            overlay:setColor(background[1], background[2],
                background[3], background[4])
        end
        for index = 1, 3 do
            local bar = ThreePartOverlay.new()
            bar:setLeftPart("gui.progressbar_left", 0, 0)
            bar:setMiddlePart("gui.progressbar_middle", 0, 0)
            bar:setRightPart("gui.progressbar_right", 0, 0)
            state.bars[index] = bar
        end
    end)
    state.available = ok
    return ok
end

function TerraLogicMain:deleteSpeedHudOverlays()
    local state = self.speedHudOverlays
    if state == nil then return end
    for _, overlay in pairs(state.background or {}) do
        if overlay ~= nil and overlay.delete ~= nil then overlay:delete() end
    end
    for _, overlay in pairs(state.bars or {}) do
        if overlay ~= nil and overlay.delete ~= nil then overlay:delete() end
    end
    self.speedHudOverlays = nil
end

function TerraLogicMain:renderSpeedHudBackground(x, y, width, height, alpha)
    if not self:ensureSpeedHudOverlays() then return false end
    local state = self.speedHudOverlays
    alpha = math.clamp(tonumber(alpha) or 1, 0, 1)
    local capWidth = select(1, getSpeedHudScaledPixels(10, 0))
    capWidth = math.min(capWidth, width * 0.25)
    local left, middle, right = state.background.left,
        state.background.middle, state.background.right
    local background = HUD ~= nil and HUD.COLOR ~= nil
        and HUD.COLOR.BACKGROUND or {0.01, 0.01, 0.01, 0.58}
    for _, overlay in pairs(state.background) do
        overlay:setColor(background[1], background[2], background[3],
            (background[4] or 1) * alpha)
    end
    left:setPosition(x, y)
    left:setDimension(capWidth, height)
    middle:setPosition(x + capWidth, y)
    middle:setDimension(math.max(width - capWidth * 2, 0), height)
    right:setPosition(x + width - capWidth, y)
    right:setDimension(capWidth, height)
    left:render()
    middle:render()
    right:render()
    return true
end

function TerraLogicMain:renderSpeedHudBar(
        index, x, y, width, height, color, roundedLeft, roundedRight, alpha)
    local state = self.speedHudOverlays
    local bar = state ~= nil and state.bars[index] or nil
    if bar == nil or width <= 0 or type(color) ~= "table" then return false end
    local capWidth = select(1, getSpeedHudScaledPixels(3, 0))
    capWidth = math.min(capWidth, width * 0.5)
    local leftWidth = roundedLeft and capWidth or 0
    local rightWidth = roundedRight and capWidth or 0
    bar:setLeftPart(nil, leftWidth, height)
    bar:setMiddlePart(nil,
        math.max(width - leftWidth - rightWidth, 0), height)
    bar:setRightPart(nil, rightWidth, height)
    alpha = math.clamp(tonumber(alpha) or 1, 0, 1)
    bar:setColor(color[1], color[2], color[3],
        (color[4] or 1) * alpha)
    bar:setPosition(x, y)
    bar:render()
    return true
end

-- Draws the compact speed range, current marker and optional quality label.
function TerraLogicMain:drawLegacySpeedHud()
    if self.enabled == false or g_localPlayer == nil then return end
    local hudMode = TerraLogicSettings ~= nil
        and TerraLogicSettings.speedHudMode or "dynamic"
    local now = g_currentMission.time or 0
    if hudMode == "off" then
        self.speedHudFadeAlpha = 0
        self.speedHudFadeLastTime = now
        return
    end
    local vehicle = g_localPlayer:getCurrentVehicle()
    if self.speedHudVehicle ~= vehicle then
        self.speedHudVehicle = vehicle
        self.speedHudVehicleNameHiddenUntil = vehicle ~= nil
            and now + TerraLogicMain.SPEED_HUD_VEHICLE_NAME_DELAY_MS or 0
        self.speedHudImplement = nil
        self.speedHudOptimalSince = nil
        self.speedHudFadeAlpha = 0
        self.speedHudFadeLastTime = now
    end
    if vehicle == nil or drawFilledRect == nil or not getIsGameHudVisible() then
        self.speedHudFadeAlpha = 0
        self.speedHudFadeLastTime = now
        return
    end

    local currentSpeed = math.abs(vehicle:getLastSpeed(true) or 0)
    -- Dynamic mode requires the implement to be lowered/in work position and,
    -- where applicable, switched on. It does not require a positive density-
    -- map result, so balers remain stable over sparse windrows. Always mode
    -- intentionally keeps recognized attached tools visible in every state.
    local requestedImplement, activeImplementCount = self:getSpeedHudImplement(
        hudMode == "dynamic", currentSpeed)
    local implement = requestedImplement
    if implement == nil and hudMode == "dynamic"
        and (self.speedHudFadeAlpha or 0) > 0 then
        -- Keep the last eligible attached tool available for the short fade
        -- after it is raised or switched off. Gameplay readiness still
        -- controls the target visibility and Work Quality state.
        implement, activeImplementCount = self:getSpeedHudImplement(
            false, currentSpeed)
    end
    if implement == nil then
        self.speedHudImplement = nil
        self.speedHudOptimalSince = nil
        self.speedHudFadeAlpha = 0
        self.speedHudFadeLastTime = now
        return
    end
    local spec = implement.spec_terraLogic
    local shopSpeed = tonumber(spec.ratedSpeed) or 0
    local realSpeed = tonumber(spec.safeSpeed)
        or tonumber(spec.optimalSpeed) or shopSpeed
    local suitabilityContext = spec.soilSuitabilityContext
    local suitabilityIsFresh = suitabilityContext ~= nil
        and now - (tonumber(suitabilityContext.time) or now) <= 2500
    if suitabilityIsFresh and (spec.implementClassKey == "sowingMachine"
        or spec.implementClassKey == "directDrill"
        or spec.implementClassKey == "precisionPlanter"
        or spec.implementClassKey == "precisionDirectDrill"
        or spec.seedSoilClassKey ~= nil) then
        local soilSafeMaximum = math.min(shopSpeed, math.max(
            tonumber(suitabilityContext.safeSpeedKph) or shopSpeed, 0.5))
        shopSpeed = soilSafeMaximum
        -- For seed tools the soil-safe value is the upper green boundary.
        -- Preserve a compact efficiency range below it; slower travel remains
        -- harmless but is shown blue as economically unnecessary.
        realSpeed = math.min(realSpeed,
            math.max(soilSafeMaximum * 0.80, soilSafeMaximum - 3))
    end
    if shopSpeed <= 0 then return end
    local qualityComponent = getSpeedHudWorkQualityComponent(implement)
    local physicalQualityProfile =
        getSpeedHudPhysicalQualityProfile(implement)
    local isQualityActive = getIsSpeedHudQualityActive(
        implement, currentSpeed, qualityComponent, physicalQualityProfile)
    -- Multiplayer work confirmation can briefly toggle at a quality-cell or PF
    -- soil boundary. Keep the last active state for a short HUD-only grace
    -- period while the same implement remains work-ready and moving. Stopping,
    -- raising or switching the tool off still produces "Work quality: -"
    -- immediately.
    if isQualityActive then
        self.speedHudQualityGraceImplement = implement
        self.speedHudQualityActiveUntil = now + 1200
    elseif currentSpeed >= 0.5
        and self.speedHudQualityGraceImplement == implement
        and now <= (self.speedHudQualityActiveUntil or 0)
        and getIsSpeedHudImplementReady(implement, true) then
        isQualityActive = true
    end
    -- Work quality and the number of detected implements explain the speed
    -- bar and are therefore a permanent part of the work HUD.
    local hasDisplayedWorkQuality = spec.implementClassKey ~= "defoliator"
        and (qualityComponent ~= nil or physicalQualityProfile ~= nil)
    local quality = nil
    if hasDisplayedWorkQuality and isQualityActive then
        if qualityComponent ~= nil then
            quality = self:getSpeedHudWorkQuality(implement, currentSpeed)
        else
            quality = self:getSpeedHudPhysicalWorkQuality(
                implement, currentSpeed, physicalQualityProfile)
        end
    end
    local conditionDamage = implement.getDamageAmount ~= nil
        and math.clamp(
            tonumber(implement:getDamageAmount()) or 0, 0, 1) or 0
    local showUnavailableQuality = hasDisplayedWorkQuality and quality == nil
    local showImplementCount = qualityTextEnabled
        and (activeImplementCount or 0) > 1
    local showSupplementalRow = renderText ~= nil
        and (quality ~= nil or showUnavailableQuality or showImplementCount)

    if self.speedHudImplement ~= implement then
        self.speedHudImplement = implement
        self.speedHudOptimalSince = nil
    end
    local cruiseSpeed = nil
    if vehicle ~= nil and vehicle.getCruiseControlSpeed ~= nil then
        cruiseSpeed = tonumber(vehicle:getCruiseControlSpeed())
    elseif vehicle ~= nil and vehicle.spec_drivable ~= nil
        and vehicle.spec_drivable.cruiseControl ~= nil then
        cruiseSpeed = tonumber(vehicle.spec_drivable.cruiseControl.speed)
    end
    if cruiseSpeed ~= nil then
        if self.speedHudCruiseVehicle == vehicle
            and self.speedHudCruiseSpeed ~= nil
            and math.abs(cruiseSpeed - self.speedHudCruiseSpeed) >= 0.1 then
            self.speedHudForcedUntil = now + 3000
        end
        self.speedHudCruiseVehicle = vehicle
        self.speedHudCruiseSpeed = cruiseSpeed
    end
    local isOptimal = currentSpeed >= realSpeed - 0.25
        and currentSpeed <= shopSpeed + 0.25
    local hideForOptimalSpeed = false
    if hudMode == "dynamic" and isOptimal then
        self.speedHudOptimalSince = self.speedHudOptimalSince or now
        if now - self.speedHudOptimalSince >= 3000
            and now >= (self.speedHudForcedUntil or 0) then
            hideForOptimalSpeed = true
        end
    elseif hudMode == "dynamic" then
        self.speedHudOptimalSince = nil
    else
        self.speedHudOptimalSince = nil
    end
    local vehicleNameFinished =
        now >= (self.speedHudVehicleNameHiddenUntil or 0)
    -- Dynamic mode follows confirmed field or material processing rather than
    -- a field-boundary test. This keeps the HUD off while a lowered tool merely
    -- travels over a road, but still supports mowers, tedders, windrowers and
    -- pickups wherever they actually process grass or swath. "Always on"
    -- deliberately retains the ready-state preview and its quality dash.
    local dynamicWorkVisible = hudMode ~= "dynamic" or isQualityActive
    local shouldShowSpeedHud = requestedImplement ~= nil
        and dynamicWorkVisible and vehicleNameFinished and not hideForOptimalSpeed
    local speedHudAlpha = updateSpeedHudFade(
        self, now, shouldShowSpeedHud)
    if speedHudAlpha <= 0 then
        return
    end

    -- Pixel values follow the Vanilla fill-level widget and are scaled through
    -- an existing HUDDisplay when available, including the user's UI scale.
    local centreX = 0.5
    local width, height = getSpeedHudScaledPixels(225, 6)
    -- The narrow bar-only box needs one extra pixel below the progress bar to
    -- visually match the rounded border's upper inset.
    local paddingBottomPixels = showSupplementalRow and 8 or 7
    local paddingX, paddingBottom = getSpeedHudScaledPixels(
        14, paddingBottomPixels)
    local qualityTextPixels = math.max(
        getSpeedHudDefaultTextPixels() - 2, 10)
    local _, textHeight = getSpeedHudScaledPixels(0,
        showSupplementalRow and qualityTextPixels or 0)
    local _, textGap = getSpeedHudScaledPixels(0,
        showSupplementalRow and 7 or 0)
    local _, paddingTop = getSpeedHudScaledPixels(0,
        showSupplementalRow and 4 or 8)
    local boxWidth = width + paddingX * 2
    local boxHeight = paddingBottom + height + textGap + textHeight + paddingTop
    -- Raise the complete widget another seven pixels while retaining the same
    -- UI-scale-aware bottom anchoring on different resolutions.
    local _, boxY = getSpeedHudScaledPixels(0, 30)
    local centreY = boxY + paddingBottom + height * 0.5
    local x, y = centreX - width * 0.5, centreY - height * 0.5
    -- Zoom the scale around the useful working range. Realistic-to-shop speed
    -- always occupies 60% of the bar; the remaining 40% provides equally
    -- sized slow/overspeed safety zones. This keeps narrow green ranges
    -- readable instead of compressing them into a global 0..50 km/h scale.
    local safetyShare = 0.20
    local greenShare = 0.60
    local greenSpeedRange = math.max(shopSpeed - realSpeed, 0.1)
    local safetySpeedRange = greenSpeedRange * safetyShare / greenShare
    local visibleMinimum = realSpeed - safetySpeedRange
    local visibleMaximum = shopSpeed + safetySpeedRange
    local visibleRange = math.max(visibleMaximum - visibleMinimum, 0.1)
    local realX = x + width * safetyShare
    local shopX = x + width * (safetyShare + greenShare)
    -- Keep marker motion continuous across the zoomed range. The live speed is
    -- intentionally not rounded, so narrow working ranges remain precise.
    local markerRatio = (currentSpeed - visibleMinimum) / visibleRange
    local markerOutsideLeft = markerRatio < 0
    local markerOutsideRight = markerRatio > 1
    local markerOutside = markerOutsideLeft or markerOutsideRight
    local markerX = x + width * math.clamp(markerRatio, 0, 1)

    -- Use the same rounded background and progress-bar slices as Vanilla's
    -- fill-level display. Rectangle rendering remains as a compatibility
    -- fallback for HUD replacement mods which remove these shared classes.
    local boxX = centreX - boxWidth * 0.5
    local nativeStyle = self:renderSpeedHudBackground(
        boxX, boxY, boxWidth, boxHeight, speedHudAlpha)
    if not nativeStyle then
        drawFilledRect(boxX, boxY, boxWidth, boxHeight,
            0.01, 0.01, 0.01, 0.58 * speedHudAlpha)
    end
    local blue = {0.0097, 0.4287, 0.6445, 1}
    local green = HUD ~= nil and HUD.COLOR ~= nil and HUD.COLOR.ACTIVE
        or {0.22, 0.68, 0.30, 1}
    local orange = SPEED_HUD_CAUTION_COLOR
    if nativeStyle then
        self:renderSpeedHudBar(1, x, y, math.max(realX - x, 0),
            height, blue, true, false, speedHudAlpha)
        self:renderSpeedHudBar(2, realX, y,
            math.max(shopX - realX, 0), height, green, false, false,
            speedHudAlpha)
        self:renderSpeedHudBar(3, shopX, y,
            math.max(x + width - shopX, 0), height, orange, false, true,
            speedHudAlpha)
    else
        drawFilledRect(x, y, math.max(realX - x, 0), height,
            blue[1], blue[2], blue[3], blue[4] * speedHudAlpha)
        drawFilledRect(realX, y, math.max(shopX - realX, 0), height,
            green[1], green[2], green[3],
            (green[4] or 1) * speedHudAlpha)
        drawFilledRect(shopX, y, math.max(x + width - shopX, 0), height,
            orange[1], orange[2], orange[3], orange[4] * speedHudAlpha)
    end
    drawFilledRect(realX - 0.00054, y - 0.00214,
        0.00108, height + 0.00428, 0.85, 0.92, 1, speedHudAlpha)
    drawFilledRect(shopX - 0.00054, y - 0.00214,
        0.00108, height + 0.00428, 1, 0.82, 0.18, speedHudAlpha)
    -- An out-of-range marker remains clamped to the appropriate edge and
    -- blinks, signalling that the real speed lies beyond the zoomed scale.
    local markerVisible = not markerOutside
        or math.floor(now / 300) % 2 == 0
    if markerVisible then
        drawFilledRect(markerX - 0.0008, y - 0.00374,
            0.0016, height + 0.00748, 1, 1, 1, speedHudAlpha)
    end

    if showSupplementalRow and renderText ~= nil then
        local _, size = getSpeedHudScaledPixels(0, qualityTextPixels)
        setTextBold(false)
        setTextColor(1, 1, 1, speedHudAlpha)
        -- Fixed anchors keep changing percentages and tool counts stable.
        if quality ~= nil then
            local roundedQuality = math.floor(
                math.clamp(quality, 0, 1) * 100 + 0.5)
            local label
            if conditionDamage >= 0.9995 then
                local format = TerraLogicQualityManager:getText(
                    "terraLogic_speedHudQualityBroken",
                    "Work quality (broken): %d %%")
                label = TerraLogicI18n.format(format, roundedQuality)
                setSpeedHudConditionTextColor(conditionDamage, speedHudAlpha)
            elseif conditionDamage >= 0.90 then
                local format = TerraLogicQualityManager:getText(
                    "terraLogic_speedHudQualityDamaged",
                    "Work quality (damaged): %d %%")
                label = TerraLogicI18n.format(format, roundedQuality)
                setSpeedHudConditionTextColor(conditionDamage, speedHudAlpha)
            elseif conditionDamage >= 0.75 then
                local format = TerraLogicQualityManager:getText(
                    "terraLogic_speedHudQualityWorn",
                    "Work quality (worn): %d %%")
                label = TerraLogicI18n.format(format, roundedQuality)
                setSpeedHudConditionTextColor(conditionDamage, speedHudAlpha)
            else
                local format = TerraLogicQualityManager:getText(
                    "terraLogic_speedHudQuality", "Work quality: %d %%")
                label = TerraLogicI18n.format(format, roundedQuality)
            end
            setTextAlignment(RenderText.ALIGN_LEFT)
            renderText(x, y + height + textGap, size, label)
            setTextColor(1, 1, 1, speedHudAlpha)
        elseif showUnavailableQuality then
            local label
            if conditionDamage >= 0.9995 then
                label = TerraLogicQualityManager:getText(
                    "terraLogic_speedHudQualityBrokenUnavailable",
                    "Work quality (broken): -")
                setSpeedHudConditionTextColor(conditionDamage, speedHudAlpha)
            elseif conditionDamage >= 0.90 then
                label = TerraLogicQualityManager:getText(
                    "terraLogic_speedHudQualityDamagedUnavailable",
                    "Work quality (damaged): -")
                setSpeedHudConditionTextColor(conditionDamage, speedHudAlpha)
            elseif conditionDamage >= 0.75 then
                label = TerraLogicQualityManager:getText(
                    "terraLogic_speedHudQualityWornUnavailable",
                    "Work quality (worn): -")
                setSpeedHudConditionTextColor(conditionDamage, speedHudAlpha)
            else
                label = TerraLogicQualityManager:getText(
                    "terraLogic_speedHudQualityUnavailable", "Work quality: -")
            end
            setTextAlignment(RenderText.ALIGN_LEFT)
            renderText(x, y + height + textGap, size, label)
            setTextColor(1, 1, 1, speedHudAlpha)
        end
        if showImplementCount then
            local countFormat = TerraLogicQualityManager:getText(
                "terraLogic_speedHudActiveImplements", "%d tools")
            local countLabel = TerraLogicI18n.format(
                countFormat, activeImplementCount)
            setTextAlignment(RenderText.ALIGN_RIGHT)
            renderText(x + width, y + height + textGap, size, countLabel)
        end
        setTextAlignment(RenderText.ALIGN_LEFT)
        setTextColor(1, 1, 1, 1)
    end
end

local function updateWorkHudWarningFade(self, now, visible)
    local alpha = math.clamp(
        tonumber(self.workHudWarningFadeAlpha) or 0, 0, 1)
    local previous = tonumber(self.workHudWarningFadeTime) or now
    local elapsed = math.max(now - previous, 0)
    local step = elapsed / math.max(
        tonumber(TerraLogicMain.SPEED_HUD_FADE_DURATION_MS) or 250, 1)
    alpha = visible and math.min(alpha + step, 1)
        or math.max(alpha - step, 0)
    self.workHudWarningFadeAlpha = alpha
    self.workHudWarningFadeTime = now
    return alpha
end

local function getWorkHudText(key, fallback)
    return TerraLogicQualityManager ~= nil
        and TerraLogicQualityManager:getText(key, fallback) or fallback
end

local WORK_HUD_SEEDING_CLASSES = {
    sowingMachine=true, directDrill=true,
    precisionPlanter=true, precisionDirectDrill=true
}
local WORK_HUD_PICKUP_CLASSES = {
    baler=true, loaderWagon=true
}
local WORK_HUD_HAY_CLASSES = {
    windrower=true, tedder=true
}
local WORK_HUD_TILLAGE_CLASSES = {
    plow=true, subsoiler=true, cultivator=true,
    shallowCultivator=true, discHarrow=true,
    powerHarrow=true, spader=true
}
local WORK_HUD_APPLICATION_CLASSES = {
    fertilizerSpreader=true, liquidSprayer=true,
    manureSpreader=true, slurrySpreader=true, slurryApplicator=true,
    slurryInjector=true
}

local function getWorkHudClassGroup(classKey)
    if TerraLogicSpecialImplements.SEED_CLASSES[classKey]
        or classKey == "ridgeFormer" or classKey == "defoliator" then
        return classKey
    end
    if classKey == "roller" then return "roller" end
    if WORK_HUD_SEEDING_CLASSES[classKey] then return "seeding" end
    if WORK_HUD_PICKUP_CLASSES[classKey] then return "pickup" end
    if WORK_HUD_HAY_CLASSES[classKey] then return "hay" end
    if WORK_HUD_TILLAGE_CLASSES[classKey] then return "tillage" end
    if WORK_HUD_APPLICATION_CLASSES[classKey] then return "application" end
    return "general"
end

-- Translate the same measured cause into the consequence a player actually
-- sees with this implement. The warning source and queue id remain unchanged,
-- so better wording cannot create extra messages or queue flicker.
local function getWorkHudClassWarning(classGroup, cause, hasDropout)
    local specialDetail = TerraLogicSpecialImplements.getWarning(classGroup, cause)
    if specialDetail ~= nil then return nil, specialDetail end
    if classGroup == "roller" then
        local key = ({overspeed="Speed", condition="Wear", wet="Wet",
            dry="Dry", frost="Frost", uneven="Uneven", soil="Soil"})[cause]
        if key ~= nil then
            return nil, getWorkHudText("terraLogic_workHudRoller"..key.."Detail",
                "Rolling is less effective; check speed and soil conditions")
        end
    end
    if cause == "overspeed" then
        if classGroup == "seeding" then
            return getWorkHudText("terraLogic_workHudSeedingSpeedTitle",
                    "SEEDING TOO FAST"),
                getWorkHudText(hasDropout
                        and "terraLogic_workHudSeedingSpeedDropoutDetail"
                        or "terraLogic_workHudSeedingSpeedQualityDetail",
                    hasDropout
                        and "Openers lose ground contact; crop gaps are being created"
                        or "Seed placement becomes less even at this speed")
        elseif classGroup == "pickup" then
            return getWorkHudText("terraLogic_workHudPickupSpeedTitle",
                    "PICKUP TOO FAST"),
                getWorkHudText(hasDropout
                        and "terraLogic_workHudPickupSpeedDropoutDetail"
                        or "terraLogic_workHudPickupSpeedQualityDetail",
                    hasDropout
                        and "The pickup is leaving material on the field"
                        or "Material pickup becomes less reliable at this speed")
        elseif classGroup == "hay" then
            return getWorkHudText("terraLogic_workHudHaySpeedTitle",
                    "HAY WORK TOO FAST"),
                getWorkHudText(hasDropout
                        and "terraLogic_workHudHaySpeedDropoutDetail"
                        or "terraLogic_workHudHaySpeedQualityDetail",
                    hasDropout
                        and "Material is not being turned or raked completely"
                        or "The swath result becomes less even at this speed")
        elseif classGroup == "tillage" then
            return getWorkHudText("terraLogic_workHudTillageSpeedTitle",
                    "SOIL WORK TOO FAST"),
                getWorkHudText(hasDropout
                        and "terraLogic_workHudTillageSpeedDropoutDetail"
                        or "terraLogic_workHudTillageSpeedQualityDetail",
                    hasDropout
                        and "The tool loses working depth; untreated gaps are appearing"
                        or "The implement does not achieve its full soil effect at this speed")
        elseif classGroup == "application" then
            return getWorkHudText("terraLogic_workHudApplicationSpeedTitle",
                    "APPLICATION TOO FAST"),
                getWorkHudText(hasDropout
                        and "terraLogic_workHudApplicationSpeedDropoutDetail"
                        or "terraLogic_workHudApplicationSpeedQualityDetail",
                    hasDropout
                        and "Coverage gaps are appearing"
                        or "Application becomes less even at this speed")
        end
    elseif cause == "condition" then
        if classGroup == "seeding" then
            return nil, getWorkHudText(hasDropout
                    and "terraLogic_workHudSeedingWearDropoutDetail"
                    or "terraLogic_workHudSeedingWearQualityDetail",
                hasDropout
                    and "Worn openers are causing crop gaps; repair the seeder"
                    or "Worn openers reduce seed-placement quality; repair the seeder")
        elseif classGroup == "pickup" then
            return nil, getWorkHudText(hasDropout
                    and "terraLogic_workHudPickupWearDropoutDetail"
                    or "terraLogic_workHudPickupWearQualityDetail",
                hasDropout
                    and "Wear is causing material to remain on the field; repair the implement"
                    or "Wear reduces reliable material pickup; repair the implement")
        end
    elseif cause == "uneven" then
        if classGroup == "seeding" then
            return nil, getWorkHudText(hasDropout
                    and "terraLogic_workHudSeedingUnevenDropoutDetail"
                    or "terraLogic_workHudSeedingUnevenQualityDetail",
                hasDropout
                    and "Openers lose contact on the uneven seedbed; slow down or level it"
                    or "Seed placement is uneven because the seedbed is rough")
        elseif classGroup == "pickup" then
            return nil, getWorkHudText(hasDropout
                    and "terraLogic_workHudPickupUnevenDropoutDetail"
                    or "terraLogic_workHudPickupUnevenQualityDetail",
                hasDropout
                    and "The pickup cannot follow the surface; material remains behind"
                    or "The pickup follows the uneven surface less reliably")
        elseif classGroup == "hay" then
            return nil, getWorkHudText(hasDropout
                    and "terraLogic_workHudHayUnevenDropoutDetail"
                    or "terraLogic_workHudHayUnevenQualityDetail",
                hasDropout
                    and "The tines lose contact; material is not fully turned or raked"
                    or "Uneven ground makes the swath result inconsistent")
        elseif classGroup == "tillage" then
            return nil, getWorkHudText("terraLogic_workHudTillageUnevenDetail",
                "The tool is not maintaining a consistent working depth")
        elseif classGroup == "application" then
            return nil, getWorkHudText(
                "terraLogic_workHudApplicationUnevenDetail",
                "Uneven ground makes application less consistent")
        end
    elseif cause == "wet" then
        if classGroup == "seeding" then
            return nil, getWorkHudText("terraLogic_workHudSeedingWetDetail",
                "Wet soil reduces seed placement quality.")
        elseif classGroup == "tillage" then
            return nil, getWorkHudText("terraLogic_workHudTillageWetDetail",
                "Wet soil smears instead of crumbling cleanly")
        end
    elseif cause == "dry" then
        if classGroup == "seeding" then
            return nil, getWorkHudText("terraLogic_workHudSeedingDryDetail",
                "Openers penetrate unevenly; seed depth becomes inconsistent")
        elseif classGroup == "tillage" then
            return nil, getWorkHudText("terraLogic_workHudTillageDryDetail",
                "Hard dry soil reduces penetration and the intended soil effect")
        end
    elseif cause == "frost" then
        if classGroup == "seeding" then
            return nil, getWorkHudText("terraLogic_workHudSeedingFrostDetail",
                "Openers cannot penetrate reliably; placement and emergence suffer")
        elseif classGroup == "tillage" then
            return nil, getWorkHudText("terraLogic_workHudTillageFrostDetail",
                "The tool cannot reach its intended depth in frozen soil")
        end
    end
    return nil, nil
end

-- Warning attribution uses the contributions that actually produced the
-- suitability result. Mere presence of rough ground is not evidence of cause.
local function getWorkHudSoilWarningCause(context, classGroup, loss, dropout)
    if context == nil then return nil end
    local structuralLoss = math.max(1-(context.structuralQualityFactor or 1), 0)
    local moistureLoss = math.max(1-(context.moistureQualityFactor or 1), 0)
    local structuralDropout = context.structuralDropoutFraction or 0
    local moistureDropout = context.moistureDropoutFraction or 0
    local missing = dropout >= TerraLogicMain.WORK_HUD_DROPOUT_WARNING_FRACTION
    local environmentDominant = missing
        and moistureDropout > structuralDropout
        or not missing and moistureLoss > structuralLoss
    if environmentDominant then
        local frostLoss = math.max(1-(context.frostQualityFactor or 1), 0)
        local wetLoss, dryLoss = context.wetQualityLoss or 0,
            context.dryQualityLoss or 0
        if (context.frostSeverity or 0) >= 0.35
            and ((missing and (context.frostDropoutFraction or 0) > 0)
                or frostLoss >= math.max(wetLoss, dryLoss)) then
            return "frost"
        elseif wetLoss > 0 and wetLoss >= dryLoss then return "wetSoil"
        elseif dryLoss > 0 then return "drySoil" end
        return "soil"
    end
    -- Difficult starting soil is normal for a seedbed tool. Keep the measured
    -- quality, but reserve structural alerts for substantial losses or gaps.
    if (classGroup == "tillage" or classGroup == "roller")
        and loss < 0.15 and not missing then return nil end
    local factor = missing and context.dominantDropoutFactor
        or context.dominantQualityFactor
    if factor == "roughness" then return "unevenSoil" end
    if factor == "aggregateSize" and classGroup == "seeding" then
        local tilth = (context.averages or {}).aggregateSize or 0.5
        return tilth < 0.5 and "coarseSoil" or "fineSoil"
    end
    return "soil"
end

local function getWorkHudWarning(
        self, implement, quality, qualityContext, isQualityActive,
        isMechanicalActive, now, standalone)
    local spec = implement ~= nil and implement.spec_terraLogic or nil
    local warningVehicle = g_localPlayer ~= nil and g_localPlayer:getCurrentVehicle() or nil
    -- Tool messages belong to the tool that produced them, not to whichever
    -- tractor/trailer happens to be driven next. Clear the reading slot too.
    if self.workHudWarningImplement ~= implement then
        self.workHudWarningSources, self.workHudWarningQueue = {}, {}
        self.workHudWarningCurrentId, self.workHudWarningCurrent = nil, nil
        self.workHudLastWarning, self.workHudWarningLayoutState = nil, nil
        self.workHudWarningFadeAlpha = 0
    end
    self.workHudWarningImplement = implement
    local candidatesById = {}
    local function consider(candidate)
        if candidate ~= nil then
            candidate.id = candidate.id
                or tostring(candidate.title or candidate.priority or "warning")
            local previous = candidatesById[candidate.id]
            if previous == nil or (tonumber(candidate.priority) or 0)
                > (tonumber(previous.priority) or 0) then
                candidatesById[candidate.id] = candidate
            end
        end
    end
    if spec ~= nil then
        local damage = implement.getDamageAmount ~= nil
            and math.clamp(tonumber(implement:getDamageAmount()) or 0, 0, 1) or 0
        local broken = damage >= 0.9995
        if broken then
            consider({id="broken", priority=100, severity="critical",
                title=getWorkHudText("terraLogic_workHudBrokenTitle", "IMPLEMENT BROKEN"),
                detail=getWorkHudText("terraLogic_workHudBrokenDetail", "Please repair")})
        end
        self.workHudEventWarnings = self.workHudEventWarnings or {}
        for id, event in pairs(self.workHudEventWarnings) do
            if now >= (event.expiresAt or 0) then
                self.workHudEventWarnings[id] = nil
            elseif event.implement == implement then
                consider(event)
            end
        end
        local structuralRate = math.max(
            tonumber(spec.structuralDamagePercentPerMinute) or 0, 0)
        if not broken and isMechanicalActive and spec.mechanicalLoadModel ~= "none"
            and structuralRate
                >= self.WORK_HUD_SEVERE_DAMAGE_RATE_PCT_PER_MIN then
            consider({id="mechanicalLoad", priority=80, severity="critical",
                title=getWorkHudText("terraLogic_workHudOverloadTitle",
                    "SEVERE MECHANICAL LOAD"),
                detail=getWorkHudText("terraLogic_workHudOverloadDetail",
                    "Damage rate rising rapidly")})
        end
        if not broken and isMechanicalActive and spec.mechanicalLoadModel ~= "none"
            and spec.workHudMechanicalWarningActive == true then
            consider({id="mechanicalLoad", priority=70, severity="caution",
                title=getWorkHudText("terraLogic_workHudHighLoadTitle",
                    "HIGH MECHANICAL LOAD"),
                detail=getWorkHudText("terraLogic_workHudHighLoadDetail",
                    "Wear rises with load")})
        end
        if not broken and isQualityActive and qualityContext ~= nil then
            local speedDropout = math.max(tonumber(
                qualityContext.speedDropoutFraction) or 0, 0)
            local conditionDropout = math.max(tonumber(
                qualityContext.conditionDropoutFraction) or 0, 0)
            local soilDropout = math.max(tonumber(
                qualityContext.soilDropoutFraction) or 0, 0)
            local rainDropout = math.max(tonumber(
                qualityContext.rainDropoutFraction) or 0, 0)
            local speedCause = math.max(speedDropout,
                tonumber(qualityContext.speedLoss) or 0)
            local conditionCause = math.max(conditionDropout,
                tonumber(qualityContext.conditionLoss) or 0)
            local soilCause = math.max(soilDropout,
                tonumber(qualityContext.soilLoss) or 0)
            local rainCause = math.max(rainDropout,
                tonumber(qualityContext.rainLoss) or 0)
            local classGroup = getWorkHudClassGroup(spec.implementClassKey)
            local isPickup = classGroup == "pickup"
            local function addQualityCause(id, magnitude, dropoutMagnitude,
                    titleKey, titleFallback,
                    qualityDetailKey, qualityDetailFallback, dropoutDetailKey,
                    dropoutDetailFallback, classCause)
                local causeHasDropout = dropoutMagnitude
                    >= self.WORK_HUD_DROPOUT_WARNING_FRACTION
                if magnitude < self.WORK_HUD_QUALITY_WARNING_LOSS
                    and not causeHasDropout then
                    return
                end
                -- The cause id remains stable when a loss crosses from invisible
                -- quality into physical misses. Only the detail changes, so the
                -- queue never mistakes one fluctuating cause for two warnings.
                local title = getWorkHudText(titleKey, titleFallback)
                local detail = getWorkHudText(
                    causeHasDropout and dropoutDetailKey or qualityDetailKey,
                    causeHasDropout and dropoutDetailFallback
                        or qualityDetailFallback)
                if classCause ~= nil then
                    local classTitle, classDetail = getWorkHudClassWarning(
                        classGroup, classCause, causeHasDropout)
                    title = classTitle or title
                    detail = classDetail or detail
                end
                consider({id=id,
                    priority=causeHasDropout and 75 or 60, magnitude=magnitude,
                    severity="caution",
                    title=title, detail=detail})
            end

            addQualityCause("overspeed", speedCause, speedDropout,
                "terraLogic_workHudOverspeedTitle", "OVERSPEED",
                "terraLogic_workHudOverspeedQualityDetail",
                "Speed reduces work quality",
                isPickup and "terraLogic_workHudPickupDropoutDetail"
                    or "terraLogic_workHudWorkDropoutDetail",
                isPickup and "Material is being left behind"
                    or "Work gaps are being created", "overspeed")
            local conditionStart = TerraLogicQualityManager ~= nil
                and tonumber(TerraLogicQualityManager.CONDITION_QUALITY_START_DAMAGE)
                or 0.75
            if damage >= conditionStart then
                addQualityCause("condition", conditionCause, conditionDropout,
                    "terraLogic_workHudConditionCauseTitle", "IMPLEMENT WORN",
                    "terraLogic_workHudConditionQualityDetail",
                    "Wear reduces work quality",
                    "terraLogic_workHudConditionActionDetail",
                    "Slow down to reduce losses; repair to remove them",
                    "condition")
            end

            if soilCause >= self.WORK_HUD_QUALITY_WARNING_LOSS
                or soilDropout >= self.WORK_HUD_DROPOUT_WARNING_FRACTION then
                local mitigation = qualityContext.soilContext
                local rawContext = mitigation ~= nil and mitigation.context or nil
                local soilId = getWorkHudSoilWarningCause(
                    rawContext, classGroup, soilCause, soilDropout)
                local titleKey, titleFallback =
                    "terraLogic_workHudSoilCauseTitle", "UNSUITABLE SOIL"
                local detailKey, detailFallback =
                    "terraLogic_workHudSoilQualityDetail",
                    "Soil condition reduces work quality"
                if soilId == "frost" then
                    soilId, titleKey, titleFallback = "frost",
                        "terraLogic_workHudFrozenTitle", "SOIL FROZEN"
                    detailKey, detailFallback =
                        "terraLogic_workHudFrozenQualityDetail",
                        "Frozen soil reduces penetration and quality"
                elseif soilId == "wetSoil" then
                    soilId, titleKey, titleFallback = "wetSoil",
                        "terraLogic_workHudWetTitle", "WET SOIL"
                    detailKey, detailFallback =
                        "terraLogic_workHudWetQualityDetail",
                        "Wet soil reduces penetration and placement"
                elseif soilId == "drySoil" then
                    soilId, titleKey, titleFallback = "drySoil",
                        "terraLogic_workHudDryTitle", "DRY SOIL"
                    detailKey, detailFallback =
                        "terraLogic_workHudDryQualityDetail",
                        "Dry soil reduces penetration and placement"
                elseif soilId == "unevenSoil" then
                    soilId, titleKey, titleFallback = "unevenSoil",
                        "terraLogic_workHudUnevenGroundTitle", "UNEVEN GROUND"
                    detailKey, detailFallback =
                        "terraLogic_workHudUnevenQualityDetail",
                        "Ground following and placement are reduced"
                elseif soilId == "coarseSoil" then
                    soilId, titleKey, titleFallback = "coarseSoil",
                        "terraLogic_workHudCoarseTitle", "COARSE SEEDBED"
                    detailKey, detailFallback =
                        "terraLogic_workHudCoarseDetail",
                        "Large clods reduce consistent placement"
                elseif soilId == "fineSoil" then
                    soilId, titleKey, titleFallback = "fineSoil",
                        "terraLogic_workHudFineTitle", "OVER-FINE SEEDBED"
                    detailKey, detailFallback =
                        "terraLogic_workHudFineDetail",
                        "Overworked soil reduces placement stability"
                end
                local classCause = soilId == "unevenSoil" and "uneven"
                    or soilId == "wetSoil" and "wet"
                    or soilId == "drySoil" and "dry"
                    or soilId == "frost" and "frost" or "soil"
                if soilId ~= nil then
                    addQualityCause(soilId, soilCause, soilDropout,
                        titleKey, titleFallback,
                        detailKey, detailFallback,
                        "terraLogic_workHudSoilActionDetail",
                        "Soil conditions cause missed areas; check the Planner",
                        classCause)
                end
            end

            addQualityCause("herbicideRain", rainCause, rainDropout,
                "terraLogic_workHudRainTitle", "RAIN DURING SPRAYING",
                "terraLogic_workHudRainQualityDetail",
                "Herbicide is washed off before absorption",
                "terraLogic_workHudRainDropoutDetail",
                "Weed control is leaving untreated patches")
        end
        if not broken and isQualityActive
            and (tonumber(spec.frostSeverity) or 0) >= 0.35
            and spec.additionalDraftEnabled == true then
            consider({id="frost", priority=73, severity="caution",
                title=getWorkHudText("terraLogic_workHudFrozenTitle", "SOIL FROZEN"),
                detail=getWorkHudText("terraLogic_workHudFrozenDetail",
                    "Draft demand increased")})
        end
    end -- implement-specific mechanical/work-quality warnings

    local trafficLevel, trafficKnown = TerraLogicTrafficWarnings:getLevel(
        g_localPlayer ~= nil and g_localPlayer:getCurrentVehicle() or nil, now)
    if trafficLevel >= 2 then
        consider({id="trafficCompaction", priority=74, severity="caution", repeatRank=trafficLevel,
            title=getWorkHudText("terraLogic_workHudCompactionTitle",
                "HIGH COMPACTION RISK"),
            detail=getWorkHudText(trafficLevel == 3
                and "terraLogic_workHudWetCompactionDetail"
                or "terraLogic_workHudCompactionDetail", trafficLevel == 3
                    and "Wet soil: reduce load or use wider tires"
                    or "Reduce axle load or ground contact pressure")})
    elseif trafficLevel == 1 then
        consider({id="trafficCompaction", priority=72, severity="caution", repeatRank=trafficLevel,
            title=getWorkHudText("terraLogic_workHudWetTitle", "WET SOIL"),
            detail=getWorkHudText("terraLogic_workHudWetDetail",
                "Compaction risk increased")})
    end

    TerraLogicWarningEpisodes:update(warningVehicle, candidatesById, now, trafficKnown)
    -- Stable source states debounce transient WorkArea samples before they can
    -- enter the queue. A disappearing source receives only a short clear grace;
    -- if it is already visible, its configured reading slot still finishes.
    self.workHudWarningSources = self.workHudWarningSources or {}
    for _, state in pairs(self.workHudWarningSources) do
        state.seen = false
    end
    for id, candidate in pairs(candidatesById) do
        local state = self.workHudWarningSources[id]
        if state == nil then
            state = {firstSeen=now}
            self.workHudWarningSources[id] = state
        end
        state.warning = candidate
        state.lastSeen = now
        state.seen = true
    end

    local currentId = self.workHudWarningCurrentId
    for id, state in pairs(self.workHudWarningSources) do
        local warning = state.warning or {}
        local expiredEvent = warning.oneShot == true
            and now >= (warning.expiresAt or 0)
        local cleared = warning.oneShot ~= true and state.seen ~= true
            and now-(tonumber(state.lastSeen) or 0)
                > self.WORK_HUD_WARNING_CLEAR_GRACE_MS
        if (expiredEvent or cleared) and id ~= currentId then
            self.workHudWarningSources[id] = nil
        end
    end

    self.workHudWarningQueue = self.workHudWarningQueue or {}
    local queue = self.workHudWarningQueue
    local function isEligible(id)
        local state = self.workHudWarningSources[id]
        if state == nil or state.warning == nil then return false end
        if standalone and not TerraLogicWarningEpisodes:eligible(warningVehicle, state.warning) then return false end
        return state.warning.oneShot == true
            or now-(tonumber(state.firstSeen) or now)
                >= self.WORK_HUD_WARNING_CONFIRM_MS
    end
    local cleaned, queued = {}, {}
    for _, id in ipairs(queue) do
        if id ~= currentId and isEligible(id) and queued[id] ~= true then
            cleaned[#cleaned+1] = id
            queued[id] = true
        end
    end
    self.workHudWarningQueue = cleaned
    queue = cleaned

    local newcomers = {}
    for id, _ in pairs(self.workHudWarningSources) do
        if id ~= currentId and queued[id] ~= true and isEligible(id) then
            newcomers[#newcomers+1] = id
        end
    end
    table.sort(newcomers, function(a, b)
        local aw = self.workHudWarningSources[a].warning
        local bw = self.workHudWarningSources[b].warning
        local ap, bp = tonumber(aw.priority) or 0, tonumber(bw.priority) or 0
        if ap ~= bp then return ap > bp end
        return tostring(a) < tostring(b)
    end)
    local function insertByPriority(id)
        local warning = self.workHudWarningSources[id].warning
        local priority = tonumber(warning.priority) or 0
        local position = #queue+1
        for index, queuedId in ipairs(queue) do
            local queuedState = self.workHudWarningSources[queuedId]
            local queuedPriority = queuedState ~= nil
                and tonumber(queuedState.warning.priority) or 0
            if priority > queuedPriority then
                position = index
                break
            end
        end
        table.insert(queue, position, id)
        queued[id] = true
    end
    for _, id in ipairs(newcomers) do insertByPriority(id) end

    local maximum = math.max(
        tonumber(self.WORK_HUD_WARNING_MAX_QUEUE) or 5, 1)
    while #queue+(currentId ~= nil and 1 or 0) > maximum do
        queued[table.remove(queue)] = nil
    end

    local slotMs = math.max(
        TerraLogicSettings ~= nil
            and TerraLogicSettings.getWarningDisplayDurationMs ~= nil
            and TerraLogicSettings:getWarningDisplayDurationMs()
            or tonumber(self.WORK_HUD_WARNING_SLOT_MS) or 5000,
        1000)
    if currentId ~= nil
        and now-(tonumber(self.workHudWarningSlotStartedAt) or now) >= slotMs then
        local finishedState = self.workHudWarningSources[currentId]
        local finishedWarning = finishedState ~= nil
            and finishedState.warning or self.workHudWarningCurrent
        if finishedWarning ~= nil and finishedWarning.oneShot == true then
            self.workHudWarningSources[currentId] = nil
            if self.workHudEventWarnings ~= nil then
                self.workHudEventWarnings[currentId] = nil
            end
        elseif not standalone and finishedState ~= nil
            and (finishedState.seen == true
                or now-(tonumber(finishedState.lastSeen) or 0)
                    <= self.WORK_HUD_WARNING_CLEAR_GRACE_MS) then
            -- A continuously valid cause returns at the end of the waiting
            -- line. This round-robin tail prevents one permanent high-priority
            -- warning from starving every other useful explanation.
            if queued[currentId] ~= true then
                queue[#queue+1] = currentId
                queued[currentId] = true
            end
        end
        self.workHudWarningCurrentId = nil
        self.workHudWarningCurrent = nil
        currentId = nil
    end

    while currentId == nil and #queue > 0 do
        local nextId = table.remove(queue, 1)
        queued[nextId] = nil
        local state = self.workHudWarningSources[nextId]
        if state ~= nil and state.warning ~= nil then
            currentId = nextId
            self.workHudWarningCurrentId = nextId
            TerraLogicWarningEpisodes:shown(warningVehicle, state.warning, now)
            -- Copy the displayed values so title/detail cannot flicker during
            -- the slot even if a live threshold changes behind the scenes.
            self.workHudWarningCurrent = {
                id=state.warning.id,
                priority=state.warning.priority,
                severity=state.warning.severity,
                title=state.warning.title,
                detail=state.warning.detail,
                oneShot=state.warning.oneShot
            }
            self.workHudWarningSlotStartedAt = now
            self.workHudWarningDisplaySequence =
                (tonumber(self.workHudWarningDisplaySequence) or 0)+1
            self.workHudWarningSlotCount = math.min(1+#queue, maximum)
            self.workHudWarningSlotIndex =
                (self.workHudWarningDisplaySequence-1)
                    % math.max(self.workHudWarningSlotCount, 1)+1
        end
    end

    local current = self.workHudWarningCurrent
    if current == nil then return nil, 0, 0 end
    return current,
        math.max(tonumber(self.workHudWarningSlotCount) or 1, 1),
        math.max(tonumber(self.workHudWarningSlotIndex) or 1, 1)
end

local function getWorkHudWearRank(self, implement, isMechanicalActive)
    local spec = implement ~= nil and implement.spec_terraLogic or nil
    if spec == nil or not isMechanicalActive then return 0, 1 end
    local wearFactor = math.max(
        (tonumber(spec.loadWearMultiplier) or 1)
            * (tonumber(spec.baselineAbrasionMultiplier) or 1), 0)
    local rank = wearFactor >= 4 and 3
        or (wearFactor >= 2 and 2 or (wearFactor >= 1.25 and 1 or 0))
    if spec.mechanicalLoadModel ~= "none" then
        local structuralRate = math.max(
            tonumber(spec.structuralDamagePercentPerMinute) or 0, 0)
        if spec.workHudMechanicalWarningActive == true then
            rank = math.max(rank, 1)
        end
        if structuralRate > 0 then rank = math.max(rank, 2) end
        if structuralRate >= self.WORK_HUD_SEVERE_DAMAGE_RATE_PCT_PER_MIN then
            rank = 3
        end
    end
    return rank, wearFactor
end

-- Stable work HUD. It reuses Vanilla HUD slices, follows UI scale and reserves
-- a separate fading warning card above without moving the main card. The
-- coloured bar retains the familiar slow/recommended/overspeed comparison,
-- while the redundant numeric speed is left to Vanilla's tachometer.
-- Keep complete translations at a readable size, including long UTF-8 words.
-- Measurement is injectable for regression tests; the game supplies getTextWidth.
function TerraLogicMain.wrapWarningText(text, width, measure)
    local lines, line = {}, ""
    local function addWord(word)
        local candidate = line == "" and word or line .. " " .. word
        if measure(candidate) <= width then line = candidate; return end
        if line ~= "" then lines[#lines+1], line = line, "" end
        if measure(word) <= width then line = word; return end
        for character in word:gmatch("[%z\1-\127\194-\244][\128-\191]*") do
            if line ~= "" and measure(line .. character) > width then
                lines[#lines+1], line = line, ""
            end
            line = line .. character
        end
    end
    text = tostring(text or ""):gsub("\r\n", "\n"):gsub("\r", "\n")
    for paragraph in (text .. "\n"):gmatch("(.-)\n") do
        for word in paragraph:gmatch("%S+") do addWord(word) end
        lines[#lines+1], line = line, ""
    end
    return lines
end

-- Inline title/detail, measured in their actual fonts. Cache bounded by
-- language, width and font size; no queue-dependent geometry.
function TerraLogicMain:getWarningTextLayout(warning, width, size)
    local key=tostring(g_languageShort)..":"..tostring(width)..":"..tostring(size)
        ..":"..tostring(warning.title)..":"..tostring(warning.detail)
    self.warningTextCache=self.warningTextCache or {}
    local cached=self.warningTextCache[key]
    if cached~=nil then return cached end
    local lines, lineWidth = {{}}, 0
    local function append(text,bold)
        setTextBold(bold)
        for word in tostring(text or ""):gmatch("%S+") do
            local line=lines[#lines]
            local token=(#line>0 and " " or "")..word
            local w=getTextWidth(size,token)
            if lineWidth+w>width and #line>0 then
                lines[#lines+1]={};line=lines[#lines];lineWidth=0
                token=word;w=getTextWidth(size,token)
            end
            line[#line+1]={text=token,bold=bold,x=lineWidth}
            lineWidth=lineWidth+w
        end
    end
    local title=tostring(warning.title or "")
    append(title~="" and title..":" or "",true)
    append(warning.detail,false)
    setTextBold(false)
    local result={lines=lines}
    if (self.warningTextCacheCount or 0)>=64 then
        self.warningTextCache={};self.warningTextCacheCount=0
    end
    self.warningTextCache[key]=result
    self.warningTextCacheCount=(self.warningTextCacheCount or 0)+1
    return result
end

function TerraLogicMain:prepareWarningCard(warning,width,size,now)
    local shown=warning or self.workHudLastWarning
    if shown==nil then return nil end
    if warning~=nil then self.workHudLastWarning=warning end
    local alpha=updateWorkHudWarningFade(self,now,warning~=nil)
    return shown,self:getWarningTextLayout(shown,width,size),2,alpha
end

function TerraLogicMain:drawSpeedHud()
    if self.enabled == false or g_localPlayer == nil or g_currentMission == nil then
        return
    end
    local hudMode = TerraLogicSettings ~= nil
        and TerraLogicSettings.speedHudMode or "dynamic"
    local now = g_currentMission.time or 0
    if hudMode == "off" then
        self.workHudWarningLayoutState = nil
        self.speedHudFadeAlpha = 0
        self.workHudWarningFadeAlpha = 0
        self.workHudWarningSources = {}
        self.workHudWarningQueue = {}
        self.workHudWarningCurrentId = nil
        self.workHudWarningCurrent = nil
        self.workHudEventWarnings = {}
        return
    end
    local vehicle = g_localPlayer:getCurrentVehicle()
    if vehicle == nil or drawFilledRect == nil or renderText == nil
        or not getIsGameHudVisible() then
        self.workHudWarningLayoutState = nil
        self.speedHudFadeAlpha = 0
        self.workHudWarningFadeAlpha = 0
        if vehicle == nil then self.speedHudVehicle = nil end
        return
    end
    if self.speedHudVehicle ~= vehicle then
        self.workHudWarningLayoutState = nil
        self.speedHudVehicle = vehicle
        self.speedHudVehicleNameHiddenUntil = now
            + TerraLogicMain.SPEED_HUD_VEHICLE_NAME_DELAY_MS
        self.speedHudImplement = nil
        self.speedHudOptimalSince = nil
        self.speedHudForcedUntil = nil
        self.speedHudCruiseVehicle = nil
        self.speedHudCruiseSpeed = nil
        self.speedHudFadeAlpha = 0
        self.workHudWarningFadeAlpha = 0
        self.workHudWarningSources = {}
        self.workHudWarningQueue = {}
        self.workHudWarningCurrentId = nil
        self.workHudWarningCurrent = nil
        self.workHudLastWarning = nil
        self.workHudWarningImplement = nil
        self.workHudWarningDisplaySequence = 0
        self.workHudEventWarnings = {}
    end

    -- Do not consume a one-time warning while the vehicle-name banner hides it.
    if now < (self.speedHudVehicleNameHiddenUntil or 0) then return end
    local currentSpeed = math.abs(vehicle:getLastSpeed(true) or 0)
    local requestedImplement, activeImplementCount, activeImplements =
        self:getSpeedHudImplement(
        hudMode == "dynamic", currentSpeed)
    local implement = requestedImplement
    if implement == nil then
        implement, activeImplementCount, activeImplements =
            self:getSpeedHudImplement(false, currentSpeed)
    end
    if implement == nil or implement.spec_terraLogic == nil
        or (tonumber(implement.spec_terraLogic.ratedSpeed) or 0) <= 0 then
        self.speedHudFadeAlpha = 0
        local warning, count, index = getWorkHudWarning(
            self, nil, nil, nil, false, false, now, true)
        if now < (self.speedHudVehicleNameHiddenUntil or 0) then
            self.workHudWarningFadeAlpha = 0
            return
        end
        local _, warningY = getSpeedHudScaledPixels(0, 42)
        self:drawWorkHudWarning(warning, count, index, now, warningY)
        return
    end
    local spec = implement.spec_terraLogic
    local shopSpeed = math.max(tonumber(spec.ratedSpeed) or 0, 0)
    local recommendedSpeed = math.max(
        tonumber(spec.safeSpeed) or tonumber(spec.optimalSpeed) or shopSpeed, 0)
    if shopSpeed <= 0 then return end
    if self.speedHudImplement ~= implement then
        self.speedHudImplement = implement
        self.speedHudOptimalSince = nil
    end

    local qualityComponent = getSpeedHudWorkQualityComponent(implement)
    local physicalProfile = getSpeedHudPhysicalQualityProfile(implement)
    local isWorkActive = getIsSpeedHudQualityActive(
        implement, currentSpeed, qualityComponent, physicalProfile)
    local isMechanicalActive = getIsSpeedHudMechanicalActive(
        implement, currentSpeed)
    updateWorkHudMechanicalWarningState(spec, isMechanicalActive)
    if isWorkActive then
        self.speedHudQualityGraceImplement = implement
        self.speedHudQualityActiveUntil = now + 1200
    elseif currentSpeed >= 0.5
        and self.speedHudQualityGraceImplement == implement
        and now <= (self.speedHudQualityActiveUntil or 0)
        and getIsSpeedHudImplementReady(implement, true) then
        isWorkActive = true
    end
    local quality, qualityContext = nil, nil
    if isWorkActive then
        if qualityComponent ~= nil then
            quality, qualityContext = self:getSpeedHudWorkQuality(
                implement, currentSpeed)
        elseif physicalProfile ~= nil then
            quality, qualityContext = self:getSpeedHudPhysicalWorkQuality(
                implement, currentSpeed, physicalProfile)
        end
    end
    local qualityImplement = implement
    local loadImplement = implement
    local warningImplement = implement
    local warningQuality, warningContext, warningActive =
        quality, qualityContext, isWorkActive
    local warningMechanicalActive = isMechanicalActive
    local maximumWarningPriority = 0
    local maximumLoadRatio = math.max(
        tonumber(spec.mechanicalLoadRatio) or 0, 0)
    local maximumWearRank = getWorkHudWearRank(
        self, implement, isMechanicalActive)
    local maximumDamage = implement.getDamageAmount ~= nil
        and math.clamp(tonumber(implement:getDamageAmount()) or 0, 0, 1) or 0
    if maximumDamage >= 0.9995 then quality = 0 end
    local function estimateWarningPriority(
            candidate, candidateQualityActive, candidateMechanicalActive,
            context, candidateDamage, candidateLoad)
        local candidateSpec = candidate.spec_terraLogic
        local priority = candidateDamage >= 0.9995 and 100 or 0
        if candidateMechanicalActive then
            if (tonumber(candidateSpec.structuralDamagePercentPerMinute) or 0)
                >= self.WORK_HUD_SEVERE_DAMAGE_RATE_PCT_PER_MIN then
                priority = math.max(priority, 80)
            end
            if candidateSpec.workHudMechanicalWarningActive == true then
                priority = math.max(priority, 70)
            end
        end
        if candidateQualityActive then
            if context ~= nil then
                local dropout = tonumber(context.dropoutFraction) or 0
                local loss = math.max(tonumber(context.speedLoss) or 0,
                    tonumber(context.conditionLoss) or 0,
                    tonumber(context.soilLoss) or 0)
                priority = math.max(priority,
                    dropout >= self.WORK_HUD_DROPOUT_WARNING_FRACTION
                        and 75
                        or (loss >= self.WORK_HUD_QUALITY_WARNING_LOSS
                            and 60 or 0))
            end
            if (tonumber(candidateSpec.frostSeverity) or 0) >= 0.35
                and candidateSpec.additionalDraftEnabled == true then
                priority = math.max(priority, 73)
            end
        end
        for _, event in pairs(self.workHudEventWarnings or {}) do
            if event.implement == candidate
                and now < (event.expiresAt or 0) then
                priority = math.max(priority,
                    tonumber(event.priority) or 0)
            end
        end
        return priority
    end
    maximumWarningPriority = estimateWarningPriority(
        implement, isWorkActive, isMechanicalActive, qualityContext,
        maximumDamage, maximumLoadRatio)
    local loadIsMechanicalActive = isMechanicalActive
    for _, candidate in ipairs(activeImplements or {}) do
        if candidate ~= implement and candidate.spec_terraLogic ~= nil then
            local candidateSpec = candidate.spec_terraLogic
            local candidateComponent = getSpeedHudWorkQualityComponent(candidate)
            local candidateProfile = getSpeedHudPhysicalQualityProfile(candidate)
            local candidateActive = getIsSpeedHudQualityActive(
                candidate, currentSpeed, candidateComponent, candidateProfile)
            local candidateMechanicalActive =
                getIsSpeedHudMechanicalActive(candidate, currentSpeed)
            updateWorkHudMechanicalWarningState(
                candidateSpec, candidateMechanicalActive)
            local candidateQuality, candidateContext = nil, nil
            if candidateActive then
                if candidateComponent ~= nil then
                    candidateQuality, candidateContext =
                        self:getSpeedHudWorkQuality(candidate, currentSpeed)
                elseif candidateProfile ~= nil then
                    candidateQuality, candidateContext =
                        self:getSpeedHudPhysicalWorkQuality(
                            candidate, currentSpeed, candidateProfile)
                end
            end
            local candidateDamage = candidate.getDamageAmount ~= nil
                and math.clamp(tonumber(candidate:getDamageAmount()) or 0, 0, 1)
                or 0
            if candidateDamage >= 0.9995 then candidateQuality = 0 end
            maximumDamage = math.max(maximumDamage, candidateDamage)
            if candidateQuality ~= nil
                and (quality == nil or candidateQuality < quality) then
                quality = candidateQuality
                qualityContext = candidateContext
                qualityImplement = candidate
            end
            local candidateLoad = math.max(
                tonumber(candidateSpec.mechanicalLoadRatio) or 0, 0)
            if candidateMechanicalActive
                and (not loadIsMechanicalActive
                    or candidateLoad > maximumLoadRatio) then
                maximumLoadRatio = candidateLoad
                loadImplement = candidate
                loadIsMechanicalActive = true
            end
            -- getWorkHudWearRank also returns the numeric wear factor for
            -- diagnostics.  Explicitly select the rank here: when several
            -- NEXAT modules were active Lua forwarded both return values into
            -- math.max(), so the normal factor 1.0 became warning rank 1 and
            -- produced "WEAR RATE INCREASED" even at a standstill.
            local candidateWearRank = select(1, getWorkHudWearRank(
                self, candidate, candidateMechanicalActive))
            maximumWearRank = math.max(maximumWearRank, candidateWearRank)
            local candidateWarningPriority = estimateWarningPriority(
                candidate, candidateActive, candidateMechanicalActive,
                candidateContext,
                candidateDamage, candidateLoad)
            if candidateWarningPriority > maximumWarningPriority then
                maximumWarningPriority = candidateWarningPriority
                warningImplement, warningQuality, warningContext, warningActive =
                    candidate, candidateQuality, candidateContext, candidateActive
                warningMechanicalActive = candidateMechanicalActive
            end
        end
    end
    local damage = maximumDamage

    local cruiseSpeed = nil
    if vehicle.getCruiseControlSpeed ~= nil then
        cruiseSpeed = tonumber(vehicle:getCruiseControlSpeed())
    elseif vehicle.spec_drivable ~= nil
        and vehicle.spec_drivable.cruiseControl ~= nil then
        cruiseSpeed = tonumber(vehicle.spec_drivable.cruiseControl.speed)
    end
    if cruiseSpeed ~= nil then
        if self.speedHudCruiseVehicle == vehicle
            and self.speedHudCruiseSpeed ~= nil
            and math.abs(cruiseSpeed - self.speedHudCruiseSpeed) >= 0.1 then
            self.speedHudForcedUntil = now + 3000
        end
        self.speedHudCruiseVehicle = vehicle
        self.speedHudCruiseSpeed = cruiseSpeed
    end

    -- Dynamic mode follows readiness: outside the recommended speed range it
    -- remains visible; within that range it fades after three stable seconds
    -- and returns after a cruise-speed
    -- change. Context warnings always keep the card visible.
    local displayRecommendedSpeed = getWorkHudDisplayRecommendedSpeed(
        recommendedSpeed, shopSpeed)
    local inNominalRange = currentSpeed >= displayRecommendedSpeed - 0.25
        and currentSpeed <= shopSpeed + 0.25
    local hideForNominalRange = false
    if hudMode == "dynamic" and requestedImplement ~= nil
        and inNominalRange then
        self.speedHudOptimalSince = self.speedHudOptimalSince or now
        hideForNominalRange = now - self.speedHudOptimalSince >= 3000
            and now >= (self.speedHudForcedUntil or 0)
    else
        self.speedHudOptimalSince = nil
    end
    local warning, warningCount, warningIndex = getWorkHudWarning(
        self, warningImplement, warningQuality, warningContext,
        warningActive, warningMechanicalActive, now)
    local wearRank = maximumWearRank
    if hudMode == "warnings" then
        self.speedHudFadeAlpha = 0
        TerraLogicTutorialManager:observeHud(qualityImplement or implement,
            qualityContext, quality ~= nil, warning ~= nil, currentSpeed)
        local _, warningY = getSpeedHudScaledPixels(0, 42)
        self:drawWorkHudWarning(warning, warningCount, warningIndex, now, warningY)
        return
    end
    local hasContextWarning = warning ~= nil
    local shouldShow = implement ~= nil
        and now >= (self.speedHudVehicleNameHiddenUntil or 0)
        and (hudMode ~= "dynamic"
            or (requestedImplement ~= nil and not hideForNominalRange)
            or damage >= 0.9995 or hasContextWarning or wearRank >= 1)
    local alpha = updateSpeedHudFade(self, now, shouldShow)
    TerraLogicTutorialManager:observeHud(qualityImplement or implement,
        qualityContext, quality ~= nil, alpha > 0, currentSpeed)
    if alpha <= 0 then self.workHudWarningLayoutState = nil; return end

    -- Two distinct columns: speed guidance on the left, work result on the
    -- right. Keep the game's default font and a shared heading size.
    local boxWidth, boxHeight = getSpeedHudScaledPixels(380, 54)
    local _, boxY = getSpeedHudScaledPixels(0, 42)
    local boxX = 0.5 - boxWidth * 0.5
    if not self:renderSpeedHudBackground(
        boxX, boxY, boxWidth, boxHeight, alpha) then
        drawFilledRect(boxX, boxY, boxWidth, boxHeight,
            0.01, 0.01, 0.01, 0.58 * alpha)
    end
    local padX = getSpeedHudScaledPixels(15, 0)
    local speedWidth = getSpeedHudScaledPixels(210, 0)
    local dividerX = boxX + getSpeedHudScaledPixels(235, 0)
    local qualityX = boxX + getSpeedHudScaledPixels(245, 0)
    local rightX = boxX + boxWidth - padX
    local qualityCenterX = (qualityX + rightX) * 0.5
    local _, topY = getSpeedHudScaledPixels(0, 33)
    local _, bottomY = getSpeedHudScaledPixels(0, 11)
    local _, barY = getSpeedHudScaledPixels(0, 15)
    local _, barHeight = getSpeedHudScaledPixels(0, 7)
    local _, smallSize = getSpeedHudScaledPixels(0,
        math.max(getSpeedHudDefaultTextPixels() - 3, 10))
    local _, valueSize = getSpeedHudScaledPixels(0,
        getSpeedHudDefaultTextPixels() + 3)
    local lineWidth, lineHeight = getSpeedHudScaledPixels(1, 32)
    local _, lineY = getSpeedHudScaledPixels(0, 11)
    drawFilledRect(dividerX, boxY + lineY, lineWidth, lineHeight,
        1, 1, 1, 0.14 * alpha)
    local white = {1, 1, 1, alpha}
    local muted = {0.78, 0.82, 0.84, alpha}
    local orange = {SPEED_HUD_CAUTION_COLOR[1],
        SPEED_HUD_CAUTION_COLOR[2], SPEED_HUD_CAUTION_COLOR[3], alpha}
    local qualitySpec = qualityImplement ~= nil
        and qualityImplement.spec_terraLogic or spec
    local pickup = qualitySpec.implementClassKey == "baler"
        or qualitySpec.implementClassKey == "loaderWagon"
    local qualityLabel = pickup
        and getWorkHudText("terraLogic_workHudPickupCompact", "Material pickup")
        or getWorkHudText("terraLogic_workHudQualityCompact", "Work quality")
    local showQualityValue = qualitySpec.implementClassKey ~= "defoliator"
    if not showQualityValue then
        qualityLabel = getWorkHudText(
            "terraLogic_fa_planner_ui_class_defoliator", "Defoliator")
    end
    local speedLabel = getWorkHudText("terraLogic_workHudSpeedCompact", "Recommended speed")
    local speedValue = TerraLogicI18n.formatSpeedRange(
        displayRecommendedSpeed, shopSpeed)
    setTextBold(false)
    -- Fit all headings together, never shrink only one column independently.
    if getTextWidth ~= nil then
        local gap = getSpeedHudScaledPixels(8, 0)
        local speedTextWidth = getTextWidth(smallSize, speedLabel)
            + getTextWidth(smallSize, speedValue)
        local qualityTextWidth = getTextWidth(smallSize, qualityLabel)
        local fit = math.min(1, (speedWidth - gap) / math.max(speedTextWidth, 0.0001),
            (rightX - qualityX) / math.max(qualityTextWidth, 0.0001))
        smallSize = smallSize * fit
    end
    setTextAlignment(RenderText.ALIGN_LEFT)
    setTextColor(unpack(muted))
    renderText(boxX + padX, boxY + topY, smallSize, speedLabel)
    setTextAlignment(RenderText.ALIGN_CENTER)
    renderText(qualityCenterX, boxY + topY, smallSize, qualityLabel)
    setTextAlignment(RenderText.ALIGN_RIGHT)
    setTextColor(unpack(white))
    renderText(boxX + padX + speedWidth, boxY + topY, smallSize, speedValue)
    local qualityText = quality ~= nil
        and TerraLogicI18n.format("%d %%", math.floor(quality * 100 + 0.5))
        or "-"
    local countText = (activeImplementCount or 0) > 1
        and TerraLogicI18n.format(
            getWorkHudText("terraLogic_speedHudActiveImplements", "%d tools"),
            activeImplementCount) or nil
    local valueX = qualityCenterX
    local countX = qualityCenterX
    -- With several tools, center the complete count/value group rather than
    -- placing the count underneath the centered percentage.
    if countText ~= nil and showQualityValue and getTextWidth ~= nil then
        local countWidth = getTextWidth(smallSize, countText)
        local valueWidth = getTextWidth(valueSize, qualityText)
        local gap = getSpeedHudScaledPixels(8, 0)
        countX = qualityCenterX - (countWidth + gap + valueWidth) * 0.5
            + countWidth * 0.5
        valueX = qualityCenterX + (countWidth + gap) * 0.5
    end
    setTextAlignment(RenderText.ALIGN_CENTER)
    if showQualityValue then
        if quality == nil then setTextColor(unpack(muted))
        elseif quality < 0.75 then setTextColor(unpack(orange))
        else setTextColor(unpack(white)) end
        renderText(valueX, boxY + bottomY, valueSize, qualityText)
    end
    if countText ~= nil then
        setTextColor(unpack(muted))
        renderText(countX, boxY + bottomY, smallSize, countText)
    end
    setTextBold(false)

    -- Zoom the speed scale around the useful range. The central 60 percent is
    -- the recommended-to-shop interval, with equally sized slow and overspeed
    -- areas. The tachometer supplies the number; this bar supplies context.
    local barX = boxX + padX
    local barWidth = speedWidth
    local safetyShare, recommendedShare = 0.20, 0.60
    local realSpeed = displayRecommendedSpeed
    local usefulRange = math.max(shopSpeed-realSpeed, 0.1)
    local safetyRange = usefulRange * safetyShare / recommendedShare
    local visibleMinimum = realSpeed-safetyRange
    local visibleMaximum = shopSpeed+safetyRange
    local visibleRange = math.max(visibleMaximum-visibleMinimum, 0.1)
    local realX = barX+barWidth*safetyShare
    local shopX = barX+barWidth*(safetyShare+recommendedShare)
    local markerRatio = (currentSpeed-visibleMinimum)/visibleRange
    local markerX = barX+barWidth*math.clamp(markerRatio, 0, 1)
    -- The physics controller can settle a few hundredths above the displayed
    -- electronic limit.  Keep the marker visibly inside the nominal segment
    -- while it is still within the same 0.25 km/h tolerance used by the HUD's
    -- state logic.  This is especially visible on speed-limited NEXAT modules,
    -- where the driver cannot intentionally enter the overspeed segment.
    if currentSpeed <= shopSpeed + 0.25 then
        markerX = math.min(markerX, shopX - barWidth * 0.004)
    end
    local blue = {0.0097, 0.4287, 0.6445, 1}
    local green = HUD ~= nil and HUD.COLOR ~= nil and HUD.COLOR.ACTIVE
        or {0.22, 0.68, 0.30, 1}
    local barOrange = SPEED_HUD_CAUTION_COLOR
    -- Plain filled rectangles are intentionally used for the live work bar.
    -- They share Vanilla's colours but cannot fail because a HUD replacement
    -- changes ThreePartOverlay internals or one segment lacks an overlay part.
    local frameX, frameY = getSpeedHudScaledPixels(1, 1)
    drawFilledRect(barX-frameX, boxY+barY-frameY,
        barWidth+frameX*2, barHeight+frameY*2,
        0.015, 0.015, 0.015, 0.90*alpha)
    drawFilledRect(barX, boxY+barY, math.max(realX-barX, 0), barHeight,
        blue[1], blue[2], blue[3], alpha)
    drawFilledRect(realX, boxY+barY, math.max(shopX-realX, 0), barHeight,
        green[1], green[2], green[3], alpha)
    drawFilledRect(shopX, boxY+barY,
        math.max(barX+barWidth-shopX, 0), barHeight,
        barOrange[1], barOrange[2], barOrange[3], alpha)
    local markerWidth, markerExtra = getSpeedHudScaledPixels(2, 2)
    local markerShadow = markerWidth*2
    drawFilledRect(markerX-markerShadow*0.5,
        boxY+barY-markerExtra*1.5, markerShadow,
        barHeight+markerExtra*3, 0, 0, 0, 0.85*alpha)
    drawFilledRect(markerX-markerWidth*0.5,
        boxY+barY-markerExtra, markerWidth,
        barHeight+markerExtra*2, 1, 1, 1, alpha)

    local _, warningGap = getSpeedHudScaledPixels(0, 7)
    self:drawWorkHudWarning(warning, warningCount, warningIndex, now,
        boxY + boxHeight + warningGap)
end

-- The same card and stable multiline queue layout serves both HUD modes.
-- The caller supplies its bottom anchor; no invisible work-card spacer.
function TerraLogicMain:drawWorkHudWarning(warning, warningCount, warningIndex, now, warningY)
    local boxWidth = getSpeedHudScaledPixels(380, 0)
    local boxX = 0.5 - boxWidth * 0.5
    local padX = getSpeedHudScaledPixels(15, 0)
    local _, smallSize = getSpeedHudScaledPixels(0,
        math.max(getSpeedHudDefaultTextPixels() - 3, 10))
    local shown,layout,rows,warningAlpha = self:prepareWarningCard(
        warning,boxWidth-padX*2,smallSize,now)
    if (warningAlpha or 0) > 0 then
        if shown ~= nil then
            local isCritical = shown.severity == "critical"
            local accent = isCritical and SPEED_HUD_CRITICAL_COLOR or SPEED_HUD_CAUTION_COLOR
            local _, lineGap = getSpeedHudScaledPixels(0, 4)
            local lineHeight = smallSize + lineGap
            local _, inset = getSpeedHudScaledPixels(0, 7)
            local _, dotReserve = getSpeedHudScaledPixels(0, 7)
            local warningHeight = inset*2 + 2*smallSize + lineGap + dotReserve
            if not self:renderSpeedHudBackground(boxX,warningY,boxWidth,warningHeight,warningAlpha) then
                drawFilledRect(boxX,warningY,boxWidth,warningHeight,0.01,0.01,0.01,0.72*warningAlpha)
            end
            drawFilledRect(boxX,warningY,select(1,getSpeedHudScaledPixels(4,0)),warningHeight,
                accent[1],accent[2],accent[3],warningAlpha)
            -- All shipped messages fit two lines. For unexpectedly long text
            -- from future translations, page rather than clip or resize.
            local pages=math.max(1,math.ceil(#layout.lines/2))
            local page=math.floor(math.max(0,now-(self.workHudWarningSlotStartedAt or now))/2200)%pages
            local first=page*2+1
            local count=math.min(2,#layout.lines-first+1)
            -- Center the reserved two-line area, not the current message.
            -- Keep the first baseline fixed when the queue changes line count.
            local textHeight=smallSize+lineHeight
            local top=(warningHeight+dotReserve+textHeight)*0.5-smallSize
            setTextAlignment(RenderText.ALIGN_LEFT)
            for i=0,count-1 do
                for _,run in ipairs(layout.lines[first+i]) do
                    setTextBold(run.bold)
                    if run.bold then setTextColor(accent[1],accent[2],accent[3],warningAlpha)
                    else setTextColor(1,1,1,warningAlpha) end
                    renderText(boxX+padX+run.x,warningY+top-i*lineHeight,smallSize,run.text)
                end
            end
            if (warningCount or 0) > 1 then
                local dotSize = select(1, getSpeedHudScaledPixels(4, 0))
                local dotGap = select(1, getSpeedHudScaledPixels(4, 0))
                local totalDotWidth = warningCount*dotSize
                    +(warningCount-1)*dotGap
                local dotX = boxX+boxWidth-padX-totalDotWidth
                local dotY = warningY+select(2, getSpeedHudScaledPixels(0, 5))
                for dotIndex=1, warningCount do
                    local active = dotIndex == warningIndex
                    drawFilledRect(dotX+(dotIndex-1)*(dotSize+dotGap), dotY,
                        dotSize, dotSize,
                        active and accent[1] or 0.58,
                        active and accent[2] or 0.62,
                        active and accent[3] or 0.64,
                        (active and 1 or 0.70)*warningAlpha)
                end
            end
        end
    end
    setTextAlignment(RenderText.ALIGN_LEFT)
    setTextBold(false)
    setTextColor(1, 1, 1, 1)
end

-- Creates a Vanilla-style field-info box for the stored quality components.
function TerraLogicMain:getOrCreateQualityInfoBox()
    if self.qualityInfoBox ~= nil then return self.qualityInfoBox end
    local infoDisplay = g_currentMission ~= nil and g_currentMission.hud ~= nil
        and g_currentMission.hud.infoDisplay or nil
    if infoDisplay == nil or infoDisplay.createBox == nil
        or InfoDisplayKeyValueBox == nil then
        if self.qualityInfoBoxUnavailableLogged ~= true then
            self.qualityInfoBoxUnavailableLogged = true
            Logging.warning("[FS25_TerraLogic] Native WORK QUALITY info box is unavailable")
        end
        return nil
    end
    self.qualityInfoBox = infoDisplay:createBox(InfoDisplayKeyValueBox)
    if self.qualityInfoBox ~= nil then
        TerraLogicLogging.debug("[FS25_TerraLogic] Native WORK QUALITY info box created")
    end
    return self.qualityInfoBox
end

-- Adds TerraLogic's bars to a real InfoDisplay box. The native box controls
-- position, stacking, UI scaling and background; only the right-hand value
-- region is custom-drawn.
function TerraLogicMain:drawNativeSoilBars(box, posX, posY)
    local rows = box.terraLogicSoilRows
    if rows == nil or #rows == 0 then return end
    local boxWidth = box.boxWidth
        or select(1, getNormalizedScreenValues(340, 0))
    local rowHeight = box.rowHeight
        or select(2, getNormalizedScreenValues(0, 26))
    local lineHeight = box.lineHeight or rowHeight * (22 / 26)
    local marginWidth = box.listMarginWidth
        or select(1, getNormalizedScreenValues(16, 0))
    local marginHeight = box.listMarginHeight
        or select(2, getNormalizedScreenValues(0, 15))
    local rightOffset = box.rightTextOffsetX or 0
    local rowTextSize = box.rowTextSize or rowHeight * 0.55
    -- Reserve a fixed numeric column. Descriptors live in the left label, so
    -- neither changing values nor coarse/optimal/fine can move the bars.
    local valueWidth = getTextWidth(rowTextSize, "100 %")
    local valueGap = boxWidth * 0.025
    local barWidth = boxWidth * 0.245
    local barHeight = rowTextSize * 0.88
    local rightX = posX - marginWidth - rightOffset
    local barX = rightX - valueWidth - valueGap - barWidth
    local baselineOffset = box.rightTextOffsetY
        or (rowHeight - rowTextSize) * 0.5

    -- The desktop native box reserves 26 px per background row but advances
    -- text baselines by 22 px. Using rowHeight for both made the error grow
    -- with every line. Keep the already-correct first-row anchor, then follow
    -- the native baseline spacing for subsequent rows.
    local firstRowY = posY + marginHeight
        + (#rows - 2) * rowHeight + baselineOffset
    for index, row in ipairs(rows) do
        local condition = row
        local layerId = nil
        if type(row) == "table" then
            condition = row.value
            layerId = row.layerId
        end
        condition = math.clamp(tonumber(condition) or 0, 0, 1)
        local y = firstRowY - (index - 1) * lineHeight
        drawFilledRect(barX, y, barWidth, barHeight,
            0.035, 0.035, 0.035, 0.95)
        local segments = 24
        for segment=1,segments do
            local t = (segment - 0.5) / segments
            local r, g, b
            local raw = layerId == "roughness" and 1-t or t
            r, g, b = TerraLogicSoilManager:getColor(layerId, raw)
            drawFilledRect(
                barX + (segment - 1) * barWidth / segments,
                y, barWidth / segments + g_pixelSizeX,
                barHeight, r, g, b, 0.95)
        end
        local markerX = barX + condition * barWidth
        drawFilledRect(markerX - g_pixelSizeX, y - g_pixelSizeY,
            g_pixelSizeX * 2, barHeight + g_pixelSizeY * 2,
            1, 1, 1, 1)
    end
    setTextAlignment(RenderText.ALIGN_LEFT)
    setTextColor(1, 1, 1, 1)
end

function TerraLogicMain:getOrCreateSoilInfoBox()
    if self.soilInfoBox ~= nil then return self.soilInfoBox end
    local infoDisplay = g_currentMission ~= nil and g_currentMission.hud ~= nil
        and g_currentMission.hud.infoDisplay or nil
    if infoDisplay == nil or infoDisplay.createBox == nil
        or InfoDisplayKeyValueBox == nil then return nil end
    local box = infoDisplay:createBox(InfoDisplayKeyValueBox)
    if box == nil then return nil end
    local nativeDraw = box.draw
    box.draw = function(soilBox, posX, posY)
        local results = {nativeDraw(soilBox, posX, posY)}
        TerraLogicMain:drawNativeSoilBars(soilBox, posX, posY)
        return unpack(results)
    end
    self.soilInfoBox = box
    return box
end

function TerraLogicMain:drawSoilHud()
    local x, z = getHudWorldPosition(nil)
    if x == nil then return end
    local surface = TerraLogicQualityManager:getSurfaceTypeAtWorldPosition(x, z)
    if surface ~= "field" and surface ~= "grassField" then return end
    local state = TerraLogicSoilManager:getStateAtWorldPosition(x, z)
    if state == nil then return end
    local box = self:getOrCreateSoilInfoBox()
    if box == nil then return end
    local definitions = {
        {"surfaceCompaction", "terraLogic_soilSurfaceHud"},
        {"deepCompaction", "terraLogic_soilDeepHud"},
        {"aggregateSize", "terraLogic_soilAggregate"},
        {"roughness", "terraLogic_soilEvenness"},
        {"resilience", "terraLogic_soilResilience"}
    }
    box:clear()
    box:setTitle(g_i18n:getText("terraLogic_localSoilTitle"))
    box.terraLogicSoilRows = {}
    for _, definition in ipairs(definitions) do
        local layerId = definition[1]
        local rawValue = math.clamp(tonumber(state[layerId]) or 0, 0, 1)
        local directionalTilth = layerId == "aggregateSize"
        local directCompaction = layerId == "surfaceCompaction"
            or layerId == "deepCompaction"
        local displayValue = (directionalTilth or directCompaction) and rawValue
            or TerraLogicSoilManager:getDisplayValue(layerId, rawValue)
        local valueText = TerraLogicI18n.format("%d %%",
            math.floor(displayValue * 100 + 0.5))
        local rowLabel = g_i18n:getText(definition[2])
        box.terraLogicSoilRows[#box.terraLogicSoilRows + 1] = {
            value = displayValue,
            layerId = layerId,
            valueText = valueText
        }
        box:addLine(rowLabel, valueText, false)
    end
    box:showNextFrame()
end

function TerraLogicMain:drawQualityHud()
    if g_localPlayer == nil or g_localPlayer:getCurrentVehicle() ~= nil
        or not getIsGameHudVisible() then return end
    -- The selected ALT+T target changes immediately, while the PF/TL minimap
    -- transition is deliberately delayed. Drive the foot HUD from that target
    -- so it never lags behind the user's key press or needs a menu round-trip.
    local soilMapMode = math.clamp(tonumber(
        TerraLogicSettings.vehicleSoilMapMode) or 0, 0,
        #TerraLogicSoilManager.layers)
    if soilMapMode > 0 then
        self:drawSoilHud()
        return
    end
    local box = self:getOrCreateQualityInfoBox()
    if box == nil then return end
    local x, z, fallbackX, fallbackZ = getHudWorldPosition(nil)
    if x == nil then return end
    local quality, entries, requestPending =
        TerraLogicQualityManager:getSummaryAtWorldPosition(
        x, z, fallbackX, fallbackZ)
    local now = g_currentMission ~= nil and (g_currentMission.time or 0) or 0
    if quality ~= nil and entries ~= nil and #entries > 0 then
        self.lastQualityHudSummary = {
            quality = quality,
            entries = entries,
            x = x,
            z = z,
            time = now
        }
    elseif requestPending == true and self.lastQualityHudSummary ~= nil then
        local cached = self.lastQualityHudSummary
        local dx, dz = x - cached.x, z - cached.z
        local maximumBridgeDistance =
            (TerraLogicQualityManager.CELL_SIZE or 4) * 2
        if now - cached.time <= 1500
            and dx * dx + dz * dz <= maximumBridgeDistance * maximumBridgeDistance then
            quality, entries = cached.quality, cached.entries
        end
    elseif requestPending ~= true then
        -- An authoritative empty cell must remove the preceding field's box;
        -- only a still-pending multiplayer request may use the short bridge.
        self.lastQualityHudSummary = nil
    end
    if quality == nil then
        local implement = self:getDebugImplement()
        local isActivePlow = implement ~= nil and implement.spec_plow ~= nil
            and implement.getIsOverSpeedGroundContactActive ~= nil
            and implement:getIsOverSpeedGroundContactActive()
        if isActivePlow then
            local vehicle = g_localPlayer ~= nil and g_localPlayer:getCurrentVehicle() or nil
            local speed = vehicle ~= nil
                and math.abs(vehicle:getLastSpeed(true) or 0) or 0
            local livePenalty
            quality, livePenalty = TerraLogicQualityManager:getWorkQualityModel(
                implement, speed, "soilPlow")
            local definition = TerraLogicQualityManager.GROUP_DEFINITIONS.soil
            entries = {{
                name = "soil",
                label = TerraLogicQualityManager:getComponentLabel("soil"),
                quality = quality,
                yieldPenalty = livePenalty
            }}
        end
    end
    if quality == nil or entries == nil or #entries == 0 then
        return
    end

    box:clear()
    box:setTitle(TerraLogicQualityManager:getText(
        "terraLogic_localWorkQualityTitle", "LOCAL WORK QUALITY"))
    for _, entry in ipairs(entries) do
        local percent = math.floor(entry.quality * 100 + 0.5)
        box:addLine(entry.label, TerraLogicI18n.format("%d %%", percent),
            entry.quality < 0.90)
    end
    local rootFactor, moistureFactor = 1, 1
    for _, entry in ipairs(entries) do
        if entry.rootYieldFactor ~= nil then rootFactor = entry.rootYieldFactor end
        if entry.moistureYieldFactor ~= nil then moistureFactor = entry.moistureYieldFactor end
    end
    local yieldFactor = TerraLogicQualityManager:getTerraLogicYieldFactor(
        entries, rootFactor, moistureFactor,
        TerraLogicSettings == nil or TerraLogicSettings:getMoistureYieldEnabled(), 1)
    box:addLine(
        TerraLogicQualityManager:getText(
            "terraLogic_workQualityFinalYieldFactor",
            "Final yield factor"
        ),
        TerraLogicI18n.format("%.1f %%", yieldFactor * 100),
        yieldFactor < 0.90
    )
    box:showNextFrame()
    if self.qualityInfoBoxShownLogged ~= true then
        self.qualityInfoBoxShownLogged = true
        TerraLogicLogging.debug("[FS25_TerraLogic] WORK QUALITY info box shown with %d row(s)",
            #entries + 1)
    end
end

-- Debug panel helpers --------------------------------------------------------

-- Formats finite values consistently for the developer HUD.
local function formatNumber(value, decimals)
    if value == nil or value == math.huge or value ~= value then
        return "n/a"
    end
    return string.format("%." .. tostring(decimals or 1) .. "f", value)
end

local DEBUG_VIEW_SECTIONS = {
    wear = { ["SPEED / IMPLEMENT"] = true, ["CONTINUOUS WEAR"] = true },
    economy = {
        ["SPEED / IMPLEMENT"] = true,
        ["CONTINUOUS WEAR"] = true,
        ["LIFETIME / COST"] = true
    },
    draft = {
        ["SPEED / IMPLEMENT"] = true,
        ["DRAFT / RESISTANCE"] = true,
        ["SOIL INPUTS"] = true
    },
    impacts = {
        ["SPEED / IMPLEMENT"] = true,
        ["RANDOM IMPACTS (ABSTRACT / HIDDEN)"] = true,
        ["REAL STONE MAP IMPACTS"] = true
    },
    damageanalysis = {
        ["SPEED / IMPLEMENT"] = true,
        ["DAMAGE ANALYSIS"] = true
    },
    quality = { ["SPEED / IMPLEMENT"] = true, ["WORK QUALITY"] = true },
    technical = { ["SPEED / IMPLEMENT"] = true, ["TECHNICAL"] = true }
}

local function filterDebugSections(lines, view)
    local allowed = DEBUG_VIEW_SECTIONS[view]
    if allowed == nil then
        return lines
    end
    local filtered = {lines[1]}
    local keep = false
    for index = 2, #lines do
        local line = lines[index]
        local section = type(line) == "string"
            and string.match(line, "^%-%-%- (.-) %-%-%-$") or nil
        if section ~= nil then
            keep = allowed[section] == true
        end
        if keep then
            filtered[#filtered + 1] = line
        end
    end
    return filtered
end

local function buildOverviewLines(data, state, currentSpeed, recommendedSpeed, ratedSpeed)
    local qualitySummary = "not applicable"
    if data.isSowingMachine then
        qualitySummary = string.format("seed %.1f%% | %s",
            data.seedQuality * 100, data.seedQualityStatus)
    elseif data.isApplicationTool then
        qualitySummary = string.format("application %.1f%% | %s",
            data.applicationQuality * 100, data.applicationQualityStatus)
    elseif data.isSoilRoller then
        qualitySummary = string.format("roller rollback %.2f%% | %s",
            data.rollerQualityFailure * 100, data.rollerQualityStatus)
    end
    return {
        string.format("TerraLogic OVERVIEW | %s | %s | %s", data.name, state, data.groundToolType),
        "--- IMPLEMENT / SPEED ---",
        string.format("Speed %.1f km/h | class realistic %.1f | safe %.1f | shop %.1f | width %.2f m | damage %.2f%%",
            currentSpeed, recommendedSpeed, data.safeSpeed, ratedSpeed, data.workingWidth or 0,
            data.damagePercent),
        string.format("Safe resolver %s | shop/class %s | window %.2f-%.2f%s",
            data.safeSpeedSource,
            formatNumber(data.shopToClassSpeedFactor, 2),
            data.wearClassShopFactorMin, data.wearClassShopFactorMax,
            data.safeSpeedFallback and " | FALLBACK" or ""),
        string.format("Class %s | depth %.0f cm | work detection %s",
            data.implementClassKey, data.workDepthCm, data.workDetectionSource),
        string.format("Mechanical load %.1f%% | protection %s | safe/trip %.1f/%.1f%% | events %d | structural damage %.4f%%",
            data.structuralLoadPercent,
            data.structuralProtection,
            data.structuralSafeRatio * 100,
            data.structuralTripRatio * 100,
            data.structuralOverloadEventCount,
            data.structuralOverloadDamagePercent),
        "--- WEAR SNAPSHOT (LAST SECOND) ---",
        string.format("Actual %s%%/ha | %s%%/10km | normalized @ %.1fm %s%%/ha",
            formatNumber(data.currentDamagePerHectare ~= nil
                and data.currentDamagePerHectare * 100 or nil, 3),
            formatNumber(data.currentDamagePer10Km ~= nil
                and data.currentDamagePer10Km * 100 or nil, 3),
            data.normalizedReferenceWidth,
            formatNumber(data.normalizedDamagePerHectare ~= nil
                and data.normalizedDamagePerHectare * 100 or nil, 3)),
        string.format("Rate %.3f%%/h | continuous/Vanilla %s x | total/Vanilla %s x",
            data.damageRatePercentPerHour,
            formatNumber(data.continuousVsVanillaMultiplier, 2),
            formatNumber(data.totalVsVanillaMultiplier, 2)),
        string.format("Wear model %s | abrasion tool x%.2f | soil x%.2f | share %.0f%% | baseline x%.2f | policy %s",
            data.wearModel, data.implementAbrasionFactor, data.abrasionMultiplier,
            data.abrasiveShare * 100, data.baselineAbrasionMultiplier,
            data.wearPolicy),
        "--- ECONOMY / LOAD ---",
        string.format("Projected repair %s/ha | measured last second %s/ha",
            data.repairCostPerHectare ~= nil
                and g_i18n:formatMoney(data.repairCostPerHectare, 0, true, false) or "n/a",
            data.measuredRepairCostPerHectare ~= nil
                and g_i18n:formatMoney(data.measuredRepairCostPerHectare, 0, true, false) or "n/a"),
        string.format("Projected remaining %s ha | measured %s ha / %s km",
            formatNumber(data.projectedHectaresToFullDamage, 1),
            formatNumber(data.hectaresToFullDamage, 1),
            formatNumber(data.kilometersToFullDamage, 1)),
        string.format("Draft x%.3f | MaxForce %.2f -> %.2f kN | soil %s",
            data.speedDraftMultiplier, data.baseMaxForce, data.modifiedMaxForce,
            data.soilName),
        "--- EVENTS / QUALITY ---",
        string.format("Random impact damage %.3f%%/s | real stones %.3f%%/s | quality %s",
            data.randomImpactDamageLastSecondPercent,
            data.stoneDamageLastSecondPercent, qualitySummary)
    }
end

local function renderDebugPanel(lines)
    if lines == nil or #lines == 0 then return end
    if TerraLogicMain ~= nil
        and TerraLogicMain.captureDebugPanelLines ~= nil then
        TerraLogicMain:captureDebugPanelLines(lines)
    end
    local topY, x, textX = 0.865, 0.009, 0.015
    local heights, sizes = {}, {}
    local totalHeight, maximumWidth = 0.014, 0.28
    for index, line in ipairs(lines) do
        local isTitle = index == 1
        local isHeading = type(line) == "string"
            and string.match(line, "^%-%-%- .+ %-%-%-$") ~= nil
        local size = isTitle and 0.0140 or (isHeading and 0.0128 or 0.0113)
        local height = isTitle and 0.020 or (isHeading and 0.017 or 0.0142)
        sizes[index], heights[index] = size, height
        totalHeight = totalHeight + height
        if getTextWidth ~= nil then
            maximumWidth = math.max(maximumWidth, getTextWidth(size, tostring(line)))
        else
            maximumWidth = math.max(maximumWidth, #tostring(line) * size * 0.42)
        end
    end
    if drawFilledRect ~= nil then
        drawFilledRect(
            x,
            math.max(topY - totalHeight, 0.006),
            math.min(maximumWidth + 0.018, 0.982),
            math.min(totalHeight, topY - 0.006),
            0.01, 0.01, 0.01, 0.66
        )
    end
    local y = 0.84
    for index, line in ipairs(lines) do
        local isTitle = index == 1
        local isHeading = type(line) == "string"
            and string.match(line, "^%-%-%- .+ %-%-%-$") ~= nil
        if setTextBold ~= nil then setTextBold(isTitle or isHeading) end
        renderText(textX, y, sizes[index], line)
        if setTextBold ~= nil then setTextBold(false) end
        y = y - heights[index]
    end
end

function TerraLogicMain:drawSoilDebug()
    local x, z = getHudWorldPosition(nil)
    if x == nil or z == nil then
        renderDebugPanel({"TerraLogic SOIL", "Player/vehicle position unavailable"})
        return
    end
    local state = TerraLogicSoilManager:getStateAtWorldPosition(x, z)
    local tillageQuality, tillage =
        TerraLogicSoilManager:getTillageQualityFromState(state)
    local rootYield = TerraLogicSoilManager:getRootYieldFactorFromState(state)
    local temperature = TerraLogicSoilTemperatureManager:getState()
    local moisture = TerraLogicSoilMoistureManager:getStateAtWorldPosition(x, z)
    local moistureSystem = TerraLogicSoilMoistureManager:getState()
    local recovery = TerraLogicSoilManager:
        getNaturalRecoveryDebugAtWorldPosition(x, z)
    local implement = self:getDebugImplement(false)
    local implementSpec = implement ~= nil and implement.spec_terraLogic or nil
    local classKey = implementSpec ~= nil
        and implementSpec.implementClassKey or nil
    local depth = implementSpec ~= nil
        and tonumber(implementSpec.workDepthCm) or 0
    local mechanics = TerraLogicSoilMoistureManager:getMechanicalResponse(
        moisture.profileIndex, classKey, depth)
    local ix = math.floor(x / TerraLogicQualityManager.CELL_SIZE)
    local iz = math.floor(z / TerraLogicQualityManager.CELL_SIZE)
    local fruitTypeIndex, growthState = TerraLogicQualityManager:
        getGrowthStateAtCell(ix, iz)
    local growthStage = TerraLogicQualityManager:getSemanticPlowGrowthStage(
        fruitTypeIndex, growthState, nil)
    local moistureYield = TerraLogicSoilMoistureManager:
        getCropYieldResponse(moisture.profileIndex, fruitTypeIndex,
            math.max(growthStage, 1))
    local projectedMoisture, moistureSteps = TerraLogicQualityManager:
        getGrowthMoistureYieldFactor({ix=ix, iz=iz}, false, true)
    local lines = {
        string.format("TerraLogic SOIL | x %.1f z %.1f | %s",
            x, z, moisture.profileName),
        "--- LOCAL PERSISTENT SOIL ---",
        string.format("Surface compaction %.1f%% | deep compaction %.1f%% | resilience %.1f%%",
            state.surfaceCompaction * 100, state.deepCompaction * 100,
            state.resilience * 100),
        string.format("Tilth raw %.1f%% (quality %.1f%%) | evenness %.1f%% | combined soil quality %.1f%%",
            state.aggregateSize * 100, (tillage.tilth or 0) * 100,
            (tillage.levelness or 0) * 100,
            (tillageQuality or 0) * 100),
        string.format("Current root yield %.2f%% | crop-water yield %s x%.3f (stage %d/3, sampled %d)",
            (tonumber(rootYield) or 1) * 100,
            TerraLogicSettings:getMoistureYieldEnabled() and "ACTIVE" or "OFF",
            tonumber(projectedMoisture) or moistureYield.factor,
            growthStage, moistureSteps or 0),
        "--- TEMPERATURE ---",
        string.format("Air %.2f C | soil %.2f C @ %d cm | %.2f C @ %d cm",
            temperature.airTemperatureC, temperature.surfaceTemperatureC,
            temperature.surfaceDepthCm, temperature.subsoilTemperatureC,
            temperature.subsoilDepthCm),
        string.format("Last day mean %.2f C | next sample %.0f%% | climate %.2f C | calendar x%.2f",
            temperature.dailyMeanTemperatureC,
            temperature.dailySampleFraction * 100,
            temperature.climateMeanTemperatureC,
            temperature.calendarScale),
        string.format("Frost surface/deep %s/%s | %.1f/%.1f h | min %.2f/%.2f C | pending thaw %.3f/%.3f | cycles %.0f/%.0f",
            temperature.surfaceFrozen and "FROZEN" or "open",
            temperature.subsoilFrozen and "FROZEN" or "open",
            temperature.surfaceFrozenHours, temperature.subsoilFrozenHours,
            temperature.surfaceFreezeMinimumC,
            temperature.subsoilFreezeMinimumC,
            temperature.pendingSurfaceThawPulse,
            temperature.pendingDeepThawPulse,
            temperature.surfaceFreezeThawCycles,
            temperature.deepFreezeThawCycles),
        "--- MOISTURE / WEATHER ---",
        string.format("Local profile %s%s | water %.1f/%.1f%% | liquid %.1f/%.1f%% @ %d/%d cm",
            moisture.profileName, moisture.pfActive and " (PF)" or " (fallback)",
            moisture.surface * 100, moisture.subsoil * 100,
            moisture.liquidSurface * 100, moisture.liquidSubsoil * 100,
            moistureSystem.surfaceDepthCm, moistureSystem.subsoilDepthCm),
        string.format("Rain %.1f%% | game ground wetness %.1f%% (liquid %.1f%%) | liquid precipitation %.1f%% | evaporation x%.2f",
            moistureSystem.rainScale * 100,
            moistureSystem.groundWetness * 100,
            moistureSystem.liquidGroundWetness * 100,
            moistureSystem.liquidPrecipitationFactor * 100,
            moistureSystem.evaporationFactor),
        string.format("Robust model | operational surface %.1f%% | slow root zone %.1f%% | climate target %.1f%%",
            moistureSystem.surfaceWetness * 100,
            moistureSystem.rootMoisture * 100,
            moistureSystem.climateMoistureTarget * 100),
        string.format("Period %d | history %d | %.1f h observed | liquid-rain exposure %.2f h | weather input %s",
            moistureSystem.periodSerial, moistureSystem.historyCount,
            moistureSystem.periodObservedHours,
            moistureSystem.periodLiquidRainHours,
            moistureSystem.weatherDataValid and "valid" or "INVALID/frozen"),
        string.format("Last period | root mean %.1f%% | surface mean %.1f%% | liquid-rain %.3f h/day | coverage %.0f%% (valid %.0f%%)",
            moistureSystem.lastRootMean * 100,
            moistureSystem.lastSurfaceMean * 100,
            moistureSystem.lastRainHoursPerDay,
            moistureSystem.lastObservationShare * 100,
            moistureSystem.lastValidWeatherShare * 100),
        "Weather effects ACTIVE | draft, WQ, soil work, traffic, crop yield, evaporation, biology and thaw recovery",
        string.format("Crop water now x%.3f | dry %.1f%% wet %.1f%% | root/field capacity %.2f",
            moistureYield.factor, moistureYield.drySeverity * 100,
            moistureYield.wetSeverity * 100,
            moistureYield.relativeToFieldCapacity),
        "--- MOISTURE MECHANICS ---",
        classKey ~= nil and string.format(
            "%s @ %.0f cm | water/liquid %.1f/%.1f%% | dry %.1f%% | wet %.1f%%",
            classKey, depth, mechanics.hydrologicEffective * 100,
            mechanics.liquidEffective * 100,
            mechanics.drySeverity * 100, mechanics.wetSeverity * 100)
            or "No supported implement selected; profile values remain live",
        classKey ~= nil and string.format(
            "Moisture draft x%.3f | combined Work Quality ceiling %.1f%% | soil-effect strength %.1f%% | missed area %.1f%%",
            mechanics.draftMultiplier, mechanics.qualityFactor * 100,
            mechanics.soilEffectiveness * 100,
            mechanics.dropoutFraction * 100)
            or "Select/lower an implement to show its mechanical response",
        classKey ~= nil and string.format(
            "Frost severity %.1f%% (surface %.1f%% x%.2f / deep %.1f%% x%.2f) | draft x%.3f | penetration %.1f%% | WQ %.1f%% | missed area %.1f%%",
            mechanics.frostSeverity * 100,
            mechanics.frostSurfaceSeverity * 100,
            mechanics.frostSurfaceWeight,
            mechanics.frostSubsoilSeverity * 100,
            mechanics.frostSubsoilWeight,
            mechanics.frostDraftMultiplier,
            mechanics.penetrationFactor * 100,
            mechanics.frostQualityFactor * 100,
            mechanics.frostDropoutFraction * 100)
            or "Frost mechanics require a soil-engaging implement",
        "--- NATURAL RECOVERY ---",
        string.format("Cover %s | age %s months | setting %dx | resilience %dx | physical %dx | establishment/rest x%.3f",
            recovery.coverKey, recovery.ageMature
                and "15+" or tostring(recovery.ageMonths),
            recovery.developmentSpeed, recovery.resilienceDevelopmentSpeed,
            recovery.physicalDevelopmentSpeed, recovery.restFactor),
        string.format("Period history %d completed | %d pending%s | current month %.1f h accumulated",
            recovery.completedPeriods, recovery.pendingPeriods,
            recovery.recoveryRunning and " + running" or "",
            recovery.accumulatorHours),
        string.format("Last snapshot %.1f h across %g day(s) at %dx | mean soil %.2f/%.2f C | %s",
            recovery.snapshotHours, recovery.snapshotDaysPerPeriod,
            recovery.snapshotDevelopmentSpeed,
            recovery.snapshotSurfaceTemperatureC,
            recovery.snapshotSubsoilTemperatureC,
            recovery.snapshotSource),
        string.format("Activity | moisture x%.3f | biology x%.3f | physical surface/deep x%.3f/x%.3f | thaw surface/deep x%.3f/x%.3f",
            recovery.moistureFactor, recovery.biologicalFactor,
            recovery.physicalSurfaceFactor,
            recovery.physicalDeepFactor,
            recovery.surfaceFrostFactor,
            recovery.deepFrostFactor),
        string.format("Limits | compaction %.0f/%.0f%% | resilience <= %.0f%% | tilth %s | settling roughness %.0f%% + compaction floor %.0f%%",
            recovery.surfaceTarget * 100,
            recovery.deepTarget * 100,
            recovery.resilienceCeiling * 100,
            recovery.tilthTarget ~= nil
                and string.format("-> %.0f%%", recovery.tilthTarget * 100)
                or "physical-only",
            recovery.settlingTarget * 100,
            recovery.settlementCompactionFloor * 100),
        "--- DERIVED TEXTURE RESPONSES ---"
    }
    for _, index in ipairs(TerraLogicSoilMoistureManager.PROFILE_ORDER) do
        local profile = moistureSystem.profiles[index]
        lines[#lines + 1] = string.format("#%d %-12s | surface %5.1f%% | subsoil %5.1f%%",
            index, profile.name, profile.surface * 100, profile.subsoil * 100)
    end
    local lastPass = TerraLogicSoilManager.lastPass
    if lastPass ~= nil then
        lines[#lines + 1] = "--- LAST SOIL PASS ---"
        lines[#lines + 1] = string.format(
            "%s | moisture %.1f%% | soil effect %.1f%% | draft x%.3f | changed %d cells/%d layers",
            tostring(lastPass.classKey),
            (tonumber(lastPass.moisture) or 0.5) * 100,
            (tonumber(lastPass.moistureSoilEffectiveness) or 1) * 100,
            tonumber(lastPass.moistureDraftMultiplier) or 1,
            tonumber(lastPass.changedCells) or 0,
            tonumber(lastPass.changedLayers) or 0)
        lines[#lines + 1] = string.format(
            "Frost severity %.1f%% | draft x%.3f | WQ %.1f%% | penetration %.1f%%",
            (tonumber(lastPass.frostSeverity) or 0) * 100,
            tonumber(lastPass.frostDraftMultiplier) or 1,
            (tonumber(lastPass.frostQualityFactor) or 1) * 100,
            (tonumber(lastPass.frostPenetrationFactor) or 1) * 100)
    end
    renderDebugPanel(lines)
end

local function formatRuntimeBoolean(value, available)
    if available == false or value == nil then return "n/a" end
    return value == true and "YES" or "no"
end

local function formatRuntimeAge(milliseconds)
    if milliseconds == nil then return "never" end
    return string.format("%.2fs", math.max(
        tonumber(milliseconds) or 0, 0) / 1000)
end

function TerraLogicMain:drawSoilProcessDebug()
    local now = g_currentMission ~= nil and (g_currentMission.time or 0) or 0
    if self.soilProcessDebugLines == nil
        or now >= (self.soilProcessDebugNextRefresh or 0) then
        local x, z = getHudWorldPosition(nil)
        if x == nil or z == nil then
            self.soilProcessDebugLines = {
                "TerraLogic SOIL PROCESS",
                "Player/vehicle position unavailable"
            }
            self.soilProcessDebugNextRefresh = now + 1000
            renderDebugPanel(self.soilProcessDebugLines)
            return
        end

        local layerOrder = {
            {id="surfaceCompaction", label="surface compaction"},
            {id="deepCompaction", label="deep compaction"},
            {id="aggregateSize", label="tilth raw"},
            {id="roughness", label="roughness"},
            {id="resilience", label="resilience"}
        }
        local diagnostics, positionParts = {}, {}
        for _, entry in ipairs(layerOrder) do
            local diagnostic = TerraLogicSoilManager:
                getLayerDebugAtWorldPosition(entry.id, x, z)
            diagnostics[entry.id] = diagnostic
            if diagnostic ~= nil then
                positionParts[#positionParts + 1] = string.format(
                    "%s:%d:%d", entry.id, diagnostic.ix, diagnostic.iz)
            end
        end
        local positionKey = table.concat(positionParts, "|")
        local snapshot = self.soilProcessDebugSnapshot
        if snapshot == nil or snapshot.positionKey ~= positionKey then
            snapshot = {positionKey=positionKey, start={}, previous={}}
            for _, entry in ipairs(layerOrder) do
                local diagnostic = diagnostics[entry.id]
                local value = diagnostic ~= nil and diagnostic.effective or 0
                snapshot.start[entry.id] = value
                snapshot.previous[entry.id] = value
            end
            self.soilProcessDebugSnapshot = snapshot
        end

        local state = TerraLogicSoilManager:getStateAtWorldPosition(x, z)
        local combined, tillage =
            TerraLogicSoilManager:getTillageQualityFromState(state)
        local rootYield, surfaceYieldLoss, deepYieldLoss =
            TerraLogicSoilManager:getRootYieldFactorFromState(state)
        local recovery = TerraLogicSoilManager:
            getNaturalRecoveryDebugAtWorldPosition(x, z)
        local temperature = TerraLogicSoilTemperatureManager:getState()
        local moisture = TerraLogicSoilMoistureManager:getStateAtWorldPosition(x, z)
        local moistureSystem = TerraLogicSoilMoistureManager:getState()
        local surfaceType = TerraLogicQualityManager ~= nil
            and TerraLogicQualityManager:getSurfaceTypeAtWorldPosition(x, z)
            or "unknown"
        local lines = {
            string.format("TerraLogic SOIL PROCESS | x %.1f z %.1f | %s | %s",
                x, z, tostring(surfaceType), moisture.profileName),
            "--- FIVE AUTHORITATIVE SOIL VALUES ---",
            string.format("Displayed values | surface compaction %.2f%% deep compaction %.2f%% tilth quality %.2f%% evenness %.2f%% resilience %.2f%% | combined %.2f%% | root yield %.2f%%",
                (state.surfaceCompaction or 0) * 100,
                (state.deepCompaction or 0) * 100,
                (tillage.tilth or 0) * 100,
                (tillage.levelness or 0) * 100,
                (state.resilience or 0) * 100,
                (combined or 0) * 100,
                (rootYield or 1) * 100)
        }
        lines[#lines + 1] = string.format(
            "Compaction yield | surface loss %.3f%% | deep loss %.3f%% | combined retained %.3f%%",
            (surfaceYieldLoss or 0) * 100,
            (deepYieldLoss or 0) * 100,
            (rootYield or 1) * 100)
        for _, entry in ipairs(layerOrder) do
            local diagnostic = diagnostics[entry.id]
            if diagnostic ~= nil then
                local current = diagnostic.effective
                local deltaLast = current
                    - (snapshot.previous[entry.id] or current)
                local deltaStart = current
                    - (snapshot.start[entry.id] or current)
                local directCompaction = entry.id == "surfaceCompaction"
                    or entry.id == "deepCompaction"
                local displayValue = directCompaction and current
                    or TerraLogicSoilManager:getDisplayValue(entry.id, current)
                local rasterStatus = diagnostic.rasterMatches and "OK"
                    or (diagnostic.source ~= "raster" and "PENDING" or "MISMATCH")
                local visualStatus = diagnostic.visualMatches and "OK"
                    or (diagnostic.visualMaskRaw == 0
                        and "MASKED" or "MISMATCH")
                lines[#lines + 1] = string.format(
                    "%s | stored %.3f%% display %.3f%% | d1s %+.4f pp | dPanel %+.4f pp | cell %d:%d @ %gm",
                    entry.label, current * 100, displayValue * 100,
                    deltaLast * 100, deltaStart * 100,
                    diagnostic.ix, diagnostic.iz,
                    diagnostic.cellSize)
                lines[#lines + 1] = string.format(
                    "  map raw %d/%d %s decoded %.4f%% | overlay source %d/%d %s mask %d decoded %s | source %s | writes %d",
                    diagnostic.raw, diagnostic.expectedRaw, rasterStatus,
                    diagnostic.rasterValue * 100,
                    diagnostic.visualRaw, diagnostic.expectedVisualRaw,
                    visualStatus, diagnostic.visualMaskRaw,
                    diagnostic.visualValue ~= nil
                        and string.format("%.4f%%", diagnostic.visualValue * 100)
                        or "masked",
                    diagnostic.source, diagnostic.writeSerial)
                snapshot.previous[entry.id] = current
            end
        end

        lines[#lines + 1] = "--- PROCESS DRIVERS / RECOVERY ---"
        lines[#lines + 1] = string.format(
            "Cover %s | age %d months | setting %dx | resilience %dx | physical %dx | rest x%.3f | recovery completed/pending %d/%d%s",
            recovery.coverKey, recovery.ageMonths,
            recovery.developmentSpeed, recovery.resilienceDevelopmentSpeed,
            recovery.physicalDevelopmentSpeed, recovery.restFactor,
            recovery.completedPeriods, recovery.pendingPeriods,
            recovery.recoveryRunning and " RUNNING" or "")
        lines[#lines + 1] = string.format(
            "Targets | compaction %.1f/%.1f%% | resilience ceiling %.1f%% | tilth %s | roughness %.1f%% floor %.1f%%",
            recovery.surfaceTarget * 100, recovery.deepTarget * 100,
            recovery.resilienceCeiling * 100,
            recovery.tilthTarget ~= nil
                and string.format("%.1f%%", recovery.tilthTarget * 100)
                or "physical-only",
            recovery.settlingTarget * 100,
            recovery.settlementCompactionFloor * 100)
        lines[#lines + 1] = string.format(
            "Environment | moisture x%.3f biology x%.3f physical %.3f/%.3f thaw %.3f/%.3f | soil %.2f/%.2f C",
            recovery.moistureFactor, recovery.biologicalFactor,
            recovery.physicalSurfaceFactor, recovery.physicalDeepFactor,
            recovery.surfaceFrostFactor, recovery.deepFrostFactor,
            recovery.surfaceTemperatureC, recovery.subsoilTemperatureC)
        lines[#lines + 1] = string.format(
            "Water state | hydrologic %.1f/%.1f%% | liquid %.1f/%.1f%% | ground wetness %.1f%% liquid ground %.1f%% | frozen %s/%s",
            moisture.surface * 100, moisture.subsoil * 100,
            moisture.liquidSurface * 100, moisture.liquidSubsoil * 100,
            moistureSystem.groundWetness * 100,
            moistureSystem.liquidGroundWetness * 100,
            temperature.surfaceFrozen and "YES" or "no",
            temperature.subsoilFrozen and "YES" or "no")
        lines[#lines + 1] = string.format(
            "Recovery snapshot | %.1fh @ %g day(s), %dx, %.2f/%.2f C, source %s | accumulator %.1fh",
            recovery.snapshotHours, recovery.snapshotDaysPerPeriod,
            recovery.snapshotDevelopmentSpeed,
            recovery.snapshotSurfaceTemperatureC,
            recovery.snapshotSubsoilTemperatureC,
            recovery.snapshotSource, recovery.accumulatorHours)

        local lastPass = TerraLogicSoilManager.lastPass
        lines[#lines + 1] = "--- LAST WRITES / MAP PIPELINE ---"
        if lastPass ~= nil then
            lines[#lines + 1] = string.format(
                "Last pass %s | source %s | %.1fs ago | changed %d cells/%d layers | eligible/touched %d/%d | vanilla changed/total %.3f/%.3f",
                tostring(lastPass.classKey),
                tostring(lastPass.implementName or "unknown implement"),
                math.max(now - (tonumber(lastPass.time) or now), 0) / 1000,
                tonumber(lastPass.changedCells) or 0,
                tonumber(lastPass.changedLayers) or 0,
                tonumber(lastPass.eligibleCells) or 0,
                tonumber(lastPass.touchedCells) or 0,
                tonumber(lastPass.changedArea) or 0,
                tonumber(lastPass.totalArea) or 0)
            lines[#lines + 1] = string.format(
                "Last pass factors | speed %.2f/%.2f kph ratio %.3f overspeed %.3f | wear x%.3f | moisture %.1f%% effect %.1f%% draft x%.3f",
                tonumber(lastPass.speedKph) or 0,
                tonumber(lastPass.speedReferenceKph) or 0,
                tonumber(lastPass.speedRatio) or 0,
                tonumber(lastPass.overspeedSeverity) or 0,
                tonumber(lastPass.wearStrengthMultiplier) or 1,
                (tonumber(lastPass.moisture) or 0) * 100,
                (tonumber(lastPass.moistureSoilEffectiveness) or 1) * 100,
                tonumber(lastPass.moistureDraftMultiplier) or 1)
            lines[#lines + 1] = string.format(
                "Last pass config | %s",
                tostring(lastPass.configFileName or "unknown"))
            lines[#lines + 1] = string.format(
                "Last pass frost | severity %.1f%% | draft x%.3f | WQ %.1f%% | penetration %.1f%%",
                (tonumber(lastPass.frostSeverity) or 0) * 100,
                tonumber(lastPass.frostDraftMultiplier) or 1,
                (tonumber(lastPass.frostQualityFactor) or 1) * 100,
                (tonumber(lastPass.frostPenetrationFactor) or 1) * 100)
        else
            lines[#lines + 1] = "No soil pass recorded in this session"
        end
        local rejectedPass = TerraLogicSoilManager.lastRejectedPass
        if rejectedPass ~= nil then
            lines[#lines + 1] = string.format(
                "Last ignored pass %s | %.1fs ago | %s | speed %.3f kph | vanilla changed/total %.3f/%.3f",
                tostring(rejectedPass.classKey),
                math.max(now - (tonumber(rejectedPass.time) or now), 0) / 1000,
                tostring(rejectedPass.reason or "inactive"),
                tonumber(rejectedPass.speedKph) or 0,
                tonumber(rejectedPass.changedArea) or 0,
                tonumber(rejectedPass.totalArea) or 0)
        end
        local lastWrite = TerraLogicSoilManager.lastWrite
        if lastWrite ~= nil then
            lines[#lines + 1] = string.format(
                "Last write | %s | source %s | %s cell %d:%d | %.4f -> %.4f%% (d %+.4f pp) | %.1fs ago",
                tostring(lastWrite.classKey),
                tostring(lastWrite.sourceName or "unknown"),
                tostring(lastWrite.layerId),
                tonumber(lastWrite.ix) or 0, tonumber(lastWrite.iz) or 0,
                (tonumber(lastWrite.beforeValue)
                    or tonumber(lastWrite.value) or 0) * 100,
                (tonumber(lastWrite.value) or 0) * 100,
                (tonumber(lastWrite.delta) or 0) * 100,
                math.max(now - (tonumber(lastWrite.time) or now), 0) / 1000)
        end
        local wheel = TerraLogicSoilManager.lastWheelImpactDebug
        if wheel ~= nil then
            lines[#lines + 1] = "--- LAST WHEEL CAUSE (GLOBAL) ---"
            lines[#lines + 1] = string.format(
                "Wheel source %s | %.2fs ago | mass/supported %.3f/%.3f t | wheels/axles %d/%d | axle mean/max %.3f/%.3f t",
                tostring(wheel.vehicleName or "vehicle"),
                math.max(now - (tonumber(wheel.time) or now), 0) / 1000,
                tonumber(wheel.vehicleMassT) or 0,
                tonumber(wheel.supportedLoadT) or 0,
                tonumber(wheel.wheelCount) or 0,
                tonumber(wheel.axleCount) or 0,
                tonumber(wheel.meanAxleLoadT) or 0,
                tonumber(wheel.maxAxleLoadT) or 0)
            lines[#lines + 1] = string.format(
                "Wheel config | %s | position %.2f %.2f | distance from panel %.2f m",
                tostring(wheel.configFileName or "unknown"),
                tonumber(wheel.x) or 0,
                tonumber(wheel.z) or 0,
                math.sqrt(((tonumber(wheel.x) or x) - x) ^ 2
                    + ((tonumber(wheel.z) or z) - z) ^ 2))
            lines[#lines + 1] = string.format(
                "Ground contact pressure mean/max %.1f/%.1f kPa | causal contact load %.3f t @ %.1f kPa | width/diameter/contact %.3f/%.3f/%.3f m",
                tonumber(wheel.meanPressureKPa) or 0,
                tonumber(wheel.maxPressureKPa) or 0,
                tonumber(wheel.wheelLoadT) or 0,
                tonumber(wheel.pressureKPa) or 0,
                tonumber(wheel.tireWidthM) or 0,
                tonumber(wheel.tireDiameterM) or 0,
                tonumber(wheel.contactLengthM) or 0)
            lines[#lines + 1] = string.format(
                "Causal wheel #%d %s | rest load %.3f t | visual tyres %d | tyre source %s",
                tonumber(wheel.wheelIndex) or 0,
                tostring(wheel.wheelNodeName or "unknown"),
                tonumber(wheel.wheelRestLoadT) or 0,
                tonumber(wheel.wheelVisualCount) or 0,
                wheel.wheelExternalFilename ~= nil
                    and wheel.wheelExternalFilename ~= ""
                    and tostring(wheel.wheelExternalFilename)
                    or "inline physics")
            if wheel.workingImplementSurfaceSuppressed == true then
                lines[#lines + 1] = string.format(
                    "Working implement surface traffic SUPPRESSED | contacts %d | strongest wheel #%d %s | %.3f t @ %.1f kPa | avoided target/strength %.2f%%/%.4f",
                    tonumber(wheel.suppressedSurfaceContacts) or 0,
                    tonumber(wheel.maxSuppressedWheelIndex) or 0,
                    tostring(wheel.maxSuppressedWheelNodeName or "unknown"),
                    tonumber(wheel.maxSuppressedWheelLoadT) or 0,
                    tonumber(wheel.maxSuppressedPressureKPa) or 0,
                    (tonumber(wheel.maxSuppressedSurfaceTarget) or 0) * 100,
                    tonumber(wheel.maxSuppressedSurfaceStrength) or 0)
            else
                lines[#lines + 1] =
                    "Surface traffic ACTIVE | below 50 kPa target 30 -> 47%; existing curve 50 -> 300 kPa | raised, folded, transporting or non-soil-working"
            end
            local runtime = wheel.implementRuntimeState
            if runtime ~= nil then
                lines[#lines + 1] = string.format(
                    "Engine work state | lowered %s | chain %s | fold %s direction %s | fold work position %s",
                    formatRuntimeBoolean(runtime.lowered,
                        runtime.loweredAvailable),
                    formatRuntimeBoolean(runtime.chainLowered,
                        runtime.chainLoweredAvailable),
                    runtime.foldAnimTime ~= nil
                        and string.format("%.4f", runtime.foldAnimTime)
                        or "n/a",
                    runtime.foldMoveDirection ~= nil
                        and string.format("%.0f", runtime.foldMoveDirection)
                        or "n/a",
                    formatRuntimeBoolean(runtime.foldWorkPosition, true))
                lines[#lines + 1] = string.format(
                    "WorkArea state | active %d/%d%s | last %s @ %s | %s | lowered-only %s",
                    tonumber(runtime.workAreaActiveCount) or 0,
                    tonumber(runtime.workAreaCount) or 0,
                    runtime.workAreaQueryAvailable == true
                        and "" or " (query unavailable)",
                    formatRuntimeBoolean(runtime.lastWorkAreaActive,
                        runtime.lastWorkAreaActive ~= nil),
                    formatRuntimeAge(runtime.lastWorkAreaActiveAgeMs),
                    tostring(runtime.lastWorkAreaFunctionName or "unknown"),
                    formatRuntimeBoolean(
                        runtime.lastWorkAreaOnlyActiveWhenLowered,
                        runtime.lastWorkAreaOnlyActiveWhenLowered ~= nil))
                lines[#lines + 1] = string.format(
                    "Ground reference | active %d/%d known of %d | source %s | detection %s",
                    tonumber(runtime.groundReferenceActiveCount) or 0,
                    tonumber(runtime.groundReferenceKnownCount) or 0,
                    tonumber(runtime.groundReferenceCount) or 0,
                    tostring(runtime.groundReferenceSource or "unavailable"),
                    tostring(runtime.workDetectionSource or "inactive"))
                lines[#lines + 1] = string.format(
                    "Cultivator callbacks | any %s | processing %s | changed %s | last vanilla %.3f/%.3f",
                    formatRuntimeAge(runtime.lastCultivatorCallbackAgeMs),
                    formatRuntimeAge(runtime.lastCultivatorProcessingAgeMs),
                    formatRuntimeAge(runtime.lastCultivatorChangedAgeMs),
                    tonumber(runtime.lastCultivatorChangedArea) or 0,
                    tonumber(runtime.lastCultivatorTotalArea) or 0)
            end
            lines[#lines + 1] = string.format(
                "Wheel inputs | surface mode %s target/strength %.3f%%/%.4f | deep %.3f%%/%.5f coverage %.2f%% | moisture %.1f/%.1f%% | resilience %.1f%%",
                wheel.surfaceLowPressureResponse == true
                    and "continuous <50 kPa" or "standard",
                (tonumber(wheel.surfaceTarget) or 0) * 100,
                tonumber(wheel.surfaceAppliedStrength) or 0,
                (tonumber(wheel.deepTarget) or 0) * 100,
                tonumber(wheel.deepAppliedStrength) or 0,
                (tonumber(wheel.deepCoverage) or 0) * 100,
                (tonumber(wheel.moistureSurface) or 0) * 100,
                (tonumber(wheel.moistureSubsoil) or 0) * 100,
                (tonumber(wheel.resilience) or 0) * 100)
            lines[#lines + 1] = string.format(
                "Wheel compaction cell | surface %.3f -> %.3f%% (d %+.4f pp) | deep %.3f -> %.3f%% (d %+.4f pp) | slip %.2f%% | soil %s",
                (tonumber(wheel.before ~= nil
                    and wheel.before.surfaceCompaction) or 0) * 100,
                (tonumber(wheel.after ~= nil
                    and wheel.after.surfaceCompaction) or 0) * 100,
                (tonumber(wheel.delta ~= nil
                    and wheel.delta.surfaceCompaction) or 0) * 100,
                (tonumber(wheel.before ~= nil
                    and wheel.before.deepCompaction) or 0) * 100,
                (tonumber(wheel.after ~= nil
                    and wheel.after.deepCompaction) or 0) * 100,
                (tonumber(wheel.delta ~= nil
                    and wheel.delta.deepCompaction) or 0) * 100,
                (tonumber(wheel.slipSeverity) or 0) * 100,
                tostring(wheel.soilName or "Generic"))
        end
        lines[#lines + 1] = string.format(
            "Pipeline | raster %s | visual dirty %s | overlay mode %d | panel position key %s",
            TerraLogicSoilManager.rasterReady and "READY" or "NOT READY",
            TerraLogicSoilManager.visualizationDirty and "YES" or "no",
            tonumber(TerraLogicSoilManager.activeMapMode) or 0,
            positionKey)

        self.soilProcessDebugLines = lines
        self.soilProcessDebugNextRefresh = now + 1000
    end
    renderDebugPanel(self.soilProcessDebugLines)
end

function TerraLogicMain:drawWorkQualityDebug()
    local now = g_currentMission.time or 0
    if self.workQualityDebugLines == nil
        or now >= (self.workQualityDebugNextRefresh or 0) then
        local x, z, fallbackX, fallbackZ = getHudWorldPosition(nil)
        local overallQuality, entries
        if x ~= nil then
            overallQuality, entries = TerraLogicQualityManager:getSummaryAtWorldPosition(
                x, z, fallbackX, fallbackZ)
        end

        local byName = {}
        for _, entry in ipairs(entries or {}) do byName[entry.name] = entry end
        local lines = {
            string.format("TerraLogic WORK QUALITY | sample x=%s z=%s",
                formatNumber(x, 1), formatNumber(z, 1)),
            string.format(
                "Speed curve | real 100%% -> shop %.0f%% | post-shop H=exp(-%.2f*overspeed^2)",
                TerraLogicQualityManager.QUALITY_AT_SHOP_SPEED * 100,
                TerraLogicQualityManager.ECONOMY_CURVE_K),
            "--- CURRENT STORED OPERATIONS ---"
        }
        for _, name in ipairs(TerraLogicQualityManager.GROUP_ORDER) do
            local definition = TerraLogicQualityManager.GROUP_DEFINITIONS[name]
            local entry = byName[name]
            local quality = entry ~= nil and entry.quality or nil
            local contribution = entry ~= nil
                and (entry.yieldPenalty or 0) or 0
            local neutral = definition.affectsYield == false
            if neutral then contribution = 0 end
            lines[#lines + 1] = string.format(
                "%-12s | %-8s | Q %6s | %s | factor x%.4f%s",
                string.upper(name), entry ~= nil and "DONE" or "NOT DONE",
                quality ~= nil and string.format("%.1f%%", quality * 100) or "n/a",
                neutral and "yield-neutral" or string.format(
                    "weight %5.1f%% max %4.1f%%",
                    definition.yieldWeight * 100,
                    definition.maxYieldPenalty * 100),
                1 - contribution,
                definition.directDensityPenalty == true and " (physical + residual)" or "")
        end
        local qualityIx = x ~= nil and math.floor(
            x / TerraLogicQualityManager.CELL_SIZE) or 0
        local qualityIz = z ~= nil and math.floor(
            z / TerraLogicQualityManager.CELL_SIZE) or 0
        local rootFactor = TerraLogicQualityManager:getGrowthRootYieldFactor(
            {ix=qualityIx,iz=qualityIz},false,true) or 1
        local moistureFactor = TerraLogicQualityManager:
            getGrowthMoistureYieldFactor(
                {ix=qualityIx,iz=qualityIz},false,true) or 1
        local resilience = x ~= nil and TerraLogicSoilManager ~= nil
            and TerraLogicSoilManager:getValueAtWorldPosition(
                "resilience",x,z) or 0.50
        local effectiveFactor, yieldDetail = TerraLogicQualityManager:
            getTerraLogicYieldFactor(entries or {},rootFactor,moistureFactor,
                TerraLogicSettings == nil
                    or TerraLogicSettings:getMoistureYieldEnabled(),
                1,resilience)
        local effectiveLoss = 1 - effectiveFactor
        lines[#lines + 1] = "--- CURRENT TerraLogic YIELD EFFECT ---"
        lines[#lines + 1] = string.format(
            "Displayed mean quality %s | signed relative change %+.3f",
            overallQuality ~= nil and string.format("%.1f%%", overallQuality * 100)
                or "n/a", effectiveFactor-1)
        lines[#lines + 1] = string.format(
            "TerraLogic factor x%.4f | deductions: soil %.2f pp, water %.2f pp, work %.2f pp",
            effectiveFactor, (yieldDetail.soilDeduction or 0)*100,
            (yieldDetail.waterDeduction or 0)*100,
            (yieldDetail.workDeduction or 0)*100)
        lines[#lines + 1] = "Formula: 110% - soil - water - work; minimum 60%; physical missed plants remain additional"
        lines[#lines + 1] = "Soil Work Quality is descriptive; tilth/levelness act through seeding only"
        lines[#lines + 1] = "SEED target loss = physical missing plants + residual harvest correction"
        lines[#lines + 1] = "NOT DONE is neutral; Vanilla or active PF handles missing base-game bonuses"

        lines[#lines + 1] = "--- LAST REAL HARVEST APPLICATION (SERVER) ---"
        local harvest = TerraLogicQualityManager.lastHarvestDebug
        if harvest ~= nil then
            lines[#lines + 1] = string.format(
                "Base Vanilla/PF x%.4f -> after TerraLogic x%.4f | signed delta %+.3f points",
                harvest.baseMultiplier, harvest.finalMultiplier,
                harvest.appliedDelta or -harvest.appliedDeduction)
            lines[#lines + 1] = string.format(
                "Actual TL factor %.2f%% | change %+.2f%% | root/moisture loss %.2f%%/%.2f%% | sampled cells %d",
                (harvest.averageFactor or 1)*100,
                (harvest.relativeChange or -harvest.relativeLoss)*100,
                (harvest.averageRootLoss or 0) * 100,
                (harvest.averageMoistureLoss or 0) * 100,
                harvest.samples or 0)
            if (harvest.liveHarvestPenalty or 0) > 0 then
                lines[#lines + 1] = string.format(
                    "Live root harvester %s | Q %.1f%% | direct whole-yield penalty %.2f%%",
                    tostring(harvest.liveHarvestClass or "root crop"),
                    (harvest.liveHarvestQuality or 1) * 100,
                    (harvest.liveHarvestPenalty or 0) * 100)
            end
        else
            lines[#lines + 1] = "No harvest processed in this session yet"
        end
        self.workQualityDebugLines = lines
        self.workQualityDebugNextRefresh = now + 1000
    end

    renderDebugPanel(self.workQualityDebugLines)
end

function TerraLogicMain:drawBalancingDebug()
    local implement = self:getDebugImplement()
    if implement == nil or implement.spec_terraLogic == nil then
        renderDebugPanel({
            "TerraLogic BALANCING",
            "No supported active implement selected"
        })
        return
    end
    local data = implement:getOverSpeedDebugData()
    local spec = implement.spec_terraLogic
    local speed = math.max(tonumber(data.speed) or 0, 0)
    local shopSpeed = math.max(tonumber(data.ratedSpeed) or 0, 0.01)
    local economy = TerraLogicQualityManager:getSpeedEconomy(implement, speed)
    local ratio = economy.shopRatio
    local overspeed = economy.overspeed
    local timeSaved = economy.timeSaved
    local now = g_currentMission.time or 0
    local activeRows = {}
    local activeGroups = {}
    for _, group in ipairs(TerraLogicQualityManager.GROUP_ORDER) do
        local live = spec.liveWorkQualityGroups ~= nil
            and spec.liveWorkQualityGroups[group] or nil
        if live ~= nil and now - (live.time or 0) <= 1500 then
            activeGroups[group] = true
            activeRows[#activeRows + 1] = string.format(
                "%s | quality %.1f%% | yield loss %.1f%%",
                TerraLogicQualityManager:getComponentLabel(group),
                (live.quality or 1) * 100,
                (live.yieldPenalty or 0) * 100
            )
        end
    end
    local liveMower = spec.liveWorkQualityGroups ~= nil
        and spec.liveWorkQualityGroups.mower or nil
    if liveMower ~= nil and now - (liveMower.time or 0) <= 1500 then
        activeGroups.mower = true
        activeRows[#activeRows + 1] = string.format(
            "%s | quality %.1f%% | yield loss %.1f%%",
            TerraLogicQualityManager:getComponentLabel("mower"),
            (liveMower.quality or 1) * 100,
            (liveMower.yieldPenalty or 0) * 100)
    end
    if next(activeGroups) == nil then
        if implement.spec_sowingMachine ~= nil then
            activeGroups.seed = true
            if implement.spec_sowingMachine.useDirectPlanting == true then
                activeGroups.soil = true
            end
        elseif implement.spec_plow ~= nil or implement.spec_cultivator ~= nil then
            activeGroups.soil = true
        elseif implement.spec_sprayer ~= nil then
            local component = TerraLogic ~= nil
                and TerraLogic.getApplicationComponentForVehicle ~= nil
                and TerraLogic.getApplicationComponentForVehicle(implement)
                or spec.applicationQualityComponent or "fertilizer"
            if component ~= "herbicide" then
                activeGroups[component] = true
            end
        elseif implement.spec_roller ~= nil then
            activeGroups.roller = true
        elseif implement.spec_mulcher ~= nil then
            activeGroups.mulch = true
        elseif implement.spec_mower ~= nil then
            activeGroups.mower = true
        end
    end

    local currentFactor, shopFactor = 1, 1
    local modelRows = {}
    local componentByGroup = {
        soil = implement.spec_plow ~= nil and "soilPlow"
            or (implement.spec_sowingMachine ~= nil
                and implement.spec_sowingMachine.useDirectPlanting == true
                and "soilCultivate" or "soilCultivate"),
        seed = "seed", fertilizer = "fertilizer", lime = "lime",
        herbicide = "herbicide", roller = "roller", mulch = "mulch"
    }
    componentByGroup.mower = "mower"
    local modelGroupOrder = {}
    for _, group in ipairs(TerraLogicQualityManager.GROUP_ORDER) do
        modelGroupOrder[#modelGroupOrder + 1] = group
    end
    if activeGroups.mower == true then
        modelGroupOrder[#modelGroupOrder + 1] = "mower"
    end
    for _, group in ipairs(modelGroupOrder) do
        if activeGroups[group] == true then
            local component = componentByGroup[group]
            local bonusOverride = (group == "fertilizer" or group == "lime")
                and spec.applicationQualityPfBonus or nil
            local quality, penalty, model =
                TerraLogicQualityManager:getWorkQualityModel(
                    implement, speed, component, bonusOverride)
            local displayQuality = bonusOverride ~= nil
                and select(1, TerraLogicQualityManager:getWorkQualityModel(
                    implement, speed, component, nil)) or quality
            currentFactor = currentFactor * model.areaFactor
            shopFactor = shopFactor * model.shopAreaFactor
            local effectDetail = model.effectType == "bonus"
                and string.format(" | bonus %.1f%% only%s",
                    (model.bonus or 0) * 100,
                    model.bonusFloorReached and " | BASELINE FLOOR" or "")
                or string.format(" | whole-yield cap %.1f%%%s",
                    (model.maximumPenalty or 0) * 100,
                    model.penaltyFloorReached and " | CAP REACHED" or "")
            modelRows[#modelRows + 1] = string.format(
                "%s | Q %.1f%% | area x%.3f | loss %.1f%%%s",
                TerraLogicQualityManager:getComponentLabel(group),
                displayQuality * 100, model.areaFactor, penalty * 100,
                effectDetail)
        end
    end
    local relativeYieldFactor = currentFactor / math.max(shopFactor, 0.0001)
    local yieldLossVsShop = 1 - relativeYieldFactor
    local hourlyYieldIndex = ratio * relativeYieldFactor
    local breakEvenFactor = ratio > 0 and math.min(1 / ratio, 1) or 1
    local breakEvenLoss = 1 - breakEvenFactor
    local pfActive = self.isPrecisionFarmingActive ~= nil
        and self:isPrecisionFarmingActive()
    local lines = {
        string.format("TerraLogic BALANCING | %s", data.name),
        "--- SPEED ECONOMY ---",
        string.format(
            "Current %.1f km/h | realistic %.1f | shop %.1f | shop ratio x%.3f",
            speed, economy.realSpeed, shopSpeed, ratio),
        string.format(
            "Shop overspeed %.1f%% | time saved per area %.1f%%",
            overspeed * 100, timeSaved * 100),
        string.format(
            "Speed wear | x%.3f Vanilla at current speed | x%.3f per-area vs shop",
            data.liveWearSpeedMultiplier, data.liveWearPerAreaVsShop),
        string.format(
            "Age/usage | Vanilla x%.3f -> TerraLogic x%.3f | full operating-age %.0f h",
            data.vanillaAgeUsageFactor,
            data.adjustedAgeUsageFactor,
            data.ageUsageFullHours),
        "--- LIVE WORK QUALITY ---"
    }
    if #activeRows == 0 then
        lines[#lines + 1] = "No recent density change; showing live model for detected implement"
    end
    for _, row in ipairs(modelRows) do lines[#lines + 1] = row end
    lines[#lines + 1] = "--- PROFITABILITY CHECK ---"
    lines[#lines + 1] = string.format(
        "Current area x%.3f | shop area x%.3f | retained vs shop %.1f%%",
        currentFactor, shopFactor, relativeYieldFactor * 100)
    lines[#lines + 1] = string.format(
        "Yield loss vs shop %.1f%% | break-even loss %.1f%% | margin %+.1f pp",
        yieldLossVsShop * 100, breakEvenLoss * 100,
        (yieldLossVsShop - breakEvenLoss) * 100)
    local profitabilityStatus = ratio <= 1.0001
        and "AT/BELOW SHOP SPEED"
        or (hourlyYieldIndex <= 1.0001
            and "OVERSPEED NOT PROFITABLE" or "OVERSPEED STILL PROFITABLE")
    lines[#lines + 1] = string.format(
        "SPEED/YIELD PROFITABILITY FACTOR %.3f | %s",
        hourlyYieldIndex,
        profitabilityStatus)
    lines[#lines + 1] = "Factor <1 = not profitable | >1 = profitable | benchmark: shop speed"
    lines[#lines + 1] = string.format(
        "Economic target H %.3f | curve K %.2f | abrasion/impacts excluded",
        economy.hourlyTarget, TerraLogicQualityManager.ECONOMY_CURVE_K)
    lines[#lines + 1] = string.format(
        "Yield basis: %s | PF bonus uses local N/pH gain when available",
        pfActive and "Precision Farming" or "Vanilla")
    lines[#lines + 1] = "Unified harvest factor 60-110% of Vanilla/PF | physical missed plants additional"
    renderDebugPanel(lines)
end

function TerraLogicMain:drawTrafficDebug()
    local now = g_currentMission ~= nil and g_currentMission.time or 0
    if self.trafficDebugLines == nil
        or now >= (self.trafficDebugNextRefresh or 0) then
        local controlled = g_localPlayer ~= nil
            and g_localPlayer.getCurrentVehicle ~= nil
            and g_localPlayer:getCurrentVehicle() or nil
        local diagnostic = TerraLogicWheelCompactionManager ~= nil
            and TerraLogicWheelCompactionManager:getDiagnostic(controlled)
            or nil
        if diagnostic == nil then
            self.trafficDebugLines = {
                "TerraLogic VEHICLE / SOIL TRAFFIC",
                "No moving wheel sample recorded yet",
                "Enter a vehicle and drive onto a field above 0.25 km/h",
                "CSV: tlTestStart soilprocess <name>"
            }
            self.trafficDebugNextRefresh = now + 1000
            renderDebugPanel(self.trafficDebugLines)
            return
        end

        local impact = diagnostic.lastImpact
        local before = impact ~= nil and impact.before or {}
        local after = impact ~= nil and impact.after or {}
        local delta = impact ~= nil and impact.delta or {}
        local changed = diagnostic.changedByLayer or {}
        local totalChanged = diagnostic.totalChangedByLayer or {}
        local tickDelta = diagnostic.deltaByLayer or {}
        local maxDelta = diagnostic.maximumDeltaByLayer or {}
        local counts = diagnostic.impactCountBySize or {}
        local age = math.max(now - (tonumber(diagnostic.time) or now), 0)
            / 1000
        local sampleSource = diagnostic.vehicle == controlled
            and "controlled vehicle" or "latest moving wheel entity"
        local lines = {
            string.format("TerraLogic VEHICLE / SOIL TRAFFIC | %s",
                tostring(diagnostic.vehicleName or "vehicle")),
            string.format(
                "Sample %.2fs old | %s | speed %.2f km/h | position %.1f %.1f",
                age, sampleSource, tonumber(diagnostic.speed) or 0,
                tonumber(diagnostic.firstX) or 0,
                tonumber(diagnostic.firstZ) or 0),
            "--- VEHICLE MASS / TYRE GEOMETRY ---",
            string.format(
                "Vehicle mass %.3f t | supported load %.3f t (%.1f%%) | contacts %d field %d",
                tonumber(diagnostic.vehicleMass) or 0,
                tonumber(diagnostic.totalLoad) or 0,
                (tonumber(diagnostic.supportedLoadRatio) or 0) * 100,
                tonumber(diagnostic.wheelCount) or 0,
                tonumber(diagnostic.fieldContactCount) or 0),
            string.format(
                "Wheel loads min/mean/max %.3f/%.3f/%.3f t | axles %d | mean/max axle %.3f/%.3f t",
                tonumber(diagnostic.minWheelLoad) or 0,
                tonumber(diagnostic.meanWheelLoad) or 0,
                tonumber(diagnostic.maxWheelLoad) or 0,
                tonumber(diagnostic.axleCount) or 0,
                tonumber(diagnostic.meanAxleLoad) or 0,
                tonumber(diagnostic.maxAxleLoad) or 0),
            string.format(
                "Surface footprints %d | represented tyres %d | crawler contacts/modules/fallback %d/%d/%d",
                tonumber(diagnostic.effectiveFootprintCount) or 0,
                tonumber(diagnostic.physicalTireCount) or 0,
                tonumber(diagnostic.crawlerCount) or 0,
                tonumber(diagnostic.crawlerModuleCount) or 0,
                tonumber(diagnostic.unmatchedCrawlerCount) or 0),
            string.format(
                "Mean tire width/diameter/contact length %.3f/%.3f/%.3f m | ground contact pressure mean/peak %.1f/%.1f kPa",
                tonumber(diagnostic.meanWidth) or 0,
                tonumber(diagnostic.meanDiameter) or 0,
                tonumber(diagnostic.meanContactLength) or 0,
                tonumber(diagnostic.meanPressure) or 0,
                tonumber(diagnostic.maxPressure) or 0),
            string.format(
                "Slip raw/corrected maximum %.2f/%.2f%% | active severity %.2f%%",
                (tonumber(diagnostic.maxRawSlip) or 0) * 100,
                (tonumber(diagnostic.maxSlip) or 0) * 100,
                (impact ~= nil and tonumber(impact.slipSeverity) or 0) * 100),
            "--- LOCAL SOIL / WEATHER INPUTS ---"
        }
        if impact ~= nil then
            lines[#lines + 1] = string.format(
                "Cell %.1f %.1f @ %gm | soil #%d %s | PF %s | frozen %s",
                tonumber(impact.x) or 0, tonumber(impact.z) or 0,
                tonumber(impact.inputCellSize) or 0,
                tonumber(impact.soilTypeIndex) or 0,
                tostring(impact.soilName or "Generic"),
                impact.pfActive and "ACTIVE" or "generic fallback",
                impact.surfaceFrozen and "YES" or "no")
            lines[#lines + 1] = string.format(
                "Moisture surface/subsoil/liquid %.2f/%.2f/%.2f%% | dry/wet severity %.2f/%.2f%%",
                (tonumber(impact.moistureSurface) or 0) * 100,
                (tonumber(impact.moistureSubsoil) or 0) * 100,
                (tonumber(impact.liquidSurface) or 0) * 100,
                (tonumber(impact.drySeverity) or 0) * 100,
                (tonumber(impact.wetSeverity) or 0) * 100)
            lines[#lines + 1] = string.format(
                "Texture response surface/deep x%.3f/x%.3f | moisture traffic x%.3f/x%.3f",
                tonumber(impact.textureSurfaceMultiplier) or 1,
                tonumber(impact.textureDeepMultiplier) or 1,
                tonumber(impact.trafficSurfaceMultiplier) or 1,
                tonumber(impact.trafficDeepMultiplier) or 1)
            lines[#lines + 1] = string.format(
                "Resilience %.2f%% -> susceptibility x%.3f | field confirmed %s",
                (tonumber(impact.resilience) or 0) * 100,
                tonumber(impact.resilienceTrafficMultiplier) or 1,
                impact.fieldConfirmed and "YES" or "surface query")
        else
            lines[#lines + 1] = "No accepted field impact for this entity yet"
        end
        lines[#lines + 1] = "--- COMPACTION MODEL ---"
        lines[#lines + 1] =
            "Surface pressure curve | below 50 kPa target 30-47% with cubic strength -> existing 50-300 kPa curve"
        if diagnostic.workingImplementSurfaceSuppressed == true then
            lines[#lines + 1] = string.format(
                "Working implement surface traffic SUPPRESSED | contacts %d | strongest wheel #%d %s | %.3f t @ %.1f kPa | avoided target/strength %.2f%%/%.4f",
                tonumber(diagnostic.suppressedSurfaceContacts) or 0,
                tonumber(diagnostic.maxSuppressedWheelIndex) or 0,
                tostring(diagnostic.maxSuppressedWheelNodeName or "unknown"),
                tonumber(diagnostic.maxSuppressedWheelLoadT) or 0,
                tonumber(diagnostic.maxSuppressedPressureKPa) or 0,
                (tonumber(diagnostic.maxSuppressedSurfaceTarget) or 0) * 100,
                tonumber(diagnostic.maxSuppressedSurfaceStrength) or 0)
        else
            lines[#lines + 1] =
                "Surface traffic ACTIVE | tool raised, folded, transporting or not soil-working"
        end
        lines[#lines + 1] = string.format(
            "Surface target %.2f%% | maximum applied strength %.3f | pressure target input %.2f%% | last mode %s",
            (tonumber(diagnostic.maxSurfaceTargetApplied) or 0) * 100,
            tonumber(diagnostic.maxSurfaceStrengthApplied) or 0,
            (impact ~= nil and tonumber(impact.surfaceTarget) or 0) * 100,
            impact ~= nil and impact.surfaceLowPressureResponse == true
                and "continuous <50 kPa" or "standard")
        lines[#lines + 1] = string.format(
            "Deep target %.2f%% | base/applied strength %.4f/%.4f | maximum axle %.2f t",
            (tonumber(diagnostic.maxDeepTarget) or 0) * 100,
            tonumber(diagnostic.maxDeepStrength) or 0,
            tonumber(diagnostic.maxDeepStrengthApplied) or 0,
            tonumber(diagnostic.maxAxleLoad) or 0)
        lines[#lines + 1] = string.format(
            "Deep track coverage tick mean/max %.2f/%.2f%% | width mean %.3f m | samples %d",
            (tonumber(diagnostic.meanDeepCoverage) or 0) * 100,
            (tonumber(diagnostic.maximumDeepCoverage) or 0) * 100,
            tonumber(diagnostic.meanDeepStressWidth) or 0,
            tonumber(diagnostic.deepCoverageSamples) or 0)
        lines[#lines + 1] = string.format(
            "Last deep track coverage %.2f%% | stress width %.3f m | age %.2fs",
            (tonumber(diagnostic.lastDeepCoverage) or 0) * 100,
            tonumber(diagnostic.lastDeepStressWidth) or 0,
            math.max(now - (tonumber(diagnostic.lastDeepCoverageTime)
                or now), 0) / 1000)
        lines[#lines + 1] = "--- TILTH / EVENNESS MODEL ---"
        if impact ~= nil then
            lines[#lines + 1] = string.format(
                "Mode %s | structure pass %s | pressure driver %.3f | local load %.3f t @ %.1f kPa",
                tostring(impact.structureMode or "none"),
                impact.structurePass and "YES" or "no",
                tonumber(impact.structurePressureDriver) or 0,
                tonumber(impact.wheelLoadT) or 0,
                tonumber(impact.pressureKPa) or 0)
            lines[#lines + 1] = string.format(
                "Local tyre width/diameter/contact %.3f/%.3f/%.3f m | tyres in contact representation %d | crawler %s",
                tonumber(impact.tireWidthM) or 0,
                tonumber(impact.tireDiameterM) or 0,
                tonumber(impact.contactLengthM) or 0,
                tonumber(impact.tireCount) or 0,
                impact.crawler and "YES" or "no")
            lines[#lines + 1] = string.format(
                "Local wheel #%d %s | rest load %.3f t | visual tyres %d | tyre source %s",
                tonumber(impact.wheelIndex) or 0,
                tostring(impact.wheelNodeName or "unknown"),
                tonumber(impact.wheelRestLoadT) or 0,
                tonumber(impact.wheelVisualCount) or 0,
                impact.wheelExternalFilename ~= nil
                    and impact.wheelExternalFilename ~= ""
                    and tostring(impact.wheelExternalFilename)
                    or "inline physics")
            lines[#lines + 1] = string.format(
                "Tilth target/strength %s/%.4f | Evenness raw target/strength %s/%.4f",
                impact.aggregateTarget ~= nil
                    and string.format("%.2f%%", impact.aggregateTarget * 100)
                    or "inactive",
                tonumber(impact.aggregateStrength) or 0,
                impact.roughnessTarget ~= nil
                    and string.format("%.2f%%", impact.roughnessTarget * 100)
                    or "inactive",
                tonumber(impact.roughnessStrength) or 0)
        else
            lines[#lines + 1] = "No two-metre structure pass recorded"
        end
        lines[#lines + 1] = "--- LAST ACCEPTED CELL: BEFORE -> AFTER (DELTA PP) ---"
        local layerOrder = {
            {"surfaceCompaction", "Surface compaction"},
            {"deepCompaction", "Deep compaction"},
            {"aggregateSize", "Tilth raw (coarse 0 / crumb 50 / fine 100)"},
            {"roughness", "Evenness raw (roughness)"},
            {"resilience", "Resilience"}
        }
        for _, entry in ipairs(layerOrder) do
            local id, label = entry[1], entry[2]
            lines[#lines + 1] = string.format(
                "%s | %.3f -> %.3f%% | dCell %+.4f pp | tick sum %+.4f pp maxAbs %.4f | changed tick/total %d/%d",
                label,
                (tonumber(before[id]) or 0) * 100,
                (tonumber(after[id]) or 0) * 100,
                (tonumber(delta[id]) or 0) * 100,
                (tonumber(tickDelta[id]) or 0) * 100,
                (tonumber(maxDelta[id]) or 0) * 100,
                tonumber(changed[id]) or 0,
                tonumber(totalChanged[id]) or 0)
            if impact ~= nil and TerraLogicSoilManager ~= nil
                and TerraLogicSoilManager.getLayerDebugAtWorldPosition
                    ~= nil then
                local mapState = TerraLogicSoilManager:getLayerDebugAtWorldPosition(
                    id, impact.x, impact.z)
                if mapState ~= nil then
                    lines[#lines + 1] = string.format(
                        "  Map effective/raster %.3f/%.3f%% | raw/expected %d/%d | %s | source %s",
                        (tonumber(mapState.effective) or 0) * 100,
                        (tonumber(mapState.rasterValue) or 0) * 100,
                        tonumber(mapState.raw) or 0,
                        tonumber(mapState.expectedRaw) or 0,
                        mapState.rasterMatches and "MATCH" or "pending quantization",
                        tostring(mapState.source or "raster"))
                end
            end
        end
        lines[#lines + 1] = "--- SAMPLING / DEDUPLICATION ---"
        lines[#lines + 1] = string.format(
            "Impact cells this tick total %d | surface 1m %d | structure 2m %d | deep 2m %d | changed %d",
            tonumber(diagnostic.impactCount) or 0,
            tonumber(counts[1]) or 0,
            tonumber(counts[2]) or 0,
            tonumber(counts[4]) or 0,
            tonumber(diagnostic.changedCells) or 0)
        lines[#lines + 1] = string.format(
            "Session cells impact/structure/changed %d/%d/%d | update interval %d ms | structure once per 2m passage",
            tonumber(diagnostic.totalImpactCells) or 0,
            tonumber(diagnostic.totalStructureCells) or 0,
            tonumber(diagnostic.totalChangedCells) or 0,
            tonumber(TerraLogicWheelCompactionManager.UPDATE_INTERVAL_MS) or 0)
        lines[#lines + 1] = "CSV: tlTestStart traffic <name> | stop with tlTestStop"
        self.trafficDebugLines = lines
        self.trafficDebugNextRefresh = now + 1000
    end
    renderDebugPanel(self.trafficDebugLines)
end

function TerraLogicMain:mouseEvent(x, y, isDown, isUp, button)
    TerraLogicTutorialManager:mouseEvent(x, y, isDown, isUp, button)
end

function TerraLogicMain:draw()
    if g_currentMission ~= nil then
        self:drawSpeedHud()
        self:drawQualityHud()
        TerraLogicTutorialManager:draw()
    end
    if not self.debugEnabled or g_currentMission == nil then
        return
    end
    if self.debugMode == "workquality" then
        self:drawWorkQualityDebug()
        return
    end
    if self.debugMode == "balancing" then
        self:drawBalancingDebug()
        return
    end
    if self.debugMode == "soil" then
        self:drawSoilDebug()
        return
    end
    if self.debugMode == "soilprocess" then
        self:drawSoilProcessDebug()
        return
    end
    if self.debugMode == "traffic" then
        self:drawTrafficDebug()
        return
    end
    if TerraLogicAuditManager ~= nil
        and TerraLogicAuditManager:isAuditView(self.debugMode) then
        renderDebugPanel(TerraLogicAuditManager:getPanelLines(
            self.debugMode, self))
        return
    end

    local implement = self:getDebugImplement(
        self.debugMode == "damageanalysis")
    if implement == nil then
        renderDebugPanel({"TerraLogic DEBUG", "No supported implement selected/working"})
        return
    end

    local now = g_currentMission.time or 0
    if self.debugLines == nil
        or self.debugLineImplement ~= implement
        or self.debugLineMode ~= self.debugMode
        or now >= (self.debugNextRefresh or 0) then
        local data = implement:getOverSpeedDebugData()
        local wearDifference = nil
        if data.vanillaDamagePerHectare ~= nil and data.vanillaDamagePerHectare > 0
            and data.continuousDamagePerHectare ~= nil then
            wearDifference = (data.continuousDamagePerHectare / data.vanillaDamagePerHectare - 1) * 100
        end

        local state = data.modEnabled and (data.telemetryWorking and "WORKING" or "PAUSED") or "MOD DISABLED"
        local recommendedSpeed = tonumber(data.optimalSpeed) or tonumber(data.ratedSpeed) or 0
        local ratedSpeed = tonumber(data.ratedSpeed) or recommendedSpeed
        local currentSpeed = tonumber(data.speed) or 0
        local damageAnalysis = data.damageAnalysis or {}
        local damageAnalysisTotal = math.max(
            tonumber(data.damageAnalysisTotal) or 0, 0)
        local function formatDamageCause(label, amount, suffix)
            local value = math.max(tonumber(amount) or 0, 0)
            local share = damageAnalysisTotal > 0
                and value / damageAnalysisTotal * 100 or 0
            return string.format("%s | %.4f%% damage | %.1f%% of recorded%s",
                label, value * 100, share, suffix or "")
        end
        local elapsedSeconds = math.floor(
            math.max(tonumber(damageAnalysis.elapsedMs) or 0, 0) / 1000)
        local workingSeconds = math.floor(
            math.max(tonumber(damageAnalysis.workingMs) or 0, 0) / 1000)
        local lines = {
            string.format("TerraLogic %s | %s | %s | %s",
                string.upper(self.debugMode or "overview"),
                data.name, state, data.groundToolType),

            "--- SPEED / IMPLEMENT ---",
            string.format("Speed %.1f km/h | class realistic %.1f | safe %.1f (%.0f%% shop) | shop %.1f | damage %.2f%%",
                currentSpeed, recommendedSpeed, data.safeSpeed,
                data.safeSpeedRatio * 100, ratedSpeed, data.damagePercent),
            string.format("Classification | %s | store %s | via %s",
                data.groundToolType, data.storeCategory, data.classificationSource),
            string.format("NEXAT module | %s | kind %s",
                data.isNexatModule and "YES" or "NO",
                tostring(data.nexatModuleKind)),
            string.format("Speed-limit unlock | %s | %s",
                data.speedLimitUnlockEligible and "ELIGIBLE" or "INACTIVE",
                data.speedLimitUnlockSource),
            string.format("Safe resolver | %s | shop/class %s | valid window %.2f-%.2f%s",
                data.safeSpeedSource,
                formatNumber(data.shopToClassSpeedFactor, 2),
                data.wearClassShopFactorMin, data.wearClassShopFactorMax,
                data.safeSpeedFallback and " | FALLBACK ACTIVE" or ""),
            string.format("Assumed work depth %.0f cm | impact-frequency depth factor x%.2f",
                data.workDepthCm, data.impactDepthFactor),
            string.format("Whole-yield quality | weight %.1f%% | operation cap %.1f%%",
                data.yieldWeight * 100, data.maxYieldPenalty * 100),
            string.format("Mechanical load | protection %s | current %.1f%% | safe %.1f%% | trip %.1f%% | events %d | structural damage %.4f%%",
                data.structuralProtection,
                data.structuralLoadPercent,
                data.structuralSafeRatio * 100,
                data.structuralTripRatio * 100,
                data.structuralOverloadEventCount,
                data.structuralOverloadDamagePercent),

            "--- DAMAGE ANALYSIS ---",
            string.format("Session %02d:%02d | working %02d:%02d | distance %.1fm | recorded damage %.4f%%",
                math.floor(elapsedSeconds / 60), elapsedSeconds % 60,
                math.floor(workingSeconds / 60), workingSeconds % 60,
                tonumber(damageAnalysis.distanceM) or 0,
                damageAnalysisTotal * 100),
            formatDamageCause("General continuous wear",
                damageAnalysis.generalWear),
            formatDamageCause("Soil abrasion",
                damageAnalysis.soilAbrasion),
            formatDamageCause("Load / throughput wear",
                damageAnalysis.overspeedWear),
            formatDamageCause("Simulated underground: small",
                damageAnalysis.undergroundSmall,
                string.format(" | %d hits",
                    damageAnalysis.undergroundSmallCount or 0)),
            formatDamageCause("Simulated underground: medium",
                damageAnalysis.undergroundMedium,
                string.format(" | %d hits",
                    damageAnalysis.undergroundMediumCount or 0)),
            formatDamageCause("Simulated underground: large",
                damageAnalysis.undergroundBig,
                string.format(" | %d hits",
                    damageAnalysis.undergroundBigCount or 0)),
            formatDamageCause("Real map stones: small",
                damageAnalysis.mapSmall,
                string.format(" | %d hits",
                    damageAnalysis.mapSmallCount or 0)),
            formatDamageCause("Real map stones: medium",
                damageAnalysis.mapMedium,
                string.format(" | %d hits",
                    damageAnalysis.mapMediumCount or 0)),
            formatDamageCause("Real map stones: large",
                damageAnalysis.mapBig,
                string.format(" | %d hits",
                    damageAnalysis.mapBigCount or 0)),
            string.format("Real-map origin | existing %.4f%% | generated during work %.4f%%",
                (tonumber(damageAnalysis.mapExisting) or 0) * 100,
                (tonumber(damageAnalysis.mapGenerated) or 0) * 100),
            data.damageAnalysisVisibleStoneExact
                and string.format("Visible-stone attribution | EXACT TerraLogic path | %s",
                    data.visibleStoneDamageSource)
                or string.format("Visible-stone attribution | VANILLA-OWNED, not separable from continuous wear | %s",
                    data.visibleStoneDamageSource),

            "--- WORK QUALITY ---",
            data.isSowingMachine and string.format(
                "Seed work Q %.1f%% | retained placement %.1f%% | direct yield loss %.1f%% | weight %.1f%% cap %.1f%%",
                data.seedWorkQuality * 100, data.seedQuality * 100,
                data.seedYieldPenalty * 100, data.yieldWeight * 100,
                data.maxYieldPenalty * 100)
                or "Seed quality | not a sowing machine / planter",
            data.isSowingMachine and string.format(
                "Seed pattern | fruit %s | %s | mode %s | skipped lanes %d/%d | full-width chance %.2f%% | post-clear pixels %d",
                data.seedQualityFruit, data.seedQualityStatus,
                data.seedQualityPatternMode, data.seedQualityPatternLanes,
                data.seedQualityLaneCap, data.seedQualityFullWidthChance * 100,
                data.seedQualityPostClearPixels)
                or "Seed pattern | inactive",
            data.isSowingMachine and string.format(
                "Seed patch | WorkArea depth %.2f m | lane width %.2f m | hold %.2f m (%.2f remaining) | missed %.1f%% | %s",
                data.seedQualityWorkAreaDepthM,
                data.seedQualityEffectiveLaneWidthM,
                data.seedQualityHoldDistanceM,
                data.seedQualityHoldRemainingM,
                data.seedQualityMissedFraction * 100,
                data.seedQualityLatchReused and "LATCHED" or "NEW SAMPLE")
                or "Seed patch | inactive",
            data.isApplicationTool and string.format(
                "Application quality %.1f%% | health %.1f%% | missed-area threshold %.1f km/h (damage shift -%.1f) | speed penalty %.1f%%",
                data.applicationQuality * 100, data.applicationQualityHealth * 100,
                data.applicationQualityThresholdSpeed,
                data.applicationQualityThresholdShift,
                data.applicationQualitySpeedPenalty * 100)
                or "Application quality | not a sprayer / spreader",
            data.isApplicationTool and string.format(
                "Application pattern | profile %s | mode %s | fill %s | %s | processed lanes %d | skipped lanes %d",
                data.applicationQualityProfile, data.applicationQualityPatternMode,
                data.applicationQualityFillType, data.applicationQualityStatus,
                data.applicationQualityProcessedLanes,
                data.applicationQualitySkippedLanes)
                or "Application pattern | inactive",
            data.isSoilRoller and string.format(
                "Roller rollback %.2f%% | %s | removed seed pixels %d",
                data.rollerQualityFailure * 100, data.rollerQualityStatus,
                data.rollerQualityFailedPixels)
                or "Roller rollback | not a soil roller",
            data.impactDropoutProfile ~= "none" and string.format(
                "Mechanical missed area | profile %s | %s",
                data.impactDropoutProfile, data.impactDropoutStatus)
                or "Mechanical missed area | unsupported for this class",
            data.impactDropoutProfile ~= "none" and string.format(
                "Overspeed plow surface | expected %.2f patches/100 m | last %d patch(es), %d extended, %d px",
                data.impactDropoutThrowEventsPer100m,
                data.plowIrregularLastPassEvents,
                data.plowIrregularLastTwoPixelEvents,
                data.plowIrregularLastPixels)
                or "Overspeed plow surface | inactive",
            data.impactDropoutProfile ~= "none" and string.format(
                "Density raster | terrain %.0f m | detail %.0f px | %.3f m/px (%.2fx linear) | miss frequency x%.3f | %s",
                data.plowDensityTerrainSizeM,
                data.plowDensityDetailMapSize,
                data.plowDensityPixelSizeM,
                data.plowDensityLinearScale,
                data.plowDropoutResolutionFactor,
                data.plowDensityResolutionSource)
                or "Density raster | inactive",
            data.impactDropoutProfile ~= "none" and string.format(
                "Tripped segments %d/%d | tier %s | recovery %.2f/%.2f m remaining/hold",
                data.impactDropoutFailedLanes,
                data.impactDropoutTotalLanes,
                data.impactDropoutLastTier,
                data.impactDropoutRemainingDistanceM,
                data.impactDropoutHoldDistanceM)
                or "Mechanical recovery | inactive",
            data.impactDropoutProfile ~= "none" and string.format(
                "Stone work result | below/equal shop: damage only | above shop: one 1x2 patch (%d px) with previous PLOW_LEVEL",
                data.impactVisualOnlyPixels)
                or "Stone work result | inactive",
            data.impactDropoutProfile ~= "none" and string.format(
                "Mechanical totals | triggers %d (throw %d / medium %d / big %d) | missed %.5f ha | width-weighted distance %.1f m",
                data.impactDropoutTriggerCount,
                data.impactDropoutThrowCount,
                data.impactDropoutMediumCount,
                data.impactDropoutBigCount,
                data.impactDropoutMissedAreaHa,
                data.impactDropoutMissedDistanceM)
                or "Mechanical totals | inactive",
            data.impactDropoutProfile ~= "none" and string.format(
                "Plow hook | %s | rebound %d | visual effects: %s",
                data.plowDropoutHookActive and "ACTIVE" or "NOT CALLED",
                data.workAreaFunctionsRebound,
                data.plowVisualEffectStatus)
                or "Plow visual effects | inactive",

            "--- CONTINUOUS WEAR ---",
            string.format("Curve anchors | reference %.1f km/h = x%.2f | shop %.1f km/h = x%.2f",
                data.safeSpeed, data.wearAtSafeSpeed,
                ratedSpeed, data.wearAtShopSpeed),
            string.format("Curve shape | smooth real-to-shop Hermite + shifted cubic excess | exponents %.2f / %.2f | vehicle/shop ratio x%.2f",
                data.wearBelowShopExponent, data.wearAboveShopExponent,
                data.shopSpeedRatio),
            string.format("Runtime wear x%.3f | speed curve x%.2f | effective total x%.2f | %s",
                data.wearRuntimeMultiplier, data.speedDamageMultiplier,
                data.totalDamageMultiplier,
                data.wearSpeedApplicationActive and "ACTIVE WORK" or "PAUSED / TRANSPORT"),
            string.format("Wear baseline | policy %s | XML %.1f min (rate x%.3f) | reference %.0f min%s",
                data.wearPolicy, data.xmlWearDurationMinutes,
                data.xmlWearRateFactor, data.referenceWearDurationMinutes,
                data.customWearRateDetected and " | EXTREME CUSTOM RATE" or ""),
            string.format("Age/usage damage | Vanilla x%.3f -> TerraLogic x%.3f | full operating-age at %.0f h",
                data.vanillaAgeUsageFactor,
                data.adjustedAgeUsageFactor,
                data.ageUsageFullHours),
            data.wearModel == "surface"
                and string.format("Surface wear | PF abrasion ignored | Vanilla/XML baseline x%.3f | above shop: speed ratio cubed",
                    data.baselineAbrasionMultiplier)
                or string.format("Abrasion model | general %.0f%% + abrasive %.0f%% | tool x%.2f | soil x%.2f | load x%.3f | safe baseline x%.3f",
                    (1 - data.abrasiveShare) * 100, data.abrasiveShare * 100,
                    data.implementAbrasionFactor, data.abrasionMultiplier,
                    data.abrasiveLoad, data.baselineAbrasionMultiplier),
            data.wearSpeedApplicationActive
                and string.format("Speed application | curve x%.3f scales complete class/soil baseline x%.3f",
                    data.speedDamageMultiplier, data.baselineAbrasionMultiplier)
                or "Speed application | INACTIVE: raised/not working; TerraLogic adds no speed wear (Vanilla wear remains Vanilla-owned)",
            string.format("Continuous damage/ha | Vanilla %s%% | TerraLogic %s%% | difference %s%%",
                formatNumber(data.vanillaDamagePerHectare ~= nil and data.vanillaDamagePerHectare * 100 or nil, 3),
                formatNumber(data.continuousDamagePerHectare ~= nil and data.continuousDamagePerHectare * 100 or nil, 3),
                wearDifference ~= nil and string.format("%+.1f", wearDifference) or "n/a"),
            string.format("Total live wear | actual %s%%/ha | %s%%/10km | normalized @ %.1fm %s%%/ha",
                formatNumber(data.currentDamagePerHectare ~= nil and data.currentDamagePerHectare * 100 or nil, 3),
                formatNumber(data.currentDamagePer10Km ~= nil and data.currentDamagePer10Km * 100 or nil, 3),
                data.normalizedReferenceWidth,
                formatNumber(data.normalizedDamagePerHectare ~= nil and data.normalizedDamagePerHectare * 100 or nil, 3)),
            string.format("Continuous normalized | Vanilla %s%%/ha | TerraLogic %s%%/ha | TerraLogic/Vanilla %s x",
                formatNumber(data.normalizedVanillaDamagePerHectare ~= nil
                    and data.normalizedVanillaDamagePerHectare * 100 or nil, 3),
                formatNumber(data.normalizedContinuousDamagePerHectare ~= nil
                    and data.normalizedContinuousDamagePerHectare * 100 or nil, 3),
                formatNumber(data.continuousVsVanillaMultiplier, 2)),
            string.format("Live rate | total %.3f%%/h | estimated Vanilla %s%%/h | total/Vanilla %s x",
                data.damageRatePercentPerHour,
                formatNumber(data.vanillaDamageRatePercentPerHour, 3),
                formatNumber(data.totalVsVanillaMultiplier, 2)),

            "--- DRAFT / RESISTANCE ---",
            string.format("Shared draft curve | x1 through shop | strength %.2f | exponent %.2f | cap x%.2f",
                data.draftSpeedStrength, data.draftSpeedExponent, data.draftSpeedMaximum),
            string.format("Additional draft %s | profile scale x%.2f | depth response %.1f%% | global %s | runtime x%.3f | current x%.3f",
                data.additionalDraftEnabled and "ELIGIBLE" or "EXCLUDED",
                data.additionalDraftScale, data.draftDepthResponse * 100,
                data.globalDraftEnabled and "ON" or "OFF",
                data.draftRuntimeMultiplier, data.speedDraftMultiplier),
            string.format("Normalized drawbar-power proxy | speed ratio %.2f x draft %.3f = %.3f",
                ratedSpeed > 0 and currentSpeed / ratedSpeed or 0,
                data.speedDraftMultiplier,
                (ratedSpeed > 0 and currentSpeed / ratedSpeed or 0) * data.speedDraftMultiplier),
            string.format("MaxForce | original %.2f | PF-only %.2f | wear x%.3f (curve %.2f, full at %.0f%%, runtime x%.2f) | final %.2f kN",
                data.baseMaxForce, data.soilMaxForce, data.damageResistanceMultiplier,
                data.damageResistanceExponent, data.damageResistanceFullAt * 100,
                data.damageResistanceRuntimeMultiplier, data.projectedMaxForce),

            "--- SOIL INPUTS ---",
            string.format("PF soil | #%d %s", data.soilTypeIndex, data.soilName),
            string.format("PF/raw abrasion x%.3f | %s", data.abrasionMultiplier, data.abrasionSource),
            data.wearModel == "surface"
                and string.format("Surface wear | soil abrasion bypassed | Vanilla/XML baseline x%.3f",
                    data.baselineAbrasionMultiplier)
                or string.format("Implement abrasion x%.3f | abrasive share %.0f%% | tool x soil load %.3f | baseline x%.3f",
                    data.implementAbrasionFactor, data.abrasiveShare * 100,
                    data.abrasiveLoad, data.baselineAbrasionMultiplier),
            string.format("Resistance raw x%.3f -> depth-adjusted x%.3f | %s",
                data.rawSoilResistanceMultiplier,
                data.soilResistanceMultiplier, data.resistanceSource),
            string.format("TL state x%.3f + wear => x%.3f | base PF/state/wear/moisture envelope x%.3f (%.2f..%.2f) | sample %s",
                data.persistentSoilDraftMultiplier,
                data.stateWearDraftMultiplier,
                data.baseEnvironmentDraftMultiplier,
                data.environmentDraftMinimum,
                data.environmentDraftMaximum,
                data.persistentSoilPositionSource),
            string.format("Moisture %s | %.1f%% surface / %.1f%% subsoil => %.1f%% effective | dry %.0f%% wet %.0f%%",
                data.moistureProfileName,
                data.moistureSurface * 100,
                data.moistureSubsoil * 100,
                data.moistureEffective * 100,
                data.moistureDrySeverity * 100,
                data.moistureWetSeverity * 100),
            string.format("Moisture mechanics | theoretical draft x%.3f | applied x%.3f | WQ ceiling %.1f%% | soil effect %.1f%% | missed area %.1f%%",
                data.moistureDraftMultiplier,
                data.moistureAppliedDraftMultiplier,
                data.moistureQualityFactor * 100,
                data.moistureSoilEffectiveness * 100,
                data.moistureDropoutFraction * 100),
            string.format("Frost mechanics | severity %.1f%% (surface %.1f%% / deep %.1f%%) | draft x%.3f | penetration %.1f%% | WQ %.1f%% | missed area %.1f%%",
                data.frostSeverity * 100,
                data.frostSurfaceSeverity * 100,
                data.frostSubsoilSeverity * 100,
                data.frostDraftMultiplier,
                data.frostPenetrationFactor * 100,
                data.frostQualityFactor * 100,
                data.frostDropoutFraction * 100),
            string.format("Draft composition | base environment x%.3f + frost excess %.3f => x%.3f (frost cap x%.2f), then speed x%.3f",
                data.baseEnvironmentDraftMultiplier,
                math.max(data.frostDraftMultiplier - 1, 0),
                data.environmentDraftMultiplier,
                data.frostEnvironmentDraftMaximum,
                data.speedDraftMultiplier),
            string.format("Ground engagement | %s at x%.2f reference speed | soil effect %.1f%% | draft retention %.1f%% | abrasion contact %.1f%% | collapse %.2fx->%.1f%%",
                tostring(data.engagementState),
                data.engagementSpeedRatio,
                data.engagementFactor * 100,
                data.engagementDraftRetention * 100,
                data.engagementAbrasionContact * 100,
                data.engagementFailedRatio,
                data.engagementMinimum * 100),

            "--- RANDOM IMPACTS (ABSTRACT / HIDDEN) ---",
            string.format("Status %s | frequency runtime x%.3f | damage runtime x%.3f",
                data.randomImpactsEnabled and "ON" or "OFF",
                data.randomFrequencyRuntimeMultiplier, data.randomDamageRuntimeMultiplier),
            string.format("Reference depth %.0fcm = %.1f/ha | actual depth %.0fcm x%.3f => active %.1f/ha",
                data.impactReferenceDepthCm, data.soilImpactEventsPerHa,
                data.workDepthCm, data.impactDepthFactor,
                data.impactRiskEventsPerHa),
            string.format("Area scaling | width %.2fm | active %.1f/ha => expected %.2f hits/km",
                data.workingWidth or 0, data.impactRiskEventsPerHa,
                data.impactRiskEventsPerKm),
            string.format("Linear depth frequency x%.3f | small %.2f/ha | medium %.3f/ha | big %.3f/ha",
                data.impactDepthFactor, data.impactSmallEventsPerHa,
                data.impactMediumEventsPerHa, data.impactBigEventsPerHa),
            string.format("Stone model | underground %s | vanilla %s | speed %s | rotation %s",
                data.impactUndergroundEnabled and "YES" or "NO",
                data.impactVanillaEnabled and "YES" or "NO",
                data.impactUsesWorkSpeed and "YES" or "NO",
                data.impactUsesRotation and "YES" or "NO"),
            string.format("Uniform impact model | overspeed-only %s | underground map factor x%.2f",
                data.impactOverspeedOnly and "YES" or "NO",
                data.undergroundVisibleStoneFactor),
            string.format("Tier shares | small %.2f%% | medium %.2f%% | big %.3f%%",
                data.impactSmallProbability * 100, data.impactMediumProbability * 100,
                data.impactBigProbability * 100),
            string.format("Energy x%.2f | raw excess x%.2f -> scaled x%.3f | PF severity x%.2f | damage last second %.3f%%",
                data.impactEnergy, data.excessImpactEnergy,
                data.scaledExcessImpactEnergy, data.impactSeverityFactor,
                data.randomImpactDamageLastSecondPercent),
            string.format("Max damage now | small %.2f%% | medium %.2f%% | big %.2f%%",
                data.impactSmallMaximumDamagePercent,
                data.impactMediumMaximumDamagePercent,
                data.impactBigMaximumDamagePercent),
            string.format("Expected damage/ha now | small %.2f%% | medium %.2f%% | big %.2f%% | total %.2f%%",
                data.impactSmallExpectedDamagePerHaPercent,
                data.impactMediumExpectedDamagePerHaPercent,
                data.impactBigExpectedDamagePerHaPercent,
                data.impactSmallExpectedDamagePerHaPercent
                    + data.impactMediumExpectedDamagePerHaPercent
                    + data.impactBigExpectedDamagePerHaPercent),
            string.format("Hits S/M/B %d/%d/%d | last %s %s%% (%ss ago)",
                data.impactSmallCount, data.impactMediumCount, data.impactBigCount,
                data.lastImpactTier, formatNumber(data.lastImpactDamagePercent, 1),
                formatNumber(data.lastImpactSecondsAgo, 0)),

            "--- REAL STONE MAP IMPACTS ---",
            string.format("Status %s | map %s | tool mode %s",
                data.stoneImpactsEnabled and "ON" or "OFF",
                data.stoneSystemActive and "ACTIVE" or data.stoneSystemStatus,
                data.stoneToolMode),
            string.format("Vanilla range %d..%d | area state %d | field coverage %.1f%%",
                data.stoneMapMinValue, data.stoneMapMaxValue,
                data.stoneLastVanillaAreaState,
                data.stoneLastFieldCoveragePercent),
            string.format("Surface factor x%.3f (runtime x%.3f) | generation factor x%.3f (runtime x%.3f)",
                data.stoneSurfaceFactor, data.stoneSurfaceRuntimeMultiplier,
                data.stoneGenerationFactor, data.stoneGeneratedRuntimeMultiplier),
            string.format("Map | level %.2f raw/effective coverage %.2f%%/%.1f%% | generated %.5f ha",
                data.stoneExistingLevel, data.stoneExistingCoveragePercent,
                data.stoneEffectiveCoveragePercent,
                data.stoneGeneratedWeightedHaLastSecond),
            string.format("Exposure S/M/B %.3f/%.3f/%.3f | next %.3f/%.3f/%.3f",
                data.stoneVisibleExposureSmall,
                data.stoneVisibleExposureMedium,
                data.stoneVisibleExposureBig,
                data.stoneVisibleThresholdSmall,
                data.stoneVisibleThresholdMedium,
                data.stoneVisibleThresholdBig),
            string.format("Result hits S/M/B %d/%d/%d | big-source mix 70%%/25%%/5%%",
                data.stoneVisibleResultSmallCount,
                data.stoneVisibleResultMediumCount,
                data.stoneVisibleResultBigCount),
            string.format("Damage last second | surface %.3f%% | generated %.3f%% | total %.3f%% | scans %d",
                data.stoneSurfaceDamageLastSecondPercent,
                data.stoneGeneratedDamageLastSecondPercent,
                data.stoneDamageLastSecondPercent, data.stoneScansLastSecond),
            string.format("Last real-stone event | %s | %s%% (%ss ago)",
                data.lastStoneEventSource,
                formatNumber(data.lastStoneEventDamagePercent, 3),
                formatNumber(data.lastStoneEventSecondsAgo, 1)),

            "--- LIFETIME / COST ---",
            string.format("Measured damage/ha (last second) | %s%%",
                formatNumber(data.currentDamagePerHectare ~= nil and data.currentDamagePerHectare * 100 or nil, 3)),
            string.format("Projected damage/ha | %.3f%% (continuous + expected random + measured real stones)",
                (data.projectedDamagePerHectare or 0) * 100),
            string.format("Live total damage rate | %.2f%%/h", data.damageRatePercentPerHour),
            string.format("Projected lifetime | %s ha to 100%% | repair/ha %s",
                formatNumber(data.projectedHectaresToFullDamage, 2),
                data.repairCostPerHectare ~= nil and g_i18n:formatMoney(data.repairCostPerHectare, 0, true, false) or "n/a"),
            string.format("Distance lifetime | %s km to 100%% | working width %.2f m",
                formatNumber(data.kilometersToFullDamage, 1), data.workingWidth or 0),
            string.format("Repair comparison | measured/ha %s | projected/10km %s | projected @ %.1fm/ha %s",
                data.measuredRepairCostPerHectare ~= nil
                    and g_i18n:formatMoney(data.measuredRepairCostPerHectare, 0, true, false) or "n/a",
                data.repairCostPer10Km ~= nil
                    and g_i18n:formatMoney(data.repairCostPer10Km, 0, true, false) or "n/a",
                data.normalizedReferenceWidth,
                data.normalizedRepairCostPerHectare ~= nil
                    and g_i18n:formatMoney(data.normalizedRepairCostPerHectare, 0, true, false) or "n/a"),
            string.format("Repair | now %s | at 100%% %s",
                g_i18n:formatMoney(data.currentRepairCost or 0, 0, true, false),
                g_i18n:formatMoney(data.fullRepairCost or 0, 0, true, false))
        }

        if self.debugMode == "technical" then
            lines[#lines + 1] = "--- TECHNICAL ---"
            lines[#lines + 1] = string.format("TECH | workArea=%s via %s | width=%sm | PF=%s:%s",
                data.workAreaProcessing and "ACTIVE" or "INACTIVE", data.workDetectionSource,
                formatNumber(data.workingWidth, 1),
                string.upper(data.pfMode), data.pfActive and "ACTIVE" or "INACTIVE")
            lines[#lines + 1] = string.format("PF query %s ok=%s soil=%d via %s",
                data.pfLastPositionSource, data.pfLastQueryOk and "YES" or "NO",
                data.pfLastSoilTypeIndex, data.pfSoilValueSource)
            lines[#lines + 1] = string.format("PF source: %s | actual maxForce %.2f kN",
                data.pfSource, data.modifiedMaxForce)
            lines[#lines + 1] = string.format("Wear compatibility | %s | XML %.1fmin rate x%.3f | ref %.0fmin | custom=%s",
                data.wearPolicy, data.xmlWearDurationMinutes,
                data.xmlWearRateFactor, data.referenceWearDurationMinutes,
                data.customWearRateDetected and "EXTREME" or "normal")
            lines[#lines + 1] = string.format("QUALITY TECH | rebound=%d | seed hook=%s | density filter=%s calls=%d",
                data.workAreaFunctionsRebound,
                data.seedQualityHookActive and "ACTIVE" or "NOT CALLED",
                data.seedQualityDensityHookActive and "ACTIVE" or "NOT CALLED",
                data.seedQualityDensityCalls)
            lines[#lines + 1] = string.format("STONE TECH | scans/s=%d | existing weighted=%.5f ha | generated delta pixels=%.1f | last scan generated=%.5f ha",
                data.stoneScansLastSecond, data.stoneExistingWeightedHaLastSecond,
                data.stoneGeneratedLevelDelta, data.stoneGeneratedWeightedHaLastScan)
        end

        if self.debugMode == "overview" then
            lines = buildOverviewLines(
                data, state, currentSpeed, recommendedSpeed, ratedSpeed
            )
        else
            lines = filterDebugSections(lines, self.debugMode)
        end

        self.debugLines = lines
        self.debugLineImplement = implement
        self.debugLineMode = self.debugMode
        self.debugNextRefresh = now + 1000
    end

    renderDebugPanel(self.debugLines)
end

-- Specialization installation ----------------------------------------------

-- Registers the TerraLogic specialization with the vehicle type manager.
function TerraLogicMain.registerSpecialization()
    g_specializationManager:addSpecialization(
        SPEC_NAME,
        "TerraLogic",
        MOD_DIR .. "scripts/TerraLogic.lua",
        nil
    )

    TypeManager.finalizeTypes = Utils.appendedFunction(
        TypeManager.finalizeTypes,
        TerraLogicMain.installSpecialization
    )
end

-- Adds TerraLogic only to vehicle types that satisfy its prerequisites.
function TerraLogicMain.installSpecialization()
    if TerraLogicMain.specializationInstallDone then
        return
    end
    local specialization = g_specializationManager:getSpecializationObjectByName(SPEC_NAME)
    if specialization == nil then
        Logging.error("[%s] Could not load specialization '%s'", MOD_NAME, SPEC_NAME)
        return
    end
    TerraLogicMain.specializationInstallDone = true

    local installedCount = 0

    for _, vehicleType in pairs(g_vehicleTypeManager.types) do
        local specializations = vehicleType.specializationsByName
        local isAttachable = specializations ~= nil and specializations.attachable ~= nil
        local isWearable = specializations ~= nil and specializations.wearable ~= nil
        local isMotorized = specializations ~= nil and specializations.motorized ~= nil
        local isMower = specializations ~= nil and specializations.mower ~= nil
        local isWindrower = specializations ~= nil
            and specializations.windrower ~= nil
        local isTedder = specializations ~= nil and specializations.tedder ~= nil
        local isBaler = specializations ~= nil and specializations.baler ~= nil
        local isForageWagon = specializations ~= nil
            and specializations.forageWagon ~= nil
        local isHarvester = specializations ~= nil
            and (specializations.combine ~= nil or specializations.cutter ~= nil)
        local isAlreadyInstalled = specializations ~= nil and specializations[SPEC_NAME] ~= nil

        -- Ordinary implements remain supported as before. Motorized forage
        -- surface tools are explicitly allowed; combines/cutters stay out so
        -- TerraLogic does not collide with dedicated harvesting/yield mods.
        local isSupportedWorkTool = specializations ~= nil
            and (specializations.plow ~= nil
                or specializations.cultivator ~= nil
                or specializations.sowingMachine ~= nil
                or specializations.sprayer ~= nil
                or specializations.roller ~= nil
                or specializations.mulcher ~= nil
                or specializations.weeder ~= nil
                or specializations.stonePicker ~= nil
                or specializations.ridgeFormer ~= nil
                or specializations.fruitPreparer ~= nil
                or isMower or isWindrower or isTedder or isBaler
                or isForageWagon)
        local supportedImplement = isAttachable and isWearable
            and not isMotorized and not isHarvester and isSupportedWorkTool
        local supportedSelfPropelledForageTool = isMotorized and isWearable
            and (isMower or isWindrower or isTedder) and not isHarvester
        if (supportedImplement or supportedSelfPropelledForageTool)
            and not isAlreadyInstalled then
            vehicleType.specializationsByName[SPEC_NAME] = specialization
            table.insert(vehicleType.specializationNames, SPEC_NAME)
            table.insert(vehicleType.specializations, specialization)
            installedCount = installedCount + 1
        end
    end

    TerraLogicLogging.debug("[%s] Installed specialization on %d implement vehicle types", MOD_NAME, installedCount)
end

TerraLogicMain.registerSpecialization()
if PlayerInputComponent ~= nil
    and PlayerInputComponent.registerActionEvents ~= nil
    and PlayerInputComponent.terraLogicSoilInputHookInstalled ~= true then
    PlayerInputComponent.registerActionEvents = Utils.appendedFunction(
        PlayerInputComponent.registerActionEvents,
        TerraLogicMain.registerPlayerSoilDisplayActionEvent)
    PlayerInputComponent.terraLogicSoilInputHookInstalled = true
end
if Enterable ~= nil and Enterable.onRegisterActionEvents ~= nil
    and Enterable.terraLogicSoilInputHookInstalled ~= true then
    Enterable.onRegisterActionEvents = Utils.appendedFunction(
        Enterable.onRegisterActionEvents,
        TerraLogicMain.registerVehicleSoilDisplayActionEvent)
    Enterable.terraLogicSoilInputHookInstalled = true
end
if FSBaseMission ~= nil and FSBaseMission.saveSavegame ~= nil
    and FSBaseMission.terraLogicQualitySaveHookInstalled ~= true then
    FSBaseMission.saveSavegame = Utils.appendedFunction(
        FSBaseMission.saveSavegame,
        TerraLogicMain.saveWorkQualityData
    )
    FSBaseMission.terraLogicQualitySaveHookInstalled = true
    TerraLogicLogging.debug(
        "[%s] Installed FSBaseMission work-quality save hook",
        MOD_NAME
    )
end
addModEventListener(TerraLogicMain)
