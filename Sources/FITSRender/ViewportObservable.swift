import Foundation
import SwiftUI
import FITSCore

/// Single source of truth for the on-screen viewport. Owned by SwiftUI, shared by the
/// Metal renderer (writes from fit-to-bounds; reads in `draw`), the gesture handler
/// (writes from pan/zoom), and any overlay views (reads for layout).
///
/// All values are in **points** (bounds-space), not drawable pixels. The renderer
/// applies backing-scale internally when generating its MVP.
public final class ViewportObservable: ObservableObject {
    @Published public var transform: ViewTransform
    @Published public var viewSizePoints: CGSize
    @Published public var vmin: Float
    @Published public var vmax: Float
    /// Scalar parameter for stretches that need it (power exponent today; may grow).
    @Published public var stretchParameter: Float

    public init(
        transform: ViewTransform = ViewTransform(),
        viewSizePoints: CGSize = .zero,
        vmin: Float = 0,
        vmax: Float = 1,
        stretchParameter: Float = 2.0
    ) {
        self.transform = transform
        self.viewSizePoints = viewSizePoints
        self.vmin = vmin
        self.vmax = vmax
        self.stretchParameter = stretchParameter
    }
}
