// sgw3_trainer.asi: ImGui trainer + debug console for Sniper Ghost Warrior 3 (loaded by Ultimate ASI Loader).
//
// Rendering: hooks IDXGISwapChain::Present/ResizeBuffers (vtable taken from a dummy D3D11 device) with MinHook.
// Game access goes through the game's Lua runtime (Scripts/Trainer/Trainer.lua in zzz_bhop.pak):
//   trainer -> game: process environment variable SGW3_TR_CMD = "<seq>\x1f<cmd>\x1e<cmd>..."
//                    (the game imports the shared UCRT getenv, and this DLL is built /MD, so they share it)
//   game -> trainer: named pipe \\.\pipe\sgw3_trainer, lines "ack <seq>", "out ..", "err ..", "state k=v;.."
// Insert toggles the menu. While it is open the game gets no DirectInput/keyboard/mouse input (and its action
// maps are disabled from Lua), and cursor recentering/clipping is suppressed so the mouse can drive the UI.

#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <d3d11.h>
#include <dxgi.h>
#define DIRECTINPUT_VERSION 0x0800
#include <dinput.h>
#include <stdlib.h>
#include <stdio.h>
#include <atomic>
#include <deque>
#include <map>
#include <mutex>
#include <string>
#include <vector>

#include "MinHook.h"
#include "imgui.h"
#include "backends/imgui_impl_dx11.h"
#include "backends/imgui_impl_win32.h"
#include "spawn_catalog.h"
#include <shellapi.h>

extern IMGUI_IMPL_API LRESULT ImGui_ImplWin32_WndProcHandler(HWND, UINT, WPARAM, LPARAM);

// ---------------------------------------------------------------- bridge state
static std::recursive_mutex g_bridgeMx;   // recursive: Windows can re-enter our hooks on the same thread
static std::deque<std::pair<ImU32, std::string>> g_console;   // colour, text
static std::map<std::string, std::string> g_state;
static std::vector<std::string> g_queue;                      // commands waiting to be posted
static unsigned g_seqSent = 0;
static std::atomic<unsigned> g_seqAcked{0};
static ULONGLONG g_sentAt = 0;
static std::atomic<bool> g_pipeConnected{false};
static std::atomic<ULONGLONG> g_lastState{0};

// map editor data from the game ("ed", "edobjs", "edlist" lines)
struct EdProj { int n; float x, y, z; };   // x,y on the game's virtual 800x600 screen, z < 1 = in front
static std::map<std::string, std::string> g_ed;
static std::vector<EdProj> g_edObjs;
static std::vector<std::pair<int, std::string>> g_edList;
static std::vector<std::pair<int, std::string>> g_edNear;   // nearby world entities: index, "label (dist m)"
static bool g_pickWorld = true;
static std::atomic<ULONGLONG> g_edLast{0};
// high-rate editor commands, coalesced so only the latest value is sent with each batch
static std::string g_pendingPos;
static float g_lookDX = 0, g_lookDY = 0;

static const ImU32 COL_OUT = IM_COL32(220, 220, 220, 255);
static const ImU32 COL_ERR = IM_COL32(255, 110, 110, 255);
static const ImU32 COL_CMD = IM_COL32(140, 200, 255, 255);
static const ImU32 COL_SYS = IM_COL32(170, 170, 120, 255);

static void console_add(ImU32 col, const std::string &s)
{
    std::lock_guard<std::recursive_mutex> lk(g_bridgeMx);
    g_console.emplace_back(col, s);
    while (g_console.size() > 4000) g_console.pop_front();
}

static void send_cmd(const std::string &cmd)
{
    std::lock_guard<std::recursive_mutex> lk(g_bridgeMx);
    g_queue.push_back(cmd);
}

// post queued commands when the previous batch was acked (or timed out, e.g. during a level load)
static void pump_commands()
{
    std::lock_guard<std::recursive_mutex> lk(g_bridgeMx);
    bool look = g_lookDX != 0 || g_lookDY != 0;
    if (g_queue.empty() && g_pendingPos.empty() && !look) return;
    ULONGLONG now = GetTickCount64();
    if (g_seqAcked.load() < g_seqSent && now - g_sentAt < 3000) return;
    std::string body;
    for (auto &c : g_queue) { body += c; body += '\x1e'; }
    g_queue.clear();
    if (!g_pendingPos.empty()) { body += "feat edpos " + g_pendingPos + '\x1e'; g_pendingPos.clear(); }
    if (look) {
        char b[64];
        snprintf(b, sizeof b, "feat edlook %.1f %.1f", g_lookDX, g_lookDY);
        body += b; body += '\x1e';
        g_lookDX = g_lookDY = 0;
    }
    char head[32];
    snprintf(head, sizeof head, "%u\x1f", ++g_seqSent);
    _putenv_s("SGW3_TR_CMD", (head + body).c_str());
    g_sentAt = now;
}

#include "export_pak.h"

static void handle_line(const std::string &line)
{
    if (line.rfind("ack ", 0) == 0) {
        g_seqAcked = (unsigned)strtoul(line.c_str() + 4, nullptr, 10);
    } else if (line.rfind("out ", 0) == 0) {
        console_add(COL_OUT, line.substr(4));
    } else if (line.rfind("err ", 0) == 0) {
        console_add(COL_ERR, line.substr(4));
    } else if (line.rfind("ed ", 0) == 0) {
        std::lock_guard<std::recursive_mutex> lk(g_bridgeMx);
        g_ed.clear();
        size_t p = 3;
        while (p < line.size()) {
            size_t e = line.find(';', p);
            if (e == std::string::npos) e = line.size();
            size_t eq = line.find('=', p);
            if (eq != std::string::npos && eq < e) g_ed[line.substr(p, eq - p)] = line.substr(eq + 1, e - eq - 1);
            p = e + 1;
        }
        g_edLast = GetTickCount64();
    } else if (line.rfind("edexport ", 0) == 0) {
        std::string result;
        export_layout_pak(line.substr(9), result);
        console_add(result.find(".pak") != std::string::npos ? COL_SYS : COL_ERR, "[editor] export: " + result);
    } else if (line.rfind("edobjs ", 0) == 0) {
        std::vector<EdProj> v;
        const char *c = line.c_str() + 7;
        while (*c) {
            EdProj o;
            if (sscanf(c, "%d:%f,%f,%f", &o.n, &o.x, &o.y, &o.z) == 4) v.push_back(o);
            const char *bar = strchr(c, '|');
            if (!bar) break;
            c = bar + 1;
        }
        std::lock_guard<std::recursive_mutex> lk(g_bridgeMx);
        g_edObjs.swap(v);
    } else if (line.rfind("edlist ", 0) == 0) {
        std::vector<std::pair<int, std::string>> v;
        size_t p = 7;
        while (p < line.size()) {
            size_t e = line.find(';', p);
            if (e == std::string::npos) e = line.size();
            size_t bar = line.find('|', p);
            if (bar != std::string::npos && bar < e) v.emplace_back(atoi(line.substr(p, bar - p).c_str()), line.substr(bar + 1, e - bar - 1));
            p = e + 1;
        }
        std::lock_guard<std::recursive_mutex> lk(g_bridgeMx);
        g_edList.swap(v);
    } else if (line.rfind("ednear ", 0) == 0) {
        // "i|label|dist;..."
        std::vector<std::pair<int, std::string>> v;
        size_t p = 7;
        while (p < line.size()) {
            size_t e = line.find(';', p);
            if (e == std::string::npos) e = line.size();
            std::string item = line.substr(p, e - p);
            size_t b1 = item.find('|'), b2 = item.rfind('|');
            if (b1 != std::string::npos && b2 > b1)
                v.emplace_back(atoi(item.substr(0, b1).c_str()), item.substr(b1 + 1, b2 - b1 - 1) + "  " + item.substr(b2 + 1) + " m");
            p = e + 1;
        }
        std::lock_guard<std::recursive_mutex> lk(g_bridgeMx);
        g_edNear.swap(v);
    } else if (line.rfind("state ", 0) == 0) {
        std::lock_guard<std::recursive_mutex> lk(g_bridgeMx);
        size_t p = 6;
        while (p < line.size()) {
            size_t e = line.find(';', p);
            if (e == std::string::npos) e = line.size();
            size_t eq = line.find('=', p);
            if (eq != std::string::npos && eq < e) g_state[line.substr(p, eq - p)] = line.substr(eq + 1, e - eq - 1);
            p = e + 1;
        }
        g_lastState = GetTickCount64();
    }
}

