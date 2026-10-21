plugin = {
    name = "anticheat",
    displayName = "Cheater Detector",
    prefix = "§cAC",
    version = "1.0.0",
    description = "Scans players to detect patterns that can indicate cheating",
    credits = "pugbw, aurevelle",
}

-- Constants

local CHECK_DEFINITIONS = {
    NoSlowA = {
        enabled = true,
        vl = 10,
        cooldown = 2000,
        description = "Moving too fast while eating, drawing a bow or blocking."
    },
    AutoBlockA = {
        enabled = true,
        vl = 10,
        cooldown = 2000,
        description = "Attacking while blocking with a sword."
    },
    EagleA = {
        enabled = true,
        vl = 5,
        cooldown = 2000,
        description = "Diagonal double-shift (legit scaffold) patterns."
    },
    NoBreakDelayA = {
        enabled = true,
        vl = 5,
        cooldown = 2000,
        description = "Breaking blocks faster than the 6-tick break delay."
    }
}

local SWORD_IDS = { [267] = true, [268] = true, [272] = true, [276] = true, [283] = true }
local CONSUMABLE_IDS = {
    [260] = true, [297] = true, [319] = true, [320] = true, [322] = true,
    [335] = true, [349] = true, [350] = true, [354] = true, [357] = true,
    [360] = true, [363] = true, [364] = true, [365] = true, [366] = true,
    [367] = true, [373] = true, [391] = true, [392] = true, [393] = true,
    [394] = true, [396] = true, [400] = true, [411] = true, [412] = true,
    [413] = true, [423] = true, [424] = true
}

local CARDINAL_ANGLES = {0, 90, 180, 270}

local MIN_BREAK_DELAY_MS = 150
local BLOCK_BREAK_EFFECT = 2001
local BREAK_EFFECT_WINDOW_MS = 50

-- Config schema

for checkName, checkDef in pairs(CHECK_DEFINITIONS) do
    starfish.schema.section({
        key = checkName,
        label = checkName,
        description = checkDef.description,
        settings = {
            { key = "checks." .. checkName .. ".enabled", type = "toggle", default = checkDef.enabled, label = "Enabled", description = "Turn this check on or off." },
            { key = "checks." .. checkName .. ".sound", type = "soundToggle", default = true, label = "Sound", description = "Play a sound with this check's alerts." },
            { key = "checks." .. checkName .. ".vl", type = "cycle", default = checkDef.vl, label = "Violation Level", description = "Alert once a player reaches this many violations.", values = {
                { text = "VL: 1", value = 1 },
                { text = "VL: 5", value = 5 },
                { text = "VL: 10", value = 10 },
                { text = "VL: 15", value = 15 },
                { text = "VL: 20", value = 20 },
                { text = "VL: 30", value = 30 }
            }},
            { key = "checks." .. checkName .. ".cooldown", type = "cycle", default = checkDef.cooldown, label = "Cooldown", description = "Wait this long between alerts for one player.", values = {
                { text = "CD: 0s", value = 0 },
                { text = "CD: 1s", value = 1000 },
                { text = "CD: 2s", value = 2000 },
                { text = "CD: 3s", value = 3000 }
            }},
        }
    })
end

-- Check config

local configCache = {}

local function getCheckConfig(checkName)
    local cached = configCache[checkName]
    if cached then return cached end

    cached = {
        enabled = starfish.config.get("checks." .. checkName .. ".enabled"),
        sound = starfish.config.get("checks." .. checkName .. ".sound"),
        vl = starfish.config.get("checks." .. checkName .. ".vl"),
        cooldown = starfish.config.get("checks." .. checkName .. ".cooldown")
    }
    configCache[checkName] = cached
    return cached
end

-- Player state

local playersByUuid = {}
local entityToPlayer = {}
local uuidToName = {}

local function createPlayerData(uuid, name, entityId)
    return {
        uuid = uuid,
        name = name,
        entityId = entityId,

        position = { x = 0, y = 0, z = 0 },
        velocity = { x = 0, y = 0, z = 0 },
        lastPositionData = nil,

        pitch = 0,
        onGround = true,

        isCrouching = false,
        isSprinting = false,
        isUsingItem = false,
        isBlocking = false,
        swingProgress = 0,

        heldItem = nil,

        violations = {},
        lastAlerts = {},

        noSlowData = { startTime = nil, isActive = false },
        swingHistory = {},
        shiftEvents = {},
        blockingStartTime = 0,
        lastSwingDetected = 0,

        breakDelayData = {
            diggingPos = nil,
            releasedPos = nil,
            releasedAt = 0,
            lastHarvestAt = nil,
            breakDelay = nil
        }
    }
