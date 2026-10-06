# SGW3 reverse-engineering notes

Research log behind the framework (SGW3 3.8.6.53, GOG, PE timestamp 2018-06-21). Facts marked VERIFIED were checked in game. Game data itself is not part of this repository; extract it from your own install with `tools/extract_paks.py` and `tools/cryxml.py`.

Exe: `win_x64\SGW3.exe` v3.8.6.53, PE timestamp 2018-06-21, imagebase 0x140000000

## Engine
- CryEngine (5.x-era "CRYENGINE GAME SDK" + Mannequin), **monolithic**: CryGame/CryAction/
  CrySystem/Physics statically linked into SGW3.exe (uber_files build). Separate DLLs only for
  renderer (CryRenderD3D11.dll / OpenGL) and audio (CryAudioImplWwise.dll).
- Internal PDB path: `j:\Projekty\SGW3_MP\S3\trunk\BinTemp\win_x64_release\...\GameSDK.pdb` (not shipped).
- 31 named exports usable as anchors: CreateGameFramework, CreateSystemInterface, ModuleInitISystem,
  CreateGame, CreateGameStartup, CreatePhysicalWorld, CreateNetwork, CryMalloc...
- No anti-cheat, no DRM wrapper (GOG). Plain x64 MSVC.
- ~56k printable strings; ~936 g_/pl_/i_/w_ cvar names; DevMode code present
  (CDevMode, "nodevmode", IsDevModeEnable).

