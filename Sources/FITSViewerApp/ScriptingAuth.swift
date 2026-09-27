import Foundation
import TheiaKit

/// Mac path and cache for the shared scripting token store.
@MainActor
enum ScriptingAuth {
    private static var cachedToken: String?

    static func tokenHex() -> String {
        if let cachedToken { return cachedToken }
        do {
            let token = try ScriptingTokenStore(url: tokenURL()).loadOrCreate()
            cachedToken = token
            return token
        } catch {
            NSLog("[ScriptingAuth] scripting token unavailable: \(error)")
            return ""
        }
    }

    static func tokenURL() -> URL {
        // The Mac path cannot fail; Linux validates its runtime directory first.
        try! AppPaths(platform: .macOS).tokenFile()
    }

    static func authorise(headerValue: String?) -> Bool {
        let token = tokenHex()
        guard !token.isEmpty else { return false }
        return ScriptingTokenStore.authorise(headerValue: headerValue, token: token)
    }
}
