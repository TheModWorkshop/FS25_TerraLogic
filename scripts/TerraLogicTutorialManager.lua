-- Local nonmodal learning cards. No input-context replacement or density scans.
TerraLogicTutorialManager = {SOURCE_FINGERPRINT=1.200276, SAVE_VERSION=4}
local M=TerraLogicTutorialManager
local function tr(de,en) return g_languageShort=="de" and de or en end
local function vehicle()
    return g_localPlayer and g_localPlayer.getCurrentVehicle and g_localPlayer:getCurrentVehicle() or nil
end
local function root(obj) return obj and obj.getRootVehicle and obj:getRootVehicle() or obj end
local function path() return getUserProfileAppPath and getUserProfileAppPath().."modSettings/FS25_TerraLogicTutorial.xml" end
function M:isGameplayViewActive()
    if g_gui==nil then return true end
    if g_gui.getIsGuiVisible then return not g_gui:getIsGuiVisible() end
    return g_gui.currentGui==nil
end
function M:enabled()
    return self.loaded and g_localPlayer~=nil and TerraLogicSettings~=nil and TerraLogicSettings:getTutorialsEnabled()
end
function M:isOwn(obj) return vehicle()~=nil and root(obj)==root(vehicle()) end
function M:load()
    self.loaded=true
    self.clock,self.nextCheck,self.cooldown,self.still=0,0,0,0
    self.seen,self.displayed,self.pages,self.evidence,self.byId={},{},{},{},{}
    self.current,self.pending,self.hud,self.work,self.snapshot=nil,nil,nil,nil,nil
    self.actor,self.lastPosition,self.resume,self.layout=nil,nil,nil,nil
    self.cursorOwned,self.library,self.manualRequested,self.wasInMenu=false,false,false,false
    self.massReference=nil
    self.snoozed,self.libraryIndex,self.libraryGroup={},false,1
    self.restartRequested,self.resetDialogOpen,self.cursorRestorePending=false,false,false
    self.buttons,self.rightGesture,self.previousCursor=nil,nil,nil
    self.windowX,self.windowY,self.drag=nil,nil,nil
    for i,item in ipairs(TerraLogicTutorialLessons) do item.index=i; self.byId[item.id]=item end
    local p=path()
    if p and fileExists(p) then
        local xml=loadXMLFile("terraLogicTutorial",p)
        if xml and xml~=0 then
            self.windowX=getXMLFloat(xml,"tutorial#windowX")
            self.windowY=getXMLFloat(xml,"tutorial#windowY")
            -- Legacy modal messages were marked read on display, not dismissal.
            -- Offer the new introduction once; never infer completion from them.
            if (getXMLInt(xml,"tutorial#version") or 0)>=4 then
                for _,item in ipairs(TerraLogicTutorialLessons) do
                    local k="tutorial.lessons."..item.id
                    self.seen[item.id]=getXMLBool(xml,k.."#completed")==true
                    self.displayed[item.id]=getXMLBool(xml,k.."#displayed")==true
                    self.pages[item.id]=math.max(1,getXMLInt(xml,k.."#page") or 1)
                end
                local saved=getXMLString(xml,"tutorial#resume")
                if saved and self.byId[saved] then self.resume=saved end
            end
            delete(xml)
        end
    end
end
function M:save()
    local p=path(); if not self.loaded or not p then return end
    local directory=getUserProfileAppPath().."modSettings"
    if not fileExists(directory) and createFolder then createFolder(directory) end
    local xml=createXMLFile("terraLogicTutorial",p,"tutorial")
    if not xml or xml==0 then return end
    setXMLInt(xml,"tutorial#version",4); setXMLString(xml,"tutorial#resume",self.resume or "")
    local x,y=self:getWindowRect()
    setXMLFloat(xml,"tutorial#windowX",x)
    setXMLFloat(xml,"tutorial#windowY",y)
    for _,item in ipairs(TerraLogicTutorialLessons) do
        local k="tutorial.lessons."..item.id
        setXMLBool(xml,k.."#completed",self.seen[item.id]==true)
        setXMLBool(xml,k.."#displayed",self.displayed[item.id]==true)
        setXMLInt(xml,k.."#page",self.pages[item.id] or 1)
    end
    saveXMLFile(xml); delete(xml)
end
function M:releaseCursor()
    if self.drag then self.drag=nil; self:save() end
    if (self.cursorOwned or self.cursorRestorePending) and g_inputBinding then
        if self:isGameplayViewActive() then
            g_inputBinding:setShowMouseCursor(self.previousCursor==true)
            self.cursorRestorePending=false
        else
            -- A menu owns the cursor now; restore ours after returning to play.
            self.cursorRestorePending=true
        end
    end
    self.cursorOwned=false
    self.rightGesture=nil
