-- GundamScript | RoChess Pro V4.0
-- WindUI + Lucide icons + Live information tab
-- Stockfish.online engine + Enhanced Opening Book Detection
-- For testing your own chess game

local WindUI = loadstring(game:HttpGet(
    "https://raw.githubusercontent.com/Footagesus/WindUI/refs/heads/main/dist/main.lua"
))()

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local VirtualUser = game:GetService("VirtualUser")

local Chess = ReplicatedStorage:WaitForChild("Chess")
local Client = ReplicatedStorage:WaitForChild("ChessClient")

local Engine = require(Chess:WaitForChild("Engine"))
local Bot = require(Chess:WaitForChild("Bot"))
local App = require(Client:WaitForChild("App"))

--==================================================
-- STOCKFISH.ONLINE ENGINE
-- Primary engine: stockfish.online REST API
-- Fallback: in-game Bot module
--==================================================

local HttpService = game:GetService("HttpService")

-- Build FEN from session for Stockfish.online
local function buildFenFromSession(session)
    -- Use startFen and apply moves via engine to get current FEN
    local ok, fen = pcall(function()
        local eng = Engine.new(session.startFen)
        for _, uci in ipairs(session.ucis or {}) do
            eng:playUci(uci)
        end
        -- Try to get FEN from engine if method available
        if eng.toFen then
            return eng:toFen()
        elseif eng.getFen then
            return eng:getFen()
        elseif eng.fen then
            return eng.fen
        end
        return nil
    end)
    if ok and fen and type(fen) == "string" and #fen > 10 then
        return fen
    end
    -- fallback: startFen (position may be inaccurate if moves were played)
    return session.startFen or "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1"
end

-- Convert UCI move list to space-separated string
local function ucisToString(ucis)
    if not ucis or #ucis == 0 then
        return ""
    end
    return table.concat(ucis, " ")
end

-- Query stockfish.online for best move
-- API: https://stockfish.online/api/s/v2.php?fen=<FEN>&depth=<depth>
-- Returns JSON: { success, bestmove, ... }
local StockfishCache = {}
local StockfishCacheKey = nil

local function queryStockfishOnline(session, depth)
    -- Respect Settings toggle
    if _G.GS_PreferOnline == false then
        return nil
    end
    depth = depth or 15

    local fen = buildFenFromSession(session)
    local cacheKey = fen .. "|" .. tostring(depth)

    if StockfishCacheKey == cacheKey and StockfishCache[cacheKey] then
        return StockfishCache[cacheKey]
    end

    -- URL encode FEN (spaces → %20)
    local encodedFen = fen:gsub(" ", "%%20"):gsub("/", "%%2F")
    local url = "https://stockfish.online/api/s/v2.php?fen=" .. encodedFen .. "&depth=" .. tostring(depth)

    local ok, response = pcall(function()
        return game:HttpGet(url, true)
    end)

    if not ok or not response then
        warn("[GundamScript] Stockfish.online request failed:", tostring(response))
        return nil
    end

    local parseOk, data = pcall(function()
        return HttpService:JSONDecode(response)
    end)

    if not parseOk or not data then
        warn("[GundamScript] Stockfish.online JSON parse failed:", tostring(data))
        return nil
    end

    if not data.success then
        warn("[GundamScript] Stockfish.online returned error:", tostring(data.error or "unknown"))
        return nil
    end

    -- bestmove format: "bestmove e2e4 ponder e7e5" or just "e2e4"
    local bestmove = data.bestmove or ""
    local uci = bestmove:match("bestmove%s+(%S+)") or bestmove:match("^(%S+)")

    if not uci or uci == "(none)" or #uci < 4 then
        return nil
    end

    -- Cache result
    StockfishCache = {}
    StockfishCache[cacheKey] = uci
    StockfishCacheKey = cacheKey

    return uci
end

