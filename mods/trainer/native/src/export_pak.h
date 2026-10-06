// Layout export: packs an editor layout into zzz_layout_<name>.pak (a plain stored ZIP, which is what CryEngine
// paks are) as an SGW3 Mod Framework mod: one Scripts/AutoLoad/sgw3_layout_<name>/init.lua and no game files,
// so it coexists with any other mod and needs only the framework (sgw3_modloader.asi), not the trainer.
#pragma once
#include <stdint.h>
#include <string>
#include <vector>

static uint32_t crc32_of(const std::string &d)
{
    static uint32_t table[256];
    if (!table[1])
        for (uint32_t i = 0; i < 256; i++) {
            uint32_t c = i;
            for (int k = 0; k < 8; k++) c = c & 1 ? 0xEDB88320u ^ (c >> 1) : c >> 1;
            table[i] = c;
        }
    uint32_t c = 0xFFFFFFFFu;
    for (unsigned char b : d) c = table[(c ^ b) & 0xFF] ^ (c >> 8);
    return c ^ 0xFFFFFFFFu;
}

static void put16(std::string &o, uint16_t v) { o += (char)(v & 0xFF); o += (char)(v >> 8); }
static void put32(std::string &o, uint32_t v) { put16(o, (uint16_t)(v & 0xFFFF)); put16(o, (uint16_t)(v >> 16)); }

// entries are (path inside the pak, contents); method 0 (stored)
static std::string build_zip(const std::vector<std::pair<std::string, std::string>> &entries)
{
    std::string out, central;
    for (auto &e : entries) {
        uint32_t crc = crc32_of(e.second), size = (uint32_t)e.second.size(), offset = (uint32_t)out.size();
        put32(out, 0x04034b50); put16(out, 10); put16(out, 0); put16(out, 0); put16(out, 0); put16(out, 0x21);
        put32(out, crc); put32(out, size); put32(out, size); put16(out, (uint16_t)e.first.size()); put16(out, 0);
        out += e.first;
        out += e.second;
        put32(central, 0x02014b50); put16(central, 20); put16(central, 10); put16(central, 0); put16(central, 0);
        put16(central, 0); put16(central, 0x21); put32(central, crc); put32(central, size); put32(central, size);
        put16(central, (uint16_t)e.first.size()); put16(central, 0); put16(central, 0); put16(central, 0);
        put16(central, 0); put32(central, 0); put32(central, offset);
        central += e.first;
    }
    uint32_t cdOffset = (uint32_t)out.size();
    out += central;
    put32(out, 0x06054b50); put16(out, 0); put16(out, 0); put16(out, (uint16_t)entries.size());
    put16(out, (uint16_t)entries.size()); put32(out, (uint32_t)central.size()); put32(out, cdOffset); put16(out, 0);
    return out;
}

static bool read_file(const std::string &path, std::string &out)
{
    FILE *f = fopen(path.c_str(), "rb");
    if (!f) return false;
    char buf[8192];
    size_t n;
    while ((n = fread(buf, 1, sizeof buf, f)) > 0) out.append(buf, n);
    fclose(f);
    return true;
}

static bool write_file(const std::string &path, const std::string &data)
{
    FILE *f = fopen(path.c_str(), "wb");
    if (!f) return false;
    bool ok = fwrite(data.data(), 1, data.size(), f) == data.size();
    fclose(f);
    return ok;
}

static std::string exports_dir()
{
    char prof[MAX_PATH] = "";
    GetEnvironmentVariableA("USERPROFILE", prof, MAX_PATH);
    std::string dir = std::string(prof) + "\\Saved Games\\Sniper Ghost Warrior 3\\exports";
    CreateDirectoryA(dir.c_str(), nullptr);
    return dir;
}

// "name|path-to-layout-script" from the game -> exports\zzz_layout_<name>.pak (+ install readme)
static void export_layout_pak(const std::string &msg, std::string &result)
{
    size_t bar = msg.find('|');
    if (bar == std::string::npos) { result = "bad export message"; return; }
    std::string name = msg.substr(0, bar), src = msg.substr(bar + 1), layout;
    if (!read_file(src, layout)) { result = "cannot read " + src; return; }
    std::vector<std::pair<std::string, std::string>> entries = {
        { "Scripts/AutoLoad/sgw3_layout_" + name + "/init.lua", layout },
    };
    std::string dir = exports_dir(), pak = dir + "\\zzz_layout_" + name + ".pak";
    if (!write_file(pak, build_zip(entries))) { result = "cannot write " + pak; return; }
    write_file(dir + "\\zzz_layout_" + name + "_README.txt",
               "Sniper Ghost Warrior 3 map layout \"" + name + "\"\r\n\r\n"
               "Requires: SGW3 Mod Framework (Ultimate ASI Loader dinput8.dll + sgw3_modloader.asi in win_x64).\r\n"
               "Install: copy zzz_layout_" + name + ".pak into <game folder>\\GameSDK\\\r\n"
               "Then load the level it was made for; the objects appear automatically (also after deaths\r\n"
               "and checkpoints). It overrides no game files, so it works alongside other mods.\r\n"
               "Uninstall: delete the .pak.\r\n");
    result = pak;
}