end
function M:isCardVisible()
    return (self.current~=nil or self.libraryIndex==true) and self:isGameplayViewActive()
        and (getIsGameHudVisible==nil or getIsGameHudVisible())
end
function M:blocksCameraLook()
    return self.loaded and self.cursorOwned
        and self:isCardVisible() and g_inputBinding ~= nil
        and g_inputBinding:getShowMouseCursor()
end
function M:guardCamera(camera, method, onFoot)
    if camera == nil or type(camera[method]) ~= "function" then return end
    self.cameraGuards=self.cameraGuards or setmetatable({}, {__mode="k"})
    local installed=self.cameraGuards[camera]
    if installed and camera[method] == installed then return end
    local original=camera[method]
    local function guarded(activeCamera, ...)
        if M:blocksCameraLook() then
            if onFoot then
                if activeCamera.player == g_localPlayer and vehicle() == nil then
                    local input=activeCamera.player.inputComponent
                    if input then input.cameraRotationX=0; input.cameraRotationY=0 end
                end
            elseif M:isOwn(activeCamera.vehicle) then
                local input=activeCamera.lastInputValues
                if input then input.leftRight=0; input.upDown=0 end
            end
        end
        -- Only consume look deltas. Still run positioning, collision handling,
        -- smoothing and every unrelated camera/vehicle update normally.
        return original(activeCamera, ...)
    end
    camera[method]=guarded
    self.cameraGuards[camera]=guarded
end
function M:ensureCameraGuards()
    -- Use live instances: their action events may already hold older callbacks.
    -- Retry while our cursor is owned to cover camera switches and late creation.
    if g_localPlayer == nil then return end
    self:guardCamera(g_localPlayer.camera, "updateRotation", true)
    local actor=root(vehicle())
    local spec=actor and actor.spec_enterable
    if spec and spec.cameras then
        for _,camera in pairs(spec.cameras) do self:guardCamera(camera, "update", false) end
    end
    if g_activeVehicleCamera and self:isOwn(g_activeVehicleCamera.vehicle) then
        self:guardCamera(g_activeVehicleCamera, "update", false)
    end
end
function M:toggleCursor()
    if not self:isCardVisible() then return end
    if self.cursorOwned then self:releaseCursor(); return end
    if g_inputBinding and g_inputBinding.setShowMouseCursor then
        self.previousCursor=g_inputBinding:getShowMouseCursor()
        g_inputBinding:setShowMouseCursor(true); self.cursorOwned=true
        self:ensureCameraGuards()
    end
end
function M:open(id,library)
    local item=self.byId[id]; if not item then return false end
    self.current,self.library,self.pending,self.layout=item,library==true,nil,nil
    self.libraryIndex=false; self.buttons=nil
    self.rightGesture=nil
    self.displayed[id],self.resume=true,id
    self:save(); return true
end
function M:close()
    if self.current then self.snoozed[self.current.id]=self.clock+300000 end
    self:save(); self:releaseCursor()
    self.current,self.layout,self.pending=nil,nil,nil
    self.libraryIndex=false; self.buttons=nil
    self.cooldown=self.clock+15000
end
function M:openLibrary()
    if not self.loaded then return end
    if not self:isGameplayViewActive() then self.manualRequested=true; return end
    self.current,self.pending,self.layout=nil,nil,nil
    self.libraryIndex=true; self.library=true; self.buttons=nil; self.rightGesture=nil
end
function M:selectGroup(group)
    self.libraryGroup=group; self.libraryPage=1; self.buttons=nil
end
function M:changeLibraryPage(delta)
    self.libraryPage=math.max(1,(self.libraryPage or 1)+delta); self.buttons=nil
end
function M:selectLesson(id)
    self:open(id,true)
end
function M:next()
    if not self.current or not self:isGameplayViewActive() then return end
    self:buildLayout()
    local id=self.current.id; local p=self.pages[id] or 1
    if p<#self.layout.pages then self.pages[id]=p+1; self:save()
    else
        self.seen[id],self.pages[id],self.resume=true,1,nil
        if self.library then self:save(); self:openLibrary()
        else self:close() end
    end
end
function M:previous()
    if not self.current or not self:isGameplayViewActive() then return end
    local id=self.current.id
    if (self.pages[id] or 1)>1 then self.pages[id]=self.pages[id]-1; self:save()
    end
end
function M:disable()
    TerraLogicSettings.tutorialsEnabled=false
    TerraLogicSettings:saveLocal()
    if TerraLogicSettings.tutorialsOption then TerraLogicSettings.tutorialsOption:setState(1) end
    self.restartRequested,self.manualRequested=false,false
    self:onEnabledChanged(false)
