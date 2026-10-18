-- FAO-56, tables 17/22: basal coefficients, effective roots and depletion.
-- https://www.fao.org/4/X0490E/x0490e0c.htm
-- https://www.fao.org/4/X0490E/x0490e0e.htm
-- Curves are mapped to FS foliage states, not real-day planting calendars.
-- Roots are capped at the model's 60 cm; no imaginary deep water source.
TerraLogicCropWaterProfiles = {
    generic={mid=1.00, finish=.30, depth=.60, depletion=.50},
    profiles={
        wheat={mid=1.10,finish=.20,depth=.60,depletion=.55},
        barley={mid=1.10,finish=.15,depth=.60,depletion=.55},
        oat={mid=1.10,finish=.15,depth=.60,depletion=.55},
        maize={mid=1.15,finish=.15,depth=.60,depletion=.55},
        sorghum={mid=1.00,finish=.35,depth=.60,depletion=.55},
        canola={mid=1.05,finish=.25,depth=.60,depletion=.60},
        sunflower={mid=1.05,finish=.25,depth=.60,depletion=.45},
        soybean={mid=1.10,finish=.30,depth=.60,depletion=.50},
        potato={mid=1.10,finish=.65,depth=.45,depletion=.35},
        sugarbeet={mid=1.15,finish=.50,depth=.60,depletion=.55},
        sugarcane={mid=1.20,finish=.70,depth=.60,depletion=.65},
        cotton={mid=1.10,finish=.45,depth=.60,depletion=.65},
        carrot={mid=.95,finish=.85,depth=.50,depletion=.35},
        parsnip={mid=.95,finish=.85,depth=.50,depletion=.40},
        beetroot={mid=.95,finish=.85,depth=.60,depletion=.50},
        greenbean={mid=1.00,finish=.80,depth=.50,depletion=.45},
        pea={mid=1.10,finish=1.05,depth=.60,depletion=.35},
        spinach={mid=.90,finish=.85,depth=.35,depletion=.20},
        grass={mid=.95,finish=.95,depth=.60,depletion=.40,perennial=true},
        oilseedradish={mid=.85,finish=.70,depth=.50,depletion=.40},
        grape={mid=.65,finish=.40,depth=.60,depletion=.45,woody=true},
        olive={mid=.65,finish=.65,depth=.60,depletion=.65,woody=true},
        poplar={mid=.95,finish=.70,depth=.60,depletion=.50,woody=true},
        -- Rice here describes root use only. Flooded paddies require the
        -- actual rice-field water state; rainfall does not imply irrigation.
        rice={mid=1.15,finish=.70,depth=.50,depletion=.20,paddy=true},
        ricelonggrain={mid=1.15,finish=.45,depth=.50,depletion=.20}
    }
}

function TerraLogicCropWaterProfiles:get(fruit)
    local desc = g_fruitTypeManager and g_fruitTypeManager:getFruitTypeByIndex(fruit)
    local name = string.lower(tostring(desc and desc.name or ""))
    return self.profiles[name] or self.generic, desc, self.profiles[name] == nil
end

function TerraLogicCropWaterProfiles:sample(fruit, state)
    local p, desc, generic = self:get(fruit)
    if desc == nil or not state or state <= 0 then
        return {kcb=0,cover=0,upperShare=1,active=false,generic=generic}
    end
    local info = TerraLogicSoilManager and TerraLogicSoilManager:getRecoveryFruitStateInfo(fruit)
    if info and ((info.withered or {})[state]
        or ((info.cut or {})[state] and not (info.regrowthSources or {})[state])) then
        return {kcb=0,cover=0,upperShare=1,active=false,generic=generic}
    end
    local growing = {}
    for s,name in pairs(desc.growthStateToName or {}) do
        s=tonumber(s)
        local normalized=string.lower(tostring(name))
        if s and not (info and ((info.cut or {})[s] or (info.withered or {})[s])) then growing[s]=true end
        if s==state and normalized=="invisible" then
            return {kcb=0,cover=0,upperShare=1,active=false,generic=generic}
        end
    end
    local rank, count = 0, 0
    for s in pairs(growing) do
        count = count + 1
        if s <= state then rank = rank + 1 end
    end
    local progress
    if count > 1 then progress = math.clamp((rank-1)/(count-1),0,1)
    else progress = math.clamp((state-1)/math.max((desc.numGrowthStates or 7)-2,1),0,1) end
    if info and (info.harvestReady or {})[state] then progress=1 end
    local cover = math.clamp(progress/.55,0,1)
    local kcb = .15+(p.mid-.15)*cover
    if progress>.8 and not p.perennial then
        kcb=p.mid+(p.finish-p.mid)*(progress-.8)/.2
    end
    if info and (info.regrowthSources or {})[state] and (info.cut or {})[state] then
        kcb,cover=.25,.15
    end
    local depth=math.min(.60,.15+(p.depth-.15)*math.clamp(progress/.65,0,1))
    return {kcb=kcb,cover=cover,upperShare=math.clamp(.15/depth,.25,1),
        active=true,generic=generic,paddy=p.paddy,progress=progress,depletion=p.depletion}
end
