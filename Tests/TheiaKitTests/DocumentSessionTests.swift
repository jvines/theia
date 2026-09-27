import Foundation
import XCTest
import Observation
import FITSCore
@testable import TheiaKit

final class DocumentSessionTests: XCTestCase {
    func testRegionSaveRequestRetainsTheRequestTimeRegions() async throws {
        try await MainActor.run {
            let session = try makeSession()
            let first = Region(shape: .point(.init(x: 2, y: 3)), frame: .image)
            _ = session.perform(.addRegion(first), origin: .user)
            let asked = session.perform(.saveRegions, origin: .user)
            guard case .ask(let question, let request) = asked.effects.first,
                  case .saveRegions(let snapshot) = request else {
                return XCTFail("Saving regions should ask for a path")
            }
            XCTAssertEqual(question, .savePath(suggestedName: "regions.reg", types: ["reg"]))
            XCTAssertEqual(snapshot.regions, [first])
            _ = session.perform(.clearRegions, origin: .user)
            let destination = FileManager.default.temporaryDirectory
                .appendingPathComponent("theia-regions-\(UUID().uuidString).reg")
            defer { try? FileManager.default.removeItem(at: destination) }
            let answered = session.perform(.answer(request, .path(destination)), origin: .user)
            guard case .saveRegions(let saved, let url) = answered.effects.first else {
                return XCTFail("Answer should carry the original regions")
            }
            XCTAssertEqual(url, destination)
            XCTAssertEqual(saved.regions, [first])
            try saved.write(to: destination)
            XCTAssertEqual(try String(contentsOf: destination, encoding: .utf8),
                           RegionFile.format([first]))
            XCTAssertEqual(session.perform(.answer(request, .path(destination)), origin: .user).failure,
                           .invalidPendingRequest)
        }
    }

    func testRegionLoadRequestAcceptsOnePathAndReplacementTracksGeneration() async throws {
        try await MainActor.run {
            let session = try makeSession()
            let initialRevision = session.regionReplacementRevision
            let asked = session.perform(.loadRegions, origin: .user)
            guard case .ask(let question, let request) = asked.effects.first,
                  case .loadRegions(let load) = request else {
                return XCTFail("Loading regions should ask for one path")
            }
            XCTAssertEqual(question, .openPath(types: ["public.plain-text", "public.data"], multiple: false))
            let invalid = session.perform(.answer(request, .paths([])), origin: .user)
            XCTAssertEqual(invalid.failure, .invalidAnswer)
            XCTAssertEqual(invalid.effects, [.alert(title: "Regions not loaded",
                                                   message: "Answer does not match the request",
                                                   style: .warning)])
            let source = URL(fileURLWithPath: "/tmp/theia-regions.reg")
            let answered = session.perform(.answer(request, .paths([source])), origin: .user)
            XCTAssertEqual(answered.effects, [.loadRegions(load, source)])

            let region = Region(shape: .point(.init(x: 9, y: 10)), frame: .image)
            XCTAssertNil(session.perform(.completeRegionLoad(load, [region]), origin: .user).failure)
            XCTAssertEqual(session.regionReplacementRevision, initialRevision + 1)
            session.close()
            XCTAssertEqual(session.perform(.completeRegionLoad(load, []), origin: .user).failure, .documentClosed)
            XCTAssertEqual(session.regions, [region])
        }
    }

    func testRegionLoadCompletionRejectsOlderLoadAndInterveningEdits() async throws {
        try await MainActor.run {
            let session = try makeSession()
            let source = URL(fileURLWithPath: "/tmp/theia-regions.reg")
            @MainActor func acceptLoad() -> RegionLoadRequest {
                let asked = session.perform(.loadRegions, origin: .user)
                guard case .ask(_, let request) = asked.effects.first,
                      case .loadRegions(let load) = request else {
                    XCTFail("Expected region load request")
                    fatalError("Expected region load request")
                }
                XCTAssertEqual(session.perform(.answer(request, .path(source)), origin: .user).effects,
                               [.loadRegions(load, source)])
                return load
            }

            let older = acceptLoad()
            let newer = acceptLoad()
            let first = Region(shape: .point(.init(x: 1, y: 2)), frame: .image)
            let second = Region(shape: .point(.init(x: 3, y: 4)), frame: .image)
            XCTAssertEqual(session.perform(.completeRegionLoad(older, [first]), origin: .user).failure,
                           .supersededRegionLoad)
            XCTAssertNil(session.perform(.completeRegionLoad(newer, [second]), origin: .user).failure)
            XCTAssertEqual(session.regions, [second])

            let stale = acceptLoad()
            _ = session.perform(.addRegion(first), origin: .user)
            XCTAssertEqual(session.perform(.completeRegionLoad(stale, []), origin: .user).failure,
                           .supersededRegionLoad)
            XCTAssertEqual(session.regions, [second, first])
        }
    }

    func testExportQuestionKeepsTheRequestTimeImageAndDisplayParameters() async throws {
        try await MainActor.run {
            let session = try makeSession()
            _ = session.perform(.setStretch(.log), origin: .user)
            _ = session.perform(.setLevels(min: 1, max: 7), origin: .user)
            let outcome = session.perform(.exportImage, origin: .user)
            XCTAssertNil(outcome.failure)
            guard case .ask(let question, let request) = outcome.effects.first else {
                return XCTFail("Export should ask for a path")
            }
            XCTAssertEqual(question, .savePath(suggestedName: "image.png", types: ["png", "tiff"]))
            guard case .exportImage(let snapshot) = request else {
                return XCTFail("Export should carry a render snapshot")
            }
            XCTAssertEqual(snapshot.plane, 0)
            XCTAssertEqual(snapshot.stretch, .log)
            XCTAssertEqual(snapshot.vmin, 1)
            XCTAssertEqual(snapshot.vmax, 7)
            XCTAssertEqual(snapshot.image.physicalValue(x: 0, y: 0), 0)

            _ = session.perform(.selectPlane(1), origin: .user)
            _ = session.perform(.setStretch(.linear), origin: .user)
            let destination = FileManager.default.temporaryDirectory
                .appendingPathComponent("theia-export-\(UUID().uuidString).tiff")
            defer { try? FileManager.default.removeItem(at: destination) }
            let answered = session.perform(.answer(request, .path(destination)), origin: .user)
            XCTAssertNil(answered.failure)
            guard case .exportImage(let saved, let url) = answered.effects.first else {
                return XCTFail("Answer should export the saved snapshot")
            }
            XCTAssertEqual(url, destination)
            XCTAssertEqual(saved.id, snapshot.id)
            XCTAssertEqual(saved.image.physicalValue(x: 0, y: 0), 0)
            try saved.writeImage(to: destination)
            let encoded = try Data(contentsOf: destination)
            XCTAssertEqual(Array(encoded.prefix(4)), [73, 73, 42, 0])
            XCTAssertEqual(Array(encoded.suffix(8)), [0, 0, 0, 255, 0, 0, 0, 255])
            XCTAssertEqual(session.perform(.answer(request, .path(destination)), origin: .user).failure,
                           .invalidPendingRequest)
        }
    }

