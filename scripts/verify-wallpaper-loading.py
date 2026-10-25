#!/usr/bin/env python3
"""Verify the final executable starts safely without the private framework or its ABI."""

import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile


WALLPAPER = "/System/Library/PrivateFrameworks/Wallpaper.framework/Versions/A/Wallpaper"


def run(*arguments):
    subprocess.run(arguments, check=True, capture_output=True, text=True, timeout=30)


def expect_unavailable(executable, environment):
    result = subprocess.run(
        [str(executable), "--verify-compatibility"], env=environment,
        capture_output=True, text=True, timeout=15,
    )
    if result.returncode != 1:
        raise RuntimeError(f"Expected a handled compatibility error: {result.returncode}\n{result.stdout}\n{result.stderr}")
    report = json.loads(result.stdout)
    if report["interfaceAvailable"] or report["playbackVerified"] or not report.get("error"):
        raise RuntimeError(f"Invalid compatibility failure: {report}")
    return report["error"]


def main():
    executable = Path(sys.argv[1]).resolve(strict=True)
    with tempfile.TemporaryDirectory(prefix="motionpaper-wallpaper-loading-") as temporary:
        directory = Path(temporary)
        unavailable = directory / "Motionpaper"
        shutil.copy2(executable, unavailable)
        run("xcrun", "install_name_tool", "-change", WALLPAPER,
            str(directory / "Absent.framework/Absent"), str(unavailable))
        run("/usr/bin/codesign", "--force", "--sign", "-", str(unavailable))
        environment = dict(os.environ)
        environment.pop("DYLD_FRAMEWORK_PATH", None)
        missing_framework = expect_unavailable(unavailable, environment)

        framework = directory / "Wallpaper.framework/Versions/A/Wallpaper"
        framework.parent.mkdir(parents=True)
        source = directory / "EmptyWallpaper.c"
        source.write_text("int motionpaper_wallpaper_fixture = 0;\n")
        run("xcrun", "clang", "-dynamiclib", str(source), "-install_name", WALLPAPER,
            "-o", str(framework))
        environment["DYLD_FRAMEWORK_PATH"] = str(directory)
        missing_symbols = expect_unavailable(executable, environment)
        if missing_symbols == missing_framework:
            raise RuntimeError("The empty framework did not reach ABI symbol validation")
    print("Missing Wallpaper.framework and missing ABI symbols both produce handled errors.")


if __name__ == "__main__":
    main()
