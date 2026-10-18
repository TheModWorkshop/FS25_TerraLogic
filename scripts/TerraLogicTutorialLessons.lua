-- Stable lesson IDs and translation keys. Text is resolved when displayed.
TerraLogicTutorialLessons = {}
local function lesson(id, group, sections, actions)
    table.insert(TerraLogicTutorialLessons, {id=id, group=group,
        titleKey="tutorial."..id..".title", sections=sections, actions=actions})
end

-- Resolve lazily: localization is loaded by the game, not at source-file load.
function TerraLogicTutorialLessons.getContent(item)
    local sections={}
    for _,keys in ipairs(item.sections) do
        local paragraphs={}
        for _,key in ipairs(keys) do paragraphs[#paragraphs+1]=g_i18n:getText(key) end
        sections[#sections+1]=table.concat(paragraphs,"\n\n")
    end
    return {title=g_i18n:getText(item.titleKey), text=table.concat(sections,"\f")}
end

lesson("welcome", 1, {{"tutorial.welcome.page1.paragraph1", "tutorial.welcome.page1.paragraph2", "tutorial.welcome.page1.paragraph3", "tutorial.welcome.page1.paragraph4"}})
lesson("firstMap", 1, {{"tutorial.firstMap.page1.paragraph1", "tutorial.firstMap.page1.paragraph2", "tutorial.firstMap.page1.paragraph3"}}, {"TERRALOGIC_TOGGLE_SOIL_DISPLAY"})
lesson("mapControls", 1, {{"tutorial.mapControls.page1.paragraph1"}, {"tutorial.mapControls.page2.paragraph1", "tutorial.mapControls.page2.paragraph2", "tutorial.mapControls.page2.paragraph3"}, {"tutorial.mapControls.page3.paragraph1", "tutorial.mapControls.page3.paragraph2", "tutorial.mapControls.page3.paragraph3"}, {"tutorial.mapControls.page4.paragraph1", "tutorial.mapControls.page4.paragraph2", "tutorial.mapControls.page4.paragraph3"}, {"tutorial.mapControls.page5.paragraph1", "tutorial.mapControls.page5.paragraph2", "tutorial.mapControls.page5.paragraph3"}, {"tutorial.mapControls.page6.paragraph1", "tutorial.mapControls.page6.paragraph2", "tutorial.mapControls.page6.paragraph3"}, {"tutorial.mapControls.page7.paragraph1", "tutorial.mapControls.page7.paragraph2"}})
lesson("speedHud", 1, {{"tutorial.speedHud.page1.paragraph1", "tutorial.speedHud.page1.paragraph2", "tutorial.speedHud.page1.paragraph3"}, {"tutorial.speedHud.page2.paragraph1"}, {"tutorial.speedHud.page3.paragraph1"}})
lesson("cruise", 1, {{"tutorial.cruise.page1.paragraph1", "tutorial.cruise.page1.paragraph2", "tutorial.cruise.page1.paragraph3"}}, {"AXIS_CRUISE_CONTROL", "TOGGLE_CRUISE_CONTROL"})
lesson("changedSoil", 1, {{"tutorial.changedSoil.page1.paragraph1", "tutorial.changedSoil.page1.paragraph2", "tutorial.changedSoil.page1.paragraph3"}})
lesson("traffic", 1, {{"tutorial.traffic.page1.paragraph1", "tutorial.traffic.page1.paragraph2", "tutorial.traffic.page1.paragraph3"}})
lesson("analysis", 1, {{"tutorial.analysis.page1.paragraph1", "tutorial.analysis.page1.paragraph2", "tutorial.analysis.page1.paragraph3", "tutorial.analysis.page1.paragraph4", "tutorial.analysis.page1.paragraph5"}})
lesson("compaction", 2, {{"tutorial.compaction.page1.paragraph1", "tutorial.compaction.page1.paragraph2", "tutorial.compaction.page1.paragraph3"}})
lesson("tires", 2, {{"tutorial.tires.page1.paragraph1", "tutorial.tires.page1.paragraph2", "tutorial.tires.page1.paragraph3"}})
lesson("payload", 2, {{"tutorial.payload.page1.paragraph1", "tutorial.payload.page1.paragraph2", "tutorial.payload.page1.paragraph3"}})
lesson("tramlines", 2, {{"tutorial.tramlines.page1.paragraph1", "tutorial.tramlines.page1.paragraph2", "tutorial.tramlines.page1.paragraph3"}})
lesson("pfLanes", 2, {{"tutorial.pfLanes.page1.paragraph1", "tutorial.pfLanes.page1.paragraph2"}})
lesson("tilth", 2, {{"tutorial.tilth.page1.paragraph1", "tutorial.tilth.page1.paragraph2"}})
lesson("evenness", 2, {{"tutorial.evenness.page1.paragraph1", "tutorial.evenness.page1.paragraph2", "tutorial.evenness.page1.paragraph3"}})
lesson("plow", 2, {{"tutorial.plow.page1.paragraph1", "tutorial.plow.page1.paragraph2"}})
lesson("seedbed", 2, {{"tutorial.seedbed.page1.paragraph1", "tutorial.seedbed.page1.paragraph2", "tutorial.seedbed.page1.paragraph3"}})
lesson("directDrill", 2, {{"tutorial.directDrill.page1.paragraph1", "tutorial.directDrill.page1.paragraph2"}, {"tutorial.directDrill.page2.paragraph1", "tutorial.directDrill.page2.paragraph2", "tutorial.directDrill.page2.paragraph3"}})
lesson("seeding", 2, {{"tutorial.seeding.page1.paragraph1", "tutorial.seeding.page1.paragraph2"}})
lesson("roller", 2, {{"tutorial.roller.page1.paragraph1", "tutorial.roller.page1.paragraph2", "tutorial.roller.page1.paragraph3"}})
lesson("overspeed", 2, {{"tutorial.overspeed.page1.paragraph1", "tutorial.overspeed.page1.paragraph2"}})
lesson("draft", 2, {{"tutorial.draft.page1.paragraph1", "tutorial.draft.page1.paragraph2", "tutorial.draft.page1.paragraph3"}})
lesson("condition", 2, {{"tutorial.condition.page1.paragraph1", "tutorial.condition.page1.paragraph2"}})
lesson("stones", 2, {{"tutorial.stones.page1.paragraph1", "tutorial.stones.page1.paragraph2", "tutorial.stones.page1.paragraph3"}})
lesson("weather", 3, {{"tutorial.weather.page1.paragraph1", "tutorial.weather.page1.paragraph2", "tutorial.weather.page1.paragraph3"}})
lesson("wetTraffic", 3, {{"tutorial.wetTraffic.page1.paragraph1", "tutorial.wetTraffic.page1.paragraph2"}})
lesson("moistureWork", 3, {{"tutorial.moistureWork.page1.paragraph1", "tutorial.moistureWork.page1.paragraph2"}})
lesson("waterGrowth", 3, {{"tutorial.waterGrowth.page1.paragraph1", "tutorial.waterGrowth.page1.paragraph2", "tutorial.waterGrowth.page1.paragraph3"}})
lesson("frost", 3, {{"tutorial.frost.page1.paragraph1", "tutorial.frost.page1.paragraph2", "tutorial.frost.page1.paragraph3"}})
lesson("thaw", 3, {{"tutorial.thaw.page1.paragraph1", "tutorial.thaw.page1.paragraph2", "tutorial.thaw.page1.paragraph3"}})
lesson("rainApplication", 3, {{"tutorial.rainApplication.page1.paragraph1", "tutorial.rainApplication.page1.paragraph2"}})
lesson("resilience", 4, {{"tutorial.resilience.page1.paragraph1", "tutorial.resilience.page1.paragraph2", "tutorial.resilience.page1.paragraph3"}})
lesson("continuity", 4, {{"tutorial.continuity.page1.paragraph1", "tutorial.continuity.page1.paragraph2", "tutorial.continuity.page1.paragraph3"}})
lesson("recovery", 4, {{"tutorial.recovery.page1.paragraph1", "tutorial.recovery.page1.paragraph2", "tutorial.recovery.page1.paragraph3"}})
lesson("rotationPlan", 4, {{"tutorial.rotationPlan.page1.paragraph1", "tutorial.rotationPlan.page1.paragraph2", "tutorial.rotationPlan.page1.paragraph3"}})
lesson("rotation", 4, {{"tutorial.rotation.page1.paragraph1", "tutorial.rotation.page1.paragraph2"}})
lesson("cover", 4, {{"tutorial.cover.page1.paragraph1", "tutorial.cover.page1.paragraph2", "tutorial.cover.page1.paragraph3"}})
lesson("systems", 4, {{"tutorial.systems.page1.paragraph1", "tutorial.systems.page1.paragraph2", "tutorial.systems.page1.paragraph3"}})
lesson("yield", 5, {{"tutorial.yield.page1.paragraph1", "tutorial.yield.page1.paragraph2"}})
lesson("bonus", 5, {{"tutorial.bonus.page1.paragraph1", "tutorial.bonus.page1.paragraph2", "tutorial.bonus.page1.paragraph3"}})
lesson("pf", 5, {{"tutorial.pf.page1.paragraph1", "tutorial.pf.page1.paragraph2"}})
lesson("moistureSystem", 3, {{"tutorial.moistureSystem.page1.paragraph1", "tutorial.moistureSystem.page1.paragraph2", "tutorial.moistureSystem.page1.paragraph3"}})
lesson("options", 5, {{"tutorial.options.page1.paragraph1", "tutorial.options.page1.paragraph2", "tutorial.options.page1.paragraph3", "tutorial.options.page1.paragraph4", "tutorial.options.page1.paragraph5"}})
