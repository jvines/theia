import Foundation
#if canImport(simd)
import simd
#endif

/// Which handle on a region a hit-test landed on.
public enum RegionEditHandle: Equatable, Sendable {
    case move
    case circleRadius
    case annulusInner
    case annulusOuter
    /// Box corner index 0..3, ordered: 0=bottom-left, 1=bottom-right, 2=top-right, 3=top-left
    /// (axis-aligned local frame before rotation).
    case boxCorner(Int)
    case ellipseRx
    case ellipseRy
    case polygonVertex(Int)
    // Future: boxEdge…
}

public struct RegionHit: Equatable, Sendable {
    public let regionIndex: Int
    public let handle: RegionEditHandle
}

public enum RegionHitTest {
    /// Walk `regions` and return the first region whose handle the image-pixel `imagePoint`
    /// is within `toleranceImagePixels` of. WCS-frame regions need a `wcs` argument; if
    /// `wcs` is nil they are skipped.
    ///
    /// Hit-test priority for a given region: ring edges (inner / outer) beat the move handle,
    /// so the user can grab the ring even when it's close to the centre.
    public static func hit(
        in regions: [Region],
        atImagePoint imagePoint: SIMD2<Double>,
        toleranceImagePixels tolerance: Double,
        wcs: WCS? = nil
    ) -> RegionHit? {
        for (idx, region) in regions.enumerated() {
            switch region.shape {
            case .annulus(let center, let rIn, let rOut):
                guard let cp = imageCenter(of: center, frame: region.frame, wcs: wcs),
                      let inPix = pixelLength(rIn, frame: region.frame, wcs: wcs),
                      let outPix = pixelLength(rOut, frame: region.frame, wcs: wcs) else { continue }
                let dist = ((imagePoint.x - cp.x).squared + (imagePoint.y - cp.y).squared).squareRoot()
                if abs(dist - outPix) <= tolerance {
                    return RegionHit(regionIndex: idx, handle: .annulusOuter)
                }
                if abs(dist - inPix) <= tolerance {
                    return RegionHit(regionIndex: idx, handle: .annulusInner)
                }
                if dist <= inPix {
                    return RegionHit(regionIndex: idx, handle: .move)
                }

            case .circle(let center, let radius):
                guard let cp = imageCenter(of: center, frame: region.frame, wcs: wcs),
                      let rPix = pixelLength(radius, frame: region.frame, wcs: wcs) else { continue }
                let dist = ((imagePoint.x - cp.x).squared + (imagePoint.y - cp.y).squared).squareRoot()
                if abs(dist - rPix) <= tolerance {
                    return RegionHit(regionIndex: idx, handle: .circleRadius)
                }
                if dist < rPix {
                    return RegionHit(regionIndex: idx, handle: .move)
                }

            case .box(let center, let w, let h, let angle):
                guard let cp = imageCenter(of: center, frame: region.frame, wcs: wcs),
                      let wPix = pixelLength(w, frame: region.frame, wcs: wcs),
                      let hPix = pixelLength(h, frame: region.frame, wcs: wcs) else { continue }
                let theta = angle * .pi / 180
                let cosT = Foundation.cos(theta), sinT = Foundation.sin(theta)
                let dx = imagePoint.x - cp.x, dy = imagePoint.y - cp.y
                let localX =  dx * cosT + dy * sinT
                let localY = -dx * sinT + dy * cosT
                let halfW = wPix / 2, halfH = hPix / 2
                let corners: [(Double, Double)] = [
                    (-halfW, -halfH), ( halfW, -halfH),
                    ( halfW,  halfH), (-halfW,  halfH),
                ]
                for (i, c) in corners.enumerated() {
                    let d = ((localX - c.0).squared + (localY - c.1).squared).squareRoot()
                    if d <= tolerance {
                        return RegionHit(regionIndex: idx, handle: .boxCorner(i))
                    }
                }
                if abs(localX) <= halfW && abs(localY) <= halfH {
                    return RegionHit(regionIndex: idx, handle: .move)
                }

            case .ellipse(let center, let rx, let ry, let angle):
                guard let cp = imageCenter(of: center, frame: region.frame, wcs: wcs),
                      let rxPix = pixelLength(rx, frame: region.frame, wcs: wcs),
                      let ryPix = pixelLength(ry, frame: region.frame, wcs: wcs) else { continue }
                let theta = angle * .pi / 180
                let cosT = Foundation.cos(theta), sinT = Foundation.sin(theta)
                let dx = imagePoint.x - cp.x, dy = imagePoint.y - cp.y
                let localX =  dx * cosT + dy * sinT
                let localY = -dx * sinT + dy * cosT
                if abs(localY) <= tolerance && abs(abs(localX) - rxPix) <= tolerance {
                    return RegionHit(regionIndex: idx, handle: .ellipseRx)
                }
                if abs(localX) <= tolerance && abs(abs(localY) - ryPix) <= tolerance {
                    return RegionHit(regionIndex: idx, handle: .ellipseRy)
                }
                if rxPix > 0 && ryPix > 0 {
                    let nx = localX / rxPix, ny = localY / ryPix
                    if nx * nx + ny * ny <= 1 {
                        return RegionHit(regionIndex: idx, handle: .move)
                    }
                }

            case .polygon(let pts):
                // Image-frame polygons only; WCS polygons rare enough to defer.
                guard region.frame == .image else { continue }
                for (i, p) in pts.enumerated() {
                    let vx = p.x - 1, vy = p.y - 1
                    let d = ((imagePoint.x - vx).squared + (imagePoint.y - vy).squared).squareRoot()
                    if d <= tolerance {
                        return RegionHit(regionIndex: idx, handle: .polygonVertex(i))
                    }
                }
                if Region.pointInPolygon(imagePoint, vertices: pts) {
                    return RegionHit(regionIndex: idx, handle: .move)
                }

            default:
                continue
            }
        }
        return nil
    }
}

