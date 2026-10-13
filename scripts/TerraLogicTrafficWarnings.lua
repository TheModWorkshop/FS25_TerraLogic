-- Read-only warning summaries from the existing authoritative wheel pass.
-- No extra wheel-physics queries, soil probes or persistent savegame data.
TerraLogicTrafficWarnings = {}
TerraLogicTrafficWarnings.INTERVAL_MS = 250
TerraLogicTrafficWarnings.SAMPLE_MAX_AGE_MS = 1500
TerraLogicTrafficWarnings.REPLY_MAX_AGE_MS = 2500

local function timeNow()
    return g_currentMission ~= nil and (g_currentMission.time or 0) or 0
end

local function rootOf(vehicle)
    if vehicle ~= nil and vehicle.getRootVehicle ~= nil then
        return vehicle:getRootVehicle() or vehicle
    end
    return vehicle
end

function TerraLogicTrafficWarnings:load()
    self.samples = setmetatable({}, {__mode="k"})
    self.requestTimes = setmetatable({}, {__mode="k"})
    self.vehicle, self.reply, self.pending = nil, nil, {}
    self.serial, self.appliedSerial, self.nextRequest = 0, 0, 0
    self.display = setmetatable({}, {__mode="k"})
end

function TerraLogicTrafficWarnings:delete()
    self:load()
end

-- Read the resulting state of the contacted cells after the authoritative update.
-- Sampling and warnings do not change the authoritative soil simulation.
function TerraLogicTrafficWarnings:newStatus()
    return {surface=0,deep=0,surfaceKnown=false,deepKnown=false,wet=false,pressure=false,axle=false}
end

-- Post-pass compaction, not targets, deltas or probabilities. Boundaries are
-- rounded from roughly 1/4/8% of the reference layer yield-loss curves.
TerraLogicTrafficWarnings.COMPACTION_THRESHOLDS = {
    surface={0.40,0.57,0.75}, deep={0.20,0.35,0.50}
}
function TerraLogicTrafficWarnings:getCompactionLevel(layer,value)
    local t=self.COMPACTION_THRESHOLDS[layer]
    return value>=t[3] and 4 or value>=t[2] and 3 or value>=t[1] and 2 or 1
end
function TerraLogicTrafficWarnings:accumulate(status, detail)
    local sc,dc=detail.surfaceCoverage or 0,detail.deepCoverage or 0
    -- SoilManager supplies after even when the pass does not increase compaction.
    -- Never substitute a target or a zero for missing measurements.
    local after=detail.after or {}
    local sr=tonumber(after.surfaceCompaction)
    local dr=tonumber(after.deepCompaction)
    if sr==nil then sc=0 else sr=math.min(math.max(sr,0),1) end
    if dr==nil then dc=0 else dr=math.min(math.max(dr,0),1) end
    if (detail.surfaceAppliedStrength or 0)<=0 then sc=0 end
    if (detail.deepAppliedStrength or 0)<=0 then dc=0 end
    if sc>0 then status.surfaceKnown=true;status.surface=math.max(status.surface,sr) end
    if dc>0 then status.deepKnown=true;status.deep=math.max(status.deep,dr) end
    local highSurface=sc>0 and self:getCompactionLevel('surface',sr)>=3
    local highDeep=dc>0 and self:getCompactionLevel('deep',dr)>=3
    status.pressure=status.pressure or highSurface
    status.axle=status.axle or highDeep
    status.wet=status.wet or (highSurface and (detail.trafficSurfaceMultiplier or 1)>=1.08)
        or (highDeep and (detail.trafficDeepMultiplier or 1)>=1.08)
end
function TerraLogicTrafficWarnings:getImpactLevel(detail)
    local s=self:newStatus();self:accumulate(s,detail)
    return (s.pressure or s.axle) and (s.wet and 3 or 2) or (s.wet and 1 or 0)
end

function TerraLogicTrafficWarnings:record(vehicle, level, now, status)
    if self.samples == nil then return end
    local sample = self.samples[vehicle] or {}
    status=status or self:newStatus()
    local previous=sample.status or self:newStatus()
    -- Deep cells are sampled less often than surface contacts. Keep only a
    -- short, timestamped sample between cell crossings; never retain it forever.
    for _,layer in ipairs({'surface','deep'}) do
        local stamp=layer..'Time'
        if status[layer..'Known'] then sample[stamp]=now
        elseif sample[stamp] and now-sample[stamp]<=self.SAMPLE_MAX_AGE_MS then
            status[layer..'Known']=previous[layer..'Known'];status[layer]=previous[layer]
        end
    end
    for _,cause in ipairs({'wet','pressure','axle'}) do
        local stamp=cause..'Time'
        if status[cause] then sample[stamp]=now
        elseif sample[stamp] and now-sample[stamp]<=self.SAMPLE_MAX_AGE_MS then status[cause]=true end
    end
    level=(status.pressure or status.axle) and (status.wet and 3 or 2) or (status.wet and 1 or 0)
    sample.time, sample.level = now, level
    sample.status=status
    self.samples[vehicle] = sample
end

