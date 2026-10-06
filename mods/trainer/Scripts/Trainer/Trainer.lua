-- SGW3 Trainer: in-game half of sgw3_trainer.asi.
-- ASI -> Lua: environment variable SGW3_TR_CMD = "<seq>\31<cmd>\30<cmd>..." (polled every frame).
-- Lua -> ASI: named pipe \\.\pipe\sgw3_trainer, one message per line:
--   "ack <seq>", "out <text>", "err <text>", "state k=v;k=v;..."

TRAINER = TRAINER or {}
local T = TRAINER
local PIPE = "\\\\.\\pipe\\sgw3_trainer"
T.feat = T.feat or {}
for k, v in pairs({ infhealth = false, menu = false, god = false, ammo = false, invisible = false, noclip = false, aifreeze = false }) do
  if T.feat[k] == nil then T.feat[k] = v end
end
T.noclipSpeed = T.noclipSpeed or 12
T.slots = T.slots or {}
T.lastSeq = T.lastSeq or nil
T.frame = T.frame or 0
T.nextOpen = 0

local function now() return System.GetCurrAsyncTime and System.GetCurrAsyncTime() or os.clock() end

local function pipe_write(line)
  if not T.pipe then
    if now() < T.nextOpen then return false end
    T.nextOpen = now() + 2
    for _, mode in ipairs({"r+b", "ab", "wb"}) do
      local ok, f = pcall(io.open, PIPE, mode)
      if ok and f then T.pipe = f; break end
    end
    if not T.pipe then return false end
  end
  local ok = pcall(function() T.pipe:write(line, "\n"); T.pipe:flush() end)
  if not ok then pcall(function() T.pipe:close() end); T.pipe = nil end
  return ok
end

function T.out(kind, text)
  for line in (tostring(text) .. "\n"):gmatch("([^\n]*)\n") do pipe_write(kind .. " " .. line) end
end

