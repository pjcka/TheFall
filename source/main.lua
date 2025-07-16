import "CoreLibs/object"
import "CoreLibs/graphics"
import "CoreLibs/sprites"
import "CoreLibs/timer"
import "CoreLibs/crank"
import "scoring"

local gfx <const> = playdate.graphics
local snd <const> = playdate.sound

-- Sound effects using synthesizers
local landingSynth = nil
local crashSynth = nil
local thrustSynth = nil
local bounceSynth = nil
local thrustIsPlaying = false

-- Initialize sound effects
local function initSounds()
    -- Landing sound: pure tone from bass to violin-like
    landingSynth = snd.synth.new(snd.kWaveSine)
    landingSynth:setADSR(0.005, 0.02, 0.6, 0.15)
    landingSynth:setVolume(0.9)

    -- Crash sound: explosion noise
    crashSynth = snd.synth.new(snd.kWaveNoise)
    crashSynth:setADSR(0, 0.2, 0.1, 0.5)
    crashSynth:setVolume(0.8)

    -- Thrust sound: continuous whoosh (softer with fade in/out)
    thrustSynth = snd.synth.new(snd.kWaveNoise)
    thrustSynth:setADSR(0.3, 0.1, 0.5, 0.5) -- Softer attack, lower sustain, longer release
    thrustSynth:setVolume(0.2)              -- Lower volume for softer sound

    -- Bounce sound: quick pop (mellower tone)
    bounceSynth = snd.synth.new(snd.kWaveTriangle)
    bounceSynth:setADSR(0.01, 0.05, 0.1, 0.1)
    bounceSynth:setVolume(0.5)
end

-- Play landing sound
function landingSound()
    if landingSynth then
        -- Get sequential landing count for pitch adjustment
        local landingCount = scoring.getSequentialLandings()

        -- Add 1 to anticipate the increment that will happen when score is calculated
        local nextLandingNumber = landingCount + 1

        -- Classic "ta da" sound - optimized for Playdate speaker
        local noteProgressions = {
            { "C3", "G3" }, -- Landing 1: Mid range start
            { "E3", "B3" }, -- Landing 2
            { "G3", "D4" }, -- Landing 3
            { "C4", "G4" }, -- Landing 4: Middle C range
            { "E4", "B4" }, -- Landing 5
            { "G4", "D5" }, -- Landing 6
            { "C5", "G5" }  -- Landing 7+: Bright and clear
        }

        -- Select progression based on the next landing number (cap at 7)
        local progressionIndex = math.min(nextLandingNumber, 7)
        local notes = noteProgressions[progressionIndex]

        -- Play classic "ta da" - two quick plucked notes
        landingSynth:playNote(notes[1], 0.8, 0.08)
        playdate.timer.performAfterDelay(100, function()
            landingSynth:playNote(notes[2], 1.0, 0.15)
        end)
    end
end

-- Play crash sound
-- Play crash/explosion sound
function crashSound()
    if crashSynth then
        crashSynth:playNote("C2", 1.0, 0.5)
    end
end

-- Play bounce sound
function bounceSound(velocity)
    if bounceSynth then
        -- Scale pitch and volume based on impact velocity
        local impactStrength = math.min(math.abs(velocity) / 5, 1.0)
        local pitch = 100 + (impactStrength * 120)  -- 100Hz to 220Hz range (mellower high end)
        local volume = 0.3 + (impactStrength * 0.4) -- 0.3 to 0.7 volume
        bounceSynth:setVolume(volume)
        bounceSynth:playNote(pitch, 1.0, 0.1)
    end
end

