import CTheiaCurl
import FITSCore
import Foundation

private final class CurlCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }
}

private struct CurlTransportError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// EL8's system libcurl transport; keeps FoundationNetworking out of the process.
struct CurlCatalogTransport: CatalogTransport {
    func get(_ url: URL, timeout: TimeInterval) async throws -> CatalogHTTPResponse {
        let cancellation = CurlCancellation()
        let timeoutMs = timeout.isFinite
            ? Int64(min(2_147_483_647, max(1, timeout * 1_000))) : 30_000
        return try await withTaskCancellationHandler {
            try await Task.detached(priority: .userInitiated) {
                var body: UnsafeMutablePointer<UInt8>?
                var length = 0
                var status: Int = 0
                let context = Unmanaged.passRetained(cancellation).toOpaque()
                defer { Unmanaged<CurlCancellation>.fromOpaque(context).release() }
                let shouldCancel: @convention(c) (UnsafeMutableRawPointer?) -> Int32 = { pointer in
                    guard let pointer else { return 1 }
                    return Unmanaged<CurlCancellation>.fromOpaque(pointer)
                        .takeUnretainedValue().isCancelled ? 1 : 0
                }
                let code = url.absoluteString.withCString {
                    theia_curl_get($0, Int(timeoutMs), shouldCancel, context,
                                   &body, &length, &status)
                }
                defer { theia_curl_free(body) }
                if cancellation.isCancelled { throw CancellationError() }
                guard code == 0 else {
                    throw CurlTransportError(message: String(cString: theia_curl_error(code)))
                }
                let data = length == 0 ? Data() : Data(bytes: body!, count: length)
                return CatalogHTTPResponse(data: data, statusCode: status == 0 ? nil : status)
            }.value
        } onCancel: {
            cancellation.cancel()
        }
    }
}