end

local function updatePosition(player, x, y, z, onGround, pitch)
    player.position = { x = x, y = y, z = z }
    player.onGround = onGround

    if pitch then player.pitch = pitch end

    local currentTime = starfish.time.monotonic()
    local calculatedVelocity = { x = 0, y = 0, z = 0 }

    if player.lastPositionData then
        local timeDelta = (currentTime - player.lastPositionData.timestamp) / 1000
        if timeDelta > 0 then
            calculatedVelocity = {
                x = (x - player.lastPositionData.position.x) / timeDelta,
                y = (y - player.lastPositionData.position.y) / timeDelta,
                z = (z - player.lastPositionData.position.z) / timeDelta
            }
        end
    end

    player.velocity = calculatedVelocity
    player.lastPositionData = {
        position = { x = x, y = y, z = z },
        timestamp = currentTime
    }
end

local function isSamePosition(a, b)
    return a ~= nil and b ~= nil and a.x == b.x and a.y == b.y and a.z == b.z
end

-- Held item

local function getItemId(player)
    return player.heldItem and player.heldItem.id
end

local function isHoldingSword(player)
    local id = getItemId(player)
    return id and SWORD_IDS[id]
end

local function isHoldingConsumable(player)
    local id = getItemId(player)
    return id and CONSUMABLE_IDS[id]
end

local function isHoldingBow(player)
    return getItemId(player) == 261
end

local function isHoldingBlock(player)
    local id = getItemId(player)
    return id and id < 256
end

-- Violation management

local flagHistory = {}
local flaggedUuids = {}

local function addViolation(player, checkName, amount)
    amount = amount or 1
    player.violations[checkName] = (player.violations[checkName] or 0) + amount
end

local function reduceViolation(player, checkName, amount)
    amount = amount or 1
    local current = player.violations[checkName] or 0
    player.violations[checkName] = math.max(0, current - amount)
end

local function shouldAlert(player, checkName, config)
    local vl = player.violations[checkName] or 0
    local lastAlert = player.lastAlerts[checkName] or 0
    local now = starfish.time.monotonic()
    local hasViolations = vl >= config.vl
    local cooldownPassed = (now - lastAlert) > config.cooldown
    return hasViolations and cooldownPassed
end

local function markAlert(player, checkName)
    player.lastAlerts[checkName] = starfish.time.monotonic()
end

local function recordFlag(name, checkName, vl)
    local checks = flagHistory[name:lower()]
    if not checks then
        checks = {}
        flagHistory[name:lower()] = checks
    end

    local entry = checks[checkName]
    if not entry then
        entry = { count = 0 }
        checks[checkName] = entry
    end
    entry.count = entry.count + 1
    entry.vl = vl
    entry.lastAt = os.time()
end

local function markFlagged(uuid)
    if not uuid or flaggedUuids[uuid] then return end
    flaggedUuids[uuid] = true
    starfish.display.prependPrefix(uuid, "§n")
    starfish.display.appendSuffix(uuid, " §r§c[!]")
end

local function flag(player, checkName, vl)
    local config = getCheckConfig(checkName)

    markAlert(player, checkName)

    local cleanName = player.name
    local cleanPlayer = starfish.players.byName(cleanName)
    local team = cleanPlayer and cleanPlayer.team
    local prefix = team and team.prefix or ""
    local suffix = team and team.suffix or ""
    local displayName = prefix .. cleanName .. suffix

    recordFlag(cleanName, checkName, vl)
    markFlagged(player.uuid)
    starfish.events.emit("anticheat:flag", { name = cleanName, check = checkName, vl = vl })

    starfish.log.debug("Flagging " .. displayName .. " for " .. checkName .. " (VL: " .. vl .. ")")

    local message = displayName .. " §7flagged §5" .. checkName .. " §8(§7VL: " .. vl .. "§8)"
    starfish.chat.info(message)

    if config.sound then
        starfish.client.world.playSound("note.pling", { volume = 1.0, pitch = 1.0 })
    end
end

-- Checks

