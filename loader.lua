--[[
    DChronos Loader v1.2.1 — Native Edition

    No third-party module bridge.
    Registry metadata is local to DChronos.
    Modules are loaded only from:
      https://raw.githubusercontent.com/elyoenaia-hub/DChronos/main/modules/

    Resolution priority:
      1. PlaceId
      2. UniverseId (game.GameId)
      3. CreatorId fallback
]]

if not game:IsLoaded() then
    game.Loaded:Wait()
end

local VERSION = "1.2.1"
local REPO_OWNER = "elyoenaia-hub"
local REPO_NAME = "DChronos"
local BRANCH = "main"

local RAW_ROOT = string.format(
    "https://raw.githubusercontent.com/%s/%s/%s/",
    REPO_OWNER,
    REPO_NAME,
    BRANCH
)

local MANIFEST_URL = RAW_ROOT .. "modules/manifest.json"

local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")
local LocalPlayer = Players.LocalPlayer

local env = (type(getgenv) == "function" and getgenv()) or _G

if env.__DCHRONOS_RUNNING then
    warn("[DChronos] Loader is already running.")
    return
end

env.__DCHRONOS_RUNNING = true

local gui
local statusLabel
local detailLabel
local progressFill
local sourceLabel

local function cleanup()
    env.__DCHRONOS_RUNNING = nil
end

local function destroyGui(delaySeconds)
    if not gui then return end

    task.delay(delaySeconds or 2, function()
        pcall(function()
            if gui then
                gui:Destroy()
            end
        end)
    end)
end

local function createGui()
    if not LocalPlayer then return end

    local playerGui = LocalPlayer:FindFirstChildOfClass("PlayerGui")
        or LocalPlayer:WaitForChild("PlayerGui", 10)

    if not playerGui then return end

    gui = Instance.new("ScreenGui")
    gui.Name = "DChronosNativeLoader"
    gui.IgnoreGuiInset = true
    gui.ResetOnSpawn = false

    local frame = Instance.new("Frame")
    frame.AnchorPoint = Vector2.new(0.5, 0.5)
    frame.Position = UDim2.fromScale(0.5, 0.5)
    frame.Size = UDim2.fromOffset(470, 215)
    frame.BackgroundColor3 = Color3.fromRGB(10, 12, 18)
    frame.BorderSizePixel = 0
    frame.Parent = gui

    local frameCorner = Instance.new("UICorner")
    frameCorner.CornerRadius = UDim.new(0, 16)
    frameCorner.Parent = frame

    local stroke = Instance.new("UIStroke")
    stroke.Color = Color3.fromRGB(60, 66, 82)
    stroke.Thickness = 1
    stroke.Parent = frame

    local title = Instance.new("TextLabel")
    title.BackgroundTransparency = 1
    title.Position = UDim2.fromOffset(24, 18)
    title.Size = UDim2.new(1, -48, 0, 30)
    title.Font = Enum.Font.GothamBold
    title.Text = "DCHRONOS"
    title.TextSize = 24
    title.TextColor3 = Color3.fromRGB(246, 248, 255)
    title.TextXAlignment = Enum.TextXAlignment.Left
    title.Parent = frame

    local version = Instance.new("TextLabel")
    version.BackgroundTransparency = 1
    version.Position = UDim2.fromOffset(24, 47)
    version.Size = UDim2.new(1, -48, 0, 18)
    version.Font = Enum.Font.Gotham
    version.Text = "Native Edition  •  v" .. VERSION
    version.TextSize = 11
    version.TextColor3 = Color3.fromRGB(125, 132, 150)
    version.TextXAlignment = Enum.TextXAlignment.Left
    version.Parent = frame

    sourceLabel = Instance.new("TextLabel")
    sourceLabel.BackgroundTransparency = 1
    sourceLabel.AnchorPoint = Vector2.new(1, 0)
    sourceLabel.Position = UDim2.new(1, -24, 0, 22)
    sourceLabel.Size = UDim2.fromOffset(120, 24)
    sourceLabel.Font = Enum.Font.GothamMedium
    sourceLabel.Text = "NATIVE"
    sourceLabel.TextSize = 11
    sourceLabel.TextColor3 = Color3.fromRGB(155, 240, 178)
    sourceLabel.TextXAlignment = Enum.TextXAlignment.Right
    sourceLabel.Parent = frame

    statusLabel = Instance.new("TextLabel")
    statusLabel.BackgroundTransparency = 1
    statusLabel.Position = UDim2.fromOffset(24, 82)
    statusLabel.Size = UDim2.new(1, -48, 0, 24)
    statusLabel.Font = Enum.Font.GothamMedium
    statusLabel.Text = "Initializing..."
    statusLabel.TextSize = 16
    statusLabel.TextColor3 = Color3.fromRGB(222, 226, 237)
    statusLabel.TextXAlignment = Enum.TextXAlignment.Left
    statusLabel.Parent = frame

    detailLabel = Instance.new("TextLabel")
    detailLabel.BackgroundTransparency = 1
    detailLabel.Position = UDim2.fromOffset(24, 111)
    detailLabel.Size = UDim2.new(1, -48, 0, 55)
    detailLabel.Font = Enum.Font.Gotham
    detailLabel.Text = "Preparing DChronos Native..."
    detailLabel.TextSize = 12
    detailLabel.TextWrapped = true
    detailLabel.TextColor3 = Color3.fromRGB(145, 151, 168)
    detailLabel.TextXAlignment = Enum.TextXAlignment.Left
    detailLabel.TextYAlignment = Enum.TextYAlignment.Top
    detailLabel.Parent = frame

    local bar = Instance.new("Frame")
    bar.Position = UDim2.fromOffset(24, 181)
    bar.Size = UDim2.new(1, -48, 0, 7)
    bar.BackgroundColor3 = Color3.fromRGB(37, 41, 52)
    bar.BorderSizePixel = 0
    bar.Parent = frame

    local barCorner = Instance.new("UICorner")
    barCorner.CornerRadius = UDim.new(1, 0)
    barCorner.Parent = bar

    progressFill = Instance.new("Frame")
    progressFill.Size = UDim2.fromScale(0.04, 1)
    progressFill.BackgroundColor3 = Color3.fromRGB(235, 238, 248)
    progressFill.BorderSizePixel = 0
    progressFill.Parent = bar

    local progressCorner = Instance.new("UICorner")
    progressCorner.CornerRadius = UDim.new(1, 0)
    progressCorner.Parent = progressFill

    gui.Parent = playerGui
