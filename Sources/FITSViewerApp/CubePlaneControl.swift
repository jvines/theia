import SwiftUI

/// Compact navigation control for a NAXIS=3 FITS cube. Play / pause auto-advances
/// the plane at `fps` frames per second; the slider lets you scrub directly; the
/// stepper sets playback rate.
struct CubePlaneControl: View {
    @Binding var plane: Int
    let planeCount: Int
    @Binding var playing: Bool
    @Binding var fps: Double

    var body: some View {
        HStack(spacing: 4) {
            Text("Plane").foregroundStyle(.secondary)
            Button {
                playing.toggle()
            } label: {
                Image(systemName: playing ? "pause.fill" : "play.fill")
                    .imageScale(.small)
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
            Slider(
                value: Binding(
                    get: { Double(plane) },
                    set: { plane = Int($0.rounded()) }
                ),
                in: 0...Double(max(planeCount - 1, 1)),
                step: 1
            )
            .controlSize(.small)
            .frame(width: 100)
            Text("\(plane + 1)/\(planeCount)")
                .font(.system(.caption, design: .monospaced))
                .monospacedDigit()
                .frame(minWidth: 44, alignment: .trailing)
            Stepper(value: $fps, in: 1...30, step: 1) {
                Text("\(Int(fps)) fps")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .frame(minWidth: 36, alignment: .trailing)
            }
            .controlSize(.mini)
        }
        .hoverTooltip("Cube plane. ▶ / ⏸ auto-advances at the chosen fps. Slider scrubs. Arrow keys ←/→ also step.")
    }
}
