--[[
    TerraLogicSettings.lua
    Savegame settings, in-game options and multiplayer synchronization.

    Copyright (c) 2026 The Mod Workshop. All rights reserved.
    Unauthorized copying, modification, or redistribution is prohibited
    except where expressly permitted by the copyright owner.

    Source fingerprint: TMW-TL-SET-1.200862
]]

TerraLogicSettings = {
    DRAFT_TERRALOGIC = "terraLogic",
    DRAFT_MR = "mr",
    VISIBLE_STONES_VANILLA = "vanilla",
    VISIBLE_STONES_TERRALOGIC = "terraLogic",
    draftModel = "terraLogic",
    visibleStoneDamageModel = "terraLogic",
    physicalDropoutsEnabled = true,
    soilDevelopmentSpeed = 8,
    moistureYieldEnabled = true,
    mapUpdatePreset = "gentle",
    tutorialsEnabled = true,
    tutorialMode = "guided",
    speedHudMode = "dynamic",
    warningDisplaySeconds = 5,
    damageWarningsEnabled = true,
    fieldHudMode = "soil",
    vehicleSoilMapMode = 0,
    soilMinimapZoom = 4.0,
    debugEnabled = false,
    menuInstalled = false
}
-- Numeric source signature only; it is deliberately excluded from gameplay math.
TerraLogicSettings.SOURCE_FINGERPRINT = 1.200862

TerraLogicLogging = TerraLogicLogging or {verbose = false}

-- Public legacy aliases keep integrations and older diagnostic snippets
-- working after the TerraLogic rename. New code uses the TerraLogic names.
OverSpeedDamageSettings = TerraLogicSettings
OSDLogging = TerraLogicLogging

-- Emits detailed diagnostics only after the player enables verbose logging.
function TerraLogicLogging.debug(message, ...)
    if TerraLogicLogging.verbose then
        Logging.info(message, ...)
    end
end

