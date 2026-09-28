import CGtk4
import Foundation
import XCTest
@testable import TheiaGTK

final class GTKFileDropTargetTests: XCTestCase {
    @MainActor func testFileListExtractsLocalPathsForSharedOpenRoute() async {
        let first = g_file_new_for_path("/tmp/first.fits")!
        let second = g_file_new_for_path("/tmp/second.fit")!
        defer {
            g_object_unref(UnsafeMutableRawPointer(first))
            g_object_unref(UnsafeMutableRawPointer(second))
        }
        var files: [OpaquePointer?] = [first, second]
        let list = files.withUnsafeMutableBufferPointer {
            gdk_file_list_new_from_array($0.baseAddress, gsize($0.count))!
        }
        var value = GValue()
        g_value_init(&value, gdk_file_list_get_type())
        g_value_take_boxed(&value, UnsafeMutableRawPointer(list))
        defer { g_value_unset(&value) }

        XCTAssertEqual(GTKFileDropTarget.paths(from: &value),
                       ["/tmp/first.fits", "/tmp/second.fit"])
    }
}