local function checkNoSlowA(player)
    local config = getCheckConfig("NoSlowA")
    if not config.enabled then return end

    local now = starfish.time.monotonic()
    local isUsingSlowdownItem = player.isUsingItem and (
        isHoldingConsumable(player) or
        isHoldingBow(player) or
        isHoldingSword(player)
    )

    local isCurrentlyNoSlow = isUsingSlowdownItem and player.isSprinting

    if isCurrentlyNoSlow then
        if not player.noSlowData.isActive then
            player.noSlowData.startTime = now
            player.noSlowData.isActive = true
        end

        local duration = now - player.noSlowData.startTime
        if duration >= 500 then
            addViolation(player, "NoSlowA", 2)
            if shouldAlert(player, "NoSlowA", config) then
                flag(player, "NoSlowA", player.violations.NoSlowA)
            end
        end
    else
        player.noSlowData.isActive = false
        player.noSlowData.startTime = nil
        reduceViolation(player, "NoSlowA")
    end
end

local function checkAutoBlockA(player)
    local config = getCheckConfig("AutoBlockA")
    if not config.enabled then return end

    local now = starfish.time.monotonic()
    local isSwordHeld = isHoldingSword(player)
    local isSwinging = player.swingProgress > 0

    if isSwinging and (not player.lastSwingDetected or now - player.lastSwingDetected > 100) then
        local hasBeenBlockingLongEnough = player.isBlocking and
            player.blockingStartTime > 0 and
            (now - player.blockingStartTime >= 150)

        table.insert(player.swingHistory, {
            time = now,
            wasBlockingBefore = hasBeenBlockingLongEnough,
            wasBlockingAfter = nil
        })
        player.lastSwingDetected = now

        while #player.swingHistory > 20 do
            table.remove(player.swingHistory, 1)
        end
    end

    for _, swing in ipairs(player.swingHistory) do
        if swing.wasBlockingAfter == nil then
            local timeSinceSwing = now - swing.time
            if timeSinceSwing >= 150 and timeSinceSwing <= 200 then
                swing.wasBlockingAfter = player.isBlocking
            elseif timeSinceSwing > 200 then
                swing.wasBlockingAfter = false
            end
        end
    end

    local autoBlockCount = 0
    for _, swing in ipairs(player.swingHistory) do
        if now - swing.time < 1000 and swing.wasBlockingAfter ~= nil and isSwordHeld then
            if swing.wasBlockingBefore and swing.wasBlockingAfter then
                autoBlockCount = autoBlockCount + 1
            end
        end
    end

    if autoBlockCount >= 2 then
        addViolation(player, "AutoBlockA")
        if shouldAlert(player, "AutoBlockA", config) then
            flag(player, "AutoBlockA", player.violations.AutoBlockA)
        end
    else
        reduceViolation(player, "AutoBlockA")
    end
end

local function checkEagleA(player)
    local config = getCheckConfig("EagleA")
    if not config.enabled then return end

    local isLookingDown = player.pitch >= 30
    local isOnGround = player.onGround
    local isSwingingBlock = player.swingProgress > 0 and isHoldingBlock(player)

    local horizontalSpeed = math.sqrt(player.velocity.x * player.velocity.x + player.velocity.z * player.velocity.z)
    local isMovingFast = horizontalSpeed > 2.0

    local movementAngle = math.atan(player.velocity.z, player.velocity.x) * 180 / math.pi
    if movementAngle < 0 then movementAngle = movementAngle + 360 end
    local isMovingStraight = false
    for _, angle in ipairs(CARDINAL_ANGLES) do
        if math.abs(movementAngle - angle) <= 15 or math.abs(movementAngle - angle - 360) <= 15 then
            isMovingStraight = true
            break
        end
    end
    local isMovingDiagonal = not isMovingStraight and horizontalSpeed > 0.1

    local now = starfish.time.monotonic()
    local shiftCount = 0
    for _, event in ipairs(player.shiftEvents) do
        if now - event.timestamp < 2000 and event.eventType == "start" then
            shiftCount = shiftCount + 1
        end
    end
    local hasExcessiveShifts = shiftCount > 6 and horizontalSpeed > 2.5

    local isEagle = isLookingDown and isOnGround and isSwingingBlock and
                    isMovingDiagonal and isMovingFast and hasExcessiveShifts

    if isEagle then
        addViolation(player, "EagleA", 3)
        if shouldAlert(player, "EagleA", config) then
            flag(player, "EagleA", player.violations.EagleA)
        end
    else
        reduceViolation(player, "EagleA", 3)
    end
