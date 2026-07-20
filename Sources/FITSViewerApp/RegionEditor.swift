import SwiftUI
import FITSCore

/// Numeric editor for a single `Region`. Surfaces shape-specific fields:
///   - circle: center x/y, radius
///   - box: center x/y, width, height, angle
///   - ellipse: center x/y, rx, ry, angle
///   - annulus: center x/y, inner & outer radius
///   - polygon: vertex list with per-vertex x/y
///   - point: x/y
///
/// All values are in the region's stored frame (FITS 1-based pixel for `image` regions,
/// degrees for `fk5`/`icrs`). Distance unit is preserved when editing the magnitude.
struct RegionEditor: View {
    @Binding var region: Region

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Attributes row: color + text label apply to every shape.
            HStack(spacing: 6) {
                Text("color").frame(width: 44, alignment: .trailing).foregroundStyle(.secondary)
                Picker("", selection: colorBinding) {
                    ForEach(["green", "red", "yellow", "cyan", "magenta", "blue", "white"], id: \.self) {
                        Text($0.capitalized).tag($0)
                    }
                }
                .pickerStyle(.menu)
                .frame(width: 120)
            }
            HStack(spacing: 6) {
                Text("label").frame(width: 44, alignment: .trailing).foregroundStyle(.secondary)
                TextField("optional", text: labelBinding)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 180)
            }
            HStack(spacing: 6) {
                Text("tag").frame(width: 44, alignment: .trailing).foregroundStyle(.secondary)
                TextField("group name", text: tagBinding)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 180)
            }
            switch region.shape {
            case .circle(let c, let r):
                centerRow(c) { newC in
                    region = with(shape: .circle(center: newC, radius: r))
                }
                distanceRow(label: "radius", value: r) { newR in
                    region = with(shape: .circle(center: c, radius: newR))
                }
            case .box(let c, let w, let h, let a):
                centerRow(c) { newC in
                    region = with(shape: .box(center: newC, width: w, height: h, angle: a))
                }
                distanceRow(label: "width", value: w) { newW in
                    region = with(shape: .box(center: c, width: newW, height: h, angle: a))
                }
                distanceRow(label: "height", value: h) { newH in
                    region = with(shape: .box(center: c, width: w, height: newH, angle: a))
                }
                angleRow(a) { newA in
                    region = with(shape: .box(center: c, width: w, height: h, angle: newA))
                }
            case .ellipse(let c, let rx, let ry, let a):
                centerRow(c) { newC in
                    region = with(shape: .ellipse(center: newC, rx: rx, ry: ry, angle: a))
                }
                distanceRow(label: "rx", value: rx) { newR in
                    region = with(shape: .ellipse(center: c, rx: newR, ry: ry, angle: a))
                }
                distanceRow(label: "ry", value: ry) { newR in
                    region = with(shape: .ellipse(center: c, rx: rx, ry: newR, angle: a))
                }
                angleRow(a) { newA in
                    region = with(shape: .ellipse(center: c, rx: rx, ry: ry, angle: newA))
                }
            case .annulus(let c, let rIn, let rOut):
                centerRow(c) { newC in
                    region = with(shape: .annulus(center: newC, innerRadius: rIn, outerRadius: rOut))
                }
                distanceRow(label: "inner", value: rIn) { newR in
                    region = with(shape: .annulus(center: c, innerRadius: newR, outerRadius: rOut))
                }
                distanceRow(label: "outer", value: rOut) { newR in
                    region = with(shape: .annulus(center: c, innerRadius: rIn, outerRadius: newR))
                }
            case .polygon(let pts):
                Text("vertices").font(.caption).foregroundStyle(.secondary)
                ForEach(Array(pts.enumerated()), id: \.offset) { i, p in
                    pointRow(label: "v\(i)", point: p) { newP in
                        var copy = pts
                        copy[i] = newP
                        region = with(shape: .polygon(points: copy))
                    }
                }
            case .point(let p):
                pointRow(label: "pos", point: p) { newP in
                    region = with(shape: .point(newP))
                }
            }
        }
        .font(.caption)
    }

    // MARK: - Rows

    private func centerRow(_ c: Region.Point, _ set: @escaping (Region.Point) -> Void) -> some View {
        pointRow(label: "center", point: c, set: set)
    }

    private func pointRow(label: String, point: Region.Point,
                          set: @escaping (Region.Point) -> Void) -> some View {
        HStack(spacing: 6) {
            Text(label).frame(width: 44, alignment: .trailing).foregroundStyle(.secondary)
            DoubleField(value: point.x) { set(.init(x: $0, y: point.y)) }
            DoubleField(value: point.y) { set(.init(x: point.x, y: $0)) }
        }
    }

    private func distanceRow(label: String, value: Region.Distance,
                             set: @escaping (Region.Distance) -> Void) -> some View {
        HStack(spacing: 6) {
            Text(label).frame(width: 44, alignment: .trailing).foregroundStyle(.secondary)
            DoubleField(value: value.value) { set(.init(value: $0, unit: value.unit)) }
            Text(unitLabel(value.unit))
                .foregroundStyle(.tertiary)
                .frame(width: 36, alignment: .leading)
        }
    }

    private func angleRow(_ angle: Double, _ set: @escaping (Double) -> Void) -> some View {
        HStack(spacing: 6) {
            Text("angle").frame(width: 44, alignment: .trailing).foregroundStyle(.secondary)
            DoubleField(value: angle) { set($0) }
            Text("°").foregroundStyle(.tertiary).frame(width: 36, alignment: .leading)
        }
    }

    private func unitLabel(_ u: Region.Distance.Unit) -> String {
        switch u {
        case .pixel: return "px"
        case .arcsecond: return "″"
        case .arcminute: return "′"
        case .degree: return "°"
        }
    }

    private func with(shape: Region.Shape) -> Region {
        Region(shape: shape, frame: region.frame, attributes: region.attributes)
    }

    private var colorBinding: Binding<String> {
        Binding(
            get: { region.attributes["color"] ?? "green" },
            set: { newColor in
                var attrs = region.attributes
                attrs["color"] = newColor
                region = Region(shape: region.shape, frame: region.frame, attributes: attrs)
            }
        )
    }

    private var labelBinding: Binding<String> {
        Binding(
            get: { region.attributes["text"] ?? "" },
            set: { newText in
                var attrs = region.attributes
                if newText.isEmpty { attrs.removeValue(forKey: "text") } else { attrs["text"] = newText }
                region = Region(shape: region.shape, frame: region.frame, attributes: attrs)
            }
        )
    }

    private var tagBinding: Binding<String> {
        Binding(
            get: { region.attributes["tag"] ?? "" },
            set: { newTag in
                var attrs = region.attributes
                if newTag.isEmpty { attrs.removeValue(forKey: "tag") } else { attrs["tag"] = newTag }
                region = Region(shape: region.shape, frame: region.frame, attributes: attrs)
            }
        )
    }
}

private struct DoubleField: View {
    let value: Double
    let onCommit: (Double) -> Void
    @State private var text: String = ""
    @State private var initialised = false

    var body: some View {
        TextField("", text: $text, onCommit: commit)
            .textFieldStyle(.roundedBorder)
            .font(.system(.body, design: .monospaced))
            .frame(width: 80)
            .onAppear {
                if !initialised { text = format(value); initialised = true }
            }
            .onChange(of: value) { _, new in
                // Only refresh from outside if the user isn't mid-edit (text already matches).
                if Double(text) != new { text = format(new) }
            }
    }

    private func commit() {
        if let v = Double(text) {
            onCommit(v)
            text = format(v)
        } else {
            text = format(value)
        }
    }

    private func format(_ d: Double) -> String {
        if d == d.rounded() && abs(d) < 1e9 { return String(format: "%.0f", d) }
        return String(format: "%.4g", d)
    }
}
