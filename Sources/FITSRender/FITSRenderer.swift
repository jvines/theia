import Foundation
import Metal
import MetalKit
import simd
import FITSCore
import TheiaKit

private struct Vertex {
    var position: SIMD2<Float>
    var uv: SIMD2<Float>
}

private struct Uniforms {
    var mvp: simd_float4x4
    var vmin: Float
    var vmax: Float
    var stretchType: Int32
    var cdfLength: Int32
    var stretchParam: Float
    var _pad: Float = 0
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
    private let samplerState: MTLSamplerState
    private let vertexBuffer: MTLBuffer

    public var texture: MTLTexture?
    public private(set) var image: FITSImage?
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
    private var lutTexture: MTLTexture?
    private let lutSampler: MTLSamplerState

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
        let library = try device.makeLibrary(source: source, options: nil)
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

        let samplerDesc = MTLSamplerDescriptor()
        samplerDesc.minFilter = .nearest
        samplerDesc.magFilter = .nearest
        samplerDesc.sAddressMode = .clampToEdge
        samplerDesc.tAddressMode = .clampToEdge
        guard let sampler = device.makeSamplerState(descriptor: samplerDesc) else {
            throw RenderError.metalUnavailable
        }
        self.samplerState = sampler

        let lutDesc = MTLSamplerDescriptor()
        lutDesc.minFilter = .linear
        lutDesc.magFilter = .linear
        lutDesc.sAddressMode = .clampToEdge
        lutDesc.tAddressMode = .clampToEdge
        guard let ls = device.makeSamplerState(descriptor: lutDesc) else {
            throw RenderError.metalUnavailable
        }
        self.lutSampler = ls

