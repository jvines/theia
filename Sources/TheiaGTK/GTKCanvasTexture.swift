import CGtk4
import FITSRaster

enum GTKCanvasTexture {
    /// GBytes owns its copy, so the large pixel transfer can finish off the UI thread.
    final class Prepared: @unchecked Sendable {
        let width: Int
        let height: Int
        let bytes: OpaquePointer

        init(raster: RasterImage) {
            width = raster.width
            height = raster.height
            bytes = raster.bytes.withUnsafeBytes { buffer in
                g_bytes_new(buffer.baseAddress, gsize(buffer.count))
            }!
        }

        deinit { g_bytes_unref(bytes) }
    }

    static func prepare(from raster: RasterImage) -> Prepared {
        Prepared(raster: raster)
    }

    static func make(from prepared: Prepared) -> OpaquePointer {
        return gdk_memory_texture_new(
            gint(prepared.width), gint(prepared.height), GDK_MEMORY_R8G8B8A8,
            prepared.bytes, gsize(prepared.width * 4)
        )!
    }
}
