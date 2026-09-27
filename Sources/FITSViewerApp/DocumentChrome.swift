import SwiftUI
import FITSCore
import FITSRender
import TheiaKit

struct HDUSidebar: View {
    let file: FITSFile
    @Binding var selection: Int

    var body: some View {
        List(selection: $selection) {
            ForEach(Array(file.hdus.enumerated()), id: \.offset) { idx, hdu in
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text("HDU \(idx)").font(.headline)
                        if let name = hdu.name {
                            Text(name)
                                .font(.headline)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Text(DocumentText.sidebarDetails(for: hdu))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .tag(idx)
            }
        }
        .navigationTitle("HDUs")
    }
}

struct StatusBar: View {
    let hdu: FITSHDU
    let planeCount: Int
    @Binding var plane: Int
    @Binding var planePlaying: Bool
    @Binding var planeFPS: Double
    let cursor: CursorInfo?
    let wcs: WCS?
    let viewport: ImageViewState

    /// Persisted readout frame (shared across windows/sessions).
    @AppStorage(PreferenceKeys.ReadoutFrame.name) private var coordFrameRaw = CelestialFrame.icrs.rawValue
    private var coordFrame: CelestialFrame { CelestialFrame(rawValue: coordFrameRaw) ?? .icrs }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            fullBar
            compactBar
        }
        .font(.body)
        .frame(height: 22)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(.bar)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(AppTheme.accent.opacity(0.6))
                .frame(height: 1)
        }
    }

    @ViewBuilder
    private var planePicker: some View {
        if planeCount > 1 {
            CubePlaneControl(
                plane: $plane,
                planeCount: planeCount,
                playing: $planePlaying,
                fps: $planeFPS
            )
            Divider().frame(height: 14)
        }
    }

    private var fullBar: some View {
        HStack(spacing: 12) {
            planePicker
            pixelBlock(showLabel: true)
            skyBlock
            Spacer(minLength: 12)
            scaleBlock(showLabel: true)
            Text(DocumentText.statusDetails(for: hdu))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    private var compactBar: some View {
        HStack(spacing: 10) {
            planePicker
            pixelBlock(showLabel: false)
            skyBlock
            Spacer(minLength: 8)
            scaleBlock(showLabel: false)
        }
    }

    private func pixelBlock(showLabel: Bool) -> some View {
        HStack(spacing: 4) {
            if showLabel { Text("Pixel").foregroundStyle(.tertiary) }
            if let c = cursor {
                Text(DocumentText.pixelCoordinates(imageX: c.imageX, imageY: c.imageY))
                    .font(.system(.body, design: .monospaced))
                Text("=").foregroundStyle(.secondary)
                Text(DocumentText.pixelValue(c.value))
                    .font(.system(.body, design: .monospaced))
            } else {
                Text("(—, —) = —")
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }
        }
        .lineLimit(1)
    }

    @ViewBuilder
    private var skyBlock: some View {
        if let c = cursor, let wcs, let sky = wcs.pixelToSky(imageX: c.imageX, imageY: c.imageY) {
            Divider().frame(height: 14)
            // Project the native-frame (ra,dec) into the user-selected frame.
            let out = CelestialTransform.convert(lon: sky.ra, lat: sky.dec,
                                                 from: wcs.nativeFrame, to: coordFrame)
            let f = SkyCoordinateFormatter.format(lon: out.lon, lat: out.lat, frame: coordFrame)
            Text("\(f.lonLabel) \(f.lon)")
                .font(.system(.body, design: .monospaced))
                .lineLimit(1)
            Text("\(f.latLabel) \(f.lat)")
                .font(.system(.body, design: .monospaced))
                .lineLimit(1)
            coordFrameMenu
        }
    }

    /// Lets the user pick the readout frame (DS9-style); persisted across windows.
    private var coordFrameMenu: some View {
        Menu(coordFrame.label) {
            ForEach(CelestialFrame.allCases, id: \.self) { frame in
                Button {
                    coordFrameRaw = frame.rawValue
                } label: {
                    if frame == coordFrame { Label(frame.label, systemImage: "checkmark") }
                    else { Text(frame.label) }
                }
            }
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .foregroundStyle(.secondary)
        .help("Coordinate system for the sky readout")
    }

    private func scaleBlock(showLabel: Bool) -> some View {
        HStack(spacing: 4) {
            if showLabel { Text("Scale").foregroundStyle(.secondary) }
            Text("min").foregroundStyle(.tertiary)
            Text(DocumentText.level(viewport.vmin))
                .font(.system(.body, design: .monospaced))
            Text("max").foregroundStyle(.tertiary)
            Text(DocumentText.level(viewport.vmax))
                .font(.system(.body, design: .monospaced))
            Image(systemName: "questionmark.circle")
                .foregroundStyle(.tertiary)
                .imageScale(.small)
        }
        .lineLimit(1)
        .padding(.horizontal, 4)
        .contentShape(.rect)
        .hoverTooltip("Right-click + drag on the image to adjust scale. Horizontal = contrast, vertical = bias. ZScale toolbar button resets.")
    }

}