    func testExportQuestionRejectsScriptAndCancellationAndClosedDocument() async throws {
        try await MainActor.run {
            let session = try makeSession()
            XCTAssertEqual(session.perform(.exportImage, origin: .script).failure,
                           .requiresUserInterface)
            guard case .ask(_, let cancelled) = session.perform(.exportImage, origin: .user).effects.first else {
                return XCTFail("Export should ask for a path")
            }
            XCTAssertTrue(session.perform(.answer(cancelled, .cancelled), origin: .user).effects.isEmpty)
            let replayed = session.perform(.answer(cancelled, .path(URL(fileURLWithPath: "/tmp/no.png"))),
                                           origin: .user)
            XCTAssertEqual(replayed.failure, .invalidPendingRequest)
            XCTAssertEqual(replayed.effects, [.alert(title: "Export not saved",
                                                    message: "Request is no longer pending",
                                                    style: .warning)])
            guard case .ask(_, let pending) = session.perform(.exportImage, origin: .user).effects.first else {
                return XCTFail("Second export should ask for a path")
            }
            XCTAssertEqual(session.perform(.answer(pending, .paths([])), origin: .user).failure,
                           .invalidAnswer)
            XCTAssertEqual(session.perform(.answer(pending, .path(URL(fileURLWithPath: "/tmp/no.png"))),
                                           origin: .script).failure, .requiresUserInterface)
            session.close()
            let closed = session.perform(.answer(pending, .path(URL(fileURLWithPath: "/tmp/no.png"))),
                                         origin: .user)
            XCTAssertEqual(closed.failure, .documentClosed)
            XCTAssertEqual(closed.effects, [.alert(title: "Export not saved",
                                                  message: "Document is closed", style: .warning)])
        }
    }

    func testCubeExportAnswerUsesTheRequestTimeHDU() async throws {
        try await MainActor.run {
            let session = try makeSession()
            let asked = session.perform(.exportCube, origin: .user)
            XCTAssertNil(asked.failure)
            guard case .ask(let question, let request) = asked.effects.first,
                  case .exportCube(let snapshot) = request else {
                return XCTFail("Cube export should ask for an MP4 path")
            }
            XCTAssertEqual(question, .savePath(suggestedName: "session.mp4", types: ["mp4"]))
            XCTAssertEqual(snapshot.hduIndex, 1)
            XCTAssertEqual(snapshot.hdu.axes, [2, 2, 2])
            XCTAssertEqual(snapshot.imageRevision, session.imageRevision)

            session.selectHDU(2)
            let destination = URL(fileURLWithPath: "/tmp/theia-cube-export.mp4")
            let answered = session.perform(.answer(request, .path(destination)), origin: .user)
            XCTAssertNil(answered.failure)
            guard case .exportCube(let saved, let url) = answered.effects.first else {
                return XCTFail("Cube export should use the captured HDU")
            }
            XCTAssertEqual(url, destination)
            XCTAssertEqual(saved.id, snapshot.id)
            XCTAssertEqual(try FITSImage(hdu: saved.hdu, plane: 1).physicalValue(x: 0, y: 0), 4)
            XCTAssertEqual(session.perform(.answer(request, .path(destination)), origin: .user).failure,
                           .invalidPendingRequest)
            XCTAssertEqual(session.perform(.exportCube, origin: .script).failure,
                           .requiresUserInterface)
            XCTAssertEqual(session.perform(.exportCube, origin: .user).failure, .unavailableCube)
        }
    }

    func testToolsMenuUsesSharedSectionsAndTypedActions() async throws {
        try await MainActor.run {
            let session = try makeSession()
            let entries = CommandCatalog.toolsMenu(for: session, workspaceImageCount: 1)
            XCTAssertEqual(entries.compactMap(\.section), [
                .collapseCube, .stackAcrossWindows, .analysis, .filter,
                .transform, .reprojectOnto, .arithmeticVs,
            ])
            XCTAssertEqual(entries.compactMap(\.item).first?.identifier, "tools.collapse.sum")
            XCTAssertEqual(entries.compactMap(\.item).first?.action, .collapse(.sum))
            let stack = entries.compactMap(\.item).first { $0.identifier == "tools.stack.sum" }
            XCTAssertEqual(stack?.enabled, false)
            XCTAssertEqual(stack?.action, .stack(.sum))
            let reproject = entries.compactMap(\.item).first { $0.identifier == "tools.reproject.2" }
            XCTAssertEqual(reproject?.enabled, false)
            let sameShape = entries.compactMap(\.item).first { $0.identifier == "tools.arithmetic.2" }
            XCTAssertEqual(sameShape?.enabled, true)
            XCTAssertEqual(sameShape?.children.first?.action, .binary(.sum, 2))
            let differentShape = entries.compactMap(\.item).first { $0.identifier == "tools.arithmetic.3" }
            XCTAssertEqual(differentShape?.enabled, false)
            XCTAssertTrue(entries.compactMap(\.item).allSatisfy { !$0.tooltip.isEmpty && $0.visible })

            let displayed = try XCTUnwrap(session.displayed)
            session.setDerived(DerivedImage(image: displayed, wcs: nil, label: "Test"))
            let derivedEntries = CommandCatalog.toolsMenu(for: session, workspaceImageCount: 1)
            XCTAssertEqual(derivedEntries.last?.item?.identifier, "tools.showOriginal")
            XCTAssertEqual(derivedEntries.last?.item?.action, .clearDerivedImage)
            XCTAssertTrue(derivedEntries.contains { if case .separator = $0 { return true }; return false })
        }
    }

    func testToolsMenuHidesUnavailableSectionsButKeepsWorkspaceStacking() async throws {
        try await MainActor.run {
            let session = try makeSession()
            session.selectHDU(4)
            let entries = CommandCatalog.toolsMenu(for: session, workspaceImageCount: 2)
            XCTAssertEqual(entries.compactMap(\.section), [
                .stackAcrossWindows, .reprojectOnto, .arithmeticVs,
            ])
            XCTAssertEqual(entries.compactMap(\.item).first { $0.identifier == "tools.stack.sum" }?.enabled, true)
            XCTAssertEqual(entries.compactMap(\.item).first { $0.identifier == "tools.lightCurve" }?.enabled, false)
            XCTAssertEqual(CommandCatalog.toolbarItem("tools", for: session, workspaceImageCount: 2)?.enabled, true)

            session.selectHDU(2)
            let imageEntries = CommandCatalog.toolsMenu(for: session, workspaceImageCount: 1)
            XCTAssertFalse(imageEntries.compactMap(\.section).contains(.collapseCube))
            XCTAssertTrue(imageEntries.compactMap(\.section).contains(.reprojectOnto))
            XCTAssertTrue(imageEntries.compactMap(\.section).contains(.arithmeticVs))
        }
    }

    func testRegionCommandsKeepSelectionAndRejectStaleIndices() async throws {
        try await MainActor.run {
            let session = try makeSession()
            let first = Region(shape: .point(.init(x: 2, y: 3)), frame: .image)
            let second = Region(shape: .point(.init(x: 4, y: 5)), frame: .image)
            var events: [SessionEvent] = []
            session.addEventObserver { events.append($0) }

            XCTAssertNil(session.perform(.addRegion(first), origin: .user).failure)
            XCTAssertEqual(session.regions, [first])
            XCTAssertEqual(session.selectedRegionIndex, 0)
            XCTAssertNil(session.perform(.addRegion(second), origin: .script).failure)
            XCTAssertEqual(session.selectedRegionIndex, 1)

            let replacement = Region(shape: .point(.init(x: 7, y: 8)), frame: .image)
            XCTAssertNil(session.perform(.updateRegion(0, replacement), origin: .user).failure)
            XCTAssertEqual(session.regions, [replacement, second])
            let invalid = session.perform(.deleteRegion(9), origin: .script)
            XCTAssertEqual(invalid.failure, .invalidRegionIndex(9))
            XCTAssertEqual(session.regions, [replacement, second])

            XCTAssertNil(session.perform(.deleteRegion(0), origin: .user).failure)
            XCTAssertEqual(session.regions, [second])
            XCTAssertEqual(session.selectedRegionIndex, 0)
            XCTAssertNil(session.perform(.clearRegions, origin: .user).failure)
            XCTAssertTrue(session.regions.isEmpty)
            XCTAssertNil(session.selectedRegionIndex)
            XCTAssertTrue(events.contains { $0.kind == .regionsChanged && $0.origin == .script })
        }
    }

