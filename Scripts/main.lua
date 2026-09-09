-- IntegratedStorage v1.0 - Palworld 1.0.4 (UE4SS/Lua)
-- Single-player edition
-- Original concept/code: Sarfflow
--
-- Verified behavior:
--   * Same-guild bases share ordinary chest materials.
--   * Crafting can read and consume cross-base materials.
--   * Building can read and consume cross-base materials.
--   * Shared helper stays active for the whole loaded world.
--   * Craft temporarily disables BaseCamp foreign edges to avoid duplicate paths.
--   * Map changes clean up injected helper containers.
--
-- Maintenance tip after a future Palworld update:
--   Set VERBOSE = true and inspect [IntegratedStorage] lines in UE4SS.log.

----------------------------------------------------------------
-- CONFIG
----------------------------------------------------------------

local CHEST_CLASS = "PalMapObjectItemChestModel"

local DRIVER_MS = 1000
local INIT_STABLE = 2
local INIT_MAX = 6
local INSURANCE_TICKS = 600 -- 10 minutes

local VERBOSE = false

----------------------------------------------------------------
-- STATE
----------------------------------------------------------------

-- guilds[guildKey] = {
--   storages    = { [storageFullName] = storageObject },
--   storageCamp = { [storageFullName] = campFullName },
--   models      = { [modelFullName] = chestObject },
--   modelCamp   = { [modelFullName] = campFullName },
-- }
local guilds = {}

local injecting = false
local initDone = false
local bootScans = 0
local stableStreak = 0
local lastSig = -1
local steadyTick = 0

local dirty = false
local dirtyReason = nil

local registeredHooks = {}

-- Persistent player helper union used by both Craft and Build.
local pool = {
    active = false,
    helper = nil,
    injectedNames = {},
}

-- During Craft only, BaseCamp foreign edges are temporarily removed.
local craftActive = false

----------------------------------------------------------------
-- LOG / SAFE HELPERS
----------------------------------------------------------------

local function log(fmt, ...)
    print("[IntegratedStorage] " .. string.format(fmt, ...))
end

local function debugLog(fmt, ...)
    if VERBOSE then
        log(fmt, ...)
    end
end

local function valid(o)
    if not o then return false end
    local ok, v = pcall(function() return o:IsValid() end)
    return ok and v
end

local function unwrap(p)
    if p == nil or type(p) ~= "userdata" then return p end

    local okGet, inner = pcall(function() return p:get() end)
    if okGet and inner ~= nil then
        return inner
    end

    local okValid, isValid = pcall(function() return p:IsValid() end)
    if okValid and isValid then
        return p
    end

    return nil
end

local function fullName(o)
    if not o then return nil end
    local ok, n = pcall(function() return o:GetFullName() end)
    return ok and n or nil
end

local function guildKey(camp)
    if not valid(camp) then return nil end

    local ok, g = pcall(function()
        return camp:GetGroupIdBelongTo()
    end)

    if not ok or type(g) ~= "table" then
        return nil
    end

    return string.format(
        "%s_%s_%s_%s",
        tostring(g.A), tostring(g.B), tostring(g.C), tostring(g.D)
    )
end

local function campKey(camp)
    return fullName(camp)
end

local function modelCamp(model)
    if not valid(model) then return nil end

    local ok, camp = pcall(function()
        return model:GetBaseCampModelBelongTo()
    end)

    if not ok or not valid(camp) then
        return nil
    end

    return camp
end

local function storageCamp(storage)
    if not valid(storage) then return nil end

    local ok, camp = pcall(function()
        return storage:GetOuter()
    end)

    if not ok or not valid(camp) then
        return nil
    end

    return camp
end

local function isChest(model)
    if not valid(model) then return false end

    local okClass, cls = pcall(function()
        return model:GetClass()
    end)

    if not okClass or not cls then
        return false
    end

    while valid(cls) do
        local okName, name = pcall(function()
            return cls:GetFName():ToString()
        end)

        if okName and name == CHEST_CLASS then
            return true
        end

        local okSuper, super = pcall(function()
            return cls:GetSuperStruct()
        end)

        if not okSuper then
            break
        end

        cls = super
    end

    return false
