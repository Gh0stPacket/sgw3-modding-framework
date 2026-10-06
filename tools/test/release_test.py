"""Automated in-game release test for the SGW3 Modding Framework.

Installs the release zips (plus the dev test-harness pak) into the game, restarts the game into your last save,
runs tools/test/ingame_tests.lua inside the game, drives keyboard input for the bhop and overlay checks, checks
the framework logs, and writes build/test-report/report.md (+ a screenshot of the overlay).

Requirements:
  * a build: python tools/build.py --dev && cmake --build build --config Release && python tools/package.py <ver>
  * the universal-modder plugin (https://github.com/rehan-remade/universal-modder) for game input and window
    capture: pass --um <its folder> or set UM_ROOT
  * a campaign save; the test continues it ("Campaign: Continue") and doesn't change your saves

Usage:
  python tools/test/release_test.py --game "D:/GOG Galaxy/Games/Sniper Ghost Warrior 3" --version 1.0.0 --um <path>

If the game is running, the script waits until there has been no keyboard/mouse input for 15 s before closing it.
"""
import argparse
import os
import subprocess
import sys
import time
import zipfile

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
SAVED = os.path.join(os.environ["USERPROFILE"], "Saved Games", "Sniper Ghost Warrior 3")
OUR_PAKS = ["zzz_sgw3_bhop.pak", "zzz_sgw3_trainer.pak", "zzz_sgw3_dev.pak", "zzz_hello_world.pak",
            "zzzz_sgw3_framework_fallback.pak", "zzz_bhop.pak", "zzz_bhop_dev.pak", "zzzzz_othermod_test.pak"]
OUR_BINS = ["sgw3_modloader.asi", "sgw3_trainer.asi", "sgw3_models.txt", "bhop_input.asi"]


class Report:
    def __init__(self):
        self.rows = []

    def add(self, ok, name, detail=""):
        self.rows.append((bool(ok), name, str(detail)))
        print(("PASS " if ok else "FAIL ") + name + ("  " + str(detail) if detail else ""), flush=True)

    @property
    def ok(self):
        return all(r[0] for r in self.rows)


def game_pid():
    out = subprocess.run(["powershell", "-NoProfile", "-Command", "(Get-Process SGW3 -ErrorAction SilentlyContinue).Id"],
                         capture_output=True, text=True).stdout.strip()
    return int(out.split()[0]) if out else None


def read(path):
    try:
        return open(path, encoding="utf-8", errors="replace").read()
    except OSError:
        return ""


