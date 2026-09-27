import SwiftUI
import AppKit
import UniformTypeIdentifiers
import FITSCore
import FITSRender
import TheiaKit

struct InspectorPanel: View {
    let header: FITSHeader
    @Binding var tab: InspectorTab
    @Binding var regions: [Region]
    let session: DocumentSession
    let imageProvider: () -> FITSImage?
    let onEffect: (Effect) -> Void

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $tab) {
                ForEach(InspectorTab.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .padding(8)
            switch tab {
            case .header: HeaderPanel(header: header, hduIndex: session.hdu,
                                      editor: session.headerEditor, imageProvider: imageProvider)
            case .regions: RegionListPanel(regions: $regions, session: session, onEffect: onEffect)
            case .photometry: PhotometryPanel(session: session)
            case .stats: ImageStatsPanel(session: session)
            }
        }
    }
}

struct RegionListPanel: View {
    @Binding var regions: [Region]
    let session: DocumentSession
    let onEffect: (Effect) -> Void
    @State private var expanded: Set<Int> = []

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Button {
                    performAndApply(.loadRegions)
                } label: { Label("Load…", systemImage: "tray.and.arrow.down") }
                Button {
                    performAndApply(.saveRegions)
                } label: { Label("Save…", systemImage: "tray.and.arrow.up") }
                    .disabled(regions.isEmpty)
                Spacer()
                if !regions.isEmpty {
                    Button(role: .destructive) {
                        session.perform(.clearRegions, origin: .user)
                        expanded.removeAll()
                    } label: { Label("Clear", systemImage: "trash") }
                }
            }
            .controlSize(.small)
            .buttonStyle(.bordered)
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            Divider()
            content
        }
        .onChange(of: session.regionReplacementRevision) { _, _ in expanded.removeAll() }
    }

    @ViewBuilder
    private var content: some View {
        if regions.isEmpty {
            ContentUnavailableView(
                "Nothing marked yet",
                systemImage: "circle.dashed",
                description: Text("Pick a shape in the toolbar's Mode menu and drag on the image to mark a star, source, or region — or Load… an existing .reg file.")
            )
        } else {
            List {
                ForEach(Array(regions.enumerated()), id: \.offset) { idx, region in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Button {
                                if expanded.contains(idx) { expanded.remove(idx) } else { expanded.insert(idx) }
                            } label: {
                                Image(systemName: expanded.contains(idx) ? "chevron.down" : "chevron.right")
                                    .frame(width: 12)
                            }
                            .buttonStyle(.borderless)
                            Image(systemName: icon(for: region))
                            Text(RegionList.summary(for: region))
                                .font(.system(.body, design: .monospaced))
                                .lineLimit(1)
                            Spacer()
                            Button(role: .destructive) {
                                session.perform(.deleteRegion(idx), origin: .user)
                                expanded.remove(idx)
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.borderless)
                        }
                        if expanded.contains(idx) {
                            RegionEditor(region: Binding(
                                get: { regions[idx] },
                                set: { session.perform(.updateRegion(idx, $0), origin: .user) }
                            ))
                            .padding(.leading, 22)
                        }
                    }
                }
            }
        }
    }

    private func icon(for r: Region) -> String {
        switch r.shape {
        case .circle: return "circle"
        case .box: return "rectangle"
        case .ellipse: return "oval"
        case .polygon: return "hexagon"
        case .annulus: return "circle.dotted.circle"
        case .point: return "smallcircle.filled.circle"
        }
    }

    private func performAndApply(_ command: SessionCommand) {
        let outcome = session.perform(command, origin: .user)
        for effect in outcome.effects { onEffect(effect) }
    }
}

struct HeaderPanel: View {
    let header: FITSHeader
    let hduIndex: Int
    @Bindable var editor: HeaderEditor
    let imageProvider: () -> FITSImage?

    var rows: [HeaderRow] { editor.filteredRows(in: header) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                TextField("Filter…", text: $editor.search).textFieldStyle(.roundedBorder)
                Toggle("Edit", isOn: $editor.editing).toggleStyle(.button).controlSize(.small)
                Button {
                    saveEditedFITS()
                } label: { Label("Save modified…", systemImage: "tray.and.arrow.up") }
                .controlSize(.small)
                .disabled(editor.editCount(for: hduIndex) == 0)
            }
            .padding(8)
            if editor.editing {
                List(rows) { row in
                    HStack(spacing: 8) {
                        Text(row.card.keyword)
                            .font(.system(.body, design: .monospaced))
                            .frame(width: 70, alignment: .leading)
                        TextField("value", text: valueBinding(for: row))
                            .textFieldStyle(.roundedBorder)
                            .font(.system(.body, design: .monospaced))
                            .frame(width: 160)
                        TextField("comment", text: commentBinding(for: row))
                            .textFieldStyle(.roundedBorder)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(editor.hasEdit(at: row.id, hdu: hduIndex) ? .primary : .secondary)
                    }
                }
            } else {
                Table(rows) {
                    TableColumn("Keyword") { row in
                        Text(row.card.keyword).font(.system(.body, design: .monospaced))
                    }
                    .width(min: 80, ideal: 100)
                    TableColumn("Value") { row in
                        Text(row.card.value?.displayString ?? "")
                            .font(.system(.body, design: .monospaced))
                            .lineLimit(1)
                    }
                    TableColumn("Comment") { row in
                        Text(row.card.comment ?? "")
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }
            }
            let editCount = editor.editCount(for: hduIndex)
            if editCount > 0 {
                Text("\(editCount) edited card\(editCount == 1 ? "" : "s")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.bottom, 4)
            }
        }
    }

    private func valueBinding(for row: HeaderRow) -> Binding<String> {
        Binding(
            get: { editor.valueText(for: row.card, at: row.id, hdu: hduIndex) },
            set: { editor.setValue($0, for: row.card, at: row.id, hdu: hduIndex) }
        )
    }

    private func commentBinding(for row: HeaderRow) -> Binding<String> {
        Binding(
            get: { editor.commentText(for: row.card, at: row.id, hdu: hduIndex) },
            set: { editor.setComment($0, for: row.card, at: row.id, hdu: hduIndex) }
        )
    }

    private func saveEditedFITS() {
        guard let image = imageProvider() else { NSSound.beep(); return }
        let extra = editor.serializedExtraCards(from: header, hdu: hduIndex)
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "fits") ?? .data]
        panel.nameFieldStringValue = "modified.fits"
        guard let win = NSApp.keyWindow else { return }
        panel.beginSheetModal(for: win) { resp in
            guard resp == .OK, let url = panel.url else { return }
            do {
                try FITSWriter.write(image, to: url, extraCards: extra)
                editor.clearEdits(for: hduIndex)
            } catch {
                let a = NSAlert(error: error)
                a.runModal()
            }
        }
    }
}
