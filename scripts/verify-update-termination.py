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
import uuid


def main():
    binary = Path(sys.argv[1]).resolve(strict=True)
    with tempfile.TemporaryDirectory(prefix="motionpaper-termination-") as temporary:
        root = Path(temporary)
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
        try:
            subprocess.run(
                [str(executable), "--verify-update-termination"],
                env=environment,
                check=True,
                timeout=10,
            )
        except subprocess.TimeoutExpired as error:
            raise RuntimeError("Update termination stalled in the AppKit event loop") from error
        result = json.loads((root / "verification.json").read_text())
        if result.get("phase") != "terminated" or result.get("shutdownState") != "disabled":
            raise RuntimeError(f"App did not complete shutdown: {result}")
        print("Update task completed AppKit termination and shutdown cleanup.")


if __name__ == "__main__":
    main()
