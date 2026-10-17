-- Shared geometry makes the two layers recognisable even without colour.
TerraLogicSoilHud = {}
function TerraLogicSoilHud:draw(x,y,alpha,top,deep,scale,textSize,rect)
    local function text(key,fallback)
        return g_i18n and g_i18n:hasText(key) and g_i18n:getText(key) or fallback
    end
    local labels={text('terraLogic_hudSoilLow','Low'),text('terraLogic_hudSoilModerate','Regular'),text('terraLogic_hudSoilHigh','High'),text('terraLogic_hudSoilSevere','Severe')}
    local c=TerraLogicDisplay.COLORS
    local colors={c.green,c.yellow,c.orange,c.red}
    local function icon(cx,level,isDeep)
        local c=colors[level] or {0.65,0.68,0.70}
        local function box(px,py,w,h)
            local dx,dy=scale(px,py);local sw,sh=scale(w,h)
            rect(x+dx,y+dy,sw,sh,c[1],c[2],c[3],alpha)
        end
        -- Identical soil: three lines, two empty layers.
        for _,py in ipairs({20,27,34}) do box(cx-10,py,24,1) end
        local arrowY=isDeep and 23 or 30
        -- Same compact, filled triangle in each layer.
        for i=0,2 do box(cx-15+i,arrowY-2+i,1,5-2*i) end
        -- Wheel silhouette / axle with two wheel silhouettes.
        if isDeep then
            box(cx-8,36,4,9);box(cx+8,36,4,9);box(cx-4,40,12,2)
        else
            for row=-4,4 do
                local half=math.sqrt(4.5*4.5-row*row)
                box(cx+1-half,40+row,half*2,1)
            end
        end
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
