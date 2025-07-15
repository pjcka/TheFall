-- Scoring System Module for The Fall

scoring = {}

-- Scoring constants
local BASE_SCORE = 100
local IDEAL_TIME = 10.0 -- 10 seconds in ideal conditions
local IDEAL_GRAVITY = 0.1
local IDEAL_WIND = 0.0

-- Time scoring parameters
local FAST_LANDING_EXPONENT = 2.0 -- Exponential growth for fast landings
local SLOW_LANDING_PENALTY = 5    -- Linear penalty per second over ideal time

-- Multiplier ranges
local GRAVITY_MULTIPLIER_RANGE = 0.8  -- Max deviation multiplier for gravity
local WIND_MULTIPLIER_BASE = 0.5      -- Base multiplier increase per 0.01 wind
local DISTANCE_MULTIPLIER_MAX = 1.0   -- Maximum bonus for edge landing zones
local DEFAULT_LANDING_ZONE_WIDTH = 70 -- Standard landing zone width

-- Score tracking
local startTime = nil
local finalScore = 0
local scoreBreakdown = {}

-- Initialize scoring for a new game
function scoring.startGame()
    startTime = playdate.getCurrentTimeMilliseconds()
    finalScore = 0
    scoreBreakdown = {
        baseScore = 0,
        timeBonus = 0,
        gravityMultiplier = 1.0,
        windMultiplier = 1.0,
        distanceMultiplier = 1.0,
        sizeMultiplier = 1.0,
        totalScore = 0
    }
end

-- Calculate time-based score component
local function calculateTimeScore(elapsedTime)
    local baseScore = BASE_SCORE
    local timeBonus = 0

    if elapsedTime < IDEAL_TIME then
        -- Exponential bonus for fast landing
        local timeDifference = IDEAL_TIME - elapsedTime
        timeBonus = math.pow(timeDifference, FAST_LANDING_EXPONENT) * 10
    elseif elapsedTime > IDEAL_TIME then
        -- Linear penalty for slow landing
        local timeDifference = elapsedTime - IDEAL_TIME
        timeBonus = -timeDifference * SLOW_LANDING_PENALTY
    end

    -- Ensure minimum score of 10
    local timeScore = math.max(10, baseScore + timeBonus)

    return baseScore, timeBonus, timeScore
end

-- Calculate gravity multiplier
local function calculateGravityMultiplier(currentGravity)
    -- Calculate deviation from ideal gravity
    local gravityDeviation = math.abs(currentGravity - IDEAL_GRAVITY)
    local maxDeviation = IDEAL_GRAVITY * GRAVITY_MULTIPLIER_RANGE

    -- Linear interpolation for multiplier
    -- At ideal gravity: multiplier = 1.0
    -- At max deviation: multiplier = 1.5
    local multiplier
    if gravityDeviation == 0 then
        multiplier = 1.0
    else
        local deviationRatio = math.min(gravityDeviation / maxDeviation, 1.0)
        multiplier = 1.0 + (1.0 * deviationRatio)
    end

    return multiplier
end

-- Calculate wind multiplier
local function calculateWindMultiplier(currentWind)
    -- Wind strength (absolute value)
    local windStrength = math.abs(currentWind)

    -- Calculate multiplier
    -- No wind: multiplier = 1.0
    -- Max wind (0.02): multiplier = 1.5
    local multiplier
    if windStrength == 0 then
        multiplier = 1.0
    else
        -- Each 0.01 of wind increases multiplier
        local increase = windStrength / 0.01 * WIND_MULTIPLIER_BASE
        multiplier = math.min(2.0, 1.0 + increase)
    end

    return multiplier
end

-- Calculate distance from center multiplier
local function calculateDistanceMultiplier(landingZoneX, landingZoneWidth)
    -- Screen center is at 200 (400 width / 2)
    local screenCenter = 200
    local landingZoneCenter = landingZoneX + (landingZoneWidth / 2)

    -- Calculate distance from center
    local distanceFromCenter = math.abs(landingZoneCenter - screenCenter)

    -- Maximum possible distance (zone at edge)
    local maxDistance = screenCenter - (landingZoneWidth / 2)

    -- Linear interpolation
    -- At center: multiplier = 1.0
    -- At edge: multiplier = 2.0
    local distanceRatio = math.min(distanceFromCenter / maxDistance, 1.0)
    local multiplier = 1.0 + (DISTANCE_MULTIPLIER_MAX * distanceRatio)

    return multiplier
end