static DWORD WINAPI pipe_thread(LPVOID)
{
    for (;;) {
        HANDLE h = CreateNamedPipeA("\\\\.\\pipe\\sgw3_trainer", PIPE_ACCESS_DUPLEX,
                                    PIPE_TYPE_BYTE | PIPE_READMODE_BYTE | PIPE_WAIT, 1, 4096, 1 << 16, 0, nullptr);
        if (h == INVALID_HANDLE_VALUE) { Sleep(1000); continue; }
        if (ConnectNamedPipe(h, nullptr) || GetLastError() == ERROR_PIPE_CONNECTED) {
            g_pipeConnected = true;
            console_add(COL_SYS, "[trainer] game connected");
            std::string acc;
            char buf[8192];
            DWORD n;
            while (ReadFile(h, buf, sizeof buf, &n, nullptr) && n) {
                acc.append(buf, n);
                size_t nl;
                while ((nl = acc.find('\n')) != std::string::npos) {
                    handle_line(acc.substr(0, nl));
                    acc.erase(0, nl + 1);
                }
            }
            g_pipeConnected = false;
            console_add(COL_SYS, "[trainer] game disconnected");
        }
        DisconnectNamedPipe(h);
        CloseHandle(h);
    }
}

static std::string st(const char *k, const char *def = "")
{
    std::lock_guard<std::recursive_mutex> lk(g_bridgeMx);
    auto it = g_state.find(k);
    return it == g_state.end() ? def : it->second;
}
static float stf(const char *k, float def = 0) { std::string s = st(k); return s.empty() ? def : (float)atof(s.c_str()); }
static bool stb(const char *k) { return stf(k) != 0; }

// ---------------------------------------------------------------- input / cursor
static HWND g_hwnd = nullptr;
static WNDPROC g_origWndProc = nullptr;
static std::atomic<bool> g_menuOpen{false};   // input captured (trainer window or editor open)
static bool g_showMenu = false;
static bool g_editor = false;
static bool g_looking = false;                  // editor mouse-look (RMB held)
static std::recursive_mutex g_imguiMx;

typedef BOOL(WINAPI *SetCursorPos_t)(int, int);
typedef BOOL(WINAPI *ClipCursor_t)(const RECT *);
static SetCursorPos_t oSetCursorPos;
static ClipCursor_t oClipCursor;
static BOOL WINAPI hkSetCursorPos(int x, int y) { return g_menuOpen ? TRUE : oSetCursorPos(x, y); }
static BOOL WINAPI hkClipCursor(const RECT *r) { return oClipCursor(g_menuOpen ? nullptr : r); }

// CryEngine reads keyboard and mouse through DirectInput; while the menu is open, report no input.
typedef HRESULT(STDMETHODCALLTYPE *GetDeviceState_t)(IDirectInputDevice8W *, DWORD, LPVOID);
typedef HRESULT(STDMETHODCALLTYPE *GetDeviceData_t)(IDirectInputDevice8W *, DWORD, LPDIDEVICEOBJECTDATA, LPDWORD, DWORD);
static GetDeviceState_t oGetDeviceStateW, oGetDeviceStateA;
static GetDeviceData_t oGetDeviceDataW, oGetDeviceDataA;

static HRESULT blank_state(HRESULT hr, DWORD size, LPVOID data)
{
    if (SUCCEEDED(hr) && g_menuOpen && data) memset(data, 0, size);
    return hr;
}
static HRESULT blank_data(HRESULT hr, LPDWORD count, DWORD flags)
{
    // drain the buffer but hand the game nothing (DIGDD_PEEK leaves it alone anyway)
    if (SUCCEEDED(hr) && g_menuOpen && count && !(flags & DIGDD_PEEK)) *count = 0;
    return hr;
}
static HRESULT STDMETHODCALLTYPE hkGetDeviceStateW(IDirectInputDevice8W *d, DWORD n, LPVOID p) { return blank_state(oGetDeviceStateW(d, n, p), n, p); }
static HRESULT STDMETHODCALLTYPE hkGetDeviceStateA(IDirectInputDevice8W *d, DWORD n, LPVOID p) { return blank_state(oGetDeviceStateA(d, n, p), n, p); }
static HRESULT STDMETHODCALLTYPE hkGetDeviceDataW(IDirectInputDevice8W *d, DWORD sz, LPDIDEVICEOBJECTDATA od, LPDWORD n, DWORD f) { return blank_data(oGetDeviceDataW(d, sz, od, n, f), n, f); }
static HRESULT STDMETHODCALLTYPE hkGetDeviceDataA(IDirectInputDevice8W *d, DWORD sz, LPDIDEVICEOBJECTDATA od, LPDWORD n, DWORD f) { return blank_data(oGetDeviceDataA(d, sz, od, n, f), n, f); }

