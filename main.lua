--[[
╔═══════════════════════════════════════════════╗
║  DELTA HUB — Mobile Pro (Performance Fix)      ║
║  ✅ Lag Fix: Raycasts موزعة + Aimbot throttled ║
║  ESP: 🟢 ظاهر | 🔴 خلف جدار                    ║
╚═══════════════════════════════════════════════╝
]]

-- ═══════════════════════════════════════════
-- CONFIGURATION
-- ═══════════════════════════════════════════
local Config = {
    Aimbot = {
        Enabled = true,
        AimPart = "Head",
        TeamCheck = true,
        WallCheck = true,
        Prediction = true,
        PredictionFactor = 0.2,
        Smoothness = 1,
        LockTarget = true,
        LockSwitchKey = Enum.KeyCode.LeftShift,
        AutoShoot = false,
        TouchSwitch = true,
        RetargetInterval = 0.12,      -- 🆕 يختار هدف كل 0.12ث (مو كل فريم = توفير ضخم)
        MaxVisibilityChecks = 2,      -- 🆕 مخفض من 5
    },
    ESP = {
        Enabled = true,
        TeamCheck = true,
        MaxDistance = 2500,
        BoxEnabled = true,
        BoxThickness = 1.4,
        BoxGlow = true,
        CornersEnabled = true,
        CornerThickness = 2.2,
        Tracers = true,
        TracerThickness = 1.1,
        TracerTransparency = 0.5,
        TracerOutline = true,
        HeadDot = true,
        Names = true,
        NameSize = 13,
        Distance = true,
        DistSize = 11,
        HealthBar = true,
        HealthBarWidth = 2.6,
        HealthDynamicColor = false,
        VisibleColor = Color3.fromRGB(94, 255, 170),
        HiddenColor  = Color3.fromRGB(255, 94, 98),
        WallCheck = true,
        VisPerFrame = 2,              -- 🆕 يفحص 2 لاعبين بس كل تحديث (سر التقطيع)
        MobileFPS = 30,               -- مخفض للجوال
        MaxDrawPlayers = 12,          -- مخفض (ارفعه من القائمة لو جوالك قوي)
    },
    Protection = {
        AntiKick = true,
        AntiFreeze = true,
        AntiScreenShake = true,
        AntiLagBack = true,
    },
}

-- ═══════════════════════════════════════════
-- SERVICES
-- ═══════════════════════════════════════════
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")
local Camera = Workspace.CurrentCamera
local LocalPlayer = Players.LocalPlayer

-- ═══════════════════════════════════════════
-- UTILITIES
-- ═══════════════════════════════════════════
local function safeCall(fn, ...)
    local ok, err = pcall(fn, ...)
    if not ok then warn("[Delta]", err) end
    return ok
end

safeCall(function() RunService:UnbindFromRenderStep("DeltaESP") end)
safeCall(function() RunService:UnbindFromRenderStep("DeltaAimbot") end)

local function ClampNumber(n, min, max)
    if typeof(n) ~= "number" or n ~= n or n == math.huge or n == -math.huge then
        return min
    end
    if n < min then return min end
    if n > max then return max end
    return n
end

-- ═══════════════════════════════════════════
-- PROTECTION
-- ═══════════════════════════════════════════
local function ApplyAntiFreeze(char)
    local hum = char and char:FindFirstChildOfClass("Humanoid")
    if hum then
        hum:SetStateEnabled(Enum.HumanoidStateType.FallingDown, false)
        hum:SetStateEnabled(Enum.HumanoidStateType.PlatformStand, false)
    end
end

safeCall(function()
    local mt = getrawmetatable(game)
    if mt then
        local old = mt.__namecall
        setreadonly(mt, false)
        mt.__namecall = newcclosure(function(self, ...)
            local method = getnamecallmethod()
            if Config.Protection.AntiKick and typeof(self) == "Instance" and method == "FireServer" and (self.Name == "Kick" or self.Name == "Ban") then
                return nil
            end
            if old then
                return old(self, ...)
            end
        end)
        setreadonly(mt, true)
    end
end)

safeCall(function()
    LocalPlayer.CharacterAdded:Connect(function(char)
        safeCall(function()
            if Config.Protection.AntiFreeze then ApplyAntiFreeze(char) end
        end)
    end)
    if Config.Protection.AntiFreeze and LocalPlayer.Character then
        ApplyAntiFreeze(LocalPlayer.Character)
    end
end)

safeCall(function()
    local function applyCameraType()
        if not Config.Protection.AntiScreenShake then return end
        Camera = Workspace.CurrentCamera or Camera
        if Camera then Camera.CameraType = Enum.CameraType.Custom end
    end
    applyCameraType()
    LocalPlayer.CharacterAdded:Connect(applyCameraType)
end)

safeCall(function()
    LocalPlayer.CharacterAdded:Connect(function(char)
        safeCall(function()
            local root = char:WaitForChild("HumanoidRootPart", 5)
            if not root then return end
            local lastCF = root.CFrame
            root:GetPropertyChangedSignal("CFrame"):Connect(function()
                if not Config.Protection.AntiLagBack then
                    lastCF = root.CFrame
                    return
                end
                if (root.Position - lastCF.Position).Magnitude > 200 then
                    root.CFrame = lastCF
                else
                    lastCF = root.CFrame
                end
            end)
        end)
    end)
end)

-- ═══════════════════════════════════════════
-- ESP (Performance Optimized)
-- ═══════════════════════════════════════════
local ESP = {}
ESP.Objects = {}
ESP.Candidates = {}
ESP.VisCache = {}        -- نتيجة الرؤية لكل لاعب (تتحدث بالتدريج)
ESP.VisIndex = 0         -- مؤشر الـ round-robin
ESP.LastUpdate = 0

local ESPRayParams = RaycastParams.new()
ESPRayParams.FilterType = Enum.RaycastFilterType.Exclude
ESPRayParams.IgnoreWater = true
local ESPRayIgnore = {}

