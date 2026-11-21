-- GundamScript | RoChess Pro V3.6\n-- Added Opening Notifications + safe Cosmetics catalogue/preferences tab
-- WindUI + Lucide icons + Live information tab
-- For testing your own chess game

local WindUI = loadstring(game:HttpGet(
    "https://raw.githubusercontent.com/Footagesus/WindUI/refs/heads/main/dist/main.lua"
))()

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local VirtualUser = game:GetService("VirtualUser")
local HttpService = game:GetService("HttpService")

local Chess = ReplicatedStorage:WaitForChild("Chess")
local Client = ReplicatedStorage:WaitForChild("ChessClient")

local Engine = require(Chess:WaitForChild("Engine"))
local Bot = require(Chess:WaitForChild("Bot"))
local App = require(Client:WaitForChild("App"))

-- Used only as a fallback if the game's client move handler is unavailable.
local Remotes = Chess:WaitForChild("Remotes")
local Action = Remotes:WaitForChild("Action")
local function sendAction(payload)
    return pcall(function()
        Action:FireServer(payload)
    end)
end

--==================================================
-- WINDOW + TABS
--==================================================

local Window = WindUI:CreateWindow({
    Title = "GundamScript | RoChess Pro",
    Icon = "bot",
    Author = "GundamScript",
    Theme = "Dark",
    Folder = "GundamScript",
    Size = UDim2.fromOffset(600, 500),
    MinSize = Vector2.new(320, 360),
    Resizable = true,
    HideSearchBar = false,
    ToggleKey = Enum.KeyCode.RightShift,
})

-- Keep Live as the first/top tab.
local LiveTab = Window:Tab({
    Title = "Live",
    Icon = "radio",
})

local MainTab = Window:Tab({
    Title = "Game Helper",
    Icon = "house",
})

local VisualTab = Window:Tab({
    Title = "Visual",
    Icon = "eye",
})

local OpeningTab = Window:Tab({
    Title = "Opening Book",
    Icon = "book-open",
})

local CosmeticsTab = Window:Tab({
    Title = "Cosmetics",
    Icon = "palette",
})

local SettingsTab = Window:Tab({
    Title = "Settings",
    Icon = "settings",
})

--==================================================
-- SETTINGS
--==================================================

local AnalysisEnabled = true
local AutoPlayEnabled = false
local AutoQueueEnabled = false
local AntiAFKEnabled = false
local ShowTop3 = false
local AutoOpeningEnabled = true

local MoveDelay = 1.5
local OpeningMode = "Auto Random"
local SelectedOpeningName = "Alien Gambit"
local OpeningNotificationsEnabled = false
local LastNotifiedOpening = nil

local COSMETICS_SAVE_FILE = "rochess_cosmetics_preferences.json"
local CosmeticsModule = nil
local CosmeticsCatalogue = {}
local SelectedCosmeticName = nil
local CosmeticNameToId = {}
local CosmeticPreferences = {}

--==================================================
-- COSMETICS: READ-ONLY CATALOGUE + LOCAL PREFERENCES
-- Equipping remains inside the game's normal Shop/UI flow.
-- This module never grants ownership or changes server loadouts.
--==================================================

local function loadCosmeticsModule()
    local ok, result = pcall(function()
        return require(Chess:WaitForChild("Cosmetics"))
    end)

    if ok and type(result) == "table" then
        CosmeticsModule = result
    else
        CosmeticsModule = nil
        warn("[GundamScript] Cosmetics catalogue unavailable:", tostring(result))
    end
end

local function refreshCosmeticsCatalogue()
    CosmeticsCatalogue = {}
    CosmeticNameToId = {}

    if not CosmeticsModule or type(CosmeticsModule.ITEMS) ~= "table" then
        return CosmeticsCatalogue
    end

    for _, item in ipairs(CosmeticsModule.ITEMS) do
        if type(item) == "table" and item.id ~= nil then
            local id = tostring(item.id)
            local name = tostring(item.name or item.displayName or id)
            local kind = tostring(item.kind or item.type or "unknown")

            table.insert(CosmeticsCatalogue, {
                id = id,
                name = name,
                kind = kind,
            })
            CosmeticNameToId[name] = id
        end
    end

    table.sort(CosmeticsCatalogue, function(a, b)
        return string.lower(a.name) < string.lower(b.name)
    end)

    return CosmeticsCatalogue
end

local function loadCosmeticPreferences()
    if type(isfile) ~= "function" or type(readfile) ~= "function" then
        CosmeticPreferences = {}
        return false, "File reading is not supported by this executor."
    end

    local ok, result = pcall(function()
        if not isfile(COSMETICS_SAVE_FILE) then
            return {}
        end

        local raw = readfile(COSMETICS_SAVE_FILE)
        if type(raw) ~= "string" or raw == "" then
            return {}
        end

        local decoded = HttpService:JSONDecode(raw)
        return type(decoded) == "table" and decoded or {}
    end)

    if not ok then
        CosmeticPreferences = {}
        return false, tostring(result)
    end

    CosmeticPreferences = result
    return true
end

