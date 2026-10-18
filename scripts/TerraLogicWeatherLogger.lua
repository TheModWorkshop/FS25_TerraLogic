-- Opt-in diagnostics only: no writes to weather, savegame or soil state.
TerraLogicWeatherLogger = {active=false, intervalHours=5/60}
local L=TerraLogicWeatherLogger
local function call(o,k)
    if o and type(o[k])=='function' then local ok,v=pcall(o[k],o);if ok then return v end end
end
local function finite(v) return type(v)=='number' and v==v and math.abs(v)<math.huge end
local function cell(v)
    if v==nil then v='' elseif finite(v) then v=string.format('%.8f',v) end
    return '"'..tostring(v):gsub('"','""'):gsub('[\r\n]',' ')..'"'
end
local measurements={
    {'rain_scale','getRainFallScale'}, {'snow_scale','getSnowFallScale'},
    {'hail_scale','getHailFallScale'}, {'ground_wetness','getGroundWetness'},
    {'air_C','getCurrentTemperature'}
}
local fluxNames={'input_mm','infiltration_mm','transfer_mm','drainage_mm',
    'evaporation_mm','uptake_mm','runoff_mm','upper_uptake_mm','lower_uptake_mm','balance_error_mm'}
local thermalColumns={'temperature_save_version','temperature_days_per_period',
    'temperature_calendar_scale_end','temperature_calendar_source','thermal_elapsed_h',
    'temperature_filtered_air_C_end','temperature_climate_mean_C_end',
    'recovery_jobs_completed','recovery_last_serial_end','recovery_queue_length_end',
    'recovery_job_active_end','recovery_surface_cells_changed','recovery_deep_cells_changed'}
local layerColumns={'temperature_C_min','temperature_C_max','frozen_game_h','frozen_thermal_h',
    'phase_frozen_thermal_h_end','phase_minimum_C_end','cycles_total_end','cycles_interval',
    'thaw_pulse_raw_generated','thaw_pulse_weighted_generated','thaw_pulse_pending_end',
    'thaw_pulse_handed_to_recovery','thaw_pulse_completed_recovery'}
function L:resetInterval()
    self.hours=0;self.realSeconds=0;self.maxFrameHours=0
    self.means={};self.fluxes={};self.validModelHours=0
    self.liquidHours=0;self.rainHours=0;self.snowHours=0
    self.solidInputMm=0;self.meltMm=0;self.precipitationMm=0
    self.thermalHours=0;self.thermalLayers={surface={},deep={}}
    self.completedRecoveryJobs=0;self.recoverySurfaceChanges=0;self.recoveryDeepChanges=0
    if TerraLogicMoistureSystemTelemetry then TerraLogicMoistureSystemTelemetry:resetInterval() end
end
function L:write(values)
    local cells={};for i=1,#values do cells[i]=cell(values[i]) end
    local ok,result=pcall(fileWrite,self.file,table.concat(cells,';')..'\n')
    if not ok or result==false then
        self.active=false
        if self.file then pcall(delete,self.file);self.file=nil end
        Logging.warning('[FS25_TerraLogic] Weather logger stopped: CSV write failed')
        return false
    end
    return true
