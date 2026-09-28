import CGtk4
import FITSCore
import Foundation
import TheiaKit

@MainActor private final class GTKHeaderEntryAction {
    private let onChange: @MainActor (String) -> Void

    init(_ onChange: @escaping @MainActor (String) -> Void) { self.onChange = onChange }

    func connect(to entry: OpaquePointer) {
        let context = Unmanaged.passRetained(self).toOpaque()
        let callback: @convention(c) (OpaquePointer?, gpointer?) -> Void = { entry, userData in
            guard let entry, let userData else { return }
            let action = Unmanaged<GTKHeaderEntryAction>.fromOpaque(userData).takeUnretainedValue()
            MainActor.assumeIsolated {
                action.onChange(String(cString: gtk_editable_get_text(entry)))
            }
        }
        g_signal_connect_data(UnsafeMutableRawPointer(entry), "changed",
                              unsafeBitCast(callback, to: GCallback.self), context,
                              { userData, _ in
            guard let userData else { return }
            Unmanaged<GTKHeaderEntryAction>.fromOpaque(userData).release()
        }, GConnectFlags(rawValue: 0))
    }
}

@MainActor private final class GTKHeaderToggleAction {
    private let onToggle: @MainActor () -> Void
    init(_ onToggle: @escaping @MainActor () -> Void) { self.onToggle = onToggle }

    func connect(to toggle: UnsafeMutablePointer<GtkWidget>) {
        let context = Unmanaged.passRetained(self).toOpaque()
        let callback: @convention(c) (OpaquePointer?, gpointer?) -> Void = { _, userData in
            guard let userData else { return }
            let action = Unmanaged<GTKHeaderToggleAction>.fromOpaque(userData).takeUnretainedValue()
            MainActor.assumeIsolated { action.onToggle() }
        }
        g_signal_connect_data(UnsafeMutableRawPointer(toggle), "toggled",
                              unsafeBitCast(callback, to: GCallback.self), context,
                              { userData, _ in
            guard let userData else { return }
            Unmanaged<GTKHeaderToggleAction>.fromOpaque(userData).release()
        }, GConnectFlags(rawValue: 0))
    }
}

/// GTK document sidebar backed by the shared inspector models.
@MainActor final class GTKInspectorPanel {
    let widget: UnsafeMutablePointer<GtkWidget>
    let notebook: OpaquePointer
    let regionList: OpaquePointer
    private let session: DocumentSession
    let headerView: OpaquePointer
    private let headerSearch: OpaquePointer
    private let headerEditButton: UnsafeMutablePointer<GtkWidget>
    private let headerSaveButton: UnsafeMutablePointer<GtkWidget>
    private let headerReadScroller: UnsafeMutablePointer<GtkWidget>
    private let headerEditScroller: UnsafeMutablePointer<GtkWidget>
    let headerEditList: OpaquePointer
    private let photometryView: OpaquePointer
    private let statsView: OpaquePointer
    private var observerID: UUID?
    private var analysisTask: Task<Void, Never>?
    private var syncing = false
    var onSaveHeader: @MainActor (Int, [String]) -> Void = { _, _ in }
    private(set) var headerText = ""
    private(set) var photometryText = ""
    private(set) var statsText = ""

