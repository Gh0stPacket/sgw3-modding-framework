# Third-party notices

## Included (git submodules, compiled into the plugins)

| Component | Use | License |
|---|---|---|
| [Dear ImGui](https://github.com/ocornut/imgui) v1.91.9 | Trainer and editor UI (`sgw3_trainer.asi`) | MIT, Copyright (c) 2014-2025 Omar Cornut |
| [MinHook](https://github.com/TsudaKageyu/minhook) | Function hooking (both plugins) | BSD 2-Clause, Copyright (c) 2009-2017 Tsuda Kageyu |

Full license texts are in `deps/imgui/LICENSE.txt` and `deps/minhook/LICENSE.txt`.

## Required at runtime (not included)

| Component | Use | License |
|---|---|---|
| [Ultimate ASI Loader](https://github.com/ThirteenAG/Ultimate-ASI-Loader) | Loads `.asi` plugins into the game | MIT, ThirteenAG |

## Used during development (not included)

| Component | Use |
|---|---|
| [universal-modder](https://github.com/rehan-remade/universal-modder) | Claude Code plugin: modding workflow, in-game automation, publishing checks (MIT) |
| [unluac](https://sourceforge.net/projects/unluac/) | Reading the game's Lua 5.1 bytecode |
| [Capstone](https://www.capstone-engine.org/) | Disassembly in `tools/find_lua_api.py` (BSD) |

## The game

Sniper Ghost Warrior 3 is © CI Games S.A., built on CRYENGINE. This project contains no game files and is not
affiliated with or endorsed by CI Games or Crytek.
