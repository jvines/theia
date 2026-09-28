import Foundation
import XCTest
@testable import TheiaKit

#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

final class ScriptingSocketServerTests: XCTestCase {
    func testBindsIPv4LoopbackAndWritesPrivatePortFile() throws {
        let (directory, portFile) = try temporaryPortFile()
        defer { try? FileManager.default.removeItem(at: directory) }
        let server = ScriptingSocketServer(portFileURL: portFile, portRange: 0...0) { _ in
            ScriptingSocketReply(data: Data("ok".utf8))
        }
        defer { server.stop() }

        let port = try server.start()
        XCTAssertGreaterThan(port, 0)
        XCTAssertEqual(server.boundIPv4Address, "127.0.0.1")
        let contents = try String(contentsOf: portFile, encoding: .utf8)
        XCTAssertEqual(contents, "\(port)\n\(getpid())\n")
        let attributes = try FileManager.default.attributesOfItem(atPath: portFile.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }

    func testOccupiedListeningPortIsSkipped() throws {
        let (directory, portFile) = try temporaryPortFile()
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = ScriptingSocketServer(portFileURL: portFile, portRange: 0...0) { _ in
            ScriptingSocketReply(data: Data("first".utf8))
        }
        defer { first.stop() }
        let occupied = try first.start()
        let second = ScriptingSocketServer(
            portFileURL: directory.appendingPathComponent("second-port"),
            portRange: occupied...occupied
        ) { _ in ScriptingSocketReply(data: Data("second".utf8)) }
        defer { second.stop() }
        XCTAssertThrowsError(try second.start()) { error in
            guard case ScriptingSocketError.noAvailablePort = error else {
                return XCTFail("Expected occupied port to be skipped, got \(error)")
            }
        }
    }

    func testSlowReaderReceivesEntireLargeResponse() async throws {
        let (directory, portFile) = try temporaryPortFile()
        defer { try? FileManager.default.removeItem(at: directory) }
        let response = Data(repeating: 65, count: 2 * 1024 * 1024)
        let server = ScriptingSocketServer(portFileURL: portFile, portRange: 0...0) { _ in
            ScriptingSocketReply(data: response)
        }
        defer { server.stop() }
        let port = try server.start()

        let received = try await Task.detached {
            try Self.exchange(port: port, request: Data("GET /status HTTP/1.1\r\n\r\n".utf8),
                              readChunk: 1024, pauseMicroseconds: 500)
        }.value
        XCTAssertEqual(received, response)
    }

    func testEarlyClosingClientDoesNotBreakNextRequest() async throws {
        let (directory, portFile) = try temporaryPortFile()
        defer { try? FileManager.default.removeItem(at: directory) }
        let response = Data(repeating: 66, count: 512 * 1024)
        let server = ScriptingSocketServer(portFileURL: portFile, portRange: 0...0) { _ in
            ScriptingSocketReply(data: response)
        }
        defer { server.stop() }
        let port = try server.start()

        try await Task.detached {
            let fd = try Self.connectToLoopback(port: port)
            defer { close(fd) }
            try Self.sendAll(fd, Data("GET /status HTTP/1.1\r\n\r\n".utf8))
        }.value
        try await Task.sleep(nanoseconds: 50_000_000)

        let received = try await Task.detached {
            try Self.exchange(port: port, request: Data("GET /status HTTP/1.1\r\n\r\n".utf8),
                              readChunk: 4096, pauseMicroseconds: 0)
        }.value
        XCTAssertEqual(received, response)
    }

    func testWriteCompletionRunsAfterFullResponseIsSent() async throws {
        let (directory, portFile) = try temporaryPortFile()
        defer { try? FileManager.default.removeItem(at: directory) }
        let response = Data(repeating: 67, count: 2 * 1024 * 1024)
        let sent = expectation(description: "response fully sent")
        let server = ScriptingSocketServer(portFileURL: portFile, portRange: 0...0) { _ in
            ScriptingSocketReply(data: response, didSend: { sent.fulfill() })
        }
        defer { server.stop() }
        let port = try server.start()

        let received = try await Task.detached {
            try Self.exchange(port: port, request: Data("GET /status HTTP/1.1\r\n\r\n".utf8),
                              readChunk: 1024, pauseMicroseconds: 500)
        }.value
        XCTAssertEqual(received, response)
        await fulfillment(of: [sent], timeout: 5)
    }

    private func temporaryPortFile() throws -> (URL, URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("theia-socket-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return (directory, directory.appendingPathComponent("scripting-port"))
    }

    private static func exchange(port: UInt16, request: Data, readChunk: Int,
                                 pauseMicroseconds: useconds_t) throws -> Data {
        let fd = try connectToLoopback(port: port)
        defer { close(fd) }
        try sendAll(fd, request)
        var output = Data()
        var bytes = [UInt8](repeating: 0, count: readChunk)
        while true {
            let count = recv(fd, &bytes, bytes.count, 0)
            if count == 0 { return output }
            if count < 0 { throw POSIXTestError.operation("recv", errno) }
            output.append(contentsOf: bytes.prefix(count))
            if pauseMicroseconds > 0 { usleep(pauseMicroseconds) }
        }
    }

    private static func connectToLoopback(port: UInt16) throws -> Int32 {
        #if os(Linux)
        let fd = socket(AF_INET, Int32(SOCK_STREAM.rawValue), 0)
        #else
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        #endif
        guard fd >= 0 else { throw POSIXTestError.operation("socket", errno) }
        var timeout = timeval(tv_sec: 5, tv_usec: 0)
        _ = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout.size(ofValue: timeout)))
        var address = sockaddr_in()
        #if canImport(Darwin)
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        #endif
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard result == 0 else {
            let code = errno
            close(fd)
            throw POSIXTestError.operation("connect", code)
        }
        return fd
    }

    private static func sendAll(_ fd: Int32, _ data: Data) throws {
        try data.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return }
            var offset = 0
            while offset < bytes.count {
                #if os(Linux)
                let sent = send(fd, base.advanced(by: offset), bytes.count - offset, Int32(MSG_NOSIGNAL))
                #else
                let sent = send(fd, base.advanced(by: offset), bytes.count - offset, 0)
                #endif
                guard sent > 0 else { throw POSIXTestError.operation("send", errno) }
                offset += sent
            }
        }
    }
}

private enum POSIXTestError: Error {
    case operation(String, Int32)
}
