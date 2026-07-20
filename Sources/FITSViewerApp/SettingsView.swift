import SwiftUI
import FITSCore

struct SettingsView: View {
    var body: some View {
        DefaultsTab()
            .frame(width: 520, height: 360)
    }
}

private struct DefaultsTab: View {
    @State private var stretch: ImageStretch = UserPreferences.shared.defaultStretch
    @State private var colorMap: ColorMap = UserPreferences.shared.defaultColorMap
    @State private var contrast: Double = UserPreferences.shared.zscaleContrast
    @State private var pixelTableSize: Int = UserPreferences.shared.pixelTableSize
    @State private var regionColor: String = UserPreferences.shared.regionColor

    var body: some View {
        Form {
            Section("Display") {
                Picker("Default stretch", selection: $stretch) {
                    ForEach(ImageStretch.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                .onChange(of: stretch) { _, new in UserPreferences.shared.defaultStretch = new }

                Picker("Default colormap", selection: $colorMap) {
                    ForEach(ColorMap.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                .onChange(of: colorMap) { _, new in UserPreferences.shared.defaultColorMap = new }
            }
            Section("Scaling") {
                HStack {
                    Text("ZScale contrast")
                    Slider(value: $contrast, in: 0.05...1.0)
                        .onChange(of: contrast) { _, new in UserPreferences.shared.zscaleContrast = new }
                    Text(String(format: "%.2f", contrast))
                        .font(.system(.body, design: .monospaced))
                        .frame(width: 50, alignment: .trailing)
                }
            }
            Section("Tools") {
                Picker("Pixel table size", selection: $pixelTableSize) {
                    Text("5×5").tag(5)
                    Text("7×7").tag(7)
                    Text("9×9").tag(9)
                    Text("11×11").tag(11)
                }
                .onChange(of: pixelTableSize) { _, new in UserPreferences.shared.pixelTableSize = new }
                TextField("Region color", text: $regionColor)
                    .onChange(of: regionColor) { _, new in UserPreferences.shared.regionColor = new }
            }
            Text("Defaults apply to documents opened after this change.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
        .padding()
    }
}