end

local function setStatus(status, detail, progress)
    print("[DChronos Native]", status, detail or "")

    if statusLabel then statusLabel.Text = status end
    if detailLabel and detail then detailLabel.Text = detail end

    if progressFill and progress then
        progressFill:TweenSize(
            UDim2.fromScale(math.clamp(progress, 0.04, 1), 1),
            Enum.EasingDirection.Out,
            Enum.EasingStyle.Quad,
            0.2,
            true
        )
    end
end

local function finishWith(status, detail, color, delaySeconds)
    setStatus(status, detail, 1)

    if statusLabel and color then
        statusLabel.TextColor3 = color
    end

    cleanup()
    destroyGui(delaySeconds or 3)
end

local function fail(message)
    warn("[DChronos Native]", message)
    finishWith(
        "Unable to load",
        tostring(message),
        Color3.fromRGB(255, 145, 145),
        4
    )
end

local function httpGet(url, retries)
    local lastError = "unknown error"
    local attempts = retries or 3

    for attempt = 1, attempts do
        local ok, result = pcall(function()
            return game:HttpGet(url)
        end)

        if ok
            and type(result) == "string"
            and #result > 0
            and not result:find("404: Not Found", 1, true) then
            return result
        end

        lastError = tostring(result)

        if attempt < attempts then
            task.wait(0.65 * attempt)
        end
    end

    return nil, lastError
end

local function containsId(list, target)
    if type(list) ~= "table" then return false end

    target = tonumber(target)

    for _, value in ipairs(list) do
        if tonumber(value) == target then
            return true
        end
    end

    return false
end

