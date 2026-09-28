import CGtk4
import Foundation
import TheiaKit

/// GTK document sidebar backed by the shared inspector models.
@MainActor final class GTKInspectorPanel {
    let widget: UnsafeMutablePointer<GtkWidget>
    let notebook: OpaquePointer
    let regionList: OpaquePointer
    private let session: DocumentSession
    private let headerView: OpaquePointer
    private let photometryView: OpaquePointer
    private let statsView: OpaquePointer
    private var observerID: UUID?
    private var analysisTask: Task<Void, Never>?
    private var syncing = false
    private(set) var headerText = ""
    private(set) var photometryText = ""
    private(set) var statsText = ""

    init(session: DocumentSession) {
        self.session = session
        notebook = OpaquePointer(gtk_notebook_new()!)
        widget = UnsafeMutablePointer<GtkWidget>(notebook)
        regionList = OpaquePointer(gtk_list_box_new()!)
        headerView = OpaquePointer(gtk_text_view_new()!)
        photometryView = OpaquePointer(gtk_text_view_new()!)
        statsView = OpaquePointer(gtk_text_view_new()!)
        gtk_widget_set_size_request(widget, 260, -1)
        gtk_widget_set_vexpand(widget, 1)
        for view in [headerView, photometryView, statsView] {
            let textView = UnsafeMutablePointer<GtkTextView>(view)
            gtk_text_view_set_editable(textView, 0)
            gtk_text_view_set_cursor_visible(textView, 0)
            gtk_text_view_set_monospace(textView, 1)
            gtk_text_view_set_wrap_mode(textView, GTK_WRAP_WORD_CHAR)
        }
        appendPage(headerView, title: "Header")
        appendPage(regionList, title: "Regions")
        appendPage(photometryView, title: "Photometry")
        appendPage(statsView, title: "Stats")
        refreshHeader()
        refreshRegions()
        syncPanelState()
        connectSignals()
        observerID = session.addEventObserver { [weak self] event in
            guard let self else { return }
            switch event.kind {
            case .imageRevisionChanged:
                self.refreshHeader()
                self.refreshRegions()
                self.refreshAnalysis()
            case .regionsChanged:
                self.refreshRegions()
                self.refreshAnalysis()
            case .selectionChanged: self.syncRegionSelection()
            case .panelStateChanged: self.syncPanelState()
            default: break
            }
        }
    }

    func stop() {
        analysisTask?.cancel()
        if let observerID {
            session.removeEventObserver(observerID)
            self.observerID = nil
        }
    }

    private func appendPage(_ child: OpaquePointer, title: String) {
        let scroller = gtk_scrolled_window_new()!
        gtk_scrolled_window_set_child(OpaquePointer(scroller), UnsafeMutablePointer<GtkWidget>(child))
        gtk_notebook_append_page(notebook, scroller, gtk_label_new(title))
    }

    private func connectSignals() {
        let switched: @convention(c) (OpaquePointer?, UnsafeMutablePointer<GtkWidget>?, guint, gpointer?) -> Void = {
            _, _, index, userData in
            guard let userData else { return }
            let panel = Unmanaged<GTKInspectorPanel>.fromOpaque(userData).takeUnretainedValue()
            MainActor.assumeIsolated {
                guard !panel.syncing, Int(index) < InspectorTab.allCases.count else { return }
                panel.session.inspectorTab = InspectorTab.allCases[Int(index)]
            }
        }
        let selected: @convention(c) (OpaquePointer?, UnsafeMutablePointer<GtkListBoxRow>?, gpointer?) -> Void = {
            _, row, userData in
            guard let row, let userData else { return }
            let panel = Unmanaged<GTKInspectorPanel>.fromOpaque(userData).takeUnretainedValue()
            MainActor.assumeIsolated {
                guard !panel.syncing else { return }
                panel.session.selectedRegionIndex = Int(gtk_list_box_row_get_index(row))
            }
        }
        let release: GClosureNotify = { userData, _ in
            guard let userData else { return }
            Unmanaged<GTKInspectorPanel>.fromOpaque(userData).release()
        }
        g_signal_connect_data(UnsafeMutableRawPointer(notebook), "switch-page",
                              unsafeBitCast(switched, to: GCallback.self),
                              Unmanaged.passRetained(self).toOpaque(), release,
                              GConnectFlags(rawValue: 0))
        g_signal_connect_data(UnsafeMutableRawPointer(regionList), "row-selected",
                              unsafeBitCast(selected, to: GCallback.self),
                              Unmanaged.passRetained(self).toOpaque(), release,
                              GConnectFlags(rawValue: 0))
    }

