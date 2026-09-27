import AppKit
import XCTest
@testable import FITSViewerApp

@MainActor final class ViewMenuFocusTests: XCTestCase {
    func testChildPanelResolvesItsDocumentWindow() {
        let document = NSWindow(contentRect: .init(x: 0, y: 0, width: 100, height: 100),
                                styleMask: [.titled], backing: .buffered, defer: false)
        let panel = NSPanel(contentRect: .init(x: 0, y: 0, width: 50, height: 50),
                            styleMask: [.titled], backing: .buffered, defer: false)
        document.addChildWindow(panel, ordered: .above)
        XCTAssertTrue(ViewMenuFocus.documentWindow(key: panel, main: nil,
                                                    documents: [document]) === document)
    }

    func testUnattachedPanelUsesMainDocumentWindow() {
        let document = NSWindow(contentRect: .init(x: 0, y: 0, width: 100, height: 100),
                                styleMask: [.titled], backing: .buffered, defer: false)
        let panel = NSPanel(contentRect: .init(x: 0, y: 0, width: 50, height: 50),
                            styleMask: [.titled], backing: .buffered, defer: false)
        XCTAssertTrue(ViewMenuFocus.documentWindow(key: panel, main: document,
                                                    documents: [document]) === document)
        XCTAssertNil(ViewMenuFocus.documentWindow(key: panel, main: nil,
                                                  documents: [document]))
    }
}