-- Diagnostic warnings (e.g. a modded vehicle's unusual XML wear rate) are
-- distinct from actual failures, which continue using Logging.warning/error.
function TerraLogicLogging.debugWarning(message, ...)
    if TerraLogicLogging.verbose then
        Logging.warning(message, ...)
    end
end

-- Persistence helpers -------------------------------------------------------

-- Returns the current and legacy savegame setting paths.
local function getSettingsPath()
    local missionInfo = g_currentMission ~= nil and g_currentMission.missionInfo or nil
    local directory = missionInfo ~= nil and missionInfo.savegameDirectory or nil
    if directory == nil or directory == "" then return nil end
    return directory .. "/terraLogicSettings.xml",
        directory .. "/overSpeedDamageSettings.xml"
end

local function getLocalSettingsPath()
    if getUserProfileAppPath == nil then return nil end
    local directory = getUserProfileAppPath() .. "modSettings"
    return directory .. "/FS25_TerraLogic.xml", directory,
        directory .. "/FS25_OverSpeedDamage.xml"
end

-- Loads client-only HUD preferences that do not affect multiplayer gameplay.
function TerraLogicSettings:loadLocal()
    local path, _, legacyPath = getLocalSettingsPath()
    if path == nil then return end
    local migrated = false
    if not fileExists(path) then
        if legacyPath == nil or not fileExists(legacyPath) then return end
        path = legacyPath
        migrated = true
    end
    local xml = loadXMLFile("terraLogicLocalSettings", path)
    if xml ~= nil and xml ~= 0 then
        local mode = string.lower(tostring(
            getXMLString(xml, "settings#speedHudMode") or "dynamic"))
        self.speedHudMode = (mode == "always" or mode == "off" or mode == "warnings")
            and mode or "dynamic"
        self.warningDisplaySeconds = math.clamp(math.floor(
            tonumber(getXMLInt(xml, "settings#warningDisplaySeconds"))
                or 5), 1, 10)
        self.damageWarningsEnabled = Utils.getNoNil(
            getXMLBool(xml, "settings#damageWarningsEnabled"), true)
        self.tutorialsEnabled = Utils.getNoNil(
            getXMLBool(xml, "settings#tutorialsEnabled"), true)
        self.tutorialMode = getXMLString(xml, "settings#tutorialMode") == "context"
            and "context" or "guided"
        local fieldMode = string.lower(tostring(
            getXMLString(xml, "settings#fieldHudMode") or "soil"))
        self.fieldHudMode = (fieldMode == "work" or fieldMode == "off")
            and fieldMode or "soil"
        self.vehicleSoilMapMode = math.clamp(tonumber(getXMLInt(
            xml, "settings#vehicleSoilMapMode")) or 0, 0, 5)
        local minimapZoom = tonumber(getXMLFloat(
            xml, "settings#soilMinimapZoom")) or 4.0
        self.soilMinimapZoom = self:normalizeSoilMinimapZoom(minimapZoom)
        delete(xml)
    end
    if migrated then self:saveLocal() end
end

-- Saves client-only HUD preferences outside the savegame.
function TerraLogicSettings:saveLocal()
    local path, directory = getLocalSettingsPath()
    if path == nil then return end
    if not fileExists(directory) and createFolder ~= nil then
        createFolder(directory)
    end
    local xml = createXMLFile("terraLogicLocalSettings", path, "settings")
    if xml ~= nil and xml ~= 0 then
        setXMLString(xml, "settings#speedHudMode", self.speedHudMode)
        setXMLInt(xml, "settings#warningDisplaySeconds",
            self:getWarningDisplaySeconds())
        setXMLBool(xml, "settings#damageWarningsEnabled",
            self.damageWarningsEnabled ~= false)
        setXMLBool(xml, "settings#tutorialsEnabled",
            self.tutorialsEnabled ~= false)
        setXMLString(xml, "settings#tutorialMode", self.tutorialMode or "guided")
        setXMLString(xml, "settings#fieldHudMode", self.fieldHudMode or "soil")
        setXMLInt(xml, "settings#vehicleSoilMapMode",
            math.clamp(tonumber(self.vehicleSoilMapMode) or 0, 0, 5))
        setXMLFloat(xml, "settings#soilMinimapZoom",
            self:normalizeSoilMinimapZoom(self.soilMinimapZoom))
        saveXMLFile(xml)
        delete(xml)
    end
end

-- Detects whether More Realistic is active in the current mission.
function TerraLogicSettings:isMoreRealisticActive()
    return PowerConsumer ~= nil
        and type(PowerConsumer.mrGetDraftForceMultiplier) == "function"
        and type(PowerConsumer.mrGetForceMultiplier) == "function"
end

-- Resolves the selected draft provider with a safe TerraLogic fallback.
function TerraLogicSettings:getEffectiveDraftModel()
    if self.draftModel == self.DRAFT_MR and self:isMoreRealisticActive() then
        return self.DRAFT_MR
    end
    return self.DRAFT_TERRALOGIC
end

function TerraLogicSettings:getPhysicalDropoutsEnabled()
    -- Physical misses are now a core consequence for seeders, pickups and
    -- application tools. Keep the API for old callers/network packets, but do
    -- not allow a savegame option to silently remove their gameplay balance.
    return true
end

function TerraLogicSettings:normalizeSoilDevelopmentSpeed(value)
    local requested = tonumber(value) or 1
    -- v67-v70 stored literal 1..4 factors. Preserve the 1x simulation tier
    -- and migrate former intermediate convenience levels to the 4x tier.
    if requested <= 1 then return 1 end
    if requested <= 4 then return 4 end
    return 8
end

function TerraLogicSettings:getSoilDevelopmentSpeedState(value)
    local speed = self:normalizeSoilDevelopmentSpeed(
        value ~= nil and value or self.soilDevelopmentSpeed)
    return speed == 1 and 1 or (speed == 4 and 2 or 3)
end

function TerraLogicSettings:getSoilDevelopmentSpeedFromState(state)
    state = math.clamp(math.floor(tonumber(state) or 2), 1, 3)
    return state == 1 and 1 or (state == 2 and 4 or 8)
end

function TerraLogicSettings:getSoilDevelopmentSpeed()
    return self:normalizeSoilDevelopmentSpeed(self.soilDevelopmentSpeed)
end

-- The persisted/networked value deliberately remains 1/4/8 for backwards
-- compatibility. It controls resilience only and the displayed multiplier is
-- now also the literal biological development rate.
function TerraLogicSettings:getResilienceDevelopmentSpeed(value)
    local speed = self:normalizeSoilDevelopmentSpeed(
        value ~= nil and value or self.soilDevelopmentSpeed)
    return speed
end

-- Physical recovery and direct root loosening use the former 4x calibration
-- in every tier. Keeping these helpers here makes the separation explicit to
-- every server-side system that consumes the setting.
function TerraLogicSettings:getPhysicalSoilDevelopmentSpeed()
    return 4
end

function TerraLogicSettings:getRootLooseningSpeed()
    return 4
end

-- Use the same acceleration for gains and losses. The old 1x/2x/4x damage
-- curve let biological recovery outrun tillage on faster gameplay settings
-- and changed the long-term equilibrium instead of only reaching it sooner.
function TerraLogicSettings:getResilienceTillageLossScale(value)
    local speed = self:normalizeSoilDevelopmentSpeed(
        value ~= nil and value or self.soilDevelopmentSpeed)
    return speed
end

function TerraLogicSettings:getMoistureYieldEnabled()
    return self.moistureYieldEnabled ~= false
end

function TerraLogicSettings:getTutorialsEnabled()
    return self.tutorialsEnabled ~= false
end

function TerraLogicSettings:getDamageWarningsEnabled()
    return self.damageWarningsEnabled ~= false
end

function TerraLogicSettings:getWarningDisplaySeconds()
    return math.clamp(math.floor(
        tonumber(self.warningDisplaySeconds) or 5), 1, 10)
end

function TerraLogicSettings:getWarningDisplayDurationMs()
    return self:getWarningDisplaySeconds() * 1000
end

function TerraLogicSettings:normalizeSoilMinimapZoom(value)
    local requested = tonumber(value) or 2.0
    local choices = {0, 1.5, 2.0, 3.0, 4.0}
    local nearest, distance = choices[1], math.huge
    for _, choice in ipairs(choices) do
        local currentDistance = math.abs(requested - choice)
        if currentDistance < distance then
            nearest, distance = choice, currentDistance
        end
    end
    return nearest
end

function TerraLogicSettings:getSoilMinimapZoom()
    return self:normalizeSoilMinimapZoom(self.soilMinimapZoom)
end

function TerraLogicSettings:getVisibleStoneDamageModel()
    return self.visibleStoneDamageModel == self.VISIBLE_STONES_VANILLA
        and self.VISIBLE_STONES_VANILLA or self.VISIBLE_STONES_TERRALOGIC
end

function TerraLogicSettings:applyVisibleStoneDamageModel(value)
    value = string.lower(tostring(value or ""))
    if value ~= self.VISIBLE_STONES_VANILLA then
        value = self.VISIBLE_STONES_TERRALOGIC
    end
    self.visibleStoneDamageModel = value
    if self.visibleStoneDamageOption ~= nil then
        self.visibleStoneDamageOption:setState(
            value == self.VISIBLE_STONES_TERRALOGIC and 2 or 1)
    end
end

function TerraLogicSettings:applyPhysicalDropoutsEnabled(value)
    self.physicalDropoutsEnabled = true
end

function TerraLogicSettings:applySoilDevelopmentSpeed(value)
    self.soilDevelopmentSpeed = self:normalizeSoilDevelopmentSpeed(value)
    if self.soilDevelopmentSpeedOption ~= nil then
        self.soilDevelopmentSpeedOption:setState(
            self:getSoilDevelopmentSpeedState())
    end
end

function TerraLogicSettings:applyMoistureYieldEnabled(value)
    self.moistureYieldEnabled = value ~= false
    if self.moistureYieldOption ~= nil then
        self.moistureYieldOption:setState(
            self.moistureYieldEnabled and 2 or 1)
    end
end

function TerraLogicSettings:getDebugEnabled()
    return self.debugEnabled == true
end

function TerraLogicSettings:applyDebugEnabled(value)
    local wasEnabled = self:getDebugEnabled()
    self.debugEnabled = value == true
    TerraLogicLogging.verbose = self.debugEnabled
    if self.debugOption ~= nil then
        self.debugOption:setState(self.debugEnabled and 2 or 1)
    end
    if self.debugEnabled and not wasEnabled and TerraLogicQualityManager ~= nil
        and TerraLogicQualityManager.resetHarvestDiagnostics ~= nil then
        TerraLogicQualityManager:resetHarvestDiagnostics()
    end
end

function TerraLogicSettings:applyDraftModel(value)
    value = string.lower(tostring(value or ""))
    if value ~= self.DRAFT_MR then value = self.DRAFT_TERRALOGIC end
    if value == self.DRAFT_MR and not self:isMoreRealisticActive() then
        value = self.DRAFT_TERRALOGIC
    end
    self.draftModel = value
    if self.menuOption ~= nil then
        self.menuOption:setState(value == self.DRAFT_MR and 2 or 1)
    end
end

-- Loads synchronized gameplay settings and migrates legacy OSD settings.
function TerraLogicSettings:load()
    -- Missing keys and a new mission must never inherit a previous debug session.
    self:applyDebugEnabled(false)
    self:applyMapUpdatePreset("gentle")
    self:loadLocal()
    local default = self:isMoreRealisticActive() and self.DRAFT_MR or self.DRAFT_TERRALOGIC
    self:applyDraftModel(default)
    self:applyPhysicalDropoutsEnabled(true)
    self:applySoilDevelopmentSpeed(8)
    self:applyMoistureYieldEnabled(true)
    self:applyVisibleStoneDamageModel(self.VISIBLE_STONES_TERRALOGIC)
    local path, legacyPath = getSettingsPath()
    if path == nil then return end
    local migrated = false
    if not fileExists(path) then
        if legacyPath == nil or not fileExists(legacyPath) then return end
        path = legacyPath
        migrated = true
    end
    local xml = loadXMLFile("osdSettings", path)
    if xml ~= nil and xml ~= 0 then
        self:applyDebugEnabled(getXMLBool(xml, "settings#debugEnabled") == true)
        self:applyDraftModel(getXMLString(xml, "settings#draftModel") or default)
        self:applyMapUpdatePreset(getXMLString(xml, "settings#mapUpdatePreset"))
        -- Read no legacy toggle here: all existing savegames migrate to the
        -- mandatory physical consequence model on first load.
        self:applyPhysicalDropoutsEnabled(true)
        self:applySoilDevelopmentSpeed(tonumber(getXMLInt(
            xml, "settings#soilDevelopmentSpeed")) or 8)
        self:applyMoistureYieldEnabled(Utils.getNoNil(
            getXMLBool(xml, "settings#moistureYieldEnabled"), true))
        self:applyVisibleStoneDamageModel(
            getXMLString(xml, "settings#visibleStoneDamageModel")
                or self.VISIBLE_STONES_TERRALOGIC)
        delete(xml)
    end
    if migrated then self:save() end
end

-- Saves server-owned gameplay settings and the local player's HUD choices.
function TerraLogicSettings:save()
    if g_currentMission == nil or not g_currentMission:getIsServer() then return end
    local path = getSettingsPath()
    if path == nil then return end
    local xml = createXMLFile("osdSettings", path, "settings")
    if xml ~= nil and xml ~= 0 then
        setXMLBool(xml, "settings#debugEnabled", self:getDebugEnabled())
        setXMLString(xml, "settings#draftModel", self.draftModel)
        setXMLString(xml, "settings#mapUpdatePreset", self.mapUpdatePreset)
        -- Retain the key for older releases that may read this settings file.
        setXMLBool(xml, "settings#physicalDropoutsEnabled", true)
        setXMLInt(xml, "settings#soilDevelopmentSpeed",
            self:getSoilDevelopmentSpeed())
        setXMLBool(xml, "settings#moistureYieldEnabled",
            self:getMoistureYieldEnabled())
        setXMLString(xml, "settings#visibleStoneDamageModel",
            self:getVisibleStoneDamageModel())
        saveXMLFile(xml)
        delete(xml)
    end
end

-- Returns whether this client may change synchronized multiplayer settings.
function TerraLogicSettings:isLocalAdmin()
    return g_server ~= nil
        or (g_currentMission ~= nil and g_currentMission.isMasterUser == true)
end

function TerraLogicSettings:setFromMenu(value)
    if not self:isLocalAdmin() then return end
    if g_server ~= nil then
        self:applyDraftModel(value)
        self:save()
        g_server:broadcastEvent(TerraLogicSettingsEvent.new(
            self.draftModel, self.physicalDropoutsEnabled,
            self.visibleStoneDamageModel, self.soilDevelopmentSpeed))
    elseif g_client ~= nil then
        g_client:getServerConnection():sendEvent(TerraLogicSettingsEvent.new(
            value, self.physicalDropoutsEnabled,
            self.visibleStoneDamageModel, self.soilDevelopmentSpeed))
    end
end

function TerraLogicSettings:setVisibleStoneDamageModelFromMenu(value)
    if not self:isLocalAdmin() then return end
    value = value == self.VISIBLE_STONES_VANILLA
        and self.VISIBLE_STONES_VANILLA or self.VISIBLE_STONES_TERRALOGIC
    if g_server ~= nil then
        self:applyVisibleStoneDamageModel(value)
        self:save()
        g_server:broadcastEvent(TerraLogicSettingsEvent.new(
            self.draftModel, self.physicalDropoutsEnabled,
            self.visibleStoneDamageModel, self.soilDevelopmentSpeed))
    elseif g_client ~= nil then
        g_client:getServerConnection():sendEvent(TerraLogicSettingsEvent.new(
            self.draftModel, self.physicalDropoutsEnabled, value,
            self.soilDevelopmentSpeed))
    end
end

function TerraLogicSettings:setSoilDevelopmentSpeedFromMenu(value)
    if not self:isLocalAdmin() then return end
    value = self:normalizeSoilDevelopmentSpeed(value)
    if g_server ~= nil then
        self:applySoilDevelopmentSpeed(value)
        self:save()
        g_server:broadcastEvent(TerraLogicSettingsEvent.new(
            self.draftModel, self.physicalDropoutsEnabled,
            self.visibleStoneDamageModel, self.soilDevelopmentSpeed))
    elseif g_client ~= nil then
        g_client:getServerConnection():sendEvent(TerraLogicSettingsEvent.new(
            self.draftModel, self.physicalDropoutsEnabled,
            self.visibleStoneDamageModel, value))
    end
end

function TerraLogicSettings:setMoistureYieldFromMenu(value)
    if not self:isLocalAdmin() then return end
    value = value ~= false
    if g_server ~= nil then
        self:applyMoistureYieldEnabled(value)
        self:save()
        g_server:broadcastEvent(TerraLogicSettingsEvent.new(
            self.draftModel, self.physicalDropoutsEnabled,
            self.visibleStoneDamageModel, self.soilDevelopmentSpeed,
            self.moistureYieldEnabled))
    elseif g_client ~= nil then
        g_client:getServerConnection():sendEvent(TerraLogicSettingsEvent.new(
            self.draftModel, self.physicalDropoutsEnabled,
            self.visibleStoneDamageModel, self.soilDevelopmentSpeed, value))
    end
end

TerraLogicSettingsMenuCallbacks = {}

function TerraLogicSettings:applyMapUpdatePreset(value)
    self.mapUpdatePreset = value == "fast" and "fast" or "gentle"
    if self.mapUpdateOption ~= nil then
        self.mapUpdateOption:setState(self.mapUpdatePreset == "fast" and 2 or 1)
    end
    if TerraLogicMapMaintenance ~= nil then
        TerraLogicMapMaintenance:applyPreset(self.mapUpdatePreset)
    end
end

function TerraLogicSettings:setMapUpdatePresetFromMenu(value)
    if not self:isLocalAdmin() then return end
    value = value == "fast" and "fast" or "gentle"
    if g_server ~= nil then
        self:applyMapUpdatePreset(value)
        self:save()
        g_server:broadcastEvent(TerraLogicSettingsEvent.new(
            self.draftModel, true, self.visibleStoneDamageModel,
            self.soilDevelopmentSpeed, self.moistureYieldEnabled, value))
    elseif g_client ~= nil then
        g_client:getServerConnection():sendEvent(TerraLogicSettingsEvent.new(
            self.draftModel, true, self.visibleStoneDamageModel,
            self.soilDevelopmentSpeed, self.moistureYieldEnabled, value))
    end
end

-- Debug follows this savegame and its administrator, including remote servers.
-- Applying a received state never writes a client's unrelated local preferences.
function TerraLogicSettings:setDebugEnabledFromMenu(value)
    if not self:isLocalAdmin() then return false end
    value = value == true
    if g_server ~= nil then
        self:applyDebugEnabled(value)
        self:save()
        g_server:broadcastEvent(TerraLogicSettingsEvent.new(
            self.draftModel, true, self.visibleStoneDamageModel,
            self.soilDevelopmentSpeed, self.moistureYieldEnabled,
            self.mapUpdatePreset, value))
        return true
    elseif g_client ~= nil then
        g_client:getServerConnection():sendEvent(TerraLogicSettingsEvent.new(
            self.draftModel, true, self.visibleStoneDamageModel,
            self.soilDevelopmentSpeed, self.moistureYieldEnabled,
            self.mapUpdatePreset, value))
        return true
    end
    return false
end

function TerraLogicSettingsMenuCallbacks:onDebugChanged(state)
    TerraLogicSettings:setDebugEnabledFromMenu(state == 2)
end

function TerraLogicSettingsMenuCallbacks:onMapUpdateChanged(state)
    TerraLogicSettings:setMapUpdatePresetFromMenu(state == 2 and "fast" or "gentle")
end

-- Menu callbacks ------------------------------------------------------------

-- Forwards the draft-model selection from the options menu.
function TerraLogicSettingsMenuCallbacks:onDraftModelChanged(state)
    TerraLogicSettings:setFromMenu(state == 2 and "mr" or "terraLogic")
end

function TerraLogicSettingsMenuCallbacks:onSoilDevelopmentSpeedChanged(state)
    TerraLogicSettings:setSoilDevelopmentSpeedFromMenu(
        TerraLogicSettings:getSoilDevelopmentSpeedFromState(state))
end

function TerraLogicSettingsMenuCallbacks:onVisibleStoneDamageChanged(state)
    TerraLogicSettings:setVisibleStoneDamageModelFromMenu(
        state == 1 and "vanilla" or "terraLogic")
end

function TerraLogicSettingsMenuCallbacks:onMoistureYieldChanged(state)
    TerraLogicSettings:setMoistureYieldFromMenu(state == 2)
end

function TerraLogicSettingsMenuCallbacks:onTutorialsChanged(state)
    TerraLogicSettings.tutorialsEnabled = state ~= 1
    TerraLogicSettings.tutorialMode = state == 3 and "context" or "guided"
    TerraLogicSettings:saveLocal()
    if TerraLogicTutorialManager ~= nil
        and TerraLogicTutorialManager.onEnabledChanged ~= nil then
        TerraLogicTutorialManager:onEnabledChanged(
            TerraLogicSettings.tutorialsEnabled)
    end
end

function TerraLogicSettingsMenuCallbacks:onTutorialReset()
    if TerraLogicTutorialManager ~= nil
        and TerraLogicTutorialManager.requestReset ~= nil then
        TerraLogicTutorialManager:requestReset()
    end
end

function TerraLogicSettingsMenuCallbacks:onTutorialLibrary()
    TerraLogicTutorialManager:openLibrary()
end

function TerraLogicSettingsMenuCallbacks:onSpeedHudModeChanged(state)
    TerraLogicSettings.speedHudMode = ({
        "dynamic", "always", "warnings", "off"
    })[state] or "dynamic"
    TerraLogicSettings:saveLocal()
end

function TerraLogicSettingsMenuCallbacks:onTutorialPositionReset()
    TerraLogicTutorialManager:resetPosition()
end

function TerraLogicSettingsMenuCallbacks:onWarningDisplaySecondsChanged(state)
    TerraLogicSettings.warningDisplaySeconds = math.clamp(
        math.floor(tonumber(state) or 5), 1, 10)
    TerraLogicSettings:saveLocal()
end

function TerraLogicSettingsMenuCallbacks:onSoilMinimapZoomChanged(state)
    TerraLogicSettings.soilMinimapZoom = ({0, 1.5, 2.0, 3.0, 4.0})[state]
        or 4.0
    TerraLogicSettings:saveLocal()
end

function TerraLogicSettingsMenuCallbacks:onDamageWarningsChanged(state)
    TerraLogicSettings.damageWarningsEnabled = state == 2
    TerraLogicSettings:saveLocal()
end

-- Repairs focus IDs after dynamically inserting controls into the menu.
local function updateFocusIds(element)
    if element == nil then return end
    element.focusId = FocusManager:serveAutoFocusId()
    for _, child in pairs(element.elements or {}) do updateFocusIds(child) end
end

-- Adds TerraLogic controls to the in-game settings page when it is available.
function TerraLogicSettings:tryInstallMenu()
    if self.menuInstalled or g_gui == nil or g_gui.screenControllers == nil then
        return self.menuInstalled
    end
    local menu = g_gui.screenControllers[InGameMenu]
    local page = menu ~= nil and menu.pageSettings or nil
    if page == nil or page.gameSettingsLayout == nil
        or page.multiVolumeVoiceBox == nil then return false end

    TerraLogicSettingsMenuCallbacks.name = page.name
    local header
    for _, element in ipairs(page.gameSettingsLayout.elements or {}) do
        if element.name == "sectionHeader" then
            header = element:clone(page.gameSettingsLayout)
            break
        end
    end
    if header ~= nil then
        header:setText(g_i18n:getText("terraLogic_settingSection"))
        updateFocusIds(header)
        table.insert(page.controlsList, header)
    end

    local function addOption(id, callback, texts, state, titleKey, tooltipKey)
        local box = page.multiVolumeVoiceBox:clone(page.gameSettingsLayout)
        box.id = id .. "Box"
        local option = box.elements[1]
        option.id = id
        option.target = TerraLogicSettingsMenuCallbacks
        option:setCallback("onClickCallback", callback)
        option:setTexts(texts)
        option:setState(state)
        if option.elements ~= nil and option.elements[1] ~= nil then
            option.elements[1]:setText(g_i18n:getText(tooltipKey))
        end
        if box.elements[2] ~= nil then
            box.elements[2]:setText(g_i18n:getText(titleKey))
        end
        updateFocusIds(box)
        table.insert(page.controlsList, box)
        return option, box
    end

    -- The settings page already contains a native action row ("Pause game").
    -- Its primary ButtonElement carries the correct right-hand alignment,
    -- centred caption and mouse-hover animation for this exact layout.
    local function findSettingsActionButtonTemplate()
        if ButtonElement == nil then return nil end
        for _, row in ipairs(page.gameSettingsLayout.elements or {}) do
            if row.isa ~= nil and row:isa(ButtonElement) then
                return row
            end
            -- Only inspect direct row children. MultiTextOption arrow buttons
            -- live another level deeper and must never become our template.
            for _, child in ipairs(row.elements or {}) do
                if child.isa ~= nil and child:isa(ButtonElement) then
                    return child
                end
            end
        end
        return nil
    end
    local settingsActionButtonTemplate =
        findSettingsActionButtonTemplate()

    -- Action rows must use a ButtonElement. A MultiTextOption with identical
    -- values still processes left/right input and can receive the same release
    -- event again after a modal dialog closes.
    local function addButton(id, callback, textKey, titleKey, tooltipKey)
        local box = page.multiVolumeVoiceBox:clone(page.gameSettingsLayout)
        box.id = id .. "Box"
        local optionTemplate = box.elements[1]
        local titleElement = box.elements[2]
        local position = table.clone(optionTemplate.position)
        local size = table.clone(optionTemplate.size)
        local anchors = table.clone(optionTemplate.anchors)
        local anchorDeltas = table.clone(optionTemplate.anchorDeltas)
        local pivot = table.clone(optionTemplate.pivot)
        local margin = table.clone(optionTemplate.margin)
        local absoluteSizeOffset = optionTemplate.absoluteSizeOffset ~= nil
            and table.clone(optionTemplate.absoluteSizeOffset) or nil
        local menuButtonTemplate = settingsActionButtonTemplate
            or (menu.menuButton ~= nil and menu.menuButton[1] or nil)

        if menuButtonTemplate == nil or ButtonElement == nil then
            -- This should not occur in the Vanilla in-game menu. Keep a safe
            -- no-arrow fallback for custom menu replacements.
            optionTemplate.id = id
            optionTemplate.target = TerraLogicSettingsMenuCallbacks
            optionTemplate:setCallback("onClickCallback", callback)
            optionTemplate:setTexts({g_i18n:getText(textKey)})
            optionTemplate:setState(1)
            optionTemplate.hideLeftRightButtons = true
            if optionTemplate.leftButtonElement ~= nil then
                optionTemplate.leftButtonElement:setVisible(false)
            end
            if optionTemplate.rightButtonElement ~= nil then
                optionTemplate.rightButtonElement:setVisible(false)
            end
            if titleElement ~= nil then
                titleElement:setText(g_i18n:getText(titleKey))
            end
            updateFocusIds(box)
            table.insert(page.controlsList, box)
            return optionTemplate, box
        end

        optionTemplate:delete()
        local button = menuButtonTemplate:clone(box)
        button.id = id
        button.name = id
        button.target = TerraLogicSettingsMenuCallbacks
        button:setCallback("onClickCallback", callback)
        button:setText(g_i18n:getText(textKey))
        -- Keep the Vanilla settings-button visuals and input behaviour, while
        -- using this option row's geometry so it remains correctly aligned.
        button.fitToContent = false
        button.textAutoWidth = false
        button.position = position
        button.size = size
        button.anchors = anchors
        button.anchorDeltas = anchorDeltas
        button.pivot = pivot
        button.margin = margin
        button.absoluteSizeOffset = absoluteSizeOffset
        button:updateAbsolutePosition()
        button:setVisible(true)
        button:setDisabled(false)
        -- Dynamically inserted controls do not participate in the settings
        -- page's initial onOpen/reset pass. The cloned Pause button can thus
        -- retain its template's selected/focused text colour until the first
        -- mouse enter/leave cycle. Initialize all interaction flags now so the
        -- caption is readable immediately when the page opens.
        button:reset()
        button.inputActionName = nil
        button.keyDisplayText = nil
        button.hasLoadedInputGlyph = true
        -- The settings template carries a Pause icon independently of its
        -- input binding. Hide that glyph in every input mode and remove its
        -- text spacing. Fresh tables leave the original Vanilla row untouched.
        button.iconSize = {0, 0}
        button.touchIconSize = {0, 0}
        button.gamepadIconSize = {0, 0}
        button.keyGlyphSize = {0, 0}
        button.iconTextOffset = {0, 0}
        button:updateSize()
        button.toolTipText = g_i18n:getText(tooltipKey)
        if titleElement ~= nil then
            titleElement:setText(g_i18n:getText(titleKey))
        end
        updateFocusIds(box)
        table.insert(page.controlsList, box)
        return button, box
    end

    -- Player-facing guidance and display options come first. The tutorial
    -- reset is an ordinary row directly below the tutorial toggle so it is
    -- visible in the same TerraLogic section on every input device.
    self.tutorialsOption = addOption(
        "terraLogicTutorials", "onTutorialsChanged",
        {g_i18n:getText("terraLogic_settingOff"),
            g_i18n:getText("terraLogic_tutorialModeGuided"),
            g_i18n:getText("terraLogic_tutorialModeContext")},
        self:getTutorialsEnabled() and (self.tutorialMode == "context" and 3 or 2) or 1,
        "terraLogic_settingTutorialsTitle",
        "terraLogic_settingTutorialsTooltip")
    self.tutorialLibraryButton = addButton(
        "terraLogicTutorialLibrary", "onTutorialLibrary",
        "terraLogic_tutorialLibraryAction", "terraLogic_tutorialLibraryTitle",
        "terraLogic_tutorialLibraryTooltip")
    self.tutorialResetButton = addButton(
        "terraLogicTutorialReset", "onTutorialReset",
        "terraLogic_settingTutorialResetAction",
        "terraLogic_settingTutorialReset",
        "terraLogic_settingTutorialResetTooltip")
    addButton("terraLogicTutorialPositionReset", "onTutorialPositionReset",
        "terraLogic_tutorialPositionResetAction", "terraLogic_tutorialPositionResetTitle",
        "terraLogic_tutorialPositionResetTooltip")
    local speedHudState = self.speedHudMode == "always" and 2
        or (self.speedHudMode == "warnings" and 3 or (self.speedHudMode == "off" and 4 or 1))
    self.speedHudModeOption = addOption(
        "terraLogicSpeedHudMode", "onSpeedHudModeChanged",
        {g_i18n:getText("terraLogic_settingHudDynamic"),
            g_i18n:getText("terraLogic_settingHudAlways"),
            g_i18n:getText("terraLogic_settingHudWarnings"),
            g_i18n:getText("terraLogic_settingHudOff")},
        speedHudState,
        "terraLogic_settingHudModeTitle", "terraLogic_settingHudModeTooltip")
    local warningDurationTexts = {}
    for seconds=1,10 do
        warningDurationTexts[seconds] = string.format("%d s", seconds)
    end
    self.warningDisplaySecondsOption = addOption(
        "terraLogicWarningDisplaySeconds",
        "onWarningDisplaySecondsChanged",
        warningDurationTexts,
        self:getWarningDisplaySeconds(),
        "terraLogic_settingWarningDurationTitle",
        "terraLogic_settingWarningDurationTooltip")
    local minimapZoom = self:getSoilMinimapZoom()
    local minimapZoomState = minimapZoom == 0 and 1
        or (minimapZoom == 1.5 and 2
            or (minimapZoom == 2 and 3
                or (minimapZoom == 3 and 4 or 5)))
    self.soilMinimapZoomOption = addOption(
        "terraLogicSoilMinimapZoom", "onSoilMinimapZoomChanged",
        {g_i18n:getText("terraLogic_settingOff"), TerraLogicI18n.format("%.1fx", 1.5), "2x", "3x", "4x"},
        minimapZoomState,
        "terraLogic_settingSoilMinimapZoomTitle",
        "terraLogic_settingSoilMinimapZoomTooltip")

    -- Gameplay simulation follows the local display options. Server-owned
    -- switches stay together, which also makes the admin-disabled rows easy
    -- to understand in multiplayer.
    self.soilDevelopmentSpeedOption = addOption(
        "terraLogicSoilDevelopmentSpeed", "onSoilDevelopmentSpeedChanged",
        {g_i18n:getText("terraLogic_settingSoilDevelopmentRealistic"),
            g_i18n:getText("terraLogic_settingSoilDevelopmentNormal"),
            g_i18n:getText("terraLogic_settingSoilDevelopmentFast")},
        self:getSoilDevelopmentSpeedState(),
        "terraLogic_settingSoilDevelopmentTitle",
        "terraLogic_settingSoilDevelopmentTooltip")
    self.mapUpdateOption = addOption(
        "terraLogicMapUpdate", "onMapUpdateChanged",
        {g_i18n:getText("terraLogic_mapUpdateGentle"),
            g_i18n:getText("terraLogic_mapUpdateFast")},
        self.mapUpdatePreset == "fast" and 2 or 1,
        "terraLogic_mapUpdateTitle", "terraLogic_mapUpdateHelp")
    self.mapUpdateOption:setDisabled(not self:isLocalAdmin())
    self.moistureYieldOption = addOption(
        "terraLogicMoistureYield", "onMoistureYieldChanged",
        {g_i18n:getText("terraLogic_settingOff"),
            g_i18n:getText("terraLogic_settingOn")},
        self:getMoistureYieldEnabled() and 2 or 1,
        "terraLogic_settingMoistureYieldTitle",
        "terraLogic_settingMoistureYieldTooltip")
    self.visibleStoneDamageOption = addOption(
        "terraLogicVisibleStoneDamage", "onVisibleStoneDamageChanged",
        {g_i18n:getText("terraLogic_settingVisibleStonesVanilla"),
            g_i18n:getText("terraLogic_settingVisibleStonesTerraLogic")},
        self.visibleStoneDamageModel == self.VISIBLE_STONES_TERRALOGIC and 2 or 1,
        "terraLogic_settingVisibleStonesTitle",
        "terraLogic_settingVisibleStonesTooltip")
    self.menuOption, self.draftModelBox = addOption(
        "terraLogicDraftModel", "onDraftModelChanged",
        {g_i18n:getText("terraLogic_settingDraftTerraLogic"),
            g_i18n:getText("terraLogic_settingDraftMR")},
        self.draftModel == self.DRAFT_MR and 2 or 1,
        "terraLogic_settingDraftTitle", "terraLogic_settingDraftTooltip")
    self.draftModelBox:setVisible(self:isMoreRealisticActive())

    -- Stone-impact events are the only optional warning. Condition, wear and
    -- mechanical-load information are integral parts of the work HUD.
    self.damageWarningsOption = addOption(
        "terraLogicDamageWarnings", "onDamageWarningsChanged",
        {g_i18n:getText("terraLogic_settingOff"),
            g_i18n:getText("terraLogic_settingOn")},
        self.damageWarningsEnabled and 2 or 1,
        "terraLogic_settingDamageWarningsTitle",
        "terraLogic_settingDamageWarningsTooltip")
    -- Keep diagnostics last, separate from normal gameplay/display choices.
    self.debugOption = addOption(
        "terraLogicDebug", "onDebugChanged",
        {g_i18n:getText("terraLogic_settingOff"),
            g_i18n:getText("terraLogic_settingOn")},
        self:getDebugEnabled() and 2 or 1,
        "terraLogic_settingDebugTitle", "terraLogic_settingDebugTooltip")
    self.debugOption:setDisabled(not self:isLocalAdmin())
    page.gameSettingsLayout:invalidateLayout()
    self.menuInstalled = true

    if InGameMenuSettingsFrame ~= nil
        and InGameMenuSettingsFrame.terraLogicAdminHookInstalled ~= true then
        InGameMenuSettingsFrame.onFrameOpen = Utils.appendedFunction(
            InGameMenuSettingsFrame.onFrameOpen,
            function(frame)
                local debugControl = TerraLogicSettings.debugOption
                if debugControl ~= nil then
                    debugControl:setState(TerraLogicSettings:getDebugEnabled() and 2 or 1)
                    debugControl:setDisabled(not TerraLogicSettings:isLocalAdmin())
                end
                local mapControl = TerraLogicSettings.mapUpdateOption
                if mapControl ~= nil then
                    mapControl:setState(TerraLogicSettings.mapUpdatePreset == "fast" and 2 or 1)
                    mapControl:setDisabled(not TerraLogicSettings:isLocalAdmin())
                end
                local control = TerraLogicSettings.menuOption
                if control ~= nil then
                    control:setState(TerraLogicSettings.draftModel == "mr" and 2 or 1)
                    control:setDisabled(not TerraLogicSettings:isLocalAdmin())
                end
                local draftBox = TerraLogicSettings.draftModelBox
                if draftBox ~= nil then
                    draftBox:setVisible(
                        TerraLogicSettings:isMoreRealisticActive())
                end
                local developmentControl =
                    TerraLogicSettings.soilDevelopmentSpeedOption
                if developmentControl ~= nil then
                    developmentControl:setState(
                        TerraLogicSettings:getSoilDevelopmentSpeedState())
                    developmentControl:setDisabled(
                        not TerraLogicSettings:isLocalAdmin())
                end
                local moistureYieldControl =
                    TerraLogicSettings.moistureYieldOption
                if moistureYieldControl ~= nil then
                    moistureYieldControl:setState(
                        TerraLogicSettings:getMoistureYieldEnabled()
                            and 2 or 1)
                    moistureYieldControl:setDisabled(
                        not TerraLogicSettings:isLocalAdmin())
                end
                local tutorialControl = TerraLogicSettings.tutorialsOption
                if tutorialControl ~= nil then
                    tutorialControl:setState(
                        TerraLogicSettings:getTutorialsEnabled()
                            and (TerraLogicSettings.tutorialMode == "context" and 3 or 2) or 1)
                    tutorialControl:setDisabled(false)
                end
                local tutorialResetControl =
                    TerraLogicSettings.tutorialResetButton
                if tutorialResetControl ~= nil then
                    tutorialResetControl:setDisabled(false)
                end
                local stoneControl =
                    TerraLogicSettings.visibleStoneDamageOption
                if stoneControl ~= nil then
                    stoneControl:setState(
                        TerraLogicSettings.visibleStoneDamageModel == "terraLogic"
                            and 2 or 1)
                    stoneControl:setDisabled(
                        not TerraLogicSettings:isLocalAdmin())
                end
                local hudControl = TerraLogicSettings.speedHudModeOption
                if hudControl ~= nil then
                    local mode = TerraLogicSettings.speedHudMode
                    hudControl:setState(mode == "always" and 2
                        or (mode == "warnings" and 3 or (mode == "off" and 4 or 1)))
                    hudControl:setDisabled(false)
                end
                local warningDurationControl =
                    TerraLogicSettings.warningDisplaySecondsOption
                if warningDurationControl ~= nil then
                    warningDurationControl:setState(
                        TerraLogicSettings:getWarningDisplaySeconds())
                    warningDurationControl:setDisabled(false)
                end
                local minimapZoomControl =
                    TerraLogicSettings.soilMinimapZoomOption
                if minimapZoomControl ~= nil then
                    local zoom = TerraLogicSettings:getSoilMinimapZoom()
                    minimapZoomControl:setState(zoom == 0 and 1
                        or (zoom == 1.5 and 2
                            or (zoom == 2 and 3
                                or (zoom == 3 and 4 or 5))))
                    minimapZoomControl:setDisabled(false)
                end
                local damageWarningControl =
                    TerraLogicSettings.damageWarningsOption
                if damageWarningControl ~= nil then
                    damageWarningControl:setState(
                        TerraLogicSettings.damageWarningsEnabled and 2 or 1)
                    damageWarningControl:setDisabled(false)
                end
                if TerraLogicSettings.draftModelBox ~= nil then
                    local parent = TerraLogicSettings.draftModelBox.parent
                    if parent ~= nil and parent.invalidateLayout ~= nil then
                        parent:invalidateLayout()
                    end
                end
            end
        )
        InGameMenuSettingsFrame.terraLogicAdminHookInstalled = true
    end
    return true
end

TerraLogicSettingsEvent = {}
OverSpeedDamageSettingsEvent = TerraLogicSettingsEvent
local TerraLogicSettingsEvent_mt = Class(TerraLogicSettingsEvent, Event)
InitEventClass(TerraLogicSettingsEvent, "TerraLogicSettingsEvent")

-- Multiplayer event ---------------------------------------------------------

-- Constructs an empty settings event for network deserialization.
function TerraLogicSettingsEvent.emptyNew()
    return Event.new(TerraLogicSettingsEvent_mt)
end

function TerraLogicSettingsEvent.new(
        draftModel, physicalDropoutsEnabled, visibleStoneDamageModel,
        soilDevelopmentSpeed, moistureYieldEnabled, mapUpdatePreset, debugEnabled)
    local self = TerraLogicSettingsEvent.emptyNew()
    if debugEnabled == nil then debugEnabled = TerraLogicSettings:getDebugEnabled() end
    self.debugEnabled = debugEnabled == true
    self.mapUpdatePreset = (mapUpdatePreset or TerraLogicSettings.mapUpdatePreset)
        == "fast" and "fast" or "gentle"
    self.draftModel = draftModel == "mr" and "mr" or "terraLogic"
    self.physicalDropoutsEnabled = true
    self.visibleStoneDamageModel = visibleStoneDamageModel == "vanilla"
        and "vanilla" or "terraLogic"
    self.soilDevelopmentSpeed =
        TerraLogicSettings:normalizeSoilDevelopmentSpeed(
            soilDevelopmentSpeed)
    self.moistureYieldEnabled = moistureYieldEnabled == nil
        and TerraLogicSettings:getMoistureYieldEnabled()
        or moistureYieldEnabled ~= false
    return self
end

function TerraLogicSettingsEvent:readStream(streamId, connection)
    self.draftModel = streamReadUIntN(streamId, 1) == 1 and "mr" or "terraLogic"
    streamReadUIntN(streamId, 1) -- legacy always-on field
    self.physicalDropoutsEnabled = true
    self.visibleStoneDamageModel = streamReadUIntN(streamId, 1) == 1
        and "terraLogic" or "vanilla"
    self.soilDevelopmentSpeed =
        TerraLogicSettings:getSoilDevelopmentSpeedFromState(
            streamReadUIntN(streamId, 2) + 1)
    self.moistureYieldEnabled = streamReadBool(streamId)
    self.mapUpdatePreset = streamReadBool(streamId) and "fast" or "gentle"
    self.debugEnabled = streamReadBool(streamId)
    self:run(connection)
end

function TerraLogicSettingsEvent:writeStream(streamId, connection)
    streamWriteUIntN(streamId, self.draftModel == "mr" and 1 or 0, 1)
    streamWriteUIntN(streamId, 1, 1)
    streamWriteUIntN(streamId,
        self.visibleStoneDamageModel == "terraLogic" and 1 or 0, 1)
    streamWriteUIntN(streamId,
        TerraLogicSettings:getSoilDevelopmentSpeedState(
            self.soilDevelopmentSpeed) - 1, 2)
    streamWriteBool(streamId, self.moistureYieldEnabled)
    streamWriteBool(streamId, self.mapUpdatePreset == "fast")
    streamWriteBool(streamId, self.debugEnabled)
end

function TerraLogicSettingsEvent:run(connection)
    if connection:getIsServer() then
        TerraLogicSettings:applyDebugEnabled(self.debugEnabled)
        TerraLogicSettings:applyMapUpdatePreset(self.mapUpdatePreset)
        TerraLogicSettings:applyDraftModel(self.draftModel)
        TerraLogicSettings:applyPhysicalDropoutsEnabled(
            self.physicalDropoutsEnabled)
        TerraLogicSettings:applyVisibleStoneDamageModel(
            self.visibleStoneDamageModel)
        TerraLogicSettings:applySoilDevelopmentSpeed(
            self.soilDevelopmentSpeed)
        TerraLogicSettings:applyMoistureYieldEnabled(
            self.moistureYieldEnabled)
        return
    end
    local userManager = g_currentMission ~= nil and g_currentMission.userManager or nil
    local userId = userManager ~= nil and userManager:getUserIdByConnection(connection) or nil
    local user = userId ~= nil and userManager:getUserByUserId(userId) or nil
    if user == nil or not user:getIsMasterUser() then return end
    TerraLogicSettings:applyDebugEnabled(self.debugEnabled)
    TerraLogicSettings:applyMapUpdatePreset(self.mapUpdatePreset)
    TerraLogicSettings:applyDraftModel(self.draftModel)
    TerraLogicSettings:applyPhysicalDropoutsEnabled(
        self.physicalDropoutsEnabled)
    TerraLogicSettings:applyVisibleStoneDamageModel(
        self.visibleStoneDamageModel)
    TerraLogicSettings:applySoilDevelopmentSpeed(
        self.soilDevelopmentSpeed)
    TerraLogicSettings:applyMoistureYieldEnabled(
        self.moistureYieldEnabled)
    TerraLogicSettings:save()
    g_server:broadcastEvent(TerraLogicSettingsEvent.new(
        TerraLogicSettings.draftModel,
        TerraLogicSettings.physicalDropoutsEnabled,
        TerraLogicSettings.visibleStoneDamageModel,
        TerraLogicSettings.soilDevelopmentSpeed,
        TerraLogicSettings.moistureYieldEnabled))
end

if FSBaseMission ~= nil and FSBaseMission.sendInitialClientState ~= nil
    and FSBaseMission.terraLogicSettingsSyncHookInstalled ~= true then
    FSBaseMission.sendInitialClientState = Utils.appendedFunction(
        FSBaseMission.sendInitialClientState,
        function(_, connection)
            if g_server ~= nil then
                connection:sendEvent(TerraLogicSettingsEvent.new(
                    TerraLogicSettings.draftModel,
                    TerraLogicSettings.physicalDropoutsEnabled,
                    TerraLogicSettings.visibleStoneDamageModel,
                    TerraLogicSettings.soilDevelopmentSpeed))
            end
        end
    )
    FSBaseMission.terraLogicSettingsSyncHookInstalled = true
end
