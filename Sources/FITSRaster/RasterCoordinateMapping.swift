import Foundation

/// Float32 device-pixel mapping consumed by the CPU raster and Metal uniforms.
public struct RasterCoordinateMapping: Sendable {
    public let x0: Float
    public let y0: Float
    public let step: Float
    public let backing: Float
    public let scale: Float

    public init(_ mapping: ViewMapping, sampleStep: Int = 1) {
        precondition(sampleStep > 0 && mapping.transform.scale > 0 && mapping.backingScale > 0)
        scale = Float(mapping.transform.scale)
        backing = Float(mapping.backingScale)
        step = Float(sampleStep) / (backing * scale)
        let firstView = Float(sampleStep) * 0.5 / backing
        x0 = Float(mapping.transform.centre.x) + (firstView - Float(mapping.viewSize.x) * 0.5) / scale
        y0 = Float(mapping.transform.centre.y) - (firstView - Float(mapping.viewSize.y) * 0.5) / scale
    }

    public func imageX(column: Int) -> Float { fma(Float(column), step, x0) }
    public func imageY(row: Int) -> Float { fma(-Float(row), step, y0) }
}
