# Update rollout and rollback

Perry packages a release only when both the new signed DMG and the previous signed release are available. Packaging verifies both DMGs with Gatekeeper, generates the signed Sparkle appcast, records artifact hashes, and opens the new release at the `internal` ring.

Packaging requires a new output directory. The default is `build/distribution`; set `PERRY_RELEASE_OUTPUT_DIR` to another absolute path for a subsequent run. Existing directories, including empty directories and symlinks, are rejected rather than deleting earlier archives or staging files. The release automation tests exercise this reservation behavior; it does not establish signing or notarization readiness.

The legal order is `internal`, `beta`, `10`, `25`, `50`, then `100`. Promotion writes the current appcast only to the next ring feed. The command refuses skipped rings, changed artifacts, missing feeds, and promotion after rollback.

```sh
scripts/manage-update-rollout.py promote \
  --state build/distribution/rollout/rollout.json \
  --stage beta

scripts/manage-update-rollout.py verify \
  --state build/distribution/rollout/rollout.json
```

Rollback replaces every reached ring feed with the verified previous appcast, which stops additional installs of the withdrawn release. Sparkle does not downgrade Macs that already installed it. Unreached rings remain empty.

```sh
scripts/manage-update-rollout.py rollback \
  --state build/distribution/rollout/rollout.json
```

The deployment host must map each enrolled cohort to its matching `feeds/<ring>/appcast.xml` path and publish a feed only after `verify` succeeds. Perry does not yet have live evidence for that hosted cohort mapping, a signed promotion, or a rollback rehearsal.
