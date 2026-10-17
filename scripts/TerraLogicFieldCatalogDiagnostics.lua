-- Explicit, server-local geometry export. Does not change the catalogue,
-- fields, ownership, density maps or water stores. Terrain work and CSV writes
-- are spread over updates; normal gameplay never allocates connection traces.
TerraLogicFieldCatalogDiagnostics = {ROWS_PER_UPDATE=128, MAX_EDGES=2048}
local D=TerraLogicFieldCatalogDiagnostics
local columns={"record","farm_id","native_field","component","offered","reason",
    "area_ha","area_m2","x_m","z_m","ix","iz","fraction","to_x_m","to_z_m",
    "blocked_x_m","blocked_z_m","connected","resolved_x_m","resolved_z_m",
    "coarse_connections","detour_connections","blocked_connections","omitted_edges",
    "probes","cache_age_ms","scan_capped"}

local function csv(value)
    if value==nil then return '""' end
    if type(value)=="number" then value=string.format("%.10g",value) end
    return '"'..tostring(value):gsub('"','""'):gsub('[\r\n]',' ')..'"'
end

local function owned(x,z,owner)
    local land=g_farmlandManager and g_farmlandManager:getFarmlandAtWorldPosition(x,z)
    if not land then return false end
    local actual=g_farmlandManager.getFarmlandOwner
        and g_farmlandManager:getFarmlandOwner(land.id) or land.farmId
    return actual==owner
end

function D:reset()
    if self.file then pcall(delete,self.file) end
    self.file,self.records,self.geometry,self.output,self.path,self.trace=nil,nil,nil,nil,nil,nil
    self.index,self.phase=nil,nil
end

function D:write(row)
    local values={}
    for i,key in ipairs(columns) do values[i]=csv(row[key]) end
    local ok,result=pcall(fileWrite,self.file,table.concat(values,";").."\n")
    if not ok or result==false then error("field diagnostic CSV write failed") end
end

