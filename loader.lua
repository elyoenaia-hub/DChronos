-- DChronos Loader v1.1.0 — Bridge Edition
-- Supports internal DChronos modules and attributed external module URLs.

if not game:IsLoaded() then game.Loaded:Wait() end

local VERSION = "1.1.0"
local ROOT = "https://raw.githubusercontent.com/elyoenaia-hub/DChronos/main/"
local MANIFEST_URL = ROOT .. "modules/manifest.json"
local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")
local player = Players.LocalPlayer
local env = (type(getgenv) == "function" and getgenv()) or _G

if env.__DCHRONOS_RUNNING then
    warn("[DChronos] Already running")
    return
end
env.__DCHRONOS_RUNNING = true

local gui, statusLabel, detailLabel, fill

local function finish()
    env.__DCHRONOS_RUNNING = nil
end

local function makeGui()
    if not player then return end
    local pg = player:FindFirstChildOfClass("PlayerGui") or player:WaitForChild("PlayerGui", 10)
    if not pg then return end

    gui = Instance.new("ScreenGui")
    gui.Name = "DChronosLoader"
    gui.IgnoreGuiInset = true
    gui.ResetOnSpawn = false

    local frame = Instance.new("Frame")
    frame.AnchorPoint = Vector2.new(.5,.5)
    frame.Position = UDim2.fromScale(.5,.5)
    frame.Size = UDim2.fromOffset(460,190)
    frame.BackgroundColor3 = Color3.fromRGB(12,14,20)
    frame.BorderSizePixel = 0
    frame.Parent = gui
    Instance.new("UICorner", frame).CornerRadius = UDim.new(0,16)

    local stroke = Instance.new("UIStroke", frame)
    stroke.Color = Color3.fromRGB(62,68,82)

    local title = Instance.new("TextLabel", frame)
    title.BackgroundTransparency = 1
    title.Position = UDim2.fromOffset(24,18)
    title.Size = UDim2.new(1,-48,0,30)
    title.Font = Enum.Font.GothamBold
    title.Text = "DCHRONOS"
    title.TextSize = 23
    title.TextColor3 = Color3.fromRGB(245,247,255)
    title.TextXAlignment = Enum.TextXAlignment.Left

    local ver = Instance.new("TextLabel", frame)
    ver.BackgroundTransparency = 1
    ver.Position = UDim2.fromOffset(24,47)
    ver.Size = UDim2.new(1,-48,0,18)
    ver.Font = Enum.Font.Gotham
    ver.Text = "Bridge Edition  •  v" .. VERSION
    ver.TextSize = 11
    ver.TextColor3 = Color3.fromRGB(125,132,150)
    ver.TextXAlignment = Enum.TextXAlignment.Left

    statusLabel = Instance.new("TextLabel", frame)
    statusLabel.BackgroundTransparency = 1
    statusLabel.Position = UDim2.fromOffset(24,78)
    statusLabel.Size = UDim2.new(1,-48,0,24)
    statusLabel.Font = Enum.Font.GothamMedium
    statusLabel.Text = "Initializing..."
    statusLabel.TextSize = 15
    statusLabel.TextColor3 = Color3.fromRGB(220,224,235)
    statusLabel.TextXAlignment = Enum.TextXAlignment.Left

    detailLabel = Instance.new("TextLabel", frame)
    detailLabel.BackgroundTransparency = 1
    detailLabel.Position = UDim2.fromOffset(24,105)
    detailLabel.Size = UDim2.new(1,-48,0,38)
    detailLabel.Font = Enum.Font.Gotham
    detailLabel.Text = "Preparing DChronos..."
    detailLabel.TextSize = 12
    detailLabel.TextWrapped = true
    detailLabel.TextColor3 = Color3.fromRGB(145,151,168)
    detailLabel.TextXAlignment = Enum.TextXAlignment.Left
    detailLabel.TextYAlignment = Enum.TextYAlignment.Top

    local bar = Instance.new("Frame", frame)
    bar.Position = UDim2.fromOffset(24,158)
    bar.Size = UDim2.new(1,-48,0,7)
    bar.BackgroundColor3 = Color3.fromRGB(37,41,52)
    bar.BorderSizePixel = 0
    Instance.new("UICorner", bar).CornerRadius = UDim.new(1,0)

    fill = Instance.new("Frame", bar)
    fill.Size = UDim2.fromScale(.04,1)
    fill.BackgroundColor3 = Color3.fromRGB(235,238,248)
    fill.BorderSizePixel = 0
    Instance.new("UICorner", fill).CornerRadius = UDim.new(1,0)

    gui.Parent = pg
end

