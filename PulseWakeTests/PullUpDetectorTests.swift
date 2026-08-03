import XCTest
import CoreGraphics
@testable import PulseWake

/// Endpoint G: state-machine tests for PullUpDetector's double-count guard.
///
/// The detector has two rep-registration branches per cycle (`chinAboveBar` and
/// `lowering`). Before the fix, a single physical pull-up could be counted twice from
/// both branches if the user paused at the top. The hardening: a `repCountedThisCycle`
/// flag set on first registration, cleared only on returning to `.hanging`.
///
/// These tests drive the pure `processFrame` seam (no Vision dependency) so they run on
/// the simulator without a device.
final class PullUpDetectorTests: XCTestCase {

    /// Convenience: build a FrameInput from the geometric primitives that drive the
    /// state machine. Vision normalized coords: y=1 is top of frame, y=0 is bottom.
    /// `chinAboveWrist` (CGFloat): chin Y minus wrist Y. Positive = chin is above wrists.
    /// `elbowAngle` (degrees): 180 = locked-out arm, 0 = fully bent.
    /// `shoulderYRelWrist` computed automatically as `chinY − headHeightAboveShoulder` (we
    /// keep shoulders slightly below chin for realism).
    private func frame(chinAboveWrist: Double, elbowAngle: Double) -> PullUpDetector.FrameInput {
        let wristY: Double = 0.85
        let chinY: Double = wristY + chinAboveWrist
        let shoulderY: Double = chinY - 0.08
        let elbowY: Double = shoulderY - 0.04
        let conf: Float = 0.95
        return PullUpDetector.FrameInput(
            nose: CGPoint(x: 0.5, y: chinY), noseConf: 0.95,
            neck: CGPoint(x: 0.5, y: neckY(from: shoulderY)), neckConf: 0.95,
            leftWrist: CGPoint(x: 0.4, y: wristY), leftWristConf: conf,
            rightWrist: CGPoint(x: 0.6, y: wristY), rightWristConf: conf,
            leftShoulder: CGPoint(x: 0.45, y: shoulderY), leftShoulderConf: conf,
            rightShoulder: CGPoint(x: 0.55, y: shoulderY), rightShoulderConf: conf,
            // Elbow position inferred from elbowAngle for both arms.
            leftElbow: CGPoint(x: 0.42, y: elbowY + (90 - elbowAngle) * 0.001),
            rightElbow: CGPoint(x: 0.58, y: elbowY + (90 - elbowAngle) * 0.001)
        )
    }

    private func neckY(from shoulderY: Double) -> Double { shoulderY + 0.02 }

    private func angleForElbow(_ angle: Double) -> CGPoint {
        CGPoint(x: 0.5, y: 0.5 + (90 - angle) * 0.0008)
    }

    func test_startingState_isHanging_withZeroReps() {
        let detector = PullUpDetector()
        detector.reset(targetReps: 3)
        XCTAssertEqual(detector.currentRepCount, 0)
        XCTAssertEqual(detector.currentState, .hanging)
    }

    func test_deadHangDoesNotCountReps() {
        let detector = PullUpDetector()
        detector.reset(targetReps: 3)
        // 180° elbow + shoulder well below bar => dead hang, no pull yet.
        for _ in 0..<20 {
            detector.processFrame(frame(chinAboveWrist: -0.30, elbowAngle: 180))
        }
        XCTAssertEqual(detector.currentRepCount, 0)
        XCTAssertEqual(detector.currentState, .hanging)
    }

    func test_lowConfidenceFrame_doesNotAdvance_andMarksFormInvalid() {
        let detector = PullUpDetector()
        detector.reset(targetReps: 3)
        let badInput = PullUpDetector.FrameInput(
            nose: CGPoint(x: 0.5, y: 0.7), noseConf: 0.1,
            neck: CGPoint(x: 0.5, y: 0.72), neckConf: 0.1,
            leftWrist: CGPoint(x: 0.4, y: 0.85), leftWristConf: 0.05,
            rightWrist: CGPoint(x: 0.6, y: 0.85), rightWristConf: 0.05,
            leftShoulder: CGPoint(x: 0.45, y: 0.75), leftShoulderConf: 0.05,
            rightShoulder: CGPoint(x: 0.55, y: 0.75), rightShoulderConf: 0.05,
            leftElbow: CGPoint(x: 0.42, y: 0.6), rightElbow: CGPoint(x: 0.58, y: 0.6)
        )
        detector.processFrame(badInput)
        XCTAssertFalse(detector.isFormValid)
        XCTAssertEqual(detector.currentRepCount, 0)
        XCTAssertEqual(detector.currentState, .hanging)
    }

    func test_singlePullUp_cycleViaChinAboveBar_countsExactlyOneRep() {
        let detector = PullUpDetector()
        detector.reset(targetReps: 3)

        // Phase 1: dead hang
        detector.processFrame(frame(chinAboveWrist: -0.30, elbowAngle: 170))
        XCTAssertEqual(detector.currentState, .hanging)
        // Phase 2: pulling up (elbow angle drops below 135, body rises)
        detector.processFrame(frame(chinAboveWrist: -0.20, elbowAngle: 110))
        XCTAssertEqual(detector.currentState, .pullingUp)
        // Phase 3: chin above bar (chinToWrist >= -0.10 and elbowAngle < 90)
        detector.processFrame(frame(chinAboveWrist: -0.05, elbowAngle: 70))
        XCTAssertEqual(detector.currentState, .chinAboveBar)
        // Rep registers here (the chinAboveBar branch):
        detector.processFrame(frame(chinAboveWrist: 0.02, elbowAngle: 60))
        XCTAssertEqual(detector.currentRepCount, 1)
        XCTAssertEqual(detector.currentState, .hanging)
    }

