-- Anticheat Plugin
-- Detects potential cheaters on Hypixel
-- Adapted from Pug's Custom Anticheat Raven script (github.com/PugrillaDev)

plugin = {
    name = "anticheat",
    displayName = "Cheater Detector",
    prefix = "§cAC",
    version = "0.3.0",
    author = "Hexze",
    description = [[
Monitors players in your game and flags patterns to identify likely cheaters.]]
}

-- Check definitions with defaults
local CHECK_DEFINITIONS = {
    NoSlowA = {
        enabled = true,
        vl = 10,
        cooldown = 2000,
        description = "Detects moving too fast while using items that should slow you down (eating food, drawing bow, blocking sword)."
    },
    AutoBlockA = {
        enabled = true,
        vl = 10,
        cooldown = 2000,
        description = "Detects attacking while blocking with a sword."
    },
    EagleA = {
        enabled = true,
        vl = 5,
        cooldown = 2000,
        description = "Detects diagonal double-shifting eagle (legit scaffold) patterns."
    },
    ScaffoldA = {
        enabled = false,
        vl = 15,
        cooldown = 2000,
        description = "Detects fast flat scaffold with no vertical movement"
    },
    ScaffoldB = {
        enabled = true,
        vl = 10,
        cooldown = 2000,
        description = "Detects moving faster than walking speed while looking backwards and placing blocks."
    },
    TowerA = {
        enabled = false,
        vl = 10,
        cooldown = 2000,
        description = "Detects ascending (towering) faster than normal while placing blocks below."
    },
    LagRangeA = {
        enabled = false,
        vl = 5,
        cooldown = 2000,
        description = "Detects sudden large position changes (blinking)."
    },
    NoBreakDelayA = {
        enabled = true,
        vl = 10,
        cooldown = 2000,
        description = "Detects breaking blocks faster than the 6-tick delay allows (bypassing break delay)."
    }
}

-- Config helper: config.get auto-returns schema defaults when no value is stored
local function getCheckConfig(checkName)
    local def = CHECK_DEFINITIONS[checkName]
    if not def then return nil end

    return {
        enabled = starfish.config.get("checks." .. checkName .. ".enabled"),
        sound = starfish.config.get("checks." .. checkName .. ".sound"),
        vl = starfish.config.get("checks." .. checkName .. ".vl"),
        cooldown = starfish.config.get("checks." .. checkName .. ".cooldown"),
        description = def.description
    }
end

-- Register config schema
for checkName, checkDef in pairs(CHECK_DEFINITIONS) do
    starfish.schema.section({
        key = checkName,
        label = checkName,
        settings = {
            { key = "checks." .. checkName .. ".enabled", type = "toggle", default = checkDef.enabled, description = checkDef.description },
            { key = "checks." .. checkName .. ".sound", type = "soundToggle", default = true, description = "Toggles sound alerts for this check." },
            { key = "checks." .. checkName .. ".vl", type = "cycle", default = checkDef.vl, description = "Sets the violation level to trigger an alert.", values = {
                { text = "VL: 1", value = 1 },
                { text = "VL: 5", value = 5 },
                { text = "VL: 10", value = 10 },
                { text = "VL: 15", value = 15 },
                { text = "VL: 20", value = 20 },
                { text = "VL: 30", value = 30 }
            }},
            { key = "checks." .. checkName .. ".cooldown", type = "cycle", default = checkDef.cooldown, description = "Sets the cooldown between alerts for this check.", values = {
                { text = "CD: 0s", value = 0 },
                { text = "CD: 1s", value = 1000 },
                { text = "CD: 2s", value = 2000 },
                { text = "CD: 3s", value = 3000 }
            }},
        }
    })
end

-- Player tracking
local players = {}
local playersByUuid = {}
local entityToPlayer = {}
local uuidToName = {}
local uuidToDisplayName = {}

-- Tick counter for time tracking
local currentTick = 0

