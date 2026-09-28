import FITSCore
import Foundation
import TheiaKit
import XCTest
@testable import TheiaGTK

final class GTKCubeVideoExportTests: XCTestCase {
    @MainActor private func cubeSnapshot() throws -> CubeRenderSnapshot {
        let cards = [
            "SIMPLE  =                    T", "BITPIX  =                    8",
            "NAXIS   =                    3", "NAXIS1  =                    1",
            "NAXIS2  =                    1", "NAXIS3  =                    3", "END",
        ]
        let text = cards.map { $0.padding(toLength: 80, withPad: " ", startingAt: 0) }.joined()
        var data = Data((text + String(repeating: " ", count: 2880 - text.utf8.count)).utf8)
        data.append(contentsOf: [2, 3, 5])
        data.append(Data(repeating: 0, count: 2880 - 3))
        let session = DocumentSession(url: URL(fileURLWithPath: "/tmp/theia-video-cube.fits"),
                                      file: try FITSFile(data: data))
        session.view.vmin = 0
        session.view.vmax = 6
        let outcome = session.perform(.exportCube, origin: .user)
        guard let effect = outcome.effects.first,
              case .ask(_, let request) = effect,
              case .exportCube(let snapshot) = request else {
            throw NSError(domain: "TheiaVideoTest", code: 1)
        }
        return snapshot
    }

    @MainActor func testStreamsEveryCubePlaneToEncoderAndReplacesOutputOnlyOnSuccess() async throws {
        let snapshot = try cubeSnapshot()
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(
            "theia-video-test-\(UUID().uuidString)", isDirectory: true
        )
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let encoder = folder.appendingPathComponent("fake-ffmpeg")
        let capture = folder.appendingPathComponent("frames.rgba")
        let arguments = folder.appendingPathComponent("arguments.txt")
        let output = folder.appendingPathComponent("cube.mp4")
        let script = """
        #!/bin/sh
        cat > '\(capture.path)'
        printf '%s\n' "$@" > '\(arguments.path)'
        for last do :; done
        printf 'encoded' > "$last"
        """
        try script.write(to: encoder, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: encoder.path)
        try GTKCubeVideoExport.write(snapshot, to: output, encoder: encoder)
        XCTAssertEqual(try Data(contentsOf: output), Data("encoded".utf8))
        let pixels = try Data(contentsOf: capture)
        XCTAssertEqual(pixels.count, 3 * 4)
        XCTAssertEqual([pixels[3], pixels[7], pixels[11]], [255, 255, 255])
        let options = try String(contentsOf: arguments, encoding: .utf8)
        XCTAssertTrue(options.contains("rawvideo\n"))
        XCTAssertTrue(options.contains("rgba\n"))
        XCTAssertTrue(options.contains("1x1\n"))
        XCTAssertTrue(options.contains("libx264\n"))
        XCTAssertTrue(options.contains("yuv420p\n"))

        try "#!/bin/sh\nexit 42\n".write(to: encoder, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: encoder.path)
        XCTAssertThrowsError(try GTKCubeVideoExport.write(snapshot, to: output, encoder: encoder))
        XCTAssertEqual(try Data(contentsOf: output), Data("encoded".utf8))
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: folder.path)
        XCTAssertFalse(leftovers.contains { $0.contains(".theia-") })
    }

    @MainActor func testRealH264ExportDecodesAllPlanes() async throws {
        guard let path = ProcessInfo.processInfo.environment["THEIA_TEST_FFMPEG"],
              FileManager.default.isExecutableFile(atPath: path) else {
            throw XCTSkip("Set THEIA_TEST_FFMPEG to a static FFmpeg build")
        }
        let snapshot = try cubeSnapshot()
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(
            "theia-h264-test-\(UUID().uuidString)", isDirectory: true
        )
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let output = folder.appendingPathComponent("cube.mp4")
        try GTKCubeVideoExport.write(snapshot, to: output, encoder: URL(fileURLWithPath: path))

        let decoder = Process()
        decoder.executableURL = URL(fileURLWithPath: path)
        decoder.arguments = ["-hide_banner", "-loglevel", "error", "-i", output.path,
                             "-f", "rawvideo", "-pix_fmt", "rgba", "pipe:1"]
        let decoded = Pipe()
        decoder.standardOutput = decoded
        decoder.standardError = FileHandle.nullDevice
        try decoder.run()
        let frames = decoded.fileHandleForReading.readDataToEndOfFile()
        decoder.waitUntilExit()
        XCTAssertEqual(decoder.terminationStatus, 0)
        guard frames.count == 2 * 2 * 4 * 3 else {
            return XCTFail("Expected three decoded 2×2 RGBA frames, got \(frames.count) bytes")
        }
        XCTAssertLessThan(frames[0], frames[16])
        XCTAssertLessThan(frames[16], frames[32])
        XCTAssertEqual([frames[3], frames[19], frames[35]], [255, 255, 255])
    }
}