    func testRegionCopyIsAnEffectAndRegionMenuFollowsSelection() async throws {
        try await MainActor.run {
            let session = try makeSession()
            let region = Region(shape: .point(.init(x: 2, y: 3)), frame: .image)
            _ = session.perform(.addRegion(region), origin: .user)
            let menu = CommandCatalog.regionMenu(for: session)
            XCTAssertEqual(menu.map { $0.item?.identifier ?? "separator" }, [
                "region.load", "region.save", "separator",
                "region.delete", "region.bringToFront", "region.copy", "separator",
                "region.clear", "separator", "region.undo", "region.redo",
            ])
            XCTAssertEqual(menu.compactMap(\.item).first { $0.identifier == "region.save" }?.enabled, true)
            XCTAssertEqual(menu.last?.item?.enabled, false)
            let copied = session.perform(.copyRegion(0), origin: .user)
            XCTAssertEqual(copied.effects, [.copyToClipboard(RegionFile.format([region]))])
            XCTAssertEqual(session.perform(.copyRegion(0), origin: .script).failure,
                           .requiresUserInterface)
            _ = session.perform(.clearRegions, origin: .user)
            XCTAssertFalse(CommandCatalog.regionMenu(for: session).compactMap(\.item)
                .first { $0.identifier == "region.save" }?.enabled ?? true)
        }
    }

    func testRegionReorderingKeepsTheSameSelectedRegion() async throws {
        try await MainActor.run {
            let session = try makeSession()
            let first = Region(shape: .point(.init(x: 1, y: 1)), frame: .image)
            let second = Region(shape: .point(.init(x: 2, y: 2)), frame: .image)
            let third = Region(shape: .point(.init(x: 3, y: 3)), frame: .image)
            _ = session.perform(.replaceRegions([first, second, third]), origin: .user)
            session.selectedRegionIndex = 2
            XCTAssertNil(session.perform(.bringRegionToFront(0), origin: .user).failure)
            XCTAssertEqual(session.regions, [second, third, first])
            XCTAssertEqual(session.selectedRegionIndex, 1)
            XCTAssertNil(session.perform(.bringRegionToFront(1), origin: .user).failure)
            XCTAssertEqual(session.regions, [second, first, third])
            XCTAssertEqual(session.selectedRegionIndex, 2)
            _ = session.perform(.replaceRegions([first]), origin: .user)
            XCTAssertNil(session.selectedRegionIndex)
        }
    }

    func testAnalysisMenuSelectsModesAndInspectorPanels() async throws {
        try await MainActor.run {
            let session = try makeSession()
            let entries = CommandCatalog.analysisMenu(for: session)
            XCTAssertEqual(entries.map { $0.item?.identifier ?? "separator" }, [
                "analysis.lineProfile", "analysis.radialProfile", "analysis.growthCurve",
                "analysis.measure", "analysis.cubeSpectrum", "separator",
                "analysis.photometry", "analysis.statistics",
            ])
            XCTAssertEqual(entries[1].item?.state, .checked(false))
            let radial = try XCTUnwrap(entries[1].item?.command)
            XCTAssertNil(session.perform(radial, origin: .user).failure)
            XCTAssertEqual(session.mode, .radialProfile)
            XCTAssertEqual(CommandCatalog.analysisMenu(for: session)[1].item?.state, .checked(true))

            session.inspectorVisible = false
            let stats = try XCTUnwrap(entries.last?.item?.command)
            let scripted = session.perform(stats, origin: .script)
            XCTAssertEqual(scripted.failure, .requiresUserInterface)
            XCTAssertFalse(session.inspectorVisible)
            XCTAssertEqual(session.inspectorTab, .header)
            XCTAssertEqual(session.perform(.setInspectorVisible(true), origin: .script).failure,
                           .requiresUserInterface)
            XCTAssertFalse(session.inspectorVisible)
            XCTAssertNil(session.perform(stats, origin: .user).failure)
            XCTAssertTrue(session.inspectorVisible)
            XCTAssertEqual(session.inspectorTab, .stats)
            XCTAssertEqual(CommandCatalog.analysisMenu(for: session).last?.item?.state,
                           .checked(true))
            XCTAssertTrue(CommandCatalog.analysisMenu(for: nil)
                .compactMap(\.item).allSatisfy { !$0.enabled })
        }
    }

    func testCubeSpectrumModeIsDisabledForA2DImage() async throws {
        try await MainActor.run {
            let session = try makeSession()
            session.selectHDU(2)
            XCTAssertNotNil(session.displayed)
            XCTAssertEqual(session.file.hdus[session.hdu].naxis, 2)
            XCTAssertFalse(CommandCatalog.analysisMenu(for: session)[4].item?.enabled ?? true)
            let toolbarMode = CommandCatalog.sessionMenu("mode", for: session)?
                .compactMap(\.item).first { $0.identifier == "mode.cubeSpectrum" }
            XCTAssertEqual(toolbarMode?.enabled, false)
            let attempted = session.perform(.setDrawMode(.cubeSpectrum), origin: .script)
            XCTAssertEqual(attempted.failure, .unavailableDrawMode(.cubeSpectrum))
            XCTAssertEqual(session.mode, .pan)
        }
    }




    func testWorkspaceCommandsReturnPlatformEffectsAndSuppressScriptedWindows() async throws {
        await MainActor.run {
            let workspace = Workspace()
            let about = workspace.perform(.showAppWindow(.about), origin: .user)
            XCTAssertNil(about.failure)
            XCTAssertEqual(about.effects, [.showAppWindow(.about)])

            let scripted = workspace.perform(.showAppWindow(.about), origin: .script)
            XCTAssertEqual(scripted.failure, .requiresUserInterface)
            XCTAssertTrue(scripted.effects.isEmpty)

            let help = workspace.perform(.openHelp(.documentation), origin: .user)
            XCTAssertEqual(help.effects, [.openURL(HelpDestination.documentation.url)])
            XCTAssertEqual(workspace.perform(.tileWindows, origin: .user).effects, [.tileWindows])
            XCTAssertEqual(workspace.perform(.quit, origin: .script).effects, [.quit])
        }
    }

    func testWorkspaceMenuCatalogueCarriesStableIDsAndCommands() async throws {
        await MainActor.run {
            let about = CommandCatalog.workspaceMenuItem(.about)
            XCTAssertEqual(about.identifier, "app.about")
            XCTAssertEqual(about.title, "About Theia")
            if case .showAppWindow(.about) = about.command {} else {
                XCTFail("About menu item should dispatch a workspace command")
            }
            let help = CommandCatalog.workspaceMenuItem(.documentation)
            XCTAssertEqual(help.identifier, "help.documentation")
            if case .openHelp(.documentation) = help.command {} else {
                XCTFail("Help menu item should open the documentation")
            }
        }
    }

    func testWorkspaceSyncCommandsDriveCatalogueState() async throws {
        await MainActor.run {
            let workspace = Workspace()
            let before = CommandCatalog.workspaceMenu(section: .sync, for: workspace)
            XCTAssertEqual(before.compactMap(\.item).map(\.title), [
                "Match zoom + pan", "Match scale (vmin/vmax)", "Match colormap",
                "Match crosshair (cursor)", "Tile windows",
            ])
            XCTAssertEqual(before.filter { $0.item == nil }.count, 1)
            XCTAssertEqual(before.first?.item?.state, .checked(false))

            let outcome = workspace.perform(.setSyncFlag(.zoomPan, true), origin: .user)
            XCTAssertNil(outcome.failure)
            XCTAssertTrue(workspace.syncEnabled(.zoomPan))
            let enabled = CommandCatalog.workspaceMenu(section: .sync, for: workspace)
            XCTAssertEqual(enabled.first?.item?.state, .checked(true))
            XCTAssertEqual(enabled.first?.item?.identifier, "sync.zoomPan")
            XCTAssertEqual(enabled.first?.item?.tooltip, "Synchronise zoom and pan across windows")
            if case .setSyncFlag(.zoomPan, false) = enabled.first?.item?.command {} else {
                XCTFail("Checked sync entry should offer the inverse command")
            }
            _ = workspace.perform(.setSyncFlag(.zoomPan, false), origin: .script)
            XCTAssertFalse(workspace.syncEnabled(.zoomPan))
        }
    }