-- Item IDs
local SWORD_IDS = { [267] = true, [268] = true, [272] = true, [276] = true, [283] = true }
local CONSUMABLE_IDS = {
    [260] = true, [297] = true, [319] = true, [320] = true, [322] = true,
    [335] = true, [349] = true, [350] = true, [354] = true, [357] = true,
    [360] = true, [363] = true, [364] = true, [365] = true, [366] = true,
    [367] = true, [373] = true, [391] = true, [392] = true, [393] = true,
    [394] = true, [396] = true, [400] = true, [411] = true, [412] = true,
    [413] = true, [423] = true, [424] = true
}

-- Helper to get current time in ms
local function getTime()
    return os.clock() * 1000
end

-- Create player data object
local function createPlayerData(uuid, name, entityId)
    return {
        uuid = uuid,
        name = name,
        displayName = name,
        entityId = entityId or -1,

        position = { x = 0, y = 0, z = 0 },
        lastPosition = { x = 0, y = 0, z = 0 },
        velocity = { x = 0, y = 0, z = 0 },
        lastPositionData = nil,

        yaw = 0,
        pitch = 0,
        onGround = true,
        lastOnGround = true,

        isCrouching = false,
        lastCrouching = false,
        isSprinting = false,
        isUsingItem = false,
        isBlocking = false,
        swingProgress = 0,

        lastSwingTime = 0,
        lastCrouchTime = 0,
        lastStopCrouchTime = 0,
        currentShiftStart = nil,

        heldItem = nil,
        hasJumpBoost = false,
        lastDamaged = 0,

        violations = {},
        lastAlerts = {},

        noSlowData = { startTime = nil, isActive = false },
        swingHistory = {},
        shiftEvents = {},
        towerData = { heightHistory = {}, lastReset = 0 },
        blockingStartTime = 0,
        lastSwingDetected = 0,
        lastSwingItem = nil,

        lastSprinting = false,
        lastUsing = false,

        lastPauseInMovement = nil,
        lastLag = nil,

        breakDelayData = {
            lastBreakFinishTick = 0,
            lastStartTick = 0,
            breakHistory = {},
            currentBreakPos = nil,
            lastFinishedPos = nil
        }
    }
end

-- Helper functions
local function getItemId(player)
    if not player.heldItem then return nil end
    return player.heldItem.blockId or player.heldItem.itemId or player.heldItem.id
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

local NON_SOLID_BLOCKS = {
    [0] = true,    -- Air
    [6] = true,    -- Sapling
    [8] = true,    -- Water
    [9] = true,    -- Stationary water
    [10] = true,   -- Lava
    [11] = true,   -- Stationary lava
    [27] = true,   -- Powered rail
    [28] = true,   -- Detector rail
    [30] = true,   -- Cobweb
    [31] = true,   -- Tall grass
    [32] = true,   -- Dead bush
    [37] = true,   -- Dandelion
    [38] = true,   -- Poppy
    [39] = true,   -- Brown mushroom
    [40] = true,   -- Red mushroom
    [50] = true,   -- Torch
    [51] = true,   -- Fire
    [55] = true,   -- Redstone wire
    [59] = true,   -- Wheat crops
    [63] = true,   -- Standing sign
    [65] = true,   -- Ladder
    [66] = true,   -- Rail
    [68] = true,   -- Wall sign
    [69] = true,   -- Lever
    [70] = true,   -- Stone pressure plate
    [72] = true,   -- Wood pressure plate
    [75] = true,   -- Redstone torch off
    [76] = true,   -- Redstone torch on
    [77] = true,   -- Stone button
    [78] = true,   -- Snow layer
    [83] = true,   -- Sugar cane
    [90] = true,   -- Nether portal
    [93] = true,   -- Repeater off
    [94] = true,   -- Repeater on
    [104] = true,  -- Pumpkin stem
    [105] = true,  -- Melon stem
    [106] = true,  -- Vines
    [111] = true,  -- Lily pad
    [115] = true,  -- Nether wart
    [119] = true,  -- End portal
    [131] = true,  -- Tripwire hook
    [132] = true,  -- Tripwire
    [141] = true,  -- Carrots
    [142] = true,  -- Potatoes
    [143] = true,  -- Wood button
    [147] = true,  -- Light weighted pressure plate
    [148] = true,  -- Heavy weighted pressure plate
    [149] = true,  -- Comparator off
    [150] = true,  -- Comparator on
    [157] = true,  -- Activator rail
    [171] = true,  -- Carpet
    [175] = true,  -- Double plant
    [176] = true,  -- Standing banner
    [177] = true,  -- Wall banner
}

