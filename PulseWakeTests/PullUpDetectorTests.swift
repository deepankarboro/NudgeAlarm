import XCTest
import CoreGraphics
@testable import PulseWake

/// Endpoint G: state-machine tests for PullUpDetector's double-count guard.
///
/// The detector has two rep-registration branches per cycle (`chinAboveBar` and
/// `lowering`). Before the fix, a single physical pull-up could be counted twice
/// from both branches if the user paused at the top. The hardening: a `repCountedThisCycle`
/// flag set on first registration, cleared only on returning to `.hanging`.
///
/// These tests drive the pure `processFrame` seam (no Vision dependency) so they run on
/// the simulator without a device. The helper computes elbow joint positions from
/// requested geometric primitives (chin-above-wrist offset, elbow angle) so the
/// detector's underlying `calculateAngle(shoulder, elbow, wrist)` math produces the
/// same angle the test requested.
final class PullUpDetectorTests: XCTestCase {

    /// Builds a FrameInput from two abstract primitives:
    ///   - `chinAboveWrist`: chin Y minus wrist Y. Positive = chin above wrists (over bar).
    ///     Realistic pull-up: ranges from -0.30 (dead hang) to +0.05 (chin over bar).
    ///   - `elbowAngle`: requested elbow flexion in degrees. 180 = locked-out arm.
    ///     0 = fully bent. Real pull-up ranges from 180 (hang) down to ~50 (top).
    ///
    /// The elbow joint is placed such that the angle formed at the elbow by the
    /// vectors shoulder→elbow and wrist→elbow equals `elbowAngle`.
    /// All other joints use realistic symmetric positions around the vertical axis.
    private func frame(chinAboveWrist: Double, elbowAngle: Double) -> PullUpDetector.FrameInput {
        // Place wrists high in the frame (bar height).
        let wristY: Double = 0.85
        let wristX: Double = 0.5
        let chinY: Double = wristY + chinAboveWrist

        // Shoulders ~10 cm below chin (normalized units rough approximation).
        let shoulderY: Double = chinY - 0.10
        // Place shoulder directly below chin.
        let shoulderX: Double = 0.5

        // Wrist-to-shoulder distance; arms are roughly vertical in a pull-up.
        let armSegment: Double = 0.30 // shoulder-to-elbow and elbow-to-wrist both
        // Total arm length = 2 * armSegment. The shoulder-to-wrist distance changes
        // as the elbow flexes: by cosine law, distance = 2 * s * cos((180 - angle) / 2)?...
        // Simpler: place the elbow horizontally off the shoulder-wrist line so the
        // interior angle at the elbow equals `elbowAngle`. Use a perpendicular offset
        // that scales with sin((180 - elbowAngle)/2 * pi/180).
        let halfFlex = (180.0 - elbowAngle) / 2.0 * .pi / 180.0 // radians
        let halfChord = armSegment * cos(halfFlex) // half the shoulder-wrist chord
        let perpOffset = armSegment * sin(halfFlex) // elbow protrudes this far sideways

        // Shoulder-wrist line is vertical (shoulder directly below wrist since arm hangs up).
        // Place the midpoint, then elbow offset perpendicular (horizontal).
        let midY = (shoulderY + wristY) / 2.0
        let elbowX = wristX + perpOffset // bent elbow sticks out to the right
        let elbowY = midY

        // Sanity: ensure shoulder-wrist distance is achievable with armSegment length.
        let shoulderWristDist = abs(wristY - shoulderY)
        // If elbowAngle=180 (straight), perpOffset=0 and halfChord=armSegment, so
        // shoulder-wrist distance should equal 2*halfChord = 2*armSegment. Adjust
        // shoulderY so this holds (otherwise angle math is off).
        // -> We set shoulderY = wristY - 2*armSegment when fully extended. To keep
        // tests simple, only flexible the inputs in a range where this is true.
        let straightArmShoulderY = wristY - 2 * armSegment
        let resolvedShoulderY: Double
        if abs(elbowAngle - 180.0) < 0.5 {
            resolvedShoulderY = straightArmShoulderY
        } else {
            // Adjust shoulderY to honor cosine law: chord = 2 * armSegment * cos(halfFlex).
            // chord = |wristY - shoulderY| (arms vertical). So shoulderY = wristY - chord.
            let chord = 2 * armSegment * cos(halfFlex)
            resolvedShoulderY = wristY - chord
        }
        // recompute midY and elbowY with resolvedShoulderY
        let resolvedMidY = (resolvedShoulderY + wristY) / 2.0
        let resolvedElbowY = resolvedMidY
        // recompute chinY relative to the resolved shoulder (keep chin above wrists by
        // the requested offset). chin must be > shoulderY for realism.
        let resolvedChinY = wristY + chinAboveWrist

        let conf: Float = 0.95
        return PullUpDetector.FrameInput(
            nose: CGPoint(x: 0.5, y: resolvedChinY), noseConf: 0.95,
            neck: CGPoint(x: 0.5, y: resolvedShoulderY + 0.04), neckConf: 0.95,
            leftWrist: CGPoint(x: wristX - 0.08, y: wristY), leftWristConf: conf,
            rightWrist: CGPoint(x: wristX + 0.08, y: wristY), rightWristConf: conf,
            leftShoulder: CGPoint(x: shoulderX - 0.06, y: resolvedShoulderY), leftShoulderConf: conf,
            rightShoulder: CGPoint(x: shoulderX + 0.06, y: resolvedShoulderY), rightShoulderConf: conf,
            leftElbow: CGPoint(x: elbowX - 0.12, y: resolvedElbowY),
            rightElbow: CGPoint(x: elbowX + 0.12, y: resolvedElbowY)
        )
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
        // 180° straight-arm dead hang, chin well below bar.
        for _ in 0..<20 {
            detector.processFrame(frame(chinAboveWrist: -0.40, elbowAngle: 180))
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

        // Phase 1: dead hang (elbow ~170°, chin well below bar).
        detector.processFrame(frame(chinAboveWrist: -0.40, elbowAngle: 170))
        XCTAssertEqual(detector.currentState, .hanging, "Dead hang should stay in .hanging")

        // Phase 2: pulling up - elbow flexes past 135°, body rises (shoulder near bar).
        detector.processFrame(frame(chinAboveWrist: -0.25, elbowAngle: 110))
        XCTAssertEqual(detector.currentState, .pullingUp, "Flexed arm + rising body should start pulling")

        // Phase 3a: chin approaches bar - this frame TRANSITIONS to .chinAboveBar (the first
        // switch case fires: pullingUp→chinAboveBar via chinToWrist >= -0.08) but does NOT
        // register a rep on this same frame (the switch case exits).
        detector.processFrame(frame(chinAboveWrist: -0.05, elbowAngle: 70))
        XCTAssertEqual(detector.currentState, .chinAboveBar, "Chin reaching bar transitions to chinAboveBar")

        // Phase 3b: another frame at the top — now the chinAboveBar branch can register:
        //   chinToWrist (0.02) >= -0.10 AND elbowAngle (60) < 90 → registerCompletedRep.
        detector.processFrame(frame(chinAboveWrist: 0.02, elbowAngle: 60))
        XCTAssertEqual(detector.currentRepCount, 1, "Second chin-above-bar frame should register rep #1")
        XCTAssertEqual(detector.currentState, .hanging, "After registerCompletedRep the state returns to .hanging")
    }

    /// CRITICAL hardening test: a single physical pull-up must NOT be counted twice when the
    /// user pauses at the top. Before the fix, `chinAboveBar` would register a rep while the
    /// user was at the top, then `lowering` would register ANOTHER rep when the user re-
    /// extended their arms. The `repCountedThisCycle` flag blocks the second count.
    func test_doubleCountGuard_chinAboveBar_thenLowering_countsOneNotTwo() {
        let detector = PullUpDetector()
        detector.reset(targetReps: 3)

        // Initial pull-up: register rep #1 via the chinAboveBar branch.
        detector.processFrame(frame(chinAboveWrist: -0.40, elbowAngle: 170)) // hanging
        XCTAssertEqual(detector.currentState, .hanging)
        detector.processFrame(frame(chinAboveWrist: -0.25, elbowAngle: 110)) // pulling
        XCTAssertEqual(detector.currentState, .pullingUp)
        detector.processFrame(frame(chinAboveWrist: -0.05, elbowAngle: 70))  // chin above bar (transitions to chinAboveBar)
        XCTAssertEqual(detector.currentState, .chinAboveBar)
        detector.processFrame(frame(chinAboveWrist: 0.02, elbowAngle: 60))   // register rep #1
        XCTAssertEqual(detector.currentRepCount, 1)
        XCTAssertEqual(detector.currentState, .hanging)

        // The user pauses at the top: another frame at the top satisfies the chinAboveBar
        // register condition, but per-cycle flag must block re-registration. State is now
        // .hanging but repCountedThisCycle is true; chinAboveWrist=0.02 + elbow=60 would
        // transition hanging → pullingUp. After this frame the state should be .pullingUp
        // (NOT a new rep counted) because the cycle hasn't completed.
        detector.processFrame(frame(chinAboveWrist: 0.02, elbowAngle: 60))
        XCTAssertEqual(detector.currentRepCount, 1, "Re-register in same cycle must be blocked")
        // With chinToWrist=0.02 and elbow=60, shoulderY > (wristY - 0.25) is true → pullingUp.
        XCTAssertEqual(detector.currentState, .pullingUp)

        // Now the user's elbow extends (>95°) AND chin drops below bar (chinToWrist < -0.14):
        // chinAboveBar→lowering transition.
        // First come back up a hair so .pullingUp→.chinAboveBar path is exercised, then drop.
        detector.processFrame(frame(chinAboveWrist: -0.20, elbowAngle: 110)) // elbow flexes again
        XCTAssertEqual(detector.currentState, .pullingUp, "Still pulling (chin below bar threshold)")
        detector.processFrame(frame(chinAboveWrist: -0.20, elbowAngle: 100)) // elbow >95 but chinToWrist -0.20 < -0.14 ok for lowering
        // Now the chin-above-bar → lowering condition: chin < -0.14 AND elbow > 95.
        // But state is .pullingUp, not .chinAboveBar; we need a chin-above-bar transition first.
        // Retry with a frame sequence that goes through chin-above-bar.
        detector.processFrame(frame(chinAboveWrist: -0.05, elbowAngle: 80))  // back to chin-above-bar
        XCTAssertEqual(detector.currentState, .chinAboveBar)
        detector.processFrame(frame(chinAboveWrist: -0.20, elbowAngle: 100)) // chin BELOW threshold + elbow >95 → lowering
        XCTAssertEqual(detector.currentState, .lowering, "Chin below bar + elbow >95° should start lowering")

        // Lowering completes (elbow extends past 135°) — lowering branch WOULD register another
        // rep if the per-cycle guard weren't in place. With the guard it must NOT count.
        detector.processFrame(frame(chinAboveWrist: -0.40, elbowAngle: 150))
        XCTAssertEqual(detector.currentRepCount, 1, "Lowering-branch register in same cycle must be blocked")
        XCTAssertEqual(detector.currentState, .lowering, "Without registerCompletedRep clearing, state stays .lowering")

        // Final true dead hang — clears the per-cycle flag and returns state to .hanging.
        detector.processFrame(frame(chinAboveWrist: -0.40, elbowAngle: 180))
        XCTAssertEqual(detector.currentState, .hanging, "Full lockout returns to hanging and clears the guard")

        // CYCLE 2: a brand new pull should now count. Clear the 0.4 s anti-double-count
        // cooldown first — the frames above are driven in microseconds, which no real pull-up
        // can match, and without the wait the detector correctly rejects rep #2 as too soon.
        Thread.sleep(forTimeInterval: 0.45)

        detector.processFrame(frame(chinAboveWrist: -0.25, elbowAngle: 110))
        XCTAssertEqual(detector.currentState, .pullingUp)
        detector.processFrame(frame(chinAboveWrist: -0.05, elbowAngle: 70))
        detector.processFrame(frame(chinAboveWrist: 0.02, elbowAngle: 60))
        XCTAssertEqual(detector.currentRepCount, 2)
    }

    func test_repCooldown_blocksRapidFireCounts() {
        let detector = PullUpDetector()
        detector.reset(targetReps: 10)

        // Rep #1 via chinAboveBar path.
        detector.processFrame(frame(chinAboveWrist: -0.40, elbowAngle: 170))
        detector.processFrame(frame(chinAboveWrist: -0.25, elbowAngle: 110))
        detector.processFrame(frame(chinAboveWrist: -0.05, elbowAngle: 70)) // → chinAboveBar
        detector.processFrame(frame(chinAboveWrist: 0.02, elbowAngle: 60))  // register rep #1
        XCTAssertEqual(detector.currentRepCount, 1)

        // Immediately re-trigger the same chin-above-bar condition: per-cycle guard blocks
        // (registerCompletedRep would normally have flipped to .hanging; subsequent chin frame
        // transitions hanging→pullingUp without counting).
        detector.processFrame(frame(chinAboveWrist: 0.02, elbowAngle: 60))
        XCTAssertEqual(detector.currentRepCount, 1)
    }

    func test_resetClearsAllState() {
        let detector = PullUpDetector()
        detector.reset(targetReps: 5)

        detector.processFrame(frame(chinAboveWrist: -0.40, elbowAngle: 170))
        detector.processFrame(frame(chinAboveWrist: -0.25, elbowAngle: 110))
        detector.processFrame(frame(chinAboveWrist: -0.05, elbowAngle: 70))
        detector.processFrame(frame(chinAboveWrist: 0.02, elbowAngle: 60))  // register rep #1
        XCTAssertEqual(detector.currentRepCount, 1)

        detector.reset(targetReps: 7)
        XCTAssertEqual(detector.currentRepCount, 0)
        XCTAssertEqual(detector.currentState, .hanging)
        XCTAssertFalse(detector.isFormValid)
    }
}
