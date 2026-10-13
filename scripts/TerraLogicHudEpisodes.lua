-- Presentation only. Episodes survive turning, lifting tools and vehicle switches.
TerraLogicWarningEpisodes = {CONFIRM_MS=2000, CLEAR_MS=30000, GRACE_MS=1200}
local E = TerraLogicWarningEpisodes
function E:get(owner)
    self.vehicles = self.vehicles or setmetatable({}, {__mode="k"})
    if owner == nil then return {} end
    local s=self.vehicles[owner]
    if not s then s={};self.vehicles[owner]=s end
    return s
end
function E:eligible(owner,w)
    if w.oneShot or w.severity=="critical" then return true end
    local s=self:get(w.owner or owner)[w.id]
    return not s or not s.shown
end
function E:shown(owner,w)
    if w.oneShot or w.severity=="critical" then return end
    local s=self:get(w.owner or owner)[w.id]
    if s then s.shown=true end
end
-- Absence counts only while the corresponding system is actively observed.
function E:observe(owner,candidates,now,valid)
    local states=self:get(owner)
    for id,s in pairs(states) do
        if now-(s.updated or now)>2500 then s.clearSince=nil;s.first=nil;s.confirmed=nil end
        local w=candidates[id]
        s.updated=now
        if w then
            s.clearSince=nil
            if not s.first then s.first=now end
            s.last=now;s.warning=w
        else
            s.first=nil
            if now-s.last>self.GRACE_MS then s.confirmed=nil end
            if valid[id]==true then
                s.clearSince=s.clearSince or now
                if now-s.clearSince>=self.CLEAR_MS then s.shown=false end
            else s.clearSince=nil end
        end
    end
    for id,w in pairs(candidates) do
        if not states[id] then states[id]={first=now,last=now,updated=now,warning=w} end
    end
end
function E:select(main,vehicle,implement,candidates,now,qualityActive,mechanicalActive,traffic)
    local root=vehicle and vehicle.getRootVehicle and vehicle:getRootVehicle() or vehicle
    local toolCandidates,trafficCandidates={},{}
    local toolValid,trafficValid={},{}
    for id in pairs(self:get(implement)) do
        toolValid[id]=id=="mechanicalLoad" and mechanicalActive or
            (id~="mechanicalLoad" and qualityActive) or false
    end
    traffic=traffic or {}
    trafficValid.trafficPressure=traffic.surfaceKnown==true
    trafficValid.trafficAxle=traffic.deepKnown==true
    trafficValid.trafficWet=traffic.surfaceKnown==true and traffic.deepKnown==true
    for id,w in pairs(candidates) do
        w.owner=w.traffic and root or implement or root
        if w.traffic then trafficCandidates[id]=w else toolCandidates[id]=w end
    end
    if implement==root then
        for id,w in pairs(trafficCandidates) do toolCandidates[id]=w end
        for id,v in pairs(trafficValid) do if id:sub(1,7)=="traffic" then toolValid[id]=v end end
        self:observe(root,toolCandidates,now,toolValid)
    else
        self:observe(implement,toolCandidates,now,toolValid)
        self:observe(root,trafficCandidates,now,trafficValid)
    end
    local red,yellow={},{}
    local seen={}
    for _,owner in pairs({tool=implement,train=root}) do
        if owner and not seen[owner] then
            seen[owner]=true
            for id,s in pairs(self:get(owner)) do
                local w=s.warning
                local present=candidates[id] and candidates[id].owner==owner
                local confirmed=w.oneShot or (s.first and now-s.first>=self.CONFIRM_MS)
                local holdingRed=w.severity=="critical" and not w.oneShot and s.confirmed and now-s.last<=self.GRACE_MS
                if present and confirmed then s.confirmed=true end
                if (present and confirmed or holdingRed) and (not w.oneShot or now<(w.expiresAt or 0)) then
                    if w.severity=="critical" then red[#red+1]=w
                    elseif self:eligible(owner,w) then yellow[#yellow+1]=w end
                end
            end
        end
    end
    local function order(a,b)
        if a.priority~=b.priority then return a.priority>b.priority end
        return a.id<b.id
    end
    table.sort(red,order);table.sort(yellow,order)
    local slot=math.max(1000,TerraLogicSettings and TerraLogicSettings.getWarningDisplayDurationMs
        and TerraLogicSettings:getWarningDisplayDurationMs() or 8000)
    local current=main.workHudWarningCurrent
    local expired=current and now-(main.workHudWarningSlotStartedAt or now)>=slot
    local interrupted=current and #red>0 and current.severity~="critical"
    local invalid=current and (current.owner~=implement and current.owner~=root)
    if current and current.severity=="critical" and not current.oneShot then
        local found=false
        for _,w in ipairs(red) do if w.id==current.id and w.owner==current.owner then found=true end end
        invalid=invalid or not found
    end
    if current and (expired or interrupted or invalid) then
        -- Only consume yellow/event cards after a complete reading slot.
        if expired then
            if current.oneShot then
                if main.workHudEventWarnings then main.workHudEventWarnings[current.id]=nil end
                self:get(current.owner)[current.id]=nil
                for i=#red,1,-1 do if red[i].id==current.id then table.remove(red,i) end end
                for i=#yellow,1,-1 do if yellow[i].id==current.id then table.remove(yellow,i) end end
            else self:shown(current.owner,current) end
        end
        main.workHudPreviousWarningId=current.id
        main.workHudWarningCurrent=nil;current=nil
    end
    if not current then
        local list=#red>0 and red or yellow
        local chosen
        local start=0
        if #red>0 then
            for i,w in ipairs(list) do
                if w.id==main.workHudPreviousWarningId then start=i;break end
            end
        end
        for offset=1,#list do
            local w=list[(start+offset-1)%#list+1]
            if self:eligible(w.owner,w) then
                chosen=w;break
            end
        end
        if chosen then
            current={}
            for k,v in pairs(chosen) do current[k]=v end
            main.workHudWarningCurrent=current;main.workHudWarningSlotStartedAt=now
        end
    end
    if not current then return nil,0,0 end
    return current,math.max(1,#red>0 and #red or #yellow),1
end
