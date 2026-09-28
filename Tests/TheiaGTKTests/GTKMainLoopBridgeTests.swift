import CGtk4
import Dispatch
import Foundation
import XCTest
@testable import TheiaGTK

final class GTKMainLoopBridgeTests: XCTestCase {
    func testMainQueueRunsWhileGLibContextIterates() {
        let bridge = GTKMainLoopBridge()
        XCTAssertTrue(bridge.install())
        defer { bridge.remove() }

        let completed = DispatchSemaphore(value: 0)
        DispatchQueue.main.async { completed.signal() }

        let deadline = Date().addingTimeInterval(2)
        var didRun = false
        while Date() < deadline {
            _ = g_main_context_iteration(nil, 0)
            if completed.wait(timeout: .now()) == .success {
                didRun = true
                break
            }
            Thread.sleep(forTimeInterval: 0.001)
        }
        XCTAssertTrue(didRun, "GLib must service the Swift main queue")
    }

    func testMainActorAndDispatchTimerRunWhileGLibContextIterates() {
        let bridge = GTKMainLoopBridge()
        XCTAssertTrue(bridge.install())
        defer { bridge.remove() }

        let actorCompleted = DispatchSemaphore(value: 0)
        let timerCompleted = DispatchSemaphore(value: 0)
        Task { @MainActor in actorCompleted.signal() }
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + .milliseconds(10))
        timer.setEventHandler { timerCompleted.signal() }
        timer.resume()
        defer { timer.cancel() }

        let deadline = Date().addingTimeInterval(2)
        var actorRan = false
        var timerRan = false
        while Date() < deadline && (!actorRan || !timerRan) {
            _ = g_main_context_iteration(nil, 0)
            if actorCompleted.wait(timeout: .now()) == .success { actorRan = true }
            if timerCompleted.wait(timeout: .now()) == .success { timerRan = true }
            Thread.sleep(forTimeInterval: 0.001)
        }
        XCTAssertTrue(actorRan, "GLib must service MainActor tasks")
        XCTAssertTrue(timerRan, "GLib must service main-queue timers")
    }
}