-- Calculate landing zone size multiplier
local function calculateSizeMultiplier(landingZoneWidth)
    -- Size multipliers:
    -- Half size (35): 2.0x multiplier
    -- Normal size (70): 1.0x multiplier
    -- Max size (105): 0.75x multiplier

    local sizeRatio = landingZoneWidth / DEFAULT_LANDING_ZONE_WIDTH
    local multiplier

    if sizeRatio <= 0.5 then
        -- Half size or smaller: 2.0x
        multiplier = 2.0
    elseif sizeRatio >= 1.5 then
        -- 1.5x size or larger: 0.75x
        multiplier = 0.75
    elseif sizeRatio < 1.0 then
        -- Between half and normal: interpolate from 2.0 to 1.0
        local t = (sizeRatio - 0.5) / 0.5
        multiplier = 2.0 - (1.0 * t)
    else
        -- Between normal and max: interpolate from 1.0 to 0.75
        local t = (sizeRatio - 1.0) / 0.5
        multiplier = 1.0 - (0.25 * t)
    end

    return multiplier
end

-- Calculate final score when landing
function scoring.calculateScore(gravity, wind, landingZoneX, landingZoneWidth)
    if not startTime then
        print("Error: Game not started properly")
        return 0
    end

    -- Calculate elapsed time in seconds
    local endTime = playdate.getCurrentTimeMilliseconds()
    local elapsedTime = (endTime - startTime) / 1000.0

    -- Calculate base time score
    local baseScore, timeBonus, timeScore = calculateTimeScore(elapsedTime)

    -- Calculate multipliers
    local gravityMultiplier = calculateGravityMultiplier(gravity)
    local windMultiplier = calculateWindMultiplier(wind)
    local distanceMultiplier = calculateDistanceMultiplier(landingZoneX, landingZoneWidth)
    local sizeMultiplier = calculateSizeMultiplier(landingZoneWidth)

    -- Calculate final score
    local totalMultiplier = gravityMultiplier * windMultiplier * distanceMultiplier * sizeMultiplier
    finalScore = math.floor(timeScore * totalMultiplier)

    -- Store breakdown for display
    scoreBreakdown = {
        elapsedTime = elapsedTime,
        baseScore = baseScore,
        timeBonus = math.floor(timeBonus),
        timeScore = math.floor(timeScore),
        gravityMultiplier = gravityMultiplier,
        windMultiplier = windMultiplier,
        distanceMultiplier = distanceMultiplier,
        sizeMultiplier = sizeMultiplier,
        totalMultiplier = totalMultiplier,
        totalScore = finalScore
    }

    return finalScore
end

-- Get the current score breakdown
function scoring.getScoreBreakdown()
    return scoreBreakdown
end

-- Get just the final score
function scoring.getFinalScore()
    return finalScore
end

-- Format score for display
function scoring.getScoreDisplay()
    if scoreBreakdown.totalScore == 0 then
        return ""
    end

    local display = string.format("SCORE: %d", scoreBreakdown.totalScore)
    return display
end

-- Get detailed score breakdown for display
function scoring.getDetailedDisplay()
    if scoreBreakdown.totalScore == 0 then
        return {}
    end

    local details = {}

    -- Time
    table.insert(details, string.format("Time: %.1fs", scoreBreakdown.elapsedTime))

    -- Base score with bonus/penalty
    if scoreBreakdown.timeBonus > 0 then
        table.insert(details, string.format("Time Score: %d (+%d)",
            scoreBreakdown.baseScore, scoreBreakdown.timeBonus))
    elseif scoreBreakdown.timeBonus < 0 then
        table.insert(details, string.format("Time Score: %d (%d)",
            scoreBreakdown.baseScore, scoreBreakdown.timeBonus))
    else
        table.insert(details, string.format("Time Score: %d", scoreBreakdown.baseScore))
    end

    -- Multipliers
    table.insert(details, string.format("Gravity Difficulty: x%.2f", scoreBreakdown.gravityMultiplier))
    table.insert(details, string.format("Wind Difficulty: x%.2f", scoreBreakdown.windMultiplier))
    table.insert(details, string.format("Edge Landing: x%.2f", scoreBreakdown.distanceMultiplier))
    table.insert(details, string.format("Target Size: x%.2f", scoreBreakdown.sizeMultiplier))

    -- Total
    table.insert(details, "")
    table.insert(details, string.format("TOTAL: %d", scoreBreakdown.totalScore))

    return details
end

-- Get a single line summary of conditions
function scoring.getConditionsSummary(gravity, wind)
    local gravityPercent = (gravity / IDEAL_GRAVITY) * 100
    local windDirection = ""
    if wind < 0 then
        windDirection = "←"
    elseif wind > 0 then
        windDirection = "→"
    else
        windDirection = "-"
    end

    return string.format("Gravity: %d%% | Wind: %s%.3f",
        math.floor(gravityPercent), windDirection, math.abs(wind))
end

-- Module is now available globally as 'scoring'
