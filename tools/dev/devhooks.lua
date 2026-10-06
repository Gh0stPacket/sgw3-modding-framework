-- SGW3 dev tools mod (development builds only; packed as Scripts/AutoLoad/00_sgw3_dev/init.lua).
-- Enabled only when the environment variable SGW3_DEV_DIR points at a writable folder:
--   <SGW3_DEV_DIR>/log.txt     BHOP_LOG / dev log
--   <SGW3_DEV_DIR>/reload.txt  create it to hot-reload the mod scripts from SGW3_DEV_SRC (the repo root)
--   <SGW3_DEV_DIR>/exec.lua    create it to run it once inside the game (then it is deleted)
local DIR = os.getenv("SGW3_DEV_DIR")
local SRC = os.getenv("SGW3_DEV_SRC")
if not DIR or DIR == "" then return end
DIR = DIR:gsub("\\", "/"):gsub("/?$", "/")
if SRC then SRC = SRC:gsub("\\", "/"):gsub("/?$", "/") end

function BHOP_LOG(s) local f = io.open(DIR .. "log.txt", "a"); if f then f:write(string.format("[%.2f] %s\n", os.clock(), s)); f:close() end end
do local f = io.open(DIR .. "log.txt", "w"); if f then f:close() end end
BHOP_LOG("dev tools loaded, framework " .. tostring(SGW3 and SGW3.version))

local HOT = { "mods/trainer/Scripts/Trainer/Trainer.lua", "mods/trainer/Scripts/Trainer/Editor.lua", "mods/bhop/Scripts/Bhop/Bhop.lua" }
local polls = 0
function BHOP_DEV_POLL()
  polls = polls + 1
  if polls % 60 ~= 0 then return end
  local f = io.open(DIR .. "reload.txt", "r")
  if f then
    f:close(); os.remove(DIR .. "reload.txt")
    if SRC then
      for _, rel in ipairs(HOT) do
        local ok, err = pcall(dofile, SRC .. rel)
        BHOP_LOG("hot reload " .. rel .. " ok=" .. tostring(ok) .. (ok and "" or (" " .. tostring(err))))
      end
    else
      BHOP_LOG("hot reload needs SGW3_DEV_SRC (repo root)")
    end
  end
  f = io.open(DIR .. "exec.lua", "r")
  if f then
    f:close()
    local ok, err = pcall(dofile, DIR .. "exec.lua")
    os.remove(DIR .. "exec.lua")
    BHOP_LOG("exec ok=" .. tostring(ok) .. (ok and "" or (" " .. tostring(err))))
  end
end
SGW3.RegisterMod{ name = "SGW3 dev tools", version = "dev" }
SGW3.OnTick("00_dev", function() BHOP_DEV_POLL() end)
SGW3.OnLevelLoad("00_dev", function(level) BHOP_LOG("level load: " .. tostring(level)) end)