end
function M:onEnabledChanged(enabled)
    self.pending,self.evidence=nil,{}
    if not enabled then self:close() end
end
function M:resetAll()
    self:close(); self.seen,self.displayed,self.pages,self.evidence={},{},{},{}
    self.snoozed={}; self.pending,self.hud,self.work,self.snapshot=nil,nil,nil,nil
    self.resume=nil; self.cooldown=0; self.manualRequested=false
    TerraLogicSettings.tutorialsEnabled=true; TerraLogicSettings.tutorialMode="guided"
    TerraLogicSettings:saveLocal()
    if TerraLogicSettings.tutorialsOption then TerraLogicSettings.tutorialsOption:setState(2) end
    self.restartRequested=true; self:save()
end
function M:requestReset()
    -- Explicit settings action: restart the introduction after leaving the menu.
    -- No modal dialog (or dialog callback) can trap a reset request.
    self:resetAll()
end
function M:consoleStatus()
    local n=0; for _,v in pairs(self.seen) do if v then n=n+1 end end
    return string.format("Tutorials %d/%d complete; active=%s; pending=%s",n,#TerraLogicTutorialLessons,
        self.current and self.current.id or "none",self.pending and self.pending.id or "none")
end
function M:consoleShow(id)
    if not id or id=="" then self:openLibrary(); return self:consoleStatus() end
    return self:open(id,true) and self:consoleStatus() or "Unknown lesson id"
end
function M:delete()
    self:save(); self:releaseCursor(); self.loaded=false
    self.current,self.pending,self.hud,self.work,self.snapshot=nil,nil,nil,nil,nil
end
-- Prerequisites teach vocabulary before contextual lessons use it.
local prerequisites={
 mapControls="firstMap", analysis="mapControls", changedSoil="mapControls",
 traffic="speedHud", cruise="speedHud", overspeed="cruise", condition="speedHud",
 compaction="analysis", tires="compaction", payload="tires", tramlines="tires", pfLanes="tramlines",
 plow="analysis", seedbed="analysis", tilth="analysis", evenness="analysis", seeding="analysis",
 roller="seeding", draft="speedHud", moistureWork="analysis", wetTraffic="tires",
 frost="weather", thaw="recovery", waterGrowth="weather", rainApplication="speedHud",
 resilience="analysis", continuity="resilience", recovery="continuity", directDrill="recovery",
 rotation="recovery", cover="recovery", rotationPlan="rotation", systems="recovery",
 bonus="yield", yield="analysis", weather="analysis", pf="analysis", options="analysis"
}
function M:resolveLesson(id)
 local depth=0
 while prerequisites[id] and not self.seen[prerequisites[id]] and depth<12 do
  local parent=prerequisites[id]
  if TerraLogicSettings.tutorialMode=="context" and (parent=="firstMap" or parent=="mapControls") then break end
  id=parent; depth=depth+1
 end
 return id
end
-- One recent candidate, not a queue. Refresh only while its context still applies.
function M:offer(id,priority,actor)
    id=self:resolveLesson(id)
    if not self:enabled() or self.current or self.libraryIndex or self.clock<self.cooldown
        or self.seen[id] or (self.snoozed[id] or 0)>self.clock or not self.byId[id] then return end
    if TerraLogicSettings.tutorialMode=="context" and (id=="welcome" or id=="firstMap" or id=="mapControls") then return end
    if self.pending and self.pending.id==id and self.pending.actor==actor then
        self.pending.expires=self.clock+8000
    elseif not self.pending or priority>self.pending.priority then
        self.pending={id=id,priority=priority,actor=actor,expires=self.clock+8000}
    end
end
function M:signal(id,priority,actor,duration)
    if not self:enabled() then return end
    local e=self.evidence[id]
    if not e or e.actor~=actor or self.clock-e.last>1500 then
        e={start=self.clock,last=self.clock,actor=actor}; self.evidence[id]=e
    end
    e.last=self.clock
    if self.clock-e.start>=(duration or 4000) then self:offer(id,priority,actor) end
end
function M:observeHud(implement,context,active,visible,speed)
    if not self:enabled() or not self:isOwn(implement) then return end
    local h=self.hud or {}; self.hud=h
    h.implement,h.context,h.active,h.visible,h.speed,h.time=implement,context,active,visible,speed,self.clock
end
function M:observeWork(implement,pass)
    if not self:enabled() or not self:isOwn(implement) or (pass.eligibleCells or 0)<=0 or (pass.coverage or 0)<=0 then return end
    local w=self.work or {}; self.work=w
    w.implement,w.pass,w.time=implement,pass,self.clock
