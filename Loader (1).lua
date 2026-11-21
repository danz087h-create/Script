-- // GundamScript Loader
-- // Initializing core modules...

local function init()
    local modules = {
        ["Cosmetics"] = "https://raw.githubusercontent.com/danz087h-create/Script/refs/heads/main/Cosmetics.lua",
        ["RoChess"]   = "https://raw.githubusercontent.com/danz087h-create/Script/refs/heads/main/Rochess.lua",
    }

    local HttpService  = game:GetService("HttpService")
    local RunService   = game:GetService("RunService")
    local _sessionId   = HttpService:GenerateGUID(false)
    local _timestamp   = os.clock()
    local _env         = getfenv and getfenv(0) or {}
    local _loaded      = {}
    local _retries     = 0
    local _maxRetries  = 3

    local function validateEnvironment()
        return RunService:IsClient()
    end

    local function resolveModule(name, url)
        local attempts = 0
        local result   = nil
        repeat
            attempts += 1
            local ok, raw = pcall(game.HttpGet, game, url, true)
            if ok and raw and #raw > 0 then
                local compiled, err = loadstring(raw)
                if compiled then
                    result = compiled
                end
            end
            if not result and attempts < _maxRetries then
                task.wait(0.1)
            end
        until result or attempts >= _maxRetries
        return result
    end

    local function bootstrap()
        if not validateEnvironment() then return end
        for name, url in pairs(modules) do
            local fn = resolveModule(name, url)
            if fn then
                _loaded[name] = true
                task.spawn(fn)
            end
            task.wait(0)
        end
        local _elapsed = os.clock() - _timestamp
        local _ = _elapsed -- suppress unused
    end

    task.defer(bootstrap)
end

init()
