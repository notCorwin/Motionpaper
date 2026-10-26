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


def verify_termination(binary, root, quit_sender=None, with_alert=False):
    contents = root / "Motionpaper.app" / "Contents"
    executable = contents / "MacOS" / "Motionpaper"
    executable.parent.mkdir(parents=True)
    shutil.copy2(binary, executable)
    resources = contents / "Resources"
    resources.mkdir()
    shutil.copy2(Path(__file__).resolve().parents[1] / "assets" / "AppIcon.png", resources / "StatusIcon.png")
    with (contents / "Info.plist").open("wb") as stream:
        plistlib.dump(
            {
                "CFBundleIdentifier": f"local.motionpaper.termination-test.{uuid.uuid4().hex}",
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
    if with_alert:
        arguments.append("--verify-alert-termination")
    process = subprocess.Popen(arguments, env=environment, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    report = root / "verification.json"
    try:
        if quit_sender:
            deadline = time.monotonic() + 5
            while not report.exists():
                if process.poll() is not None or time.monotonic() >= deadline:
                    raise RuntimeError("App did not become ready for external termination")
                time.sleep(0.01)
            if with_alert and json.loads(report.read_text()).get("alertVisible") is not True:
                raise RuntimeError("The external quit test did not show an update alert")
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
    finally:
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
        verify_termination(binary, root / "external-alert", quit_sender, with_alert=True)
    print("Update task completed AppKit termination and shutdown cleanup.")
    print("External quit completed successfully without reporting user cancellation.")
    print("External quit dismissed a pending update alert and completed shutdown.")


if __name__ == "__main__":
    main()
