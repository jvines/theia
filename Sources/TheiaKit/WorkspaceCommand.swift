import Foundation
import Observation

public enum HelpDestination: Sendable, Equatable {
    case documentation
    case source
    case reportIssue

    public var url: URL {
        switch self {
        case .documentation: URL(string: "https://jvines.cl/fitsviewer")!
        case .source: URL(string: "https://github.com/jvines/fitsviewer")!
        case .reportIssue: URL(string: "https://github.com/jvines/fitsviewer/issues/new")!
        }
    }
}

public enum WorkspaceCommand: Sendable {
    case showAppWindow(AppWindowKind)
    case openHelp(HelpDestination)
    case setSyncFlag(SyncFlag, Bool)
    case tileWindows
    case quit
}

public enum SyncFlag: String, CaseIterable, Hashable, Sendable {
    case zoomPan
    case scale
    case colormap
    case crosshair
}

/// App-level command dispatcher. Document registration and cross-document state
/// join this type as those migration steps move out of the Mac shell.
@MainActor @Observable public final class Workspace {
    private var enabledSyncFlags: Set<SyncFlag> = []

    public init() {}

    public func syncEnabled(_ flag: SyncFlag) -> Bool {
        enabledSyncFlags.contains(flag)
    }

    @discardableResult public func perform(
        _ command: WorkspaceCommand, origin: CommandOrigin
    ) -> CommandOutcome {
        switch command {
        case .showAppWindow(let window):
            guard origin == .user else {
                return CommandOutcome(failure: .requiresUserInterface)
            }
            return CommandOutcome(effects: [.showAppWindow(window)])
        case .openHelp(let destination):
            guard origin == .user else {
                return CommandOutcome(failure: .requiresUserInterface)
            }
            return CommandOutcome(effects: [.openURL(destination.url)])
        case .setSyncFlag(let flag, let enabled):
            if enabled { enabledSyncFlags.insert(flag) }
            else { enabledSyncFlags.remove(flag) }
            return CommandOutcome()
        case .tileWindows:
            return CommandOutcome(effects: [.tileWindows])
        case .quit:
            return CommandOutcome(effects: [.quit])
        }
    }
}