    func testWorkspaceHelpMenuOrderComesFromCatalogue() async throws {
        await MainActor.run {
            let entries = CommandCatalog.workspaceMenu(section: .help, for: Workspace())
            XCTAssertEqual(entries.map { $0.item?.identifier ?? "separator" }, [
                "help.documentation", "help.source", "help.reportIssue", "separator",
                "help.scriptingReference", "separator", "help.welcome", "help.onboarding",
            ])
            XCTAssertTrue(entries.compactMap(\.item).allSatisfy { $0.visible && $0.enabled })
        }
    }

    func testEventsReportStateChangesAndPreserveOriginAndEchoTag() async throws {
        try await MainActor.run {
            let session = try makeSession()
            var events: [SessionEvent] = []
            let observer = session.addEventObserver { events.append($0) }
            let echoTag = UUID()

            session.withEventContext(origin: .script, echoTag: echoTag) {
                session.view.stretch = .log
                session.view.transform = ViewTransform(scale: 2)
                session.regions = [Region(shape: .point(.init(x: 1, y: 1)), frame: .image)]
                session.cursor = CursorInfo(imageX: 1, imageY: 0, value: 2)
                session.selectPlane(1)
            }

            XCTAssertTrue(events.contains { $0.kind == .displayParametersChanged })
            XCTAssertTrue(events.contains { $0.kind == .transformChanged })
            XCTAssertTrue(events.contains { $0.kind == .regionsChanged })
            XCTAssertTrue(events.contains { $0.kind == .persistedFieldChanged })
            XCTAssertTrue(events.contains { $0.kind == .cursorMoved })
            XCTAssertTrue(events.contains { $0.kind == .selectionChanged })
            XCTAssertTrue(events.contains { $0.kind == .imageRevisionChanged })
            XCTAssertTrue(events.allSatisfy { $0.origin == .script && $0.echoTag == echoTag })
            XCTAssertTrue(events.allSatisfy { $0.imageRevision <= session.imageRevision })

            let count = events.count
            session.view.stretch = .log
            XCTAssertEqual(events.count, count)
            session.removeEventObserver(observer)
            session.view.stretch = .linear
            XCTAssertEqual(events.count, count)
        }
    }

    func testDisplayCommandsApplySynchronouslyWithScriptOrigin() async throws {
        try await MainActor.run {
            let session = try makeSession()
            var events: [SessionEvent] = []
            session.addEventObserver { events.append($0) }
            let stretch = session.perform(.setStretch(.log), origin: .script)
            XCTAssertNil(stretch.failure)
            XCTAssertTrue(stretch.effects.isEmpty)
            XCTAssertEqual(session.view.stretch, .log)
            XCTAssertTrue(events.allSatisfy { $0.origin == .script })

            let plane = session.perform(.selectPlane(1), origin: .script)
            XCTAssertNil(plane.failure)
            XCTAssertEqual(session.plane, 1)
            XCTAssertEqual(session.displayed?.physicalValue(x: 0, y: 0), 4)
            XCTAssertTrue(events.contains { $0.kind == .selectionChanged && $0.origin == .script })
        }
    }

    func testInvalidSelectionCommandReturnsTypedFailureWithoutMutation() async throws {
        try await MainActor.run {
            let session = try makeSession()
            let initialRevision = session.imageRevision
            let invalid = session.perform(.selectHDU(999), origin: .script)
            XCTAssertEqual(invalid.failure, .invalidHDU(999))
            XCTAssertEqual(session.hdu, 1)
            XCTAssertEqual(session.imageRevision, initialRevision)
        }
    }

    func testPlaybackCommandRejectsAnHDUWithoutMultiplePlanes() async throws {
        try await MainActor.run {
            let session = try makeSession()
            session.selectHDU(2) // a 2D image
            let outcome = session.perform(.setPlaying(true), origin: .script)
            XCTAssertEqual(outcome.failure, .unavailablePlayback)
            XCTAssertFalse(session.playing)
        }
    }

    func testScalePresetIsSharedWithToolbarAndCommandDispatch() async throws {
        try await MainActor.run {
            let session = try makeSession()
            XCTAssertEqual(ScalePreset.toolbarPresets.count, 5)
            XCTAssertEqual(ScalePreset.percentile(lower: 0.25, upper: 99.75).label, "99.5 %")
            let outcome = session.perform(.applyScalePreset(.minMax), origin: .user)
            XCTAssertNil(outcome.failure)
            XCTAssertEqual(session.view.vmin, 0)
            XCTAssertEqual(session.view.vmax, 3)
        }
    }

    func testInvalidScriptPercentileReturnsFailureWithoutChangingLevels() async throws {
        try await MainActor.run {
            let session = try makeSession()
            let before = (session.view.vmin, session.view.vmax)
            let outcome = session.perform(
                .applyScalePreset(.percentile(lower: .nan, upper: 99)), origin: .script
            )
            XCTAssertEqual(outcome.failure, .invalidPercentileBounds)
            XCTAssertEqual(session.view.vmin, before.0)
            XCTAssertEqual(session.view.vmax, before.1)
        }
    }

    func testPanelCommandReturnsEffectWithoutOpeningUIInSharedLayer() async throws {
        try await MainActor.run {
            let session = try makeSession()
            let outcome = session.perform(.showPanel(.scaleParameters), origin: .user)
            XCTAssertNil(outcome.failure)
            XCTAssertEqual(outcome.effects, [.showPanel(.scaleParameters)])
            let scripted = session.perform(.showPanel(.scaleParameters), origin: .script)
            XCTAssertTrue(scripted.effects.isEmpty)
            XCTAssertEqual(scripted.failure, .requiresUserInterface)
        }
    }

    func testToolbarToggleCommandsUseCurrentSessionState() async throws {
        try await MainActor.run {
            let session = try makeSession()
            let grid = try XCTUnwrap(CommandCatalog.toolbarItem("grid", for: session))
            XCTAssertEqual(grid, CommandCatalog.toolbarItem("grid", for: session))
            XCTAssertEqual(grid.state, .checked(false))
            guard case .setGridVisible(true) = grid.command else {
                return XCTFail("Grid action should turn the overlay on")
            }
            _ = session.perform(grid.command!, origin: .user)
            let updated = try XCTUnwrap(CommandCatalog.toolbarItem("grid", for: session))
            XCTAssertEqual(updated.state, .checked(true))
            guard case .setGridVisible(false) = updated.command else {
                return XCTFail("Grid action should turn the overlay off")
            }
            let pixelTable = try XCTUnwrap(CommandCatalog.toolbarItem("pixeltable", for: session))
            let panel = try XCTUnwrap(pixelTable.command)
            XCTAssertEqual(session.perform(panel, origin: .user).effects, [.showPanel(.pixelTable)])
        }
    }

    func testImageMenuReflectsActiveSessionAndPanelEffects() async throws {
        try await MainActor.run {
            let session = try makeSession()
            let entries = CommandCatalog.imageMenu(for: session)
            XCTAssertEqual(entries.map { $0.item?.identifier ?? "separator" }, [
                "image.zscale", "separator", "image.grid", "image.compass",
                "image.colorBar", "separator", "image.pixelTable", "image.contours",
            ])
            XCTAssertEqual(entries[2].item?.state, .checked(false))
            _ = session.perform(.setGridVisible(true), origin: .user)
            let updated = CommandCatalog.imageMenu(for: session)
            XCTAssertEqual(updated[2].item?.state, .checked(true))
            if case .setGridVisible(false) = updated[2].item?.command {} else {
                XCTFail("Image menu should offer the current inverse toggle")
            }
            let panel = try XCTUnwrap(updated.last?.item?.command)
            XCTAssertEqual(session.perform(panel, origin: .user).effects,
                           [.showPanel(.contourLevels)])
            let noDocument = CommandCatalog.imageMenu(for: nil)
            XCTAssertTrue(noDocument.compactMap(\.item).allSatisfy { !$0.enabled })
        }
    }

