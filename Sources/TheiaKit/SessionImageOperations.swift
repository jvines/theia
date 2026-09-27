import Foundation
import FITSCore

enum ImageOperationRequest: Sendable {
    case filter(FilterSpec)
    case unary(ImageArithmetic.UnaryOp)
    case binary(ImageArithmetic.BinaryOp, Int)
    case subtractBackground
    case reproject(Int)
}

struct ImageOperationSnapshot: Sendable {
    let image: FITSImage
    let wcs: WCS?
    let revision: Int
}

private struct ImageOperationOutput: Sendable {
    let inputRevision: Int
    let result: DerivedImage?
    let error: String?

    init(_ revision: Int, result: DerivedImage? = nil, error: String? = nil) {
        inputRevision = revision
        self.result = result
        self.error = error
    }
}

extension DocumentSession {
    /// The queue obtains its input after all earlier jobs have applied. Two
    /// operations submitted in one event turn therefore read the first result
    /// before the second calculation starts.
    func queueImageOperation(_ request: ImageOperationRequest) {
        let epoch = imageOperationEpoch
        let origin = eventOrigin
        let echoTag = eventEchoTag
        let sourceFile = file
        let targetWCS: WCS?
        let targetShape: SIMD2<Int>?
        if case .reproject(let index) = request {
            targetWCS = facts[index].wcs(variant: "")
            targetShape = facts[index].shape
        } else {
            targetWCS = nil
            targetShape = nil
        }
        jobs.enqueue(
            kind: .imageOperation, imageRevision: epoch,
            currentRevision: { [weak self] in
                guard let self, !self.isClosed else { return -1 }
                return self.imageOperationEpoch
            },
            work: { [weak self] in
                guard let snapshot = await self?.imageOperationSnapshot(),
                      !Task.isCancelled else { return nil }
                do {
                    return try Self.calculateImageOperation(
                        request, snapshot: snapshot, file: sourceFile,
                        targetWCS: targetWCS, targetShape: targetShape
                    )
                } catch is CancellationError {
                    return nil
                } catch {
                    return ImageOperationOutput(snapshot.revision,
                                                error: "Image operation failed: \(error.localizedDescription)")
                }
            },
            apply: { [weak self] (output: ImageOperationOutput) in
                guard let self, self.imageRevision == output.inputRevision else { return }
                self.withEventContext(origin: origin, echoTag: echoTag) {
                    if let result = output.result {
                        self.updateDerived(result, cancelDependentJobs: false)
                    } else if let error = output.error {
                        self.imageOperationErrorMessage = error
                        self.imageOperationNoticeID &+= 1
                        self.emit(.jobStatusChanged)
                    }
                }
            }
        )
    }

    func imageOperationSnapshot() -> ImageOperationSnapshot? {
        guard !isClosed, let image = displayed else { return nil }
        return ImageOperationSnapshot(image: image, wcs: displayedWCS,
                                      revision: imageRevision)
    }

    private nonisolated static func calculateImageOperation(
        _ request: ImageOperationRequest, snapshot: ImageOperationSnapshot,
        file: FITSFile, targetWCS: WCS?, targetShape: SIMD2<Int>?
    ) throws -> ImageOperationOutput {
        let image = snapshot.image
        let wcs = snapshot.wcs
        switch request {
        case .filter(let spec):
            guard let result = try ImageOperations.filterCheckingCancellation(
                image, wcs: wcs, spec: spec) else {
                return ImageOperationOutput(snapshot.revision, error: "Invalid filter size or sigma.")
            }
            return ImageOperationOutput(snapshot.revision, result: result)
        case .unary(let op):
            return ImageOperationOutput(snapshot.revision,
                result: try ImageOperations.unaryCheckingCancellation(
                    image, wcs: wcs, op: op))
        case .binary(let op, let index):
            let other = try FITSImage(hdu: file.hdus[index])
            let result = try ImageOperations.binaryCheckingCancellation(
                image, wcs: wcs, other: other, op: op, otherHDU: index
            )
            return ImageOperationOutput(snapshot.revision, result: result)
        case .subtractBackground:
            guard let result = try ImageOperations.subtractBackgroundCheckingCancellation(
                image, wcs: wcs) else {
                return ImageOperationOutput(snapshot.revision,
                                            error: "The image has no valid pixels.")
            }
            return ImageOperationOutput(snapshot.revision, result: result)
        case .reproject(let index):
            guard let wcs, let targetWCS, let targetShape,
                  let result = try ImageOperations.reprojectCheckingCancellation(
                    image, sourceWCS: wcs, targetWCS: targetWCS,
                    targetWidth: targetShape.x, targetHeight: targetShape.y,
                    targetHDU: index
                  ) else {
                return ImageOperationOutput(snapshot.revision,
                                            error: "Reprojection could not be completed.")
            }
            return ImageOperationOutput(snapshot.revision, result: result)
        }
    }
}
