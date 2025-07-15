import "CoreLibs/object"
import "CoreLibs/graphics"
import "CoreLibs/sprites"
import "CoreLibs/timer"
import "CoreLibs/crank"
import "scoring"

local gfx <const> = playdate.graphics

-- Game constants
local GRAVITY = 0.1
local THRUST_POWER <const> = 0.35
local MAX_SAFE_LANDING_SPEED <const> = 1.5
local MAX_SAFE_LANDING_ANGLE <const> = 8
local GROUND_HEIGHT <const> = 235
local AIR_RESISTANCE <const> = 0.99

-- Game state
local lander = nil
local gameState = "start"             -- "start", "playing", "landed", "crashed", "session_ended"
local trees = {}                      -- Store tree positions and types
local clouds = {}                     -- Store cloud positions and properties
local landingZoneX = 150              -- Starting X position of landing zone
local landingZoneWidth = 70           -- Landing zone width in pixels (will be randomized)
local wind = 0                        -- Wind force (-negative = left, +positive = right)
local DEFAULT_LANDING_ZONE_WIDTH = 70 -- Default landing zone width
local gameTimer = 60                  -- 60 second game timer
local totalScore = 0                  -- Running total score
local lastLandingScore = 0            -- Score from last landing
local showLandingScore = false        -- Whether to show +#### score
local restartFlashTimer = 0           -- Timer for flashing restart indicator
local sessionActive = false           -- Whether a timed session is active
local demoLander = nil                -- Demo lander for title screen
local highScore = 0                   -- Highest score achieved
local newHighScore = false            -- Whether current score is a new high score
local crashReason = ""                -- Reason for crash to display

-- Lander class
class('Lander').extends(gfx.sprite)

function Lander:init(x, y)
    Lander.super.init(self)

    -- Create lander image with modern design
    local landerSize = 8
    local landerImage = gfx.image.new(landerSize * 2, landerSize * 2)
    gfx.pushContext(landerImage)
    gfx.setColor(gfx.kColorWhite)
    gfx.fillRoundRect(0, 0, landerSize * 2, landerSize * 2, 1)

    -- Engine nozzle (thruster trapezoid)
    -- COORDINATE SYSTEM: (0,0) is top-left of the lander image
    -- landerSize = 8, so the lander is a 16x16 pixel rounded rectangle
    -- The lander spans from (0,0) to (16,16)
    -- Center of lander is at (8,8)

    gfx.setColor(gfx.kColorBlack)
    gfx.setLineWidth(1)

    -- Thruster trapezoid
    -- Left edge: from (3, 16) to (7, 9)
    -- Start at bottom left of thruster, angle up and inward
    gfx.drawLine(landerSize - 8, landerSize * 2, landerSize - 2, landerSize + 1)

    -- Right edge: from (8, 9) to (12, 16)
    -- Start at top right, angle down and outward
    gfx.drawLine(landerSize + 2, landerSize + 1, landerSize + 7, landerSize * 2)

    -- This creates a trapezoid nozzle that's wider at the bottom (9 pixels)
    -- and narrower at the top (1 pixel gap), extending from the lander body


    gfx.popContext()

    self:setImage(landerImage)
    self:moveTo(x, y)
    self:add()

    -- Physics properties
    self.vx = 0
    self.vy = 0
    self.angle = 0 -- in degrees
    self.thrusting = false
    self.thrustParticles = {}
    self.explosionParticles = {}

    -- Set collision rect
    self:setCollideRect(0, 0, self:getSize())
end