local function saveCosmeticPreferences()
    if type(writefile) ~= "function" then
        return false, "File writing is not supported by this executor."
    end

    local payload = {
        preferredCosmeticId = CosmeticPreferences.preferredCosmeticId,
        preferredCosmeticName = CosmeticPreferences.preferredCosmeticName,
        savedAt = os.time(),
    }

    local ok, err = pcall(function()
        writefile(COSMETICS_SAVE_FILE, HttpService:JSONEncode(payload))
    end)

    if not ok then
        return false, tostring(err)
    end

    CosmeticPreferences = payload
    return true
end

local function getLocalCosmeticState()
    local equipped = App.cos
    if equipped == nil and type(App.profile) == "table" then
        equipped = App.profile.cos
    end

    local theme = "Unavailable"
    if type(App.settings) == "table" and App.settings.theme ~= nil then
        theme = tostring(App.settings.theme)
    end

    local equippedText = "Unavailable"
    if type(equipped) == "table" then
        local ok, encoded = pcall(function()
            return HttpService:JSONEncode(equipped)
        end)
        equippedText = ok and encoded or "Cosmetic state is available"
    elseif equipped ~= nil then
        equippedText = tostring(equipped)
    end

    return equippedText, theme
end

loadCosmeticsModule()
refreshCosmeticsCatalogue()
loadCosmeticPreferences()

if type(CosmeticPreferences.preferredCosmeticName) == "string"
    and CosmeticNameToId[CosmeticPreferences.preferredCosmeticName] then
    SelectedCosmeticName = CosmeticPreferences.preferredCosmeticName
end

--==================================================
-- ARROW STATE
--==================================================

local LastMoves = {
    m1 = "",
    m2 = "",
    m3 = ""
}

local LastPositionKey = nil
local LastBoard = nil

local AnalysisToken = 0
local PreviousPositionKey = nil
local PreviousSession = nil
local AnalysisRunning = false
local PendingAnalysis = false

local Colors = {
    Rank1 = Color3.fromRGB(46, 204, 113),
    Rank2 = Color3.fromRGB(241, 196, 15),
    Rank3 = Color3.fromRGB(230, 126, 34)
}

--==================================================
-- OPENING BOOK
-- UCI format: e2e4, g1f3, e7e5, etc.
-- Lines assume a standard chess starting position.
--==================================================

