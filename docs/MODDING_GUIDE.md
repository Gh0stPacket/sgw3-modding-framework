# SGW3 Modding Guide

How to write mods for the SGW3 Modding Framework (Sniper Ghost Warrior 3, GOG build 3.8.6.53). Players: see
[INSTALL.md](INSTALL.md).

## Make a mod

A mod is a `.pak` (a plain ZIP; stored or deflate) with an entry point:

```
zzz_mymod.pak
└── Scripts/AutoLoad/mymod/init.lua      <- run by the framework at startup
    Scripts/MyMod/...                    <- your other scripts (load with Script.ReloadScript)
    Objects/..., Textures/..., ...       <- your own assets, in your own folders
```

`Scripts/AutoLoad/<name>.lua` (a single file) also works. Entry points run in name order; prefix with digits
(`10_mylib`) if another mod must load yours first.

Minimal mod (`examples/hello_world`):

```lua
SGW3.RegisterMod{ name = "Hello World", version = "1.0", author = "you" }

SGW3.OnLevelLoad("hello_world", function(level)
  SGW3.Log("hello_world", "entered level " .. level)
end)

SGW3.OnTick("hello_world", function(player, dt)
  if player and SGW3.KeyPressed(0x78) then   -- F9
    local p = player:GetWorldPos()
    SGW3.Log("hello_world", string.format("F9 at %.1f %.1f %.1f", p.x, p.y, p.z))
  end
end)
```

### API

| Call | What it does |
|---|---|
| `SGW3.RegisterMod{name, version, author}` | Lists your mod in `sgw3_mods.log`. |
| `SGW3.OnTick(id, fn(player, dt))` | Every frame. `player` is `g_localActor` or `nil` in menus. Re-armed automatically after deaths, checkpoints and level loads. |
| `SGW3.OnLevelLoad(id, fn(level))` | Level start, checkpoint reload, respawn. `level` is the map name, e.g. `Mining_Town_2k`. |
| `SGW3.IsKeyDown(vk)` / `SGW3.KeyPressed(vk)` | Keyboard state by [Windows virtual-key code](https://learn.microsoft.com/windows/win32/inputdev/virtual-key-codes); only while the game window is focused. `KeyPressed` is true on the first frame only. |
| `SGW3.Player()` / `SGW3.Level()` | Local player entity / current map name. |
| `SGW3.Log(id, msg)` | Append to `sgw3_mods.log`. |
| `SGW3.RegisterLayout(name, {level, objects, edits})` | Applied whenever `level` loads (what map-editor exports use). `objects`: static models to spawn, `{model = "objects/...cgf", x, y, z, rx, ry, rz, s}` (degrees, scale). `edits`: changes to existing level entities by name, `{name = "BasicEntity65", x, y, z, rx, ry, rz, s, hidden}`, re-applied for 20 s after each load because checkpoints restore entities. |
| `SGW3.SpawnStatic(entityName, object)` | Spawn one static model now. |
| `SGW3.version` | Framework version string. |

Every callback runs in its own `pcall`: an error in your mod is logged (rate-limited) and doesn't stop other mods.
Using the same `id` again replaces your callback, which makes hot reloading easy.

### Compatibility rules

- **Never ship `Scripts/main.lua`** or other game files unless your mod is *meant* to replace them. Keep your
  scripts under your own folder name.
- Wrap game functions instead of replacing them, and call the original:
  ```lua
  local orig = SinglePlayer.ProcessActorDamage
  SinglePlayer.ProcessActorDamage = function(self, hit) --[[ ... ]] return orig(self, hit) end
  ```
- Namespace your globals (`MYMOD = MYMOD or {}`).
- Changing cvars? Save the old value and restore it when your feature turns off.
- Pak names starting with `zzz_` load after the game's own paks.

### Useful game facts (SGW3 3.8.6.53)

- Lua 5.1, numbers are 32-bit floats. The game's own scripts are bytecode; decompile them with unluac to read them.
- Damage is applied in Lua: `SinglePlayer:ProcessActorDamage(hit)`.
- Spawn characters: `System.SpawnEntity{class = "ci_human", archetype = "Pro_Russians.Soldiers.Regular", position = ...}`,
  then `e:Activate(1); e:Event_Enable()`. Archetypes live in `GameData/Libs/EntityArchetypes/*.xml`.
- Static props: class `BasicEntity` with `Properties.object_Model`.
- Cheat cvars (`g_godMode`, `g_infiniteAmmo`, `ai_IgnorePlayer`, `g_detachCamera`...) are locked in this release.
- `System.ProjectToScreen(v)` returns a virtual 800x600 screen position; `actor:PlayerSetViewAngles` takes radians.

### Packaging

Any ZIP tool works; keep the paths inside the archive relative to `GameSDK` (`Scripts/AutoLoad/mymod/init.lua`).
Name it `zzz_<mymod>.pak` and drop it into `<game>\GameSDK\`. `tools/build.py` shows how this repo packs its own
mods.

### Iterating quickly

Build the dev pak (`python tools/build.py --dev`) and set two environment variables before starting the game:
`SGW3_DEV_DIR` (a writable folder) and `SGW3_DEV_SRC` (this repo's root). Then:

- `<SGW3_DEV_DIR>\log.txt` collects `BHOP_LOG` output;
- creating `<SGW3_DEV_DIR>\exec.lua` runs that file once inside the game (handy for probing the API);
- creating `<SGW3_DEV_DIR>\reload.txt` hot-reloads the bundled mods from `SGW3_DEV_SRC`.

The trainer's **Console** tab also runs Lua typed into it, and prints `SGW3.Log` output from every mod.

### Reading the game's own scripts

The game's scripts are compiled Lua 5.1 (32-bit float numbers) inside `GameSDK\Scripts*.pak`. Extract them with
`python tools/extract_paks.py "<game>" <out>`, decompile with [unluac](https://sourceforge.net/projects/unluac/),
and convert binary XML with `python tools/cryxml.py <folder>`. Keep that output out of anything you publish.
[RE_NOTES.md](RE_NOTES.md) collects what is known about the engine.

## How it works

`sgw3_modloader.asi` hooks the game's statically linked `lua_load`. When `Scripts/main.lua` finishes compiling
(whichever pak it came from), it compiles and runs the embedded framework, which scans `Scripts/AutoLoad` across
all paks and runs each entry point. It also writes the keyboard state into the process environment
(`SGW3_KEYS`), which Lua reads with `os.getenv`. The function addresses are checked against known byte
signatures; on another game build the loader logs a mismatch and stays inactive instead of crashing.