function ESP:IsPartVisible(part)
    if not Camera or typeof(part) ~= "Instance" or not part:IsA("BasePart") or not part.Parent then
        return false
    end
    local origin = Camera.CFrame.Position
    local target = part.Position
    local dir = target - origin
    local dist = dir.Magnitude
    if typeof(dist) ~= "number" or dist ~= dist or dist == math.huge then return false end
    if dist < 0.05 then return true end
    if dist > Config.ESP.MaxDistance then return false end

    table.clear(ESPRayIgnore)
    if LocalPlayer.Character then ESPRayIgnore[1] = LocalPlayer.Character end
    ESPRayParams.FilterDescendantsInstances = ESPRayIgnore

    local ok, result = pcall(function()
        return Workspace:Raycast(origin, dir.Unit * dist, ESPRayParams)
    end)
    if not ok then return true end
    if not result then return true end
    return result.Instance:IsDescendantOf(part.Parent)
end

-- 🆕 فحص رؤية فوري (يُستدعى بالتدريج، مو لكل اللاعبين)
function ESP:ForceCheckVisible(plr, head, root)
    local visible = self:IsPartVisible(head) or self:IsPartVisible(root)
    self.VisCache[plr] = visible
end

function ESP:Create(player)
    local OC = Color3.fromRGB(10, 10, 14)
    local d = {
        Glow = Drawing.new("Square"),
        BoxOutline = Drawing.new("Square"),
        Box = Drawing.new("Square"),
        TracerOutline = Drawing.new("Line"),
        Tracer = Drawing.new("Line"),
        HP_Outline = Drawing.new("Square"),
        HP_BG = Drawing.new("Square"),
        HP = Drawing.new("Square"),
        Corners = {},
        HeadDot = Drawing.new("Circle"),
        Name = Drawing.new("Text"),
        Dist = Drawing.new("Text"),
    }

    d.Glow.Filled = false
    d.Glow.Thickness = 5
    d.Glow.Transparency = 0.2
    d.Glow.Visible = false

    d.BoxOutline.Filled = false
    d.BoxOutline.Thickness = 3.4
    d.BoxOutline.Color = OC
    d.BoxOutline.Visible = false

    d.Box.Filled = false
    d.Box.Thickness = Config.ESP.BoxThickness
    d.Box.Visible = false

    d.TracerOutline.Thickness = Config.ESP.TracerThickness + 1.4
    d.TracerOutline.Color = OC
    d.TracerOutline.Transparency = 0.5
    d.TracerOutline.Visible = false

    d.Tracer.Thickness = Config.ESP.TracerThickness
    d.Tracer.Transparency = Config.ESP.TracerTransparency
    d.Tracer.Visible = false

    d.HP_Outline.Filled = true
    d.HP_Outline.Color = OC
    d.HP_Outline.Visible = false

    d.HP_BG.Filled = true
    d.HP_BG.Color = Color3.fromRGB(18, 18, 24)
    d.HP_BG.Visible = false

    d.HP.Filled = true
    d.HP.Visible = false

    for i = 1, 8 do
        d.Corners[i] = Drawing.new("Line")
        d.Corners[i].Thickness = Config.ESP.CornerThickness
        d.Corners[i].Visible = false
    end

    d.HeadDot.Filled = false
    d.HeadDot.Thickness = 1.6
    d.HeadDot.NumSides = 20
    d.HeadDot.Visible = false

    d.Name.Size = Config.ESP.NameSize
    d.Name.Center = true
    d.Name.Outline = true
    d.Name.OutlineColor = OC
    d.Name.Color = Color3.fromRGB(255, 255, 255)
    d.Name.Font = Drawing.Fonts.Plex
    d.Name.Visible = false

    d.Dist.Size = Config.ESP.DistSize
    d.Dist.Center = true
    d.Dist.Outline = true
    d.Dist.OutlineColor = OC
    d.Dist.Color = Color3.fromRGB(185, 190, 205)
    d.Dist.Font = Drawing.Fonts.Plex
    d.Dist.Visible = false

    ESP.Objects[player] = d
end

function ESP:RefreshStyles()
    for _, d in pairs(ESP.Objects) do
        d.Box.Thickness = Config.ESP.BoxThickness
        d.Tracer.Thickness = Config.ESP.TracerThickness
        d.Tracer.Transparency = Config.ESP.TracerTransparency
        d.TracerOutline.Thickness = Config.ESP.TracerThickness + 1.4
        d.Name.Size = Config.ESP.NameSize
        d.Dist.Size = Config.ESP.DistSize
        for i = 1, 8 do
            d.Corners[i].Thickness = Config.ESP.CornerThickness
        end
    end
end

function ESP:Hide(plr)
    local d = ESP.Objects[plr]
    if not d then return end
    d.Glow.Visible = false
    d.BoxOutline.Visible = false
    d.Box.Visible = false
    d.TracerOutline.Visible = false
    d.Tracer.Visible = false
    d.HP_Outline.Visible = false
    d.HP_BG.Visible = false
    d.HP.Visible = false
    for i = 1, 8 do d.Corners[i].Visible = false end
    d.HeadDot.Visible = false
    d.Name.Visible = false
    d.Dist.Visible = false
end

function ESP:HideAll()
    for plr in pairs(ESP.Objects) do self:Hide(plr) end
end

