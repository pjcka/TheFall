# The Fall

A modern lunar lander game for the Playdate console with a minimal aesthetic and challenging physics-based gameplay.

## Overview

The Fall is a reimagining of the classic lunar lander genre, designed specifically for the Playdate's unique controls. Master gravity and thrust as you guide your spacecraft to safe landings on designated landing zones. The game features realistic physics, fuel management, and precise control using the Playdate's crank and buttons.

## Features

- **Crank-based rotation control** - Use the Playdate's unique crank to precisely control your lander's orientation
- **Physics-based gameplay** - Realistic gravity and momentum make every landing a challenge
- **Minimal, modern aesthetic** - Clean visual design focused on gameplay
- **Visual feedback** - Real-time velocity indicators and thrust effects
- **Fuel management** - Limited fuel adds strategic depth to each landing attempt

### Planned Features (Coming Soon)
- Wind effects that push your lander
- Cloud layers that obscure visibility
- Airplanes and other obstacles to avoid
- Power-ups including emergency parachutes
- Multiple landing zones with varying difficulty
- Score system based on landing precision and fuel efficiency

## Controls

- **Crank**: Rotate the lander
- **B Button**: Activate thrust
- **A Button**: Restart after landing or crashing

## How to Play

1. Your lander starts at the top of the screen with limited fuel
2. Use the crank to adjust your angle
3. Press and hold B to thrust in the direction you're facing
4. Land gently on the white landing zone (between the markers)
5. Success requires:
   - Landing in the designated zone
   - Vertical speed below 1.5 units
   - Angle within 15 degrees of upright

## Building and Running

### Prerequisites
- Playdate SDK
- Playdate Simulator or device

### Build Instructions
1. Ensure the Playdate SDK is installed and `pdc` is in your PATH
2. Navigate to the project directory
3. Build the game:
   ```
   pdc source TheFall.pdx
   ```
4. Run in the Simulator:
   ```
   open TheFall.pdx
   ```
   Or drag the .pdx file to the Simulator

### Running on Device
1. Build the game as above
2. Connect your Playdate via USB
3. Use the Simulator's "Upload Game to Device" option

## Game Mechanics

- **Gravity**: Constant downward acceleration of 0.1 units/frame
- **Thrust Power**: 0.35 units/frame when activated
- **Air Resistance**: Slight damping effect (0.99x per frame)
- **Safe Landing Speed**: Maximum 1.5 units/frame vertical
- **Safe Landing Angle**: Within 15 degrees of vertical
- **Fuel Consumption**: 0.5 units per frame while thrusting

## Tips for Success

- Start rotating early - the lander has momentum
- Use short thrust bursts to control descent
- Watch the velocity vector (black line) to predict your path
- Keep an eye on your fuel gauge
- The landing zone is marked with white lines and a patterned area
- Practice controlling horizontal drift while managing vertical speed

## Development

This game is built with Lua using the Playdate SDK. The codebase is designed to be extensible for the planned features while maintaining clean, readable code.

### Project Structure
```
TheFall/
├── source/
│   ├── main.lua          # Main game logic
│   ├── pdxinfo           # Game metadata
│   └── images/           # Game assets
│       └── launcher/     # Menu icons
└── README.md
```

## Credits

Created for the Playdate gaming system by Panic.

## License

[Your license here]