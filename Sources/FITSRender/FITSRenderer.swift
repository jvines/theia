import Foundation
import Metal
import MetalKit
import simd
import FITSCore
import FITSRaster
import TheiaKit

private struct Vertex {
    var position: SIMD2<Float>
}

private struct Uniforms {
    var vmin: Float
    var vmax: Float
    var stretchType: Int32
    var cdfLength: Int32
    var stretchParam: Float
    var imageX0: Float
    var imageY0: Float
    var deviceStep: Float
    var imageWidth: Int32
    var imageHeight: Int32
    var lutLength: Int32
    var usesViewportRaster: Int32
}

extension ImageStretch {
    /// Index used by the Metal fragment shader's stretch switch.
    var shaderID: Int32 {
        switch self {
        case .linear: return 0
        case .log: return 1
        case .sqrt: return 2
        case .asinh: return 3
        case .histogramEq: return 4
        case .power: return 5
        }
    }
}

/// Renders a `FITSImage` into an `MTKView` with linear stretch.
/// Stretch functions other than linear arrive in FITS-10.
public final class FITSRenderer: NSObject, MTKViewDelegate {
    public let device: MTLDevice

    private let commandQueue: MTLCommandQueue
    private let pipelineState: MTLRenderPipelineState
    private let vertexBuffer: MTLBuffer

    public var texture: MTLTexture?
    public private(set) var image: FITSImage?
    public private(set) var displayImage: DisplayImage?
    public var usesViewportRaster: Bool { displayImage != nil && texture == nil }
    public let viewport: ViewportObservable
    public var transform: ViewTransform {
        get { viewport.transform }
        set { viewport.transform = newValue }
    }
    private var hasFittedImage = false
    public var vmin: Float {
        get { viewport.vmin }
        set { viewport.vmin = newValue }
    }
    public var vmax: Float {
        get { viewport.vmax }
        set { viewport.vmax = newValue }
    }
    public var stretch: ImageStretch = .linear
    /// Scalar parameter consumed by stretches that need it (currently `.power`'s exponent).
    public var stretchParameter: Float = 2.0
    public var colorMap: ColorMap = .gray {
        didSet {
            if oldValue != colorMap {
                rebuildLUT()
            }
        }
    }

    private var cdfBuffer: MTLBuffer?
    private var cdfLength: Int = 0
    private var cdfLevels: RasterLevels?
    private(set) var currentCDF: [Float] = []
    private var lutBuffer: MTLBuffer?
    private var lutLength: Int = 0

    public init(
        device: MTLDevice,
        viewport: ViewportObservable,
        pixelFormat: MTLPixelFormat = .bgra8Unorm
    ) throws {
        self.device = device
        self.viewport = viewport
        guard let queue = device.makeCommandQueue() else {
            throw RenderError.metalUnavailable
        }
        self.commandQueue = queue

        guard let shaderURL = Bundle.module.url(forResource: "Shaders", withExtension: "metal") else {
            throw RenderError.shaderCompilationFailed("Shaders.metal not found in bundle")
        }
        let source = try String(contentsOf: shaderURL, encoding: .utf8)
        let compileOptions = MTLCompileOptions()
        compileOptions.fastMathEnabled = false
        let library = try device.makeLibrary(source: source, options: compileOptions)
        guard
            let vertexFn = library.makeFunction(name: "vertexMain"),
            let fragmentFn = library.makeFunction(name: "fragmentMain")
        else {
            throw RenderError.shaderCompilationFailed("vertexMain / fragmentMain not found")
        }

        let desc = MTLRenderPipelineDescriptor()
        desc.vertexFunction = vertexFn
        desc.fragmentFunction = fragmentFn
        desc.colorAttachments[0].pixelFormat = pixelFormat
        self.pipelineState = try device.makeRenderPipelineState(descriptor: desc)

        // A full-screen quad; the fragment maps device-pixel centres to image pixels.
        let vertices: [Vertex] = [
            Vertex(position: SIMD2(0, 0)),
            Vertex(position: SIMD2(1, 0)),
            Vertex(position: SIMD2(0, 1)),
            Vertex(position: SIMD2(1, 1)),
        ]
        guard
            let buf = device.makeBuffer(
                bytes: vertices,
                length: MemoryLayout<Vertex>.stride * vertices.count,
                options: .storageModeShared
            )
        else { throw RenderError.metalUnavailable }
        self.vertexBuffer = buf
        super.init()
        rebuildLUT()
    }