// hook IDirectInputDevice8 W and A vtables (GetDeviceState = slot 9, GetDeviceData = slot 10)
static void hook_dinput()
{
    HMODULE inst = GetModuleHandleA(nullptr);
    IDirectInput8W *diW = nullptr;
    if (SUCCEEDED(DirectInput8Create(inst, DIRECTINPUT_VERSION, IID_IDirectInput8W, (void **)&diW, nullptr))) {
        IDirectInputDevice8W *dev = nullptr;
        if (SUCCEEDED(diW->CreateDevice(GUID_SysKeyboard, &dev, nullptr))) {
            void **vt = *(void ***)dev;
            MH_CreateHook(vt[9], (void *)hkGetDeviceStateW, (void **)&oGetDeviceStateW);
            MH_CreateHook(vt[10], (void *)hkGetDeviceDataW, (void **)&oGetDeviceDataW);
            dev->Release();
        }
        diW->Release();
    }
    IDirectInput8A *diA = nullptr;
    if (SUCCEEDED(DirectInput8Create(inst, DIRECTINPUT_VERSION, IID_IDirectInput8A, (void **)&diA, nullptr))) {
        IDirectInputDevice8A *dev = nullptr;
        if (SUCCEEDED(diA->CreateDevice(GUID_SysKeyboard, &dev, nullptr))) {
            void **vt = *(void ***)dev;
            // A and W can share one implementation; MinHook refuses a second hook on the same address
            if (MH_CreateHook(vt[9], (void *)hkGetDeviceStateA, (void **)&oGetDeviceStateA) != MH_OK) oGetDeviceStateA = oGetDeviceStateW;
            if (MH_CreateHook(vt[10], (void *)hkGetDeviceDataA, (void **)&oGetDeviceDataA) != MH_OK) oGetDeviceDataA = oGetDeviceDataW;
            dev->Release();
        }
        diA->Release();
    }
}

static LRESULT CALLBACK hkWndProc(HWND h, UINT m, WPARAM w, LPARAM l)
{
    if (g_menuOpen) {
        try {
            std::lock_guard<std::recursive_mutex> lk(g_imguiMx);
            if (ImGui::GetCurrentContext()) ImGui_ImplWin32_WndProcHandler(h, m, w, l);
        } catch (...) {
        }
        if ((m >= WM_MOUSEFIRST && m <= WM_MOUSELAST) || (m >= WM_KEYFIRST && m <= WM_KEYLAST) || m == WM_INPUT) return 0;
    }
    return CallWindowProcA(g_origWndProc, h, m, w, l);
}

static void update_capture()
{
    bool cap = g_showMenu || g_editor;
    if (cap == g_menuOpen) return;
    g_menuOpen = cap;
    send_cmd(cap ? "feat menu 1" : "feat menu 0");
    if (cap) oClipCursor(nullptr);
}

static void set_menu(bool open) { g_showMenu = open; update_capture(); }

static void set_editor(bool on)
{
    g_editor = on;
    g_looking = false;
    send_cmd(on ? "feat ed 1" : "feat ed 0");
    update_capture();
}

// ---------------------------------------------------------------- UI
static bool g_showOverlay = true;
static char g_input[1024];
static std::vector<std::string> g_history;
static int g_histPos = -1;
static bool g_scrollToBottom = true;
static ImGuiTextFilter g_filter;

static void cvar_toggle(const char *label, const char *stateKey, const char *cvar)
{
    bool v = stb(stateKey);
    if (ImGui::Checkbox(label, &v)) {
        send_cmd(std::string("set ") + cvar + (v ? " 1" : " 0"));
        std::lock_guard<std::recursive_mutex> lk(g_bridgeMx);
        g_state[stateKey] = v ? "1" : "0";
    }
}

static void feat_toggle(const char *label, const char *key)
{
    bool v = stb(key);
    if (ImGui::Checkbox(label, &v)) {
        send_cmd(std::string("feat ") + key + (v ? " 1" : " 0"));
        std::lock_guard<std::recursive_mutex> lk(g_bridgeMx);
        g_state[key] = v ? "1" : "0";
    }
}

static void cvar_slider(const char *label, const char *stateKey, const char *cvar, float lo, float hi, const char *fmt = "%.2f")
{
    float v = stf(stateKey, lo);
    if (ImGui::SliderFloat(label, &v, lo, hi, fmt)) {
        char b[64];
        snprintf(b, sizeof b, " %g", v);
        send_cmd(std::string("set ") + cvar + b);
        std::lock_guard<std::recursive_mutex> lk(g_bridgeMx);
        g_state[stateKey] = std::to_string(v);
    }
}

static void bhop_slider(const char *label, const char *key, float lo, float hi)
{
    std::string sk = std::string("cfg.") + key;
    float v = stf(sk.c_str(), lo);
    if (ImGui::SliderFloat(label, &v, lo, hi, "%.2f")) {
        char b[96];
        snprintf(b, sizeof b, "feat bhopcfg %s %g", key, v);
        send_cmd(b);
        std::lock_guard<std::recursive_mutex> lk(g_bridgeMx);
        g_state[sk] = std::to_string(v);
    }
}

static int history_cb(ImGuiInputTextCallbackData *d)
{
    if (d->EventFlag != ImGuiInputTextFlags_CallbackHistory || g_history.empty()) return 0;
    if (d->EventKey == ImGuiKey_UpArrow) g_histPos = g_histPos < 0 ? (int)g_history.size() - 1 : (g_histPos > 0 ? g_histPos - 1 : 0);
    else if (d->EventKey == ImGuiKey_DownArrow && g_histPos >= 0) g_histPos = g_histPos + 1 < (int)g_history.size() ? g_histPos + 1 : -1;
    d->DeleteChars(0, d->BufTextLen);
    if (g_histPos >= 0) d->InsertChars(0, g_history[g_histPos].c_str());
    return 0;
}

static void draw_console()
{
    g_filter.Draw("Filter", 200);
    ImGui::SameLine();
    if (ImGui::SmallButton("Clear")) { std::lock_guard<std::recursive_mutex> lk(g_bridgeMx); g_console.clear(); }
    ImGui::SameLine();
    if (ImGui::SmallButton("Help")) send_cmd("lua help");
    float footer = ImGui::GetStyle().ItemSpacing.y + ImGui::GetFrameHeightWithSpacing();
    if (ImGui::BeginChild("log", ImVec2(0, -footer), ImGuiChildFlags_Borders, ImGuiWindowFlags_HorizontalScrollbar)) {
        std::lock_guard<std::recursive_mutex> lk(g_bridgeMx);
        for (auto &e : g_console) {
            if (!g_filter.PassFilter(e.second.c_str())) continue;
            ImGui::PushStyleColor(ImGuiCol_Text, e.first);
            ImGui::TextUnformatted(e.second.c_str());
            ImGui::PopStyleColor();
        }
        if (g_scrollToBottom || ImGui::GetScrollY() >= ImGui::GetScrollMaxY()) ImGui::SetScrollHereY(1.0f);
        g_scrollToBottom = false;
    }
    ImGui::EndChild();
    ImGui::SetNextItemWidth(-1);
    if (ImGui::InputText("##in", g_input, sizeof g_input,
                         ImGuiInputTextFlags_EnterReturnsTrue | ImGuiInputTextFlags_CallbackHistory, history_cb)) {
        std::string line = g_input;
        if (!line.empty()) {
            console_add(COL_CMD, "> " + line);
            g_history.push_back(line);
            g_histPos = -1;
            send_cmd("lua " + line);
        }
        g_input[0] = 0;
        g_scrollToBottom = true;
        ImGui::SetKeyboardFocusHere(-1);
    }
}