end

local function guildOf(key)
    local g = guilds[key]

    if not g then
        g = {
            storages = {},
            storageCamp = {},
            models = {},
            modelCamp = {},
        }
        guilds[key] = g
    end

    return g
end

local function markDirty(reason)
    dirty = true
    dirtyReason = reason or dirtyReason or "structure"
end

----------------------------------------------------------------
-- BASECAMP FOREIGN STORAGE GRAPH
----------------------------------------------------------------

local function callAvailable(storage, model)
    local ok, err = pcall(function()
        storage:OnAvailableConcreteModel_ServerInternal(model)
    end)

    if not ok then
        log("ERROR add foreign storage edge: %s", tostring(err))
        return false
    end

    return true
end

local function callNotAvailable(storage, model)
    local ok, err = pcall(function()
        storage:OnNotAvailableConcreteModel_ServerInternal(model)
    end)

    if not ok then
        log("ERROR remove foreign storage edge: %s", tostring(err))
        return false
    end

    return true
end

-- Never register a base's own native chest back into its own storage module.
local function isForeignEdge(g, storageName, modelName)
    local storageOwner = g.storageCamp[storageName]
    local modelOwner = g.modelCamp[modelName]

    return storageOwner ~= nil
        and modelOwner ~= nil
        and storageOwner ~= modelOwner
end

local function applyGuildEdges(g, refresh)
    local attempted = 0
    local added = 0
    local removed = 0
    local failures = 0

    injecting = true

    for sk, storage in pairs(g.storages) do
        if valid(storage) then
            for mk, model in pairs(g.models) do
                if valid(model) and isForeignEdge(g, sk, mk) then
                    attempted = attempted + 1

                    if refresh then
                        if callNotAvailable(storage, model) then
                            removed = removed + 1
                        else
                            failures = failures + 1
                        end
                    end

                    if callAvailable(storage, model) then
                        added = added + 1
                    else
                        failures = failures + 1
                    end
                end
            end
        end
    end

    injecting = false

    return attempted, added, removed, failures
end

local function removeAllForeignEdges()
    local attempted = 0
    local removed = 0

    injecting = true

    for _, g in pairs(guilds) do
        for sk, storage in pairs(g.storages) do
            if valid(storage) then
                for mk, model in pairs(g.models) do
                    if valid(model) and isForeignEdge(g, sk, mk) then
                        attempted = attempted + 1

                        if callNotAvailable(storage, model) then
                            removed = removed + 1
                        end
                    end
                end
            end
        end
    end

    injecting = false

    return attempted, removed
end

local function addAllForeignEdges()
    local attempted = 0
    local added = 0

    injecting = true

    for _, g in pairs(guilds) do
        for sk, storage in pairs(g.storages) do
            if valid(storage) then
                for mk, model in pairs(g.models) do
                    if valid(model) and isForeignEdge(g, sk, mk) then
                        attempted = attempted + 1

                        if callAvailable(storage, model) then
                            added = added + 1
                        end
                    end
                end
            end
        end
    end

    injecting = false

    return attempted, added
end

----------------------------------------------------------------
-- STORAGE EVENTS
----------------------------------------------------------------