    private func rebuildLUT() {
        let entries = ColorTable.cached(colorMap).entries
        lutLength = entries.count
        lutBuffer = entries.withUnsafeBufferPointer { ptr in
            device.makeBuffer(
                bytes: ptr.baseAddress!, length: entries.count * MemoryLayout<RGBA8>.stride,
                options: .storageModeShared
            )
        }
    }

    public func setImage(_ image: FITSImage, revision: Int) throws {
        let display = DisplayImage(image: image, revision: revision)
        try setDisplayImage(display, sourceImage: image)
    }

    public func setDisplayImage(_ display: DisplayImage, sourceImage image: FITSImage) throws {
        self.image = image
        self.displayImage = display
        self.texture = try? MetalTextureFactory.makeTexture(from: display, device: device)
        hasFittedImage = false
        let size = viewport.viewSizePoints
        if size.width > 0, size.height > 0 {
            transform = ViewTransform.fit(
                imageSize: SIMD2(Double(image.width), Double(image.height)),
                viewSize: SIMD2(Double(size.width), Double(size.height))
            )
            hasFittedImage = true
        }
        self.vmin = display.initialLevels.vmin
        self.vmax = display.initialLevels.vmax
        cdfLevels = nil
        updateCDFIfNeeded()
    }

    func updateCDFIfNeeded() {
        guard let displayImage else { return }
        let levels = RasterLevels(vmin: vmin, vmax: vmax)
        guard levels != cdfLevels else { return }
        let cdf = RasterCDF.make(sortedFiniteSample: displayImage.sortedFiniteSample, levels: levels)
        let bytes = cdf.count * MemoryLayout<Float>.size
        cdfBuffer = cdf.withUnsafeBufferPointer {
            device.makeBuffer(bytes: $0.baseAddress!, length: bytes, options: .storageModeShared)
        }
        currentCDF = cdf
        cdfLength = cdf.count
        cdfLevels = levels
    }

    // MARK: - MTKViewDelegate

