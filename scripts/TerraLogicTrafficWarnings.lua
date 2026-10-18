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
    self.referencePasses = setmetatable({}, {__mode="k"})
    self.samples = setmetatable({}, {__mode="k"})
    self.requestTimes = setmetatable({}, {__mode="k"})
    self.vehicle, self.reply, self.pending = nil, nil, {}
    self.serial, self.appliedSerial, self.nextRequest = 0, 0, 0
    self.display = setmetatable({}, {__mode="k"})
end

function TerraLogicTrafficWarnings:delete()
    self:load()
end

-- A partial pass and an in-flight reply from the previous balancing setting
-- must never be combined with new targets. Soil itself is not touched.
function TerraLogicTrafficWarnings:onCompactionIntensityChanged()
    self.referencePasses = setmetatable({}, {__mode="k"})
    self.samples = setmetatable({}, {__mode="k"})
    self.display = setmetatable({}, {__mode="k"})
    self.reply, self.pending, self.nextRequest = nil, {}, 0
end

-- Read the resulting state of the contacted cells after the authoritative update.
-- Sampling and warnings do not change the authoritative soil simulation.
function TerraLogicTrafficWarnings:newStatus()
    return {surface=0,deep=0,surfaceKnown=false,deepKnown=false,wet=false,pressure=false,axle=false}
end

-- Absolute post-pass state. Use the same bands as Field Analysis, rather than
-- separate yield-loss thresholds (which overstated deep-compaction severity).
function TerraLogicTrafficWarnings:getCompactionLevel(layer,value)
    local key = layer == "surface" and "surfaceCompaction" or "deepCompaction"
    local _, color = TerraLogicDisplay.rating(key, value)
    return color == "red" and 4 or color == "orange" and 3
        or color == "yellow" and 2 or 1
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
    if now >= (self.referenceCleanupAt or 0) then
        self.referenceCleanupAt=now+1000
        for root,cache in pairs(self.referencePasses) do
            if now-cache.updated>3000 then self.referencePasses[root]=nil end
        end
    end
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
    self:prepareReferencePass(rootOf(vehicle), now)
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
    -- Warnings retain their existing causal samples. Icons, however, must
    -- not mistake a partially accumulated reference pass for a low load.
    local cache = self.referencePasses[rootOf(vehicle)]
    for _, layer in ipairs({'surface','deep'}) do
        local completed = cache and cache.completed and cache.completed[layer]
        local contactTime = cache and cache[layer..'ContactTime']
        if not contactTime or now-contactTime>self.SAMPLE_MAX_AGE_MS then completed=nil end
        combined[layer..'Known'] = completed ~= nil
        combined[layer] = completed and completed.value or 0
        combined[layer..'Source'] = completed and completed.source or nil
    end
    return level, source, combined
end

-- Keep cells only while they are inside the moving combination's wheel bounds.
-- Unlike a contact timeout, stopping does not separate front and trailer axles.
function TerraLogicTrafficWarnings:prepareReferencePass(root, now)
    if root == nil then return end
    local old = self.referencePasses[root]
    if old and old.updated == now then return end
    local bounds, contactBounds, members, count = nil, nil, {}, 0
    local function visit(object)
        if not object or members[object] or count >= 64 then return end
        members[object]=true; count=count+1
        for _, wheel in pairs(object.spec_wheels and object.spec_wheels.wheels or {}) do
            local node=wheel.driveNode or wheel.repr or wheel.node
            if node and getWorldTranslation then
                local x,_,z=getWorldTranslation(node)
                if x and z then
                    local margin=math.max(4,tonumber(wheel.width) or 0)
                    if not bounds then bounds={x-margin,x+margin,z-margin,z+margin}
                    else
                        bounds[1]=math.min(bounds[1],x-margin)
                        bounds[2]=math.max(bounds[2],x+margin)
                        bounds[3]=math.min(bounds[3],z-margin)
                        bounds[4]=math.max(bounds[4],z+margin)
                    end
                    local physics = wheel.physics or {}
                    local contactMargin = math.max(.25, tonumber(physics.radius)
                        or tonumber(wheel.radius) or .75,
                        (tonumber(physics.width) or tonumber(wheel.width) or 0)/2)
                    if not contactBounds then
                        contactBounds={x-contactMargin,x+contactMargin,z-contactMargin,z+contactMargin}
                    else
                        contactBounds[1]=math.min(contactBounds[1],x-contactMargin)
                        contactBounds[2]=math.max(contactBounds[2],x+contactMargin)
                        contactBounds[3]=math.min(contactBounds[3],z-contactMargin)
                        contactBounds[4]=math.max(contactBounds[4],z+contactMargin)
                    end
                end
            end
        end
        for _, attachment in pairs(object.spec_attacherJoints
                and object.spec_attacherJoints.attachedImplements or {}) do
            visit(attachment.object)
        end
    end
    visit(root)
    local same=old~=nil
    if old then
        for object in pairs(old.members) do if not members[object] then same=false end end
        for object in pairs(members) do if not old.members[object] then same=false end end
        if now-old.updated>3000 then same=false end
    end
    -- A teleport is not a completed pass. Restart rather than publishing all
    -- the cells that happened to disappear from the previous bounds.
    if old and bounds and old.bounds and (bounds[2]<old.bounds[1]
        or bounds[1]>old.bounds[2] or bounds[4]<old.bounds[3]
        or bounds[3]>old.bounds[4]) then same=false end
    local cache=same and old or {cells={},count=0,completed={},startBounds=contactBounds}
    cache.updated,cache.members,cache.bounds=now,members,bounds
    local finished = {}
    if bounds then
        for key,cell in pairs(cache.cells) do
            local half = (cell.size or 1)/2
            if not cell.finished and cell.eligible and contactBounds
                and (cell.x+half<contactBounds[1] or cell.x-half>contactBounds[2]
                    or cell.z+half<contactBounds[3] or cell.z-half>contactBounds[4]) then
                -- Wheel updates can still deliver the final swept segment
                -- after this bounds check. Confirm departure on the next
                -- observation; any intervening contact cancels it below.
                if cell.leftBoundsAt and now>cell.leftBoundsAt then
                    cell.finished=true
                    local previous=finished[cell.layer]
                    if not previous or cell.value>previous.value then
                        finished[cell.layer]={value=cell.value,source=cell.source,time=now}
                    end
                else
                    cell.leftBoundsAt=now
                end
            end
            if (cell.x<bounds[1] or cell.x>bounds[2]
                or cell.z<bounds[3] or cell.z>bounds[4])
                and (not cell.eligible or cell.finished) then
                cache.cells[key]=nil;cache.count=cache.count-1
            end
        end
    else cache.cells={};cache.count=0;cache.completed={} end
    for layer, value in pairs(finished) do cache.completed[layer]=value end
    self.referencePasses[root]=cache
