-- Optional, server-owned boundary adapter. MS objects are only queried; the
-- irrigation observer forwards the original call and never changes its result.
-- MS percentages are an abstract wetness signal, not measured volumetric water.
TerraLogicMoistureSystemAdapter = {
    MAPPING_ID="ms-field-v3-wet50", RELAXATION_HOURS=.5, MAX_DRYING_MM_H=2,
    SAMPLE_CACHE_MS=500, MAX_HYDRAULIC_STEP=1/60
}
local A=TerraLogicMoistureSystemAdapter
local function finite(v)return type(v)=="number" and v==v and math.abs(v)<math.huge end
local function server()return g_currentMission and g_currentMission:getIsServer()end
local function now()return g_currentMission and g_currentMission.time or 0 end
local function pack(...)return {n=select('#',...),...}end
local function number(o,k,...)
    if o and type(o[k])=="function" then
        local ok,v=pcall(o[k],o,...)
        if ok and finite(v) then return v end
    end
end

function A:isAvailable()
    local ms=g_currentMission and g_currentMission.MoistureSystem
    return ms~=nil and type(ms.getMoistureAtPosition)=="function"
end

function A:getMS()
    local ms=g_currentMission and g_currentMission.MoistureSystem
    if self:isAvailable() and ms.missionStarted==true and finite(ms.currentMoisturePercent)
        and ms.currentMoisturePercent>=0 and ms.currentMoisturePercent<=1 then return ms end
end

function A:isUsingMS()
    return self.initialized==true and TerraLogicSettings~=nil
        and TerraLogicSettings.moistureSource=="moistureSystem" and self:getMS()~=nil
end

-- Keep dry/ordinary conditions unchanged. Above 30 MS percentage points,
-- halve the additional rise rather than forcing saturation already at 50.
-- Use the same knots in both directions, including TL-owned irrigation.
function A:getMoistureCurve(h)
    local f30=.4*(.30-.22)/(.35-.22)
    local f35=f30+.5*(.4-f30)
    local saturationAt=.35+(1-f35)/2
    local d=h.saturation-h.fieldCapacity
    return {0,.05,.12,.22,.30,.35,saturationAt},
        {h.residual,h.wilt,(h.wilt+h.fieldCapacity)*.5,h.fieldCapacity,
            h.fieldCapacity+f30*d,h.fieldCapacity+f35*d,h.saturation}
end

