-- PF keeps its own map, legend and replication. Only the value supplied to
-- its void setAreaYield method is adjusted, after TL's one harvest correction.
TerraLogicPFYieldBridge = {}
local Bridge = TerraLogicPFYieldBridge
local function now() return g_currentMission ~= nil and g_currentMission.time or 0 end

function Bridge:flush(factor)
    local batch = self.batch
    self.batch = nil
    if batch == nil then return end
    factor = tonumber(factor) or 1
    if factor ~= factor or factor < 0.599999 or factor > 1.100001 then factor = 1 end
    factor = math.max(0.60, math.min(1.10, factor))
    for _, entry in ipairs(batch.entries) do
        local a = entry.args
        -- Exactly one native map write. Never feed this value back into liters.
        entry.original(entry.map, a[1], a[2], a[3], a[4], a[5], a[6], a[7]*factor)
    end
end

function Bridge:tick()
    if self.batch ~= nil and self.batch.time ~= now() then self:flush(1) end
end

function Bridge:install(map)
    if self.map == map then return end
    self:delete()
    if type(map) ~= "table" or type(map.setAreaYield) ~= "function" then return end
    self.map, self.previousRaw = map, rawget(map, "setAreaYield")
    local original = map.setAreaYield
    self.wrapper = function(receiver, ...)
        local batch = self.batch
        if receiver ~= map or batch == nil or batch.time ~= now()
            or select("#", ...) ~= 7 or #batch.entries >= 64 then
            return original(receiver, ...)
        end
        local a = {...}
        for i=1,7 do
            if type(a[i]) ~= "number" or a[i] ~= a[i] then return original(receiver, ...) end
        end
        -- Reject unrelated map writes: PF's three world-space corners must
        -- belong to a work area of this cutter in this very simulation frame.
        local matches = false
        for _, g in ipairs(batch.geometry) do
            local inside = true
            for i=1,5,2 do
                if a[i] < g.minX-1 or a[i] > g.maxX+1
                    or a[i+1] < g.minZ-1 or a[i+1] > g.maxZ+1 then inside = false; break end
            end
            if inside then matches = true; break end
        end
        if not matches then return original(receiver, ...) end
        batch.entries[#batch.entries+1] = {original=original,map=receiver,args=a}
        -- This PF method returns no values (verified with installed PF 1.5.1).
    end
    map.setAreaYield = self.wrapper
end

function Bridge:begin(cutter, geometry)
    if g_currentMission == nil or not g_currentMission:getIsServer() then return end
    local pf = FS25_precisionFarming ~= nil and FS25_precisionFarming.g_precisionFarming or nil
    self:install(pf ~= nil and pf.yieldMap or nil)
    if self.map == nil then return end
    if self.batch ~= nil and (self.batch.cutter ~= cutter or self.batch.time ~= now()) then
        self:flush(1)
    end
    if geometry == nil then return end
    self.batch = self.batch or {cutter=cutter,time=now(),entries={},geometry={}}
    if #self.batch.geometry < 64 then self.batch.geometry[#self.batch.geometry+1] = geometry end
end

function Bridge:complete(cutter, before, after)
    if self.batch == nil or self.batch.cutter ~= cutter then return end
    local factor = self.batch.time == now() and (tonumber(before) or 0) > 0
        and (tonumber(after) or before)/before or 1
    self:flush(factor)
end

function Bridge:delete()
    self:flush(1)
    if self.map ~= nil and rawget(self.map, "setAreaYield") == self.wrapper then
        self.map.setAreaYield = self.previousRaw
    end
    self.map, self.wrapper, self.previousRaw = nil, nil, nil
end
