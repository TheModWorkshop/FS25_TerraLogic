-- Server-authoritative field water. Sparse geometry reuses Field Analysis's
-- 8 m cells; water is stored per field/texture, never per terrain pixel.
-- Discovery, topology and crop probes are budgeted independently of menus.
TerraLogicFieldWaterManager = {
    CELL_SIZE=8, GEOMETRY_BUDGET=8, PROBE_BUDGET=16,
    CROP_REFRESH_MS=30000, CROP_REFRESH_HOURS=1,
    WATER_STEP_HOURS=1/60,
    SAVE_FILE="terraLogicFieldWater.xml", SAVE_VERSION=1,
    PRECIPITATION_FACTORS={.70,1,1.30}
}
local function server() return g_currentMission and g_currentMission:getIsServer() end
local function clock() return g_currentMission and g_currentMission.time or 0 end
local function keyAt(x,z) return math.floor(x/8)..":"..math.floor(z/8) end
local function path()
    local info=g_currentMission and g_currentMission.missionInfo
    return info and info.savegameDirectory and info.savegameDirectory.."/"..TerraLogicFieldWaterManager.SAVE_FILE
end
local function freshStore(i)
    local w=TerraLogicSoilMoistureManager.waterStores[i]
    return {upper=w.upper,lower=w.lower,history={},day={hours=0,upper=0,lower=0},
        period={hours=0,upper=0,lower=0}}
end

function TerraLogicFieldWaterManager:load()
    self.fields,self.cellOwner,self.queue,self.queued={},{},{},{}
    self.ids,self.nextId,self.revision={},1,0
    self.scanCursor,self.cropCursor=1,1
    self.gameHour=0;self.nextMaintenance=0;self.syncDue=0
    self.pendingDirty={};self.cropJob=nil;self.discovery=nil;self.paddies={}
    self.pendingWater=nil
    self.pruneJob=nil
    self.misses={};self.validationCursor=0;self.nextValidation=30000
    self.networkQueue={};self.broadcastFields={};self.lastBroadcastRevision=nil
    self.initialized=true
    if TerraLogicFieldDrainage then TerraLogicFieldDrainage:load() end
    if server() then self:loadSave();self:seedNativeFields() end
end