    func testToolbarCatalogueDisablesImageActionsOnTablesAndAllowsSingleImageTools() async throws {
        try await MainActor.run {
            let session = try makeSession()
            session.selectHDU(4) // table
            XCTAssertFalse(CommandCatalog.toolbarItem("export", for: session)?.enabled ?? true)
            XCTAssertFalse(CommandCatalog.toolbarItem("tools", for: session)?.enabled ?? true)
            XCTAssertFalse(CommandCatalog.toolbarItem("blink", for: session)?.enabled ?? true)
            XCTAssertTrue(CommandCatalog.toolbarItem(
                "tools", for: session, workspaceImageCount: 2
            )?.enabled ?? false)

            var data = Data()
            appendHDU(&data, cards: [
                "SIMPLE  =                    T", "BITPIX  =                    8",
                "NAXIS   =                    2", "NAXIS1  =                    2", "NAXIS2  =                    2"
            ], pixels: [1, 2, 3, 4])
            let single = DocumentSession(
                url: URL(fileURLWithPath: "/tmp/single.fits"), file: try FITSFile(data: data)
            )
            XCTAssertTrue(CommandCatalog.toolbarItem("tools", for: single)?.enabled ?? false)
            XCTAssertFalse(CommandCatalog.toolbarItem("blink", for: single)?.enabled ?? true)
            XCTAssertEqual(CommandCatalog.toolbarItem("export", for: single)?.title, "Export…")
        }
    }

    func testCommandCatalogueProvidesDynamicWCSAndScaleMenus() async throws {
        try await MainActor.run {
            let session = try makeSession()
            let variants = CommandCatalog.sessionMenu("wcsVariant", for: session)
            XCTAssertEqual(variants?.compactMap(\.item?.title), ["Primary", "Variant A"])
            XCTAssertEqual(variants?.first?.item?.state, .checked(true))
            if case .selectWCSVariant("A")? = variants?.last?.item?.command {} else {
                XCTFail("Variant menu should dispatch its selected WCS")
            }

            let scale = CommandCatalog.sessionMenu("scale", for: session)
            XCTAssertEqual(scale?.count, ScalePreset.toolbarPresets.count + 2)
            XCTAssertEqual(scale?.first?.item?.title, "ZScale")
            XCTAssertEqual(scale?.compactMap(\.item?.identifier), [
                "scale.preset.zscale", "scale.preset.minmax",
                "scale.preset.percentile.0.5.99.5",
                "scale.preset.percentile.0.25.99.75",
                "scale.preset.percentile.0.05.99.95",
                "scale.parameters",
            ])
            if case .applyScalePreset(.zscale)? = scale?.first?.item?.command {} else {
                XCTFail("Scale menu should dispatch a shared preset")
            }
            if case .showPanel(.scaleParameters)? = scale?.last?.item?.command {} else {
                XCTFail("Scale menu should open parameters")
            }

            session.selectHDU(2)
            let unavailable = CommandCatalog.sessionMenu("wcsVariant", for: session)
            XCTAssertEqual(unavailable?.first?.item?.title, "No WCS in this HDU")
            XCTAssertEqual(unavailable?.first?.item?.enabled, false)

            session.selectHDU(1)
            session.setDerived(DerivedImage(image: session.displayed!,
                                            wcs: session.displayedWCS, label: "derived"))
            XCTAssertEqual(CommandCatalog.sessionMenu("wcsVariant", for: session)?
                .first?.item?.enabled, false)
            XCTAssertEqual(CommandCatalog.toolbarItem("wcsVariant", for: session)?.enabled, false)
        }
    }

    func testViewCommandsFitAndZoomAroundAnImageAnchor() async throws {
        try await MainActor.run {
            let session = try makeSession()
            session.view.viewSizePoints = CGSize(width: 100, height: 80)

            XCTAssertNil(session.perform(.fitView, origin: .user).failure)
            XCTAssertEqual(session.view.transform.scale, 40)
            XCTAssertEqual(session.view.transform.centre, SIMD2(0.5, 0.5))

            XCTAssertNil(session.perform(
                .zoom(factor: 2, aroundImagePoint: SIMD2(1, 0)), origin: .user
            ).failure)
            XCTAssertEqual(session.view.transform.scale, 80)
            XCTAssertEqual(session.view.transform.centre, SIMD2(0.75, 0.25))

            XCTAssertNil(session.perform(.actualSize, origin: .user).failure)
            XCTAssertEqual(session.view.transform.scale, 1)
            XCTAssertEqual(session.view.transform.centre, SIMD2(0.75, 0.25))
        }
    }

    func testViewCommandsRejectInvalidZoomWithoutMutatingTransform() async throws {
        try await MainActor.run {
            let session = try makeSession()
            let before = session.view.transform
            XCTAssertEqual(session.perform(
                .zoom(factor: .nan, aroundImagePoint: .zero), origin: .script
            ).failure, .invalidZoomFactor)
            XCTAssertEqual(session.view.transform, before)
            session.view.viewSizePoints = .zero
            XCTAssertEqual(session.perform(.fitView, origin: .script).failure, .unavailableViewSize)
            XCTAssertEqual(session.view.transform, before)
        }
    }

    func testViewCommandsZoomAtCentreAndPanInViewPoints() async throws {
        try await MainActor.run {
            let session = try makeSession()
            session.view.transform = ViewTransform(scale: 2, centre: SIMD2(10, 10))
            XCTAssertNil(session.perform(.zoomIn, origin: .user).failure)
            XCTAssertEqual(session.view.transform, ViewTransform(scale: 4, centre: SIMD2(10, 10)))
            XCTAssertNil(session.perform(.zoomOut, origin: .user).failure)
            XCTAssertEqual(session.view.transform.scale, 2)
            XCTAssertNil(session.perform(.pan(viewDelta: SIMD2(4, -6)), origin: .user).failure)
            XCTAssertEqual(session.view.transform.centre, SIMD2(8, 7))
            XCTAssertEqual(session.perform(
                .pan(viewDelta: SIMD2(.nan, 0)), origin: .script
            ).failure, .invalidPanDelta)
            XCTAssertEqual(session.view.transform.centre, SIMD2(8, 7))
        }
    }

    func testViewMenuKeepsActionsVisibleAndDisablesThemWithoutAnImage() async throws {
        try await MainActor.run {
            let session = try makeSession()
            let actions = CommandCatalog.viewMenu(for: session).compactMap(\.item)
            XCTAssertEqual(actions.map(\.identifier), [
                "view.fit", "view.actualSize", "view.zoomIn", "view.zoomOut",
            ])
            XCTAssertTrue(actions.allSatisfy(\.enabled))
            XCTAssertEqual(actions.first?.shortcut?.key, "0")
            if case .fitView? = actions.first?.command {} else {
                XCTFail("Fit menu action should dispatch the shared command")
            }

            session.selectHDU(4) // table
            XCTAssertTrue(CommandCatalog.viewMenu(for: session).compactMap(\.item)
                .allSatisfy { !$0.enabled })
            XCTAssertTrue(CommandCatalog.viewMenu(for: nil).compactMap(\.item)
                .allSatisfy { !$0.enabled })
        }
    }