local OpeningBook = {
    -- WHITE: ATTACKING OPENINGS

    {
        name = "Italian Game",
        side = "White",
        moves = {
            "e2e4", "e7e5", "g1f3", "b8c6", "f1c4",
            "f8c5", "c2c3", "g8f6"
        }
    },
    {
        name = "Ruy Lopez",
        side = "White",
        moves = {
            "e2e4", "e7e5", "g1f3", "b8c6", "f1b5",
            "a7a6", "b5a4", "g8f6"
        }
    },
    {
        name = "Scotch Game",
        side = "White",
        moves = {
            "e2e4", "e7e5", "g1f3", "b8c6",
            "d2d4", "e5d4", "f3d4"
        }
    },
    {
        name = "Vienna Game",
        side = "White",
        moves = {
            "e2e4", "e7e5", "b1c3", "g8f6",
            "f2f4"
        }
    },
    {
        name = "King's Gambit",
        side = "White",
        moves = {
            "e2e4", "e7e5", "f2f4", "e5f4",
            "g1f3"
        }
    },
    {
        name = "Danish Gambit",
        side = "White",
        moves = {
            "e2e4", "e7e5", "d2d4", "e5d4",
            "c2c3", "d4c3", "f1c4"
        }
    },
    {
        name = "Ponziani Opening",
        side = "White",
        moves = {
            "e2e4", "e7e5", "g1f3", "b8c6",
            "c2c3"
        }
    },
    {
        name = "Four Knights Game",
        side = "White",
        moves = {
            "e2e4", "e7e5", "g1f3", "b8c6",
            "b1c3", "g8f6"
        }
    },
    {
        name = "Queen's Gambit",
        side = "White",
        moves = {
            "d2d4", "d7d5", "c2c4", "e7e6",
            "b1c3"
        }
    },
    {
        name = "London System",
        side = "White",
        moves = {
            "d2d4", "d7d5", "c1f4", "g8f6",
            "e2e3"
        }
    },
    {
        name = "English Opening",
        side = "White",
        moves = {
            "c2c4", "e7e5", "b1c3", "g8f6",
            "g1f3"
        }
    },
    {
        name = "Réti Opening",
        side = "White",
        moves = {
            "g1f3", "d7d5", "c2c4", "e7e6",
            "g2g3"
        }
    },
    {
        name = "Bird Opening",
        side = "White",
        moves = {
            "f2f4", "d7d5", "g1f3", "g8f6",
            "e2e3"
        }
    },
    {
        name = "Trompowsky Attack",
        side = "White",
        moves = {
            "d2d4", "g8f6", "c1g5", "d7d5",
            "b1c3"
        }
    },
    {
        name = "King's Indian Attack",
        side = "White",
        moves = {
            "g1f3", "d7d5", "g2g3", "g8f6",
            "f1g2", "e7e6"
        }
    },

    -- BLACK: DEFENSE AGAINST 1.e4

    {
        name = "Sicilian Defense",
        side = "Black",
        moves = {
            "e2e4", "c7c5", "g1f3", "d7d6",
            "d2d4", "c5d4", "f3d4"
        }
    },
    {
        name = "French Defense",
        side = "Black",
        moves = {
            "e2e4", "e7e6", "d2d4", "d7d5",
            "b1c3", "g8f6"
        }
    },
    {
        name = "Caro-Kann Defense",
        side = "Black",
        moves = {
            "e2e4", "c7c6", "d2d4", "d7d5",
            "b1c3"
        }
    },
    {
        name = "Scandinavian Defense",
        side = "Black",
        moves = {
            "e2e4", "d7d5", "e4d5", "d8d5",
            "b1c3"
        }
    },
    {
        name = "Pirc Defense",
        side = "Black",
        moves = {
            "e2e4", "d7d6", "d2d4", "g8f6",
            "b1c3", "g7g6"
        }
    },
    {
        name = "Alien Gambit",
        side = "White",
        -- Caro-Kann: 1.e4 c6 2.d4 d5 3.Nc3 dxe4
        -- 4.Nxe4 Nf6 5.Ng5 h6 6.Nxf7 Kxf7 7.Nf3 c5
        moves = {
            "e2e4", "c7c6", "d2d4", "d7d5", "b1c3",
            "d5e4", "c3e4", "g8f6", "e4g5", "h7h6",
            "g5f7", "e8f7", "g1f3", "c7c5"
        }
    },
    {
        name = "Alekhine Defense",
        side = "Black",
        moves = {
            "e2e4", "g8f6", "e4e5", "f6d5",
            "d2d4"
        }
    },
    {
        name = "Modern Defense",
        side = "Black",
        moves = {
            "e2e4", "g7g6", "d2d4", "f8g7",
            "b1c3"
        }
    },
    {
        name = "Owen's Defense",
        side = "Black",
        moves = {
            "e2e4", "b7b6", "d2d4", "c8b7",
            "b1c3"
        }
    },
    {
        name = "Nimzowitsch Defense",
        side = "Black",
        moves = {
            "e2e4", "b8c6", "d2d4", "d7d5"
        }
    },
    {
        name = "Open Game",
        side = "Black",
        moves = {
            "e2e4", "e7e5", "g1f3", "b8c6",
            "b1c3", "g8f6"
        }
    },

    -- BLACK: DEFENSE AGAINST 1.d4

    {
        name = "King's Indian Defense",
        side = "Black",
        moves = {
            "d2d4", "g8f6", "c2c4", "g7g6",
            "b1c3", "f8g7"
        }
    },
    {
        name = "Grunfeld Defense",
        side = "Black",
        moves = {
            "d2d4", "g8f6", "c2c4", "g7g6",
            "b1c3", "d7d5"
        }
    },
    {
        name = "Nimzo-Indian Defense",
        side = "Black",
        moves = {
            "d2d4", "g8f6", "c2c4", "e7e6",
            "b1c3", "f8b4"
        }
    },
    {
        name = "Queen's Indian Defense",
        side = "Black",
        moves = {
            "d2d4", "g8f6", "c2c4", "e7e6",
            "g1f3", "b7b6"
        }
    },
    {
        name = "Slav Defense",
        side = "Black",
        moves = {
            "d2d4", "d7d5", "c2c4", "c7c6",
            "g1f3"
        }
    },
    {
        name = "Dutch Defense",
        side = "Black",
        moves = {
            "d2d4", "f7f5", "g2g3", "g8f6",
            "f1g2"
        }
    },
    {
        name = "Queen's Gambit Declined",
        side = "Black",
        moves = {
            "d2d4", "d7d5", "c2c4", "e7e6",
            "b1c3"
        }
    },
    {
        name = "Benoni Defense",
        side = "Black",
        moves = {
            "d2d4", "g8f6", "c2c4", "c7c5",
            "d4d5"
        }
    },
    {
        name = "Budapest Gambit",
        side = "Black",
        moves = {
            "d2d4", "g8f6", "c2c4", "e7e5"
        }
    },
    {
        name = "Albin Countergambit",
        side = "Black",
        moves = {
            "d2d4", "d7d5", "c2c4", "e7e5"
        }
    },
    {
        name = "Chigorin Defense",
        side = "Black",
        moves = {
            "d2d4", "d7d5", "c2c4", "b8c6"
        }
    },
}

--==================================================
-- OPENING BOOK STATE
--==================================================

local CurrentOpening = nil
local CurrentLine = nil

