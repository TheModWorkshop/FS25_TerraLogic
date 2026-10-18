-- One mass-conserving solver shared by global fallback and field stores.
-- Rates are calibrated FS water-equivalent mm/game-hour, not rainfall gauges.
TerraLogicWaterBalance = {}
local function smooth(a,b,v)
    local t=math.clamp((v-a)/math.max(b-a,1e-9),0,1)
    return t*t*(3-2*t)
end

function TerraLogicWaterBalance:step(w,h,hours,input,evaporation,upperFlow,lowerFlow,snow,vegetation,manager,structure)
    local before=w.upper+w.lower
    local infiltration=math.min(input,h.infiltration*upperFlow*hours,math.max(h.upper-w.upper,0))
    w.upper=w.upper+infiltration
    local gravity=smooth(h.fieldCapacity*.70,h.saturation,w.upper/150)^2
    local transfer=math.min(math.max(w.upper-h.residual*150,0),math.max(h.lower-w.lower,0),
        h.transfer*math.min(upperFlow,lowerFlow)*gravity*hours)
    -- Structure changes wet-surplus transport only. Preserve the calibrated
    -- below-FC matrix flux, storage capacities, evaporation and root uptake.
    local tf=structure and structure.transferFactor or 1
    local df=structure and structure.drainageFactor or 1
    if tf~=1 then
        tf=math.clamp(tf,.85,1.30)
        local wetUpper=math.max(w.upper-h.fieldCapacity*150,0)
        if tf<1 then transfer=transfer+(tf-1)*math.min(transfer,wetUpper)
        else transfer=transfer+math.min(math.max(wetUpper-transfer,0),
            math.max(h.lower-w.lower-transfer,0),transfer*(tf-1)) end
    end
    w.upper,w.lower=w.upper-transfer,w.lower+transfer
    -- Limited upward redistribution between the two existing stores. Dry
    -- surface conductivity falls again near residual water. This is not a
    -- groundwater source. FAO soil-water movement: /4/y4690e/y4690e07.htm.
    local reserve=math.max(h.fieldCapacity-h.wilt,1e-6)
    local upperAvailable=math.clamp((w.upper/150-h.wilt)/reserve,0,1)
    local lowerAvailable=math.clamp((w.lower/450-h.wilt)/reserve,0,1)
    local capillary=math.min(math.max(w.lower-h.wilt*450,0),math.max(h.upper-w.upper,0),
        (h.capillary or .04)*math.min(upperFlow,lowerFlow)*hours
        *math.max(lowerAvailable-upperAvailable,0)
        *(.10+.90*smooth(h.residual,h.wilt+.25*reserve,w.upper/150)))
    w.upper,w.lower=w.upper+capillary,w.lower-capillary
    local drainage=math.max(w.lower-h.fieldCapacity*450,0)*(1-math.exp(-hours*lowerFlow/h.drainHours))
    if df~=1 then
        df=math.clamp(df,.85,1.30)
        local extra=math.max(w.lower-h.fieldCapacity*450,0)
            *(math.exp(-hours*lowerFlow/h.drainHours)-math.exp(-hours*lowerFlow*df/h.drainHours))
        -- The BONUS must not drain ordinary whole-profile plant reserves
        -- through below-FC redistribution into a temporarily wetter subsoil.
        if extra>0 then extra=math.min(extra,math.max(w.upper+w.lower-drainage-h.fieldCapacity*600,0)) end
        drainage=drainage+extra
    end
    w.lower=w.lower-drainage
    local cover=vegetation and vegetation.cover or 0
    local evaporated=math.min(math.max(w.upper-h.residual*150,0),manager.EVAPORATION_MM_PER_HOUR
        *evaporation*upperFlow/(1+snow/2)*smooth(h.residual,h.fieldCapacity,w.upper/150)
        *(1-.80*cover)*hours)
    w.upper=w.upper-evaporated
    local kcb=vegetation and vegetation.kcb or 1
    local upperShare=vegetation and vegetation.upperShare or .4
    local demand=manager.ROOT_EXTRACTION_MM_PER_HOUR*evaporation*kcb*hours
    local depletion=vegetation and vegetation.depletion or .5
    local critical=h.wilt+(1-depletion)*(h.fieldCapacity-h.wilt)
    local u=math.min(math.max(w.upper-h.wilt*150,0),demand*upperShare*upperFlow
        *smooth(h.wilt,critical,w.upper/150))
    local d=math.min(math.max(w.lower-h.wilt*450,0),demand*(1-upperShare)*lowerFlow
        *smooth(h.wilt,critical,w.lower/450))
    w.upper,w.lower=w.upper-u,w.lower-d
    w.lastTransferMm,w.lastRunoffMm=transfer-capillary,input-infiltration
    w.lastCapillaryMm=capillary
    w.lastBalanceError=w.upper+w.lower-before-infiltration+drainage+evaporated+u+d
    return infiltration,transfer-capillary,drainage,evaporated,u+d,u,d
end
