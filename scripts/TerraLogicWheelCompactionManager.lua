-- TerraLogic wheel-load and axle-load soil compaction.
--
-- GIANTS already solves the difficult mass distribution problem. Each
-- WheelPhysics:getTireLoad() is the instantaneous supported mass in tonnes,
-- including fill, wheel weights, mounted implements and dynamic load transfer.
-- TerraLogic converts that load into contact pressure and axle-load effects.

TerraLogicWheelCompactionManager = {
    UPDATE_INTERVAL_MS = 250,
    MIN_SPEED_KMH = 0.25,
    MIN_WHEEL_LOAD_T = 0.10,
    AXLE_GROUP_DISTANCE_M = 0.65,
    CRAWLER_PAIR_MIN_DISTANCE_M = 0.20,
    CRAWLER_PAIR_MAX_DISTANCE_M = 4.50,
    CRAWLER_PAIR_LATERAL_TOLERANCE_M = 0.75,
    STRUCTURE_CELL_SIZE_M = 2,
    DEEP_CELL_SIZE_M = 2,
    -- The deep layer represents the worked subsoil around 35 cm.  A simple
    -- 2:1 load-spread approximation expands the loaded tyre width by roughly
    -- one reference depth at that horizon.  This width is used only for the
    -- fraction of a two-metre storage cell that was stressed; axle load still
    -- owns the target and strength of the local compaction response.
    DEEP_REFERENCE_DEPTH_M = 0.35,
    DEEP_WIDTH_SPREAD_PER_DEPTH = 1.00,
    SLIP_REPEAT_MS = 1400,
    -- Never bridge wheel samples across a pause, teleport or network catch-up.
    -- Twelve metres still covers a 250 ms sample at any normal farm-vehicle
    -- speed, while rejecting the long straight rays produced by discontinuous
    -- positions. A long time gap is reset independently of distance.
    MAX_CONTINUOUS_SAMPLE_DISTANCE_M = 12,
    MAX_CONTINUOUS_SAMPLE_INTERVAL_MS = 1500,
    updateAccumulator = 0,
    vehicleStates = nil,
    diagnostics = nil
}

local function clamp(value, minimum, maximum)
    return math.max(minimum, math.min(tonumber(value) or 0, maximum))
end

local function clamp01(value)
    return clamp(value, 0, 1)
end

local function smoothstep(edge0, edge1, value)
    if edge1 <= edge0 then return value >= edge1 and 1 or 0 end
    local t = clamp01((value - edge0) / (edge1 - edge0))
    return t * t * (3 - 2 * t)
end

local function getVehicleNode(vehicle)
    if vehicle == nil then return nil end
    return vehicle.rootNode or (vehicle.components ~= nil
        and vehicle.components[1] ~= nil and vehicle.components[1].node) or nil
end

local function getVehicleSpeed(vehicle)
    if vehicle == nil or vehicle.getLastSpeed == nil then return 0 end
    local ok, speed = pcall(vehicle.getLastSpeed, vehicle, true)
    return ok and math.abs(tonumber(speed) or 0) or 0
end

local function getVehicles()
    local mission = g_currentMission
    if mission == nil then return {} end
    if mission.vehicleSystem ~= nil and mission.vehicleSystem.vehicles ~= nil then
        return mission.vehicleSystem.vehicles
    end
    return mission.vehicles or {}
end

local function getTireTypeName(physics)
    if physics == nil or WheelsUtil == nil
        or WheelsUtil.getTireTypeName == nil then return "unknown" end
    local ok, name = pcall(WheelsUtil.getTireTypeName, physics.tireType)
    return ok and string.lower(tostring(name or "unknown")) or "unknown"
end

local function isCrawlerWheel(wheel)
    return string.find(getTireTypeName(wheel.physics), "crawler", 1, true)
        ~= nil
end

local function getTireLoad(wheel)
    local physics = wheel ~= nil and wheel.physics or nil
    if physics == nil or physics.getTireLoad == nil then return 0 end
    local ok, load = pcall(physics.getTireLoad, physics)
    if not ok then return 0 end
    return math.max(0, tonumber(load) or 0)
end

local function getContactPoint(wheel)
    local physics = wheel ~= nil and wheel.physics or nil
    local node = wheel ~= nil and wheel.node or nil
    local shape = physics ~= nil and physics.wheelShape or nil
    if node == nil or shape == nil or getWheelShapeContactPoint == nil then
        return nil
    end
    local ok, x, y, z = pcall(getWheelShapeContactPoint, node, shape)
    if not ok or x == nil then return nil end
    -- Use the same synchronized local wheel position that Vanilla uses for
    -- visuals and tire tracks. The contact-point return value is deliberately
    -- used only as a ground-contact test because its coordinate convention is
    -- not documented consistently between engine generations.
    local netInfo = physics.netInfo
    if netInfo ~= nil and netInfo.x ~= nil and netInfo.z ~= nil then
        return localToWorld(node, netInfo.x, netInfo.y or 0, netInfo.z)
    end
    local positionNode = wheel.driveNode or wheel.repr
    if positionNode ~= nil then return getWorldTranslation(positionNode) end
    return nil
end

local function getRawSlip(wheel)
    local physics = wheel ~= nil and wheel.physics or nil
    return clamp01(physics ~= nil and physics.netInfo ~= nil
        and physics.netInfo.slip or 0)
end

local function getWheelRuntimeIdentity(wheel, wheelIndex)
    local reprName = "wheel"
    if wheel ~= nil and wheel.repr ~= nil and getName ~= nil then
        local ok, value = pcall(getName, wheel.repr)
        if ok and value ~= nil and value ~= "" then
            reprName = tostring(value)
        end
    end
    local xmlObject = wheel ~= nil and wheel.xmlObject or nil
    local externalFilename = xmlObject ~= nil
        and tostring(xmlObject.externalFilename or "") or ""
    local physics = wheel ~= nil and wheel.physics or {}
    return {
        index=tonumber(wheelIndex) or 0,
        reprName=reprName,
        externalFilename=externalFilename,
        visualCount=wheel ~= nil and #(wheel.visualWheels or {}) or 0,
        restLoadT=tonumber(physics.restLoad) or 0,
        supportsWheelSink=physics.supportsWheelSink == true
    }
end

-- GIANTS compares wheel circumference speed with the vehicle centre speed.
-- That over-reports the faster outside wheel in a turn. Confirm its value
-- against the distance travelled by this individual contact point; taking the
-- lower result preserves real wheel spin but rejects ordinary cornering.
local function getCorrectedSlip(wheel, wheelState, x, z, now)
    local rawSlip = getRawSlip(wheel)
    if wheelState == nil or wheelState.x == nil or wheelState.z == nil
        or wheelState.sampleTime == nil then return 0, rawSlip end
    local elapsedSeconds = math.max(
        ((tonumber(now) or 0) - wheelState.sampleTime) * 0.001, 0)
    if elapsedSeconds < 0.02 then return 0, rawSlip end
    local dx, dz = x - wheelState.x, z - wheelState.z
    local contactSpeed = math.sqrt(dx * dx + dz * dz) / elapsedSeconds
    local physics = wheel ~= nil and wheel.physics or nil
    local wheelSpeed = math.abs(tonumber(physics ~= nil
        and physics.netInfo ~= nil and physics.netInfo.lastSpeedSmoothed) or 0)
    local kinematicSlip = clamp01(
        wheelSpeed / math.max(contactSpeed, 0.05) - 1)
    return math.min(rawSlip, kinematicSlip), rawSlip
end

local function resetDiscontinuousWheelSample(
        wheelState, x, z, now, speedKph)
    if wheelState == nil or wheelState.x == nil or wheelState.z == nil
        or wheelState.sampleTime == nil then return false end
    local elapsedMs = math.max(
        (tonumber(now) or 0) - (tonumber(wheelState.sampleTime) or 0), 0)
    local dx, dz = x-wheelState.x, z-wheelState.z
    local distance = math.sqrt(dx*dx + dz*dz)
    local elapsedSeconds = elapsedMs*0.001
    local expectedDistance = math.max(tonumber(speedKph) or 0, 0)
        / 3.6 * elapsedSeconds
    local allowedDistance = math.min(math.max(
        expectedDistance*2.5 + 2, 4),
        TerraLogicWheelCompactionManager.MAX_CONTINUOUS_SAMPLE_DISTANCE_M)
    local maximumInterval =
        TerraLogicWheelCompactionManager.MAX_CONTINUOUS_SAMPLE_INTERVAL_MS
    if elapsedMs <= maximumInterval
        and distance <= allowedDistance then return false end
    wheelState.surfaceCellKey = nil
    wheelState.structureCellKey = nil
    wheelState.deepCellKey = nil
    wheelState.x, wheelState.z, wheelState.sampleTime = nil, nil, nil
    return true
end

local function getIsOnField(wheel)
    local physics = wheel ~= nil and wheel.physics or nil
    if physics == nil or physics.getIsOnField == nil then return false end
    local ok, result = pcall(physics.getIsOnField, physics)
    return ok and result == true
end

local function getRubberWidth(wheel)
    local width = 0
    local count = 0
    for _, visualWheel in ipairs(wheel.visualWheels or {}) do
        if visualWheel.getWidthAndOffset ~= nil then
            local ok, visualWidth = pcall(
                visualWheel.getWidthAndOffset, visualWheel)
            if ok and tonumber(visualWidth) ~= nil and visualWidth > 0 then
                width = width + visualWidth
                count = count + 1
            end
        end
    end
    local physics = wheel.physics or {}
    if width <= 0 then
        width = tonumber(physics.width)
            or tonumber(physics.wheelShapeWidth) or 0.45
        count = 1
    end
    return math.max(width, 0.12), math.max(count, 1)
end

