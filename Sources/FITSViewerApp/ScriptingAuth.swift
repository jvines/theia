import Foundation
import CryptoKit
import TheiaKit

/// Random per-install bearer token used to gate the localhost HTTP scripting
/// server. Written once on first launch to
/// `~/Library/Application Support/<bundle>/scripting-token` with 0600 permissions
/// so only the current macOS user can read it. Scripts read that file to find
/// the token, then send it as `Authorization: Bearer <hex>`.
@MainActor
enum ScriptingAuth {
    private static var cachedToken: String?

    /// Lazily generates (or loads) the token. 32 random bytes hex-encoded → 64 chars.
    static func tokenHex() -> String {
        if let t = cachedToken { return t }
        let url = tokenURL()
        if let existing = try? String(contentsOf: url, encoding: .utf8) {
            let trimmed = existing.trimmingCharacters(in: .whitespacesAndNewlines)
            if isWellFormed(trimmed) {
                cachedToken = trimmed
                return trimmed
            }
        }
        let bytes = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
        let hex = bytes.map { String(format: "%02x", $0) }.joined()
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        do {
            try hex.write(to: url, atomically: true, encoding: .utf8)
            // Restrict to owner-only read/write.
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch {
            NSLog("[ScriptingAuth] couldn't persist token to \(url.path): \(error)")
        }
        cachedToken = hex
        return hex
    }

    /// Path to the token file — also useful for the in-app help so users can find it.
    static func tokenURL() -> URL {
        // This target is macOS-only, so AppPaths.tokenFile() cannot throw here.
        try! AppPaths(platform: .macOS).tokenFile()
    }

    /// Check an `Authorization: Bearer <token>` header against the live token in
    /// constant time. Returns true only if the header is well-formed and matches.
    static func authorise(headerValue: String?) -> Bool {
        guard let raw = headerValue?.trimmingCharacters(in: .whitespaces),
              raw.lowercased().hasPrefix("bearer ") else { return false }
        let supplied = raw.dropFirst("bearer ".count).trimmingCharacters(in: .whitespaces)
        return constantTimeEquals(supplied, tokenHex())
    }

    private static func isWellFormed(_ s: String) -> Bool {
        s.count == 64 && s.allSatisfy { c in "0123456789abcdef".contains(c) }
    }

    /// Length-stable comparison to avoid timing side-channels on token equality.
    private static func constantTimeEquals(_ a: String, _ b: String) -> Bool {
        let aBytes = Array(a.utf8), bBytes = Array(b.utf8)
        guard aBytes.count == bBytes.count else { return false }
        var diff: UInt8 = 0
        for i in 0..<aBytes.count { diff |= aBytes[i] ^ bBytes[i] }
        return diff == 0
    }
}