        // Quad in unit image-pixel coords (0,0)-(1,1); MVP scales to actual image dims.
        let vertices: [Vertex] = [
            Vertex(position: SIMD2(0, 0), uv: SIMD2(0, 0)),
            Vertex(position: SIMD2(1, 0), uv: SIMD2(1, 0)),
            Vertex(position: SIMD2(0, 1), uv: SIMD2(0, 1)),
            Vertex(position: SIMD2(1, 1), uv: SIMD2(1, 1)),
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
        let lut = colorMap.lut()
        var rgba = [Float]()
        rgba.reserveCapacity(lut.count * 4)
        for c in lut {
            rgba.append(c.x)
            rgba.append(c.y)
            rgba.append(c.z)
            rgba.append(1)
        }
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba32Float,
            width: lut.count,
            height: 1,
            mipmapped: false
        )
        desc.usage = [.shaderRead]
        desc.storageMode = .shared
        guard let tex = device.makeTexture(descriptor: desc) else { return }
        rgba.withUnsafeBufferPointer { ptr in
            tex.replace(
                region: MTLRegionMake2D(0, 0, lut.count, 1),
                mipmapLevel: 0,
                withBytes: ptr.baseAddress!,
                bytesPerRow: lut.count * MemoryLayout<Float>.size * 4
            )
        }
        lutTexture = tex
    }

    public func setImage(_ image: FITSImage) throws {
        self.image = image
        self.texture = try MetalTextureFactory.makeTexture(from: image, device: device)
        hasFittedImage = false
        let size = viewport.viewSizePoints
        if size.width > 0, size.height > 0 {
            transform = ViewTransform.fit(
                imageSize: SIMD2(Double(image.width), Double(image.height)),
                viewSize: SIMD2(Double(size.width), Double(size.height))
            )
            hasFittedImage = true
        }
        let values = image.physicalValues()
        if let r = image.defaultRange() {
            self.vmin = Float(r.z1)
            self.vmax = Float(r.z2)
        } else if let mm = PixelStatistics.minMax(values) {
            self.vmin = Float(mm.min)
            self.vmax = Float(mm.max)
        }
        // CDF for histogram-equalization stretch.
        if let mm = PixelStatistics.minMax(values), mm.max > mm.min {
            let histogram = PixelStatistics.histogram(values, bins: 256, range: mm.min...mm.max)
            let cdf = histogram.cdf().map(Float.init)
            let bytes = cdf.count * MemoryLayout<Float>.size
            cdfBuffer = cdf.withUnsafeBufferPointer {
                device.makeBuffer(bytes: $0.baseAddress!, length: bytes, options: .storageModeShared)
            }
            cdfLength = cdf.count
        }
    }

    // MARK: - MTKViewDelegate

    public func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        let pointSize = view.bounds.size
        guard pointSize.width > 0, pointSize.height > 0 else { return }
        viewport.viewSizePoints = pointSize
        if let tex = texture, !hasFittedImage {
            transform = ViewTransform.fit(
                imageSize: SIMD2(Double(tex.width), Double(tex.height)),
                viewSize: SIMD2(Double(pointSize.width), Double(pointSize.height))
            )
            hasFittedImage = true
        }
    }

    public func draw(in view: MTKView) {
        guard
            let texture,
            let drawable = view.currentDrawable,
            let descriptor = view.currentRenderPassDescriptor,
            let command = commandQueue.makeCommandBuffer(),
            let encoder = command.makeRenderCommandEncoder(descriptor: descriptor)
        else { return }

        // Use bounds (points) so the transform and shader are in the same coord system
        // as the SwiftUI canvas overlay and mouse events. NDC math is unit-invariant —
        // the system stretches the drawable to the bounds automatically.
        let bounds = view.bounds
        guard bounds.width > 0, bounds.height > 0 else { return }
        let mvp = Self.modelViewProjection(
            imageSize: SIMD2(Double(texture.width), Double(texture.height)),
            viewSize: SIMD2(Double(bounds.width), Double(bounds.height)),
            transform: transform
        )

        var uniforms = Uniforms(
            mvp: mvp,
            vmin: vmin,
            vmax: vmax,
            stretchType: stretch.shaderID,
            cdfLength: Int32(cdfLength),
            stretchParam: stretchParameter
        )

        encoder.setRenderPipelineState(pipelineState)
        encoder.setVertexBuffer(vertexBuffer, offset: 0, index: 0)
        encoder.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 1)
        encoder.setFragmentTexture(texture, index: 0)
        if let lutTexture {
            encoder.setFragmentTexture(lutTexture, index: 1)
        }
        encoder.setFragmentSamplerState(samplerState, index: 0)
        encoder.setFragmentSamplerState(lutSampler, index: 1)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 1)
        if let cdfBuffer {
            encoder.setFragmentBuffer(cdfBuffer, offset: 0, index: 2)
        }
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        encoder.endEncoding()
        command.present(drawable)
        command.commit()
    }

    /// Projects unit quad vertices through image edges into Metal's Y-up NDC.
    /// The centre of texel j lies at image coordinate j, half a pixel from each edge.
    static func modelViewProjection(
        imageSize: SIMD2<Double>,
        viewSize: SIMD2<Double>,
        transform: ViewTransform
    ) -> simd_float4x4 {
        let mapping = ViewMapping(transform: transform, viewSize: viewSize, backingScale: 1)
        let lowerLeft = mapping.imageToViewYUp(SIMD2(-0.5, -0.5))
        let upperRight = mapping.imageToViewYUp(imageSize - SIMD2(repeating: 0.5))
        let a = 2 * Float(upperRight.x - lowerLeft.x) / Float(viewSize.x)
        let b = 2 * Float(upperRight.y - lowerLeft.y) / Float(viewSize.y)
        let cx = 2 * Float(lowerLeft.x) / Float(viewSize.x) - 1
        let cy = 2 * Float(lowerLeft.y) / Float(viewSize.y) - 1
        return simd_float4x4(rows: [
            SIMD4(a, 0, 0, cx),
            SIMD4(0, b, 0, cy),
            SIMD4(0, 0, 1, 0),
            SIMD4(0, 0, 0, 1),
        ])
    }
}
