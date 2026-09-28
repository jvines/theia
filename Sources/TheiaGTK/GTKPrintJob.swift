import CGtk4
import FITSCore
import FITSRaster
import Foundation
import Glibc
import TheiaKit

enum GTKPrintError: Error {
    case unavailableImage
    case invalidImageSize
    case pdfFailure
    case temporaryFile
}

/// Captures the visible data and display settings before the print dialog opens.
struct GTKPrintSnapshot: Sendable {
    let image: FITSImage
    let revision: Int
    let stretch: ImageStretch
    let colorMap: ColorMap
    let vmin: Float
    let vmax: Float
    let parameter: Float

    @MainActor init?(session: DocumentSession) {
        guard let image = session.displayed else { return nil }
        self.image = image
        revision = session.imageRevision
        stretch = session.view.stretch
        colorMap = session.view.colorMap
        vmin = session.view.vmin
        vmax = session.view.vmax
        parameter = session.view.stretchParameter
    }

    func writePDF(to url: URL) throws {
        let raster = ViewportRasterizer.renderNative(
            DisplayImage(image: image, revision: revision), stretch: stretch,
            levels: RasterLevels(vmin: vmin, vmax: vmax), colorMap: colorMap,
            parameter: parameter
        )
        let width = raster.width, height = raster.height
        guard width > 0, height > 0,
              width <= Int(Int32.max), height <= Int(Int32.max),
              raster.bytes.count == width * height * 4 else {
            throw GTKPrintError.invalidImageSize
        }
        let pageWidth = width > height ? 842.0 : 595.0
        let pageHeight = width > height ? 595.0 : 842.0
        let margin = 36.0
        let scale = min((pageWidth - 2 * margin) / Double(width),
                        (pageHeight - 2 * margin) / Double(height))
        guard let pdf = cairo_pdf_surface_create(url.path, pageWidth, pageHeight),
              let bitmap = cairo_image_surface_create(CAIRO_FORMAT_ARGB32,
                                                       Int32(width), Int32(height)) else {
            throw GTKPrintError.pdfFailure
        }
        defer {
            cairo_surface_destroy(bitmap)
            cairo_surface_destroy(pdf)
        }
        guard cairo_surface_status(pdf) == CAIRO_STATUS_SUCCESS,
              cairo_surface_status(bitmap) == CAIRO_STATUS_SUCCESS,
              let destination = cairo_image_surface_get_data(bitmap) else {
            throw GTKPrintError.pdfFailure
        }
        let stride = Int(cairo_image_surface_get_stride(bitmap))
        for row in 0..<height {
            for column in 0..<width {
                let source = (row * width + column) * 4
                let target = row * stride + column * 4
                let alpha = Int(raster.bytes[source + 3])
                destination[target] = UInt8(Int(raster.bytes[source + 2]) * alpha / 255)
                destination[target + 1] = UInt8(Int(raster.bytes[source + 1]) * alpha / 255)
                destination[target + 2] = UInt8(Int(raster.bytes[source]) * alpha / 255)
                destination[target + 3] = UInt8(alpha)
            }
        }
        cairo_surface_mark_dirty(bitmap)
        guard let context = cairo_create(pdf) else { throw GTKPrintError.pdfFailure }
        cairo_translate(context, (pageWidth - Double(width) * scale) / 2,
                        (pageHeight - Double(height) * scale) / 2)
        cairo_scale(context, scale, scale)
        cairo_set_source_surface(context, bitmap, 0, 0)
        cairo_paint(context)
        cairo_show_page(context)
        cairo_destroy(context)
        cairo_surface_finish(pdf)
        guard cairo_surface_status(pdf) == CAIRO_STATUS_SUCCESS else {
            throw GTKPrintError.pdfFailure
        }
    }
}

/// Prepares a PDF off the GTK thread, then invokes GtkPrintDialog asynchronously.
@MainActor final class GTKPrintJob {
    private let snapshot: GTKPrintSnapshot
    private let parent: UnsafeMutablePointer<GtkWindow>
    private let onComplete: @MainActor (String?) -> Void
    private let fileURL: URL
    private var worker: Task<Void, Never>?
    private var dialog: OpaquePointer?
    private var file: OpaquePointer?
    private var cancellable: UnsafeMutablePointer<GCancellable>?
    private var cancelled = false

    init(snapshot: GTKPrintSnapshot, parent: UnsafeMutablePointer<GtkWindow>,
         onComplete: @escaping @MainActor (String?) -> Void) {
        self.snapshot = snapshot
        self.parent = parent
        self.onComplete = onComplete
        fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("theia-print-\(UUID().uuidString).pdf")
    }

    func start() {
        let snapshot = self.snapshot, fileURL = self.fileURL
        worker = Task.detached(priority: .userInitiated) { [self] in
            do {
                let descriptor = fileURL.path.withCString {
                    Glibc.open($0, O_CREAT | O_EXCL | O_WRONLY, mode_t(0o600))
                }
                guard descriptor >= 0 else { throw GTKPrintError.temporaryFile }
                _ = Glibc.close(descriptor)
                try snapshot.writePDF(to: fileURL)
                await presentDialog()
            } catch {
                await finish(error.localizedDescription)
            }
        }
    }

    func cancel() {
        cancelled = true
        worker?.cancel()
        if let cancellable { g_cancellable_cancel(cancellable) }
    }

    private func presentDialog() {
        guard !cancelled else { finish(nil); return }
        guard let printDialog = gtk_print_dialog_new(),
              let printFile = g_file_new_for_path(fileURL.path),
              let printCancellable = g_cancellable_new() else {
            finish("The print dialog could not be created")
            return
        }
        dialog = printDialog
        file = printFile
        cancellable = printCancellable
        gtk_print_dialog_set_title(printDialog, "Print Theia image")
        let context = Unmanaged.passRetained(self).toOpaque()
        let completed: @convention(c) (OpaquePointer?, OpaquePointer?, gpointer?) -> Void = {
            _, result, userData in
            guard let result, let userData else { return }
            let job = Unmanaged<GTKPrintJob>.fromOpaque(userData).takeRetainedValue()
            MainActor.assumeIsolated { job.completeDialog(result: result) }
        }
        gtk_print_dialog_print_file(printDialog, parent, nil, printFile, printCancellable,
                                    unsafeBitCast(completed, to: GAsyncReadyCallback.self),
                                    context)
    }

    private func completeDialog(result: OpaquePointer) {
        guard let dialog else { finish(nil); return }
        var error: UnsafeMutablePointer<GError>?
        let succeeded = gtk_print_dialog_print_file_finish(dialog, result, &error) != 0
        let dismissed = error.map {
            g_error_matches($0, gtk_dialog_error_quark(),
                            Int32(GTK_DIALOG_ERROR_DISMISSED.rawValue)) != 0
        } ?? false
        let message = !succeeded && !dismissed && !cancelled
            ? error.map { String(cString: $0.pointee.message) } ?? "Printing failed"
            : nil
        if let error { g_error_free(error) }
        finish(message)
    }

    private func finish(_ message: String?) {
        if let file { g_object_unref(UnsafeMutableRawPointer(file)); self.file = nil }
        if let dialog { g_object_unref(UnsafeMutableRawPointer(dialog)); self.dialog = nil }
        if let cancellable {
            g_object_unref(UnsafeMutableRawPointer(cancellable))
            self.cancellable = nil
        }
        try? FileManager.default.removeItem(at: fileURL)
        onComplete(cancelled ? nil : message)
    }
}