end

local function checkNoBreakDelayA(player)
    local config = getCheckConfig("NoBreakDelayA")
    if not config.enabled then return end

    local data = player.breakDelayData
    local breakDelay = data.breakDelay
    if not breakDelay then return end
    data.breakDelay = nil

    if breakDelay < MIN_BREAK_DELAY_MS then
        addViolation(player, "NoBreakDelayA")
        if shouldAlert(player, "NoBreakDelayA", config) then
            flag(player, "NoBreakDelayA", player.violations.NoBreakDelayA)
        end
    else
        reduceViolation(player, "NoBreakDelayA")
    end
end

local function runChecks(player)
    checkNoSlowA(player)
    checkAutoBlockA(player)
    checkEagleA(player)
    checkNoBreakDelayA(player)
end

-- Player tracking

local function getOrCreatePlayer(uuid, name, entityId)
    local player = playersByUuid[uuid]

    if not player then
        player = createPlayerData(uuid, name, entityId)
        playersByUuid[uuid] = player
        entityToPlayer[entityId] = player
    elseif player.entityId ~= entityId then
        entityToPlayer[player.entityId] = nil
        player.entityId = entityId
        entityToPlayer[entityId] = player
    end

    return player
end

local function resolvePlayerName(uuid)
    local name = uuidToName[uuid]
    if name then return name end
    local info = starfish.players.byUuid(uuid)
    return (info and info.name) or "Unknown"
end

local function isMe(entity)
    local me = starfish.players.me()
    return me ~= nil and entity.entityId == me.entityId
end

local function isOtherPlayer(entity)
    return entity ~= nil and entity.type == "player" and entity.uuid ~= nil and not isMe(entity)
end

local function trackEntityPlayer(entityId, uuid)
    local player = playersByUuid[uuid]
    if player and player.entityId == entityId then
        return player
    end

    return getOrCreatePlayer(uuid, resolvePlayerName(uuid), entityId)
end

local function findHarvester(pos)
    for _, player in pairs(playersByUuid) do
        local data = player.breakDelayData
        if isSamePosition(data.releasedPos, pos) and starfish.time.since(data.releasedAt) <= BREAK_EFFECT_WINDOW_MS then
            return player
        end
    end
end

local function forgetPlayer(uuid)
    if flaggedUuids[uuid] then
        starfish.display.clearPrefix(uuid)
        starfish.display.clearSuffix(uuid)
        flaggedUuids[uuid] = nil
    end

    local player = playersByUuid[uuid]
    if player then
        playersByUuid[uuid] = nil
        entityToPlayer[player.entityId] = nil
    end
end

local function clearFlaggedDisplays()
    for uuid in pairs(flaggedUuids) do
        starfish.display.clearPrefix(uuid)
        starfish.display.clearSuffix(uuid)
    end
    flaggedUuids = {}
end

local function reset()
    playersByUuid = {}
    entityToPlayer = {}
    uuidToName = {}
    flagHistory = {}
    clearFlaggedDisplays()
    starfish.log.debug("Anticheat: Cleared all tracked player data")
end

-- Player events

local function onEntityMove(event)
    if not isOtherPlayer(event.entity) then return end

    local player = trackEntityPlayer(event.entity.entityId, event.entity.uuid)

    if event.position then
        updatePosition(player,
            event.position.x,
            event.position.y,
            event.position.z,
            true,
            event.rotation and event.rotation.pitch
        )
    elseif event.delta then
        local newX = player.position.x + event.delta.x
        local newY = player.position.y + event.delta.y
        local newZ = player.position.z + event.delta.z
        updatePosition(player, newX, newY, newZ,
            event.onGround ~= nil and event.onGround or player.onGround,
            event.rotation and event.rotation.pitch
        )
    end

    runChecks(player)
end

