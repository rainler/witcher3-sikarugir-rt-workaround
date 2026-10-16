#!/usr/bin/env python3
"""Build/install or remove the Sikarugir RT startup workaround, with backups."""
import argparse
import datetime
import hashlib
import json
from pathlib import Path
import plistlib
import shlex
import shutil
import subprocess
import sys

PATCHED_EXE_SHA256 = "7b64e2c9207f341cc992f3db4a952d948f446554d3a005dd859316a2f70d38c9"
ORIGINAL_EXE_SHA256 = "2df765398a3d1f165db418271be7200178320a4466817379f2fa0dc0001fb101"
PACKAGE = Path(__file__).resolve().parent


def sha(data):
    return hashlib.sha256(data).hexdigest()


def check_closed(contents):
    rows = subprocess.check_output(["ps", "-axo", "pid=,comm="], text=True)
    for row in rows.splitlines():
        parts = row.strip().split(None, 1)
        if len(parts) != 2:
            continue
        pid, name = parts
        if not (name.lower().endswith("witcher3.exe") or name.lower().endswith("steam.exe")):
            continue
        loaded = subprocess.run(["lsof", "-p", pid, "-Fn"], capture_output=True, text=True).stdout
        if str(contents / "SharedSupport/prefix") in loaded:
            raise ValueError("Close Witcher 3 and Windows Steam in this wrapper first.")


def read_wrapper(wrapper):
    if sys.platform != "darwin":
        raise ValueError("This installer is for macOS Sikarugir wrappers.")
    contents = wrapper.expanduser().resolve() / "Contents"
    config = contents / "Info.plist"
    original = config.read_bytes()
    data = plistlib.loads(original)
    if not data.get("CFBundleIdentifier", "").startswith("com.sikarugir."):
        raise ValueError("Expected a Sikarugir wrapper; this package has not been adapted for CrossOver or Whisky.")
    if not isinstance(data.get("CLI Custom Commands"), str):
        raise ValueError("Wrapper has no supported CLI Custom Commands field.")
    return contents, config, original, data


