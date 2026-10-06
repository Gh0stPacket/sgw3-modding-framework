-- SGW3 Mod Framework (core). Injected by sgw3_modloader.asi right after Scripts/main.lua compiles, so no game
-- file has to be overridden. (Fallback for setups without ASI loaders: zzzz_sgw3_framework_fallback.pak.)
--
-- Mods are drop-in paks with Scripts/AutoLoad/<ModName>/init.lua (or a single Scripts/AutoLoad/<name>.lua).
-- API for mods (all optional):
--   SGW3.RegisterMod{ name = "...", version = "...", author = "..." }
--   SGW3.OnTick(name, function(player, dt) ... end)      every frame; player may be nil in menus
--   SGW3.OnLevelLoad(name, function(level) ... end)     level start, checkpoint load, respawn
--   SGW3.IsKeyDown(vk) / SGW3.KeyPressed(vk)            Windows virtual-key codes, only while the game is focused
--   SGW3.Level()  SGW3.Player()  SGW3.Log(mod, msg)
--   SGW3.RegisterLayout(name, { level = "...", objects = { {model=..., x,y,z, rx,ry,rz, s}, ... },
--                              edits = { {name = <level entity>, x,y,z, rx,ry,rz, s, hidden}, ... } })
-- Each callback runs in its own pcall: one broken mod can't stop the others; errors go to the framework log.

if SGW3_FRAMEWORK_LOADED then return end
SGW3_FRAMEWORK_LOADED = true

SGW3 = SGW3 or {}
local F = SGW3
F.version = "1.0.0"
F.mods, F.ticks, F.levelHandlers, F.layouts = {}, {}, {}, {}
F.tickOrder, F.levelOrder = {}, {}
F.errors = {}

-- ---------------------------------------------------------------- logging
local LOG_PATH = (os.getenv("USERPROFILE") or ".") .. "/Saved Games/Sniper Ghost Warrior 3/sgw3_mods.log"
do local f = io.open(LOG_PATH, "w"); if f then f:write("SGW3 Mod Framework " .. F.version .. "\n"); f:close() end end
function F.Log(mod, msg)
  local f = io.open(LOG_PATH, "a")
  if f then f:write(string.format("[%8.2f] [%s] %s\n", os.clock(), tostring(mod), tostring(msg))); f:close() end
end

local function report(mod, where, err)
  local key = mod .. ":" .. where
  local n = (F.errors[key] or 0) + 1
  F.errors[key] = n
  if n == 1 or n % 600 == 0 then F.Log(mod, string.format("error in %s (x%d): %s", where, n, tostring(err))) end
end