local function setStatus(s, d, p)
    print("[DChronos]", s, d or "")
    if statusLabel then statusLabel.Text = s end
    if detailLabel and d then detailLabel.Text = d end
    if fill and p then
        fill:TweenSize(UDim2.fromScale(math.clamp(p,.04,1),1), Enum.EasingDirection.Out, Enum.EasingStyle.Quad, .2, true)
    end
end

local function fail(msg)
    warn("[DChronos]", msg)
    setStatus("Unable to load", tostring(msg), 1)
    if statusLabel then statusLabel.TextColor3 = Color3.fromRGB(255,145,145) end
    finish()
end

local function httpGet(url, tries)
    local err = "unknown error"
    for i=1,(tries or 3) do
        local ok, res = pcall(function() return game:HttpGet(url) end)
        if ok and type(res)=="string" and #res>0 and not res:find("404: Not Found",1,true) then return res end
        err = tostring(res)
        if i < (tries or 3) then task.wait(.65*i) end
    end
    return nil, err
end

local function contains(t, n)
    if type(t) ~= "table" then return false end
    n = tonumber(n)
    for _,v in ipairs(t) do if tonumber(v)==n then return true end end
    return false
end

local function resolve(m)
    for _,e in ipairs(m.modules or {}) do
        if e.enabled ~= false and contains(e.placeIds, game.PlaceId) then return e,"PlaceId" end
    end
    for _,e in ipairs(m.modules or {}) do
        if e.enabled ~= false and contains(e.universeIds, game.GameId) then return e,"UniverseId" end
    end
    local hits = {}
    for _,e in ipairs(m.modules or {}) do
        if e.enabled ~= false and e.creatorFallback ~= false and tonumber(e.creatorId)==tonumber(game.CreatorId) then
            table.insert(hits,e)
        end
    end
    if #hits==1 then return hits[1],"CreatorId" end
    if #hits>1 then return nil,"Ambiguous CreatorId: "..tostring(game.CreatorId) end
    return nil,"Unsupported game"
end

local function host(url)
    return type(url)=="string" and url:match("^https://([^/]+)/") or nil
end

local function allowedHost(m,url)
    local h=host(url)
    if not h then return false end
    for _,v in ipairs(m.allowedExternalHosts or {}) do if tostring(v)==h then return true end end
    return false
end

local function moduleUrl(m,e)
    local source = tostring(e.source or "internal"):lower()
    if source=="external" then
        if type(e.url)~="string" or not e.url:match("^https://") then return nil,"Invalid external URL" end
        if not allowedHost(m,e.url) then return nil,"External host not allowed" end
        return e.url,"External"
    end
    if type(e.file)~="string" or e.file=="" or e.file:find("..",1,true) or e.file:match("^https?://") then
        return nil,"Invalid internal path"
    end
    return (m.internalBaseUrl or (ROOT.."modules/"))..e.file,"Internal"
end

makeGui()
setStatus("Loading registry...", "Fetching DChronos manifest", .16)

local body,err=httpGet(MANIFEST_URL,3)
if not body then fail("Manifest download failed: "..tostring(err)); return end

local ok,m=pcall(function() return HttpService:JSONDecode(body) end)
if not ok or type(m)~="table" or type(m.modules)~="table" then fail("Manifest JSON is invalid"); return end

setStatus("Detecting game...", "PlaceId "..tostring(game.PlaceId).." • UniverseId "..tostring(game.GameId), .40)
local e,matched=resolve(m)
if not e then fail(matched.." • CreatorId "..tostring(game.CreatorId)); return end

local url,source=moduleUrl(m,e)
if not url then fail(source); return end

setStatus("Module detected", tostring(e.name or e.file or "Unnamed").." • "..source.." • "..matched, .62)
if source=="External" then print("[DChronos] Upstream:", tostring(e.upstream or host(url) or "unknown")) end

setStatus("Downloading module...", source.." source", .80)
local src,downloadErr=httpGet(url,3)
if not src then fail("Module download failed: "..tostring(downloadErr)); return end
if type(loadstring)~="function" then fail("loadstring unavailable"); return end

setStatus("Starting...", tostring(e.name or e.file or "Module"), .93)
local fn,compileErr=loadstring(src, "@DChronos/"..source.."/"..tostring(e.upstreamFile or e.file or "module.lua"))
if not fn then fail("Compile error: "..tostring(compileErr)); return end
local ran,runtimeErr=pcall(fn)
if not ran then fail("Runtime error: "..tostring(runtimeErr)); return end

setStatus("Loaded successfully", tostring(e.name or e.file or "Module").." • "..source, 1)
if statusLabel then statusLabel.TextColor3=Color3.fromRGB(155,240,178) end
finish()
if gui then task.delay(1.4,function() pcall(function() gui:Destroy() end) end) end