def install(args):
    contents, config, original, data = read_wrapper(args.wrapper)
    check_closed(contents)
    settings = args.settings.expanduser().resolve()
    values = {line.strip() for line in settings.read_text().splitlines()}
    if "PTEnable=false" not in values or "PTEnable=true" in values:
        raise ValueError("Set Path Tracing OFF in the game, exit, then retry. Settings are never edited by this installer.")
    framework_info = contents / "Frameworks/renderer/d3dmetal/external/D3DMetal.framework/Versions/A/Resources/Info.plist"
    if not framework_info.exists():
        framework_info = contents / "Frameworks/renderer/d3dmetal/external/D3DMetal.framework/Versions/A/Info.plist"
    renderer = plistlib.loads(framework_info.read_bytes())
    renderer_version = renderer.get("CFBundleShortVersionString", "")
    if renderer_version != "4.0b2":
        raise ValueError(f"This preview targets D3DMetal 4.0b2; found {renderer_version!r}.")
    game = contents / "SharedSupport/prefix/drive_c/Program Files (x86)/Steam/steamapps/common/The Witcher 3"
    exe = args.game_exe.expanduser().resolve() if args.game_exe else game / "bin/x64/witcher3.exe"
    digest = sha(exe.read_bytes())
    if digest == ORIGINAL_EXE_SHA256:
        raise ValueError("This is the pristine tested executable. Apply the upstream RT-only toggle unlock first; see README.md.")
    if digest != PATCHED_EXE_SHA256:
        raise ValueError("Executable differs from the tested RT-unlocked build. No game or wrapper files changed.")
    if "DYLD_INSERT_LIBRARIES" in data["CLI Custom Commands"]:
        raise ValueError("This wrapper already sets DYLD_INSERT_LIBRARIES. This installer will not replace an existing injected library.")
    if not shutil.which("clang"):
        raise ValueError("Install Apple Command Line Tools with xcode-select --install, then retry.")
    print(f"Wrapper: {args.wrapper.expanduser().resolve()}")
    print(f"Settings: {settings}")
    print(f"Executable: {exe}")
    print(f"Renderer: {renderer_version}; RT-unlocked executable verified")
    if args.dry_run:
        print("Dry run passed. Nothing built, installed, or modified.")
        return
    stamp = datetime.datetime.now().strftime("%Y%m%d-%H%M%S-%f")
    base = contents / "SharedSupport/Witcher3RTPreview"
    install_dir = base / stamp
    install_dir.mkdir(parents=True, exist_ok=False)
    library = install_dir / "witcher3-rt-compat.dylib"
    backup = install_dir / "Info.plist.original"
    try:
        subprocess.run(["clang", "-arch", "x86_64", "-dynamiclib", "-fobjc-arc",
                        "-Wall", "-Wextra", "-Werror", "-O2", "-framework", "Foundation",
                        "-framework", "Metal", str(PACKAGE / "witcher3-rt-compat.m"),
                        "-o", str(library)], check=True)
        log = contents / "SharedSupport/Logs/Witcher3RTCompatPublic.log"
        log.parent.mkdir(parents=True, exist_ok=True)
        exports = {"DYLD_INSERT_LIBRARIES": str(library),
                   "W3_RT_COMPAT_SETTINGS_PATH": str(settings),
                   "W3_RT_COMPAT_LOG_PATH": str(log)}
        addition = "; " + "; ".join(f"export {key}={shlex.quote(value)}" for key, value in exports.items())
        old_commands = data["CLI Custom Commands"]
        data["CLI Custom Commands"] = old_commands.rstrip() + addition
        subprocess.run(["/bin/sh", "-n", "-c", data["CLI Custom Commands"] + "; true"], check=True)
        updated = plistlib.dumps(data, fmt=plistlib.FMT_XML, sort_keys=False)
        backup.write_bytes(original)
        record = {"active": True, "backup": str(backup), "library": str(library),
                  "library_sha256": sha(library.read_bytes()), "installed_config_sha256": sha(updated),
                  "old_commands": old_commands, "addition": addition}
        record_path = install_dir / "install.json"
        record_path.write_text(json.dumps(record, indent=2) + "\n")
        config.write_bytes(updated)
        (base / "current.json").write_text(json.dumps({"record": str(record_path)}, indent=2) + "\n")
    except Exception:
        config.write_bytes(original)
        raise
    print("Installed. Launch normally with Ray Tracing ON and Path Tracing OFF.")
    print(f"Backup: {backup}")
    print(f"Diagnostic log: {log}")
    print("Your executable, graphics settings and saves were not modified.")


def uninstall(args):
    contents, config, current, data = read_wrapper(args.wrapper)
    check_closed(contents)
    pointer = contents / "SharedSupport/Witcher3RTPreview/current.json"
    record_path = Path(json.loads(pointer.read_text())["record"])
    record = json.loads(record_path.read_text())
    if not record["active"]:
        print("This preview is already inactive.")
        return
    commands = data["CLI Custom Commands"]
    if not commands.endswith(record["addition"]):
        raise ValueError("The launch commands changed after installation. Automatic removal stopped to preserve them; see the recorded backup.")
    if args.dry_run:
        print("Uninstall dry run passed. No changes made.")
        return
    if sha(current) == record["installed_config_sha256"]:
        restored = Path(record["backup"]).read_bytes()
    else:
        remaining = commands[:-len(record["addition"])]
        data["CLI Custom Commands"] = record["old_commands"] if remaining == record["old_commands"].rstrip() else remaining
        restored = plistlib.dumps(data, fmt=plistlib.FMT_XML, sort_keys=False)
    config.write_bytes(restored)
    record["active"] = False
    record_path.write_text(json.dumps(record, indent=2) + "\n")
    print("Compatibility exports removed. Backups and the RT toggle unlock are preserved.")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=["install", "uninstall"])
    parser.add_argument("--wrapper", type=Path, default=Path.home() / "Applications/SteamWindows.app")
    parser.add_argument("--settings", type=Path, default=Path.home() / "Documents/The Witcher 3/dx12user.settings")
    parser.add_argument("--game-exe", type=Path, help="Actual launched RT-unlocked executable if it is outside bin/x64")
    parser.add_argument("--dry-run", action="store_true")
    args = parser.parse_args()
    try:
        (install if args.action == "install" else uninstall)(args)
    except (OSError, ValueError, subprocess.CalledProcessError) as error:
        print(f"Stopped: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
