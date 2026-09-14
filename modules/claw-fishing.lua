--[[
    DChronos Native Module
    Game: Claw Fishing
    PlaceId: 128931272139211
    UniverseId: 10008606756
    Creator/Group ID: 492855504

    This module is a DChronos-native diagnostics / session helper.
    It does not load or depend on third-party module code.
]]

local EXPECTED_PLACE_ID = 128931272139211
local EXPECTED_UNIVERSE_ID = 10008606756

if tonumber(game.PlaceId) ~= EXPECTED_PLACE_ID
    and tonumber(game.GameId) ~= EXPECTED_UNIVERSE_ID then
    warn("[DChronos/ClawFishing] Wrong game.")
    return
end

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

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

local existing = playerGui:FindFirstChild("DChronosClawFishing")
if existing then
    existing:Destroy()
end

local state = {
    startedAt = os.clock(),
    scan = {
        fish = 0,
        claw = 0,
        boat = 0,
        aquarium = 0,
    },
    warning = "No tsunami warning detected",
}

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

local function findValueByNames(names)
    local lookup = {}
    for _, name in ipairs(names) do
        lookup[string.lower(name)] = true
    end

    local leaderstats = player:FindFirstChild("leaderstats")
    if leaderstats then
        for _, child in ipairs(leaderstats:GetChildren()) do
            if lookup[string.lower(child.Name)]
                and child:IsA("ValueBase") then
                return child.Value, child.Name
            end
        end
    end

    for _, child in ipairs(player:GetDescendants()) do
        if lookup[string.lower(child.Name)]
            and child:IsA("ValueBase") then
            return child.Value, child.Name
        end
    end

    return nil, nil
end

local function scanWorkspace()
    local counts = {
        fish = 0,
        claw = 0,
        boat = 0,
        aquarium = 0,
    }

    local ok, descendants = pcall(function()
        return Workspace:GetDescendants()
    end)

    if not ok then
        return counts
    end

    for _, instance in ipairs(descendants) do
        local n = string.lower(instance.Name)

        if n:find("fish", 1, true) then
            counts.fish += 1
        end

        if n:find("claw", 1, true)
            or n:find("crane", 1, true) then
            counts.claw += 1
        end

        if n:find("boat", 1, true)
            or n:find("ship", 1, true) then
            counts.boat += 1
        end

        if n:find("aquarium", 1, true)
            or n:find("tank", 1, true) then
            counts.aquarium += 1
        end
    end

    return counts
end

local function detectWarningText()
    local best = nil

    for _, obj in ipairs(playerGui:GetDescendants()) do
        if (obj:IsA("TextLabel") or obj:IsA("TextButton"))
            and obj.Visible
            and type(obj.Text) == "string"
            and obj.Text ~= "" then

            local lower = string.lower(obj.Text)

            if lower:find("tsunami", 1, true)
                or lower:find("wave", 1, true)
                or lower:find("dead waters", 1, true) then
                best = obj.Text
                break
            end
        end
    end

    return best or "No tsunami warning detected"
end

-- GUI
local gui = Instance.new("ScreenGui")
gui.Name = "DChronosClawFishing"
gui.ResetOnSpawn = false
gui.IgnoreGuiInset = true

local main = Instance.new("Frame")
main.Name = "Main"
main.AnchorPoint = Vector2.new(0, 0.5)
main.Position = UDim2.new(0, 24, 0.5, 0)
main.Size = UDim2.fromOffset(370, 405)
main.BackgroundColor3 = Color3.fromRGB(10, 13, 20)
main.BorderSizePixel = 0
main.Parent = gui

local mainCorner = Instance.new("UICorner")
mainCorner.CornerRadius = UDim.new(0, 16)
mainCorner.Parent = main

local stroke = Instance.new("UIStroke")
stroke.Color = Color3.fromRGB(58, 66, 84)
stroke.Thickness = 1
stroke.Parent = main

local header = Instance.new("Frame")
header.BackgroundTransparency = 1
header.Position = UDim2.fromOffset(20, 16)
header.Size = UDim2.new(1, -40, 0, 56)
header.Parent = main

