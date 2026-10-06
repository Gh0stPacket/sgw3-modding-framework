# AI disclosure

This project is **vibecoded**: built by directing an AI rather than by writing the code by hand.

## Who did what

- **AI ([Claude](https://www.anthropic.com/claude) by Anthropic, through Claude Code):** reverse engineering of
  the game (pak and binary XML formats, Lua runtime, locating `lua_load` / `lua_pcall` in the executable), all
  source code (C++ plugins, Lua framework and mods, Python tools), the build system and the documentation.
  Commits carry a `Co-Authored-By: Claude` trailer.
- **Human ([Gh0stPacket](https://github.com/Gh0stPacket)):** the ideas and direction, every feature request and
  design decision, and play-testing in the real game.
- **Tooling:** the [universal-modder](https://github.com/rehan-remade/universal-modder) Claude Code plugin,
  which provided the modding workflow (game recon, reverse-engineering methods, automated in-game testing with
  screenshots and input, publishing checks).

## How it was checked

Each feature was exercised in Sniper Ghost Warrior 3 (3.8.6.53, GOG) before it was considered done: crashes were
diagnosed from Windows error reports, behaviour from in-game logs and screenshots. Examples: the loader was tested
next to a mod that replaces `Scripts/main.lua`; map-editor exports were tested with only the exported pak
installed; world edits were tested against simulated checkpoint reloads.

## What that means for you

- The code works in the cases that were tested. It has **not** had a line-by-line human review or a security audit.
- The native plugins hook game functions in memory. They check the game build before hooking and stay inactive
  on a mismatch, but treat them like any other game mod: single-player, at your own risk, saves backed up.
- Bug reports and reviews are very welcome. If you find something the AI got wrong, please open an issue.
