import Foundation
import FITSCore

enum ImageOperationRequest: Sendable {
    case filter(FilterSpec)
    case unary(ImageArithmetic.UnaryOp)
    case binary(ImageArithmetic.BinaryOp, Int)
    case subtractBackground
    case reproject(Int)
    case bin(Int)
    case cropToRegion(Region)
    case stack([FITSImage], StackMode)
    case collapseCube(hdu: Int, mode: FITSImage.CollapseMode)
    case slab(hdu: Int, from: Int, to: Int)
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
    /// Captures other windows now, then reads the reference window after earlier
    /// queued image edits finish. The workspace owns cross-window selection.
    @discardableResult public func stack(
        with otherImages: [FITSImage], mode: StackMode,
        origin: CommandOrigin = .user
    ) -> CommandOutcome {
        withEventContext(origin: origin) {
            guard !isClosed else { return CommandOutcome(failure: .documentClosed) }
            guard let displayed else { return CommandOutcome(failure: .noDisplayedImage) }
            guard !otherImages.isEmpty else {
                return CommandOutcome(failure: .insufficientStackImages)
            }
            guard jobs.hasActive(kind: .imageOperation) ||
                  otherImages.allSatisfy({ $0.width == displayed.width &&
                                           $0.height == displayed.height }) else {
                return CommandOutcome(failure: .imageDimensionMismatch)
            }
            queueImageOperation(.stack(otherImages, mode))
            return CommandOutcome()
        }
    }

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
        let cubeWCS: WCS?
        if case .reproject(let index) = request {
            targetWCS = facts[index].wcs(variant: "")
            targetShape = facts[index].shape
        } else {
            targetWCS = nil
            targetShape = nil
        }
        switch request {
        case .collapseCube(let index, _), .slab(let index, _, _):
            cubeWCS = facts[index].wcs(variant: sourceWCSVariant)
        default:
            cubeWCS = nil
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
                        targetWCS: targetWCS, targetShape: targetShape,
                        cubeWCS: cubeWCS
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
        file: FITSFile, targetWCS: WCS?, targetShape: SIMD2<Int>?, cubeWCS: WCS?
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
        case .bin(let factor):
            guard let result = try ImageOperations.binCheckingCancellation(
                image, wcs: wcs, factor: factor
            ) else {
                return ImageOperationOutput(snapshot.revision,
                                            error: "Binning could not be completed for this image.")
            }
            return ImageOperationOutput(snapshot.revision, result: result)
        case .cropToRegion(let region):
            guard let result = try ImageOperations.cropToRegionCheckingCancellation(
                image, wcs: wcs, region: region
            ) else {
                return ImageOperationOutput(snapshot.revision,
                                            error: "The selected region does not cover image pixels.")
            }
            return ImageOperationOutput(snapshot.revision, result: result)
        case .stack(let otherImages, let mode):
            guard let result = try ImageOperations.stackCheckingCancellation(
                [image] + otherImages, referenceWCS: wcs, mode: mode
            ) else {
                return ImageOperationOutput(snapshot.revision,
                                            error: "All stack images must have the same dimensions.")
            }
            return ImageOperationOutput(snapshot.revision, result: result)
        case .collapseCube(let index, let mode):
            // Only accepted with the original cube displayed and no earlier
            // image job pending; a 2D derived image has no plane axis to collapse.
            let collapsed = try FITSImage.collapsedCheckingCancellation(
                hdu: file.hdus[index], mode: mode
            )
            return ImageOperationOutput(snapshot.revision, result: DerivedImage(
                image: collapsed, wcs: cubeWCS, label: "\(mode.label) over plane axis"
            ))
        case .slab(let index, let from, let to):
            // The command preflight applies the same original-cube rule.
            let slab = try FITSImage.slabCheckingCancellation(
                hdu: file.hdus[index], from: from, to: to
            )
            return ImageOperationOutput(snapshot.revision, result: DerivedImage(
                image: slab, wcs: cubeWCS, label: "Slab \(from)…\(to) (sum)"
            ))
        }
    }
}
