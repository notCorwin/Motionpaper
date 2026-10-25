"""Focused tests for exact-target compatibility evidence aggregation."""

import importlib.util
import hashlib
import json
from pathlib import Path
import plistlib
import tempfile
import unittest


COVERAGE_PATH = Path(__file__).with_name("compatibility-coverage.py")
COVERAGE_SPEC = importlib.util.spec_from_file_location("compatibility_coverage", COVERAGE_PATH)
COVERAGE = importlib.util.module_from_spec(COVERAGE_SPEC)
COVERAGE_SPEC.loader.exec_module(COVERAGE)


COMMIT = "c" * 40
APP_SHA256 = "1" * 64
UPDATER_SHA256 = "2" * 64


def target_catalog():
    return {
        "source": "https://example.test/apple-versions",
        "asOf": "2026-10-25",
        "cases": [
            {"productVersion": "15.0", "architecture": "arm64"},
            {"productVersion": "15.0", "architecture": "x86_64"},
            {"productVersion": "15.1", "architecture": "arm64"},
        ],
    }


def report(product_version="15.0", architecture="arm64", build_version="24A1"):
    return {
        "schemaVersion": 2,
        "scope": "nativeAssertionLifecycleAndUpdaterLaunch",
        "desktopFramesObserved": False,
        "status": "passed",
        "errors": [],
        "expected": {
            "commit": COMMIT,
            "major": product_version.split(".", 1)[0],
            "architecture": architecture,
        },
        "system": {
            "productVersion": product_version,
            "productVersionValid": True,
            "buildVersion": build_version,
            "buildVersionValid": True,
            "architecture": architecture,
        },
        "app": {
            "motionpaperCommit": COMMIT,
            "binarySha256": APP_SHA256,
            "exitCode": 0,
            "nativeReport": {
                "systemVersion": f"Version {product_version} (Build {build_version})",
                "architecture": architecture,
                "interfaceAvailable": True,
                "assertionLifecycleVerified": True,
            },
        },
        "updater": {
            "binarySha256": UPDATER_SHA256,
            "exitCode": 0,
            "arguments": [],
        },
        "checks": {name: True for name in COVERAGE.REQUIRED_CHECKS},
        "runner": "macos-15",
    }


class CompatibilityCoverageTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.report_path = Path(self.temporary.name) / "compatibility-macos-15.json"
        self.write_report(report())

    def write_report(self, value):
        self.report_path.write_text(json.dumps(value), encoding="utf-8")

    def summarize(self, paths=None, **overrides):
        arguments = {
            "target_catalog": target_catalog(),
            "report_paths": [self.report_path] if paths is None else paths,
            "expected_commit": COMMIT,
            "expected_app_sha256": APP_SHA256,
            "expected_updater_sha256": UPDATER_SHA256,
            "artifact_commit": COMMIT,
        }
        arguments.update(overrides)
        return COVERAGE.build_summary(**arguments)

    def test_reads_commit_and_hashes_both_binaries_from_app_bundle(self):
        app = Path(self.temporary.name) / "Motionpaper.app"
        contents = app / "Contents"
        (contents / "MacOS").mkdir(parents=True)
        (contents / "Helpers").mkdir()
        (contents / "MacOS" / "Motionpaper").write_bytes(b"release app")
        (contents / "Helpers" / "MotionpaperUpdater").write_bytes(b"release updater")
        with (contents / "Info.plist").open("wb") as stream:
            plistlib.dump({"MotionpaperCommit": COMMIT}, stream)

        identity = COVERAGE.artifact_identity(app)

        self.assertEqual(identity["commit"], COMMIT)
        self.assertEqual(identity["appBinarySha256"], hashlib.sha256(b"release app").hexdigest())
        self.assertEqual(identity["updaterBinarySha256"], hashlib.sha256(b"release updater").hexdigest())

    def test_accepts_exact_case_and_records_build_without_claiming_playback(self):
        summary = self.summarize()

        self.assertEqual(summary["status"], "incomplete")
        self.assertEqual(summary["scope"], "nativeAssertionLifecycleAndUpdaterLaunch")
        self.assertFalse(summary["desktopFramesObserved"])
        self.assertIn("does not establish wallpaper playback", summary["claim"])
        self.assertEqual(summary["counts"]["targetCases"], 3)
        self.assertEqual(summary["counts"]["verifiedCases"], 1)
        self.assertEqual(summary["counts"]["missingCases"], 2)
        self.assertEqual(summary["verifiedCases"][0]["builds"], ["24A1"])

    def test_same_major_but_unlisted_product_version_is_not_credited(self):
        self.write_report(report(product_version="15.1.1"))

        summary = self.summarize()

        self.assertEqual(summary["status"], "invalid")
        self.assertEqual(summary["counts"]["verifiedCases"], 0)
        self.assertTrue(any("not an exact target case" in error
                            for error in summary["rejectedReports"][0]["errors"]))

    def test_unlisted_architecture_for_an_exact_version_is_not_credited(self):
        single_architecture_target = {
            "source": "https://example.test/apple-versions",
            "asOf": "2026-10-25",
            "cases": [{"productVersion": "15.0", "architecture": "arm64"}],
        }
        self.write_report(report(architecture="x86_64"))

        summary = self.summarize(target_catalog=single_architecture_target)

        self.assertEqual(summary["status"], "invalid")
        self.assertEqual(summary["counts"]["verifiedCases"], 0)
        self.assertTrue(any("not an exact target case" in error
                            for error in summary["rejectedReports"][0]["errors"]))

    def test_rejects_reports_with_mixed_commit_or_either_binary_digest(self):
        cases = (
            ("expected", "commit", "d" * 40),
            ("app", "binarySha256", "3" * 64),
            ("updater", "binarySha256", "4" * 64),
        )
        for section, key, value in cases:
            with self.subTest(section=section, key=key):
                candidate = report()
                candidate[section][key] = value
                self.write_report(candidate)

                summary = self.summarize()

                self.assertEqual(summary["status"], "invalid")
                self.assertEqual(summary["counts"]["verifiedCases"], 0)
                self.assertEqual(summary["counts"]["reportsRejected"], 1)

    def test_rejects_legacy_playback_report_and_missing_updater_hash(self):
        candidate = report()
        candidate["app"]["nativeReport"]["playbackVerified"] = True
        candidate["updater"].pop("binarySha256")
        self.write_report(candidate)

        summary = self.summarize()

        self.assertEqual(summary["status"], "invalid")
        self.assertEqual(summary["counts"]["verifiedCases"], 0)
        errors = summary["rejectedReports"][0]["errors"]
        self.assertTrue(any("legacy playbackVerified" in error for error in errors))
        self.assertTrue(any("updater binary SHA-256" in error for error in errors))

    def test_failed_report_with_invalid_build_metadata_is_not_credited(self):
        candidate = report()
        candidate["status"] = "failed"
        candidate["system"]["buildVersion"] = "not-a-build"
        self.write_report(candidate)

        summary = self.summarize()

        self.assertEqual(summary["status"], "invalid")
        self.assertEqual(summary["counts"]["verifiedCases"], 0)
        errors = summary["rejectedReports"][0]["errors"]
        self.assertTrue(any("status must be 'passed'" in error for error in errors))
        self.assertTrue(any("buildVersion is missing or invalid" in error for error in errors))

    def test_malformed_native_report_is_rejected_without_crashing(self):
        candidate = report()
        candidate["app"]["nativeReport"] = 1
        self.write_report(candidate)

        summary = self.summarize()

        self.assertEqual(summary["status"], "invalid")
        self.assertEqual(summary["counts"]["verifiedCases"], 0)
        self.assertIn("native report metadata is missing", summary["rejectedReports"][0]["errors"])

    def test_optional_exact_product_and_build_expectations_must_match(self):
        candidate = report()
        candidate["expected"]["productVersion"] = "15.0.1"
        candidate["expected"]["buildVersion"] = "24A2"
        candidate["checks"]["productVersionMatches"] = True
        candidate["checks"]["buildVersionMatches"] = True
        self.write_report(candidate)

        summary = self.summarize()

        self.assertEqual(summary["status"], "invalid")
        self.assertEqual(summary["counts"]["verifiedCases"], 0)
        errors = summary["rejectedReports"][0]["errors"]
        self.assertIn("report expected productVersion does not match system productVersion", errors)
        self.assertIn("report expected buildVersion does not match system buildVersion", errors)

    def test_rejects_release_app_commit_mismatch(self):
        summary = self.summarize(artifact_commit="d" * 40)

        self.assertEqual(summary["status"], "invalid")
        self.assertIn("release app MotionpaperCommit does not match requested commit", summary["errors"])
        self.assertEqual(summary["counts"]["verifiedCases"], 0)
        self.assertEqual(summary["counts"]["reportsRejected"], 1)


if __name__ == "__main__":
    unittest.main()