function Lander:update()
    -- Update explosion particles even when crashed or session ended
    if gameState == "crashed" or gameState == "session_ended" then
        for i = #self.explosionParticles, 1, -1 do
            local p = self.explosionParticles[i]
            p.x += p.vx
            p.y += p.vy
            p.vy += 0.2 -- gravity for particles
            p.life -= 1
            if p.life <= 0 then
                table.remove(self.explosionParticles, i)
            end
        end
        return
    end

    if gameState ~= "playing" then
        return
    end

    -- Apply gravity
    self.vy += GRAVITY

    -- Apply wind force
    self.vx += wind

    -- Handle crank input for rotation (absolute position)
    local crankPosition = playdate.getCrankPosition()
    self.angle = crankPosition
    self:setRotation(self.angle)

    -- Handle thrust input (B button or Down arrow)
    if playdate.buttonIsPressed(playdate.kButtonB) or playdate.buttonIsPressed(playdate.kButtonDown) then
        -- Calculate thrust vector based on angle
        local thrustAngle = math.rad(self.angle - 90) -- -90 because 0 degrees points up
        self.vx += math.cos(thrustAngle) * THRUST_POWER
        self.vy += math.sin(thrustAngle) * THRUST_POWER
        self.thrusting = true

        -- Create thrust particles
        if math.random() < 0.8 then
            local particle = {
                x = self.x - math.cos(thrustAngle) * 8,
                y = self.y - math.sin(thrustAngle) * 8,
                vx = -math.cos(thrustAngle) * 1 + (math.random() - 0.5) * 0.5,
                vy = -math.sin(thrustAngle) * 1 + (math.random() - 0.5) * 0.5,
                life = 10
            }
            table.insert(self.thrustParticles, particle)
        end
    else
        self.thrusting = false
    end

    -- Update thrust particles
    for i = #self.thrustParticles, 1, -1 do
        local p = self.thrustParticles[i]
        p.x += p.vx
        p.y += p.vy
        p.life -= 1
        if p.life <= 0 then
            table.remove(self.thrustParticles, i)
        end
    end

    -- Apply air resistance
    self.vx *= AIR_RESISTANCE
    self.vy *= AIR_RESISTANCE

    -- Update position
    local newX = self.x + self.vx
    local newY = self.y + self.vy

    -- Keep lander on screen horizontally with bounce
    if newX < 10 then
        newX = 10
        self.vx = -self.vx * 0.5
    elseif newX > 390 then
        newX = 390
        self.vx = -self.vx * 0.5
    end

    -- Check tree collisions
    local landerHalfSize = 8
    for _, tree in ipairs(trees) do
        local treeCollision = false

        if tree.type == 1 then
            -- Pine tree collision (triangular)
            local treeHeight = 27
            local treeWidth = 8
            -- More precise triangular collision
            if newY > GROUND_HEIGHT - treeHeight - landerHalfSize and
                newY < GROUND_HEIGHT + landerHalfSize then
                -- Calculate triangle width at lander's Y position
                local yFromBottom = GROUND_HEIGHT - newY
                local widthAtY = treeWidth * (yFromBottom / treeHeight)
                if math.abs(newX - tree.x) < widthAtY + landerHalfSize then
                    treeCollision = true
                end
            end
        elseif tree.type == 2 then
            -- Lollipop tree collision (circular top + trunk)
            local radius = 10.5
            local trunkHeight = 12
            local treeTopY = GROUND_HEIGHT - trunkHeight - radius
            -- Check collision with circular top
            local dx = newX - tree.x
            local dy = newY - treeTopY
            if dx * dx + dy * dy < (radius + landerHalfSize) * (radius + landerHalfSize) then
                treeCollision = true
            end
            -- Check collision with trunk
            if newX > tree.x - 2 - landerHalfSize and
                newX < tree.x + 2 + landerHalfSize and
                newY > GROUND_HEIGHT - trunkHeight - landerHalfSize and
                newY < GROUND_HEIGHT + landerHalfSize then
                treeCollision = true
            end
        else
            -- Palm tree collision (trunk + fronds)
            local trunkHeight = 18
            -- Check trunk collision
            if newX > tree.x - 2 - landerHalfSize and
                newX < tree.x + 2 + landerHalfSize and
                newY > GROUND_HEIGHT - trunkHeight - landerHalfSize and
                newY < GROUND_HEIGHT + landerHalfSize then
                treeCollision = true
            end
            -- Check frond collision (three lines)
            local frondY = GROUND_HEIGHT - trunkHeight
            -- Check if lander is in frond area
            if newY > frondY - 9 - landerHalfSize and newY < frondY + landerHalfSize then
                -- Check collision with each frond line
                -- Left frond
                if math.abs(newX - (tree.x - 4.5)) < 4.5 + landerHalfSize and
                    math.abs(newY - (frondY - 2.5)) < 2.5 + landerHalfSize then
                    treeCollision = true
                end
                -- Right frond
                if math.abs(newX - (tree.x + 4.5)) < 4.5 + landerHalfSize and
                    math.abs(newY - (frondY - 2.5)) < 2.5 + landerHalfSize then
                    treeCollision = true
                end
                -- Center frond
                if math.abs(newX - tree.x) < 1 + landerHalfSize and
                    math.abs(newY - (frondY - 4.5)) < 4.5 + landerHalfSize then
                    treeCollision = true
                end
            end
        end

        if treeCollision then
            gameState = "crashed"
            crashReason = "Tree"
            self.thrustParticles = {}
            self:createExplosion()
            print("Crash! Hit a tree!")
            break
        end
    end

    -- Check ground collision
    -- Lander needs to be 1px above the dither pattern (which starts at GROUND_HEIGHT)
    if newY >= GROUND_HEIGHT - 9 then
        -- Check if in landing zone (entire ship must be within zone, with 4px buffer)
        local shipHalfWidth = 8 -- Ship is 16 pixels wide
        local inLandingZone = newX - shipHalfWidth >= landingZoneX - 4 and
            newX + shipHalfWidth <= landingZoneX + landingZoneWidth + 4

        -- Normalize angle to -180 to 180 range
        local normalizedAngle = self.angle
        if normalizedAngle > 180 then
            normalizedAngle = normalizedAngle - 360
        end

        if math.abs(self.vy) <= MAX_SAFE_LANDING_SPEED and
            math.abs(self.vx) <= MAX_SAFE_LANDING_SPEED and
            math.abs(normalizedAngle) <= MAX_SAFE_LANDING_ANGLE and
            inLandingZone then
            -- Safe landing
            gameState = "landed"
            newY = GROUND_HEIGHT - 9
            self.vx = 0
            self.vy = 0
            self.thrustParticles = {}
            -- Calculate score
            local score = scoring.calculateScore(GRAVITY, wind, landingZoneX, landingZoneWidth)
            lastLandingScore = score
            totalScore = totalScore + score
            showLandingScore = true

            -- Print score breakdown to console
            print("Safe landing! Score:", score)
            local details = scoring.getDetailedDisplay()
            for _, detail in ipairs(details) do
                print(detail)
            end
        else
            -- Crash
            gameState = "crashed"
            self.thrustParticles = {}
            self:createExplosion()
            if not inLandingZone then
                crashReason = "Missed"
            elseif math.abs(self.vy) > MAX_SAFE_LANDING_SPEED or math.abs(self.vx) > MAX_SAFE_LANDING_SPEED then
                crashReason = "Too Fast"
            else
                -- Re-normalize angle for crash reason check
                local normalizedAngle = self.angle
                if normalizedAngle > 180 then
                    normalizedAngle = normalizedAngle - 360
                end
                if math.abs(normalizedAngle) > MAX_SAFE_LANDING_ANGLE then
                    crashReason = "Crooked"
                else
                    crashReason = "Unknown"
                end
            end
            print("Crash!", crashReason)
        end
    end

    self:moveTo(newX, newY)
