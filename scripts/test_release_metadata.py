from __future__ import annotations

import tempfile
import unittest
from pathlib import Path

import release_metadata


REPO_ROOT = Path(__file__).resolve().parents[1]


class ReleaseMetadataTests(unittest.TestCase):
    def test_xcodegen_lock_is_emitted_as_sbom_and_license_component(self):
        runtime = release_metadata.load_runtime_lock(REPO_ROOT / "scripts/codex-runtime.lock")
        cua_driver = release_metadata.load_cua_driver_lock(REPO_ROOT / "scripts/cua-driver.lock")
        sparkle = release_metadata.load_sparkle_lock(REPO_ROOT / "scripts/sparkle.lock")
        xcodegen = release_metadata.load_xcodegen_lock(REPO_ROOT / "scripts/xcodegen.lock")

        licenses, unresolved = release_metadata.third_party_components(
            {}, runtime, cua_driver, sparkle, xcodegen, []
        )
        self.assertEqual(unresolved, [])
        xcodegen_license = next(item for item in licenses if item["id"] == "tool.xcodegen")
        self.assertEqual(xcodegen_license["purl"], "pkg:github/yonaskolb/XcodeGen@2.46.0")
        self.assertEqual(xcodegen_license["source"], "https://github.com/yonaskolb/XcodeGen")
        self.assertEqual(xcodegen_license["license"], "MIT")
        self.assertEqual(
            xcodegen_license["archive_sha256"],
            "4d9e34b62172d645eed6457cac13fc222569974098ef4ee9c3368bedf0196806",
        )
        self.assertEqual(
            xcodegen_license["binary_sha256"],
            "8774da746668bc18fe74e54cbaf10f2631a1fb05947cd374179aa912f14f99db",
        )

        sbom = release_metadata.build_sbom(
            {}, {}, set(), runtime, cua_driver, sparkle, xcodegen, []
        )
        xcodegen_component = next(
            item for item in sbom["components"] if item["bom-ref"] == "tool:xcodegen"
        )
        self.assertEqual(xcodegen_component["purl"], xcodegen_license["purl"])
        self.assertEqual(xcodegen_component["version"], "2.46.0")
        self.assertEqual(xcodegen_component["licenses"], [{"license": {"id": "MIT"}}])
        application = next(
            item for item in sbom["dependencies"] if item["ref"] == "application:perry"
        )
        self.assertIn("tool:xcodegen", application["dependsOn"])

    def test_xcodegen_lock_rejects_an_unpinned_archive_url(self):
        with tempfile.TemporaryDirectory() as directory:
            lock = Path(directory) / "xcodegen.lock"
            lock.write_text(
                (REPO_ROOT / "scripts/xcodegen.lock")
                .read_text(encoding="utf-8")
                .replace("/2.46.0/xcodegen.zip", "/2.46.0/other.zip"),
                encoding="utf-8",
            )
            with self.assertRaisesRegex(SystemExit, "exact pinned GitHub release asset"):
                release_metadata.load_xcodegen_lock(lock)


if __name__ == "__main__":
    unittest.main()