end

function TerraLogicTrafficWarnings:accumulateReference(status, detail, vehicle, now)
    local root=rootOf(vehicle)
    local cache=self.referencePasses[root]
    if not cache or now-cache.updated>3000 or not cache.bounds then return end
    if detail.x==nil or detail.z==nil then return end
    local sampled={after={},trafficSurfaceMultiplier=detail.trafficSurfaceMultiplier,
        trafficDeepMultiplier=detail.trafficDeepMultiplier}
    for _,layer in ipairs({"surface","deep"}) do
        local target,strength=detail[layer.."Target"],detail[layer.."AppliedStrength"]
        local coverage=detail[layer.."Coverage"] or 0
        if target and strength and strength>0 and coverage>0 then
            cache[layer..'ContactTime']=now
            local size=layer=="surface" and TerraLogicSoilManager.WHEEL_CELL_SIZE
                or TerraLogicWheelCompactionManager.DEEP_CELL_SIZE_M
            local ix,iz=math.floor(detail.x/size),math.floor(detail.z/size)
            local key=layer..":"..ix..":"..iz
            local cell=cache.cells[key]
            if not cell and cache.count<2048 then
                local x,z=(ix+.5)*size,(iz+.5)*size
                local start=cache.startBounds
                local eligible=start~=nil and (x+size/2<start[1] or x-size/2>start[2]
                    or z+size/2<start[3] or z-size/2>start[4])
                cell={value=.20,x=x,z=z,size=size,layer=layer,
                    source=vehicle,eligible=eligible}
                cache.cells[key]=cell;cache.count=cache.count+1
            end
            if cell then
                -- Turning back into a completed cell starts another contact;
                -- wait until this contact has left the combination too.
                cell.finished=false
                cell.leftBoundsAt=nil
                target=math.max(0,math.min(1,target))
                strength=math.max(0,math.min(1,strength))
                if target>cell.value then
                    local nextValue=cell.value+(target-cell.value)*strength
                    local minimum=layer=="deep" or detail.surfaceLowPressureResponse==true
                    minimum=minimum and .000001 or .001
                    if nextValue-cell.value>minimum then cell.value=nextValue end
                end
                sampled.after[layer=="surface" and "surfaceCompaction" or "deepCompaction"]=cell.value
                sampled[layer.."Coverage"]=coverage
                sampled[layer.."AppliedStrength"]=strength
            end
        end
    end
    self:accumulate(status,sampled)
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

-- Show first readings and increases immediately; smooth only decreases.
-- Missing data is always unknown, never an artificial low reading.
function TerraLogicTrafficWarnings:getDisplayLevels(vehicle,now)
    local s=self:getStatus(vehicle,now)
    if not vehicle then return 0,0 end
    local state=self.display[vehicle] or {};self.display[vehicle]=state
    for _,layer in ipairs({'surface','deep'}) do
        local target=not s[layer..'Known'] and 0 or self:getCompactionLevel(layer,s[layer])
        local old=state[layer] or {value=0};state[layer]=old
        if target==0 then old.value=0;old.target=nil
        elseif old.value==0 or target>old.value then
            old.value=target;old.target=nil
        elseif target~=old.value then
            if old.target~=target then old.target=target;old.since=now end
            if now-old.since>=2000 then old.value=target;old.target=nil end
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