static int g_spawnGroup = 0;
static int g_spawnSel = -1;
static int g_spawnCount = 1;
static int g_spawnMode = 0;     // 0 crosshair, 1 in front
static int g_spawnFacing = 0;   // 0 toward me, 1 away
static ImGuiTextFilter g_spawnFilter;

static void draw_spawner()
{
    const int n = (int)(sizeof kSpawnCatalog / sizeof kSpawnCatalog[0]);
    std::vector<const char *> groups;
    for (int i = 0; i < n; i++) {
        bool seen = false;
        for (auto *g : groups) seen |= strcmp(g, kSpawnCatalog[i].group) == 0;
        if (!seen) groups.push_back(kSpawnCatalog[i].group);
    }
    if (g_spawnGroup >= (int)groups.size()) g_spawnGroup = 0;
    ImGui::SetNextItemWidth(260);
    if (ImGui::BeginCombo("Faction", groups[g_spawnGroup])) {
        for (int g = 0; g < (int)groups.size(); g++)
            if (ImGui::Selectable(groups[g], g == g_spawnGroup)) { g_spawnGroup = g; g_spawnSel = -1; }
        ImGui::EndCombo();
    }
    g_spawnFilter.Draw("Search", 260);
    if (ImGui::BeginListBox("##types", ImVec2(-1, 200))) {
        for (int i = 0; i < n; i++) {
            const SpawnEntry &e = kSpawnCatalog[i];
            if (strcmp(e.group, groups[g_spawnGroup]) != 0 || !g_spawnFilter.PassFilter(e.archetype)) continue;
            const char *shortName = strchr(e.archetype, '.');
            char label[160];
            snprintf(label, sizeof label, "%s  (%s)", shortName ? shortName + 1 : e.archetype, e.cls);
            if (ImGui::Selectable(label, i == g_spawnSel)) g_spawnSel = i;
        }
        ImGui::EndListBox();
    }
    ImGui::SliderInt("Count", &g_spawnCount, 1, 20);
    ImGui::RadioButton("At crosshair", &g_spawnMode, 0); ImGui::SameLine();
    ImGui::RadioButton("In front of me", &g_spawnMode, 1);
    ImGui::RadioButton("Facing me", &g_spawnFacing, 0); ImGui::SameLine();
    ImGui::RadioButton("Facing away", &g_spawnFacing, 1);
    ImGui::BeginDisabled(g_spawnSel < 0);
    if (ImGui::Button("Spawn", ImVec2(120, 0)) && g_spawnSel >= 0) {
        const SpawnEntry &e = kSpawnCatalog[g_spawnSel];
        char b[256];
        snprintf(b, sizeof b, "feat spawn %s %s %d %s %s", e.archetype, e.cls, g_spawnCount,
                 g_spawnMode == 0 ? "aim" : "front", g_spawnFacing == 0 ? "face" : "away");
        send_cmd(b);
    }
    ImGui::EndDisabled();
    ImGui::SameLine();
    if (ImGui::Button("Kill all spawned")) send_cmd("feat killspawned");
    ImGui::SameLine();
    if (ImGui::Button("Remove all spawned")) send_cmd("feat despawn");
    ImGui::TextDisabled("Hostile factions attack you unless 'Invisible to enemies' is on. Results show in Console.");
}

static void draw_menu()
{
    ImGui::SetNextWindowSize(ImVec2(560, 520), ImGuiCond_FirstUseEver);
    ImGui::Begin("SGW3 Trainer  [Insert]");
    bool live = GetTickCount64() - g_lastState.load() < 1500;
    ImGui::TextColored(live ? ImVec4(0.4f, 1, 0.4f, 1) : ImVec4(1, 0.5f, 0.3f, 1),
                       live ? "game bridge: live" : (g_pipeConnected ? "game bridge: connected, waiting" : "game bridge: not connected (zzz_bhop.pak loaded?)"));
    if (ImGui::BeginTabBar("tabs")) {
        if (ImGui::BeginTabItem("Player")) {
            // the game's cheat cvars are locked in this build; these run through the trainer's Lua side
            feat_toggle("God mode (ignore all damage)", "god");
            feat_toggle("Infinite health (refill every frame)", "infhealth");
            feat_toggle("Infinite ammo (clip stays full)", "ammo");
            feat_toggle("Invisible to enemies", "invisible");
            feat_toggle("Freeze AI (within 500 m)", "aifreeze");
            if (ImGui::Button("Refill health")) send_cmd("feat heal");
            ImGui::SeparatorText("Teleport");
            for (int i = 1; i <= 3; i++) {
                char b[48];
                ImGui::PushID(i);
                snprintf(b, sizeof b, "Save %d", i);
                if (ImGui::Button(b)) { snprintf(b, sizeof b, "feat tp_save %d", i); send_cmd(b); }
                ImGui::SameLine();
                snprintf(b, sizeof b, "Load %d", i);
                if (ImGui::Button(b)) { snprintf(b, sizeof b, "feat tp_load %d", i); send_cmd(b); }
                if (i < 3) ImGui::SameLine(0, 20);
                ImGui::PopID();
            }
            if (ImGui::Button("Blink forward 10 m")) send_cmd("feat tp_fwd 10");
            ImGui::SameLine();
            if (ImGui::Button("50 m")) send_cmd("feat tp_fwd 50");
            ImGui::EndTabItem();
        }
        if (ImGui::BeginTabItem("Movement")) {
            bool bh = stb("bhop");
            if (ImGui::Checkbox("Bunny hop (F6)", &bh)) send_cmd(bh ? "feat bhop 1" : "feat bhop 0");
            bhop_slider("Air accel", "air_accel", 0, 40);
            bhop_slider("Strafe gain cap (m/s)", "air_wish_cap", 0, 10);
            bhop_slider("Max speed (m/s)", "max_speed", 5, 60);
            bhop_slider("Per-hop boost", "hop_boost", 1, 1.3f);
            bhop_slider("Jump speed (m/s)", "jump_speed", 3, 20);
            if (ImGui::Button("Reset bhop to defaults")) send_cmd("feat bhopreset");
            ImGui::SeparatorText("Noclip");
            feat_toggle("Noclip fly (WASD, Space up, C down, Shift fast)", "noclip");
            {
                float v = stf("noclipspeed", 12);
                if (ImGui::SliderFloat("Noclip speed (m/s)", &v, 2, 60, "%.0f")) {
                    char b[64];
                    snprintf(b, sizeof b, "feat noclipspeed %g", v);
                    send_cmd(b);
                    std::lock_guard<std::recursive_mutex> lk(g_bridgeMx);
                    g_state["noclipspeed"] = std::to_string(v);
                }
            }
            ImGui::EndTabItem();
        }
        if (ImGui::BeginTabItem("World")) {
            cvar_slider("Time scale", "tscale", "t_Scale", 0.05f, 3);
            if (ImGui::Button("Normal time")) send_cmd("set t_Scale 1");
            cvar_slider("Time of day (h)", "tod", "e_TimeOfDay", 0, 24, "%.1f");
            cvar_slider("Time of day speed", "todspeed", "e_TimeOfDaySpeed", 0, 10);
            cvar_slider("Field of view", "fov", "cl_fov", 40, 120, "%.0f");
            ImGui::Checkbox("Speed / position overlay", &g_showOverlay);
            ImGui::EndTabItem();
        }
        if (ImGui::BeginTabItem("Spawner")) {
            draw_spawner();
            ImGui::EndTabItem();
        }
        if (ImGui::BeginTabItem("Map Editor")) {
            ImGui::TextWrapped("Fly-cam editor: place any of the game's models, move them with X/Y/Z arrows, save layouts.");
            if (ImGui::Button(g_editor ? "Exit editor" : "Enter editor", ImVec2(160, 0))) set_editor(!g_editor);
            ImGui::EndTabItem();
        }
        if (ImGui::BeginTabItem("Console")) {
            draw_console();
            ImGui::EndTabItem();
        }
        ImGui::EndTabBar();
    }
    ImGui::End();
}