function TerraLogicFieldWaterManager:reindex(rebuildOwnership)
    self.ids={}
    if rebuildOwnership~=false then self.cellOwner={} end
    for id,f in pairs(self.fields) do
        self.ids[#self.ids+1]=id
        if rebuildOwnership~=false then for k in pairs(f.cells) do self.cellOwner[k]=id end end
    end
    table.sort(self.ids)
end

function TerraLogicFieldWaterManager:enqueue(x,z,force)
    if not self.initialized or not server() or not x or not z then return end
    local k=keyAt(x,z)
    if #self.queue>=2048 or not force and (self.misses[k] or 0)>clock() then return end
    if not self.queued[k] and (force or not self.cellOwner[k]) then
        self.queued[k]=true;self.queue[#self.queue+1]={x=x,z=z,key=k,force=force}
    end
end

function TerraLogicFieldWaterManager:markDirty(x,z)
    if not self.initialized or not server() then return end
    self.pendingDirty[keyAt(x,z)]={x=x,z=z}
end

function TerraLogicFieldWaterManager:seedNativeFields()
    if not TerraLogicFieldAnalysis then return end
    local count=0
    for _,field in pairs(g_fieldManager and g_fieldManager.fields or {}) do
        count=count+1
        local polygon=TerraLogicFieldAnalysis.getFieldPolygon(field)
        if polygon and #polygon>0 then
            local x,z=0,0
            for _,p in ipairs(polygon) do x,z=x+p.x,z+p.z end
            x,z=x/#polygon,z/#polygon
            self:enqueue(x,z,false)
            for _,p in ipairs(polygon) do self:enqueue(p.x*.8+x*.2,p.z*.8+z*.2,false) end
        end
    end
    self.nativeReady=count>0
end

function TerraLogicFieldWaterManager:getField(x,z)
    if not self.initialized or type(x)~="number" or type(z)~="number" then return nil end
    local id=self.cellOwner[keyAt(x,z)]
    return id and self.fields[id] or nil
end

function TerraLogicFieldWaterManager:getStore(x,z,soil)
    local f=self:getField(x,z)
    if f then return f.stores[soil or 0],f end
    -- A bounded queue lookup, not an immediate geometry scan in wheel code.
    if x and z then self:enqueue(x,z,false) end
    return nil
end

-- Remap by overlap area. Expansion imports ONLY the new area from fallback;
-- splitting retains the parent's state/history; merging conserves water.
function TerraLogicFieldWaterManager:commitGeometry(cells,points)
    if #cells==0 then return end
    self:flushWater()
    local existing=self:getField(cells[1].x,cells[1].z)
    if existing then
        local count=0;local same=true
        for _ in pairs(existing.cells) do count=count+1 end
        if count==#cells then
            for _,c in ipairs(cells) do
                local old=existing.cells[keyAt(c.x,c.z)]
                if not old or math.abs(old.area-64*(c.fraction or 1))>1e-6
                    or c.soil and old.soil~=c.soil then same=false;break end
            end
            if same then return existing end
        end
    end
    local totals,contributions,newCells={}, {}, {}
    local changedRecords={}
    local vegArea,vegKcb,vegCover,vegUpper,vegPond,vegDepletion=0,0,0,0,0,0
    local first=cells[1]
    for _,c in ipairs(cells) do
        local k=keyAt(c.x,c.z)
        local soil=c.soil or TerraLogicSoilMoistureManager:getProfileIndex(
            TerraLogicSoilManager:getPFSoilTypeAtWorldPosition(c.x,c.z))
        local area=64*(c.fraction or 1)
        local old=self.fields[self.cellOwner[k]]
        local oldCell=old and old.cells[k]
        local overlap=oldCell and math.min(area,oldCell.area) or 0
        newCells[k]={x=c.x,z=c.z,soil=soil,area=area}
        totals[soil]=(totals[soil] or 0)+area
        contributions[soil]=contributions[soil] or {}
        if overlap>0 then
            local v=old.vegetation or {kcb=0,cover=0,upperShare=1}
            vegKcb=vegKcb+(v.kcb or 0)*overlap
            vegCover=vegCover+(v.cover or 0)*overlap
            vegUpper=vegUpper+(v.upperShare or 1)*(v.kcb or 0)*overlap
            vegPond=vegPond+(v.ponded or 0)*overlap
            vegDepletion=vegDepletion+(v.depletion or .5)*(v.kcb or 0)*overlap
            local s=old.stores[oldCell.soil] or old.stores[soil]
            local part=contributions[soil][s] or {store=s,area=0}
            part.area=part.area+overlap;contributions[soil][s]=part
            -- Leave unvisited parts in the old record until their own scan.
            old.cells[k]=nil
            old.geometryRevision=self.revision+1
            changedRecords[old.id]=true
        end
        vegArea=vegArea+area
        if area>overlap then
            local part=contributions[soil].fresh or {area=0}
            part.area=part.area+area-overlap;contributions[soil].fresh=part
        end
    end
    local f={id=self.nextId,cells=newCells,points=points,stores={},soilAreas=totals,area=0,x=first.x,z=first.z,
        lastCrop=-math.huge,lastCropHour=-math.huge}
    self.nextId=self.nextId+1
    f.vegetation={kcb=vegKcb/vegArea,cover=vegCover/vegArea,
        upperShare=vegKcb>0 and vegUpper/vegKcb or 1,ponded=vegPond/vegArea,
        depletion=vegKcb>0 and vegDepletion/vegKcb or .5}
    for i=0,4 do
        local w=freshStore(i);local area=totals[i] or 0
        if area>0 then
            local fallback=freshStore(i)
            w.upper,w.lower=0,0
            w.daily={upper=0,lower=0}
            -- Merge water and period/day accumulators, not just live values.
            local serials={}
            for _,part in pairs(contributions[i]) do
                local s=part.store or fallback;local share=part.area/area
                w.upper,w.lower=w.upper+s.upper*share,w.lower+s.lower*share
                TerraLogicMoistureSystemAdapter:mergeStore(w,s,share)
                local daily=s.daily or {upper=s.upper/150,lower=s.lower/450}
                w.daily.upper=w.daily.upper+daily.upper*share
                w.daily.lower=w.daily.lower+daily.lower*share
                for _,name in ipairs({"day","period"}) do
                    for _,k in ipairs({"hours","upper","lower"}) do
                        w[name][k]=w[name][k]+((s[name] or {})[k] or 0)*share
                    end
                end
                for serial,h in pairs(s.history or {}) do serials[serial]=true end
            end
            for serial in pairs(serials) do
                local u,d,weight=0,0,0
                for _,part in pairs(contributions[i]) do
                    local s=part.store;local h=s and s.history and s.history[serial]
                    if h then u,d,weight=u+h.upper*part.area,d+h.lower*part.area,weight+part.area end
                end
                if weight>0 then w.history[serial]={upper=u/weight,lower=d/weight} end
            end
        end
        f.stores[i]=w;f.area=f.area+area
    end
    for id in pairs(changedRecords) do
        local old=self.fields[id]
        local area=0;old.soilAreas={}
        for _,c in pairs(old.cells) do area=area+c.area;old.soilAreas[c.soil]=(old.soilAreas[c.soil] or 0)+c.area end
        old.area=area
        old.msGroups,old.msSamples=nil,nil
        if TerraLogicFieldDrainage then TerraLogicFieldDrainage:invalidate(old) end
        if area==0 then self.fields[id]=nil end
    end
    self.fields[f.id]=f
    for k in pairs(f.cells) do self.cellOwner[k]=f.id end
    self:reindex(false);self.revision=self.revision+1
    f.geometryRevision=self.revision
    self.syncDue=0
    return f
end

function TerraLogicFieldWaterManager:beginCropJob(f)
    local points={}
    for _,p in ipairs(f.points or {}) do
        if f.cells[keyAt(p.x,p.z)] then points[#points+1]=p end
    end
    -- A record left after a split still needs representative coverage.
    if #points==0 then
        for _,p in pairs(f.cells) do points[#points+1]=p;if #points>=169 then break end end
    end
    self.cropJob={field=f,points=points,index=1,count=0,kcb=0,cover=0,upper=0,crops={},ponded=0,depletion=0}
end

-- Read-only bridge to GIANTS PlaceableRiceField: spec.fields contains the
-- Polygon2D and relative waterHeight (metres). No change to vanilla pumps.
function TerraLogicFieldWaterManager:refreshPaddies()
    self.paddies={}
    local system=g_currentMission and g_currentMission.placeableSystem
    for _,placeable in pairs(system and system.placeables or {}) do
        local spec=placeable.spec_riceField
        for _,field in ipairs(spec and spec.fields or {}) do
            if field.polygon and field.polygon.getVertices then
                self.paddies[#self.paddies+1]={field=field,vertices=field.polygon:getVertices()}
            end
        end
    end
end

function TerraLogicFieldWaterManager:isPonded(x,z)
    for _,p in ipairs(self.paddies or {}) do
        if (p.field.waterHeight or 0)>.001 then
            local v=p.vertices;local inside=false
            if #v>=6 and type(v[1])=="number" then
                local j=#v-1
                for i=1,#v-1,2 do
                    if (v[i+1]>z)~=(v[j+1]>z)
                        and x<(v[j]-v[i])*(z-v[i+1])/(v[j+1]-v[i+1])+v[i] then inside=not inside end
                    j=i
                end
            end
            if inside then return true end
        end
    end
    return false
end

function TerraLogicFieldWaterManager:stepCropJob()
    local job=self.cropJob;if not job then return end
    if self.fields[job.field.id]~=job.field then self.cropJob=nil;return end
    local timeScale=TerraLogicSoilMoistureManager:getEffectiveTimeScale()
    local budget=math.min(256,math.max(self.PROBE_BUDGET,math.ceil(timeScale/20)))
    for _=1,budget do
        local p=job.points[job.index]
        if not p then
            if job.count>0 then
                self:flushWater()
                job.field.vegetation={kcb=job.kcb/job.count,cover=job.cover/job.count,
                    upperShare=job.kcb>0 and job.upper/job.kcb or 1,crops=job.crops,
                    ponded=job.ponded/job.count,depletion=job.kcb>0 and job.depletion/job.kcb or .5}
            end
            job.field.lastCrop,job.field.lastCropHour=clock(),self.gameHour
            self.cropJob=nil;return
        end
        local ok,fruit,state=false,nil,nil
        if FSDensityMapUtil and FSDensityMapUtil.getFruitTypeIndexAtWorldPos then
            ok,fruit,state=pcall(FSDensityMapUtil.getFruitTypeIndexAtWorldPos,p.x,p.z)
        end
        if ok then
            local v=TerraLogicCropWaterProfiles:sample(tonumber(fruit),tonumber(state))
            job.count=job.count+1;job.kcb=job.kcb+v.kcb;job.cover=job.cover+v.cover
            job.upper=job.upper+v.upperShare*v.kcb
            job.depletion=job.depletion+(v.depletion or .5)*v.kcb
            if self:isPonded(p.x,p.z) then job.ponded=job.ponded+1 end
            if v.active then job.crops[fruit]=(job.crops[fruit] or 0)+1 end
        end
        job.index=job.index+1
    end
end

function TerraLogicFieldWaterManager:update(dt)
    if not server() or not self.initialized then return end
    if clock()>=(self.nextMaintenance or 0) then
        self.nextMaintenance=clock()+5000
        self:refreshPaddies()
        if not self.nativeReady or clock()>=(self.nextNativeSeed or 0) then
            self:seedNativeFields();self.nextNativeSeed=clock()+60000
        end
        for _,p in pairs(self.pendingDirty) do
            self:enqueue(p.x,p.z,true)
            -- Both sides of a newly cut gap need their own component scan.
        end
        self.pendingDirty={}
    end
    local discovery=self.discovery
    local timeScale=TerraLogicSoilMoistureManager:getEffectiveTimeScale()
    local geometryBudget=math.min(64,math.max(self.GEOMETRY_BUDGET,math.ceil(timeScale/80)))
    local probeBudget=math.min(128,math.max(self.PROBE_BUDGET,math.ceil(timeScale/40)))
    if discovery and discovery.cells then
        for _=1,probeBudget do
            local c=discovery.cells[discovery.index]
            if not c then
                self:commitGeometry(discovery.cells,discovery.points);self.discovery=nil;break
            end
            c.soil=TerraLogicSoilMoistureManager:getProfileIndex(
                TerraLogicSoilManager:getPFSoilTypeAtWorldPosition(c.x,c.z))
            discovery.index=discovery.index+1
        end
    elseif discovery then
        if discovery.job:step(geometryBudget) then
            local r=discovery.job.result
            discovery.cells,discovery.points,discovery.index=r[8] or {},r[1] or {},1
            if #discovery.cells==0 and discovery.key then
                self.misses[discovery.key]=clock()+5000
                local old=self.fields[self.cellOwner[discovery.key]]
                if old and not self.pruneJob then
                    local keys={};for k in pairs(old.cells) do keys[#keys+1]=k end
                    self.pruneJob={field=old,keys=keys,index=1,changed=false}
                end
            end
        end
    else
        local seed=table.remove(self.queue,1)
        if seed then self.queued[seed.key]=nil end
        if seed and (seed.force or not self.cellOwner[seed.key]) then
            self.queued[seed.key]=nil
            self.discovery={key=seed.key,job=TerraLogicFieldAnalysis.createDynamicFieldJob(seed.x,seed.z)}
        elseif not seed then
            -- Slow fallback sweep also finds externally-created/split fields.
            local half=(TerraLogicSoilManager.terrainSize or 2048)/2
            self.sweepX,self.sweepZ=self.sweepX or -half+4,self.sweepZ or -half+4
            for _=1,4 do
                local x,z=self.sweepX,self.sweepZ
                if TerraLogicFieldAnalysis.isVisibleSoilSurface(x,z) then self:enqueue(x,z,false) end
                self.sweepX=self.sweepX+8
                if self.sweepX>=half then self.sweepX=-half+4;self.sweepZ=self.sweepZ+8 end
                if self.sweepZ>=half then self.sweepZ=-half+4;self:seedNativeFields() end
            end
        end
    end
    if clock()>=self.nextValidation and #self.ids>0 then
        self.nextValidation=clock()+30000
        self.validationCursor=self.validationCursor%#self.ids+1
        local f=self.fields[self.ids[self.validationCursor]]
        local points=f.points or {}
        f.validationPoint=(f.validationPoint or 0)%math.max(#points,1)+1
        local p=points[f.validationPoint]
        if p then self:enqueue(p.x,p.z,true) end
    end
    local prune=self.pruneJob
    if prune and self.fields[prune.field.id]~=prune.field then self.pruneJob=nil;prune=nil end
    if prune then
        local f=prune.field
        for _=1,self.PROBE_BUDGET do
            local k=prune.keys[prune.index]
            if not k then
                if prune.changed then
                    if f.area<=0 then self.fields[f.id]=nil end
                    self.revision=self.revision+1;f.geometryRevision=self.revision
                    self:reindex(false);self.syncDue=0
                end
                self.pruneJob=nil;break
            end
            local c=f.cells[k]
            if c and not TerraLogicFieldAnalysis.isVisibleSoilSurface(c.x,c.z) then
                f.msGroups,f.msSamples=nil,nil
                if TerraLogicFieldDrainage then TerraLogicFieldDrainage:invalidate(f) end
                f.cells[k]=nil;f.area=f.area-c.area
                f.soilAreas[c.soil]=math.max((f.soilAreas[c.soil] or 0)-c.area,0)
                if self.cellOwner[k]==f.id then self.cellOwner[k]=nil end
                prune.changed=true
            end
            prune.index=prune.index+1
        end
    end
    if TerraLogicFieldDrainage then TerraLogicFieldDrainage:update(self) end
    self:stepCropJob()
    if not self.cropJob and #self.ids>0 then
        self.cropCursor=self.cropCursor%#self.ids+1
        local f=self.fields[self.ids[self.cropCursor]]
        if f and (clock()-(f.lastCrop or -math.huge)>=self.CROP_REFRESH_MS
            or self.gameHour-(f.lastCropHour or -math.huge)>=self.CROP_REFRESH_HOURS) then self:beginCropJob(f) end
    end
    self.syncDue=(self.syncDue or 0)-dt
    if self.syncDue<=0 then self:sendState(nil);self.syncDue=10000 end
    -- Never send an entire map's geometry in one frame.
    for _=1,4 do
        local packet=table.remove(self.networkQueue or {},1)
        if not packet then break end
        if packet.connection then packet.connection:sendEvent(packet.event)
        elseif g_server then g_server:broadcastEvent(packet.event) end
    end
end

function TerraLogicFieldWaterManager:step(hours,input,evaporation,upperFlow,lowerFlow,snow)
    if not self.initialized or not server() then return end
    self.gameHour=self.gameHour+hours
    -- Hydrology need not traverse every field on every render frame. Buffer
    -- the forcing, not a guessed moisture target; flush at most a game minute
    -- later and before topology, crop, calendar or save boundaries.
    local p=self.pendingWater or {hours=0,input=0,evap=0,upper=0,lower=0,snow=0}
    self.pendingWater=p
    p.hours,p.input=p.hours+hours,p.input+input
    p.evap=p.evap+evaporation*hours;p.upper=p.upper+upperFlow*hours
    p.lower=p.lower+lowerFlow*hours;p.snow=p.snow+snow*hours
    if p.hours+1e-10>=self.WATER_STEP_HOURS then self:flushWater() end
end

function TerraLogicFieldWaterManager:flushWater()
    local p=self.pendingWater
    if not p or p.hours<=0 then return end
    self.pendingWater=nil
    -- Water integration must not cancel the independent, budgeted geometry
    -- cleanup. At high time scales a flush can occur between every batch.
    local hours,input=p.hours,p.input
    local evaporation,upperFlow,lowerFlow,snow=p.evap/hours,p.upper/hours,p.lower/hours,p.snow/hours
    local m=TerraLogicSoilMoistureManager
    for _,f in pairs(self.fields) do
        for i,w in pairs(f.stores) do
            local beforeU,beforeD=w.upper/150,w.lower/450
            local irrigation=m.HYDRAULICS[i].infiltration*upperFlow*hours*(f.vegetation.ponded or 0)
            TerraLogicMoistureSystemAdapter:step(w,m.HYDRAULICS[i],hours,input,evaporation,
                upperFlow,lowerFlow,snow,f.vegetation,m,f,i,irrigation,
                TerraLogicFieldDrainage and TerraLogicFieldDrainage:getFactors(f,i))
            for _,name in ipairs({"day","period"}) do
                local a=w[name];a.hours=a.hours+hours
                a.upper=a.upper+(beforeU+w.upper/150)*.5*hours
                a.lower=a.lower+(beforeD+w.lower/450)*.5*hours
            end
        end
    end
end

function TerraLogicFieldWaterManager:onDayChanged()
    if not server() then return end
    self:flushWater()
    for _,f in pairs(self.fields or {}) do for _,w in pairs(f.stores) do
        local a=w.day
        if a.hours>=12 then w.daily={upper=a.upper/a.hours,lower=a.lower/a.hours} end
        w.day={hours=0,upper=0,lower=0}
    end end
end

function TerraLogicFieldWaterManager:onPeriodChanged(serial,days)
    if not server() then return end
    self:flushWater()
    for _,f in pairs(self.fields or {}) do for _,w in pairs(f.stores) do
        local a=w.period
        if a.hours>=math.max(tonumber(days) or 1,1)*12 then
            w.history[serial]={upper=a.upper/a.hours,lower=a.lower/a.hours}
        end
        for s in pairs(w.history) do if s<serial-48 then w.history[s]=nil end end
        w.period={hours=0,upper=0,lower=0}
    end end
end

function TerraLogicFieldWaterManager:getYieldResponse(x,z,soil,fruit,stage,startSerial,endSerial)
    local w=self:getStore(x,z,soil)
    if not w then return nil end
    local m=TerraLogicSoilMoistureManager
    local response,total,count=nil,0,0
    if startSerial and endSerial and endSerial>startSerial then
        for serial,h in pairs(w.history) do
            if serial>startSerial and serial<=endSerial then
                response=m:getCropYieldResponseForRoot(h.lower,soil,fruit,stage,true,h.upper,h.lower)
                total,count=total+response.factor,count+1
            end
        end
    end
    if count>0 then response.factor=total/count;response.historyPeriods=count
    else
        local h=w.daily or {upper=w.upper/150,lower=w.lower/450}
        response=m:getCropYieldResponseForRoot(h.lower,soil,fruit,stage,nil,h.upper,h.lower)
    end
    response.fieldAverage=true
    return response,count
end

-- Separate save file preserves older global saves and permits safe rollback.
function TerraLogicFieldWaterManager:save()
    if not server() or not self.initialized or not path() then return end
    self:flushWater()
    local xml=createXMLFile("terraLogicFieldWater",path(),"fieldWater")
    if not xml or xml==0 then return end
    setXMLInt(xml,"fieldWater#version",self.SAVE_VERSION)
    setXMLInt(xml,"fieldWater#nextId",self.nextId)
    setXMLFloat(xml,"fieldWater#globalHours",TerraLogicSoilMoistureManager.simulatedGameHours or 0)
    for n,id in ipairs(self.ids) do
        local f=self.fields[id];local k="fieldWater.field("..(n-1)..")"
        setXMLInt(xml,k.."#id",id);setXMLFloat(xml,k.."#x",f.x);setXMLFloat(xml,k.."#z",f.z)
        for _,v in ipairs({"kcb","cover","upperShare","ponded","depletion"}) do
            setXMLFloat(xml,k..".vegetation#"..v,f.vegetation[v] or (v=="depletion" and .5 or 0))
        end
        local cells={}
        for cell,c in pairs(f.cells) do
            local packed=cell..":"..c.soil..":"..c.area
            if c.x%8~=4 or c.z%8~=4 then packed=packed..":"..c.x..":"..c.z end
            cells[#cells+1]=packed
        end
        table.sort(cells)
        for first=1,#cells,128 do
            local block={};for j=first,math.min(first+127,#cells) do block[#block+1]=cells[j] end
            setXMLString(xml,k..".cells("..math.floor((first-1)/128)..")#data",table.concat(block," "))
        end
        for i,w in pairs(f.stores) do
            local s=k..".soil("..i..")"
            setXMLFloat(xml,s.."#upper",w.upper);setXMLFloat(xml,s.."#lower",w.lower)
            TerraLogicMoistureSystemAdapter:saveStore(xml,s,w)
            if TerraLogicFieldDrainage then TerraLogicFieldDrainage:saveFactors(xml,s,f,i) end
            for _,name in ipairs({"day","period","daily"}) do
                for _,a in ipairs({"hours","upper","lower"}) do
                    if w[name] and w[name][a] then setXMLFloat(xml,s.."."..name.."#"..a,w[name][a]) end
                end
            end
            local hi=0
            for serial,h in pairs(w.history) do
                local hk=s..".history("..hi..")";hi=hi+1
                setXMLInt(xml,hk.."#serial",serial)
                setXMLFloat(xml,hk.."#upper",h.upper);setXMLFloat(xml,hk.."#lower",h.lower)
            end
        end
    end
    saveXMLFile(xml);delete(xml)
end

function TerraLogicFieldWaterManager:loadSave()
    if not path() or not fileExists(path()) then return end
    local xml=loadXMLFile("terraLogicFieldWater",path())
    if not xml or xml==0 then return end
    if getXMLInt(xml,"fieldWater#version")~=self.SAVE_VERSION then delete(xml);return end
    local savedHours=getXMLFloat(xml,"fieldWater#globalHours")
    if savedHours and math.abs(savedHours-(TerraLogicSoilMoistureManager.simulatedGameHours or 0))>.01 then
        Logging.warning('[FS25_TerraLogic] Field water belongs to a different save point (for example after a rollback). Fields will inherit the current fallback water state.')
        delete(xml);return
    end
    self.nextId=math.max(getXMLInt(xml,"fieldWater#nextId") or 1,1)
    local n=0
    while getXMLInt(xml,"fieldWater.field("..n..")#id") do
        local k="fieldWater.field("..n..")";n=n+1
        local id=getXMLInt(xml,k.."#id")
        local f={id=id,x=getXMLFloat(xml,k.."#x"),z=getXMLFloat(xml,k.."#z"),
            cells={},stores={},points={},soilAreas={},area=0,vegetation={kcb=0,cover=0,upperShare=1,depletion=.5}}
        for _,v in ipairs({"kcb","cover","upperShare","ponded","depletion"}) do
            f.vegetation[v]=getXMLFloat(xml,k..".vegetation#"..v) or f.vegetation[v]
        end
        local block=0
        while getXMLString(xml,k..".cells("..block..")#data") do
            for token in string.gmatch(getXMLString(xml,k..".cells("..block..")#data"),"%S+") do
                local values={};for v in token:gmatch("[^:]+") do values[#values+1]=tonumber(v) end
                local ix,iz,soil,area=values[1],values[2],values[3],values[4]
                if ix and iz and soil and soil>=0 and soil<=4 and area then
                    local c={x=values[5] or (ix+.5)*8,z=values[6] or (iz+.5)*8,
                        soil=soil,area=math.clamp(area,0,64)}
                    f.cells[ix..":"..iz]=c;f.area=f.area+c.area
                    f.soilAreas[soil]=(f.soilAreas[soil] or 0)+c.area
                end
            end
            block=block+1
        end
        local all={};for _,c in pairs(f.cells) do all[#all+1]=c end
        table.sort(all,function(a,b)return a.z<b.z or a.z==b.z and a.x<b.x end)
        for j=1,math.min(169,#all) do f.points[j]=all[math.ceil((j-.5)*#all/math.min(169,#all))] end
        for i=0,4 do
            local s=k..".soil("..i..")";local w=freshStore(i);local h=TerraLogicSoilMoistureManager.HYDRAULICS[i]
            w.upper=math.clamp(getXMLFloat(xml,s.."#upper") or w.upper,0,h.upper)
            w.lower=math.clamp(getXMLFloat(xml,s.."#lower") or w.lower,0,h.lower)
            TerraLogicMoistureSystemAdapter:loadStore(xml,s,w,h)
            if TerraLogicFieldDrainage then TerraLogicFieldDrainage:loadFactors(xml,s,f,i,self.gameHour) end
            for _,name in ipairs({"day","period","daily"}) do
                if getXMLFloat(xml,s.."."..name.."#upper") then
                    w[name]={hours=getXMLFloat(xml,s.."."..name.."#hours") or 0,
                        upper=getXMLFloat(xml,s.."."..name.."#upper"),lower=getXMLFloat(xml,s.."."..name.."#lower")}
                end
            end
            local hi=0
            while getXMLInt(xml,s..".history("..hi..")#serial") do
                local hk=s..".history("..hi..")";hi=hi+1
                w.history[getXMLInt(xml,hk.."#serial")]={upper=getXMLFloat(xml,hk.."#upper"),lower=getXMLFloat(xml,hk.."#lower")}
            end
            f.stores[i]=w
        end
        if f.area>0 and f.x and f.z then self.fields[id]=f;self.nextId=math.max(self.nextId,id+1) end
    end
    delete(xml);self:reindex()
end

function TerraLogicFieldWaterManager:delete()
    if TerraLogicFieldDrainage then TerraLogicFieldDrainage:load() end
    self.initialized=false;self.fields={};self.cellOwner={};self.ids={}
    self.queue={};self.queued={};self.discovery=nil;self.cropJob=nil
    self.networkQueue={};self.lastBroadcastRevision=nil;self.broadcastFields={}
    self.paddies={};self.pendingDirty={};self.misses={}
    self.pendingWater=nil
end

-- Compact field geometry is sent only after topology changes / on join.
-- Live stores and daily averages are much smaller and travel every 10 s.
function TerraLogicFieldWaterManager:sendState(connection)
    if not server() or not self.initialized or not TerraLogicFieldWaterEvent then return end
    self.networkQueue=self.networkQueue or {}
    -- Finish an existing broadcast before scheduling another snapshot.
    if not connection and #self.networkQueue>0 then return end
    local function queue(kind,id,cells,values)
        self.networkQueue[#self.networkQueue+1]={connection=connection,
            event=TerraLogicFieldWaterEvent.new(kind,id,self.revision,cells,values)}
    end
    local full=connection~=nil or self.lastBroadcastRevision==nil
    self.broadcastFields=self.broadcastFields or {}
    if full then queue(0,0)
    else
        for id in pairs(self.broadcastFields) do if not self.fields[id] then queue(3,id) end end
    end
    for _,id in ipairs(self.ids) do
        local f=self.fields[id];local values={}
        local geometry=full or self.broadcastFields[id]~=(f.geometryRevision or 0)
        if geometry and not full then queue(3,id) end
        for i=0,4 do
            local w=f.stores[i];local daily=w.daily or {upper=w.upper/150,lower=w.lower/450}
            values[i]={w.upper,w.lower,daily.upper,daily.lower,w.msWaterSource or 0}
        end
        queue(2,id,nil,values)
        if geometry then
            local cells={}
            for k in pairs(f.cells) do
                local ix,iz=string.match(k,"([%-0-9]+):([%-0-9]+)")
                cells[#cells+1]={tonumber(ix),tonumber(iz)}
                if #cells==128 then queue(1,id,cells);cells={} end
            end
            if #cells>0 then queue(1,id,cells) end
        end
        if not connection then self.broadcastFields[id]=f.geometryRevision or 0 end
    end
    if not connection then
        for id in pairs(self.broadcastFields) do if not self.fields[id] then self.broadcastFields[id]=nil end end
        self.lastBroadcastRevision=self.revision
    end
end

TerraLogicFieldWaterEvent={}
local FieldWaterEvent_mt=Class(TerraLogicFieldWaterEvent,Event)
InitEventClass(TerraLogicFieldWaterEvent,"TerraLogicFieldWaterEvent")
function TerraLogicFieldWaterEvent.emptyNew() return Event.new(FieldWaterEvent_mt) end
function TerraLogicFieldWaterEvent.new(kind,id,revision,cells,values)
    local self=TerraLogicFieldWaterEvent.emptyNew()
    self.kind,self.id,self.revision,self.cells,self.values=kind,id,revision,cells,values
    return self
end
function TerraLogicFieldWaterEvent:writeStream(streamId,connection)
    streamWriteUIntN(streamId,self.kind,2)
    streamWriteInt32(streamId,self.id);streamWriteInt32(streamId,self.revision)
    if self.kind==1 then
        streamWriteUInt8(streamId,#self.cells)
        for _,c in ipairs(self.cells) do streamWriteInt16(streamId,c[1]);streamWriteInt16(streamId,c[2]) end
    elseif self.kind==2 then
        for i=0,4 do
            for j=1,4 do streamWriteFloat32(streamId,self.values[i][j]) end
            streamWriteUIntN(streamId,self.values[i][5] or 0,2)
        end
    end
end
function TerraLogicFieldWaterEvent:readStream(streamId,connection)
    self.kind=streamReadUIntN(streamId,2)
    self.id,self.revision=streamReadInt32(streamId),streamReadInt32(streamId)
    self.cells,self.values={},{}
    if self.kind==1 then
        local n=streamReadUInt8(streamId)
        for i=1,n do self.cells[i]={streamReadInt16(streamId),streamReadInt16(streamId)} end
    elseif self.kind==2 then
        for i=0,4 do
            self.values[i]={};for j=1,4 do self.values[i][j]=streamReadFloat32(streamId) end
            self.values[i][5]=streamReadUIntN(streamId,2)
        end
    end
    self:run(connection)
end
function TerraLogicFieldWaterEvent:run(connection)
    -- Reject client-originated simulation writes, including on listen servers.
    if not connection:getIsServer() or server() then return end
    local m=TerraLogicFieldWaterManager
    if not m.initialized then return end
    if self.kind==0 then m.fields={};m.cellOwner={};m.ids={};m.revision=self.revision;return end
    if self.revision<(m.revision or 0) then return end
    m.revision=self.revision
    if self.kind==3 then
        local previous=m.fields[self.id]
        for k in pairs(previous and previous.cells or {}) do
            if m.cellOwner[k]==self.id then m.cellOwner[k]=nil end
        end
        m.fields[self.id]=nil;return
    end
    local f=m.fields[self.id] or {id=self.id,cells={},stores={}}
    m.fields[self.id]=f
    if self.kind==1 then
        for _,c in ipairs(self.cells) do
            local k=c[1]..":"..c[2];f.cells[k]=true;m.cellOwner[k]=self.id
        end
    elseif self.kind==2 then
        for i=0,4 do
            local v=self.values[i];f.stores[i]={upper=v[1],lower=v[2],daily={upper=v[3],lower=v[4]},msWaterSource=v[5] or 0}
        end
    end
end

if FSBaseMission and FSBaseMission.sendInitialClientState then
    FSBaseMission.sendInitialClientState=Utils.appendedFunction(FSBaseMission.sendInitialClientState,
        function(_,connection) TerraLogicFieldWaterManager:sendState(connection) end)
end
