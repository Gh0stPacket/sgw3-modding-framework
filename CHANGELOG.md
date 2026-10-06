# Changelog

All notable changes to this project. Versions follow [Semantic Versioning](https://semver.org/).

## [1.0.0] - 2026-10-06

First release. Supports Sniper Ghost Warrior 3 3.8.6.53 (GOG).

### Framework
- `sgw3_modloader.asi`: injects the framework after `Scripts/main.lua` compiles by hooking the game's `lua_load`;
  no game files are replaced. Signature-checked; inactive on other game builds.
- Lua API `SGW3`: `RegisterMod`, `OnTick` (survives deaths, checkpoints and level loads), `OnLevelLoad`,
  `IsKeyDown` / `KeyPressed`, `Player`, `Level`, `Log`, `RegisterLayout` (models + level-entity edits),
  `SpawnStatic`. Per-mod error isolation; log at `Saved Games\Sniper Ghost Warrior 3\sgw3_mods.log`.
- Autoload of `Scripts/AutoLoad/<mod>/init.lua` across all paks.
- Optional fallback pak for setups without an ASI loader (built locally from the player's own game files).

### Mods
- Bunny Hop: hold-to-hop, Quake-style air strafing, live tuning, F6 toggle.
- Trainer: god mode, infinite health/ammo, invisibility, freeze AI, teleports, noclip, world settings,
  NPC spawner (407 types), Lua debug console. ImGui overlay (Insert).
- Map Editor: fly-cam, model placement with X/Y/Z gizmo, editing of existing level entities, per-level autosave,
  export to standalone layout paks.
