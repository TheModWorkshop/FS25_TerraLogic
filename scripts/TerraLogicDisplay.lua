-- Presentation only. Never use these bands to calculate soil or yield effects.
TerraLogicDisplay = {}
local D = TerraLogicDisplay
D.COLORS = {green={0.35,0.82,0.31,1}, yellow={1,0.78,0.08,1},
    orange={1,0.4287,0.0006,1}, red={1,0.18,0.10,1}}
local function clamp(v) return math.max(0,math.min(tonumber(v) or 0,1)) end

function D.rating(key, raw)
    local v = clamp(raw)
    if key == "surfaceCompaction" or key == "deepCompaction" then
        if v <= .300001 then return "terraLogic_fa_ui_compactionLow", "green" end
        if v <= .500001 then return "terraLogic_fa_ui_compactionModerate", "yellow" end
        if v <= .700001 then return "terraLogic_fa_ui_compactionHigh", "orange" end
        return "terraLogic_fa_ui_compactionVeryHigh", "red"
    elseif key == "aggregateSize" then
        if v < .25 then return "terraLogic_display_veryCoarse", "red" end
        if v < .45 then return "terraLogic_soilTilthCoarse", "yellow" end
        if v <= .55 then return "terraLogic_soilTilthOptimal", "green" end
        if v <= .75 then return "terraLogic_soilTilthFine", "yellow" end
        return "terraLogic_display_veryFine", "red"
    elseif key == "roughness" then
        if 1-v >= .80 then return "terraLogic_display_even", "green" end
        if 1-v >= .60 then return "terraLogic_display_medium", "yellow" end
        return "terraLogic_display_uneven", "red"
    elseif key == "resilience" then
        if v >= .65 then return "terraLogic_fa_ui_compactionHigh", "green" end
        if v >= .45 then return "terraLogic_display_medium", "yellow" end
        return "terraLogic_fa_ui_compactionLow", "red"
    elseif key == "continuity" then
        if v >= .85 then return "terraLogic_fa_ui_continuityEstablished", "green" end
        if v >= .40 then return "terraLogic_display_rebuilding", "yellow" end
        return "terraLogic_fa_ui_continuityInterrupted", "red"
    end
    if v >= .80 then return "terraLogic_soilStateGood", "green" end
    if v >= .60 then return "terraLogic_soilStateFair", "yellow" end
    return "terraLogic_soilStatePoor", "red"
end

function D.caption(key, raw)
    local textKey = D.rating(key, raw)
    return g_i18n ~= nil and g_i18n:getText(textKey) or textKey
end

function D.color(key, raw)
    local _, band = D.rating(key, raw)
    return unpack(D.COLORS[band])
end

local function interpolate(v, stops)
    for i=2,#stops do
        if v <= stops[i][1] then
            local a,b = stops[i-1],stops[i]
            local t = (v-a[1])/(b[1]-a[1])
            local ca,cb = D.COLORS[a[2]],D.COLORS[b[2]]
            local sa,sb=a[3] or 1,b[3] or 1
            return ca[1]*sa+(cb[1]*sb-ca[1]*sa)*t, ca[2]*sa+(cb[2]*sb-ca[2]*sa)*t,
                ca[3]*sa+(cb[3]*sb-ca[3]*sa)*t, .78
        end
    end
    local c=D.COLORS[stops[#stops][2]]
    return c[1],c[2],c[3],.78
end
local COMPACTION={{0,"green"},{.3,"green",.8},{.5,"yellow"},{.7,"orange"},{1,"red"}}
local RESILIENCE={{0,"red"},{.45,"yellow"},{.65,"green",.8},{1,"green"}}
local EVENNESS={{0,"red"},{.6,"yellow"},{.8,"green",.8},{1,"green"}}
local TILTH={{0,"red"},{.25,"orange"},{.45,"green",.9},{.5,"green"},{.55,"green",.9},{.75,"orange"},{1,"red"}}
function D.mapColor(key, raw)
    local v=clamp(raw)
    if key=="surfaceCompaction" or key=="deepCompaction" then return interpolate(v,COMPACTION) end
    if key=="resilience" then return interpolate(v,RESILIENCE) end
    if key=="aggregateSize" then return interpolate(v,TILTH) end
    return interpolate(1-v,EVENNESS)
end
