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
    PlayerInfo = true,
    HighlightModel = true,
    ShowDistance = true,
    InfiniteJump = false,
    KeyFinder = false,
    EnemyRange = 500,
    KeyRange = 1000,
}

local MONSTER_NAME = "Mickey" -- Workspace.Mickey

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

-- Susun teks label: nama, info tambahan (HP), dan jarak
local function buildLabel(name, extra, distance)
    local second = {}

    if extra then
        table.insert(second, extra)
    end
    if Settings.ShowDistance and distance then
        table.insert(second, string.format("%dm", math.floor(distance + 0.5)))
    end

    if #second == 0 then
        return name
    end
    return name .. "\n" .. table.concat(second, "  |  ")
end

local function getHealthText(model)
    local humanoid = model:FindFirstChildOfClass("Humanoid")
    if not humanoid then
        return nil
    end

    return string.format("HP %d/%d", math.floor(humanoid.Health + 0.5), math.floor(humanoid.MaxHealth + 0.5))
end

local function addVisual(instance, label, color)
    local root = getRoot(instance) or (instance:IsA("BasePart") and instance or nil)
    if not root then
        return
    end

    local existing = tracked[instance]
    if existing then
        if existing.highlight and existing.highlight.Parent
            and existing.billboard and existing.billboard.Parent then
            existing.highlight.Enabled = Settings.HighlightModel
            existing.text.Text = label
            return
        end
        clearVisual(instance)
    end

    local highlight = Instance.new("Highlight")
    highlight.Name = "RatonESP_Highlight"
    highlight.Adornee = instance
    highlight.FillColor = color
    highlight.OutlineColor = Color3.new(1, 1, 1)
    highlight.FillTransparency = 0.45
    highlight.OutlineTransparency = 0
    highlight.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
    highlight.Enabled = Settings.HighlightModel
    highlight.Parent = instance

    local billboard = Instance.new("BillboardGui")
    billboard.Name = "RatonESP_Label"
    billboard.Adornee = root
    billboard.Size = UDim2.fromOffset(180, 42)
    billboard.StudsOffset = Vector3.new(0, 3.5, 0)
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
    text.TextWrapped = true
    text.Parent = billboard

    tracked[instance] = {
        highlight = highlight,
        billboard = billboard,
        text = text,
    }
end

local function isKeyObject(instance)
    if instance:IsA("ProximityPrompt") then
        return instance.Parent ~= nil
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
    local characterRoot = getRoot(LocalPlayer.Character)

    -- Monster ESP (Workspace.Mickey)
    if Settings.MonsterESP and characterRoot then
        local monster = Workspace:FindFirstChild(MONSTER_NAME)
        local root = getRoot(monster)

        if monster and root then
            local distance = (root.Position - characterRoot.Position).Magnitude
            if distance <= Settings.EnemyRange then
                keep[monster] = true
                addVisual(
                    monster,
                    buildLabel(monster.Name, getHealthText(monster), distance),
                    Color3.fromRGB(255, 75, 75)
                )
            end
        end
    end

    -- Player ESP + Player Info
    if Settings.PlayerESP and characterRoot then
        for _, player in ipairs(Players:GetPlayers()) do
            if player ~= LocalPlayer and player.Character then
                local character = player.Character
                local root = getRoot(character)

                if root then
                    local distance = (root.Position - characterRoot.Position).Magnitude
                    if distance <= Settings.EnemyRange then
                        local name = player.Name
                        local extra = nil

                        if Settings.PlayerInfo then
                            name = string.format("%s (@%s)", player.DisplayName, player.Name)
                            extra = getHealthText(character)
                        end

                        keep[character] = true
                        addVisual(
                            character,
                            buildLabel(name, extra, distance),
                            Color3.fromRGB(80, 170, 255)
                        )
                    end
                end
            end
        end
    end

    -- Key Finder
    if Settings.KeyFinder and characterRoot then
        for _, object in ipairs(Workspace:GetDescendants()) do
            if isKeyObject(object) then
                local part = getObjectPart(object)
                if part then
                    local distance = (part.Position - characterRoot.Position).Magnitude
                    if distance <= Settings.KeyRange then
                        local model = part:FindFirstAncestorOfClass("Model")
                        local target = model or part
                        keep[target] = true
                        addVisual(
                            target,
                            buildLabel("INTERACTABLE", nil, distance),
                            Color3.fromRGB(255, 220, 70)
                        )
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
    if scanTimer >= 0.2 then
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
    Desc = "Show Mickey with distance",
    Icon = "skull",
    Type = "Checkbox",
    Value = Settings.MonsterESP,
    Callback = function(value)
        Settings.MonsterESP = value
    end,
})

MainTab:Slider({
    Title = "ESP Range",
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
    Title = "Player Info",
    Desc = "Show display name, username, and HP on players",
    Icon = "info",
    Type = "Checkbox",
    Value = Settings.PlayerInfo,
    Callback = function(value)
        Settings.PlayerInfo = value
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
    Title = "Highlight Model",
    Desc = "Fill and outline the whole model",
    Icon = "box",
    Type = "Checkbox",
    Value = Settings.HighlightModel,
    Callback = function(value)
        Settings.HighlightModel = value
    end,
})

VisualTab:Toggle({
    Title = "Show Distance",
    Desc = "Show distance in the label",
    Icon = "ruler",
    Type = "Checkbox",
    Value = Settings.ShowDistance,
    Callback = function(value)
        Settings.ShowDistance = value
    end,
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
