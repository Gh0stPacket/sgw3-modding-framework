cmake_minimum_required(VERSION 3.21)
project(sgw3_modding_framework LANGUAGES C CXX)

# Native plugins for Sniper Ghost Warrior 3 (x64, MSVC). Run `python tools/build.py` first: it generates
# build/generated/framework_lua.h, which sgw3_modloader embeds.
#
# Runtime: the C++ runtime is linked statically because the game ships an old MSVCP140.dll (14.0.24210) that
# newer STL code crashes against, but the UCRT stays shared (ucrt.lib): the plugins pass data to the game's Lua
# through the process environment, which only works if both use the same UCRT environment block.

if(NOT MSVC OR NOT CMAKE_SIZEOF_VOID_P EQUAL 8)
  message(FATAL_ERROR "Build with MSVC for x64 (e.g. cmake -B build -A x64)")
endif()

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_MSVC_RUNTIME_LIBRARY "MultiThreaded")
add_compile_definitions(_CRT_SECURE_NO_WARNINGS WIN32_LEAN_AND_MEAN)
add_link_options(/NODEFAULTLIB:libucrt.lib ucrt.lib)

set(GENERATED ${CMAKE_SOURCE_DIR}/build/generated)
if(NOT EXISTS ${GENERATED}/framework_lua.h)
  message(FATAL_ERROR "Missing ${GENERATED}/framework_lua.h - run `python tools/build.py` first")
endif()

set(MINHOOK ${CMAKE_SOURCE_DIR}/deps/minhook)
add_library(minhook STATIC
  ${MINHOOK}/src/buffer.c ${MINHOOK}/src/hook.c ${MINHOOK}/src/trampoline.c ${MINHOOK}/src/hde/hde64.c)
target_include_directories(minhook PUBLIC ${MINHOOK}/include)

# ---- sgw3_modloader.asi: the framework core (injects framework/src/Framework.lua, keyboard bridge)
add_library(sgw3_modloader SHARED modloader/src/sgw3_modloader.cpp)
target_include_directories(sgw3_modloader PRIVATE ${GENERATED})
target_link_libraries(sgw3_modloader PRIVATE minhook user32)
set_target_properties(sgw3_modloader PROPERTIES SUFFIX ".asi")

# ---- sgw3_trainer.asi: ImGui overlay for the trainer / map editor mod
set(IMGUI ${CMAKE_SOURCE_DIR}/deps/imgui)
add_library(sgw3_trainer SHARED
  mods/trainer/native/src/sgw3_trainer.cpp
  ${IMGUI}/imgui.cpp ${IMGUI}/imgui_draw.cpp ${IMGUI}/imgui_tables.cpp ${IMGUI}/imgui_widgets.cpp
  ${IMGUI}/backends/imgui_impl_dx11.cpp ${IMGUI}/backends/imgui_impl_win32.cpp)
target_include_directories(sgw3_trainer PRIVATE ${IMGUI})
target_link_libraries(sgw3_trainer PRIVATE minhook d3d11 dxgi dwmapi dinput8 dxguid shell32 user32 gdi32)
set_target_properties(sgw3_trainer PROPERTIES SUFFIX ".asi")
