--[[
    DChronos Native Module
    Game: Claw Fishing
    Edition: Advanced v1.2.2

    Features:
      - Floating DC toggle button
      - Minimize / restore menu
      - Live stats
      - Workspace object scan
      - Tsunami/wave warning monitor
      - Auto refresh
      - Draggable menu + floating toggle

    This is a native DChronos utility module.
]]

local EXPECTED_PLACE_ID = 128931272139211
local EXPECTED_UNIVERSE_ID = 10008606756

if tonumber(game.PlaceId) ~= EXPECTED_PLACE_ID
    and tonumber(game.GameId) ~= EXPECTED_UNIVERSE_ID then
    warn("[DChronos/ClawFishing] Wrong game.")
    return
end

local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")
local UserInputService = game:GetService("UserInputService")

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
    scan = {
        fish = 0,
        claw = 0,
        boat = 0,
        aquarium = 0,
        prompts = 0,
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
            if lookup[string.lower(child.Name)] and child:IsA("ValueBase") then
                return child.Value, child.Name
            end
        end
    end

    for _, child in ipairs(player:GetDescendants()) do
        if lookup[string.lower(child.Name)] and child:IsA("ValueBase") then
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
        prompts = 0,
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

            local lower = string.lower(obj.Text)

            if lower:find("tsunami", 1, true)
                or lower:find("wave", 1, true)
                or lower:find("dead waters", 1, true)
                or lower:find("storm", 1, true) then
                return obj.Text
            end
        end
    end

    return "No tsunami warning detected"
end

local gui = Instance.new("ScreenGui")
gui.Name = "DChronosClawFishing"
gui.ResetOnSpawn = false
gui.IgnoreGuiInset = true

-- Floating toggle
local floatButton = Instance.new("TextButton")
floatButton.Name = "FloatingToggle"
floatButton.AnchorPoint = Vector2.new(0, 0.5)
floatButton.Position = UDim2.new(0, 18, 0.5, 0)
floatButton.Size = UDim2.fromOffset(54, 54)
floatButton.BackgroundColor3 = Color3.fromRGB(19, 24, 34)
floatButton.BorderSizePixel = 0
floatButton.AutoButtonColor = true
floatButton.Font = Enum.Font.GothamBold
floatButton.Text = "DC"
floatButton.TextSize = 16
floatButton.TextColor3 = Color3.fromRGB(242, 245, 255)
floatButton.Visible = false
floatButton.ZIndex = 20
floatButton.Parent = gui

local floatCorner = Instance.new("UICorner")
floatCorner.CornerRadius = UDim.new(1, 0)
floatCorner.Parent = floatButton

local floatStroke = Instance.new("UIStroke")
floatStroke.Color = Color3.fromRGB(83, 94, 122)
floatStroke.Thickness = 1
floatStroke.Parent = floatButton

-- Main window
local main = Instance.new("Frame")
main.Name = "Main"
main.AnchorPoint = Vector2.new(0, 0.5)
main.Position = UDim2.new(0, 24, 0.5, 0)
main.Size = UDim2.fromOffset(392, 468)
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

-- Header
local header = Instance.new("Frame")
header.BackgroundTransparency = 1
header.Position = UDim2.fromOffset(20, 14)
header.Size = UDim2.new(1, -40, 0, 62)
header.Parent = main

local title = Instance.new("TextLabel")
title.BackgroundTransparency = 1
title.Size = UDim2.new(1, -110, 0, 27)
title.Font = Enum.Font.GothamBold
title.Text = "DCHRONOS"
title.TextSize = 21
title.TextColor3 = Color3.fromRGB(246, 248, 255)
title.TextXAlignment = Enum.TextXAlignment.Left
title.Parent = header

local subtitle = Instance.new("TextLabel")
subtitle.BackgroundTransparency = 1
subtitle.Position = UDim2.fromOffset(0, 28)
subtitle.Size = UDim2.new(1, -110, 0, 20)
subtitle.Font = Enum.Font.Gotham
subtitle.Text = "Claw Fishing • Advanced Native"
subtitle.TextSize = 12
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
divider.Position = UDim2.fromOffset(20, 80)
divider.Size = UDim2.new(1, -40, 0, 1)
divider.BackgroundColor3 = Color3.fromRGB(38, 43, 56)
divider.BorderSizePixel = 0
divider.Parent = main

-- Info strip
local infoStrip = Instance.new("Frame")
infoStrip.Position = UDim2.fromOffset(20, 94)
infoStrip.Size = UDim2.new(1, -40, 0, 54)
infoStrip.BackgroundColor3 = Color3.fromRGB(15, 19, 28)
infoStrip.BorderSizePixel = 0
infoStrip.Parent = main

local infoCorner = Instance.new("UICorner")
infoCorner.CornerRadius = UDim.new(0, 9)
infoCorner.Parent = infoStrip

local gameLabel = Instance.new("TextLabel")
gameLabel.BackgroundTransparency = 1
gameLabel.Position = UDim2.fromOffset(10, 7)
gameLabel.Size = UDim2.new(1, -20, 0, 18)
gameLabel.Font = Enum.Font.GothamMedium
gameLabel.Text = "Claw Fishing"
gameLabel.TextSize = 12
gameLabel.TextColor3 = Color3.fromRGB(229, 233, 244)
gameLabel.TextXAlignment = Enum.TextXAlignment.Left
gameLabel.Parent = infoStrip

local idLabel = Instance.new("TextLabel")
idLabel.BackgroundTransparency = 1
idLabel.Position = UDim2.fromOffset(10, 27)
idLabel.Size = UDim2.new(1, -20, 0, 17)
idLabel.Font = Enum.Font.Gotham
idLabel.Text = "Place " .. tostring(game.PlaceId) .. "  •  Universe " .. tostring(game.GameId)
idLabel.TextSize = 10
idLabel.TextColor3 = Color3.fromRGB(126, 135, 153)
idLabel.TextXAlignment = Enum.TextXAlignment.Left
idLabel.Parent = infoStrip

local content = Instance.new("Frame")
content.BackgroundTransparency = 1
content.Position = UDim2.fromOffset(20, 160)
content.Size = UDim2.new(1, -40, 0, 216)
content.Parent = main

local list = Instance.new("UIListLayout")
list.Padding = UDim.new(0, 7)
list.SortOrder = Enum.SortOrder.LayoutOrder
list.Parent = content

local valueLabels = {}

local function createRow(labelText, key)
    local row = Instance.new("Frame")
    row.Size = UDim2.new(1, 0, 0, 31)
    row.BackgroundColor3 = Color3.fromRGB(17, 21, 30)
    row.BorderSizePixel = 0
    row.Parent = content

    local corner = Instance.new("UICorner")
    corner.CornerRadius = UDim.new(0, 7)
    corner.Parent = row

    local label = Instance.new("TextLabel")
    label.BackgroundTransparency = 1
    label.Position = UDim2.fromOffset(10, 0)
    label.Size = UDim2.new(0.39, -10, 1, 0)
    label.Font = Enum.Font.Gotham
    label.Text = labelText
    label.TextSize = 11
    label.TextColor3 = Color3.fromRGB(135, 144, 162)
    label.TextXAlignment = Enum.TextXAlignment.Left
    label.Parent = row

    local value = Instance.new("TextLabel")
    value.BackgroundTransparency = 1
    value.Position = UDim2.new(0.39, 0, 0, 0)
    value.Size = UDim2.new(0.61, -10, 1, 0)
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
createRow("World Objects", "scan")
createRow("Prompts", "prompts")
createRow("Event Warning", "warning")

-- Controls
local controls = Instance.new("Frame")
controls.BackgroundTransparency = 1
controls.Position = UDim2.fromOffset(20, 392)
controls.Size = UDim2.new(1, -40, 0, 56)
controls.Parent = main

local refresh = Instance.new("TextButton")
refresh.Size = UDim2.new(0.48, -4, 0, 34)
refresh.BackgroundColor3 = Color3.fromRGB(32, 38, 52)
refresh.BorderSizePixel = 0
refresh.AutoButtonColor = true
refresh.Font = Enum.Font.GothamMedium
refresh.Text = "Refresh Scan"
refresh.TextSize = 11
refresh.TextColor3 = Color3.fromRGB(235, 238, 247)
refresh.Parent = controls

local refreshCorner = Instance.new("UICorner")
refreshCorner.CornerRadius = UDim.new(0, 9)
refreshCorner.Parent = refresh

local auto = Instance.new("TextButton")
auto.AnchorPoint = Vector2.new(1, 0)
auto.Position = UDim2.new(1, 0, 0, 0)
auto.Size = UDim2.new(0.48, -4, 0, 34)
auto.BackgroundColor3 = Color3.fromRGB(25, 48, 37)
auto.BorderSizePixel = 0
auto.AutoButtonColor = true
auto.Font = Enum.Font.GothamMedium
auto.Text = "Auto Refresh: ON"
auto.TextSize = 11
auto.TextColor3 = Color3.fromRGB(168, 237, 188)
auto.Parent = controls

local autoCorner = Instance.new("UICorner")
autoCorner.CornerRadius = UDim.new(0, 9)
autoCorner.Parent = auto

local close = Instance.new("TextButton")
close.Position = UDim2.new(0, 0, 0, 40)
close.Size = UDim2.new(1, 0, 0, 16)
close.BackgroundTransparency = 1
close.Font = Enum.Font.Gotham
close.Text = "Close DChronos Module"
close.TextSize = 10
close.TextColor3 = Color3.fromRGB(133, 141, 158)
close.Parent = controls

local function refreshStats(forceScan)
    local cash, cashName = findValueByNames({
        "Cash", "Money", "Coins", "Coin", "Currency"
    })

    local fish, fishName = findValueByNames({
        "Fish", "Fishes", "CaughtFish", "FishCaught"
    })

    valueLabels.cash.Text = cash ~= nil
        and ((cashName or "Cash") .. ": " .. formatNumber(cash))
        or "Not exposed"

    valueLabels.fishStat.Text = fish ~= nil
        and ((fishName or "Fish") .. ": " .. formatNumber(fish))
        or "Not exposed"

    local elapsed = math.max(0, os.clock() - state.startedAt)
    valueLabels.session.Text = string.format(
        "%02d:%02d:%02d",
        math.floor(elapsed / 3600),
        math.floor(elapsed / 60) % 60,
        math.floor(elapsed) % 60
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

    valueLabels.prompts.Text = tostring(state.scan.prompts)

    state.warning = detectWarningText()
    valueLabels.warning.Text = state.warning

    if state.warning ~= "No tsunami warning detected" then
        valueLabels.warning.TextColor3 = Color3.fromRGB(255, 202, 122)
    else
        valueLabels.warning.TextColor3 = Color3.fromRGB(225, 229, 239)
    end
end

local function setMenuVisible(visible)
    state.visible = visible
    main.Visible = visible
    floatButton.Visible = not visible
end

minimize.MouseButton1Click:Connect(function()
    setMenuVisible(false)
end)

floatButton.MouseButton1Click:Connect(function()
    setMenuVisible(true)
end)

refresh.MouseButton1Click:Connect(function()
    refresh.Text = "Scanning..."
    task.spawn(function()
        refreshStats(true)
        task.wait(0.15)
        refresh.Text = "Refresh Scan"
    end)
end)

auto.MouseButton1Click:Connect(function()
    state.autoRefresh = not state.autoRefresh

    if state.autoRefresh then
        auto.Text = "Auto Refresh: ON"
        auto.BackgroundColor3 = Color3.fromRGB(25, 48, 37)
        auto.TextColor3 = Color3.fromRGB(168, 237, 188)
    else
        auto.Text = "Auto Refresh: OFF"
        auto.BackgroundColor3 = Color3.fromRGB(45, 35, 29)
        auto.TextColor3 = Color3.fromRGB(233, 198, 159)
    end
end)

close.MouseButton1Click:Connect(function()
    gui:Destroy()
end)

local function makeDraggable(target, handle)
    local dragging = false
    local dragStart
    local startPos

    handle.InputBegan:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1
            or input.UserInputType == Enum.UserInputType.Touch then
            dragging = true
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
            target.Position = UDim2.new(
                startPos.X.Scale,
                startPos.X.Offset + delta.X,
                startPos.Y.Scale,
                startPos.Y.Offset + delta.Y
            )
        end
    end)
end

makeDraggable(main, header)
makeDraggable(floatButton, floatButton)

gui.Parent = playerGui

task.spawn(function()
    state.scan = scanWorkspace()
    refreshStats(false)
end)

task.spawn(function()
    local scanTicker = 0

    while gui.Parent do
        task.wait(1)

        if state.autoRefresh then
            scanTicker += 1

            pcall(function()
                refreshStats(scanTicker % 5 == 0)
            end)
        else
            pcall(function()
                refreshStats(false)
            end)
        end
    end
end)

print("[DChronos Native] Claw Fishing Advanced v1.2.2 loaded.")
