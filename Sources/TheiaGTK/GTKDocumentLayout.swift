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
}
