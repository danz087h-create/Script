-- SCRIPT RATON 🎃
-- WindUI client script
-- NOTE: This loadstring/HttpGet loader is NOT supported by a normal Roblox Studio
-- LocalScript. It requires an environment that supports both APIs.
-- For standard Studio use, install WindUI as a ModuleScript/package instead.

local WindUI = loadstring(game:HttpGet(
    "https://github.com/Footagesus/WindUI/releases/latest/download/main.lua"
))()

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")

local LocalPlayer = Players.LocalPlayer
local PlayerGui = LocalPlayer:WaitForChild("PlayerGui")

local Settings = {
    MonsterESP = true,
    PlayerESP = false,
    InfiniteJump = false,
    KeyFinder = false,
    EnemyRange = 500,
    KeyRange = 1000,
}

local tracked = {}
local scanTimer = 0

local function getRoot(model)
    if not model or not model:IsA("Model") then
        return nil
    end

    return model:FindFirstChild("HumanoidRootPart")
        or model.PrimaryPart
        or model:FindFirstChild("Head")
end

local function isPlayerCharacter(model)
    for _, player in ipairs(Players:GetPlayers()) do
        if player.Character == model then
            return true
        end
    end
    return false
end

local function clearVisual(instance)
    local data = tracked[instance]
    if not data then
        return
    end

    if data.highlight then
        data.highlight:Destroy()
    end
    if data.billboard then
        data.billboard:Destroy()
    end

    tracked[instance] = nil
end

local function addVisual(instance, label, color)
    local root = getRoot(instance)
    if not root then
        return
    end

    local existing = tracked[instance]
    if existing then
        if existing.highlight and existing.highlight.Parent and existing.billboard and existing.billboard.Parent then
            return
        end
        clearVisual(instance)
    end

    local highlight = Instance.new("Highlight")
    highlight.Name = "RatonESP_Highlight"
    highlight.Adornee = instance
    highlight.FillColor = color
    highlight.OutlineColor = color
    highlight.FillTransparency = 0.72
    highlight.OutlineTransparency = 0
    highlight.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
    highlight.Parent = instance

    local billboard = Instance.new("BillboardGui")
    billboard.Name = "RatonESP_Label"
    billboard.Adornee = root
    billboard.Size = UDim2.fromOffset(150, 28)
    billboard.StudsOffset = Vector3.new(0, 3, 0)
    billboard.AlwaysOnTop = true
    billboard.Parent = PlayerGui

    local text = Instance.new("TextLabel")
    text.BackgroundTransparency = 1
    text.Size = UDim2.fromScale(1, 1)
    text.Font = Enum.Font.GothamBold
    text.Text = label
    text.TextColor3 = color
    text.TextStrokeTransparency = 0.25
    text.TextScaled = true
    text.Parent = billboard

    tracked[instance] = {
        highlight = highlight,
        billboard = billboard,
    }
end

local function isEnemy(model)
    if not model:IsA("Model") or model == LocalPlayer.Character then
        return false
    end
    if isPlayerCharacter(model) then
        return false
    end

    local humanoid = model:FindFirstChildOfClass("Humanoid")
    return humanoid ~= nil and humanoid.Health > 0 and getRoot(model) ~= nil
end

local function isKeyObject(instance)
    if instance:IsA("ProximityPrompt") then
        local parent = instance.Parent
        return parent ~= nil
    end

    if instance:IsA("ClickDetector") then
        return instance.Parent ~= nil
    end

    return false
end

local function getObjectPart(instance)
    local parent = instance.Parent
    if not parent then
        return nil
    end

    if parent:IsA("BasePart") then
        return parent
    end

    if parent:IsA("Model") then
        return getRoot(parent)
    end

    return parent:FindFirstAncestorWhichIsA("BasePart")
end

