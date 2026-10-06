// sgw3_modloader.asi - SGW3 Mod Framework loader (load with Ultimate ASI Loader).
//
// 1) Hooks the game's statically linked Lua 5.1 lua_load. Right after Scripts/main.lua compiles (whichever
//    pak provides it), it compiles and runs the embedded framework (Scripts/SGW3/Framework.lua), which then
//    autoloads every Scripts/AutoLoad/<mod>/init.lua. Mods therefore never override a game file.
// 2) Publishes the keyboard state to Lua: SGW3_KEYS = 64 hex digits, digit i = virtual keys 4i..4i+3. The game
//    and this DLL share the UCRT environment (built /MT with the shared ucrt.lib), so Lua's os.getenv sees it.
//
// Addresses are for SGW3.exe 3.8.6.53 (GOG). The first bytes of each function are checked before hooking;
// on any other build the loader logs the mismatch and does nothing.

#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <ctype.h>

#include "MinHook.h"
#include "framework_lua.h"

typedef const char *(*lua_Reader)(void *L, void *ud, size_t *size);
typedef int (*lua_load_t)(void *L, lua_Reader reader, void *data, const char *chunkname);
typedef int (*lua_pcall_t)(void *L, int nargs, int nresults, int errfunc);

static const DWORD RVA_LUA_LOAD = 0x1b27d60, RVA_LUA_PCALL = 0x1b27f20;
static const unsigned char SIG_LUA_LOAD[] = { 0x48, 0x89, 0x5c, 0x24, 0x08, 0x57, 0x48, 0x83, 0xec, 0x50, 0x49, 0x8b, 0xd9, 0x48, 0x8b, 0xf9 };
static const unsigned char SIG_LUA_PCALL[] = { 0x48, 0x89, 0x5c, 0x24, 0x08, 0x57, 0x48, 0x83, 0xec, 0x40, 0x41, 0x8b, 0xf8, 0x44, 0x8b, 0xd2 };

static lua_load_t o_lua_load;
static lua_pcall_t o_lua_pcall;
static volatile LONG g_injected = 0;
static int g_logged = 0;
static char g_logPath[MAX_PATH];

static void logf(const char *fmt, ...)
{
    FILE *f = fopen(g_logPath, "a");
    if (!f) return;
    va_list ap;
    va_start(ap, fmt);
    vfprintf(f, fmt, ap);
    va_end(ap);
    fputc('\n', f);
    fclose(f);
}

struct StrReader { const char *s; size_t n; };
static const char *str_reader(void *, void *ud, size_t *size)
{
    StrReader *r = (StrReader *)ud;
    if (!r->n) return nullptr;
    *size = r->n;
    r->n = 0;
    return r->s;
}

static bool is_main_chunk(const char *name)
{
    char low[260];
    size_t i = 0;
    for (; name[i] && i < sizeof low - 1; i++) low[i] = (char)tolower((unsigned char)(name[i] == '\\' ? '/' : name[i]));
    low[i] = 0;
    return strstr(low, "scripts/main.lua") != nullptr;
}

static int hk_lua_load(void *L, lua_Reader reader, void *data, const char *chunkname)
{
    int status = o_lua_load(L, reader, data, chunkname);
    if (g_logged < 40) { g_logged++; logf("chunk: %s (status %d)", chunkname ? chunkname : "(null)", status); }
    if (status == 0 && chunkname && is_main_chunk(chunkname) && InterlockedCompareExchange(&g_injected, 1, 0) == 0) {
        // stack: [... main chunk]. Compile + run the framework (it pushes then pops its own function), leaving
        // the main chunk on top for the engine. The framework body never raises (everything is pcall'd).
        StrReader r = { kFrameworkLua, sizeof(kFrameworkLua) - 1 };
        int cs = o_lua_load(L, str_reader, &r, "=SGW3Framework");
        if (cs == 0) {
            int rs = o_lua_pcall(L, 0, 0, 0);
            logf("framework injected after %s: run status %d", chunkname, rs);
        } else {
            logf("framework failed to compile (status %d)", cs);
        }
    }
    return status;
}

static DWORD WINAPI key_thread(LPVOID)
{
    char last[65] = "", cur[65];
    for (;;) {
        DWORD pid = 0;
        HWND fg = GetForegroundWindow();
        if (fg) GetWindowThreadProcessId(fg, &pid);
        bool focused = pid == GetCurrentProcessId();
        for (int d = 0; d < 64; d++) {
            int v = 0;
            if (focused)
                for (int b = 0; b < 4; b++)
                    if (GetAsyncKeyState(d * 4 + b) & 0x8000) v |= 1 << b;
            cur[d] = "0123456789abcdef"[v];
        }
        cur[64] = 0;
        if (strcmp(cur, last) != 0) { _putenv_s("SGW3_KEYS", cur); memcpy(last, cur, sizeof cur); }
        Sleep(2);
    }
}

static bool check(const char *what, unsigned char *p, const unsigned char *sig, size_t n)
{
    if (memcmp(p, sig, n) == 0) return true;
    logf("%s signature mismatch at %p - unsupported game build, framework disabled", what, p);
    return false;
}

BOOL WINAPI DllMain(HINSTANCE inst, DWORD reason, LPVOID)
{
    if (reason != DLL_PROCESS_ATTACH) return TRUE;
    DisableThreadLibraryCalls(inst);
    char prof[MAX_PATH] = ".";
    GetEnvironmentVariableA("USERPROFILE", prof, MAX_PATH);
    snprintf(g_logPath, sizeof g_logPath, "%s\\Saved Games\\Sniper Ghost Warrior 3\\sgw3_modloader.log", prof);
    FILE *f = fopen(g_logPath, "w");
    if (f) { fputs("sgw3_modloader 1.0.0\n", f); fclose(f); }

    _putenv_s("SGW3_KEYS", "");
    CloseHandle(CreateThread(nullptr, 0, key_thread, nullptr, 0, nullptr));

    unsigned char *base = (unsigned char *)GetModuleHandleA(nullptr);
    unsigned char *pLoad = base + RVA_LUA_LOAD, *pPcall = base + RVA_LUA_PCALL;
    if (!check("lua_load", pLoad, SIG_LUA_LOAD, sizeof SIG_LUA_LOAD) || !check("lua_pcall", pPcall, SIG_LUA_PCALL, sizeof SIG_LUA_PCALL))
        return TRUE;
    o_lua_pcall = (lua_pcall_t)pPcall;
    if (MH_Initialize() != MH_OK && MH_Initialize() != MH_ERROR_ALREADY_INITIALIZED) { logf("MinHook init failed"); return TRUE; }
    if (MH_CreateHook(pLoad, (void *)hk_lua_load, (void **)&o_lua_load) != MH_OK || MH_EnableHook(pLoad) != MH_OK) {
        logf("hooking lua_load failed");
        return TRUE;
    }
    logf("hooked lua_load at %p", pLoad);
    return TRUE;
}