-- ---------------------------------------------------------------- registration
function F.RegisterMod(info)
  info = type(info) == "table" and info or { name = tostring(info) }
  F.mods[#F.mods + 1] = info
  F.Log("framework", "mod: " .. tostring(info.name) .. " " .. tostring(info.version or "") .. " by " .. tostring(info.author or "?"))
  return info
end

local function add(tbl, order, name, fn)
  if type(fn) ~= "function" then return end
  if not tbl[name] then order[#order + 1] = name end
  tbl[name] = fn
end
function F.OnTick(name, fn) add(F.ticks, F.tickOrder, name, fn) end
function F.OnLevelLoad(name, fn) add(F.levelHandlers, F.levelOrder, name, fn) end

function F.Level() return tostring((System.GetCVar("sv_map"))) end
function F.Player() return rawget(_G, "g_localActor") end

-- ---------------------------------------------------------------- keyboard (from sgw3_modloader.asi)
-- SGW3_KEYS = 64 hex digits; digit i holds virtual keys 4i..4i+3 (bit 0 = 4i).
local keys, prevKeys, keyFrame = {}, {}, -1
local function refresh_keys()
  if keyFrame == F.frame then return end
  keyFrame = F.frame
  prevKeys, keys = keys, {}
  local s = os.getenv("SGW3_KEYS")
  if not s then return end
  for i = 1, #s do
    local d = tonumber(s:sub(i, i), 16) or 0
    if d ~= 0 then
      for bit = 0, 3 do
        if math.floor(d / 2 ^ bit) % 2 == 1 then keys[(i - 1) * 4 + bit] = true end
      end
    end
  end
end
function F.IsKeyDown(vk) refresh_keys(); return keys[vk] == true end
function F.KeyPressed(vk) refresh_keys(); return keys[vk] == true and not prevKeys[vk] end

-- ---------------------------------------------------------------- layouts (map editor exports)
local function copy(t)
  if type(t) ~= "table" then return t end
  local c = {}
  for k, v in pairs(t) do c[k] = copy(v) end
  return c
end
function F.SpawnStatic(name, o)
  local props = copy(BasicEntity and BasicEntity.Properties or {})
  props.object_Model = o.model
  props.Physics = props.Physics or {}
  props.Physics.bPhysicalize, props.Physics.bRigidBody, props.Physics.bPushableByPlayers = 1, 0, 0
  props.Physics.Mass, props.Physics.Density = 0, -1
  local ok, e = pcall(System.SpawnEntity, { class = "BasicEntity", name = name, position = {x = o.x, y = o.y, z = o.z}, properties = props })
  if not ok or not e then return nil end
  e:SetWorldAngles({x = math.rad(o.rx or 0), y = math.rad(o.ry or 0), z = math.rad(o.rz or 0)})
  e:SetScale(o.s or 1)
  return e
end
function F.RegisterLayout(name, layout) F.layouts[name] = layout end
local function spawn_layouts(level)
  local lv = string.lower(level)
  for lname, layout in pairs(F.layouts) do
    if string.lower(layout.level or "") == lv then
      for i, o in ipairs(layout.objects or {}) do
        local en = "layout_" .. lname .. "_" .. i
        if not System.GetEntityByName(en) then F.SpawnStatic(en, o) end
      end
    end
  end
end
-- world edits: { name = <level entity name>, x, y, z, rx, ry, rz, s, hidden }; applied by entity name.
-- Re-applied for a while after each load, because checkpoint loads restore entities to their saved state.
local function apply_edits(level)
  local lv = string.lower(level)
  for _, layout in pairs(F.layouts) do
    if string.lower(layout.level or "") == lv then
      for _, w in ipairs(layout.edits or {}) do
        local e = System.GetEntityByName(w.name)
        if e then
          if w.x then e:SetWorldPos({x = w.x, y = w.y, z = w.z}) end
          e:SetWorldAngles({x = math.rad(w.rx or 0), y = math.rad(w.ry or 0), z = math.rad(w.rz or 0)})
          e:SetScale(w.s or 1)
          e:Hide(w.hidden and 1 or 0)
        end
      end
    end
  end
end
F.ApplyEdits = apply_edits

-- ---------------------------------------------------------------- per-frame tick
-- A global Script.SetTimer chain. Level and checkpoint loads wipe script timers, so every Player lifecycle
-- callback restarts it (the generation counter keeps exactly one chain alive) and flags a level load.
F.frame, F.gen = 0, 0
local pendingLevel = false
local function chain(gen)
  if gen ~= F.gen then return end
  F.frame = F.frame + 1
  local p = F.Player()
  if p and not p.actor then p = nil end
  local dt = System.GetFrameTime()
  if pendingLevel and p and F.frame % 20 == 0 then
    pendingLevel = false
    local level = F.Level()
    local ok, err = pcall(spawn_layouts, level)
    if not ok then report("framework", "layouts", err) end
    F.editsUntil = F.frame + 1200   -- re-apply world edits for ~20 s of frames
    for _, name in ipairs(F.levelOrder) do
      local ok2, err2 = pcall(F.levelHandlers[name], level)
      if not ok2 then report(name, "OnLevelLoad", err2) end
    end
  end
  if p and F.editsUntil and F.frame < F.editsUntil and F.frame % 60 == 0 then
    local ok, err = pcall(apply_edits, F.Level())
    if not ok then report("framework", "edits", err) end
  end
  for _, name in ipairs(F.tickOrder) do
    local ok, err = pcall(F.ticks[name], p, dt)
    if not ok then report(name, "OnTick", err) end
  end
  Script.SetTimer(0, function() chain(gen) end)
end
function F.Restart(why)
  F.gen = F.gen + 1
  local gen = F.gen
  pendingLevel = true
  Script.SetTimer(0, function() chain(gen) end)
end
if Player then
  for _, fn in ipairs({"OnInit", "OnReset", "OnLoad", "OnPostLoad", "OnResetLoad", "OnSpawn", "Revive"}) do
    local orig = Player[fn]
    Player[fn] = function(self, ...)
      local r
      if orig then r = orig(self, ...) end
      F.Restart(fn)
      return r
    end
  end
end
F.Restart("startup")

-- ---------------------------------------------------------------- autoload
-- Scripts/AutoLoad/<dir>/init.lua and Scripts/AutoLoad/*.lua, across all paks, in name order.
local entries = {}
for _, d in pairs(System.ScanDirectory("Scripts/AutoLoad", SCANDIR_SUBDIRS) or {}) do
  if type(d) == "string" and d ~= "." and d ~= ".." then entries[#entries + 1] = { key = d:lower(), path = "Scripts/AutoLoad/" .. d .. "/init.lua" } end
end
for _, f in pairs(System.ScanDirectory("Scripts/AutoLoad", SCANDIR_FILES) or {}) do
  if type(f) == "string" and f:lower():match("%.lua$") then entries[#entries + 1] = { key = f:lower(), path = "Scripts/AutoLoad/" .. f } end
end
table.sort(entries, function(a, b) return a.key < b.key end)
for _, e in ipairs(entries) do
  local ok, err = pcall(Script.ReloadScript, e.path)
  F.Log("framework", "autoload " .. e.path .. (ok and "" or (" FAILED: " .. tostring(err))))
end
F.Log("framework", string.format("ready: %d autoload entries, %d mods registered", #entries, #F.mods))
