# Theia

Theia is a native macOS and Linux viewer for FITS (Flexible Image Transport System) files, built for working astronomers.

## Status

Core viewing, multi-extension navigation, WCS, regions, catalogs, photometry, profiles, and blink are all built and covered by an extensive unit-test suite plus an integration smoke test. Actively developed.

## Features

- **Viewing**: pan/zoom, stretches (linear, log, sqrt, asinh, power, histogram eq), zscale default range, colormaps, scale-parameter editor
- **Multi-extension**: MEF navigation, image cubes with plane control, ASCII and binary table HDUs
- **Tile-compressed FITS** (`.fz`): RICE/GZIP/HCOMPRESS read transparently via a vendored CFITSIO
- **WCS**: TAN/SIN/ZEA/STG/CAR/MER/AIT/MOL projections with SIP distortion; coordinate readout selectable between ICRS / FK5 / FK4 / galactic / ecliptic; grid overlay, reprojection, compass + scale bar
- **Regions**: circle, box, polygon, annulus; interactive editing; `.reg` file read/write
- **Analysis**: aperture photometry, source extraction, radial/box profiles, contours, Gaussian fitting, image statistics, pixel table, PV diagrams, light curves
- **Catalogs**: cone-search overlay (Gaia / Vizier)
- **Blink**: multi-frame blink for difference imaging
- **Export**: PNG/TIFF image export, MPEG export, save as FITS
- **Scripting**: local HTTP server (`/status`, `/open`, `/document/...`, `/quit`) with token auth
- **XPA scripting**: registers `DS9:ds9` and `DS9:fitsviewer` access points (vendored libxpa), so `xpaget`/`xpaset` (and pyds9 against those commands) can drive it. Implemented subset: `file`/`fits`, `scale`, `cmap`, `regions`, `zscale`, `frame`, `version`, `exit`. Not a full DS9 XPA reimplementation.

## Layout

- `Sources/FITSCore/` — pure logic: FITS parsing, header model, tables, stretches, WCS, photometry, regions (no UI)
- `Sources/FITSRender/` — Metal-backed rendering, shaders, overlays, image/movie export
- `Sources/FITSViewerApp/` — SwiftUI/AppKit app shell, document windows, toolbar, analysis panels, scripting server
- `Tests/` — `FITSCoreTests` (logic) and `FITSRenderTests`
- `scripts/` — fixtures, icon, and packaging

## Building

On macOS, open `Package.swift` in Xcode 15.4+ and run the `Theia` scheme.

Command-line build (requires Xcode toolchain on macOS):

```bash
swift build
swift test
```

Test data lives outside the repo; fetch it with `scripts/fetch_test_data.sh`. Unit-test fixtures are committed under `Tests/FITSCoreTests/Fixtures/`.

### Linux

The Linux build uses the pinned AlmaLinux 8, Swift 6.3.3, and GTK4 toolchain in
`ci/Dockerfile.almalinux8-swift63` and `ci/Dockerfile.almalinux8-gtk4`. The CI job
builds and tests the app, creates a relocatable tarball and AppImage, then runs
both on a clean AlmaLinux 8 image without the build toolchain.

Extract `Theia-<version>-linux-<architecture>.tar.xz` and run its `bin/theia`
launcher, or make the matching `.AppImage` executable and run it directly. The
archive includes the GTK runtime, FITS desktop integration, fallback fonts,
XPA tools, and FFmpeg for MP4 export. CI verifies the package under Xvfb on
AlmaLinux 8. The AppImage can use `APPIMAGE_EXTRACT_AND_RUN=1` when FUSE is
unavailable.

The Arch `theia-fits-bin` recipe is generated from release archive hashes; see
the [AUR packaging instructions](packaging/aur/README.md).

## Design notes

- **FITS parsing**: pure Swift for uncompressed data (`BITPIX` 8/16/32/-32/-64, BSCALE/BZERO, multi-HDU). Tile-compressed (`.fz`) images are decompressed by a vendored, statically-linked CFITSIO 4.6.4 (`Sources/CFITSIO/`) and swapped in as native image HDUs at parse time, so the rest of the pipeline never sees compression.
- **Rendering**: the Mac app uses Metal shaders; the Linux app rasterizes on the CPU and presents a `GdkMemoryTexture`. Both use the shared stretch and colormap logic.
- **WCS**: pure-Swift implementation of common projections (TAN/SIN/ZEA/STG/CAR/MER/AIT/MOL) plus SIP distortion, rather than bridging WCSlib.
- **Toolchain**: `swift-tools-version:5.10`; macOS 14+ or the pinned AlmaLinux 8 / Swift 6.3.3 / GTK4 Linux build image.
- **Distribution**: free; notarized DMG on macOS and relocatable tarball and AppImage on Linux.

## License

Theia is released under the [BSD 3-Clause License](LICENSE) — the permissive license used across the scientific-Python / astronomy ecosystem (astropy, NumPy, SciPy).

It bundles CFITSIO (NASA/HEASARC, public-domain-permissive), XPA (SAO, MIT), and
additional Linux package components; see [THIRD-PARTY-NOTICES.md](THIRD-PARTY-NOTICES.md).