static void draw_overlay()
{
    if (!g_showOverlay || GetTickCount64() - g_lastState.load() > 1500 || st("hp").empty()) return;
    ImGui::SetNextWindowPos(ImVec2(12, 12), ImGuiCond_Always);
    ImGui::SetNextWindowBgAlpha(0.45f);
    ImGui::Begin("##overlay", nullptr, ImGuiWindowFlags_NoDecoration | ImGuiWindowFlags_AlwaysAutoResize |
                                           ImGuiWindowFlags_NoInputs | ImGuiWindowFlags_NoFocusOnAppearing | ImGuiWindowFlags_NoNav);
    ImGui::Text("speed %5.2f m/s   vz %5.2f", stf("spd"), stf("vz"));
    ImGui::Text("pos %.1f %.1f %.1f", stf("x"), stf("y"), stf("z"));
    ImGui::Text("hp %.0f/%.0f   fps %.0f%s", stf("hp"), stf("maxhp"), stf("fps"), stb("bhop") ? "   bhop" : "");
    ImGui::End();
}

// ---------------------------------------------------------------- map editor
static std::vector<std::string> g_models;
static bool g_modelsLoaded = false;
static ImGuiTextFilter g_modelFilter;
static int g_modelSel = -1;
static char g_layoutName[64] = "default";
static int g_dragAxis = -1;                    // 0 x, 1 y, 2 z
static ImVec2 g_dragStart;
static float g_dragOrigin[3], g_dragAxisPx[2], g_dragLen;
static POINT g_lookAnchor;
static bool g_noKeys = false;

static void load_models()
{
    g_modelsLoaded = true;
    char path[MAX_PATH];
    HMODULE self = nullptr;
    GetModuleHandleExA(GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS | GET_MODULE_HANDLE_EX_FLAG_UNCHANGED_REFCOUNT, (LPCSTR)&load_models, &self);
    GetModuleFileNameA(self, path, MAX_PATH);
    char *slash = strrchr(path, '\\');
    if (slash) strcpy(slash + 1, "sgw3_models.txt");
    FILE *f = fopen(path, "r");
    if (!f) { console_add(COL_ERR, std::string("[editor] model list not found: ") + path); return; }
    char line[512];
    while (fgets(line, sizeof line, f)) {
        size_t n = strlen(line);
        while (n && (line[n - 1] == '\n' || line[n - 1] == '\r')) line[--n] = 0;
        if (n) g_models.emplace_back(line);
    }
    fclose(f);
}

static std::string edv(const char *k)
{
    std::lock_guard<std::recursive_mutex> lk(g_bridgeMx);
    auto it = g_ed.find(k);
    return it == g_ed.end() ? "" : it->second;
}
static float edf(const char *k) { return (float)atof(edv(k).c_str()); }

// "x,y,z" projected point -> real screen pixels; false when behind the camera
static bool edp(const char *k, ImVec2 &out)
{
    float x, y, z;
    if (sscanf(edv(k).c_str(), "%f,%f,%f", &x, &y, &z) != 3 || z >= 1.0f) return false;
    ImVec2 ds = ImGui::GetIO().DisplaySize;
    out = ImVec2(x / 800.f * ds.x, y / 600.f * ds.y);
    return true;
}

static float seg_dist(ImVec2 p, ImVec2 a, ImVec2 b)
{
    float vx = b.x - a.x, vy = b.y - a.y, wx = p.x - a.x, wy = p.y - a.y;
    float l2 = vx * vx + vy * vy;
    float t = l2 > 0 ? (wx * vx + wy * vy) / l2 : 0;
    t = t < 0 ? 0 : (t > 1 ? 1 : t);
    float dx = a.x + vx * t - p.x, dy = a.y + vy * t - p.y;
    return sqrtf(dx * dx + dy * dy);
}

static void draw_arrow(ImDrawList *dl, ImVec2 a, ImVec2 b, ImU32 col, float th)
{
    dl->AddLine(a, b, col, th);
    float dx = b.x - a.x, dy = b.y - a.y, l = sqrtf(dx * dx + dy * dy);
    if (l < 1) return;
    dx /= l; dy /= l;
    ImVec2 p1(b.x - dx * 14 - dy * 6, b.y - dy * 14 + dx * 6), p2(b.x - dx * 14 + dy * 6, b.y - dy * 14 - dx * 6);
    dl->AddTriangleFilled(b, p1, p2, col);
}

