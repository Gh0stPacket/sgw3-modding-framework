-- SGW3 Bunny Hop: hold jump to hop, strafe (A/D + mouse) in the air to build speed, Quake-style.
-- An SGW3 Mod Framework mod (ticks and keys come from the framework). F6 toggles it.

BHOP = BHOP or {}
BHOP.defaults = {
  jump_speed = 6.0,       -- m/s launch, matches the game's own jump
  air_accel = 10.0,       -- air acceleration while strafing
  air_wish_cap = 3.5,     -- m/s; Quake-style (Source caps at ~0.9)
  ground_speed = 5.0,     -- reference speed for accel scaling
  max_speed = 30.0,       -- hard cap on horizontal speed
  hop_boost = 1.0,        -- per-hop multiplier (1.0 = gains only from strafing)
  hop_cooldown = 0.2,     -- s after a hop before ground checks resume
  wall_loss = 0.7,        -- measured/virtual speed ratio below which we assume we hit something
}
-- live settings (tuned from the trainer); keep tweaks across reloads, fill in anything new
BHOP.cfg = BHOP.cfg or {}
for k, v in pairs(BHOP.defaults) do if BHOP.cfg[k] == nil then BHOP.cfg[k] = v end end
-- engine cvars that fight bhop; applied while enabled, restored when toggled off
BHOP.cvars = {
  ["pl_jump_control.air_resistance_scale"] = 0,
  ["pl_jump_control.air_control_scale"] = 0,
  ["pl_jump_baseTimeAddedPerJump"] = 0,          -- the game's anti-bunnyhop jump timer
  ["pl_jump_currentTimeMultiplierOnJump"] = 0,
  ["pl_movement.ground_timeInAirToFall"] = 5,    -- hops aren't the game's jump state; don't treat them as falls
  ["pl_fallHeight"] = 5,
  ["pl_health.enable_FallandPlay"] = 0,          -- stumble reaction to sudden velocity changes
}

local K_JUMP, K_FWD, K_BACK, K_LEFT, K_RIGHT, K_TOGGLE = 1, 2, 4, 8, 16, 32
local function bit(k, b) return math.floor(k / b) % 2 end
local function log(s) if BHOP_LOG then BHOP_LOG(s) end end

BHOP.saved = BHOP.saved or {}
function BHOP.apply_cvars(on)
  for name, val in pairs(BHOP.cvars) do
    local cur = System.GetCVar(name)
    if on then
      if BHOP.saved[name] == nil then BHOP.saved[name] = cur end
      if tostring(cur) ~= tostring(val) then System.SetCVar(name, tostring(val)) end
    elseif BHOP.saved[name] ~= nil then
      System.SetCVar(name, tostring(BHOP.saved[name]))
    end
  end
end

local hits, down = {}, {x = 0, y = 0, z = -0.5}
local function ground_dist(p)
  local pos = p:GetWorldPos()
  local n = Physics.RayWorldIntersection({x = pos.x, y = pos.y, z = pos.z + 0.2}, down, 1,
    ent_terrain + ent_static + ent_rigid + ent_sleeping_rigid, p.id, nil, hits)
  if n and n > 0 and hits[1] then return hits[1].dist - 0.2 end
end

local function clamp_speed(vx, vy)
  local hs = math.sqrt(vx * vx + vy * vy)
  local m = BHOP.cfg.max_speed
  if hs > m then return vx * m / hs, vy * m / hs, m end
  return vx, vy, hs
end