-- Initialize sounds on startup
initSounds()

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

    -- Create lander image with monitor/TV design (16x20)
    local landerWidth = 16
    local landerHeight = 20
    local landerImage = gfx.image.new(landerWidth, landerHeight)
    gfx.pushContext(landerImage)

    -- Draw the monitor body (rounded rectangle)
    gfx.setColor(gfx.kColorWhite)
    gfx.fillRoundRect(0, 0, landerWidth, 14, 3)

    -- Draw the screen (black rounded rectangle inside)
    gfx.setColor(gfx.kColorBlack)
    gfx.fillRoundRect(3, 3, 10, 6, 2)

    -- Draw the triangular base/stand
    gfx.setColor(gfx.kColorWhite)
    -- Triangle from bottom center spreading out
    gfx.fillPolygon(
        landerWidth / 2, 14,          -- Top center of triangle (connects to monitor)
        2, landerHeight,              -- Bottom left
        landerWidth - 2, landerHeight -- Bottom right
    )

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

        -- Start thrust sound if not already playing
        if thrustSynth and not thrustIsPlaying then
            thrustSynth:playNote("C2", 0.8, -1) -- Lower pitch and volume for softer sound
            thrustIsPlaying = true
        end

        -- Create thrust particles
        if math.random() < 0.8 then
            local particle = {
                x = lander.x - math.cos(thrustAngle) * 10, -- Adjusted for new height
                y = lander.y - math.sin(thrustAngle) * 10, -- Adjusted for new height
                vx = -math.cos(thrustAngle) * 1 + (math.random() - 0.5) * 0.5,
                vy = -math.sin(thrustAngle) * 1 + (math.random() - 0.5) * 0.5,
                life = 10
            }
            table.insert(lander.thrustParticles, particle)
        end
    else
        self.thrusting = false

        -- Stop thrust sound if playing
        if thrustSynth and thrustIsPlaying then
            thrustSynth:stop()
            thrustIsPlaying = false
        end
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
        -- Only play sound if actually moving left
        if self.vx < -0.5 then
            bounceSound(self.vx)
        end
        self.vx = -self.vx * 0.5
    elseif newX > 390 then
        newX = 390
        -- Only play sound if actually moving right
        if self.vx > 0.5 then
            bounceSound(self.vx)
        end
        self.vx = -self.vx * 0.5
    end

    -- Check tree collisions
    local landerHalfWidth = 8
    local landerHalfHeight = 10
    for _, tree in ipairs(trees) do
        local treeCollision = false

        if tree.type == 1 then
            -- Pine tree collision (triangular)
            local treeHeight = 27
            local treeWidth = 8
            -- More precise triangular collision
            if newY > GROUND_HEIGHT - treeHeight - landerHalfHeight and
                newY < GROUND_HEIGHT + landerHalfHeight then
                -- Calculate triangle width at lander's Y position
                local yFromBottom = GROUND_HEIGHT - newY
                local widthAtY = treeWidth * (yFromBottom / treeHeight)
                if math.abs(newX - tree.x) < widthAtY + landerHalfWidth then
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
            local effectiveRadius = math.max(landerHalfWidth, landerHalfHeight)
            if dx * dx + dy * dy < (radius + effectiveRadius) * (radius + effectiveRadius) then
                treeCollision = true
            end
            -- Check collision with trunk
            if newX > tree.x - 2 - landerHalfWidth and
                newX < tree.x + 2 + landerHalfWidth and
                newY > GROUND_HEIGHT - trunkHeight - landerHalfHeight and
                newY < GROUND_HEIGHT + landerHalfHeight then
                treeCollision = true
            end
        else
            -- Palm tree collision (trunk + fronds)
            local trunkHeight = 18
            -- Check trunk collision
            if newX > tree.x - 2 - landerHalfWidth and
                newX < tree.x + 2 + landerHalfWidth and
                newY > GROUND_HEIGHT - trunkHeight - landerHalfHeight and
                newY < GROUND_HEIGHT + landerHalfHeight then
                treeCollision = true
            end
            -- Check frond collision (three lines)
            local frondY = GROUND_HEIGHT - trunkHeight
            -- Check if lander is in frond area
            if newY > frondY - 9 - landerHalfHeight and newY < frondY + landerHalfHeight then
                -- Check collision with each frond line
                -- Left frond
                if math.abs(newX - (tree.x - 4.5)) < 4.5 + landerHalfWidth and
                    math.abs(newY - (frondY - 2.5)) < 2.5 + landerHalfHeight then
                    treeCollision = true
                end
                -- Right frond
                if math.abs(newX - (tree.x + 4.5)) < 4.5 + landerHalfWidth and
                    math.abs(newY - (frondY - 2.5)) < 2.5 + landerHalfHeight then
                    treeCollision = true
                end
                -- Center frond
                if math.abs(newX - tree.x) < 1 + landerHalfWidth and
                    math.abs(newY - (frondY - 4.5)) < 4.5 + landerHalfHeight then
                    treeCollision = true
                end
            end
        end

        if treeCollision then
            gameState = "crashed"
            crashReason = "Tree"
            self.thrustParticles = {}
            self:createExplosion()
            scoring.resetSequentialLandings()
            print("Crash! Hit a tree!")
            break
        end
    end

    -- Check ground collision
    -- Lander needs to be 1px above the dither pattern (which starts at GROUND_HEIGHT)
    if newY >= GROUND_HEIGHT - 12 then -- Adjusted for new height (20px height, so half is 10, plus 2)
        -- Check if in landing zone (entire ship must be within zone, with 4px buffer)
        local shipHalfWidth = 8        -- Ship is 16 pixels wide
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
            newY = GROUND_HEIGHT - 10
            self.vx = 0
            self.vy = 0
            self.thrustParticles = {}

            -- Stop thrust sound if playing
            if thrustSynth and thrustIsPlaying then
                thrustSynth:stop()
                thrustIsPlaying = false
            end

            -- Play landing sound
            if landingSound then
                landingSound()
            end
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
            scoring.resetSequentialLandings()
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
    -- Stop thrust sound if playing
    if thrustSynth and thrustIsPlaying then
        thrustSynth:stop()
        thrustIsPlaying = false
    end

    -- Play crash sound
    if crashSound then
        crashSound()
    end

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

            -- Start thrust sound if not already playing
            if thrustSynth and not thrustIsPlaying then
                thrustSynth:playNote("C2", 0.8, -1) -- Same as main game thrust
                thrustIsPlaying = true
            end

            -- Create thrust particles
            if math.random() < 0.8 then
                local particle = {
                    x = demoLander.x - math.cos(thrustAngle) * 10, -- Adjusted for new height
                    y = demoLander.y - math.sin(thrustAngle) * 10, -- Adjusted for new height
                    vx = -math.cos(thrustAngle) * 1 + (math.random() - 0.5) * 0.5,
                    vy = -math.sin(thrustAngle) * 1 + (math.random() - 0.5) * 0.5,
                    life = 10
                }
                table.insert(demoLander.thrustParticles, particle)
            end
        else
            demoLander.thrusting = false

            -- Stop thrust sound if playing
            if thrustSynth and thrustIsPlaying then
                thrustSynth:stop()
                thrustIsPlaying = false
            end
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
            -- Only play sound if actually moving left
            if demoLander.vx < -0.5 then
                bounceSound(demoLander.vx)
            end
            demoLander.vx = -demoLander.vx * 0.5
        elseif newX > 390 then
            newX = 390
            -- Only play sound if actually moving right
            if demoLander.vx > 0.5 then
                bounceSound(demoLander.vx)
            end
            demoLander.vx = -demoLander.vx * 0.5
        end

        -- Bounce off ground
        if newY >= GROUND_HEIGHT - 9 then
            newY = GROUND_HEIGHT - 9
            -- Only play sound if actually falling with some velocity
            if demoLander.vy > 1.0 then
                bounceSound(demoLander.vy)
            end
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
        gfx.drawText("A to Start", instructionX, instructionY + lineSpacing * 2)

        -- Draw chevron pointing to "A to Start" if crank is undocked
        if not playdate.isCrankDocked() then
            gfx.setColor(gfx.kColorWhite)
            gfx.setLineWidth(2)
            -- Draw chevron pointing right
            local chevronX = instructionX - 10
            local chevronY = instructionY + lineSpacing * 2 + 8
            gfx.drawLine(chevronX - 5, chevronY - 5, chevronX, chevronY)
            gfx.drawLine(chevronX - 5, chevronY + 5, chevronX, chevronY)
        end

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

        -- Check for A button to start, but only if crank is undocked
        if playdate.buttonJustPressed(playdate.kButtonA) and not playdate.isCrankDocked() then
            -- Start a new session
            gameTimer = 60
            totalScore = 0
            scoring.resetSequentialLandings()
            sessionActive = true
            newHighScore = false
            -- Stop thrust sound if playing
            if thrustSynth and thrustIsPlaying then
                thrustSynth:stop()
                thrustIsPlaying = false
            end
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
                scoring.resetSequentialLandings()
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

        -- Draw sequential landing multiplier below score
        if (gameState == "playing" or gameState == "landed") and sessionActive then
            local sequentialCount = scoring.getSequentialLandings()
            if sequentialCount > 0 then
                local multiplierText = string.format("x%d", sequentialCount)
                local multiplierWidth = gfx.getTextSize(multiplierText)
                gfx.drawText(multiplierText, 400 - multiplierWidth - 5, 22)
            end
        end
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
            -- Draw up triangle inside
            gfx.fillTriangle(20, 10, 16, 18, 24, 18)
        end

        -- Check for up button to restart
        if playdate.buttonJustPressed(playdate.kButtonUp) then
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
