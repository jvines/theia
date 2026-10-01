import Foundation

/// FITS data that arrived through a pipe (`xpaset ds9 fits < image.fits`)
/// rather than from a file. Each image is shown under its own `stdin:` URL,
/// titled "stdin" as DS9 titles it, and is neither remembered as a recent
/// location nor given a saved session.
public enum PipedFITS {
    public static let scheme = "stdin"

    @MainActor private static var count = 0

    /// A URL no other open document uses, so each pipe loads afresh.
    @MainActor public static func nextURL() -> URL {
        count += 1
        return URL(string: "\(scheme):///\(count)/stdin")!
    }

    public static func isPiped(_ url: URL) -> Bool { url.scheme == scheme }

    /// True when the bytes start like a FITS primary header.
    public static func isFITS(_ data: Data) -> Bool {
        data.starts(with: Data("SIMPLE  =".utf8))
    }

    /// What `xpaget file` reports: "stdin" for piped data, else the path.
    public static func displayPath(for url: URL) -> String {
        isPiped(url) ? "stdin" : url.path
    }
}
