#!/usr/bin/env python3
"""Summarize exact-version native assertion lifecycle and updater launch evidence."""

import argparse
import hashlib
import json
from pathlib import Path
import plistlib
import re
import sys


ARCHITECTURES = ("arm64", "x86_64")
PRODUCT_VERSION_PATTERN = re.compile(r"(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)(?:\.(?:0|[1-9][0-9]*))?\Z")
BUILD_VERSION_PATTERN = re.compile(r"[0-9]{2}[A-Z][0-9]+[A-Z]?\Z")
SHA256_PATTERN = re.compile(r"[0-9a-f]{64}\Z")
COMMIT_PATTERN = re.compile(r"[0-9a-f]{40}\Z")
SCOPE = "nativeAssertionLifecycleAndUpdaterLaunch"
REQUIRED_CHECKS = (
    "productVersionValid",
    "productVersionMajorMatches",
    "buildVersionValid",
    "architectureMatches",
    "commitMatches",
    "appExitCodeZero",
    "nativeReportValid",
    "nativeArchitectureMatches",
    "interfaceAvailable",
    "assertionLifecycleVerified",
    "nativeSystemVersionPresent",
    "obsoletePlaybackFieldAbsent",
    "nativeErrorAbsent",
    "updaterBinaryHashAvailable",
    "updaterStartsWithoutArguments",
)


def sha256_file(path):
    digest = hashlib.sha256()
    with Path(path).open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def artifact_identity(app_path):
    app = Path(app_path)
    with (app / "Contents" / "Info.plist").open("rb") as stream:
        info = plistlib.load(stream)
    if not isinstance(info, dict) or not isinstance(info.get("MotionpaperCommit"), str):
        raise ValueError("app Info.plist has no string MotionpaperCommit")
    executable = app / "Contents" / "MacOS" / "Motionpaper"
    updater = app / "Contents" / "Helpers" / "MotionpaperUpdater"
    return {
        "commit": info["MotionpaperCommit"],
        "appBinarySha256": sha256_file(executable),
        "updaterBinarySha256": sha256_file(updater),
    }


def load_targets(path):
    with Path(path).open(encoding="utf-8") as stream:
        catalog = json.load(stream)
    if not isinstance(catalog, dict):
        raise ValueError("target catalog root must be a JSON object")
    source = catalog.get("source")
    as_of = catalog.get("asOf")
    families = catalog.get("families")
    if not isinstance(source, str) or not source or not isinstance(as_of, str) or not as_of:
        raise ValueError("target catalog must include source and asOf strings")
    if not isinstance(families, list) or not families:
        raise ValueError("target catalog families must be a non-empty array")

    cases = []
    seen_versions = set()
    for family in families:
        if not isinstance(family, dict):
            raise ValueError("each target family must be an object")
        major = family.get("major")
        architectures = family.get("architectures")
        versions = family.get("versions")
        if not isinstance(major, int) or isinstance(major, bool) or major < 1:
            raise ValueError(f"invalid target family major: {major!r}")
        if (not isinstance(architectures, list) or not architectures
                or any(architecture not in ARCHITECTURES for architecture in architectures)
                or len(set(architectures)) != len(architectures)):
            raise ValueError(f"invalid architectures for macOS {major}: {architectures!r}")
        if not isinstance(versions, list) or not versions:
            raise ValueError(f"versions for macOS {major} must be a non-empty array")
        for item in versions:
            version = item.get("version") if isinstance(item, dict) else None
            if not isinstance(version, str) or not PRODUCT_VERSION_PATTERN.fullmatch(version):
                raise ValueError(f"invalid target productVersion: {version!r}")
            if version.split(".", 1)[0] != str(major):
                raise ValueError(f"target version {version} does not belong to macOS {major}")
            if version in seen_versions:
                raise ValueError(f"duplicate target productVersion: {version}")
            seen_versions.add(version)
            cases.extend({"productVersion": version, "architecture": architecture}
                         for architecture in architectures)
    return {"source": source, "asOf": as_of, "sha256": sha256_file(path), "cases": cases}