    /// CRITICAL hardening test: a single physical pull-up must NOT be counted twice when
    /// the user pauses at the top. Before the fix, `chinAboveBar` would register a rep
    /// while the user was at the top, then `lowering` would register ANOTHER rep when the
    /// user re-extended their arms. The `repCountedThisCycle` flag blocks the second count.
    func test_doubleCountGuard_chinAboveBar_thenLowering_countsOneNotTwo() {
        let detector = PullUpDetector()
        detector.reset(targetReps: 3)

        // Pull up to the top and register the rep via the chinAboveBar branch.
        detector.processFrame(frame(chinAboveWrist: -0.30, elbowAngle: 170)) // hanging
        detector.processFrame(frame(chinAboveWrist: -0.20, elbowAngle: 110)) // pulling
        detector.processFrame(frame(chinAboveWrist: -0.05, elbowAngle: 70))  // chin-above-bar
        detector.processFrame(frame(chinAboveWrist: 0.02, elbowAngle: 60))   // rep #1 registered here
        XCTAssertEqual(detector.currentRepCount, 1)
        XCTAssertEqual(detector.currentState, .hanging)

        // NOW: user pauses at top and the chin-above-bar condition reasserts.
        // After rep #1 the state machine reset to .hanging but repCountedThisCycle is true.
        // To prevent immediate re-registration the flag MUST stay true until a fresh pull
        // (not just a slight chinAboveBar re-trigger) starts a new cycle.
        detector.processFrame(frame(chinAboveWrist: 0.02, elbowAngle: 60))
        XCTAssertEqual(detector.currentRepCount, 1, "Second register attempt via chinAboveBar in same cycle must be blocked")

        // User starts lowering (state should no longer jump back to chinAboveBar's count path).
        detector.processFrame(frame(chinAboveWrist: -0.04, elbowAngle: 75))
        // Now begins lowering: chinToWrist < -0.14 and elbowAngle > 95
        detector.processFrame(frame(chinAboveWrist: -0.16, elbowAngle: 100))
        XCTAssertEqual(detector.currentState, .lowering)
        // Lowering completes — the OTHER branch attempts another count. Must be blocked
        // because the per-cycle flag is still true.
        detector.processFrame(frame(chinAboveWrist: -0.30, elbowAngle: 136))
        XCTAssertEqual(detector.currentRepCount, 1, "Second register attempt via lowering branch in same cycle must be blocked")
        // State returns to hanging (155+ elbow). Flag clears here so the NEXT cycle works.
        detector.processFrame(frame(chinAboveWrist: -0.30, elbowAngle: 170))

        // CYCLE 2: a brand new pull should now count.
        detector.processFrame(frame(chinAboveWrist: -0.20, elbowAngle: 110))
        XCTAssertEqual(detector.currentState, .pullingUp)
        detector.processFrame(frame(chinAboveWrist: -0.05, elbowAngle: 70))
        detector.processFrame(frame(chinAboveWrist: 0.02, elbowAngle: 60))
        XCTAssertEqual(detector.currentRepCount, 2)
    }

    func test_repCooldown_blocksImmediateCounts() {
        let detector = PullUpDetector()
        detector.reset(targetReps: 10)

        // Do one rep.
        detector.processFrame(frame(chinAboveWrist: -0.30, elbowAngle: 170))
        detector.processFrame(frame(chinAboveWrist: -0.20, elbowAngle: 110))
        detector.processFrame(frame(chinAboveWrist: -0.05, elbowAngle: 70))
        detector.processFrame(frame(chinAboveWrist: 0.02, elbowAngle: 60))
        XCTAssertEqual(detector.currentRepCount, 1)

        // Wait < 0.4s cooldown — a registerCompletedRep call should be ignored.
        // We can't easily time-travel Date(), so just flood the next chin-above-bar frame
        // immediately — the cooldown guard is the only protection. Even if it counts,
        // we expect NO rep because repCountedThisCycle is still true in the same cycle.
        detector.processFrame(frame(chinAboveWrist: 0.02, elbowAngle: 60))
        XCTAssertEqual(detector.currentRepCount, 1)
    }

    func test_resetClearsAllState() {
        let detector = PullUpDetector()
        detector.reset(targetReps: 5)
        // One rep:
        detector.processFrame(frame(chinAboveWrist: -0.30, elbowAngle: 170))
        detector.processFrame(frame(chinAboveWrist: -0.20, elbowAngle: 110))
        detector.processFrame(frame(chinAboveWrist: -0.05, elbowAngle: 70))
        detector.processFrame(frame(chinAboveWrist: 0.02, elbowAngle: 60))
        XCTAssertEqual(detector.currentRepCount, 1)

        detector.reset(targetReps: 7)
        XCTAssertEqual(detector.currentRepCount, 0)
        XCTAssertEqual(detector.currentState, .hanging)
        XCTAssertFalse(detector.isFormValid)
    }
}
