-- DDS masks preserve the original 32 x 32 design-space icon geometry.
TerraLogicSoilHud = {MOD_DIR = g_currentModDirectory or ""}
function TerraLogicSoilHud:loadIcons()
    if self.surfaceIcon == nil then
        self.surfaceIcon = Overlay.new(self.MOD_DIR .. "gui/compactionSurface.dds", 0, 0, 0, 0)
    end
    if self.deepIcon == nil then
        self.deepIcon = Overlay.new(self.MOD_DIR .. "gui/compactionDeep.dds", 0, 0, 0, 0)
    end
end
function TerraLogicSoilHud:delete()
    if self.surfaceIcon ~= nil then
        self.surfaceIcon:delete()
        self.surfaceIcon = nil
    end
    if self.deepIcon ~= nil then
        self.deepIcon:delete()
        self.deepIcon = nil
    end
end
-- Keep the rect argument for existing callers; icons no longer use it.
function TerraLogicSoilHud:draw(x,y,alpha,top,deep,scale,textSize,rect)
    self:loadIcons()
    local function text(key,fallback)
        return g_i18n and g_i18n:hasText(key) and g_i18n:getText(key) or fallback
    end
    local labels={text('terraLogic_hudSoilLow','Low'),text('terraLogic_hudSoilModerate','Regular'),text('terraLogic_hudSoilHigh','High'),text('terraLogic_hudSoilSevere','Severe')}
    local c=TerraLogicDisplay.COLORS
    local colors={c.green,c.yellow,c.orange,c.red}
    local function icon(cx,level,isDeep)
        local c=colors[level] or {0.65,0.68,0.70}
        -- Transparent padding maps design x=-16..16 and y=18..50.
        -- Visible geometry retains the old bounds, including wheel/axle height.
        local dx,dy=scale(cx-16,18)
        local width,height=scale(32,32)
        local overlay=isDeep and self.deepIcon or self.surfaceIcon
        overlay:setPosition(x+dx,y+dy)
        overlay:setDimension(width,height)
        overlay:setColor(c[1],c[2],c[3],alpha)
        overlay:render()
        local label=labels[level] or '-'
        local maxWidth=scale(46,0)
        local font=textSize
        if getTextWidth then font=math.min(font,font*maxWidth/math.max(getTextWidth(font,label),0.0001)) end
        local dx,dy=scale(cx,7)
        setTextAlignment(RenderText.ALIGN_CENTER);setTextBold(false)
        setTextColor(c[1],c[2],c[3],alpha)
        renderText(x+dx,y+dy,font,label)
    end
    icon(380,top,false);icon(431,deep,true)
    setTextAlignment(RenderText.ALIGN_LEFT);setTextBold(false);setTextColor(1,1,1,1)
end
