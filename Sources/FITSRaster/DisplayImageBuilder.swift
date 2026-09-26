import FITSCore

/// Serializes expensive display builds. A superseded request waiting for this
/// actor observes cancellation before allocating its Float32 image buffer.
public actor DisplayImageBuilder {
    public init() {}

    public func build(image: FITSImage, revision: Int) -> DisplayImage? {
        guard !Task.isCancelled else { return nil }
        let display = DisplayImage(image: image, revision: revision)
        return Task.isCancelled ? nil : display
    }
}
