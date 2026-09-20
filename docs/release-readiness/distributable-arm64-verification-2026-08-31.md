# Apple Silicon distributable verification

Owner: Release Engineering. Scope: M10 unsigned release construction. Environment: Apple Silicon macOS, Xcode 26.6, dirty development checkout. This evidence does not prove signing, notarization, Gatekeeper acceptance, update installation, rollback, or clean-checkout reproducibility.

The first full release verification failed because the unstripped 17,165,304-byte Perry executable exceeded the 16 MiB release budget. The verifier now builds the same deployment-postprocessed product shape used by packaging and asserts `DEPLOYMENT_POSTPROCESSING=YES` and `STRIP_INSTALLED_PRODUCT=YES`. The resulting executable is 8,160,760 bytes. The failing run is retained at `/tmp/perry-m10-verify-release-red.log` and the passing run at `/tmp/perry-m10-verify-release-green.log`.

Inspection also found that the pinned Cua archive contained a universal executable even though its asset is named `darwin-arm64`. Acquisition now verifies the upstream archive member and Cua AI signature, derives the arm64 slice, then verifies the distribution hash, exact architecture, signing identifier, and signing team. The distribution binary is 30,073,760 bytes with SHA256 `c8343fb4ce61af8091bd3a08d8c6c812b5b45488f78a72d110685e5eb2b80cc9`, identifier `cua-driver`, and team `YCK386LBJ7`.

The verified unsigned app occupies 229,764 KiB. Its Perry, Codex, and Cua executables are arm64-only; their sizes are 8,160,760, 193,804,960, and 30,073,760 bytes. Bundle-content tests prove that a universal Cua fixture is rejected. Cua acquisition tests cover wrong-team rejection and derived-binary validation. The release automation suite passed eight distribution-signature fixtures, ten signing fixtures, rollout checks, metadata checks, and bundle checks in `/tmp/perry-m10-release-automation-rerun.log`.

No Developer ID Application identity or release credentials were available on this machine. The result is a credential-free unsigned distributable check, not a Perry 1.0 release candidate.

## Independent gauntlet follow-up

An independent verifier repeated Cua acquisition, bundle-content, release-automation, metadata, manifest, and evidence checks on 1 September 2026. Those checks passed. Its fresh unsigned build stopped before compilation when Sentry artifact extraction exhausted the disk; direct inspection of the prior derived app reproduced the arm64 architectures, sizes, Cua hash, and Cua signing identity above. The enclosing unsigned app correctly failed strict code-signing and Gatekeeper checks.

The independent critic found release-boundary defects after the first green run. The Cua capability manifest is now visible to Git and included in the 12-entry artifact manifest; a mutation regression proves policy changes invalidate verification. Rollout state owns relative immutable copies of both releases and survives relocation. Appcast validation now binds version, build, DMG filename, byte length, and signature presence before rollout changes. Signed packaging additionally invokes Sparkle's `sign_update --verify` against the current and previous DMGs before it creates rollout state. XcodeGen is now an SBOM and license component, and Sparkle public-key parsing rejects malformed base64 instead of trusting a pipeline byte count.

The post-critic release automation run passed eight distribution-signature tests, ten signing tests, four public-key tests, three Sparkle release-verification tests, rollout checks, bundle checks, metadata checks, and negative paths in `/tmp/perry-m10-release-automation-appcast-crypto-rerun.log`. The live Sparkle signature path still requires the unavailable release key and signed current and previous DMGs, so this hardening does not change the release-proof status.