-- Stockfish.online with fallback to in-game Bot
local function getStockfishMove(session, depth)
    -- Try online first
    local onlineMove = queryStockfishOnline(session, depth or 15)
    if onlineMove then
        return onlineMove, "stockfish.online"
    end

    -- Fallback: Bot.think
    local ok1, uci1 = pcall(function()
        return Bot.think(
            session.startFen,
            table.clone(session.ucis or {}),
            { rating = 3000, depth = 20, noise = 0, blunder = 0 }
        )
    end)
    if ok1 and type(uci1) == "string" and uci1 ~= "" then
        return uci1, "bot.think"
    end

    -- Fallback: Bot.analyse
    local ok2, result2 = pcall(function()
        return Bot.analyse(session.startFen, session.ucis, 0.5, 14)
    end)
    if ok2 and result2 and result2.best and result2.best ~= "" then
        return result2.best, "bot.analyse"
    end

    return nil, nil
end

-- Engine source label for Live Tab display
local LastEngineSource = "none"

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
-- OPENING BOOK DETECT STATE (ENHANCED)
--==================================================

local BookStatus = {
    active      = false,       -- currently in a known opening
    name        = "—",         -- opening name
    movesDone   = 0,           -- how many book moves played so far
    movesTotal  = 0,           -- total moves in the selected line
    nextMove    = "—",         -- next book move UCI
    deviated    = false,       -- opponent deviated from book line
    deviatedAt  = 0,           -- move index where deviation happened
    engineUsed  = "none",      -- "stockfish.online" / "bot.think" / "bot.analyse"
}

-- Live paragraph handles (set after UI creation, updated dynamically)
local LiveBookNamePara   = nil
local LiveBookProgressPara = nil
local LiveBookNextPara   = nil
local LiveBookStatusPara = nil
local LiveEngineSourcePara = nil

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

    -- Reset BookStatus
    BookStatus.active      = false
    BookStatus.name        = "—"
    BookStatus.movesDone   = 0
    BookStatus.movesTotal  = 0
    BookStatus.nextMove    = "—"
    BookStatus.deviated    = false
    BookStatus.deviatedAt  = 0
end

-- Update BookStatus and refresh Live Tab paragraphs if bound
local function updateBookStatus(opening, line, history, nextMove, deviated, deviatedAt)
    BookStatus.active     = (opening ~= nil)
    BookStatus.name       = opening or "—"
    BookStatus.movesDone  = #history
    BookStatus.movesTotal = line and #line or 0
    BookStatus.nextMove   = nextMove or "—"
    BookStatus.deviated   = deviated or false
    BookStatus.deviatedAt = deviatedAt or 0

    -- Refresh Live Tab UI if available
    if LiveBookNamePara then
        pcall(function()
            LiveBookNamePara:Set(BookStatus.name)
        end)
    end
    if LiveBookProgressPara then
        local prog = BookStatus.active
            and (tostring(BookStatus.movesDone) .. " / " .. tostring(BookStatus.movesTotal) .. " moves")
            or "Not in book"
        pcall(function()
            LiveBookProgressPara:Set(prog)
        end)
    end
    if LiveBookNextPara then
        pcall(function()
            LiveBookNextPara:Set(BookStatus.nextMove)
        end)
    end
    if LiveBookStatusPara then
        local statusText
        if BookStatus.deviated then
            statusText = "⚠ Deviation at move " .. tostring(BookStatus.deviatedAt) .. " — engine takes over"
        elseif BookStatus.active then
            statusText = "✓ Following book line"
        else
            statusText = "Engine mode (no book match)"
        end
        pcall(function()
            LiveBookStatusPara:Set(statusText)
        end)
    end
    if LiveEngineSourcePara then
        pcall(function()
            LiveEngineSourcePara:Set(BookStatus.engineUsed)
        end)
    end
end

