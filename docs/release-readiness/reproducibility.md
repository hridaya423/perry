# Release reproducibility

The M10 gate records the Swift package graph, pinned runtime and SDK inputs, and hashes of the files that enter a release. The generated metadata contains no checkout-specific absolute paths, timestamps, or network-fetched values.

Run the metadata generator after changing a package manifest or the runtime lock:

```sh
scripts/generate-release-metadata.sh --write
scripts/verify-artifact-manifest.sh --write
```

CI uses `--check` for both scripts. The first command regenerates the CycloneDX SBOM and third-party inventory in memory, then compares the bytes with `docs/release-readiness/sbom.cdx.json` and `docs/release-readiness/third-party-licenses.json`. The second checks every entry in `docs/release-readiness/artifact-manifest.sha256` against the files in the checkout.

`scripts/codex-runtime.lock` is the runtime source of truth. Its version, target, archive digest, binary digest, SPDX license, repository, and tag-specific license URL are required; `fetch-codex-runtime.sh --check-lock` rejects missing, duplicate, malformed, or unpinned values before any download or build step.

The inventory includes Codex, Cua Driver, Sparkle, and the pinned XcodeGen build tool. Cua entries retain the source revision and both archive and binary hashes. The generator rejects unresolved licenses rather than dropping a component from the inventory.

Distribution signature verification checks the application, bundled runtimes, and nested framework executables for the expected team and hardened runtime after strict nested signature verification. Its parser reads the runtime flag from the `CodeDirectory` line emitted by `codesign`. `python3 -B scripts/test_distribution_signatures.py` tests the verifier with captured-format fixtures, including rejected teams, missing runtimes, failed strict verification, and misleading flag text. These fixtures do not prove a signed or notarized Perry artifact; that requires the release packaging workflow and a clean-Mac Gatekeeper check.

The feature-evidence validator currently rejects every `release-proven` promotion. A review reproduced acceptance of a 31-byte counterfeit executable with an arm64 header, a Perry plist, a matching hash, and an existing Git revision. Those fields establish neither a distribution signature nor a relationship between the executable and its declared source revision. Promotion must remain disabled until trusted signature and Gatekeeper checks and artifact-to-revision provenance are integrated; supplying additional self-declared JSON is insufficient.

The containment regression and release automation self-tests passed on 31 August 2026, recorded in `/tmp/perry-release-proven-containment.log`. The same run passed the eight signature-verifier fixtures and ten signing fixtures. The default registry remains at 68 features: 25 absent, 18 wired, 25 unit-tested, and none live-tested or release-proven. This is development-worktree containment evidence, not completion of M0 or M10.