end
function M:observeHarvest(implement,area)
    if self:enabled() and self:isOwn(implement) and (area or 0)>0 then
        self:signal("yield",45,vehicle(),2500); self:signal("rotationPlan",40,vehicle(),2500)
    end
end
function M:observeStone(implement)
    if self:enabled() and self:isOwn(implement) then self:offer("stones",95,vehicle()) end
end
function M:observeAnalysis(s)
    if not self:enabled() or not s or not s.valid then return end
    if not self:isGameplayViewActive() then
        self.snapshot=s; self.snapshotActor=vehicle(); return
    end
    -- User-requested history is a reading opportunity, not a new growth event.
    self:offer("analysis",30,nil)
    if (s.growthSteps or 0)>0 then
        self:offer("yield",27,vehicle()); self:offer("waterGrowth",25,vehicle())
        self:offer("rotationPlan",24,vehicle())
    end
    if s.coverCrop then self:offer("cover",24,nil) end
    if (s.rotationDiverseShare or 0)>0 then self:offer("rotation",23,nil) end
    if TerraLogicMain:isPrecisionFarmingActive() then self:offer("pf",22,nil) end
    self:offer("resilience",21,nil); self:offer("weather",20,nil); self:offer("bonus",19,nil)
    if (s.biologicalContinuity or 0)>.5 then self:offer("recovery",18,nil) end
    self:offer("systems",17,nil); self:offer("options",16,nil)
    if TerraLogicMain:isPrecisionFarmingActive() and self.seen.tramlines then self:offer("pfLanes",26,nil) end
end
function M:observeRecovery(job)
    -- Recovery jobs can cover another field and are server-only. Teach recovery
    -- from the local field analysis instead of attributing a global job to it.
end
function M:evaluate()
    local actor=vehicle(); local h=self.hud
    if h and self.clock-h.time<1000 and self:isOwn(h.implement) and h.implement.spec_terraLogic then
        if h.visible then self:signal("speedHud",90,actor,0) end
        -- Sustained positive context exceeds the HUD's 1.2s exit grace.
        if h.active and h.context and (h.speed or 0)>1 then
            self:signal("firstMap",76,actor,5000)
            if self.seen.speedHud then self:signal("cruise",85,actor,5000) end
            self:signal("traffic",80,actor,5000)
            local c=h.context
            if math.max(c.speedLoss or 0,c.speedDropoutFraction or 0)>.08 then self:signal("overspeed",94,actor,5000) end
            if math.max(c.conditionLoss or 0,c.conditionDropoutFraction or 0)>.05 then self:signal("condition",93,actor) end
            if math.max(c.rainLoss or 0,c.rainDropoutFraction or 0)>.05 then self:signal("rainApplication",92,actor) end
            local class=h.implement.spec_terraLogic.implementClassKey
            local soil=c.soilContext and c.soilContext.context
            -- Local HUD context is already available on multiplayer clients.
            if class=="plow" or class=="spader" then self:signal("plow",55,actor)
            elseif class=="cultivator" or class=="shallowCultivator" or class=="discHarrow" or class=="powerHarrow" then
                self:signal("seedbed",55,actor); self:signal("tilth",48,actor)
            end
            self:signal("analysis",49,actor)
            if class=="plow" or class=="subsoiler" or class=="cultivator" or class=="shallowCultivator"
                or class=="discHarrow" or class=="powerHarrow" or class=="spader" then self:signal("draft",38,actor) end
            if (c.frostSeverity or (soil and soil.frostSeverity) or 0)>.1 then
                self:signal("frost",92,actor)
                if self.seen.frost then self:signal("thaw",41,actor) end
            end
            if class=="directDrill" or class=="precisionDirectDrill" then self:signal("directDrill",52,actor)
            elseif class=="sowingMachine" or class=="precisionPlanter" then self:signal("seeding",51,actor)
            elseif class=="roller" then self:signal("roller",52,actor) end
            if self.seen.traffic then
                if class=="liquidSprayer" or class=="fertilizerSpreader"
                    or class=="slurrySpreader" or class=="manureSpreader" then self:signal("tramlines",60,actor) end
                self:signal("compaction",40,actor); self:signal("tires",39,actor)
            end
        end
    end
    local w=self.work
    if w and self.clock-w.time<1200 and self:isOwn(w.implement) then
        local p=w.pass
        if (p.changedCells or 0)>0 then self:signal("changedSoil",65,actor,2500) end
        self:signal("traffic",80,actor,5000)
        self:signal("firstMap",76,actor,5000)
        self:signal("draft",38,actor)
        if self.seen.speedHud then self:signal("cruise",85,actor,5000) end
        if (p.frostDraftMultiplier or 1)>1.08 and (p.frostSeverity or 0)>.1 then self:signal("frost",92,actor) end
        if (p.moistureSoilEffectiveness or 1)<.9 then self:signal("moistureWork",70,actor) end
        if (p.moisture or 0)>.75 and (p.frostSeverity or 0)<.01 then self:signal("wetTraffic",69,actor) end
        if p.classKey=="plow" or p.classKey=="spader" then
            self:signal("plow",55,actor); self:signal("continuity",50,actor)
        elseif p.classKey=="cultivator" or p.classKey=="shallowCultivator" or p.classKey=="discHarrow" or p.classKey=="powerHarrow" then
            self:signal("seedbed",55,actor); self:signal("tilth",48,actor)
        elseif p.classKey=="roller" then self:signal("roller",55,actor) end
    end
    -- Existing wheel diagnostics, not another wheel/pressure calculation.
    local wm=TerraLogicWheelCompactionManager
    local d=wm and wm.diagnostics and wm.diagnostics[actor]
    local missionNow=g_currentMission and g_currentMission.time or 0
    local currentMass=nil
    if d and missionNow-(d.time or -100000)>-1 and missionNow-(d.time or -100000)<1500
        and (d.fieldContactCount or 0)>0 and (d.vehicleMass or 0)>0 then
        currentMass=d.vehicleMass
    elseif actor and actor.getTotalMass and h and self.clock-h.time<1000 and h.active and h.context then
        -- Clients need no wheel diagnostic stream to observe their own load.
        currentMass=tonumber(actor:getTotalMass(true))
        if currentMass and currentMass>1000 then currentMass=currentMass/1000 end
    end
    if currentMass and currentMass>0 then
        if self.massReference==nil then self.massReference=currentMass end
        if math.abs(currentMass-self.massReference)>math.max(1,self.massReference*.20) then
            self:signal("payload",46,actor)
        end
    end
    local mode=TerraLogicSettings.vehicleSoilMapMode or 0
    if mode>0 then
        self:signal("firstMap",75,actor,0)
        if self.seen.firstMap then self:signal("mapControls",73,actor,0) end
        if mode==4 and self.seen.mapControls then self:signal("evenness",35,actor) end
        if mode==5 and self.seen.mapControls then self:signal("resilience",35,actor) end
    end
