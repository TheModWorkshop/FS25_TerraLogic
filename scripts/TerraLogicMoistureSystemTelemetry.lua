-- Optional, observational MS diagnostics. Never hooks MS or changes TL water.
-- Reports both the fixed conversion and the actual selected/effective source.
TerraLogicMoistureSystemTelemetry = { MAX_PROBES = 3, MAPPING_ID = "ms-field-v3-wet50" }
local D = TerraLogicMoistureSystemTelemetry
local function finite(v)
    return type(v) == "number" and v == v and math.abs(v) < math.huge
end
local function query(fn, ...)
    if type(fn) == "function" then
        return fn(...)
    end
end
local function method(o, name, ...)
    return o and query(o[name], o, ...)
end
local function add(t, v)
    t[#t + 1] = v == nil and "" or v
end
local contextColumns = {
    "available_end",
    "ready_end",
    "version_end",
    "profile_id_end",
    "scenario_id_end",
    "weather_override_end",
    "month_end",
    "clamp_min_pct_end",
    "clamp_max_pct_end",
    "base_moisture_pct_end",
    "base_moisture_pct_mean",
    "base_moisture_pct_min",
    "base_moisture_pct_max",
    "base_valid_h",
    "gain_multiplier_end",
    "loss_multiplier_end",
    "month_rate_factor_end",
    "rate_scale_end",
    "update_interval_real_ms_end",
    "update_window_game_h_end",
    "update_age_game_h_estimate_end",
    "base_changes_interval",
    "read_errors_interval",
    "candidate_mapping_id",
    "withering_enabled_end",
    "irrigation_active_boosts_end",
    "irrigation_job_count_end",
    "next_year_scenario_id_end",
    "moisture_source_selected_end",
    "moisture_source_active_end",
    "irrigation_deliveries_total",
    "adapter_read_errors_total",
}
local weights = { "rain", "thunder", "snow", "hail", "sun", "partlyCloudy", "cloudy", "tempMin", "tempMax" }
local probeColumns = {
    "source",
    "x_m",
    "z_m",
    "height_m",
    "soil_index",
    "tl_field_id_end",
    "tl_uses_field_store_end",
    "tl_upper_vol_pct_end",
    "tl_lower_vol_pct_end",
    "tl_crop_kcb_end",
    "tl_crop_cover_end",
    "tl_crops_sample_counts_end",
    "ms_moisture_pct_end",
    "ms_irrigation_boost_pp_end",
    "ms_candidate_upper_vol_pct_end",
    "ms_candidate_upper_traffic_multiplier_end",
    "tl_upper_traffic_multiplier_end",
    "tl_lower_traffic_multiplier_end",
    "ms_wheat_yield_factor_end",
    "ms_maize_yield_factor_end",
    "ms_soybean_yield_factor_end",
    "tl_water_source_end",
    "tl_ms_reference_upper_vol_pct_end",
    "tl_ms_reference_lower_vol_pct_end",
    "tl_ms_input_last_step_mm",
    "tl_ms_drying_last_step_mm",
    "tl_irrigation_pending_mm_end",
}

-- Fixed anchors shared by every month/crop; calibrated as gameplay, not a
-- measurement of physical grain/soil water. All values inside are fractions.
function D:mapCandidate(value, h)
    return TerraLogicMoistureSystemAdapter:mapMoisture(value, h)
end

function D:resetInterval()
    self.sum, self.hours, self.minimum, self.maximum = 0, 0, nil, nil
    self.changes, self.errors = 0, 0
end
function D:start()
    self.probes = {}
    self:resetInterval()
    local ms = g_currentMission and g_currentMission.MoistureSystem
    self.previousBase = ms
            and ms.missionStarted == true
            and finite(ms.currentMoisturePercent)
            and ms.currentMoisturePercent * 100
        or nil
    local player = g_localPlayer
    local vehicle = method(g_currentMission, "getControlledVehicle")
    local node = vehicle and vehicle.rootNode
    local x, z
    if node and type(getWorldTranslation) == "function" then
        local px, _, pz = getWorldTranslation(node)
        do
            x, z = px, pz
        end
    elseif player and type(player.getPositionData) == "function" then
        local px, _, pz = player.getPositionData(player)
        do
            x, z = px, pz
        end
    elseif player and player.rootNode and type(getWorldTranslation) == "function" then
        local px, _, pz = getWorldTranslation(player.rootNode)
        do
            x, z = px, pz
        end
    end
    if finite(x) and finite(z) then
        self.probes[1] = { x = x, z = z, source = "position_at_recording_start" }
    end
end
function D:observe(hours)
    local ms = g_currentMission and g_currentMission.MoistureSystem
    local v = ms and ms.currentMoisturePercent
    if not ms or ms.missionStarted ~= true or not finite(v) then
        return
    end
    v = v * 100
    self.sum = self.sum + v * hours
    self.hours = self.hours + hours
    self.minimum = self.minimum and math.min(self.minimum, v) or v
    self.maximum = self.maximum and math.max(self.maximum, v) or v
    if self.previousBase and v ~= self.previousBase then
        self.changes = self.changes + 1
    end
    self.previousBase = v
end
function D:appendHeader(header)
    for _, n in ipairs(contextColumns) do
        add(header, "ms_" .. n)
    end
    for _, n in ipairs(weights) do
        add(header, "ms_profile_" .. n .. "_end")
    end
    for i = 0, 4 do
        add(header, "ms_base_candidate_soil" .. i .. "_upper_vol_pct_end")
    end
    for i = 1, self.MAX_PROBES do
        for _, n in ipairs(probeColumns) do
            add(header, "comparison" .. i .. "_" .. n)
        end
    end
end
function D:fillProbes()
    self.probes = self.probes or {}
    if #self.probes >= self.MAX_PROBES then
        return
    end
    local fm = TerraLogicFieldWaterManager
    for _, id in ipairs(fm and fm.ids or {}) do
        local f = fm.fields[id]
        for _, p in ipairs(f.points or { { x = f.x, z = f.z } }) do
            local key = math.floor(p.x / 8) .. ":" .. math.floor(p.z / 8)
            if f.cells[key] then
                local distinct = true
                for _, q in ipairs(self.probes) do
                    if (p.x - q.x) ^ 2 + (p.z - q.z) ^ 2 < 32 ^ 2 then
                        distinct = false
                        break
                    end
                end
                if distinct then
                    self.probes[#self.probes + 1] = { x = p.x, z = p.z, source = "fixed_field_reference" }
                    if #self.probes >= self.MAX_PROBES then
                        return
                    end
                end
            end
        end
    end
end
function D:readLocal(ms, x, z)
    if not ms or ms.missionStarted ~= true or type(ms.getMoistureAtPosition) ~= "function" then
        return nil
    end
    local value = ms.getMoistureAtPosition(ms, x, z)
    if finite(value) then
        return value
    end
    self.errors = self.errors + 1
end
function D:appendValues(values, timeScale)
    local mission = g_currentMission or {}
    local ms = mission.MoistureSystem
    local env = FS25_MoistureSystem
    local wps = mission.WeatherProfileSystem
    local settings = ms and ms.settings or {}
    local month = ms and query(ms.periodToMonth, (mission.environment or {}).currentPeriod)
    local clamp = month and method(wps, "getClampForMonth", month) or {}
    local md = month and method(wps, "getMonthData", month) or {}
    clamp = clamp or {}
    md = md or {}
    local base = ms and ms.currentMoisturePercent
    local ready = ms ~= nil and ms.missionStarted == true and finite(base)
    local mod = method(g_modManager, "getModByName", "FS25_MoistureSystem")
    local version = mod and (mod.versionString or mod.version)
    if type(version) ~= "string" and type(version) ~= "number" then
        version = nil
    end
    local interval = ms and tonumber(ms.updateInterval)
    local age = ms and tonumber(ms.timeSinceLastUpdate)
    local info = {
        available_end = ms ~= nil,
        ready_end = ready,
        version_end = version,
        moisture_source_selected_end = TerraLogicSettings and TerraLogicSettings.moistureSource or "terraLogic",
        moisture_source_active_end = TerraLogicMoistureSystemAdapter:isUsingMS() and "moistureSystem" or "terraLogic",
        irrigation_deliveries_total = TerraLogicMoistureSystemAdapter.receipts or 0,
        adapter_read_errors_total = TerraLogicMoistureSystemAdapter.readErrors or 0,
        profile_id_end = settings.weatherProfile,
        scenario_id_end = wps and wps.activeScenarioId,
        weather_override_end = settings.overrideWeather,
        month_end = month,
        clamp_min_pct_end = clamp.min,
        clamp_max_pct_end = clamp.max,
        base_moisture_pct_end = ready and base * 100 or nil,
        base_moisture_pct_mean = self.hours > 0 and self.sum / self.hours or nil,
        base_moisture_pct_min = self.minimum,
        base_moisture_pct_max = self.maximum,
        base_valid_h = self.hours,
        gain_multiplier_end = settings.moistureGainMultiplier,
        loss_multiplier_end = settings.moistureLossMultiplier,
        month_rate_factor_end = method(ms, "getScaleFactor"),
        rate_scale_end = ms and ms.RATE_SCALE,
        update_interval_real_ms_end = interval,
        update_window_game_h_end = interval and interval * timeScale / 3600000,
        update_age_game_h_estimate_end = age and age * timeScale / 3600000,
        base_changes_interval = self.changes,
        candidate_mapping_id = self.MAPPING_ID,
        withering_enabled_end = settings.witheringEnabled,
        irrigation_active_boosts_end = mission.irrigationSystem and mission.irrigationSystem.anyActiveBoosts,
        irrigation_job_count_end = mission.irrigationSystem and #(mission.irrigationSystem.jobs or {}),
        next_year_scenario_id_end = wps and wps.nextYearScenarioId,
    }
    -- Do not bind new reference positions when MS is absent. Existing positions
    -- remain fixed for the whole recording, even when the player moves away.
    if ready then
        self:fillProbes()
    end
    local probeRows = {}
    local m = TerraLogicSoilMoistureManager
    for i = 1, self.MAX_PROBES do
        local p = self.probes and self.probes[i]
        local row = {}
        if p then
            local fm = TerraLogicFieldWaterManager
            local f = method(fm, "getField", p.x, p.z)
            local c = f and f.cells[math.floor(p.x / 8) .. ":" .. math.floor(p.z / 8)]
            local soil = c and c.soil or method(TerraLogicSoilManager, "getPFSoilTypeAtWorldPosition", p.x, p.z)
            soil = method(m, "getProfileIndex", soil) or 0
            local w = f and f.stores[soil] or m.waterStores and m.waterStores[soil]
            local h = m.HYDRAULICS[soil]
            local moisture = self:readLocal(ms, p.x, p.z)
            local mapped = self:mapCandidate(moisture, h)
            local t = TerraLogicSoilTemperatureManager or {}
            local function traffic(theta, frozen)
                if not finite(theta) then
                    return nil
                end
                if frozen then
                    return 1
                end
                local suction = method(m, "getMatricSuction", theta, soil)
                return finite(suction) and 0.72 + 0.78 / (1 + (suction / h.suctionFC) ^ 0.8) or nil
            end
            local farmland = method(g_farmlandManager, "getFarmlandIdAtWorldPosition", p.x, p.z)
            local boost = farmland and method(mission.irrigationSystem, "getBoost", farmland)
            local names = {}
            for fruit, count in pairs(f and f.vegetation and f.vegetation.crops or {}) do
                local desc = method(g_fruitTypeManager, "getFruitTypeByIndex", fruit)
                names[#names + 1] = tostring(desc and desc.name or fruit) .. ":" .. tostring(count)
            end
            table.sort(names)
            local height = query(getTerrainHeightAtWorldPos, g_terrainNode, p.x, 0, p.z)
            row = {
                source = p.source,
                x_m = p.x,
                z_m = p.z,
                height_m = height,
                soil_index = soil,
                tl_field_id_end = f and f.id,
                tl_uses_field_store_end = f ~= nil,
                tl_upper_vol_pct_end = w and w.upper / 150 * 100,
                tl_lower_vol_pct_end = w and w.lower / 450 * 100,
                tl_crop_kcb_end = f and f.vegetation and f.vegetation.kcb,
                tl_crop_cover_end = f and f.vegetation and f.vegetation.cover,
                tl_crops_sample_counts_end = table.concat(names, "|"),
                ms_moisture_pct_end = moisture and moisture * 100,
                ms_irrigation_boost_pp_end = boost and boost * 100,
                ms_candidate_upper_vol_pct_end = mapped and mapped * 100,
                ms_candidate_upper_traffic_multiplier_end = traffic(mapped, t.surfaceFrozen),
                tl_upper_traffic_multiplier_end = traffic(w and w.upper / 150, t.surfaceFrozen),
                tl_lower_traffic_multiplier_end = traffic(w and w.lower / 450, t.subsoilFrozen),
                tl_water_source_end = w and w.msWaterSource == 1 and "moistureSystem" or "terraLogic",
                tl_ms_reference_upper_vol_pct_end = w and w.msRefUpper and w.msRefUpper / 150 * 100,
                tl_ms_reference_lower_vol_pct_end = w and w.msRefLower and w.msRefLower / 450 * 100,
                tl_ms_input_last_step_mm = w and w.lastMSInputMm,
                tl_ms_drying_last_step_mm = w and w.lastMSDryingMm,
                tl_irrigation_pending_mm_end = w and (w.msIrrigationPendingMm or 0),
            }
            for _, crop in ipairs({ "WHEAT", "MAIZE", "SOYBEAN" }) do
                local index = method(g_fillTypeManager, "getFillTypeIndexByName", crop)
                local cv = env and env.CropValueMap
                local factor = moisture and index and cv and query(cv.getYieldMultiplier, index, moisture)
                if finite(factor) then
                    row["ms_" .. crop:lower() .. "_yield_factor_end"] = factor
                end
            end
        end
        probeRows[i] = row
    end
    info.read_errors_interval = self.errors
    for _, n in ipairs(contextColumns) do
        add(values, info[n])
    end
    for _, n in ipairs(weights) do
        add(values, md[n])
    end
    for i = 0, 4 do
        local v = ready and self:mapCandidate(base, m.HYDRAULICS[i])
        add(values, v and v * 100)
    end
    for i = 1, self.MAX_PROBES do
        for _, n in ipairs(probeColumns) do
            add(values, probeRows[i][n])
        end
    end
end