function D:command(argument)
    if not g_currentMission or not g_currentMission:getIsServer() then
        return "Field diagnostics: run tlFieldDebug on the host/server console."
    end
    if argument=="status" or argument==nil then
        return self.records and ("Field diagnostics running | "..self.path)
            or "tlFieldDebug <field number> | status | stop (open Field Analysis first)"
    end
    if argument=="stop" then
        local path=self.path
        self:reset()
        return "Field diagnostics stopped; any CSV already created is incomplete: "..tostring(path or "none")
    end
    if self.records then return "Field diagnostics already running; use tlFieldDebug status or stop." end
    local fieldId=tonumber(argument)
    if not fieldId or fieldId~=fieldId or fieldId<0 or fieldId==math.huge
        or fieldId~=math.floor(fieldId) then return "tlFieldDebug <field number> | status | stop" end
    if not createFile or not fileWrite or not FileAccess or not createFolder
        or not fileExists or not getUserProfileAppPath or not getDate then
        return "Field diagnostics: file API unavailable."
    end
    local catalog=TerraLogicFieldCatalog
    local records={}
    for owner,cache in pairs(catalog.cache or {}) do
        local entries={}
        for _,entry in ipairs(cache.entries or {}) do
            if owned(entry.x,entry.z,owner) then entries[#entries+1]=entry end
        end
        local _,hidden=catalog:getOfferedEntries(entries)
        for _,entry in ipairs(entries) do
            local matches=false
            for _,id in ipairs(entry.fieldIds or {}) do if id==fieldId then matches=true end end
            if matches and not entry.provisional then
                local cells={}
                for key in pairs(entry.cells or {}) do
                    local ix,iz=key:match("^(-?%d+):(-?%d+)$")
                    cells[#cells+1]={ix=tonumber(ix),iz=tonumber(iz)}
                end
                table.sort(cells,function(a,b)
                    return (a.iz or 0)<(b.iz or 0)
                        or a.iz==b.iz and (a.ix or 0)<(b.ix or 0)
                end)
                records[#records+1]={owner=owner,fieldId=fieldId,key=entry.key,
                    x=entry.x,z=entry.z,areaHa=entry.areaHa or 0,cells=cells,
                    offered=hidden[entry]==nil,reason=hidden[entry] or "retained",
                    cacheAge=math.max(0,(g_currentMission.time or 0)-(cache.time or 0))}
            end
        end
    end
    -- Jobs are keyed by requester, not farm. Do not capture an incomplete
    -- discovery or misleadingly use a previous cache while it is refreshed.
    for _,job in pairs(catalog.jobs or {}) do
        for _,record in ipairs(records) do
            if record.owner==job.owner then
                return "Field diagnostics: wait until field discovery has finished."
            end
        end
    end
    if #records==0 then
        return "Field diagnostics: no completed catalogue for that field. Open its farm's Field Analysis and wait for discovery."
    end
    table.sort(records,function(a,b)
        if a.owner~=b.owner then return a.owner<b.owner end
        if a.z~=b.z then return a.z<b.z end
        return a.x<b.x
    end)
    local root=getUserProfileAppPath().."modSettings"
    local directory=root.."/FS25_TerraLogic/fieldDiagnostics"
    for _,folder in ipairs({root,root.."/FS25_TerraLogic",directory}) do pcall(createFolder,folder) end
    local stamp=tostring(getDate("%Y%m%d_%H%M%S")):gsub("[^%w_-]","_")
    local stem=directory.."/TerraLogic_field"..fieldId.."_"..stamp
    local path=stem..".csv"
    local serial=1
    while fileExists(path) do path=stem.."_"..serial..".csv";serial=serial+1 end
    local ok,file=pcall(createFile,path,FileAccess.WRITE)
    if not ok or file==nil or file==0 then return "Field diagnostics: cannot create "..path end
    self.file,self.path,self.records,self.index,self.phase=file,path,records,1,"start"
    local ok,result=pcall(fileWrite,file,table.concat(columns,";").."\n")
    if not ok or result==false then self:reset();return "Field diagnostics: cannot write CSV header." end
    return "Field diagnostics started (read-only, incremental): "..path
end

function D:step()
    local record=self.records[self.index]
    if not record then
        local path=self.path
        self:write({record="complete"})
        self:reset()
        Logging.info("[FS25_TerraLogic] Field diagnostics complete: %s",path)
        return
    end
    local function row(kind)
        return {record=kind,farm_id=record.owner,native_field=record.fieldId,
            component=record.key,offered=record.offered,reason=record.reason}
    end
    if self.phase=="start" then
        local header=row("component")
        header.area_ha,header.area_m2=record.areaHa,record.areaHa*10000
        header.x_m,header.z_m,header.cache_age_ms=record.x,record.z,record.cacheAge
        self:write(header)
        self.output,self.phase=1,"cached"
    elseif self.phase=="scan" then
        if self.geometry:step(TerraLogicFieldCatalog.GEOMETRY_CELLS_PER_SLICE) then
            local result,trace=self.geometry.result,self.trace
            local header=row("recheck")
            header.area_ha,header.area_m2=result[2],result[2]*10000
            header.coarse_connections,header.detour_connections=trace.coarseConnections or 0,trace.detourConnections or 0
            header.blocked_connections,header.omitted_edges=trace.blockedConnections or 0,trace.omittedEdges or 0
            header.probes=trace.probes or 0
            header.scan_capped=#(result[8] or {})>=TerraLogicFieldAnalysis.DYNAMIC_FIELD_MAX_CELLS
            self:write(header)
            self.output,self.phase=1,"cells"
        end
    else
        for _=1,self.ROWS_PER_UPDATE do
            if self.phase=="cached" then
                local cell=record.cells[self.output]
                if not cell then
                    self.trace={maxEdges=self.MAX_EDGES}
                    self.geometry=TerraLogicFieldAnalysis.createDynamicFieldJob(record.x,record.z,
                        {diagnostics=self.trace,allowed=function(x,z) return owned(x,z,record.owner) end})
                    self.phase="scan";break
                end
                local value=row("cached_cell")
                value.ix,value.iz=cell.ix,cell.iz
                self:write(value)
            elseif self.phase=="cells" then
                local cell=(self.geometry.result[8] or {})[self.output]
                if not cell then self.phase,self.output="edges",1;break end
                local value=row("recheck_cell")
                value.x_m,value.z_m,value.ix,value.iz,value.fraction=cell.x,cell.z,cell.ix,cell.iz,cell.fraction
                self:write(value)
            else
                local edge=(self.trace.edges or {})[self.output]
                if not edge then
                    self.geometry,self.trace=nil,nil
                    self.index,self.phase=self.index+1,"start";break
                end
                local value=row("connection")
                value.x_m,value.z_m,value.to_x_m,value.to_z_m=edge.fromX,edge.fromZ,edge.toX,edge.toZ
                value.blocked_x_m,value.blocked_z_m=edge.blockedX,edge.blockedZ
                value.connected,value.resolved_x_m,value.resolved_z_m=edge.connected,edge.resolvedX,edge.resolvedZ
                self:write(value)
            end
            self.output=self.output+1
        end
    end
end

function D:update()
    if not self.records then return end
    local ok,message=pcall(self.step,self)
    if not ok then
        local path=self.path
        self:reset()
        Logging.warning("[FS25_TerraLogic] Field diagnostics failed (CSV incomplete: %s): %s",tostring(path),tostring(message))
    end
end
