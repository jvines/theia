import Foundation
import FITSCore

/// Regions and user-facing fit statistics produced from a displayed image.
public struct SourceDetectionResult: Sendable {
    public let regions: [Region]
    public let fittedCount: Int
    public let noticeTitle: String?
    public let noticeMessage: String?

    public static func analyze(
        image: FITSImage, threshold: Double? = nil,
        checkCancellation: () throws -> Void = { try Task.checkCancellation() }
    ) throws -> SourceDetectionResult {
        let detections = try SourceExtractor.detectCheckingCancellation(
            image: image, threshold: threshold, minSeparation: 3,
            backgroundBoxSize: 21, nSigma: 5,
            checkCancellation: checkCancellation
        )
        var regions: [Region] = []
        var fwhms: [Double] = []
        regions.reserveCapacity(detections.count)
        for detection in detections {
            try checkCancellation()
            let near = (Int(detection.x.rounded()), Int(detection.y.rounded()))
            if let fit = GaussianFit.fit(image: image, near: near, boxRadius: 7),
               fit.sigmaX > 0.5 {
                let radius = max(2.0 * fit.sigmaX, 2.5)
                let label = String(format: "FWHM %.2f", fit.fwhm)
                fwhms.append(fit.fwhm)
                regions.append(Region(
                    shape: .circle(center: .init(x: fit.x + 1, y: fit.y + 1),
                                   radius: .init(value: radius, unit: .pixel)),
                    frame: .image,
                    attributes: ["color": "yellow", "text": label, "tag": "sources"]
                ))
            } else {
                regions.append(Region(
                    shape: .circle(center: .init(x: detection.x + 1, y: detection.y + 1),
                                   radius: .init(value: 4, unit: .pixel)),
                    frame: .image,
                    attributes: ["color": "yellow", "tag": "sources"]
                ))
            }
        }
        guard !fwhms.isEmpty else {
            return SourceDetectionResult(regions: regions, fittedCount: 0,
                                         noticeTitle: nil, noticeMessage: nil)
        }
        var sum = 0.0
        var minimum = Double.infinity
        var maximum = -Double.infinity
        for (index, fwhm) in fwhms.enumerated() {
            if index & 8_191 == 0 { try checkCancellation() }
            sum += fwhm
            minimum = min(minimum, fwhm)
            maximum = max(maximum, fwhm)
        }
        let median = try ImageStatisticsSummary.selectRanks(
            in: &fwhms, ranks: [fwhms.count / 2],
            checkCancellation: checkCancellation
        )[0]
        let mean = sum / Double(fwhms.count)
        let title = "Detected \(regions.count) sources (\(fwhms.count) Gaussian-fitted)"
        let message = String(
            format: "FWHM (px) — median %.2f, mean %.2f, min %.2f, max %.2f",
            median, mean, minimum, maximum
        )
        return SourceDetectionResult(regions: regions, fittedCount: fwhms.count,
                                     noticeTitle: title, noticeMessage: message)
    }
}