end

function Lander:createExplosion()
    -- Create explosion particles
    for i = 1, 15 do
        local angle = math.random() * math.pi * 2
        local speed = 1 + math.random() * 3
        local particle = {
            x = self.x,
            y = self.y,
            vx = math.cos(angle) * speed,
            vy = math.sin(angle) * speed,
            life = 20 + math.random(10)
        }
        table.insert(self.explosionParticles, particle)
    end

    -- Hide the lander sprite
    self:setVisible(false)
end

function Lander:drawThrust()
    -- Draw thrust particles
    gfx.setColor(gfx.kColorWhite)
    for _, p in ipairs(self.thrustParticles) do
        local size = (math.floor(p.life / 5) * 0.5 + 0.5) * 1.5
        gfx.fillCircleAtPoint(p.x, p.y, size)
    end

    -- Draw explosion particles
    for _, p in ipairs(self.explosionParticles) do
        local size = math.floor(p.life / 10) + 1
        gfx.fillCircleAtPoint(p.x, p.y, size)
    end
end

-- Initialize game
function initGame()
    -- Clear any existing sprites
    gfx.sprite.removeAll()

    -- Reset game state
    gameState = "playing"

    -- Start scoring timer
    scoring.startGame()

    -- Reset display flags but not the timer
    showLandingScore = false
    restartFlashTimer = 0
    crashReason = ""

    -- Randomize gravity (0.1 ± 0.04)
    GRAVITY = 0.06 + math.random() * 0.08

    -- Randomize wind (-0.02 to +0.02)
    wind = (math.random() - 0.5) * 0.04

    -- Create lander
    lander = Lander(200, 50)

    -- Randomize landing zone width (0.5x to 1.5x default)
    -- Min: 35 pixels (half), Max: 105 pixels (1.5x)
    local sizeMultiplier = 0.5 + math.random() * 1.0
    landingZoneWidth = math.floor(DEFAULT_LANDING_ZONE_WIDTH * sizeMultiplier)

    -- Generate random landing zone position (ensure it fits on screen)
    landingZoneX = math.random(10, 400 - landingZoneWidth - 10)

    -- Generate random trees
    trees = {}

    -- Function to check if a position is too close to existing trees or landing zone
    local function isPositionValid(x, minDistance)
        -- Check distance from other trees
        for _, tree in ipairs(trees) do
            if math.abs(tree.x - x) < minDistance then
                return false
            end
        end
        -- Check distance from landing zone
        if x >= landingZoneX - minDistance and x <= landingZoneX + landingZoneWidth + minDistance then
            return false
        end
        return true
    end

    -- Minimum distance between trees to prevent overlap
    local MIN_TREE_DISTANCE = 15

    -- Generate trees across the entire width
    local numTrees = math.random(5, 8)
    local attempts = 0
    local treesAdded = 0
    while treesAdded < numTrees and attempts < 100 do
        local x = math.random(20, 380)
        if isPositionValid(x, MIN_TREE_DISTANCE) then
            table.insert(trees, {
                x = x,
                type = math.random(1, 3)
            })
            treesAdded = treesAdded + 1
        end
        attempts = attempts + 1
    end

    -- Generate clouds
    clouds = {}
    local numClouds = math.random(3, 6)
    for i = 1, numClouds do
        local rectHeight = math.random(20, 40)
        local cloud = {
            x = math.random(-50, 450),
            y = math.random(50, 185),
            width = math.random(60, 120),
            height = rectHeight,
            radius = rectHeight / 2
        }
        table.insert(clouds, cloud)
    end