// gizmo drawing, axis dragging, click picking and RMB mouse-look in the 3D view
static void editor_viewport()
{
    ImGuiIO &io = ImGui::GetIO();
    ImDrawList *dl = ImGui::GetForegroundDrawList();
    bool live = GetTickCount64() - g_edLast.load() < 1000;
    int sel = live ? atoi(edv("sel").c_str()) : 0;

    // mouse look while RMB held over the 3D view
    if (!g_looking && ImGui::IsMouseClicked(ImGuiMouseButton_Right) && !io.WantCaptureMouse) {
        g_looking = true;
        GetCursorPos(&g_lookAnchor);
    }
    if (g_looking) {
        if (!ImGui::IsMouseDown(ImGuiMouseButton_Right)) {
            g_looking = false;
        } else {
            POINT c;
            GetCursorPos(&c);
            std::lock_guard<std::recursive_mutex> lk(g_bridgeMx);
            g_lookDX += (float)(c.x - g_lookAnchor.x);
            g_lookDY += (float)(c.y - g_lookAnchor.y);
            oSetCursorPos(g_lookAnchor.x, g_lookAnchor.y);
        }
        return;
    }

    // other placed objects: small markers
    {
        std::lock_guard<std::recursive_mutex> lk(g_bridgeMx);
        for (auto &o : g_edObjs) {
            if (o.z >= 1.0f || o.n == sel) continue;
            ImVec2 c(o.x / 800.f * io.DisplaySize.x, o.y / 600.f * io.DisplaySize.y);
            dl->AddCircle(c, 6, IM_COL32(255, 220, 80, 200), 0, 2);
        }
    }

    ImVec2 o, ax[3];
    bool haveGizmo = sel > 0 && edp("o", o);
    bool ok[3] = { haveGizmo && edp("ax", ax[0]), haveGizmo && edp("ay", ax[1]), haveGizmo && edp("az", ax[2]) };
    const ImU32 cols[3] = { IM_COL32(235, 60, 60, 255), IM_COL32(60, 220, 60, 255), IM_COL32(70, 120, 255, 255) };
    const char *names[3] = { "X", "Y", "Z" };

    int hover = -1;
    if (haveGizmo && g_dragAxis < 0 && !io.WantCaptureMouse) {
        float best = 10;
        for (int i = 0; i < 3; i++)
            if (ok[i]) { float d = seg_dist(io.MousePos, o, ax[i]); if (d < best) { best = d; hover = i; } }
    }
    if (haveGizmo) {
        for (int i = 0; i < 3; i++) {
            if (!ok[i]) continue;
            bool hot = i == hover || i == g_dragAxis;
            draw_arrow(dl, o, ax[i], hot ? IM_COL32(255, 255, 140, 255) : cols[i], hot ? 5.f : 3.5f);
            dl->AddText(ImVec2(ax[i].x + 6, ax[i].y - 8), cols[i], names[i]);
        }
        dl->AddCircleFilled(o, 4, IM_COL32_WHITE);
    }

    // start / continue / finish an axis drag
    if (hover >= 0 && ImGui::IsMouseClicked(ImGuiMouseButton_Left)) {
        g_dragAxis = hover;
        g_dragStart = io.MousePos;
        g_dragOrigin[0] = edf("x"); g_dragOrigin[1] = edf("y"); g_dragOrigin[2] = edf("z");
        g_dragAxisPx[0] = ax[hover].x - o.x; g_dragAxisPx[1] = ax[hover].y - o.y;
        g_dragLen = edf("len");
    } else if (g_dragAxis >= 0) {
        if (!ImGui::IsMouseDown(ImGuiMouseButton_Left)) {
            g_dragAxis = -1;
        } else {
            // project the mouse movement onto the arrow's screen direction; arrow length = g_dragLen metres
            float vx = g_dragAxisPx[0], vy = g_dragAxisPx[1], l2 = vx * vx + vy * vy;
            if (l2 > 4) {
                float t = ((io.MousePos.x - g_dragStart.x) * vx + (io.MousePos.y - g_dragStart.y) * vy) / l2 * g_dragLen;
                float np[3] = { g_dragOrigin[0], g_dragOrigin[1], g_dragOrigin[2] };
                np[g_dragAxis] += t;
                char b[96];
                snprintf(b, sizeof b, "%.4f %.4f %.4f", np[0], np[1], np[2]);
                std::lock_guard<std::recursive_mutex> lk(g_bridgeMx);
                g_pendingPos = b;
            }
        }
    } else if (ImGui::IsMouseClicked(ImGuiMouseButton_Left) && !io.WantCaptureMouse) {
        // click picking: an edited object's marker under the cursor wins; otherwise ray-pick a world entity
        int best = -1;
        float bestD = 22;
        {
            std::lock_guard<std::recursive_mutex> lk(g_bridgeMx);
            for (auto &e : g_edObjs) {
                if (e.z >= 1.0f) continue;
                float dx = e.x / 800.f * io.DisplaySize.x - io.MousePos.x, dy = e.y / 600.f * io.DisplaySize.y - io.MousePos.y;
                float d = sqrtf(dx * dx + dy * dy);
                if (d < bestD) { bestD = d; best = e.n; }
            }
        }
        if (best > 0) {
            send_cmd("feat edsel " + std::to_string(best));
        } else if (g_pickWorld) {
            char b[96];
            snprintf(b, sizeof b, "feat edpickray %.2f %.2f %.4f", io.MousePos.x / io.DisplaySize.x * 800.f,
                     io.MousePos.y / io.DisplaySize.y * 600.f, io.DisplaySize.x / io.DisplaySize.y);
            send_cmd(b);
        } else {
            send_cmd("feat edsel none");
        }
    }
}

