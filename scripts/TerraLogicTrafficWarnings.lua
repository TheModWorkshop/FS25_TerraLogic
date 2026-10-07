-- Read-only warning summaries from the existing authoritative wheel pass.
-- No extra wheel-physics queries, soil probes or persistent savegame data.
TerraLogicTrafficWarnings = {}
TerraLogicTrafficWarnings.INTERVAL_MS = 1000
TerraLogicTrafficWarnings.SAMPLE_MAX_AGE_MS = 900
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
end

function TerraLogicTrafficWarnings:delete()
    self:load()
end

-- A risk warning needs actual new compaction, not simply a heavy vehicle.
-- Evaluate each layer separately: pressure drives surface damage, axle load
-- drives deep damage. Sensitivities already include texture, moisture,
-- resilience and that layer's frost protection, exactly as used by the map.
function TerraLogicTrafficWarnings:getImpactLevel(detail)
    local delta = detail.delta or {}
    local surfaceRisk = (delta.surfaceCompaction or 0) > 0.0000001
        and math.min((detail.pressureKPa or 0) / 300, 1)
            * (detail.surfaceTrafficSensitivity or 0) or 0
    local deepRisk = (delta.deepCompaction or 0) > 0.0000001
        and math.min(((detail.maxAxleLoadT or 0) / 11)^2, 1)
            * (detail.deepTrafficSensitivity or 0) or 0
    local wet = (surfaceRisk >= 0.35 and (detail.trafficSurfaceMultiplier or 1) >= 1.08)
        or (deepRisk >= 0.35 and (detail.trafficDeepMultiplier or 1) >= 1.08)
    if math.max(surfaceRisk, deepRisk) >= 0.75 then return wet and 3 or 2 end
    if wet then return 1 end
    return 0
end

function TerraLogicTrafficWarnings:record(vehicle, level, now)
    if self.samples == nil then return end
    local sample = self.samples[vehicle] or {}
    sample.time, sample.level = now, level
    self.samples[vehicle] = sample
end

function TerraLogicTrafficWarnings:getServerStatus(vehicle, now)
    local level, source, visited, count = 0, nil, {}, 0
    local function visit(object)
        if object == nil or visited[object] or count >= 64 then return end
        visited[object], count = true, count + 1
        local sample = (self.samples or {})[object]
        if sample ~= nil and now - sample.time <= self.SAMPLE_MAX_AGE_MS
            and sample.level > level then
            level, source = sample.level, object
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
    return level, source
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

function TerraLogicTrafficWarnings:receive(vehicle, source, serial, level)
    local pending = (self.pending or {})[serial]
    if pending == nil or vehicle ~= self.vehicle or pending.vehicle ~= vehicle
        or serial <= self.appliedSerial
        or timeNow() - pending.time > self.REPLY_MAX_AGE_MS then return end
    self.appliedSerial = serial
    self.reply = {level=math.min(math.max(level, 0), 3), source=source, time=pending.time}
    self.pending[serial] = nil
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
        local level, source = self:getServerStatus(vehicle, now)
        self.reply = {level=level, source=source, time=now}
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
    if now - last < 500 then return end
    manager.requestTimes[connection] = now
    local level, source = 0, nil
    if TerraLogicMain.enabled ~= false then
        level, source = manager:getServerStatus(self.vehicle, now)
    end
    connection:sendEvent(TerraLogicTrafficWarningReplyEvent.new(self.vehicle, source, self.serial, level))
end

TerraLogicTrafficWarningReplyEvent = {}
local Reply_mt = Class(TerraLogicTrafficWarningReplyEvent, Event)
InitEventClass(TerraLogicTrafficWarningReplyEvent, "TerraLogicTrafficWarningReplyEvent")
function TerraLogicTrafficWarningReplyEvent.emptyNew() return Event.new(Reply_mt) end
function TerraLogicTrafficWarningReplyEvent.new(vehicle, source, serial, level)
    local self = TerraLogicTrafficWarningReplyEvent.emptyNew()
    self.vehicle, self.source, self.serial, self.level = vehicle, source, serial, level
    return self
end
function TerraLogicTrafficWarningReplyEvent:writeStream(streamId, connection)
    NetworkUtil.writeNodeObject(streamId, self.vehicle)
    NetworkUtil.writeNodeObject(streamId, self.source)
    streamWriteInt32(streamId, self.serial)
    streamWriteUInt8(streamId, self.level)
end
function TerraLogicTrafficWarningReplyEvent:readStream(streamId, connection)
    self.vehicle = NetworkUtil.readNodeObject(streamId)
    self.source = NetworkUtil.readNodeObject(streamId)
    self.serial, self.level = streamReadInt32(streamId), streamReadUInt8(streamId)
    self:run(connection)
end
function TerraLogicTrafficWarningReplyEvent:run(connection)
    if not connection:getIsServer() then return end
    TerraLogicTrafficWarnings:receive(self.vehicle, self.source, self.serial, self.level)
end
