#!/usr/bin/env python3
"""Run and record the release app's compatibility checks on the current macOS host."""

import argparse
import hashlib
import json
from pathlib import Path
import plistlib
import re
import subprocess
import sys


APP_TIMEOUT_SECONDS = 60
HELPER_TIMEOUT_SECONDS = 10
PROBE_TIMEOUT_SECONDS = 10
ARCHITECTURES = ("arm64", "x86_64")
PRODUCT_VERSION_PATTERN = re.compile(r"(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)(?:\.(?:0|[1-9][0-9]*))?\Z")
BUILD_VERSION_PATTERN = re.compile(r"[0-9]{2}[A-Z][0-9]+[A-Z]?\Z")
VERIFICATION_SCOPE = "nativeAssertionLifecycleAndUpdaterLaunch"


def _output_text(value):
    if isinstance(value, bytes):
        return value.decode("utf-8", errors="replace")
    return value or ""


def run_process(arguments, timeout, process_runner=None):
    """Capture a process result without losing timeout or launch diagnostics."""
    if process_runner is None:
        process_runner = subprocess.run
    try:
        completed = process_runner(
            [str(argument) for argument in arguments],
            capture_output=True,
            text=True,
            timeout=timeout,
        )
        return {
            "exitCode": completed.returncode,
            "stdout": _output_text(completed.stdout),
            "stderr": _output_text(completed.stderr),
            "timedOut": False,
        }
    except subprocess.TimeoutExpired as error:
        return {
            "exitCode": None,
            "stdout": _output_text(error.stdout),
            "stderr": _output_text(error.stderr),
            "timedOut": True,
            "timeoutSeconds": timeout,
        }
    except Exception as error:
        return {
            "exitCode": None,
            "stdout": "",
            "stderr": "",
            "timedOut": False,
            "launchError": str(error),
        }


def _process_problem(label, result):
    if result.get("launchError"):
        return f"{label} could not start: {result['launchError']}"
    if result.get("timedOut"):
        return f"{label} timed out after {result['timeoutSeconds']} seconds"
    if result.get("exitCode") != 0:
        return f"{label} exited with code {result.get('exitCode')}"
    return None


def _read_plist_commit(info_plist):
    with info_plist.open("rb") as stream:
        info = plistlib.load(stream)
    if not isinstance(info, dict):
        raise ValueError("Info.plist root is not a dictionary")
    commit = info.get("MotionpaperCommit")
    if not isinstance(commit, str) or not commit:
        raise ValueError("Info.plist MotionpaperCommit is missing or is not a string")
    return commit


def _sha256(path):
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def _check(checks, errors, name, passed, message):
    checks[name] = passed is True
    if passed is not True:
        errors.append(message)


def _validate_native_report(report, expected_architecture, checks, errors):
    if not isinstance(report, dict):
        errors.append("app stdout must contain a JSON object")
        checks["nativeReportValid"] = False
        return

    checks["nativeReportValid"] = True
    architecture = report.get("architecture")
    _check(
        checks, errors, "nativeArchitectureMatches",
        isinstance(architecture, str) and architecture == expected_architecture,
        f"native report architecture must be {expected_architecture!r}, got {architecture!r}",
    )
    interface_available = report.get("interfaceAvailable")
    _check(
        checks, errors, "interfaceAvailable",
        interface_available is True,
        "native report interfaceAvailable must be true",
    )
    lifecycle_verified = report.get("assertionLifecycleVerified")
    _check(
        checks, errors, "assertionLifecycleVerified",
        lifecycle_verified is True,
        "native report assertionLifecycleVerified must be true",
    )
    system_version = report.get("systemVersion")
    _check(
        checks, errors, "nativeSystemVersionPresent",
        isinstance(system_version, str) and bool(system_version.strip()),
        "native report systemVersion must be a non-empty string",
    )
    if "playbackVerified" in report:
        errors.append("native report contains obsolete playbackVerified field")
        checks["obsoletePlaybackFieldAbsent"] = False
    else:
        checks["obsoletePlaybackFieldAbsent"] = True
    if report.get("error") is not None:
        errors.append(f"native report error must be absent or null on success, got {report['error']!r}")
        checks["nativeErrorAbsent"] = False
    else:
        checks["nativeErrorAbsent"] = True