// MARK: - Frame conversion helpers

/// Apply a drag delta to a region's centre, preserving its frame. For image-frame
/// centres the delta is added straight in pixels; for WCS frames the start/current
/// pixels are projected to sky and the resulting sky-delta is applied to the centre.
func movedCenter(_ center: Region.Point, frame: Region.Frame, wcs: WCS?,
                 dragStartImage: SIMD2<Double>, currentImage: SIMD2<Double>) -> Region.Point {
    switch frame {
    case .image:
        let dx = currentImage.x - dragStartImage.x
        let dy = currentImage.y - dragStartImage.y
        return .init(x: center.x + dx, y: center.y + dy)
    case .fk5, .icrs, .j2000, .galactic:
        guard let wcs, let regionFrame = celestialFrame(for: frame),
              let start = wcs.pixelToSky(imageX: Int(dragStartImage.x.rounded()),
                                         imageY: Int(dragStartImage.y.rounded())),
              let curr  = wcs.pixelToSky(imageX: Int(currentImage.x.rounded()),
                                         imageY: Int(currentImage.y.rounded())) else { return center }
        let startInFrame = CelestialTransform.convert(lon: start.ra, lat: start.dec,
                                                       from: wcs.nativeFrame, to: regionFrame)
        let currentInFrame = CelestialTransform.convert(lon: curr.ra, lat: curr.dec,
                                                         from: wcs.nativeFrame, to: regionFrame)
        var dLon = currentInFrame.lon - startInFrame.lon
        if dLon > 180 { dLon -= 360 }
        if dLon < -180 { dLon += 360 }
        return .init(x: center.x + dLon, y: center.y + currentInFrame.lat - startInFrame.lat)
    }
}