-- route Lua print and the mods' logs into the trainer console
if not T.printHooked then
  T.printHooked = true
  local origPrint = print
  print = function(...)
    local parts = {}
    for i = 1, select("#", ...) do parts[#parts + 1] = tostring((select(i, ...))) end
    T.out("out", table.concat(parts, "\t"))
    if origPrint then pcall(origPrint, ...) end
  end
  local origLog = BHOP_LOG
  BHOP_LOG = function(s)
    T.out("out", "[bhop] " .. tostring(s))
    if origLog then origLog(s) end
  end
  -- framework log lines (every mod's SGW3.Log and callback errors) also show in the trainer console
  local origFLog = SGW3.Log
  SGW3.Log = function(mod, msg)
    T.out("out", "[" .. tostring(mod) .. "] " .. tostring(msg))
    return origFLog(mod, msg)
  end
end

local function show(v, depth)
  depth = depth or 0
  if type(v) ~= "table" or depth > 1 then return tostring(v) end
  local items, n = {}, 0
  for k, x in pairs(v) do
    n = n + 1
    if n > 40 then items[#items + 1] = "..."; break end
    items[#items + 1] = tostring(k) .. "=" .. show(x, depth + 1)
  end
  return "{" .. table.concat(items, ", ") .. "}"
end

local function run_lua(code)
  local f, err = loadstring("return " .. code, "console")
  if not f then f, err = loadstring(code, "console") end
  if not f then T.out("err", err); return end
  local res = { pcall(f) }
  if not res[1] then T.out("err", res[2]); return end
  if #res > 1 then
    local parts = {}
    for i = 2, #res do parts[#parts + 1] = show(res[i]) end
    T.out("out", table.concat(parts, "  "))
  end
end

local function player() return rawget(_G, "g_localActor") end
-- GetCVar returns nothing (not nil) for unknown cvars, which tostring() rejects
local function cvar(name) local v = System.GetCVar(name); return tostring(v) end

local function set_menu(open)
  T.feat.menu = open
  pcall(ActionMapManager.EnableActionMap, "player", not open)
  -- every game action (menus, map, tablet...), not just movement; the ASI also blanks DirectInput
  pcall(ActionMapManager.EnableActionMapManager, not open, open)
end

-- the game's cheat cvars (g_godMode, g_infiniteAmmo, ai_IgnorePlayer, ...) are locked in this release build,
-- so these features are implemented here through the game's own Lua hooks and script binds
local function flag(name) return function(v) T.feat[name] = v == "1" end end
local feats = {
  infhealth = flag("infhealth"),
  god = flag("god"),
  ammo = flag("ammo"),
  invisible = function(v)
    T.feat.invisible = v == "1"
    T.apply_invisible(true)
  end,
  aifreeze = function(v)
    T.feat.aifreeze = v == "1"
    T.apply_aifreeze(true)
  end,
  noclip = function(v)
    T.feat.noclip = v == "1"
    local p = player()
    if p and not T.feat.noclip then p:SetVelocity({x = 0, y = 0, z = 0}) end
  end,
  noclipspeed = function(v) T.noclipSpeed = tonumber(v) or T.noclipSpeed end,
  -- spawn <archetype> <class> <count> <aim|front> <face|away>
  spawn = function(v)
    local arch, cls, count, mode, facing = v:match("^(%S+)%s+(%S+)%s+(%d+)%s+(%S+)%s+(%S+)$")
    if not arch then T.out("err", "usage: feat spawn <archetype> <class> <count> <aim|front> <face|away>"); return end
    T.spawn(arch, cls, tonumber(count), mode, facing)
  end,
  despawn = function() T.despawn(false) end,
  killspawned = function() T.despawn(true) end,
  menu = function(v) set_menu(v == "1") end,
  heal = function() local p = player(); if p then p.actor:SetHealth(p.actor:GetMaxHealth()) end end,
  bhop = function(v)
    if BHOP and BHOP.S then
      BHOP.S.enabled = v == "1"; BHOP.S.air = nil
      BHOP.apply_cvars(BHOP.S.enabled)
    end
  end,
  bhopcfg = function(v)
    local key, val = v:match("^(%S+)%s+(%S+)$")
    if BHOP and BHOP.cfg and key and BHOP.cfg[key] ~= nil then BHOP.cfg[key] = tonumber(val) or BHOP.cfg[key] end
  end,
  bhopreset = function()
    if BHOP and BHOP.defaults then
      for k, val in pairs(BHOP.defaults) do BHOP.cfg[k] = val end
      T.out("out", "bhop settings reset to defaults")
    end
  end,
  tp_save = function(v)
    local p = player(); if not p then return end
    local pos = p:GetWorldPos()
    T.slots[v] = {x = pos.x, y = pos.y, z = pos.z}
    T.out("out", string.format("saved slot %s at %.1f %.1f %.1f", v, pos.x, pos.y, pos.z))
  end,
  tp_load = function(v)
    local p, s = player(), T.slots[v]
    if not p then return end
    if not s then T.out("err", "slot " .. v .. " is empty"); return end
    p:SetWorldPos(s); p:SetVelocity({x = 0, y = 0, z = 0})
  end,
  tp_fwd = function(v)
    local p = player(); if not p then return end
    local d, f, pos = tonumber(v) or 10, System.GetViewCameraDir(), p:GetWorldPos()
    p:SetWorldPos({x = pos.x + f.x * d, y = pos.y + f.y * d, z = pos.z + math.max(0, f.z * d) + 0.5})
    p:SetVelocity({x = 0, y = 0, z = 0})
  end,
}

T.feats = feats   -- other trainer modules (Editor.lua) register commands here

local HELP = [[
Console: type Lua (expressions are printed), or:
  /<command>        run a CryEngine console command (System.ExecuteCommand)
  get <cvar>        print a cvar      set <cvar> <value>   set a cvar
  help              this text
Globals: g_localActor (player), BHOP (bhop mod), TRAINER, System, Physics]]

local function exec(cmd)
  local verb, rest = cmd:match("^(%S+)%s?(.*)$")
  if verb == "lua" then
    local c = rest
    if c == "help" then T.out("out", HELP); return end
    if c:sub(1, 1) == "/" then System.ExecuteCommand(c:sub(2)); T.out("out", "> " .. c:sub(2)); return end
    local g = c:match("^get%s+(%S+)$")
    if g then T.out("out", g .. " = " .. cvar(g)); return end
    local sn, sv = c:match("^set%s+(%S+)%s+(.+)$")
    if sn then System.SetCVar(sn, sv); T.out("out", sn .. " = " .. cvar(sn)); return end
    run_lua(c)
  elseif verb == "set" then
    local name, val = rest:match("^(%S+)%s+(.+)$")
    -- locked cheat cvars (sent by older overlay builds) map onto the Lua features
    local alias = { g_godMode = "god", g_infiniteAmmo = "ammo", ai_IgnorePlayer = "invisible", ai_NoUpdate = "aifreeze" }
    if name and alias[name] then feats[alias[name]](val == "0" and "0" or "1")
    elseif name then System.SetCVar(name, val) end
  elseif verb == "feat" then
    local name, val = rest:match("^(%S+)%s?(.*)$")
    if feats[name] then feats[name](val) else T.out("err", "unknown feature " .. tostring(name)) end
  else
    T.out("err", "unknown command " .. tostring(cmd))
  end
end

local function poll_commands()
  local raw = os.getenv("SGW3_TR_CMD")
  if not raw then return end
  local seq, body = raw:match("^(%d+)\31(.*)$")
  if not seq or seq == T.lastSeq then return end
  T.lastSeq = seq
  for cmd in (body .. "\30"):gmatch("(.-)\30") do
    if cmd ~= "" then
      local ok, err = pcall(exec, cmd)
      if not ok then T.out("err", err) end
    end
  end
  pipe_write("ack " .. seq)
end

local CVARS = { tscale = "t_Scale", tod = "e_TimeOfDay", todspeed = "e_TimeOfDaySpeed", fov = "cl_fov" }

local function send_state(p)
  local s = { "frame=" .. T.frame, "fps=" .. string.format("%.0f", 1 / math.max(System.GetFrameTime(), 1e-4)) }
  for k, c in pairs(CVARS) do s[#s + 1] = k .. "=" .. cvar(c) end
  if p and p.actor then
    local pos, v = p:GetWorldPos(), p:GetVelocity()
    s[#s + 1] = string.format("hp=%.0f;maxhp=%.0f;x=%.1f;y=%.1f;z=%.1f;spd=%.2f;vz=%.2f",
      p.actor:GetHealth(), p.actor:GetMaxHealth(), pos.x, pos.y, pos.z, math.sqrt(v.x * v.x + v.y * v.y), v.z)
  end
  if BHOP and BHOP.S then
    s[#s + 1] = "bhop=" .. (BHOP.S.enabled and 1 or 0)
    for k, val in pairs(BHOP.cfg) do s[#s + 1] = "cfg." .. k .. "=" .. tostring(val) end
  end
  for _, k in ipairs({"infhealth", "god", "ammo", "invisible", "noclip", "aifreeze"}) do s[#s + 1] = k .. "=" .. (T.feat[k] and 1 or 0) end
  s[#s + 1] = "noclipspeed=" .. tostring(T.noclipSpeed)
  s[#s + 1] = "ignore=" .. (T.feat.invisible and 1 or 0)   -- key used by older overlay builds
  pipe_write("state " .. table.concat(s, ";"))
end

-- God mode: the game applies damage in Lua (SinglePlayer:ProcessActorDamage). Skip hits on the local player.
-- Re-wrapped whenever the game rules script is (re)loaded and replaces the function.
local function ensure_damage_hook()
  local sp = rawget(_G, "SinglePlayer")
  if not sp or type(sp.ProcessActorDamage) ~= "function" or sp.ProcessActorDamage == T.padHook then return end
  local orig = sp.ProcessActorDamage
  T.padHook = function(self, hit)
    if T.feat.god and hit then
      local tgt, me = hit.target, player()
      if me and (tgt == me or (type(tgt) == "table" and tgt.id == me.id) or tgt == me.id) then
        T.out("out", string.format("[god] blocked %s hit (%.0f damage)", tostring(hit.type), tonumber(hit.damage) or 0))
        return false
      end
    end
    return orig(self, hit)
  end
  sp.ProcessActorDamage = T.padHook
end

-- AI actors around the player (everything with an actor that isn't us)
local function nearby_ai(p, radius)
  local list = {}
  local ents = System.GetEntitiesInSphere(p:GetWorldPos(), radius) or {}
  for _, e in pairs(ents) do
    if e.id ~= p.id and e.actor and AI then list[#list + 1] = e end
  end
  return list
end

-- Invisible: neither AIPARAM_INVISIBLE nor the faction switch alone stops this game's AI (detection runs through
-- perception), so: player in the "Cinematic" faction (neutral to every faction in Scripts/AI/Factions.xml),
-- and every AI nearby made ignorant with zero perception scales and its targets cleared. Re-applied every second
-- for AI that streams in; switching off reverts only what this feature changed.
T.blinded = T.blinded or {}
T.frozen = T.frozen or {}
-- SGW3's own vision system (ghillie/bush camouflage); these cvars are not cheat-locked
local CAMO = { ai_PlayerCamouflage = "1", ai_CamoThreshold = "0", ai_OpengroundVisibilityBoost = "0" }
T.camoSaved = T.camoSaved or {}
local function apply_camo(on)
  for name, val in pairs(CAMO) do
    if on then
      if T.camoSaved[name] == nil then T.camoSaved[name] = tostring((System.GetCVar(name))) end
      System.SetCVar(name, val)
    elseif T.camoSaved[name] ~= nil then
      System.SetCVar(name, T.camoSaved[name]); T.camoSaved[name] = nil
    end
  end
end
function T.apply_invisible(changed)
  local p = player()
  if not (p and AI) then return end
  local on = T.feat.invisible
  if on or changed then apply_camo(on) end
  pcall(AI.SetFactionOf, p.id, on and "Cinematic" or "Players")
  pcall(AI.ChangeParameter, p.id, AIPARAM_INVISIBLE, on and 1 or 0)
  if on then
    for _, e in ipairs(nearby_ai(p, 400)) do
      if not T.blinded[e.id] or changed then
        pcall(AI.SetIgnorant, e.id, 1)
        pcall(AI.ChangeParameter, e.id, AIPARAM_PERCEPTIONSCALE_VISUAL, 0)
        pcall(AI.ChangeParameter, e.id, AIPARAM_PERCEPTIONSCALE_AUDIO, 0)
        T.blinded[e.id] = true
      end
      pcall(AI.ClearPotentialTargets, e.id)
      pcall(AI.DropTarget, e.id, p.id)
    end
  elseif changed then
    for id in pairs(T.blinded) do
      if not T.frozen[id] then pcall(AI.SetIgnorant, id, 0) end
      pcall(AI.ChangeParameter, id, AIPARAM_PERCEPTIONSCALE_VISUAL, 1)
      pcall(AI.ChangeParameter, id, AIPARAM_PERCEPTIONSCALE_AUDIO, 1)
    end
    T.blinded = {}
  end
end

-- Freeze AI: stop behaviour-tree decisions and perception for every AI actor nearby
T.frozen = T.frozen or {}
function T.apply_aifreeze(changed)
  local p = player()
  if not (p and AI) then return end
  if T.feat.aifreeze then
    for _, e in ipairs(nearby_ai(p, 500)) do
      pcall(AI.SetBehaviorTreeEvaluationEnabled, e.id, false)
      pcall(AI.SetIgnorant, e.id, 1)
      pcall(AI.ClearPotentialTargets, e.id)
      T.frozen[e.id] = true
    end
  elseif changed then
    for id in pairs(T.frozen) do
      pcall(AI.SetBehaviorTreeEvaluationEnabled, id, true)
      if not T.blinded[id] then pcall(AI.SetIgnorant, id, 0) end
    end
    T.frozen = {}
  end
end

-- NPC spawner: System.SpawnEntity with an archetype from GameData/Libs/EntityArchetypes (as the game's own
-- AISpawners do with class + properties). Spawns land at the crosshair or in front of the player, on the ground.
T.spawned = T.spawned or {}
T.spawnSerial = T.spawnSerial or 0

local function ground_at(x, y, z, skip)
  local hits = {}
  local n = Physics.RayWorldIntersection({x = x, y = y, z = z + 3}, {x = 0, y = 0, z = -60}, 1, ent_terrain + ent_static, skip, nil, hits)
  if n and n > 0 and hits[1] then return hits[1].pos.z + 0.05 end
  return z
end

function T.spawn(arch, cls, count, mode, facing)
  local p = player()
  if not p then T.out("err", "spawn: no player"); return end
  local cam, dir = System.GetViewCameraPos(), System.GetViewCameraDir()
  local hl = math.sqrt(dir.x * dir.x + dir.y * dir.y)
  if hl < 1e-3 then hl, dir = 1, {x = 1, y = 0, z = 0} end
  local fx, fy = dir.x / hl, dir.y / hl
  local base
  if mode == "aim" then
    local hits = {}
    local n = Physics.RayWorldIntersection(cam, {x = dir.x * 200, y = dir.y * 200, z = dir.z * 200}, 1,
      ent_terrain + ent_static + ent_rigid + ent_sleeping_rigid, p.id, nil, hits)
    if n and n > 0 and hits[1] then base = hits[1].pos end
  end
  if not base then local pos = p:GetWorldPos(); base = {x = pos.x + fx * 8, y = pos.y + fy * 8, z = pos.z} end
  local made = 0
  for i = 1, math.max(1, math.min(count or 1, 20)) do
    -- spread a group on a sunflower spiral so they don't spawn inside each other
    local ang = (i - 1) * 2.399963
    local r = (i == 1) and 0 or 1.2 * math.sqrt(i - 1)
    local x, y = base.x + math.cos(ang) * r, base.y + math.sin(ang) * r
    local z = ground_at(x, y, base.z, p.id)
    local face = (facing == "away") and {x = fx, y = fy, z = 0} or {x = -fx, y = -fy, z = 0}
    T.spawnSerial = T.spawnSerial + 1
    local ok, e = pcall(System.SpawnEntity, { class = cls, archetype = arch, name = "trainer_spawn_" .. T.spawnSerial,
      position = {x = x, y = y, z = z}, orientation = face })
    if ok and e then
      -- wake the AI the way AIWave does for its spawns; without this they stand inert
      if e.Activate then pcall(e.Activate, e, 1) end
      if e.Event_Enable then pcall(e.Event_Enable, e) end
      T.spawned[#T.spawned + 1] = e.id
      made = made + 1
    else
      T.out("err", "spawn failed: " .. tostring(e))
    end
  end
  T.out("out", string.format("spawned %d x %s (%d from trainer so far)", made, arch, #T.spawned))
end

function T.despawn(kill)
  local n = 0
  for _, id in ipairs(T.spawned) do
    local e = System.GetEntity(id)
    if e then
      if kill then
        if e.actor then pcall(e.actor.SetHealth, e.actor, 0) end
        if e.Kill then pcall(e.Kill, e, {}) end
      else
        System.RemoveEntity(id)
      end
      n = n + 1
    end
  end
  if not kill then T.spawned = {} end
  T.out("out", (kill and "killed " or "removed ") .. n .. " spawned NPC(s)")
end

local function refill_ammo(p)
  local item = p.inventory and p.inventory:GetCurrentItem()
  local w = item and item.weapon
  if not w then return end
  local clip = w:GetClipSize()
  if clip and clip > 0 and (w:GetAmmoCount() or 0) < clip then w:SetAmmoCount(nil, clip) end
end

-- Noclip: hold the player still and move it with WASD (Space up, C down) along the camera; keys come from
-- the bhop_input.asi bitmask
local function noclip(p)
  if os.getenv("SGW3_ED_NOKEYS") == "1" then p:SetVelocity({x = 0, y = 0, z = 0}); return end   -- typing in the overlay
  local VK = { [1] = 0x20, [2] = 0x57, [4] = 0x53, [8] = 0x41, [16] = 0x44, [64] = 0x43, [128] = 0x10 }   -- Space W S A D C Shift
  local function b(n) return SGW3.IsKeyDown(VK[n]) and 1 or 0 end
  local f = System.GetViewCameraDir()
  local fl = math.sqrt(f.x * f.x + f.y * f.y + f.z * f.z)
  if fl < 1e-3 then return end
  f = {x = f.x / fl, y = f.y / fl, z = f.z / fl}
  local rl = math.sqrt(f.x * f.x + f.y * f.y)
  local r = rl > 1e-3 and {x = f.y / rl, y = -f.x / rl} or {x = 1, y = 0}
  local fw, rt, up = b(2) - b(4), b(16) - b(8), b(1) - b(64)
  local sp = T.noclipSpeed * (b(128) == 1 and 3 or 1) * System.GetFrameTime()
  local pos = p:GetWorldPos()
  p:SetWorldPos({x = pos.x + (f.x * fw + r.x * rt) * sp, y = pos.y + (f.y * fw + r.y * rt) * sp, z = pos.z + (f.z * fw + up) * sp})
  p:SetVelocity({x = 0, y = 0, z = 0})
end

-- called every frame from the mod tick chain (p may be nil in menus)
function TRAINER_TICK(p)
  T.frame = T.frame + 1
  poll_commands()
  ensure_damage_hook()
  if p and p.actor then
    if T.feat.infhealth or T.feat.god then
      local mx = p.actor:GetMaxHealth()
      if p.actor:GetHealth() < mx then p.actor:SetHealth(mx) end
    end
    if T.feat.ammo and T.frame % 3 == 0 then pcall(refill_ammo, p) end
    if T.feat.invisible and T.frame % 60 == 0 then T.apply_invisible(false) end
    if T.feat.aifreeze and T.frame % 60 == 30 then T.apply_aifreeze(false) end
    if EDITOR and EDITOR.background then pcall(EDITOR.background, p) end
    local editing = EDITOR and EDITOR.active
    if T.feat.noclip and (editing or not T.feat.menu) then noclip(p) end
    if editing then local ok, err = pcall(EDITOR.tick, p); if not ok and T.frame % 300 == 0 then T.out("err", "[editor] " .. tostring(err)) end end
  end
  if T.feat.menu and T.frame % 30 == 0 then
    pcall(ActionMapManager.EnableActionMap, "player", false)
    pcall(ActionMapManager.EnableActionMapManager, false, false)
  end
  if T.frame % 6 == 0 then send_state(p) end
end

SGW3.RegisterMod{ name = "SGW3 Trainer", version = "1.2.0", author = "SGW3 trainer project" }
SGW3.OnTick("sgw3_trainer", function(p) TRAINER_TICK(p) end)