    public func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        let pointSize = view.bounds.size
        guard pointSize.width > 0, pointSize.height > 0 else { return }
        viewport.viewSizePoints = pointSize
        if let displayImage, !hasFittedImage {
            transform = ViewTransform.fit(
                imageSize: SIMD2(Double(displayImage.width), Double(displayImage.height)),
                viewSize: SIMD2(Double(pointSize.width), Double(pointSize.height))
            )
            hasFittedImage = true
        }
    }

    public func draw(in view: MTKView) {
        guard
            let drawable = view.currentDrawable,
            let descriptor = view.currentRenderPassDescriptor,
            let command = commandQueue.makeCommandBuffer()
        else { return }
        let bounds = view.bounds
        guard encodeRender(
            command: command, descriptor: descriptor, target: drawable.texture,
            viewSize: bounds.size
        ) else { return }
        command.present(drawable)
        command.commit()
    }

    /// Shared encoding path for the on-screen drawable and parity tests.
    @discardableResult
    private func encodeRender(
        command: MTLCommandBuffer,
        descriptor: MTLRenderPassDescriptor,
        target: MTLTexture,
        viewSize: CGSize
    ) -> Bool {
        guard let displayImage, let lutBuffer,
              viewSize.width > 0, viewSize.height > 0 else { return false }
        updateCDFIfNeeded()
        let backingScale = Double(target.width) / Double(viewSize.width)
        let mapping = ViewMapping(
            transform: transform,
            viewSize: SIMD2(Double(viewSize.width), Double(viewSize.height)),
            backingScale: backingScale
        )
        let sourceTexture: MTLTexture
        if let texture {
            sourceTexture = texture
        } else {
            guard let viewportTexture = makeViewportTexture(
                displayImage, mapping: mapping, width: target.width, height: target.height
            ) else { return false }
            sourceTexture = viewportTexture
        }
        guard let encoder = command.makeRenderCommandEncoder(descriptor: descriptor) else { return false }
        let coordinates = RasterCoordinateMapping(mapping)
        let levels = RasterLevels(vmin: vmin, vmax: vmax)
        var uniforms = Uniforms(
            vmin: levels.vmin,
            vmax: levels.vmax,
            stretchType: stretch.shaderID,
            cdfLength: Int32(cdfLength),
            stretchParam: stretchParameter,
            imageX0: coordinates.x0,
            imageY0: coordinates.y0,
            deviceStep: coordinates.step,
            imageWidth: Int32(displayImage.width),
            imageHeight: Int32(displayImage.height),
            lutLength: Int32(lutLength),
            usesViewportRaster: usesViewportRaster ? 1 : 0
        )

        encoder.setRenderPipelineState(pipelineState)
        encoder.setVertexBuffer(vertexBuffer, offset: 0, index: 0)
        encoder.setFragmentTexture(sourceTexture, index: 0)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 1)
        if let cdfBuffer {
            encoder.setFragmentBuffer(cdfBuffer, offset: 0, index: 2)
        }
        encoder.setFragmentBuffer(lutBuffer, offset: 0, index: 3)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        encoder.endEncoding()
        return true
    }

    private func makeViewportTexture(
        _ display: DisplayImage, mapping: ViewMapping, width: Int, height: Int
    ) -> MTLTexture? {
        let raster = ViewportRasterizer.renderViewport(
            display, mapping: mapping, width: width, height: height,
            stretch: stretch, levels: RasterLevels(vmin: vmin, vmax: vmax),
            colorMap: colorMap, parameter: stretchParameter
        )
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm, width: width, height: height, mipmapped: false
        )
        descriptor.usage = [.shaderRead]
        descriptor.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: descriptor) else { return nil }
        raster.bytes.withUnsafeBufferPointer { bytes in
            texture.replace(
                region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0,
                withBytes: bytes.baseAddress!, bytesPerRow: width * 4
            )
        }
        return texture
    }

    /// Renders through the production shader into a readable texture for
    /// CPU/Metal parity tests and diagnostics.
    func renderOffscreen(viewSize: CGSize, backingScale: Double) throws -> RasterImage {
        let width = Int((Double(viewSize.width) * backingScale).rounded())
        let height = Int((Double(viewSize.height) * backingScale).rounded())
        guard width > 0, height > 0 else { throw RenderError.renderFailed }
        let textureDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false
        )
        textureDescriptor.usage = [.renderTarget, .shaderRead]
        textureDescriptor.storageMode = .shared
        guard let target = device.makeTexture(descriptor: textureDescriptor),
              let command = commandQueue.makeCommandBuffer() else {
            throw RenderError.renderFailed
        }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        guard encodeRender(
            command: command, descriptor: pass, target: target, viewSize: viewSize
        ) else { throw RenderError.renderFailed }
        command.commit()
        command.waitUntilCompleted()
        guard command.status == .completed else { throw RenderError.renderFailed }
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        bytes.withUnsafeMutableBufferPointer { buffer in
            target.getBytes(
                buffer.baseAddress!, bytesPerRow: width * 4,
                from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0
            )
        }
        for offset in stride(from: 0, to: bytes.count, by: 4) {
            bytes.swapAt(offset, offset + 2) // BGRA target -> RGBA raster
        }
        return RasterImage(width: width, height: height, bytes: bytes)
    }

}
