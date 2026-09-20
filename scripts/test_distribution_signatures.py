import os
from pathlib import Path
import subprocess
import tempfile
import unittest


VERIFIER = Path(__file__).with_name("verify-distribution-signatures.sh")
CODE_PATHS = (
    "Contents/MacOS/Perry",
    "Contents/Resources/CodexRuntime/bin/codex",
    "Contents/Resources/CuaDriver/bin/cua-driver",
    "Contents/Frameworks/Sparkle.framework/Versions/Current/Sparkle",
    "Contents/Frameworks/Sparkle.framework/Versions/Current/Autoupdate",
    "Contents/Frameworks/Sparkle.framework/Versions/Current/Updater.app/Contents/MacOS/Updater",
    "Contents/Frameworks/Sparkle.framework/Versions/Current/XPCServices/Downloader.xpc/Contents/MacOS/Downloader",
    "Contents/Frameworks/Sparkle.framework/Versions/Current/XPCServices/Installer.xpc/Contents/MacOS/Installer",
)
CODE_DIRECTORY = "CodeDirectory v=20500 size=58934 flags=0x10000(runtime) hashes=1831+7 location=embedded"


class DistributionSignatureTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory(prefix="perry-signature-test-")
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        self.app = self.root / "Perry.app"
        for relative_path in CODE_PATHS:
            path = self.app / relative_path
            path.parent.mkdir(parents=True, exist_ok=True)
            path.touch()
        commands = self.root / "commands"
        commands.mkdir()
        codesign = commands / "codesign"
        codesign.write_text(
            '#!/bin/sh\n'
            'if [ "$1" = "--verify" ]; then exit "${FIXTURE_VERIFY_STATUS:-0}"; fi\n'
            'printf "%s\\n" "$FIXTURE_CODE_DIRECTORY" "TeamIdentifier=${FIXTURE_TEAM:-TESTTEAM}" >&2\n',
            encoding="utf-8",
        )
        codesign.chmod(0o755)
        self.environment = dict(os.environ, PATH=f"{commands}:/usr/bin:/bin",
                                FIXTURE_CODE_DIRECTORY=CODE_DIRECTORY, FIXTURE_TEAM="TESTTEAM",
                                FIXTURE_VERIFY_STATUS="0")

    def verify(self, **environment):
        return subprocess.run(
            ["/bin/sh", str(VERIFIER), str(self.app), "TESTTEAM"],
            env=dict(self.environment, **environment), capture_output=True, text=True, timeout=10,
        )

    def test_accepts_observed_code_directory_format(self):
        result = self.verify()
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_rejects_missing_runtime_flag(self):
        result = self.verify(FIXTURE_CODE_DIRECTORY=CODE_DIRECTORY.replace("0x10000(runtime)", "0x0(none)"))
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("hardened runtime is missing", result.stderr)

    def test_accepts_runtime_among_other_flags(self):
        for flags in ("runtime,adhoc", "adhoc,runtime"):
            with self.subTest(flags=flags):
                result = self.verify(FIXTURE_CODE_DIRECTORY=CODE_DIRECTORY.replace("(runtime)", f"({flags})"))
                self.assertEqual(result.returncode, 0, result.stderr)

    def test_rejects_partial_runtime_flag_names(self):
        for flags in ("not-runtime", "runtime-disabled"):
            with self.subTest(flags=flags):
                result = self.verify(FIXTURE_CODE_DIRECTORY=CODE_DIRECTORY.replace("(runtime)", f"({flags})"))
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("hardened runtime is missing", result.stderr)

    def test_rejects_runtime_text_outside_code_directory_flags(self):
        result = self.verify(FIXTURE_CODE_DIRECTORY="Identifier=runtime\nflags=0x10000(runtime)")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("hardened runtime is missing", result.stderr)

    def test_rejects_wrong_team(self):
        result = self.verify(FIXTURE_TEAM="OTHERTEAM")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("unexpected signing team", result.stderr)

    def test_rejects_failed_strict_verification(self):
        result = self.verify(FIXTURE_VERIFY_STATUS="1")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("failed strict nested signature verification", result.stderr)

    def test_rejects_missing_nested_runtime(self):
        (self.app / "Contents/Resources/CuaDriver/bin/cua-driver").unlink()
        result = self.verify()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("missing signed code object", result.stderr)


if __name__ == "__main__":
    unittest.main()