end
function L:command(action,label)
    action=tostring(action or 'status'):lower()
    if action=='stop' then return self:stop() end
    if action=='status' then
        return self.active and ('Weather logger ON | rows='..self.rows..' | '..self.path)
            or 'Weather logger OFF | tlWeatherLog start [name]'
    end
    if action~='start' then return 'tlWeatherLog start [name] | stop | status' end
    if self.active then return self:command('status') end
    if not g_currentMission or not g_currentMission:getIsServer() then
        return 'Weather logger: start on the host/server.'
    end
    if not createFile or not fileWrite or not FileAccess or not fileExists
        or not createFolder or not getUserProfileAppPath or not getDate then
        return 'Weather logger: file API unavailable.'
    end
    local m=TerraLogicSoilMoistureManager
    if not m or not m.initialized then return 'Weather logger: soil model not ready.' end
    local root=getUserProfileAppPath()..'modSettings'
    local directory=root..'/FS25_TerraLogic/weatherLogs'
    for _,p in ipairs({root,root..'/FS25_TerraLogic',directory}) do pcall(createFolder,p) end
    label=tostring(label or 'weather'):gsub('[^%w_-]','_'):sub(1,40)
    local stem=directory..'/TerraLogic_weather_'..label..'_'..getDate('%Y%m%d_%H%M%S')
    local path=stem..'.csv';local suffix=0
    while fileExists(path) do suffix=suffix+1;path=stem..'_'..suffix..'.csv' end
    local ok,file=pcall(createFile,path,FileAccess.WRITE)
    if not ok or not file or file==0 then return 'Weather logger: cannot create '..path end
    self.file=file;self.path=path;self.rows=0;self.active=true;self:resetInterval()
    if TerraLogicMoistureSystemTelemetry then TerraLogicMoistureSystemTelemetry:start() end
    self.lastSim=m.simulatedGameHours or 0;self.lastDropped=m.droppedGameHours or 0
    self.lastSnowHeight=m:getSnowHeight()
    local e=g_currentMission.environment or {}
    self.lastClock=(e.currentMonotonicDay or 0)*24+(e.dayTime or 0)/3600000
    local header={'schema','event','row','real_time','map_id','year','period','day',
        'hour','days_per_period','time_scale','interval_game_h','interval_real_s',
        'clock_elapsed_h','model_elapsed_h','model_dropped_h','max_frame_game_h',
        'weather_type_end','weather_valid_end','audit_override_end','valid_model_h',
        'rain_present_h','snow_present_h','model_liquid_scale_h','crop_daily_moisture_vol_pct',
        'surface_frozen','subsoil_frozen','model_evaporation_factor_end',
        'surface_temperature_C_end','subsoil_temperature_C_end'}
    for _,v in ipairs(measurements) do
        for _,s in ipairs({'mean','min','max','valid_h'}) do header[#header+1]=v[1]..'_'..s end
    end
    for i=0,4 do
        header[#header+1]='soil'..i..'_surface_vol_pct';header[#header+1]='soil'..i..'_deep_vol_pct'
        for _,n in ipairs(fluxNames) do header[#header+1]='soil'..i..'_model_'..n end
    end
    for _,name in ipairs({'model_fingerprint','snow_height_m_end','snow_height_change_m',
        'snow_water_mm_end','model_solid_input_mm','model_melt_mm','model_total_precipitation_mm',
        'snow_initialization','snow_api_available','hail_api_available','snow_enabled',
        'rain_mm_per_hour','snow_mm_per_hour','melt_mm_per_degree_day'}) do
        header[#header+1]=name
    end
    header[#header+1]='moisture_unit'
    for i=0,4 do
        for _,name in ipairs({'wilting_vol_pct','field_capacity_vol_pct','saturation_vol_pct',
            'surface_available_fraction','deep_available_fraction','surface_suction_kPa',
            'deep_suction_kPa','surface_traffic_multiplier','deep_traffic_multiplier'}) do
            header[#header+1]='soil'..i..'_'..name
        end
    end
    for _,name in ipairs(thermalColumns) do header[#header+1]=name end
    for _,layer in ipairs({'surface','deep'}) do
        for _,name in ipairs(layerColumns) do header[#header+1]=layer..'_'..name end
    end
    for _,name in ipairs({'field_water_count','precipitation_state','precipitation_factor','field_water_pending_h'}) do header[#header+1]=name end
    for i=0,4 do
        for _,name in ipairs({'area_m2','upper_vol_pct_mean','lower_vol_pct_mean',
            'upper_vol_pct_min','upper_vol_pct_max','lower_vol_pct_min','lower_vol_pct_max',
            'crop_kcb_mean','crop_cover_mean'}) do header[#header+1]='field_soil'..i..'_'..name end
    end
    if TerraLogicMoistureSystemTelemetry then TerraLogicMoistureSystemTelemetry:appendHeader(header) end
    if not self:write(header) then return 'Weather logger: header write failed.' end
    self:sample('start')
    if not self.active then return 'Weather logger: initial sample failed.' end
    Logging.info('[FS25_TerraLogic] Weather logger started: %s',path)
    return 'Weather logger STARTED | '..path
end
-- Exact amounts already computed by the model; no duplicate simulation.
function L:recordThermalStep(hours, temperature)
    self.thermalHours=self.thermalHours+hours
    local scale=math.max(tonumber(temperature.calendarScale) or 1,1)
    for _,layer in ipairs({'surface','deep'}) do
        local prefix=layer=='surface' and 'surface' or 'subsoil'
        local value=temperature[prefix..'TemperatureC']
        local a=self.thermalLayers[layer]
        if finite(value) then
            a.min=a.min and math.min(a.min,value) or value
            a.max=a.max and math.max(a.max,value) or value
        end
        if temperature[prefix..'Frozen'] then
            a.gameHours=(a.gameHours or 0)+hours/scale
            a.thermalHours=(a.thermalHours or 0)+hours
        end
    end
end
function L:recordThawGenerated(prefix, raw, weighted)
    local a=self.thermalLayers[prefix=='surface' and 'surface' or 'deep']
    a.cycles=(a.cycles or 0)+1
    a.raw=(a.raw or 0)+raw;a.weighted=(a.weighted or 0)+weighted
end
function L:recordThawConsumed(surface,deep)
    self.thermalLayers.surface.consumed=(self.thermalLayers.surface.consumed or 0)+surface
    self.thermalLayers.deep.consumed=(self.thermalLayers.deep.consumed or 0)+deep
end
function L:recordRecoveryCompleted(job)
    local snapshot=job.snapshot or {}
    self.completedRecoveryJobs=self.completedRecoveryJobs+1
    self.recoverySurfaceChanges=self.recoverySurfaceChanges+(job.surfaceCompactionChanges or 0)
    self.recoveryDeepChanges=self.recoveryDeepChanges+(job.deepCompactionChanges or 0)
    self.thermalLayers.surface.completed=(self.thermalLayers.surface.completed or 0)+(snapshot.surfaceThawPulse or 0)
    self.thermalLayers.deep.completed=(self.thermalLayers.deep.completed or 0)+(snapshot.deepThawPulse or 0)
end
function L:recordSnowFlux(solid,melt,precipitation)
    self.solidInputMm=self.solidInputMm+solid
    self.meltMm=self.meltMm+melt
    self.precipitationMm=self.precipitationMm+precipitation
end
function L:recordFlux(index,input,infiltration,transfer,drainage,evaporation,uptake,upperUptake,lowerUptake,error)
    local f=self.fluxes[index]
    if not f then f={0,0,0,0,0,0,0,0,0,0};self.fluxes[index]=f end
    f[1]=f[1]+input;f[2]=f[2]+infiltration;f[3]=f[3]+transfer
    f[4]=f[4]+drainage;f[5]=f[5]+evaporation;f[6]=f[6]+uptake
    f[7]=f[7]+input-infiltration
    f[8]=f[8]+(upperUptake or 0);f[9]=f[9]+(lowerUptake or 0)
    f[10]=f[10]+(error or 0)
end
function L:update(dt)
    if not self.active then return end
    local m=TerraLogicSoilMoistureManager
    local ms=math.max(tonumber(dt) or 0,0)
    local hours=ms*m:getEffectiveTimeScale()/3600000
    if hours<=0 then return end
    self.hours=self.hours+hours;self.realSeconds=self.realSeconds+ms/1000
    self.maxFrameHours=math.max(self.maxFrameHours,hours)
    if TerraLogicMoistureSystemTelemetry then TerraLogicMoistureSystemTelemetry:observe(hours) end
    local weather=g_currentMission.environment and g_currentMission.environment.weather
    for _,v in ipairs(measurements) do
        local value=call(weather,v[2])
        if finite(value) then
            local a=self.means[v[1]] or {sum=0,hours=0,min=value,max=value}
            a.sum=a.sum+value*hours;a.hours=a.hours+hours
            a.min=math.min(a.min,value);a.max=math.max(a.max,value);self.means[v[1]]=a
            if v[1]=='rain_scale' and value>0.001 then self.rainHours=self.rainHours+hours end
            if v[1]=='snow_scale' and value>0.001 then self.snowHours=self.snowHours+hours end
        end
    end
    if m.weatherDataValid and not m.auditOverrideActive then
        local h=math.min(hours,m.MAX_GAME_HOURS_PER_UPDATE)
        self.validModelHours=self.validModelHours+h
        self.liquidHours=self.liquidHours+(m.rainScale or 0)*(m.liquidPrecipitationFactor or 0)*h
    end
    if self.hours+1e-9>=self.intervalHours then self:sample('sample') end
end
function L:sample(event)
    local m=TerraLogicSoilMoistureManager
    local mission=g_currentMission or {};local e=mission.environment or {}
    local t=TerraLogicSoilTemperatureManager or {}
    local clock=(e.currentMonotonicDay or 0)*24+(e.dayTime or 0)/3600000
    local sim=m.simulatedGameHours or 0;local dropped=m.droppedGameHours or 0
    self.rows=self.rows+1
    local values={7,event,self.rows,getDate('%Y-%m-%dT%H:%M:%S'),
        (mission.missionInfo or {}).mapId or '',e.currentYear or '',e.currentPeriod or '',
        e.currentMonotonicDay or '',(e.dayTime or 0)/3600000,e.daysPerPeriod or '',
        m:getEffectiveTimeScale(),self.hours,self.realSeconds,clock-self.lastClock,
        sim-self.lastSim,dropped-self.lastDropped,self.maxFrameHours,
        call(e.weather,'getCurrentWeatherType') or '',m.weatherDataValid==true,
        m.auditOverrideActive==true,self.validModelHours,self.rainHours,self.snowHours,
        self.liquidHours,(m.rootMoisture or 0)*100,t.surfaceFrozen==true,
        t.subsoilFrozen==true,m.evaporationFactor or '',
        t.surfaceTemperatureC or '',t.subsoilTemperatureC or ''}
    for _,v in ipairs(measurements) do
        local a=self.means[v[1]]
        values[#values+1]=a and a.sum/a.hours or ''
        values[#values+1]=a and a.min or '';values[#values+1]=a and a.max or ''
        values[#values+1]=a and a.hours or 0
    end
    for i=0,4 do
        local w=m.waterStores and m.waterStores[i];local h=m.HYDRAULICS[i]
        values[#values+1]=w and w.upper/150*100 or ''
        values[#values+1]=w and w.lower/450*100 or ''
        for j=1,#fluxNames do values[#values+1]=self.fluxes[i] and self.fluxes[i][j] or 0 end
    end
    local height=m:getSnowHeight()
    local extra={m.SOURCE_FINGERPRINT,height or '',
        height~=nil and self.lastSnowHeight~=nil and height-self.lastSnowHeight or '',
        m.snowWaterMm or 0,self.solidInputMm,self.meltMm,self.precipitationMm,
        m.snowInitialization or '',finite(call(e.weather,'getSnowFallScale')),
        finite(call(e.weather,'getHailFallScale')),
        mission.isSnowEnabled==nil and '' or mission.isSnowEnabled,
        m.RAIN_MM_PER_HOUR,m.SNOW_MM_PER_HOUR,m.MELT_MM_PER_DEGREE_DAY}
    for _,v in ipairs(extra) do values[#values+1]=v end
    values[#values+1]='vol.%'
    for i=0,4 do
        local h=m.HYDRAULICS[i]
        local u,d=m:getProfileState(i)
        local mu,md=m:getTrafficMultipliers(i)
        local diagnostics={h.wilt*100,h.fieldCapacity*100,h.saturation*100,
            m:getAvailableWater(u,i),m:getAvailableWater(d,i),
            m:getMatricSuction(u,i),m:getMatricSuction(d,i),mu,md}
        for _,v in ipairs(diagnostics) do values[#values+1]=v end
    end
    local soil=TerraLogicSoilManager or {}
    local snapshot=soil.recoveryLastSnapshot or {}
    local thermal={t.SAVE_VERSION or '',t.daysPerPeriod or '',t.calendarScale or '',
        t.daysPerPeriodSource or '',self.thermalHours,t.dailyMeanTemperatureC or '',
        t.climateMeanTemperatureC or '',self.completedRecoveryJobs,snapshot.serial or '',
        #(soil.recoverySnapshotQueue or {}),soil.recoveryJob~=nil,
        self.recoverySurfaceChanges,self.recoveryDeepChanges}
    for _,v in ipairs(thermal) do values[#values+1]=v end
    for _,layer in ipairs({'surface','deep'}) do
        local a=self.thermalLayers[layer]
        local prefix=layer=='surface' and 'surface' or 'subsoil'
        local cycleKey=layer=='surface' and 'surfaceFreezeThawCycles' or 'deepFreezeThawCycles'
        local pulseKey=layer=='surface' and 'pendingSurfaceThawPulse' or 'pendingDeepThawPulse'
        local diagnostics={a.min or '',a.max or '',a.gameHours or 0,a.thermalHours or 0,
            t[prefix..'FrozenHours'] or '',t[prefix..'FreezeMinimumC'] or '',
            t[cycleKey] or '',a.cycles or 0,a.raw or 0,a.weighted or 0,
            t[pulseKey] or '',a.consumed or 0,a.completed or 0}
        for _,v in ipairs(diagnostics) do values[#values+1]=v end
    end
    local fm=TerraLogicFieldWaterManager
    local setting=TerraLogicSettings and TerraLogicSettings.precipitationState or 2
    values[#values+1]=fm and #(fm.ids or {}) or 0
    values[#values+1]=setting
    values[#values+1]=TerraLogicMoistureSystemAdapter:isUsingMS() and 1
        or fm and fm.PRECIPITATION_FACTORS[setting] or 1
    values[#values+1]=fm and fm.pendingWater and fm.pendingWater.hours or 0
    for i=0,4 do
        local area,u,d,kcb,cover=0,0,0,0,0
        local minU,maxU,minD,maxD=math.huge,-math.huge,math.huge,-math.huge
        for _,f in pairs(fm and fm.fields or {}) do
            local a=(f.soilAreas or {})[i] or 0
            if a>0 then
                local w=f.stores[i];local x,y=w.upper/150*100,w.lower/450*100
                area,u,d=area+a,u+x*a,d+y*a
                kcb=kcb+(f.vegetation.kcb or 0)*a;cover=cover+(f.vegetation.cover or 0)*a
                minU,maxU,minD,maxD=math.min(minU,x),math.max(maxU,x),math.min(minD,y),math.max(maxD,y)
            end
        end
        local items=area>0 and {area,u/area,d/area,minU,maxU,minD,maxD,kcb/area,cover/area}
            or {0,'','','','','','','',''}
        for _,v in ipairs(items) do values[#values+1]=v end
    end
    if TerraLogicMoistureSystemTelemetry then
        TerraLogicMoistureSystemTelemetry:appendValues(values,m:getEffectiveTimeScale())
    end
    self.lastSnowHeight=height
    self:write(values)
    self.lastClock=clock;self.lastSim=sim;self.lastDropped=dropped;self:resetInterval()
end
function L:stop()
    if not self.active then return 'Weather logger is not active.' end
    self:sample('stop');self.active=false
    if self.file then pcall(delete,self.file);self.file=nil end
    return 'Weather logger STOPPED | rows='..self.rows..' | '..self.path
end
