import Foundation

/// The image pixel currently under the cursor in a `FITSMetalView`.
public struct CursorInfo: Sendable, Equatable {
    public let imageX: Int
    public let imageY: Int
    /// Physical (post-BSCALE/BZERO) value. NaN if BLANK or float NaN.
    public let value: Double

    public init(imageX: Int, imageY: Int, value: Double) {
        self.imageX = imageX
        self.imageY = imageY
        self.value = value
    }
}
