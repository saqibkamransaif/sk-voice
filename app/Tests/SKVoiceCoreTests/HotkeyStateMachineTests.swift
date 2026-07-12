import XCTest
@testable import SKVoiceCore

final class HotkeyStateMachineTests: XCTestCase {
    var sm = HotkeyStateMachine(holdThreshold: 0.3)

    override func setUp() {
        sm = HotkeyStateMachine(holdThreshold: 0.3)
    }

    func testFnHoldProducesDictationStartAndFinish() {
        XCTAssertEqual(sm.handle(fn: true, ctrl: false, at: 0), .start(.dictation))
        XCTAssertTrue(sm.isActive)
        XCTAssertEqual(sm.handle(fn: false, ctrl: false, at: 0.5), .finish(.dictation))
        XCTAssertFalse(sm.isActive)
    }

    func testShortTapCancels() {
        XCTAssertEqual(sm.handle(fn: true, ctrl: false, at: 0), .start(.dictation))
        XCTAssertEqual(sm.handle(fn: false, ctrl: false, at: 0.1), .cancel)
        XCTAssertFalse(sm.isActive)
    }

    func testCtrlAtDownStartsRefine() {
        XCTAssertEqual(sm.handle(fn: true, ctrl: true, at: 0), .start(.refine))
        XCTAssertEqual(sm.handle(fn: false, ctrl: true, at: 1.0), .finish(.refine))
    }

    func testCtrlMidHoldUpgradesToRefine() {
        XCTAssertEqual(sm.handle(fn: true, ctrl: false, at: 0), .start(.dictation))
        XCTAssertEqual(sm.handle(fn: true, ctrl: true, at: 0.2), .upgradeToRefine)
        XCTAssertEqual(sm.handle(fn: false, ctrl: true, at: 0.8), .finish(.refine))
    }

    func testRefineIsStickyAfterCtrlRelease() {
        XCTAssertEqual(sm.handle(fn: true, ctrl: true, at: 0), .start(.refine))
        // Releasing ctrl mid-hold must not downgrade to dictation and emits nothing.
        XCTAssertNil(sm.handle(fn: true, ctrl: false, at: 0.4))
        XCTAssertEqual(sm.handle(fn: false, ctrl: false, at: 0.9), .finish(.refine))
    }

    func testRepeatedIdenticalFlagsAreNoOps() {
        XCTAssertEqual(sm.handle(fn: true, ctrl: false, at: 0), .start(.dictation))
        XCTAssertNil(sm.handle(fn: true, ctrl: false, at: 0.1))
        XCTAssertNil(sm.handle(fn: true, ctrl: false, at: 0.2))
        XCTAssertEqual(sm.handle(fn: false, ctrl: false, at: 0.5), .finish(.dictation))
    }

    func testCtrlUpgradeEmittedOnlyOnce() {
        XCTAssertEqual(sm.handle(fn: true, ctrl: false, at: 0), .start(.dictation))
        XCTAssertEqual(sm.handle(fn: true, ctrl: true, at: 0.1), .upgradeToRefine)
        XCTAssertNil(sm.handle(fn: true, ctrl: false, at: 0.2))
        XCTAssertNil(sm.handle(fn: true, ctrl: true, at: 0.3))
        XCTAssertEqual(sm.handle(fn: false, ctrl: false, at: 0.6), .finish(.refine))
    }

    func testCtrlAloneWithoutFnDoesNothing() {
        XCTAssertNil(sm.handle(fn: false, ctrl: true, at: 0))
        XCTAssertNil(sm.handle(fn: false, ctrl: false, at: 0.2))
        XCTAssertFalse(sm.isActive)
    }

    func testShortRefineTapAlsoCancels() {
        XCTAssertEqual(sm.handle(fn: true, ctrl: true, at: 0), .start(.refine))
        XCTAssertEqual(sm.handle(fn: false, ctrl: true, at: 0.15), .cancel)
    }

    func testExactThresholdCountsAsFinish() {
        XCTAssertEqual(sm.handle(fn: true, ctrl: false, at: 0), .start(.dictation))
        XCTAssertEqual(sm.handle(fn: false, ctrl: false, at: 0.3), .finish(.dictation))
    }
}