local function getFootprint(wheel, loadT)
    local physics = wheel.physics or {}
    local width, tireCount = getRubberWidth(wheel)
    local radius = math.max(tonumber(physics.radius) or 0.65, 0.18)
    local diameter = radius * 2
    local crawler = isCrawlerWheel(wheel)

    -- A flexible agricultural tire lengthens its footprint as load rises.
    -- Width and diameter therefore both matter, while duals contribute their
    -- actual combined rubber width rather than the empty gap between tires.
    local referenceLoad = math.max(3.0 * width * diameter, 0.35)
    local loadRatio = clamp(loadT / referenceLoad, 0.25, 2.5)
    local lengthFactor = crawler and 0.72 or 0.34
    local contactLength = diameter * lengthFactor * loadRatio ^ 0.22
    contactLength = clamp(contactLength,
        diameter * (crawler and 0.48 or 0.22),
        diameter * (crawler and 1.05 or 0.48))
    local efficiency = tireCount > 1 and 0.92 or 1
    local area = math.max(width * contactLength * efficiency, 0.035)
    local pressureKPa = loadT * 9.81 / area
    return pressureKPa, width, contactLength, tireCount, crawler, diameter
end

-- Steering changes the tire contact point even though the physical axle has
-- not moved inside the vehicle.  Axle grouping must therefore use the stable
-- wheel carrier position, never the current ground-contact position.  The
-- fallback keeps unusual third-party wheel implementations supported.
local function getStableWheelLocalPosition(rootNode, wheel, fallbackX,
        fallbackY, fallbackZ)
    local node = wheel ~= nil
        and (wheel.driveNode or wheel.repr or wheel.node) or nil
    local x, y, z = fallbackX, fallbackY, fallbackZ
    if node ~= nil and getWorldTranslation ~= nil then
        local ok, nodeX, nodeY, nodeZ = pcall(getWorldTranslation, node)
        if ok and nodeX ~= nil then x, y, z = nodeX, nodeY, nodeZ end
    end
    if rootNode == nil or x == nil or worldToLocal == nil then return 0, 0 end
    local ok, localX, localY, localZ = pcall(
        worldToLocal, rootNode, x, y or 0, z or 0)
    if not ok then return 0, 0 end
    return tonumber(localX) or 0, tonumber(localZ) or 0
end