    private func setText(_ text: String, in view: OpaquePointer) {
        gtk_text_buffer_set_text(
            gtk_text_view_get_buffer(UnsafeMutablePointer<GtkTextView>(view)), text, -1
        )
    }

    private func refreshHeader() {
        headerText = session.file.hdus[session.hdu].header.cards.map { card in
            let value = card.value?.displayString ?? ""
            let comment = card.comment.map { " / \($0)" } ?? ""
            return "\(card.keyword.padding(toLength: 8, withPad: " ", startingAt: 0))  \(value)\(comment)"
        }.joined(separator: "\n")
        setText(headerText, in: headerView)
    }

    private func refreshRegions() {
        syncing = true
        defer { syncing = false }
        let listWidget = UnsafeMutablePointer<GtkWidget>(regionList)
        while let child = gtk_widget_get_first_child(listWidget) {
            gtk_list_box_remove(regionList, child)
        }
        for (index, region) in session.regions.enumerated() {
            let label = gtk_label_new("\(index + 1). \(RegionList.summary(for: region))")!
            gtk_label_set_xalign(OpaquePointer(label), 0)
            gtk_list_box_append(regionList, label)
        }
        if let index = session.selectedRegionIndex,
           let row = gtk_list_box_get_row_at_index(regionList, gint(index)) {
            gtk_list_box_select_row(regionList, row)
        }
    }

    private func syncRegionSelection() {
        guard !syncing else { return }
        syncing = true
        defer { syncing = false }
        if let index = session.selectedRegionIndex,
           let row = gtk_list_box_get_row_at_index(regionList, gint(index)) {
            gtk_list_box_select_row(regionList, row)
        } else {
            gtk_list_box_unselect_all(regionList)
        }
    }

    private func syncPanelState() {
        gtk_widget_set_visible(widget, session.inspectorVisible ? 1 : 0)
        syncing = true
        let index = InspectorTab.allCases.firstIndex(of: session.inspectorTab) ?? 0
        gtk_notebook_set_current_page(notebook, gint(index))
        syncing = false
        refreshAnalysis()
    }

    private func refreshAnalysis() {
        analysisTask?.cancel()
        guard session.inspectorVisible else { return }
        switch session.inspectorTab {
        case .photometry:
            session.photometry.refresh(regions: session.regions, image: session.displayed,
                                       imageRevision: session.imageRevision, wcs: session.displayedWCS)
            updatePhotometry()
            analysisTask = Task { @MainActor [weak self] in
                guard let self else { return }
                await self.session.photometry.idle()
                if !Task.isCancelled { self.updatePhotometry() }
            }
        case .stats:
            session.statistics.refresh(image: session.displayed,
                                       imageRevision: session.imageRevision)
            updateStats()
            analysisTask = Task { @MainActor [weak self] in
                guard let self else { return }
                await self.session.statistics.idle()
                if !Task.isCancelled { self.updateStats() }
            }
        case .header, .regions: break
        }
    }

    private func updatePhotometry() {
        let rows = session.photometry.groups.flatMap { group in
            group.rows.map { row in
                let sum = row.result.map { String(format: "%.4g", $0.sum) } ?? "…"
                return "\(row.id + 1)  \(RegionList.summary(for: row.region))  sum \(sum)"
            }
        }
        photometryText = rows.isEmpty ? "No regions" : rows.joined(separator: "\n")
        setText(photometryText, in: photometryView)
    }

    private func updateStats() {
        guard let result = session.statistics.summary else {
            statsText = session.statistics.isComputing ? "Computing…" : "No image"
            setText(statsText, in: statsView)
            return
        }
        let lines = [
            "Size       \(result.width) × \(result.height)",
            "Pixels     \(result.n)",
            "NaN        \(result.nans)",
            "Min        \(ImageStatisticsSummary.format(result.min))",
            "Max        \(ImageStatisticsSummary.format(result.max))",
            "Mean       \(ImageStatisticsSummary.format(result.mean))",
            "Median     \(ImageStatisticsSummary.format(result.median))",
            "Std. dev.  \(ImageStatisticsSummary.format(result.stddev))",
        ]
        statsText = lines.joined(separator: "\n")
        setText(statsText, in: statsView)
    }
}
