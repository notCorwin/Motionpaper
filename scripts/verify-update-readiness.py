#!/usr/bin/env python3
"""Verify update launch is confirmed only after wallpaper playback is ready."""

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


WALLPAPER = "/System/Library/PrivateFrameworks/Wallpaper.framework/Versions/A/Wallpaper"
COMMIT = "b" * 40
PREVIOUS_COMMIT = "a" * 40
ACQUIRE_DELAY_SECONDS = 2


def run(*arguments):
    subprocess.run(arguments, check=True, capture_output=True, text=True, timeout=30)


def compile_fixture(directory):
    framework = directory / "Wallpaper.framework/Versions/A/Wallpaper"
    framework.parent.mkdir(parents=True)
    fixture = Path(__file__).parent / "fixtures/WallpaperAssertion.swift"
    run(
        "xcrun", "swiftc", "-swift-version", "6", "-parse-as-library", "-emit-library",
        "-module-name", "Wallpaper", str(fixture), "-Xlinker", "-install_name",
        "-Xlinker", WALLPAPER, "-o", str(framework),
    )
    return directory


def make_application(root, binary, scenario):
    application = root / f"Motionpaper-{scenario}.app"
    contents = application / "Contents"
    executable = contents / "MacOS/Motionpaper"
    executable.parent.mkdir(parents=True)
    shutil.copy2(binary, executable)
    resources = contents / "Resources"
    resources.mkdir()
    shutil.copy2(Path(__file__).resolve().parents[1] / "assets/AppIcon.png",
                 resources / "StatusIcon.png")
    with (contents / "Info.plist").open("wb") as stream:
        plistlib.dump(
            {
                "CFBundleIdentifier": f"local.motionpaper.update-readiness.{uuid.uuid4().hex}",
                "CFBundleExecutable": "Motionpaper",
                "CFBundleName": "Motionpaper",
                "CFBundlePackageType": "APPL",
                "LSUIElement": True,
                "MotionpaperCommit": COMMIT,
                "MotionpaperUpdateURL": "http://127.0.0.1:9/update.json",
            },
            stream,
        )
    return application.absolute(), executable.absolute()


def make_transaction(root, application):
    directory = root / f".motionpaper-update-{uuid.uuid4()}"
    directory.mkdir()
    canonical_directory = directory.absolute()
    canonical_application = application.absolute()
    if canonical_directory.parent != canonical_application.parent:
        raise RuntimeError("Prepared update directory and destination must share a parent")

    def directory_file_url(path):
        url = path.as_uri()
        return url if url.endswith("/") else url + "/"

    plan = {
        "directory": directory_file_url(canonical_directory),
        "destination": directory_file_url(canonical_application),
        "commit": COMMIT,
        "previousCommit": PREVIOUS_COMMIT,
    }
    (canonical_directory / "update.json").write_text(json.dumps(plan), encoding="utf-8")
    # Preparation creates this lease file; the readiness check never invokes the updater.
    (canonical_directory / "lock").touch()
    return canonical_directory