local function updateESP()
    local keep = {}

    if Settings.MonsterESP then
        local characterRoot = getRoot(LocalPlayer.Character)
        local mickey = Workspace:FindFirstChild("Mickey")
        local root = getRoot(mickey)

        if mickey and root and characterRoot
            and (root.Position - characterRoot.Position).Magnitude <= Settings.EnemyRange then
            keep[mickey] = true
            addVisual(mickey, mickey.Name, Color3.fromRGB(255, 75, 75))
        end
    end

    if Settings.PlayerESP then
        local characterRoot = getRoot(LocalPlayer.Character)
        if characterRoot then
            for _, player in ipairs(Players:GetPlayers()) do
                if player ~= LocalPlayer and player.Character then
                    local root = getRoot(player.Character)
                    if root and (root.Position - characterRoot.Position).Magnitude <= Settings.EnemyRange then
                        keep[player.Character] = true
                        addVisual(player.Character, player.Name, Color3.fromRGB(80, 170, 255))
                    end
                end
            end
        end
    end

    if Settings.KeyFinder then
        local characterRoot = getRoot(LocalPlayer.Character)
        if characterRoot then
            for _, object in ipairs(Workspace:GetDescendants()) do
                if isKeyObject(object) then
                    local part = getObjectPart(object)
                    if part and (part.Position - characterRoot.Position).Magnitude <= Settings.KeyRange then
                        local model = part:FindFirstAncestorOfClass("Model")
                        local target = model or part
                        keep[target] = true
                        addVisual(target, "INTERACTABLE", Color3.fromRGB(255, 220, 70))
                    end
                end
            end
        end
    end

    for instance in pairs(tracked) do
        if not keep[instance] or not instance.Parent then
            clearVisual(instance)
        end
    end
end

RunService.Heartbeat:Connect(function(deltaTime)
    scanTimer += deltaTime
    if scanTimer >= 0.4 then
        scanTimer = 0
        updateESP()
    end
end)

UserInputService.JumpRequest:Connect(function()
    if not Settings.InfiniteJump then
        return
    end

    local character = LocalPlayer.Character
    local humanoid = character and character:FindFirstChildOfClass("Humanoid")
    if humanoid then
        humanoid:ChangeState(Enum.HumanoidStateType.Jumping)
    end
end)

LocalPlayer.CharacterRemoving:Connect(function()
    for instance in pairs(tracked) do
        clearVisual(instance)
    end
end)

local Window = WindUI:CreateWindow({
    Title = "SCRIPT RATON 🎃",
    Icon = "ghost",
    Author = "Raton",
    Folder = "ScriptRaton",
    Size = UDim2.fromOffset(520, 420),
    Transparent = true,
    Theme = "Dark",
    SideBarWidth = 170,
})

local MainTab = Window:Tab({
    Title = "Main",
    Icon = "house",
    Locked = false,
})

MainTab:Toggle({
    Title = "Monster ESP",
    Desc = "Show nearby NPC enemies",
    Icon = "skull",
    Type = "Checkbox",
    Value = Settings.MonsterESP,
    Callback = function(value)
        Settings.MonsterESP = value
    end,
})

MainTab:Slider({
    Title = "Enemy ESP Range",
    Step = 25,
    Value = {
        Min = 50,
        Max = 2000,
        Default = Settings.EnemyRange,
    },
    Callback = function(value)
        Settings.EnemyRange = tonumber(value) or Settings.EnemyRange
    end,
})

MainTab:Toggle({
    Title = "Player ESP",
    Desc = "Show other players",
    Icon = "users",
    Type = "Checkbox",
    Value = Settings.PlayerESP,
    Callback = function(value)
        Settings.PlayerESP = value
    end,
})

MainTab:Toggle({
    Title = "Infinite Jump",
    Desc = "Jump repeatedly while enabled",
    Icon = "arrow-up",
    Type = "Checkbox",
    Value = Settings.InfiniteJump,
    Callback = function(value)
        Settings.InfiniteJump = value
    end,
})

local VisualTab = Window:Tab({
    Title = "Visuals",
    Icon = "eye",
    Locked = false,
})

VisualTab:Toggle({
    Title = "Key Finder",
    Desc = "Highlight objects with ProximityPrompt or ClickDetector",
    Icon = "key-round",
    Type = "Checkbox",
    Value = Settings.KeyFinder,
    Callback = function(value)
        Settings.KeyFinder = value
    end,
})

VisualTab:Slider({
    Title = "Key Finder Range",
    Step = 50,
    Value = {
        Min = 100,
        Max = 3000,
        Default = Settings.KeyRange,
    },
    Callback = function(value)
        Settings.KeyRange = tonumber(value) or Settings.KeyRange
    end,
})

WindUI:Notify({
    Title = "SCRIPT RATON 🎃",
    Content = "Loaded successfully",
    Duration = 4,
    Icon = "check-circle",
})