def verify_compatibility(
    app_path,
    expected_commit,
    expected_major,
    expected_architecture,
    expected_product_version=None,
    expected_build_version=None,
    process_runner=None,
):
    """Return an auditable result document; status is passed only for the full contract."""
    app = Path(app_path).expanduser().resolve()
    executable = app / "Contents" / "MacOS" / "Motionpaper"
    updater = app / "Contents" / "Helpers" / "MotionpaperUpdater"
    errors = []
    checks = {}
    expected = {
        "commit": expected_commit,
        "major": str(expected_major),
        "architecture": expected_architecture,
    }
    if expected_product_version is not None:
        expected["productVersion"] = expected_product_version
    if expected_build_version is not None:
        expected["buildVersion"] = expected_build_version

    result = {
        "schemaVersion": 2,
        "scope": VERIFICATION_SCOPE,
        "desktopFramesObserved": False,
        "status": "failed",
        "expected": expected,
        "system": {
            "productVersion": None,
            "productVersionValid": False,
            "buildVersion": None,
            "buildVersionValid": False,
            "architecture": None,
            "probes": {},
        },
        "app": {
            "bundlePath": str(app),
            "executablePath": str(executable),
            "motionpaperCommit": None,
            "binarySha256": None,
            "exitCode": None,
            "stdout": "",
            "stderr": "",
            "nativeReport": None,
        },
        "updater": {
            "executablePath": str(updater),
            "arguments": [],
            "exitCode": None,
            "binarySha256": None,
            "stdout": "",
            "stderr": "",
        },
        "checks": checks,
        "errors": errors,
    }

    product_probe = run_process(("sw_vers", "-productVersion"), PROBE_TIMEOUT_SECONDS, process_runner)
    build_probe = run_process(("sw_vers", "-buildVersion"), PROBE_TIMEOUT_SECONDS, process_runner)
    architecture_probe = run_process(("uname", "-m"), PROBE_TIMEOUT_SECONDS, process_runner)
    result["system"]["probes"] = {
        "productVersion": product_probe,
        "buildVersion": build_probe,
        "architecture": architecture_probe,
    }
    for label, probe in (
        ("sw_vers -productVersion", product_probe),
        ("sw_vers -buildVersion", build_probe),
        ("uname -m", architecture_probe),
    ):
        problem = _process_problem(label, probe)
        if problem:
            errors.append(problem)
    if product_probe.get("exitCode") == 0:
        result["system"]["productVersion"] = product_probe["stdout"].strip()
    if build_probe.get("exitCode") == 0:
        result["system"]["buildVersion"] = build_probe["stdout"].strip()
    if architecture_probe.get("exitCode") == 0:
        result["system"]["architecture"] = architecture_probe["stdout"].strip()

    product_version = result["system"]["productVersion"]
    major = product_version.split(".", 1)[0] if product_version else None
    product_version_valid = bool(product_version and PRODUCT_VERSION_PATTERN.fullmatch(product_version))
    result["system"]["productVersionValid"] = product_version_valid
    _check(
        checks, errors, "productVersionValid", product_version_valid,
        f"sw_vers productVersion is empty or invalid: {product_version!r}",
    )
    _check(
        checks, errors, "productVersionMajorMatches",
        major == str(expected_major),
        f"expected macOS major {expected_major}, found productVersion {product_version!r}",
    )
    build_version = result["system"]["buildVersion"]
    build_version_valid = bool(build_version and BUILD_VERSION_PATTERN.fullmatch(build_version))
    result["system"]["buildVersionValid"] = build_version_valid
    _check(
        checks, errors, "buildVersionValid", build_version_valid,
        f"sw_vers buildVersion is empty or invalid: {build_version!r}",
    )
    _check(
        checks, errors, "architectureMatches",
        result["system"]["architecture"] == expected_architecture,
        f"expected architecture {expected_architecture!r}, found {result['system']['architecture']!r}",
    )
    if expected_product_version is not None:
        _check(
            checks, errors, "productVersionMatches",
            product_version == expected_product_version,
            f"expected productVersion {expected_product_version!r}, found {product_version!r}",
        )
    if expected_build_version is not None:
        _check(
            checks, errors, "buildVersionMatches",
            result["system"]["buildVersion"] == expected_build_version,
            f"expected buildVersion {expected_build_version!r}, found {result['system']['buildVersion']!r}",
        )

    info_plist = app / "Contents" / "Info.plist"
    try:
        commit = _read_plist_commit(info_plist)
        result["app"]["motionpaperCommit"] = commit
        _check(
            checks, errors, "commitMatches",
            commit == expected_commit,
            f"expected app MotionpaperCommit {expected_commit!r}, found {commit!r}",
        )
    except (OSError, plistlib.InvalidFileException, ValueError) as error:
        checks["commitMatches"] = False
        errors.append(f"could not read app MotionpaperCommit from {info_plist}: {error}")

    try:
        if not executable.is_file():
            raise FileNotFoundError(f"app executable does not exist: {executable}")
        result["app"]["binarySha256"] = _sha256(executable)
    except OSError as error:
        errors.append(f"could not hash app executable: {error}")

    try:
        if not updater.is_file():
            raise FileNotFoundError(f"updater executable does not exist: {updater}")
        result["updater"]["binarySha256"] = _sha256(updater)
        checks["updaterBinaryHashAvailable"] = True
    except OSError as error:
        checks["updaterBinaryHashAvailable"] = False
        errors.append(f"could not hash updater executable: {error}")

    if executable.is_file():
        app_process = run_process(
            (executable, "--verify-compatibility", "--verify-assertion-lifecycle"),
            APP_TIMEOUT_SECONDS,
            process_runner,
        )
        result["app"].update({
            "exitCode": app_process.get("exitCode"),
            "stdout": app_process.get("stdout", ""),
            "stderr": app_process.get("stderr", ""),
            "timedOut": app_process.get("timedOut", False),
        })
        for key in ("launchError", "timeoutSeconds"):
            if key in app_process:
                result["app"][key] = app_process[key]
        problem = _process_problem("release app verification", app_process)
        _check(checks, errors, "appExitCodeZero", problem is None, problem or "")
        try:
            native_report = json.loads(app_process.get("stdout", ""))
            result["app"]["nativeReport"] = native_report
            if app_process.get("exitCode") == 0:
                _validate_native_report(native_report, expected_architecture, checks, errors)
            else:
                checks["nativeReportValid"] = isinstance(native_report, dict)
                if not isinstance(native_report, dict):
                    errors.append("app stdout must contain a JSON object")
        except (json.JSONDecodeError, TypeError) as error:
            checks["nativeReportValid"] = False
            errors.append(f"release app stdout is not valid JSON: {error}")

    if updater.is_file():
        updater_process = run_process((updater,), HELPER_TIMEOUT_SECONDS, process_runner)
        result["updater"].update({
            "exitCode": updater_process.get("exitCode"),
            "stdout": updater_process.get("stdout", ""),
            "stderr": updater_process.get("stderr", ""),
            "timedOut": updater_process.get("timedOut", False),
        })
        for key in ("launchError", "timeoutSeconds"):
            if key in updater_process:
                result["updater"][key] = updater_process[key]
        problem = _process_problem("MotionpaperUpdater without arguments", updater_process)
        _check(checks, errors, "updaterStartsWithoutArguments", problem is None, problem or "")
    else:
        checks["updaterStartsWithoutArguments"] = False
        errors.append(f"updater executable does not exist: {updater}")

    result["status"] = "passed" if not errors else "failed"
    return result