## Pak format
- `.pak` = plain ZIP, **unencrypted**, store(0)/deflate(8).
- Quirk: local headers use `\`, central directory uses `/` -> Python zipfile raises
  "File name in directory ... differ"; tools/extract_paks.py reads the local name.
- Patch layering: `Name.pak`, then `Name.p1.pak` ... `Name.pN.pak` (higher overrides — assumed, verify in game).
- Large: Textures-*, Objects-*, Animations*, Sounds* (Wwise), Videos*. Each level: level.pak / levelmm.pak /
  terraintexture.pak. `GameSDK/preload/*.data/.header` = separate streaming format (not examined).

## Data formats
- **CryXmlB** binary XML (7,200 files, 0 failures via tools/cryxml.py):
  "CryXmlB\0" + 9×u32 (fileSize, nodePos, nodeCnt, attrPos, attrCnt, childPos, childCnt, strPos, strSize);
  node = 28 B `<IIHHiIII` (tag, content, nAttr, nChild, parent, firstAttr, firstChildIdx, pad);
  attr = 8 B (keyOff, valOff); child table = u32 node indices. No writer yet (only needed if text XML is rejected).
- **Lua**: 459 files are Lua 5.1 bytecode, header int=4, size_t=8, Instruction=4, **lua_Number=4 (float)**.
  Decompiled with unluac (unluac) : 459/459 OK.
  Debug info stripped, so locals are L0_1-style; logic intact.
  2 shipped .lua are **plain source** (Libs/ReverbPresets/ReverbPresetDB.lua,
  Entities/Vehicles/Implementations/kamaz_barrel.lua) -> loader accepts text Lua; edited scripts likely need no recompile (verify).
- `.dlg` (3,709) dialogue, `.mtl` materials, `.ent` entity defs, `.gfx` Scaleform UI.

## Gameplay data map (paths under paks/)
- Difficulty: `GameData/Difficulty/{easy,normal,hard,delta,posthuman}.cfg` (cvar scripts: AI ROD, regen,
  health thresholds) + `Scripts/Scripts/difficulty.xml` (per-difficulty UI options).
- Weapons: `Scripts/Scripts/Entities/Items/XML/Weapons/<Category>/*.xml`. Fire modes from
  `WeaponCacheBalance.xml` / `WeaponCacheStats.xml` (~99k lines) when `use_weapon_cache_firemodes=1`.
- Ammo/ballistics: `Scripts/Scripts/Entities/Items/XML/Ammo/**` — base_damage (SP/MP), base_damage_ai,
  base_damage_armored, speed, mass, gravity (SP -9.81 / MP -13).
- Body damage multipliers: `GameData/Libs/BodyDamage/*.xml`; loadouts: `GameData/Libs/EquipmentPacks`.
- Hidden debug weapon: `SniperRifles/SilencedDebugSniperRifle.xml` ("SDSR", "UBER WEAPON").
- `Scripts/Scripts/DataPatcher/patchablecvars.txt`: whitelist of patch-tunable cvars.
- Tweak menu: `Tweaks.lua`, `TweakSystem.lua`, `TweaksConfig.lua` (cvars g_TweakProfile, g_TweakComment).

## Mod loading (VERIFIED in game 2026-10-06)
- Exe mounts `GameSDK\*.pak` by wildcard (string `%s\*.pak`), so any new pak in GameSDK loads.
- Test: two paks each overriding `Scripts/main.lua` (= decompiled text + marker that io.open-writes a file).
  `zzz_paktest.pak` WON over `Scripts.p8.pak` -> name mod paks `zzz_<mod>.pak`.
  Internal path is relative to GameSDK, forward slashes OK (`Scripts/main.lua`), deflate OK.
- Plain-text Lua is accepted in place of bytecode. Lua `io` library is available (file writes work).
- Marker appeared ~10 s after launch (before intro videos end); game loaded to "GAME STARTING" normally.
- Not yet tested: text XML overriding binary CryXmlB (e.g. weapon/ammo XML).

## Next steps
1. Test a text-XML override (ammo base_damage) via zzz pak.
2. Read lua_decomp actor/ and Items/ scripts.
3. IDA: anchor on cvar registration strings (e.g. "pl_movement.speedScale") to find CGame/CPlayer,
   gEnv, and the damage pipeline (HitInfo -> CActor::Damage).

## Lua runtime facts (VERIFIED in game 2026-10-06, bhop mod work)
- Sandbox: io/os/debug present. `package.loadlib` is a stub ("dynamic libraries not enabled") -> no native code from Lua.
- Input: no Lua key API. Bridge = `bhop_input.asi` (Ultimate ASI Loader) polls GetAsyncKeyState and `_putenv_s`
  a bitmask into SGW3_BHOP_KEYS; Lua reads it with `os.getenv` (exe imports shared UCRT getenv; ASI built /MD).
  Injected scancode input (SendInput) is seen by GetAsyncKeyState.
- Per-frame tick: `Script.SetTimer(0, fn)` chain (~1 call/frame). Level loads AND checkpoint/death reloads wipe it.
  Re-arm from Player hooks (OnReset/OnInit/OnLoad/OnPostLoad/OnResetLoad/OnSpawn/Revive). Entity timers
  (self:SetTimer -> Player.Client.OnTimer) never fired. Player.OnUpdateView is never called.
- Wrapping functions on the global `Player` class table at main.lua time affects the spawned player.
- Player: `g_localActor`, `p:GetVelocity()` returns {x,y,z}, `p:SetVelocity(v)` works (incl. launching from ground),
  `p:AddImpulse` is ~ignored on the living entity in air and per-tick air impulses broke jumps.
  `p.actor:IsFalling()` stays false during jumps. Ground test: Physics.RayWorldIntersection down 0.5 m from pos+0.2.
  Physics: mass 120, gravity -13. Game jump = vz 6.0 m/s.
- Mid-air SetVelocity trips the hands-to-ground stumble unless pl_health.enable_FallandPlay=0.
  Other relevant cvars: pl_movement.ground_timeInAirToFall (0.1), pl_fallHeight (0.7),
  pl_jump_control.air_control_scale (1) / air_resistance_scale (1.3), anti-bhop pl_jump_baseTimeAddedPerJump (0.4),
  pl_jump_currentTimeMultiplierOnJump (1.5). Checkpoint loads re-apply game cvar values -> re-assert periodically.
- `actor:SetHealth(0)` is NOT a real death (no reload; leaves broken state). Don't use for tests.

## Trainer / editor facts (VERIFIED in game 2026-10-06)
- Cheat cvars locked in release (g_godMode, g_infiniteAmmo, ai_IgnorePlayer, ai_NoUpdate, g_detachCamera...); `-devmode` is stripped.
  Settable: t_Scale, e_TimeOfDay(+Speed), cl_fov, ai_PlayerCamouflage/ai_CamoThreshold/ai_OpengroundVisibilityBoost.
- Damage is applied in Lua: SinglePlayer:ProcessActorDamage(hit) (hit.target = entity) -> wrap for god mode.
- Ammo: inventory:GetCurrentItem().weapon:GetClipSize()/GetAmmoCount()/SetAmmoCount(nil, n).
- AI: factions in Scripts/AI/Factions.xml ("Cinematic" neutral to all); AI.SetFactionOf, SetIgnorant, ChangeParameter(AIPARAM_PERCEPTIONSCALE_*).
- Spawning: System.SpawnEntity{class, archetype="Lib.Group.Name", position, orientation}; then e:Activate(1), e:Event_Enable() (as AIWave).
  Archetypes: GameData/Libs/EntityArchetypes/*.xml (407 actor entries -> trainer/src/spawn_catalog.h).
- Static props: class BasicEntity, Properties.object_Model = .cgf, Physics.bRigidBody=0. 9949 models -> trainer/sgw3_models.txt.
- System.ProjectToScreen(v) -> {x,y} on a virtual 800x600 screen, z<1 in front. GetViewCameraAngles in degrees;
  actor:PlayerSetViewAngles takes RADIANS (relative changes map 1:1). FOV 1.396 rad.
- Game bundles an old MSVCP140 (14.0.24210): ASIs must link the C++ runtime statically (/MT + shared ucrt.lib).

## Shared autoloader + layout export (VERIFIED in game 2026-10-06)
- Every mod pak ships the same Scripts/main.lua = original + src/loader_main.lua, which runs Scripts/AutoLoad/*.lua
  in name order (System.ScanDirectory("Scripts/AutoLoad", SCANDIR_FILES) sees files across all paks, lowercased).
  So any number of our paks coexist regardless of which main.lua wins. Dev hooks = AutoLoad/00_devhooks.lua.
- Level name: System.GetCVar("sv_map") (e.g. Mining_Town_2k).
- Editor autosave: Saved Games\Sniper Ghost Warrior 3\editor_level_<map>.lua, restored on level/checkpoint load.
- Export: overlay packs exports\zzz_layout_<name>.pak = main.lua loader + AutoLoad/10_layout_runtime.lua +
  AutoLoad/20_layout_<name>.lua (stored zip written by trainer/src/export_pak.h). Verified standalone: with only
  the layout pak installed (trainer pak removed) the objects spawn on level load.
