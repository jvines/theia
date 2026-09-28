import FITSCore
import FITSRaster
import Foundation
import Glibc
import TheiaKit

enum GTKCubeVideoExport {
    enum ExportError: LocalizedError {
        case invalidCube
        case encoderUnavailable
        case encodingFailed(Int32)

        var errorDescription: String? {
            switch self {
            case .invalidCube: return "The selected HDU has no cube planes"
            case .encoderUnavailable: return "FFmpeg with an H.264 encoder is required to export MP4"
            case .encodingFailed(let status): return "FFmpeg failed to encode the cube (status \(status))"
            }
        }
    }

    static func write(_ snapshot: CubeRenderSnapshot, to url: URL,
                      encoder: URL? = nil) throws {
        let hdu = snapshot.hdu
        guard hdu.naxis == 3, hdu.axes.count >= 3,
              hdu.axes[0] > 0, hdu.axes[1] > 0, hdu.axes[2] > 0,
              snapshot.fps > 0 else { throw ExportError.invalidCube }
        guard let executable = encoder ?? locateEncoder() else { throw ExportError.encoderUnavailable }
        let temporary = url.deletingLastPathComponent().appendingPathComponent(
            ".\(url.lastPathComponent).theia-\(UUID().uuidString).mp4"
        )
        defer { try? FileManager.default.removeItem(at: temporary) }

        let process = Process()
        process.executableURL = executable
        process.arguments = [
            "-hide_banner", "-loglevel", "error", "-nostdin", "-y",
            "-f", "rawvideo", "-pixel_format", "rgba",
            "-video_size", "\(hdu.axes[0])x\(hdu.axes[1])",
            "-framerate", String(snapshot.fps), "-i", "pipe:0",
            "-an", "-vf", "pad=ceil(iw/2)*2:ceil(ih/2)*2",
            "-c:v", "libx264", "-pix_fmt", "yuv420p",
            "-movflags", "+faststart", temporary.path,
        ]
        let input = Pipe()
        process.standardInput = input
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run() }
        catch { throw ExportError.encoderUnavailable }

        var writeFailure: Error?
        do {
            for plane in 0..<hdu.axes[2] {
                try Task.checkCancellation()
                let image = try FITSImage(hdu: hdu, plane: plane)
                let display = DisplayImage(image: image, revision: plane)
                let frame = ViewportRasterizer.renderNative(
                    display, stretch: snapshot.stretch,
                    levels: RasterLevels(vmin: snapshot.vmin, vmax: snapshot.vmax),
                    colorMap: snapshot.colorMap, parameter: snapshot.stretchParameter
                )
                try input.fileHandleForWriting.write(contentsOf: Data(frame.bytes))
            }
        } catch {
            writeFailure = error
        }
        try? input.fileHandleForWriting.close()
        if writeFailure != nil && process.isRunning { process.terminate() }
        process.waitUntilExit()
        if let writeFailure { throw writeFailure }
        guard process.terminationStatus == 0 else {
            throw ExportError.encodingFailed(process.terminationStatus)
        }
        let renameResult = temporary.path.withCString { source in
            url.path.withCString { destination in Glibc.rename(source, destination) }
        }
        guard renameResult == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
    }

    private static func locateEncoder() -> URL? {
        let executable = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
        let bundled = executable.deletingLastPathComponent().appendingPathComponent("ffmpeg")
        if FileManager.default.isExecutableFile(atPath: bundled.path) { return bundled }
        let paths = (ProcessInfo.processInfo.environment["PATH"] ?? "")
            .split(separator: ":").map(String.init)
        for directory in paths {
            let candidate = URL(fileURLWithPath: directory).appendingPathComponent("ffmpeg")
            if FileManager.default.isExecutableFile(atPath: candidate.path) { return candidate }
        }
        return nil
    }
}
