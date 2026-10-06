-- SGW3 Trainer map editor (in-game half). Fly-cam editing with a move gizmo, of
--   * placed models (static BasicEntity props spawned by the editor), and
--   * world entities already in the level (props with physics, doors, vehicles, lights, AI...), picked with a
--     mouse ray or from the nearby list. Static level geometry ("brushes") is render data, not entities, and
--     can't be edited from script.
-- Commands arrive through TRAINER feats ("feat ed..."); per-frame data goes back over the pipe:
--   "ed k=v;..."          selected object + its gizmo projected to the game's virtual 800x600 screen
--   "edobjs n:x,y,z|..."  projected origins of all edited objects (click picking / markers)
--   "edlist n|label;..."  edited object list          "ednear i|label|dist;..."  nearby world entities
-- Every edit autosaves per level (Saved Games\Sniper Ghost Warrior 3\editor_level_<map>.lua) and is re-applied
-- when the level loads (world edits are re-applied after checkpoint loads too). Export writes a framework layout
-- (placed objects + world edits) that the overlay packs into zzz_layout_<name>.pak.

EDITOR = EDITOR or {}
local E = EDITOR
local T = TRAINER
E.objs = E.objs or {}          -- [n] = record; record.kind = "placed" | "world"
E.serial = E.serial or 0
E.near = E.near or {}
E.frame = 0

local function player() return rawget(_G, "g_localActor") end
local function ent(n) local o = E.objs[n]; return o and System.GetEntity(o.id) end

local function deepcopy(t)
  if type(t) ~= "table" then return t end
  local c = {}
  for k, v in pairs(t) do c[k] = deepcopy(v) end
  return c
end

local function label(o)
  if o.kind == "world" then return string.format("[world] %s (%s)%s", o.name, o.cls, o.hidden and " hidden" or "") end
  return o.model
end

-- ---------------------------------------------------------------- enter / exit
function E.set_active(on)
  local p = player()
  if on == E.active or not p then return end
  E.active = on
  if on then
    E.saved = { noclip = T.feat.noclip, god = T.feat.god, invisible = T.feat.invisible }
    T.feat.noclip, T.feat.god, T.feat.invisible = true, true, true
    T.apply_invisible(true)
    pcall(p.actor.HolsterItem, p.actor, true)
    local a = p.actor:GetAngles()
    E.pitch, E.yaw = a.x, a.z
  else
    local s = E.saved or {}
    T.feat.noclip, T.feat.god, T.feat.invisible = s.noclip or false, s.god or false, s.invisible or false
    T.apply_invisible(true)
    pcall(p.actor.HolsterItem, p.actor, false)
    p:SetVelocity({x = 0, y = 0, z = 0})
  end
  T.out("out", on and "[editor] on - RMB look, WASD/Space/C fly, Shift fast" or "[editor] off")
end

-- ---------------------------------------------------------------- transforms
local function apply_xform(o, e)
  e:SetWorldAngles({x = math.rad(o.rx), y = math.rad(o.ry), z = math.rad(o.rz)})
  e:SetScale(o.s)
end

-- move + remember the desired position (world edits are re-applied after loads)
local function setpos(o, e, pos)
  e:SetWorldPos(pos)
  o.x, o.y, o.z = pos.x, pos.y, pos.z
end

-- apply a record's full desired state to its entity
local function apply_all(o, e)
  if o.x then e:SetWorldPos({x = o.x, y = o.y, z = o.z}) end
  apply_xform(o, e)
  if o.kind == "world" then e:Hide(o.hidden and 1 or 0) end
end

-- ---------------------------------------------------------------- placed models
function E.place(model, pos, rx, ry, rz, s)
  local props = deepcopy(BasicEntity and BasicEntity.Properties or {})
  props.object_Model = model
  props.Physics = props.Physics or {}
  props.Physics.bPhysicalize, props.Physics.bRigidBody, props.Physics.bPushableByPlayers = 1, 0, 0
  props.Physics.Mass, props.Physics.Density = 0, -1
  E.serial = E.serial + 1
  local ok, e = pcall(System.SpawnEntity, { class = "BasicEntity", name = "editor_obj_" .. E.serial, position = pos, properties = props })
  if not ok or not e then T.out("err", "[editor] spawn failed: " .. tostring(e)); return end
  local n = E.serial
  E.objs[n] = { kind = "placed", id = e.id, model = model, x = pos.x, y = pos.y, z = pos.z, rx = rx or 0, ry = ry or 0, rz = rz or 0, s = s or 1 }
  apply_xform(E.objs[n], e)
  return n