function TerraLogicTrafficWarnings:getServerStatus(vehicle, now)
    local level, source, visited, count = 0, nil, {}, 0
    local combined=self:newStatus()
    local function visit(object)
        if object == nil or visited[object] or count >= 64 then return end
        visited[object], count = true, count + 1
        local sample = (self.samples or {})[object]
        if sample ~= nil and now - sample.time <= self.SAMPLE_MAX_AGE_MS then
            if sample.level>level then level,source=sample.level,object end
            local s=sample.status or self:newStatus()
            for _,layer in ipairs({'surface','deep'}) do
                if s[layer..'Known'] then
                    combined[layer..'Known']=true
                    if combined[layer..'Source']==nil or s[layer]>combined[layer] then
                        combined[layer]=s[layer];combined[layer..'Source']=object
                    end
                end
            end
            for _,cause in ipairs({'wet','pressure','axle'}) do
                if s[cause] then combined[cause]=true;combined[cause..'Source']=object end
            end
        end
        if object.getChildVehicles ~= nil then
            for _, child in pairs(object:getChildVehicles() or {}) do visit(child) end
        end
        local joints = object.spec_attacherJoints
        for _, attached in pairs(joints ~= nil and joints.attachedImplements or {}) do
            visit(attached.object)
        end
    end
    visit(rootOf(vehicle))
    return level, source, combined
end

function TerraLogicTrafficWarnings:getLevel(vehicle, now)
    if vehicle == nil or vehicle ~= self.vehicle or self.reply == nil then return 0, false end
    local reply = self.reply
    if now - reply.time > self.REPLY_MAX_AGE_MS then return 0, false end
    -- Detaching a trailer invalidates its warning immediately, even while an
    -- older network response is in flight. Nearby vehicles are never included.
    if reply.source ~= nil and rootOf(reply.source) ~= rootOf(vehicle) then return 0, false end
    if reply.level > 0 and reply.source == nil then return 0, false end
    return reply.level, true
end

function TerraLogicTrafficWarnings:receive(vehicle, source, serial, level, status)
    local pending = (self.pending or {})[serial]
    if pending == nil or vehicle ~= self.vehicle or pending.vehicle ~= vehicle
        or serial <= self.appliedSerial
        or timeNow() - pending.time > self.REPLY_MAX_AGE_MS then return end
    self.appliedSerial = serial
    self.reply = {level=math.min(math.max(level, 0), 3), source=source, time=pending.time,status=status}
    self.pending[serial] = nil
end

function TerraLogicTrafficWarnings:getStatus(vehicle,now)
    local reply=self.reply
    if vehicle==nil or self.vehicle~=vehicle or not reply or now-reply.time>self.REPLY_MAX_AGE_MS
        or math.abs(vehicle:getLastSpeed(true) or 0)<0.25 then return self:newStatus() end
    local s=reply.status or self:newStatus()
    local result=self:newStatus()
    for _,layer in ipairs({'surface','deep'}) do
        if s[layer..'Known'] and s[layer..'Source'] and rootOf(s[layer..'Source'])==rootOf(vehicle) then
            result[layer..'Known']=true;result[layer]=s[layer]
        end
    end
    for _,cause in ipairs({'wet','pressure','axle'}) do
        result[cause]=s[cause]==true and s[cause..'Source']~=nil
            and rootOf(s[cause..'Source'])==rootOf(vehicle)
    end
    return result
end

-- Discrete labels with short rise/longer release smoothing, never green for no data.
function TerraLogicTrafficWarnings:getDisplayLevels(vehicle,now)
    local s=self:getStatus(vehicle,now)
    if not vehicle then return 0,0 end
    local state=self.display[vehicle] or {};self.display[vehicle]=state
    for _,layer in ipairs({'surface','deep'}) do
        local target=not s[layer..'Known'] and 0 or self:getCompactionLevel(layer,s[layer])
        local old=state[layer] or {value=0};state[layer]=old
        if target==0 then old.value=0;old.target=nil
        elseif target~=old.value then
            if old.target~=target then old.target=target;old.since=now end
            if now-old.since>=(target>old.value and 500 or 2000) then old.value=target end
        else old.target=nil end
    end
    return state.surface.value,state.deep.value
end

function TerraLogicTrafficWarnings:update(dt)
    if g_localPlayer == nil then return end -- dedicated server only records samples
    local now, vehicle = timeNow(), g_localPlayer:getCurrentVehicle()
    if vehicle ~= self.vehicle then
        self.vehicle, self.reply, self.pending, self.nextRequest = vehicle, nil, {}, 0
        -- Also catches briefly leaving/re-entering the same tractor while a
        -- menu is open (drawSpeedHud is not necessarily called in between).
        TerraLogicMain.speedHudVehicle = nil
    end
    if vehicle == nil then return end
    if TerraLogicMain.enabled == false or TerraLogicSettings.speedHudMode == "off"
        or math.abs(vehicle:getLastSpeed(true) or 0) < 0.25 then
        self.reply, self.pending = nil, {}
        return
    end
    if now < self.nextRequest then return end
    self.nextRequest = now + self.INTERVAL_MS
    if g_server ~= nil then
        local level, source, status = self:getServerStatus(vehicle, now)
        self.reply = {level=level, source=source, time=now,status=status}
    elseif g_client ~= nil then
        for serial, pending in pairs(self.pending) do
            if now - pending.time > self.REPLY_MAX_AGE_MS then self.pending[serial] = nil end
        end
        local connection = g_client:getServerConnection()
        if connection ~= nil then
            self.serial = (self.serial + 1) % 2147483647
            if self.serial == 0 then self.serial, self.appliedSerial, self.pending = 1, 0, {} end
            self.pending[self.serial] = {vehicle=vehicle, time=now}
            connection:sendEvent(TerraLogicTrafficWarningRequestEvent.new(vehicle, self.serial))
        end
    end
