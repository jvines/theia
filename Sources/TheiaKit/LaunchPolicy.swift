/// Platform-independent choices for the first window and a later app reopen.
public enum LaunchPolicy {
    public static func initialWindow(
        hasSeenOnboarding: Bool, openDocumentCount: Int
    ) -> AppWindowKind? {
        if !hasSeenOnboarding { return .onboarding }
        return openDocumentCount == 0 ? .welcome : nil
    }

    public static func reopenWindow(
        hasVisibleWindows: Bool, openDocumentCount: Int
    ) -> AppWindowKind? {
        !hasVisibleWindows && openDocumentCount == 0 ? .welcome : nil
    }
}