/// Centre of a region.Point in 0-based image pixels. Returns nil if the frame
/// requires WCS and `wcs` is absent.
public func imageCenter(of point: Region.Point, frame: Region.Frame, wcs: WCS?) -> SIMD2<Double>? {
    switch frame {
    case .image:
        return SIMD2(point.x - 1, point.y - 1)
    case .fk5, .icrs, .j2000, .galactic:
        guard let wcs, let regionFrame = celestialFrame(for: frame) else { return nil }
        let native = CelestialTransform.convert(lon: point.x, lat: point.y,
                                                 from: regionFrame, to: wcs.nativeFrame)
        guard let p = wcs.skyToPixel(ra: native.lon, dec: native.lat) else { return nil }
        return SIMD2(p.x, p.y)
    }
}

private func celestialFrame(for frame: Region.Frame) -> CelestialFrame? {
    switch frame {
    case .image: nil
    case .fk5, .j2000: .fk5
    case .icrs: .icrs
    case .galactic: .galactic
    }
}

private func regionPoint(at image: SIMD2<Double>, frame: Region.Frame, wcs: WCS?) -> Region.Point? {
    if frame == .image { return .init(x: image.x + 1, y: image.y + 1) }
    guard let wcs, let regionFrame = celestialFrame(for: frame),
          let native = wcs.pixelToSky(imageX: Int(image.x.rounded()),
                                      imageY: Int(image.y.rounded())) else { return nil }
    let converted = CelestialTransform.convert(lon: native.ra, lat: native.dec,
                                                from: wcs.nativeFrame, to: regionFrame)
    return .init(x: converted.lon, y: converted.lat)
}

/// Distance expressed in image pixels. Pixel-unit distances pass through; angular
/// units are converted via the local CD-matrix scale (small-angle approximation;
/// fine for the small regions photometry typically uses).
public func pixelLength(_ d: Region.Distance, frame: Region.Frame, wcs: WCS?) -> Double? {
    switch d.unit {
    case .pixel:
        return d.value
    case .arcsecond, .arcminute, .degree:
        guard let wcs else { return nil }
        let degPerPix = sqrt(abs(wcs.cd11 * wcs.cd22 - wcs.cd12 * wcs.cd21))
        guard degPerPix > 0 else { return nil }
        let degrees: Double
        switch d.unit {
        case .arcsecond: degrees = d.value / 3600
        case .arcminute: degrees = d.value / 60
        case .degree:    degrees = d.value
        case .pixel:     degrees = 0
        }
        _ = frame
        return degrees / degPerPix
    }
}

/// Inverse of `pixelLength`: converts an image-pixel length back into the same
/// distance unit as `like`, so a drag-resize preserves the original unit.
func distance(fromPixels pixels: Double, like other: Region.Distance, wcs: WCS?) -> Region.Distance {
    switch other.unit {
    case .pixel:
        return .init(value: pixels, unit: .pixel)
    case .arcsecond, .arcminute, .degree:
        guard let wcs else { return .init(value: pixels, unit: .pixel) }
        let degPerPix = sqrt(abs(wcs.cd11 * wcs.cd22 - wcs.cd12 * wcs.cd21))
        let degrees = pixels * degPerPix
        switch other.unit {
        case .arcsecond: return .init(value: degrees * 3600, unit: .arcsecond)
        case .arcminute: return .init(value: degrees * 60, unit: .arcminute)
        case .degree:    return .init(value: degrees, unit: .degree)
        case .pixel:     return .init(value: pixels, unit: .pixel)
        }
    }
}

private extension Double {
    var squared: Double { self * self }
}


