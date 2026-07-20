// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "Theia",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Theia", targets: ["FITSViewerApp"]),
        .library(name: "FITSCore", targets: ["FITSCore"]),
        .library(name: "FITSRender", targets: ["FITSRender"]),
    ],
    dependencies: [],
    targets: [
        .executableTarget(
            name: "FITSViewerApp",
            dependencies: ["FITSCore", "FITSRender", "XPABridge"],
            path: "Sources/FITSViewerApp"
        ),
        // Vendored CFITSIO 4.6.4 (HEASARC/NASA) compiled as a static C target.
        // Fortran wrappers, network/GSI/shared-mem drivers, and platform utilities
        // are not vendored. Network/bzip2 code paths compile out (their HAVE_* macros
        // are left undefined). Only system zlib is linked.
        .target(
            name: "CFITSIO",
            path: "Sources/CFITSIO",
            publicHeadersPath: "include",
            cSettings: [
                // CFITSIO's POSIX feature detection keys off macros its ./configure
                // would set. Apple clang defines none of unix/__unix__, so set the
                // ones true on macOS explicitly (these gate <unistd.h>, ftruncate, …).
                .define("HAVE_UNISTD_H"),
                .define("HAVE_FTRUNCATE"),
                // Third-party C: silence its (many) warnings so they don't drown our own.
                .unsafeFlags(["-w"])
            ],
            linkerSettings: [.linkedLibrary("z")]
        ),
        // Vendored libxpa 2.1.20 (SAO, MIT) compiled as a static C target — the
        // XPA IPC library DS9 uses, so xpaget/xpaset and pyds9 can drive the app.
        // Only the BASE_OBJS core is vendored (no tcl/xt/gtk loops, CLI tools, or
        // the xpans name server). conf.h is hand-authored for macOS.
        .target(
            name: "CXPA",
            path: "Sources/CXPA",
            publicHeadersPath: "include",
            cSettings: [
                .define("HAVE_CONFIG_H"),
                .headerSearchPath("include"),
                .unsafeFlags(["-w"])
            ]
        ),
        // Swift surface over libxpa: registers DS9-compatible access points and
        // dispatches get/set commands to a host-provided handler. Kept out of
        // FITSCore (this is app IPC, not FITS logic) and unit-testable in isolation.
        .target(
            name: "XPABridge",
            dependencies: ["CXPA"],
            path: "Sources/XPABridge"
        ),
        // XPA command-line tools + name server, built from the vendored libxpa
        // sources. `xpans` is bundled in the app so libxpa can spawn it for name
        // registration; xpaget/xpaset are used by the smoke test (and are handy
        // for users who don't already have the XPA tools installed).
        .executableTarget(
            name: "xpans", dependencies: ["CXPA"], path: "Sources/xpans",
            cSettings: [.define("HAVE_CONFIG_H"), .unsafeFlags(["-w"])]
        ),
        .executableTarget(
            name: "xpaget", dependencies: ["CXPA"], path: "Sources/xpaget",
            cSettings: [.define("HAVE_CONFIG_H"), .unsafeFlags(["-w"])]
        ),
        .executableTarget(
            name: "xpaset", dependencies: ["CXPA"], path: "Sources/xpaset",
            cSettings: [.define("HAVE_CONFIG_H"), .unsafeFlags(["-w"])]
        ),
        .target(
            name: "FITSCore",
            dependencies: ["CFITSIO"],
            path: "Sources/FITSCore"
        ),
        .target(
            name: "FITSRender",
            dependencies: ["FITSCore"],
            path: "Sources/FITSRender",
            resources: [.copy("Shaders.metal")]
        ),
        .testTarget(
            name: "FITSCoreTests",
            dependencies: ["FITSCore"],
            path: "Tests/FITSCoreTests",
            resources: [.copy("Fixtures")]
        ),
        .testTarget(
            name: "FITSRenderTests",
            dependencies: ["FITSRender"],
            path: "Tests/FITSRenderTests"
        ),
        .testTarget(
            name: "XPABridgeTests",
            dependencies: ["XPABridge"],
            path: "Tests/XPABridgeTests"
        ),
    ]
)