function ESP:DrawPlayer(c, cam, centerX, bottomY, viewport)
    local plr, root, head, hum, dist = c.Player, c.Root, c.Head, c.Humanoid, c.Dist

    local rootScreen, onScreen = cam:WorldToViewportPoint(root.Position)
    if not onScreen then
        self:Hide(plr)
        return
    end

    if not ESP.Objects[plr] then self:Create(plr) end
    local d = ESP.Objects[plr]
    if not d then return end

    -- ═══ اللون من الكاش (بدون رايكاست هنا!) ═══
    local visible
    if Config.ESP.WallCheck then
        local v = ESP.VisCache[plr]
        visible = (v == nil) and true or v
    else
        visible = true
    end
    local color = visible and Config.ESP.VisibleColor or Config.ESP.HiddenColor

    local hpRatio = 1
    if hum.MaxHealth > 0 then
        hpRatio = ClampNumber(hum.Health / hum.MaxHealth, 0, 1)
    end
    local hpColor = color
    if Config.ESP.HealthDynamicColor then
        hpColor = Color3.fromRGB(255 * (1 - hpRatio), 210 * hpRatio + 45, 70)
    end

    local topScreen = cam:WorldToViewportPoint(head.Position + Vector3.new(0, 1.1, 0))
    local bottomScreen = cam:WorldToViewportPoint(root.Position - Vector3.new(0, 3.1, 0))
    local yTop = math.min(topScreen.Y, bottomScreen.Y)
    local yBottom = math.max(topScreen.Y, bottomScreen.Y)
    local boxH = ClampNumber(yBottom - yTop, 14, viewport.Y)
    local boxW = boxH * 0.5
    local boxX = rootScreen.X - boxW * 0.5
    local boxY = yTop

    if Config.ESP.BoxGlow then
        d.Glow.Visible = true
        d.Glow.Color = color
        d.Glow.Position = Vector2.new(boxX - 2.5, boxY - 2.5)
        d.Glow.Size = Vector2.new(boxW + 5, boxH + 5)
    else
        d.Glow.Visible = false
    end

    if Config.ESP.BoxEnabled then
        d.BoxOutline.Visible = true
        d.BoxOutline.Position = Vector2.new(boxX, boxY)
        d.BoxOutline.Size = Vector2.new(boxW, boxH)
        d.Box.Visible = true
        d.Box.Color = color
        d.Box.Position = Vector2.new(boxX, boxY)
        d.Box.Size = Vector2.new(boxW, boxH)
    else
        d.BoxOutline.Visible = false
        d.Box.Visible = false
    end

    if Config.ESP.CornersEnabled then
        local cs = ClampNumber(boxH * 0.14, 4, 14)
        d.Corners[1].From = Vector2.new(boxX, boxY + cs); d.Corners[1].To = Vector2.new(boxX, boxY)
        d.Corners[2].From = Vector2.new(boxX, boxY);     d.Corners[2].To = Vector2.new(boxX + cs, boxY)
        d.Corners[3].From = Vector2.new(boxX + boxW - cs, boxY); d.Corners[3].To = Vector2.new(boxX + boxW, boxY)
        d.Corners[4].From = Vector2.new(boxX + boxW, boxY); d.Corners[4].To = Vector2.new(boxX + boxW, boxY + cs)
        d.Corners[5].From = Vector2.new(boxX, boxY + boxH - cs); d.Corners[5].To = Vector2.new(boxX, boxY + boxH)
        d.Corners[6].From = Vector2.new(boxX, boxY + boxH); d.Corners[6].To = Vector2.new(boxX + cs, boxY + boxH)
        d.Corners[7].From = Vector2.new(boxX + boxW - cs, boxY + boxH); d.Corners[7].To = Vector2.new(boxX + boxW, boxY + boxH)
        d.Corners[8].From = Vector2.new(boxX + boxW, boxY + boxH - cs); d.Corners[8].To = Vector2.new(boxX + boxW, boxY + boxH)
        for i = 1, 8 do
            d.Corners[i].Visible = true
            d.Corners[i].Color = color
        end
    else
        for i = 1, 8 do d.Corners[i].Visible = false end
    end

    if Config.ESP.Tracers then
        local from = Vector2.new(centerX, bottomY)
        local to = Vector2.new(rootScreen.X, yBottom + 2)
        if Config.ESP.TracerOutline then
            d.TracerOutline.Visible = true
            d.TracerOutline.From = from
            d.TracerOutline.To = to
        else
            d.TracerOutline.Visible = false
        end
        d.Tracer.Visible = true
        d.Tracer.From = from
        d.Tracer.To = to
        d.Tracer.Color = color
    else
        d.TracerOutline.Visible = false
        d.Tracer.Visible = false
    end

    if Config.ESP.HeadDot then
        local headScreen = cam:WorldToViewportPoint(head.Position)
        d.HeadDot.Visible = true
        d.HeadDot.Position = Vector2.new(headScreen.X, headScreen.Y)
        d.HeadDot.Radius = ClampNumber(boxW * 0.17, 2.5, 8)
        d.HeadDot.Color = color
    else
        d.HeadDot.Visible = false
    end

    if Config.ESP.HealthBar then
        local barW = Config.ESP.HealthBarWidth
        local barX = boxX - barW - 5
        d.HP_Outline.Visible = true
        d.HP_Outline.Position = Vector2.new(barX - 1, boxY - 1)
        d.HP_Outline.Size = Vector2.new(barW + 2, boxH + 2)
        d.HP_BG.Visible = true
        d.HP_BG.Position = Vector2.new(barX, boxY)
        d.HP_BG.Size = Vector2.new(barW, boxH)
        d.HP.Visible = true
        d.HP.Position = Vector2.new(barX, boxY + boxH * (1 - hpRatio))
        d.HP.Size = Vector2.new(barW, math.max(boxH * hpRatio, hpRatio > 0 and 1 or 0))
        d.HP.Color = hpColor
    else
        d.HP_Outline.Visible = false
        d.HP_BG.Visible = false
        d.HP.Visible = false
    end

    if Config.ESP.Names then
        d.Name.Visible = true
        d.Name.Text = plr.DisplayName or plr.Name
        d.Name.Position = Vector2.new(rootScreen.X, boxY - 16)
    else
        d.Name.Visible = false
    end

    if Config.ESP.Distance then
        d.Dist.Visible = true
        d.Dist.Text = string.format("%.0f m", dist)
        d.Dist.Position = Vector2.new(rootScreen.X, yBottom + 5)
    else
        d.Dist.Visible = false
    end