end

-- ---------------------------------------------------------------- world entities
local function find_record(id)
  for n, o in pairs(E.objs) do if o.id == id then return n end end
end

-- start tracking a level entity (captures its original transform for Reset); returns the record index
function E.track_world(e)
  local n = find_record(e.id)
  if n then return n end
  local p, a = e:GetWorldPos(), e:GetWorldAngles()
  local s = e:GetScale() or 1
  if type(s) == "table" then s = s.x or 1 end
  local cur = { x = p.x, y = p.y, z = p.z, rx = math.deg(a.x), ry = math.deg(a.y), rz = math.deg(a.z), s = s }
  E.serial = E.serial + 1
  n = E.serial
  E.objs[n] = { kind = "world", id = e.id, name = e:GetName(), cls = e.class or "?", model = e:GetName(),
    x = cur.x, y = cur.y, z = cur.z, rx = cur.rx, ry = cur.ry, rz = cur.rz, s = cur.s, hidden = false, orig = cur }
  return n
end

local function cross(a, b) return {x = a.y * b.z - a.z * b.y, y = a.z * b.x - a.x * b.z, z = a.x * b.y - a.y * b.x} end
local function norm(a) local l = math.sqrt(a.x * a.x + a.y * a.y + a.z * a.z); return {x = a.x / l, y = a.y / l, z = a.z / l} end

-- ray through a point of the virtual 800x600 screen (vertical FOV; verified against System.ProjectToScreen)
local function screen_ray(sx, sy, aspect)
  local f, u = System.GetViewCameraDir(), System.GetViewCameraUpDir()
  local r = norm(cross(f, u))
  local uu = norm(cross(r, f))
  local tv = math.tan(System.GetViewCameraFov() / 2)
  local nx, ny = sx / 800 * 2 - 1, 1 - sy / 600 * 2
  return norm({ x = f.x + r.x * nx * tv * aspect + uu.x * ny * tv,
                y = f.y + r.y * nx * tv * aspect + uu.y * ny * tv,
                z = f.z + r.z * nx * tv * aspect + uu.z * ny * tv })
end

function E.pick(sx, sy, aspect)
  local p = player()
  local cam, d = System.GetViewCameraPos(), screen_ray(sx, sy, aspect)
  local hits = {}
  local n = Physics.RayWorldIntersection(cam, {x = d.x * 500, y = d.y * 500, z = d.z * 500}, 1, ent_all, p and p.id, nil, hits)
  local h = n and n > 0 and hits[1]
  if not h then E.sel = nil; return end
  local e = h.entity
  if type(e) ~= "table" or not e.id then
    T.out("out", string.format("[editor] that's static level geometry (%.0f m away) - not an editable entity", h.dist or 0))
    E.sel = nil
    return
  end
  E.sel = E.track_world(e)
  if E.objs[E.sel].kind == "world" then T.out("out", "[editor] selected " .. label(E.objs[E.sel])) end
end

