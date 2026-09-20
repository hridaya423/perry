# Live UI automation, 2026-08-30

Perry has a separate native macOS UI-test target for Settings and onboarding. The target launches Debug builds directly into either surface. Settings coverage inspects the accessibility tree, verifies all seven categories, opens Integrations and Appearance, and checks disabled-state behavior under default and accessibility appearance preferences. Onboarding coverage uses deterministic denied-permission and available-runtime fixtures, then verifies progress, navigation, recovery controls, and the permission gate without opening a real TCC prompt.

The target and runner build successfully on arm64 macOS. Live execution did not begin on this host because Xcode could not materialize its UI-test worker, with or without ad-hoc signing. Settings was stopped after 41 seconds; the isolated onboarding test reproduced the same host failure and was stopped after 31 seconds. This is infrastructure evidence, not a passed live test, and it does not close the M7 accessibility or M8 onboarding gates.

The `PerryUI` scheme is separate from the unit-test scheme so a host-level automation failure cannot stall logic tests. CI runs the UI scheme in its own 15-minute job. A green hosted run or a controlled test-account run is still required before the checked flows count as live-tested.
