-- Presentation-only memory. No map queries, savegame data or network traffic.
TerraLogicWarningEpisodes = {}
local Episodes = TerraLogicWarningEpisodes

function Episodes:get(vehicle)
    self.vehicles = self.vehicles or setmetatable({}, {__mode="k"})
    if vehicle == nil then return {} end
    local states = self.vehicles[vehicle]
    if states == nil then states = {}; self.vehicles[vehicle] = states end
    return states
end

function Episodes:rank(warning)
    return tonumber(warning.repeatRank) or tonumber(warning.priority) or 1
end

function Episodes:update(vehicle, candidates, time, trafficKnown)
    local states = self:get(vehicle)
    for id, state in pairs(states) do
        -- Hidden HUDs, pauses and stale network replies are not an all-clear.
        if time-(state.updated or time) > 2500 then state.clearSince = nil end
        state.updated = time
        if candidates[id] ~= nil then
            state.clearSince = nil
        elseif id ~= "trafficCompaction" or trafficKnown then
            state.clearSince = state.clearSince or time
            if time-state.clearSince >= 10000 then state.shownRank = 0 end
        else state.clearSince = nil end
    end
end

function Episodes:eligible(vehicle, warning)
    if warning.oneShot then return true end
    local state = self:get(vehicle)[warning.id]
    return state == nil or (state.shownRank or 0) < self:rank(warning)
end

function Episodes:shown(vehicle, warning, time)
    if warning.oneShot then return end
    local states = self:get(vehicle)
    local state = states[warning.id] or {}
    states[warning.id] = state
    state.shownRank = math.max(state.shownRank or 0, self:rank(warning))
    state.updated, state.clearSince = time, nil
end