def write_report(path, report):
    destination = Path(path)
    destination.parent.mkdir(parents=True, exist_ok=True)
    temporary = destination.with_name(destination.name + ".tmp")
    temporary.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    temporary.replace(destination)


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("app", help="path to the release Motionpaper.app bundle")
    parser.add_argument("--expected-commit", required=True, help="full 40-character app commit hash")
    parser.add_argument("--expected-major", required=True, help="expected macOS major version, such as 15")
    parser.add_argument("--expected-architecture", required=True, choices=ARCHITECTURES)
    parser.add_argument("--expected-product-version", help="optional exact sw_vers productVersion")
    parser.add_argument("--expected-build-version", help="optional exact sw_vers buildVersion")
    parser.add_argument("--output", default="compatibility.json", help="path for the reusable JSON result")
    arguments = parser.parse_args(argv)

    if not re.fullmatch(r"[0-9a-f]{40}", arguments.expected_commit):
        parser.error("--expected-commit must be a lowercase full 40-character hash")
    if not re.fullmatch(r"[0-9]+", arguments.expected_major):
        parser.error("--expected-major must be a numeric macOS major version")

    report = verify_compatibility(
        arguments.app,
        arguments.expected_commit,
        arguments.expected_major,
        arguments.expected_architecture,
        arguments.expected_product_version,
        arguments.expected_build_version,
    )
    try:
        write_report(arguments.output, report)
    except OSError as error:
        message = f"could not write compatibility report {arguments.output}: {error}"
        report["status"] = "failed"
        report["errors"].append(message)
        print(f"error: {message}", file=sys.stderr)
        print(json.dumps(report, indent=2, sort_keys=True), file=sys.stdout)
        return 1
    print(json.dumps(report, indent=2, sort_keys=True))
    return 0 if report["status"] == "passed" else 1


if __name__ == "__main__":
    raise SystemExit(main())
