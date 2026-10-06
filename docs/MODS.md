# SGW3 Mods: Bunny Hop, Trainer, Map Editor

Mods for the [SGW3 Modding Framework](../README.md). Requires the framework (Ultimate ASI Loader +
`sgw3_modloader.asi`). Extract the release zip into the game folder: `.pak` files go to `GameSDK\`, the
`.asi` and `sgw3_models.txt` to `win_x64\`.

## Bunny Hop (`zzz_sgw3_bhop.pak`)

- **Hold Space** to keep hopping: each landing relaunches you at full jump speed without losing horizontal speed.
- **Gain speed by strafing**: in the air, hold A while turning the mouse left, D while turning right (Quake-style).
- **F6** toggles the mod; turning it off restores the game's own jump, air-control and fall settings.
- Tune it live in the trainer's **Movement** tab (air accel, strafe gain, max speed, per-hop boost, jump speed),
  with a reset-to-defaults button.

## Trainer (`zzz_sgw3_trainer.pak` + `sgw3_trainer.asi`)

Press **Insert**. While the menu is open the game receives no input.

| Tab | Features |
|---|---|
| Player | God mode, infinite health, infinite ammo, invisible to enemies, freeze AI, refill health, 3 teleport slots, blink forward |
| Movement | Bunny hop settings, noclip fly (WASD, Space up, C down, Shift fast) |
| World | Time scale, time of day and its speed, field of view, speed/position overlay |
| Spawner | 407 character types (enemies, civilians, animals) by faction; count, at crosshair or in front, facing; kill/remove spawned |
| Map Editor | See below |
| Console | Run Lua in the game, `/command` for console commands, `get`/`set` cvars, `help`; shows all mods' log output |

The game's own cheat cvars are locked in this release; these features are implemented through the game's
scripts instead (for example god mode filters damage in `SinglePlayer:ProcessActorDamage`).

## Map Editor (Trainer → Map Editor → Enter editor)

- **Fly-cam**: hold the right mouse button to look, WASD / Space / C to fly, Shift for speed.
- **Place models**: search ~9,900 game models, double-click to place at the crosshair.
- **Move with arrows**: drag the red/green/blue X/Y/Z arrows; exact position, rotation and scale fields.
- **Edit the level**: click an existing entity (props, doors, vehicles, lights, AI...) or pick it from the
  Nearby list; move, rotate, scale, hide/show, reset to original. Static level geometry can't be edited.
- **Persistence**: every edit autosaves per level and is restored when the level loads, also after checkpoints.
- **Export**: *Export standalone .pak* writes `zzz_layout_<name>.pak` to
  `Saved Games\Sniper Ghost Warrior 3\exports\`. Anyone with the framework can install it; it needs no trainer.

## Uninstall

Delete the `.pak` files from `GameSDK\` and `sgw3_trainer.asi` / `sgw3_models.txt` from `win_x64\`.
