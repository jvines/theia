import SwiftUI
import FITSCore
import TheiaKit

/// All values are in the region's stored frame (FITS 1-based pixel for `image` regions,
/// degrees for `fk5`/`icrs`). Distance unit is preserved when editing the magnitude.
struct RegionEditor: View {
    @Binding var region: Region

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text("color").frame(width: 44, alignment: .trailing).foregroundStyle(.secondary)
                Picker("", selection: colorBinding) {
                    ForEach(RegionList.colors, id: \.self) {
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
            if case .polygon = region.shape {
                Text("vertices").font(.caption).foregroundStyle(.secondary)
            }
            ForEach(Array(RegionList.editorRows(for: region).enumerated()), id: \.offset) { _, row in
                switch row {
                case .coordinates(let label, let x, let y, let xField, let yField):
                    coordinateRow(label: label, x: x, y: y, xField: xField, yField: yField)
                case .distance(let label, let value, let unit, let field):
                    distanceRow(label: label, value: value, unit: unit, field: field)
                case .angle(let value, let field):
                    angleRow(value, field: field)
                }
            }
        }
        .font(.caption)
    }

    private func coordinateRow(label: String, x: Double, y: Double,
                               xField: RegionList.Field, yField: RegionList.Field) -> some View {
        HStack(spacing: 6) {
            Text(label).frame(width: 44, alignment: .trailing).foregroundStyle(.secondary)
            DoubleField(value: x) { set(xField, to: $0) }
            DoubleField(value: y) { set(yField, to: $0) }
        }
    }

    private func distanceRow(label: String, value: Double, unit: Region.Distance.Unit,
                             field: RegionList.Field) -> some View {
        HStack(spacing: 6) {
            Text(label).frame(width: 44, alignment: .trailing).foregroundStyle(.secondary)
            DoubleField(value: value) { set(field, to: $0) }
            Text(RegionList.unitLabel(unit))
                .foregroundStyle(.tertiary)
                .frame(width: 36, alignment: .leading)
        }
    }

    private func angleRow(_ angle: Double, field: RegionList.Field) -> some View {
        HStack(spacing: 6) {
            Text("angle").frame(width: 44, alignment: .trailing).foregroundStyle(.secondary)
            DoubleField(value: angle) { set(field, to: $0) }
            Text("°").foregroundStyle(.tertiary).frame(width: 36, alignment: .leading)
        }
    }

    private func set(_ field: RegionList.Field, to value: Double) {
        if let changed = RegionList.setting(field, to: value, in: region) { region = changed }
    }

    private var colorBinding: Binding<String> {
        Binding(
            get: { RegionList.attribute(.color, in: region) },
            set: { region = RegionList.settingAttribute(.color, to: $0, in: region) }
        )
    }

    private var labelBinding: Binding<String> {
        Binding(
            get: { RegionList.attribute(.label, in: region) },
            set: { region = RegionList.settingAttribute(.label, to: $0, in: region) }
        )
    }

    private var tagBinding: Binding<String> {
        Binding(
            get: { RegionList.attribute(.tag, in: region) },
            set: { region = RegionList.settingAttribute(.tag, to: $0, in: region) }
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
                if !initialised { text = RegionList.editorNumber(value); initialised = true }
            }
            .onChange(of: value) { _, new in
                // Only refresh from outside if the user isn't mid-edit (text already matches).
                if Double(text) != new { text = RegionList.editorNumber(new) }
            }
    }

    private func commit() {
        if let v = Double(text) {
            onCommit(v)
            text = RegionList.editorNumber(v)
        } else {
            text = RegionList.editorNumber(value)
        }
    }
}
