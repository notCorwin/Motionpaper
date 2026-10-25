"""Focused contract tests for the native compatibility verifier."""

import json
import importlib.util
import hashlib
from pathlib import Path
import plistlib
import subprocess
import tempfile
import unittest

VERIFIER_PATH = Path(__file__).with_name("verify-compatibility.py")
VERIFIER_SPEC = importlib.util.spec_from_file_location("verify_compatibility", VERIFIER_PATH)
VERIFIER = importlib.util.module_from_spec(VERIFIER_SPEC)
VERIFIER_SPEC.loader.exec_module(VERIFIER)
verify_compatibility = VERIFIER.verify_compatibility


COMMIT = "a" * 40


class CompatibilityVerifierTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.app = Path(self.temporary.name) / "Motionpaper.app"
        contents = self.app / "Contents"
        (contents / "MacOS").mkdir(parents=True)
        (contents / "Helpers").mkdir()
        (contents / "MacOS" / "Motionpaper").write_bytes(b"release executable fixture")
        (contents / "Helpers" / "MotionpaperUpdater").write_bytes(b"updater executable fixture")
        with (contents / "Info.plist").open("wb") as stream:
            plistlib.dump({"MotionpaperCommit": COMMIT}, stream)
        self.native_report = {
            "systemVersion": "macOS 26.0 (Build 25A1)",
            "architecture": "arm64",
            "interfaceAvailable": True,
            "assertionLifecycleVerified": True,
        }
        self.product_version = "26.0"
        self.build_version = "25A1"
        self.native_exit_code = 0
        self.updater_exit_code = 0
        self.app_timeout = False

    def process_runner(self, arguments, capture_output, text, timeout):
        del capture_output, text
        arguments = [str(argument) for argument in arguments]
        if arguments == ["sw_vers", "-productVersion"]:
            return subprocess.CompletedProcess(arguments, 0, self.product_version + "\n", "")
        if arguments == ["sw_vers", "-buildVersion"]:
            return subprocess.CompletedProcess(arguments, 0, self.build_version + "\n", "")
        if arguments == ["uname", "-m"]:
            return subprocess.CompletedProcess(arguments, 0, "arm64\n", "")
        if arguments[0].endswith("/Contents/MacOS/Motionpaper"):
            if self.app_timeout:
                raise subprocess.TimeoutExpired(arguments, timeout, output=b"partial report", stderr=b"native timed out")
            stdout = json.dumps(self.native_report)
            return subprocess.CompletedProcess(arguments, self.native_exit_code, stdout, "native diagnostic")
        if arguments[0].endswith("/Contents/Helpers/MotionpaperUpdater"):
            return subprocess.CompletedProcess(arguments, self.updater_exit_code, "", "")
        self.fail(f"unexpected subprocess: {arguments}")

    def verify(self, **overrides):
        arguments = {
            "app_path": self.app,
            "expected_commit": COMMIT,
            "expected_major": "26",
            "expected_architecture": "arm64",
            "process_runner": self.process_runner,
        }
        arguments.update(overrides)
        return verify_compatibility(**arguments)

    def test_success_records_native_contract_and_exact_os_build(self):
        report = self.verify(expected_product_version="26.0", expected_build_version="25A1")

        self.assertEqual(report["status"], "passed")
        self.assertTrue(report["checks"]["interfaceAvailable"])
        self.assertTrue(report["checks"]["assertionLifecycleVerified"])
        self.assertTrue(report["checks"]["buildVersionMatches"])
        self.assertEqual(report["system"]["productVersion"], "26.0")
        self.assertEqual(report["system"]["buildVersion"], "25A1")
        self.assertEqual(report["app"]["motionpaperCommit"], COMMIT)
        self.assertEqual(len(report["app"]["binarySha256"]), 64)
        self.assertEqual(report["app"]["exitCode"], 0)
        self.assertEqual(
            report["updater"]["binarySha256"],
            hashlib.sha256(b"updater executable fixture").hexdigest(),
        )
        self.assertEqual(report["updater"]["exitCode"], 0)

    def test_rejects_empty_or_invalid_os_versions_without_exact_expectations(self):
        cases = (
            ("", "25A1", False, True),
            ("26.beta", "25A1", False, True),
            ("26.0", "", True, False),
            ("26.0", "25A", True, False),
        )

        for product_version, build_version, product_valid, build_valid in cases:
            with self.subTest(product_version=product_version, build_version=build_version):
                self.product_version = product_version
                self.build_version = build_version

                report = self.verify()

                self.assertEqual(report["status"], "failed")
                self.assertEqual(report["checks"]["productVersionValid"], product_valid)
                self.assertEqual(report["checks"]["buildVersionValid"], build_valid)

    def test_rejects_native_report_without_required_true_lifecycle_result(self):
        self.native_report["assertionLifecycleVerified"] = False

        report = self.verify()

        self.assertEqual(report["status"], "failed")
        self.assertFalse(report["checks"]["assertionLifecycleVerified"])
        self.assertIn("native report assertionLifecycleVerified must be true", report["errors"])

    def test_rejects_integer_instead_of_boolean_success_field(self):
        self.native_report["interfaceAvailable"] = 1

        report = self.verify()

        self.assertEqual(report["status"], "failed")
        self.assertFalse(report["checks"]["interfaceAvailable"])
        self.assertIn("native report interfaceAvailable must be true", report["errors"])

    def test_rejects_stale_playback_field_even_if_old_contract_passes(self):
        self.native_report["playbackVerified"] = True

        report = self.verify()

        self.assertEqual(report["status"], "failed")
        self.assertIn("native report contains obsolete playbackVerified field", report["errors"])

    def test_rejects_mismatched_exact_os_build(self):
        report = self.verify(expected_build_version="25A2")

        self.assertEqual(report["status"], "failed")
        self.assertFalse(report["checks"]["buildVersionMatches"])
        self.assertIn("expected buildVersion '25A2', found '25A1'", report["errors"])

    def test_rejects_nonzero_app_exit_even_when_stdout_looks_successful(self):
        self.native_exit_code = 1

        report = self.verify()

        self.assertEqual(report["status"], "failed")
        self.assertFalse(report["checks"]["appExitCodeZero"])
        self.assertEqual(report["app"]["exitCode"], 1)
        self.assertIn("release app verification exited with code 1", report["errors"])

    def test_preserves_app_timeout_diagnostics_and_never_passes(self):
        self.app_timeout = True

        report = self.verify()

        self.assertEqual(report["status"], "failed")
        self.assertTrue(report["app"]["timedOut"])
        self.assertEqual(report["app"]["stdout"], "partial report")
        self.assertEqual(report["app"]["stderr"], "native timed out")
        self.assertIn("release app verification timed out after 60 seconds", report["errors"])


if __name__ == "__main__":
    unittest.main()
