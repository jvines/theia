import CXPA

/// Swift surface over the vendored libxpa. Expanded incrementally; for now this
/// proves the C target compiles, links, and that XPA access points can be
/// created and torn down.
public enum XPABridge {
    /// The linked libxpa version (e.g. "2.1.20").
    public static let version = String(cString: XPA_VERSION)

    /// Smoke check that libxpa is callable: register a transient access point
    /// (with a no-op xpaget callback, since XPANew requires at least one), confirm
    /// it was created, then free it. Standalone — doesn't resolve by name, so no
    /// xpans needed.
    public static func canCreateAccessPoint() -> Bool {
        let sendCb: SendCb = { _, _, _, buf, len in
            if let len { len.pointee = 0 }
            if let buf { buf.pointee = nil }
            return 0
        }
        guard let xpa = "DS9".withCString({ cls in
            "_xpabridge_probe".withCString { name in
                "probe".withCString { help in
                    XPANew(UnsafeMutablePointer(mutating: cls),
                           UnsafeMutablePointer(mutating: name),
                           UnsafeMutablePointer(mutating: help),
                           sendCb, nil, nil,   // xpaget callback
                           nil, nil, nil)      // no xpaset callback
                }
            }
        }) else { return false }
        XPAFree(xpa)
        return true
    }
}