local function isBlockSolid(blockId)
    if blockId == nil then return false end
    return not NON_SOLID_BLOCKS[blockId]
end

local function rayTraceBlocks(x1, y1, z1, x2, y2, z2)
    local dx = x2 - x1
    local dy = y2 - y1
    local dz = z2 - z1
    local distance = math.sqrt(dx * dx + dy * dy + dz * dz)

    if distance < 0.1 then return false end

    local steps = math.ceil(distance * 4)
    local stepX = dx / steps
    local stepY = dy / steps
    local stepZ = dz / steps

    local lastBlockX, lastBlockY, lastBlockZ = nil, nil, nil

    for i = 1, steps - 1 do
        local x = x1 + stepX * i
        local y = y1 + stepY * i
        local z = z1 + stepZ * i

        local blockX = math.floor(x)
        local blockY = math.floor(y)
        local blockZ = math.floor(z)

        if blockX ~= lastBlockX or blockY ~= lastBlockY or blockZ ~= lastBlockZ then
            local block = starfish.world.getBlock(blockX, blockY, blockZ)
            if block and isBlockSolid(block.id) then
                return true
            end
            lastBlockX, lastBlockY, lastBlockZ = blockX, blockY, blockZ
        end
    end

    return false
end

local function normalizeYaw(yaw)
    yaw = yaw % 360
    if yaw > 180 then yaw = yaw - 360 end
    if yaw < 180 then yaw = yaw + 360 end
    return yaw
end

-- Update player position and calculate velocity
local function updatePosition(player, x, y, z, onGround, yaw, pitch)
    player.lastPosition = { x = player.position.x, y = player.position.y, z = player.position.z }
    player.position = { x = x, y = y, z = z }
    player.onGround = onGround

    if yaw then player.yaw = yaw end
    if pitch then player.pitch = pitch end

    local currentTime = getTime()
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
    player.lastOnGround = onGround
end

-- Violation management
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
    local now = getTime()
    local hasViolations = vl >= config.vl
    local cooldownPassed = (now - lastAlert) > config.cooldown
    return hasViolations and cooldownPassed
end

local function markAlert(player, checkName)
    player.lastAlerts[checkName] = getTime()
end

-- Flag a player
local function flag(player, checkName, vl)
    local config = getCheckConfig(checkName)
    if not config or not config.enabled then return end

    -- Mark the alert FIRST to prevent spam from rapid events
    markAlert(player, checkName)

    local cleanName = player.name or player.displayName or "Unknown"
    local team = starfish.players.getTeam(cleanName)
    local prefix = team and team.prefix or ""
    local suffix = team and team.suffix or ""
    local displayName = prefix .. cleanName .. suffix

    starfish.debug("Flagging " .. displayName .. " for " .. checkName .. " (VL: " .. vl .. ")")

    local message = displayName .. " §7flagged §5" .. checkName .. " §8(§7VL: " .. vl .. "§8)"
    starfish.chat.send(starfish.chat.prefix(message))

    if config.sound then
        starfish.chat.sound("note.pling", 1.0, 1.0)
    end
end