end

TerraLogicTrafficWarningRequestEvent = {}
local Request_mt = Class(TerraLogicTrafficWarningRequestEvent, Event)
InitEventClass(TerraLogicTrafficWarningRequestEvent, "TerraLogicTrafficWarningRequestEvent")
function TerraLogicTrafficWarningRequestEvent.emptyNew() return Event.new(Request_mt) end
function TerraLogicTrafficWarningRequestEvent.new(vehicle, serial)
    local self = TerraLogicTrafficWarningRequestEvent.emptyNew()
    self.vehicle, self.serial = vehicle, serial
    return self
end
function TerraLogicTrafficWarningRequestEvent:writeStream(streamId, connection)
    NetworkUtil.writeNodeObject(streamId, self.vehicle)
    streamWriteInt32(streamId, self.serial)
end
function TerraLogicTrafficWarningRequestEvent:readStream(streamId, connection)
    self.vehicle = NetworkUtil.readNodeObject(streamId)
    self.serial = streamReadInt32(streamId)
    self:run(connection)
end
function TerraLogicTrafficWarningRequestEvent:run(connection)
    if connection:getIsServer() or g_server == nil or self.vehicle == nil then return end
    local manager, now = TerraLogicTrafficWarnings, timeNow()
    local last = manager.requestTimes[connection] or -1000
    if now - last < 200 then return end
    manager.requestTimes[connection] = now
    local level, source, status = 0, nil, manager:newStatus()
    if TerraLogicMain.enabled ~= false then
        level, source, status = manager:getServerStatus(self.vehicle, now)
    end
    connection:sendEvent(TerraLogicTrafficWarningReplyEvent.new(self.vehicle, source, self.serial, level,status))
end

TerraLogicTrafficWarningReplyEvent = {}
local Reply_mt = Class(TerraLogicTrafficWarningReplyEvent, Event)
InitEventClass(TerraLogicTrafficWarningReplyEvent, "TerraLogicTrafficWarningReplyEvent")
function TerraLogicTrafficWarningReplyEvent.emptyNew() return Event.new(Reply_mt) end
function TerraLogicTrafficWarningReplyEvent.new(vehicle, source, serial, level,status)
    local self = TerraLogicTrafficWarningReplyEvent.emptyNew()
    self.vehicle, self.source, self.serial, self.level = vehicle, source, serial, level
    self.status=status or TerraLogicTrafficWarnings:newStatus()
    return self
end
function TerraLogicTrafficWarningReplyEvent:writeStream(streamId, connection)
    NetworkUtil.writeNodeObject(streamId, self.vehicle)
    NetworkUtil.writeNodeObject(streamId, self.source)
    streamWriteInt32(streamId, self.serial)
    streamWriteUInt8(streamId, self.level)
    for _,layer in ipairs({'surface','deep'}) do
        streamWriteBool(streamId,self.status[layer..'Known'])
        streamWriteFloat32(streamId,self.status[layer])
        NetworkUtil.writeNodeObject(streamId,self.status[layer..'Source'])
    end
    for _,cause in ipairs({'wet','pressure','axle'}) do
        streamWriteBool(streamId,self.status[cause])
        NetworkUtil.writeNodeObject(streamId,self.status[cause..'Source'])
    end
end
function TerraLogicTrafficWarningReplyEvent:readStream(streamId, connection)
    self.vehicle = NetworkUtil.readNodeObject(streamId)
    self.source = NetworkUtil.readNodeObject(streamId)
    self.serial, self.level = streamReadInt32(streamId), streamReadUInt8(streamId)
    self.status=TerraLogicTrafficWarnings:newStatus()
    for _,layer in ipairs({'surface','deep'}) do
        self.status[layer..'Known']=streamReadBool(streamId)
        self.status[layer]=streamReadFloat32(streamId)
        self.status[layer..'Source']=NetworkUtil.readNodeObject(streamId)
    end
    for _,cause in ipairs({'wet','pressure','axle'}) do
        self.status[cause]=streamReadBool(streamId)
        self.status[cause..'Source']=NetworkUtil.readNodeObject(streamId)
    end
    self:run(connection)
end
function TerraLogicTrafficWarningReplyEvent:run(connection)
    if not connection:getIsServer() then return end
    TerraLogicTrafficWarnings:receive(self.vehicle, self.source, self.serial, self.level,self.status)
end
