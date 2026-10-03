-- Owned-field browsing. Only the server discovers terrain; clients receive
-- compact entry lists, never a map-sized mask. Work is suspended between small
-- probe batches. Registered fields appear first; later refreshes use creation
-- seeds, with a periodic background sweep as a fallback for external changes.
TerraLogicFieldCatalog = {PROBES_PER_SLICE=128, GEOMETRY_CELLS_PER_SLICE=8, CACHE_MS=1800000}

local function now() return g_currentMission ~= nil and g_currentMission.time or 0 end
local function farmFor(connection)
    local player = g_localPlayer
    if connection ~= nil then
        player = g_currentMission ~= nil and g_currentMission.getPlayerByConnection ~= nil
            and g_currentMission:getPlayerByConnection(connection) or nil
    end
    local id = player ~= nil and tonumber(player.farmId) or nil
    if id == nil and connection == nil and g_currentMission ~= nil
        and g_currentMission.getFarmId ~= nil then id = g_currentMission:getFarmId() end
    return id ~= nil and id > 0 and id or nil
end

local function owns(x, z, farmId)
    if farmId == nil or g_farmlandManager == nil then return false end
    local land = g_farmlandManager:getFarmlandAtWorldPosition(x, z)
    if land == nil then return false end
    local owner = g_farmlandManager.getFarmlandOwner ~= nil
        and g_farmlandManager:getFarmlandOwner(land.id) or land.farmId
    return owner == farmId
end

local function cellKey(x, z)
    local size = TerraLogicFieldAnalysis.DYNAMIC_FIELD_CELL_SIZE
    return tostring(math.floor(x/size)) .. ":" .. tostring(math.floor(z/size))
end

