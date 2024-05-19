-- Initializing global variables to store the latest game state and game host process.
latestGameState = latestGameState or nil
inAction = inAction or false -- Prevents the agent from taking multiple actions at once.
logs = logs or {}

local colors = {
    red = "\27[31m",
    green = "\27[32m",
    blue = "\27[34m",
    reset = "\27[0m",
    gray = "\27[90m"
}

local function addLog(message, text)
    logs[message] = logs[message] or {}
    table.insert(logs[message], text)
end

local function inRange(x1, y1, x2, y2, range)
    return math.abs(x1 - x2) <= range and math.abs(y1 - y2) <= range
end

local function findNearestPlayers(numPlayers)
    local me = latestGameState.Players[ao.id]
    local players = {}

    for id, state in pairs(latestGameState.Players) do
        if id ~= ao.id then
            table.insert(players, {
                id = id,
                x = state.x,
                y = state.y,
                energy = state.energy,
                health = state.health
            })
        end
    end

    table.sort(players, function(a, b)
        local distA = (me.x - a.x)^2 + (me.y - a.y)^2
        local distB = (me.x - b.x)^2 + (me.y - b.y)^2
        return distA < distB
    end)

    local nearestPlayers = {}
    for i = 1, math.min(numPlayers, #players) do
        table.insert(nearestPlayers, players[i])
    end

    return nearestPlayers
end

local function normalizeVector(vector)
    local length = math.sqrt(vector.x * vector.x + vector.y * vector.y)
    return { x = vector.x / length, y = vector.y / length }
end

local function calculateDirection(from, to)
    return normalizeVector({ x = to.x - from.x, y = to.y - from.y })
end

local function retreatDirection()
    local me = latestGameState.Players[ao.id]
    local direction = { x = 0, y = 0 }

    for id, state in pairs(latestGameState.Players) do
        if id ~= ao.id then
            local avoidVector = { x = me.x - state.x, y = me.y - state.y }
            direction.x = direction.x + avoidVector.x
            direction.y = direction.y + avoidVector.y
        end
    end

    return normalizeVector(direction)
end

local function isPlayerInAttackRange(player)
    local me = latestGameState.Players[ao.id]
    return inRange(me.x, me.y, player.x, player.y, 1)
end

local function decideNextAction()
    local me = latestGameState.Players[ao.id]
    local nearestPlayers = findNearestPlayers(3)

    -- Health check and retreat if necessary
    if me.health < 30 then
        print(colors.red .. "Low health! Retreating..." .. colors.reset)
        local retreatDir = retreatDirection()
        ao.send({ Target = Game, Action = "PlayerMove", Player = ao.id, Direction = retreatDir })
        inAction = false
        return
    end

    -- If attacked, find the attacker and decide whether to attack back or retreat
    for _, player in ipairs(nearestPlayers) do
        if player.targetPlayer == ao.id then
            print(colors.red .. "Under attack! Deciding response..." .. colors.reset)
            if me.energy > player.energy then
                print(colors.red .. "Attacking back..." .. colors.reset)
                ao.send({ Target = Game, Action = "PlayerAttack", Player = ao.id, TargetPlayer = player.id, AttackEnergy = tostring(me.energy) })
            else
                print(colors.red .. "Retreating from attacker..." .. colors.reset)
                local retreatDir = retreatDirection()
                ao.send({ Target = Game, Action = "PlayerMove", Player = ao.id, Direction = retreatDir })
            end
            inAction = false
            return
        end
    end

    -- If no immediate threat, find and approach the nearest weaker player
    for _, player in ipairs(nearestPlayers) do
        if me.energy > player.energy and me.health > player.health then
            if isPlayerInAttackRange(player) then
                print(colors.green .. "Attacking weaker player..." .. colors.reset)
                ao.send({ Target = Game, Action = "PlayerAttack", Player = ao.id, TargetPlayer = player.id, AttackEnergy = tostring(me.energy) })
            else
                print(colors.blue .. "Approaching weaker player..." .. colors.reset)
                local approachDir = calculateDirection(me, player)
                ao.send({ Target = Game, Action = "PlayerMove", Player = ao.id, Direction = approachDir })
            end
            inAction = false
            return
        end
    end

    -- Default action: move randomly
    local randomDirection = { x = math.random(-1, 1), y = math.random(-1, 1) }
    print(colors.gray .. "No immediate actions. Moving randomly..." .. colors.reset)
    ao.send({ Target = Game, Action = "PlayerMove", Player = ao.id, Direction = normalizeVector(randomDirection) })
    inAction = false
end

-- Handler to update the game state upon receiving game state information.
Handlers.add(
    "UpdateGameState",
    Handlers.utils.hasMatchingTag("Action", "GameState"),
    function(msg)
        local json = require("json")
        latestGameState = json.decode(msg.Data)
        ao.send({ Target = ao.id, Action = "UpdatedGameState" })
    end
)

-- Handler to decide the next best action.
Handlers.add(
    "DecideNextAction",
    Handlers.utils.hasMatchingTag("Action", "UpdatedGameState"),
    function()
        if latestGameState.GameMode ~= "Playing" then
            print("Game not started.")
            inAction = false
            return
        end
        print("Deciding next action.")
        decideNextAction()
        ao.send({ Target = ao.id, Action = "Tick" })
    end
)

-- Handler to print game announcements and trigger game state updates.
Handlers.add(
    "PrintAnnouncements",
    Handlers.utils.hasMatchingTag("Action", "Announcement"),
    function(msg)
        if msg.Event == "Started-Waiting-Period" then
            ao.send({ Target = ao.id, Action = "AutoPay" })
        elseif (msg.Event == "Tick" or msg.Event == "Started-Game") and not inAction then
            inAction = true
            ao.send({ Target = Game, Action = "GetGameState" })
        elseif inAction then
            print("Previous action still in progress. Skipping.")
        end
        print(colors.green .. msg.Event .. ": " .. msg.Data .. colors.reset)
    end
)

-- Handler to trigger game state updates.
Handlers.add(
    "GetGameStateOnTick",
    Handlers.utils.hasMatchingTag("Action", "Tick"),
    function()
        if not inAction then
            inAction = true
            print(colors.gray .. "Getting game state..." .. colors.reset)
            ao.send({ Target = Game, Action = "GetGameState" })
        else
            print("Previous action still in progress. Skipping.")
        end
    end
)

-- Handler to automate payment confirmation when waiting period starts.
Handlers.add(
    "AutoPay",
    Handlers.utils.hasMatchingTag("Action", "AutoPay"),
    function(msg)
        print("Auto-paying confirmation fees.")
        ao.send({ Target = Game, Action = "Transfer", Recipient = Game, Quantity = "1000" })
    end
)

-- Handler to automatically attack when hit by another player.
Handlers.add(
    "ReturnAttack",
    Handlers.utils.hasMatchingTag("Action", "Hit"),
    function(msg)
        if not inAction then
            inAction = true
            local playerEnergy = latestGameState.Players[ao.id].energy
            if not playerEnergy then
                print(colors.red .. "Unable to read energy." .. colors.reset)
                ao.send({ Target = Game, Action = "Attack-Failed", Reason = "Unable to read energy." })
            elseif playerEnergy == 0 then
                print(colors.red .. "Player has insufficient energy." .. colors.reset)
                ao.send({ Target = Game, Action = "Attack-Failed", Reason = "Player has no energy." })
            else
                print(colors.red .. "Returning attack." .. colors.reset)
                ao.send({ Target = Game, Action = "PlayerAttack", Player = ao.id, AttackEnergy = tostring(playerEnergy) })
            end
            inAction = false
            ao.send({ Target = ao.id, Action = "Tick" })
        else
            print("Previous action still in progress. Skipping.")
        end
    end
)
