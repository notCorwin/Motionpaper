#!/usr/bin/env python3
"""Exercise the app's real AppKit termination loop without enabling wallpaper playback."""

import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
import tempfile
import time
import uuid


def verify_termination(binary, root, quit_sender=None, menu_only=False):
    contents = root / "Motionpaper.app" / "Contents"
    executable = contents / "MacOS" / "Motionpaper"
    executable.parent.mkdir(parents=True)
    shutil.copy2(binary, executable)
    resources = contents / "Resources"
    resources.mkdir()
    shutil.copy2(Path(__file__).resolve().parents[1] / "assets" / "AppIcon.png", resources / "StatusIcon.png")
    bundle_identifier = f"local.motionpaper.termination-test.{uuid.uuid4().hex}"
    with (contents / "Info.plist").open("wb") as stream:
        plistlib.dump(
            {
                "CFBundleIdentifier": bundle_identifier,
                "CFBundleExecutable": "Motionpaper",
                "CFBundlePackageType": "APPL",
                "LSUIElement": True,
                "MotionpaperCommit": "a" * 40,
                "MotionpaperUpdateURL": "http://127.0.0.1:9/update.json",
            },
            stream,
        )
    environment = dict(os.environ, MOTIONPAPER_VERIFICATION_DIRECTORY=str(root))
    arguments = [str(executable), "--verify-update-termination"]
    if quit_sender:
        arguments.append("--verify-external-termination")
    if menu_only:
        arguments.append("--verify-menu-only")
    report = root / "verification.json"
    process = None
    try:
        process = subprocess.Popen(arguments, env=environment, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        if quit_sender:
            deadline = time.monotonic() + 10
            while not report.exists():
                if process.poll() is not None or time.monotonic() >= deadline:
                    process.kill()
                    stdout, stderr = process.communicate()
                    raise RuntimeError(f"App did not become ready for external termination: {stdout}\n{stderr}")
                time.sleep(0.01)
            ready = json.loads(report.read_text())
            if menu_only:
                if ready.get("menuOnlyVerified") is not True:
                    raise RuntimeError(f"The menu-only update behavior was not verified: {ready}")
                if ready.get("updateMenuTitle") != "检查更新失败，重试" or not ready.get("updateMenuToolTip"):
                    raise RuntimeError(f"The failed update check did not expose its menu retry state: {ready}")
                if ready.get("visibleTitledWindows") != 0:
                    raise RuntimeError(f"Menu-only verification opened a titled window: {ready}")
            subprocess.run([str(quit_sender), str(process.pid)], check=True, timeout=10)
        try:
            stdout, stderr = process.communicate(timeout=10)
        except subprocess.TimeoutExpired as error:
            raise RuntimeError("Termination stalled in the AppKit event loop") from error
        if process.returncode != 0:
            raise RuntimeError(f"App exited {process.returncode}: {stdout}\n{stderr}")
        result = json.loads(report.read_text())
        if (result.get("phase") != "terminated" or result.get("shutdownState") != "disabled"
                or result.get("pid") != process.pid):
            raise RuntimeError(f"App did not complete shutdown: {result}")
        if menu_only:
            if result.get("menuOnlyVerified") is not True:
                raise RuntimeError(f"The menu-only update behavior was not verified: {result}")
            if (result.get("updateMenuTitle") != "检查更新失败，重试" or not result.get("updateMenuToolTip")
                    or result.get("visibleTitledWindows") != 0):
                raise RuntimeError(f"The menu-only failure state or window check was not preserved: {result}")
    finally:
        if process:
            if process.poll() is None:
                process.kill()
            process.communicate()


def main():
    binary = Path(sys.argv[1]).resolve(strict=True)
    with tempfile.TemporaryDirectory(prefix="motionpaper-termination-") as temporary:
        root = Path(temporary)
        quit_sender = root / "QuitApplication"
        fixture = Path(__file__).parent / "fixtures" / "QuitApplication.swift"
        subprocess.run(["xcrun", "swiftc", "-swift-version", "6", str(fixture), "-o", str(quit_sender)],
                       check=True, timeout=30)
        verify_termination(binary, root / "internal")
        verify_termination(binary, root / "external", quit_sender)
        verify_termination(binary, root / "external-menu-only", quit_sender, menu_only=True)
    print("Update task completed AppKit termination and shutdown cleanup.")
    print("External quit completed successfully without reporting user cancellation.")
    print("Menu-only update failure was shown without a titled window; external quit completed successfully.")


if __name__ == "__main__":
    main()
