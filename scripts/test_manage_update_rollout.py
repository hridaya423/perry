import json
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


SCRIPT = Path(__file__).with_name("manage-update-rollout.py")
SPARKLE_NAMESPACE = "http://www.andymatuschak.org/xml-namespaces/sparkle"


def appcast(version, build, dmg_name, length, signature="test-signature"):
    return f'''<?xml version="1.0"?>
<rss xmlns:sparkle="{SPARKLE_NAMESPACE}" version="2.0">
  <channel>
    <title>Perry Updates</title>
    <item>
      <title>Perry {version}</title>
      <sparkle:version>{build}</sparkle:version>
      <sparkle:shortVersionString>{version}</sparkle:shortVersionString>
      <enclosure url="https://updates.example.test/{dmg_name}" length="{length}" type="application/octet-stream" sparkle:edSignature="{signature}" />
    </item>
  </channel>
</rss>
'''


class ManageUpdateRolloutTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory(prefix="perry-rollout-test-")
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        self.inputs = self.root / "inputs"
        self.inputs.mkdir()
        self.current_dmg = self.inputs / "Perry-1.0.dmg"
        self.previous_dmg = self.inputs / "Perry-0.9.dmg"
        self.current_dmg.write_bytes(b"current-dmg")
        self.previous_dmg.write_bytes(b"previous-dmg")
        self.current_appcast = self.inputs / "current-appcast.xml"
        self.previous_appcast = self.inputs / "previous-appcast.xml"
        self.current_appcast.write_text(
            appcast("1.0", 2, self.current_dmg.name, self.current_dmg.stat().st_size),
            encoding="utf-8",
        )
        self.previous_appcast.write_text(
            appcast("0.9", 1, self.previous_dmg.name, self.previous_dmg.stat().st_size),
            encoding="utf-8",
        )

    def run_script(self, *arguments):
        return subprocess.run(
            [sys.executable, str(SCRIPT), *arguments],
            capture_output=True,
            text=True,
            timeout=10,
        )

    def initialize(self, state, current_appcast=None, previous_appcast=None):
        return self.run_script(
            "initialize",
            "--state",
            str(state),
            "--version",
            "1.0",
            "--build",
            "2",
            "--dmg",
            str(self.current_dmg),
            "--appcast",
            str(current_appcast or self.current_appcast),
            "--previous-version",
            "0.9",
            "--previous-build",
            "1",
            "--previous-dmg",
            str(self.previous_dmg),
            "--previous-appcast",
            str(previous_appcast or self.previous_appcast),
        )

    def test_state_remains_valid_after_bundle_relocation(self):
        bundle = self.root / "bundle"
        state = bundle / "rollout.json"
        result = self.initialize(state)
        self.assertEqual(result.returncode, 0, result.stderr)

        state_data = json.loads(state.read_text(encoding="utf-8"))
        for release in (state_data["current_release"], state_data["previous_release"]):
            self.assertFalse(Path(release["dmg"]["path"]).is_absolute())
            self.assertFalse(Path(release["appcast"]["path"]).is_absolute())
        self.assertTrue((bundle / "artifacts").is_dir())

        relocated = self.root / "relocated-bundle"
        shutil.move(bundle, relocated)
        result = self.run_script("verify", "--state", str(relocated / "rollout.json"))
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_rejects_invalid_current_appcast_xml(self):
        invalid = self.inputs / "invalid-current.xml"
        invalid.write_text("<rss>", encoding="utf-8")
        result = self.initialize(self.root / "bundle" / "rollout.json", invalid)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("current_release.appcast is not valid XML", result.stderr)

    def test_rejects_invalid_previous_appcast_xml(self):
        invalid = self.inputs / "invalid-previous.xml"
        invalid.write_text("not xml", encoding="utf-8")
        result = self.initialize(
            self.root / "bundle" / "rollout.json", previous_appcast=invalid
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("previous_release.appcast is not valid XML", result.stderr)

    def test_rejects_appcast_with_wrong_dmg_identity(self):
        mismatched = self.inputs / "mismatched-current.xml"
        mismatched.write_text(
            appcast("1.0", 2, "Perry-9.9.dmg", self.current_dmg.stat().st_size),
            encoding="utf-8",
        )
        result = self.initialize(self.root / "bundle" / "rollout.json", mismatched)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("does not identify Perry-1.0.dmg", result.stderr)

    def test_rejects_appcast_with_wrong_dmg_length(self):
        mismatched = self.inputs / "mismatched-length-current.xml"
        mismatched.write_text(
            appcast("1.0", 2, self.current_dmg.name, 999),
            encoding="utf-8",
        )
        result = self.initialize(self.root / "bundle" / "rollout.json", mismatched)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("enclosure length does not match", result.stderr)


if __name__ == "__main__":
    unittest.main()
