# Keychain erasure evidence

Owner: Perry privacy and persistence. Scope: provider credentials stored as generic-password items under `dev.perry.keys` and `dev.perry.integrations`.

The previous eraser listed known account names. `/tmp/perry-keychain-closed-world-red.log` and `Test-Perry-2026.08.31_23-34-09-+0100.xcresult` show that a second account under the same owned service remained invisible when it was absent from that list.

Perry now enumerates account attributes for each owned Keychain service without requesting secret data. It deletes each discovered account separately, continues to later accounts and services after a failure, then uses the existing post-erasure inventory to reject residual credentials. A service-enumeration failure also leaves the report incomplete while later services are still erased.

The focused erasure suite passed 15 tests in `/tmp/perry-keychain-service-final-focused.log`. PerryGuide passed 184 tests in `/tmp/perry-keychain-service-guide.log`. The app suite passed 325 tests with two permission-gated live-Cua tests skipped in `/tmp/perry-keychain-service-app.log`; its result bundle is `Test-Perry-2026.08.31_23-37-58-+0100.xcresult`. The unsigned Apple Silicon Release build passed in `/tmp/perry-keychain-service-release.log`.

These runs use the development target and isolated test services in the current dirty checkout. They do not prove erasure from a signed release on a clean Mac, deletion of telemetry already accepted by a hosted operator, or deletion of any future Keychain service until that service is added to Perry's owned-service set. Account deletion remains absent because Perry 1.0 has no hosted account.
