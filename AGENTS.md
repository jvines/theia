# Theia repository guidance

- Project 1 of the native Linux port is specified in `docs/superpowers/specs/2026-09-25-theia-shared-layer-design.md`. It is a local-only design document. Follow its migration order; do not commit the spec.
- Keep the Mac SwiftUI/AppKit shell and extract shared logic into Swift targets that compile with Swift 6.3.3 on AlmaLinux 8. No Linux UI belongs in Project 1.
- Add a regression test before each behavior fix. Switch the Mac app to the shared implementation in the same migration step.
- Run `swift test` and `scripts/smoke_test.sh` after each modular implementation commit. Run the neutral targets in the Linux container as the migration adds them.
- Preserve `NSToolbarItem` identifiers and toolbar autosave ID during command catalogue migration.