-- Quake/Source air acceleration toward the strafe direction relative to the camera
local function air_strafe(vx, vy, k, dt)
  local cfg = BHOP.cfg
  local wf, wr = bit(k, K_FWD) - bit(k, K_BACK), bit(k, K_RIGHT) - bit(k, K_LEFT)
  if cfg.air_accel <= 0 or (wf == 0 and wr == 0) then return vx, vy end
  local f = System.GetViewCameraDir()
  local fl = math.sqrt(f.x * f.x + f.y * f.y)
  if fl < 0.001 then return vx, vy end
  local fx, fy = f.x / fl, f.y / fl
  local wx, wy = fx * wf + fy * wr, fy * wf - fx * wr   -- right = (fy, -fx)
  local wl = math.sqrt(wx * wx + wy * wy); wx, wy = wx / wl, wy / wl
  local add = cfg.air_wish_cap - (vx * wx + vy * wy)
  if add <= 0 then return vx, vy end
  local acc = math.min(cfg.air_accel * cfg.ground_speed * dt, add)
  return vx + acc * wx, vy + acc * wy
end

BHOP.S = BHOP.S or { enabled = true, prevKeys = 0, n = 0 }
local S = BHOP.S
S.air, S.cooldown = nil, 0

function BHOP.tick(p)
  S.n = S.n + 1
  local cfg = BHOP.cfg
  local k = BHOP.keymask()
  if bit(k, K_TOGGLE) == 1 and bit(S.prevKeys, K_TOGGLE) == 0 then
    S.enabled = not S.enabled; S.air = nil; BHOP.apply_cvars(S.enabled); log("toggle -> " .. tostring(S.enabled))
  end
  S.prevKeys = k
  if not S.enabled or (TRAINER and TRAINER.feat and (TRAINER.feat.menu or TRAINER.feat.noclip)) then return end
  if S.n % 120 == 1 then BHOP.apply_cvars(true) end   -- checkpoint loads re-apply the game's own values
  local dt = System.GetFrameTime()
  if dt <= 0 or dt > 0.1 then return end
  local v = p:GetVelocity()
  S.cooldown = math.max(0, S.cooldown - dt)
  local gd = S.cooldown == 0 and ground_dist(p)
  local grounded = gd and gd < 0.12 and v.z <= 0.5
  local jump = bit(k, K_JUMP) == 1
  if grounded then
    if jump and S.air then
      -- landed with jump held: relaunch keeping air speed, skipping ground friction
      local hx, hy, hs = clamp_speed(S.air.x * cfg.hop_boost, S.air.y * cfg.hop_boost)
      p:SetVelocity({x = hx, y = hy, z = cfg.jump_speed})
      S.cooldown = cfg.hop_cooldown
      log(string.format("hop speed=%.2f", hs))
      return
    end
    S.air = nil
    return
  end
  -- airborne: the virtual velocity is authoritative; skip right after a hop (vz may be stale) and
  -- adopt the real velocity when it suddenly drops (we hit something)
  if not S.air then S.air = {x = v.x, y = v.y} end
  local ms, vs = math.sqrt(v.x * v.x + v.y * v.y), math.sqrt(S.air.x ^ 2 + S.air.y ^ 2)
  if S.cooldown == 0 and vs > 0.5 and ms < vs * cfg.wall_loss then S.air = {x = v.x, y = v.y} end
  local vx, vy = clamp_speed(air_strafe(S.air.x, S.air.y, k, dt))
  S.air.x, S.air.y = vx, vy
  if S.cooldown == 0 then p:SetVelocity({x = vx, y = vy, z = v.z}) end
end

-- keys from the framework, packed into the bit layout the tick uses
local VK = { [K_JUMP] = 0x20, [K_FWD] = 0x57, [K_BACK] = 0x53, [K_LEFT] = 0x41, [K_RIGHT] = 0x44, [K_TOGGLE] = 0x75 }
function BHOP.keymask()
  local k = 0
  for b, vk in pairs(VK) do if SGW3.IsKeyDown(vk) then k = k + b end end
  return k
end

SGW3.RegisterMod{ name = "SGW3 Bunny Hop", version = "1.1.0", author = "SGW3 trainer project" }
SGW3.OnTick("sgw3_bhop", function(p) if p then BHOP.tick(p) end end)
SGW3.OnLevelLoad("sgw3_bhop", function() S.air, S.cooldown = nil, 0 end)
