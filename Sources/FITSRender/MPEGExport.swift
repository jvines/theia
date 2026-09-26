import Foundation
import AppKit
import AVFoundation
import FITSCore
import FITSRaster

public enum MPEGExportError: Error {
    case noPlanes
    case writerCreationFailed
    case writerNotReadyForMore
    case writerFinishFailed(String)
}

/// Encodes each plane of an NAXIS=3 cube (or any sequence of `FITSImage`s) as an
/// H.264 .mp4 file. Each frame is rendered using the supplied `stretch` / `vmin`/`vmax`/
/// `colorMap` so the output matches what you see on screen.
public enum MPEGExport {
    public static func writeCube(
        hdu: FITSHDU,
        to url: URL,
        stretch: ImageStretch,
        vmin: Double,
        vmax: Double,
        colorMap: ColorMap,
        parameter: Float = 2,
        fps: Int = 8
    ) throws {
        // The encoder ends with a semaphore wait, so calling this on the main
        // queue would freeze the UI. Callers must dispatch to a background queue.
        dispatchPrecondition(condition: .notOnQueue(.main))
        guard hdu.naxis == 3 else { throw MPEGExportError.noPlanes }
        let depth = hdu.axes[2]
        var frames: [CGImage] = []
        frames.reserveCapacity(depth)
        var width = 0, height = 0
        for p in 0..<depth {
            let img = try FITSImage(hdu: hdu, plane: p)
            width = img.width; height = img.height
            let cg = try render(
                image: img, stretch: stretch, vmin: vmin, vmax: vmax,
                colorMap: colorMap, parameter: parameter
            )
            frames.append(cg)
        }
        guard !frames.isEmpty else { throw MPEGExportError.noPlanes }
        try write(frames: frames, width: width, height: height, fps: fps, to: url)
    }

    // MARK: - Frame rendering

    static func renderFrameBytes(
        image: FITSImage, stretch: ImageStretch, vmin: Double, vmax: Double,
        colorMap: ColorMap, parameter: Float
    ) -> [UInt8] {
        let display = DisplayImage(image: image, revision: 0)
        return ViewportRasterizer.renderNative(
            display, stretch: stretch,
            levels: RasterLevels(vmin: Float(vmin), vmax: Float(vmax)),
            colorMap: colorMap, parameter: parameter
        ).bytes
    }

    private static func render(
        image: FITSImage, stretch: ImageStretch, vmin: Double, vmax: Double,
        colorMap: ColorMap, parameter: Float
    ) throws -> CGImage {
        let w = image.width, h = image.height
        let bytes = renderFrameBytes(
            image: image, stretch: stretch, vmin: vmin, vmax: vmax,
            colorMap: colorMap, parameter: parameter
        )
        let cs = (CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB())
        let info = CGImageAlphaInfo.premultipliedLast.rawValue
        guard let provider = CGDataProvider(data: Data(bytes) as CFData),
              let cg = CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32,
                               bytesPerRow: w * 4, space: cs,
                               bitmapInfo: CGBitmapInfo(rawValue: info), provider: provider,
                               decode: nil, shouldInterpolate: false, intent: .defaultIntent) else {
            throw MPEGExportError.writerCreationFailed
        }
        return cg
    }

    // MARK: - AVAssetWriter pipeline

    private static func write(frames: [CGImage], width: Int, height: Int, fps: Int, to url: URL) throws {
        try? FileManager.default.removeItem(at: url)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
        ]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = false
        let adaptorAttrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
        ]
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input,
                                                           sourcePixelBufferAttributes: adaptorAttrs)
        guard writer.canAdd(input) else { throw MPEGExportError.writerCreationFailed }
        writer.add(input)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)

        let timescale: CMTimeScale = 600
        let frameDuration = CMTime(value: CMTimeValue(timescale / CMTimeScale(fps)), timescale: timescale)

        for (i, cg) in frames.enumerated() {
            while !input.isReadyForMoreMediaData {
                Thread.sleep(forTimeInterval: 0.005)
            }
            guard let buf = pixelBuffer(from: cg, width: width, height: height, pool: adaptor.pixelBufferPool) else { continue }
            let presentationTime = CMTimeMultiply(frameDuration, multiplier: Int32(i))
            adaptor.append(buf, withPresentationTime: presentationTime)
        }

        input.markAsFinished()
        let sem = DispatchSemaphore(value: 0)
        var finishError: Error?
        writer.finishWriting {
            if writer.status == .failed { finishError = writer.error }
            sem.signal()
        }
        sem.wait()
        if let e = finishError {
            throw MPEGExportError.writerFinishFailed(e.localizedDescription)
        }
    }

    /// Acquire a pixel buffer (preferring the adaptor's pool to avoid per-frame
    /// allocation) and rasterise `image` into it.
    private static func pixelBuffer(from image: CGImage, width: Int, height: Int, pool: CVPixelBufferPool?) -> CVPixelBuffer? {
        var pb: CVPixelBuffer?
        if let pool {
            CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &pb)
        }
        if pb == nil {
            let attrs: [CFString: Any] = [
                kCVPixelBufferCGImageCompatibilityKey: true,
                kCVPixelBufferCGBitmapContextCompatibilityKey: true,
            ]
            let status = CVPixelBufferCreate(kCFAllocatorDefault, width, height,
                                             kCVPixelFormatType_32BGRA, attrs as CFDictionary, &pb)
            guard status == kCVReturnSuccess else { return nil }
        }
        guard let buf = pb else { return nil }
        CVPixelBufferLockBaseAddress(buf, [])
        defer { CVPixelBufferUnlockBaseAddress(buf, []) }
        let ctx = CGContext(data: CVPixelBufferGetBaseAddress(buf),
                            width: width, height: height,
                            bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buf),
                            space: (CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()),
                            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        ctx?.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return buf
    }
}
