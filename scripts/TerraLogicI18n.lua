-- Player-facing numeric formatting only. Never use for keys, saves, CSV or wire data.
TerraLogicI18n = {}

-- Read the local player's preferences at display time. Simulation, save and
-- network values stay metric, including on servers with mixed-unit clients.
local function usesUnit(setting, fallback)
    local keys = SettingsModel ~= nil and SettingsModel.SETTING or {}
    return g_gameSettings ~= nil and g_gameSettings.getValue ~= nil
        and g_gameSettings:getValue(keys[setting] or fallback) == true
end

function TerraLogicI18n.speedValue(kmh)
    if g_i18n ~= nil and g_i18n.getSpeed ~= nil then
        return g_i18n:getSpeed(kmh)
    end
    return usesUnit("USE_MILES", "useMiles") and kmh / 1.609344 or kmh
end

function TerraLogicI18n.speedUnit()
    if g_i18n ~= nil and g_i18n.getSpeedMeasuringUnit ~= nil then
        return g_i18n:getSpeedMeasuringUnit()
    end
    return usesUnit("USE_MILES", "useMiles") and "mph" or "km/h"
end

function TerraLogicI18n.formatSpeed(kmh)
    local decimals = TerraLogicI18n.speedUnit() == "mph" and 1 or 0
    return TerraLogicI18n.format("%." .. decimals .. "f %s",
        TerraLogicI18n.speedValue(kmh), TerraLogicI18n.speedUnit())
end

function TerraLogicI18n.formatSpeedRange(lowKmh, highKmh)
    local decimals = TerraLogicI18n.speedUnit() == "mph" and 1 or 0
    return TerraLogicI18n.format("%." .. decimals .. "f-%." .. decimals .. "f %s",
        TerraLogicI18n.speedValue(lowKmh), TerraLogicI18n.speedValue(highKmh),
        TerraLogicI18n.speedUnit())
end

function TerraLogicI18n.formatTemperature(celsius)
    local fahrenheit = usesUnit("USE_FAHRENHEIT", "useFahrenheit")
    return TerraLogicI18n.format("%.1f %s",
        fahrenheit and celsius * 1.8 + 32 or celsius,
        fahrenheit and "°F" or "°C")
end

function TerraLogicI18n.formatArea(hectares)
    local acres = usesUnit("USE_ACRE", "useAcre")
    local value, unit = hectares, "ha"
    if g_i18n ~= nil and g_i18n.getArea ~= nil and g_i18n.getAreaUnit ~= nil then
        value, unit = g_i18n:getArea(hectares), g_i18n:getAreaUnit()
    elseif acres then
        value, unit = hectares * 2.4710538146717, "ac"
    end
    return TerraLogicI18n.format("%.2f %s", value, unit)
end

function TerraLogicI18n.format(pattern, ...)
    if g_languageShort ~= "de" then return string.format(pattern, ...) end

    local args={...}
    local count=select("#", ...)
    local index=0
    -- Parse placeholders, not the rendered text: a vehicle name passed as %s,
    -- a URL or a version number must never have its punctuation rewritten.
    local localized=pattern:gsub("%%[-+ #0]*%d*%.?%d*[cdiouxXeEfgGqs%%]", function(spec)
        if spec=="%%" then return spec end
        index=index+1
        local conversion=spec:sub(-1)
        if conversion:find("[eEfgG]") then
            local value=args[index]
            local rendered=string.format(spec, value)
            local number=tonumber(value)
            if number and number==number and number~=math.huge and number~=-math.huge then
                rendered=rendered:gsub("%.", ",", 1)
            end
            args[index]=rendered
            return "%s"
        end
        return spec
    end)
    return string.format(localized, unpack(args, 1, count))
end
