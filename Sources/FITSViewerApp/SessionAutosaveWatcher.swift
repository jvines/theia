import SwiftUI
import FITSCore
import FITSRender
import TheiaKit

/// Invisible helper view that owns all the `.onChange` watchers used by `DocumentView`
/// to trigger a session autosave. Kept separate so DocumentView's body stays under
/// the SwiftUI type-checker's complexity budget.
struct SessionAutosaveWatcher: View {
    let regions: [Region]
    let stretch: ImageStretch
    let colorMap: ColorMap
    let drawMode: DrawMode
    let showWCSGrid: Bool
    let showCompass: Bool
    let showColorBar: Bool
    let selectedHDU: Int
    let selectedPlane: Int
    let contourEnabled: Bool
    let contourCount: Int
    let save: () -> Void

    var body: some View {
        Color.clear
            .onChange(of: regions.count) { _, _ in save() }
            .onChange(of: regionDigest)  { _, _ in save() }
            .onChange(of: stretch)       { _, _ in save() }
            .onChange(of: colorMap)      { _, _ in save() }
            .onChange(of: drawMode)      { _, _ in save() }
            .onChange(of: showWCSGrid)   { _, _ in save() }
            .onChange(of: showCompass)   { _, _ in save() }
            .onChange(of: showColorBar)  { _, _ in save() }
            .onChange(of: selectedHDU)   { _, _ in save() }
            .onChange(of: selectedPlane) { _, _ in save() }
            .onChange(of: contourEnabled){ _, _ in save() }
            .onChange(of: contourCount)  { _, _ in save() }
    }

    // Cheap-ish digest of the regions list to catch edits that don't change count.
    private var regionDigest: Int {
        var h = Hasher()
        for r in regions {
            h.combine(r.frame.rawValue)
            switch r.shape {
            case .circle(let c, let radius):
                h.combine("c"); h.combine(c.x); h.combine(c.y); h.combine(radius.value); h.combine(radius.unit.rawValue)
            case .box(let c, let w, let hh, let a):
                h.combine("b"); h.combine(c.x); h.combine(c.y); h.combine(w.value); h.combine(hh.value); h.combine(a)
            case .ellipse(let c, let rx, let ry, let a):
                h.combine("e"); h.combine(c.x); h.combine(c.y); h.combine(rx.value); h.combine(ry.value); h.combine(a)
            case .annulus(let c, let rIn, let rOut):
                h.combine("a"); h.combine(c.x); h.combine(c.y); h.combine(rIn.value); h.combine(rOut.value)
            case .polygon(let pts):
                h.combine("p")
                for p in pts { h.combine(p.x); h.combine(p.y) }
            case .point(let p):
                h.combine("pt"); h.combine(p.x); h.combine(p.y)
            }
        }
        return h.finalize()
    }
}