static void draw_editor()
{
    if (!g_modelsLoaded) load_models();
    editor_viewport();

    // pause fly keys while typing into a text box
    bool typing = ImGui::GetIO().WantTextInput;
    if (typing != g_noKeys) { g_noKeys = typing; _putenv_s("SGW3_ED_NOKEYS", typing ? "1" : "0"); }

    ImGui::SetNextWindowPos(ImVec2(ImGui::GetIO().DisplaySize.x - 470, 40), ImGuiCond_FirstUseEver);
    ImGui::SetNextWindowSize(ImVec2(450, 760), ImGuiCond_FirstUseEver);
    ImGui::Begin("Map Editor");
    ImGui::TextDisabled("RMB: look   WASD/Space/C: fly   Shift: fast   LMB: pick / drag arrows");
    if (ImGui::Button("Exit editor")) set_editor(false);
    ImGui::SameLine();
    float spd = stf("noclipspeed", 12);
    ImGui::SetNextItemWidth(160);
    if (ImGui::SliderFloat("Fly speed", &spd, 2, 60, "%.0f m/s")) {
        char b[64];
        snprintf(b, sizeof b, "feat noclipspeed %g", spd);
        send_cmd(b);
        std::lock_guard<std::recursive_mutex> lk(g_bridgeMx);
        g_state["noclipspeed"] = std::to_string(spd);
    }

    ImGui::SeparatorText("Models");
    g_modelFilter.Draw("Search##models", 300);
    ImGui::SameLine();
    ImGui::TextDisabled("%d", (int)g_models.size());
    std::vector<int> shown;
    for (int i = 0; i < (int)g_models.size(); i++)
        if (g_modelFilter.PassFilter(g_models[i].c_str())) shown.push_back(i);
    if (ImGui::BeginListBox("##models", ImVec2(-1, 230))) {
        ImGuiListClipper clip;
        clip.Begin((int)shown.size());
        while (clip.Step())
            for (int r = clip.DisplayStart; r < clip.DisplayEnd; r++) {
                int i = shown[r];
                const char *full = g_models[i].c_str();
                const char *base = strrchr(full, '/');
                ImGui::PushID(i);
                if (ImGui::Selectable(base ? base + 1 : full, i == g_modelSel, ImGuiSelectableFlags_AllowDoubleClick)) {
                    g_modelSel = i;
                    if (ImGui::IsMouseDoubleClicked(ImGuiMouseButton_Left)) send_cmd("feat edspawn " + g_models[i]);
                }
                if (ImGui::IsItemHovered()) ImGui::SetTooltip("%s", full);
                ImGui::PopID();
            }
        ImGui::EndListBox();
    }
    ImGui::BeginDisabled(g_modelSel < 0);
    if (ImGui::Button("Place at crosshair  (or double-click)") && g_modelSel >= 0) send_cmd("feat edspawn " + g_models[g_modelSel]);
    ImGui::EndDisabled();

    ImGui::SeparatorText("Selected");
    bool live = GetTickCount64() - g_edLast.load() < 1000;
    int sel = live ? atoi(edv("sel").c_str()) : 0;
    bool world = edv("kind") == "world";
    if (sel > 0) {
        if (world) {
            ImGui::TextColored(ImVec4(0.55f, 0.85f, 1, 1), "Level entity");
            ImGui::TextWrapped("#%d  %s  (%s)%s", sel, edv("model").c_str(), edv("cls").c_str(), edf("hidden") != 0 ? "  [hidden]" : "");
        } else {
            ImGui::TextWrapped("#%d  %s", sel, edv("model").c_str());
        }
        float pos[3] = { edf("x"), edf("y"), edf("z") };
        if (ImGui::DragFloat3("Position", pos, 0.05f, 0, 0, "%.2f")) {
            char b[96];
            snprintf(b, sizeof b, "%.4f %.4f %.4f", pos[0], pos[1], pos[2]);
            std::lock_guard<std::recursive_mutex> lk(g_bridgeMx);
            g_pendingPos = b;
        }
        float rot[3] = { edf("rx"), edf("ry"), edf("rz") };
        if (ImGui::DragFloat3("Rotation (deg)", rot, 0.5f, -360, 360, "%.1f")) {
            char b[96];
            snprintf(b, sizeof b, "feat edrot %.2f %.2f %.2f", rot[0], rot[1], rot[2]);
            send_cmd(b);
        }
        float sc = edf("s");
        if (ImGui::DragFloat("Scale", &sc, 0.01f, 0.05f, 50, "%.2f")) {
            char b[64];
            snprintf(b, sizeof b, "feat edscale %.3f", sc);
            send_cmd(b);
        }
        if (ImGui::Button("Drop to ground")) send_cmd("feat edground");
        ImGui::SameLine();
        if (ImGui::Button("Move to crosshair")) send_cmd("feat edtocam");
        ImGui::SameLine();
        if (ImGui::Button("Duplicate")) send_cmd("feat eddup");
        ImGui::SameLine();
        if (world) {
            if (ImGui::Button(edf("hidden") != 0 ? "Show" : "Hide")) send_cmd("feat edhide");
            ImGui::SameLine();
            if (ImGui::Button("Reset to original")) send_cmd("feat edreset");
        } else {
            if (ImGui::Button("Delete")) send_cmd("feat eddel");
        }
    } else {
        ImGui::TextDisabled("Nothing selected - click an object in the world, a yellow marker, or place a model.");
    }
    ImGui::Checkbox("Click picks level entities", &g_pickWorld);
    ImGui::SameLine();
    ImGui::TextDisabled("(static geometry can't be edited)");

    ImGui::SeparatorText("Nearby level entities");
    {
        static float radius = 40;
        static char filter[64] = "";
        ImGui::SetNextItemWidth(120);
        ImGui::SliderFloat("Radius", &radius, 5, 300, "%.0f m");
        ImGui::SameLine();
        ImGui::SetNextItemWidth(120);
        ImGui::InputText("Filter##near", filter, sizeof filter);
        ImGui::SameLine();
        if (ImGui::Button("Scan")) {
            char b[160];
            snprintf(b, sizeof b, "feat ednear %.0f %s", radius, filter);
            send_cmd(b);
        }
        if (ImGui::BeginListBox("##near", ImVec2(-1, 110))) {
            std::vector<std::pair<int, std::string>> nearList;
            {
                std::lock_guard<std::recursive_mutex> lk(g_bridgeMx);
                nearList = g_edNear;
            }
            for (auto &e : nearList) {
                ImGui::PushID(e.first);
                if (ImGui::Selectable(e.second.c_str())) send_cmd("feat ednearsel " + std::to_string(e.first));
                ImGui::PopID();
            }
            ImGui::EndListBox();
        }
    }

    ImGui::SeparatorText("Edited objects");
    if (ImGui::BeginListBox("##placed", ImVec2(-1, 120))) {
        std::vector<std::pair<int, std::string>> list;
        {
            std::lock_guard<std::recursive_mutex> lk(g_bridgeMx);
            list = g_edList;
        }
        for (auto &e : list) {
            const char *base = strrchr(e.second.c_str(), '/');
            char label[200];
            snprintf(label, sizeof label, "#%d  %s", e.first, base ? base + 1 : e.second.c_str());
            if (ImGui::Selectable(label, e.first == sel)) send_cmd("feat edsel " + std::to_string(e.first));
        }
        ImGui::EndListBox();
    }

    ImGui::SeparatorText("Layout");
    ImGui::SetNextItemWidth(160);
    ImGui::InputText("##layout", g_layoutName, sizeof g_layoutName);
    ImGui::SameLine();
    if (ImGui::Button("Save")) send_cmd(std::string("feat edsave ") + g_layoutName);
    ImGui::SameLine();
    if (ImGui::Button("Load")) send_cmd(std::string("feat edload ") + g_layoutName);
    ImGui::SameLine();
    if (ImGui::Button("Clear all")) send_cmd("feat edclear");
    ImGui::TextDisabled("Every edit autosaves per level and comes back when the level loads.");
    if (ImGui::Button("Export standalone .pak")) send_cmd(std::string("feat edexport ") + g_layoutName);
    ImGui::SameLine();
    if (ImGui::Button("Open exports folder")) ShellExecuteA(nullptr, "open", exports_dir().c_str(), nullptr, nullptr, SW_SHOWNORMAL);
    ImGui::TextDisabled("Export = zzz_layout_<name>.pak: others drop it in GameSDK, no trainer needed.");
    ImGui::End();
}

// ---------------------------------------------------------------- D3D11 hooks
typedef HRESULT(STDMETHODCALLTYPE *Present_t)(IDXGISwapChain *, UINT, UINT);
typedef HRESULT(STDMETHODCALLTYPE *ResizeBuffers_t)(IDXGISwapChain *, UINT, UINT, UINT, DXGI_FORMAT, UINT);
static Present_t oPresent;
static ResizeBuffers_t oResizeBuffers;
static ID3D11Device *g_dev;
static ID3D11DeviceContext *g_ctx;
static ID3D11RenderTargetView *g_rtv;
static bool g_init;
static bool g_insertWas;