end
function M:update(dt)
    if not self.loaded or not g_localPlayer then return end
    self.clock=self.clock+math.max(0,dt or 0)
    if self.cursorRestorePending and self:isGameplayViewActive() then self:releaseCursor() end
    local actor=vehicle()
    if actor~=self.actor then
        self.actor=actor; self.snapshot=nil; self.pending=nil; self.evidence={}; self.work=nil; self.hud=nil
        self.lastPosition=nil; self.still=0; self.massReference=nil; self:releaseCursor()
    end
    if self.cursorOwned then self:ensureCameraGuards() end
    if not self:isGameplayViewActive() then self.wasInMenu=true; self.still=0; return end
    if self.wasInMenu then
        self:releaseCursor(); self.wasInMenu=false; self.layout=nil
        local snapshot=self.snapshot; self.snapshot=nil
        if snapshot and self.snapshotActor==actor then self:observeAnalysis(snapshot) end
    end
    if self.manualRequested then self.manualRequested=false; self:openLibrary() end
    if self.restartRequested then self.restartRequested=false; self:open("welcome",false) end
    if self.clock<self.nextCheck then return end
    self.nextCheck=self.clock+500
    local node=actor and actor.rootNode or g_localPlayer.rootNode
    local x,z
    if actor==nil and g_localPlayer.getPosition then
        local unused; x,unused,z=g_localPlayer:getPosition()
    elseif node and getWorldTranslation then
        local unused; x,unused,z=getWorldTranslation(node)
    end
    if x~=nil and z~=nil then
        local p=self.lastPosition
        if p and (x-p.x)^2+(z-p.z)^2<.0025 then self.still=self.still+500 else self.still=0 end
        self.lastPosition={x=x,z=z}
    else self.still=0 end
    if not self:enabled() or self.current or self.libraryIndex then return end
    if self.pending and (self.clock>self.pending.expires or self.pending.actor and self.pending.actor~=actor) then self.pending=nil end
    if self.clock<self.cooldown then return end
    if not self.displayed.welcome and TerraLogicSettings.tutorialMode~="context" then
        if self.clock>=5000 then self:open("welcome",false) end
        return
    end
    -- One native point query while this lesson is still relevant; no field scan.
    -- Walking onto a field is enough. Vehicle traffic requires actual work below.
    if actor==nil and not self.seen.firstMap and (self.snoozed.firstMap or 0)<=self.clock
        and x~=nil and z~=nil and FSDensityMapUtil and FSDensityMapUtil.getIsFieldAtWorldPos
        and FSDensityMapUtil.getIsFieldAtWorldPos(x,z)==true then
        self:signal("firstMap",89,nil,1000)
    end
    self:evaluate()
    -- These explain the UI at first use; nonmodal cards can safely appear moving.
    local immediate=self.pending and (self.pending.id=="firstMap" or self.pending.id=="speedHud"
        or self.pending.id=="mapControls" or self.pending.id=="cruise" or self.pending.id=="traffic")
    if self.pending and (immediate or self.still>=3000) then self:open(self.pending.id,false) end
