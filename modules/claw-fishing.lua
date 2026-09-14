--[[
    DChronos Native Module
    Game: Claw Fishing
    Edition: Smart Fishing v1.2.4

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
local MODULE_VERSION = "1.2.4"

if tonumber(game.PlaceId) ~= EXPECTED_PLACE_ID
    and tonumber(game.GameId) ~= EXPECTED_UNIVERSE_ID then
    warn("[DChronos/ClawFishing] Wrong game.")
    return
end

local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")
local UserInputService = game:GetService("UserInputService")

local VirtualInputManager = nil
pcall(function()
    VirtualInputManager = game:GetService("VirtualInputManager")
end)

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
        filterIndex = 2, -- Rare+
        currentTarget = nil,
        currentRarity = "Unknown",
        currentRank = 0,
        currentDistance = math.huge,
        candidates = 0,
        busy = false,
        lastCycleAt = 0,
        cycleDelay = 3.0,
        pauseOnWarning = true,
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

local function rarityFromText(value)
    local text = lower(value)

    for alias, rank in pairs(RARITY_ALIASES) do
        if text == alias or text:find(alias, 1, true) then
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

local function looksLikeFish(instance)
    if not instance then
        return false
    end

    if not (instance:IsA("Model") or instance:IsA("BasePart")) then
        return false
    end

    local n = lower(instance.Name)
    local path = lower(fullNameSafe(instance))

    for _, keyword in ipairs(FISH_KEYWORDS) do
        if n:find(keyword, 1, true) or path:find(keyword, 1, true) then
            return true
        end
    end

    local rank = readRarityFromObject(instance)
    return rank ~= nil and rank > 0
end

local function getFishingOrigin()
    local boat = nil
    local character = player.Character
    local humanoid = character and character:FindFirstChildOfClass("Humanoid")

    if humanoid then
        for _, obj in ipairs(Workspace:GetDescendants()) do
            if (obj:IsA("VehicleSeat") or obj:IsA("Seat"))
                and obj.Occupant == humanoid then
                local model = obj:FindFirstAncestorOfClass("Model")
                if model then
                    boat = model
                    break
                end
            end
        end
    end

    if boat then
        local cf = getObjectCFrame(boat)
        if cf then
            return cf.Position, boat
        end
    end

    local _, root = getCharacter()
    return root and root.Position or Vector3.new(), boat
end

local function getPlayerBoat()
    local character = player.Character
    local humanoid = character and character:FindFirstChildOfClass("Humanoid")

    if not humanoid then
        return nil
    end

    for _, obj in ipairs(Workspace:GetDescendants()) do
        if (obj:IsA("VehicleSeat") or obj:IsA("Seat"))
            and obj.Occupant == humanoid then
            return obj:FindFirstAncestorOfClass("Model"), obj
        end
    end

    return nil
end

local function getPlayerClaw(origin)
    local best = nil
    local bestScore = -math.huge
    local playerName = lower(player.Name)
    local userId = tostring(player.UserId)

    for _, obj in ipairs(Workspace:GetDescendants()) do
        if obj:IsA("Model") or obj:IsA("BasePart") then
            local n = lower(obj.Name)
            local path = lower(fullNameSafe(obj))

            if n:find("claw", 1, true)
                or n:find("hook", 1, true)
                or n:find("crane", 1, true) then

                local cf = getObjectCFrame(obj)
                if cf then
                    local score = 0

                    if path:find(playerName, 1, true) then
                        score += 80
                    end

                    if path:find(userId, 1, true) then
                        score += 80
                    end

                    local distance = (cf.Position - origin).Magnitude
                    score += math.max(0, 50 - distance / 5)

                    if score > bestScore then
                        bestScore = score
                        best = obj
                    end
                end
            end
        end
    end

    return best
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

local function scanFishTarget()
    local origin = getFishingOrigin()
    local best = nil
    local bestScore = -math.huge
    local candidates = 0

    for _, obj in ipairs(Workspace:GetDescendants()) do
        if obj:IsA("Model") and looksLikeFish(obj) then
            local cf = getObjectCFrame(obj)

            if cf then
                local rank, rarity = readRarityFromObject(obj)

                if fishMatchesFilter(rank or 0) then
                    candidates += 1

                    local distance = (cf.Position - origin).Magnitude
                    -- Rarity is prioritized first, then proximity.
                    local score = ((rank or 0) * 100000) - distance

                    if score > bestScore then
                        bestScore = score
                        best = {
                            instance = obj,
                            cframe = cf,
                            rank = rank or 0,
                            rarity = rarity or "Unknown",
                            distance = distance,
                        }
                    end
                end
            end
        end
    end

    -- Fallback to loose parts if no model target was found.
    if not best then
        for _, obj in ipairs(Workspace:GetDescendants()) do
            if obj:IsA("BasePart") and looksLikeFish(obj) then
                local rank, rarity = readRarityFromObject(obj)

                if fishMatchesFilter(rank or 0) then
                    local cf = obj.CFrame
                    candidates += 1
                    local distance = (cf.Position - origin).Magnitude
                    local score = ((rank or 0) * 100000) - distance

                    if score > bestScore then
                        bestScore = score
                        best = {
                            instance = obj,
                            cframe = cf,
                            rank = rank or 0,
                            rarity = rarity or "Unknown",
                            distance = distance,
                        }
                    end
                end
            end
        end
    end

    state.fishing.currentTarget = best and best.instance or nil
    state.fishing.currentRarity = best and best.rarity or "None"
    state.fishing.currentRank = best and best.rank or 0
    state.fishing.currentDistance = best and best.distance or math.huge
    state.fishing.candidates = candidates

    return best
end

local function updateFishHighlight(target)
    if fishHighlight then
        fishHighlight:Destroy()
        fishHighlight = nil
    end

    if not target or not target.instance or not target.instance.Parent then
        return
    end

    local highlight = Instance.new("Highlight")
    highlight.Name = "DChronosFishTarget"
    highlight.Adornee = target.instance
    highlight.FillTransparency = 0.78
    highlight.OutlineTransparency = 0.05
    highlight.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
    highlight.Parent = Workspace
    fishHighlight = highlight
end

local function approachFishWithBoat(target)
    if not target or not target.cframe then
        return false, "Fish target unavailable"
    end

    local boat = getPlayerBoat()
    if not boat then
        return false, "Sit in your boat first"
    end

    local current = getObjectCFrame(boat)
    if not current then
        return false, "Boat pivot unavailable"
    end

    local fishPos = target.cframe.Position
    local currentPos = current.Position
    local rotation = current - current.Position
    local destination = CFrame.new(
        fishPos.X,
        currentPos.Y,
        fishPos.Z + 7
    ) * rotation

    local ok, err = pcall(function()
        boat:PivotTo(destination)
    end)

    if not ok then
        return false, tostring(err)
    end

    return true
end

local function sendClawInput()
    if not VirtualInputManager then
        return false, "VirtualInputManager unavailable"
    end

    local camera = Workspace.CurrentCamera
    local viewport = camera and camera.ViewportSize or Vector2.new(800, 600)
    local x = math.floor(viewport.X / 2)
    local y = math.floor(viewport.Y / 2)

    local ok, err = pcall(function()
        -- Recorded PC play uses Space to lower the crane and a click to grab.
        VirtualInputManager:SendKeyEvent(true, Enum.KeyCode.Space, false, game)
        task.wait(1.1)
        VirtualInputManager:SendMouseButtonEvent(x, y, 0, true, game, 0)
        task.wait(0.08)
        VirtualInputManager:SendMouseButtonEvent(x, y, 0, false, game, 0)
        task.wait(0.18)
        VirtualInputManager:SendKeyEvent(false, Enum.KeyCode.Space, false, game)
    end)

    if not ok then
        return false, tostring(err)
    end

    return true
end

local function targetIsAligned(target)
    if not target or not target.cframe then
        return false, math.huge
    end

    local origin, boat = getFishingOrigin()
    local claw = getPlayerClaw(origin)

    local sourcePosition = origin

    if claw then
        local cf = getObjectCFrame(claw)
        if cf then
            sourcePosition = cf.Position
        end
    elseif boat then
        local cf = getObjectCFrame(boat)
        if cf then
            sourcePosition = cf.Position
        end
    end

    local fishPos = target.cframe.Position
    local horizontal = Vector3.new(
        fishPos.X - sourcePosition.X,
        0,
        fishPos.Z - sourcePosition.Z
    ).Magnitude

    return horizontal <= 24, horizontal
end

local function runAutoFishingCycle()
    if state.fishing.busy or not state.fishing.autoFishing then
        return
    end

    if state.fishing.pauseOnWarning and state.warningActive then
        setStatus("Auto Fishing paused: event warning detected", "warn")
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
        setStatus(
            "Auto Fishing: no fish matches "
                .. RARITY_FILTERS[state.fishing.filterIndex].name,
            "warn"
        )
        state.fishing.busy = false
        return
    end

    if state.fishing.autoApproach then
        local ok, message = approachFishWithBoat(target)
        if not ok then
            setStatus("Auto Approach: " .. tostring(message), "warn")
        else
            task.wait(0.45)
            target.cframe = getObjectCFrame(target.instance) or target.cframe
        end
    end

    local aligned, distance = targetIsAligned(target)

    if not aligned then
        setStatus(
            string.format(
                "Target %s (%s) is %.0f studs from claw",
                target.instance.Name,
                target.rarity,
                distance
            ),
            "warn"
        )
        state.fishing.busy = false
        return
    end

    setStatus(
        "Auto Fishing: claw cycle → "
            .. target.instance.Name
            .. " • "
            .. target.rarity,
        "good"
    )

    local ok, message = sendClawInput()

    if not ok then
        setStatus("Auto Fishing input failed: " .. tostring(message), "bad")
    end

    task.wait(1.2)
    state.fishing.busy = false
end


-- GUI -----------------------------------------------------------------------

local gui = Instance.new("ScreenGui")
gui.Name = "DChronosClawFishing"
gui.ResetOnSpawn = false
gui.IgnoreGuiInset = true

local floatButton = Instance.new("TextButton")
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

local main = Instance.new("Frame")
main.Name = "Main"
main.AnchorPoint = Vector2.new(0, 0.5)
main.Position = UDim2.new(0, 24, 0.5, 0)
main.Size = UDim2.fromOffset(430, 520)
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

local function setStatus(text, tone)
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
    page.Size = UDim2.new(1, -40, 0, 285)
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
    button.Size = UDim2.new(1/4, -6, 1, 0)
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

local dashboardPage = createPage("Dashboard")
local teleportPage = createPage("Teleport")
local trackerPage = createPage("Tracker")
local fishingPage = createPage("Fishing")

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

local rarityButton = createActionButton(fishingPage, 0, 160, 1, "Rarity Filter: Rare+")
local autoFishingButton = createActionButton(fishingPage, 0, 205, 0.49, "Auto Fishing: OFF")
local autoApproachButton = createActionButton(fishingPage, 0.51, 205, 0.49, "Auto Approach: OFF")
local scanFishButton = createActionButton(fishingPage, 0, 250, 1, "Scan / Select Fish Target")

autoFishingButton.BackgroundColor3 = Color3.fromRGB(45, 35, 29)
autoFishingButton.TextColor3 = Color3.fromRGB(233, 198, 159)


-- Footer
local closeButton = Instance.new("TextButton")
closeButton.AnchorPoint = Vector2.new(0.5, 1)
closeButton.Position = UDim2.new(0.5, 0, 1, -10)
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
    local target = nil

    if forceScan
        or not state.fishing.currentTarget
        or not state.fishing.currentTarget.Parent then
        target = scanFishTarget()
        updateFishHighlight(target)
    elseif state.fishing.currentTarget then
        local cf = getObjectCFrame(state.fishing.currentTarget)
        local origin = getFishingOrigin()

        if cf then
            state.fishing.currentDistance = (cf.Position - origin).Magnitude
        end
    end

    local filter = RARITY_FILTERS[state.fishing.filterIndex]
    fishingValues.filter.Text = filter.name

    if state.fishing.currentTarget and state.fishing.currentTarget.Parent then
        fishingValues.target.Text = state.fishing.currentTarget.Name
        fishingValues.rarity.Text = state.fishing.currentRarity
        fishingValues.distance.Text = string.format(
            "%.0f studs • %d candidates",
            state.fishing.currentDistance,
            state.fishing.candidates
        )
    else
        fishingValues.target.Text = "None"
        fishingValues.rarity.Text = "—"
        fishingValues.distance.Text = tostring(state.fishing.candidates) .. " candidates"
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


rarityButton.MouseButton1Click:Connect(function()
    state.fishing.filterIndex += 1

    if state.fishing.filterIndex > #RARITY_FILTERS then
        state.fishing.filterIndex = 1
    end

    local filter = RARITY_FILTERS[state.fishing.filterIndex]
    rarityButton.Text = "Rarity Filter: " .. filter.name

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
            setStatus(
                "Target selected: "
                    .. target.instance.Name
                    .. " • "
                    .. target.rarity,
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
        setStatus("Auto Fishing enabled (experimental)", "good")
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
        task.wait(0.55)

        if state.fishing.autoFishing then
            pcall(runAutoFishingCycle)
        end
    end
end)

print("[DChronos Native] Claw Fishing Smart Fishing v1.2.4 loaded.")