local title = Instance.new("TextLabel")
title.BackgroundTransparency = 1
title.Size = UDim2.new(1, -70, 0, 27)
title.Font = Enum.Font.GothamBold
title.Text = "DCHRONOS"
title.TextSize = 21
title.TextColor3 = Color3.fromRGB(246, 248, 255)
title.TextXAlignment = Enum.TextXAlignment.Left
title.Parent = header

local subtitle = Instance.new("TextLabel")
subtitle.BackgroundTransparency = 1
subtitle.Position = UDim2.fromOffset(0, 28)
subtitle.Size = UDim2.new(1, 0, 0, 22)
subtitle.Font = Enum.Font.Gotham
subtitle.Text = "Claw Fishing • Native Module"
subtitle.TextSize = 12
subtitle.TextColor3 = Color3.fromRGB(142, 151, 170)
subtitle.TextXAlignment = Enum.TextXAlignment.Left
subtitle.Parent = header

local nativeBadge = Instance.new("TextLabel")
nativeBadge.AnchorPoint = Vector2.new(1, 0)
nativeBadge.Position = UDim2.new(1, 0, 0, 2)
nativeBadge.Size = UDim2.fromOffset(64, 24)
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

local divider = Instance.new("Frame")
divider.Position = UDim2.fromOffset(20, 78)
divider.Size = UDim2.new(1, -40, 0, 1)
divider.BackgroundColor3 = Color3.fromRGB(38, 43, 56)
divider.BorderSizePixel = 0
divider.Parent = main

local content = Instance.new("Frame")
content.BackgroundTransparency = 1
content.Position = UDim2.fromOffset(20, 92)
content.Size = UDim2.new(1, -40, 1, -154)
content.Parent = main

local list = Instance.new("UIListLayout")
list.Padding = UDim.new(0, 7)
list.SortOrder = Enum.SortOrder.LayoutOrder
list.Parent = content

local valueLabels = {}

local function createRow(labelText, key)
    local row = Instance.new("Frame")
    row.Size = UDim2.new(1, 0, 0, 29)
    row.BackgroundColor3 = Color3.fromRGB(17, 21, 30)
    row.BorderSizePixel = 0
    row.Parent = content

    local corner = Instance.new("UICorner")
    corner.CornerRadius = UDim.new(0, 7)
    corner.Parent = row

    local label = Instance.new("TextLabel")
    label.BackgroundTransparency = 1
    label.Position = UDim2.fromOffset(10, 0)
    label.Size = UDim2.new(0.42, -10, 1, 0)
    label.Font = Enum.Font.Gotham
    label.Text = labelText
    label.TextSize = 11
    label.TextColor3 = Color3.fromRGB(135, 144, 162)
    label.TextXAlignment = Enum.TextXAlignment.Left
    label.Parent = row

    local value = Instance.new("TextLabel")
    value.BackgroundTransparency = 1
    value.Position = UDim2.new(0.42, 0, 0, 0)
    value.Size = UDim2.new(0.58, -10, 1, 0)
    value.Font = Enum.Font.GothamMedium
    value.Text = "—"
    value.TextSize = 11
    value.TextColor3 = Color3.fromRGB(225, 229, 239)
    value.TextXAlignment = Enum.TextXAlignment.Right
    value.TextTruncate = Enum.TextTruncate.AtEnd
    value.Parent = row

    valueLabels[key] = value
end

createRow("Cash / Money", "cash")
createRow("Fish Stat", "fishStat")
createRow("Session", "session")
createRow("Workspace Scan", "scan")
createRow("Tsunami Status", "warning")

local footer = Instance.new("Frame")
footer.BackgroundTransparency = 1
footer.Position = UDim2.new(0, 20, 1, -54)
footer.Size = UDim2.new(1, -40, 0, 38)
footer.Parent = main

local refresh = Instance.new("TextButton")
refresh.Size = UDim2.new(0.68, -5, 1, 0)
refresh.BackgroundColor3 = Color3.fromRGB(32, 38, 52)
refresh.BorderSizePixel = 0
refresh.AutoButtonColor = true
refresh.Font = Enum.Font.GothamMedium
refresh.Text = "Refresh Scan"
refresh.TextSize = 12
refresh.TextColor3 = Color3.fromRGB(235, 238, 247)
refresh.Parent = footer