local function onEntityStateChange(event)
    if event.entity.kind ~= "minecraft:player" then return end

    local player = entityToPlayer[event.entity.id]
    if not player and event.entity.uuid then
        player = trackEntityPlayer(event.entity.id, event.entity.uuid)
    end
    if not player then return end

    local now = starfish.time.monotonic()

    if event.changed.sneaking then
        local wasCrouching = player.isCrouching
        player.isCrouching = event.state.sneaking

        if player.isCrouching ~= wasCrouching then
            table.insert(player.shiftEvents, {
                eventType = player.isCrouching and "start" or "stop",
                timestamp = now
            })
            if #player.shiftEvents > 50 then
                table.remove(player.shiftEvents, 1)
            end
        end
    end

    if event.changed.sprinting then
        player.isSprinting = event.state.sprinting
    end

    if event.changed.usingItem then
        local wasUsingItem = player.isUsingItem
        player.isUsingItem = event.state.usingItem

        if player.isUsingItem and not wasUsingItem and isHoldingSword(player) then
            player.isBlocking = true
            player.blockingStartTime = now
        elseif not player.isUsingItem and wasUsingItem then
            player.isBlocking = false
        end
    end

    runChecks(player)
end

local function onEntityAnimation(event)
    if not isOtherPlayer(event.entity) then return end

    local player = trackEntityPlayer(event.entity.entityId, event.entity.uuid)
    if event.animation == 0 then
        player.swingProgress = 6
    end

    runChecks(player)
end

local function onEquipmentChange(event)
    if not event.entity or not event.isPlayer then return end

    local player = entityToPlayer[event.entity.entityId]
    if player and event.slot == "held" then
        player.heldItem = event.item
    end
end

local function onPlayerListUpdate(event)
    if event.action == "remove" then
        for _, update in ipairs(event.players) do
            forgetPlayer(update.uuid)
        end
        return
    end

    for _, update in ipairs(event.players) do
        if update.name then
            uuidToName[update.uuid] = update.name
        end
    end
end

local function onEntitySpawn(event)
    if event.kind ~= "player" then return end

    local player = getOrCreatePlayer(event.uuid, uuidToName[event.uuid] or "Unknown", event.entityId)
    updatePosition(player, event.x, event.y, event.z, false)
    player.pitch = event.pitch
end

local function onEntityDespawn(event)
    for _, entityId in ipairs(event.entityIds) do
        local player = entityToPlayer[entityId]
        if player then
            playersByUuid[player.uuid] = nil
            entityToPlayer[entityId] = nil
        end
    end
end

local function onBlockBreakAnimation(event)
    local player = entityToPlayer[event.entityId]
    if not player then return end

    local data = player.breakDelayData
    local pos = { x = event.x, y = event.y, z = event.z }

    if event.destroyStage < 0 then
        data.diggingPos = nil
        data.releasedPos = pos
        data.releasedAt = starfish.time.monotonic()
    elseif not isSamePosition(pos, data.diggingPos) then
        data.diggingPos = pos
        if data.lastHarvestAt then
            data.breakDelay = starfish.time.since(data.lastHarvestAt)
            data.lastHarvestAt = nil
        end
    end

    runChecks(player)
end

local function onWorldEffect(event)
    if event.effectId ~= BLOCK_BREAK_EFFECT then return end

    local harvester = findHarvester(event.position)
    if not harvester then return end

    harvester.breakDelayData.releasedPos = nil
    harvester.breakDelayData.lastHarvestAt = starfish.time.monotonic()
end

local function decaySwings()
    for _, player in pairs(playersByUuid) do
        if player.swingProgress > 0 then
            player.swingProgress = player.swingProgress - 1
        end
    end
end

-- Event wiring

starfish.entities.onMove(onEntityMove)
starfish.entities.onStateChange(onEntityStateChange)
starfish.entities.onSpawn(onEntitySpawn)
starfish.entities.onDespawn(onEntityDespawn)
starfish.entities.onEquipmentChange(onEquipmentChange)
starfish.events.on("entity:animation", onEntityAnimation)
starfish.events.on("player:listUpdate", onPlayerListUpdate)
starfish.events.on("world:blockBreakAnimation", onBlockBreakAnimation)
starfish.events.on("world:effect", onWorldEffect)
starfish.events.on("world:respawn", reset)
starfish.events.on("config:changed", function() configCache = {} end)
starfish.timers.everyTick(decaySwings)

-- Exports

starfish.plugin.export("getFlags", function(name)
    if not name then return nil end
    local checks = flagHistory[name:lower()]
    if not checks then return nil end

    local result = {}
    for check, entry in pairs(checks) do
        table.insert(result, { check = check, count = entry.count, vl = entry.vl, lastAt = entry.lastAt })
    end
    table.sort(result, function(a, b) return a.count > b.count end)
    return result
end)
