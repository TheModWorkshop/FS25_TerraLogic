-- Explicit, temporary PF harvest diagnostics. No yield/map values are changed.
-- PF instance wrappers exist only while armed; ordinary gameplay does not log.
TerraLogicPFHarvestTrace = {}
local Trace = TerraLogicPFHarvestTrace
local unpackValues = unpack or table.unpack

local function pack(...) return {n=select("#", ...), ...} end
local function now() return g_currentMission ~= nil and g_currentMission.time or 0 end

local function describe(value, depth)
    local kind = type(value)
    if kind == "number" then return string.format("%.9g", value) end
    if kind == "string" then return string.sub(value, 1, 180) end
    if kind ~= "table" or depth == 0 then return tostring(value) end
    local keys = {}
    for key, child in pairs(value) do
        if (type(key) == "string" or type(key) == "number")
            and type(child) ~= "function" then keys[#keys+1] = key end
    end
    table.sort(keys, function(a,b) return tostring(a) < tostring(b) end)
    local parts = {}
    for i=1,math.min(#keys, 12) do
        local key = keys[i]
        parts[#parts+1] = tostring(key) .. "=" .. describe(value[key], depth-1)
    end
    if #keys > 12 then parts[#parts+1] = "..." end
    return string.sub("{" .. table.concat(parts, ",") .. "}", 1, 900)
end

local function arguments(values)
    local parts = {}
    for i=1,math.min(values.n, 16) do
        parts[#parts+1] = tostring(i) .. ":" .. describe(values[i], 2)
    end
    return "argc=" .. tostring(values.n) .. " " .. table.concat(parts, " | ")
end

function Trace:row(label, text)
    local frame = self.frame
    if frame == nil or frame.time ~= now() then return end
    if #frame.rows < 60 then
        frame.rows[#frame.rows+1] = label .. " | " .. tostring(text)
    else frame.truncated = true end
end

function Trace:flush()
    local frame = self.frame
    self.frame = nil
    if frame == nil or not frame.harvested then return end
    self.samples = self.samples + 1
    self.lastSampleTime = frame.time
    Logging.info("[FS25_TerraLogic] PF-YIELD sample=%d time=%s cutter=%s",
        self.samples, tostring(frame.time), tostring(frame.cutter.configFileName))
    for i, line in ipairs(frame.rows) do
        Logging.info("[FS25_TerraLogic] PF-YIELD %d.%02d %s", self.samples, i, line)
    end
    if frame.truncated then
        Logging.info("[FS25_TerraLogic] PF-YIELD sample truncated at 60 events")
    end
end

function Trace:stop(reason)
    -- Disarm before restoring wrappers, including error paths.
    if Trace.active == self then Trace.active = nil end
    for _, hook in ipairs(self.hooks or {}) do
        -- Do not overwrite another mod's subsequent wrapper. Ours becomes a
        -- transparent pass-through if retained inside another mod's chain.
        if rawget(hook.object, hook.key) == hook.wrapper then
            hook.object[hook.key] = hook.previousRaw
        end
    end
    self.hooks = {}
    self:flush()
    Logging.info("[FS25_TerraLogic] PF-YIELD STOP samples=%d reason=%s",
        self.samples, tostring(reason))
    return "TerraLogic PF yield trace stopped; details in log.txt"
end

-- Diagnostic failures must never suppress a harvest or a PF method call.
function Trace.safe(event, ...)
    local active = Trace.active
    if active == nil then return end
    local ok, err = pcall(active[event], active, ...)
    if not ok then
        active:stop("diagnostic error: " .. tostring(err))
    end
end

function Trace:observe(object, key)
    if type(object) ~= "table" or type(object[key]) ~= "function" then return end
    local original = object[key]
    local hook = {object=object, key=key, previousRaw=rawget(object, key)}
    hook.wrapper = function(receiver, ...)
        if Trace.active ~= self or self.frame == nil or self.frame.time ~= now() then
            return original(receiver, ...)
        end
        Trace.safe("observed", "PF." .. key .. ".in", pack(...))
        -- Preserve all original arguments, nils, return values and errors.
        local result = pack(original(receiver, ...))
        Trace.safe("observed", "PF." .. key .. ".out", result)
        return unpackValues(result, 1, result.n)
    end
    object[key] = hook.wrapper
    self.hooks[#self.hooks+1] = hook
end

function Trace:observed(label, values)
    self:row(label, arguments(values))
    if label == "PF.setAreaYield.in" then
        self.frame.mapCalls = (self.frame.mapCalls or 0) + 1
        if not self.stackRecorded and debug ~= nil and type(debug.traceback) == "function" then
            self.stackRecorded = true
            local ok, stack = pcall(debug.traceback, "PF setAreaYield call path", 2)
            if ok then self:row("call_path", string.sub(tostring(stack), 1, 2400)) end
        end
    end
end

function Trace:tick()
    if self.frame ~= nil and self.frame.time ~= now() then self:flush() end
    if self.samples >= 12 or now() - self.started >= 60000 then
        self:stop(self.samples >= 12 and "12 harvest samples captured" or "60 seconds elapsed")
    end
end

function Trace:stage(stage, cutter, workArea)
    self:tick()
    if Trace.active ~= self then return end
    local root = cutter.getRootVehicle ~= nil and cutter:getRootVehicle() or cutter
    if root ~= self.vehicle then return end
    if stage == "area.begin" and self.frame == nil
        and now() - self.lastSampleTime >= 1000 then
        self.frame = {time=now(), cutter=cutter, rows={}}
    end
    local frame = self.frame
    if frame == nil or frame.cutter ~= cutter then return end
    local params = cutter.spec_cutter ~= nil and cutter.spec_cutter.workAreaParameters or {}
    self:row(stage, "area=" .. describe(params.lastArea, 0)
        .. " multiplierArea=" .. describe(params.lastMultiplierArea, 0)
        .. " fruit=" .. describe(params.lastFruitType, 0)
        .. (workArea ~= nil and " workArea=" .. describe(workArea.index, 0) or ""))
    if stage == "end.beforeTL" then
        frame.harvested = (tonumber(params.lastArea) or 0) > 0
        frame.previousDebug = TerraLogicQualityManager.lastHarvestDebug
    elseif stage == "end.afterTL" then
        local detail = TerraLogicQualityManager.lastHarvestDebug
        if detail ~= nil and detail ~= frame.previousDebug then
            self:row("TL.applied", "factor=" .. describe(detail.averageFactor, 0)
                .. " baseMultiplier=" .. describe(detail.baseMultiplier, 0)
                .. " finalMultiplier=" .. describe(detail.finalMultiplier, 0)
                .. " harvestedArea=" .. describe(detail.harvestedArea, 0))
        else self:row("TL.applied", "no fresh correction") end
    end
    if stage == "end.afterOriginal" then
        for key, spec in pairs(root) do
            if type(key) == "string" and string.sub(key, 1, 5) == "spec_"
                and type(spec) == "table" and spec.lastYieldPercentage ~= nil then
                self:row("PF.live." .. key,
                    "percentage=" .. describe(spec.lastYieldPercentage, 0)
                    .. " weight=" .. describe(spec.lastYieldWeight, 0)
                    .. " potential=" .. describe(spec.lastYieldPotential, 0))
            end
        end
    end
end

function Trace.start(controller, vehicle)
    if Trace.active ~= nil then return "PF yield trace already active; use tlPFInspect yieldStop to stop" end
    if g_currentMission == nil or not g_currentMission:getIsServer() then
        return "PF yield trace needs local authoritative harvest data. Please use singleplayer for this test."
    end
    if vehicle == nil then return "Enter the combine first, then run tlPFInspect yield" end
    local map = controller ~= nil and controller.yieldMap or nil
    if type(map) ~= "table" or type(map.setAreaYield) ~= "function" then
        return "PF yield trace unavailable: yieldMap.setAreaYield was not found"
    end
    local root = vehicle.getRootVehicle ~= nil and vehicle:getRootVehicle() or vehicle
    local self = setmetatable({vehicle=root, samples=0, hooks={}, started=now(),
        lastSampleTime=-math.huge}, {__index=Trace})
    Trace.active = self
    local ok, err = pcall(function()
        self:observe(map, "setAreaYield")
        self:observe(map, "getNearestInternalYieldValueFromValue")
        self:observe(root, "setLastYieldValues")
        Logging.info("[FS25_TerraLogic] PF-YIELD START vehicle=%s legend=%s wrappers=%d; raw PF arguments, not assumed units",
            tostring(root.configFileName), tostring(map.minimapGradientLabelName), #self.hooks)
        -- Decode the map's actual installed legend, without guessing its scale.
        for key, value in pairs(map.yieldValues or {}) do
            Logging.info("[FS25_TerraLogic] PF-YIELD legend[%s]=%s", tostring(key), describe(value, 1))
        end
    end)
    if not ok then return self:stop("setup error: " .. tostring(err)) end
    return "PF yield trace armed for 60 seconds / 12 harvest samples. Harvest straight ahead; tlPFInspect yieldStop ends it."
end
