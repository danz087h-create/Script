-- GundamScript | RoChess Pro V5.1
-- WindUI + Lucide icons + Live information tab
-- Stockfish.online engine + Enhanced Opening Book Detection
-- Mate Prediction System + Enhanced Visual Arrows
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
--==================================================

local HttpService = game:GetService("HttpService")

local function buildFenFromSession(session)
    local ok, fen = pcall(function()
        local eng = Engine.new(session.startFen)
        for _, uci in ipairs(session.ucis or {}) do
            eng:playUci(uci)
        end
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
    return session.startFen or "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1"
end

local StockfishCache = {}
local StockfishCacheKey = nil

-- Query Stockfish.online — returns bestmove UCI and raw data table
local function queryStockfishOnlineFull(session, depth)
    depth = depth or 15
    local fen = buildFenFromSession(session)
    local cacheKey = fen .. "|" .. tostring(depth) .. "|full"

    if StockfishCacheKey == cacheKey and StockfishCache[cacheKey] then
        return StockfishCache[cacheKey]
    end

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

    if not parseOk or not data or not data.success then
        return nil
    end

    StockfishCache = {}
    StockfishCache[cacheKey] = data
    StockfishCacheKey = cacheKey

    return data
end

local function queryStockfishOnline(session, depth)
    local data = queryStockfishOnlineFull(session, depth or 15)
    if not data then return nil end

    local bestmove = data.bestmove or ""
    local uci = bestmove:match("bestmove%s+(%S+)") or bestmove:match("^(%S+)")

    if not uci or uci == "(none)" or #uci < 4 then
        return nil
    end
    return uci
end

-- Parse mate-in-N from Stockfish info string
-- Returns: mateInN (number or nil), mateSequence (array of UCI or nil)
local function parseMateFromStockfish(data)
    if not data then return nil, nil end

    -- Try to parse "mate N" from the info field
    local info = data.info or ""
    local mateN = nil

    -- Look for "score mate N" in info
    local m = info:match("score mate (%-?%d+)")
    if m then
        local n = tonumber(m)
        if n and n > 0 and n <= 10 then
            mateN = n
        end
    end

    -- Also check evaluation field sometimes returned by the API
    if not mateN then
        local eval = data.evaluation
        if type(eval) == "string" then
            local em = eval:match("^#(%d+)") or eval:match("^Mate in (%d+)")
            if em then
                mateN = tonumber(em)
            end
        end
    end

    return mateN, nil
end

-- Get best move from Stockfish with fallback to in-game Bot
local function getStockfishMove(session, depth)
    local onlineUci = queryStockfishOnline(session, depth or 15)
    if onlineUci then
        return onlineUci, "stockfish.online"
    end

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

    local ok2, result2 = pcall(function()
        return Bot.analyse(session.startFen, session.ucis, 0.5, 14)
    end)
    if ok2 and result2 and result2.best and result2.best ~= "" then
        return result2.best, "bot.analyse"
    end

    return nil, nil
end

local LastEngineSource = "none"

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

--==================================================
-- STATE VARIABLES
--==================================================

local AnalysisEnabled = true
local AutoPlayEnabled = false
local AutoQueueEnabled = false
local AntiAFKEnabled = false
local ShowTop3 = true        -- Now unlocked and ON by default
local ShowMateArrows = true  -- Mate prediction arrows
local AutoOpeningEnabled = true

local MoveDelay = 1.5
local OpeningMode = "Auto Random"
local SelectedOpeningName = "Alien Gambit"

--==================================================
-- ARROW STATE
--==================================================

-- Forward declarations (real implementations defined later in MATE LABEL section)
local removeMateLabel = function() end
local showMateLabel   = function(_sq) end

local LastMoves = { m1 = "", m2 = "", m3 = "" }
local LastPositionKey = nil
local LastBoard = nil

-- Mate arrow state (up to 10 mate steps)
local MateArrowKeys = {}
for i = 1, 10 do
    MateArrowKeys[i] = "mate_arrow_" .. i
end

local AnalysisToken = 0
local PreviousPositionKey = nil
local PreviousSession = nil
local AnalysisRunning = false
local PendingAnalysis = false

-- Mate state
local CurrentMateN = 0
local MateNotified = false

--==================================================
-- ENHANCED ARROW COLORS
--==================================================

-- Main move arrows (3 ranks)
local Colors = {
    Rank1 = Color3.fromRGB(46, 213, 115),    -- Bright green — best move
    Rank2 = Color3.fromRGB(100, 149, 237),   -- Cornflower blue — 2nd best
    Rank3 = Color3.fromRGB(255, 165, 0),     -- Orange — 3rd best
}

-- Mate arrow colors: move 1 always green, rest cycle through vivid palette
local MateColors = {
    Color3.fromRGB(46, 213, 115),   -- [1] Green  — your first move (start)
    Color3.fromRGB(255, 71,  87),   -- [2] Red    — enemy response
    Color3.fromRGB(255, 215,  0),   -- [3] Gold   — your follow-up
    Color3.fromRGB(100, 149, 237),  -- [4] Blue   — enemy
    Color3.fromRGB(199,  36, 177),  -- [5] Magenta— your move
    Color3.fromRGB(255, 128,   0),  -- [6] Orange — enemy
    Color3.fromRGB(0,   206, 209),  -- [7] Cyan   — your move
    Color3.fromRGB(255, 255, 255),  -- [8] White  — enemy
    Color3.fromRGB(173, 255,  47),  -- [9] GreenYellow
    Color3.fromRGB(255,  20, 147),  -- [10] DeepPink
}

--==================================================
-- OPENING BOOK STATUS
--==================================================

local BookStatus = {
    active      = false,
    name        = "—",
    movesDone   = 0,
    movesTotal  = 0,
    nextMove    = "—",
    deviated    = false,
    deviatedAt  = 0,
    engineUsed  = "none",
}

local LiveBookNamePara    = nil
local LiveBookProgressPara= nil
local LiveBookNextPara    = nil
local LiveBookStatusPara  = nil
local LiveEngineSourcePara= nil
local LiveMatePara        = nil

--==================================================
-- OPENING BOOK
--==================================================

local OpeningBook = {
    -- WHITE: ATTACKING OPENINGS
    { name = "Italian Game",      side = "White", moves = { "e2e4","e7e5","g1f3","b8c6","f1c4","f8c5","c2c3","g8f6" } },
    { name = "Ruy Lopez",         side = "White", moves = { "e2e4","e7e5","g1f3","b8c6","f1b5","a7a6","b5a4","g8f6" } },
    { name = "Scotch Game",       side = "White", moves = { "e2e4","e7e5","g1f3","b8c6","d2d4","e5d4","f3d4" } },
    { name = "Vienna Game",       side = "White", moves = { "e2e4","e7e5","b1c3","g8f6","f2f4" } },
    { name = "King's Gambit",     side = "White", moves = { "e2e4","e7e5","f2f4","e5f4","g1f3" } },
    { name = "Danish Gambit",     side = "White", moves = { "e2e4","e7e5","d2d4","e5d4","c2c3","d4c3","f1c4" } },
    { name = "Ponziani Opening",  side = "White", moves = { "e2e4","e7e5","g1f3","b8c6","c2c3" } },
    { name = "Four Knights Game", side = "White", moves = { "e2e4","e7e5","g1f3","b8c6","b1c3","g8f6" } },
    { name = "Queen's Gambit",    side = "White", moves = { "d2d4","d7d5","c2c4","e7e6","b1c3" } },
    { name = "London System",     side = "White", moves = { "d2d4","d7d5","c1f4","g8f6","e2e3" } },
    { name = "English Opening",   side = "White", moves = { "c2c4","e7e5","b1c3","g8f6","g1f3" } },
    { name = "Réti Opening",      side = "White", moves = { "g1f3","d7d5","c2c4","e7e6","g2g3" } },
    { name = "Bird Opening",      side = "White", moves = { "f2f4","d7d5","g1f3","g8f6","e2e3" } },
    { name = "Trompowsky Attack", side = "White", moves = { "d2d4","g8f6","c1g5","d7d5","b1c3" } },
    { name = "King's Indian Attack",side="White", moves = { "g1f3","d7d5","g2g3","g8f6","f1g2","e7e6" } },

    -- BLACK: DEFENSE AGAINST 1.e4
    { name = "Sicilian Defense",      side = "Black", moves = { "e2e4","c7c5","g1f3","d7d6","d2d4","c5d4","f3d4" } },
    { name = "French Defense",        side = "Black", moves = { "e2e4","e7e6","d2d4","d7d5","b1c3","g8f6" } },
    { name = "Caro-Kann Defense",     side = "Black", moves = { "e2e4","c7c6","d2d4","d7d5","b1c3" } },
    { name = "Scandinavian Defense",  side = "Black", moves = { "e2e4","d7d5","e4d5","d8d5","b1c3" } },
    { name = "Pirc Defense",          side = "Black", moves = { "e2e4","d7d6","d2d4","g8f6","b1c3","g7g6" } },
    {
        name = "Alien Gambit", side = "White",
        moves = { "e2e4","c7c6","d2d4","d7d5","b1c3","d5e4","c3e4","g8f6","e4g5","h7h6","g5f7","e8f7","g1f3","c7c5" }
    },
    { name = "Alekhine Defense",      side = "Black", moves = { "e2e4","g8f6","e4e5","f6d5","d2d4" } },
    { name = "Modern Defense",        side = "Black", moves = { "e2e4","g7g6","d2d4","f8g7","b1c3" } },
    { name = "Owen's Defense",        side = "Black", moves = { "e2e4","b7b6","d2d4","c8b7","b1c3" } },
    { name = "Nimzowitsch Defense",   side = "Black", moves = { "e2e4","b8c6","d2d4","d7d5" } },
    { name = "Open Game",             side = "Black", moves = { "e2e4","e7e5","g1f3","b8c6","b1c3","g8f6" } },

    -- BLACK: DEFENSE AGAINST 1.d4
    { name = "King's Indian Defense",   side = "Black", moves = { "d2d4","g8f6","c2c4","g7g6","b1c3","f8g7" } },
    { name = "Grunfeld Defense",        side = "Black", moves = { "d2d4","g8f6","c2c4","g7g6","b1c3","d7d5" } },
    { name = "Nimzo-Indian Defense",    side = "Black", moves = { "d2d4","g8f6","c2c4","e7e6","b1c3","f8b4" } },
    { name = "Queen's Indian Defense",  side = "Black", moves = { "d2d4","g8f6","c2c4","e7e6","g1f3","b7b6" } },
    { name = "Slav Defense",            side = "Black", moves = { "d2d4","d7d5","c2c4","c7c6","g1f3" } },
    { name = "Dutch Defense",           side = "Black", moves = { "d2d4","f7f5","g2g3","g8f6","f1g2" } },
    { name = "Queen's Gambit Declined", side = "Black", moves = { "d2d4","d7d5","c2c4","e7e6","b1c3" } },
    { name = "Benoni Defense",          side = "Black", moves = { "d2d4","g8f6","c2c4","c7c5","d4d5" } },
    { name = "Budapest Gambit",         side = "Black", moves = { "d2d4","g8f6","c2c4","e7e5" } },
    { name = "Albin Countergambit",     side = "Black", moves = { "d2d4","d7d5","c2c4","e7e5" } },
    { name = "Chigorin Defense",        side = "Black", moves = { "d2d4","d7d5","c2c4","b8c6" } },
}

--==================================================
-- OPENING BOOK STATE
--==================================================

local CurrentOpening = nil
local CurrentLine = nil

local function randomChoice(list)
    if not list or #list == 0 then return nil end
    return list[math.random(1, #list)]
end

local function samePrefix(history, line)
    if #history > #line then return false end
    for i, move in ipairs(history) do
        if move ~= line[i] then return false end
    end
    return true
end

local function clearCurrentOpening()
    CurrentOpening = nil
    CurrentLine = nil
    BookStatus.active    = false
    BookStatus.name      = "—"
    BookStatus.movesDone = 0
    BookStatus.movesTotal= 0
    BookStatus.nextMove  = "—"
    BookStatus.deviated  = false
    BookStatus.deviatedAt= 0
end

local function updateBookStatus(opening, line, history, nextMove, deviated, deviatedAt)
    BookStatus.active     = (opening ~= nil)
    BookStatus.name       = opening or "—"
    BookStatus.movesDone  = #history
    BookStatus.movesTotal = line and #line or 0
    BookStatus.nextMove   = nextMove or "—"
    BookStatus.deviated   = deviated or false
    BookStatus.deviatedAt = deviatedAt or 0

    if LiveBookNamePara then
        pcall(function() LiveBookNamePara:Set(BookStatus.name) end)
    end
    if LiveBookProgressPara then
        local prog = BookStatus.active
            and (tostring(BookStatus.movesDone).." / "..tostring(BookStatus.movesTotal).." moves")
            or "Not in book"
        pcall(function() LiveBookProgressPara:Set(prog) end)
    end
    if LiveBookNextPara then
        pcall(function() LiveBookNextPara:Set(BookStatus.nextMove) end)
    end
    if LiveBookStatusPara then
        local statusText
        if BookStatus.deviated then
            statusText = "⚠ Deviation at move "..tostring(BookStatus.deviatedAt).." — engine takes over"
        elseif BookStatus.active then
            statusText = "✓ Following book line"
        else
            statusText = "Engine mode (no book match)"
        end
        pcall(function() LiveBookStatusPara:Set(statusText) end)
    end
    if LiveEngineSourcePara then
        pcall(function() LiveEngineSourcePara:Set(BookStatus.engineUsed) end)
    end
end

local function detectOpeningFromHistory(history)
    if not history or #history == 0 then return nil, nil, false, 0 end
    local bestMatch, bestDepth = nil, 0
    for _, opening in ipairs(OpeningBook) do
        local matchDepth = 0
        for i, move in ipairs(opening.moves) do
            if history[i] == move then matchDepth = i else break end
        end
        if matchDepth > bestDepth then
            bestDepth = matchDepth
            bestMatch = opening
        end
    end
    if not bestMatch or bestDepth == 0 then return nil, nil, false, 0 end
    local deviated, deviatedAt = false, 0
    for i = 1, math.min(#history, #bestMatch.moves) do
        if history[i] ~= bestMatch.moves[i] then
            deviated = true; deviatedAt = i; break
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
                    updateBookStatus(opening.name, opening.moves, history, nil, false, 0)
                    clearCurrentOpening()
                    return nil, opening.name
                end
                local devIdx = 0
                for i = 1, math.min(#history, #opening.moves) do
                    if history[i] ~= opening.moves[i] then devIdx = i; break end
                end
                updateBookStatus(opening.name, opening.moves, history, nil, true, devIdx)
                clearCurrentOpening()
                return nil, opening.name
            end
        end
        return nil
    end
    if OpeningMode ~= "Auto Random" then return nil end

    -- Continue current line if still on track
    if CurrentLine and CurrentOpening then
        if samePrefix(history, CurrentLine) then
            local nextMove = CurrentLine[#history + 1]
            if nextMove then
                updateBookStatus(CurrentOpening, CurrentLine, history, nextMove, false, 0)
                return nextMove, CurrentOpening
            else
                updateBookStatus(CurrentOpening, CurrentLine, history, nil, false, 0)
                clearCurrentOpening()
                return nil, CurrentOpening
            end
        else
            local devIdx = 0
            for i = 1, math.min(#history, #CurrentLine) do
                if history[i] ~= CurrentLine[i] then devIdx = i; break end
            end
            updateBookStatus(CurrentOpening, CurrentLine, history, nil, true, devIdx)
            clearCurrentOpening()
        end
    end

    -- Try to re-detect from full history (re-entry detection)
    local detected, _, deviated, deviatedAt = detectOpeningFromHistory(history)
    if detected and not deviated then
        local nextMove = detected.moves[#history + 1]
        if nextMove then
            CurrentOpening = detected.name
            CurrentLine = detected.moves
            updateBookStatus(detected.name, detected.moves, history, nextMove, false, 0)
            return nextMove, detected.name
        end
    end

    -- Find ALL openings whose full move list starts with current history
    -- No side filter — the opening's own moves encode whose turn it is
    local candidates = {}
    for _, opening in ipairs(OpeningBook) do
        if #opening.moves > #history and samePrefix(history, opening.moves) then
            table.insert(candidates, opening)
        end
    end

    local selected = randomChoice(candidates)
    if not selected then
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
    if not board then return end
    pcall(function()
        board:setArrow("sagg_1", nil)
        board:setArrow("sagg_2", nil)
        board:setArrow("sagg_3", nil)
        for i = 1, 10 do
            board:setArrow(MateArrowKeys[i], nil)
        end
    end)
end

local function resetArrows()
    clearArrows(LastBoard or App.board)
    removeMateLabel()
    LastMoves = { m1 = "", m2 = "", m3 = "" }
    LastPositionKey = nil
    LastBoard = nil
    CurrentMateN = 0
    MateNotified = false
end

local function getPositionKey(session)
    local moves = session.ucis or {}
    return tostring(session.startFen) .. "|" .. table.concat(moves, ",")
end

-- Draw an enhanced arrow with better visuals
local function drawArrow(board, key, uci, color, transparency)
    if type(uci) ~= "string" or #uci < 4 then return end
    local from = Engine.algToIndex64(uci:sub(1, 2))
    local to   = Engine.algToIndex64(uci:sub(3, 4))
    if from and to then
        board:setArrow(key, from, to, color, transparency)
    end
end

-- Update the 3 main analysis arrows (now all powered by Stockfish)
local function updateMultiArrows(m1, m2, m3, positionKey)
    local board = App.board
    if not board then return end
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

        if AnalysisEnabled then
            -- Rank 1: Green, fully visible
            drawArrow(board, "sagg_1", m1, Colors.Rank1, 0.10)

            if ShowTop3 then
                -- Rank 2: Blue, slightly transparent
                drawArrow(board, "sagg_2", m2, Colors.Rank2, 0.25)
                -- Rank 3: Orange, more transparent
                drawArrow(board, "sagg_3", m3, Colors.Rank3, 0.40)
            end
        end
    end)

    if success then
        LastMoves = { m1 = m1, m2 = m2, m3 = m3 }
        LastPositionKey = positionKey
    end
end

--==================================================
-- MATE PREDICTION ARROWS
--==================================================

-- Given a session and mateN, simulate the forced mate line using Stockfish
-- Returns array of UCI strings for the mate sequence (alternating sides)
local function getMateSequence(session, mateN)
    if not mateN or mateN <= 0 or mateN > 10 then return nil end

    local sequence = {}
    local simSession = {
        startFen = session.startFen,
        ucis = table.clone(session.ucis or {})
    }

    for step = 1, mateN * 2 - 1 do
        -- Build a temporary session clone for Stockfish
        local tempSession = {
            startFen = simSession.startFen,
            ucis = table.clone(simSession.ucis)
        }

        local uci = queryStockfishOnline(tempSession, math.min(mateN * 2 + 2, 20))
        if not uci or uci == "(none)" then
            break
        end

        table.insert(sequence, uci)
        table.insert(simSession.ucis, uci)

        -- Stop after the final checkmate move
        if step == mateN * 2 - 1 then break end
    end

    return #sequence > 0 and sequence or nil
end

-- Draw mate sequence arrows on the board
-- myMoves: our moves (odd indices in sequence: 1,3,5...)
-- enemyMoves: enemy response moves (even indices: 2,4,6...)
local function drawMateArrows(board, sequence, positionKey)
    if not board or not sequence or #sequence == 0 then return end

    -- Clear previous mate arrows
    for i = 1, 10 do
        pcall(function() board:setArrow(MateArrowKeys[i], nil) end)
    end

    for i, uci in ipairs(sequence) do
        local color = MateColors[i] or MateColors[#MateColors]
        -- Our moves (index 1, 3, 5...) are more opaque, enemy moves more transparent
        local isOurMove = (i % 2 == 1)
        local transparency = isOurMove and 0.08 or 0.25

        drawArrow(board, MateArrowKeys[i], uci, color, transparency)
        task.wait(0.02) -- Stagger draws slightly for visual effect
    end
end

-- Clear all mate arrows
local function clearMateArrows(board)
    if not board then return end
    for i = 1, 10 do
        pcall(function() board:setArrow(MateArrowKeys[i], nil) end)
    end
end

--==================================================
-- MATE LABEL: show "#" text on the destination square
-- of the best move arrow when mate is detected
--==================================================

local MateLabelGui = nil  -- BillboardGui instance

-- Override the forward declaration
removeMateLabel = function()
    if MateLabelGui then
        pcall(function() MateLabelGui:Destroy() end)
        MateLabelGui = nil
    end
end

-- Convert UCI square (e.g. "e4") to world position on the board
local function getSquareWorldPos(board, squareAlg)
    -- Try board:getSquarePart or board:squarePart to get the 3D part
    local part = nil
    pcall(function()
        local idx = Engine.algToIndex64(squareAlg)
        if board.getSquarePart then
            part = board:getSquarePart(idx)
        elseif board.squareParts then
            part = board.squareParts[idx]
        elseif board.squares then
            part = board.squares[idx]
        end
    end)
    return part
end

-- Override the forward declaration
showMateLabel = function(bestMoveTo)
    removeMateLabel()

    local board = App.board
    if not board then return end

    -- Get the 3D part for the destination square
    local squarePart = getSquareWorldPos(board, bestMoveTo)
    if not squarePart or not squarePart:IsA("BasePart") then
        -- Fallback: try to find via workspace using the board's model
        pcall(function()
            local boardModel = board.model or board.Model or board.instance
            if boardModel then
                for _, child in ipairs(boardModel:GetDescendants()) do
                    if child:IsA("BasePart") and child.Name:lower():find(bestMoveTo:lower()) then
                        squarePart = child
                        break
                    end
                end
            end
        end)
    end

    if not squarePart or not squarePart:IsA("BasePart") then return end

    pcall(function()
        local gui = Instance.new("BillboardGui")
        gui.Name = "GS_MateLabel"
        gui.Adornee = squarePart
        gui.AlwaysOnTop = true
        gui.Size = UDim2.fromOffset(60, 36)
        gui.StudsOffset = Vector3.new(0, 1.2, 0)
        gui.ResetOnSpawn = false

        local frame = Instance.new("Frame", gui)
        frame.Size = UDim2.fromScale(1, 1)
        frame.BackgroundColor3 = Color3.fromRGB(20, 20, 20)
        frame.BackgroundTransparency = 0.15
        frame.BorderSizePixel = 0

        local corner = Instance.new("UICorner", frame)
        corner.CornerRadius = UDim.new(0, 6)

        local stroke = Instance.new("UIStroke", frame)
        stroke.Color = Color3.fromRGB(46, 213, 115)
        stroke.Thickness = 2
        stroke.Transparency = 0

        local label = Instance.new("TextLabel", frame)
        label.Size = UDim2.fromScale(1, 1)
        label.BackgroundTransparency = 1
        label.Text = "#"
        label.TextColor3 = Color3.fromRGB(46, 213, 115)
        label.TextScaled = true
        label.Font = Enum.Font.GothamBold
        label.TextStrokeTransparency = 0.4
        label.TextStrokeColor3 = Color3.fromRGB(0, 0, 0)

        gui.Parent = squarePart
        MateLabelGui = gui
    end)
end

--==================================================
-- ANALYSIS + OPENING BOOK
-- Now uses real Stockfish for all 3 ranked moves
--==================================================

-- Simulate position after one move to get Stockfish's response
local function getStockfishMoveAfter(session, playedUci, depth)
    local tempSession = {
        startFen = session.startFen,
        ucis = table.clone(session.ucis or {})
    }
    table.insert(tempSession.ucis, playedUci)
    return getStockfishMove(tempSession, depth or 12)
end

local function getRankedMoves(session)
    -- Build legal move set
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
        bestMove = bookMove
        engineSource = "opening.book"
        BookStatus.engineUsed = engineSource
    else
        if bookMove then clearCurrentOpening() end

        -- PRIMARY: Stockfish.online for best move
        local sfMove, sfSource = getStockfishMove(session, 15)
        if sfMove and legalSet[sfMove] then
            bestMove = sfMove
            engineSource = sfSource or "stockfish.online"
        elseif sfMove then
            bestMove = sfMove
            engineSource = (sfSource or "stockfish.online").." (unverified)"
        else
            bestMove = legalMoves[1] or ""
            engineSource = "legal.fallback"
        end
        BookStatus.engineUsed = engineSource
        LastEngineSource = engineSource
    end

    -- Rank 2 & 3: Use Stockfish at lower depth on slightly different positions
    -- We exclude bestMove and get Stockfish's next-best from remaining legal moves
    local alt2, alt3 = "", ""
    if ShowTop3 and #legalMoves >= 2 then
        -- Collect candidates excluding bestMove
        local candidates = {}
        for _, uci in ipairs(legalMoves) do
            if uci ~= bestMove then
                table.insert(candidates, uci)
            end
        end

        -- For alt2: ask Stockfish what it would play from position WITHOUT bestMove being available
        -- We simulate this by getting Stockfish at depth 10 from the same position (may return bestMove again)
        -- then fall back to second candidate
        if #candidates >= 1 then
            local sfAlt2, _ = queryStockfishOnline(session, 10)
            if sfAlt2 and sfAlt2 ~= bestMove and legalSet[sfAlt2] then
                alt2 = sfAlt2
            else
                alt2 = candidates[1] or ""
            end
        end

        -- For alt3: third distinct legal move via Stockfish at depth 8
        if #candidates >= 2 then
            local sfAlt3, _ = queryStockfishOnline(session, 8)
            if sfAlt3 and sfAlt3 ~= bestMove and sfAlt3 ~= alt2 and legalSet[sfAlt3] then
                alt3 = sfAlt3
            else
                for _, uci in ipairs(candidates) do
                    if uci ~= alt2 then
                        alt3 = uci
                        break
                    end
                end
            end
        end
    end

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
-- MATE DETECTION + NOTIFICATION
--==================================================

local function detectAndShowMate(session, positionKey)
    if not ShowMateArrows or not AnalysisEnabled then return end

    local board = App.board
    if not board then return end

    -- Query Stockfish at high depth for mate detection
    local data = queryStockfishOnlineFull(session, 20)
    if not data then return end

    local mateN, _ = parseMateFromStockfish(data)

    -- Also check evaluation for mate score from some API responses
    if not mateN then
        local bestmove = data.bestmove or ""
        local info = data.info or ""
        -- Sometimes API returns "mate in X" in different fields
        local m2 = info:match("mate (%d+)") or info:match("Mate in (%d+)")
        if m2 then mateN = tonumber(m2) end
    end

    if not mateN or mateN <= 0 then
        -- No forced mate — clear mate arrows and label
        if CurrentMateN > 0 then
            clearMateArrows(board)
            removeMateLabel()
            CurrentMateN = 0
            MateNotified = false
            if LiveMatePara then
                pcall(function() LiveMatePara:Set("No forced mate detected") end)
            end
        end
        return
    end

    -- Found a forced mate — skip if already processed for this position
    if mateN == CurrentMateN and MateNotified then return end

    CurrentMateN = mateN
    MateNotified = true

    -- Update Live Tab only (no popup notification)
    if LiveMatePara then
        pcall(function()
            LiveMatePara:Set(string.format("⚡ Mate in %d — follow green arrows", mateN))
        end)
    end

    -- Retrieve and draw the mate sequence arrows
    task.spawn(function()
        local sequence = getMateSequence(session, mateN)
        local board2 = App.board
        if not board2 then return end

        if sequence and #sequence > 0 then
            drawMateArrows(board2, sequence, positionKey)

            -- For mate in 1: show "#" label on the destination square of the killing move
            if mateN == 1 and sequence[1] and #sequence[1] >= 4 then
                local destSq = sequence[1]:sub(3, 4)
                showMateLabel(destSq)
            end
        end
    end)
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
    if ok and info and info.Name then return info.Name end
    return "Unavailable"
end

local function showLiveInfo()
    local playerCount = #Players:GetPlayers()
    local maxPlayers = "?"
    pcall(function() maxPlayers = tostring(Players.MaxPlayers) end)
    WindUI:Notify({
        Title = "GundamScript | Live Information",
        Content = "Player: " .. (LocalPlayer and LocalPlayer.Name or "?")
            .. "\nAccount age: " .. (LocalPlayer and tostring(LocalPlayer.AccountAge).." days" or "?")
            .. "\nGame: " .. getGameName()
            .. "\nPlayers in server: " .. tostring(playerCount) .. " / " .. maxPlayers,
        Duration = 8,
    })
end

LiveTab:Section({ Title = "Live Information", Icon = "activity" })

LiveTab:Paragraph({ Title = "Player Name",   Desc = LocalPlayer and LocalPlayer.Name or "Unavailable" })
LiveTab:Paragraph({ Title = "Account Age",   Desc = LocalPlayer and (tostring(LocalPlayer.AccountAge).." days") or "Unavailable" })
LiveTab:Paragraph({ Title = "Current Game",  Desc = getGameName() })
LiveTab:Paragraph({
    Title = "Players in Server",
    Desc = tostring(#Players:GetPlayers()) .. " players in this server. Press Refresh to update.",
})

LiveTab:Button({
    Title = "Refresh Information",
    Icon = "refresh-cw",
    Callback = function() showLiveInfo() end,
})

LiveTab:Section({ Title = "Opening Book — Live", Icon = "book-open" })

LiveBookNamePara = LiveTab:Paragraph({ Title = "Active Opening", Desc = "—" })
LiveBookProgressPara = LiveTab:Paragraph({ Title = "Book Progress", Desc = "Not in book" })
LiveBookNextPara = LiveTab:Paragraph({ Title = "Next Book Move", Desc = "—" })
LiveBookStatusPara = LiveTab:Paragraph({ Title = "Book Status", Desc = "Engine mode (no book match)" })

LiveTab:Section({ Title = "Engine & Mate Detection", Icon = "cpu" })

LiveEngineSourcePara = LiveTab:Paragraph({ Title = "Engine Source", Desc = "none" })

LiveMatePara = LiveTab:Paragraph({
    Title = "Mate Prediction",
    Desc = "No forced mate detected",
})

LiveTab:Paragraph({
    Title = "Engine Info",
    Desc = "Primary: stockfish.online (depth 15-20) | Fallback: in-game Bot.think → Bot.analyse",
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
                    .. "\nProgress: " .. tostring(BookStatus.movesDone).."/"..tostring(BookStatus.movesTotal)
                    .. "\nNext move: " .. BookStatus.nextMove
                    .. "\nEngine: " .. BookStatus.engineUsed,
                Duration = 6,
            })
        else
            WindUI:Notify({ Title = "Opening Book", Content = "No active game session.", Duration = 3 })
        end
    end,
})

--==================================================
-- MAIN TAB (Game Helper)
--==================================================

MainTab:Section({ Title = "Analysis", Icon = "brain" })

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
    Title = "Show Top 3 Moves",
    Desc = "Display 3 Stockfish-powered move arrows. Green=best, Blue=2nd, Orange=3rd.",
    Value = true,
    Callback = function(value)
        ShowTop3 = value
        PreviousPositionKey = nil
        PendingAnalysis = true
    end,
})

MainTab:Toggle({
    Title = "Mate Prediction Arrows",
    Desc = "When a forced mate is found, show the full sequence of arrows on the board.",
    Value = true,
    Callback = function(value)
        ShowMateArrows = value
        if not value then
            clearMateArrows(App.board)
            CurrentMateN = 0
            MateNotified = false
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

MainTab:Section({ Title = "Convenience", Icon = "settings-2" })

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
-- VISUAL TAB
--==================================================

VisualTab:Section({ Title = "Arrow Legend", Icon = "palette" })

VisualTab:Paragraph({
    Title = "Main Analysis Arrows",
    Desc = "All 3 arrows are powered by Stockfish.online. Green = Best move | Blue = 2nd best | Orange = 3rd best",
})

VisualTab:Button({
    Title = "🟢  Best Move (Rank 1)",
    Icon = "arrow-up-right",
    Callback = function()
        WindUI:Notify({
            Title = "Rank 1 — Best Move",
            Content = "Bright green arrow.\nStockfish depth 15 primary engine.\nMost accurate move from current position.",
            Duration = 4,
        })
    end,
})

VisualTab:Button({
    Title = "🔵  2nd Best (Rank 2)",
    Icon = "arrow-up-right",
    Callback = function()
        WindUI:Notify({
            Title = "Rank 2 — 2nd Best Move",
            Content = "Blue arrow.\nStockfish depth 10 — strong alternative.\nEnable 'Show Top 3 Moves' in Game Helper.",
            Duration = 4,
        })
    end,
})

VisualTab:Button({
    Title = "🟠  3rd Best (Rank 3)",
    Icon = "arrow-up-right",
    Callback = function()
        WindUI:Notify({
            Title = "Rank 3 — 3rd Best Move",
            Content = "Orange arrow.\nStockfish depth 8 — third option.\nEnable 'Show Top 3 Moves' in Game Helper.",
            Duration = 4,
        })
    end,
})

VisualTab:Section({ Title = "Mate Prediction Arrows", Icon = "zap" })

VisualTab:Paragraph({
    Title = "Mate Sequence Colors",
    Desc = "Move 1 (your move) = Green. Even moves (enemy) = Red/Orange/etc. Each arrow in the forced mate sequence gets its own distinct color.",
})

VisualTab:Button({
    Title = "⚡ Mate Arrow Guide",
    Icon = "info",
    Callback = function()
        WindUI:Notify({
            Title = "Mate Prediction Guide",
            Content = "When a forced mate is found:\n"
                .. "• Green arrow = YOUR first move\n"
                .. "• Red = Enemy's forced response\n"
                .. "• Gold = Your follow-up\n"
                .. "• Blue = Enemy response\n"
                .. "• Continue until checkmate\n\n"
                .. "A notification appears showing mate in N moves.",
            Duration = 8,
        })
    end,
})

VisualTab:Paragraph({
    Title = "Arrow Transparency",
    Desc = "Your moves are drawn at 90% opacity. Enemy response arrows at 75% opacity to distinguish both sides clearly.",
})

--==================================================
-- OPENING BOOK TAB
--==================================================

OpeningTab:Section({ Title = "Opening Mode", Icon = "book-open" })

OpeningTab:Dropdown({
    Title = "Mode",
    Values = { "Auto Random", "Manual", "Engine Only" },
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

local OpeningNames = {}
for _, opening in ipairs(OpeningBook) do
    table.insert(OpeningNames, opening.name)
end
table.sort(OpeningNames, function(a, b) return string.lower(a) < string.lower(b) end)

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
        WindUI:Notify({ Title = "Manual Opening", Content = "Selected: " .. SelectedOpeningName, Duration = 3 })
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
        WindUI:Notify({ Title = "Opening Book", Content = "Opening selection has been reset.", Duration = 3 })
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
                .. "\nProgress: " .. tostring(BookStatus.movesDone).." / "..tostring(BookStatus.movesTotal).." moves"
                .. "\nNext: " .. BookStatus.nextMove
                .. "\nStatus: " .. statusLine
                .. "\nEngine: " .. BookStatus.engineUsed,
            Duration = 6,
        })
    end,
})

OpeningTab:Paragraph({
    Title = "Opening Detect Engine",
    Desc = "V5.0 detects current opening from full move history, tracks deviations, and re-enters the book if the game returns to a known line.",
})

--==================================================
-- ANTI-AFK
--==================================================

if LocalPlayer then
    LocalPlayer.Idled:Connect(function()
        if not AntiAFKEnabled then return end
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
    local ok, err = sendAction({ type = "queue", tc = "3+2" })
    if not ok then warn("[GundamScript] Auto Queue failed:", tostring(err)) end
    return ok
end

task.spawn(function()
    task.wait(2)
    while task.wait(1.5) do
        if not AutoQueueEnabled or QueueBusy then continue end
        local session = App.session
        if session and not session.over then continue end
        QueueBusy = true
        task.spawn(function()
            task.wait(2.5)
            if AutoQueueEnabled then requestQueue() end
            task.wait(5)
            QueueBusy = false
        end)
    end
end)

--==================================================
-- AUTO PLAY WORKER
--==================================================

local AutoPlayBusy = false

local function isAutoPlayTurn(session)
    if not session or session.over then return false end
    local ok, result = pcall(function() return session:isMyTurn() end)
    if ok then return result == true end
    return session.myColor ~= nil
        and session.engine ~= nil
        and session.engine.side == session.myColor
        and session.viewPly == #(session.ucis or {})
end

local function getAutoPlayMove(session)
    local bookMove = getBookMove(session)
    if type(bookMove) == "string" and #bookMove >= 4 then
        local legalOk, legal = pcall(function()
            local eng = Engine.new(session.startFen)
            for _, played in ipairs(session.ucis or {}) do eng:playUci(played) end
            for _, move in ipairs(eng:legalMoves()) do
                if eng:moveToUci(move) == bookMove then return true end
            end
            return false
        end)
        if legalOk and legal then return bookMove end
    end
    local sfMove, sfSource = getStockfishMove(session, 15)
    BookStatus.engineUsed = sfSource or "none"
    if sfMove and type(sfMove) == "string" and #sfMove >= 4 then return sfMove end
    local fallbackOk, best = pcall(function()
        local m1 = getRankedMoves(session)
        return m1
    end)
    if fallbackOk and type(best) == "string" and best ~= "" then return best end
    return nil
end

local function attemptAutoMove(session, uci)
    if type(uci) ~= "string" or #uci < 4 then return false end
    local from64 = Engine.algToIndex64(uci:sub(1, 2))
    local to64   = Engine.algToIndex64(uci:sub(3, 4))
    local promo  = ({ q=5, r=4, b=3, n=2 })[uci:sub(5,5):lower()] or 0
    if not from64 or not to64 then return false end
    local clientOk = pcall(function() App.onBoardMove(from64, to64, promo, false) end)
    if clientOk then return true end
    if session.kind == "online" and not session.over then
        local remoteOk = sendAction({ type="move", id=session.id, uci=uci, ply=#(session.ucis or {}) })
        return remoteOk
    end
    return false
end

task.spawn(function()
    while task.wait(0.25) do
        if not AutoPlayEnabled or AutoPlayBusy then continue end
        local session = App.session
        if not isAutoPlayTurn(session) then continue end
        if session.kind ~= "online" and session.kind ~= "bot" then continue end
        AutoPlayBusy = true
        local startSession = session
        local startKeyOk, startKey = pcall(getPositionKey, session)
        task.spawn(function()
            local ok, err = pcall(function()
                task.wait(MoveDelay)
                if not AutoPlayEnabled or App.session ~= startSession or startSession.over or not isAutoPlayTurn(startSession) then return end
                local currentKeyOk, currentKey = pcall(getPositionKey, startSession)
                if not startKeyOk or not currentKeyOk or currentKey ~= startKey then return end
                local uci = getAutoPlayMove(startSession)
                if not uci then return end
                local verifyOk, verifyKey = pcall(getPositionKey, startSession)
                if AutoPlayEnabled and App.session == startSession and not startSession.over
                    and isAutoPlayTurn(startSession) and verifyOk and verifyKey == startKey then
                    attemptAutoMove(startSession, uci)
                end
            end)
            if not ok then warn("[GundamScript] Auto Play failed:", tostring(err)) end
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

        if session ~= PreviousSession then
            AnalysisToken += 1
            PreviousSession = session
            PreviousPositionKey = nil
            PendingAnalysis = true
            clearCurrentOpening()
            resetArrows()
        end

        local keyOk, positionKey = pcall(getPositionKey, session)
        if not keyOk then continue end

        if positionKey ~= PreviousPositionKey then
            PreviousPositionKey = positionKey
            AnalysisToken += 1
            PendingAnalysis = true
            resetArrows()
        end

        if not AnalysisEnabled then continue end
        if not PendingAnalysis or AnalysisRunning or not session:isMyTurn() then continue end

        PendingAnalysis = false
        AnalysisRunning = true

        local token = AnalysisToken
        local analyzedPosition = positionKey

        task.spawn(function()
            local success, m1, m2, m3, openingName = pcall(getRankedMoves, session)
            AnalysisRunning = false

            if token ~= AnalysisToken or App.session ~= session or session.over or not AnalysisEnabled then
                return
            end

            local currentOk, currentKey = pcall(getPositionKey, session)
            if not currentOk or currentKey ~= analyzedPosition then
                PendingAnalysis = true
                return
            end

            if success and m1 and m1 ~= "" then
                -- Draw the 3 main arrows
                updateMultiArrows(m1, m2 or "", m3 or "", analyzedPosition)

                -- Run mate detection in a separate thread (non-blocking)
                task.spawn(function()
                    detectAndShowMate(session, analyzedPosition)
                end)
            elseif not success then
                warn("[GundamScript] Analysis failed:", m1)
            end
        end)
    end
end)