def _report_errors(report, expected_commit, expected_app_sha256, expected_updater_sha256, target_cases):
    errors = []
    if not isinstance(report, dict):
        return ["report root must be a JSON object"], None
    if report.get("schemaVersion") != 2:
        errors.append(f"unsupported report schemaVersion: {report.get('schemaVersion')!r}")
    if report.get("status") != "passed":
        errors.append(f"report status must be 'passed', got {report.get('status')!r}")
    if report.get("scope") != SCOPE:
        errors.append(f"report scope must be {SCOPE!r}")
    if report.get("desktopFramesObserved") is not False:
        errors.append("report must state desktopFramesObserved=false")
    if report.get("errors") != []:
        errors.append("report errors must be an empty array")
    if "playbackVerified" in report:
        errors.append("legacy playbackVerified reports are not accepted")

    expected = report.get("expected")
    if not isinstance(expected, dict):
        errors.append("report expected metadata is missing")
    else:
        if expected.get("commit") != expected_commit:
            errors.append("report expected commit does not match requested commit")

    app = report.get("app")
    if not isinstance(app, dict):
        app = {}
        errors.append("report app metadata is missing")
    if app.get("motionpaperCommit") != expected_commit:
        errors.append("app MotionpaperCommit does not match requested commit")
    if app.get("binarySha256") != expected_app_sha256:
        errors.append("app binary SHA-256 does not match the requested artifact")
    if app.get("exitCode") != 0 or isinstance(app.get("exitCode"), bool):
        errors.append("app exitCode must be integer zero")

    updater = report.get("updater")
    if not isinstance(updater, dict):
        updater = {}
        errors.append("report updater metadata is missing")
    if updater.get("binarySha256") != expected_updater_sha256:
        errors.append("updater binary SHA-256 does not match the requested artifact")
    if updater.get("exitCode") != 0 or isinstance(updater.get("exitCode"), bool):
        errors.append("updater exitCode must be integer zero")
    if updater.get("arguments") != []:
        errors.append("updater must have been launched without arguments")

    system = report.get("system")
    if not isinstance(system, dict):
        system = {}
        errors.append("report system metadata is missing")
    product_version = system.get("productVersion")
    build_version = system.get("buildVersion")
    architecture = system.get("architecture")
    if not isinstance(product_version, str) or not PRODUCT_VERSION_PATTERN.fullmatch(product_version):
        errors.append(f"system productVersion is missing or invalid: {product_version!r}")
    if not isinstance(build_version, str) or not BUILD_VERSION_PATTERN.fullmatch(build_version):
        errors.append(f"system buildVersion is missing or invalid: {build_version!r}")
    if architecture not in ARCHITECTURES:
        errors.append(f"system architecture is missing or invalid: {architecture!r}")
    if system.get("productVersionValid") is not True:
        errors.append("report productVersionValid must be true")
    if system.get("buildVersionValid") is not True:
        errors.append("report buildVersionValid must be true")

    native = app.get("nativeReport")
    if not isinstance(native, dict):
        native = {}
        errors.append("native report metadata is missing")
    if "playbackVerified" in native:
        errors.append("legacy playbackVerified native reports are not accepted")
    if native.get("architecture") != architecture:
        errors.append("native architecture does not match uname architecture")
    if native.get("interfaceAvailable") is not True:
        errors.append("native interfaceAvailable must be true")
    if native.get("assertionLifecycleVerified") is not True:
        errors.append("native assertionLifecycleVerified must be true")
    native_system_version = native.get("systemVersion")
    if not isinstance(native_system_version, str) or not native_system_version.strip():
        errors.append("native systemVersion is missing")
    if native.get("error") is not None:
        errors.append("native report error must be absent or null")

    checks = report.get("checks")
    if not isinstance(checks, dict):
        errors.append("report checks metadata is missing")
    else:
        for name in REQUIRED_CHECKS:
            if checks.get(name) is not True:
                errors.append(f"report check {name} must be true")
        if isinstance(expected, dict) and "productVersion" in expected:
            if checks.get("productVersionMatches") is not True:
                errors.append("report check productVersionMatches must be true")
        if isinstance(expected, dict) and "buildVersion" in expected:
            if checks.get("buildVersionMatches") is not True:
                errors.append("report check buildVersionMatches must be true")

    case = None
    if isinstance(product_version, str) and isinstance(architecture, str):
        case = (product_version, architecture)
        if case not in target_cases:
            errors.append(f"{product_version}/{architecture} is not an exact target case")
        if not isinstance(expected, dict) or expected.get("major") != product_version.split(".", 1)[0]:
            errors.append("report expected major does not match exact system productVersion")
        if not isinstance(expected, dict) or expected.get("architecture") != architecture:
            errors.append("report expected architecture does not match system architecture")
    if isinstance(expected, dict):
        if "productVersion" in expected and expected["productVersion"] != product_version:
            errors.append("report expected productVersion does not match system productVersion")
        if "buildVersion" in expected and expected["buildVersion"] != build_version:
            errors.append("report expected buildVersion does not match system buildVersion")
    return errors, {
        "case": case,
        "productVersion": product_version,
        "buildVersion": build_version,
        "architecture": architecture,
        "nativeSystemVersion": native_system_version,
        "runner": report.get("runner"),
    }


