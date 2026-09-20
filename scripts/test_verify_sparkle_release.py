import stat
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


SCRIPT = Path(__file__).with_name("verify_sparkle_release.py")
SPARKLE_NAMESPACE = "http://www.andymatuschak.org/xml-namespaces/sparkle"


class VerifySparkleReleaseTests(unittest.TestCase):
    def setUp(self) -> None:
        self.directory = tempfile.TemporaryDirectory(prefix="perry-sparkle-release-")
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        self.dmg = self.root / "Perry-1.0.dmg"
        self.dmg.write_bytes(b"signed release")
        self.key = self.root / "key"
        self.key.write_text("key", encoding="utf-8")
        self.verifier = self.root / "sign_update"
        self.verifier.write_text("#!/bin/sh\n[ \"$5\" = valid-signature ]\n", encoding="utf-8")
        self.verifier.chmod(self.verifier.stat().st_mode | stat.S_IXUSR)

    def write_appcast(
        self,
        signature: str = "valid-signature",
        name: str | None = None,
    ) -> Path:
        appcast = self.root / "appcast.xml"
        appcast.write_text(
            f'''<rss xmlns:sparkle="{SPARKLE_NAMESPACE}" version="2.0"><channel><item><sparkle:version>2</sparkle:version><sparkle:shortVersionString>1.0</sparkle:shortVersionString><enclosure url="https://updates.example.test/{name or self.dmg.name}" length="{self.dmg.stat().st_size}" sparkle:edSignature="{signature}" /></item></channel></rss>''',
            encoding="utf-8",
        )
        return appcast

    def verify(self, appcast: Path) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            [
                sys.executable,
                "-B",
                str(SCRIPT),
                "--appcast",
                str(appcast),
                "--dmg",
                str(self.dmg),
                "--version",
                "1.0",
                "--build",
                "2",
                "--sign-update",
                str(self.verifier),
                "--key-file",
                str(self.key),
            ],
            capture_output=True,
            text=True,
            check=False,
        )

    def test_accepts_cryptographically_verified_release(self) -> None:
        self.assertEqual(self.verify(self.write_appcast()).returncode, 0)

    def test_rejects_signature_verifier_failure(self) -> None:
        result = self.verify(self.write_appcast(signature="invalid-signature"))
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("EdDSA signature verification failed", result.stderr)

    def test_rejects_wrong_dmg_identity_before_verification(self) -> None:
        result = self.verify(self.write_appcast(name="Perry-9.9.dmg"))
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("does not identify Perry-1.0.dmg", result.stderr)


if __name__ == "__main__":
    unittest.main()
