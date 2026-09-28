import Foundation
import TheiaRemote
import XCTest

final class SSHRemoteFileClientTests: XCTestCase {
    func testRealSSHHelperWhenConfigured() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let locationString = environment["THEIA_REMOTE_TEST_URL"],
              let fixture = environment["THEIA_REMOTE_TEST_FIXTURE"] else {
            throw XCTSkip("Requires an ephemeral SSH helper test server")
        }
        let location = try RemoteFileLocation(url: XCTUnwrap(URL(string: locationString)))
        XCTAssertEqual(try SSHRemoteFileClient().read(location),
                       try Data(contentsOf: URL(fileURLWithPath: fixture)))
    }

    func testSSHClientKeepsPathOutOfCommandAndReadsBinaryResponse() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("theia-ssh-client-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let script = directory.appendingPathComponent("fake-ssh")
        let arguments = directory.appendingPathComponent("arguments")
        let request = directory.appendingPathComponent("request")
        try Data("""
        #!/bin/sh
        printf '%s\\n' "$@" > "$THEIA_TEST_ARGUMENTS"
        cat > "$THEIA_TEST_REQUEST"
        printf '{"version":1,"size":4,"error":null}\\n'
        printf '\\000\\012\\377\\200'
        """.utf8).write(to: script)
        try FileManager.default.setAttributes([.posixPermissions: 0o755],
                                              ofItemAtPath: script.path)
        var environment = ProcessInfo.processInfo.environment
        environment["THEIA_TEST_ARGUMENTS"] = arguments.path
        environment["THEIA_TEST_REQUEST"] = request.path
        let client = SSHRemoteFileClient(executableURL: script, environment: environment)
        let location = try RemoteFileLocation(url: URL(
            string: "ssh://jose@cluster.example:2222/data/shell%20'%3B%20touch%20bad.fits"
        )!)

        XCTAssertEqual(try client.read(location), Data([0, 10, 255, 128]))
        let options = try String(contentsOf: arguments, encoding: .utf8)
            .split(separator: "\n").map(String.init)
        XCTAssertEqual(options, ["-T", "-o", "BatchMode=yes", "-o",
                                 "StrictHostKeyChecking=yes", "-p", "2222", "--",
                                 "jose@cluster.example", "~/.local/bin/theia-remote-helper"])
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(
            with: Data(contentsOf: request)
        ) as? [String: Any])
        XCTAssertEqual(payload["path"] as? String, location.path)
        XCTAssertEqual(payload["operation"] as? String, "read")
        XCTAssertEqual(payload["version"] as? Int, 1)
    }

    func testSSHClientReportsHelperErrorWithoutTreatingItAsFileBytes() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("theia-ssh-error-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let script = directory.appendingPathComponent("fake-ssh")
        try Data("""
        #!/bin/sh
        cat >/dev/null
        printf '{"version":1,"size":null,"error":"File is unreadable"}\\n'
        exit 1
        """.utf8).write(to: script)
        try FileManager.default.setAttributes([.posixPermissions: 0o755],
                                              ofItemAtPath: script.path)
        let client = SSHRemoteFileClient(executableURL: script)
        let location = try RemoteFileLocation(url: URL(string: "ssh://cluster.example/data.fits")!)
        XCTAssertThrowsError(try client.read(location)) { error in
            XCTAssertTrue(error.localizedDescription.contains("File is unreadable"))
        }
    }

    func testCancellationStopsAnInFlightSSHTransfer() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("theia-ssh-cancel-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let script = directory.appendingPathComponent("fake-ssh")
        let ready = directory.appendingPathComponent("ready")
        try Data("#!/bin/sh\ncat >/dev/null\ntouch \"$THEIA_TEST_READY\"\nexec sleep 10\n".utf8)
            .write(to: script)
        try FileManager.default.setAttributes([.posixPermissions: 0o755],
                                              ofItemAtPath: script.path)
        var environment = ProcessInfo.processInfo.environment
        environment["THEIA_TEST_READY"] = ready.path
        let client = SSHRemoteFileClient(executableURL: script, environment: environment)
        let location = try RemoteFileLocation(url: URL(string: "ssh://cluster.example/data.fits")!)
        let task = Task.detached { try await client.readAsync(location) }
        let deadline = Date().addingTimeInterval(3)
        while !FileManager.default.fileExists(atPath: ready.path) && Date() < deadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: ready.path))
        let cancellationTime = Date()
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {
            XCTAssertLessThan(Date().timeIntervalSince(cancellationTime), 2)
        }
    }
}