    init(session: DocumentSession) {
        self.session = session
        notebook = OpaquePointer(gtk_notebook_new()!)
        widget = UnsafeMutablePointer<GtkWidget>(notebook)
        regionList = OpaquePointer(gtk_list_box_new()!)
        headerView = OpaquePointer(gtk_text_view_new()!)
        headerSearch = OpaquePointer(gtk_entry_new()!)
        headerEditButton = gtk_toggle_button_new_with_label("Edit")!
        headerSaveButton = gtk_button_new_with_label("Save modified…")!
        headerReadScroller = gtk_scrolled_window_new()!
        headerEditScroller = gtk_scrolled_window_new()!
        headerEditList = OpaquePointer(gtk_list_box_new()!)
        photometryView = OpaquePointer(gtk_text_view_new()!)
        statsView = OpaquePointer(gtk_text_view_new()!)
        gtk_widget_set_size_request(widget, 260, -1)
        // Explicit, so the header filter's hexpand does not propagate up and
        // make the inspector split spare width with the image.
        gtk_widget_set_hexpand(widget, 0)
        gtk_widget_set_vexpand(widget, 1)
        for view in [headerView, photometryView, statsView] {
            let textView = UnsafeMutablePointer<GtkTextView>(view)
            gtk_text_view_set_editable(textView, 0)
            gtk_text_view_set_cursor_visible(textView, 0)
            gtk_text_view_set_monospace(textView, 1)
            // Header cards stay one per line, as in the Mac table; the
            // scroller pans across long comments.
            gtk_text_view_set_wrap_mode(textView, view == headerView ? GTK_WRAP_NONE : GTK_WRAP_WORD_CHAR)
        }
        appendHeaderPage()
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

    private func appendHeaderPage() {
        let page = UnsafeMutablePointer<GtkBox>(OpaquePointer(
            gtk_box_new(GTK_ORIENTATION_VERTICAL, 4)!
        ))
        let toolbar = UnsafeMutablePointer<GtkBox>(OpaquePointer(
            gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 4)!
        ))
        gtk_entry_set_placeholder_text(UnsafeMutablePointer<GtkEntry>(headerSearch), "Filter…")
        gtk_widget_set_hexpand(UnsafeMutablePointer<GtkWidget>(headerSearch), 1)
        gtk_box_append(toolbar, UnsafeMutablePointer<GtkWidget>(headerSearch))
        gtk_box_append(toolbar, headerEditButton)
        gtk_box_append(toolbar, headerSaveButton)
        gtk_box_append(page, UnsafeMutablePointer<GtkWidget>(OpaquePointer(toolbar)))
        gtk_scrolled_window_set_child(OpaquePointer(headerReadScroller),
                                      UnsafeMutablePointer<GtkWidget>(headerView))
        gtk_scrolled_window_set_child(OpaquePointer(headerEditScroller),
                                      UnsafeMutablePointer<GtkWidget>(headerEditList))
        for scroller in [headerReadScroller, headerEditScroller] {
            gtk_widget_set_vexpand(scroller, 1)
            gtk_box_append(page, scroller)
        }
        gtk_notebook_append_page(notebook, UnsafeMutablePointer<GtkWidget>(OpaquePointer(page)),
                                 gtk_label_new("Header"))
        GTKHeaderEntryAction { [weak self] value in
            guard let self else { return }
            self.session.headerEditor.search = value
            self.refreshHeader()
        }.connect(to: headerSearch)
        GTKHeaderToggleAction { [weak self] in
            guard let self else { return }
            self.session.headerEditor.editing = gtk_toggle_button_get_active(
                UnsafeMutablePointer<GtkToggleButton>(OpaquePointer(self.headerEditButton))
            ) != 0
            self.refreshHeader()
        }.connect(to: headerEditButton)
        GTKButtonAction { [weak self] in self?.saveHeader() }.connect(to: headerSaveButton)
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
        let hdu = session.hdu
        let editor = session.headerEditor
        let header = session.file.hdus[hdu].header
        let rows = editor.filteredRows(in: header)
        headerText = rows.map { row in
            let value = editor.valueText(for: row.card, at: row.id, hdu: hdu)
            let comment = editor.commentText(for: row.card, at: row.id, hdu: hdu)
            return "\(row.card.keyword.padding(toLength: 8, withPad: " ", startingAt: 0))  \(value)\(comment.isEmpty ? "" : " / \(comment)")"
        }.joined(separator: "\n")
        setText(headerText, in: headerView)
        gtk_widget_set_visible(headerReadScroller, editor.editing ? 0 : 1)
        gtk_widget_set_visible(headerEditScroller, editor.editing ? 1 : 0)
        let list = UnsafeMutablePointer<GtkWidget>(headerEditList)
        while let child = gtk_widget_get_first_child(list) {
            gtk_list_box_remove(headerEditList, child)
        }
        if editor.editing {
            for row in rows { appendEditableHeaderRow(row, hdu: hdu) }
        }
        refreshHeaderSaveButton()
    }

    private func appendEditableHeaderRow(_ row: HeaderRow, hdu: Int) {
        let content = UnsafeMutablePointer<GtkBox>(OpaquePointer(
            gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 4)!
        ))
        let keyword = gtk_label_new(row.card.keyword)!
        gtk_widget_set_size_request(keyword, 75, -1)
        gtk_label_set_xalign(OpaquePointer(keyword), 0)
        gtk_box_append(content, keyword)
        let value = OpaquePointer(gtk_entry_new()!)
        let comment = OpaquePointer(gtk_entry_new()!)
        gtk_editable_set_text(value, session.headerEditor.valueText(
            for: row.card, at: row.id, hdu: hdu
        ))
        gtk_editable_set_text(comment, session.headerEditor.commentText(
            for: row.card, at: row.id, hdu: hdu
        ))
        gtk_widget_set_size_request(UnsafeMutablePointer<GtkWidget>(value), 110, -1)
        gtk_widget_set_hexpand(UnsafeMutablePointer<GtkWidget>(comment), 1)
        gtk_box_append(content, UnsafeMutablePointer<GtkWidget>(value))
        gtk_box_append(content, UnsafeMutablePointer<GtkWidget>(comment))
        gtk_list_box_append(headerEditList, UnsafeMutablePointer<GtkWidget>(OpaquePointer(content)))
        GTKHeaderEntryAction { [weak self] text in
            guard let self else { return }
            self.session.headerEditor.setValue(text, for: row.card, at: row.id, hdu: hdu)
            self.refreshHeaderSaveButton()
        }.connect(to: value)
        GTKHeaderEntryAction { [weak self] text in
            guard let self else { return }
            self.session.headerEditor.setComment(text, for: row.card, at: row.id, hdu: hdu)
            self.refreshHeaderSaveButton()
        }.connect(to: comment)
    }

    private func refreshHeaderSaveButton() {
        gtk_widget_set_sensitive(headerSaveButton,
                                 session.displayed != nil &&
                                 session.headerEditor.editCount(for: session.hdu) > 0 ? 1 : 0)
    }

    private func saveHeader() {
        guard session.displayed != nil else { return }
        let hdu = session.hdu
        guard session.headerEditor.editCount(for: hdu) > 0 else { return }
        let extra = session.headerEditor.serializedExtraCards(
            from: session.file.hdus[hdu].header, hdu: hdu
        )
        onSaveHeader(hdu, extra)
    }

    func didSaveHeader(hdu: Int) {
        session.headerEditor.clearEdits(for: hdu)
        refreshHeader()
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
