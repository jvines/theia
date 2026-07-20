import AppKit

/// An NSMenuItem that owns the Swift closure it fires. The closure lives as a
/// regular stored property on the subclass — no `objc_setAssociatedObject`
/// dance and no chance the target gets deallocated out from under the menu.
final class ClosureMenuItem: NSMenuItem {
    private let _action: () -> Void

    init(title: String, action: @escaping () -> Void) {
        self._action = action
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        self.target = self
    }

    required init(coder: NSCoder) { fatalError("init(coder:) not supported") }

    @objc private func fire() { _action() }
}

// (RegionMenuClosureTarget / RegionMenuTarget removed — closure delivery is now
// handled by ClosureMenuItem above.)
