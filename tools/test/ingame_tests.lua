-- In-game release tests. Run by tools/test/release_test.py through the dev mod's exec hook
-- (<SGW3_DEV_DIR>/exec.lua). Writes "PASS|FAIL <name> <detail>" lines and a final "DONE" to
-- <SGW3_DEV_DIR>/test_results.txt. Everything a test creates is removed again; the player's own editor
-- edits are left alone.

local DIR = os.getenv("SGW3_DEV_DIR"):gsub("\\", "/"):gsub("/?$", "/")
local OUT = DIR .. "test_results.txt"
do local f = io.open(OUT, "w"); f:close() end
local function res(ok, name, detail)
  local f = io.open(OUT, "a")
  f:write((ok and "PASS " or "FAIL ") .. name .. " " .. tostring(detail or "") .. "\n")
  f:close()
end
local function try(name, fn) local ok, err = pcall(fn); if not ok then res(false, name, "error: " .. tostring(err)) end end
local p = g_localActor
local T, E = TRAINER, EDITOR
local steps = {}
local function step(delay, fn) steps[#steps + 1] = { delay = delay, fn = fn } end
local function run(i)
  local s = steps[i]
  if not s then local f = io.open(OUT, "a"); f:write("DONE\n"); f:close(); return end
  Script.SetTimer(s.delay, function() try("step" .. i, s.fn); run(i + 1) end)
end

-- framework ------------------------------------------------------------------------------------------
local frame0
step(0, function()
  res(SGW3 and SGW3.version ~= nil, "framework.loaded", SGW3 and SGW3.version)
  local names = {}
  for _, m in ipairs(SGW3.mods) do names[#names + 1] = m.name end
  local all = table.concat(names, ", ")
  res(all:find("SGW3 Bunny Hop", 1, true) and all:find("SGW3 Trainer", 1, true) and all:find("SGW3 Map Editor", 1, true),
    "framework.mods_registered", all)
  res(p ~= nil and p.actor ~= nil, "framework.player_present", tostring(SGW3.Level()))
  frame0 = SGW3.frame
end)
step(1000, function() res(SGW3.frame > frame0, "framework.tick_running", (SGW3.frame - frame0) .. " frames/s") end)

-- bhop ---------------------------------------------------------------------------------------------
step(0, function()
  res(BHOP and BHOP.S and BHOP.S.enabled, "bhop.enabled")
  res(tostring((System.GetCVar("pl_jump_baseTimeAddedPerJump"))) == "0", "bhop.antibhop_timer_disabled")
end)

-- god mode: a real damage call is blocked -------------------------------------------------------------
local godWas, hp0
step(0, function() godWas = T.feat.god; T.feat.god = true end)
step(500, function()
  local hooked = SinglePlayer.ProcessActorDamage == T.padHook
  res(hooked, "god.damage_hook_installed")
  if not hooked then T.feat.god = godWas; return end   -- never send real damage without the hook
  hp0 = p.actor:GetHealth()
  local died = SinglePlayer:ProcessActorDamage({ target = p, shooter = p, damage = 50, type = "melee", pos = p:GetWorldPos(), dir = {x = 0, y = 0, z = -1} })
  res(p.actor:GetHealth() >= hp0, "god.blocks_damage", string.format("hp %.0f -> %.0f, died=%s", hp0, p.actor:GetHealth(), tostring(died)))
  T.feat.god = godWas
end)

-- infinite ammo ------------------------------------------------------------------------------------
local ammoWas
step(0, function()
  local w = p.inventory:GetCurrentItem() and p.inventory:GetCurrentItem().weapon
  if not w then res(false, "ammo.refill", "no weapon equipped"); return end
  ammoWas = T.feat.ammo
  w:SetAmmoCount(nil, 1)
  T.feat.ammo = true
end)
step(600, function()
  local w = p.inventory:GetCurrentItem() and p.inventory:GetCurrentItem().weapon
  if w then res(w:GetAmmoCount() == w:GetClipSize(), "ammo.refill", w:GetAmmoCount() .. "/" .. w:GetClipSize()) end
  T.feat.ammo = ammoWas or false
end)

-- invisibility ------------------------------------------------------------------------------------
local invWas
step(0, function()
  invWas = T.feat.invisible
  T.feat.invisible = true; T.apply_invisible(true)
  res(AI.GetFactionOf(p.id) == "Cinematic", "invisible.faction", AI.GetFactionOf(p.id))
  res(tostring((System.GetCVar("ai_PlayerCamouflage"))) == "1", "invisible.camouflage")
  T.feat.invisible = false; T.apply_invisible(true)
  res(AI.GetFactionOf(p.id) == "Players" and tostring((System.GetCVar("ai_CamoThreshold"))) == "0.5", "invisible.restored",
    AI.GetFactionOf(p.id) .. " thr=" .. tostring((System.GetCVar("ai_CamoThreshold"))))
  T.feat.invisible = invWas
  if invWas then T.apply_invisible(true) end
end)

-- NPC spawner --------------------------------------------------------------------------------------
local spawnedBefore
step(0, function()
  spawnedBefore = #T.spawned
  T.spawn("Civilians.Male.City_1", "ci_human", 1, "front", "face")
  local e = System.GetEntity(T.spawned[#T.spawned])
  res(#T.spawned == spawnedBefore + 1 and e and e.actor and e.actor:GetHealth() > 0, "spawner.spawn", e and e:GetName())
end)
local removedId
step(500, function()
  removedId = T.spawned[#T.spawned]
  System.RemoveEntity(removedId)   -- CryEngine removes entities at the end of the frame
  table.remove(T.spawned)
end)
step(300, function() res(System.GetEntity(removedId) == nil, "spawner.remove") end)

-- map editor: place, export, clean up ------------------------------------------------------------------
local placed
local exportDir = os.getenv("USERPROFILE") .. "/Saved Games/Sniper Ghost Warrior 3/"
step(0, function()
  placed = E.place("Objects/outpost/metal_barrel_2/metal_barrel_red.cgf", p:GetWorldPos())
  res(placed and System.GetEntity(E.objs[placed].id) ~= nil, "editor.place", placed)
  E.export("release_test")
end)
step(2000, function()
  local f = io.open(exportDir .. "exports/zzz_layout_release_test.pak", "rb")
  local head = f and f:read(4)
  if f then f:close() end
  res(head == "PK\3\4", "editor.export_pak", "exports/zzz_layout_release_test.pak")
  os.remove(exportDir .. "exports/zzz_layout_release_test.pak")
  os.remove(exportDir .. "exports/zzz_layout_release_test_README.txt")
  os.remove(exportDir .. "export_release_test.lua")
  if placed then E.sel = placed; T.feats.eddel(); E.dirty = true end
  res(placed == nil or E.objs[placed] == nil, "editor.cleanup")
end)

run(1)
