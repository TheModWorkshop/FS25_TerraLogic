-- Derived field/texture transport factors. No extra raster or water store.
-- Read each layer at its own native spacing, then weight by field-cell area.
-- The edge fractions have the same resolution as field-water geometry; this
-- is a field average, not an additional centimetre-scale hydraulic model.
TerraLogicFieldDrainage = {
    READ_BUDGET=64, MAX_READ_BUDGET=128, REFRESH_MS=60000, REFRESH_HOURS=6
}
local D=TerraLogicFieldDrainage
local function finite(v) return type(v)=="number" and v==v and math.abs(v)<math.huge end
local function bound(v) return finite(v) and math.clamp(v,0,1) or nil end
local function now() return g_currentMission and g_currentMission.time or 0 end

function D:load() self.jobs={};self.cursor=0 end
function D:invalidate(field)
    if not field then return end
    field.drainageStructure=nil
    if self.jobs then self.jobs[field.id]=nil end
end
function D:getFactors(field,index)
    local cache=field and field.drainageStructure
    if cache and cache.geometry==field.geometryRevision then return cache.soils[index] end
    -- Newly discovered / changed fields use the unchanged baseline until a
    -- complete area-weighted snapshot is ready. Never publish half a field.
    return nil
end

-- Optional derived scalars avoid a neutral warm-up after reloading a large
-- map. Old builds ignore these attributes; old saves simply resample.
function D:saveFactors(xml,key,field,index)
    local s=self:getFactors(field,index)
    if not s then return end
    setXMLInt(xml,key..".structure#version",1)
    setXMLFloat(xml,key..".structure#transfer",s.transferFactor)
    setXMLFloat(xml,key..".structure#drainage",s.drainageFactor)
    setXMLFloat(xml,key..".structure#resilience",s.resilience)
end
function D:loadFactors(xml,key,field,index,hour)
    if getXMLInt(xml,key..".structure#version")~=1 or (field.soilAreas[index] or 0)<=0 then return end
    local tf=getXMLFloat(xml,key..".structure#transfer")
    local df=getXMLFloat(xml,key..".structure#drainage")
    local r=getXMLFloat(xml,key..".structure#resilience")
    if not finite(tf) or not finite(df) or not finite(r)
        or tf<.85 or tf>1.30 or df<.85 or df>1.30 or r<0 or r>1 then return end
    local cache=field.drainageStructure or {geometry=field.geometryRevision,
        soils={},time=now()-self.REFRESH_MS,hour=hour or 0}
    field.drainageStructure=cache
    cache.soils[index]={transferFactor=tf,drainageFactor=df,resilience=r}
end

local function layerSize(id,fallback)
    for _,layer in ipairs(TerraLogicSoilManager.layers or {}) do
        if layer.id==id and (layer.cellSize or 0)>0 then return layer.cellSize end
    end
    return fallback
end
local function beginLayer(cell,id,size)
    cell.layer,cell.size,cell.sum,cell.weight=id,size,0,0
    cell.ix,cell.iz=math.floor(cell.x0/size),math.floor(cell.z0/size)
    cell.firstX=cell.ix
end
local function startCell(job,c)
    local x0,z0=math.floor(c.x/8)*8,math.floor(c.z/8)*8
    job.cell={source=c,x0=x0,z0=z0,x1=x0+8,z1=z0+8}
    beginLayer(job.cell,"resilience",layerSize("resilience",8))
end
local function finishCell(job)
    local c=job.cell
    local r=c.resilience
    local shift=(2*r-1)*(r<.5 and .15 or .30)
    local transfer,drain=1+shift,1+shift
    if shift>0 then
        transfer=1+shift*(1-math.max(c.surfaceCompaction,c.deepCompaction))
        drain=1+shift*(1-c.deepCompaction)
    end
    local soil=c.source.soil or 0
    local area=math.clamp(tonumber(c.source.area) or 0,0,64)
    local s=job.soils[soil] or {area=0,transfer=0,drain=0,resilience=0}
    job.soils[soil]=s
    s.area=s.area+area;s.transfer=s.transfer+transfer*area
    s.drain=s.drain+drain*area;s.resilience=s.resilience+r*area
    job.cell=nil
