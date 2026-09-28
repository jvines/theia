import CGtk4
import FITSRaster

enum GTKCanvasTexture {
    static func make(from raster: RasterImage) -> OpaquePointer {
        let bytes = raster.bytes.withUnsafeBytes { buffer in
            g_bytes_new(buffer.baseAddress, gsize(buffer.count))
        }!
        defer { g_bytes_unref(bytes) }
        return gdk_memory_texture_new(
            gint(raster.width), gint(raster.height), GDK_MEMORY_R8G8B8A8,
            bytes, gsize(raster.width * 4)
        )!
    }
}
