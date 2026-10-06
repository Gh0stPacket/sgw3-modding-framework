-- Minimal SGW3 Mod Framework mod. Pak layout:  zzz_hello_world.pak -> Scripts/AutoLoad/hello_world/init.lua
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
