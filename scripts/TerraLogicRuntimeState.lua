-- Records temporary engine state, not protected calls. Normal work restores
-- it synchronously. If an unexpected error aborts a callback, the next update
-- restores pending state without swallowing the original error from the log.
TerraLogicRuntimeState = { pending = {} }

function TerraLogicRuntimeState:rememberFunction(owner, key, original)
    local entry = { owner = owner, key = key, original = original, temporary = owner[key] }
    self.serial = (self.serial or 0) + 1
    entry.serial = self.serial
    self.pending[entry] = true
    return entry
end

function TerraLogicRuntimeState:rememberDensityMode(mapId)
    local entry = { mapId = mapId }
    self.serial = (self.serial or 0) + 1
    entry.serial = self.serial
    self.pending[entry] = true
    return entry
end

function TerraLogicRuntimeState:release(entry)
    if entry ~= nil then
        self.pending[entry] = nil
    end
end

function TerraLogicRuntimeState:restorePending()
    if next(self.pending) == nil then
        return
    end
    local entries = {}
    for entry in pairs(self.pending) do
        entries[#entries + 1] = entry
    end
    table.sort(entries, function(a, b)
        return a.serial > b.serial
    end)
    for _, entry in ipairs(entries) do
        -- A stale engine handle must not retry forever on every frame. Leave
        -- an unexpected restore error visible, but retire this entry first.
        self.pending[entry] = nil
        if entry.owner ~= nil then
            -- Respect a newer wrapper installed by another mod.
            if entry.owner[entry.key] == entry.temporary then
                entry.owner[entry.key] = entry.original
            end
        elseif type(setDensityNewTypeIndexMode) == "function" then
            setDensityNewTypeIndexMode(entry.mapId, 0)
        end
    end
    Logging.warning(
        "[FS25_TerraLogic] Restored temporary work-area state after an interrupted callback; check the preceding error in log.txt."
    )
end