local function onAvailable(self, model)
    if injecting then return end

    self = unwrap(self)
    model = unwrap(model)

    if not valid(self) or not valid(model) or not isChest(model) then
        return
    end

    local targetCamp = storageCamp(self)
    local sourceCamp = modelCamp(model)

    if not targetCamp or not sourceCamp then
        markDirty("available-unresolved")
        return
    end

    local targetGuild = guildKey(targetCamp)
    local sourceGuild = guildKey(sourceCamp)

    if not targetGuild or targetGuild ~= sourceGuild then
        return
    end

    local sk = fullName(self)
    local mk = fullName(model)
    local sc = campKey(targetCamp)
    local mc = campKey(sourceCamp)

    if not sk or not mk or not sc or not mc then
        markDirty("available-name")
        return
    end

    local g = guildOf(targetGuild)
    local newStorage = g.storages[sk] == nil

    g.storages[sk] = self
    g.storageCamp[sk] = sc
    g.models[mk] = model
    g.modelCamp[mk] = mc

    -- Native event is normally for the chest's own base.
    -- Propagate that chest to every other known base in the same guild.
    injecting = true

    for otherSk, otherStorage in pairs(g.storages) do
        if otherSk ~= sk
            and valid(otherStorage)
            and isForeignEdge(g, otherSk, mk)
        then
            callAvailable(otherStorage, model)
        end
    end

    -- Newly seen base module: backfill all existing foreign chests.
    if newStorage then
        for otherMk, otherModel in pairs(g.models) do
            if valid(otherModel) and isForeignEdge(g, sk, otherMk) then
                callAvailable(self, otherModel)
            end
        end
    end

    injecting = false

    -- Also refresh the persistent player helper on the next safe driver tick.
    markDirty("chest-available")
end

local function onNotAvailable(self, model)
    if injecting then return end

    self = unwrap(self)
    model = unwrap(model)

    if not valid(self) or not valid(model) or not isChest(model) then
        return
    end

    local targetCamp = storageCamp(self)
    if not targetCamp then
        markDirty("notAvailable-unresolved")
        return
    end

    local gk = guildKey(targetCamp)
    local g = gk and guilds[gk] or nil

    if not g then
        markDirty("notAvailable-noGuild")
        return
    end

    local sk = fullName(self)
    local mk = fullName(model)

    if not sk or not mk then
        markDirty("notAvailable-name")
        return
    end

    injecting = true

    for otherSk, otherStorage in pairs(g.storages) do
        if otherSk ~= sk
            and valid(otherStorage)
            and isForeignEdge(g, otherSk, mk)
        then
            callNotAvailable(otherStorage, model)
        end
    end

    injecting = false

    g.models[mk] = nil
    g.modelCamp[mk] = nil

    markDirty("chest-notAvailable")
end

----------------------------------------------------------------
-- FULL DISCOVERY / RECONCILE
----------------------------------------------------------------

local function reconcile(reason, refresh)
    if not FindFirstOf("PalItemContainerManager") then
        debugLog("scan(%s): PalItemContainerManager not ready", reason)
        return nil
    end

    local chests = FindAllOf(CHEST_CLASS)
    local storages = FindAllOf("PalBaseCampModuleItemStorage")

    if not chests or not storages then
        debugLog(
            "scan(%s): objects not ready (chests=%s storages=%s)",
            reason,
            tostring(chests ~= nil),
            tostring(storages ~= nil)
        )
        return nil
    end

    local fresh = {}

    local function freshGuild(key)
        local g = fresh[key]

        if not g then
            g = {
                storages = {},
                storageCamp = {},
                models = {},
                modelCamp = {},
            }
            fresh[key] = g
        end

        return g
    end

    local chestCount = 0
    local storageCount = 0
    local skippedChest = 0
    local skippedStorage = 0

    for _, chest in pairs(chests) do
        if valid(chest) and isChest(chest) then
            local camp = modelCamp(chest)
            local gk = camp and guildKey(camp) or nil
            local mk = fullName(chest)
            local ck = camp and campKey(camp) or nil

            if gk and mk and ck then
                local g = freshGuild(gk)
                g.models[mk] = chest
                g.modelCamp[mk] = ck
                chestCount = chestCount + 1
            else
                skippedChest = skippedChest + 1
            end
        end
    end

    for _, storage in pairs(storages) do
        if valid(storage) then
            local camp = storageCamp(storage)
            local gk = camp and guildKey(camp) or nil
            local sk = fullName(storage)
            local ck = camp and campKey(camp) or nil

            if gk and sk and ck then
                local g = freshGuild(gk)
                g.storages[sk] = storage
                g.storageCamp[sk] = ck
                storageCount = storageCount + 1
            else
                skippedStorage = skippedStorage + 1
            end
        end
    end

    local guildCount = 0
    local foreignEdges = 0
    local adds = 0
    local removes = 0
    local failures = 0

    for _, g in pairs(fresh) do
        guildCount = guildCount + 1

        local attempted, added, removed, failed =
            applyGuildEdges(g, refresh == true)

        foreignEdges = foreignEdges + attempted
        adds = adds + added
        removes = removes + removed
        failures = failures + failed
    end

    guilds = fresh

    if failures > 0 then
        log(
            "WARNING scan(%s): foreignEdges=%d failures=%d",
            reason, foreignEdges, failures
        )
    elseif VERBOSE then
        log(
            "scan(%s%s): guilds=%d storages=%d chests=%d foreignEdges=%d "
                .. "add=%d remove=%d skippedChest=%d skippedStorage=%d",
            reason,
            refresh and "+refresh" or "",
            guildCount,
            storageCount,
            chestCount,
            foreignEdges,
            adds,
            removes,
            skippedChest,
            skippedStorage
        )
    end

    return storageCount, chestCount, foreignEdges