end

function ESP:Update()
    local now = tick()
    local interval = 1 / ClampNumber(Config.ESP.MobileFPS, 10, 120)
    if now - ESP.LastUpdate < interval then return end
    ESP.LastUpdate = now

    if not Config.ESP.Enabled then
        self:HideAll()
        return
    end

    Camera = Workspace.CurrentCamera or Camera
    local cam = Camera
    if not cam then return end

    local viewport = cam.ViewportSize
    if viewport.X <= 0 or viewport.Y <= 0 then return end

    local centerX = viewport.X * 0.5
    local bottomY = viewport.Y
    local camPos = cam.CFrame.Position
    local maxDist = Config.ESP.MaxDistance
    local cap = Config.ESP.MaxDrawPlayers

    local candidates = ESP.Candidates
    table.clear(candidates)

    for _, plr in ipairs(Players:GetPlayers()) do
        if plr ~= LocalPlayer then
            local char = plr.Character
            local root = char and char:FindFirstChild("HumanoidRootPart")
            local head = char and char:FindFirstChild("Head")
            local hum = char and char:FindFirstChild("Humanoid")
            if root and head and hum then
                local dist = (camPos - root.Position).Magnitude
                if typeof(dist) == "number" and dist == dist and dist ~= math.huge and dist <= maxDist then
                    candidates[#candidates + 1] = {
                        Player = plr, Root = root, Head = head, Humanoid = hum, Dist = dist,
                    }
                else
                    if ESP.Objects[plr] then ESP:Hide(plr) end
                end
            else
                if ESP.Objects[plr] then ESP:Hide(plr) end
            end
        end
    end

    if #candidates > 1 then
        table.sort(candidates, function(a, b) return a.Dist < b.Dist end)
    end

    -- 🆕 فحص رؤية مُوزَّع: 2 لاعبين بس كل تحديث (بدل الكل = سر السلاسة)
    if Config.ESP.WallCheck then
        local n = math.min(cap, #candidates)
        if n > 0 then
            local vpf = ClampNumber(Config.ESP.VisPerFrame, 1, 6)
            for k = 1, vpf do
                ESP.VisIndex = (ESP.VisIndex % n) + 1
                local c = candidates[ESP.VisIndex]
                self:ForceCheckVisible(c.Player, c.Head, c.Root)
            end
        end
    end

    for i = 1, #candidates do
        local c = candidates[i]
        if i > cap then
            if ESP.Objects[c.Player] then ESP:Hide(c.Player) end
        else
            self:DrawPlayer(c, cam, centerX, bottomY, viewport)
        end
    end
end

function ESP:Remove(plr)
    local d = ESP.Objects[plr]
    if not d then return end
    d.Glow:Remove(); d.BoxOutline:Remove(); d.Box:Remove()
    d.TracerOutline:Remove(); d.Tracer:Remove()
    d.HP_Outline:Remove(); d.HP_BG:Remove(); d.HP:Remove()
    for i = 1, 8 do d.Corners[i]:Remove() end
    d.HeadDot:Remove(); d.Name:Remove(); d.Dist:Remove()
    ESP.Objects[plr] = nil
    ESP.VisCache[plr] = nil
end

Players.PlayerRemoving:Connect(function(plr)
    safeCall(function() ESP:Remove(plr) end)
end)

LocalPlayer.CharacterAdded:Connect(function()
    safeCall(function()
        local list = {}
        for plr, _ in pairs(ESP.Objects) do table.insert(list, plr) end
        for _, plr in ipairs(list) do ESP:Remove(plr) end
        table.clear(ESP.VisCache)
    end)
end)

-- ═══════════════════════════════════════════
-- GOD AIMBOT (Throttled = سلس)
-- ═══════════════════════════════════════════
pcall(function() RunService:UnbindFromRenderStep("DeltaAimbot") end)

local Aimbot = {
    Locked = nil, LastSwitch = 0, LastShot = 0,
    LastRetarget = 0,             -- 🆕
    LockVisTime = 0,              -- 🆕 كاش رؤية الهدف المقفول
    LockVisResult = true,
    LockVisPart = nil,
}
local AimbotConnections = {}

pcall(function()
    local old = getgenv().DeltaAimbotConnections
    if old then
        for _, c in ipairs(old) do pcall(function() c:Disconnect() end) end
    end
    getgenv().DeltaAimbotConnections = AimbotConnections
end)

local function ConnectAimbot(signal, fn)
    local c = signal:Connect(fn)
    table.insert(AimbotConnections, c)
    return c
end

local function AimSafe(fn, ...)
    local ok, err = pcall(fn, ...)
    if not ok then warn("[Delta Aimbot]", err) end
    return ok, err
end

local function IsFiniteNumber(n)
    return typeof(n) == "number" and n == n and n ~= math.huge and n ~= -math.huge
end

local function AimClamp(n, min, max)
    if not IsFiniteNumber(n) then return min end
    if n < min then return min end
    if n > max then return max end
    return n
end

local function IsFiniteVector(v)
    return typeof(v) == "Vector3" and IsFiniteNumber(v.X) and IsFiniteNumber(v.Y) and IsFiniteNumber(v.Z)
end

local function IsPlayerAlive(plr)
    local char = plr and plr.Character
    if not char then return false end
    local root = char:FindFirstChild("HumanoidRootPart")
        or char:FindFirstChild("Torso")
        or char:FindFirstChild("UpperTorso")
    local hum = char:FindFirstChildOfClass("Humanoid")
    return root ~= nil and hum ~= nil and hum.Health > 0
end

local function IsEnemy(plr)
    local C = Config.Aimbot
    if not C.TeamCheck then return true end
    local meTeam = LocalPlayer.Team
    local plrTeam = plr.Team
    if meTeam == nil or plrTeam == nil then return true end
    return meTeam ~= plrTeam
end

local function GetPartByName(char, name)
    if not char or not name then return nil end
    local p = char:FindFirstChild(name)
    if p and p:IsA("BasePart") then return p end
    return nil
end

local RayParams = RaycastParams.new()
RayParams.FilterType = Enum.RaycastFilterType.Exclude
RayParams.IgnoreWater = true

local lastCamera = Camera
local lastCharacter = LocalPlayer.Character

local function RefreshRayIgnore()
    local ignore = {}
    if LocalPlayer.Character then table.insert(ignore, LocalPlayer.Character) end
    if lastCamera then table.insert(ignore, lastCamera) end
    RayParams.FilterDescendantsInstances = ignore
end
RefreshRayIgnore()

local function MaybeRefreshRayIgnore()
    local cam = Workspace.CurrentCamera or Camera
    local char = LocalPlayer.Character
    if cam ~= lastCamera or char ~= lastCharacter then
        Camera = cam; lastCamera = cam; lastCharacter = char
        RefreshRayIgnore()
    end
end

local function IsPartVisible(part)
    if typeof(part) ~= "Instance" or not part:IsA("BasePart") or not part.Parent then return false end
    MaybeRefreshRayIgnore()
    if not Camera then return false end
    local origin = Camera.CFrame.Position
    local targetPos = part.Position
    if not IsFiniteVector(origin) or not IsFiniteVector(targetPos) then return false end
    local dir = targetPos - origin
    local dist = dir.Magnitude
    if not IsFiniteNumber(dist) then return false end
    if dist < 0.05 then return true end
    if dist > 12000 then return false end
    local ok, result = pcall(function()
        return Workspace:Raycast(origin, dir.Unit * (dist + 0.1), RayParams)
    end)
    if not ok then return true end
    if not result then return true end
    return result.Instance:IsDescendantOf(part.Parent)
end

-- 🆕 مخففة: 3 أجزاء بس بدل 6 (رايكاستات أقل)
local function GetBestAimPart(plr)
    local C = Config.Aimbot
    local char = plr and plr.Character
    if not char or not Camera then return nil end
    local wallCheck = C.WallCheck ~= false
    local dynamicBone = C.DynamicBone == nil or C.DynamicBone
    local preferred = {C.AimPart, "Head", "HumanoidRootPart"}

    if not dynamicBone then
        for _, name in ipairs(preferred) do
            local part = GetPartByName(char, name)
            if part and (not wallCheck or IsPartVisible(part)) then return part end
        end
        return nil
    end

    local bestPart, bestScore = nil, math.huge
    local camPos = Camera.CFrame.Position
    local checked = {}

    local function Consider(name, weight)
        if not name or checked[name] then return end
        checked[name] = true
        local part = GetPartByName(char, name)
        if part and IsFiniteVector(part.Position) and (not wallCheck or IsPartVisible(part)) then
            local score = (part.Position - camPos).Magnitude * weight
            if IsFiniteNumber(score) and score < bestScore then
                bestScore = score; bestPart = part
            end
        end
    end

    Consider(C.AimPart, 0.55)
    Consider("Head", 0.60)
    Consider("HumanoidRootPart", 0.78)

    return bestPart
end

local function GetTargetScore(plr, part)
    local C = Config.Aimbot
    if typeof(part) ~= "Instance" or not part.Parent or not Camera then return nil end
    local partPos = part.Position
    if not IsFiniteVector(partPos) then return nil end
    local viewport = Camera.ViewportSize
    if viewport.X <= 0 or viewport.Y <= 0 then return nil end
    local screenPos, onScreen = Camera:WorldToViewportPoint(partPos)
    if not onScreen then return nil end
    local center = Vector2.new(viewport.X * 0.5, viewport.Y * 0.5)
    local screenDist = (Vector2.new(screenPos.X, screenPos.Y) - center).Magnitude
    if not IsFiniteNumber(screenDist) then return nil end
    local fov = C.FOV or 0
    if fov > 0 and screenDist > fov then return nil end
    local worldDist = (partPos - Camera.CFrame.Position).Magnitude
    local hum = plr.Character and plr.Character:FindFirstChildOfClass("Humanoid")
    local hpRatio = 1
    if hum and hum.MaxHealth > 0 then
        hpRatio = AimClamp(hum.Health / hum.MaxHealth, 0, 1)
    end
    local score = screenDist * (C.ScreenWeight or 1)
    score = score + worldDist * (C.DistanceWeight or 0.12)
    score = score - (1 - hpRatio) * (C.HealthWeight or 45)
    if not IsFiniteNumber(score) then return nil end
    return score, screenDist
end

function Aimbot:GetTarget()
    local C = Config.Aimbot
    if not Camera then return nil end
    local candidates = {}
    for _, plr in ipairs(Players:GetPlayers()) do
        if plr ~= LocalPlayer and IsEnemy(plr) and IsPlayerAlive(plr) then
            local char = plr.Character
            local part = GetPartByName(char, C.AimPart)
                or GetPartByName(char, "Head")
                or GetPartByName(char, "HumanoidRootPart")
            if part then
                local score = GetTargetScore(plr, part)
                if score then table.insert(candidates, {Player = plr, Score = score}) end
            end
        end
    end
    if #candidates == 0 then return nil end
    table.sort(candidates, function(a, b) return a.Score < b.Score end)
    local maxChecks = math.max(1, C.MaxVisibilityChecks or 2)
    for i = 1, math.min(maxChecks, #candidates) do
        local cand = candidates[i]
        local part = GetBestAimPart(cand.Player)
        if part then
            local score = GetTargetScore(cand.Player, part)
            if score then return {Player = cand.Player, Part = part, Score = score} end
        end
    end
    return nil
end

-- 🆕 رؤية الهدف المقفول بكاش (تتجدد كل 0.15ث بدل كل فريم)
function Aimbot:IsLockedValid()
    local C = Config.Aimbot
    local t = self.Locked
    if not t or not t.Player or not t.Part then return false end
    if t.Player == LocalPlayer then return false end
    if not IsEnemy(t.Player) then return false end
    if not IsPlayerAlive(t.Player) then return false end
    if typeof(t.Part) ~= "Instance" or not t.Part.Parent then
        local newPart = GetBestAimPart(t.Player)
        if not newPart then return false end
        t.Part = newPart
        self.LockVisPart = newPart; self.LockVisResult = true; self.LockVisTime = tick()
    end
    if C.WallCheck ~= false then
        local now = tick()
        if self.LockVisPart ~= t.Part or now - self.LockVisTime > 0.15 then
            self.LockVisTime = now
            self.LockVisPart = t.Part
            local vis = IsPartVisible(t.Part)
            if not vis then
                local alt = GetBestAimPart(t.Player)
                if alt then t.Part = alt; self.LockVisPart = alt; vis = true end
            end
            self.LockVisResult = vis
        end
        if not self.LockVisResult then return false end
    end
    local fov = C.FOV or 0
    if fov > 0 then
        local _, screenDist = GetTargetScore(t.Player, t.Part)
        if not screenDist then return false end
        local lockFov = fov * (C.LockFOVScale or 1.35)
        if screenDist > lockFov then return false end
    end
    return true
end

function Aimbot:ForceSwitch()
    self.Locked = nil
    self.LastSwitch = tick()
end

local function TrySwitchLock()
    local C = Config.Aimbot
    if C.LockSwitchKey then
        local ok, down = pcall(function() return UserInputService:IsKeyDown(C.LockSwitchKey) end)
        if ok and down and tick() - Aimbot.LastSwitch > (C.SwitchCooldown or 0.3) then
            Aimbot:ForceSwitch()
        end
    end
end

local function PredictPosition(part, basePos)
    local C = Config.Aimbot
    if not C.Prediction then return basePos end
    if typeof(part) ~= "Instance" or not part:IsA("BasePart") or not Camera then return basePos end
    if not IsFiniteVector(basePos) then return basePos end
    local vel = part.AssemblyLinearVelocity or part.Velocity or Vector3.zero
    if not IsFiniteVector(vel) then vel = Vector3.zero end
    local origin = Camera.CFrame.Position
    local dist = (basePos - origin).Magnitude
    if not IsFiniteNumber(dist) then return basePos end
    local speed = C.ProjectileSpeed or 0
    local travelTime
    if speed > 0 then travelTime = dist / speed else travelTime = dist / 1200 end
    travelTime = travelTime * (C.PredictionFactor or 0.2)
    if not IsFiniteNumber(travelTime) then travelTime = 0 end
    travelTime = AimClamp(travelTime, 0, 0.45)
    local predicted = basePos + vel * travelTime
    if C.GravityCompensation and speed > 0 then
        local g = Workspace.Gravity or 196.2
        predicted = predicted + Vector3.new(0, 0.5 * g * travelTime * travelTime, 0)
    end
    if not IsFiniteVector(predicted) then return basePos end
    return predicted
end

local function AimAtPosition(targetPos, dt)
    local C = Config.Aimbot
    if not Camera or not IsFiniteVector(targetPos) then return end
    local origin = Camera.CFrame.Position
    if not IsFiniteVector(origin) then return end
    if (targetPos - origin).Magnitude < 0.01 then return end
    local goal = CFrame.new(origin, targetPos)
    local smooth = C.Smoothness
    if smooth == nil then smooth = 1 end
    if smooth >= 1 or dt == nil then
        Camera.CFrame = goal
    else
        local speed = C.SmoothSpeed or 20
        local frameDt = AimClamp(typeof(dt) == "number" and dt or 0, 0, 0.1)
        local alpha = 1 - math.exp(-speed * frameDt)
        alpha = alpha * AimClamp(smooth, 0.01, 1)
        Camera.CFrame = Camera.CFrame:Lerp(goal, alpha)
    end
end

local function TryAutoShoot()
    local C = Config.Aimbot
    if not C.AutoShoot then return end
    local delay = C.AutoShootDelay or 0.09
    if tick() - Aimbot.LastShot < delay then return end
    Aimbot.LastShot = tick()
    task.spawn(function()
        AimSafe(function()
            local vim = game:GetService("VirtualInputManager")
            vim:SendMouseButtonEvent(0, 0, 0, true, nil, 0)
            task.wait(0.02)
            vim:SendMouseButtonEvent(0, 0, 0, false, nil, 0)
        end)
    end)
end

-- 🆕 اختيار الهدف throttled (التصويب نفسه كل فريم = سلس)
function Aimbot:Update(dt)
    local C = Config.Aimbot
    MaybeRefreshRayIgnore()
    if not C.Enabled then self.Locked = nil; return end
    if not IsPlayerAlive(LocalPlayer) then self.Locked = nil; return end
    TrySwitchLock()

    local now = tick()
    if C.LockTarget and self.Locked then
        if not self:IsLockedValid() then self.Locked = nil end
    end
    if not self.Locked then
        if now - self.LastRetarget >= (C.RetargetInterval or 0.12) then
            self.LastRetarget = now
            self.Locked = self:GetTarget()
        end
    end

    local target = self.Locked
    if not target then return end
    local part = target.Part
    if typeof(part) ~= "Instance" or not part.Parent then self.Locked = nil; return end
    local aimPos = PredictPosition(part, part.Position)
    AimAtPosition(aimPos, dt)
    TryAutoShoot()
end

if UserInputService.TouchEnabled and Config.Aimbot.TouchSwitch ~= false then
    pcall(function()
        ConnectAimbot(UserInputService.TouchTap, function(touchPositions, processedByUI)
            if processedByUI then return end
            if touchPositions and #touchPositions >= 2 then Aimbot:ForceSwitch() end
        end)
    end)
end

-- ═══════════════════════════════════════════
-- تشغيل
-- ═══════════════════════════════════════════
RunService:BindToRenderStep("DeltaESP", 200, function() safeCall(ESP.Update, ESP) end)
RunService:BindToRenderStep("DeltaAimbot", Enum.RenderPriority.Camera.Value + 1, function() safeCall(Aimbot.Update, Aimbot) end)

print("[Delta] Mobile Pro (Lag Fix) loaded.")

-- ═══════════════════════════════════════════
-- القائمة (WindUI)
-- ═══════════════════════════════════════════
safeCall(function()
    local WindUI = loadstring(game:HttpGet("https://raw.githubusercontent.com/Footagesus/WindUI/main/dist/main.lua"))()

    local Window = WindUI:CreateWindow({
        Title = "Delta Hub",
        Author = "Mobile Pro",
        Icon = "crosshair",
        Theme = "Dark",
    })
    Window:SetToggleKey(Enum.KeyCode.RightShift)

    -- ═══════════ AIMBOT ═══════════
    local AimTab = Window:Tab({ Title = "Aimbot", Icon = "crosshair" })

    local AimMain = AimTab:Section({ Title = "Main", Box = true, BoxBorder = true, Opened = true })
    AimMain:Toggle({ Title = "Enable Aimbot", Value = Config.Aimbot.Enabled, Callback = function(v) Config.Aimbot.Enabled = v end })
    AimMain:Dropdown({
        Title = "Aim Part",
        Values = { "Head", "HumanoidRootPart", "UpperTorso", "Torso" },
        Value = Config.Aimbot.AimPart,
        Callback = function(v) Config.Aimbot.AimPart = v end,
    })
    AimMain:Toggle({ Title = "Team Check", Value = Config.Aimbot.TeamCheck, Callback = function(v) Config.Aimbot.TeamCheck = v end })
    AimMain:Toggle({ Title = "Wall Check", Value = Config.Aimbot.WallCheck, Callback = function(v) Config.Aimbot.WallCheck = v end })

    local AimPred = AimTab:Section({ Title = "Prediction", Box = true, BoxBorder = true, Opened = true })
    AimPred:Toggle({ Title = "Prediction", Value = Config.Aimbot.Prediction, Callback = function(v) Config.Aimbot.Prediction = v end })
    AimPred:Slider({
        Title = "Prediction Factor", Step = 0.05,
        Value = { Min = 0, Max = 1, Default = Config.Aimbot.PredictionFactor },
        Callback = function(v) Config.Aimbot.PredictionFactor = v end,
    })

    local AimBeh = AimTab:Section({ Title = "Behavior", Box = true, BoxBorder = true, Opened = true })
    AimBeh:Slider({
        Title = "Smoothness", Step = 0.05,
        Value = { Min = 0.05, Max = 1, Default = Config.Aimbot.Smoothness },
        Callback = function(v) Config.Aimbot.Smoothness = v end,
    })
    AimBeh:Toggle({ Title = "Lock Target", Value = Config.Aimbot.LockTarget, Callback = function(v) Config.Aimbot.LockTarget = v end })
    AimBeh:Toggle({ Title = "Auto Shoot", Value = Config.Aimbot.AutoShoot, Callback = function(v) Config.Aimbot.AutoShoot = v end })
    AimBeh:Toggle({ Title = "Touch Switch (2 fingers)", Value = Config.Aimbot.TouchSwitch, Callback = function(v) Config.Aimbot.TouchSwitch = v end })
    AimBeh:Slider({
        Title = "Target Refresh (s)", Desc = "أكبر = سلاسة أكثر، أصغر = استجابة أسرع",
        Step = 0.01,
        Value = { Min = 0.05, Max = 0.4, Default = Config.Aimbot.RetargetInterval },
        Callback = function(v) Config.Aimbot.RetargetInterval = v end,
    })
    AimBeh:Keybind({
        Title = "Switch Lock Key", Value = "LeftShift",
        Callback = function(keyName)
            if keyName ~= "MouseLeft" and keyName ~= "MouseRight" and Enum.KeyCode[keyName] then
                Config.Aimbot.LockSwitchKey = Enum.KeyCode[keyName]
            end
        end,
    })

    -- ═══════════ ESP ═══════════
    local ESPTab = Window:Tab({ Title = "ESP", Icon = "eye" })

    local ESPMain = ESPTab:Section({ Title = "Main", Box = true, BoxBorder = true, Opened = true })
    ESPMain:Toggle({ Title = "Enable ESP", Value = Config.ESP.Enabled, Callback = function(v) Config.ESP.Enabled = v end })
    ESPMain:Toggle({
        Title = "Wall Check Colors", Desc = "أخضر = ظاهر | أحمر = خلف جدار",
        Value = Config.ESP.WallCheck, Callback = function(v) Config.ESP.WallCheck = v end,
    })

    local ESPVis = ESPTab:Section({ Title = "Visuals", Box = true, BoxBorder = true, Opened = true })
    ESPVis:Toggle({ Title = "Box", Value = Config.ESP.BoxEnabled, Callback = function(v) Config.ESP.BoxEnabled = v end })
    ESPVis:Toggle({ Title = "Box Glow", Value = Config.ESP.BoxGlow, Callback = function(v) Config.ESP.BoxGlow = v end })
    ESPVis:Toggle({ Title = "Corners", Value = Config.ESP.CornersEnabled, Callback = function(v) Config.ESP.CornersEnabled = v end })
    ESPVis:Toggle({ Title = "Tracers", Value = Config.ESP.Tracers, Callback = function(v) Config.ESP.Tracers = v end })
    ESPVis:Toggle({ Title = "Tracer Outline", Value = Config.ESP.TracerOutline, Callback = function(v) Config.ESP.TracerOutline = v end })
    ESPVis:Toggle({ Title = "Head Dot", Value = Config.ESP.HeadDot, Callback = function(v) Config.ESP.HeadDot = v end })
    ESPVis:Toggle({ Title = "Names", Value = Config.ESP.Names, Callback = function(v) Config.ESP.Names = v end })
    ESPVis:Toggle({ Title = "Distance", Value = Config.ESP.Distance, Callback = function(v) Config.ESP.Distance = v end })
    ESPVis:Toggle({ Title = "Health Bar", Value = Config.ESP.HealthBar, Callback = function(v) Config.ESP.HealthBar = v end })
    ESPVis:Toggle({ Title = "Dynamic Health Color", Value = Config.ESP.HealthDynamicColor, Callback = function(v) Config.ESP.HealthDynamicColor = v end })

    local ESPCol = ESPTab:Section({ Title = "Colors", Box = true, BoxBorder = true, Opened = true })
    ESPCol:Colorpicker({ Title = "Visible Color", Default = Config.ESP.VisibleColor, Callback = function(color) Config.ESP.VisibleColor = color end })
    ESPCol:Colorpicker({ Title = "Hidden Color", Default = Config.ESP.HiddenColor, Callback = function(color) Config.ESP.HiddenColor = color end })

    local ESPStyle = ESPTab:Section({ Title = "Sizes", Box = true, BoxBorder = true, Opened = false })
    ESPStyle:Slider({ Title = "Box Thickness", Step = 0.1, Value = { Min = 0.5, Max = 4, Default = Config.ESP.BoxThickness }, Callback = function(v) Config.ESP.BoxThickness = v; ESP:RefreshStyles() end })
    ESPStyle:Slider({ Title = "Corner Thickness", Step = 0.1, Value = { Min = 0.5, Max = 5, Default = Config.ESP.CornerThickness }, Callback = function(v) Config.ESP.CornerThickness = v; ESP:RefreshStyles() end })
    ESPStyle:Slider({ Title = "Tracer Thickness", Step = 0.1, Value = { Min = 0.5, Max = 4, Default = Config.ESP.TracerThickness }, Callback = function(v) Config.ESP.TracerThickness = v; ESP:RefreshStyles() end })
    ESPStyle:Slider({ Title = "Name Size", Step = 1, Value = { Min = 8, Max = 24, Default = Config.ESP.NameSize }, Callback = function(v) Config.ESP.NameSize = v; ESP:RefreshStyles() end })
    ESPStyle:Slider({ Title = "Health Bar Width", Step = 0.2, Value = { Min = 1, Max = 6, Default = Config.ESP.HealthBarWidth }, Callback = function(v) Config.ESP.HealthBarWidth = v end })

    local ESPPerf = ESPTab:Section({ Title = "Performance ⚡", Box = true, BoxBorder = true, Opened = true })
    ESPPerf:Slider({
        Title = "Wall Check Speed", Desc = "1 = أخف للجوال، 4 = أدق",
        Step = 1, Value = { Min = 1, Max = 4, Default = Config.ESP.VisPerFrame },
        Callback = function(v) Config.ESP.VisPerFrame = v end,
    })
    ESPPerf:Slider({ Title = "Mobile FPS", Step = 5, Value = { Min = 15, Max = 60, Default = Config.ESP.MobileFPS }, Callback = function(v) Config.ESP.MobileFPS = v end })
    ESPPerf:Slider({ Title = "Max Players", Step = 1, Value = { Min = 1, Max = 30, Default = Config.ESP.MaxDrawPlayers }, Callback = function(v) Config.ESP.MaxDrawPlayers = v end })
    ESPPerf:Slider({ Title = "Max Distance", Step = 100, Value = { Min = 500, Max = 5000, Default = Config.ESP.MaxDistance }, Callback = function(v) Config.ESP.MaxDistance = v end })

    -- ═══════════ PROTECTION ═══════════
    local ProtTab = Window:Tab({ Title = "Protection", Icon = "shield" })
    local ProtSec = ProtTab:Section({ Title = "Anti-Cheat Bypass", Box = true, BoxBorder = true, Opened = true })
    ProtSec:Toggle({ Title = "Anti Kick", Value = Config.Protection.AntiKick, Callback = function(v) Config.Protection.AntiKick = v end })
    ProtSec:Toggle({ Title = "Anti Freeze", Value = Config.Protection.AntiFreeze, Callback = function(v) Config.Protection.AntiFreeze = v; if v and LocalPlayer.Character then ApplyAntiFreeze(LocalPlayer.Character) end end })
    ProtSec:Toggle({ Title = "Anti Screen Shake", Value = Config.Protection.AntiScreenShake, Callback = function(v) Config.Protection.AntiScreenShake = v; if v and Camera then Camera.CameraType = Enum.CameraType.Custom end end })
    ProtSec:Toggle({ Title = "Anti Lag Back", Value = Config.Protection.AntiLagBack, Callback = function(v) Config.Protection.AntiLagBack = v end })

    -- ═══════════ SETTINGS ═══════════
    local SetTab = Window:Tab({ Title = "Settings", Icon = "settings" })
    local SetSec = SetTab:Section({ Title = "Menu", Box = true, BoxBorder = true, Opened = true })
    SetSec:Keybind({ Title = "Toggle Menu Key", Value = "RightShift", Callback = function(keyName) if Enum.KeyCode[keyName] then Window:SetToggleKey(Enum.KeyCode[keyName]) end end })
    SetSec:Button({ Title = "Close Menu", Icon = "x", Callback = function() Window:Close() end })
    SetSec:Button({
        Title = "Destroy Script", Icon = "trash", Color = Color3.fromRGB(255, 80, 80),
        Callback = function()
            safeCall(function() RunService:UnbindFromRenderStep("DeltaESP") end)
            safeCall(function() RunService:UnbindFromRenderStep("DeltaAimbot") end)
            safeCall(function() for plr in pairs(ESP.Objects) do ESP:Remove(plr) end end)
            safeCall(function() Window:Destroy() end)
        end,
    })

    AimTab:Select()
    WindUI:Notify({ Title = "Delta Hub", Content = "نسخة Lag Fix — افتح من الشريط أعلى يمين", Icon = "check", Duration = 5 })
end)
