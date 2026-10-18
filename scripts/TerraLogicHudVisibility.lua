-- Read native display state only; never modify input contexts or game HUDs.
TerraLogicHudVisibility = {}
function TerraLogicHudVisibility:update(main,now,scale)
    local hud=g_currentMission and g_currentMission.hud
    local occupied=false
    local _, floor=scale(0,103)
    if hud then
        for _,display in pairs(hud) do
            if type(display)=='table' and type(display.getVisible)=='function' then
                local context=ContextActionDisplay~=nil
                    and display.setContext==ContextActionDisplay.setContext
                    and display.resetContext==ContextActionDisplay.resetContext
                local message=display==hud.ingameMessage
                if (context or message) and display:getVisible() then
                    occupied=true
                    local _, y=scale(0,42)
                    if display.getPosition then local px,py=display:getPosition();y=py or y end
                    local _, height=scale(0,90)
                    if message then
                        height=display.getHeight and display:getHeight() or 0.25
                        if height<=0 then height=0.25 end
                    elseif display.iconOverlay then
                        height=math.max(height,(display.iconOverlay.height or 0)
                            + (display.titleTextSize or 0) + (display.textSize or 0))
                    end
                    local _, gap=scale(0,12)
                    floor=math.max(floor,y+height+gap)
                end
            end
        end
    end
    if occupied then main.workHudObstructedUntil=now+500;main.workHudWarningFloor=floor end
    main.workHudObstructed=occupied or now<(main.workHudObstructedUntil or 0)
    local elapsed=math.max(0,now-(main.workHudVisibilityTime or now))
    -- Preserve yellow reading time and queued yellow event lifetimes while hidden.
    if main.workHudObstructed or main.workHudWasObstructed then
        local w=main.workHudWarningCurrent
        if w and w.severity~='critical' and main.workHudWarningSlotStartedAt then
            main.workHudWarningSlotStartedAt=main.workHudWarningSlotStartedAt+elapsed
        end
        for _,event in pairs(main.workHudEventWarnings or {}) do
            if event.severity~='critical' and event.expiresAt then event.expiresAt=event.expiresAt+elapsed end
        end
    end
    main.workHudVisibilityTime=now
    main.workHudWasObstructed=main.workHudObstructed
end

function TerraLogicHudVisibility:soilState(main,now,top,deep)
    local valid=top>0 or deep>0
    if valid then
        main.soilHudValidSince=main.soilHudValidSince or now
        main.soilHudLastSampleAt=now
        main.soilHudLastTop,main.soilHudLastDeep=top,deep
        if now-main.soilHudValidSince>=1000 then main.soilHudQualified=true end
    else
        main.soilHudValidSince=nil
        if now-(main.soilHudLastSampleAt or -10000)>2000 then
            main.soilHudQualified=false
            -- Always-visible cards must not retain expired soil readings.
            main.soilHudLastTop,main.soilHudLastDeep=0,0
        end
        top,deep=main.soilHudLastTop or 0,main.soilHudLastDeep or 0
    end
    return main.soilHudQualified==true,top,deep
end
