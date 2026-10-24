import os
from pathlib import Path
import subprocess
import tempfile
import unittest


SIGNER = Path(__file__).with_name("sign-distribution.sh")
CAPABILITIES_PATH = "Contents/Resources/CuaDriver/capabilities.yaml"
REQUIRED_CODE_PATHS = (
    "Contents/MacOS/Perry",
    "Contents/MacOS/perry-mcp",
    "Contents/Resources/CodexRuntime/bin/codex",
    "Contents/Resources/CuaDriver/bin/cua-driver",
    "Contents/Frameworks/Sparkle.framework",
    "Contents/Frameworks/Sparkle.framework/Versions/Current/Sparkle",
    "Contents/Frameworks/Sparkle.framework/Versions/Current/Autoupdate",
    "Contents/Frameworks/Sparkle.framework/Versions/Current/Updater.app",
    "Contents/Frameworks/Sparkle.framework/Versions/Current/Updater.app/Contents/MacOS/Updater",
    "Contents/Frameworks/Sparkle.framework/Versions/Current/XPCServices/Downloader.xpc",
    "Contents/Frameworks/Sparkle.framework/Versions/Current/XPCServices/Downloader.xpc/Contents/MacOS/Downloader",
    "Contents/Frameworks/Sparkle.framework/Versions/Current/XPCServices/Installer.xpc",
    "Contents/Frameworks/Sparkle.framework/Versions/Current/XPCServices/Installer.xpc/Contents/MacOS/Installer",
)
SIGN_ORDER = (
    "Contents/Resources/CodexRuntime/bin/codex",
    "Contents/Resources/CuaDriver/bin/cua-driver",
    "Contents/MacOS/perry-mcp",
    "Contents/Frameworks/Sparkle.framework/Versions/Current/XPCServices/Installer.xpc",
    "Contents/Frameworks/Sparkle.framework/Versions/Current/XPCServices/Downloader.xpc",
    "Contents/Frameworks/Sparkle.framework/Versions/Current/Autoupdate",
    "Contents/Frameworks/Sparkle.framework/Versions/Current/Updater.app",
    "Contents/Frameworks/Sparkle.framework",
)


class DistributionSigningTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory(prefix="perry-signing-test-")
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        self.app = self.root / "Perry.app"
        for name, version in (("Sparkle", "B"),):
            versions = self.app / f"Contents/Frameworks/{name}.framework/Versions"
            (versions / version).mkdir(parents=True)
            (versions / "Current").symlink_to(version)
        for relative_path in REQUIRED_CODE_PATHS:
            path = self.app / relative_path
            if path.suffix in {".framework", ".app", ".xpc"}:
                path.mkdir(parents=True, exist_ok=True)
            else:
                path.parent.mkdir(parents=True, exist_ok=True)
                path.touch()
        (self.app / CAPABILITIES_PATH).write_text("capabilities", encoding="utf-8")
        self.entitlements = self.root / "Perry.entitlements"
        self.entitlements.write_text("entitlements", encoding="utf-8")
        commands = self.root / "commands"
        commands.mkdir()
        codesign = commands / "codesign"
        codesign.write_text(
            "#!/bin/sh\n"
            "for argument in \"$@\"; do\n"
            "  printf '%s\\t' \"$argument\" >> \"${CODESIGN_CAPTURE}\"\n"
            "done\n"
            "printf '\\n' >> \"${CODESIGN_CAPTURE}\"\n"
            "if [ -n \"${CODESIGN_FAIL_TARGET:-}\" ]; then\n"
            "  for argument in \"$@\"; do\n"
            "    [ \"${argument}\" = \"${CODESIGN_FAIL_TARGET}\" ] && exit 23\n"
            "  done\n"
            "fi\n"
            "exit 0\n",
            encoding="utf-8",
        )
        codesign.chmod(0o755)
        self.capture = self.root / "codesign-calls"
        self.environment = dict(
            os.environ,
            PATH=f"{commands}:/usr/bin:/bin",
            CODESIGN_CAPTURE=str(self.capture),
            CODESIGN_FAIL_TARGET="",
        )

    def run_signer(self, fail_target=""):
        environment = dict(self.environment, CODESIGN_FAIL_TARGET=fail_target)
        return subprocess.run(
            ["/bin/sh", str(SIGNER), str(self.app), "TEST IDENTITY", str(self.entitlements)],
            env=environment,
            capture_output=True,
            text=True,
            timeout=10,
        )

    def captured_calls(self):
        if not self.capture.exists():
            return []
        return [line.split("\t")[:-1] for line in self.capture.read_text(encoding="utf-8").splitlines()]

    def test_signs_required_code_leaf_to_parent_and_app_last(self):
        result = self.run_signer()
        self.assertEqual(result.returncode, 0, result.stderr)
        calls = self.captured_calls()
        expected_targets = [str(self.app / relative_path) for relative_path in SIGN_ORDER]
        expected_targets.append(str(self.app))
        self.assertEqual([call[-1] for call in calls], expected_targets)
        for call in calls:
            self.assertIn("--force", call)
            self.assertIn("--timestamp", call)
            options_index = call.index("--options")
            self.assertEqual(call[options_index + 1], "runtime")
            sign_index = call.index("--sign")
            self.assertEqual(call[sign_index + 1], "TEST IDENTITY")
            self.assertNotIn("--deep", call)
        self.assertIn("--preserve-metadata=entitlements", calls[4])
        self.assertTrue(all("--preserve-metadata=entitlements" not in call for call in calls[:4] + calls[5:-1]))
        self.assertIn("--entitlements", calls[-1])
        self.assertEqual(calls[-1][calls[-1].index("--entitlements") + 1], str(self.entitlements))
        self.assertTrue(all("--entitlements" not in call for call in calls[:-1]))

    def test_sign_failure_stops_before_app_seal(self):
        failure_target = str(self.app / SIGN_ORDER[4])
        result = self.run_signer(failure_target)
        self.assertNotEqual(result.returncode, 0)
        calls = self.captured_calls()
        self.assertEqual([call[-1] for call in calls], [str(self.app / path) for path in SIGN_ORDER[:5]])
        self.assertNotIn(str(self.app), [call[-1] for call in calls])

    def test_missing_nested_code_fails_before_any_sign(self):
        missing_target = self.app / REQUIRED_CODE_PATHS[-1]
        missing_target.unlink()
        result = self.run_signer()
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.captured_calls(), [])

    def test_broken_framework_version_link_fails_before_any_sign(self):
        current = self.app / "Contents/Frameworks/Sparkle.framework/Versions/Current"
        current.unlink()
        current.symlink_to("missing-version")
        result = self.run_signer()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("missing nested code object", result.stderr)
        self.assertEqual(self.captured_calls(), [])

    def test_missing_cua_capabilities_fails_before_any_sign(self):
        (self.app / CAPABILITIES_PATH).unlink()
        result = self.run_signer()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("missing Cua capabilities.yaml", result.stderr)
        self.assertEqual(self.captured_calls(), [])

    def test_external_cua_capabilities_symlink_fails_before_any_sign(self):
        manifest = self.app / CAPABILITIES_PATH
        external_manifest = self.root / "outside-capabilities.yaml"
        external_manifest.write_text("external capabilities", encoding="utf-8")
        manifest.unlink()
        manifest.symlink_to(external_manifest)
        result = self.run_signer()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("resolves outside the app bundle", result.stderr)
        self.assertEqual(self.captured_calls(), [])

    def test_cua_capabilities_rejects_app_path_prefix_collision(self):
        manifest = self.app / CAPABILITIES_PATH
        collision_manifest = self.root / "Perry.app-sibling" / "capabilities.yaml"
        collision_manifest.parent.mkdir(parents=True)
        collision_manifest.write_text("collision capabilities", encoding="utf-8")
        manifest.unlink()
        manifest.symlink_to(collision_manifest)
        result = self.run_signer()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("resolves outside the app bundle", result.stderr)
        self.assertEqual(self.captured_calls(), [])

    def test_cua_capabilities_rejects_directory_symlink_escape(self):
        resources = self.app / "Contents/Resources"
        driver_directory = resources / "CuaDriver"
        driver_directory.rename(resources / "CuaDriver-inside")
        external_driver = self.root / "outside-cua-driver"
        (external_driver / "bin").mkdir(parents=True)
        (external_driver / "bin/cua-driver").touch()
        (external_driver / "capabilities.yaml").write_text("external capabilities", encoding="utf-8")
        driver_directory.symlink_to(external_driver, target_is_directory=True)
        result = self.run_signer()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("resolves outside the app bundle", result.stderr)
        self.assertEqual(self.captured_calls(), [])

    def test_directory_cua_capabilities_fails_before_any_sign(self):
        manifest = self.app / CAPABILITIES_PATH
        manifest.unlink()
        manifest.mkdir()
        result = self.run_signer()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("not a regular file", result.stderr)
        self.assertEqual(self.captured_calls(), [])

    def test_internal_cua_capabilities_symlink_is_accepted(self):
        manifest = self.app / CAPABILITIES_PATH
        internal_manifest = self.app / "Contents/Resources/internal-capabilities.yaml"
        internal_manifest.write_text("internal capabilities", encoding="utf-8")
        manifest.unlink()
        manifest.symlink_to(internal_manifest)
        result = self.run_signer()
        self.assertEqual(result.returncode, 0, result.stderr)


if __name__ == "__main__":
    unittest.main()