local function randomChoice(list)
    if not list or #list == 0 then
        return nil
    end

    return list[math.random(1, #list)]
end

local function samePrefix(history, line)
    if #history > #line then
        return false
    end

    for i, move in ipairs(history) do
        if move ~= line[i] then
            return false
        end
    end

    return true
end

local function clearCurrentOpening()
    CurrentOpening = nil
    CurrentLine = nil
end

local function getBookMove(session)
    if not AutoOpeningEnabled or OpeningMode == "Engine Only" then
        return nil
    end

    local history = session.ucis or {}

    -- Manual mode follows the exact opening selected in the dropdown.
    -- It only returns a move while the played history matches that line.
    if OpeningMode == "Manual" then
        for _, opening in ipairs(OpeningBook) do
            if opening.name == SelectedOpeningName then
                if samePrefix(history, opening.moves) then
                    local nextMove = opening.moves[#history + 1]
                    if nextMove then
                        CurrentOpening = opening.name
                        CurrentLine = opening.moves
                        return nextMove, opening.name
                    end
                end
                clearCurrentOpening()
                return nil, opening.name
            end
        end
        return nil
    end

    if OpeningMode ~= "Auto Random" then
        return nil
    end

    -- Assumes a standard chess game where White moves first.
    local side = (#history % 2 == 0) and "White" or "Black"

    -- Continue the currently selected opening if history matches.
    if CurrentLine and samePrefix(history, CurrentLine) then
        local nextMove = CurrentLine[#history + 1]
        if nextMove then
            return nextMove, CurrentOpening
        end
    end

    -- Position changed away from the current opening.
    clearCurrentOpening()

    -- Find all lines matching the actual move history.
    local candidates = {}
    for _, opening in ipairs(OpeningBook) do
        if opening.side == side
            and #opening.moves > #history
            and samePrefix(history, opening.moves) then
            table.insert(candidates, opening)
        end
    end

    local selected = randomChoice(candidates)
    if not selected then
        return nil
    end

    CurrentOpening = selected.name
    CurrentLine = selected.moves
    return CurrentLine[#history + 1], CurrentOpening
end

--==================================================
-- POSITION AND ARROW HELPERS
--==================================================

local function clearArrows(board)
    if not board then
        return
    end

    pcall(function()
        board:setArrow("sagg_1", nil)
        board:setArrow("sagg_2", nil)
        board:setArrow("sagg_3", nil)
    end)
end

local function resetArrows()
    clearArrows(LastBoard or App.board)

    LastMoves = {
        m1 = "",
        m2 = "",
        m3 = ""
    }

    LastPositionKey = nil
    LastBoard = nil
end

local function getPositionKey(session)
    local moves = session.ucis or {}

    return tostring(session.startFen)
        .. "|"
        .. table.concat(moves, ",")
end

local function updateMultiArrows(m1, m2, m3, positionKey)
    local board = App.board

    if not board then
        return
    end

    if LastBoard ~= board then
        clearArrows(LastBoard)
        LastBoard = board
        LastPositionKey = nil
    end

    if LastPositionKey == positionKey
        and LastMoves.m1 == m1
        and LastMoves.m2 == m2
        and LastMoves.m3 == m3 then
        return
    end

    local success = pcall(function()
        board:setArrow("sagg_1", nil)
        board:setArrow("sagg_2", nil)
        board:setArrow("sagg_3", nil)

        local function draw(key, uci, color, transparency)
            if type(uci) ~= "string" or #uci < 4 then
                return
            end

            local from = Engine.algToIndex64(uci:sub(1, 2))
            local to = Engine.algToIndex64(uci:sub(3, 4))

            if from and to then
                board:setArrow(
                    key,
                    from,
                    to,
                    color,
                    transparency
                )
            end
        end

        if AnalysisEnabled then
            draw("sagg_1", m1, Colors.Rank1, 0.15)

            if ShowTop3 then
                draw("sagg_2", m2, Colors.Rank2, 0.30)
                draw("sagg_3", m3, Colors.Rank3, 0.40)
            end
        end
    end)

    if success then
        LastMoves = {
            m1 = m1,
            m2 = m2,
            m3 = m3
        }

        LastPositionKey = positionKey
    end
end

--==================================================
-- ANALYSIS + OPENING BOOK
--==================================================

local function getRankedMoves(session)
    -- Build the current position and legal moves first. This lets the opening
    -- book work even if the engine analysis is slow or unavailable in-game.
    local engine = Engine.new(session.startFen)
    for _, uci in ipairs(session.ucis or {}) do
        engine:playUci(uci)
    end

    local legalMoves = {}
    local legalSet = {}
    for _, move in ipairs(engine:legalMoves()) do
        local uci = engine:moveToUci(move)
        if uci then
            table.insert(legalMoves, uci)
            legalSet[uci] = true
        end
    end

    local bookMove, openingName = getBookMove(session)
    local bestMove = ""
    local activeOpeningName = nil

    if bookMove and legalSet[bookMove] then
        bestMove = bookMove
        activeOpeningName = openingName
    else
        if bookMove then
            clearCurrentOpening()
        end

        local result = Bot.analyse(
            session.startFen,
            session.ucis,
            0.5,
            14
        )
        bestMove = result and result.best or ""
    end

    -- Alternatives are legal moves, not guaranteed engine-ranked #2/#3.
    local alternatives = {}
    for _, uci in ipairs(legalMoves) do
        if uci ~= bestMove then
            table.insert(alternatives, uci)
        end
        if #alternatives >= 2 then
            break
        end
    end

    return bestMove,
        alternatives[1] or "",
        alternatives[2] or "",
        activeOpeningName
end

--==================================================
-- LIVE TAB
--==================================================

local Players = game:GetService("Players")
local MarketplaceService = game:GetService("MarketplaceService")
local LocalPlayer = Players.LocalPlayer

local function getGameName()
    local ok, info = pcall(function()
        return MarketplaceService:GetProductInfo(game.PlaceId)
    end)

    if ok and info and info.Name then
        return info.Name
    end

    return "Tidak dapat dibaca"
end

local function getLiveInfo()
    local playerCount = #Players:GetPlayers()
    local maxPlayers = "?"
    pcall(function()
        maxPlayers = tostring(Players.MaxPlayers)
    end)

    return {
        Name = LocalPlayer and LocalPlayer.Name or "Unavailable",
        AccountAge = LocalPlayer and tostring(LocalPlayer.AccountAge) .. " days" or "Unavailable",
        GameName = getGameName(),
        ServerPlayers = tostring(playerCount) .. " / " .. maxPlayers,
        Origin = "Unavailable from the Roblox client",
        ScriptUsers = "Not available — requires a separate counting service",
    }
end

local function showLiveInfo()
    local info = getLiveInfo()
    WindUI:Notify({
        Title = "GundamScript | Live Information",
        Content = "Player: " .. info.Name
            .. "\nAccount age: " .. info.AccountAge
            .. "\nGame: " .. info.GameName
            .. "\nPlayer server: " .. info.ServerPlayers
            .. "\nPlayer origin: " .. info.Origin
            .. "\nGundamScript users: " .. info.ScriptUsers,
        Duration = 8,
    })
end

LiveTab:Section({
    Title = "Live Information",
    Icon = "activity",
})

LiveTab:Paragraph({
    Title = "Player Name",
    Desc = LocalPlayer and LocalPlayer.Name or "Unavailable",
})

LiveTab:Paragraph({
    Title = "Account Age",
    Desc = LocalPlayer and (tostring(LocalPlayer.AccountAge) .. " days") or "Unavailable",
})

LiveTab:Paragraph({
    Title = "Current Game",
    Desc = getGameName(),
})

LiveTab:Paragraph({
    Title = "Players in Server",
    Desc = tostring(#Players:GetPlayers()) .. " players currently in this server. Press Refresh to update.",
})

LiveTab:Paragraph({
    Title = "Player Origin",
    Desc = "Unavailable from the Roblox client. GundamScript does not collect private location data.",
})

LiveTab:Paragraph({
    Title = "GundamScript Users",
    Desc = "Not available. An accurate count requires a separate, transparent counting service.",
})

LiveTab:Button({
    Title = "Refresh Information",
    Icon = "refresh-cw",
    Callback = function()
        showLiveInfo()
    end,
})

--==================================================
-- MAIN TAB
--==================================================

MainTab:Section({
    Title = "Analysis",
    Icon = "brain",
})

MainTab:Toggle({
    Title = "Enable Visual Analysis",
    Value = true,
    Callback = function(value)
        AnalysisEnabled = value

        if not value then
            AnalysisToken += 1
            PendingAnalysis = false
            resetArrows()
        else
            PreviousPositionKey = nil
            PendingAnalysis = true
        end
    end,
})

MainTab:Toggle({
    Title = "Automatic Opening Book",
    Value = true,
    Callback = function(value)
        AutoOpeningEnabled = value
        clearCurrentOpening()
        PreviousPositionKey = nil
        PendingAnalysis = true
    end,
})

MainTab:Toggle({
    Title = "Auto Play Best Move",
    Desc = "Automatically plays the best available move on your turn. Use only in your own test environment.",
    Value = false,
    Callback = function(value)
        AutoPlayEnabled = value
        WindUI:Notify({
            Title = value and "Auto Play Enabled" or "Auto Play Disabled",
            Content = value and "Best-move automation is enabled." or "Automation has stopped.",
            Duration = 3,
        })
    end,
})

MainTab:Slider({
    Title = "Auto Play Delay (seconds)",
    Desc = "Wait time before attempting a move.",
    Value = { Min = 0.3, Max = 3, Default = MoveDelay },
    Step = 0.1,
    Callback = function(value)
        MoveDelay = math.clamp(tonumber(value) or 1.5, 0.3, 3)
    end,
})

MainTab:Section({
    Title = "Convenience",
    Icon = "settings-2",
})

MainTab:Toggle({
    Title = "Auto Queue (3+2)",
    Desc = "Automatically queue a 3+2 match when no game is active or the current game ends.",
    Value = false,
    Callback = function(value)
        AutoQueueEnabled = value
        WindUI:Notify({
            Title = value and "Auto Queue Enabled" or "Auto Queue Disabled",
            Content = value and "Will queue when no match is active." or "Automatic matchmaking stopped.",
            Duration = 3,
        })
    end,
})

MainTab:Button({
    Title = "Queue 3+2 Match Now",
    Desc = "Send a queue request to the game.",
    Callback = function()
        local ok, err = sendAction({ type = "queue", tc = "3+2" })
        WindUI:Notify({
            Title = ok and "Queue Request Sent" or "Queue Request Failed",
            Content = ok and "The game received the request." or tostring(err),
            Duration = 3,
        })
    end,
})

MainTab:Toggle({
    Title = "Anti-AFK",
    Desc = "Attempts to keep the local session active while enabled.",
    Value = false,
    Callback = function(value)
        AntiAFKEnabled = value
        WindUI:Notify({
            Title = value and "Anti-AFK Enabled" or "Anti-AFK Disabled",
            Content = value and "Idle activity handling is enabled." or "Idle activity handling is disabled.",
            Duration = 3,
        })
    end,
})

--==================================================
-- OPENING BOOK TAB
--==================================================

OpeningTab:Section({
    Title = "Opening Mode",
    Icon = "book-open",
})

OpeningTab:Dropdown({
    Title = "Mode",
    Values = {
        "Auto Random",
        "Manual",
        "Engine Only",
    },
    Value = "Auto Random",
    Callback = function(option)
        if type(option) == "table" then
            OpeningMode = option[1] or "Auto Random"
        else
            OpeningMode = option or "Auto Random"
        end

        clearCurrentOpening()
        PreviousPositionKey = nil
        PendingAnalysis = true
    end,
})

-- Alphabetical manual opening selector.
local OpeningNames = {}
for _, opening in ipairs(OpeningBook) do
    table.insert(OpeningNames, opening.name)
end
table.sort(OpeningNames, function(a, b)
    return string.lower(a) < string.lower(b)
end)

OpeningTab:Dropdown({
    Title = "Manual Opening (A-Z)",
    Desc = "Choose an opening, then select Manual mode above.",
    Values = OpeningNames,
    Value = SelectedOpeningName,
    Callback = function(option)
        if type(option) == "table" then
            SelectedOpeningName = option[1] or SelectedOpeningName
        elseif type(option) == "string" then
            SelectedOpeningName = option
        end

        clearCurrentOpening()
        PreviousPositionKey = nil
        PendingAnalysis = true

        WindUI:Notify({
            Title = "Manual Opening",
            Content = "Selected: " .. SelectedOpeningName,
            Duration = 3,
        })
    end,
})

OpeningTab:Paragraph({
    Title = "Manual Book Info",
    Desc = "Manual mode follows the selected line only while the game's move history matches it. If the opponent plays a different move, the book pauses and engine analysis takes over.",
})

OpeningTab:Button({
    Title = "Enable Opening Notifications",
    Icon = "bell",
    Desc = "Toggle a notification when the Opening Book starts using an opening.",
    Callback = function()
        OpeningNotificationsEnabled = not OpeningNotificationsEnabled
        if not OpeningNotificationsEnabled then
            LastNotifiedOpening = nil
        end

        WindUI:Notify({
            Title = "Opening Notifications",
            Content = OpeningNotificationsEnabled
                and "Opening notifications are enabled."
                or "Opening notifications are disabled.",
            Duration = 3,
        })
    end,
})

OpeningTab:Button({
    Title = "Reset Opening",
    Icon = "rotate-ccw",
    Callback = function()
        clearCurrentOpening()
        PreviousPositionKey = nil
        PendingAnalysis = true

        WindUI:Notify({
            Title = "Opening Book",
            Content = "Opening selection has been reset.",
            Duration = 3,
        })
    end,
})

OpeningTab:Button({
    Title = "View Active Opening",
    Icon = "search",
    Callback = function()
        WindUI:Notify({
            Title = "Active Opening",
            Content = CurrentOpening or "No matching opening found yet.",
            Duration = 4,
        })
    end,
})

--==================================================
-- VISUAL TAB
--==================================================

VisualTab:Section({
    Title = "Arrow Settings",
    Icon = "palette",
})

VisualTab:Paragraph({
    Title = "Alternative Arrows — Locked",
    Desc = "Rank 2 and Rank 3 alternative arrows are temporarily locked and will be available in a future update. Only the best-move arrow is active.",
})

VisualTab:Button({
    Title = "GREEN: Best Move",
    Icon = "arrow-up-right",
    Callback = function()
        WindUI:Notify({
            Title = "Rank 1",
            Content = "Best move from the opening book or chess engine.",
            Duration = 3,
        })
    end,
})

VisualTab:Button({
    Title = "YELLOW: Alternative 1 (Locked)",
    Icon = "lock",
    Callback = function()
        WindUI:Notify({
            Title = "Coming Soon",
            Content = "Alternative arrows are temporarily locked.",
            Duration = 3,
        })
    end,
})

VisualTab:Button({
    Title = "ORANGE: Alternative 2 (Locked)",
    Icon = "lock",
    Callback = function()
        WindUI:Notify({
            Title = "Coming Soon",
            Content = "Alternative arrows are temporarily locked.",
            Duration = 3,
        })
    end,
})

--==================================================
-- COSMETICS TAB
--==================================================

CosmeticsTab:Section({
    Title = "Cosmetics Catalogue",
    Icon = "palette",
})

local CosmeticNames = {}
for _, item in ipairs(CosmeticsCatalogue) do
    table.insert(CosmeticNames, item.name)
end

if #CosmeticNames == 0 then
    CosmeticNames = { "Catalogue unavailable" }
end

CosmeticsTab:Paragraph({
    Title = "Catalogue Status",
    Desc = #CosmeticsCatalogue > 0
        and (tostring(#CosmeticsCatalogue) .. " cosmetics found in the game's catalogue.")
        or "The game's cosmetics catalogue could not be read.",
})

CosmeticsTab:Dropdown({
    Title = "Preferred Cosmetic",
    Desc = "Select a cosmetic to remember locally. This does not equip or unlock it.",
    Values = CosmeticNames,
    Value = SelectedCosmeticName or CosmeticNames[1],
    Callback = function(option)
        local chosen = type(option) == "table" and option[1] or option
        if type(chosen) == "string" and CosmeticNameToId[chosen] then
            SelectedCosmeticName = chosen
            CosmeticPreferences.preferredCosmeticId = CosmeticNameToId[chosen]
            CosmeticPreferences.preferredCosmeticName = chosen
            WindUI:Notify({
                Title = "Cosmetic Preference",
                Content = "Selected locally: " .. chosen,
                Duration = 3,
            })
        end
    end,
})

CosmeticsTab:Button({
    Title = "Save Cosmetic Preference",
    Icon = "save",
    Desc = "Save the selected cosmetic ID to a local JSON file.",
    Callback = function()
        local ok, err = saveCosmeticPreferences()
        WindUI:Notify({
            Title = ok and "Preference Saved" or "Save Failed",
            Content = ok
                and ("Saved to " .. COSMETICS_SAVE_FILE)
                or tostring(err),
            Duration = 4,
        })
    end,
})

CosmeticsTab:Button({
    Title = "Reload Cosmetic Catalogue",
    Icon = "refresh-cw",
    Callback = function()
        loadCosmeticsModule()
        refreshCosmeticsCatalogue()
        WindUI:Notify({
            Title = "Cosmetics Catalogue",
            Content = "Catalogue refreshed: " .. tostring(#CosmeticsCatalogue) .. " entries.",
            Duration = 3,
        })
    end,
})

CosmeticsTab:Button({
    Title = "View Local Cosmetic State",
    Icon = "scan-eye",
    Callback = function()
        local equipped, theme = getLocalCosmeticState()
        WindUI:Notify({
            Title = "Local Cosmetic State",
            Content = "Equipped data: " .. equipped .. "\\nBoard theme: " .. theme,
            Duration = 6,
        })
    end,
})

CosmeticsTab:Paragraph({
    Title = "Ownership & Equip Notice",
    Desc = "This tab only reads the game's catalogue and saves your local preference. To equip a cosmetic, use the game's normal Shop interface. It does not unlock paid items, spoof ownership, or modify server loadouts.",
})

--==================================================
-- SETTINGS TAB
--==================================================

SettingsTab:Section({
    Title = "General Settings",
    Icon = "sliders-horizontal",
})

SettingsTab:Paragraph({
    Title = "About",
    Desc = "GundamScript RoChess Pro — WindUI interface with Lucide icons.",
})

--==================================================
-- ANTI-AFK
--==================================================

if LocalPlayer then
    LocalPlayer.Idled:Connect(function()
        if not AntiAFKEnabled then
            return
        end

        pcall(function()
            VirtualUser:CaptureController()
            VirtualUser:ClickButton2(Vector2.new(0, 0))
        end)
    end)
end

task.spawn(function()
    while task.wait(300) do
        if AntiAFKEnabled then
            pcall(function()
                VirtualUser:CaptureController()
                VirtualUser:ClickButton2(Vector2.new(0, 0))
            end)
        end
    end
end)

--==================================================
-- AUTO QUEUE (3+2)
--==================================================

local QueueBusy = false
local function requestQueue()
    local ok, err = sendAction({
        type = "queue",
        tc = "3+2",
    })
    if not ok then
        warn("[GundamScript] Auto Queue failed:", tostring(err))
    end
    return ok
end

task.spawn(function()
    task.wait(2)
    while task.wait(1.5) do
        if not AutoQueueEnabled or QueueBusy then
            continue
        end

        local session = App.session
        if session and not session.over then
            continue
        end

        QueueBusy = true
        task.spawn(function()
            -- Small cooldown prevents repeated queue requests if the server
            -- has not updated App.session yet.
            task.wait(2.5)
            if AutoQueueEnabled then
                requestQueue()
            end
            task.wait(5)
            QueueBusy = false
        end)
    end
end)

--==================================================
-- AUTO PLAY WORKER
-- Uses the same best-move logic as the supplied RoChess bot,
-- while preferring a valid move from the active Opening Book.
--==================================================

local AutoPlayBusy = false

local function isAutoPlayTurn(session)
    if not session or session.over then
        return false
    end

    -- Prefer the game's own turn helper when available.
    local ok, result = pcall(function()
        return session:isMyTurn()
    end)
    if ok then
        return result == true
    end

    return session.myColor ~= nil
        and session.engine ~= nil
        and session.engine.side == session.myColor
        and session.viewPly == #(session.ucis or {})
end

local function getAutoPlayMove(session)
    -- Opening Book first, so manual selections (including Alien Gambit)
    -- remain effective while the current move matches the selected line.
    local bookMove = getBookMove(session)
    if type(bookMove) == "string" and #bookMove >= 4 then
        local legalOk, legal = pcall(function()
            local engine = Engine.new(session.startFen)
            for _, played in ipairs(session.ucis or {}) do
                engine:playUci(played)
            end
            for _, move in ipairs(engine:legalMoves()) do
                if engine:moveToUci(move) == bookMove then
                    return true
                end
            end
            return false
        end)
        if legalOk and legal then
            return bookMove
        end
    end

    -- Engine logic from the provided RoChess bot.
    local ok, uci = pcall(function()
        return Bot.think(
            session.startFen,
            table.clone(session.ucis or {}),
            { rating = 3000, depth = 20, noise = 0, blunder = 0 }
        )
    end)

    if ok and type(uci) == "string" and uci ~= "" then
        return uci
    end

    -- If Bot.think is not supported by this game version, use the existing
    -- analysis helper as a compatibility fallback.
    local fallbackOk, best = pcall(function()
        local m1 = getRankedMoves(session)
        return m1
    end)
    if fallbackOk and type(best) == "string" and best ~= "" then
        return best
    end

    return nil
end

local function attemptAutoMove(session, uci)
    if type(uci) ~= "string" or #uci < 4 then
        return false
    end

    local from64 = Engine.algToIndex64(uci:sub(1, 2))
    local to64 = Engine.algToIndex64(uci:sub(3, 4))
    local promo = ({ q = 5, r = 4, b = 3, n = 2 })[uci:sub(5, 5):lower()] or 0

    if not from64 or not to64 then
        return false
    end

    -- First try the game's normal client-side board handler.
    local clientOk = pcall(function()
        App.onBoardMove(from64, to64, promo, false)
    end)
    if clientOk then
        return true
    end

    -- Remote fallback mirrors the supplied script's online move path.
    if session.kind == "online" and not session.over then
        local remoteOk = sendAction({
            type = "move",
            id = session.id,
            uci = uci,
            ply = #(session.ucis or {}),
        })
        return remoteOk
    end

    return false
end

task.spawn(function()
    while task.wait(0.25) do
        if not AutoPlayEnabled or AutoPlayBusy then
            continue
        end

        local session = App.session
        if not isAutoPlayTurn(session) then
            continue
        end
        if session.kind ~= "online" and session.kind ~= "bot" then
            continue
        end

        AutoPlayBusy = true
        local startSession = session
        local startKeyOk, startKey = pcall(getPositionKey, session)

        task.spawn(function()
            local ok, err = pcall(function()
                task.wait(MoveDelay)

                if not AutoPlayEnabled
                    or App.session ~= startSession
                    or startSession.over
                    or not isAutoPlayTurn(startSession) then
                    return
                end

                local currentKeyOk, currentKey = pcall(getPositionKey, startSession)
                if not startKeyOk or not currentKeyOk or currentKey ~= startKey then
                    return
                end

                local uci = getAutoPlayMove(startSession)
                if not uci then
                    return
                end

                -- Recheck immediately before sending the move.
                local verifyOk, verifyKey = pcall(getPositionKey, startSession)
                if AutoPlayEnabled
                    and App.session == startSession
                    and not startSession.over
                    and isAutoPlayTurn(startSession)
                    and verifyOk
                    and verifyKey == startKey then
                    attemptAutoMove(startSession, uci)
                end
            end)

            if not ok then
                warn("[GundamScript] Auto Play failed:", tostring(err))
            end
            AutoPlayBusy = false
        end)
    end
end)

--==================================================
-- MAIN ANALYSIS LOOP
--==================================================

task.spawn(function()
    while task.wait(0.25) do
        local session = App.session

        if not session or session.over then
            AnalysisToken += 1
            PreviousSession = nil
            PreviousPositionKey = nil
            PendingAnalysis = false
            AnalysisRunning = false

            clearCurrentOpening()
            resetArrows()
            continue
        end

        -- Detect a new game/session.
        if session ~= PreviousSession then
            AnalysisToken += 1
            PreviousSession = session
            PreviousPositionKey = nil
            PendingAnalysis = true

            clearCurrentOpening()
            resetArrows()
        end

        local keyOk, positionKey = pcall(
            getPositionKey,
            session
        )

        if not keyOk then
            continue
        end

        -- Detect every board position change.
        if positionKey ~= PreviousPositionKey then
            PreviousPositionKey = positionKey
            AnalysisToken += 1
            PendingAnalysis = true
            resetArrows()
        end

        if not AnalysisEnabled then
            continue
        end

        if not PendingAnalysis
            or AnalysisRunning
            or not session:isMyTurn() then
            continue
        end

        PendingAnalysis = false
        AnalysisRunning = true

        local token = AnalysisToken
        local analyzedPosition = positionKey

        task.spawn(function()
            local success, m1, m2, m3, openingName = pcall(
                getRankedMoves,
                session
            )

            AnalysisRunning = false

            -- Ignore results from an old position or session.
            if token ~= AnalysisToken
                or App.session ~= session
                or session.over
                or not AnalysisEnabled then
                return
            end

            local currentOk, currentKey = pcall(
                getPositionKey,
                session
            )

            if not currentOk
                or currentKey ~= analyzedPosition then

                PendingAnalysis = true
                return
            end

            if success and m1 and m1 ~= "" then
                updateMultiArrows(
                    m1,
                    m2 or "",
                    m3 or "",
                    analyzedPosition
                )

                if openingName then
                    if OpeningNotificationsEnabled
                        and LastNotifiedOpening ~= openingName then
                        LastNotifiedOpening = openingName
                        WindUI:Notify({
                            Title = "Opening Book Used",
                            Content = "The opening is now active: " .. tostring(openingName),
                            Duration = 5,
                        })
                    end
                else
                    LastNotifiedOpening = nil
                end

            elseif not success then
                warn("[GundamScript] Analysis failed:", m1)
            end
        end)
    end
end)
