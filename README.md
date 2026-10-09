# Dragons Dogma 2 Diagonal Camera Fix

Fixes the slower diagonal camera movement when using a controller by hooking into the game's input function and replacing the built in response curve with a clean alternative. Mouse input is left completely untouched.

## Installation

1. Download the mod [here](https://github.com/InitialDet/dragons-dogma-2-diagonal-camera-fix/releases)
2. Install [REFramework](https://github.com/praydog/REFramework-nightly/releases)
3. Use [FluffyQuack's Mod Manager](https://www.nexusmods.com/site/mods/818) (recommended) or extract the `.lua` inside `\Dragons Dogma 2\reframework\autorun`

## How It Works

The game applies a strong curve to controller stick input that makes diagonal movement feel much slower than moving straight up, down, left, or right. This mod takes the stick values before the game processes them and replaces the output with a magnitude based system where the camera speed depends only on how far you push the stick, not which direction.

Two response modes are available:

- **Linear**: Scales stick input linearly from the dead zone to 1.0. Predictable and consistent.
- **Power Curve**: Applies an exponential curve (default 1.5, adjustable 1.0–3.0) for finer control at low speeds with sharper response at higher tilt. A value of 1.0 equals linear; higher values progressively emphasize the high end.

## Auto Dead Zone Detection

Watches the lightest stick movement the game can detect and sets the dead zone automatically. The current value is shown in the UI. Can be turned off to use a manual slider instead.
