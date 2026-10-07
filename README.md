# SGW3 Modding Framework

[![Build](https://github.com/Gh0stPacket/sgw3-modding-framework/actions/workflows/build.yml/badge.svg)](https://github.com/Gh0stPacket/sgw3-modding-framework/actions/workflows/build.yml)
![Game](https://img.shields.io/badge/Sniper%20Ghost%20Warrior%203-3.8.6.53%20(GOG)-informational)
![License](https://img.shields.io/badge/license-MIT-blue)
![Vibecoded](https://img.shields.io/badge/vibecoded-built%20with%20Claude-8A2BE2)

[![made with universal-modder](https://raw.githubusercontent.com/rehan-remade/universal-modder/main/docs/media/made-with-dark.svg)](https://github.com/rehan-remade/universal-modder)

A Lua modding framework for **Sniper Ghost Warrior 3**, plus a set of mods built on it: a Quake-style bunny hop, an
ImGui trainer with a debug console, an NPC spawner, and an in-game map editor that can export layouts as mods.

> **🤖 This project is vibecoded.** Almost all of the code, reverse engineering and documentation was written by
> an AI ([Claude](https://www.anthropic.com/claude), via Claude Code), directed and play-tested by a human. Every
> feature was tested in the real game, but the code has not been audited line by line. Read
> [AI disclosure](docs/AI_DISCLOSURE.md) before relying on it, and please report anything odd.

# USE AT YOUR OWN RISK!! 
**I have not audited the majority of the code in this project. This was primarily an experiment to see how far I could take modding in Claude Code with minimal human interference. As a mod developer I do not endorse the use of AI/Machine learning in mod development, but I do see that there could be some use for it for creating mod frameworks and tools.**

## What it does

- **Mods without replacing game files.** `sgw3_modloader.asi` hooks the game's Lua loader and starts the
  framework itself, so any number of mods load side by side, even next to mods that replace `Scripts/main.lua`.
- **A small, stable API.** Per-frame ticks that survive deaths, checkpoints and level loads; level-load events;
  keyboard input; logging; and placing/editing objects in levels. Each mod runs isolated: one broken mod can't
  stop the others.
- **Drop-in mods.** A mod is a `.pak` with `Scripts/AutoLoad/<mod>/init.lua`. That's it.

```lua
SGW3.RegisterMod{ name = "Hello World", version = "1.0", author = "you" }
SGW3.OnLevelLoad("hello_world", function(level) SGW3.Log("hello_world", "entered " .. level) end)
SGW3.OnTick("hello_world", function(player, dt)
  if player and SGW3.KeyPressed(0x78) then SGW3.Log("hello_world", "F9 pressed") end   -- F9
end)
```

### Included mods

| Mod | What it does |
|---|---|
| **Bunny Hop** | Hold Space to keep hopping without losing speed; build speed by strafing with A/D + mouse (Quake-style). F6 toggles. |
| **Trainer** (Insert) | God mode, infinite health/ammo, invisible to enemies, freeze AI, teleports, noclip, time scale / time of day / FOV, bhop tuning, NPC spawner (407 character types), Lua debug console. |
| **Map Editor** | Fly-cam editor inside the game: place any of ~9,900 models, move them with X/Y/Z arrows, edit existing level entities, autosave per level, export layouts as standalone mod paks. |

## Install (players)

Requires **Sniper Ghost Warrior 3 3.8.6.53** (GOG). Other builds: the loader detects the mismatch and stays off.

1. Install [Ultimate ASI Loader](https://github.com/ThirteenAG/Ultimate-ASI-Loader/releases) x64: copy its
   `dinput8.dll` into `<game>\win_x64\`.
2. From the [latest release](https://github.com/Gh0stPacket/sgw3-modding-framework/releases), extract
   **SGW3-Mod-Framework** into the game folder (adds `win_x64\sgw3_modloader.asi`).
3. Optional: extract **SGW3-Mods** too (bunny hop, trainer, map editor).

Logs: `%USERPROFILE%\Saved Games\Sniper Ghost Warrior 3\sgw3_mods.log`. Details: [docs/INSTALL.md](docs/INSTALL.md).

## Make a mod

Start with [docs/MODDING_GUIDE.md](docs/MODDING_GUIDE.md): API reference, pak layout, compatibility rules and
game facts. The [hello world example](framework/examples/hello_world) is a complete mod.

## Build from source

Windows, Visual Studio 2022 (C++ workload), CMake 3.21+, Python 3.10+.

```bash
git clone --recurse-submodules https://github.com/Gh0stPacket/sgw3-modding-framework
cd sgw3-modding-framework
python tools/build.py
cmake -B build -A x64
cmake --build build --config Release
python tools/package.py 1.0.0
```

See [CONTRIBUTING.md](CONTRIBUTING.md) for the dev workflow (hot reload, in-game exec) and repository rules.

## Repository layout

```
modloader/        sgw3_modloader.asi - Lua injection + keyboard bridge (the framework core)
framework/        Framework.lua (the SGW3 API) and examples
mods/bhop/        Bunny Hop
mods/trainer/     Trainer + map editor (Lua) and the ImGui overlay (native/)
tools/            build, packaging, pak extraction, CryXmlB decoding, Lua-API locator, catalog generation
docs/             guides, RE notes, AI disclosure
deps/             Dear ImGui, MinHook (git submodules)
```

## Credits

- **[universal-modder](https://github.com/rehan-remade/universal-modder)** by rehan-remade: the Claude Code
  plugin this project was built with. Its recon, reverse-engineering, game-automation (in-game screenshots and
  input for testing) and publishing guidance drove the whole workflow.
- **[Claude](https://www.anthropic.com/claude)** (Anthropic), via Claude Code: wrote the code, the reverse
  engineering and the docs. See [AI disclosure](docs/AI_DISCLOSURE.md).
- **[Ultimate ASI Loader](https://github.com/ThirteenAG/Ultimate-ASI-Loader)** by ThirteenAG: loads the plugins.
- **[Dear ImGui](https://github.com/ocornut/imgui)** by Omar Cornut: trainer and editor UI.
- **[MinHook](https://github.com/TsudaKageyu/minhook)** by Tsuda Kageyu: function hooking.
- **[unluac](https://sourceforge.net/projects/unluac/)** and **[Capstone](https://www.capstone-engine.org/)**: used
  to read the game's Lua bytecode and locate the Lua API in the executable (not distributed).
- **Sniper Ghost Warrior 3** by CI Games, built on CRYENGINE.

## Disclaimer

Fan project, **not affiliated with or endorsed by CI Games**. Single-player only. No game files are included or
distributed; the tools read your own installation. Use at your own risk and back up your saves
(`%USERPROFILE%\Saved Games\Sniper Ghost Warrior 3`).

## License

[MIT](LICENSE). Third-party components: see [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
