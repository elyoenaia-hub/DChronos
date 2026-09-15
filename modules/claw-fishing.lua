--[[
    DChronos Native Module
    Game: Claw Fishing
    Edition: ATM Target Engine v1.3.1

    Native DChronos features:
      - Floating DC toggle + minimize
      - Dashboard / Teleport / Tracker tabs
      - Adaptive Dock locator
      - Teleport: Dock / Aquarium / Boat / Spawn
      - Save Position + Return
      - Emergency Dock button
      - Live cash / fish / session stats
      - Tsunami / wave warning monitor
      - Object scan + locator diagnostics
      - Auto refresh
      - Draggable main menu + floating button
      - Fish rarity scanner / target highlighter
      - Rarity filters: Any / Rare+ / Epic+ / Legendary+ / Mythical+ / Special
      - Experimental Auto Fishing using normal PC claw input
      - Optional Auto Approach using the player's occupied boat
      - Auto pause while tsunami/wave warning is visible

    Teleport targets are discovered from live Workspace names and hierarchy.
    No hard-coded Dock coordinate is required.
]]

local EXPECTED_PLACE_ID = 128931272139211
local EXPECTED_UNIVERSE_ID = 10008606756
local MODULE_VERSION = "1.3.1"

if tonumber(game.PlaceId) ~= EXPECTED_PLACE_ID
    and tonumber(game.GameId) ~= EXPECTED_UNIVERSE_ID then
    warn("[DChronos/ClawFishing] Wrong game.")
    return
end