def build_summary(target_catalog, report_paths, expected_commit, expected_app_sha256,
                  expected_updater_sha256, artifact_commit=None, input_errors=()):
    targets = target_catalog.get("cases", []) if isinstance(target_catalog, dict) else []
    target_keys = {(target["productVersion"], target["architecture"]) for target in targets}
    global_errors = list(input_errors)
    identity_errors = []
    if not COMMIT_PATTERN.fullmatch(expected_commit or ""):
        identity_errors.append("requested expected commit must be a full lowercase 40-character hash")
    if artifact_commit is not None and artifact_commit != expected_commit:
        identity_errors.append("release app MotionpaperCommit does not match requested commit")
    if not isinstance(expected_app_sha256, str) or not SHA256_PATTERN.fullmatch(expected_app_sha256):
        identity_errors.append("expected app binary SHA-256 is missing or invalid")
    if not isinstance(expected_updater_sha256, str) or not SHA256_PATTERN.fullmatch(expected_updater_sha256):
        identity_errors.append("expected updater binary SHA-256 is missing or invalid")
    global_errors.extend(identity_errors)
    if not targets:
        global_errors.append("target catalog contains no valid cases")

    verified = {}
    seen_evidence = set()
    rejected = []
    accepted_reports = 0
    for path in sorted((Path(item) for item in report_paths), key=lambda item: str(item)):
        try:
            with path.open(encoding="utf-8") as stream:
                report = json.load(stream)
        except (OSError, json.JSONDecodeError) as error:
            rejected.append({"report": str(path), "errors": [f"could not read JSON report: {error}"]})
            continue
        errors, evidence = _report_errors(
            report, expected_commit, expected_app_sha256, expected_updater_sha256, target_keys,
        )
        errors.extend(f"artifact identity invalid: {error}" for error in identity_errors)
        if errors:
            rejected.append({"report": str(path), "errors": errors})
            continue
        case_key = evidence["case"]
        build_key = (case_key, evidence["buildVersion"])
        if build_key in seen_evidence:
            rejected.append({
                "report": str(path),
                "errors": [f"duplicate evidence for {case_key[0]}/{case_key[1]} build {evidence['buildVersion']}"],
            })
            continue
        seen_evidence.add(build_key)
        accepted_reports += 1
        case = verified.setdefault(case_key, {
            "productVersion": case_key[0],
            "architecture": case_key[1],
            "builds": [],
            "evidence": [],
        })
        case["builds"].append(evidence["buildVersion"])
        case["evidence"].append({
            "buildVersion": evidence["buildVersion"],
            "nativeSystemVersion": evidence["nativeSystemVersion"],
            "runner": evidence["runner"],
            "report": str(path),
            "reportSha256": sha256_file(path),
        })

    verified_cases = [verified[key] for key in sorted(verified)]
    for case in verified_cases:
        case["builds"] = sorted(set(case["builds"]))
        case["evidence"].sort(key=lambda item: (item["buildVersion"], item["runner"] or "", item["report"]))
    missing = [target for target in targets
               if (target["productVersion"], target["architecture"]) not in verified]
    target_meta = {
        "source": target_catalog.get("source") if isinstance(target_catalog, dict) else None,
        "asOf": target_catalog.get("asOf") if isinstance(target_catalog, dict) else None,
        "sha256": target_catalog.get("sha256") if isinstance(target_catalog, dict) else None,
        "versionCount": len({target["productVersion"] for target in targets}),
        "caseCount": len(targets),
    }
    has_invalid = bool(global_errors or rejected)
    status = "invalid" if has_invalid else "complete" if not missing else "incomplete"
    return {
        "schemaVersion": 1,
        "status": status,
        "scope": SCOPE,
        "desktopFramesObserved": False,
        "claim": (
            "Evidence covers native assertion lifecycle and updater startup only; "
            "desktop frames were not observed, so this does not establish wallpaper playback."
        ),
        "artifact": {
            "expectedCommit": expected_commit,
            "appMotionpaperCommit": artifact_commit,
            "appBinarySha256": expected_app_sha256,
            "updaterBinarySha256": expected_updater_sha256,
        },
        "targetCatalog": target_meta,
        "counts": {
            "reportsProvided": len(report_paths),
            "reportsAccepted": accepted_reports,
            "reportsRejected": len(rejected),
            "targetCases": len(targets),
            "verifiedCases": len(verified_cases),
            "missingCases": len(missing),
        },
        "verifiedCases": verified_cases,
        "missingCases": missing,
        "rejectedReports": rejected,
        "errors": global_errors,
    }


