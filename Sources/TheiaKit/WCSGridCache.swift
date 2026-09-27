import FITSCore

/// Keeps WCS grid geometry in image pixels so view pan and zoom only remap points.
@MainActor public final class WCSGridCache {
    private struct Key: Equatable {
        let variant: String
        let nativeFrame: CelestialFrame
        let projectionType: String
        let width: Int
        let height: Int
        let crpixX: Double
        let crpixY: Double
        let crvalLon: Double
        let crvalLat: Double
        let cd11: Double
        let cd12: Double
        let cd21: Double
        let cd22: Double
        let sipForward: WCS.SIPPolynomial?
        let sipInverse: WCS.SIPPolynomial?

        init(wcs: WCS, width: Int, height: Int) {
            variant = wcs.variant
            nativeFrame = wcs.nativeFrame
            projectionType = wcs.projectionType
            self.width = width
            self.height = height
            crpixX = wcs.crpix.x
            crpixY = wcs.crpix.y
            crvalLon = wcs.crval.ra
            crvalLat = wcs.crval.dec
            cd11 = wcs.cd11
            cd12 = wcs.cd12
            cd21 = wcs.cd21
            cd22 = wcs.cd22
            sipForward = wcs.sipForward
            sipInverse = wcs.sipInverse
        }
    }

    private var cachedKey: Key?
    private var cachedLines: [WCSGridline] = []
    private(set) var generationCount = 0

    public init() {}

    public func gridlines(wcs: WCS, imageWidth: Int, imageHeight: Int) -> [WCSGridline] {
        let key = Key(wcs: wcs, width: imageWidth, height: imageHeight)
        if key == cachedKey { return cachedLines }
        cachedLines = WCSGridGenerator.gridlines(wcs: wcs,
                                                 imageWidth: imageWidth,
                                                 imageHeight: imageHeight)
        cachedKey = key
        generationCount += 1
        return cachedLines
    }
}
