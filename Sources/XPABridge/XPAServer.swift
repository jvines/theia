import CXPA
import Foundation

/// Host hook for XPA commands. Implemented by the app; called on the main queue
/// (the server polls there), so implementations may touch main-actor app state.
public protocol XPAServerDelegate: AnyObject {
    /// Handle `xpaget <command> <params>`. Return reply text, or nil for an error.
    func xpaGet(command: String, params: String) -> String?
    /// Handle `xpaset <command> <params>` with optional stdin `data`. Return success.
    func xpaSet(command: String, params: String, data: Data?) -> Bool
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

    /// Registers `DS9:<name>` for each name (default: `ds9` for drop-in DS9
    /// compatibility, plus `fitsviewer` for explicit targeting), then starts
    /// polling on the main queue.
    public func start(names: [String] = ["ds9", "fitsviewer"],
                      commands: [String] = defaultCommands) {
        for name in names {
            guard let xpa = "DS9".withCString({ cls in
                name.withCString { nm in
                    XPACmdNew(UnsafeMutablePointer(mutating: cls), UnsafeMutablePointer(mutating: nm))
                }
            }) else { continue }
            accessPoints.append(xpa)
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
    fileprivate func handleGet(command: String, params: String) -> String? {
        delegate?.xpaGet(command: command, params: params)
    }
    fileprivate func handleSet(command: String, params: String, data: Data?) -> Bool {
        delegate?.xpaSet(command: command, params: params, data: data) ?? false
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
    guard let server = ctx.server, let reply = server.handleGet(command: ctx.command, params: params) else {
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
    return server.handleSet(command: ctx.command, params: params, data: data) ? 0 : -1
}