end
-- Layout is rebuilt on topic/resolution/language changes, never each frame.
function M:bindingText(action)
    if g_inputDisplayManager and g_inputDisplayManager.getControllerSymbolOverlays then
        local help=g_inputDisplayManager:getControllerSymbolOverlays(action,"","",false)
        if help and type(help.keys)=="table" then
            local keys={}; for _,key in ipairs(help.keys) do if type(key)=="string" then keys[#keys+1]=key end end
            if #keys>0 then return table.concat(keys," + ") end
        end
    end
    return tr("siehe Steuerungshilfe / Belegung","see input help / bindings")
end
function M:buildLayout()
    if not self.current then return end
    local scale=tostring(g_screenWidth)..":"..tostring(g_screenHeight)..":"..tostring(g_languageShort)
    if self.layout and self.layout.scale==scale then return end
    local content=self.current[g_languageShort=="de" and "de" or "en"]
    local size=.015
    local lineHeight=.020
    local maxLines=12
    local pages={}
    for section in (content.text.."\f"):gmatch("(.-)\f") do
        local page={}; pages[#pages+1]=page
        for paragraph in (section.."\n"):gmatch("(.-)\n") do
            local line=""
            for word in paragraph:gmatch("%S+") do
                local test=line=="" and word or line.." "..word
                if line~="" and getTextWidth(size,test)>.315 then
                    if #page>=maxLines then page={}; pages[#pages+1]=page end
                    page[#page+1]=line; line=word
                else line=test end
            end
            if line~="" or #page>0 and #page<maxLines then
                if #page>=maxLines then page={}; pages[#pages+1]=page end
                page[#page+1]=line
            end
        end
    end
    self.pages[self.current.id]=math.min(self.pages[self.current.id] or 1,#pages)
    self.layout={scale=scale,pages=pages,title=content.title,size=size,lineHeight=lineHeight,bindings={}}
    local actions=self.current.actions or {}
    for _,action in ipairs(actions) do
        local name=g_i18n and g_i18n:getText("input_"..action) or action
        self.layout.bindings[#self.layout.bindings+1]=name..": "..self:bindingText(action)
    end
end
-- Pixel-aligned, non-overlapping strips prevent alpha seams at the rounded cap.
function M:drawBackground(x,y,w,h)
    local sw,sh=g_screenWidth or 1920,g_screenHeight or 1080
    local left=math.floor(x*sw+.5)
    local bottom=math.floor(y*sh+.5)
    local width=math.floor((x+w)*sw+.5)-left
    local height=math.floor((y+h)*sh+.5)-bottom
    local radius=math.max(4,math.floor(8*sh/1080+.5))
    local key=sw..":"..sh
    if not self.cornerRows or self.cornerRows.key~=key then
        local rows={key=key,radius=radius}
        for i=0,radius-1 do
            local dy=radius-i-.5
            rows[#rows+1]=math.floor(radius-math.sqrt(radius*radius-dy*dy)+.5)
        end
        self.cornerRows=rows
    end
    local bg=HUD and HUD.COLOR and HUD.COLOR.BACKGROUND or {.01,.01,.01,1}
    local function rect(px,py,pw,ph)
        -- Keep the native colour but use consistent opacity for readable text.
        drawFilledRect(px/sw,py/sh,pw/sw,ph/sh,bg[1],bg[2],bg[3],self.libraryIndex and .94 or .82)
    end
    rect(left,bottom+radius,width,height-2*radius)
    for i,inset in ipairs(self.cornerRows) do
        rect(left+inset,bottom+i-1,width-2*inset,1)
        rect(left+inset,bottom+height-i,width-2*inset,1)
    end
end
function M:drawButton(label,x,y,w,h,action,arg,leftAligned,status)
    local hovered=g_inputBinding and g_inputBinding:getShowMouseCursor()
        and self.mouseX and self.mouseY and self.mouseX>=x and self.mouseX<=x+w
        and self.mouseY>=y and self.mouseY<=y+h
    if hovered then
        local active=HUD and HUD.COLOR and HUD.COLOR.ACTIVE or {.52,.72,0,1}
        drawFilledRect(x,y,w,h,active[1],active[2],active[3],.9)
    else
        -- Dark, legible controls independent of the scenery behind the card.
        drawFilledRect(x,y,w,h,.025,.030,.033,.82)
    end
    setTextColor(1,1,1,1)
    local available=w-.009-(status and .035 or 0)
    local size=math.min(.014,.014*available/math.max(getTextWidth(.014,label),available))
    local textWidth=getTextWidth(size,label)
    renderText(leftAligned and x+.005 or x+(w-textWidth)*.5,y+(h-size)*.5+size*.15,size,label)
    if status then
        setTextColor(.7,.78,.65,1)
        renderText(x+w-.032,y+(h-.011)*.5+.00165,.011,status)
    end
    self.buttons[#self.buttons+1]={x=x,y=y,w=w,h=h,action=action,arg=arg}
end
-- Normalized coordinates survive resolution changes. Keep at least 20% of
-- the width visible and the full title height on screen. The extra horizontal
-- reserve leaves a usable drag target even beside the close button.
function M:getWindowRect()
    local w,h=.345,.445
    local x,y=tonumber(self.windowX),tonumber(self.windowY)
    if not x or x~=x then x=.635 end
    if not y or y~=y then y=.395 end
    local visible=math.max(w*.2,.12)
    x=math.clamp(x,visible-w,1-visible)
    y=math.clamp(y,.008,1-h-.008)
    self.windowX,self.windowY=x,y
    return x,y,w,h
end
function M:resetPosition()
    self.drag=nil
    self.windowX,self.windowY=nil,nil
    self.buttons=nil
    self:save()
end
function M:draw()
    if not self:isCardVisible() or not drawFilledRect or not renderText or not getTextWidth then return end
    local x,y,w,h=self:getWindowRect()
    self:drawBackground(x,y,w,h)
    self.buttons={}
    setTextAlignment(RenderText.ALIGN_LEFT); setTextBold(false); setTextColor(.78,.78,.78,1)
    local groups=g_languageShort=="de" and {"GRUNDLAGEN","FELDARBEIT","WETTER","BODENLEBEN","ERTRAG UND HILFE"}
        or {"BASICS","FIELDWORK","WEATHER","SOIL LIFE","YIELD AND HELP"}
    if self.libraryIndex then
        renderText(x+.015,y+h-.03,.014,tr("TERRALOGIC · THEMEN","TERRALOGIC · TOPICS"))
        setTextColor(1,1,1,1); setTextBold(true)
        renderText(x+.015,y+h-.062,.02,tr("Was möchtest du nachlesen?","What would you like to learn?"))
        setTextBold(false)
        -- Two-column index: groups on the left, directly selectable topics on the right.
        for i,name in ipairs(groups) do
            self:drawButton(name,
                x+.012,y+h-.111-(i-1)*.037,.101,.032,"selectGroup",i)
            if i==self.libraryGroup then
                drawFilledRect(x+.012,y+h-.111-(i-1)*.037,.002,.032,.52,.72,0,1)
            end
        end
        drawFilledRect(x+.115,y+.068,.0007,h-.155,1,1,1,.18)
        local items,read={},0
        for _,item in ipairs(TerraLogicTutorialLessons) do
            if item.group==self.libraryGroup then
                items[#items+1]=item
                if self.seen[item.id] then read=read+1 end
            end
        end
        local pages=math.max(1,math.ceil(#items/8))
        self.libraryPage=math.min(self.libraryPage or 1,pages)
        setTextColor(.8,.8,.8,1)
        renderText(x+.12,y+h-.099,.012,string.format(tr("%d von %d gelesen","%d of %d read"),read,#items))
        for row=1,8 do
            local item=items[(self.libraryPage-1)*8+row]
            if item then
                local content=item[g_languageShort=="de" and "de" or "en"]
                self:drawButton(content.title,x+.12,y+h-.137-(row-1)*.033,.213,.030,
                    "selectLesson",item.id,true,self.seen[item.id] and tr("Gelesen","Read") or "")
            end
        end
        if self.libraryPage>1 then self:drawButton(tr("Zurück","Back"),x+.12,y+.042,.065,.027,"changeLibraryPage",-1) end
        if self.libraryPage<pages then self:drawButton(tr("Weiter","Next"),x+.268,y+.042,.065,.027,"changeLibraryPage",1) end
        setTextColor(.8,.8,.8,1)
        renderText(x+.213,y+.050,.012,string.format("%d / %d",self.libraryPage,pages))
        setTextColor(.8,.8,.8,1)
        renderText(x+.015,y+.015,.012,tr("Rechtsklick: Maus ein/aus | X: Schließen",
            "Right-click: cursor on/off | X: close"))
    else
        self:buildLayout()
        renderText(x+.015,y+h-.03,.014,groups[self.current.group])
        setTextColor(1,1,1,1); setTextBold(true)
        renderText(x+.015,y+h-.062,math.min(.02,.02*.315/math.max(getTextWidth(.02,self.layout.title),.315)),self.layout.title)
        setTextBold(false)
        drawFilledRect(x+.01,y+h-.076,w-.02,.001,1,1,1,.22)
        local page=self.pages[self.current.id] or 1
        for i,line in ipairs(self.layout.pages[page]) do renderText(x+.015,y+h-.097-(i-1)*self.layout.lineHeight,self.layout.size,line) end
        setTextColor(.8,.8,.8,1)
        for i,line in ipairs(self.layout.bindings) do
            renderText(x+.015,y+.106-(i-1)*.016,math.min(.013,.013*.315/math.max(getTextWidth(.013,line),.315)),line)
        end
        renderText(x+.015,y+.068,.013,string.format(tr("Seite %d/%d | Rechtsklick: Maus ein/aus","Page %d/%d | Right-click: cursor on/off"),page,#self.layout.pages))
        drawFilledRect(x+.01,y+.055,w-.02,.001,1,1,1,.22)
        if self.current.id=="welcome" and page==1 and self:enabled() then
            self:drawButton(tr("Tutorials deaktivieren","Disable tutorials"),x+.012,y+.018,.145,.03,"disable")
            self:drawButton(page<#self.layout.pages and tr("Weiter","Next") or tr("Verstanden","Got it"),
                x+.164,y+.018,.078,.03,"next")
            self:drawButton(tr("Themen","Topics"),x+.249,y+.018,.083,.03,"openLibrary")
        else
            if page>1 then self:drawButton(tr("Zurück","Back"),x+.012,y+.018,.077,.03,"previous") end
            self:drawButton(page<#self.layout.pages and tr("Weiter","Next") or tr("Verstanden","Got it"),
                x+.096,y+.018,.105,.03,"next")
            self:drawButton(tr("Themen","Topics"),x+.209,y+.018,.123,.03,"openLibrary")
        end
    end
    self:drawButton("X",x+w-.032,y+h-.042,.023,.032,"close")
    setTextColor(1,1,1,1); setTextBold(false); setTextAlignment(RenderText.ALIGN_LEFT)
end
function M:mouseEvent(x,y,isDown,isUp,button)
    if not self:isCardVisible() or not Input or not g_inputBinding then
        if self.drag then self.drag=nil; self:save() end
        self.rightGesture=nil
        return -- No action event, cursor change or crane-input interception.
    end
    self.mouseX,self.mouseY=x,y
    if self.drag then
        if not self.cursorOwned or not g_inputBinding:getShowMouseCursor() then
            self.drag=nil; self:save(); return
        end
        self.windowX=x-self.drag.x
        self.windowY=y-self.drag.y
        self:getWindowRect()
        self.buttons=nil
        if isUp and button==Input.MOUSE_BUTTON_LEFT then
            self.drag=nil; self:save()
        end
        return
    end
    if isDown and button==Input.MOUSE_BUTTON_LEFT and self.cursorOwned
        and g_inputBinding:getShowMouseCursor() then
        local wx,wy,w,h=self:getWindowRect()
        if x>=wx and x<=wx+w-.04 and y>=wy+h-.047 and y<=wy+h then
            self.drag={x=x-wx,y=y-wy}
            return
        end
    end
    local gesture=self.rightGesture
    if gesture then
        local dx=(x-gesture.x)*(g_screenWidth or 1920)
        local dy=(y-gesture.y)*(g_screenHeight or 1080)
        if dx*dx+dy*dy>64 then gesture.dragged=true end
    end
    if button==Input.MOUSE_BUTTON_RIGHT then
        if isDown then
            self.rightGesture={x=x,y=y,time=self.clock,card=self.current}
        elseif isUp then
            self.rightGesture=nil
            if gesture and not gesture.dragged and gesture.card==self.current
                and self.clock-gesture.time<=400 then self:toggleCursor() end
        end
        return
    end
    if not isUp or button~=Input.MOUSE_BUTTON_LEFT or not g_inputBinding:getShowMouseCursor() then return end
    for _,b in ipairs(self.buttons or {}) do
        if x>=b.x and x<=b.x+b.w and y>=b.y and y<=b.y+b.h then self[b.action](self,b.arg); return end
    end
end
