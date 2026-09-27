import SwiftUI
import AppKit
import FITSCore
import FITSRender
import TheiaKit

struct FITSImageView: View {
    let hdu: FITSHDU
    let displayed: FITSImage?
    let displayedWCS: WCS?
    let imageRevision: Int
    let stretch: ImageStretch
    let colorMap: ColorMap
    let viewport: ImageViewState
    let interaction: InteractionController
    let showWCSGrid: Bool
    let showCompass: Bool
    let showColorBar: Bool
    let contourSegments: [Contours.LeveledSegments]
    let drawMode: DrawMode
    let regions: [Region]
    let selectedRegionIndex: Int?
    let previewRegion: Region?
    let onCursorChange: (CursorInfo?) -> Void
    let onLineProfile: (SIMD2<Double>, SIMD2<Double>) -> Void
    let onRadialProfile: (SIMD2<Double>, Double) -> Void
    let onGrowthCurve: (SIMD2<Double>, Double) -> Void
    let onMeasure: (SIMD2<Double>, SIMD2<Double>) -> Void
    let onCubeSpectrumAt: (SIMD2<Double>) -> Void
    let onRegionContextMenu: (Int, NSEvent) -> Void
    let remoteCrosshair: SIMD2<Double>?
    let profileGeometry: ProfileGeometry?

    var body: some View {
        if displayed == nil, hdu.isTable, let table = FITSTableLoader.load(hdu) {
            TableExtensionView(table: table)
        } else if let image = displayed {
            let wcs = displayedWCS
            ZStack {
                FITSMetalView(
                    image: image,
                    imageRevision: imageRevision,
                    viewport: viewport,
                    drawMode: drawMode,
                    interactionController: interaction,
                    onCursorChange: onCursorChange,
                    onLineProfile: onLineProfile,
                    onRadialProfile: onRadialProfile,
                    onGrowthCurve: onGrowthCurve,
                    onMeasure: onMeasure,
                    onCubeSpectrumAt: onCubeSpectrumAt,
                    onRegionContextMenu: onRegionContextMenu
                )
                if showWCSGrid, let wcs {
                    WCSGridOverlay(image: image, wcs: wcs, viewport: viewport)
                }
                if !regions.isEmpty || previewRegion != nil {
                    RegionOverlay(regions: regions, selectedIndex: selectedRegionIndex,
                                  previewRegion: previewRegion, wcs: wcs, viewport: viewport)
                }
                if showCompass, let wcs {
                    CompassScaleBarOverlay(wcs: wcs, viewport: viewport)
                }
                if !contourSegments.isEmpty {
                    ContourOverlay(leveled: contourSegments, imageHeight: image.height, viewport: viewport)
                }
                CrosshairOverlay(imagePoint: remoteCrosshair, viewport: viewport)
                ProfileGeometryOverlay(geometry: profileGeometry, viewport: viewport)
                if showColorBar {
                    ColorBarOverlay(colorMap: colorMap, viewport: viewport)
                }
                if AppConfig.isBeta {
                    BetaWatermarkOverlay()
                }
            }
        } else {
            ContentUnavailableView(
                "Nothing to render here",
                systemImage: "questionmark.square.dashed",
                description: Text("This HDU doesn't have 2D image data or a parseable table. Open the Header tab to see what's inside.")
            )
        }
    }
}

/// A small, non-interactive "BETA" badge pinned to the top-trailing corner of the
/// image view. Visible only when `AppConfig.isBeta` is true.
struct BetaWatermarkOverlay: View {
    var body: some View {
        VStack {
            HStack {
                Spacer()
                Text("BETA")
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .foregroundStyle(AppTheme.accent)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(
                        AppTheme.accent.opacity(0.12),
                        in: RoundedRectangle(cornerRadius: 5)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 5)
                            .stroke(AppTheme.accent.opacity(0.35), lineWidth: 0.5)
                    )
                    .padding(.top, 8)
                    .padding(.trailing, 8)
            }
            Spacer()
        }
        .allowsHitTesting(false)
    }
}