public enum RegionEdit {
    /// Translate a region by image pixels while keeping its coordinate frame and attributes.
    /// Sky coordinates are projected through the displayed WCS for each point.
    public static func translated(
        _ region: Region, dx: Double, dy: Double, wcs: WCS?
    ) -> Region? {
        guard dx.isFinite, dy.isFinite else { return nil }
        func moved(_ point: Region.Point) -> Region.Point? {
            guard let start = imageCenter(of: point, frame: region.frame, wcs: wcs) else { return nil }
            return movedCenter(point, frame: region.frame, wcs: wcs,
                               dragStartImage: start,
                               currentImage: SIMD2(start.x + dx, start.y + dy))
        }
        let shape: Region.Shape
        switch region.shape {
        case .circle(let center, let radius):
            guard let center = moved(center) else { return nil }
            shape = .circle(center: center, radius: radius)
        case .box(let center, let width, let height, let angle):
            guard let center = moved(center) else { return nil }
            shape = .box(center: center, width: width, height: height, angle: angle)
        case .ellipse(let center, let rx, let ry, let angle):
            guard let center = moved(center) else { return nil }
            shape = .ellipse(center: center, rx: rx, ry: ry, angle: angle)
        case .annulus(let center, let inner, let outer):
            guard let center = moved(center) else { return nil }
            shape = .annulus(center: center, innerRadius: inner, outerRadius: outer)
        case .polygon(let points):
            let updated = points.compactMap(moved)
            guard updated.count == points.count else { return nil }
            shape = .polygon(points: updated)
        case .point(let center):
            guard let center = moved(center) else { return nil }
            shape = .point(center)
        }
        return with(region, shape: shape)
    }

