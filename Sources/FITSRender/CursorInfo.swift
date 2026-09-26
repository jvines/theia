import Foundation

/// The image pixel currently under the cursor in a `FITSMetalView`.
public struct CursorInfo: Sendable, Equatable {
    public let imageX: Int
    public let imageY: Int
    /// FITS/DS9 coordinates shown to the user and written at API boundaries.
    public var fitsX: Int { imageX + 1 }
    public var fitsY: Int { imageY + 1 }
    /// Physical (post-BSCALE/BZERO) value. NaN if BLANK or float NaN.
    public let value: Double

    public init(imageX: Int, imageY: Int, value: Double) {
        self.imageX = imageX
        self.imageY = imageY
        self.value = value
    }
}
