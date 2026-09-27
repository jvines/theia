import Foundation
import FITSCore

/// The image, WCS, and observation header currently displayed by one document.
public struct LightCurveFrame: Sendable {
    public let image: FITSImage
    public let wcs: WCS
    public let header: FITSHeader

    public init(image: FITSImage, wcs: WCS, header: FITSHeader) {
        self.image = image
        self.wcs = wcs
        self.header = header
    }
}

public enum LightCurveBuilder {
    /// Measures the selected aperture in each displayed image and returns a time-sorted curve.
    public static func build(region: Region, referenceWCS: WCS,
                             frames: [LightCurveFrame]) -> LightCurveModel? {
        let samples = frames.compactMap { frame -> (flux: Double, err: Double, time: (mjd: Double, label: String)?)? in
            guard let projected = project(region, from: referenceWCS, to: frame.wcs),
                  let measurement = Photometry.measure(region: projected, image: frame.image,
                                                       wcs: frame.wcs) else { return nil }
            return (measurement.skySubtractedFlux ?? measurement.sum,
                    measurement.skySubtractedFluxError ?? measurement.sumError,
                    FITSTime.observationMJD(header: frame.header))
        }
        guard samples.count >= 2 else { return nil }

        let timed = samples.compactMap { sample -> (point: LightCurvePoint, label: String)? in
            guard let time = sample.time else { return nil }
            return (LightCurvePoint(time: time.mjd, flux: sample.flux, err: sample.err), time.label)
        }
        if timed.count == samples.count {
            return LightCurveModel(points: timed.map(\.point).sorted { $0.time < $1.time },
                                   timeLabel: timed.last?.label ?? "MJD")
        }
        // A missing time makes a mixed MJD/index axis misleading. Use file order throughout.
        let points = samples.enumerated().map { index, sample in
            LightCurvePoint(time: Double(index), flux: sample.flux, err: sample.err)
        }
        return LightCurveModel(points: points, timeLabel: "file index")
    }

    private static func project(_ region: Region, from referenceWCS: WCS,
                                to targetWCS: WCS) -> Region? {
        func targetPoint(_ point: Region.Point) -> Region.Point? {
            guard let referencePixel = imageCenter(of: point, frame: region.frame, wcs: referenceWCS),
                  let sky = referenceWCS.pixelToSky(imageX: referencePixel.x,
                                                    imageY: referencePixel.y) else { return nil }
            let native = CelestialTransform.convert(lon: sky.ra, lat: sky.dec,
                                                     from: referenceWCS.nativeFrame,
                                                     to: targetWCS.nativeFrame)
            guard let pixel = targetWCS.skyToPixel(ra: native.lon, dec: native.lat) else { return nil }
            return .init(x: pixel.x + 1, y: pixel.y + 1)
        }

        func targetDistance(_ distance: Region.Distance) -> Region.Distance {
            guard distance.unit == .pixel else { return distance }
            let referenceDegreesPerPixel = sqrt(abs(referenceWCS.cd11 * referenceWCS.cd22
                                                    - referenceWCS.cd12 * referenceWCS.cd21))
            return .init(value: distance.value * referenceDegreesPerPixel, unit: .degree)
        }

        let shape: Region.Shape
        switch region.shape {
        case .circle(let center, let radius):
            guard let center = targetPoint(center) else { return nil }
            shape = .circle(center: center, radius: targetDistance(radius))
        case .box(let center, let width, let height, let angle):
            guard let center = targetPoint(center) else { return nil }
            shape = .box(center: center, width: targetDistance(width),
                         height: targetDistance(height), angle: angle)
        case .ellipse(let center, let rx, let ry, let angle):
            guard let center = targetPoint(center) else { return nil }
            shape = .ellipse(center: center, rx: targetDistance(rx),
                             ry: targetDistance(ry), angle: angle)
        case .annulus(let center, let inner, let outer):
            guard let center = targetPoint(center) else { return nil }
            shape = .annulus(center: center, innerRadius: targetDistance(inner),
                             outerRadius: targetDistance(outer))
        case .polygon(let vertices):
            let projected = vertices.compactMap(targetPoint)
            guard projected.count == vertices.count else { return nil }
            shape = .polygon(points: projected)
        case .point(let point):
            guard let point = targetPoint(point) else { return nil }
            shape = .point(point)
        }
        return Region(shape: shape, frame: .image, attributes: region.attributes)
    }
}
