import Foundation
import Metal
import FITSCore

public enum RenderError: Error {
    case textureCreationFailed
    case metalUnavailable
    case shaderCompilationFailed(String)
}

public enum MetalTextureFactory {
    /// Uploads the image's physical pixel values into a single-channel `r32Float`
    /// 2D texture, preserving NaN (from BLANK / float NaN) for downstream stretches.
    public static func makeTexture(from image: FITSImage, device: MTLDevice) throws -> MTLTexture {
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .r32Float,
            width: image.width,
            height: image.height,
            mipmapped: false
        )
        desc.usage = [.shaderRead]
        desc.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: desc) else {
            throw RenderError.textureCreationFailed
        }
        let pixels = image.normalizedFloat32()
        let region = MTLRegionMake2D(0, 0, image.width, image.height)
        let bytesPerRow = image.width * MemoryLayout<Float>.size
        pixels.withUnsafeBufferPointer { buf in
            texture.replace(
                region: region,
                mipmapLevel: 0,
                withBytes: buf.baseAddress!,
                bytesPerRow: bytesPerRow
            )
        }
        return texture
    }
}
