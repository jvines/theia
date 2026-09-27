import Foundation
import FITSCore

/// A document's regions, selection, and region-only edit history.
public struct RegionList: Sendable {
    private struct Snapshot: Sendable, Equatable {
        var regions: [Region] = []
        var selectedIndex: Int?
    }

    private struct Entry: Sendable {
        let before: Snapshot
        let after: Snapshot
    }

    private struct Edit: Sendable {
        let id: UUID
        let index: Int
        let before: Snapshot
    }

    private var state = Snapshot()
    private var undoStack: [Entry] = []
    private var redoStack: [Entry] = []
    private var activeEdit: Edit?
    private let historyLimit = 100

    public init() {}

    public var regions: [Region] { state.regions }
    public var selectedIndex: Int? { state.selectedIndex }
    public var canUndo: Bool { !undoStack.isEmpty }
    public var canRedo: Bool { !redoStack.isEmpty }
    public var activeEditID: UUID? { activeEdit?.id }

    public mutating func select(_ index: Int?) {
        state.selectedIndex = index.flatMap { state.regions.indices.contains($0) ? $0 : nil }
    }

    public mutating func add(_ region: Region) {
        change { state in
            state.regions.append(region)
            state.selectedIndex = state.regions.count - 1
        }
    }

    @discardableResult public mutating func update(at index: Int, with region: Region) -> Bool {
        guard state.regions.indices.contains(index) else { return false }
        change { $0.regions[index] = region }
        return true
    }

    /// Accept only updates from the drag that currently owns the edit group.
    @discardableResult public mutating func updateDuringEdit(
        _ id: UUID, at index: Int, with region: Region
    ) -> Bool {
        guard let activeEdit, activeEdit.id == id, activeEdit.index == index,
              state.regions.indices.contains(index) else { return false }
        state.regions[index] = region
        return true
    }

    @discardableResult public mutating func delete(at index: Int) -> Bool {
        guard state.regions.indices.contains(index) else { return false }
        change { state in
            if let selected = state.selectedIndex {
                if selected == index { state.selectedIndex = nil }
                else if selected > index { state.selectedIndex = selected - 1 }
            }
            state.regions.remove(at: index)
        }
        return true
    }

    @discardableResult public mutating func bringToFront(_ index: Int) -> Bool {
        guard state.regions.indices.contains(index) else { return false }
        change { state in
            let selected = state.selectedIndex
            let region = state.regions.remove(at: index)
            state.regions.append(region)
            if selected == index { state.selectedIndex = state.regions.count - 1 }
            else if let selected, selected > index { state.selectedIndex = selected - 1 }
        }
        return true
    }

    public mutating func clear() {
        replace([], selection: nil)
    }

    /// Replace an entire batch in one undo step.
    public mutating func replace(_ regions: [Region], selection: Int?) {
        change { state in
            state.regions = regions
            state.selectedIndex = selection.flatMap { regions.indices.contains($0) ? $0 : nil }
        }
    }

    /// Hydrate persisted state before the document is exposed; it is the undo baseline.
    public mutating func restore(_ regions: [Region], selection: Int? = nil) {
        state.regions = regions
        state.selectedIndex = selection.flatMap { regions.indices.contains($0) ? $0 : nil }
        undoStack.removeAll()
        redoStack.removeAll()
        activeEdit = nil
    }

    @discardableResult public mutating func beginEdit(at index: Int) -> Bool {
        guard state.regions.indices.contains(index), activeEdit == nil else { return false }
        state.selectedIndex = index
        activeEdit = Edit(id: UUID(), index: index, before: state)
        return true
    }

    @discardableResult public mutating func commitEdit(_ id: UUID) -> Bool {
        guard activeEdit?.id == id else { return false }
        commitEdit()
        return true
    }

    private mutating func commitEdit() {
        guard let edit = activeEdit else { return }
        activeEdit = nil
        record(before: edit.before, after: state)
    }

    @discardableResult public mutating func cancelEdit(_ id: UUID) -> Bool {
        guard activeEdit?.id == id else { return false }
        cancelEdit()
        return true
    }

    private mutating func cancelEdit() {
        guard let edit = activeEdit else { return }
        activeEdit = nil
        state = edit.before
    }

    @discardableResult public mutating func undo() -> Bool {
        commitEdit()
        guard let entry = undoStack.popLast() else { return false }
        redoStack.append(entry)
        state = entry.before
        return true
    }

    @discardableResult public mutating func redo() -> Bool {
        commitEdit()
        guard let entry = redoStack.popLast() else { return false }
        undoStack.append(entry)
        state = entry.after
        return true
    }

    private mutating func change(_ body: (inout Snapshot) -> Void) {
        commitEdit()
        let before = state
        body(&state)
        if let selected = state.selectedIndex, !state.regions.indices.contains(selected) {
            state.selectedIndex = nil
        }
        record(before: before, after: state)
    }

    private mutating func record(before: Snapshot, after: Snapshot) {
        guard before.regions != after.regions else { return }
        undoStack.append(Entry(before: before, after: after))
        if undoStack.count > historyLimit { undoStack.removeFirst() }
        redoStack.removeAll()
    }
}