-- GIANTS represents one rubber belt with two crawler wheel contacts.  Those
-- contacts carry the correct instantaneous load but must not be interpreted
-- as two independent tyres crossing the same strip. Pair contacts by stable
-- vehicle-local geometry so steering and world rotation cannot change the
-- detected undercarriage. Unusual/odd mod configurations stay unpaired and
-- retain the proven per-contact fallback.
local function buildCrawlerModules(observations)
    local crawlerObservations = {}
    for _, observation in ipairs(observations or {}) do
        if observation.crawler == true then
            crawlerObservations[#crawlerObservations + 1] = observation
        end
    end
    table.sort(crawlerObservations, function(a, b)
        local ax, bx = tonumber(a.localX) or 0, tonumber(b.localX) or 0
        if math.abs(ax - bx) > 0.001 then return ax < bx end
        return (tonumber(a.axleLocalZ) or 0)
            < (tonumber(b.axleLocalZ) or 0)
    end)

    local used, modules = {}, {}
    local manager = TerraLogicWheelCompactionManager
    for index, first in ipairs(crawlerObservations) do
        if not used[first] then
            local best, bestScore = nil, math.huge
            for candidateIndex=index+1,#crawlerObservations do
                local second = crawlerObservations[candidateIndex]
                if not used[second] then
                    local firstX = tonumber(first.localX) or 0
                    local secondX = tonumber(second.localX) or 0
                    local lateralDistance = math.abs(firstX-secondX)
                    local longitudinalDistance = math.abs(
                        (tonumber(first.axleLocalZ) or 0)
                            - (tonumber(second.axleLocalZ) or 0))
                    local sameSide = firstX == 0 or secondX == 0
                        or firstX * secondX > 0
                    local lateralTolerance = math.max(
                        manager.CRAWLER_PAIR_LATERAL_TOLERANCE_M,
                        math.max(tonumber(first.width) or 0,
                            tonumber(second.width) or 0) * 0.75)
                    if sameSide
                        and lateralDistance <= lateralTolerance
                        and longitudinalDistance
                            >= manager.CRAWLER_PAIR_MIN_DISTANCE_M
                        and longitudinalDistance
                            <= manager.CRAWLER_PAIR_MAX_DISTANCE_M then
                        local score = longitudinalDistance
                            + lateralDistance * 4
                        if score < bestScore then
                            best, bestScore = second, score
                        end
                    end
                end
            end
            if best ~= nil then
                used[first], used[best] = true, true
                local firstId = tonumber(first.identity
                    and first.identity.index) or index
                local secondId = tonumber(best.identity
                    and best.identity.index) or (index+1)
                local lowId, highId = math.min(firstId, secondId),
                    math.max(firstId, secondId)
                local dx = (tonumber(first.localX) or 0)
                    - (tonumber(best.localX) or 0)
                local dz = (tonumber(first.axleLocalZ) or 0)
                    - (tonumber(best.axleLocalZ) or 0)
                local contactSpacing = math.sqrt(dx*dx + dz*dz)
                -- The two crawler shapes sit at the ends of the flat lower
                -- belt run. Their stable centre distance therefore describes
                -- the supported ground length; adding two tyre-like contact
                -- patches would count the curved, lifted belt ends as soil
                -- contact and make tracks unrealistically pressure-free.
                local fallbackLength = 0.5
                    * ((tonumber(first.contactLength) or 0)
                        + (tonumber(best.contactLength) or 0))
                local length = math.max(contactSpacing, fallbackLength, 0.35)
                local width = math.max(tonumber(first.width) or 0.12,
                    tonumber(best.width) or 0.12)
                local loadT = math.max(tonumber(first.loadT) or 0, 0)
                    + math.max(tonumber(best.loadT) or 0, 0)
                local area = math.max(width * length, 0.035)
                local module = {
                    key="crawler:" .. tostring(lowId) .. ":" .. tostring(highId),
                    first=first, second=best, members={first, best},
                    crawler=true, loadT=loadT, width=width,
                    contactLength=length, contactSpacing=contactSpacing,
                    area=area, pressure=loadT * 9.81 / area,
                    diameter=((tonumber(first.diameter) or 0)
                        + (tonumber(best.diameter) or 0)) * 0.5,
                    tireCount=1,
                    x=((tonumber(first.x) or 0)+(tonumber(best.x) or 0))*0.5,
                    z=((tonumber(first.z) or 0)+(tonumber(best.z) or 0))*0.5,
                    localX=((tonumber(first.localX) or 0)
                        +(tonumber(best.localX) or 0))*0.5,
                    axleLocalZ=((tonumber(first.axleLocalZ) or 0)
                        +(tonumber(best.axleLocalZ) or 0))*0.5,
                    fieldConfirmed=first.fieldConfirmed == true
                        or best.fieldConfirmed == true,
                    identity=first.identity
                }
                modules[#modules + 1] = module
            end
        end
    end
    return modules, used
end

-- Cluster stable longitudinal wheel positions instead of quantizing them
-- against an arbitrary grid origin.  Two wheels on one axle can sit on
-- opposite sides of a rounding boundary; nearest-position clustering keeps
-- them together while preserving genuinely separate tandem axles.
local function buildAxleGroups(samples)
    local ordered = {}
    for _, sample in ipairs(samples or {}) do ordered[#ordered + 1] = sample end
    table.sort(ordered, function(a, b)
        return (tonumber(a.axleLocalZ) or 0)
            < (tonumber(b.axleLocalZ) or 0)
    end)
    local groups = {}
    for _, sample in ipairs(ordered) do
        local localZ = tonumber(sample.axleLocalZ) or 0
        local bestIndex, bestDistance = nil, math.huge
        for index, group in ipairs(groups) do
            local distance = math.abs(localZ - group.localZ)
            if distance <= TerraLogicWheelCompactionManager.AXLE_GROUP_DISTANCE_M
                and distance < bestDistance then
                bestIndex, bestDistance = index, distance
            end
        end
        if bestIndex == nil then
            bestIndex = #groups + 1
            groups[bestIndex] = {
                loadT=0, crawler=false, fieldConfirmed=false,
                localZ=localZ, sampleCount=0, minLocalZ=localZ,
                maxLocalZ=localZ
            }
        end
        local group = groups[bestIndex]
        group.loadT = group.loadT + math.max(tonumber(sample.loadT) or 0, 0)
        group.crawler = group.crawler or sample.crawler == true
        group.fieldConfirmed = group.fieldConfirmed == true
            or sample.fieldConfirmed == true
        group.sampleCount = group.sampleCount + 1
        group.localZ = group.localZ
            + (localZ - group.localZ) / group.sampleCount
        group.minLocalZ = math.min(group.minLocalZ, localZ)
        group.maxLocalZ = math.max(group.maxLocalZ, localZ)
        sample.axleKey = bestIndex
    end
    return groups
end

local function getSurfaceImpact(pressureKPa, slip)
    -- The footprint calculation returns mean contact pressure. Measured peak
    -- topsoil stress is higher (and rises with wheel load), so use a modest
    -- 1.30 peak-stress conversion before mapping it to the persistent soil
    -- scale. This is not tyre inflation pressure and does not invent a second
    -- wheel-load model; it closes the known gap between mean footprint load
    -- and the local stress that creates a visible wheel track.
    pressureKPa = math.max(tonumber(pressureKPa) or 0, 0)
    local effectivePeakKPa = pressureKPa * 1.30
    local compactionDriver = smoothstep(0, 200, effectivePeakKPa)
    -- Preserve the established seedbed rolling driver. Raising compaction
    -- targets must not silently rebalance Tilth or Evenness under ordinary
    -- tyres; those effects continue to use the former 50..300 kPa range.
    local pressureDriver = smoothstep(50, 300, pressureKPa)
    local slipSeverity = smoothstep(0.08, 0.22, slip) ^ 1.35
    if compactionDriver <= 0 and slipSeverity <= 0 then
        return nil, nil, slipSeverity, pressureDriver, false
    end
    -- Higher equilibria make severe surface compaction reachable with real
    -- game vehicles instead of an artificial 46 t stress test. The geometric
    -- move-to-target response still gives the largest change on the first
    -- passes and progressively smaller changes afterwards.
    local target = 0.34 + 0.54 * compactionDriver
        + 0.06 * slipSeverity
    local strength = 0.34 + 0.18 * compactionDriver
        + 0.08 * slipSeverity
    -- Very light contacts remain predominantly elastic. There is deliberately
    -- no hard 50 kPa threshold, but their first-pass impulse is reduced while
    -- retaining sub-raster accumulation over repeated traffic.
    local lowPressureResponse = pressureKPa < 50
    if lowPressureResponse and slipSeverity <= 0 then
        local responseAt50 = smoothstep(0, 200, 50 * 1.30)
        strength = strength * math.max(
            compactionDriver / math.max(responseAt50, 0.0001), 0.04)
    end
    return clamp01(target), clamp01(strength), slipSeverity, pressureDriver,
        lowPressureResponse
end

local function getDeepImpact(axleLoadT)
    -- Subsoil stress has no physical step at 5 t. Wheel/axle load studies use
    -- that region as a risk limit, not as a zero-effect boundary. A quadratic
    -- load term keeps compact tractors useful while allowing repeated light
    -- passes to accumulate very slowly. The target describes the eventual
    -- equilibrium under repeated traffic; strength is deliberately much
    -- lower because every physical axle of a vehicle train crosses the same
    -- soil. The old 0.42 peak strength was calibrated while left/right wheels
    -- were accidentally treated as separate axles. With correctly combined
    -- axle loads it could remove roughly 10-18 quality points in one ordinary
    -- drilling pass.
    local loadRatio = clamp((tonumber(axleLoadT) or 0) / 12, 0, 1.25)
    if loadRatio <= 0 then return nil, nil end
    local target = 0.25 + 0.16 * loadRatio
        + 0.55 * loadRatio ^ 1.70
    local strength = 0.008 + 0.15 * loadRatio ^ 1.50
    return clamp01(target), clamp01(strength)
end

local function getCell(x, z, size)
    size = tonumber(size) or TerraLogicSoilManager.WHEEL_CELL_SIZE or 1
    local ix = math.floor(x / size)
    local iz = math.floor(z / size)
    return ix, iz, tostring(ix) .. ":" .. tostring(iz)
end

local function mergeImpact(impacts, ix, iz, cellSize, discriminator)
    local key = tostring(cellSize) .. ":" .. tostring(ix) .. ":" .. tostring(iz)
    if discriminator ~= nil then
        key = key .. ":" .. tostring(discriminator)
    end
    local impact = impacts[key]
    if impact == nil then
        impact = {ix=ix, iz=iz, cellSize=cellSize, slipSeverity=0}
        impacts[key] = impact
    end
    return impact
end

local function getDeepStressWidth(width)
    local rubberWidth = math.max(tonumber(width) or 0.12, 0.12)
    local manager = TerraLogicWheelCompactionManager
    local spread = manager.DEEP_REFERENCE_DEPTH_M
        * manager.DEEP_WIDTH_SPREAD_PER_DEPTH
    return clamp(rubberWidth + spread, rubberWidth,
        manager.DEEP_CELL_SIZE_M)
end

-- A diagonal line crosses more raster cells per travelled metre. Dividing by
-- the cell's projected lateral width makes the accumulated stressed area
-- independent of field/grid orientation. Each physical wheel keeps its own
-- cell-entry state; both sides still use their combined physical axle load.
local function getDeepProjectedCellWidth(lateralX, lateralZ)
    local cellSize = TerraLogicWheelCompactionManager.DEEP_CELL_SIZE_M
    local projectedWidth = cellSize
        * (math.abs(lateralX) + math.abs(lateralZ))
    return math.max(projectedWidth, 0.0001)
end

local function getProjectedCellWidth(cellSize, lateralX, lateralZ)
    local projectedWidth = math.max(tonumber(cellSize) or 1, 0.01)
        * (math.abs(tonumber(lateralX) or 0)
            + math.abs(tonumber(lateralZ) or 0))
    return math.max(projectedWidth, 0.0001)
end

local function getSegmentCells(fromX, fromZ, toX, toZ, cellSize)
    local result, seen = {}, {}
    local dx, dz = (toX or 0) - (fromX or toX or 0),
        (toZ or 0) - (fromZ or toZ or 0)
    local distance = math.sqrt(dx * dx + dz * dz)
    local steps = math.max(1, math.ceil(distance / (cellSize * 0.5)))
    local firstStep = fromX ~= nil and fromZ ~= nil
        and distance > 0.0001 and 1 or 0
    for index=firstStep,steps do
        local t = index / steps
        local x = (fromX or toX) + dx * t
        local z = (fromZ or toZ) + dz * t
        local ix, iz, key = getCell(x, z, cellSize)
        if not seen[key] then
            seen[key] = true
            result[#result + 1] = {ix=ix, iz=iz, key=key}
        end
    end
    return result
end

-- Exact grid traversal for deep stress strips. The general contact sampler
-- above intentionally oversamples short surface movements; doing that for an
-- area-normalized deep band would count the starting cell twice and miss
-- briefly crossed diagonal cells. This DDA returns only cells newly entered
-- after the previous contact point. A first observation still initializes
-- the cell underneath the wheel.
local function getDeepSegmentCells(fromX, fromZ, toX, toZ, cellSize)
    local endIx, endIz, endKey = getCell(toX, toZ, cellSize)
    if fromX == nil or fromZ == nil then
        return {{ix=endIx, iz=endIz, key=endKey}}
    end
    local ix, iz = getCell(fromX, fromZ, cellSize)
    if ix == endIx and iz == endIz then return {} end
    local dx, dz = toX - fromX, toZ - fromZ
    local stepX = dx > 0 and 1 or (dx < 0 and -1 or 0)
    local stepZ = dz > 0 and 1 or (dz < 0 and -1 or 0)
    local deltaX = stepX ~= 0 and cellSize / math.abs(dx) or math.huge
    local deltaZ = stepZ ~= 0 and cellSize / math.abs(dz) or math.huge
    local boundaryX = stepX > 0 and (ix + 1) * cellSize or ix * cellSize
    local boundaryZ = stepZ > 0 and (iz + 1) * cellSize or iz * cellSize
    local nextX = stepX ~= 0 and (boundaryX - fromX) / dx or math.huge
    local nextZ = stepZ ~= 0 and (boundaryZ - fromZ) / dz or math.huge
    local result, guard = {}, 0
    while (ix ~= endIx or iz ~= endIz) and guard < 4096 do
        guard = guard + 1
        if nextX < nextZ then
            ix = ix + stepX
            nextX = nextX + deltaX
        elseif nextZ < nextX then
            iz = iz + stepZ
            nextZ = nextZ + deltaZ
        else
            -- A mathematical corner has zero area in both side-neighbouring
            -- cells; enter the diagonal cell once instead of triple-counting.
            ix, iz = ix + stepX, iz + stepZ
            nextX, nextZ = nextX + deltaX, nextZ + deltaZ
        end
        result[#result + 1] = {
            ix=ix, iz=iz, key=tostring(ix) .. ":" .. tostring(iz)
        }
    end
    return result
end

-- Rasterizes the laterally spreading subsoil stress band as narrow parallel
-- strips. Each strip contributes only its share of the projected 2 m cell
-- width. Contributions are accumulated and capped at one, so crossing a cell
-- diagonally or sampling the same axle through two wheels can never multiply
-- the full-cell strength. The weighted cell areas equal the swept stress-band
-- area to within the finite strip sampling error.
local function getDeepBandCells(
        fromX, fromZ, toX, toZ, effectiveWidth, lateralX, lateralZ)
    local width = math.max(tonumber(effectiveWidth) or 0, 0)
    if width <= 0 then return {} end
    local cellSize = TerraLogicWheelCompactionManager.DEEP_CELL_SIZE_M
    local stripCount = math.max(1, math.min(
        math.ceil(width / 0.25), 8))
    local stripWidth = width / stripCount
    local contribution = stripWidth
        / getDeepProjectedCellWidth(lateralX, lateralZ)
    local cellsByKey = {}
    for strip=1,stripCount do
        local offset = ((strip - 0.5) / stripCount - 0.5) * width
        local offsetX, offsetZ = lateralX * offset, lateralZ * offset
        for _, cell in ipairs(getDeepSegmentCells(
                fromX ~= nil and fromX + offsetX or nil,
                fromZ ~= nil and fromZ + offsetZ or nil,
                toX + offsetX, toZ + offsetZ, cellSize)) do
            local entry = cellsByKey[cell.key]
            if entry == nil then
                entry = {ix=cell.ix, iz=cell.iz, coverage=0}
                cellsByKey[cell.key] = entry
            end
            entry.coverage = clamp01(entry.coverage + contribution)
        end
    end
    local result = {}
    for _, cell in pairs(cellsByKey) do
        result[#result + 1] = cell
    end
    return result
end

-- Surface compaction uses the same area-conserving strip rasterization as the
-- structural layer, but at the one-metre topsoil resolution and with the
-- actual rubber/belt width. A 0.32 m support wheel can still have a severe
-- local pressure target; it simply contributes roughly 32% of a straight
-- one-metre cell instead of treating the complete cell as wheel track.
local function getSurfaceBandCells(
        fromX, fromZ, toX, toZ, effectiveWidth, lateralX, lateralZ)
    local width = math.max(tonumber(effectiveWidth) or 0, 0)
    if width <= 0 then return {} end
    local cellSize = TerraLogicSoilManager ~= nil
        and (TerraLogicSoilManager.WHEEL_CELL_SIZE or 1) or 1
    local stripCount = math.max(2, math.min(math.ceil(width / 0.10), 24))
    if stripCount % 2 ~= 0 then stripCount = math.min(stripCount + 1, 24) end
    local stripWidth = width / stripCount
    local contribution = stripWidth
        / getProjectedCellWidth(cellSize, lateralX, lateralZ)
    local cellsByKey = {}
    for strip=1,stripCount do
        local offset = ((strip - 0.5) / stripCount - 0.5) * width
        local offsetX, offsetZ = lateralX * offset, lateralZ * offset
        for _, cell in ipairs(getDeepSegmentCells(
                fromX ~= nil and fromX + offsetX or nil,
                fromZ ~= nil and fromZ + offsetZ or nil,
                toX + offsetX, toZ + offsetZ, cellSize)) do
            local entry = cellsByKey[cell.key]
            if entry == nil then
                entry = {ix=cell.ix, iz=cell.iz, coverage=0}
                cellsByKey[cell.key] = entry
            end
            entry.coverage = clamp01(entry.coverage + contribution)
        end
    end
    local result = {}
    for _, cell in pairs(cellsByKey) do
        result[#result + 1] = cell
    end
    return result
end

local function getBooleanCall(object, functionName, ...)
    local func = object ~= nil and object[functionName] or nil
    if func == nil then return nil, false end
    local ok, value = pcall(func, object, ...)
    if not ok then return nil, false end
    return value == true, true
end

-- Capture the engine-facing work state at the same instant as the wheel load.
-- These values are diagnostic only and never decide whether soil is changed.
local function getImplementRuntimeState(vehicle, now)
    local result = {
        lowered=nil, loweredAvailable=false,
        chainLowered=nil, chainLoweredAvailable=false,
        foldAnimTime=nil, foldMoveDirection=nil,
        foldWorkPosition=nil,
        workAreaActiveCount=0, workAreaCount=0,
        workAreaQueryAvailable=false,
        groundReferenceActiveCount=0, groundReferenceCount=0,
        groundReferenceKnownCount=0,
        groundReferenceSource="unavailable",
        lastWorkAreaActive=nil, lastWorkAreaActiveAgeMs=nil,
        lastWorkAreaFunctionName="unknown",
        lastWorkAreaOnlyActiveWhenLowered=nil,
        lastCultivatorCallbackAgeMs=nil,
        lastCultivatorProcessingAgeMs=nil,
        lastCultivatorChangedAgeMs=nil,
        lastCultivatorChangedArea=0,
        lastCultivatorTotalArea=0,
        workDetectionSource="inactive"
    }

    result.lowered, result.loweredAvailable =
        getBooleanCall(vehicle, "getIsLowered")
    result.chainLowered, result.chainLoweredAvailable =
        getBooleanCall(vehicle, "getIsImplementChainLowered", true)

    if vehicle ~= nil and vehicle.getFoldAnimTime ~= nil then
        local ok, value = pcall(vehicle.getFoldAnimTime, vehicle)
        if ok then result.foldAnimTime = tonumber(value) end
    end
    local foldable = vehicle ~= nil and vehicle.spec_foldable or nil
    if foldable ~= nil then
        result.foldMoveDirection = tonumber(foldable.foldMoveDirection)
            or tonumber(foldable.foldDirection)
    end
    if TerraLogic ~= nil
        and TerraLogic.getIsOverSpeedWorkAreaInWorkPosition ~= nil then
        local ok, value = pcall(
            TerraLogic.getIsOverSpeedWorkAreaInWorkPosition, vehicle)
        if ok then result.foldWorkPosition = value == true end
    end

    local workAreaSpec = vehicle ~= nil and vehicle.spec_workArea or nil
    local workAreas = workAreaSpec ~= nil and workAreaSpec.workAreas or nil
    if workAreas ~= nil then
        result.workAreaCount = #workAreas
        if vehicle.getIsWorkAreaActive ~= nil then
            result.workAreaQueryAvailable = true
            for _, workArea in ipairs(workAreas) do
                local ok, active = pcall(
                    vehicle.getIsWorkAreaActive, vehicle, workArea)
                if ok and active == true then
                    result.workAreaActiveCount =
                        result.workAreaActiveCount + 1
                end
            end
        end
    end

    local groundSpec = vehicle ~= nil
        and vehicle.spec_groundReferenceNodes or nil
    local groundReferences = groundSpec ~= nil
        and groundSpec.groundReferenceNodes or nil
    if groundReferences ~= nil then
        result.groundReferenceCount = #groundReferences
        for _, reference in ipairs(groundReferences) do
            local known, active = false, false
            if vehicle.getIsGroundReferenceNodeActive ~= nil then
                local ok, value = pcall(
                    vehicle.getIsGroundReferenceNodeActive,
                    vehicle, reference)
                if ok then
                    known, active = true, value == true
                    result.groundReferenceSource = "engine query"
                end
            end
            if not known and type(reference) == "table" then
                if reference.isActive ~= nil then
                    known, active = true, reference.isActive == true
                    result.groundReferenceSource = "runtime isActive"
                elseif reference.active ~= nil then
                    known, active = true, reference.active == true
                    result.groundReferenceSource = "runtime active"
                end
            end
            if known then
                result.groundReferenceKnownCount =
                    result.groundReferenceKnownCount + 1
                if active then
                    result.groundReferenceActiveCount =
                        result.groundReferenceActiveCount + 1
                end
            end
        end
    end

    local spec = vehicle ~= nil and vehicle.spec_terraLogic or nil
    if spec ~= nil then
        result.workDetectionSource = tostring(
            spec.workDetectionSource or "inactive")
        result.lastWorkAreaActive = spec.lastWorkAreaActive
        result.lastWorkAreaFunctionName = tostring(
            spec.lastWorkAreaFunctionName or "unknown")
        result.lastWorkAreaOnlyActiveWhenLowered =
            spec.lastWorkAreaOnlyActiveWhenLowered
        if spec.lastWorkAreaActiveTime ~= nil then
            result.lastWorkAreaActiveAgeMs = math.max(
                now - (tonumber(spec.lastWorkAreaActiveTime) or now), 0)
        end
        if spec.lastCultivatorCallbackTime ~= nil then
            result.lastCultivatorCallbackAgeMs = math.max(
                now - (tonumber(spec.lastCultivatorCallbackTime) or now), 0)
        end
        if spec.lastCultivatorProcessingTime ~= nil then
            result.lastCultivatorProcessingAgeMs = math.max(
                now - (tonumber(spec.lastCultivatorProcessingTime) or now), 0)
        end
        if spec.lastCultivatorChangedTime ~= nil then
            result.lastCultivatorChangedAgeMs = math.max(
                now - (tonumber(spec.lastCultivatorChangedTime) or now), 0)
        end
        result.lastCultivatorChangedArea = tonumber(
            spec.lastCultivatorCallbackChangedArea) or 0
        result.lastCultivatorTotalArea = tonumber(
            spec.lastCultivatorCallbackTotalArea) or 0
    end
    return result
end

function TerraLogicWheelCompactionManager:load()
    self.updateAccumulator = 0
    self.vehicleStates = setmetatable({}, {__mode="k"})
    self.diagnostics = setmetatable({}, {__mode="k"})
    self.lastDiagnostic = nil
    self.lastDiagnosticVehicle = nil
end

function TerraLogicWheelCompactionManager:delete()
    self.vehicleStates = nil
    self.diagnostics = nil
    self.lastDiagnostic = nil
    self.lastDiagnosticVehicle = nil
end

-- Instantaneous, read-only load summary for the Field Analysis planner. This
-- uses GIANTS' solved tire loads, so mounted tools, fill and folded geometry
-- are represented without inventing a second mass-distribution model.
function TerraLogicWheelCompactionManager:getLoadPreview(vehicle)
    local wheels = vehicle ~= nil and vehicle.spec_wheels ~= nil
        and vehicle.spec_wheels.wheels or nil
    local rootNode = getVehicleNode(vehicle)
    local result = {massT=0, supportedLoadT=0, wheelCount=0, axleCount=0,
        maxWheelLoadT=0, maxAxleLoadT=0, meanPressureKPa=0,
        maxPressureKPa=0}
    if vehicle ~= nil and vehicle.getTotalMass ~= nil then
        -- AttacherJoints:getTotalMass() includes the complete child train when
        -- the optional argument is omitted. The planner sums every object in
        -- that train itself, so request this object's own mass explicitly.
        local ok, value = pcall(vehicle.getTotalMass, vehicle, true)
        if ok then result.massT = math.max(tonumber(value) or 0, 0) end
        if result.massT > 100 then result.massT = result.massT / 1000 end
    end
    if wheels == nil or rootNode == nil then return result end
    local axleSamples, footprintSamples = {}, {}
    for wheelIndex, wheel in pairs(wheels) do
        local loadT = getTireLoad(wheel)
        if loadT >= self.MIN_WHEEL_LOAD_T then
            local node = wheel.driveNode or wheel.repr or wheel.node
            local x, y, z = nil, nil, nil
            if node ~= nil then
                x, y, z = getWorldTranslation(node)
            end
            local localX, localZ = getStableWheelLocalPosition(
                rootNode, wheel, x, y, z)
            local pressure, width, contactLength, tireCount, crawler,
                diameter = getFootprint(wheel, loadT)
            local sample = {
                wheel=wheel,
                identity=getWheelRuntimeIdentity(wheel, wheelIndex),
                x=x or 0, z=z or 0, localX=localX,
                loadT=loadT, axleLocalZ=localZ,
                crawler=crawler, fieldConfirmed=false,
                pressure=pressure, width=width,
                contactLength=contactLength, tireCount=tireCount,
                diameter=diameter
            }
            axleSamples[#axleSamples + 1] = sample
            footprintSamples[#footprintSamples + 1] = sample
            result.supportedLoadT = result.supportedLoadT + loadT
            result.wheelCount = result.wheelCount + 1
            result.maxWheelLoadT = math.max(result.maxWheelLoadT, loadT)
        end
    end
    local modules, paired = buildCrawlerModules(footprintSamples)
    local effectiveFootprints = {}
    for _, sample in ipairs(footprintSamples) do
        if sample.crawler ~= true or not paired[sample] then
            effectiveFootprints[#effectiveFootprints + 1] = sample
        end
    end
    for _, module in ipairs(modules) do
        effectiveFootprints[#effectiveFootprints + 1] = module
    end
    local pressureSum = 0
    for _, footprint in ipairs(effectiveFootprints) do
        result.maxPressureKPa = math.max(result.maxPressureKPa,
            tonumber(footprint.pressure) or 0)
        pressureSum = pressureSum + (tonumber(footprint.pressure) or 0)
    end
    for _, axle in ipairs(buildAxleGroups(axleSamples)) do
        result.axleCount = result.axleCount + 1
        result.maxAxleLoadT = math.max(
            result.maxAxleLoadT, axle.loadT or 0)
    end
    result.meanPressureKPa = #effectiveFootprints > 0
        and pressureSum / #effectiveFootprints or 0
    result.crawlerModuleCount = #modules
    result.effectiveFootprintCount = #effectiveFootprints
    return result
end

function TerraLogicWheelCompactionManager:processVehicle(vehicle, now)
    local wheelSpec = vehicle ~= nil and vehicle.spec_wheels or nil
    local wheels = wheelSpec ~= nil and wheelSpec.wheels or nil
    local rootNode = getVehicleNode(vehicle)
    local speed = getVehicleSpeed(vehicle)
    if wheels == nil or rootNode == nil or speed < self.MIN_SPEED_KMH then return end

    local vehicleState = self.vehicleStates[vehicle]
    if vehicleState == nil then
        vehicleState = {
            wheels=setmetatable({}, {__mode="k"}),
            deepWheels=setmetatable({}, {__mode="k"}),
            trackModules={}, axles={}
        }
        self.vehicleStates[vehicle] = vehicleState
    end
    vehicleState.deepWheels = vehicleState.deepWheels
        or setmetatable({}, {__mode="k"})
    vehicleState.trackModules = vehicleState.trackModules or {}

    -- A soil-working implement profile already describes the net result left
    -- behind its tines/discs, gauge wheels and packer rollers. Applying its own
    -- generic topsoil wheel pass as well makes callback order decide whether a
    -- roller writes after the cultivator and creates artificial red stripes.
    -- Suppress only surface/structure traffic while the tool is genuinely in
    -- work position. Raised or folded transport retains all wheel effects;
    -- deep axle-load stress always remains active.
    local workingImplementSurfaceSuppressed = false
    local terraLogicSpec = vehicle.spec_terraLogic
    if terraLogicSpec ~= nil and terraLogicSpec.isGroundTool == true
        and vehicle.getIsOverSpeedGroundContactActive ~= nil then
        local ok, active = pcall(
            vehicle.getIsOverSpeedGroundContactActive, vehicle)
        workingImplementSurfaceSuppressed = ok and active == true
    end
    local implementRuntimeState = getImplementRuntimeState(vehicle, now)

    local observations = {}
    local axles = {}
    local totalLoad = 0
    local maxPressure = 0
    local maxSlip = 0
    local maxRawSlip = 0
    local crawlerCount = 0
    local fieldContactCount = 0
    local maxAxleLoad = 0
    local axleCount = 0
    local maxDeepTarget = 0
    local maxDeepStrength = 0
    local maximumDeepCoverage = 0
    local deepCoverageSum, deepCoverageCount = 0, 0
    local minimumWheelLoad = math.huge
    local maximumWheelLoad = 0
    local widthSum, diameterSum, contactLengthSum, pressureSum = 0, 0, 0, 0
    local physicalTireCount = 0
    local deepStressWidthSum = 0
    local firstX, firstZ = nil, nil
    local vehicleMass = 0
    if vehicle.getTotalMass ~= nil then
        local ok, value = pcall(vehicle.getTotalMass, vehicle)
        if ok then vehicleMass = math.max(tonumber(value) or 0, 0) end
    end
    -- Base-game and third-party vehicle implementations expose this value in
    -- either tonnes or kilograms. WheelPhysics loads are normalized to tonnes.
    if vehicleMass > 100 then vehicleMass = vehicleMass / 1000 end
    local lateralX, _, lateralZ = localDirectionToWorld(rootNode, 1, 0, 0)
    local lateralLength = math.sqrt(lateralX * lateralX + lateralZ * lateralZ)
    if lateralLength > 0.0001 then
        lateralX, lateralZ = lateralX / lateralLength, lateralZ / lateralLength
    else
        lateralX, lateralZ = 1, 0
    end

    for wheelIndex, wheel in pairs(wheels) do
        local loadT = getTireLoad(wheel)
        if loadT >= self.MIN_WHEEL_LOAD_T then
            local x, y, z = getContactPoint(wheel)
            if x ~= nil and z ~= nil then
                local pressure, width, length, tireCount, crawler, diameter =
                    getFootprint(wheel, loadT)
                local fieldConfirmed = getIsOnField(wheel)
                local surfaceIx, surfaceIz, surfaceCellKey = getCell(
                    x, z, TerraLogicSoilManager.WHEEL_CELL_SIZE or 1)
                local structureIx, structureIz, structureCellKey = getCell(
                    x, z, self.STRUCTURE_CELL_SIZE_M)
                local localX, axleLocalZ = getStableWheelLocalPosition(
                    rootNode, wheel, x, y, z)
                local deepStressWidth = getDeepStressWidth(width)
                local deepIx, deepIz, deepCellKey = getCell(
                    x, z, self.DEEP_CELL_SIZE_M)
                observations[#observations + 1] = {
                    wheel=wheel,
                    identity=getWheelRuntimeIdentity(wheel, wheelIndex),
                    x=x, z=z,
                    surfaceIx=surfaceIx, surfaceIz=surfaceIz,
                    surfaceCellKey=surfaceCellKey,
                    structureIx=structureIx, structureIz=structureIz,
                    structureCellKey=structureCellKey,
                    pressure=pressure, crawler=crawler,
                    loadT=loadT, width=width, diameter=diameter,
                    contactLength=length,
                    deepStressWidth=deepStressWidth,
                    deepIx=deepIx, deepIz=deepIz,
                    deepCellKey=deepCellKey, axleLocalZ=axleLocalZ,
                    localX=localX,
                    tireCount=tireCount,
                    fieldConfirmed=fieldConfirmed
                }
                totalLoad = totalLoad + loadT
                minimumWheelLoad = math.min(minimumWheelLoad, loadT)
                maximumWheelLoad = math.max(maximumWheelLoad, loadT)
                if crawler then crawlerCount = crawlerCount + 1 end
                if fieldConfirmed then
                    fieldContactCount = fieldContactCount + 1
                end
                firstX, firstZ = firstX or x, firstZ or z
            end
        end
    end
    if #observations == 0 then return end

    local crawlerModules, pairedCrawlerObservations =
        buildCrawlerModules(observations)
    local surfaceObservations = {}
    for _, observation in ipairs(observations) do
        if observation.crawler ~= true
            or not pairedCrawlerObservations[observation] then
            surfaceObservations[#surfaceObservations + 1] = observation
        end
    end
    for _, module in ipairs(crawlerModules) do
        module.surfaceIx, module.surfaceIz, module.surfaceCellKey = getCell(
            module.x, module.z, TerraLogicSoilManager.WHEEL_CELL_SIZE or 1)
        module.structureIx, module.structureIz,
            module.structureCellKey = getCell(
                module.x, module.z, self.STRUCTURE_CELL_SIZE_M)
        module.deepStressWidth = getDeepStressWidth(module.width)
        surfaceObservations[#surfaceObservations + 1] = module
    end
    local unmatchedCrawlerCount = 0
    for _, observation in ipairs(surfaceObservations) do
        maxPressure = math.max(maxPressure, observation.pressure)
        pressureSum = pressureSum + observation.pressure
        widthSum = widthSum + observation.width
        diameterSum = diameterSum + observation.diameter
        contactLengthSum = contactLengthSum + observation.contactLength
        deepStressWidthSum = deepStressWidthSum
            + observation.deepStressWidth
        physicalTireCount = physicalTireCount
            + (observation.tireCount or 1)
        if observation.crawler == true and observation.members == nil then
            unmatchedCrawlerCount = unmatchedCrawlerCount + 1
        end
    end

    -- Build physical axles only after all stable wheel-carrier positions are
    -- known.  This prevents steered contact patches from turning one front
    -- axle into two artificial half-axles during tight turns.
    axles = buildAxleGroups(observations)

    -- Resolve physical axle load once before processing the independent wheel
    -- tracks. This preserves the correct subsoil load while preventing one
    -- side from masking the other during diagonal deep-grid crossings.
    local axleLoads, axleLocalPositions, axlePositionSpreads = {}, {}, {}
    for axleIndex, axle in ipairs(axles) do
        axleCount = axleCount + 1
        axle.deepTarget, axle.deepStrength = getDeepImpact(axle.loadT)
        maxAxleLoad = math.max(maxAxleLoad, axle.loadT)
        maxDeepTarget = math.max(maxDeepTarget, axle.deepTarget or 0)
        maxDeepStrength = math.max(maxDeepStrength, axle.deepStrength or 0)
        axleLoads[axleIndex] = axle.loadT
        axleLocalPositions[axleIndex] = axle.localZ
        axlePositionSpreads[axleIndex] = math.max(
            (axle.maxLocalZ or axle.localZ)
                - (axle.minLocalZ or axle.localZ), 0)
    end

    local impacts = {}
    local suppressedSurfaceContacts = 0
    local maxSuppressedTarget, maxSuppressedStrength = 0, 0
    local maxSuppressedPressure, maxSuppressedLoad = 0, 0
    local maxSuppressedIdentity = nil
    for _, observation in ipairs(surfaceObservations) do
        local wheelState
        if observation.members ~= nil then
            wheelState = vehicleState.trackModules[observation.key]
        else
            wheelState = vehicleState.wheels[observation.wheel]
        end
        if wheelState == nil then
            wheelState = {
                surfaceCellKey=nil, structureCellKey=nil,
                deepCellKey=nil,
                lastSlipTime=-100000, sampleTime=nil, x=nil, z=nil
            }
            if observation.members ~= nil then
                vehicleState.trackModules[observation.key] = wheelState
            else
                vehicleState.wheels[observation.wheel] = wheelState
            end
        end
        resetDiscontinuousWheelSample(wheelState,
            observation.x, observation.z, now, speed)
        local slip, rawSlip = 0, 0
        if observation.members ~= nil then
            for _, member in ipairs(observation.members) do
                local memberState = vehicleState.wheels[member.wheel]
                if memberState == nil then
                    memberState = {lastSlipTime=-100000, sampleTime=nil,
                        x=nil, z=nil}
                    vehicleState.wheels[member.wheel] = memberState
                end
                resetDiscontinuousWheelSample(memberState,
                    member.x, member.z, now, speed)
                local memberSlip, memberRawSlip = getCorrectedSlip(
                    member.wheel, memberState, member.x, member.z, now)
                slip = math.max(slip, memberSlip)
                rawSlip = math.max(rawSlip, memberRawSlip or 0)
                memberState.x, memberState.z = member.x, member.z
                memberState.sampleTime = now
            end
        else
            slip, rawSlip = getCorrectedSlip(
                observation.wheel, wheelState,
                observation.x, observation.z, now)
        end
        local target, strength, slipSeverity, pressureDriver,
            lowPressureResponse = getSurfaceImpact(observation.pressure, slip)
        maxSlip = math.max(maxSlip, slip)
        maxRawSlip = math.max(maxRawSlip, rawSlip or 0)
        local enteredStructure = wheelState.structureCellKey
            ~= observation.structureCellKey
        local spinningAgain = slipSeverity > 0.05
            and now - wheelState.lastSlipTime >= self.SLIP_REPEAT_MS
        if target ~= nil then
            local cellSize = TerraLogicSoilManager.WHEEL_CELL_SIZE or 1
            for _, cell in ipairs(getSurfaceBandCells(
                    wheelState.x, wheelState.z,
                    observation.x, observation.z, observation.width,
                    lateralX, lateralZ)) do
                local impact = mergeImpact(impacts,
                    cell.ix, cell.iz, cellSize)
                impact.surfaceCoverage = clamp01(
                    (tonumber(impact.surfaceCoverage) or 0)
                        + clamp01(cell.coverage))
                if workingImplementSurfaceSuppressed then
                    impact.workingImplementSurfaceSuppressed = true
                    impact.suppressedSurfaceTarget = math.max(
                        tonumber(impact.suppressedSurfaceTarget) or 0,
                        target)
                    impact.suppressedSurfaceStrength = math.max(
                        tonumber(impact.suppressedSurfaceStrength) or 0,
                        strength)
                elseif impact.surfaceTarget == nil
                        or target > impact.surfaceTarget
                        or (math.abs(target-impact.surfaceTarget) < 0.000001
                            and strength > (impact.surfaceStrength or 0)) then
                    impact.surfaceTarget = target
                    impact.surfaceStrength = strength
                    impact.surfaceLowPressureResponse = lowPressureResponse
                end
                if impact.surfacePressureKPa == nil
                        or observation.pressure > impact.surfacePressureKPa then
                    local identity = observation.identity or {}
                    impact.surfacePressureKPa = observation.pressure
                    impact.surfaceWheelLoadT = observation.loadT
                    impact.surfaceWidthM = observation.width
                    impact.surfaceDiameterM = observation.diameter
                    impact.surfaceContactLengthM = observation.contactLength
                    impact.surfaceTireCount = observation.tireCount
                    impact.surfaceCrawler = observation.crawler
                    impact.surfaceWheelIndex = identity.index
                    impact.surfaceWheelNodeName = identity.reprName
                    impact.surfaceWheelExternalFilename =
                        identity.externalFilename
                    impact.surfaceWheelVisualCount = identity.visualCount
                    impact.surfaceWheelRestLoadT = identity.restLoadT
                end
                -- Only the current contact cell may inherit the wheel's field
                -- confirmation.  Interpolated cells still need to validate
                -- their own centre in the soil manager, otherwise a contact
                -- near a field edge can draw thin soil-map hairs outside it.
                impact.fieldConfirmed = impact.fieldConfirmed == true
                    or (cell.ix == observation.surfaceIx
                        and cell.iz == observation.surfaceIz
                        and observation.fieldConfirmed == true)
            end
            if workingImplementSurfaceSuppressed then
                suppressedSurfaceContacts = suppressedSurfaceContacts + 1
                if target > maxSuppressedTarget then
                    maxSuppressedTarget = target
                    maxSuppressedStrength = strength
                    maxSuppressedPressure = observation.pressure
                    maxSuppressedLoad = observation.loadT
                    maxSuppressedIdentity = observation.identity
                end
            end
        end
        -- Merge every wheel belonging to the same two-metre structural cell.
        -- The soil manager therefore applies Tilth/Evenness once per physical
        -- passage instead of once for each one-metre contact sample.
        if enteredStructure and target ~= nil
            and (pressureDriver > 0 or slipSeverity > 0)
            and not workingImplementSurfaceSuppressed then
            for _, cell in ipairs(getSegmentCells(
                    wheelState.x, wheelState.z,
                    observation.x, observation.z,
                    self.STRUCTURE_CELL_SIZE_M)) do
                local impact = mergeImpact(impacts,
                    cell.ix, cell.iz, self.STRUCTURE_CELL_SIZE_M)
                impact.structurePass = true
                if impact.structurePressureDriver == nil
                        or pressureDriver > impact.structurePressureDriver then
                    impact.structurePressureDriver = pressureDriver
                    impact.structurePressureKPa = observation.pressure
                    impact.structureSurfaceStrength = strength
                    impact.structureWheelLoadT = observation.loadT
                    impact.structureWidthM = observation.width
                    impact.structureDiameterM = observation.diameter
                    impact.structureContactLengthM = observation.contactLength
                    impact.structureTireCount = observation.tireCount
                    impact.structureCrawler = observation.crawler
                end
                impact.fieldConfirmed = impact.fieldConfirmed == true
                    or (cell.ix == observation.structureIx
                        and cell.iz == observation.structureIz
                        and observation.fieldConfirmed == true)
            end
        end
        if slipSeverity > 0 and (enteredStructure or spinningAgain)
            and not workingImplementSurfaceSuppressed then
            for _, cell in ipairs(getSegmentCells(
                    wheelState.x, wheelState.z,
                    observation.x, observation.z,
                    self.STRUCTURE_CELL_SIZE_M)) do
                local impact = mergeImpact(impacts,
                    cell.ix, cell.iz, self.STRUCTURE_CELL_SIZE_M)
                impact.slipSeverity = math.max(
                    impact.slipSeverity or 0, slipSeverity)
                impact.correctedSlip = math.max(
                    impact.correctedSlip or 0, slip)
                impact.rawSlip = math.max(
                    impact.rawSlip or 0, rawSlip or 0)
                impact.fieldConfirmed = impact.fieldConfirmed == true
                    or (cell.ix == observation.structureIx
                        and cell.iz == observation.structureIz
                        and observation.fieldConfirmed == true)
            end
            wheelState.lastSlipTime = now
        end
        wheelState.surfaceCellKey = observation.surfaceCellKey
        wheelState.structureCellKey = observation.structureCellKey
        wheelState.x, wheelState.z = observation.x, observation.z
        wheelState.sampleTime = now
    end

    -- Deep stress deliberately keeps GIANTS' individual crawler load points.
    -- A belt spreads topsoil pressure over its complete footprint, but its
    -- guide wheels still transfer load into the subsoil at distinct positions.
    -- Combining the whole belt into one artificial axle would overstate deep
    -- compaction on two-track tractors and combines.
    for _, observation in ipairs(observations) do
        local deepState = vehicleState.deepWheels[observation.wheel]
        if deepState == nil then
            deepState = {deepCellKey=nil, sampleTime=nil, x=nil, z=nil}
            vehicleState.deepWheels[observation.wheel] = deepState
        end
        resetDiscontinuousWheelSample(deepState,
            observation.x, observation.z, now, speed)
        local enteredDeep = deepState.deepCellKey
            ~= observation.deepCellKey
        local axle = axles[observation.axleKey]
        if enteredDeep and axle ~= nil and axle.deepTarget ~= nil then
            for _, deepCell in ipairs(getDeepBandCells(
                    deepState.x, deepState.z,
                    observation.x, observation.z,
                    observation.deepStressWidth,
                    lateralX, lateralZ)) do
                local coverage = clamp01(deepCell.coverage)
                local impact = mergeImpact(impacts,
                    deepCell.ix, deepCell.iz,
                    self.DEEP_CELL_SIZE_M,
                    "deepAxle" .. tostring(observation.axleKey))
                impact.deepTarget = axle.deepTarget
                impact.deepStrength = axle.deepStrength
                impact.deepCoverage = clamp01(
                    (tonumber(impact.deepCoverage) or 0) + coverage)
                impact.deepCoveredWidthM = math.max(
                    tonumber(impact.deepCoveredWidthM) or 0,
                    observation.deepStressWidth)
                impact.fieldConfirmed = false
                maximumDeepCoverage = math.max(
                    maximumDeepCoverage, impact.deepCoverage)
                deepCoverageSum = deepCoverageSum + coverage
                deepCoverageCount = deepCoverageCount + 1
                vehicleState.lastDeepCoverage = impact.deepCoverage
                vehicleState.lastDeepStressWidth =
                    observation.deepStressWidth
                vehicleState.lastDeepCoverageTime = now
            end
        end
        deepState.deepCellKey = observation.deepCellKey
        deepState.x, deepState.z = observation.x, observation.z
        deepState.sampleTime = now
    end

    local sourceVehicleName = "vehicle"
    if vehicle.getFullName ~= nil then
        sourceVehicleName = tostring(vehicle:getFullName())
    elseif vehicle.getName ~= nil then
        sourceVehicleName = tostring(vehicle:getName())
    end
    local sourceConfigFileName = tostring(vehicle.configFileName or "")
    local changedCells, impactCount, structureImpactCount = 0, 0, 0
    local impactCountBySize = {}
    local changedByLayer = {
        surfaceCompaction=0, deepCompaction=0, aggregateSize=0,
        roughness=0, resilience=0
    }
    local deltaByLayer = {
        surfaceCompaction=0, deepCompaction=0, aggregateSize=0,
        roughness=0, resilience=0
    }
    local maximumDeltaByLayer = {
        surfaceCompaction=0, deepCompaction=0, aggregateSize=0,
        roughness=0, resilience=0
    }
    local maxSurfaceTargetApplied, maxSurfaceStrengthApplied = 0, 0
    local maxDeepStrengthApplied = 0
    local lastImpact = nil
    local representativeSurfaceImpact, representativeDeepImpact = nil, nil
    local representativeSurfaceScore, representativeDeepScore = -1, -1
    local trafficWarningLevel = 0
    for _, impact in pairs(impacts) do
        impact.workingImplementSurfaceSuppressed =
            workingImplementSurfaceSuppressed
        impact.suppressedSurfaceContacts = suppressedSurfaceContacts
        impact.maxSuppressedSurfaceTarget = maxSuppressedTarget
        impact.maxSuppressedSurfaceStrength = maxSuppressedStrength
        impact.maxSuppressedPressureKPa = maxSuppressedPressure
        impact.maxSuppressedWheelLoadT = maxSuppressedLoad
        impact.implementRuntimeState = implementRuntimeState
        if maxSuppressedIdentity ~= nil then
            impact.maxSuppressedWheelIndex = maxSuppressedIdentity.index
            impact.maxSuppressedWheelNodeName =
                maxSuppressedIdentity.reprName
            impact.maxSuppressedWheelExternalFilename =
                maxSuppressedIdentity.externalFilename
            impact.maxSuppressedWheelRestLoadT =
                maxSuppressedIdentity.restLoadT
            impact.maxSuppressedWheelVisualCount =
                maxSuppressedIdentity.visualCount
        end
        -- Preserve causal data on every accepted cell impact. The soil-process
        -- panel/logger can now distinguish tractor, trailed implement and any
        -- other wheel entity instead of exposing only an anonymous write.
        impact.sourceVehicleName = sourceVehicleName
        impact.sourceConfigFileName = sourceConfigFileName
        impact.sourceVehicleMassT = vehicleMass
        impact.sourceSupportedLoadT = totalLoad
        impact.sourceWheelCount = #observations
        impact.sourceAxleCount = axleCount
        impact.sourceMaxAxleLoadT = maxAxleLoad
        impact.sourceMeanAxleLoadT = axleCount > 0
            and totalLoad / axleCount or 0
        impact.sourceMeanPressureKPa = #surfaceObservations > 0
            and pressureSum / #surfaceObservations or 0
        impact.sourceMaxPressureKPa = maxPressure
        impactCount = impactCount + 1
        local sizeKey = tonumber(impact.cellSize) or 0
        impactCountBySize[sizeKey] = (impactCountBySize[sizeKey] or 0) + 1
        if impact.structurePass == true or (impact.slipSeverity or 0) > 0 then
            structureImpactCount = structureImpactCount + 1
        end
        local changed, detail = TerraLogicSoilManager:applyWheelCompactionCell(
            impact.ix, impact.iz, impact)
        if detail ~= nil then
            if trafficWarningLevel < 3 then
                trafficWarningLevel = math.max(trafficWarningLevel,
                    TerraLogicTrafficWarnings:getImpactLevel(detail))
            end
            if lastImpact == nil
                or detail.workingImplementSurfaceSuppressed == true
                or detail.structurePass == true
                or (detail.slipSeverity or 0) > 0 then
                lastImpact = detail
            end
            local surfaceDelta = math.abs(detail.delta ~= nil
                and tonumber(detail.delta.surfaceCompaction) or 0)
            if (tonumber(detail.surfaceTarget) or 0) > 0 then
                local score = surfaceDelta * 10
                    + (tonumber(detail.surfaceTarget) or 0)
                if score > representativeSurfaceScore then
                    representativeSurfaceImpact = detail
                    representativeSurfaceScore = score
                end
            end
            local deepDelta = math.abs(detail.delta ~= nil
                and tonumber(detail.delta.deepCompaction) or 0)
            if (tonumber(detail.deepTarget) or 0) > 0 then
                local score = deepDelta * 10
                    + (tonumber(detail.deepTarget) or 0)
                if score > representativeDeepScore then
                    representativeDeepImpact = detail
                    representativeDeepScore = score
                end
            end
            maxSurfaceTargetApplied = math.max(maxSurfaceTargetApplied,
                tonumber(detail.surfaceTarget) or 0)
            maxSurfaceStrengthApplied = math.max(maxSurfaceStrengthApplied,
                tonumber(detail.surfaceAppliedStrength) or 0)
            maxDeepStrengthApplied = math.max(maxDeepStrengthApplied,
                tonumber(detail.deepAppliedStrength) or 0)
            for layerId in pairs(changedByLayer) do
                local delta = detail.delta ~= nil
                    and tonumber(detail.delta[layerId]) or 0
                deltaByLayer[layerId] = deltaByLayer[layerId] + delta
                maximumDeltaByLayer[layerId] = math.max(
                    maximumDeltaByLayer[layerId], math.abs(delta))
                if detail.changedLayers ~= nil
                    and detail.changedLayers[layerId] == true then
                    changedByLayer[layerId] = changedByLayer[layerId] + 1
                end
            end
        end
        if changed then
            changedCells = changedCells + 1
        end
    end
    -- Do not reuse the diagnostic fallback to older representative impacts:
    -- warnings must describe this pass, including a fresh zero on leaving soil.
    TerraLogicTrafficWarnings:record(vehicle, trafficWarningLevel, now)
    vehicleState.totalChangedCells = (vehicleState.totalChangedCells or 0)
        + changedCells
    vehicleState.totalImpactCells = (vehicleState.totalImpactCells or 0)
        + impactCount
    vehicleState.totalStructureCells =
        (vehicleState.totalStructureCells or 0) + structureImpactCount
    vehicleState.totalChangedByLayer = vehicleState.totalChangedByLayer or {}
    vehicleState.totalDeltaByLayer = vehicleState.totalDeltaByLayer or {}
    vehicleState.maximumDeltaByLayer =
        vehicleState.maximumDeltaByLayer or {}
    for layerId, count in pairs(changedByLayer) do
        vehicleState.totalChangedByLayer[layerId] =
            (vehicleState.totalChangedByLayer[layerId] or 0) + count
        vehicleState.totalDeltaByLayer[layerId] =
            (vehicleState.totalDeltaByLayer[layerId] or 0)
            + (deltaByLayer[layerId] or 0)
        vehicleState.maximumDeltaByLayer[layerId] = math.max(
            vehicleState.maximumDeltaByLayer[layerId] or 0,
            maximumDeltaByLayer[layerId] or 0)
    end
    if representativeSurfaceImpact ~= nil then
        vehicleState.lastSurfaceImpact = representativeSurfaceImpact
    else
        representativeSurfaceImpact = vehicleState.lastSurfaceImpact
    end
    if representativeDeepImpact ~= nil then
        vehicleState.lastDeepImpact = representativeDeepImpact
    else
        representativeDeepImpact = vehicleState.lastDeepImpact
    end
    local crawlerModuleLoads, crawlerModuleWidths = {}, {}
    local crawlerModuleSpacings, crawlerModuleLengths = {}, {}
    local crawlerModulePressures, crawlerModuleLocalX = {}, {}
    local crawlerModuleLocalZ = {}
    for index, module in ipairs(crawlerModules) do
        crawlerModuleLoads[index] = module.loadT
        crawlerModuleWidths[index] = module.width
        crawlerModuleSpacings[index] = module.contactSpacing
        crawlerModuleLengths[index] = module.contactLength
        crawlerModulePressures[index] = module.pressure
        crawlerModuleLocalX[index] = module.localX
        crawlerModuleLocalZ[index] = module.axleLocalZ
    end
    local diagnostic = {
        vehicle=vehicle, vehicleName=sourceVehicleName,
        configFileName=sourceConfigFileName,
        time=now, speed=speed, wheelCount=#observations,
        vehicleMass=vehicleMass,
        supportedLoadRatio=vehicleMass > 0 and totalLoad / vehicleMass or 0,
        totalLoad=totalLoad, maxPressure=maxPressure, maxSlip=maxSlip,
        maxRawSlip=maxRawSlip,
        minWheelLoad=minimumWheelLoad < math.huge and minimumWheelLoad or 0,
        maxWheelLoad=maximumWheelLoad,
        meanWheelLoad=#observations > 0 and totalLoad / #observations or 0,
        effectiveFootprintCount=#surfaceObservations,
        meanPressure=#surfaceObservations > 0
            and pressureSum / #surfaceObservations or 0,
        meanWidth=#surfaceObservations > 0
            and widthSum / #surfaceObservations or 0,
        meanDiameter=#surfaceObservations > 0
            and diameterSum / #surfaceObservations or 0,
        meanContactLength=#surfaceObservations > 0
            and contactLengthSum / #surfaceObservations or 0,
        meanDeepStressWidth=#surfaceObservations > 0
            and deepStressWidthSum / #surfaceObservations or 0,
        physicalTireCount=physicalTireCount,
        crawlerCount=crawlerCount,
        crawlerModuleCount=#crawlerModules,
        unmatchedCrawlerCount=unmatchedCrawlerCount,
        crawlerModuleLoads=crawlerModuleLoads,
        crawlerModuleWidths=crawlerModuleWidths,
        crawlerModuleContactSpacings=crawlerModuleSpacings,
        crawlerModuleContactLengths=crawlerModuleLengths,
        crawlerModulePressures=crawlerModulePressures,
        crawlerModuleLocalX=crawlerModuleLocalX,
        crawlerModuleLocalZ=crawlerModuleLocalZ,
        changedCells=changedCells,
        fieldContactCount=fieldContactCount,
        axleCount=axleCount, maxAxleLoad=maxAxleLoad,
        meanAxleLoad=axleCount > 0 and totalLoad / axleCount or 0,
        axleLoads=axleLoads,
        axleLocalPositions=axleLocalPositions,
        axlePositionSpreads=axlePositionSpreads,
        maxDeepTarget=maxDeepTarget,
        maxDeepStrength=maxDeepStrength,
        maximumDeepCoverage=maximumDeepCoverage,
        meanDeepCoverage=deepCoverageCount > 0
            and deepCoverageSum / deepCoverageCount or 0,
        deepCoverageSamples=deepCoverageCount,
        lastDeepCoverage=vehicleState.lastDeepCoverage or 0,
        lastDeepStressWidth=vehicleState.lastDeepStressWidth or 0,
        lastDeepCoverageTime=vehicleState.lastDeepCoverageTime,
        maxSurfaceTargetApplied=maxSurfaceTargetApplied,
        maxSurfaceStrengthApplied=maxSurfaceStrengthApplied,
        maxDeepStrengthApplied=maxDeepStrengthApplied,
        totalChangedCells=vehicleState.totalChangedCells,
        impactCount=impactCount, structureImpactCount=structureImpactCount,
        impactCountBySize=impactCountBySize,
        totalImpactCells=vehicleState.totalImpactCells,
        totalStructureCells=vehicleState.totalStructureCells,
        changedByLayer=changedByLayer,
        totalChangedByLayer=vehicleState.totalChangedByLayer,
        totalDeltaByLayer=vehicleState.totalDeltaByLayer,
        sessionMaximumDeltaByLayer=vehicleState.maximumDeltaByLayer,
        deltaByLayer=deltaByLayer,
        maximumDeltaByLayer=maximumDeltaByLayer,
        workingImplementSurfaceSuppressed=
            workingImplementSurfaceSuppressed,
        suppressedSurfaceContacts=suppressedSurfaceContacts,
        maxSuppressedSurfaceTarget=maxSuppressedTarget,
        maxSuppressedSurfaceStrength=maxSuppressedStrength,
        maxSuppressedPressureKPa=maxSuppressedPressure,
        maxSuppressedWheelLoadT=maxSuppressedLoad,
        maxSuppressedWheelIndex=maxSuppressedIdentity ~= nil
            and maxSuppressedIdentity.index or 0,
        maxSuppressedWheelNodeName=maxSuppressedIdentity ~= nil
            and maxSuppressedIdentity.reprName or "",
        implementRuntimeState=implementRuntimeState,
        lastImpact=lastImpact,
        representativeSurfaceImpact=representativeSurfaceImpact,
        representativeDeepImpact=representativeDeepImpact,
        firstX=firstX, firstZ=firstZ
    }
    self.diagnostics[vehicle] = diagnostic
    self.lastDiagnostic = diagnostic
    self.lastDiagnosticVehicle = vehicle
end

function TerraLogicWheelCompactionManager:update(dt)
    if g_server == nil or TerraLogicSoilManager == nil
        or self.vehicleStates == nil then return end
    self.updateAccumulator = self.updateAccumulator + (tonumber(dt) or 0)
    if self.updateAccumulator < self.UPDATE_INTERVAL_MS then return end
    self.updateAccumulator = self.updateAccumulator % self.UPDATE_INTERVAL_MS
    local now = g_currentMission ~= nil and g_currentMission.time or 0
    for _, vehicle in pairs(getVehicles()) do
        self:processVehicle(vehicle, now)
    end
end

-- On-demand, read-only audit probe. Never called by the traffic update loop.
-- Reports current eligibility, not a fabricated historical skip reason.
function TerraLogicWheelCompactionManager:getEligibilityAudit(vehicle)
    local lines = {}
    local function add(key, value)
        lines[#lines + 1] = key .. "=" .. tostring(value)
    end
    local wheels = vehicle ~= nil and vehicle.spec_wheels ~= nil
        and vehicle.spec_wheels.wheels or nil
    local speed = getVehicleSpeed(vehicle)
    local root = getVehicleNode(vehicle)
    local listed = false
    for _, object in pairs(getVehicles()) do
        if object == vehicle then listed = true; break end
    end
    add("listed_for_traffic", listed)
    add("speed_kph", string.format("%.3f", speed))
    add("speed_method", vehicle ~= nil and vehicle.getLastSpeed ~= nil)
    local reason = "eligible_now"
    if g_server == nil then reason = "server_only"
    elseif not listed then reason = "not_in_vehicle_list"
    elseif wheels == nil then reason = "no_wheels_table"
    elseif root == nil then reason = "no_root_node"
    elseif speed < self.MIN_SPEED_KMH then reason = "below_min_speed" end
    local count, eligible = 0, 0
    for index, wheel in pairs(wheels or {}) do
        count = count + 1
        local physics = wheel.physics
        local load = getTireLoad(wheel)
        local why = "eligible"
        if physics == nil then why = "no_physics"
        elseif physics.getTireLoad == nil then why = "no_load_method"
        else
            local ok, value = pcall(physics.getTireLoad, physics)
            if not ok or tonumber(value) == nil then why = "load_read_failed"
            elseif load < self.MIN_WHEEL_LOAD_T then why = "below_100kg"
            elseif wheel.node == nil then why = "no_wheel_node"
            elseif physics.wheelShape == nil then why = "no_wheel_shape"
            elseif getWheelShapeContactPoint == nil then why = "no_contact_api"
            else
                local okContact, x, _, z = pcall(getContactPoint, wheel)
                if not okContact then why = "contact_read_failed"
                elseif x == nil or z == nil then why = "no_contact_position"
                else eligible = eligible + 1 end
            end
        end
        add("wheel_" .. tostring(index), string.format("load_t:%.4f | %s", load, why))
    end
    if reason == "eligible_now" and eligible == 0 then reason = "no_eligible_wheels" end
    add("wheel_count", count)
    add("eligible_wheels", eligible)
    add("current_gate", reason)
    return lines
end

function TerraLogicWheelCompactionManager:getDiagnostic(vehicle)
    if vehicle ~= nil then
        if self.diagnostics ~= nil then return self.diagnostics[vehicle] end
        return nil
    end
    return self.lastDiagnostic
end

function TerraLogicWheelCompactionManager:getLatestDiagnostic()
    return self.lastDiagnostic, self.lastDiagnosticVehicle
end

function TerraLogicWheelCompactionManager:getDiagnosticText(vehicle)
    local diagnostic = self:getDiagnostic(vehicle)
    if diagnostic == nil then
        return "TerraLogic wheels: no moving wheel sample recorded"
    end
    local moistureText = "moisture unavailable"
    if TerraLogicSoilMoistureManager ~= nil
        and TerraLogicSoilManager ~= nil then
        local soilType = TerraLogicSoilManager:getPFSoilTypeAtWorldPosition(
            diagnostic.firstX or 0, diagnostic.firstZ or 0)
        local moisture = TerraLogicSoilMoistureManager:getStateAtWorldPosition(
            diagnostic.firstX or 0, diagnostic.firstZ or 0)
        local surfaceMultiplier, deepMultiplier =
            TerraLogicSoilMoistureManager:getTrafficMultipliers(soilType)
        moistureText = string.format("%s %.1f/%.1f %% -> traffic x%.3f/x%.3f",
            moisture.profileName, moisture.surface * 100,
            moisture.subsoil * 100, surfaceMultiplier, deepMultiplier)
    end
    return string.format(
        "TerraLogic wheels | %s | speed %.1f km/h | contacts %d (field %d) | supported %.2f t | max axle %.2f t | peak %.0f kPa | deep target/strength %.1f/%.1f %% coverage mean/max %.1f/%.1f %% | drive slip %.1f %% | moisture %s | crawler contacts/modules/fallback %d/%d/%d | changed now/total %d/%d | first wheel %.1f %.1f",
        diagnostic.vehicleName or "vehicle",
        diagnostic.speed, diagnostic.wheelCount,
        diagnostic.fieldContactCount or 0, diagnostic.totalLoad,
        diagnostic.maxAxleLoad or 0, diagnostic.maxPressure,
        (diagnostic.maxDeepTarget or 0) * 100,
        (diagnostic.maxDeepStrength or 0) * 100,
        (diagnostic.meanDeepCoverage or 0) * 100,
        (diagnostic.maximumDeepCoverage or 0) * 100,
        diagnostic.maxSlip * 100,
        moistureText,
        diagnostic.crawlerCount, diagnostic.crawlerModuleCount or 0,
        diagnostic.unmatchedCrawlerCount or 0, diagnostic.changedCells,
        diagnostic.totalChangedCells or 0,
        diagnostic.firstX or 0, diagnostic.firstZ or 0)
end