end

-- Exactly one authoritative native-layer read. Cells spanning a different
-- layer size are intersected by area, never averaged by raw pixel count.
function D:readOne(job)
    local c=job.cell
    if not c then
        if job.key and not job.field.cells[job.key] then job.invalid=true;return false end
        local k,source=next(job.field.cells,job.key)
        job.key=k
        if not k then return false end
        startCell(job,source);c=job.cell
    end
    local x0,z0=c.ix*c.size,c.iz*c.size
    local area=math.max(0,math.min(x0+c.size,c.x1)-math.max(x0,c.x0))
        *math.max(0,math.min(z0+c.size,c.z1)-math.max(z0,c.z0))
    local v=bound(TerraLogicSoilManager:getValueAtWorldPosition(c.layer,x0+c.size*.5,z0+c.size*.5))
    if not v then job.invalid=true;return false end
    c.sum,c.weight=c.sum+v*area,c.weight+area
    c.ix=c.ix+1
    if c.ix*c.size>=c.x1 then c.ix=c.firstX;c.iz=c.iz+1 end
    if c.iz*c.size>=c.z1 then
        c[c.layer]=c.sum/math.max(c.weight,1e-9)
        if c.layer=="resilience" then
            if c.resilience<=.5 then finishCell(job)
            else beginLayer(c,"surfaceCompaction",layerSize("surfaceCompaction",1)) end
        elseif c.layer=="surfaceCompaction" then
            beginLayer(c,"deepCompaction",layerSize("deepCompaction",2))
        else finishCell(job) end
    end
    return true
end

function D:update(manager)
    local soil=TerraLogicSoilManager
    if not soil or not soil.getValueAtWorldPosition or soil.rasterReady==false then return end
    self.jobs=self.jobs or {}
    -- Geometry can disappear while a background scan is in progress.
    for id,job in pairs(self.jobs) do
        if manager.fields[id]~=job.field or job.geometry~=job.field.geometryRevision then self.jobs[id]=nil end
    end
    local count=#manager.ids
    if count==0 then return end
    local scale=TerraLogicSoilMoistureManager:getEffectiveTimeScale()
    local budget=math.min(self.MAX_READ_BUDGET,math.max(self.READ_BUDGET,math.ceil(scale/80)))
    for _=1,math.min(count,4) do
        self.cursor=(self.cursor or 0)%count+1
        local f=manager.fields[manager.ids[self.cursor]]
        local cache=f and f.drainageStructure
        local stale=not cache or cache.geometry~=f.geometryRevision
            or now()-cache.time>=self.REFRESH_MS or manager.gameHour-cache.hour>=self.REFRESH_HOURS
        if f and stale then
            local job=self.jobs[f.id]
            if not job then job={field=f,geometry=f.geometryRevision,soils={}};self.jobs[f.id]=job end
            local used=0
            while budget>0 and used<32 do
                if not self:readOne(job) then
                    if not job.invalid then
                        local soils={}
                        for i,s in pairs(job.soils) do
                            if s.area>0 then soils[i]={transferFactor=math.clamp(s.transfer/s.area,.85,1.30),
                                drainageFactor=math.clamp(s.drain/s.area,.85,1.30),resilience=math.clamp(s.resilience/s.area,0,1)} end
                        end
                        -- Flush past forcing under the previous snapshot.
                        manager:flushWater()
                        f.drainageStructure={geometry=f.geometryRevision,soils=soils,time=now(),hour=manager.gameHour}
                    end
                    self.jobs[f.id]=nil;break
                end
                budget=budget-1;used=used+1
            end
        end
        if budget<=0 then break end
    end
end