end

----------------------------------------------------------------
-- PLAYER INVENTORY MULTI-HELPER
----------------------------------------------------------------

local function resolveChestContainer(model)
    if not valid(model) then return nil end

    local okModule, module = pcall(function()
        return model:GetItemContainerModule()
    end)

    if not okModule or not valid(module) then
        return nil
    end

    local okContainer, container = pcall(function()
        return module:GetContainer()
    end)

    if not okContainer or not valid(container) then
        return nil
    end

    return container
end

local function readArrayObjects(array)
    local out = {}

    if not array then
        return out
    end

    local ok = pcall(function()
        array:ForEach(function(_, elem)
            local value = unwrap(elem)

            if valid(value) then
                out[#out + 1] = value
            end
        end)
    end)

    if not ok then
        return {}
    end

    return out
end

local function findLocalInventoryHelper()
    local inventories = FindAllOf("PalPlayerInventoryData")

    if not inventories then
        return nil, nil
    end

    local fallbackInventory = nil
    local fallbackHelper = nil

    for _, inventory in pairs(inventories) do
        if valid(inventory) then
            local name = fullName(inventory) or ""

            if not name:find("Default__", 1, true) then
                local okHelper, helper = pcall(function()
                    return inventory.InventoryMultiHelper
                end)

                if okHelper and valid(helper) then
                    local okContainers, containers = pcall(function()
                        return helper.Containers
                    end)

                    if okContainers and containers then
                        local current = readArrayObjects(containers)

                        if #current > 0 then
                            return inventory, helper
                        end

                        fallbackInventory = inventory
                        fallbackHelper = helper
                    end
                end
            end
        end
    end

    return fallbackInventory, fallbackHelper
end

local function notifyHelper(helper)
    if not valid(helper) then return end

    pcall(function()
        helper:OnRep_Containers()
    end)
end

local function countMapKeys(t)
    local n = 0
    for _ in pairs(t) do
        n = n + 1
    end
    return n
end

-- Rebuild only the containers injected by this mod.
-- Other native/modded helper entries are preserved.
local function refreshPersistentPool(reason)
    local inventory, helper = findLocalInventoryHelper()

    if not helper then
        debugLog("pool(%s): local InventoryMultiHelper not ready", reason)
        return false
    end

    local okArray, containersArray = pcall(function()
        return helper.Containers
    end)

    if not okArray or not containersArray then
        log("WARNING pool(%s): helper.Containers unavailable", reason)
        return false
    end

    local current = readArrayObjects(containersArray)
    local merged = {}
    local seen = {}

    -- Remove our previous injected containers first.
    for _, container in ipairs(current) do
        local name = fullName(container)

        if name
            and not pool.injectedNames[name]
            and not seen[name]
        then
            seen[name] = true
            merged[#merged + 1] = container
        end
    end

    local newInjected = {}
    local resolvable = 0

    for _, g in pairs(guilds) do
        for _, model in pairs(g.models) do
            local container = resolveChestContainer(model)

            if container then
                resolvable = resolvable + 1

                local name = fullName(container)

                if name and not seen[name] then
                    seen[name] = true
                    newInjected[name] = true
                    merged[#merged + 1] = container
                end
            end
        end
    end

    local okAssign, errAssign = pcall(function()
        helper.Containers = merged
    end)

    if not okAssign then
        log("ERROR pool(%s): assign failed: %s", reason, tostring(errAssign))
        return false
    end

    notifyHelper(helper)

    pool.active = true
    pool.helper = helper
    pool.injectedNames = newInjected

    local injectedCount = countMapKeys(newInjected)

    if VERBOSE or reason == "bootstrap" then
        log(
            "pool(%s): base=%d chests=%d injected=%d final=%d",
            reason,
            #merged - injectedCount,
            resolvable,
            injectedCount,
            #merged
        )
    end

    return true
end

local function cleanupPersistentPool(reason)
    if not pool.active or not valid(pool.helper) then
        pool.active = false
        pool.helper = nil
        pool.injectedNames = {}
        return
    end

    local okArray, containersArray = pcall(function()
        return pool.helper.Containers
    end)

    if okArray and containersArray then
        local current = readArrayObjects(containersArray)
        local kept = {}

        for _, container in ipairs(current) do
            local name = fullName(container)

            if name and not pool.injectedNames[name] then
                kept[#kept + 1] = container
            end
        end

        local okAssign, errAssign = pcall(function()
            pool.helper.Containers = kept
        end)

        if okAssign then
            notifyHelper(pool.helper)
            debugLog(
                "pool cleanup(%s): current=%d final=%d",
                reason, #current, #kept
            )
        else
            log(
                "WARNING pool cleanup(%s) failed: %s",
                reason, tostring(errAssign)
            )
        end
    end

    pool.active = false
    pool.helper = nil
    pool.injectedNames = {}
end

----------------------------------------------------------------
-- CRAFT SESSION
----------------------------------------------------------------

local function beginCraftSession()
    if craftActive then
        return
    end

    if not pool.active then
        if not refreshPersistentPool("craft") then
            return
        end
    end

    local attempted, removed = removeAllForeignEdges()

    craftActive = true

    debugLog(
        "craft begin: removed foreign edges %d/%d",
        removed, attempted
    )
end

local function endCraftSession(reason)
    if not craftActive then
        return
    end

    craftActive = false

    local attempted, added = addAllForeignEdges()

    debugLog(
        "craft end(%s): restored foreign edges %d/%d",
        reason, added, attempted
    )
end

----------------------------------------------------------------
-- HOOK REGISTRATION
----------------------------------------------------------------

local function registerOnce(path, pre, post, label)
    if registeredHooks[path] then
        return true
    end

    if not StaticFindObject(path) then
        return false
    end

    local ok, err = pcall(function()
        RegisterHook(
            path,
            pre or function() end,
            post or function() end
        )
    end)

    if ok then
        registeredHooks[path] = true
        debugLog("hook OK: %s -> %s", label, path)
        return true
    end

    log("ERROR hook %s failed: %s", label, tostring(err))
    return false
end

local function ensureHooks()
    local storageAvailable =
        "/Script/Pal.PalBaseCampModuleItemStorage:OnAvailableConcreteModel_ServerInternal"
    local storageNotAvailable =
        "/Script/Pal.PalBaseCampModuleItemStorage:OnNotAvailableConcreteModel_ServerInternal"

    local storageReadyA = registerOnce(
        storageAvailable,
        function() end,
        function(s, m) onAvailable(s, m) end,
        "storage-available"
    )

    local storageReadyB = registerOnce(
        storageNotAvailable,
        function() end,
        function(s, m) onNotAvailable(s, m) end,
        "storage-notAvailable"
    )

    -- Craft consumes through the persistent InventoryMultiHelper pool.
    -- Temporarily remove the BaseCamp foreign graph to avoid duplicate material paths.
    registerOnce(
        "/Script/Pal.PalUIConvertItemModel:Initialize",
        function()
            beginCraftSession()
        end,
        function() end,
        "craft-initialize"
    )

    registerOnce(
        "/Script/Pal.PalUIConvertItemModel:StartProduction",
        function() end,
        function()
            endCraftSession("StartProduction")
        end,
        "craft-startProduction"
    )

    -- Tested fallback for closing the crafting workspace without producing.
    registerOnce(
        "/Script/Pal.PalUserWidgetStackableUI:OnPreClose",
        function() end,
        function()
            if craftActive then
                endCraftSession("UI-close")
            end
        end,
        "craft-ui-close"
    )

    -- Structural rebuilds can invalidate/recreate the native storage graph.
    registerOnce(
        "/Script/Pal.PalBaseCampModuleItemStorage:OnRep_ContainerInfos",
        function()
            markDirty("OnRep_ContainerInfos")
        end,
        function() end,
        "storage-rep"
    )

    registerOnce(
        "/Script/Pal.PalBaseCampModel:OnRep_ModuleArray",
        function()
            markDirty("OnRep_ModuleArray")
        end,
        function() end,
        "module-rep"
    )

    return storageReadyA and storageReadyB
end

----------------------------------------------------------------
-- WORLD LIFECYCLE
----------------------------------------------------------------

local function resetState(reason)
    -- Remove only containers injected by this mod.
    cleanupPersistentPool(reason)

    guilds = {}
    injecting = false

    initDone = false
    bootScans = 0
    stableStreak = 0
    lastSig = -1
    steadyTick = 0

    dirty = false
    dirtyReason = nil
    craftActive = false

    debugLog("state reset (%s)", reason)
end

local resetHookOk = pcall(function()
    RegisterLoadMapPreHook(function()
        resetState("LoadMap")
    end)
end)

if not resetHookOk then
    log("WARNING RegisterLoadMapPreHook unavailable")
end

----------------------------------------------------------------
-- DRIVER
----------------------------------------------------------------

LoopAsync(DRIVER_MS, function()
    ExecuteInGameThread(function()
        if not ensureHooks() then
            return
        end

        if not initDone then
            local storageCount, chestCount = reconcile("bootstrap", false)

            if not storageCount then
                return
            end

            bootScans = bootScans + 1

            local sig = storageCount * 100000 + chestCount

            if sig == lastSig then
                stableStreak = stableStreak + 1
            else
                stableStreak = 0
            end

            lastSig = sig

            if (storageCount > 0 and stableStreak >= INIT_STABLE)
                or bootScans >= INIT_MAX
            then
                initDone = true

                local poolOk = refreshPersistentPool("bootstrap")

                log(
                    "ready: storages=%d chests=%d sharedPool=%s",
                    storageCount,
                    chestCount,
                    tostring(poolOk)
                )
            end

            return
        end

        steadyTick = steadyTick + 1

        -- Craft intentionally keeps native foreign edges disabled until it closes.
        if craftActive then
            return
        end

        if not pool.active or not valid(pool.helper) then
            pool.active = false
            pool.helper = nil
            pool.injectedNames = {}

            refreshPersistentPool("retry")
            return
        end

        if dirty then
            local reason = dirtyReason or "structure"

            dirty = false
            dirtyReason = nil

            local storageCount = reconcile("dirty:" .. reason, true)

            if not storageCount then
                markDirty(reason)
                return
            end

            if not refreshPersistentPool("dirty:" .. reason) then
                markDirty("pool-refresh")
            end

            return
        end

        if steadyTick % INSURANCE_TICKS == 0 then
            reconcile("insurance", true)
            refreshPersistentPool("insurance")
        end
    end)

    return false
end)

print("[IntegratedStorage] v3.0 loaded - Palworld 1.0.4 SINGLE-PLAYER")
