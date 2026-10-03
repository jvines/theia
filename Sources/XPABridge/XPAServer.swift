import CXPA
import Foundation

/// Why an XPA command failed. The client prints the message after `XPA$ERROR`.
public struct XPACommandError: Error, Equatable, Sendable {
    public let message: String

    public init(_ message: String) { self.message = message }
}

/// Host hook for XPA commands. Implemented by the app; called on the main queue
/// (the server polls there), so implementations may touch main-actor app state.
public protocol XPAServerDelegate: AnyObject {
    /// Handle `xpaget <command> <params>`: the reply text, or why there is none.
    func xpaGet(command: String, params: String) -> Result<String, XPACommandError>
    /// Handle `xpaset <command> <params>` with optional stdin `data`.
    func xpaSet(command: String, params: String, data: Data?) -> Result<Void, XPACommandError>
}

/// Registers DS9-compatible XPA access points (via libxpa) and dispatches their
/// get/set sub-commands to an `XPAServerDelegate`. Use from the main thread.
public final class XPAServer {
    public weak var delegate: XPAServerDelegate?

    /// DS9 sub-commands we expose. Only commands the delegate actually implements
    /// are registered — advertising an access point we don't handle returns a
    /// silent error to the client (and breaks pyds9 scripts), so unimplemented
    /// verbs (colorbar, zoom, pan, wcs, crosshair, top-level mode) are NOT listed.
    public static let defaultCommands = [
        "file", "fits", "frame", "scale", "cmap", "regions", "zscale", "version", "exit",
    ]

    private var accessPoints: [XPA] = []
    private var contexts: [XPACommandContext] = []   // retains callback contexts
    private var timer: DispatchSourceTimer?

    public init(delegate: XPAServerDelegate) {
        self.delegate = delegate
    }

    /// Where the first access point listens, as libxpa writes it: `ip:port`
    /// in hex for inet, a socket path for unix. An XPA client given this as
    /// its template reaches that access point alone, without the name server.
    public var method: String? {
        accessPoints.first?.pointee.method.map { String(cString: $0) }
    }

    /// Registers each access point (default: `DS9:ds9` for drop-in DS9
    /// compatibility, plus `THEIA:fitsviewer` for explicit targeting as
    /// `fitsviewer`), then starts polling on the main queue. Only `ds9` is in
    /// class DS9: pyds9's `DS9()` looks up `DS9:*` and refuses two matches.
    public func start(accessPoints: [(xclass: String, name: String)] = [("DS9", "ds9"), ("THEIA", "fitsviewer")],
                      commands: [String] = defaultCommands) {
        for (xclass, name) in accessPoints {
            guard let xpa = xclass.withCString({ cls in
                name.withCString { nm in
                    XPACmdNew(UnsafeMutablePointer(mutating: cls), UnsafeMutablePointer(mutating: nm))
                }
            }) else { continue }
            self.accessPoints.append(xpa)
            for cmd in commands {
                let ctx = XPACommandContext(server: self, command: cmd)
                contexts.append(ctx)
                let data = Unmanaged.passUnretained(ctx).toOpaque()
                _ = cmd.withCString { c in
                    "".withCString { h in
                        XPACmdAdd(xpa,
                                  UnsafeMutablePointer(mutating: c),
                                  UnsafeMutablePointer(mutating: h),
                                  xpaSendTrampoline, data, nil,      // xpaget
                                  xpaReceiveTrampoline, data, nil)   // xpaset
                    }
                }
            }
        }
        startPolling()
    }

    private func startPolling() {
        let t = DispatchSource.makeTimerSource(queue: .main)
        t.schedule(deadline: .now() + .milliseconds(50), repeating: .milliseconds(50))
        t.setEventHandler { _ = XPAPoll(0, 100) }
        t.resume()
        timer = t
    }

    public func stop() {
        timer?.cancel()
        timer = nil
        for xpa in accessPoints { _ = XPAFree(xpa) }
        accessPoints.removeAll()
        contexts.removeAll()
    }

    // Called from the C trampolines (on the polling/main queue).
    fileprivate func handleGet(command: String, params: String) -> Result<String, XPACommandError> {
        delegate?.xpaGet(command: command, params: params) ?? .failure(XPACommandError("Theia is shutting down"))
    }
    fileprivate func handleSet(command: String, params: String, data: Data?) -> Result<Void, XPACommandError> {
        delegate?.xpaSet(command: command, params: params, data: data) ?? .failure(XPACommandError("Theia is shutting down"))
    }
}

/// Per-(access point, command) context handed to libxpa as the callback
/// `client_data`, so a single pair of C trampolines can serve every command.
final class XPACommandContext {
    weak var server: XPAServer?
    let command: String
    init(server: XPAServer, command: String) {
        self.server = server
        self.command = command
    }
}

// MARK: - C callback trampolines (must be non-capturing → convert to C function pointers)

/// xpaget handler: fills `buf`/`len` with a malloc'd reply libxpa will free.
func xpaSendTrampoline(_ clientData: UnsafeMutableRawPointer?,
                       _ callData: UnsafeMutableRawPointer?,
                       _ paramlist: UnsafeMutablePointer<CChar>?,
                       _ buf: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?,
                       _ len: UnsafeMutablePointer<Int>?) -> Int32 {
    guard let clientData else { return -1 }
    let ctx = Unmanaged<XPACommandContext>.fromOpaque(clientData).takeUnretainedValue()
    let params = paramlist.map { String(cString: $0) } ?? ""
    guard let server = ctx.server else { return -1 }
    let reply: String
    switch server.handleGet(command: ctx.command, params: params) {
    case .success(let text): reply = text
    case .failure(let error):
        report(error, to: callData)
        return -1
    }
    let bytes = Array(reply.utf8)
    // libxpa frees this buffer after transmitting it.
    let n = bytes.count
    let raw = malloc(max(n, 1))
    if n > 0 { raw?.copyMemory(from: bytes, byteCount: n) }
    buf?.pointee = raw?.assumingMemoryBound(to: CChar.self)
    len?.pointee = n
    return 0
}

/// xpaset handler: hands the incoming bytes (if any) to the delegate.
func xpaReceiveTrampoline(_ clientData: UnsafeMutableRawPointer?,
                          _ callData: UnsafeMutableRawPointer?,
                          _ paramlist: UnsafeMutablePointer<CChar>?,
                          _ buf: UnsafeMutablePointer<CChar>?,
                          _ len: Int) -> Int32 {
    guard let clientData else { return -1 }
    let ctx = Unmanaged<XPACommandContext>.fromOpaque(clientData).takeUnretainedValue()
    let params = paramlist.map { String(cString: $0) } ?? ""
    let data: Data? = (buf != nil && len > 0) ? Data(bytes: buf!, count: len) : nil
    guard let server = ctx.server else { return -1 }
    switch server.handleSet(command: ctx.command, params: params, data: data) {
    case .success: return 0
    case .failure(let error):
        report(error, to: callData)
        return -1
    }
}

/// Sends the failure text to the client. libxpa passes the access point as
/// `call_data`; without a message the client only sees libxpa's generic
/// "error detected in ... callback routine".
private func report(_ error: XPACommandError, to callData: UnsafeMutableRawPointer?) {
    guard let callData else { return }
    let xpa = callData.assumingMemoryBound(to: xparec.self)
    _ = error.message.withCString { XPAError(xpa, UnsafeMutablePointer(mutating: $0)) }
}