    func testNestedEventContextInheritsEchoTagAndRestoresOuterContext() async throws {
        try await MainActor.run {
            let session = try makeSession()
            var events: [SessionEvent] = []
            session.addEventObserver { events.append($0) }
            let tag = UUID()
            session.withEventContext(origin: .user, echoTag: tag) {
                session.withEventContext(origin: .script) {
                    session.view.transform = ViewTransform(scale: 2)
                }
                session.view.stretch = .log
            }
            session.view.colorMap = .plasma
            XCTAssertEqual(events.first { $0.kind == .transformChanged }?.origin, .script)
            XCTAssertEqual(events.first { $0.kind == .transformChanged }?.echoTag, tag)
            XCTAssertEqual(events.first { $0.kind == .displayParametersChanged }?.echoTag, tag)
            XCTAssertNil(events.last { $0.kind == .displayParametersChanged }?.echoTag)
        }
    }

    func testPlaybackTicksDoNotEmitPersistenceEvents() async throws {
        try await MainActor.run {
            let session = try makeSession()
            var kinds: [SessionEvent.Kind] = []
            session.addEventObserver { kinds.append($0.kind) }
            let start = Date(timeIntervalSince1970: 0)
            session.setFPS(30)
            session.setPlaying(true, now: start)
            session.tick(now: start.addingTimeInterval(0.04))
            XCTAssertTrue(kinds.contains(.selectionChanged))
            XCTAssertTrue(kinds.contains(.imageRevisionChanged))
            XCTAssertFalse(kinds.contains(.persistedFieldChanged))
        }
    }

    func testStoppingBlinkDoesNotRequestAutosaveOfTransientPartner() async throws {
        try await MainActor.run {
            let session = try makeSession()
            var kinds: [SessionEvent.Kind] = []
            session.addEventObserver { kinds.append($0.kind) }
            let start = Date(timeIntervalSince1970: 0)
            session.toggleBlink(now: start)
            session.tick(now: start.addingTimeInterval(0.6))
            XCTAssertEqual(session.hdu, 2)
            session.toggleBlink(now: start.addingTimeInterval(0.7))
            XCTAssertEqual(session.hdu, 1)
            XCTAssertFalse(kinds.contains(.persistedFieldChanged))
        }
    }

    func testContourJobCompletionRetainsCommandEventContext() async throws {
        let session = try await MainActor.run { try makeSession() }
        let recorder = await MainActor.run { EventRecorder() }
        let echoTag = UUID()
        await MainActor.run {
            session.addEventObserver { recorder.events.append($0) }
            session.withEventContext(origin: .script, echoTag: echoTag) {
                session.setContourSpec(ContourSpec(enabled: true, count: 1, minValue: 1, maxValue: 2))
            }
        }
        await session.idle()
        await MainActor.run {
            let completed = recorder.events.filter { $0.kind == .overlaysChanged }
            XCTAssertEqual(completed.count, 1)
            XCTAssertEqual(completed.first?.origin, .script)
            XCTAssertEqual(completed.first?.echoTag, echoTag)
        }
    }

    func testDirectSessionPropertiesEmitPersistedFieldEvents() async throws {
        try await MainActor.run {
            let session = try makeSession()
            var kinds: [SessionEvent.Kind] = []
            session.addEventObserver { kinds.append($0.kind) }
            session.mode = .lineProfile
            session.showGrid = true
            session.showCompass = true
            session.showColorBar = true
            XCTAssertEqual(kinds.filter { $0 == .persistedFieldChanged }.count, 4)
            XCTAssertEqual(kinds.filter { $0 == .displayParametersChanged }.count, 3)
        }
    }

    func testDisplayedCachesPlanesAndTracksPixelRevisions() async throws {
        try await MainActor.run {
        let session = try makeSession()
        XCTAssertEqual(session.hdu, 1)
        XCTAssertEqual(session.displayed?.physicalValue(x: 0, y: 0), 0)
        XCTAssertEqual(session.view.image?.physicalValue(x: 0, y: 0), 0)
        XCTAssertEqual(session.view.imageRevision, session.imageRevision)
        XCTAssertEqual(session.displayed?.physicalValue(x: 0, y: 0), 0)
        XCTAssertEqual(session.decodedImageCount, 1)

        let firstRevision = session.imageRevision
        session.selectPlane(1)
        XCTAssertEqual(session.imageRevision, firstRevision + 1)
        XCTAssertEqual(session.displayed?.physicalValue(x: 0, y: 0), 4)
        XCTAssertEqual(session.view.image?.physicalValue(x: 0, y: 0), 4)
        XCTAssertEqual(session.view.imageRevision, session.imageRevision)
        session.selectPlane(0)
        XCTAssertEqual(session.displayed?.physicalValue(x: 0, y: 0), 0)
        XCTAssertEqual(session.decodedImageCount, 2)

        session.selectHDU(4)
        XCTAssertNil(session.displayed) // table HDU
        session.selectHDU(0)
        XCTAssertNil(session.displayed) // data-less primary
        }
    }

    func testDerivedImageAndWCSFollowTheDisplayedPixels() async throws {
        try await MainActor.run {
        let session = try makeSession()
        XCTAssertEqual(session.displayedWCS?.crval.ra, 10)
        session.selectWCSVariant("A")
        XCTAssertEqual(session.displayedWCS?.crval.ra, 20)
        XCTAssertEqual(session.availableWCSVariants, ["", "A"])

        let derived = FITSImage.fromFloat32(pixels: [99, 99, 99, 99], width: 2, height: 2)
        let revision = session.imageRevision
        session.setDerived(DerivedImage(image: derived, wcs: nil, label: "Filtered"))
        XCTAssertEqual(session.displayed?.physicalValue(x: 0, y: 0), 99)
        XCTAssertNil(session.displayedWCS)
        XCTAssertEqual(session.availableWCSVariants, [])
        session.selectWCSVariant("")
        XCTAssertEqual(session.wcsVariant, "A")
        XCTAssertEqual(session.imageRevision, revision + 1)

        session.setDerived(DerivedImage(image: derived, wcs: session.facts[1].wcs(variant: "A"), label: "Same geometry"))
        XCTAssertEqual(session.availableWCSVariants, ["A"])

        session.selectHDU(2)
        XCTAssertNil(session.derived)
        XCTAssertEqual(session.plane, 0)
        XCTAssertEqual(session.displayed?.physicalValue(x: 0, y: 0), 11)
        }
    }

    func testBlinkPartnerSkipsDifferentShapesAndNonImages() async throws {
        try await MainActor.run {
        let session = try makeSession()
        XCTAssertEqual(session.blinkPartner, 2)
        session.selectHDU(3)
        XCTAssertNil(session.blinkPartner)
        }
    }

    func testFourDimensionalCubeExposesEveryFlattenedPlane() async throws {
        try await MainActor.run {
            let session = try makeSession()
            session.selectHDU(5)
            XCTAssertEqual(session.facts[5].planeCount, 4)
            session.selectPlane(3)
            XCTAssertEqual(session.displayed?.physicalValue(x: 0, y: 0), 12)
        }
    }

    func testRegionsSelectionPreviewAndRemoteCrosshairBelongToSession() async throws {
        try await MainActor.run {
            let session = try makeSession()
            let region = Region(shape: .point(.init(x: 1, y: 2)), frame: .image)
            session.regions = [region]
            session.selectedRegionIndex = 0
            session.previewRegion = region
            session.remoteCrosshair = SIMD2(3, 4)

            XCTAssertEqual(session.regions, [region])
            XCTAssertEqual(session.selectedRegionIndex, 0)
            XCTAssertEqual(session.previewRegion, region)
            XCTAssertEqual(session.remoteCrosshair, SIMD2(3, 4))

            session.selectedRegionIndex = 99
            XCTAssertNil(session.selectedRegionIndex)
            session.selectedRegionIndex = 0

            let regionsChanged = expectation(description: "region change invalidates observers")
            withObservationTracking {
                _ = session.regions
            } onChange: {
                regionsChanged.fulfill()
            }
            session.regions = []
            wait(for: [regionsChanged], timeout: 1)
            XCTAssertNil(session.selectedRegionIndex)
            XCTAssertNil(session.previewRegion)
        }
    }