local function ownershipSignature(owner)
    local ids={}
    for id,land in pairs(g_farmlandManager ~= nil and g_farmlandManager.farmlands or {}) do
        local landId=land.id or id
        local farmId=g_farmlandManager.getFarmlandOwner ~= nil
            and g_farmlandManager:getFarmlandOwner(landId) or land.farmId
        if farmId==owner then ids[#ids+1]=tostring(landId) end
    end
    table.sort(ids)
    return table.concat(ids,":")
end

function TerraLogicFieldCatalog:reset()
    self.jobs, self.pending, self.cache, self.entries = {}, {}, {}, {}
    self.generation, self.opened, self.complete = 0, false, false
    self.activeSnapshot = nil
    self.cursor = 0
    self.watchers,self.dirty,self.customNames={},{},{}
    self.nextCustomId,self.nextMaintenance=1,0
end

-- Called only for successful create-field plough work. Coalesce nearby work
-- into one seed; do not query terrain or scan field polygons in the callback.
function TerraLogicFieldCatalog:markTopologyDirty(x,z)
    self.dirty=self.dirty or {}
    local key=tostring(math.floor(x/32))..":"..tostring(math.floor(z/32))
    self.dirty[key]={x=x,z=z}
end

function TerraLogicFieldCatalog:entryName(entry)
    local ids=entry.fieldIds or {}
    if #ids>0 then
        local values={};for _,id in ipairs(ids) do values[#values+1]=tostring(id) end
        local name=(g_i18n:getText("terraLogic_fa_browserField")).." "..table.concat(values," + ")
        return name..((entry.sectionNumber or 0)>0 and "-"..tostring(entry.sectionNumber) or "")
    end
    return TerraLogicI18n.format(g_i18n:getText("terraLogic_fa_browserCustom"),entry.customId or 1)
end

function TerraLogicFieldCatalog:deliver(connection, generation, entries, complete, x, z, farmId)
    -- Spatial ordering is independent of discovery/player position. Only real
    -- components participate; a provisional native entry is not a section.
    -- Commit ranks only for a completed catalog; partial discoveries must not
    -- repeatedly renumber an already visible section.
    if complete then
    local groups={}
    for _,entry in ipairs(entries) do
        entry.sectionNumber=0
        if not entry.provisional and #(entry.fieldIds or {})==1 then
            local id=entry.fieldIds[1]
            groups[id]=groups[id] or {};table.insert(groups[id],entry)
        end
    end
    for _,group in pairs(groups) do
        if #group>1 then
            table.sort(group,function(a,b)
                local az,bz=a.anchorZ or a.z,b.anchorZ or b.z
                if az~=bz then return az<bz end
                return (a.anchorX or a.x)<(b.anchorX or b.x)
            end)
            for i,entry in ipairs(group) do entry.sectionNumber=i end
        end
    end
    end
    local result = {}
    for _, entry in ipairs(entries) do
        -- Ownership can change while the menu is open or a cache is alive.
        if owns(entry.x, entry.z, farmId) then
            result[#result+1] = {x=entry.x, z=entry.z, key=entry.key,
                fieldIds=entry.fieldIds or {},customId=entry.customId or 0,sectionNumber=entry.sectionNumber or 0,
                areaHa=entry.areaHa or 0,condition=entry.condition,
                current=entry.cells[cellKey(x,z)] == true}
        end
    end
    if connection ~= nil then
        connection:sendEvent(TerraLogicFieldCatalogEvent.new(generation, result, complete))
    else self:receive(generation, result, complete) end
end

function TerraLogicFieldCatalog:request(connection, generation, x, z)
    self.jobs, self.cache = self.jobs or {}, self.cache or {}
    local owner = farmFor(connection)
    local half = (TerraLogicSoilManager.terrainSize or 2048)*.5
    if type(x) ~= "number" or type(z) ~= "number" or x ~= x or z ~= z
        or math.abs(x)>half or math.abs(z)>half then x,z=0,0 end
    if owner == nil then
        self:deliver(connection, generation, {}, true, x, z, owner)
        return
    end
    local key = connection or self
    self.watchers=self.watchers or {}
    self.watchers[key]={connection=connection,generation=generation,x=x,z=z,owner=owner}
    local signature=ownershipSignature(owner)
    local running = self.jobs[key]
    if running ~= nil and running.owner == owner and running.signature==signature then
        running.generation,running.x,running.z=generation,x,z
        self:deliver(connection,generation,running.entries,false,x,z,owner)
        return
    end
    local cache = self.cache[owner]
    if cache ~= nil and cache.signature==signature and now()-cache.time < self.CACHE_MS
        and next(cache.dirtySeeds or {})==nil then
        self:deliver(connection, generation, cache.entries, true, x, z, owner)
        return
    end
    -- One replaceable discovery job per requester; repeated opens do not pile up.
    local seeds, fields, nativeCandidates = {{x=x,z=z}}, {}, {}
    local targeted=cache~=nil and cache.signature==signature and now()-cache.time<self.CACHE_MS
    if targeted then
        seeds={}
        for _,point in pairs(cache.dirtySeeds or {}) do
            seeds[#seeds+1]=point
        end
        cache.dirtySeeds={}
    end
    for _, field in pairs(g_fieldManager ~= nil and g_fieldManager.fields or {}) do
        fields[#fields+1] = field
    end
    table.sort(fields,function(a,b)
        return TerraLogicFieldAnalysis.getFieldNumber(a)<TerraLogicFieldAnalysis.getFieldNumber(b)
    end)
    for _, field in ipairs(targeted and {} or fields) do
        local polygon = TerraLogicFieldAnalysis.getFieldPolygon(field)
        if polygon ~= nil then
            local cx,cz = 0,0
            for _, p in ipairs(polygon) do cx,cz=cx+p.x,cz+p.z end
            cx,cz=cx/#polygon,cz/#polygon
            seeds[#seeds+1]={x=cx,z=cz}
            local candidates={{x=cx,z=cz}}
            for _, p in ipairs(polygon) do
                seeds[#seeds+1]={x=p.x*.8+cx*.2,z=p.z*.8+cz*.2}
                candidates[#candidates+1]=seeds[#seeds]
            end
            nativeCandidates[#nativeCandidates+1]={id=TerraLogicFieldAnalysis.getFieldNumber(field),points=candidates}
        end
    end
    local entries={}
    if targeted then for _,entry in ipairs(cache.entries) do entries[#entries+1]=entry end end
    self.jobs[key] = {connection=connection,generation=generation,owner=owner,signature=signature,
        x=x,z=z,half=half,seeds=seeds,seedIndex=1,scanX=-half+2,scanZ=-half+2,
        entries=entries,targeted=targeted,covered={},lastSent=now(),lastCount=0,
        nativeCandidates=nativeCandidates,nativeIndex=1,nativeProbe=1,
        baseTime=targeted and cache.time or now()}
    if cache~=nil then self:deliver(connection,generation,cache.entries,false,x,z,owner) end
end

function TerraLogicFieldCatalog:sendDiscovery(job, complete, force)
    if complete or force or (#job.entries~=job.lastCount and now()-job.lastSent>=1000) then
        self:deliver(job.connection,job.generation,job.entries,complete,job.x,job.z,job.owner)
        job.lastSent,job.lastCount=now(),#job.entries
    end
end

function TerraLogicFieldCatalog:stepDiscovery(job)
    -- Publish registered owned fields after a few live-ground checks, before
    -- tracing their complete boundaries or searching for unregistered fields.
    if job.nativeCandidates~=nil then
        for _=1,self.PROBES_PER_SLICE do
            local candidate=job.nativeCandidates[job.nativeIndex]
            if candidate==nil then
                job.nativeCandidates=nil;self:sendDiscovery(job,false,true);return false
            end
            local point=candidate.points[job.nativeProbe]
            if point==nil then job.nativeIndex=job.nativeIndex+1;job.nativeProbe=1
            elseif owns(point.x,point.z,job.owner) and TerraLogicFieldAnalysis.isVisibleSoilSurface(point.x,point.z) then
                local key=cellKey(point.x,point.z)
                job.entries[#job.entries+1]={x=point.x,z=point.z,key=key,cells={[key]=true},
                    probes=candidate.points,fieldIds={candidate.id},areaHa=0,order=candidate.id,provisional=true}
                job.nativeIndex=job.nativeIndex+1;job.nativeProbe=1
            else job.nativeProbe=job.nativeProbe+1 end
        end
        return false
    end
    if job.summary~=nil then
        local summary=job.summary
        for _=1,self.GEOMETRY_CELLS_PER_SLICE do
            local point=summary.points[summary.index]
            if point==nil then
                if summary.index>1 then summary.entry.condition=summary.sum/(summary.index-1) end
                job.summary=nil;self:sendDiscovery(job,false,true);return false
            end
            local soil=TerraLogicSoilManager:getStateAtWorldPosition(point.x,point.z)
            summary.sum=summary.sum+(TerraLogicSoilManager:getTillageQualityFromState(soil) or 1)
            summary.index=summary.index+1
        end
        return false
    end
    if job.geometry ~= nil then
        if not job.geometry:step(self.GEOMETRY_CELLS_PER_SLICE) then return false end
        local result=job.geometry.result
        job.geometry=nil
        local cells=result[8]
        if #cells>0 then job.completed=result;job.mask={};job.cellIndex=1;job.anchorX=nil;job.anchorZ=nil end
        return false
    end
    if job.completed ~= nil then
        local result,cells=job.completed,job.completed[8]
        for _=1,self.PROBES_PER_SLICE do
            local cell=cells[job.cellIndex]
            if cell==nil then break end
            local k=cellKey(cell.x,cell.z)
            if job.anchorZ==nil or cell.z<job.anchorZ or (cell.z==job.anchorZ and cell.x<job.anchorX) then
                job.anchorX,job.anchorZ=cell.x,cell.z
            end
            job.mask[k],job.covered[k]=true,true
            job.cellIndex=job.cellIndex+1
        end
        if job.cellIndex>#cells then
            local first=cells[1]
            -- Different edge seeds can reach the same component. Merge masks
            -- rather than publishing duplicate choices with the same field.
            local merged=nil
            for i=#job.entries,1,-1 do
                local entry=job.entries[i]
                local overlap=false
                for k in pairs(job.mask) do
                    if entry.cells[k] then overlap=true;break end
                end
                if overlap then
                    merged=entry
                    for k in pairs(entry.cells) do job.mask[k]=true end
                    table.remove(job.entries,i)
                end
            end
            local ids=result[7] or {}
            local customId=merged and merged.customId or nil
            self.customNames=self.customNames or {};self.nextCustomId=self.nextCustomId or 1
            if #ids==0 and customId==nil then
                customId=self.customNames[cellKey(first.x,first.z)]
                if customId==nil then customId=self.nextCustomId;self.nextCustomId=customId+1 end
                self.customNames[cellKey(first.x,first.z)]=customId
            end
            local entry={x=merged and merged.x or first.x,
                z=merged and merged.z or first.z,
                key=merged and merged.key or cellKey(first.x,first.z),
                cells=job.mask,probes=cells,fieldIds=ids,customId=customId,areaHa=result[2],
                anchorX=job.anchorX,anchorZ=job.anchorZ,
                order=result[6]>=0 and result[6] or result[7][1] or math.huge}
            job.entries[#job.entries+1]=entry
            if TerraLogicSoilManager.getStateAtWorldPosition~=nil then
                job.summary={entry=entry,points=result[1],index=1,sum=0}
            end
            table.sort(job.entries,function(a,b)
                if a.order~=b.order then return a.order<b.order end
                return a.z<b.z or (a.z==b.z and a.x<b.x)
            end)
            job.completed,job.mask=nil,nil
            self:sendDiscovery(job,false)
        end
        return false
    end
    for _=1,self.PROBES_PER_SLICE do
        local px,pz
        local seed=job.seeds[job.seedIndex]
        if seed~=nil then
            px,pz=seed.x,seed.z;job.seedIndex=job.seedIndex+1
        else
            if not job.nativeDone then
                job.nativeDone=true;self:sendDiscovery(job,false,true)
            end
            if job.targeted or job.scanZ>=job.half then
                self.cache[job.owner]={time=job.baseTime or now(),entries=job.entries,signature=job.signature,
                    dirtySeeds=self.cache[job.owner] and self.cache[job.owner].dirtySeeds or {}}
                self:sendDiscovery(job,true)
                return true
            end
            px,pz=job.scanX,job.scanZ
            job.scanX=job.scanX+4
            if job.scanX>=job.half then job.scanX=-job.half+2;job.scanZ=job.scanZ+4 end
        end
        if not job.covered[cellKey(px,pz)] and owns(px,pz,job.owner)
            and TerraLogicFieldAnalysis.isVisibleSoilSurface(px,pz) then
            job.geometry=TerraLogicFieldAnalysis.createDynamicFieldJob(px,pz,
                {allowed=function(ax,az) return owns(ax,az,job.owner) end})
            return false
        end
    end
    return false
end

function TerraLogicFieldCatalog:queueSnapshot(connection, x, z, serial, vehicle, selected)
    self.pending = self.pending or {}
    -- Latest request wins, including requests made during the old 500 ms
    -- cooldown. No dropped request can leave the menu stuck at "Calculating".
    self.pending[connection or self] = {connection=connection,x=x,z=z,
        serial=serial,vehicle=vehicle,selected=selected}
    if self.activeSnapshot ~= nil and self.activeSnapshot.connection == connection then
        self.activeSnapshot=nil
    end
end

function TerraLogicFieldCatalog:update()
    if g_currentMission == nil or not g_currentMission:getIsServer() then return end
    self.jobs, self.pending = self.jobs or {}, self.pending or {}
    if now()>=(self.nextMaintenance or 0) then
        self.nextMaintenance=now()+5000
        for _,point in pairs(self.dirty or {}) do
            for _,job in pairs(self.jobs or {}) do
                if owns(point.x,point.z,job.owner) then
                    job.seeds[#job.seeds+1]=point
                    job.covered[cellKey(point.x,point.z)]=nil
                end
            end
            for owner,cache in pairs(self.cache or {}) do
                if owns(point.x,point.z,owner) then
                    cache.dirtySeeds=cache.dirtySeeds or {}
                    cache.dirtySeeds[cellKey(point.x,point.z)]=point
                end
            end
        end
        self.dirty={}
        for key,watcher in pairs(self.watchers or {}) do
            local cache=self.cache[watcher.owner]
            if watcher.connection~=nil and farmFor(watcher.connection)~=watcher.owner then
                self.watchers[key],self.jobs[key],self.pending[key]=nil,nil,nil
                if self.activeSnapshot~=nil and self.activeSnapshot.connection==watcher.connection then
                    self.activeSnapshot=nil
                end
            elseif cache~=nil and self.jobs[key]==nil
                and (next(cache.dirtySeeds or {})~=nil or now()-cache.time>=self.CACHE_MS) then
                self:request(watcher.connection,watcher.generation,watcher.x,watcher.z)
            end
        end
    end
    -- Snapshot work takes priority, but discovery also gets one bounded slice.
    if self.activeSnapshot == nil then
        local key, request = next(self.pending)
        if key ~= nil then
            self.pending[key] = nil
            local owner=farmFor(request.connection)
            request.allowed=request.selected and function(x,z) return owns(x,z,owner) end or nil
            local cache=self.cache and self.cache[owner]
            for _,entry in ipairs(cache and cache.entries or {}) do
                if entry.cells[cellKey(request.x,request.z)] then request.entry=entry;break end
            end
            request.geometry=TerraLogicFieldAnalysis.createDynamicFieldJob(request.x,request.z,
                {allowed=request.allowed})
            self.activeSnapshot=request
        end
    end
    local request=self.activeSnapshot
    if request~=nil and request.geometry.done and #(request.geometry.result[8] or {})==0
        and request.entry~=nil and not request.rechecked then
        local probes=request.entry.probes or {}
        request.probeIndex=request.probeIndex or 1
        for _=1,self.GEOMETRY_CELLS_PER_SLICE do
            local point=probes[request.probeIndex]
            if point==nil then
                self:removeEntry(request.entry)
                request.rechecked=true;break
            end
            request.probeIndex=request.probeIndex+1
            if (request.allowed==nil or request.allowed(point.x,point.z))
                and TerraLogicFieldAnalysis.isVisibleSoilSurface(point.x,point.z) then
                request.x,request.z=point.x,point.z
                request.geometry=TerraLogicFieldAnalysis.createDynamicFieldJob(point.x,point.z,{allowed=request.allowed})
                request.rechecked=true;break
            end
        end
        if not request.rechecked then request=nil end
    end
    if request~=nil and request.geometry:step(self.GEOMETRY_CELLS_PER_SLICE) then
        local snapshot=TerraLogicFieldAnalysis:buildSnapshot(request.x,request.z,
            request.serial,{geometry=request.geometry.result,allowed=request.allowed})
        snapshot.vehicleSetup=TerraLogicFieldAnalysis:buildVehicleSetup(request.vehicle)
        if request.entry~=nil and snapshot.valid then
            request.entry.areaHa,request.entry.condition=snapshot.areaHa,snapshot.soilQuality
        end
        self.activeSnapshot=nil
        if request.connection~=nil then
            request.connection:sendEvent(TerraLogicFieldAnalysisSyncEvent.new(snapshot))
        else TerraLogicFieldAnalysis:applySnapshot(snapshot) end
    end
    local keys = {}
    for key in pairs(self.jobs) do keys[#keys+1]=key end
    if #keys > 0 then
        self.cursor = (self.cursor or 0)%#keys+1
        local key=keys[self.cursor]
        if self:stepDiscovery(self.jobs[key]) then self.jobs[key]=nil end
    end
end

function TerraLogicFieldCatalog:removeEntry(entry)
    for _,cache in pairs(self.cache or {}) do
        for i=#cache.entries,1,-1 do if cache.entries[i].key==entry.key then table.remove(cache.entries,i) end end
    end
    for _,job in pairs(self.jobs or {}) do
        for i=#job.entries,1,-1 do if job.entries[i].key==entry.key then table.remove(job.entries,i) end end
    end
    for _,watcher in pairs(self.watchers or {}) do
        local cache=self.cache[watcher.owner]
        if cache~=nil then self:deliver(watcher.connection,watcher.generation,cache.entries,true,watcher.x,watcher.z,watcher.owner) end
    end
end

function TerraLogicFieldCatalog:open()
    self.generation=(self.generation or 0)+1
    self.opened,self.complete,self.entries=true,false,{}
    self.openFarm=farmFor(nil)
    local x,z=TerraLogicFieldAnalysis:getLocalPosition()
    if g_currentMission:getIsServer() then self:request(nil,self.generation,x,z)
    elseif g_client ~= nil then
        g_client:getServerConnection():sendEvent(TerraLogicFieldCatalogRequestEvent.new(self.generation,x,z))
    end
    self:updateControls()
end

function TerraLogicFieldCatalog:receive(generation, entries, complete)
    if not self.opened or generation ~= self.generation or farmFor(nil) ~= self.openFarm then return end
    self.entries,self.complete=entries,complete
    local selected=TerraLogicFieldAnalysis.selectedField
    if selected~=nil then
        local found=false
        for _,entry in ipairs(entries) do
            if entry.key==selected.key then TerraLogicFieldAnalysis.selectedField=entry;found=true;break end
        end
        if complete and not found then TerraLogicFieldAnalysis.selectedField=nil end
    end
    self:updateControls()
end

function TerraLogicFieldCatalog:selectEntry(entry)
    if entry==nil or not owns(entry.x,entry.z,farmFor(nil)) then return end
    TerraLogicFieldAnalysis.selectedField=entry
    TerraLogicFieldAnalysis:requestSnapshot()
    self:updateControls()
end

function TerraLogicFieldCatalog:select(direction)
    local entries=self.entries or {}
    if #entries == 0 or farmFor(nil) ~= self.openFarm then return end
    local selected=TerraLogicFieldAnalysis.selectedField
    local index=0
    for i,entry in ipairs(entries) do
        if (selected ~= nil and selected.key==entry.key) or (selected==nil and entry.current) then index=i;break end
    end
    if index==0 then index=direction>0 and 1 or #entries
    else index=(index-1+direction)%#entries+1 end
    local entry=entries[index]
    for _=1,#entries do
        if owns(entry.x,entry.z,farmFor(nil)) then break end
        index=(index-1+direction)%#entries+1
        entry=entries[index]
    end
    if not owns(entry.x,entry.z,farmFor(nil)) then return end
    TerraLogicFieldAnalysis.selectedField=entry
    TerraLogicFieldAnalysis:requestSnapshot()
    self:updateControls()
end

function TerraLogicFieldCatalog:updateControls()
    local frame=TerraLogicFieldAnalysis.frame
    if frame==nil then return end
    local count,index=#(self.entries or {}),0
    local selected=TerraLogicFieldAnalysis.selectedField
    for i,entry in ipairs(self.entries or {}) do
        if (selected and selected.key==entry.key) or (not selected and entry.current) then index=i;break end
    end
    local enabled=count>0 and (count>1 or index==0) and farmFor(nil)==self.openFarm
    for _,list in ipairs({frame.fieldPrevious or {},frame.fieldNext or {}}) do
        for _,button in ipairs(list) do button:setDisabled(not enabled) end
    end
    local key = self.complete and "terraLogic_fa_ownedFields" or "terraLogic_fa_findingFields"
    local label = g_i18n ~= nil and g_i18n:getText(key) or key
    if self.complete then label=TerraLogicI18n.format(label,index,count) end
    -- Keep the centered field control stationary while discovery is running.
    for _,note in ipairs(frame.fieldSelectionNote or {}) do note:setText(self.complete and label or "") end
    for _,note in ipairs(frame.fieldSearchNote or {}) do note:setText(self.complete and "" or label) end
    if frame.refreshFieldBrowser~=nil then frame:refreshFieldBrowser() end
    if frame.updateCatalogScope~=nil then frame:updateCatalogScope() end
end

TerraLogicFieldCatalogRequestEvent={}
local requestMt=Class(TerraLogicFieldCatalogRequestEvent,Event)
InitEventClass(TerraLogicFieldCatalogRequestEvent,"TerraLogicFieldCatalogRequestEvent")
function TerraLogicFieldCatalogRequestEvent.emptyNew() return Event.new(requestMt) end
function TerraLogicFieldCatalogRequestEvent.new(generation,x,z)
    local self=TerraLogicFieldCatalogRequestEvent.emptyNew()
    self.generation,self.x,self.z=generation,x,z;return self
end
function TerraLogicFieldCatalogRequestEvent:writeStream(id,connection)
    streamWriteInt32(id,self.generation);streamWriteFloat32(id,self.x);streamWriteFloat32(id,self.z)
end
function TerraLogicFieldCatalogRequestEvent:readStream(id,connection)
    self.generation,self.x,self.z=streamReadInt32(id),streamReadFloat32(id),streamReadFloat32(id)
    if not connection:getIsServer() then
        TerraLogicFieldCatalog:request(connection,self.generation,self.x,self.z)
    end
end

TerraLogicFieldCatalogEvent={}
local syncMt=Class(TerraLogicFieldCatalogEvent,Event)
InitEventClass(TerraLogicFieldCatalogEvent,"TerraLogicFieldCatalogEvent")
function TerraLogicFieldCatalogEvent.emptyNew() return Event.new(syncMt) end
function TerraLogicFieldCatalogEvent.new(generation,entries,complete)
    local self=TerraLogicFieldCatalogEvent.emptyNew()
    self.generation,self.entries,self.complete=generation,entries,complete;return self
end
function TerraLogicFieldCatalogEvent:writeStream(id,connection)
    streamWriteInt32(id,self.generation);streamWriteBool(id,self.complete)
    local count=math.min(#self.entries,4096);streamWriteUInt16(id,count)
    for i=1,count do local e=self.entries[i]
        streamWriteFloat32(id,e.x);streamWriteFloat32(id,e.z);streamWriteBool(id,e.current == true)
        local ids=e.fieldIds or {};streamWriteUInt16(id,#ids)
        for _,fieldId in ipairs(ids) do streamWriteInt32(id,fieldId) end
        streamWriteInt32(id,e.customId or 0);streamWriteUInt16(id,e.sectionNumber or 0);streamWriteFloat32(id,e.areaHa or 0)
        streamWriteFloat32(id,e.condition or -1)
    end
end
function TerraLogicFieldCatalogEvent:readStream(id,connection)
    local generation,complete=streamReadInt32(id),streamReadBool(id)
    local count=streamReadUInt16(id);local entries={}
    for i=1,count do
        local x,z=streamReadFloat32(id),streamReadFloat32(id)
        entries[i]={x=x,z=z,key=cellKey(x,z),current=streamReadBool(id)}
        local ids={};for _=1,streamReadUInt16(id) do ids[#ids+1]=streamReadInt32(id) end
        entries[i].fieldIds=ids;entries[i].customId=streamReadInt32(id)
        entries[i].sectionNumber=streamReadUInt16(id)
        entries[i].areaHa=streamReadFloat32(id)
        local condition=streamReadFloat32(id);entries[i].condition=condition>=0 and condition or nil
    end
    if connection:getIsServer() then TerraLogicFieldCatalog:receive(generation,entries,complete) end
end
