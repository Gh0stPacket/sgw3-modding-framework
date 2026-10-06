"""Assemble release zips from build outputs (after tools/build.py and the CMake build).

Usage: python tools/package.py <version> [--config Release]
Writes build/dist/SGW3-Mod-Framework-<version>.zip and build/dist/SGW3-Mods-<version>.zip, laid out like the
game folder (win_x64/, GameSDK/) so players can extract them straight into the game directory.
"""
import argparse
import os
import zipfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
B = os.path.join(ROOT, "build")


def add(z, src, dst):
    if not os.path.exists(src):
        raise SystemExit("missing build output: " + os.path.relpath(src, ROOT))
    z.write(src, dst)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("version")
    ap.add_argument("--config", default="Release")
    a = ap.parse_args()
    bin_dir = os.path.join(B, a.config)
    dist = os.path.join(B, "dist")
    os.makedirs(dist, exist_ok=True)

    fw = os.path.join(dist, "SGW3-Mod-Framework-%s.zip" % a.version)
    with zipfile.ZipFile(fw, "w", zipfile.ZIP_DEFLATED) as z:
        add(z, os.path.join(bin_dir, "sgw3_modloader.asi"), "win_x64/sgw3_modloader.asi")
        add(z, os.path.join(ROOT, "docs", "MODDING_GUIDE.md"), "SGW3-Mod-Framework/MODDING_GUIDE.md")
        add(z, os.path.join(ROOT, "docs", "INSTALL.md"), "SGW3-Mod-Framework/INSTALL.md")
        add(z, os.path.join(ROOT, "LICENSE"), "SGW3-Mod-Framework/LICENSE")
        add(z, os.path.join(B, "paks", "zzz_hello_world.pak"), "SGW3-Mod-Framework/examples/zzz_hello_world.pak")
        add(z, os.path.join(ROOT, "framework", "examples", "hello_world", "Scripts", "AutoLoad", "hello_world", "init.lua"),
            "SGW3-Mod-Framework/examples/hello_world/Scripts/AutoLoad/hello_world/init.lua")
    print("wrote", os.path.relpath(fw, ROOT))

    mods = os.path.join(dist, "SGW3-Mods-%s.zip" % a.version)
    with zipfile.ZipFile(mods, "w", zipfile.ZIP_DEFLATED) as z:
        add(z, os.path.join(bin_dir, "sgw3_trainer.asi"), "win_x64/sgw3_trainer.asi")
        add(z, os.path.join(ROOT, "mods", "trainer", "native", "sgw3_models.txt"), "win_x64/sgw3_models.txt")
        add(z, os.path.join(B, "paks", "zzz_sgw3_bhop.pak"), "GameSDK/zzz_sgw3_bhop.pak")
        add(z, os.path.join(B, "paks", "zzz_sgw3_trainer.pak"), "GameSDK/zzz_sgw3_trainer.pak")
        add(z, os.path.join(ROOT, "docs", "MODS.md"), "SGW3-Mods/README.md")
        add(z, os.path.join(ROOT, "LICENSE"), "SGW3-Mods/LICENSE")
    print("wrote", os.path.relpath(mods, ROOT))


if __name__ == "__main__":
    main()