def wait_for(pred, timeout, step=2.0):
    t0 = time.time()
    while time.time() - t0 < timeout:
        if pred():
            return True
        time.sleep(step)
    return pred()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--game", required=True)
    ap.add_argument("--version", required=True)
    ap.add_argument("--um", default=os.environ.get("UM_ROOT"))
    ap.add_argument("--max-wait", type=int, default=900, help="seconds to wait for the user to go idle")
    a = ap.parse_args()
    if not a.um:
        sys.exit("need --um <universal-modder folder> (or UM_ROOT)")
    sys.path.insert(0, a.um)
    from um.win import Drive, shot  # noqa: E402

    dist = os.path.join(ROOT, "build", "dist")
    zips = [os.path.join(dist, "SGW3-Mod-Framework-%s.zip" % a.version), os.path.join(dist, "SGW3-Mods-%s.zip" % a.version)]
    dev_pak = os.path.join(ROOT, "build", "paks", "zzz_sgw3_dev.pak")
    for z in zips + [dev_pak]:
        if not os.path.exists(z):
            sys.exit("missing %s - build first (see --help)" % os.path.relpath(z, ROOT))
    out_dir = os.path.join(ROOT, "build", "test-report")
    dev_dir = os.path.join(out_dir, "devdir")
    os.makedirs(dev_dir, exist_ok=True)
    rep = Report()

    # 1. close the game once the user has been idle 15 s
    pid = game_pid()
    if pid:
        t0 = time.time()
        while True:
            idle = float(Drive("SGW3").cmd("idle").split("->")[-1])
            if idle >= 15:
                break
            if time.time() - t0 > a.max_wait:
                sys.exit("user still active - not restarting the game")
            time.sleep(3)
        print("user idle %.0f s - closing the game" % idle)
        subprocess.run(["taskkill", "/PID", str(pid), "/F"], capture_output=True)
        time.sleep(5)

    # 2. clean install: remove our previous files, extract the release zips (game-folder parts only), add the harness
    for n in OUR_PAKS:
        p = os.path.join(a.game, "GameSDK", n)
        if os.path.exists(p):
            os.remove(p)
    for n in OUR_BINS:
        p = os.path.join(a.game, "win_x64", n)
        if os.path.exists(p):
            os.remove(p)
    installed = []
    for z in zips:
        with zipfile.ZipFile(z) as zf:
            for i in zf.infolist():
                if i.filename.startswith(("win_x64/", "GameSDK/")) and not i.is_dir():
                    zf.extract(i, a.game)
                    installed.append(i.filename)
    with open(os.path.join(a.game, "GameSDK", "zzz_sgw3_dev.pak"), "wb") as f:
        f.write(open(dev_pak, "rb").read())
    rep.add(os.path.exists(os.path.join(a.game, "win_x64", "dinput8.dll")), "install.asi_loader_present")
    rep.add(True, "install.release_files", ", ".join(installed))

    # 3. launch with the harness enabled and continue the campaign
    for n in ("log.txt", "test_results.txt"):
        p = os.path.join(dev_dir, n)
        if os.path.exists(p):
            os.remove(p)
    env = dict(os.environ, SGW3_DEV_DIR=dev_dir, SGW3_DEV_SRC=ROOT)
    subprocess.Popen([os.path.join(a.game, "win_x64", "SGW3.exe")], cwd=os.path.join(a.game, "win_x64"), env=env)
    log = os.path.join(dev_dir, "log.txt")
    rep.add(wait_for(lambda: "dev tools loaded" in read(log), 90), "launch.framework_started")
    time.sleep(38)                                    # intro videos -> title screen
    d = Drive("SGW3")
    d.focus(); d.key("0x20")                          # press to start
    time.sleep(32)                                    # title -> main menu
    d.focus(); d.key("0x20")                          # Campaign: Continue
    rep.add(wait_for(lambda: "level load" in read(log), 420, 3), "launch.level_loaded")
    time.sleep(60)                                    # let the level finish streaming

    # 4. in-game test suite
    res_path = os.path.join(dev_dir, "test_results.txt")
    with open(os.path.join(dev_dir, "exec.lua"), "w", encoding="utf-8") as f:
        f.write(open(os.path.join(ROOT, "tools", "test", "ingame_tests.lua"), encoding="utf-8").read())
    done = wait_for(lambda: "DONE" in read(res_path), 90)
    for line in read(res_path).splitlines():
        if line.startswith(("PASS ", "FAIL ")):
            status, _, rest = line.partition(" ")
            name, _, detail = rest.partition(" ")
            rep.add(status == "PASS", "lua." + name, detail)
    rep.add(done, "lua.suite_completed")

    # 5. input tests: bhop (W + Space) and the overlay (Insert)
    before = read(log).count("hop speed")
    d.focus(); d.cmd("scanmode on")
    d.key("0x57", "down"); time.sleep(0.8)
    d.key("0x20", "down"); time.sleep(3.5)
    d.key("0x20", "up"); d.key("0x57", "up")
    time.sleep(1.5)
    hops = read(log).count("hop speed") - before
    rep.add(hops >= 2, "input.bhop_hops", "%d hops" % hops)

    d.focus(); d.key("0x2D")                          # Insert: open the trainer
    time.sleep(2)
    png = os.path.join(out_dir, "overlay.png")
    try:
        shot(png, exe="SGW3.exe", scale=0.5)
        rep.add(os.path.exists(png), "input.overlay_screenshot", os.path.relpath(png, ROOT))
    except BaseException as e:  # um's die() raises SystemExit
        rep.add(False, "input.overlay_screenshot", e)
    with open(os.path.join(dev_dir, "exec.lua"), "w") as f:
        f.write('local f = io.open(os.getenv("SGW3_DEV_DIR") .. "/menu_state.txt", "w"); '
                'f:write(tostring(TRAINER.feat.menu) .. " " .. tostring(TRAINER.pipe ~= nil)); f:close()\n')
    menu_path = os.path.join(dev_dir, "menu_state.txt")
    wait_for(lambda: os.path.exists(menu_path), 15, 1)
    rep.add(read(menu_path).strip() == "true true", "input.overlay_opens_and_bridge_connected", read(menu_path).strip())
    d.focus(); d.key("0x2D")                          # close it again

    # 6. logs
    ml = read(os.path.join(SAVED, "sgw3_modloader.log"))
    rep.add("hooked lua_load" in ml, "log.modloader_hooked")
    rep.add("framework injected" in ml and "run status 0" in ml, "log.framework_injected")
    fl = read(os.path.join(SAVED, "sgw3_mods.log"))
    errors = [ln for ln in fl.splitlines() if "error in" in ln or "FAILED" in ln]
    rep.add(not errors, "log.no_mod_errors", "; ".join(errors[:3]))

    # report
    os.makedirs(out_dir, exist_ok=True)
    with open(os.path.join(out_dir, "report.md"), "w", encoding="utf-8") as f:
        f.write("# Release test %s  -  %s\n\n" % (a.version, "PASSED" if rep.ok else "FAILED"))
        f.write("%s, game %s\n\n| | Check | Detail |\n|---|---|---|\n" % (time.strftime("%Y-%m-%d %H:%M"), a.game))
        for ok, name, detail in rep.rows:
            f.write("| %s | %s | %s |\n" % ("PASS" if ok else "**FAIL**", name, detail.replace("|", "/")))
        if os.path.exists(png):
            f.write("\n![overlay](overlay_small.png)\n")
    print("\n%s - report: %s" % ("PASSED" if rep.ok else "FAILED", os.path.relpath(os.path.join(out_dir, "report.md"), ROOT)))
    sys.exit(0 if rep.ok else 1)


if __name__ == "__main__":
    main()
