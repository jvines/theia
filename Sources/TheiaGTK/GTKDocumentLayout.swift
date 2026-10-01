/// How a document window arranges its panels for the width it is given.
enum GTKDocumentLayout: Equatable {
    /// HDU list, image and inspector side by side under the menu bar.
    case wide
    /// Menus behind one button, and the HDU list and inspector in a strip
    /// under a full-width image: tiles such as half a 1.5× laptop screen.
    case narrow

    /// Window width, in logical pixels, below which documents turn narrow.
    static let narrowBelow = 1000

    static func mode(forWidth width: Int, narrowBelow: Int) -> GTKDocumentLayout {
        width < narrowBelow ? .narrow : .wide
    }

    /// Height of the narrow strip when the window is tall enough for it.
    static let naturalStripHeight = 280
    /// Most of the image-over-strip stack the strip may take, so short tiles
    /// (a quarter of 1280×800, or 1280×800 at scale 2) still show the image.
    static let maximumStripFraction = 0.4

    static func stripHeight(forStackHeight height: Int) -> Int {
        min(naturalStripHeight, Int(Double(max(0, height)) * maximumStripFraction))
    }
}
