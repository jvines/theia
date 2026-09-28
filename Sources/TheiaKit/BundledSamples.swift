import Foundation

public struct BundledSample: Sendable {
    public let title: String
    public let fileName: String
    public let url: URL
}

/// FITS examples included with installed Mac and Linux packages. Source-tree
/// discovery also keeps `swift run` useful during development.
public enum BundledSamples {
    private static let definitions: [(title: String, fileName: String)] = [
        ("Hubble NICMOS image", "nicmos_mosaic.fits"),
        ("Hubble WFPC2 cube", "wfpc2_cube.fits"),
        ("Hubble FOS spectrum and table", "fos_bintable.fits"),
        ("FEROS Tau Ceti echelle spectrum", "feros_tau_ceti_20240730.fits"),
    ]

    public static func available(in directory: URL) -> [BundledSample] {
        definitions.compactMap { definition in
            let url = directory.appendingPathComponent(definition.fileName)
            guard FileManager.default.fileExists(atPath: url.path) else { return nil }
            return BundledSample(title: definition.title,
                                 fileName: definition.fileName, url: url)
        }
    }

    public static func discover() -> [BundledSample] {
        let executable = Bundle.main.executableURL?.deletingLastPathComponent()
        let directories = [
            Bundle.main.resourceURL?.appendingPathComponent("samples"),
            executable?.deletingLastPathComponent()
                .appendingPathComponent("share/theia/samples"),
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent("resources/samples"),
        ].compactMap { $0 }
        for directory in directories {
            let samples = available(in: directory)
            if !samples.isEmpty { return samples }
        }
        return []
    }
}