function E.nearby(radius, filter)
  local p = player(); if not p then return end
  local cam = System.GetViewCameraPos()
  local list = {}
  filter = (filter or ""):lower()
  for _, e in pairs(System.GetEntitiesInSphere(cam, radius) or {}) do
    if e.id ~= p.id then
      local name, cls = tostring(e:GetName()), tostring(e.class)
      if filter == "" or name:lower():find(filter, 1, true) or cls:lower():find(filter, 1, true) then
        local q = e:GetWorldPos()
        list[#list + 1] = { id = e.id, label = name .. " (" .. cls .. ")", d = math.sqrt((q.x - cam.x) ^ 2 + (q.y - cam.y) ^ 2 + (q.z - cam.z) ^ 2) }
      end
    end
  end
  table.sort(list, function(a, b) return a.d < b.d end)
  E.near = {}
  local parts = {}
  for i = 1, math.min(#list, 150) do
    E.near[i] = list[i].id
    parts[#parts + 1] = string.format("%d|%s|%.0f", i, list[i].label:gsub("[;|]", "_"), list[i].d)
  end
  T.out("ednear", table.concat(parts, ";"))
end

-- ---------------------------------------------------------------- helpers
local function crosshair_point(maxd)
  local p = player()
  local cam, dir = System.GetViewCameraPos(), System.GetViewCameraDir()
  local hits = {}
  local n = Physics.RayWorldIntersection(cam, {x = dir.x * maxd, y = dir.y * maxd, z = dir.z * maxd}, 1,
    ent_terrain + ent_static + ent_rigid + ent_sleeping_rigid, p and p.id, nil, hits)
  if n and n > 0 and hits[1] then return hits[1].pos end
  return {x = cam.x + dir.x * 6, y = cam.y + dir.y * 6, z = cam.z + dir.z * 6}
end

local function ground_below(pos, skip)
  local hits = {}
  local n = Physics.RayWorldIntersection({x = pos.x, y = pos.y, z = pos.z + 0.5}, {x = 0, y = 0, z = -200}, 1,
    ent_terrain + ent_static, skip, nil, hits)
  if n and n > 0 and hits[1] then return hits[1].pos.z end
end

local function remove(n)
  local o = E.objs[n]
  if not o then return end
  if o.kind == "placed" then
    System.RemoveEntity(o.id)
    E.objs[n] = nil
  else
    -- level entities are only hidden, never destroyed (missions may reference them)
    o.hidden = true
    local e = System.GetEntity(o.id)
    if e then e:Hide(1) end
  end
  if E.sel == n and not E.objs[n] then E.sel = nil end
end

-- ---------------------------------------------------------------- layouts
local SAVE_DIR = (os.getenv("USERPROFILE") or ".") .. "/Saved Games/Sniper Ghost Warrior 3/"
local function clean(name) return ((name or "default"):gsub("[^%w_%-]", "_")) end
local function layout_path(name) return SAVE_DIR .. "editor_" .. clean(name) .. ".lua" end
local function level() return tostring((System.GetCVar("sv_map"))) end
local function autosave_path() return SAVE_DIR .. "editor_level_" .. clean(level()) .. ".lua" end

-- current state of a record (live entity if present, else the remembered desired state)
local function snapshot(o)
  local e = System.GetEntity(o.id)
  local x, y, z = o.x, o.y, o.z
  if e and not (o.kind == "world" and o.hidden) then local p = e:GetWorldPos(); x, y, z = p.x, p.y, p.z end
  return x, y, z
end

local function write_records(f, placedFmt, worldFmt)
  local count = 0
  for _, o in pairs(E.objs) do
    local x, y, z = snapshot(o)
    if x then
      if o.kind == "placed" then
        f:write(string.format(placedFmt, o.model, x, y, z, o.rx, o.ry, o.rz, o.s))
      else
        f:write(string.format(worldFmt, o.name, x, y, z, o.rx, o.ry, o.rz, o.s, tostring(o.hidden == true)))
      end
      count = count + 1
    end
  end
  return count
end

local PLACED_FMT = "  { model = %q, x = %.4f, y = %.4f, z = %.4f, rx = %.3f, ry = %.3f, rz = %.3f, s = %.4f },\n"
local WORLD_FMT = "  { world = true, name = %q, x = %.4f, y = %.4f, z = %.4f, rx = %.3f, ry = %.3f, rz = %.3f, s = %.4f, hidden = %s },\n"

function E.save(name, path, quiet)
  path = path or layout_path(name)
  local f = io.open(path, "w")
  if not f then T.out("err", "[editor] cannot write " .. path); return end
  f:write("return {\n")
  local count = write_records(f, PLACED_FMT, WORLD_FMT)
  f:write("}\n")
  f:close()
  if not quiet then T.out("out", string.format("[editor] saved %d object(s) to %s", count, path)) end
end

-- attach a saved world edit to its level entity (by name); returns true once applied
local function attach_world(rec)
  local e = System.GetEntityByName(rec.name)
  if not e then return false end
  local n = E.track_world(e)
  local o = E.objs[n]
  o.x, o.y, o.z, o.rx, o.ry, o.rz, o.s, o.hidden = rec.x, rec.y, rec.z, rec.rx, rec.ry, rec.rz, rec.s, rec.hidden
  apply_all(o, e)
  return true
end

function E.load(name, path, quiet)
  path = path or layout_path(name)
  local ok, data = pcall(dofile, path)
  if not ok or type(data) ~= "table" then
    if not quiet then T.out("err", "[editor] cannot load " .. path .. ": " .. tostring(data)) end
    return
  end
  E.worldPending = E.worldPending or {}
  for _, o in ipairs(data) do
    if o.world then
      if not attach_world(o) then E.worldPending[o.name] = o end
    else
      E.place(o.model, {x = o.x, y = o.y, z = o.z}, o.rx, o.ry, o.rz, o.s)
    end
  end
  if not quiet then E.dirty = true end
  T.out("out", string.format("[editor] loaded %d object(s) from %s", #data, path))
end

-- Export: a framework layout (placed objects + world edits); the overlay packs it into a .pak
function E.export(name)
  name = clean(name)
  local path = SAVE_DIR .. "export_" .. name .. ".lua"
  local f = io.open(path, "w")
  if not f then T.out("err", "[editor] cannot write " .. path); return end
  f:write(string.format("-- Map layout %q for level %s, exported from the SGW3 Trainer map editor.\n", name, level()))
  f:write("-- Needs the SGW3 Mod Framework (sgw3_modloader.asi); applied when the level loads.\n")
  f:write(string.format("SGW3.RegisterMod{ name = %q, version = \"1.0\", author = \"map editor export\" }\n", "Layout: " .. name))
  f:write(string.format("SGW3.RegisterLayout(%q, { level = %q,\n", name, level()))
  -- split placed objects / world edits into the two layout lists
  local placed, world = {}, {}
  for n, o in pairs(E.objs) do if o.kind == "placed" then placed[n] = o else world[n] = o end end
  local all = E.objs
  f:write("objects = {\n"); E.objs = placed; local c1 = write_records(f, PLACED_FMT, WORLD_FMT); f:write("},\n")
  f:write("edits = {\n"); E.objs = world; local c2 = write_records(f, PLACED_FMT,
    "  { name = %q, x = %.4f, y = %.4f, z = %.4f, rx = %.3f, ry = %.3f, rz = %.3f, s = %.4f, hidden = %s },\n"); f:write("},\n")
  E.objs = all
  f:write("})\n")
  f:close()
  T.out("out", string.format("[editor] exported %d placed object(s) and %d world edit(s) for level %s", c1, c2, level()))
  T.out("edexport", name .. "|" .. path)
end

-- ---------------------------------------------------------------- commands
local f = T.feats
local function sel() return E.objs[E.sel], ent(E.sel) end
f.ed = function(v) E.set_active(v == "1") end
f.edlook = function(v)
  local p = player(); if not (p and E.active) then return end
  local dx, dy = v:match("^(%S+)%s+(%S+)$")
  E.yaw = E.yaw - (tonumber(dx) or 0) * 0.0025
  E.pitch = math.max(-1.5, math.min(1.5, E.pitch - (tonumber(dy) or 0) * 0.0025))
  p.actor:PlayerSetViewAngles({x = E.pitch, y = 0, z = E.yaw})
end
f.edspawn = function(model)
  if model == "" then return end
  local n = E.place(model, crosshair_point(150))
  if n then E.sel = n; E.dirty = true; T.out("out", "[editor] placed #" .. n .. " " .. model) end
end
f.edsel = function(v) local n = tonumber(v); if n and E.objs[n] then E.sel = n elseif v == "none" then E.sel = nil end end
f.edpickray = function(v)
  local x, y, a = v:match("^(%S+)%s+(%S+)%s+(%S+)$")
  if x then E.pick(tonumber(x), tonumber(y), tonumber(a)) end
end
f.ednear = function(v)
  local r, filt = v:match("^(%S+)%s?(.*)$")
  E.nearby(tonumber(r) or 50, filt)
end
f.ednearsel = function(v)
  local id = E.near[tonumber(v) or 0]
  local e = id and System.GetEntity(id)
  if e then E.sel = E.track_world(e) end
end
f.edpos = function(v)
  local o, e = sel(); if not e then return end
  local x, y, z = v:match("^(%S+)%s+(%S+)%s+(%S+)$")
  if x then setpos(o, e, {x = tonumber(x), y = tonumber(y), z = tonumber(z)}); E.dirty = true end
end
f.edrot = function(v)
  local o, e = sel(); if not e then return end
  local x, y, z = v:match("^(%S+)%s+(%S+)%s+(%S+)$")
  o.rx, o.ry, o.rz = tonumber(x) or o.rx, tonumber(y) or o.ry, tonumber(z) or o.rz
  apply_xform(o, e); E.dirty = true
end
f.edscale = function(v)
  local o, e = sel(); if not e then return end
  o.s = math.max(0.01, tonumber(v) or o.s); apply_xform(o, e); E.dirty = true
end
f.edground = function()
  local o, e = sel(); if not e then return end
  local p = e:GetWorldPos()
  local z = ground_below(p, e.id)
  if z then setpos(o, e, {x = p.x, y = p.y, z = z}); E.dirty = true end
end
f.edtocam = function()
  local o, e = sel(); if not e then return end
  setpos(o, e, crosshair_point(150)); E.dirty = true
end
f.eddup = function()
  local o, e = sel(); if not e then return end
  local model = o.kind == "placed" and o.model or (e.Properties and e.Properties.object_Model)
  if not model or model == "" then T.out("err", "[editor] this entity has no model to copy"); return end
  local p = e:GetWorldPos()
  local n = E.place(model, {x = p.x + 1, y = p.y, z = p.z}, o.rx, o.ry, o.rz, o.s)
  if n then E.sel = n; E.dirty = true end
end
f.eddel = function() if E.sel then remove(E.sel); E.dirty = true end end
f.edhide = function()
  local o, e = sel(); if not (o and e and o.kind == "world") then return end
  o.hidden = not o.hidden; e:Hide(o.hidden and 1 or 0); E.dirty = true
end
f.edreset = function()
  local o, e = sel(); if not (o and e and o.kind == "world") then return end
  local r = o.orig
  e:SetWorldPos({x = r.x, y = r.y, z = r.z})
  e:SetWorldAngles({x = math.rad(r.rx), y = math.rad(r.ry), z = math.rad(r.rz)})
  e:SetScale(r.s); e:Hide(0)
  E.objs[E.sel] = nil; E.sel = nil; E.dirty = true
  T.out("out", "[editor] reset " .. tostring(r and o.name))
end
f.edclear = function()
  for n, o in pairs(E.objs) do
    if o.kind == "placed" then remove(n)
    else local e = System.GetEntity(o.id); if e and o.orig then e:SetWorldPos(o.orig); e:SetWorldAngles({x = math.rad(o.orig.rx), y = math.rad(o.orig.ry), z = math.rad(o.orig.rz)}); e:SetScale(o.orig.s); e:Hide(0) end; E.objs[n] = nil end
  end
  E.sel = nil; E.dirty = true; T.out("out", "[editor] cleared (placed objects removed, world edits reset)")
end
f.edexport = function(v) E.export(v ~= "" and v or "my_layout") end
f.edsave = function(v) E.save(v ~= "" and v or "default") end
f.edload = function(v) E.load(v ~= "" and v or "default") end

-- ---------------------------------------------------------------- persistence
-- Runs every frame whether or not the editor is open. A level / checkpoint / respawn load (SGW3.OnLevelLoad)
-- sets E.pendingLoad: drop placed records whose entities the load removed and, if nothing is tracked any more,
-- restore this level's autosave. World edits are re-applied for 20 s after every load, because checkpoint
-- loads restore level entities to their saved state.
E.bgFrame = 0
function E.background(p)
  E.bgFrame = E.bgFrame + 1
  local map = level()
  if map ~= E.map then E.map = map; E.objs = {}; E.worldPending = {}; E.sel = nil; E.pendingLoad = true end
  if E.pendingLoad and p and E.bgFrame % 30 == 0 then
    E.pendingLoad = false
    E.reapplyUntil = os.clock() + 20
    local tracked = 0
    for n, o in pairs(E.objs) do
      if o.kind == "placed" and not System.GetEntity(o.id) then E.objs[n] = nil else tracked = tracked + 1 end
    end
    if tracked == 0 then E.load(nil, autosave_path(), true) end
  end
  if E.reapplyUntil and os.clock() < E.reapplyUntil and E.bgFrame % 60 == 0 then
    for _, o in pairs(E.objs) do
      if o.kind == "world" then
        local e = System.GetEntityByName(o.name)
        if e then o.id = e.id; apply_all(o, e) end
      end
    end
    for name, rec in pairs(E.worldPending or {}) do
      if attach_world(rec) then E.worldPending[name] = nil end
    end
  end
  if E.dirty and E.bgFrame % 120 == 0 then
    E.dirty = false
    E.save(nil, autosave_path(), true)
  end
end

-- ---------------------------------------------------------------- per-frame output
local function proj(p)
  local s = System.ProjectToScreen(p)
  if not s then return "0,0,9" end
  return string.format("%.1f,%.1f,%.3f", s.x, s.y, s.z)
end

function E.tick(p)
  if not E.active then return end
  E.frame = E.frame + 1
  -- keep the view where we steer it (the game re-derives it from the actor otherwise)
  if E.frame % 2 == 0 and p then p.actor:PlayerSetViewAngles({x = E.pitch, y = 0, z = E.yaw}) end
  local cam = System.GetViewCameraPos()
  local out = { "active=1" }
  local o, e = sel()
  if e then
    local pos = e:GetWorldPos()
    local d = math.sqrt((pos.x - cam.x) ^ 2 + (pos.y - cam.y) ^ 2 + (pos.z - cam.z) ^ 2)
    local L = math.max(0.4, d * 0.12)
    out[#out + 1] = string.format("sel=%d;kind=%s;model=%s;cls=%s;hidden=%d;x=%.3f;y=%.3f;z=%.3f;rx=%.1f;ry=%.1f;rz=%.1f;s=%.3f;len=%.3f",
      E.sel, o.kind, (o.kind == "world" and o.name or o.model):gsub(";", "_"), tostring(o.cls or ""), o.hidden and 1 or 0,
      pos.x, pos.y, pos.z, o.rx, o.ry, o.rz, o.s, L)
    out[#out + 1] = "o=" .. proj(pos)
    out[#out + 1] = "ax=" .. proj({x = pos.x + L, y = pos.y, z = pos.z})
    out[#out + 1] = "ay=" .. proj({x = pos.x, y = pos.y + L, z = pos.z})
    out[#out + 1] = "az=" .. proj({x = pos.x, y = pos.y, z = pos.z + L})
  else
    out[#out + 1] = "sel=0"
  end
  T.out("ed", table.concat(out, ";"))
  if E.frame % 6 == 0 then
    local parts, n = {}, 0
    for k, ob in pairs(E.objs) do
      local oe = System.GetEntity(ob.id)
      if oe then n = n + 1; if n > 400 then break end; parts[#parts + 1] = k .. ":" .. proj(oe:GetWorldPos()) end
    end
    T.out("edobjs", table.concat(parts, "|"))
  end
  if E.frame % 30 == 0 then
    local parts = {}
    for k, ob in pairs(E.objs) do parts[#parts + 1] = k .. "|" .. label(ob):gsub("[;|]", "_") end
    T.out("edlist", table.concat(parts, ";"))
  end
end

SGW3.RegisterMod{ name = "SGW3 Map Editor", version = "1.2.0", author = "SGW3 trainer project" }
SGW3.OnLevelLoad("sgw3_editor", function() E.pendingLoad = true end)
