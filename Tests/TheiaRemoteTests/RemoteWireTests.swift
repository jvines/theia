import Foundation
import TheiaRemote
import XCTest

final class RemoteWireTests: XCTestCase {
    func testRemoteLocationKeepsSSHIdentityAndDecodedPath() throws {
        let url = try XCTUnwrap(URL(string: "ssh://jose@cluster.example:2222/data/science%20file.fits"))
        let location = try RemoteFileLocation(url: url)
        XCTAssertEqual(location.sshTarget, "jose@cluster.example")
        XCTAssertEqual(location.port, 2222)
        XCTAssertEqual(location.path, "/data/science file.fits")
        let literalPercent = try RemoteFileLocation(url: URL(
            string: "ssh://cluster.example/data/%252e%252e/file.fits"
        )!)
        XCTAssertEqual(literalPercent.path, "/data/%2e%2e/file.fits")
        XCTAssertThrowsError(try RemoteFileLocation(url: URL(string: "https://cluster.example/data.fits")!))
        XCTAssertThrowsError(try RemoteFileLocation(url: URL(string: "ssh://jose:password@cluster.example/data.fits")!))
    }

    func testHelperStreamsExactBinaryBytesAfterVersionedHeader() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("theia-remote-wire-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("shell ' ; bytes.fits")
        let bytes = Data([0, 10, 255, 0, 44, 128])
        try bytes.write(to: file)

        let request = Pipe()
        let response = Pipe()
        try request.fileHandleForWriting.write(contentsOf: RemoteWire.readRequest(path: file.path))
        try request.fileHandleForWriting.close()
        XCTAssertEqual(RemoteHelper.serve(input: request.fileHandleForReading,
                                          output: response.fileHandleForWriting), 0)
        try response.fileHandleForWriting.close()

        let header = try RemoteWire.readHeader(from: response.fileHandleForReading)
        XCTAssertEqual(header.version, 1)
        XCTAssertEqual(header.size, UInt64(bytes.count))
        XCTAssertNil(header.error)
        XCTAssertEqual(response.fileHandleForReading.readDataToEndOfFile(), bytes)
    }

    func testHelperRejectsDirectoryAndUnsupportedProtocolVersion() throws {
        let directory = FileManager.default.temporaryDirectory
        for requestLine in [
            RemoteWire.readRequest(path: directory.path),
            Data("{\"version\":2,\"operation\":\"read\",\"path\":\"/tmp/file.fits\"}\n".utf8),
        ] {
            let request = Pipe()
            let response = Pipe()
            try request.fileHandleForWriting.write(contentsOf: requestLine)
            try request.fileHandleForWriting.close()
            XCTAssertEqual(RemoteHelper.serve(input: request.fileHandleForReading,
                                              output: response.fileHandleForWriting), 1)
            try response.fileHandleForWriting.close()
            let header = try RemoteWire.readHeader(from: response.fileHandleForReading)
            XCTAssertEqual(header.version, 1)
            XCTAssertNil(header.size)
            XCTAssertNotNil(header.error)
            XCTAssertTrue(response.fileHandleForReading.readDataToEndOfFile().isEmpty)
        }
    }
}
