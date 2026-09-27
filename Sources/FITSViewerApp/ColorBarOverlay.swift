import SwiftUI
import FITSCore
import FITSRender
import TheiaKit

/// Vertical color bar drawn over the right edge of `FITSImageView`. Reflects the
/// current colour map and ticks the active vmin/vmax/midpoint so the user can read
/// physical values straight off the swatch.
struct ColorBarOverlay: View {
    let colorMap: ColorMap
    let viewport: ImageViewState

    private static let barWidth: CGFloat = 14
    private static let labelGap: CGFloat = 6
    private static let labelWidth: CGFloat = 70
    private static let trailing: CGFloat = 12
    private static let topBottomPad: CGFloat = 24

    var body: some View {
        GeometryReader { geo in
            HStack(alignment: .top, spacing: Self.labelGap) {
                Spacer()
                tickLabels(height: geo.size.height - 2 * Self.topBottomPad)
                gradient
                    .frame(width: Self.barWidth, height: geo.size.height - 2 * Self.topBottomPad)
                    .overlay(
                        RoundedRectangle(cornerRadius: 2)
                            .stroke(Color.white.opacity(0.5), lineWidth: 0.5)
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 2))
            }
            .padding(.top, Self.topBottomPad)
            .padding(.bottom, Self.topBottomPad)
            .padding(.trailing, Self.trailing)
        }
        .allowsHitTesting(false)
    }

    private var gradient: some View {
        // Build a 64-stop gradient sampling the LUT. Top of the bar = vmax, bottom = vmin.
        let stops = (0..<64).map { i -> Gradient.Stop in
            let t = Double(i) / 63.0
            let c = colorMap.sample(Float(t))
            return Gradient.Stop(
                color: Color(red: Double(c.x), green: Double(c.y), blue: Double(c.z)),
                location: t
            )
        }
        return LinearGradient(gradient: Gradient(stops: stops),
                              startPoint: .bottom,
                              endPoint: .top)
    }

    private func tickLabels(height: CGFloat) -> some View {
        let vmin = Double(viewport.vmin)
        let vmax = Double(viewport.vmax)
        return Canvas { context, size in
            let primitives = OverlayScene.colorBarLabelPrimitives(
                vmin: vmin, vmax: vmax,
                labelSize: SIMD2(Double(size.width), Double(size.height))
            )
            OverlayCanvas.draw(primitives, in: context)
        }
        .frame(width: Self.labelWidth, height: height, alignment: .trailing)
    }
}