local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")
local UserInputService = game:GetService("UserInputService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ContextActionService = game:GetService("ContextActionService")

local VirtualInputManager = nil
pcall(function()
    VirtualInputManager = game:GetService("VirtualInputManager")
end)

local IS_TOUCH_DEVICE = UserInputService.TouchEnabled
local HAS_KEYBOARD = UserInputService.KeyboardEnabled
local MOBILE_SAFE_MODE = IS_TOUCH_DEVICE and not HAS_KEYBOARD

-- Forward declarations used by Smart Fishing functions that are defined
-- before the GUI is constructed. This avoids accidentally resolving these
-- names as globals/nil in Luau.
local gui
local main
local floatButton
local setStatus

local player = Players.LocalPlayer
if not player then
    warn("[DChronos/ClawFishing] LocalPlayer unavailable.")
    return
end

local playerGui = player:FindFirstChildOfClass("PlayerGui")
    or player:WaitForChild("PlayerGui", 10)

if not playerGui then
    warn("[DChronos/ClawFishing] PlayerGui unavailable.")
    return
end

local old = playerGui:FindFirstChild("DChronosClawFishing")
if old then
    old:Destroy()
end

local state = {
    startedAt = os.clock(),
    visible = true,
    autoRefresh = true,
    savedPositionCFrame = nil,
    lastPreTeleportCFrame = nil,
    lastTeleportName = "None",
    lastWarning = "No tsunami warning detected",
    warningActive = false,
    scan = {
        fish = 0,
        claw = 0,
        boat = 0,
        aquarium = 0,
        prompts = 0,
    },
    targets = {},
    targetScanAt = 0,
    fishing = {
        autoFishing = false,
        autoApproach = false,
        autoApproachBusy = false,
        lastApproachAt = 0,
        filterIndex = 1, -- Any until live species metadata is resolved
        currentTarget = nil,
        currentRarity = "Unknown",
        currentRank = 0,
        currentDistance = math.huge,
        candidates = 0,
        busy = false,
        lastCycleAt = 0,
        cycleDelay = 3.0,
        -- Do not block Auto Fishing just because Storm/Weather UI is visible.
        -- The passive radar already survives WeatherState changes.
        pauseOnWarning = false,
        inputStrategyIndex = 1,
        lastInputStrategy = "None",
        failedInputCycles = 0,

        -- Clean-room ATM target modes inspired by the behavior observed in
        -- Ouroboros: catch-any, best-fish, fish-filter, and mutation-only.
        targetModeIndex = 2, -- Best Fish
        mutatedOnly = false,
        preferMutation = true,
        targetModeName = "Best Fish",

        networkFish = {},
        networkReady = false,
        lastCaughtFishId = nil,
        lastCaughtAt = 0,
        speciesCatalog = {},
        speciesCatalogCount = 0,
    },
    mobileMacro = {
        recording = false,
        calibrated = false,
        events = {},
        startedAt = 0,
        duration = 0,
        lastMessage = "Not calibrated",
    },
}

local TARGETS = {
    Dock = {
        keywords = {
            "dock", "docking", "pier", "harbor", "harbour",
            "port", "marina", "wharf", "jetty", "boatspawn",
            "boat spawn", "dockspawn", "dock spawn",
        },
        offset = Vector3.new(0, 5, 0),
    },
    Aquarium = {
        keywords = {
            "aquarium", "fish tank", "fishtank", "tank",
        },
        offset = Vector3.new(0, 5, 0),
    },
    Boat = {
        keywords = {
            "boat", "ship", "vessel", "playerboat", "player boat",
        },
        offset = Vector3.new(0, 6, 0),
    },
    Spawn = {
        keywords = {
            "spawn", "playerspawn", "player spawn",
            "home", "base", "plot",
        },
        offset = Vector3.new(0, 5, 0),
    },
}

local function lower(value)
    return string.lower(tostring(value or ""))
end

local function formatNumber(value)
    value = tonumber(value)
    if not value then return "—" end

    local abs = math.abs(value)
    if abs >= 1e12 then
        return string.format("%.2fT", value / 1e12)
    elseif abs >= 1e9 then
        return string.format("%.2fB", value / 1e9)
    elseif abs >= 1e6 then
        return string.format("%.2fM", value / 1e6)
    elseif abs >= 1e3 then
        return string.format("%.1fK", value / 1e3)
    end

    if math.floor(value) == value then
        return tostring(math.floor(value))
    end

    return string.format("%.2f", value)
end

local function getCharacter()
    local character = player.Character
    if not character then
        return nil, nil
    end

    local root = character:FindFirstChild("HumanoidRootPart")
    return character, root
end

local function findValueByNames(names)
    local lookup = {}
    for _, name in ipairs(names) do
        lookup[lower(name)] = true
    end

    local leaderstats = player:FindFirstChild("leaderstats")
    if leaderstats then
        for _, child in ipairs(leaderstats:GetChildren()) do
            if lookup[lower(child.Name)] and child:IsA("ValueBase") then
                return child.Value, child.Name
            end
        end
    end

    for _, child in ipairs(player:GetDescendants()) do
        if lookup[lower(child.Name)] and child:IsA("ValueBase") then
            return child.Value, child.Name
        end
    end

    return nil, nil
end

local function scanWorkspaceCounts()
    local counts = {
        fish = 0,
        claw = 0,
        boat = 0,
        aquarium = 0,
        prompts = 0,
    }

    local ok, descendants = pcall(function()
        return Workspace:GetDescendants()
    end)

    if not ok then
        return counts
    end

    for _, instance in ipairs(descendants) do
        local n = lower(instance.Name)

        if n:find("fish", 1, true) then
            counts.fish += 1
        end

        if n:find("claw", 1, true) or n:find("crane", 1, true) then
            counts.claw += 1
        end

        if n:find("boat", 1, true) or n:find("ship", 1, true) then
            counts.boat += 1
        end

        if n:find("aquarium", 1, true) or n:find("tank", 1, true) then
            counts.aquarium += 1
        end

        if instance:IsA("ProximityPrompt") then
            counts.prompts += 1
        end
    end

    return counts
end

local function detectWarningText()
    for _, obj in ipairs(playerGui:GetDescendants()) do
        if (obj:IsA("TextLabel") or obj:IsA("TextButton"))
            and obj.Visible
            and type(obj.Text) == "string"
            and obj.Text ~= "" then

            local text = obj.Text
            local n = lower(text)

            if n:find("tsunami", 1, true)
                or n:find("wave", 1, true)
                or n:find("dead waters", 1, true)
                or n:find("storm", 1, true) then
                return text
            end
        end
    end

    return "No tsunami warning detected"
end

local function getObjectCFrame(instance)
    if not instance or not instance.Parent then
        return nil
    end

    if instance:IsA("BasePart") then
        return instance.CFrame
    end

    if instance:IsA("Model") then
        local ok, pivot = pcall(function()
            return instance:GetPivot()
        end)

        if ok then
            return pivot
        end
    end

    return nil
end

local function fullNameSafe(instance)
    if not instance then return "Unknown" end

    local ok, name = pcall(function()
        return instance:GetFullName()
    end)

    return ok and name or instance.Name
end

local function getCandidateDistance(instance, origin)
    local cf = getObjectCFrame(instance)
    if not cf or not origin then
        return math.huge
    end

    return (cf.Position - origin).Magnitude
end

local function scoreCandidate(instance, definition, origin)
    if not instance then
        return -math.huge
    end

    if not (instance:IsA("BasePart") or instance:IsA("Model")) then
        return -math.huge
    end

    local name = lower(instance.Name)
    local path = lower(fullNameSafe(instance))
    local score = 0
    local matched = false

    for _, keyword in ipairs(definition.keywords) do
        local k = lower(keyword)

        if name == k then
            score += 120
            matched = true
        elseif name:find(k, 1, true) then
            score += 70
            matched = true
        elseif path:find(k, 1, true) then
            score += 24
            matched = true
        end
    end

    if not matched then
        return -math.huge
    end

    -- Prefer things inside a hierarchy that appears player-owned.
    local playerName = lower(player.Name)
    local displayName = lower(player.DisplayName)
    local userId = tostring(player.UserId)

    if path:find(playerName, 1, true) then
        score += 55
    end

    if displayName ~= playerName and path:find(displayName, 1, true) then
        score += 35
    end

    if path:find(userId, 1, true) then
        score += 55
    end

    if path:find("plot", 1, true)
        or path:find("base", 1, true)
        or path:find("home", 1, true) then
        score += 12
    end

    if instance:IsA("Model") then
        score += 4
    end

    local distance = getCandidateDistance(instance, origin)
    if distance < math.huge then
        score += math.max(0, 30 - (distance / 120))
    end

    return score
end

local function locateTarget(targetName, force)
    local definition = TARGETS[targetName]
    if not definition then
        return nil
    end

    local now = os.clock()
    if not force
        and state.targets[targetName]
        and (now - state.targetScanAt) < 8
        and state.targets[targetName].instance
        and state.targets[targetName].instance.Parent then
        return state.targets[targetName]
    end

    local _, root = getCharacter()
    local origin = root and root.Position or Vector3.new()

    local bestInstance = nil
    local bestScore = -math.huge

    local ok, descendants = pcall(function()
        return Workspace:GetDescendants()
    end)

    if ok then
        for _, instance in ipairs(descendants) do
            local score = scoreCandidate(instance, definition, origin)

            if score > bestScore then
                bestScore = score
                bestInstance = instance
            end
        end
    end

    if bestInstance and bestScore > -math.huge then
        local cf = getObjectCFrame(bestInstance)
        if cf then
            local result = {
                instance = bestInstance,
                cframe = cf,
                score = bestScore,
                distance = (cf.Position - origin).Magnitude,
                fullName = fullNameSafe(bestInstance),
            }

            state.targets[targetName] = result
            state.targetScanAt = now
            return result
        end
    end

    state.targets[targetName] = nil
    state.targetScanAt = now
    return nil
end

local function rescanTargets()
    state.targetScanAt = 0

    for targetName in pairs(TARGETS) do
        locateTarget(targetName, true)
    end
end

local function stopCharacterVelocity(root)
    if not root then return end

    pcall(function()
        root.AssemblyLinearVelocity = Vector3.zero
        root.AssemblyAngularVelocity = Vector3.zero
    end)
end

local function teleportToCFrame(cf, label)
    local _, root = getCharacter()

    if not root then
        return false, "HumanoidRootPart not found"
    end

    if not cf then
        return false, "Target CFrame unavailable"
    end

    -- Keep the position from immediately before the teleport as an automatic fallback.
    state.lastPreTeleportCFrame = root.CFrame

    stopCharacterVelocity(root)
    root.CFrame = cf
    stopCharacterVelocity(root)

    state.lastTeleportName = label or "Target"
    return true
end

local function teleportToTarget(targetName)
    local target = locateTarget(targetName, true)
    if not target then
        return false, targetName .. " target was not found"
    end

    local definition = TARGETS[targetName]
    local destination = target.cframe + (definition.offset or Vector3.new(0, 5, 0))

    return teleportToCFrame(destination, targetName)
end


-- Smart Fishing ---------------------------------------------------------------

local RARITY_FILTERS = {
    { name = "Any", minRank = 0 },
    { name = "Rare+", minRank = 3 },
    { name = "Epic+", minRank = 4 },
    { name = "Legendary+", minRank = 5 },
    { name = "Mythical+", minRank = 6 },
    { name = "Special", minRank = 7 },
}

local RARITY_NAMES = {
    [0] = "Unknown",
    [1] = "Common",
    [2] = "Uncommon",
    [3] = "Rare",
    [4] = "Epic",
    [5] = "Legendary",
    [6] = "Mythical",
    [7] = "Special",
}

local RARITY_ALIASES = {
    common = 1,
    uncommon = 2,
    rare = 3,
    epic = 4,
    legendary = 5,
    mythical = 6,
    mythic = 6,
    special = 7,
    secret = 7,
    event = 7,
    exotic = 7,
    limited = 7,
}

local CONFIRMED_SPECIES_RARITY = {
    ["puffer fish"] = 3,
    ["pufferfish"] = 3,
    ["sunfish"] = 4,
    ["whale shark"] = 5,
    ["tiger shark"] = 6,
}

local FISH_KEYWORDS = {
    "fish", "shark", "whale", "dolphin", "crab", "squid",
    "turtle", "jelly", "seahorse", "koi", "puffer", "sunfish",
    "swordfish", "goldfish",
}

local fishHighlight = nil

local RARITY_SCAN_ORDER = {
    { "legendary", 5 },
    { "mythical", 6 },
    { "mythic", 6 },
    { "uncommon", 2 },
    { "special", 7 },
    { "secret", 7 },
    { "limited", 7 },
    { "exotic", 7 },
    { "event", 7 },
    { "common", 1 },
    { "epic", 4 },
    { "rare", 3 },
}

local function rarityFromText(value)
    local text = lower(value)

    if text == "" then
        return nil, nil
    end

    -- Exact first.
    local exact = RARITY_ALIASES[text]
    if exact then
        return exact, RARITY_NAMES[exact]
    end

    -- Then ordered contains matching so "uncommon" never becomes "common".
    for _, item in ipairs(RARITY_SCAN_ORDER) do
        local alias = item[1]
        local rank = item[2]

        if text:find(alias, 1, true) then
            return rank, RARITY_NAMES[rank]
        end
    end

    return nil, nil
end

local function readRarityFromObject(instance)
    if not instance then
        return nil, nil
    end

    local current = instance

    for _ = 1, 4 do
        if not current then break end

        for _, attributeName in ipairs({
            "Rarity", "rarity",
            "Tier", "tier",
            "Grade", "grade",
            "Quality", "quality",
            "FishRarity", "fishRarity",
        }) do
            local ok, value = pcall(function()
                return current:GetAttribute(attributeName)
            end)

            if ok and value ~= nil then
                local rank, label = rarityFromText(value)
                if rank then
                    return rank, label
                end

                if type(value) == "number" then
                    local numericRank = math.clamp(math.floor(value), 1, 7)
                    return numericRank, RARITY_NAMES[numericRank]
                end
            end
        end

        for _, child in ipairs(current:GetChildren()) do
            local childName = lower(child.Name)
            if childName == "rarity"
                or childName == "tier"
                or childName == "grade"
                or childName == "quality"
                or childName == "fishrarity" then

                if child:IsA("StringValue") then
                    local rank, label = rarityFromText(child.Value)
                    if rank then
                        return rank, label
                    end
                elseif child:IsA("IntValue") or child:IsA("NumberValue") then
                    local numericRank = math.clamp(math.floor(tonumber(child.Value) or 0), 1, 7)
                    return numericRank, RARITY_NAMES[numericRank]
                end
            end
        end

        current = current.Parent
    end

    -- Some games render rarity in a BillboardGui / SurfaceGui.
    local ok, descendants = pcall(function()
        return instance:GetDescendants()
    end)

    if ok then
        for _, obj in ipairs(descendants) do
            if (obj:IsA("TextLabel") or obj:IsA("TextButton"))
                and type(obj.Text) == "string"
                and obj.Text ~= "" then
                local rank, label = rarityFromText(obj.Text)
                if rank then
                    return rank, label
                end
            end
        end
    end

    -- Conservative species fallback only for examples publicly documented.
    local name = lower(instance.Name)
    for species, rank in pairs(CONFIRMED_SPECIES_RARITY) do
        if name:find(species, 1, true) then
            return rank, RARITY_NAMES[rank]
        end
    end

    return 0, "Unknown"
end


local function readInstanceSpeciesMetadata(instance)
    if not instance then
        return nil, nil, nil
    end

    local speciesId = nil
    local rarityValue = nil
    local displayName = nil

    for _, attrName in ipairs({
        "SpeciesId", "speciesId", "SpeciesID", "speciesID",
        "FishId", "fishId", "Id", "ID"
    }) do
        local ok, value = pcall(function()
            return instance:GetAttribute(attrName)
        end)

        if ok and tonumber(value) then
            speciesId = tonumber(value)
            break
        end
    end

    for _, attrName in ipairs({"Rarity", "rarity", "Tier", "tier", "Grade", "grade"}) do
        local ok, value = pcall(function()
            return instance:GetAttribute(attrName)
        end)

        if ok and value ~= nil then
            rarityValue = value
            break
        end
    end

    for _, attrName in ipairs({"DisplayName", "displayName", "FishName", "fishName", "Name"}) do
        local ok, value = pcall(function()
            return instance:GetAttribute(attrName)
        end)

        if ok and type(value) == "string" and value ~= "" then
            displayName = value
            break
        end
    end

    for _, child in ipairs(instance:GetChildren()) do
        local n = lower(child.Name)

        if not speciesId
            and (n == "speciesid" or n == "fishid" or n == "id")
            and (child:IsA("IntValue") or child:IsA("NumberValue")) then
            speciesId = tonumber(child.Value)
        end

        if not rarityValue
            and (n == "rarity" or n == "tier" or n == "grade")
            and (child:IsA("StringValue") or child:IsA("IntValue") or child:IsA("NumberValue")) then
            rarityValue = child.Value
        end

        if not displayName
            and (n == "displayname" or n == "fishname")
            and child:IsA("StringValue") then
            displayName = child.Value
        end
    end

    return speciesId, rarityValue, displayName
end


local function safeRequireModule(moduleScript)
    if not moduleScript or not moduleScript:IsA("ModuleScript") then
        return nil
    end

    local ok, result = pcall(require, moduleScript)

    if ok and type(result) == "table" then
        return result
    end

    return nil
end

local function findReplicatedModuleByName(name)
    local wanted = lower(name)

    for _, obj in ipairs(ReplicatedStorage:GetDescendants()) do
        if obj:IsA("ModuleScript") and lower(obj.Name) == wanted then
            return obj
        end
    end

    return nil
end

local function deepFindNumericKey(tableValue, wantedKey, depth, seen)
    depth = depth or 0
    seen = seen or {}

    if type(tableValue) ~= "table" or depth > 5 or seen[tableValue] then
        return nil
    end

    seen[tableValue] = true

    if tableValue[wantedKey] ~= nil then
        local result = tableValue[wantedKey]
        seen[tableValue] = nil
        return result
    end

    for _, value in pairs(tableValue) do
        if type(value) == "table" then
            local result = deepFindNumericKey(value, wantedKey, depth + 1, seen)
            if result ~= nil then
                seen[tableValue] = nil
                return result
            end
        end
    end

    seen[tableValue] = nil
    return nil
end

local function normalizeFishMetadataRecord(speciesId, record, sourceName)
    if type(record) ~= "table" then
        return nil
    end

    local name =
        record.name
        or record.Name
        or record.displayName
        or record.DisplayName
        or record.fishName
        or record.FishName

    local rarity =
        record.rarity
        or record.Rarity
        or record.tier
        or record.Tier
        or record.grade
        or record.Grade

    local rank, rarityName = rarityFromText(rarity)

    if not rank and tonumber(rarity) then
        rank = math.clamp(math.floor(tonumber(rarity)), 1, 7)
        rarityName = RARITY_NAMES[rank]
    end

    return {
        speciesId = tonumber(speciesId),
        name = type(name) == "string" and name or nil,
        rank = rank or 0,
        rarity = rarityName or (rarity ~= nil and tostring(rarity) or "Unknown"),
        source = sourceName,
    }
end

local function readOuroborosStyleReplicatedMetadata()
    local catalog = {}
    local sourceCount = 0

    local candidateNames = {
        "FishInfo",
        "RarityInfo",
        "MutationInfo",
        "IdToName",
        "FishRarities",
        "Rarities",
    }

    local loaded = {}

    for _, name in ipairs(candidateNames) do
        local moduleScript = findReplicatedModuleByName(name)
        local value = safeRequireModule(moduleScript)

        if value then
            loaded[name] = value
            sourceCount += 1
        end
    end

    -- FishInfo-style tables are the strongest source because they commonly
    -- carry species/name/rarity together.
    local fishInfo = loaded.FishInfo

    if type(fishInfo) == "table" then
        for key, record in pairs(fishInfo) do
            local speciesId = tonumber(key)

            if type(record) == "table" then
                speciesId =
                    speciesId
                    or tonumber(record.id)
                    or tonumber(record.Id)
                    or tonumber(record.speciesId)
                    or tonumber(record.SpeciesId)
            end

            if speciesId then
                local normalized = normalizeFishMetadataRecord(
                    speciesId,
                    record,
                    "Module:FishInfo"
                )

                if normalized then
                    catalog[speciesId] = normalized
                end
            end
        end
    end

    -- IdToName can fill names even when FishInfo is absent.
    local idToName = loaded.IdToName

    if type(idToName) == "table" then
        for key, name in pairs(idToName) do
            local speciesId = tonumber(key)

            if speciesId and type(name) == "string" then
                catalog[speciesId] = catalog[speciesId] or {
                    speciesId = speciesId,
                    rank = 0,
                    rarity = "Unknown",
                    source = "Module:IdToName",
                }

                catalog[speciesId].name = name
            end
        end
    end

    -- RarityInfo / FishRarities can fill rarity by species id when keyed that way.
    for _, sourceName in ipairs({"RarityInfo", "FishRarities", "Rarities"}) do
        local tbl = loaded[sourceName]

        if type(tbl) == "table" then
            for speciesId, info in pairs(catalog) do
                local rarityValue = deepFindNumericKey(tbl, speciesId)

                if rarityValue ~= nil then
                    if type(rarityValue) == "table" then
                        rarityValue =
                            rarityValue.rarity
                            or rarityValue.Rarity
                            or rarityValue.name
                            or rarityValue.Name
                            or rarityValue.tier
                            or rarityValue.Tier
                    end

                    local rank, rarityName = rarityFromText(rarityValue)

                    if not rank and tonumber(rarityValue) then
                        rank = math.clamp(
                            math.floor(tonumber(rarityValue)),
                            1,
                            7
                        )
                        rarityName = RARITY_NAMES[rank]
                    end

                    if rank then
                        info.rank = rank
                        info.rarity = rarityName
                        info.source = info.source .. "+" .. sourceName
                    end
                end
            end
        end
    end

    return catalog, sourceCount
end


local function rebuildSpeciesCatalog()
    local catalog, moduleSourceCount =
        readOuroborosStyleReplicatedMetadata()

    local count = 0

    for _ in pairs(catalog) do
        count += 1
    end

    -- Existing generic replicated metadata remains a fallback.
    for _, obj in ipairs(ReplicatedStorage:GetDescendants()) do
        if obj:IsA("Folder")
            or obj:IsA("Model")
            or obj:IsA("Configuration")
            or obj:IsA("ValueBase") then

            local speciesId, rarityValue, displayName =
                readInstanceSpeciesMetadata(obj)

            if speciesId and rarityValue ~= nil then
                local rank, rarityName = rarityFromText(rarityValue)

                if not rank and tonumber(rarityValue) then
                    rank = math.clamp(
                        math.floor(tonumber(rarityValue)),
                        1,
                        7
                    )
                    rarityName = RARITY_NAMES[rank]
                end

                if rank then
                    if not catalog[speciesId] then
                        count += 1
                    end

                    local existing = catalog[speciesId] or {}

                    catalog[speciesId] = {
                        speciesId = speciesId,
                        rank = rank or existing.rank or 0,
                        rarity = rarityName or existing.rarity or tostring(rarityValue),
                        name = existing.name or displayName or obj.Name,
                        source = existing.source
                            or ("Replicated:" .. fullNameSafe(obj)),
                    }
                end
            end
        end
    end

    state.fishing.speciesCatalog = catalog
    state.fishing.speciesCatalogCount = count
    state.fishing.metadataModuleCount = moduleSourceCount or 0

    return count
end

local function getSpeciesInfo(speciesId)
    speciesId = tonumber(speciesId)
    if not speciesId then
        return {
            rank = 0,
            rarity = "Unknown",
            name = "Unknown species",
        }
    end

    local info = state.fishing.speciesCatalog[speciesId]
    if info then
        return info
    end

    return {
        rank = 0,
        rarity = "Unknown",
        name = "Species #" .. tostring(speciesId),
    }
end

local function getNetworkFishPosition(fish)
    if not fish then
        return nil
    end

    return fish.position or fish.destination or fish.spawnPosition
end

local function networkFishLabel(fish)
    if not fish then
        return "Fish"
    end

    local info = getSpeciesInfo(fish.speciesId)
    local mutation = fish.mutation and (" • " .. tostring(fish.mutation)) or ""

    return string.format(
        "%s [%s]%s",
        info.name or ("Species #" .. tostring(fish.speciesId)),
        info.rarity or "Unknown",
        mutation
    )
end

local function upsertNetworkFishSpawn(entry)
    if type(entry) ~= "table" then
        return
    end

    local id = tonumber(entry[1])
    if not id then
        return
    end

    local meta = type(entry[11]) == "table" and entry[11] or {}
    local fish = state.fishing.networkFish[id] or { id = id }

    fish.id = id
    fish.speciesId = tonumber(entry[2]) or fish.speciesId

    if tonumber(entry[3]) and tonumber(entry[4]) and tonumber(entry[5]) then
        fish.spawnPosition = Vector3.new(
            tonumber(entry[3]),
            tonumber(entry[4]),
            tonumber(entry[5])
        )
        fish.position = fish.position or fish.spawnPosition
    end

    if tonumber(entry[6]) and tonumber(entry[7]) and tonumber(entry[8]) then
        fish.destination = Vector3.new(
            tonumber(entry[6]),
            tonumber(entry[7]),
            tonumber(entry[8])
        )
    end

    fish.spawnedAt = tonumber(entry[9]) or fish.spawnedAt
    fish.expireAt = tonumber(entry[10]) or fish.expireAt
    fish.size = tonumber(meta.size) or fish.size
    fish.mutation = meta.mutation or fish.mutation
    fish.lastUpdateAt = os.clock()

    state.fishing.networkFish[id] = fish
    state.fishing.networkReady = true
end

local function upsertNetworkFishUpdate(entry)
    if type(entry) ~= "table" then
        return
    end

    local id = tonumber(entry[1])
    if not id then
        return
    end

    local fish = state.fishing.networkFish[id] or { id = id }

    if tonumber(entry[2]) and tonumber(entry[3]) and tonumber(entry[4]) then
        fish.position = Vector3.new(
            tonumber(entry[2]),
            tonumber(entry[3]),
            tonumber(entry[4])
        )
    end

    fish.serverTime = tonumber(entry[5]) or fish.serverTime
    fish.expireAt = tonumber(entry[6]) or fish.expireAt
    fish.lastUpdateAt = os.clock()

    state.fishing.networkFish[id] = fish
    state.fishing.networkReady = true
end

local function removeNetworkFishIds(payload)
    if type(payload) ~= "table" then
        return
    end

    for _, idValue in pairs(payload) do
        local id = tonumber(idValue)
        if id then
            state.fishing.networkFish[id] = nil

            if state.fishing.currentTarget
                and state.fishing.currentTarget.id == id then
                state.fishing.currentTarget = nil
            end
        end
    end
end

local function handleNetworkFishUpdate(action, payload)
    if action == "spawn" and type(payload) == "table" then
        for _, entry in pairs(payload) do
            upsertNetworkFishSpawn(entry)
        end
    elseif action == "update" and type(payload) == "table" then
        for _, entry in pairs(payload) do
            upsertNetworkFishUpdate(entry)
        end
    elseif action == "despawn" then
        removeNetworkFishIds(payload)
    elseif action == "freeze" and type(payload) == "table" then
        local id = tonumber(payload.id)
        if id then
            local fish = state.fishing.networkFish[id] or { id = id }

            if tonumber(payload.x) and tonumber(payload.y) and tonumber(payload.z) then
                fish.position = Vector3.new(
                    tonumber(payload.x),
                    tonumber(payload.y),
                    tonumber(payload.z)
                )
            end

            fish.frozen = true
            fish.catcher = tostring(payload.catcher or "")
            fish.lastUpdateAt = os.clock()
            state.fishing.networkFish[id] = fish

            if fish.catcher == player.Name then
                state.fishing.lastCaughtFishId = id
                state.fishing.lastCaughtAt = os.clock()
            end
        end
    end
end


local function hasRelevantFishAttribute(instance)
    if not instance then return false end

    local names = {
        "speciesId", "SpeciesId", "species", "Species",
        "rarity", "Rarity", "FishRarity",
        "caught", "Caught", "activeFish", "ActiveFish",
        "destination", "Destination", "FishState",
    }

    for _, attr in ipairs(names) do
        local ok, value = pcall(function()
            return instance:GetAttribute(attr)
        end)

        if ok and value ~= nil then
            return true
        end
    end

    return false
end

local function isRuntimeFishCandidate(instance)
    if not instance then return false end
    if not (instance:IsA("Model") or instance:IsA("BasePart")) then return false end

    local noTouchy = Workspace:FindFirstChild("NoTouchy")
    if not noTouchy or not instance:IsDescendantOf(noTouchy) then
        return false
    end

    -- Explicitly reject known non-fish runtime branches.
    local boatsFolder = noTouchy:FindFirstChild("Boats")
    if boatsFolder and instance:IsDescendantOf(boatsFolder) then
        return false
    end

    local path = lower(fullNameSafe(instance))
    if path:find(".boats.", 1, true)
        or path:find(".claw", 1, true)
        or path:find(".crane", 1, true)
        or path:find(".hull", 1, true) then
        return false
    end

    if hasRelevantFishAttribute(instance) then
        return true
    end

    local current = instance.Parent
    for _ = 1, 5 do
        if not current or current == noTouchy then break end

        if hasRelevantFishAttribute(current) then
            return true
        end

        local n = lower(current.Name)
        if n == "fishstate"
            or n == "activefish"
            or n == "active fish"
            or n == "fishes"
            or n == "fish" then
            return true
        end

        current = current.Parent
    end

    return false
end

local function looksLikeFish(instance)
    return isRuntimeFishCandidate(instance)
end

local function getFishingOrigin()
    local noTouchy = Workspace:FindFirstChild("NoTouchy")
    local boatsFolder = noTouchy and noTouchy:FindFirstChild("Boats")
    local exactBoat = boatsFolder and boatsFolder:FindFirstChild(player.Name)

    if exactBoat and exactBoat:IsA("Model") then
        local cf = getObjectCFrame(exactBoat)
        if cf then
            return cf.Position, exactBoat
        end
    end

    local _, root = getCharacter()
    return root and root.Position or Vector3.new(), nil
end

local function getPlayerBoat()
    -- Runtime report confirmed this exact hierarchy in Claw Fishing.
    local noTouchy = Workspace:FindFirstChild("NoTouchy")
    local boatsFolder = noTouchy and noTouchy:FindFirstChild("Boats")
    local exactBoat = boatsFolder and boatsFolder:FindFirstChild(player.Name)

    if exactBoat and exactBoat:IsA("Model") then
        local seat = exactBoat:FindFirstChildWhichIsA("VehicleSeat", true)
            or exactBoat:FindFirstChildWhichIsA("Seat", true)
        return exactBoat, seat, "Workspace.NoTouchy.Boats.<player>"
    end

    local character = player.Character
    local humanoid = character and character:FindFirstChildOfClass("Humanoid")

    if humanoid then
        for _, obj in ipairs(Workspace:GetDescendants()) do
            if (obj:IsA("VehicleSeat") or obj:IsA("Seat"))
                and obj.Occupant == humanoid then
                local model = obj:FindFirstAncestorOfClass("Model")
                if model then
                    return model, obj, "occupied-seat"
                end
            end
        end
    end

    return nil, nil, "not-found"
end

local function getPlayerClaw(origin)
    local boat = getPlayerBoat()

    if boat then
        local exactClaw = boat:FindFirstChild("Claw", true)
        if exactClaw then
            return exactClaw
        end

        local exactCrane = boat:FindFirstChild("Crane", true)
        if exactCrane then
            return exactCrane
        end
    end

    return nil
end

local function fishMatchesFilter(rank)
    local filter = RARITY_FILTERS[state.fishing.filterIndex]

    if not filter then
        return true
    end

    if filter.name == "Special" then
        return rank >= 7
    end

    if filter.minRank == 0 then
        return true
    end

    return rank >= filter.minRank
end


local TARGET_MODES = {
    "Catch Any",
    "Best Fish",
    "Mutation Hunt",
}

local MUTATION_PRIORITY = {
    rainbow = 4,
    gold = 3,
    silver = 2,
    shocked = 2,
}

local function mutationRank(mutation)
    local key = lower(mutation)
    if key == "" then
        return 0
    end
    return MUTATION_PRIORITY[key] or 1
end

local function targetModeScore(fish, info, distance)
    local mode = TARGET_MODES[state.fishing.targetModeIndex]
    local rarityRank = tonumber(info.rank) or 0
    local mutationScore = mutationRank(fish.mutation)

    if mode == "Catch Any" then
        return -distance
    elseif mode == "Mutation Hunt" then
        if mutationScore <= 0 then
            return nil
        end
        return (mutationScore * 1000000)
            + (rarityRank * 100000)
            - distance
    end

    -- Best Fish:
    -- rarity first, mutation second, distance third.
    return (rarityRank * 1000000)
        + (mutationScore * 100000)
        - distance
end


local function scanFishTarget()
    local origin = getFishingOrigin()
    local best = nil
    local bestScore = -math.huge
    local candidates = 0
    local filter = RARITY_FILTERS[state.fishing.filterIndex]

    for id, fish in pairs(state.fishing.networkFish) do
        local position = getNetworkFishPosition(fish)

        if position and not fish.frozen then
            local info = getSpeciesInfo(fish.speciesId)
            local rank = tonumber(info.rank) or 0
            local mutation = fish.mutation

            local matchesRarity = false

            if filter.minRank == 0 then
                matchesRarity = true
            elseif rank > 0 then
                if filter.name == "Special" then
                    matchesRarity = rank >= 7
                else
                    matchesRarity = rank >= filter.minRank
                end
            end

            local matchesMutation =
                (not state.fishing.mutatedOnly)
                or mutationRank(mutation) > 0

            if matchesRarity and matchesMutation then
                local distance = (position - origin).Magnitude
                local score = targetModeScore(fish, info, distance)

                if score ~= nil then
                    candidates += 1

                    if score > bestScore then
                        bestScore = score

                        best = {
                            id = id,
                            speciesId = fish.speciesId,
                            fish = fish,
                            position = position,
                            cframe = CFrame.new(position),
                            rank = rank,
                            rarity = info.rarity or "Unknown",
                            speciesName =
                                info.name
                                or ("Species #" .. tostring(fish.speciesId)),
                            mutation = mutation,
                            distance = distance,
                            label = networkFishLabel(fish),
                            metadataSource = info.source or "Network",
                            targetMode =
                                TARGET_MODES[state.fishing.targetModeIndex],
                        }
                    end
                end
            end
        end
    end

    state.fishing.currentTarget = best
    state.fishing.currentRarity = best and best.rarity or "None"
    state.fishing.currentRank = best and best.rank or 0
    state.fishing.currentDistance = best and best.distance or math.huge
    state.fishing.candidates = candidates
    state.fishing.targetModeName =
        TARGET_MODES[state.fishing.targetModeIndex]

    return best
end

local function updateFishHighlight(target)
    if fishHighlight then
        fishHighlight:Destroy()
        fishHighlight = nil
    end

    if not target or not target.position then
        return
    end

    local marker = Instance.new("Part")
    marker.Name = "DChronosNetworkFishTarget"
    marker.Shape = Enum.PartType.Ball
    marker.Size = Vector3.new(4, 4, 4)
    marker.Anchored = true
    marker.CanCollide = false
    marker.CanTouch = false
    marker.CanQuery = false
    marker.Material = Enum.Material.Neon
    marker.Transparency = 0.25
    marker.CFrame = CFrame.new(target.position)
    marker.Parent = Workspace

    local highlight = Instance.new("Highlight")
    highlight.Name = "TargetHighlight"
    highlight.Adornee = marker
    highlight.FillTransparency = 0.45
    highlight.OutlineTransparency = 0
    highlight.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
    highlight.Parent = marker

    local billboard = Instance.new("BillboardGui")
    billboard.Name = "TargetLabel"
    billboard.AlwaysOnTop = true
    billboard.Size = UDim2.fromOffset(260, 58)
    billboard.StudsOffset = Vector3.new(0, 4.5, 0)
    billboard.Parent = marker

    local label = Instance.new("TextLabel")
    label.BackgroundColor3 = Color3.fromRGB(12, 16, 24)
    label.BackgroundTransparency = 0.12
    label.BorderSizePixel = 0
    label.Size = UDim2.fromScale(1, 1)
    label.Font = Enum.Font.GothamMedium
    label.TextSize = 12
    label.TextWrapped = true
    label.TextColor3 = Color3.fromRGB(244, 247, 255)
    label.Text = string.format(
        "%s\nID %s • %.0f studs",
        target.label or "Fish",
        tostring(target.id or "?"),
        tonumber(target.distance) or 0
    )
    label.Parent = billboard

    local corner = Instance.new("UICorner")
    corner.CornerRadius = UDim.new(0, 8)
    corner.Parent = label

    fishHighlight = marker
end

local function approachFishWithBoat(target)
    if not target or not target.position then
        return false, "Network fish target unavailable"
    end

    local boat, seat, boatMethod = getPlayerBoat()
    if not boat then
        return false, "Player boat was not found"
    end

    local current = getObjectCFrame(boat)
    if not current then
        return false, "Boat pivot unavailable"
    end

    local fishPos = target.position
    local currentPos = current.Position
    local flatDirection = Vector3.new(
        fishPos.X - currentPos.X,
        0,
        fishPos.Z - currentPos.Z
    )

    local distanceBefore = flatDirection.Magnitude

    if distanceBefore <= 18 then
        return true, "already-near", distanceBefore
    end

    if flatDirection.Magnitude < 0.1 then
        flatDirection = Vector3.new(0, 0, -1)
    else
        flatDirection = flatDirection.Unit
    end

    local approachPosition = Vector3.new(
        fishPos.X,
        currentPos.Y,
        fishPos.Z
    ) - (flatDirection * 12)

    local destination = CFrame.lookAt(
        approachPosition,
        Vector3.new(fishPos.X, currentPos.Y, fishPos.Z)
    )

    local hull = boat:FindFirstChild("Hull", true)
    local vehicleSeat = seat or boat:FindFirstChildWhichIsA("VehicleSeat", true)

    local function zeroPhysics()
        for _, part in ipairs({hull, vehicleSeat}) do
            if part and part:IsA("BasePart") then
                pcall(function()
                    part.AssemblyLinearVelocity = Vector3.zero
                    part.AssemblyAngularVelocity = Vector3.zero
                end)
            end
        end
    end

    local ok, err = pcall(function()
        zeroPhysics()

        -- Reinforce the local movement over a few frames. This is noticeably
        -- more reliable on mobile than a single PivotTo call.
        for _ = 1, 4 do
            boat:PivotTo(destination)
            zeroPhysics()
            task.wait(0.08)
        end
    end)

    if not ok then
        return false, tostring(err)
    end

    task.wait(0.12)

    local after = getObjectCFrame(boat)
    if not after then
        return true, boatMethod or "moved", distanceBefore
    end

    local distanceAfter = Vector3.new(
        fishPos.X - after.Position.X,
        0,
        fishPos.Z - after.Position.Z
    ).Magnitude

    -- Detect immediate server correction rather than pretending approach worked.
    if distanceAfter > distanceBefore - 3 and distanceAfter > 22 then
        return false,
            string.format(
                "boat movement was server-corrected (%.0f → %.0f studs)",
                distanceBefore,
                distanceAfter
            ),
            distanceAfter
    end

    return true,
        string.format("%.0f → %.0f studs", distanceBefore, distanceAfter),
        distanceAfter
end



local function gameButtonAtPoint(x, y)
    local best = nil
    local bestArea = math.huge
    local bestZ = -math.huge

    if not playerGui then
        return nil
    end

    for _, obj in ipairs(playerGui:GetDescendants()) do
        if obj:IsA("GuiButton")
            and obj.Visible
            and gui
            and not obj:IsDescendantOf(gui) then

            local pos = obj.AbsolutePosition
            local size = obj.AbsoluteSize

            if x >= pos.X
                and x <= pos.X + size.X
                and y >= pos.Y
                and y <= pos.Y + size.Y then

                local area = math.max(1, size.X * size.Y)
                local z = obj.ZIndex

                if z > bestZ or (z == bestZ and area < bestArea) then
                    best = obj
                    bestArea = area
                    bestZ = z
                end
            end
        end
    end

    return best
end

local function activateCalibratedButton(button)
    if not button or not button.Parent then
        return false, "calibrated button is no longer available"
    end

    local activated = false

    local ok = pcall(function()
        button:Activate()
        activated = true
    end)

    if activated and ok then
        return true, "GuiButton:Activate"
    end

    if type(firesignal) == "function" then
        local fired = false

        pcall(function()
            firesignal(button.Activated)
            fired = true
        end)

        if fired then
            return true, "firesignal(Activated)"
        end
    end

    return false, "button activation unavailable"
end

local macroConnections = {}

local function clearMacroConnections()
    for _, connection in ipairs(macroConnections) do
        pcall(function()
            connection:Disconnect()
        end)
    end
    table.clear(macroConnections)
end

local function beginMobileGestureCalibration()
    if not IS_TOUCH_DEVICE then
        return false, "Touch input is not enabled"
    end

    if state.mobileMacro.recording then
        return false, "Calibration already running"
    end

    state.mobileMacro.recording = true
    state.mobileMacro.calibrated = false
    state.mobileMacro.events = {}
    state.mobileMacro.startedAt = os.clock()
    state.mobileMacro.duration = 0
    state.mobileMacro.lastMessage = "Recording touch gesture"
    clearMacroConnections()

    local activeTouches = {}
    local calibrationStart = state.mobileMacro.startedAt

    table.insert(macroConnections, UserInputService.InputBegan:Connect(function(input, processed)
        if not state.mobileMacro.recording then
            return
        end

        if input.UserInputType == Enum.UserInputType.Touch then
            local elapsed = os.clock() - calibrationStart

            -- Ignore the first moment so the Calibration button's own release is never recorded.
            if elapsed < 0.55 then
                return
            end

            local key = tostring(input)
            activeTouches[key] = true

            local buttonRef = gameButtonAtPoint(
                input.Position.X,
                input.Position.Y
            )

            table.insert(state.mobileMacro.events, {
                t = elapsed,
                state = Enum.UserInputState.Begin.Value,
                x = input.Position.X,
                y = input.Position.Y,
                buttonRef = buttonRef,
                buttonPath = buttonRef and fullNameSafe(buttonRef) or nil,
            })
        end
    end))

    table.insert(macroConnections, UserInputService.InputEnded:Connect(function(input, processed)
        if not state.mobileMacro.recording then
            return
        end

        if input.UserInputType == Enum.UserInputType.Touch then
            local elapsed = os.clock() - calibrationStart

            if elapsed < 0.55 then
                return
            end

            table.insert(state.mobileMacro.events, {
                t = elapsed,
                state = Enum.UserInputState.End.Value,
                x = input.Position.X,
                y = input.Position.Y,
            })
        end
    end))

    -- Hide DChronos while recording so only normal game touches are captured.
    main.Visible = false
    floatButton.Visible = false

    task.spawn(function()
        task.wait(13)

        if not state.mobileMacro.recording then
            return
        end

        state.mobileMacro.recording = false
        state.mobileMacro.duration = os.clock() - calibrationStart
        clearMacroConnections()

        main.Visible = true
        floatButton.Visible = false
        state.visible = true

        local eventCount = #state.mobileMacro.events

        if eventCount >= 2 then
            state.mobileMacro.calibrated = true
            state.mobileMacro.lastMessage = tostring(eventCount) .. " touch events captured"
            state.fishing.cycleDelay = math.max(4, state.mobileMacro.duration + 1.5)
            setStatus(
                "Mobile claw gesture calibrated • "
                    .. tostring(eventCount)
                    .. " touch events",
                "good"
            )
        else
            state.mobileMacro.calibrated = false
            state.mobileMacro.lastMessage = "No useful touch gesture captured"
            setStatus(
                "Calibration failed • repeat and perform one normal claw catch",
                "bad"
            )
        end
    end)

    return true
end

local function playMobileGesture()
    if not state.mobileMacro.calibrated then
        return false, "Run Mobile Gesture Calibration first"
    end

    local events = state.mobileMacro.events
    if #events == 0 then
        return false, "Recorded gesture is empty"
    end

    local previousTime = 0
    local touchId = 1
    local activatedButtons = 0
    local syntheticTouches = 0

    for _, event in ipairs(events) do
        local delay = math.max(0, (event.t or 0) - previousTime)
        if delay > 0 then
            task.wait(delay)
        end

        local handled = false

        -- For a touch that began on a real game GuiButton, prefer directly
        -- activating that button. This is far more reliable on iPad executors
        -- than synthesizing an OS-like touch.
        if event.state == Enum.UserInputState.Begin.Value
            and event.buttonRef
            and event.buttonRef.Parent then

            local ok = activateCalibratedButton(event.buttonRef)
            if ok then
                activatedButtons += 1
                handled = true
            end
        end

        if not handled then
            if not VirtualInputManager then
                return false,
                    "VirtualInputManager unavailable and no calibrated GuiButton matched"
            end

            local ok, err = pcall(function()
                VirtualInputManager:SendTouchEvent(
                    touchId,
                    tonumber(event.state) or Enum.UserInputState.Begin.Value,
                    tonumber(event.x) or 0,
                    tonumber(event.y) or 0
                )
            end)

            if not ok then
                return false, tostring(err)
            end

            syntheticTouches += 1
        end

        previousTime = event.t or previousTime
    end

    return true,
        string.format(
            "mobile replay • buttons=%d touches=%d",
            activatedButtons,
            syntheticTouches
        )
end



local function discoverClawContextAction()
    local bestName = nil
    local bestScore = -math.huge
    local bestInfo = nil

    local ok, actions = pcall(function()
        return ContextActionService:GetAllBoundActionInfo()
    end)

    if not ok or type(actions) ~= "table" then
        return nil, nil, -math.huge
    end

    for actionName, info in pairs(actions) do
        local combined = lower(actionName)

        if type(info) == "table" then
            combined = combined
                .. " "
                .. lower(info.title)
                .. " "
                .. lower(info.description)
        end

        local score = 0

        if combined:find("claw", 1, true) then score += 160 end
        if combined:find("crane", 1, true) then score += 130 end
        if combined:find("catch", 1, true) then score += 110 end
        if combined:find("grab", 1, true) then score += 100 end
        if combined:find("drop", 1, true) then score += 70 end
        if combined:find("pull", 1, true) then score += 60 end
        if combined:find("fish", 1, true) then score += 35 end

        if type(info) == "table" and info.createTouchButton then
            score += 20
        end

        if score > bestScore then
            bestName = actionName
            bestScore = score
            bestInfo = info
        end
    end

    if bestScore <= 0 then
        return nil, nil, bestScore
    end

    return bestName, bestInfo, bestScore
end

local function activateContextAction()
    local actionName, info, score = discoverClawContextAction()

    if not actionName then
        return false, "No claw-like ContextAction binding found"
    end

    local button = nil
    pcall(function()
        button = ContextActionService:GetButton(actionName)
    end)

    if button and button:IsA("GuiButton") then
        local ok, method = activateCalibratedButton(button)
        if ok then
            return true,
                "ContextButton "
                    .. tostring(actionName)
                    .. " via "
                    .. tostring(method)
        end
    end

    -- Some mobile games bind the action without exposing a touch button.
    local called = false
    local callErr = nil

    local ok, err = pcall(function()
        ContextActionService:CallFunction(
            actionName,
            Enum.UserInputState.Begin,
            nil
        )
        task.wait(0.12)
        ContextActionService:CallFunction(
            actionName,
            Enum.UserInputState.End,
            nil
        )
        called = true
    end)

    if not ok then
        callErr = err
    end

    if called then
        return true, "ContextAction " .. tostring(actionName)
    end

    return false,
        "ContextAction "
            .. tostring(actionName)
            .. " failed: "
            .. tostring(callErr)
end

local function calibratedButtonSequence()
    if not state.mobileMacro.calibrated then
        return false, "No calibrated gesture"
    end

    local used = 0
    local lastT = 0

    for _, event in ipairs(state.mobileMacro.events) do
        if event.state == Enum.UserInputState.Begin.Value
            and event.buttonRef
            and event.buttonRef.Parent then

            local delay = math.max(0, (event.t or 0) - lastT)
            if delay > 0 then
                task.wait(delay)
            end

            local ok = activateCalibratedButton(event.buttonRef)
            if ok then
                used += 1
            end

            lastT = event.t or lastT
        end
    end

    if used > 0 then
        return true, "Calibrated GuiButtons x" .. tostring(used)
    end

    return false, "Calibration did not contain a game GuiButton"
end

local function calibratedMouseSequence()
    if not state.mobileMacro.calibrated then
        return false, "No calibrated gesture"
    end

    if not VirtualInputManager then
        return false, "VirtualInputManager unavailable"
    end

    local used = 0
    local lastT = 0

    for _, event in ipairs(state.mobileMacro.events) do
        if event.state == Enum.UserInputState.Begin.Value then
            local delay = math.max(0, (event.t or 0) - lastT)
            if delay > 0 then
                task.wait(delay)
            end

            local x = tonumber(event.x) or 0
            local y = tonumber(event.y) or 0

            local ok = pcall(function()
                VirtualInputManager:SendMouseButtonEvent(
                    x, y, 0, true, game, 0
                )
                task.wait(0.07)
                VirtualInputManager:SendMouseButtonEvent(
                    x, y, 0, false, game, 0
                )
            end)

            if ok then
                used += 1
            end

            lastT = event.t or lastT
        end
    end

    if used > 0 then
        return true, "Calibrated coordinates via LMB x" .. tostring(used)
    end

    return false, "No calibrated tap coordinates"
end


local function findClawControlButton()
    local best, bestScore = nil, -math.huge

    for _, obj in ipairs(playerGui:GetDescendants()) do
        if obj:IsA("GuiButton") and obj.Visible then
            -- Never allow DChronos' own controls to be detected as game controls.
            if obj:IsDescendantOf(gui) then
                continue
            end

            local name = lower(obj.Name)
            local text = ""
            local path = lower(fullNameSafe(obj))

            pcall(function()
                text = lower(obj.Text)
            end)

            local combined = name .. " " .. text .. " " .. path
            local score = 0

            if combined:find("claw", 1, true) then score += 140 end
            if combined:find("grab", 1, true) then score += 110 end
            if combined:find("drop", 1, true) then score += 85 end
            if combined:find("lower", 1, true) then score += 85 end
            if combined:find("catch", 1, true) then score += 65 end
            if combined:find("crane", 1, true) then score += 55 end

            if obj:IsA("ImageButton") then
                score += 4
            end

            if score > bestScore and score > 0 then
                best = obj
                bestScore = score
            end
        end
    end

    return best, bestScore
end

local function activateGuiButton(button)
    if not button then
        return false, "No claw control button found"
    end

    local ok = pcall(function()
        button:Activate()
    end)

    if ok then
        return true
    end

    if VirtualInputManager then
        local pos = button.AbsolutePosition
        local size = button.AbsoluteSize
        local x = math.floor(pos.X + size.X / 2)
        local y = math.floor(pos.Y + size.Y / 2)

        local clickOk, clickErr = pcall(function()
            VirtualInputManager:SendMouseButtonEvent(x, y, 0, true, game, 0)
            task.wait(0.08)
            VirtualInputManager:SendMouseButtonEvent(x, y, 0, false, game, 0)
        end)

        if clickOk then
            return true
        end

        return false, tostring(clickErr)
    end

    return false, "Button activation failed and VirtualInputManager unavailable"
end

local INPUT_STRATEGIES = {
    "ContextAction",
    "CalibratedButton",
    "CalibratedMouse",
    "CalibratedTouch",
}

local function sendClawInput(strategyIndex)
    strategyIndex = tonumber(strategyIndex) or state.fishing.inputStrategyIndex or 1

    if not IS_TOUCH_DEVICE then
        local button = findClawControlButton()

        if button then
            local ok, err = activateGuiButton(button)
            if not ok then return false, err, "DesktopGuiButton" end

            task.wait(0.85)
            activateGuiButton(button)
            task.wait(0.45)
            activateGuiButton(button)

            return true,
                "gui-button:" .. fullNameSafe(button),
                "DesktopGuiButton"
        end

        return false, "No desktop claw control found", "DesktopGuiButton"
    end

    local strategy = INPUT_STRATEGIES[
        math.clamp(strategyIndex, 1, #INPUT_STRATEGIES)
    ]

    local ok, message = false, "Unknown strategy"

    if strategy == "ContextAction" then
        ok, message = activateContextAction()

    elseif strategy == "CalibratedButton" then
        ok, message = calibratedButtonSequence()

    elseif strategy == "CalibratedMouse" then
        ok, message = calibratedMouseSequence()

    elseif strategy == "CalibratedTouch" then
        ok, message = playMobileGesture()
    end

    state.fishing.lastInputStrategy = strategy

    return ok, message, strategy
end

local function rotateInputStrategy()
    state.fishing.inputStrategyIndex += 1

    if state.fishing.inputStrategyIndex > #INPUT_STRATEGIES then
        state.fishing.inputStrategyIndex = 1
    end

    return INPUT_STRATEGIES[state.fishing.inputStrategyIndex]
end

local function targetIsAligned(target)
    if not target or not target.position then
        return false, math.huge
    end

    local origin, boat = getFishingOrigin()
    local sourcePosition = origin

    if not state.fishing.autoApproach then
        local claw = getPlayerClaw(origin)

        if claw then
            local cf = getObjectCFrame(claw)
            if cf then
                sourcePosition = cf.Position
            end
        end
    end

    local fishPos = target.position
    local horizontal = Vector3.new(
        fishPos.X - sourcePosition.X,
        0,
        fishPos.Z - sourcePosition.Z
    ).Magnitude

    -- Auto Approach intentionally parks ~12 studs from the fish.
    return horizontal <= 34, horizontal
end

local function runAutoFishingCycle()
    if state.fishing.busy or not state.fishing.autoFishing then
        return
    end

    if os.clock() - state.fishing.lastCycleAt < state.fishing.cycleDelay then
        return
    end

    state.fishing.busy = true
    state.fishing.lastCycleAt = os.clock()

    local target = scanFishTarget()
    updateFishHighlight(target)

    if not target then
        local filterName = RARITY_FILTERS[state.fishing.filterIndex].name
        setStatus(
            "No network fish matches " .. filterName
                .. " • try Any if rarity metadata is unavailable",
            "warn"
        )
        state.fishing.busy = false
        return
    end

    if state.fishing.autoApproach then
        -- Auto Approach now runs in its own loop. Refresh the live target and
        -- wait until it is actually within claw range before fishing.
        local liveFish = state.fishing.networkFish[target.id]
        local livePos = liveFish and getNetworkFishPosition(liveFish)

        if livePos then
            target.position = livePos
            target.cframe = CFrame.new(livePos)
            target.distance = (livePos - getFishingOrigin()).Magnitude
        end
    end

    local aligned, distance = targetIsAligned(target)

    if not aligned then
        setStatus(
            string.format(
                "%s is %.0f studs from claw • enable Auto Approach",
                target.label or ("Fish #" .. tostring(target.id)),
                distance
            ),
            "warn"
        )
        state.fishing.busy = false
        return
    end

    local caughtBefore = state.fishing.lastCaughtAt

    setStatus(
        "Auto Fishing → "
            .. (target.label or ("Fish #" .. tostring(target.id))),
        "good"
    )

    local strategyIndex = state.fishing.inputStrategyIndex
    local ok, message, strategy = sendClawInput(strategyIndex)

    if not ok then
        local nextStrategy = rotateInputStrategy()
        state.fishing.failedInputCycles += 1

        setStatus(
            "Input "
                .. tostring(strategy)
                .. " failed • next: "
                .. tostring(nextStrategy)
                .. " • "
                .. tostring(message),
            "warn"
        )

        state.fishing.busy = false
        return
    end

    setStatus(
        "Claw input sent • "
            .. tostring(strategy)
            .. " • "
            .. tostring(message),
        "good"
    )

    -- Passive confirmation: FishUpdate "freeze" names the catcher and caught fish id.
    local waitStart = os.clock()
    local confirmed = false

    while os.clock() - waitStart < 6 do
        if state.fishing.lastCaughtAt > caughtBefore then
            confirmed = true
            state.fishing.failedInputCycles = 0

            setStatus(
                "Catch confirmed • Fish ID "
                    .. tostring(state.fishing.lastCaughtFishId or "?")
                    .. " • "
                    .. tostring(strategy),
                "good"
            )

            break
        end

        task.wait(0.15)
    end

    if not confirmed then
        local nextStrategy = rotateInputStrategy()
        state.fishing.failedInputCycles += 1

        setStatus(
            "No catch confirmation with "
                .. tostring(strategy)
                .. " • next cycle: "
                .. tostring(nextStrategy),
            "warn"
        )
    end

    state.fishing.busy = false
end



-- Protocol Recorder -----------------------------------------------------------

local protocolConnections = {}
local recorderEnv = (type(getgenv) == "function" and getgenv()) or _G

if type(recorderEnv.__DCHRONOS_CLAW_RECORDER) ~= "table" then
    recorderEnv.__DCHRONOS_CLAW_RECORDER = {
        enabled = false,
        logs = {},
        startedAt = 0,
        hookInstalled = false,
    }
end

local protocolState = recorderEnv.__DCHRONOS_CLAW_RECORDER

local WATCHED_REMOTE_NAMES = {
    DataUpdate = true,
    FishUpdate = true,
    Steer = true,
    CatchFish = true,
    CatchSuccess = true,
    ConfirmCatch = true,
    PullFish = true,
    Teleport = true,
    CrewCraneInput = true,
    CrewCatchShow = true,
    CrewSync = true,
    WeatherTrigger = true,
    WeatherState = true,
}

local function serializeProtocolValue(value, depth, seen)
    depth = depth or 0
    seen = seen or {}

    if depth > 3 then
        return "<max-depth>"
    end

    local valueType = typeof(value)

    if valueType == "nil" then
        return "nil"
    elseif valueType == "string" then
        local trimmed = value
        if #trimmed > 220 then
            trimmed = trimmed:sub(1, 220) .. "…"
        end
        return string.format("%q", trimmed)
    elseif valueType == "number" or valueType == "boolean" then
        return tostring(value)
    elseif valueType == "Vector3" then
        return string.format("Vector3(%.3f, %.3f, %.3f)", value.X, value.Y, value.Z)
    elseif valueType == "Vector2" then
        return string.format("Vector2(%.3f, %.3f)", value.X, value.Y)
    elseif valueType == "CFrame" then
        local p = value.Position
        return string.format("CFrame(pos=%.3f, %.3f, %.3f)", p.X, p.Y, p.Z)
    elseif valueType == "Instance" then
        return "<" .. value.ClassName .. ":" .. fullNameSafe(value) .. ">"
    elseif valueType == "EnumItem" then
        return tostring(value)
    elseif valueType == "table" then
        if seen[value] then
            return "<cycle>"
        end

        seen[value] = true
        local parts = {}
        local count = 0

        for k, v in pairs(value) do
            count += 1
            if count > 30 then
                table.insert(parts, "…")
                break
            end

            table.insert(
                parts,
                "["
                    .. serializeProtocolValue(k, depth + 1, seen)
                    .. "]="
                    .. serializeProtocolValue(v, depth + 1, seen)
            )
        end

        seen[value] = nil
        return "{" .. table.concat(parts, ", ") .. "}"
    end

    return "<" .. valueType .. ":" .. tostring(value) .. ">"
end

local function protocolLog(direction, remote, args)
    if not protocolState.enabled then
        return
    end

    local remoteName = remote and remote.Name or "?"
    if not WATCHED_REMOTE_NAMES[remoteName] then
        return
    end

    local elapsed = os.clock() - protocolState.startedAt
    local serializedArgs = {}

    for i = 1, #args do
        serializedArgs[i] = serializeProtocolValue(args[i], 0, {})
    end

    local line = string.format(
        "[%07.3f] %s %s (%s) args=[%s]",
        elapsed,
        direction,
        fullNameSafe(remote),
        remote and remote.ClassName or "?",
        table.concat(serializedArgs, ", ")
    )

    table.insert(protocolState.logs, line)

    if direction:find("IN/", 1, true) then
        local name = remote and remote.Name or ""
        if name == "FishUpdate"
            or name == "PullFish"
            or name == "CatchSuccess"
            or name == "WeatherState" then
            table.insert(
                protocolState.logs,
                string.format(
                    "[%07.3f] SNAPSHOT %s",
                    elapsed,
                    clawStateSnapshot()
                )
            )
        end
    end

    if #protocolState.logs > 500 then
        table.remove(protocolState.logs, 1)
    end
end

local function installOutgoingProtocolHook()
    if protocolState.hookInstalled then
        return true, "already-installed"
    end

    if type(hookmetamethod) ~= "function"
        or type(getnamecallmethod) ~= "function"
        or type(newcclosure) ~= "function" then
        return false, "executor does not expose hookmetamethod/getnamecallmethod/newcclosure"
    end

    local oldNamecall
    oldNamecall = hookmetamethod(game, "__namecall", newcclosure(function(self, ...)
        local method = getnamecallmethod()
        local args = {...}

        if (method == "FireServer" or method == "InvokeServer")
            and typeof(self) == "Instance"
            and (self:IsA("RemoteEvent") or self:IsA("RemoteFunction"))
            and self:IsDescendantOf(ReplicatedStorage) then

            local current = recorderEnv.__DCHRONOS_CLAW_RECORDER
            if current and current.enabled and WATCHED_REMOTE_NAMES[self.Name] then
                protocolLog("OUT/" .. method, self, args)
            end
        end

        return oldNamecall(self, ...)
    end))

    protocolState.hookInstalled = true
    return true, "installed"
end

local function disconnectProtocolConnections()
    for _, connection in ipairs(protocolConnections) do
        pcall(function()
            connection:Disconnect()
        end)
    end
    table.clear(protocolConnections)
end

local function installIncomingProtocolListeners()
    disconnectProtocolConnections()

    local events = ReplicatedStorage:FindFirstChild("Events")
    if not events then
        return 0
    end

    local count = 0

    for _, remote in ipairs(events:GetDescendants()) do
        if remote:IsA("RemoteEvent") and WATCHED_REMOTE_NAMES[remote.Name] then
            local connection = remote.OnClientEvent:Connect(function(...)
                protocolLog("IN/OnClientEvent", remote, {...})
            end)

            table.insert(protocolConnections, connection)
            count += 1
        end
    end

    return count
end

local function startProtocolRecording()
    protocolState.logs = {}
    protocolState.startedAt = os.clock()
    protocolState.enabled = true

    local hookOk = false
    local hookStatus = "mobile-safe-passive"
    local listenerCount = installIncomingProtocolListeners()

    -- iPad/mobile-safe mode intentionally does NOT hook outgoing __namecall.
    -- Some mobile executors can disturb RemoteFunction timing and leave the claw stuck.
    if not MOBILE_SAFE_MODE then
        hookOk, hookStatus = installOutgoingProtocolHook()
    end

    table.insert(
        protocolState.logs,
        string.format(
            "[000.000] RECORDER START mode=%s hook=%s(%s) incomingListeners=%d",
            MOBILE_SAFE_MODE and "MOBILE_PASSIVE" or "DESKTOP_DEEP",
            tostring(hookOk),
            tostring(hookStatus),
            listenerCount
        )
    )

    return hookOk, hookStatus, listenerCount
end

local function stopProtocolRecording()
    protocolState.enabled = false
end

local function clearProtocolRecording()
    protocolState.logs = {}
    protocolState.startedAt = 0
end

local function buildProtocolReport()
    local lines = {
        "=== DChronos Claw Fishing Mobile Safe Recording ===",
        "ModuleVersion=" .. MODULE_VERSION,
        "PlaceId=" .. tostring(game.PlaceId),
        "UniverseId=" .. tostring(game.GameId),
        "Player=" .. tostring(player.Name) .. " (" .. tostring(player.UserId) .. ")",
        "BoatPath=Workspace.NoTouchy.Boats." .. tostring(player.Name),
        "",
        "[Recorded Traffic]",
    }

    if #protocolState.logs == 0 then
        table.insert(lines, "NO TRAFFIC RECORDED")
    else
        for _, line in ipairs(protocolState.logs) do
            table.insert(lines, line)
        end
    end

    return table.concat(lines, "\n")
end

local function copyText(text)
    if type(setclipboard) == "function" then
        local ok = pcall(setclipboard, text)
        if ok then return true end
    end

    if type(toclipboard) == "function" then
        local ok = pcall(toclipboard, text)
        if ok then return true end
    end

    print(text)
    return false
end



-- Permanent passive network fish radar ---------------------------------------

local networkRadarConnection = nil

local function startNetworkFishRadar()
    if networkRadarConnection then
        return true
    end

    local events = ReplicatedStorage:FindFirstChild("Events")
    local fishUpdate = events and events:FindFirstChild("FishUpdate")

    if not fishUpdate or not fishUpdate:IsA("RemoteEvent") then
        return false
    end

    networkRadarConnection = fishUpdate.OnClientEvent:Connect(function(action, payload)
        pcall(handleNetworkFishUpdate, action, payload)
    end)

    rebuildSpeciesCatalog()
    return true
end


-- Runtime Calibration / Diagnostics ------------------------------------------

local lastDiagnosticReport = ""

local function relevantAttributes(instance)
    local parts = {}

    for _, attrName in ipairs({
        "speciesId", "SpeciesId", "species", "Species",
        "rarity", "Rarity", "FishRarity", "caught", "Caught",
        "activeFish", "ActiveFish", "destination", "Destination",
        "OwnerUserId", "ownerUserId", "Owner", "FishState",
    }) do
        local ok, value = pcall(function()
            return instance:GetAttribute(attrName)
        end)

        if ok and value ~= nil then
            table.insert(parts, attrName .. "=" .. tostring(value))
        end
    end

    return #parts > 0 and table.concat(parts, ", ") or "-"
end


local function visibleGameButtonsReport()
    local lines = {}
    local count = 0

    for _, obj in ipairs(playerGui:GetDescendants()) do
        if obj:IsA("GuiButton") and obj.Visible and not obj:IsDescendantOf(gui) then
            count += 1

            local text = ""
            local image = ""

            pcall(function()
                text = obj.Text
            end)

            pcall(function()
                image = obj.Image
            end)

            table.insert(
                lines,
                string.format(
                    "%02d | %s | %s | text=%q | image=%q | pos=(%.0f,%.0f) size=(%.0f,%.0f)",
                    count,
                    obj.ClassName,
                    fullNameSafe(obj),
                    tostring(text),
                    tostring(image),
                    obj.AbsolutePosition.X,
                    obj.AbsolutePosition.Y,
                    obj.AbsoluteSize.X,
                    obj.AbsoluteSize.Y
                )
            )

            if count >= 80 then
                break
            end
        end
    end

    if #lines == 0 then
        table.insert(lines, "NO VISIBLE GAME BUTTONS")
    end

    return lines
end

local function clawStateSnapshot()
    local boat = getPlayerBoat()
    local parts = {}

    if boat then
        local claw = boat:FindFirstChild("Claw", true)
        local crane = boat:FindFirstChild("Crane", true)
        local hull = boat:FindFirstChild("Hull", true)

        if claw then
            local cf = getObjectCFrame(claw)
            table.insert(parts, "Claw=" .. fullNameSafe(claw))
            if cf then
                table.insert(parts, string.format("ClawPos=(%.2f,%.2f,%.2f)", cf.X, cf.Y, cf.Z))
            end
        end

        if crane then
            table.insert(parts, "Crane=" .. fullNameSafe(crane))
        end

        if hull then
            local cf = getObjectCFrame(hull)
            if cf then
                table.insert(parts, string.format("HullPos=(%.2f,%.2f,%.2f)", cf.X, cf.Y, cf.Z))
            end
        end
    end

    return #parts > 0 and table.concat(parts, " | ") or "No boat/claw state"
end

local function buildDiagnosticReport()
    local lines = {}

    local function add(text)
        table.insert(lines, tostring(text))
    end

    add("=== DChronos Claw Fishing Runtime Report ===")
    add("ModuleVersion=" .. MODULE_VERSION)
    add("PlaceId=" .. tostring(game.PlaceId))
    add("UniverseId=" .. tostring(game.GameId))
    add("Player=" .. tostring(player.Name) .. " (" .. tostring(player.UserId) .. ")")
    add("TouchEnabled=" .. tostring(UserInputService.TouchEnabled))
    add("KeyboardEnabled=" .. tostring(UserInputService.KeyboardEnabled))
    add("RecorderMode=" .. (MOBILE_SAFE_MODE and "MOBILE_PASSIVE" or "DESKTOP_DEEP"))
    add("")

    local clawButton = findClawControlButton()
    add("[Visible Game Buttons]")
    for _, line in ipairs(visibleGameButtonsReport()) do
        add(line)
    end
    add("")

    add("[ClawControl]")
    if clawButton then
        local text = ""
        pcall(function() text = clawButton.Text end)
        add("Path=" .. fullNameSafe(clawButton))
        add("Class=" .. clawButton.ClassName)
        add("Text=" .. tostring(text))
    else
        add("NOT FOUND")
    end
    add("")

    local boat, seat, boatMethod = getPlayerBoat()
    add("[PlayerBoat]")
    add("Method=" .. tostring(boatMethod))
    if boat then
        add("Path=" .. fullNameSafe(boat))
        add("Attrs=" .. relevantAttributes(boat))
        add("Hull=" .. tostring(boat:FindFirstChild("Hull", true) ~= nil))
    else
        add("NOT FOUND")
    end
    if seat then
        add("Seat=" .. fullNameSafe(seat))
    end
    add("")

    add("[Remote Candidates]")
    local remoteCount = 0
    for _, obj in ipairs(ReplicatedStorage:GetDescendants()) do
        if obj:IsA("RemoteEvent") or obj:IsA("RemoteFunction") then
            local n = lower(obj.Name)
            local path = lower(fullNameSafe(obj))

            local important =
                n:find("catch", 1, true)
                or n:find("fish", 1, true)
                or n:find("claw", 1, true)
                or n:find("boat", 1, true)
                or n:find("equip", 1, true)
                or n:find("aquarium", 1, true)
                or path:find("events", 1, true)

            if important then
                remoteCount += 1
                add(obj.ClassName .. " | " .. fullNameSafe(obj))
                if remoteCount >= 80 then break end
            end
        end
    end
    if remoteCount == 0 then add("NONE MATCHED") end
    add("")

    add("[NoTouchy Top-Level]")
    local noTouchy = Workspace:FindFirstChild("NoTouchy")
    if noTouchy then
        for _, child in ipairs(noTouchy:GetChildren()) do
            add(child.ClassName .. " | " .. fullNameSafe(child) .. " | attrs=" .. relevantAttributes(child))
        end
    else
        add("Workspace.NoTouchy NOT FOUND")
    end
    add("")

    add("[Runtime Fish Candidates]")
    local fishCount = 0
    if noTouchy then
        for _, obj in ipairs(noTouchy:GetDescendants()) do
            if (obj:IsA("Model") or obj:IsA("BasePart")) and isRuntimeFishCandidate(obj) then
                fishCount += 1
                local rank, rarity = readRarityFromObject(obj)
                add(
                    string.format(
                        "%02d | %s | %s | rarity=%s(%s) | attrs=%s",
                        fishCount,
                        obj.ClassName,
                        fullNameSafe(obj),
                        tostring(rarity),
                        tostring(rank),
                        relevantAttributes(obj)
                    )
                )
                if fishCount >= 60 then break end
            end
        end
    end
    if fishCount == 0 then add("NONE MATCHED") end
    add("")

    add("[Named Runtime Objects]")
    local namedCount = 0
    local wanted = {
        "activefish", "fishstate", "fishrarities", "rarities",
        "playerdata", "catchfish", "destination", "claw",
        "hull", "aquariums", "boat", "species",
    }

    for _, root in ipairs({noTouchy, ReplicatedStorage, player}) do
        if root then
            for _, obj in ipairs(root:GetDescendants()) do
                local n = lower(obj.Name)
                for _, keyword in ipairs(wanted) do
                    if n == keyword or n:find(keyword, 1, true) then
                        namedCount += 1
                        add(obj.ClassName .. " | " .. fullNameSafe(obj) .. " | attrs=" .. relevantAttributes(obj))
                        break
                    end
                end
                if namedCount >= 120 then break end
            end
        end
        if namedCount >= 120 then break end
    end
    if namedCount == 0 then add("NONE MATCHED") end
    add("")

    local report = table.concat(lines, "\n")
    lastDiagnosticReport = report
    return report
end

local function copyDiagnosticReport()
    local report = buildDiagnosticReport()
    print(report)

    local copied = false

    if type(setclipboard) == "function" then
        copied = pcall(setclipboard, report)
    elseif type(toclipboard) == "function" then
        copied = pcall(toclipboard, report)
    end

    return copied, report
end


-- GUI -----------------------------------------------------------------------

gui = Instance.new("ScreenGui")
gui.Name = "DChronosClawFishing"
gui.ResetOnSpawn = false
gui.IgnoreGuiInset = true

floatButton = Instance.new("TextButton")
floatButton.Name = "FloatingToggle"
floatButton.AnchorPoint = Vector2.new(0, 0.5)
floatButton.Position = UDim2.new(0, 18, 0.5, 0)
floatButton.Size = UDim2.fromOffset(56, 56)
floatButton.BackgroundColor3 = Color3.fromRGB(18, 23, 34)
floatButton.BorderSizePixel = 0
floatButton.AutoButtonColor = true
floatButton.Font = Enum.Font.GothamBold
floatButton.Text = "DC"
floatButton.TextSize = 16
floatButton.TextColor3 = Color3.fromRGB(242, 245, 255)
floatButton.Visible = false
floatButton.ZIndex = 30
floatButton.Parent = gui

local floatCorner = Instance.new("UICorner")
floatCorner.CornerRadius = UDim.new(1, 0)
floatCorner.Parent = floatButton

local floatStroke = Instance.new("UIStroke")
floatStroke.Color = Color3.fromRGB(83, 94, 122)
floatStroke.Thickness = 1
floatStroke.Parent = floatButton

main = Instance.new("Frame")
main.Name = "Main"
main.AnchorPoint = Vector2.new(0, 0.5)
main.Position = UDim2.new(0, 24, 0.5, 0)
main.Size = UDim2.fromOffset(430, 700)
main.BackgroundColor3 = Color3.fromRGB(10, 13, 20)
main.BorderSizePixel = 0
main.Parent = gui

local mainCorner = Instance.new("UICorner")
mainCorner.CornerRadius = UDim.new(0, 16)
mainCorner.Parent = main

local mainStroke = Instance.new("UIStroke")
mainStroke.Color = Color3.fromRGB(58, 66, 84)
mainStroke.Thickness = 1
mainStroke.Parent = main

local header = Instance.new("Frame")
header.BackgroundTransparency = 1
header.Position = UDim2.fromOffset(20, 14)
header.Size = UDim2.new(1, -40, 0, 60)
header.Parent = main

local title = Instance.new("TextLabel")
title.BackgroundTransparency = 1
title.Size = UDim2.new(1, -116, 0, 27)
title.Font = Enum.Font.GothamBold
title.Text = "DCHRONOS"
title.TextSize = 21
title.TextColor3 = Color3.fromRGB(246, 248, 255)
title.TextXAlignment = Enum.TextXAlignment.Left
title.Parent = header

local subtitle = Instance.new("TextLabel")
subtitle.BackgroundTransparency = 1
subtitle.Position = UDim2.fromOffset(0, 28)
subtitle.Size = UDim2.new(1, -116, 0, 19)
subtitle.Font = Enum.Font.Gotham
subtitle.Text = "Claw Fishing • Utility Pack v" .. MODULE_VERSION
subtitle.TextSize = 11
subtitle.TextColor3 = Color3.fromRGB(142, 151, 170)
subtitle.TextXAlignment = Enum.TextXAlignment.Left
subtitle.Parent = header

local nativeBadge = Instance.new("TextLabel")
nativeBadge.AnchorPoint = Vector2.new(1, 0)
nativeBadge.Position = UDim2.new(1, -40, 0, 1)
nativeBadge.Size = UDim2.fromOffset(66, 24)
nativeBadge.BackgroundColor3 = Color3.fromRGB(24, 48, 36)
nativeBadge.BorderSizePixel = 0
nativeBadge.Font = Enum.Font.GothamBold
nativeBadge.Text = "NATIVE"
nativeBadge.TextSize = 10
nativeBadge.TextColor3 = Color3.fromRGB(156, 239, 181)
nativeBadge.Parent = header

local badgeCorner = Instance.new("UICorner")
badgeCorner.CornerRadius = UDim.new(1, 0)
badgeCorner.Parent = nativeBadge

local minimize = Instance.new("TextButton")
minimize.AnchorPoint = Vector2.new(1, 0)
minimize.Position = UDim2.new(1, 0, 0, 0)
minimize.Size = UDim2.fromOffset(30, 26)
minimize.BackgroundColor3 = Color3.fromRGB(29, 34, 46)
minimize.BorderSizePixel = 0
minimize.Font = Enum.Font.GothamBold
minimize.Text = "–"
minimize.TextSize = 18
minimize.TextColor3 = Color3.fromRGB(225, 230, 242)
minimize.Parent = header

local minCorner = Instance.new("UICorner")
minCorner.CornerRadius = UDim.new(0, 7)
minCorner.Parent = minimize

local divider = Instance.new("Frame")
divider.Position = UDim2.fromOffset(20, 78)
divider.Size = UDim2.new(1, -40, 0, 1)
divider.BackgroundColor3 = Color3.fromRGB(38, 43, 56)
divider.BorderSizePixel = 0
divider.Parent = main

-- Status banner
local statusBanner = Instance.new("TextLabel")
statusBanner.Position = UDim2.fromOffset(20, 90)
statusBanner.Size = UDim2.new(1, -40, 0, 34)
statusBanner.BackgroundColor3 = Color3.fromRGB(16, 20, 29)
statusBanner.BorderSizePixel = 0
statusBanner.Font = Enum.Font.GothamMedium
statusBanner.Text = "Ready • Native utility loaded"
statusBanner.TextSize = 11
statusBanner.TextColor3 = Color3.fromRGB(199, 207, 225)
statusBanner.TextXAlignment = Enum.TextXAlignment.Left
statusBanner.Parent = main

local statusPadding = Instance.new("UIPadding")
statusPadding.PaddingLeft = UDim.new(0, 10)
statusPadding.PaddingRight = UDim.new(0, 10)
statusPadding.Parent = statusBanner

local statusCorner = Instance.new("UICorner")
statusCorner.CornerRadius = UDim.new(0, 8)
statusCorner.Parent = statusBanner

setStatus = function(text, tone)
    statusBanner.Text = text

    if tone == "good" then
        statusBanner.BackgroundColor3 = Color3.fromRGB(22, 43, 34)
        statusBanner.TextColor3 = Color3.fromRGB(165, 237, 186)
    elseif tone == "warn" then
        statusBanner.BackgroundColor3 = Color3.fromRGB(48, 39, 23)
        statusBanner.TextColor3 = Color3.fromRGB(246, 208, 137)
    elseif tone == "bad" then
        statusBanner.BackgroundColor3 = Color3.fromRGB(50, 28, 32)
        statusBanner.TextColor3 = Color3.fromRGB(255, 175, 180)
    else
        statusBanner.BackgroundColor3 = Color3.fromRGB(16, 20, 29)
        statusBanner.TextColor3 = Color3.fromRGB(199, 207, 225)
    end
end

-- Tabs
local tabBar = Instance.new("Frame")
tabBar.BackgroundTransparency = 1
tabBar.Position = UDim2.fromOffset(20, 136)
tabBar.Size = UDim2.new(1, -40, 0, 34)
tabBar.Parent = main

local tabLayout = Instance.new("UIListLayout")
tabLayout.FillDirection = Enum.FillDirection.Horizontal
tabLayout.Padding = UDim.new(0, 7)
tabLayout.SortOrder = Enum.SortOrder.LayoutOrder
tabLayout.Parent = tabBar

local pages = {}
local tabButtons = {}
local activeTab = nil

local function createPage(name)
    local page = Instance.new("Frame")
    page.Name = name .. "Page"
    page.BackgroundTransparency = 1
    page.Position = UDim2.fromOffset(20, 181)
    page.Size = UDim2.new(1, -40, 0, 465)
    page.Visible = false
    page.Parent = main
    pages[name] = page
    return page
end

local function switchTab(name)
    activeTab = name

    for tabName, page in pairs(pages) do
        page.Visible = (tabName == name)
    end

    for tabName, button in pairs(tabButtons) do
        if tabName == name then
            button.BackgroundColor3 = Color3.fromRGB(40, 48, 66)
            button.TextColor3 = Color3.fromRGB(240, 243, 252)
        else
            button.BackgroundColor3 = Color3.fromRGB(20, 24, 34)
            button.TextColor3 = Color3.fromRGB(145, 154, 172)
        end
    end
end

local function createTab(name)
    local button = Instance.new("TextButton")
    button.Size = UDim2.new(1/5, -6, 1, 0)
    button.BackgroundColor3 = Color3.fromRGB(20, 24, 34)
    button.BorderSizePixel = 0
    button.AutoButtonColor = true
    button.Font = Enum.Font.GothamMedium
    button.Text = name
    button.TextSize = 11
    button.TextColor3 = Color3.fromRGB(145, 154, 172)
    button.Parent = tabBar

    local corner = Instance.new("UICorner")
    corner.CornerRadius = UDim.new(0, 8)
    corner.Parent = button

    tabButtons[name] = button
    button.MouseButton1Click:Connect(function()
        switchTab(name)
    end)
end

createTab("Dashboard")
createTab("Teleport")
createTab("Tracker")
createTab("Fishing")
createTab("Debug")

local dashboardPage = createPage("Dashboard")
local teleportPage = createPage("Teleport")
local trackerPage = createPage("Tracker")
local fishingPage = createPage("Fishing")
local debugPage = createPage("Debug")

-- Shared GUI helpers
local function createInfoRow(parent, y, labelText)
    local row = Instance.new("Frame")
    row.Position = UDim2.fromOffset(0, y)
    row.Size = UDim2.new(1, 0, 0, 32)
    row.BackgroundColor3 = Color3.fromRGB(17, 21, 30)
    row.BorderSizePixel = 0
    row.Parent = parent

    local corner = Instance.new("UICorner")
    corner.CornerRadius = UDim.new(0, 7)
    corner.Parent = row

    local label = Instance.new("TextLabel")
    label.BackgroundTransparency = 1
    label.Position = UDim2.fromOffset(10, 0)
    label.Size = UDim2.new(0.38, -10, 1, 0)
    label.Font = Enum.Font.Gotham
    label.Text = labelText
    label.TextSize = 11
    label.TextColor3 = Color3.fromRGB(135, 144, 162)
    label.TextXAlignment = Enum.TextXAlignment.Left
    label.Parent = row

    local value = Instance.new("TextLabel")
    value.BackgroundTransparency = 1
    value.Position = UDim2.new(0.38, 0, 0, 0)
    value.Size = UDim2.new(0.62, -10, 1, 0)
    value.Font = Enum.Font.GothamMedium
    value.Text = "—"
    value.TextSize = 11
    value.TextColor3 = Color3.fromRGB(225, 229, 239)
    value.TextXAlignment = Enum.TextXAlignment.Right
    value.TextTruncate = Enum.TextTruncate.AtEnd
    value.Parent = row

    return value
end

local function createActionButton(parent, xScale, y, widthScale, text)
    local button = Instance.new("TextButton")
    button.Position = UDim2.new(xScale, 0, 0, y)
    button.Size = UDim2.new(widthScale, -4, 0, 38)
    button.BackgroundColor3 = Color3.fromRGB(31, 37, 51)
    button.BorderSizePixel = 0
    button.AutoButtonColor = true
    button.Font = Enum.Font.GothamMedium
    button.Text = text
    button.TextSize = 11
    button.TextColor3 = Color3.fromRGB(233, 237, 247)
    button.Parent = parent

    local corner = Instance.new("UICorner")
    corner.CornerRadius = UDim.new(0, 9)
    corner.Parent = button

    return button
end

-- Dashboard -----------------------------------------------------------------

local dashboardValues = {}
dashboardValues.cash = createInfoRow(dashboardPage, 0, "Cash / Money")
dashboardValues.fish = createInfoRow(dashboardPage, 39, "Fish Stat")
dashboardValues.session = createInfoRow(dashboardPage, 78, "Session")
dashboardValues.objects = createInfoRow(dashboardPage, 117, "World Objects")
dashboardValues.prompts = createInfoRow(dashboardPage, 156, "Prompts")
dashboardValues.warning = createInfoRow(dashboardPage, 195, "Event Warning")

local refreshButton = createActionButton(dashboardPage, 0, 240, 0.49, "Refresh Scan")
local autoButton = createActionButton(dashboardPage, 0.51, 240, 0.49, "Auto Refresh: ON")
autoButton.BackgroundColor3 = Color3.fromRGB(25, 48, 37)
autoButton.TextColor3 = Color3.fromRGB(168, 237, 188)

-- Teleport ------------------------------------------------------------------

local teleportTitle = Instance.new("TextLabel")
teleportTitle.BackgroundTransparency = 1
teleportTitle.Size = UDim2.new(1, 0, 0, 24)
teleportTitle.Font = Enum.Font.GothamMedium
teleportTitle.Text = "Adaptive Location Teleports"
teleportTitle.TextSize = 12
teleportTitle.TextColor3 = Color3.fromRGB(218, 223, 237)
teleportTitle.TextXAlignment = Enum.TextXAlignment.Left
teleportTitle.Parent = teleportPage

local teleportHint = Instance.new("TextLabel")
teleportHint.BackgroundTransparency = 1
teleportHint.Position = UDim2.fromOffset(0, 25)
teleportHint.Size = UDim2.new(1, 0, 0, 30)
teleportHint.Font = Enum.Font.Gotham
teleportHint.Text = "DChronos scans the live map instead of relying on one fixed coordinate."
teleportHint.TextWrapped = true
teleportHint.TextSize = 10
teleportHint.TextColor3 = Color3.fromRGB(127, 137, 155)
teleportHint.TextXAlignment = Enum.TextXAlignment.Left
teleportHint.TextYAlignment = Enum.TextYAlignment.Top
teleportHint.Parent = teleportPage

local dockButton = createActionButton(teleportPage, 0, 63, 0.49, "Teleport Dock")
local aquariumButton = createActionButton(teleportPage, 0.51, 63, 0.49, "Teleport Aquarium")
local boatButton = createActionButton(teleportPage, 0, 108, 0.49, "Teleport Boat")
local spawnButton = createActionButton(teleportPage, 0.51, 108, 0.49, "Teleport Spawn")

local emergencyButton = createActionButton(teleportPage, 0, 153, 1, "⚠ Emergency Dock")
emergencyButton.BackgroundColor3 = Color3.fromRGB(54, 39, 22)
emergencyButton.TextColor3 = Color3.fromRGB(250, 211, 145)

local savePositionButton = createActionButton(teleportPage, 0, 198, 0.49, "Save Position")
local returnButton = createActionButton(teleportPage, 0.51, 198, 0.49, "Return")
local rescanButton = createActionButton(teleportPage, 0, 243, 1, "Rescan Teleport Targets")

-- Tracker -------------------------------------------------------------------

local trackerValues = {}
trackerValues.dock = createInfoRow(trackerPage, 0, "Dock")
trackerValues.aquarium = createInfoRow(trackerPage, 39, "Aquarium")
trackerValues.boat = createInfoRow(trackerPage, 78, "Boat")
trackerValues.spawn = createInfoRow(trackerPage, 117, "Spawn")
trackerValues.lastTeleport = createInfoRow(trackerPage, 156, "Last Teleport")
trackerValues.saved = createInfoRow(trackerPage, 195, "Return Point")

local trackerScanButton = createActionButton(trackerPage, 0, 240, 1, "Rescan & Refresh Tracker")


-- Fishing -------------------------------------------------------------------

local fishingValues = {}
fishingValues.filter = createInfoRow(fishingPage, 0, "Rarity Filter")
fishingValues.target = createInfoRow(fishingPage, 39, "Target Fish")
fishingValues.rarity = createInfoRow(fishingPage, 78, "Target Rarity")
fishingValues.distance = createInfoRow(fishingPage, 117, "Target Distance")

local rarityButton = createActionButton(fishingPage, 0, 160, 1, "Rarity Filter: Any")
local targetModeButton = createActionButton(fishingPage, 0, 205, 0.49, "Target: Best Fish")
local mutatedOnlyButton = createActionButton(fishingPage, 0.51, 205, 0.49, "Mutation Only: OFF")
local autoFishingButton = createActionButton(fishingPage, 0, 250, 0.49, "Auto Fishing: OFF")
local autoApproachButton = createActionButton(fishingPage, 0.51, 250, 0.49, "Auto Approach: OFF")
local scanFishButton = createActionButton(fishingPage, 0, 295, 1, "Scan / Select Fish Target")
local calibrateGestureButton = createActionButton(fishingPage, 0, 340, 1, "Calibrate iPad Claw Gesture (13s)")
local testApproachButton = createActionButton(fishingPage, 0, 385, 0.49, "Test Approach Now")
local testClawButton = createActionButton(fishingPage, 0.51, 385, 0.49, "Test Claw • ContextAction")

autoFishingButton.BackgroundColor3 = Color3.fromRGB(45, 35, 29)
autoFishingButton.TextColor3 = Color3.fromRGB(233, 198, 159)



-- Debug ---------------------------------------------------------------------

local debugInfo = Instance.new("TextLabel")
debugInfo.BackgroundTransparency = 1
debugInfo.Size = UDim2.new(1, 0, 0, 105)
debugInfo.Font = Enum.Font.Gotham
debugInfo.Text = "ATM Target Engine: DChronos independently reproduces the observed target/filter flow (Best Fish, Catch Any, Mutation Hunt) using replicated metadata + FishUpdate.\n\nDirect CatchFish/ConfirmCatch remote execution from Ouroboros is intentionally not copied."
debugInfo.TextWrapped = true
debugInfo.TextSize = 11
debugInfo.TextColor3 = Color3.fromRGB(158, 166, 184)
debugInfo.TextXAlignment = Enum.TextXAlignment.Left
debugInfo.TextYAlignment = Enum.TextYAlignment.Top
debugInfo.Parent = debugPage

local runtimeStatus = createInfoRow(debugPage, 112, "Runtime Scan")
runtimeStatus.Text = "Not scanned"

local clawStatus = createInfoRow(debugPage, 151, "Claw Button")
clawStatus.Text = "Unknown"

local boatStatus = createInfoRow(debugPage, 190, "Player Boat")
boatStatus.Text = "Unknown"

local runDiagnosticsButton = createActionButton(debugPage, 0, 235, 0.49, "Scan Runtime")
local copyDiagnosticsButton = createActionButton(debugPage, 0.51, 235, 0.49, "Copy Report")

local protocolStartButton = createActionButton(debugPage, 0, 280, 0.32, "Record Mobile Catch")
local protocolStopButton = createActionButton(debugPage, 0.34, 280, 0.32, "Stop")
local protocolCopyButton = createActionButton(debugPage, 0.68, 280, 0.32, "Copy Protocol")

protocolStartButton.BackgroundColor3 = Color3.fromRGB(24, 48, 36)
protocolStartButton.TextColor3 = Color3.fromRGB(168, 237, 188)

protocolStartButton.MouseButton1Click:Connect(function()
    local hookOk, hookStatus, listenerCount = startProtocolRecording()

    if MOBILE_SAFE_MODE then
        setStatus(
            "Mobile Safe recording ON • manually catch ONE fish now",
            "good"
        )
    elseif hookOk then
        setStatus(
            "Protocol recording ON • manually catch ONE fish now",
            "good"
        )
    else
        setStatus(
            "Passive recording ON; outgoing hook unavailable: " .. tostring(hookStatus),
            "warn"
        )
    end

    protocolStartButton.Text = "Recording..."
    runtimeStatus.Text = tostring(listenerCount) .. " listeners"
end)

protocolStopButton.MouseButton1Click:Connect(function()
    stopProtocolRecording()
    protocolStartButton.Text = "Record Mobile Catch"
    runtimeStatus.Text = tostring(#protocolState.logs) .. " events"
    setStatus("Protocol recording stopped", "good")
end)

protocolCopyButton.MouseButton1Click:Connect(function()
    stopProtocolRecording()
    local report = buildProtocolReport()
    local copied = copyText(report)

    protocolStartButton.Text = "Record Mobile Catch"
    runtimeStatus.Text = tostring(#protocolState.logs) .. " events"

    if copied then
        protocolCopyButton.Text = "Copied!"
        setStatus("Protocol report copied", "good")
    else
        protocolCopyButton.Text = "Printed"
        setStatus("Clipboard unavailable • protocol printed to console", "warn")
    end

    task.wait(1)
    protocolCopyButton.Text = "Copy Protocol"
end)

local function refreshDebugStatus()
    local clawButton = findClawControlButton()
    local boat, _, method = getPlayerBoat()

    clawStatus.Text = clawButton and clawButton.Name or "Not found"
    boatStatus.Text = boat and (boat.Name .. " • " .. tostring(method)) or "Not found"
end

runDiagnosticsButton.MouseButton1Click:Connect(function()
    runDiagnosticsButton.Text = "Scanning..."

    task.spawn(function()
        local report = buildDiagnosticReport()
        runtimeStatus.Text = tostring(#report) .. " chars"
        refreshDebugStatus()
        print(report)
        setStatus("Runtime diagnostic complete • open console or Copy Report", "good")
        task.wait(0.2)
        runDiagnosticsButton.Text = "Scan Runtime"
    end)
end)

copyDiagnosticsButton.MouseButton1Click:Connect(function()
    local copied, report = copyDiagnosticReport()
    runtimeStatus.Text = tostring(#report) .. " chars"

    if copied then
        setStatus("Diagnostic report copied to clipboard", "good")
        copyDiagnosticsButton.Text = "Copied!"
    else
        setStatus("Clipboard unavailable • report printed to console", "warn")
        copyDiagnosticsButton.Text = "Printed to Console"
    end

    task.wait(1.2)
    copyDiagnosticsButton.Text = "Copy Report"
end)


-- Footer
local closeButton = Instance.new("TextButton")
closeButton.AnchorPoint = Vector2.new(0.5, 1)
closeButton.Position = UDim2.new(0.5, 0, 1, -8)
closeButton.Size = UDim2.new(1, -40, 0, 25)
closeButton.BackgroundTransparency = 1
closeButton.Font = Enum.Font.Gotham
closeButton.Text = "Close DChronos Module"
closeButton.TextSize = 10
closeButton.TextColor3 = Color3.fromRGB(124, 133, 151)
closeButton.Parent = main

-- Live UI logic --------------------------------------------------------------

local function targetSummary(name)
    local target = locateTarget(name, false)

    if not target then
        return "Not found"
    end

    return string.format(
        "%s • %.0f studs",
        target.instance.Name,
        target.distance or 0
    )
end

local function refreshTracker(force)
    if force then
        rescanTargets()
    end

    trackerValues.dock.Text = targetSummary("Dock")
    trackerValues.aquarium.Text = targetSummary("Aquarium")
    trackerValues.boat.Text = targetSummary("Boat")
    trackerValues.spawn.Text = targetSummary("Spawn")
    trackerValues.lastTeleport.Text = state.lastTeleportName
    if state.savedPositionCFrame then
        trackerValues.saved.Text = "Manual saved"
    elseif state.lastPreTeleportCFrame then
        trackerValues.saved.Text = "Previous position"
    else
        trackerValues.saved.Text = "None"
    end
end


local function refreshFishing(forceScan)
    local target = state.fishing.currentTarget

    if forceScan or not target then
        target = scanFishTarget()
        updateFishHighlight(target)
    elseif target.id then
        local fish = state.fishing.networkFish[target.id]
        local livePos = fish and getNetworkFishPosition(fish)

        if livePos then
            target.position = livePos
            target.cframe = CFrame.new(livePos)
            local origin = getFishingOrigin()
            target.distance = (livePos - origin).Magnitude
            state.fishing.currentDistance = target.distance

            if fishHighlight and fishHighlight.Parent then
                fishHighlight.CFrame = CFrame.new(livePos)
            end
        else
            state.fishing.currentTarget = nil
            target = scanFishTarget()
            updateFishHighlight(target)
        end
    end

    local filter = RARITY_FILTERS[state.fishing.filterIndex]
    fishingValues.filter.Text = filter.name

    if target then
        fishingValues.target.Text =
            target.speciesName
            or ("Species #" .. tostring(target.speciesId or "?"))

        local rarityText = target.rarity or "Unknown"

        if target.mutation then
            rarityText = rarityText .. " • " .. tostring(target.mutation)
        end

        fishingValues.rarity.Text = rarityText
        fishingValues.distance.Text = string.format(
            "%.0f studs • %d candidates • %s",
            tonumber(target.distance) or 0,
            state.fishing.candidates,
            tostring(target.targetMode or state.fishing.targetModeName)
        )
    else
        fishingValues.target.Text = state.fishing.networkReady
            and "No matching target"
            or "Waiting for FishUpdate"

        fishingValues.rarity.Text =
            state.fishing.speciesCatalogCount > 0
            and ("Catalog: " .. tostring(state.fishing.speciesCatalogCount))
            or "Rarity metadata not resolved"

        local fishCount = 0
        for _ in pairs(state.fishing.networkFish) do
            fishCount += 1
        end

        fishingValues.distance.Text = tostring(fishCount) .. " network fish tracked"
    end
end

local function refreshDashboard(forceScan)
    local cash, cashName = findValueByNames({
        "Cash", "Money", "Coins", "Coin", "Currency"
    })

    local fish, fishName = findValueByNames({
        "Fish", "Fishes", "CaughtFish", "FishCaught"
    })

    dashboardValues.cash.Text = cash ~= nil
        and ((cashName or "Cash") .. ": " .. formatNumber(cash))
        or "Not exposed"

    dashboardValues.fish.Text = fish ~= nil
        and ((fishName or "Fish") .. ": " .. formatNumber(fish))
        or "Not exposed"

    local elapsed = math.max(0, os.clock() - state.startedAt)
    dashboardValues.session.Text = string.format(
        "%02d:%02d:%02d",
        math.floor(elapsed / 3600),
        math.floor(elapsed / 60) % 60,
        math.floor(elapsed) % 60
    )

    if forceScan then
        state.scan = scanWorkspaceCounts()
        rescanTargets()
    end

    dashboardValues.objects.Text = string.format(
        "Fish %d • Claw %d • Boat %d • Tank %d",
        state.scan.fish,
        state.scan.claw,
        state.scan.boat,
        state.scan.aquarium
    )

    dashboardValues.prompts.Text = tostring(state.scan.prompts)

    state.lastWarning = detectWarningText()
    state.warningActive = state.lastWarning ~= "No tsunami warning detected"
    dashboardValues.warning.Text = state.lastWarning

    if state.warningActive then
        dashboardValues.warning.TextColor3 = Color3.fromRGB(255, 202, 122)
        setStatus("⚠ Event warning detected • Emergency Dock is ready", "warn")
    else
        dashboardValues.warning.TextColor3 = Color3.fromRGB(225, 229, 239)
    end
end

local function doTargetTeleport(targetName)
    setStatus("Locating " .. targetName .. "...", "neutral")

    task.spawn(function()
        local ok, message = teleportToTarget(targetName)

        if ok then
            setStatus("Teleported to " .. targetName, "good")
            refreshTracker(false)
        else
            setStatus(message or ("Unable to locate " .. targetName), "bad")
        end
    end)
end

dockButton.MouseButton1Click:Connect(function()
    doTargetTeleport("Dock")
end)

aquariumButton.MouseButton1Click:Connect(function()
    doTargetTeleport("Aquarium")
end)

boatButton.MouseButton1Click:Connect(function()
    doTargetTeleport("Boat")
end)

spawnButton.MouseButton1Click:Connect(function()
    doTargetTeleport("Spawn")
end)

emergencyButton.MouseButton1Click:Connect(function()
    setStatus("Emergency Dock: scanning...", "warn")

    task.spawn(function()
        local ok, message = teleportToTarget("Dock")

        if ok then
            setStatus("Emergency Dock complete", "good")
            refreshTracker(false)
        else
            setStatus(message or "Dock target not found", "bad")
        end
    end)
end)

savePositionButton.MouseButton1Click:Connect(function()
    local _, root = getCharacter()

    if not root then
        setStatus("Cannot save position: character unavailable", "bad")
        return
    end

    state.savedPositionCFrame = root.CFrame
    setStatus("Current position saved", "good")
    refreshTracker(false)
end)

returnButton.MouseButton1Click:Connect(function()
    local returnPoint = state.savedPositionCFrame or state.lastPreTeleportCFrame

    if not returnPoint then
        setStatus("No saved or previous position is available", "warn")
        return
    end

    local label = state.savedPositionCFrame and "Saved Position" or "Previous Position"

    local _, root = getCharacter()
    if not root then
        setStatus("Return failed: character unavailable", "bad")
        return
    end

    stopCharacterVelocity(root)
    root.CFrame = returnPoint
    stopCharacterVelocity(root)

    state.lastTeleportName = label
    setStatus("Returned to " .. label, "good")
    refreshTracker(false)
end)

rescanButton.MouseButton1Click:Connect(function()
    setStatus("Rescanning map targets...", "neutral")

    task.spawn(function()
        rescanTargets()
        refreshTracker(false)
        setStatus("Teleport targets refreshed", "good")
    end)
end)

trackerScanButton.MouseButton1Click:Connect(function()
    setStatus("Refreshing tracker...", "neutral")

    task.spawn(function()
        refreshTracker(true)
        setStatus("Tracker refreshed", "good")
    end)
end)

refreshButton.MouseButton1Click:Connect(function()
    refreshButton.Text = "Scanning..."

    task.spawn(function()
        state.scan = scanWorkspaceCounts()
        refreshDashboard(true)
        refreshTracker(false)
        task.wait(0.15)
        refreshButton.Text = "Refresh Scan"
        setStatus("World scan complete", "good")
    end)
end)

autoButton.MouseButton1Click:Connect(function()
    state.autoRefresh = not state.autoRefresh

    if state.autoRefresh then
        autoButton.Text = "Auto Refresh: ON"
        autoButton.BackgroundColor3 = Color3.fromRGB(25, 48, 37)
        autoButton.TextColor3 = Color3.fromRGB(168, 237, 188)
        setStatus("Auto refresh enabled", "good")
    else
        autoButton.Text = "Auto Refresh: OFF"
        autoButton.BackgroundColor3 = Color3.fromRGB(45, 35, 29)
        autoButton.TextColor3 = Color3.fromRGB(233, 198, 159)
        setStatus("Auto refresh disabled", "warn")
    end
end)




testApproachButton.MouseButton1Click:Connect(function()
    testApproachButton.Text = "Moving..."

    task.spawn(function()
        local target = scanFishTarget()
        updateFishHighlight(target)

        if not target then
            setStatus("Test Approach: no network fish target", "warn")
            testApproachButton.Text = "Test Approach Now"
            return
        end

        local ok, message, distance = approachFishWithBoat(target)

        if ok then
            setStatus(
                "Test Approach OK • "
                    .. tostring(message)
                    .. (distance and (" • " .. string.format("%.0f studs", distance)) or ""),
                "good"
            )
        else
            setStatus("Test Approach failed: " .. tostring(message), "bad")
        end

        task.wait(0.7)
        testApproachButton.Text = "Test Approach Now"
    end)
end)

testClawButton.MouseButton1Click:Connect(function()
    testClawButton.Text = "Testing strategy..."

    task.spawn(function()
        local index = state.fishing.inputStrategyIndex
        local ok, message, strategy = sendClawInput(index)

        if ok then
            setStatus(
                "Test Claw sent • "
                    .. tostring(strategy)
                    .. " • "
                    .. tostring(message),
                "good"
            )
        else
            local nextStrategy = rotateInputStrategy()
            setStatus(
                "Test "
                    .. tostring(strategy)
                    .. " failed • next: "
                    .. tostring(nextStrategy)
                    .. " • "
                    .. tostring(message),
                "warn"
            )
        end

        task.wait(1.0)
        testClawButton.Text =
            "Test Claw • "
            .. tostring(INPUT_STRATEGIES[state.fishing.inputStrategyIndex])
    end)
end)

calibrateGestureButton.MouseButton1Click:Connect(function()
    calibrateGestureButton.Text = "Recording... perform ONE normal catch"

    local ok, message = beginMobileGestureCalibration()

    if not ok then
        calibrateGestureButton.Text = "Calibrate iPad Claw Gesture (13s)"
        setStatus(tostring(message), "bad")
        return
    end

    setStatus(
        "Calibration started • DChronos hidden • perform ONE normal claw catch",
        "good"
    )

    task.spawn(function()
        task.wait(13.4)

        if state.mobileMacro.calibrated then
            calibrateGestureButton.Text =
                "Gesture Ready • "
                .. tostring(#state.mobileMacro.events)
                .. " events"
        else
            calibrateGestureButton.Text = "Calibrate iPad Claw Gesture (13s)"
        end
    end)
end)


targetModeButton.MouseButton1Click:Connect(function()
    state.fishing.targetModeIndex += 1

    if state.fishing.targetModeIndex > #TARGET_MODES then
        state.fishing.targetModeIndex = 1
    end

    local mode = TARGET_MODES[state.fishing.targetModeIndex]
    targetModeButton.Text = "Target: " .. mode

    local target = scanFishTarget()
    updateFishHighlight(target)
    refreshFishing(false)

    setStatus("Target mode: " .. mode, "good")
end)

mutatedOnlyButton.MouseButton1Click:Connect(function()
    state.fishing.mutatedOnly = not state.fishing.mutatedOnly

    mutatedOnlyButton.Text =
        state.fishing.mutatedOnly
        and "Mutation Only: ON"
        or "Mutation Only: OFF"

    if state.fishing.mutatedOnly then
        mutatedOnlyButton.BackgroundColor3 = Color3.fromRGB(25, 48, 37)
        mutatedOnlyButton.TextColor3 = Color3.fromRGB(168, 237, 188)
    else
        mutatedOnlyButton.BackgroundColor3 = Color3.fromRGB(31, 37, 51)
        mutatedOnlyButton.TextColor3 = Color3.fromRGB(233, 237, 247)
    end

    local target = scanFishTarget()
    updateFishHighlight(target)
    refreshFishing(false)

    setStatus(
        state.fishing.mutatedOnly
            and "Mutation-only targeting enabled"
            or "Mutation-only targeting disabled",
        "good"
    )
end)

rarityButton.MouseButton1Click:Connect(function()
    state.fishing.filterIndex += 1

    if state.fishing.filterIndex > #RARITY_FILTERS then
        state.fishing.filterIndex = 1
    end

    local filter = RARITY_FILTERS[state.fishing.filterIndex]
    rarityButton.Text = "Rarity Filter: " .. filter.name

    if filter.minRank > 0 and state.fishing.speciesCatalogCount == 0 then
        setStatus(
            "Live rarity catalog not found • filter may return no fish; Any still works",
            "warn"
        )
    end

    local target = scanFishTarget()
    updateFishHighlight(target)
    refreshFishing(false)

    setStatus("Fish rarity filter: " .. filter.name, "good")
end)

scanFishButton.MouseButton1Click:Connect(function()
    scanFishButton.Text = "Scanning fish..."

    task.spawn(function()
        local target = scanFishTarget()
        updateFishHighlight(target)
        refreshFishing(false)

        if target then
            local mutationText =
                target.mutation
                and (" • " .. tostring(target.mutation))
                or ""

            setStatus(
                "Target selected: "
                    .. tostring(target.speciesName or target.label or target.id)
                    .. " • "
                    .. tostring(target.rarity)
                    .. mutationText,
                "good"
            )
        else
            setStatus("No fish matched the current rarity filter", "warn")
        end

        task.wait(0.15)
        scanFishButton.Text = "Scan / Select Fish Target"
    end)
end)

autoFishingButton.MouseButton1Click:Connect(function()
    state.fishing.autoFishing = not state.fishing.autoFishing

    if state.fishing.autoFishing then
        autoFishingButton.Text = "Auto Fishing: ON"
        autoFishingButton.BackgroundColor3 = Color3.fromRGB(25, 48, 37)
        autoFishingButton.TextColor3 = Color3.fromRGB(168, 237, 188)
        setStatus(
            "Auto Fishing ON • strategy: "
                .. tostring(INPUT_STRATEGIES[state.fishing.inputStrategyIndex])
                .. " • weather pause OFF",
            "good"
        )
    else
        autoFishingButton.Text = "Auto Fishing: OFF"
        autoFishingButton.BackgroundColor3 = Color3.fromRGB(45, 35, 29)
        autoFishingButton.TextColor3 = Color3.fromRGB(233, 198, 159)
        setStatus("Auto Fishing disabled", "warn")
    end
end)

autoApproachButton.MouseButton1Click:Connect(function()
    state.fishing.autoApproach = not state.fishing.autoApproach

    if state.fishing.autoApproach then
        autoApproachButton.Text = "Auto Approach: ON"
        autoApproachButton.BackgroundColor3 = Color3.fromRGB(25, 48, 37)
        autoApproachButton.TextColor3 = Color3.fromRGB(168, 237, 188)
        setStatus("Auto Approach enabled • stay seated in your boat", "good")
    else
        autoApproachButton.Text = "Auto Approach: OFF"
        autoApproachButton.BackgroundColor3 = Color3.fromRGB(31, 37, 51)
        autoApproachButton.TextColor3 = Color3.fromRGB(233, 237, 247)
        setStatus("Auto Approach disabled", "neutral")
    end
end)

local function setMenuVisible(visible)
    state.visible = visible
    main.Visible = visible
    floatButton.Visible = not visible
end

minimize.MouseButton1Click:Connect(function()
    setMenuVisible(false)
end)

closeButton.MouseButton1Click:Connect(function()
    stopProtocolRecording()
    disconnectProtocolConnections()
    clearMacroConnections()

    if networkRadarConnection then
        pcall(function()
            networkRadarConnection:Disconnect()
        end)
        networkRadarConnection = nil
    end

    if fishHighlight then
        fishHighlight:Destroy()
        fishHighlight = nil
    end

    gui:Destroy()
end)

local function makeDraggable(target, handle)
    local dragging = false
    local dragStart
    local startPos
    local moved = false

    handle.InputBegan:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1
            or input.UserInputType == Enum.UserInputType.Touch then
            dragging = true
            moved = false
            dragStart = input.Position
            startPos = target.Position
        end
    end)

    handle.InputEnded:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1
            or input.UserInputType == Enum.UserInputType.Touch then
            dragging = false
        end
    end)

    UserInputService.InputChanged:Connect(function(input)
        if dragging and (
            input.UserInputType == Enum.UserInputType.MouseMovement
            or input.UserInputType == Enum.UserInputType.Touch
        ) then
            local delta = input.Position - dragStart

            if delta.Magnitude > 4 then
                moved = true
            end

            target.Position = UDim2.new(
                startPos.X.Scale,
                startPos.X.Offset + delta.X,
                startPos.Y.Scale,
                startPos.Y.Offset + delta.Y
            )
        end
    end)

    return function()
        return moved
    end
end

makeDraggable(main, header)
local floatWasMoved = makeDraggable(floatButton, floatButton)

-- A click restores the menu; dragging only repositions the floating button.
floatButton.MouseButton1Click:Connect(function()
    if not floatWasMoved() then
        setMenuVisible(true)
    end
end)

gui.Parent = playerGui

switchTab("Dashboard")

task.spawn(function()
    startNetworkFishRadar()

    -- Replicated metadata modules may arrive slightly after the module starts.
    task.spawn(function()
        for attempt = 1, 5 do
            local count = rebuildSpeciesCatalog()

            if count > 0 then
                break
            end

            task.wait(1.25)
        end
    end)

    state.scan = scanWorkspaceCounts()
    rescanTargets()
    refreshDashboard(false)
    refreshTracker(false)
    refreshFishing(true)
end)

task.spawn(function()
    local scanTicker = 0

    while gui.Parent do
        task.wait(1)

        if state.autoRefresh then
            scanTicker += 1

            pcall(function()
                refreshDashboard(scanTicker % 5 == 0)

                if scanTicker % 5 == 0 then
                    refreshTracker(false)
                    refreshFishing(true)
                else
                    refreshFishing(false)
                end
            end)
        else
            pcall(function()
                refreshDashboard(false)
                refreshFishing(false)
            end)
        end
    end
end)

task.spawn(function()
    while gui.Parent do
        task.wait(0.45)

        if state.fishing.autoApproach
            and not state.fishing.autoApproachBusy
            and os.clock() - state.fishing.lastApproachAt >= 1.25 then

            state.fishing.autoApproachBusy = true
            state.fishing.lastApproachAt = os.clock()

            local ok, err = pcall(function()
                local target = scanFishTarget()

                if not target then
                    setStatus("Auto Approach: waiting for network fish", "warn")
                    return
                end

                updateFishHighlight(target)

                local moved, message, distance = approachFishWithBoat(target)

                if moved then
                    if distance and distance <= 18 then
                        setStatus(
                            "Auto Approach ready • target within claw range",
                            "good"
                        )
                    else
                        setStatus(
                            "Auto Approach • " .. tostring(message),
                            "good"
                        )
                    end
                else
                    setStatus(
                        "Auto Approach failed: " .. tostring(message),
                        "bad"
                    )
                end
            end)

            if not ok then
                setStatus("Auto Approach error: " .. tostring(err), "bad")
            end

            state.fishing.autoApproachBusy = false
        end
    end
end)

task.spawn(function()
    while gui.Parent do
        task.wait(0.55)

        if state.fishing.autoFishing then
            pcall(runAutoFishingCycle)
        end
    end
end)

print("[DChronos Native] Claw Fishing ATM Target Engine v1.3.1 loaded.")