local function resolveModule(manifest)
    local placeId = tonumber(game.PlaceId)
    local universeId = tonumber(game.GameId)
    local creatorId = tonumber(game.CreatorId)

    for _, entry in ipairs(manifest.modules or {}) do
        if entry.enabled ~= false and containsId(entry.placeIds, placeId) then
            return entry, "PlaceId"
        end
    end

    for _, entry in ipairs(manifest.modules or {}) do
        if entry.enabled ~= false and containsId(entry.universeIds, universeId) then
            return entry, "UniverseId"
        end
    end

    local matches = {}

    for _, entry in ipairs(manifest.modules or {}) do
        if entry.enabled ~= false
            and entry.creatorFallback ~= false
            and tonumber(entry.creatorId) == creatorId then
            table.insert(matches, entry)
        end
    end

    if #matches == 1 then
        return matches[1], "CreatorId"
    end

    if #matches > 1 then
        return nil, "Ambiguous CreatorId: " .. tostring(creatorId)
    end

    return nil, "Game is not in the DChronos registry"
end

local function validRelativeFile(file)
    if type(file) ~= "string" or file == "" then return false end
    if file:find("..", 1, true) then return false end
    if file:match("^https?://") then return false end
    return true
end

createGui()

setStatus(
    "Loading native registry...",
    "Fetching DChronos modules/manifest.json",
    0.16
)

local manifestSource, manifestError = httpGet(MANIFEST_URL, 3)

if not manifestSource then
    fail("Manifest download failed: " .. tostring(manifestError))
    return
end

local decodeOk, manifest = pcall(function()
    return HttpService:JSONDecode(manifestSource)
end)

if not decodeOk
    or type(manifest) ~= "table"
    or type(manifest.modules) ~= "table" then
    fail("Manifest JSON is invalid.")
    return
end

if tostring(manifest.edition or "") ~= "Native" then
    fail("Manifest is not a DChronos Native manifest.")
    return
end

setStatus(
    "Detecting game...",
    "PlaceId " .. tostring(game.PlaceId)
        .. " • UniverseId " .. tostring(game.GameId),
    0.42
)

local entry, matchedBy = resolveModule(manifest)

if not entry then
    fail(
        matchedBy
        .. " • CreatorId "
        .. tostring(game.CreatorId)
    )
    return
end

setStatus(
    "Game recognized",
    tostring(entry.name or entry.file or "Unknown")
        .. " • matched by "
        .. tostring(matchedBy),
    0.64
)

-- Registry support and implementation support are intentionally separate.
if entry.implemented ~= true then
    finishWith(
        "Native Module Pending",
        tostring(entry.name or "This game")
            .. " is registered in DChronos, but its native module has not been implemented yet.",
        Color3.fromRGB(244, 204, 120),
        5
    )
    return
end

if not validRelativeFile(entry.file) then
    fail("Invalid DChronos module path.")
    return
end

local baseUrl = manifest.internalBaseUrl
    or (RAW_ROOT .. "modules/")

local moduleUrl = baseUrl .. entry.file

-- Enforce DChronos-only module hosting.
local expectedPrefix = RAW_ROOT .. "modules/"
if moduleUrl:sub(1, #expectedPrefix) ~= expectedPrefix then
    fail("Native modules must be hosted inside the DChronos repository.")
    return
end

setStatus(
    "Downloading native module...",
    tostring(entry.file),
    0.80
)

local source, moduleError = httpGet(moduleUrl, 3)

if not source then
    fail("Native module download failed: " .. tostring(moduleError))
    return
end

if type(loadstring) ~= "function" then
    fail("loadstring is unavailable in this environment.")
    return
end

setStatus(
    "Starting native module...",
    tostring(entry.name or entry.file),
    0.93
)

local fn, compileError = loadstring(
    source,
    "@DChronos/modules/" .. entry.file
)

if not fn then
    fail("Compile error: " .. tostring(compileError))
    return
end

local ok, runtimeError = pcall(fn)

if not ok then
    fail("Runtime error: " .. tostring(runtimeError))
    return
end

finishWith(
    "Loaded successfully",
    tostring(entry.name or entry.file) .. " • DChronos Native",
    Color3.fromRGB(155, 240, 178),
    1.5
)
