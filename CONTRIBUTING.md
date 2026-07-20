# Contributing to Theia

Thanks for your interest! Theia is a native macOS FITS viewer built for working
astronomers. Contributions — bug reports, fixes, and features — are welcome.

## Building & testing

Requires the Xcode toolchain on macOS 14+.

```bash
swift build
swift test                 # unit tests (FITSCore / FITSRender)
scripts/smoke_test.sh      # launches the app + XPA and drives the scripting API
```

Unit-test fixtures live under `Tests/FITSCoreTests/Fixtures/`. Larger real-file
test data is not committed.

## Ground rules

- **Add a test with your change.** For a bug fix, add a failing test that
  reproduces it first; for a feature, cover the new behavior. Keep the suite green.
- **`Sources/FITSCore`** is pure logic (parsing, WCS, stretches, photometry,
  regions) with no UI — keep it that way so it stays easy to test.
- Match the surrounding style; keep changes focused and well-described.
- App-shell and scripting changes should also pass `scripts/smoke_test.sh`.

## License

By contributing, you agree that your contributions are licensed under the project's
[BSD 3-Clause License](LICENSE).