def launch_case(root, binary, fixture_directory, scenario, should_fail, retry=False):
    application, executable = make_application(root, binary, scenario)
    transaction = make_transaction(root, application)
    verification_directory = root / f"verification-{scenario}"
    log = root / f"assertions-{scenario}.log"
    environment = dict(os.environ)
    environment.pop("MOTIONPAPER_ASSERTION_ACQUIRE_FAIL", None)
    environment.pop("MOTIONPAPER_ASSERTION_ACQUIRE_FAIL_ONCE", None)
    environment.update(
        DYLD_FRAMEWORK_PATH=str(fixture_directory),
        MOTIONPAPER_ASSERTION_ACQUIRE_DELAY_SECONDS=str(ACQUIRE_DELAY_SECONDS),
        MOTIONPAPER_ASSERTION_RELEASE_LOG=str(log),
        MOTIONPAPER_VERIFICATION_DIRECTORY=str(verification_directory),
    )
    if should_fail:
        environment["MOTIONPAPER_ASSERTION_ACQUIRE_FAIL"] = "1"
    if retry:
        environment["MOTIONPAPER_ASSERTION_ACQUIRE_FAIL_ONCE"] = "1"

    process_started_monotonic = time.clock_gettime(time.CLOCK_MONOTONIC)
    arguments = [
        str(executable), "--verify-update-launch", "--complete-update", str(transaction), COMMIT,
    ]
    if retry:
        arguments.append("--verify-playback-retry")
    process = subprocess.Popen(arguments, env=environment, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                               text=True)
    try:
        stdout, stderr = process.communicate(timeout=20)
    except subprocess.TimeoutExpired as error:
        process.kill()
        stdout, stderr = process.communicate()
        raise RuntimeError(f"{scenario} app did not terminate within 20 seconds\n{stdout}\n{stderr}") from error
    if process.returncode != 0:
        raise RuntimeError(f"{scenario} app exited {process.returncode}\n{stdout}\n{stderr}")

    report_path = verification_directory / "verification.json"
    if not report_path.is_file():
        raise RuntimeError(f"{scenario} app did not write {report_path}\n{stdout}\n{stderr}")
    report = json.loads(report_path.read_text(encoding="utf-8"))
    if report.get("phase") != "terminated" or report.get("pid") != process.pid:
        raise RuntimeError(f"Unexpected {scenario} termination report: {report}")
    if report.get("shutdownState") != "disabled":
        raise RuntimeError(f"{scenario} app did not shut down playback: {report}")

    events = [line.split() for line in log.read_text(encoding="utf-8").splitlines()] if log.exists() else []
    if should_fail:
        if not str(report.get("state", "")).startswith("failed("):
            raise RuntimeError(f"Delayed fixture failure was not reflected in the report: {report}")
        if [event[0] for event in events] != ["failed"]:
            raise RuntimeError(f"Expected only a failed acquisition event, got: {events}")
        if (transaction / "launched.json").exists():
            raise RuntimeError("Failed playback acquisition incorrectly confirmed the update launch")
        return report

    if report.get("state") != "enabled":
        raise RuntimeError(f"Delayed fixture success did not reach enabled playback: {report}")
    expected_events = ["failed", "acquired", "released"] if retry else ["acquired", "released"]
    if [event[0] for event in events] != expected_events:
        raise RuntimeError(f"Expected {expected_events}, got: {events}")
    acquired = events[1] if retry else events[0]
    acquired_monotonic = float(acquired[1])
    if acquired_monotonic - process_started_monotonic < ACQUIRE_DELAY_SECONDS - 0.5:
        raise RuntimeError(f"Fixture acquisition was not delayed as requested: {events[0]}")

    acquired_unix_ns = int(acquired[2])
    receipt_path = transaction / "launched.json"
    if not receipt_path.is_file():
        raise RuntimeError(
            "Playback became enabled but no update launch receipt was written: "
            f"report={report}; fixture={events}; stdout={stdout!r}; stderr={stderr!r}"
        )
    receipt = json.loads(receipt_path.read_text(encoding="utf-8"))
    if receipt.get("commit") != COMMIT or receipt.get("pid") != process.pid:
        raise RuntimeError(f"Incorrect update launch receipt: {receipt}; expected PID {process.pid}")
    receipt_mtime_ns = receipt_path.stat().st_mtime_ns
    if receipt_mtime_ns < acquired_unix_ns:
        raise RuntimeError(
            "Update launch receipt predates successful playback acquisition: "
            f"receipt={receipt_mtime_ns}, acquired={acquired_unix_ns}"
        )
    return report


def verify_channel_menus(root, binary, fixture_directory):
    for channel in ("autobuild", "stable"):
        application, executable = make_application(root, binary, f"menu-{channel}")
        information = application / "Contents/Info.plist"
        with information.open("rb") as stream:
            metadata = plistlib.load(stream)
        stable_url = "https://api.github.com/repos/notCorwin/Motionpaper/releases?per_page=100"
        metadata.update(
            CFBundleShortVersionString="1.0.0",
            MotionpaperReleaseChannel=channel,
            MotionpaperRepositoryURL="https://github.com/notCorwin/Motionpaper",
            MotionpaperUpdateURL=stable_url,
        )
        with information.open("wb") as stream:
            plistlib.dump(metadata, stream)
        output = root / f"menu-{channel}"
        environment = dict(os.environ, DYLD_FRAMEWORK_PATH=str(fixture_directory),
                           MOTIONPAPER_VERIFICATION_DIRECTORY=str(output))
        environment.pop("MOTIONPAPER_ASSERTION_ACQUIRE_FAIL", None)
        environment.pop("MOTIONPAPER_ASSERTION_ACQUIRE_DELAY_SECONDS", None)
        run_result = subprocess.run([str(executable), "--verify-ui"], env=environment,
                                    capture_output=True, text=True, timeout=20)
        if run_result.returncode != 0:
            raise RuntimeError(f"{channel} menu verification failed: {run_result.stderr}")
        report = json.loads((output / "verification.json").read_text())
        if (report.get("phase") != "terminated" or report.get("hasCheckedMenuItem")
                or not report.get("applicationMenuVerified") or not report.get("updateMenuVerified")):
            raise RuntimeError(f"Unexpected {channel} menu report: {report}")


def main():
    if len(sys.argv) != 2:
        raise SystemExit(f"Usage: {Path(sys.argv[0]).name} <debug-Motionpaper-binary>")
    binary = Path(sys.argv[1]).resolve(strict=True)
    with tempfile.TemporaryDirectory(prefix="motionpaper-update-readiness-") as temporary:
        root = Path(temporary).absolute()
        fixture_directory = compile_fixture(root / "fixture")
        success = launch_case(root, binary, fixture_directory, "success", should_fail=False)
        failure = launch_case(root, binary, fixture_directory, "failure", should_fail=True)
        launch_case(root, binary, fixture_directory, "retry", should_fail=False, retry=True)
        verify_channel_menus(root, binary, fixture_directory)
    print("Delayed successful playback wrote a matching update receipt only after acquisition.")
    print("Delayed failed playback exited cleanly without confirming the update launch.")
    print("Playback recovered through the retry menu after one failed native acquisition.")
    print("Autobuild and stable menus have working update actions and no login checkmarks.")
    print(f"Reports: success={success['phase']}/{success['state']}, failure={failure['phase']}/{failure['state']}")


if __name__ == "__main__":
    main()