local refreshCorner = Instance.new("UICorner")
refreshCorner.CornerRadius = UDim.new(0, 9)
refreshCorner.Parent = refresh

local close = Instance.new("TextButton")
close.AnchorPoint = Vector2.new(1, 0)
close.Position = UDim2.new(1, 0, 0, 0)
close.Size = UDim2.new(0.32, -5, 1, 0)
close.BackgroundColor3 = Color3.fromRGB(50, 29, 33)
close.BorderSizePixel = 0
close.AutoButtonColor = true
close.Font = Enum.Font.GothamMedium
close.Text = "Close"
close.TextSize = 12
close.TextColor3 = Color3.fromRGB(255, 190, 194)
close.Parent = footer

local closeCorner = Instance.new("UICorner")
closeCorner.CornerRadius = UDim.new(0, 9)
closeCorner.Parent = close

local function refreshStats(forceScan)
    local cash, cashName = findValueByNames({
        "Cash", "Money", "Coins", "Coin", "Currency"
    })

    local fish, fishName = findValueByNames({
        "Fish", "Fishes", "CaughtFish", "FishCaught"
    })

    valueLabels.cash.Text = cash ~= nil
        and ((cashName or "Cash") .. ": " .. formatNumber(cash))
        or "Not exposed in leaderstats"

    valueLabels.fishStat.Text = fish ~= nil
        and ((fishName or "Fish") .. ": " .. formatNumber(fish))
        or "Not exposed in leaderstats"

    local elapsed = math.max(0, os.clock() - state.startedAt)
    valueLabels.session.Text = string.format(
        "%02d:%02d",
        math.floor(elapsed / 60),
        math.floor(elapsed % 60)
    )

    if forceScan then
        state.scan = scanWorkspace()
    end

    valueLabels.scan.Text = string.format(
        "Fish %d • Claw %d • Boat %d • Tank %d",
        state.scan.fish,
        state.scan.claw,
        state.scan.boat,
        state.scan.aquarium
    )

    state.warning = detectWarningText()
    valueLabels.warning.Text = state.warning

    local lowerWarning = string.lower(state.warning)
    if lowerWarning ~= "no tsunami warning detected" then
        valueLabels.warning.TextColor3 = Color3.fromRGB(255, 202, 122)
    else
        valueLabels.warning.TextColor3 = Color3.fromRGB(225, 229, 239)
    end
end

refresh.MouseButton1Click:Connect(function()
    refresh.Text = "Scanning..."
    task.spawn(function()
        refreshStats(true)
        refresh.Text = "Refresh Scan"
    end)
end)

close.MouseButton1Click:Connect(function()
    gui:Destroy()
end)

-- Simple dragging, desktop-friendly.
do
    local dragging = false
    local dragStart
    local startPos

    main.InputBegan:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1
            or input.UserInputType == Enum.UserInputType.Touch then
            dragging = true
            dragStart = input.Position
            startPos = main.Position
        end
    end)

    main.InputEnded:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1
            or input.UserInputType == Enum.UserInputType.Touch then
            dragging = false
        end
    end)

    game:GetService("UserInputService").InputChanged:Connect(function(input)
        if dragging and (
            input.UserInputType == Enum.UserInputType.MouseMovement
            or input.UserInputType == Enum.UserInputType.Touch
        ) then
            local delta = input.Position - dragStart
            main.Position = UDim2.new(
                startPos.X.Scale,
                startPos.X.Offset + delta.X,
                startPos.Y.Scale,
                startPos.Y.Offset + delta.Y
            )
        end
    end)
end

gui.Parent = playerGui

-- Initial scan.
task.spawn(function()
    state.scan = scanWorkspace()
    refreshStats(false)
end)

-- Lightweight live refresh. Workspace scan stays manual because it can be large.
task.spawn(function()
    while gui.Parent do
        task.wait(1)
        pcall(function()
            refreshStats(false)
        end)
    end
end)

print("[DChronos Native] Claw Fishing module loaded.")
