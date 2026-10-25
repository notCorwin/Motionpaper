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
        [str(executable), "--verify-compatibility", "--verify-assertion-lifecycle"], env=environment,
        capture_output=True, text=True, timeout=15,
    )
    if result.returncode != 1:
        raise RuntimeError(f"Expected a handled compatibility error: {result.returncode}\n{result.stdout}\n{result.stderr}")
    report = json.loads(result.stdout)
    if (report.get("interfaceAvailable") is not False
            or report.get("assertionLifecycleVerified") is not False
            or not report.get("error")):
        raise RuntimeError(f"Invalid compatibility failure: {report}")
    return report["error"]


def expect_released_assertions(executable, directory, environment, objective_c_base):
    framework = directory / "Wallpaper.framework/Versions/A/Wallpaper"
    framework.parent.mkdir(parents=True)
    fixture = Path(__file__).parent / "fixtures/WallpaperAssertion.swift"
    arguments = ["xcrun", "swiftc", "-swift-version", "6", "-parse-as-library", "-emit-library",
                 "-module-name", "Wallpaper", str(fixture), "-Xlinker", "-install_name",
                 "-Xlinker", WALLPAPER, "-o", str(framework)]
    if objective_c_base:
        arguments.extend(["-D", "OBJECTIVE_C_BASE"])
    run(*arguments)
    log = directory / "assertions.log"
    environment = dict(environment, DYLD_FRAMEWORK_PATH=str(directory), MOTIONPAPER_ASSERTION_RELEASE_LOG=str(log))
    result = subprocess.run(
        [str(executable), "--verify-compatibility", "--verify-assertion-lifecycle"],
        env=environment, capture_output=True, text=True, timeout=30,
    )
    if result.returncode != 0:
        raise RuntimeError(f"Assertion ownership failed (NSObject={objective_c_base}): {result.returncode}\n{result.stdout}\n{result.stderr}")
    report = json.loads(result.stdout)
    if report.get("interfaceAvailable") is not True or report.get("assertionLifecycleVerified") is not True:
        raise RuntimeError(f"Assertion lifecycle was not verified: {report}")
    events = [line.split() for line in log.read_text().splitlines()] if log.exists() else []
    if [event[0] for event in events] != ["acquired", "released"] * 2:
        raise RuntimeError(f"Native assertions were not acquired and released exactly once: {log}")
    # The app holds each session for two seconds. Allow clock tolerance while
    # detecting early deallocation that would otherwise leave the outer session alive.
    if any(float(events[index + 1][1]) - float(events[index][1]) < 1.5 for index in (0, 2)):
        raise RuntimeError(f"A native assertion was released while the controller was enabled: {events}")


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
        expect_released_assertions(executable, directory / "swift", environment, objective_c_base=False)
        expect_released_assertions(executable, directory / "objc", environment, objective_c_base=True)
    print("Missing Wallpaper.framework and missing ABI symbols both produce handled errors.")
    print("Swift and NSObject assertions are each released exactly once before reacquisition.")


if __name__ == "__main__":
    main()