    func testDocumentTextPreservesHDUAndStatusReadouts() async throws {
        try await MainActor.run {
            let session = try makeSession()
            let cube = session.file.hdus[1]
            XCTAssertEqual(DocumentText.windowSubtitle(for: session.file), "6 HDUs · 2 × 2 × 2 · uint8")
            XCTAssertEqual(DocumentText.hduLabel(index: 1, name: nil), "HDU 1")
            XCTAssertEqual(DocumentText.hduLabel(index: 2, name: "SCI"), "HDU 2 — SCI")
            XCTAssertEqual(DocumentText.sidebarDetails(for: cube), "3D cube · 2 × 2 × 2 · uint8")
            XCTAssertEqual(DocumentText.statusDetails(for: cube), "2 × 2 × 2 · uint8")
            XCTAssertEqual(DocumentText.pixelCoordinates(imageX: 0, imageY: 4), "(1, 5)")
            XCTAssertEqual(DocumentText.pixelValue(.nan), "NaN")
            XCTAssertEqual(DocumentText.pixelValue(1.23456), "1.235")
            XCTAssertEqual(DocumentText.level(0), "0.00e+00")
            XCTAssertEqual(DocumentText.level(1000), "1.00e+03")
        }
    }

    func testRestoredDisplayAndRegionsAreReadyBeforeViewAppears() async throws {
        let session = try await MainActor.run { try makeSession() }
        await MainActor.run {
            let region = Region(shape: .point(.init(x: 2, y: 3)), frame: .image)
            let saved = SessionState(
                selectedHDU: 2, selectedPlane: 0, stretch: .log, colorMap: .plasma,
                drawMode: "pan", vmin: 12, vmax: 45, stretchParameter: 3,
                showWCSGrid: true, showCompass: false, showColorBar: false,
                regions: [region],
                contour: .init(enabled: true, count: 1, minValue: 12, maxValue: 16, spacing: "linear")
            )
            session.restoreInitialState(saved)
            XCTAssertEqual(session.hdu, 2)
            XCTAssertEqual(session.displayed?.physicalValue(x: 0, y: 0), 11)
            XCTAssertEqual(session.view.vmin, 12)
            XCTAssertEqual(session.view.vmax, 45)
            XCTAssertEqual(session.view.stretch, .log)
            XCTAssertEqual(session.view.colorMap, .plasma)
            XCTAssertEqual(session.view.stretchParameter, 3)
            XCTAssertEqual(session.regions, [region])
            XCTAssertTrue(session.showGrid)
            XCTAssertTrue(session.contourSegments.isEmpty)

            session.regions = [] // an immediate script edit wins over the saved value
            XCTAssertTrue(session.regions.isEmpty)
        }
        await session.idle()
        await MainActor.run { XCTAssertEqual(session.contourSegments.count, 1) }
    }

    func testZScaleResetsDisplayedLevelsWithoutToolbarCallbacks() async throws {
        try await MainActor.run {
            let session = try makeSession()
            let image = try XCTUnwrap(session.displayed)
            let expected = DocumentSession.recommendedLevels(for: image)
            session.view.vmin = -100
            session.view.vmax = 100
            session.resetLevels()
            XCTAssertEqual(session.view.vmin, expected.vmin)
            XCTAssertEqual(session.view.vmax, expected.vmax)
        }
    }

    func testScalePresetsReadTheDisplayedImage() async throws {
        try await MainActor.run {
            let session = try makeSession()
            let derived = FITSImage.fromFloat32(pixels: [10, 20, 30, 40], width: 2, height: 2)
            session.setDerived(DerivedImage(image: derived, wcs: nil, label: "scaled"))
            session.setMinMaxLevels()
            XCTAssertEqual(session.view.vmin, 10)
            XCTAssertEqual(session.view.vmax, 40)
            session.view.vmin = -1
            session.view.vmax = -1
            session.setPercentileLevels(lower: 0, upper: 100)
            XCTAssertEqual(session.view.vmin, 10)
            XCTAssertEqual(session.view.vmax, 40)
        }
    }

    func testOverlayStateAndContoursFollowTheDisplayedPlane() async throws {
        let session = try await MainActor.run { try makeSession() }
        let contoursChanged = expectation(description: "contour change invalidates observers")
        await MainActor.run {
            session.showGrid = true
            session.showCompass = true
            session.showColorBar = true
            withObservationTracking {
                _ = session.contourSegments
            } onChange: {
                contoursChanged.fulfill()
            }
            session.setContourSpec(ContourSpec(
                enabled: true, count: 1, minValue: 1, maxValue: 2, spacing: .linear
            ))
        }
        await session.idle()
        await fulfillment(of: [contoursChanged], timeout: 1)
        await MainActor.run {
            XCTAssertTrue(session.showGrid)
            XCTAssertTrue(session.showCompass)
            XCTAssertTrue(session.showColorBar)
            XCTAssertEqual(session.contourSegments.count, 1)
            XCTAssertFalse(session.contourSegments[0].segments.isEmpty)
            session.selectPlane(1)
        }
        await session.idle()
        await MainActor.run {
            XCTAssertTrue(session.contourSegments[0].segments.isEmpty)
            session.selectPlane(0)
        }
        await session.idle()
        await MainActor.run {
            XCTAssertFalse(session.contourSegments[0].segments.isEmpty)
        }
    }

    func testContourJobsKeepOnlyTheLatestDisplayedImage() async throws {
        let session = try await MainActor.run { try makeSession() }
        await MainActor.run {
            session.setContourSpec(ContourSpec(
                enabled: true, count: 1, minValue: 1, maxValue: 2
            ))
            XCTAssertTrue(session.contourSegments.isEmpty)
            session.selectPlane(1)
        }
        await session.idle()
        await MainActor.run {
            XCTAssertEqual(session.contourSegments.count, 1)
            XCTAssertTrue(session.contourSegments[0].segments.isEmpty)
            session.selectPlane(0)
        }
        await session.idle()
        await MainActor.run {
            XCTAssertFalse(session.contourSegments[0].segments.isEmpty)
            session.selectPlane(1)
            session.setContourSpec(ContourSpec())
            XCTAssertTrue(session.contourSegments.isEmpty)
        }
        await session.idle()
        await MainActor.run { XCTAssertTrue(session.contourSegments.isEmpty) }
    }

    func testToolStateIsObservableAndRestoresBeforeViewAppears() async throws {
        try await MainActor.run {
            let session = try makeSession()
            XCTAssertEqual(session.mode, .pan)
            XCTAssertNil(session.profileMarker)
            XCTAssertNil(session.cursor)

            let modeChanged = expectation(description: "draw mode change invalidates observers")
            withObservationTracking {
                _ = session.mode
            } onChange: {
                modeChanged.fulfill()
            }
            session.mode = .radialProfile
            wait(for: [modeChanged], timeout: 1)

            let marker = ProfileGeometry.radial(center: SIMD2(2, 3), maxRadius: 4)
            let cursor = CursorInfo(imageX: 1, imageY: 0, value: 12)
            session.profileMarker = marker
            session.cursor = cursor
            XCTAssertEqual(session.profileMarker, marker)
            XCTAssertEqual(session.cursor, cursor)

            let saved = SessionState(
                selectedHDU: session.hdu, selectedPlane: session.plane,
                stretch: .linear, colorMap: .gray, drawMode: "lineProfile",
                vmin: 0, vmax: 1, stretchParameter: 1,
                showWCSGrid: false, showCompass: false, showColorBar: false,
                regions: []
            )
            session.restoreInitialState(saved)
            XCTAssertEqual(session.mode, .lineProfile)
            XCTAssertEqual(session.profileMarker, marker)
            XCTAssertEqual(session.cursor, cursor)
        }
    }