    /// Apply a drag against `region`. `dragStartImage` is where the drag began (so we
    /// can compute a delta for moves), `currentImage` is where the cursor is now.
    public static func apply(
        to region: Region,
        handle: RegionEditHandle,
        dragStartImage: SIMD2<Double>,
        currentImage: SIMD2<Double>,
        wcs: WCS? = nil
    ) -> Region {
        switch region.shape {
        case .circle(let center, let radius):
            guard let cp = imageCenter(of: center, frame: region.frame, wcs: wcs) else { return region }
            switch handle {
            case .move:
                let newCenter = movedCenter(center, frame: region.frame, wcs: wcs,
                                            dragStartImage: dragStartImage, currentImage: currentImage)
                return with(region, shape: .circle(center: newCenter, radius: radius))
            case .circleRadius:
                let nx = currentImage.x - cp.x, ny = currentImage.y - cp.y
                let newRPix = max((nx * nx + ny * ny).squareRoot(), 0.5)
                let newR = distance(fromPixels: newRPix, like: radius, wcs: wcs)
                return with(region, shape: .circle(center: center, radius: newR))
            default:
                return region
            }

        case .box(let center, let w, let h, let angle):
            guard let cp = imageCenter(of: center, frame: region.frame, wcs: wcs),
                  let wPix = pixelLength(w, frame: region.frame, wcs: wcs),
                  let hPix = pixelLength(h, frame: region.frame, wcs: wcs) else { return region }
            switch handle {
            case .move:
                let newCenter = movedCenter(center, frame: region.frame, wcs: wcs,
                                            dragStartImage: dragStartImage, currentImage: currentImage)
                return with(region, shape: .box(center: newCenter, width: w, height: h, angle: angle))
            case .boxCorner(let i):
                let theta = angle * .pi / 180
                let cosT = Foundation.cos(theta), sinT = Foundation.sin(theta)
                let dx = currentImage.x - cp.x, dy = currentImage.y - cp.y
                let lx =  dx * cosT + dy * sinT
                let ly = -dx * sinT + dy * cosT
                let halfW0 = wPix / 2, halfH0 = hPix / 2
                let opposite: (Double, Double)
                switch i {
                case 0: opposite = ( halfW0,  halfH0)
                case 1: opposite = (-halfW0,  halfH0)
                case 2: opposite = (-halfW0, -halfH0)
                case 3: opposite = ( halfW0, -halfH0)
                default: return region
                }
                let newHalfW = abs(lx - opposite.0) / 2
                let newHalfH = abs(ly - opposite.1) / 2
                let midLX = (lx + opposite.0) / 2
                let midLY = (ly + opposite.1) / 2
                let midDX =  midLX * cosT - midLY * sinT
                let midDY =  midLX * sinT + midLY * cosT
                let newCx = cp.x + midDX, newCy = cp.y + midDY
                let newCenter = regionPoint(at: SIMD2(newCx, newCy),
                                             frame: region.frame, wcs: wcs) ?? center
                let newW = distance(fromPixels: max(newHalfW * 2, 1), like: w, wcs: wcs)
                let newH = distance(fromPixels: max(newHalfH * 2, 1), like: h, wcs: wcs)
                return with(region, shape: .box(center: newCenter, width: newW, height: newH, angle: angle))
            default:
                return region
            }

        case .ellipse(let center, let rx, let ry, let angle):
            guard let cp = imageCenter(of: center, frame: region.frame, wcs: wcs) else { return region }
            switch handle {
            case .move:
                let newCenter = movedCenter(center, frame: region.frame, wcs: wcs,
                                            dragStartImage: dragStartImage, currentImage: currentImage)
                return with(region, shape: .ellipse(center: newCenter, rx: rx, ry: ry, angle: angle))
            case .ellipseRx, .ellipseRy:
                let theta = angle * .pi / 180
                let cosT = Foundation.cos(theta), sinT = Foundation.sin(theta)
                let dx = currentImage.x - cp.x, dy = currentImage.y - cp.y
                let lx =  dx * cosT + dy * sinT
                let ly = -dx * sinT + dy * cosT
                if handle == .ellipseRx {
                    let newRx = distance(fromPixels: max(abs(lx), 0.5), like: rx, wcs: wcs)
                    return with(region, shape: .ellipse(center: center, rx: newRx, ry: ry, angle: angle))
                } else {
                    let newRy = distance(fromPixels: max(abs(ly), 0.5), like: ry, wcs: wcs)
                    return with(region, shape: .ellipse(center: center, rx: rx, ry: newRy, angle: angle))
                }
            default:
                return region
            }

        case .polygon(let pts):
            switch handle {
            case .move:
                let dx = currentImage.x - dragStartImage.x
                let dy = currentImage.y - dragStartImage.y
                let moved = pts.map { Region.Point(x: $0.x + dx, y: $0.y + dy) }
                return with(region, shape: .polygon(points: moved))
            case .polygonVertex(let i):
                guard pts.indices.contains(i) else { return region }
                var copy = pts
                copy[i] = .init(x: currentImage.x + 1, y: currentImage.y + 1)
                return with(region, shape: .polygon(points: copy))
            default:
                return region
            }

        case .annulus(let center, let rIn, let rOut):
            guard let cp = imageCenter(of: center, frame: region.frame, wcs: wcs),
                  let inPix = pixelLength(rIn, frame: region.frame, wcs: wcs),
                  let outPix = pixelLength(rOut, frame: region.frame, wcs: wcs) else { return region }
            switch handle {
            case .move:
                let newCenter = movedCenter(center, frame: region.frame, wcs: wcs,
                                            dragStartImage: dragStartImage, currentImage: currentImage)
                return with(region, shape: .annulus(center: newCenter, innerRadius: rIn, outerRadius: rOut))
            case .annulusOuter:
                let nx = currentImage.x - cp.x, ny = currentImage.y - cp.y
                var newOuterPix = (nx * nx + ny * ny).squareRoot()
                let floorPix = inPix + max(inPix * 0.05, 0.5)
                if newOuterPix < floorPix { newOuterPix = floorPix }
                let newOuter = distance(fromPixels: newOuterPix, like: rOut, wcs: wcs)
                return with(region, shape: .annulus(center: center, innerRadius: rIn, outerRadius: newOuter))
            case .annulusInner:
                let nx = currentImage.x - cp.x, ny = currentImage.y - cp.y
                var newInnerPix = (nx * nx + ny * ny).squareRoot()
                let ceilingPix = max(outPix - max(outPix * 0.05, 0.5), 0)
                if newInnerPix > ceilingPix { newInnerPix = ceilingPix }
                if newInnerPix < 0 { newInnerPix = 0 }
                let newInner = distance(fromPixels: newInnerPix, like: rIn, wcs: wcs)
                return with(region, shape: .annulus(center: center, innerRadius: newInner, outerRadius: rOut))
            default:
                return region
            }
        default:
            return region
        }
    }

    private static func with(_ region: Region, shape: Region.Shape) -> Region {
        Region(shape: shape, frame: region.frame, attributes: region.attributes)
    }
}