function A:mapMoisture(value,h)
    if not finite(value) or value<0 or value>1 or not h then return nil end
    local x,y=self:getMoistureCurve(h)
    if value>=x[#x] then return h.saturation end
    for i=1,#x-1 do
        if value<=x[i+1] then return y[i]+(y[i+1]-y[i])*(value-x[i])/(x[i+1]-x[i]) end
    end
end

function A:inverseMoisture(theta,h)
    local x,y=self:getMoistureCurve(h)
    if theta<=y[1] then return 0 end
    if theta>=h.saturation then return x[#x] end
    for i=1,#y-1 do
        if theta<=y[i+1]then return x[i]+(x[i+1]-x[i])*(theta-y[i])/(y[i+1]-y[i])end
    end
end

function A:load()
    self:delete()
    self.initialized=true;self.readErrors=0;self.lastReady=nil
    self.observerWarning=nil
    self.receipts=0;self.receiptEquivalentMm=0
    self:installObserver()
end

function A:resetReferences(clearIrrigation)
    local m=TerraLogicSoilMoistureManager
    for _,w in pairs(m and m.waterStores or {})do
        w.msRefUpper,w.msRefLower=nil,nil
        if clearIrrigation then w.msIrrigationPendingMm=nil end
    end
    local f=TerraLogicFieldWaterManager
    for _,field in pairs(f and f.fields or {})do
        field.msSamples=nil
        for _,w in pairs(field.stores)do
            w.msRefUpper,w.msRefLower=nil,nil
            -- The new MS boundary already includes these delivered boosts.
            -- Keeping an unconsumed TL receipt would count the same water twice.
            if clearIrrigation then w.msIrrigationPendingMm=nil end
        end
    end
    if f then f.syncDue=0 end
end

-- Exact texture/farmland area weights; a few real cell positions in each group
-- sample height variation. Geometry work happens once, never in wheel queries.
function A:buildFieldGroups(field)
    if field.msGroups then return field.msGroups end
    if not g_farmlandManager or not g_farmlandManager.getFarmlandIdAtWorldPosition then return nil end
    local groups={}
    for _,c in pairs(field.cells or {})do
        if type(c)=="table" then
            local farmland=number(g_farmlandManager,"getFarmlandIdAtWorldPosition",c.x,c.z)
            if farmland then
                local key=c.soil..":"..farmland
                local g=groups[key] or {soil=c.soil,farmland=farmland,area=0,points={}}
                groups[key]=g;g.area=g.area+c.area
                local p=g.points
                p[1]=p[1] or c
                if not p[2] or c.x<p[2].x or c.x==p[2].x and c.z<p[2].z then p[2]=c end
                if not p[3] or c.x>p[3].x or c.x==p[3].x and c.z>p[3].z then p[3]=c end
                if not p[4] or c.z<p[4].z or c.z==p[4].z and c.x<p[4].x then p[4]=c end
                if not p[5] or c.z>p[5].z or c.z==p[5].z and c.x>p[5].x then p[5]=c end
            end
        end
    end
    field.msGroups=groups
    return groups
end

function A:readLocal(ms,p)
    local value=number(ms,"getMoistureAtPosition",p.x,p.z)
    if value and value>=0 and value<=1 then return value end
    self.readErrors=(self.readErrors or 0)+1
end

function A:getFieldTargets(field,ms)
    local stamp=now()
    local cache=field.msSamples
    if cache and cache.ms==ms and cache.base==ms.currentMoisturePercent
        and cache.generation==ms.moistureCache and stamp<cache.untilMs then
        return cache.targets
    end
    local groups=self:buildFieldGroups(field)
    if not groups then return nil end
    local targets,areas,invalid={},{},{}
    for _,g in pairs(groups)do
        local sum,count,seen=0,0,{}
        for _,p in ipairs(g.points)do
            local k=p.x..":"..p.z
            if not seen[k] then
                seen[k]=true
                local value=self:readLocal(ms,p)
                if value then
                    sum=sum+self:mapMoisture(value,TerraLogicSoilMoistureManager.HYDRAULICS[g.soil])
                    count=count+1
                else invalid[g.soil]=true end
            end
        end
        if count>0 then
            targets[g.soil]=(targets[g.soil] or 0)+sum/count*g.area
            areas[g.soil]=(areas[g.soil] or 0)+g.area
        end
    end
    for i,v in pairs(targets)do
        targets[i]=not invalid[i] and areas[i]>0 and v/areas[i] or nil
    end
    field.msSamples={ms=ms,base=ms.currentMoisturePercent,generation=ms.moistureCache,
        untilMs=stamp+self.SAMPLE_CACHE_MS,targets=targets}
    return targets
end

-- Save/load and topology retain these small state variables alongside the
-- existing reservoirs. There is no delivered-job ledger to replay on loading.
function A:saveStore(xml,key,w)
    for _,k in ipairs({"msRefUpper","msRefLower","msIrrigationPendingMm","msWaterSource"})do
        if finite(w[k])then setXMLFloat(xml,key.."#"..k,w[k])end
    end
end
function A:loadStore(xml,key,w,h)
    for _,k in ipairs({"msRefUpper","msRefLower","msIrrigationPendingMm","msWaterSource"})do
        local v=getXMLFloat(xml,key.."#"..k)
        if finite(v)then
            if k=="msRefUpper" then v=math.clamp(v,h.residual*150,h.upper)
            elseif k=="msRefLower" then v=math.clamp(v,h.residual*450,h.lower)
            elseif k=="msWaterSource" then v=v==1 and 1 or 0
            else v=math.clamp(v,0,10000)end
            w[k]=v
        end
    end
end
function A:mergeStore(w,s,share)
    for _,k in ipairs({"msRefUpper","msRefLower"})do
        local fallback=k=="msRefUpper" and s.upper or s.lower
        w[k]=(w[k] or 0)+(s[k] or fallback)*share
    end
    w.msIrrigationPendingMm=(w.msIrrigationPendingMm or 0)+(s.msIrrigationPendingMm or 0)*share
    w.msWaterSource=math.max(w.msWaterSource or 0,s.msWaterSource or 0)
end

-- Reference assimilation supplies a bounded external boundary flux. It never
-- restores the cropped store to a target or cancels that field's root uptake.
function A:step(w,h,hours,rain,evaporation,upperFlow,lowerFlow,snow,vegetation,manager,field,index,ponded,structure)
    local ms=self:isUsingMS() and self:getMS() or nil
    local target
    if ms then
        if field then target=(self:getFieldTargets(field,ms) or {})[index]
        else target=self:mapMoisture(ms.currentMoisturePercent,h)end
    end
    local pending=math.max(w.msIrrigationPendingMm or 0,0)
    w.msIrrigationPendingMm=nil
    w.msWaterSource=target and 1 or 0
    w.lastMSInputMm,w.lastMSDryingMm=0,0
    w.lastIrrigationMm=pending+math.max(ponded or 0,0)
    if not target then
        -- Preserve the original standalone numerical path, including its
        -- integration step size and vegetation defaults.
        w.msRefUpper,w.msRefLower=nil,nil
        w.lastInputMm=rain+w.lastIrrigationMm
        return TerraLogicWaterBalance:step(w,h,hours,w.lastInputMm,evaporation,
            upperFlow,lowerFlow,snow,vegetation,manager,structure)
    end
    local before=w.upper+w.lower
    local remaining=hours
    local totals={0,0,0,0,0,0,0}
    while remaining>1e-10 do
        local dt=math.min(remaining,self.MAX_HYDRAULIC_STEP)
        remaining=remaining-dt
        local share=dt/hours
        local source=rain*share
        local extraDry=0
        if target then
            source=0 -- MS already represents rainfall, snowfall and its irrigation.
            local ref={upper=w.msRefUpper or w.upper,lower=w.msRefLower or w.lower}
            TerraLogicWaterBalance:step(ref,h,dt,0,evaporation,upperFlow,lowerFlow,snow,
                {kcb=0,cover=0,upperShare=.25,depletion=.5},manager)
            local frozen=TerraLogicSoilTemperatureManager and TerraLogicSoilTemperatureManager.surfaceFrozen
            local correction=frozen and 0 or (target*150-ref.upper)*(1-math.exp(-dt/self.RELAXATION_HOURS))
            correction=math.clamp(correction,-self.MAX_DRYING_MM_H*dt,h.infiltration*upperFlow*dt)
            correction=math.clamp(correction,h.residual*150-ref.upper,h.upper-ref.upper)
            ref.upper=ref.upper+correction
            w.msRefUpper,w.msRefLower=ref.upper,ref.lower
            source=math.max(correction,0)
            extraDry=math.min(math.max(w.upper-h.residual*150,0),math.max(-correction,0))
            w.upper=w.upper-extraDry
            w.lastMSInputMm=w.lastMSInputMm+source
            w.lastMSDryingMm=w.lastMSDryingMm+extraDry
        end
        local input=source+(pending+math.max(ponded or 0,0))*share
        -- The neutral MS reference above deliberately has NO structure
        -- factors. Otherwise assimilation would refill the extra drainage.
        local values={TerraLogicWaterBalance:step(w,h,dt,input,evaporation,upperFlow,lowerFlow,snow,vegetation,manager,structure)}
        for j=1,7 do totals[j]=totals[j]+values[j]end
    end
    w.lastInputMm=(target and w.lastMSInputMm or rain)+w.lastIrrigationMm
    w.lastBalanceError=w.upper+w.lower-before-totals[1]+totals[3]+totals[4]+totals[5]+w.lastMSDryingMm
    return unpack(totals)
end

-- Observe completed delivery, not bookings or the still-present residual boost.
-- In TL mode translate each delivered increment relative to TL's own current
-- water reserve. An unrelated high MS ambient value must never cancel irrigation
-- on a dry TL field. The inverse uses exactly the same fixed conversion table.
function A:prepareDeliveries(irrigation)
    if not self.initialized or not server() or self:isUsingMS() or not self:getMS()
        or TerraLogicSoilMoistureManager.auditOverrideActive then return nil end
    local f=TerraLogicFieldWaterManager
    if not f or not f.initialized then return nil end
    f:flushWater()
    local deliveries={}
    for _,job in pairs(irrigation.jobs or {})do
        local id=job.farmlandId
        if id and not deliveries[id]then
            deliveries[id]={old=number(irrigation,"getBoost",id) or 0,entries={}}
        end
    end
    if next(deliveries)==nil then return nil end
    for _,field in pairs(f.fields)do
        for _,g in pairs(self:buildFieldGroups(field) or {})do
            local delivery=deliveries[g.farmland]
            if delivery and (field.soilAreas[g.soil] or 0)>0 then
                delivery.entries[#delivery.entries+1]={field=field,soil=g.soil,
                    share=g.area/field.soilAreas[g.soil]}
            end
        end
    end
    return deliveries
end

function A:finishDeliveries(irrigation,deliveries)
    if not deliveries then return end
    local additions={}
    for id,d in pairs(deliveries)do
        local boost=number(irrigation,"getBoost",id)
        local delta=boost and math.max(boost-d.old,0) or 0
        if delta>0 then
            self.receipts=self.receipts+1
            for _,entry in ipairs(d.entries)do
                local w=entry.field.stores[entry.soil]
                local h=TerraLogicSoilMoistureManager.HYDRAULICS[entry.soil]
                local theta=math.clamp((w.upper+(w.msIrrigationPendingMm or 0))/150,h.residual,h.saturation)
                local reference=self:inverseMoisture(theta,h)
                local mm=math.max(self:mapMoisture(math.min(reference+delta,1),h)-theta,0)*150*entry.share
                additions[w]=(additions[w] or 0)+mm
                self.receiptEquivalentMm=self.receiptEquivalentMm+mm
            end
        end
    end
    for w,mm in pairs(additions)do w.msIrrigationPendingMm=(w.msIrrigationPendingMm or 0)+mm end
    for _,field in pairs(TerraLogicFieldWaterManager.fields)do field.msSamples=nil end
end

function A:observerError()
    self.readErrors=(self.readErrors or 0)+1
    if not self.observerWarning then
        self.observerWarning=true
        Logging.warning('[FS25_TerraLogic] Moisture System irrigation observer could not read a delivery. MS itself remains unchanged.')
    end
end

function A:installObserver()
    if not self.initialized or not server() then return end
    local irrigation=g_currentMission.irrigationSystem
    if not irrigation or type(irrigation.runJobs)~="function" then return end
    if self.irrigation==irrigation then return end
    local original=irrigation.runJobs
    self.irrigation,self.originalRunJobs=irrigation,original
    local mission=g_currentMission
    local wrapper=function(object,...)
        local active=A.initialized and g_currentMission==mission and A.irrigation==object
        local ok,prepared=true,nil
        if active then ok,prepared=pcall(A.prepareDeliveries,A,object)end
        if not ok then A:observerError();prepared=nil end
        -- Do not catch, suppress or change an exception from the actual MS job.
        local result=pack(original(object,...))
        if active then
            local worked=pcall(A.finishDeliveries,A,object,prepared)
            if not worked then A:observerError()end
        end
        return unpack(result,1,result.n)
    end
    self.runJobsWrapper=wrapper;irrigation.runJobs=wrapper
end

function A:update()
    if not self.initialized or not server() then return end
    TerraLogicSettings:refreshCompatibilityDefaults()
    self:installObserver()
    local ready=self:getMS()~=nil
    if self.lastReady~=nil and ready~=self.lastReady then self:resetReferences()end
    self.lastReady=ready
end

function A:delete()
    if self.irrigation and self.irrigation.runJobs==self.runJobsWrapper then
        self.irrigation.runJobs=self.originalRunJobs
    end
    self.initialized=false;self.irrigation=nil;self.originalRunJobs=nil;self.runJobsWrapper=nil
end
