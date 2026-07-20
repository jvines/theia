import SwiftUI

/// SwiftUI hover-tooltip built from `onHover` + a delayed `popover`. Works
/// reliably regardless of the wrapped content's hit-test behavior.
public struct HoverTooltip<Label: View>: View {
    public let tip: String
    public let delay: Double
    public let label: () -> Label

    @State private var hovering = false
    @State private var present = false

    public init(
        tip: String,
        delay: Double = 0.5,
        @ViewBuilder label: @escaping () -> Label
    ) {
        self.tip = tip
        self.delay = delay
        self.label = label
    }

    public var body: some View {
        label()
            .onHover { isHovering in
                hovering = isHovering
                if isHovering {
                    DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                        if hovering { present = true }
                    }
                } else {
                    present = false
                }
            }
            .popover(isPresented: $present, arrowEdge: .top) {
                Text(tip)
                    .font(.callout)
                    .lineLimit(nil)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(width: 280, alignment: .leading)
                    .padding(12)
                    .onHover { stillThere in
                        if !stillThere { present = false }
                    }
            }
    }
}

/// Convenience modifier so you can attach the hover tooltip to any view inline.
public extension View {
    func hoverTooltip(_ tip: String, delay: Double = 0.5) -> some View {
        HoverTooltip(tip: tip, delay: delay) { self }
    }
}