-- ENHANCED: detect which moves of the history match ANY known opening,
-- report deviations, and update BookStatus in real time.
local function detectOpeningFromHistory(history)
    if not history or #history == 0 then
        return nil, nil, false, 0
    end

    -- Find the deepest opening whose full prefix matches history
    local bestMatch = nil
    local bestDepth = 0

    for _, opening in ipairs(OpeningBook) do
        local matchDepth = 0
        for i, move in ipairs(opening.moves) do
            if history[i] == move then
                matchDepth = i
            else
                break
            end
        end
        if matchDepth > bestDepth then
            bestDepth = matchDepth
            bestMatch = opening
        end
    end

    if not bestMatch or bestDepth == 0 then
        return nil, nil, false, 0
    end

    -- Check if history deviated from the matched opening at any point
    local deviated = false
    local deviatedAt = 0
    for i = 1, math.min(#history, #bestMatch.moves) do
        if history[i] ~= bestMatch.moves[i] then
            deviated = true
            deviatedAt = i
            break
        end
    end

    return bestMatch, bestDepth, deviated, deviatedAt
end

local function getBookMove(session)
    if not AutoOpeningEnabled or OpeningMode == "Engine Only" then
        updateBookStatus(nil, nil, session.ucis or {}, nil, false, 0)
        return nil
    end

    local history = session.ucis or {}

    -- Manual mode: exact match for selected opening name only
    if OpeningMode == "Manual" then
        for _, opening in ipairs(OpeningBook) do
            if opening.name == SelectedOpeningName then
                if samePrefix(history, opening.moves) then
                    local nextMove = opening.moves[#history + 1]
                    if nextMove then
                        CurrentOpening = opening.name
                        CurrentLine = opening.moves
                        updateBookStatus(opening.name, opening.moves, history, nextMove, false, 0)
                        return nextMove, opening.name
                    end
                    -- History is longer than opening line — opening exhausted
                    updateBookStatus(opening.name, opening.moves, history, nil, false, 0)
                    clearCurrentOpening()
                    return nil, opening.name
                end

                -- History deviated from manual selection
                local devIdx = 0
                for i = 1, math.min(#history, #opening.moves) do
                    if history[i] ~= opening.moves[i] then
                        devIdx = i
                        break
                    end
                end
                updateBookStatus(opening.name, opening.moves, history, nil, true, devIdx)
                clearCurrentOpening()
                return nil, opening.name
            end
        end
        return nil
    end

    if OpeningMode ~= "Auto Random" then
        return nil
    end

    local side = (#history % 2 == 0) and "White" or "Black"

    -- Continue current opening line if still on track
    if CurrentLine and CurrentOpening then
        if samePrefix(history, CurrentLine) then
            local nextMove = CurrentLine[#history + 1]
            if nextMove then
                updateBookStatus(CurrentOpening, CurrentLine, history, nextMove, false, 0)
                return nextMove, CurrentOpening
            else
                -- Line exhausted but no deviation
                updateBookStatus(CurrentOpening, CurrentLine, history, nil, false, 0)
                clearCurrentOpening()
                return nil, CurrentOpening
            end
        else
            -- Detect at which move deviation happened
            local devIdx = 0
            for i = 1, math.min(#history, #CurrentLine) do
                if history[i] ~= CurrentLine[i] then
                    devIdx = i
                    break
                end
            end
            updateBookStatus(CurrentOpening, CurrentLine, history, nil, true, devIdx)
            clearCurrentOpening()
        end
    end

    -- Auto detect: try to find which opening matches history best
    -- even if no line is currently selected (re-entry detection)
    local detected, _, deviated, deviatedAt = detectOpeningFromHistory(history)
    if detected and not deviated then
        -- We're still inside a known opening
        local nextMove = detected.moves[#history + 1]
        if nextMove and detected.side == side then
            CurrentOpening = detected.name
            CurrentLine = detected.moves
            updateBookStatus(detected.name, detected.moves, history, nextMove, false, 0)
            return nextMove, detected.name
        end
    end

    -- Find all lines still matching the actual move history
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
        -- No candidates — check if we just finished a line or deviated
        if detected then
            updateBookStatus(detected.name, detected.moves, history, nil, deviated, deviatedAt)
        else
            updateBookStatus(nil, nil, history, nil, false, 0)
        end
        return nil
    end

    CurrentOpening = selected.name
    CurrentLine = selected.moves
    local nextMove = CurrentLine[#history + 1]
    updateBookStatus(selected.name, selected.moves, history, nextMove, false, 0)
    return nextMove, CurrentOpening
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
    -- Build legal move set from in-game engine
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

    -- Try opening book first
    local bookMove, openingName = getBookMove(session)
    local bestMove = ""
    local engineSource = "none"

    if bookMove and legalSet[bookMove] then
        -- Book move is valid and legal
        bestMove = bookMove
        engineSource = "opening.book"
        BookStatus.engineUsed = engineSource
    else
        if bookMove then
            -- Book suggested a move but it's not legal — deviated
            clearCurrentOpening()
        end

        -- PRIMARY: stockfish.online
        local sfMove, sfSource = getStockfishMove(session, 15)
        if sfMove and legalSet[sfMove] then
            bestMove = sfMove
            engineSource = sfSource or "stockfish.online"
        elseif sfMove then
            -- Stockfish returned an illegal move (edge case) — use as-is, game validates
            bestMove = sfMove
            engineSource = (sfSource or "stockfish.online") .. " (unverified)"
        else
            -- All fallbacks exhausted — pick first legal move
            bestMove = legalMoves[1] or ""
            engineSource = "legal.fallback"
        end

        BookStatus.engineUsed = engineSource
        LastEngineSource = engineSource
    end

    -- Rank alternatives: stockfish.online at lower depth for m2/m3 if ShowTop3
    local alt2, alt3 = "", ""
    if ShowTop3 and #legalMoves >= 2 then
        -- Try to get #2 from Stockfish at shallower depth (avoid too many HTTP calls)
        -- For now, pick second and third legal move as placeholders
        -- (a full multi-pv query would need stockfish.online multipv support)
        local count = 0
        for _, uci in ipairs(legalMoves) do
            if uci ~= bestMove then
                count += 1
                if count == 1 then
                    alt2 = uci
                elseif count == 2 then
                    alt3 = uci
                    break
                end
            end
        end
    end

    -- Update engine source in Live Tab
    updateBookStatus(
        BookStatus.name ~= "—" and BookStatus.name or nil,
        CurrentLine,
        session.ucis or {},
        BookStatus.nextMove ~= "—" and BookStatus.nextMove or nil,
        BookStatus.deviated,
        BookStatus.deviatedAt
    )

    return bestMove, alt2, alt3, openingName
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
-- LIVE TAB: OPENING BOOK STATUS (REAL-TIME)
--==================================================

LiveTab:Section({
    Title = "Opening Book — Live",
    Icon = "book-open",
})

-- These paragraphs are stored and updated dynamically via updateBookStatus()
LiveBookNamePara = LiveTab:Paragraph({
    Title = "Active Opening",
    Desc = "—",
})

LiveBookProgressPara = LiveTab:Paragraph({
    Title = "Book Progress",
    Desc = "Not in book",
})

LiveBookNextPara = LiveTab:Paragraph({
    Title = "Next Book Move",
    Desc = "—",
})

LiveBookStatusPara = LiveTab:Paragraph({
    Title = "Book Status",
    Desc = "Engine mode (no book match)",
})

LiveTab:Section({
    Title = "Engine Status",
    Icon = "cpu",
})

LiveEngineSourcePara = LiveTab:Paragraph({
    Title = "Engine Source",
    Desc = "none",
})

LiveTab:Paragraph({
    Title = "Engine Info",
    Desc = "Primary: stockfish.online (depth 15) | Fallback: in-game Bot.think → Bot.analyse",
})

LiveTab:Button({
    Title = "Force Refresh Book Status",
    Icon = "refresh-cw",
    Callback = function()
        local session = App.session
        if session and not session.over then
            getBookMove(session)
            WindUI:Notify({
                Title = "Opening Book",
                Content = "Active: " .. BookStatus.name
                    .. "\nProgress: " .. tostring(BookStatus.movesDone) .. "/" .. tostring(BookStatus.movesTotal)
                    .. "\nNext move: " .. BookStatus.nextMove
                    .. "\nEngine: " .. BookStatus.engineUsed,
                Duration = 6,
            })
        else
            WindUI:Notify({
                Title = "Opening Book",
                Content = "No active game session.",
                Duration = 3,
            })
        end
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
        local statusLine
        if BookStatus.deviated then
            statusLine = "⚠ Deviated at move " .. tostring(BookStatus.deviatedAt)
        elseif BookStatus.active then
            statusLine = "✓ On book line"
        else
            statusLine = "Engine mode"
        end

        WindUI:Notify({
            Title = "Active Opening",
            Content = "Name: " .. BookStatus.name
                .. "\nProgress: " .. tostring(BookStatus.movesDone) .. " / " .. tostring(BookStatus.movesTotal) .. " moves"
                .. "\nNext: " .. BookStatus.nextMove
                .. "\nStatus: " .. statusLine
                .. "\nEngine: " .. BookStatus.engineUsed,
            Duration = 6,
        })
    end,
})

OpeningTab:Paragraph({
    Title = "Opening Detect Engine",
    Desc = "V4.0 detects current opening from full move history, tracks deviations, and re-enters the book if the game returns to a known line.",
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
-- SETTINGS TAB
--==================================================

SettingsTab:Section({
    Title = "General Settings",
    Icon = "sliders-horizontal",
})

SettingsTab:Paragraph({
    Title = "About",
    Desc = "GundamScript RoChess Pro V4.0 — Stockfish.online engine | Enhanced Opening Book detection | WindUI + Lucide icons.",
})

SettingsTab:Paragraph({
    Title = "Engine",
    Desc = "Primary: stockfish.online REST API (depth 15). Fallback chain: Bot.think (depth 20) → Bot.analyse (depth 14) → first legal move.",
})

SettingsTab:Section({
    Title = "Stockfish.online",
    Icon = "zap",
})

SettingsTab:Paragraph({
    Title = "API Endpoint",
    Desc = "https://stockfish.online/api/s/v2.php — free public API, no key required.",
})

SettingsTab:Toggle({
    Title = "Prefer Stockfish.online",
    Desc = "When enabled, always queries stockfish.online first before the in-game Bot. Disable if network is slow.",
    Value = true,
    Callback = function(value)
        -- Override getStockfishMove to skip online if disabled
        -- This flag is read inside getStockfishMove logic
        _G.GS_PreferOnline = value
        WindUI:Notify({
            Title = value and "Stockfish.online Active" or "Stockfish.online Disabled",
            Content = value and "Using stockfish.online as primary engine." or "Falling back to in-game Bot engine.",
            Duration = 3,
        })
    end,
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
    -- Opening Book first (Alien Gambit, manual selection, or auto random)
    local bookMove = getBookMove(session)
    if type(bookMove) == "string" and #bookMove >= 4 then
        local legalOk, legal = pcall(function()
            local eng = Engine.new(session.startFen)
            for _, played in ipairs(session.ucis or {}) do
                eng:playUci(played)
            end
            for _, move in ipairs(eng:legalMoves()) do
                if eng:moveToUci(move) == bookMove then
                    return true
                end
            end
            return false
        end)
        if legalOk and legal then
            return bookMove
        end
    end

    -- PRIMARY: stockfish.online (depth 15 for auto play — balance speed vs quality)
    local sfMove, sfSource = getStockfishMove(session, 15)
    BookStatus.engineUsed = sfSource or "none"
    if sfMove and type(sfMove) == "string" and #sfMove >= 4 then
        return sfMove
    end

    -- Last resort: getRankedMoves (which also tries stockfish + bot internally)
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
                    -- Opening name is available through
                    -- the "Lihat Opening Aktif" button.
                end

            elseif not success then
                warn("[GundamScript] Analysis failed:", m1)
            end
        end)
    end
end)


-- Load Cosmetics Module
loadstring(game:HttpGet("https://raw.githubusercontent.com/danz087h-create/Script/refs/heads/main/Cosmetics.lua"))()