static void make_rtv(IDXGISwapChain *sc)
{
    ID3D11Texture2D *bb = nullptr;
    if (SUCCEEDED(sc->GetBuffer(0, __uuidof(ID3D11Texture2D), (void **)&bb)) && bb) {
        g_dev->CreateRenderTargetView(bb, nullptr, &g_rtv);
        bb->Release();
    }
}

static void present_overlay(IDXGISwapChain *sc)
{
    if (!g_init) {
        if (SUCCEEDED(sc->GetDevice(__uuidof(ID3D11Device), (void **)&g_dev))) {
            DXGI_SWAP_CHAIN_DESC d;
            sc->GetDesc(&d);
            g_hwnd = d.OutputWindow;
            g_dev->GetImmediateContext(&g_ctx);
            ImGui::CreateContext();
            ImGuiIO &io = ImGui::GetIO();
            io.IniFilename = "sgw3_trainer.ini";
            io.ConfigFlags |= ImGuiConfigFlags_NoMouseCursorChange;
            ImGui::StyleColorsDark();
            ImGui::GetStyle().WindowRounding = 6;
            ImGui_ImplWin32_Init(g_hwnd);
            ImGui_ImplDX11_Init(g_dev, g_ctx);
            make_rtv(sc);
            g_origWndProc = (WNDPROC)SetWindowLongPtrA(g_hwnd, GWLP_WNDPROC, (LONG_PTR)hkWndProc);
            console_add(COL_SYS, "[trainer] overlay ready - Insert toggles the menu");
            g_init = true;
        }
        if (!g_init) return;
    }

    bool fg = GetForegroundWindow() == g_hwnd;
    bool ins = fg && (GetAsyncKeyState(VK_INSERT) & 0x8000);
    if (ins && !g_insertWas) set_menu(!g_showMenu);
    g_insertWas = ins;
    pump_commands();

    {
        std::lock_guard<std::recursive_mutex> lk(g_imguiMx);
        ImGui::GetIO().MouseDrawCursor = g_menuOpen && !g_looking;
        ImGui_ImplDX11_NewFrame();
        ImGui_ImplWin32_NewFrame();
        ImGui::NewFrame();
        draw_overlay();
        if (g_editor) draw_editor();
        if (g_showMenu) draw_menu();
        ImGui::Render();
        if (!g_rtv) make_rtv(sc);
        g_ctx->OMSetRenderTargets(1, &g_rtv, nullptr);
        ImGui_ImplDX11_RenderDrawData(ImGui::GetDrawData());
    }
}

static HRESULT STDMETHODCALLTYPE hkPresent(IDXGISwapChain *sc, UINT sync, UINT flags)
{
    static bool failed = false;
    if (!failed) {
        try {
            present_overlay(sc);
        } catch (const std::exception &e) {
            failed = true;   // stop drawing rather than take the game down
            console_add(COL_ERR, std::string("[trainer] overlay disabled after error: ") + e.what());
        } catch (...) {
            failed = true;
        }
    }
    return oPresent(sc, sync, flags);
}

static HRESULT STDMETHODCALLTYPE hkResizeBuffers(IDXGISwapChain *sc, UINT n, UINT w, UINT h, DXGI_FORMAT f, UINT fl)
{
    if (g_rtv) { g_rtv->Release(); g_rtv = nullptr; }
    return oResizeBuffers(sc, n, w, h, f, fl);
}

// swap chain vtable from a throwaway device on a hidden window
static bool get_swapchain_vtable(void **present, void **resize)
{
    WNDCLASSEXA wc = { sizeof wc, CS_CLASSDC, DefWindowProcA, 0, 0, GetModuleHandleA(nullptr), 0, 0, 0, 0, "sgw3_trainer_dummy", 0 };
    RegisterClassExA(&wc);
    HWND hw = CreateWindowA(wc.lpszClassName, "", WS_OVERLAPPEDWINDOW, 0, 0, 64, 64, 0, 0, wc.hInstance, 0);
    DXGI_SWAP_CHAIN_DESC sd = {};
    sd.BufferCount = 1;
    sd.BufferDesc.Format = DXGI_FORMAT_R8G8B8A8_UNORM;
    sd.BufferUsage = DXGI_USAGE_RENDER_TARGET_OUTPUT;
    sd.OutputWindow = hw;
    sd.SampleDesc.Count = 1;
    sd.Windowed = TRUE;
    IDXGISwapChain *sc = nullptr;
    ID3D11Device *dev = nullptr;
    ID3D11DeviceContext *ctx = nullptr;
    D3D_FEATURE_LEVEL fl;
    HRESULT hr = D3D11CreateDeviceAndSwapChain(nullptr, D3D_DRIVER_TYPE_HARDWARE, nullptr, 0, nullptr, 0,
                                               D3D11_SDK_VERSION, &sd, &sc, &dev, &fl, &ctx);
    bool ok = SUCCEEDED(hr) && sc;
    if (ok) {
        void **vt = *(void ***)sc;
        *present = vt[8];
        *resize = vt[13];
    }
    if (sc) sc->Release();
    if (ctx) ctx->Release();
    if (dev) dev->Release();
    DestroyWindow(hw);
    UnregisterClassA(wc.lpszClassName, wc.hInstance);
    return ok;
}

static DWORD WINAPI init_thread(LPVOID)
{
    CloseHandle(CreateThread(nullptr, 0, pipe_thread, nullptr, 0, nullptr));
    while (!GetModuleHandleA("CryRenderD3D11.dll")) Sleep(250);   // wait until the game picked its renderer
    Sleep(2000);
    void *present = nullptr, *resize = nullptr;
    if (!get_swapchain_vtable(&present, &resize)) { console_add(COL_ERR, "[trainer] could not create dummy D3D11 device"); return 0; }
    MH_Initialize();
    MH_CreateHook(present, (void *)hkPresent, (void **)&oPresent);
    MH_CreateHook(resize, (void *)hkResizeBuffers, (void **)&oResizeBuffers);
    MH_CreateHook((void *)&SetCursorPos, (void *)hkSetCursorPos, (void **)&oSetCursorPos);
    MH_CreateHook((void *)&ClipCursor, (void *)hkClipCursor, (void **)&oClipCursor);
    hook_dinput();
    MH_EnableHook(MH_ALL_HOOKS);
    return 0;
}

BOOL WINAPI DllMain(HINSTANCE inst, DWORD reason, LPVOID)
{
    if (reason == DLL_PROCESS_ATTACH) {
        DisableThreadLibraryCalls(inst);
        CloseHandle(CreateThread(nullptr, 0, init_thread, nullptr, 0, nullptr));
    }
    return TRUE;
}