-- Check: NoSlowA
local function checkNoSlowA(player)
    local config = getCheckConfig("NoSlowA")
    if not config or not config.enabled then return end

    local now = getTime()
    local isUsingSlowdownItem = player.isUsingItem and (
        isHoldingConsumable(player) or
        isHoldingBow(player) or
        (isHoldingSword(player) and player.isUsingItem)
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

-- Check: AutoBlockA
local function checkAutoBlockA(player)
    local config = getCheckConfig("AutoBlockA")
    if not config or not config.enabled then return end

    local now = getTime()
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

-- Check: EagleA
local function checkEagleA(player)
    local config = getCheckConfig("EagleA")
    if not config or not config.enabled then return end

    local isLookingDown = player.pitch >= 30
    local isOnGround = player.onGround
    local isSwingingBlock = player.swingProgress > 0 and isHoldingBlock(player)

    local horizontalSpeed = math.sqrt(player.velocity.x * player.velocity.x + player.velocity.z * player.velocity.z)
    local isMovingFast = horizontalSpeed > 2.0

    local movementAngle = math.atan(player.velocity.z, player.velocity.x) * 180 / math.pi
    if movementAngle < 0 then movementAngle = movementAngle + 360 end
    local cardinalAngles = {0, 90, 180, 270}
    local isMovingStraight = false
    for _, angle in ipairs(cardinalAngles) do
        if math.abs(movementAngle - angle) <= 15 or math.abs(movementAngle - angle - 360) <= 15 then
            isMovingStraight = true
            break
        end
    end
    local isMovingDiagonal = not isMovingStraight and horizontalSpeed > 0.1

    local now = getTime()
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

-- Check: ScaffoldA
local function checkScaffoldA(player)
    local config = getCheckConfig("ScaffoldA")
    if not config or not config.enabled then return end

    local horizontalSpeed = math.sqrt(player.velocity.x * player.velocity.x + player.velocity.z * player.velocity.z)

    if player.position.y > 100 then
        reduceViolation(player, "ScaffoldA")
        return
    end

    local isLookingDown = player.pitch >= 25
    local isPlacingBlocks = player.swingProgress > 0 and isHoldingBlock(player)
    local isMovingFast = horizontalSpeed > 5.0
    local isNotSneaking = not player.isCrouching
    local isFlat = math.abs(player.velocity.y) < 0.1

    local isScaffold = isLookingDown and isPlacingBlocks and isMovingFast and isNotSneaking and isFlat

    if isScaffold then
        addViolation(player, "ScaffoldA", 1)
        if shouldAlert(player, "ScaffoldA", config) then
            flag(player, "ScaffoldA", player.violations.ScaffoldA)
        end
    else
        reduceViolation(player, "ScaffoldA")
    end
end

-- Check: ScaffoldB
local function checkScaffoldB(player)
    local config = getCheckConfig("ScaffoldB")
    if not config or not config.enabled then return end

    local now = getTime()
    local horizontalSpeed = math.sqrt(player.velocity.x * player.velocity.x + player.velocity.z * player.velocity.z)

    local isPlacingBlocks = player.swingProgress > 0 and isHoldingBlock(player)
    local isLookingDown = player.pitch >= 50
    local isSneaking = player.isCrouching
    local hasRecentDamage = player.lastDamaged > 0 and (now - player.lastDamaged) < 1000

    local movementYaw = normalizeYaw(math.deg(math.atan(-player.velocity.x, player.velocity.z)))
    local playerYaw = normalizeYaw(player.yaw)
    local yawDifference = math.abs((movementYaw - playerYaw + 180) % 360 - 180)
    local isLookingBackwards = yawDifference >= 150

    local isScaffold = isLookingBackwards and isLookingDown and horizontalSpeed > 6.2 and isPlacingBlocks and not isSneaking and not hasRecentDamage

    if isScaffold then
        addViolation(player, "ScaffoldB", 2)
        if shouldAlert(player, "ScaffoldB", config) then
            flag(player, "ScaffoldB", player.violations.ScaffoldB)
        end
    else
        reduceViolation(player, "ScaffoldB")
    end
end

-- Check: TowerA
local function checkTowerA(player)
    local config = getCheckConfig("TowerA")
    if not config or not config.enabled then return end

    local now = getTime()
    local verticalSpeed = player.velocity.y
    local horizontalSpeed = math.sqrt(player.velocity.x * player.velocity.x + player.velocity.z * player.velocity.z)

    local isLookingDown = player.pitch >= 30
    local isSwingingBlock = player.swingProgress > 0 and isHoldingBlock(player)
    local hasNoJumpBoost = not player.hasJumpBoost
    local isAscendingFast = verticalSpeed > 5.5

    local verticalToHorizontalRatio = horizontalSpeed > 0 and (verticalSpeed / horizontalSpeed) or verticalSpeed
    local hasProperTowerRatio = verticalToHorizontalRatio >= 0.8

    local hasRecentDamage = player.lastDamaged > 0 and (now - player.lastDamaged) < 500

    if now - player.towerData.lastReset > 2000 then
        player.towerData.heightHistory = {}
        player.towerData.lastReset = now
    end

    if isLookingDown and isSwingingBlock and isAscendingFast and hasProperTowerRatio and hasNoJumpBoost and not hasRecentDamage then
        table.insert(player.towerData.heightHistory, { y = player.position.y, time = now })
        if #player.towerData.heightHistory > 15 then
            table.remove(player.towerData.heightHistory, 1)
        end
    end

    if #player.towerData.heightHistory >= 8 then
        local heights = player.towerData.heightHistory
        local startHeight = heights[1]
        local endHeight = heights[#heights]

        local totalHeightGain = endHeight.y - startHeight.y
        local timeSpan = (endHeight.time - startHeight.time) / 1000

        local consistentRiseCount = 0
        for i = 2, #heights do
            if heights[i].y > heights[i-1].y then
                consistentRiseCount = consistentRiseCount + 1
            end
        end

        local consistencyRatio = consistentRiseCount / (#heights - 1)
        local hasConsistentRise = consistencyRatio >= 0.8
        local hasSignificantHeight = totalHeightGain >= 3.0
        local hasGoodTimespan = timeSpan >= 0.4 and timeSpan <= 1.5

        if hasConsistentRise and hasSignificantHeight and hasGoodTimespan then
            addViolation(player, "TowerA", 2)
            if shouldAlert(player, "TowerA", config) then
                flag(player, "TowerA", player.violations.TowerA)
            end
        else
            reduceViolation(player, "TowerA")
        end
    end
end

-- Check: LagRangeA
local function checkLagRangeA(player)
    local config = getCheckConfig("LagRangeA")
    if not config or not config.enabled then return end

    local now = getTime()
    local deltaX = math.abs(player.position.x - player.lastPosition.x)
    local deltaY = math.abs(player.position.y - player.lastPosition.y)
    local deltaZ = math.abs(player.position.z - player.lastPosition.z)

    local distanceMoved = math.sqrt(deltaX * deltaX + deltaZ * deltaZ)

    local lastMoveTime = player.lastPositionData and player.lastPositionData.timestamp or now

    if now - lastMoveTime > 200 and now - lastMoveTime < 2000 then
        player.lastPauseInMovement = now
    end

    if distanceMoved > 1 and distanceMoved < 10 and now - (player.lastPauseInMovement or 0) < 200 then
        player.lastLag = now
    end

    local timeSinceLastLag = player.lastLag and (now - player.lastLag) or math.huge
    local timeSinceLastSwing = player.lastSwingDetected and (now - player.lastSwingDetected) or math.huge

    local isLagRanging = timeSinceLastSwing < timeSinceLastLag and timeSinceLastLag < 500 and isHoldingSword(player)

    if isLagRanging then
        player.lastLag = nil
        addViolation(player, "LagRangeA", 5)
        if shouldAlert(player, "LagRangeA", config) then
            flag(player, "LagRangeA", player.violations.LagRangeA)
        end
    else
        reduceViolation(player, "LagRangeA")
    end
end

-- Check: NoBreakDelayA
-- Detects players breaking blocks with no delay between consecutive breaks
-- Normal Minecraft behavior: 6 tick delay between finishing one block and starting another
-- NoBreakDelay bypass: 0-1 tick delay between consecutive block breaks

local MIN_BREAK_DELAY = 4
local HISTORY_SIZE = 10
local SUSPICIOUS_THRESHOLD = 1

-- Called when player STARTS breaking a new block (after a previous block finished)
local function checkNoBreakDelayA(player, startTick)
    local config = getCheckConfig("NoBreakDelayA")
    if not config or not config.enabled then return end

    local data = player.breakDelayData

    if data.lastBreakFinishTick > 0 then
        local tickDelay = startTick - data.lastBreakFinishTick

        table.insert(data.breakHistory, { tick = startTick, delay = tickDelay })
        while #data.breakHistory > HISTORY_SIZE do
            table.remove(data.breakHistory, 1)
        end

        local suspiciousBreaks = 0
        for _, entry in ipairs(data.breakHistory) do
            if entry.delay >= 0 and entry.delay < MIN_BREAK_DELAY then
                suspiciousBreaks = suspiciousBreaks + 1
            end
        end

        if suspiciousBreaks >= SUSPICIOUS_THRESHOLD then
            addViolation(player, "NoBreakDelayA", suspiciousBreaks)
            if shouldAlert(player, "NoBreakDelayA", config) then
                flag(player, "NoBreakDelayA", player.violations.NoBreakDelayA)
            end
            data.breakHistory = {}
        end
    end
end

-- Run all checks on a player
local function runChecks(player)
    checkNoSlowA(player)
    checkAutoBlockA(player)
    checkEagleA(player)
    checkScaffoldA(player)
    checkScaffoldB(player)
    checkTowerA(player)
end

-- Get or create player data
local function getOrCreatePlayer(playerData)
    local player = playersByUuid[playerData.uuid]

    if not player then
        player = createPlayerData(playerData.uuid, playerData.name, playerData.entityId)
        player.displayName = playerData.displayName or playerData.name
        players[playerData.name] = player
        playersByUuid[playerData.uuid] = player
        if playerData.entityId then
            entityToPlayer[playerData.entityId] = player
        end
    else
        if playerData.entityId and player.entityId ~= playerData.entityId then
            if player.entityId ~= -1 then
                entityToPlayer[player.entityId] = nil
            end
            player.entityId = playerData.entityId
            entityToPlayer[playerData.entityId] = player
        end
    end

    return player
end

-- Remove player by UUID
local function removePlayerByUuid(uuid)
    local player = playersByUuid[uuid]
    if player then
        players[player.name] = nil
        playersByUuid[uuid] = nil
        for entityId, p in pairs(entityToPlayer) do
            if p.uuid == uuid then
                entityToPlayer[entityId] = nil
                break
            end
        end
    end
end

-- Reset all tracking
local function reset()
    players = {}
    playersByUuid = {}
    entityToPlayer = {}
    uuidToName = {}
    uuidToDisplayName = {}
    starfish.debug("Anticheat: Cleared all tracked player data")
end

-- Event: Entity move
local function onEntityMove(event)
    if not event.entity or event.entity.type ~= "player" or not event.entity.uuid then return end

    local playerInfo = starfish.players.getInfo(event.entity.uuid)
    local playerName = (playerInfo and playerInfo.name) or uuidToName[event.entity.uuid] or "Unknown"
    local displayName = uuidToDisplayName[event.entity.uuid] or playerName

    local playerData = {
        name = playerName,
        uuid = event.entity.uuid,
        entityId = event.entity.entityId,
        displayName = displayName
    }

    local player = getOrCreatePlayer(playerData)
    if not player then return end

    if event.newPosition then
        updatePosition(player,
            event.newPosition.x,
            event.newPosition.y,
            event.newPosition.z,
            true,
            event.rotation and event.rotation.yaw,
            event.rotation and event.rotation.pitch
        )
    elseif event.delta then
        local newX = player.position.x + event.delta.x
        local newY = player.position.y + event.delta.y
        local newZ = player.position.z + event.delta.z
        updatePosition(player, newX, newY, newZ,
            event.onGround ~= nil and event.onGround or player.onGround,
            event.rotation and event.rotation.yaw,
            event.rotation and event.rotation.pitch
        )
    end

    runChecks(player)
end

-- Event: Entity animation
local function onEntityAnimation(event)
    if not event.entity or event.entity.type ~= "player" or not event.entity.uuid then return end

    local playerInfo = starfish.players.getInfo(event.entity.uuid)
    local playerName = (playerInfo and playerInfo.name) or uuidToName[event.entity.uuid] or "Unknown"
    local displayName = uuidToDisplayName[event.entity.uuid] or playerName

    local playerData = {
        name = playerName,
        uuid = event.entity.uuid,
        entityId = event.entity.entityId,
        displayName = displayName
    }

    local player = getOrCreatePlayer(playerData)
    if not player then return end

    if event.animation == 0 then
        local now = getTime()
        player.swingProgress = 6
        player.lastSwingTime = now
        player.lastSwingItem = player.heldItem
    end

    runChecks(player)
end

-- Event: Entity metadata
local function onEntityMetadata(event)
    if not event.entity or event.entity.type ~= "player" then return end

    local player = entityToPlayer[event.entity.entityId]

    if not player and event.entity.uuid then
        local playerInfo = starfish.players.getInfo(event.entity.uuid)
        local playerName = (playerInfo and playerInfo.name) or uuidToName[event.entity.uuid] or "Unknown"
        local displayName = uuidToDisplayName[event.entity.uuid] or playerName

        local playerData = {
            name = playerName,
            uuid = event.entity.uuid,
            entityId = event.entity.entityId,
            displayName = displayName
        }
        player = getOrCreatePlayer(playerData)
    end

    if not player then return end

    if event.metadata then
        for _, meta in ipairs(event.metadata) do
            if meta.key == 0 and meta.type == 0 then
                local flags = meta.value
                local now = getTime()

                local wasCrouching = player.isCrouching
                player.isCrouching = (flags & 0x02) ~= 0

                if player.isCrouching and not wasCrouching then
                    player.lastCrouchTime = now
                    player.currentShiftStart = now
                    table.insert(player.shiftEvents, {
                        eventType = "start",
                        timestamp = now,
                        position = { x = player.position.x, y = player.position.y, z = player.position.z }
                    })
                    if #player.shiftEvents > 50 then
                        table.remove(player.shiftEvents, 1)
                    end
                elseif not player.isCrouching and wasCrouching then
                    player.lastStopCrouchTime = now
                    local duration = player.currentShiftStart and (now - player.currentShiftStart) or 0
                    table.insert(player.shiftEvents, {
                        eventType = "stop",
                        timestamp = now,
                        position = { x = player.position.x, y = player.position.y, z = player.position.z },
                        duration = duration
                    })
                    player.currentShiftStart = nil
                    if #player.shiftEvents > 50 then
                        table.remove(player.shiftEvents, 1)
                    end
                end

                player.isSprinting = (flags & 0x08) ~= 0

                local wasUsingItem = player.isUsingItem
                player.isUsingItem = (flags & 0x10) ~= 0

                if player.isUsingItem and not wasUsingItem and isHoldingSword(player) then
                    player.isBlocking = true
                    player.blockingStartTime = now
                elseif not player.isUsingItem and wasUsingItem then
                    player.isBlocking = false
                end

                if player.isUsingItem ~= player.lastUsing then
                    player.lastUsing = player.isUsingItem
                end
            end
        end
    end

    runChecks(player)
end

-- Event: Entity equipment
local function onEntityEquipment(event)
    if not event.entity or not event.isPlayer then return end

    local player = entityToPlayer[event.entity.entityId]
    if not player then return end

    if event.slot == 0 then
        player.heldItem = event.item
    end
end

-- Event: Entity status
local function onEntityStatus(event)
    if not event.entity then return end

    local player = entityToPlayer[event.entity.entityId]
    if not player then return end

    if event.status == 2 then
        player.lastDamaged = getTime()
    end
end

-- Event: Player info (tab list)
local function onPlayerInfo(event)
    if event.players then
        for _, update in ipairs(event.players) do
            if update.name and update.uuid then
                uuidToName[update.uuid] = update.name
                uuidToDisplayName[update.uuid] = update.displayName or update.name
            end
        end
    end
end

-- Event: Named entity spawn
local function onNamedEntitySpawn(event)
    local data = event.player
    if not data then return end

    local playerName = uuidToName[data.playerUUID] or "Unknown"
    local displayName = uuidToDisplayName[data.playerUUID] or playerName

    local playerData = {
        name = playerName,
        uuid = data.playerUUID,
        entityId = data.entityId,
        displayName = displayName
    }

    local player = getOrCreatePlayer(playerData)

    updatePosition(player, data.position.x, data.position.y, data.position.z, false)
    player.yaw = data.yaw
    player.pitch = data.pitch
end

-- Event: Entity destroy
local function onEntityDestroy(event)
    if event.entities then
        for _, entity in ipairs(event.entities) do
            local player = entityToPlayer[entity.entityId]
            if player then
                players[player.name] = nil
                playersByUuid[player.uuid] = nil
                entityToPlayer[entity.entityId] = nil
            end
        end
    end
end

-- Event: Block change (for NoBreakDelayA) - records when a block FINISHES breaking
local function onBlockChange(event)
    if event.blockId ~= 0 then return end

    local breakPos = { x = event.x, y = event.y, z = event.z }

    for _, player in pairs(playersByUuid) do
        local data = player.breakDelayData
        if data.currentBreakPos and
           data.currentBreakPos.x == breakPos.x and
           data.currentBreakPos.y == breakPos.y and
           data.currentBreakPos.z == breakPos.z then
            data.lastBreakFinishTick = currentTick
            data.lastFinishedPos = { x = breakPos.x, y = breakPos.y, z = breakPos.z }
            data.currentBreakPos = nil
            return
        end
    end
end

-- Event: Respawn
local function onRespawn(event)
    reset()
end

-- Event: Plugin restored
local function onPluginRestored(event)
    if event.pluginName == "anticheat" then
        reset()
    end
end

-- Event: Block break animation - tracks when player STARTS breaking a new block
local function onBlockBreakAnimation(event)
    local player = entityToPlayer[event.entityId]
    if not player then return end
    if event.destroyStage < 0 then return end

    local data = player.breakDelayData
    local newPos = { x = event.x, y = event.y, z = event.z }

    -- Check if this is a NEW block (different from current)
    local isNewBlock = not data.currentBreakPos or
        data.currentBreakPos.x ~= newPos.x or
        data.currentBreakPos.y ~= newPos.y or
        data.currentBreakPos.z ~= newPos.z

    if isNewBlock then
        if data.lastBreakFinishTick > 0 then
            checkNoBreakDelayA(player, currentTick)
        end

        data.currentBreakPos = newPos
    end
end

-- Register event handlers
starfish.events.on("entity_move", onEntityMove)
starfish.events.on("entity_animation", onEntityAnimation)
starfish.events.on("entity_metadata", onEntityMetadata)
starfish.events.on("entity_equipment", onEntityEquipment)
starfish.events.on("entity_status", onEntityStatus)
starfish.events.on("player_info", onPlayerInfo)
starfish.events.on("named_entity_spawn", onNamedEntitySpawn)
starfish.events.on("entity_destroy", onEntityDestroy)
starfish.events.on("block_change", onBlockChange)
starfish.events.on("block_break_animation", onBlockBreakAnimation)
starfish.events.on("respawn", onRespawn)
starfish.events.on("plugin_restored", onPluginRestored)

-- Tick handler
local tickId = starfish.events.everyTick(function()
    currentTick = currentTick + 1
    for uuid, player in pairs(playersByUuid) do
        if player.swingProgress > 0 then
            player.swingProgress = math.max(0, player.swingProgress - 1)
        end
        checkLagRangeA(player)
    end
end)
