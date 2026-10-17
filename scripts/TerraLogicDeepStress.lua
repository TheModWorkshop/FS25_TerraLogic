-- Mechanical input for the existing subsoil cell response. Moisture, texture,
-- frost, resilience and the player's intensity setting remain in SoilManager.
-- This is a calibrated stress approximation, not measured soil deformation.
TerraLogicDeepStress = {
    REFERENCE_DEPTH_M = 0.35,
    STRENGTH_CEILING = 0.16,
    ROLLER_LOAD_SHARE = 0.25,
    referenceCurve = nil
}

local function corner(x, y, depth)
    local radius = math.sqrt(x*x + y*y + depth*depth)
    return (math.atan(x*y / (depth*radius))
        + x*y*depth/radius * (1/(x*x + depth*depth)
            + 1/(y*y + depth*depth))) / (2*math.pi)
end

-- Integral of Boussinesq vertical stress below a rectangular contact patch.
-- Tonnes and metres yield kPa. Offsets use vehicle-local coordinates, so a
-- vehicle's compass heading cannot change its calculated mechanical input.
function TerraLogicDeepStress:getPatchStress(loadT, width, length,
        offsetX, offsetZ)
    loadT = math.max(tonumber(loadT) or 0, 0)
    if loadT <= 0 then return 0 end
    width = math.max(tonumber(width) or 0.12, 0.12)
    length = math.max(tonumber(length) or 0.12, 0.12)
    local a, b, depth = width/2, length/2, self.REFERENCE_DEPTH_M
    local x, z = tonumber(offsetX) or 0, tonumber(offsetZ) or 0
    local pressure = loadT * 9.81 / (width*length)
    return math.max(0, pressure * (
        corner(a-x, b-z, depth) - corner(-a-x, b-z, depth)
        - corner(a-x, -b-z, depth) + corner(-a-x, -b-z, depth)))
end

function TerraLogicDeepStress:ensureReferenceCurve(getFootprint)
    if self.referenceCurve ~= nil then return end
    local curve = {}
    local wheel = {physics={width=0.6, radius=0.9}}
    -- Construct once, not per vehicle or frame. Use the very same footprint
    -- function as real tyres, including their load-dependent contact length.
    for index=0,800 do
        local axleLoad = index/10
        local _, width, length = getFootprint(wheel, axleLoad/2)
        curve[#curve+1] = {load=axleLoad,
            stress=self:getPatchStress(axleLoad/2, width, length, 0, 0)}
    end
    self.referenceCurve = curve
end

function TerraLogicDeepStress:getEquivalentAxleLoad(stress, getFootprint)
    self:ensureReferenceCurve(getFootprint)
    local curve = self.referenceCurve
    local low, high = 1, #curve
    while high-low > 1 do
        local middle = math.floor((low+high)/2)
        if curve[middle].stress < stress then low = middle
        else high = middle end
    end
    local a, b = curve[low], curve[high]
    -- Extrapolate rather than imposing a new hard input-load cap at 80 t.
    return math.max(0, a.load + (b.load-a.load) * (stress-a.stress)
        / math.max(b.stress-a.stress, 0.000001))
end

local function localX(contact)
    return tonumber(contact.localX) or tonumber(contact.x) or 0
end

function TerraLogicDeepStress:getContactStress(contact, x, z)
    local load, width, length = contact.loadT, contact.width,
        contact.contactLength
    local dx = x-localX(contact)
    local dz = z-(tonumber(contact.axleLocalZ) or 0)
    local uniform = self:getPatchStress(load, width, length, dx, dz)
    if contact.crawler ~= true then return uniform end

    -- A complete belt is one pressure profile, not two independent axle
    -- passages. Retain support/roller peaks rather than assuming a perfectly
    -- even belt. The 25% share is a calibration assumption, not OEM data.
    local forwardShare = 0.5
    if contact.first ~= nil and contact.second ~= nil and load > 0 then
        local front = contact.first.axleLocalZ > contact.second.axleLocalZ
            and contact.first or contact.second
        forwardShare = math.max(0, math.min(1, front.loadT/load))
    end
    local rollers = self:getPatchStress(load*forwardShare, width,
        length/4, dx, dz-3*length/8)
        + self:getPatchStress(load*(1-forwardShare), width,
            length/4, dx, dz+3*length/8)
    return (1-self.ROLLER_LOAD_SHARE)*uniform
        + self.ROLLER_LOAD_SHARE*rollers
end

function TerraLogicDeepStress:getGroupImpact(index, contacts, getFootprint)
    local members, points = {}, {}
    for _, contact in ipairs(contacts) do
        if contact.axleKey == index then
            members[#members+1] = contact
            local minimum, maximum = 0, 0
            if contact.crawler == true then minimum, maximum = -3, 3 end
            for step=minimum,maximum do
                points[#points+1] = {x=localX(contact),
                    z=(tonumber(contact.axleLocalZ) or 0)
                        + step*contact.contactLength/8}
            end
        end
    end
    -- Adjacent/dual contacts can have their peak between the tyres. Include
    -- their shared midpoint, and superimpose stresses BEFORE the soil response.
    for i=1,#members do
        for j=i+1,#members do
            local a, b = members[i], members[j]
            if math.abs(localX(a)-localX(b)) < 2 then
                points[#points+1] = {x=(localX(a)+localX(b))/2,
                    z=(a.axleLocalZ+b.axleLocalZ)/2}
            end
        end
    end
    local peak = 0
    for _, point in ipairs(points) do
        local stress = 0
        for _, contact in ipairs(members) do
            stress = stress + self:getContactStress(contact, point.x, point.z)
        end
        peak = math.max(peak, stress)
    end
    if peak <= 0 then return nil, nil, 0, 0 end
    local equivalent = self:getEquivalentAxleLoad(peak, getFootprint)
    local ratio = equivalent/12
    local target = math.min(1, 0.25 + 0.16*ratio + 0.55*ratio^1.70)
    -- Soft saturation replaces the former 15-t step. This coefficient is
    -- gameplay calibration; the stress calculation itself has no 15-t limit.
    local strength = 0.008 + self.STRENGTH_CEILING *
        (1-math.exp(-0.15*ratio^1.50/self.STRENGTH_CEILING))
    return target, strength, peak, equivalent
end