end

-- Game setup
function myGameSetUp()
    -- Set background color to black
    gfx.setBackgroundColor(gfx.kColorBlack)

    -- Clear the entire screen to black initially
    gfx.clear(gfx.kColorBlack)

    -- Load high score
    local data = playdate.datastore.read()
    if data and data.highScore then
        highScore = data.highScore
    end

    -- Don't start the game immediately
end

-- Initialize
myGameSetUp()

-- Main game loop
function playdate.update()
    -- Clear to black first
    gfx.clear(gfx.kColorBlack)

    -- Check for start state
    if gameState == "start" then
        -- Create demo lander if it doesn't exist
        if not demoLander then
            demoLander = Lander(70, -20)
            demoLander.vx = 0
            demoLander.vy = 0
        end

        -- Update demo lander physics
        if playdate.buttonIsPressed(playdate.kButtonB) or playdate.buttonIsPressed(playdate.kButtonDown) then
            -- Calculate thrust vector based on angle
            local thrustAngle = math.rad(demoLander.angle - 90)
            demoLander.vx = demoLander.vx + math.cos(thrustAngle) * THRUST_POWER
            demoLander.vy = demoLander.vy + math.sin(thrustAngle) * THRUST_POWER
            demoLander.thrusting = true

            -- Create thrust particles
            if math.random() < 0.8 then
                local particle = {
                    x = demoLander.x - math.cos(thrustAngle) * 8,
                    y = demoLander.y - math.sin(thrustAngle) * 8,
                    vx = -math.cos(thrustAngle) * 1 + (math.random() - 0.5) * 0.5,
                    vy = -math.sin(thrustAngle) * 1 + (math.random() - 0.5) * 0.5,
                    life = 10
                }
                table.insert(demoLander.thrustParticles, particle)
            end
        else
            demoLander.thrusting = false
        end

        -- Apply gravity
        demoLander.vy = demoLander.vy + 0.15

        -- Apply air resistance
        demoLander.vx = demoLander.vx * AIR_RESISTANCE
        demoLander.vy = demoLander.vy * AIR_RESISTANCE

        -- Update position
        local newX = demoLander.x + demoLander.vx
        local newY = demoLander.y + demoLander.vy

        -- Bounce off sides
        if newX < 10 then
            newX = 10
            demoLander.vx = -demoLander.vx * 0.5
        elseif newX > 390 then
            newX = 390
            demoLander.vx = -demoLander.vx * 0.5
        end

        -- Bounce off ground
        if newY >= GROUND_HEIGHT - 9 then
            newY = GROUND_HEIGHT - 9
            demoLander.vy = -demoLander.vy * 0.5
            demoLander.vx = demoLander.vx * 0.8
        end

        -- Don't bounce off ceiling, just constrain position
        if newY < -30 then
            newY = -30
        end

        -- Handle crank for rotation
        local crankPosition = playdate.getCrankPosition()
        demoLander.angle = crankPosition
        demoLander:setRotation(demoLander.angle)

        -- Update thrust particles
        for i = #demoLander.thrustParticles, 1, -1 do
            local p = demoLander.thrustParticles[i]
            p.x = p.x + p.vx
            p.y = p.y + p.vy
            p.life = p.life - 1
            if p.life <= 0 then
                table.remove(demoLander.thrustParticles, i)
            end
        end

        demoLander:moveTo(newX, newY)

        -- Draw demo lander and ground first
        gfx.sprite.update()

        -- Draw ground for demo
        gfx.setColor(gfx.kColorBlack)
        gfx.fillRect(0, GROUND_HEIGHT, 400, 5)

        -- Draw thrust effects for demo lander
        if demoLander then
            demoLander:drawThrust()
        end

        -- Now draw all UI elements on top
        gfx.setColor(gfx.kColorWhite)
        gfx.setImageDrawMode(gfx.kDrawModeFillWhite)

        -- Draw "THE FALL" vertically above d-pad (left side)
        local leftX = 70
        local startY = 10
        local letterSpacing = 25
        local title = "THE FALL"
        -- Create bold effect by drawing multiple times
        for i = 1, #title do
            local letter = title:sub(i, i)
            if letter ~= " " then
                local letterWidth = gfx.getTextSize(letter)
                local x = leftX - letterWidth / 2
                local y = startY + (i - 1) * letterSpacing
                -- Draw letter multiple times with slight offsets for bold effect
                gfx.drawText(letter, x, y)
                gfx.drawText(letter, x + 1, y)
                gfx.drawText(letter, x, y + 1)
                gfx.drawText(letter, x + 1, y + 1)
            end
        end

        -- Draw instructions on the right side
        local instructionX = 200
        local instructionY = 110
        local lineSpacing = 30

        -- Crank to Steer
        gfx.drawText("Crank to Steer", instructionX, instructionY)

        -- Down or B for thrust

        gfx.drawText("Down for Thrust", instructionX, instructionY + lineSpacing)

        -- A to Start
        gfx.drawText("Up to Start", instructionX, instructionY + lineSpacing * 2)

        -- Draw crank warning if needed
        if playdate.isCrankDocked() then
            gfx.setLineWidth(2)
            gfx.drawCircleAtPoint(instructionX - 20, instructionY + 9, 10)
            gfx.fillRect(instructionX - 21, instructionY + 3, 2, 6)
            gfx.fillCircleAtPoint(instructionX - 20, instructionY + 12, 1)
        end

        -- Draw high score at bottom left
        if highScore > 0 then
            local highScoreText = string.format("High Score: %d", highScore)
            gfx.drawText(highScoreText, instructionX, 218)
        end

        -- Check for A or Up button to start, but only if crank is undocked
        if (playdate.buttonJustPressed(playdate.kButtonA) or playdate.buttonJustPressed(playdate.kButtonUp)) and not playdate.isCrankDocked() then
            -- Start a new session
            gameTimer = 60
            totalScore = 0
            sessionActive = true
            newHighScore = false
            -- Remove demo lander
            if demoLander then
                demoLander:remove()
                demoLander = nil
            end
            initGame()
        end

        return
    end

    -- Update and draw sprites
    gfx.sprite.update()

    -- Now draw everything else on top
    -- Draw ground (5px tall at bottom of screen)
    gfx.setColor(gfx.kColorWhite)
    gfx.fillRect(0, GROUND_HEIGHT, 400, 5)

    -- Draw landing zone with dither pattern and borders
    -- First draw the dither pattern (5px tall)
    gfx.setColor(gfx.kColorBlack)
    gfx.setDitherPattern(0.5, gfx.image.kDitherTypeBayer8x8)
    gfx.fillRect(landingZoneX, GROUND_HEIGHT, landingZoneWidth, 5)

    -- Draw 2px black borders (left and right only)
    gfx.setColor(gfx.kColorBlack)
    gfx.setLineWidth(2)
    -- Left border
    gfx.drawLine(landingZoneX, GROUND_HEIGHT, landingZoneX, GROUND_HEIGHT + 5)
    -- Right border
    gfx.drawLine(landingZoneX + landingZoneWidth, GROUND_HEIGHT, landingZoneX + landingZoneWidth, GROUND_HEIGHT + 5)

    -- Tree drawing functions
    local function drawPineTree(x)
        -- Narrower pine tree
        local height = 27
        local width = 8
        gfx.setColor(gfx.kColorWhite)
        -- Tree triangle (narrow)
        gfx.fillPolygon(
            x, GROUND_HEIGHT - height,
            x - width, GROUND_HEIGHT,
            x + width, GROUND_HEIGHT
        )
        -- Tree trunk
        gfx.fillRect(x - 2, GROUND_HEIGHT - 3, 3, 3)
    end

    local function drawLollipopTree(x)
        -- Round lollipop tree
        local radius = 10.5
        local trunkHeight = 12
        gfx.setColor(gfx.kColorWhite)
        -- Tree circle
        gfx.fillCircleAtPoint(x, GROUND_HEIGHT - trunkHeight - radius, radius)
        -- Tree trunk
        gfx.fillRect(x - 1, GROUND_HEIGHT - trunkHeight, 3, trunkHeight)
    end

    local function drawPalmTree(x)
        -- Palm tree with fronds
        local trunkHeight = 18
        gfx.setColor(gfx.kColorWhite)
        -- Tree trunk (straight)
        gfx.fillRect(x - 1, GROUND_HEIGHT - trunkHeight, 2, trunkHeight)
        -- Palm fronds
        gfx.setLineWidth(2)
        -- Left frond
        gfx.drawLine(x, GROUND_HEIGHT - trunkHeight, x - 9, GROUND_HEIGHT - trunkHeight - 5)
        -- Right frond
        gfx.drawLine(x, GROUND_HEIGHT - trunkHeight, x + 9, GROUND_HEIGHT - trunkHeight - 5)
        -- Center frond
        gfx.drawLine(x, GROUND_HEIGHT - trunkHeight, x, GROUND_HEIGHT - trunkHeight - 9)
    end

    -- Draw trees from stored positions
    for _, tree in ipairs(trees) do
        if tree.type == 1 then
            drawPineTree(tree.x)
        elseif tree.type == 2 then
            drawLollipopTree(tree.x)
        else
            drawPalmTree(tree.x)
        end
    end

    -- Draw thrust effects
    gfx.setColor(gfx.kColorWhite)
    if lander then
        lander:drawThrust()
    end

    -- Draw speed warning symbol if too fast (only when playing)
    if gameState == "playing" and lander and (math.abs(lander.vy) > MAX_SAFE_LANDING_SPEED or math.abs(lander.vx) > MAX_SAFE_LANDING_SPEED) then
        -- Draw circle outline
        gfx.setColor(gfx.kColorWhite)
        gfx.setLineWidth(2)
        gfx.drawCircleAtPoint(12, 12, 10)
        -- Draw exclamation mark inside
        gfx.fillRect(11, 6, 2, 6)
        gfx.fillCircleAtPoint(12, 15, 1)
    end





    -- Draw timer at top center (show during session)
    if sessionActive and gameState ~= "start" then
        gfx.setColor(gfx.kColorWhite)
        gfx.setImageDrawMode(gfx.kDrawModeFillWhite)
        local timerText = string.format("%d", math.max(0, math.ceil(gameTimer)))
        local timerWidth = gfx.getTextSize(timerText)
        -- Draw bold by rendering multiple times
        gfx.drawText(timerText, 200 - timerWidth / 2, 5)
        gfx.drawText(timerText, 200 - timerWidth / 2 + 1, 5)
        gfx.drawText(timerText, 200 - timerWidth / 2, 6)
        gfx.drawText(timerText, 200 - timerWidth / 2 + 1, 6)

        -- Update timer
        if sessionActive then
            gameTimer = gameTimer - (1 / 30) -- Assuming 30 FPS
            if gameTimer <= 0 then
                gameTimer = 0
                sessionActive = false
                -- Check for new high score
                if totalScore > highScore then
                    highScore = totalScore
                    newHighScore = true
                    -- Save high score
                    playdate.datastore.write({ highScore = highScore })
                end
                -- End the session regardless of current state
                if gameState == "playing" or gameState == "landed" or gameState == "crashed" then
                    -- Make lander explode if still playing
                    if gameState == "playing" and lander then
                        lander:createExplosion()
                    end
                    gameState = "session_ended"
                end
            end
        end
    end

    -- Draw score at top right (always show during session)
    if sessionActive or gameState == "session_ended" then
        gfx.setColor(gfx.kColorWhite)
        gfx.setImageDrawMode(gfx.kDrawModeFillWhite)
        local scoreText = ""
        if gameState == "crashed" and crashReason ~= "" then
            scoreText = crashReason
        elseif showLandingScore and gameState == "landed" then
            scoreText = string.format("+%d", lastLandingScore)
        else
            scoreText = string.format("%d", totalScore)
        end
        local scoreWidth = gfx.getTextSize(scoreText)
        gfx.drawText(scoreText, 400 - scoreWidth - 5, 5)
    end



    -- Draw restart indicator (flashing circle with down arrow) when landed or crashed
    -- But only if session is still active
    if (gameState == "landed" or gameState == "crashed") and sessionActive then
        restartFlashTimer = restartFlashTimer + 1
        if math.floor(restartFlashTimer / 15) % 2 == 0 then -- Flash every 0.5 seconds
            gfx.setColor(gfx.kColorWhite)
            gfx.setLineWidth(2)
            -- Draw circle
            gfx.drawCircleAtPoint(20, 15, 10)
            -- Draw down arrow inside
            gfx.drawLine(20, 10, 20, 18)
            gfx.drawLine(17, 15, 20, 18)
            gfx.drawLine(23, 15, 20, 18)
        end

        -- Check for down or B button to restart
        if playdate.buttonJustPressed(playdate.kButtonDown) or playdate.buttonJustPressed(playdate.kButtonB) then
            -- Only allow restart if session is still active
            if sessionActive and gameTimer > 0 then
                -- When restarting, clear the landing score display
                showLandingScore = false
                initGame()
            elseif not sessionActive then
                -- Session ended, go back to start screen
                -- Remove lander sprite before returning to title screen
                if lander then
                    lander:remove()
                    lander = nil
                end
                gameState = "start"
            end
        end
    end

    -- Handle session ended state
    if gameState == "session_ended" then
        gfx.setColor(gfx.kColorWhite)
        gfx.setImageDrawMode(gfx.kDrawModeFillWhite)

        -- Display "Game Over" at top
        local gameOverText = "Game Over"
        local gameOverWidth = gfx.getTextSize(gameOverText)
        gfx.drawText(gameOverText, 200 - gameOverWidth / 2, 5)

        -- Score stays at top right (already handled by normal score display)

        -- Show NEW HIGH SCORE if applicable
        if newHighScore then
            local newHighText = "NEW HIGH SCORE"
            local newHighWidth = gfx.getTextSize(newHighText)
            gfx.drawText(newHighText, 400 - newHighWidth - 5, 25)
        end

        -- Draw blinking A button indicator in top left
        restartFlashTimer = restartFlashTimer + 1
        if math.floor(restartFlashTimer / 15) % 2 == 0 then -- Flash every 0.5 seconds
            gfx.setColor(gfx.kColorWhite)
            gfx.setLineWidth(2)
            -- Draw circle
            gfx.drawCircleAtPoint(20, 15, 10)
            -- Draw small "A" inside using lines
            gfx.setLineWidth(1)
            -- Left diagonal
            gfx.drawLine(16, 18, 19, 10)
            -- Right diagonal
            gfx.drawLine(22, 18, 19, 10)
            -- Horizontal crossbar
            gfx.drawLine(17, 16, 21, 16)
        end

        -- Check for A button to return to start
        if playdate.buttonJustPressed(playdate.kButtonA) then
            -- Remove lander sprite before returning to title screen
            if lander then
                lander:remove()
                lander = nil
            end
            gameState = "start"
        end
    end

    -- Update and draw clouds (draw after everything else to obscure view)
    if gameState == "playing" then
        -- Update cloud positions and remove off-screen clouds
        for i = #clouds, 1, -1 do
            local cloud = clouds[i]
            -- Cloud speed based purely on wind
            local cloudSpeed = wind * 20
            cloud.x = cloud.x + cloudSpeed
            -- Remove clouds that have gone off screen
            if (cloudSpeed > 0 and cloud.x - cloud.width / 2 > 400) or (cloudSpeed < 0 and cloud.x + cloud.width / 2 < 0) then
                table.remove(clouds, i)
            end
        end

        -- Randomly generate new clouds from appropriate side (max 8 clouds)
        if math.random() < 0.01 and #clouds < 8 then -- 1% chance per frame, limit to 8 clouds
            local rectHeight = math.random(20, 40)
            local newCloud = {
                y = math.random(50, 185),
                width = math.random(60, 120),
                height = rectHeight,
                radius = rectHeight / 2
            }
            -- Start from appropriate side based on wind
            if wind >= 0 then
                newCloud.x = -newCloud.width
            else
                newCloud.x = 450
            end
            table.insert(clouds, newCloud)
        end
    end

    -- Draw clouds
    gfx.setColor(gfx.kColorWhite)
    for _, cloud in ipairs(clouds) do
        -- Draw cloud as a single pill shape
        gfx.fillRoundRect(cloud.x - cloud.width / 2,
            cloud.y - cloud.height / 2,
            cloud.width, cloud.height, cloud.radius)
    end

    -- Update timers
    playdate.timer.updateTimers()

    -- Reset draw mode at end of frame
    gfx.setImageDrawMode(gfx.kDrawModeCopy)
end