def write_summary(path, summary):
    destination = Path(path)
    destination.parent.mkdir(parents=True, exist_ok=True)
    temporary = destination.with_name(destination.name + ".tmp")
    temporary.write_text(json.dumps(summary, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    temporary.replace(destination)


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--targets", required=True, help="Apple compatibility target catalog JSON")
    parser.add_argument("--reports-dir", required=True, help="directory containing compatibility JSON reports")
    parser.add_argument("--expected-commit", required=True, help="full commit hash expected for this artifact")
    parser.add_argument("--app", help="release app bundle to hash and inspect")
    parser.add_argument("--expected-app-sha256", help="explicit app executable SHA-256")
    parser.add_argument("--expected-updater-sha256", help="explicit updater executable SHA-256")
    parser.add_argument("--output", required=True, help="path for the reusable machine-readable summary")
    arguments = parser.parse_args(argv)
    if arguments.app and (arguments.expected_app_sha256 or arguments.expected_updater_sha256):
        parser.error("use --app or explicit SHA-256 values, not both")
    if not arguments.app and not (arguments.expected_app_sha256 and arguments.expected_updater_sha256):
        parser.error("provide --app or both explicit binary SHA-256 values")

    try:
        target_catalog = load_targets(arguments.targets)
        target_error = []
    except (OSError, json.JSONDecodeError, ValueError) as error:
        target_catalog = {"source": None, "asOf": None, "cases": []}
        target_error = [f"could not load target catalog: {error}"]

    artifact_commit = None
    app_sha256 = arguments.expected_app_sha256
    updater_sha256 = arguments.expected_updater_sha256
    input_errors = list(target_error)
    if arguments.app:
        try:
            identity = artifact_identity(arguments.app)
            artifact_commit = identity["commit"]
            app_sha256 = identity["appBinarySha256"]
            updater_sha256 = identity["updaterBinarySha256"]
        except (OSError, plistlib.InvalidFileException, ValueError) as error:
            input_errors.append(f"could not identify release app artifact: {error}")

    reports_dir = Path(arguments.reports_dir)
    report_paths = sorted(reports_dir.rglob("*.json")) if reports_dir.is_dir() else []
    summary = build_summary(
        target_catalog,
        report_paths,
        arguments.expected_commit,
        app_sha256,
        updater_sha256,
        artifact_commit=artifact_commit,
        input_errors=input_errors,
    )
    try:
        write_summary(arguments.output, summary)
    except OSError as error:
        print(f"error: could not write coverage summary {arguments.output}: {error}", file=sys.stderr)
        return 1
    print(json.dumps({"status": summary["status"], "counts": summary["counts"]}, sort_keys=True))
    return 1 if summary["status"] == "invalid" else 0


if __name__ == "__main__":
    raise SystemExit(main())
