import AppKit
import XCTest
@testable import FITSViewerApp

@MainActor final class DocumentKeyEventMonitorTests: XCTestCase {
    func testSpaceRoutesOnlyToOwningWindowAndSkipsTextEditors() throws {
        let first = NSWindow(contentRect: .init(x: 0, y: 0, width: 100, height: 100),
                             styleMask: [.titled], backing: .buffered, defer: false)
        let second = NSWindow(contentRect: .init(x: 0, y: 0, width: 100, height: 100),
                              styleMask: [.titled], backing: .buffered, defer: false)
        let space = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: first.windowNumber, context: nil,
            characters: " ", charactersIgnoringModifiers: " ", isARepeat: false, keyCode: 49
        ))
        XCTAssertTrue(DocumentKeyEventMonitor.shouldRouteSpace(
            space, in: first, firstResponder: NSButton(frame: .zero)))
        XCTAssertFalse(DocumentKeyEventMonitor.shouldRouteSpace(
            space, in: second, firstResponder: NSButton(frame: .zero)))
        XCTAssertFalse(DocumentKeyEventMonitor.shouldRouteSpace(
            space, in: first, firstResponder: NSTextView(frame: .zero)))
    }
}
