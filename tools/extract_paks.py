"""Extract SGW3 .pak archives (plain ZIPs) for reading, applying patch paks (Name.p1.pak ... Name.pN.pak) in order.

Usage: python tools/extract_paks.py "<game folder>" <output folder> [GameSDK/Scripts GameSDK/GameData Engine/Engine ...]

CryEngine writes '\\' in local headers but '/' in the central directory, which Python's zipfile rejects; the local
name is read directly to work around it. The output is the game's own data: keep it out of this repository.
"""
import glob
import os
import re
import sys
import zipfile


def patchnum(p):
    return int(re.search(r"\.p(\d+)\.pak$", p).group(1))


def main():
    if len(sys.argv) < 3:
        sys.exit(__doc__)
    game, out_root = sys.argv[1], sys.argv[2]
    bases = sys.argv[3:] or ["GameSDK/Scripts", "GameSDK/GameData", "Engine/Engine"]
    for base in bases:
        paks = [os.path.join(game, base + ".pak")] + sorted(glob.glob(os.path.join(game, base + ".p*.pak")), key=patchnum)
        out = os.path.join(out_root, os.path.basename(base))
        for p in paks:
            with zipfile.ZipFile(p) as z:
                bad = 0
                for i in z.infolist():
                    if i.is_dir():
                        continue
                    dst = os.path.join(out, i.filename.replace("\\", "/"))
                    os.makedirs(os.path.dirname(dst), exist_ok=True)
                    try:
                        z.fp.seek(i.header_offset + 26)
                        n = int.from_bytes(z.fp.read(2), "little")
                        z.fp.seek(i.header_offset + 30)
                        i.orig_filename = z.fp.read(n).decode("cp437")
                        data = z.read(i)
                    except Exception:
                        bad += 1
                        continue
                    open(dst, "wb").write(data)
                print(os.path.basename(p), len(z.infolist()), "entries", bad, "failed")


if __name__ == "__main__":
    main()
