# Installing the SGW3 Modding Framework

Supported game: **Sniper Ghost Warrior 3 3.8.6.53 (GOG)**. On any other build the loader writes a signature
mismatch to its log and does nothing.

## Framework (required for every mod)

1. **Ultimate ASI Loader** (x64): download from
   [ThirteenAG/Ultimate-ASI-Loader](https://github.com/ThirteenAG/Ultimate-ASI-Loader/releases) and copy
   `dinput8.dll` into `<game folder>\win_x64\`.
2. Extract **SGW3-Mod-Framework-x.y.z.zip** into `<game folder>`; this places `win_x64\sgw3_modloader.asi`.
3. Start the game. `%USERPROFILE%\Saved Games\Sniper Ghost Warrior 3\sgw3_modloader.log` should contain
   `hooked lua_load` and `framework injected`.

## Mods

Copy mod `.pak` files into `<game folder>\GameSDK\`. Mods that also ship native files (`.asi`) go into
`<game folder>\win_x64\`. Release zips are laid out like the game folder, so extracting into the game folder
puts everything in place.

`%USERPROFILE%\Saved Games\Sniper Ghost Warrior 3\sgw3_mods.log` lists the mods that loaded and any errors.

## Uninstall

Delete `win_x64\sgw3_modloader.asi`, the mods' `.pak` / `.asi` files, and (if nothing else uses it) the ASI
loader's `dinput8.dll`. The game's own files are never modified.

## Troubleshooting

| Symptom | Check |
|---|---|
| No `sgw3_modloader.log` | ASI loader missing or not x64; `dinput8.dll` must be in `win_x64`. |
| `signature mismatch` in the log | Unsupported game build. |
| A mod isn't listed in `sgw3_mods.log` | Its pak must contain `Scripts/AutoLoad/<name>/init.lua` (or `Scripts/AutoLoad/<name>.lua`). |
| `error in ... (xN)` lines | That mod raised a Lua error; other mods keep running. Report it to the mod's author. |
