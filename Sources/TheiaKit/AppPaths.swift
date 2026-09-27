import Foundation

#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// Per-user storage locations shared by the macOS and Linux applications.
/// Creating the Linux runtime directory is explicit because it must be checked
/// before a token or port file can be placed there.
public struct AppPaths {
    public enum Platform {
        case macOS
        case linux

        public static var current: Platform {
            #if os(Linux)
            .linux
            #else
            .macOS
            #endif
        }
    }

    public enum RuntimeDirectoryError: Error {
        case creationFailed(URL, Int32)
        case insecureDirectory(URL)
    }

    public let platform: Platform
    public let sessionsDirectory: URL
    public let logFile: URL
    /// `nil` on macOS, where preferences remain in `UserDefaults`.
    public let preferencesFile: URL?
    /// Linux runtime directory before validation. Use `runtimeDirectory()`
    /// before storing files in it.
    public let runtimeDirectoryURL: URL?

    private let scriptingDirectory: URL
    private let usesRuntimeFallback: Bool

    public init(
        platform: Platform = .current,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        bundleIdentifier: String = Bundle.main.bundleIdentifier ?? "com.athropa.theia"
    ) {
        self.platform = platform
        switch platform {
        case .macOS:
            let support = homeDirectory.appendingPathComponent("Library/Application Support", isDirectory: true)
            sessionsDirectory = support.appendingPathComponent("Theia/sessions", isDirectory: true)
            logFile = homeDirectory.appendingPathComponent("Library/Logs/\(bundleIdentifier)/app.log")
            preferencesFile = nil
            runtimeDirectoryURL = nil
            scriptingDirectory = support.appendingPathComponent(bundleIdentifier, isDirectory: true)
            usesRuntimeFallback = false
        case .linux:
            let state = Self.xdgDirectory(environment["XDG_STATE_HOME"], fallback: homeDirectory.appendingPathComponent(".local/state", isDirectory: true))
            let config = Self.xdgDirectory(environment["XDG_CONFIG_HOME"], fallback: homeDirectory.appendingPathComponent(".config", isDirectory: true))
            sessionsDirectory = state.appendingPathComponent("theia/sessions", isDirectory: true)
            logFile = state.appendingPathComponent("theia/app.log")
            preferencesFile = config.appendingPathComponent("theia/preferences.json")
            let runtime: URL
            if let runtimeBase = Self.absoluteDirectory(environment["XDG_RUNTIME_DIR"]) {
                runtime = runtimeBase.appendingPathComponent("theia", isDirectory: true)
                usesRuntimeFallback = false
            } else {
                runtime = URL(fileURLWithPath: "/tmp/theia-\(getuid())", isDirectory: true)
                usesRuntimeFallback = true
            }
            runtimeDirectoryURL = runtime
            scriptingDirectory = runtime
        }
    }

    public func runtimeDirectory() throws -> URL {
        guard platform == .linux else { return scriptingDirectory }
        if usesRuntimeFallback {
            NSLog("[AppPaths] XDG_RUNTIME_DIR unavailable; using \(scriptingDirectory.path)")
        }
        try Self.ensurePrivateDirectory(at: scriptingDirectory, ownerID: getuid())
        return scriptingDirectory
    }

    public func tokenFile() throws -> URL {
        try runtimeDirectory().appendingPathComponent("scripting-token")
    }

    public func portFile() throws -> URL {
        try runtimeDirectory().appendingPathComponent("scripting-port")
    }

    private static func xdgDirectory(_ value: String?, fallback: URL) -> URL {
        absoluteDirectory(value) ?? fallback
    }

    private static func absoluteDirectory(_ value: String?) -> URL? {
        guard let value, !value.isEmpty, value.hasPrefix("/") else { return nil }
        return URL(fileURLWithPath: value, isDirectory: true)
    }

    /// `mkdir` is atomic and does not follow a final-component symlink. Existing
    /// directories are accepted only when owned by this user and exactly 0700.
    static func ensurePrivateDirectory(at url: URL, ownerID: uid_t) throws {
        let path = url.path
        if mkdir(path, mode_t(0o700)) != 0, errno != EEXIST {
            throw RuntimeDirectoryError.creationFailed(url, errno)
        }

        var info = stat()
        guard lstat(path, &info) == 0,
              info.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR),
              info.st_uid == ownerID,
              info.st_mode & mode_t(0o777) == mode_t(0o700) else {
            throw RuntimeDirectoryError.insecureDirectory(url)
        }
    }
}