    func testInspectorSelectionAndCatalogStatusStayWithDocument() async throws {
        try await MainActor.run {
            let session = try makeSession()
            XCTAssertTrue(session.inspectorVisible)
            XCTAssertEqual(session.inspectorTab, .header)
            XCTAssertFalse(session.catalogFetchInProgress)

            let changed = expectation(description: "catalog status invalidates observers")
            withObservationTracking {
                _ = session.catalogFetchInProgress
            } onChange: {
                changed.fulfill()
            }
            session.inspectorTab = .photometry
            session.inspectorVisible = false
            session.catalogFetchInProgress = true
            wait(for: [changed], timeout: 1)
            session.inspectorVisible = true
            XCTAssertEqual(session.inspectorTab, .photometry)
            XCTAssertTrue(session.catalogFetchInProgress)
        }
    }

    func testPlaybackAdvancesAtSelectedRateAndStopsWhenHDUChanges() async throws {
        try await MainActor.run {
            let session = try makeSession()
            let start = Date(timeIntervalSince1970: 0)
            session.setFPS(30)
            session.setPlaying(true, now: start)
            XCTAssertTrue(session.playing)
            session.tick(now: start.addingTimeInterval(0.02))
            XCTAssertEqual(session.plane, 0)
            session.tick(now: start.addingTimeInterval(0.04))
            XCTAssertEqual(session.plane, 1)
            session.tick(now: start.addingTimeInterval(0.06))
            XCTAssertEqual(session.plane, 1)
            session.tick(now: start.addingTimeInterval(0.08))
            XCTAssertEqual(session.plane, 0)

            session.selectHDU(2)
            XCTAssertFalse(session.playing)
            session.tick(now: start.addingTimeInterval(1))
            XCTAssertEqual(session.hdu, 2)
        }
    }

    func testSixtyHertzPulsesDeliverThirtyFramesPerSecond() async throws {
        try await MainActor.run {
            let session = try makeSession()
            let start = Date(timeIntervalSince1970: 0)
            session.setFPS(30)
            session.setPlaying(true, now: start)
            for pulse in 1...60 {
                session.tick(now: start.addingTimeInterval(Double(pulse) / 60))
            }
            XCTAssertGreaterThanOrEqual(session.imageRevision, 29)
        }
    }

    func testFrameDriverRunsOnlyWhilePlaybackOrBlinkIsActive() async throws {
        try await MainActor.run {
            let session = try makeSession()
            var starts = 0
            var stops = 0
            let driver = SessionFrameDriver(
                session: session,
                startPulses: { starts += 1 }, stopPulses: { stops += 1 }
            )
            XCTAssertFalse(driver.isRunning)
            let start = Date(timeIntervalSince1970: 0)
            session.setFPS(30)
            session.setPlaying(true, now: start)
            XCTAssertTrue(driver.isRunning)
            XCTAssertEqual(starts, 1)
            driver.pulse(now: start.addingTimeInterval(0.04))
            XCTAssertEqual(session.plane, 1)
            session.setPlaying(false)
            XCTAssertFalse(driver.isRunning)
            XCTAssertEqual(stops, 1)
            session.toggleBlink(now: start)
            XCTAssertTrue(driver.isRunning)
            XCTAssertEqual(starts, 2)
            session.toggleBlink(now: start)
            XCTAssertFalse(driver.isRunning)
            XCTAssertEqual(stops, 2)
            driver.close()
            session.setPlaying(true, now: start)
            XCTAssertEqual(starts, 2)
        }
    }

    func testPlaybackRateAcceptsOnlyOneToThirtyFramesPerSecond() async throws {
        try await MainActor.run {
            let session = try makeSession()
            XCTAssertEqual(session.fps, 5)
            session.setFPS(0)
            XCTAssertEqual(session.fps, 1)
            session.setFPS(100)
            XCTAssertEqual(session.fps, 30)
            session.setFPS(.nan)
            XCTAssertEqual(session.fps, 5)
        }
    }

    func testBlinkAlternatesMatchingHDUsAndStopsOnPrimary() async throws {
        try await MainActor.run {
            let session = try makeSession()
            let start = Date(timeIntervalSince1970: 0)
            session.toggleBlink(now: start)
            XCTAssertEqual(session.blink?.primary, 1)
            XCTAssertEqual(session.blink?.partner, 2)
            session.tick(now: start.addingTimeInterval(0.6))
            XCTAssertEqual(session.hdu, 2)
            session.tick(now: start.addingTimeInterval(1.1))
            XCTAssertEqual(session.hdu, 1)
            session.toggleBlink(now: start.addingTimeInterval(1.2))
            XCTAssertNil(session.blink)
            XCTAssertEqual(session.hdu, 1)

            session.selectHDU(3)
            session.toggleBlink(now: start)
            XCTAssertNil(session.blink)
        }
    }

    @MainActor
    private func makeSession() throws -> DocumentSession {
        var data = Data()
        appendHDU(&data, cards: ["SIMPLE  =                    T", "BITPIX  =                    8", "NAXIS   =                    0"], pixels: [])
        appendHDU(&data, cards: imageCards(width: 2, height: 2, depth: 2) + wcsCards(suffix: "", ra: 10) + wcsCards(suffix: "A", ra: 20), pixels: Array(0..<8).map(UInt8.init))
        appendHDU(&data, cards: imageCards(width: 2, height: 2), pixels: [11, 12, 13, 14])
        appendHDU(&data, cards: imageCards(width: 3, height: 2), pixels: [1, 2, 3, 4, 5, 6])
        appendHDU(&data, cards: ["XTENSION= 'BINTABLE'", "BITPIX  =                    8", "NAXIS   =                    2", "NAXIS1  =                    0", "NAXIS2  =                    0", "PCOUNT  =                    0", "GCOUNT  =                    1", "TFIELDS =                    0"], pixels: [])
        appendHDU(&data, cards: imageCards(width: 2, height: 2, depth: 2, fourthAxis: 2), pixels: Array(0..<16).map(UInt8.init))
        return DocumentSession(url: URL(fileURLWithPath: "/tmp/session.fits"), file: try FITSFile(data: data))
    }

    private func imageCards(width: Int, height: Int, depth: Int? = nil, fourthAxis: Int? = nil) -> [String] {
        ["XTENSION= 'IMAGE   '", "BITPIX  =                    8", "NAXIS   = \(String(format: "%20d", fourthAxis != nil ? 4 : depth == nil ? 2 : 3))", "NAXIS1  = \(String(format: "%20d", width))", "NAXIS2  = \(String(format: "%20d", height))"]
        + (depth.map { ["NAXIS3  = \(String(format: "%20d", $0))"] } ?? [])
        + (fourthAxis.map { ["NAXIS4  = \(String(format: "%20d", $0))"] } ?? [])
        + ["PCOUNT  =                    0", "GCOUNT  =                    1"]
    }

    private func wcsCards(suffix: String, ra: Int) -> [String] {
        func card(_ key: String, _ value: String) -> String {
            "\(key.padding(toLength: 8, withPad: " ", startingAt: 0))= \(value)"
        }
        return [
            card("CTYPE1\(suffix)", "'RA---TAN'"), card("CTYPE2\(suffix)", "'DEC--TAN'"),
            card("CRPIX1\(suffix)", "1"), card("CRPIX2\(suffix)", "1"),
            card("CRVAL1\(suffix)", "\(ra)"), card("CRVAL2\(suffix)", "0"),
            card("CDELT1\(suffix)", "-0.1"), card("CDELT2\(suffix)", "0.1")
        ]
    }

    private func appendHDU(_ data: inout Data, cards: [String], pixels: [UInt8]) {
        var header = (cards + ["END"]).map { $0.padding(toLength: 80, withPad: " ", startingAt: 0) }.joined()
        header += String(repeating: " ", count: (2880 - header.utf8.count % 2880) % 2880)
        data.append(contentsOf: header.utf8)
        data.append(contentsOf: pixels)
        data.append(Data(repeating: 0, count: (2880 - pixels.count % 2880) % 2880))
    }
}

@MainActor private final class EventRecorder {
    var events: [SessionEvent] = []
}
