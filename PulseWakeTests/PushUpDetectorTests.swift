import XCTest
import CoreGraphics
@testable import PulseWake

/// Regression tests for push-up over-counting.
///
/// With the phone on the floor facing the user (`.inFrontOfFace`, the default placement),
/// the arms point at the lens, so the projected 2D elbow angle is foreshortened and noisy.
/// Every rep gate used to be an `||` of elbow angle and body drop, so that noise alone could
/// drive a full `.top → .bottom → .pushingUp → .top` cycle and pass the depth check, inflating
/// the count while the user was motionless.
///
/// These drive the pure `processFrame` seam — the same code path `processPoseObservation`
/// funnels into — so they run on the simulator with no camera.
final class PushUpDetectorTests: XCTestCase {

    /// Builds a frame from two abstract primitives:
    ///   - `bodyY`: normalized height of the head/shoulder cluster. Vision Y is bottom-left
    ///     origin, so a *smaller* value means lower in frame (chest toward the floor).
    ///   - `elbowAngle`: requested elbow flexion in degrees. 180 = locked out, 90 = right angle.
    ///
    /// Shoulders are placed a wide span apart so `updatePlacement` settles on `.inFrontOfFace`.
    /// The elbow is offset perpendicular to the shoulder→wrist line by the amount that makes
    /// the interior angle at the elbow equal `elbowAngle`, so the detector's own
    /// `calculateAngle` returns what the test asked for.
    private func frame(bodyY: Double, elbowAngle: Double) -> PushUpDetector.FrameInput {
        let shoulderSpanHalf = 0.09   // 0.18 total — comfortably over the 0.11 "front" threshold
        let shoulderY = bodyY
        let wristY = bodyY - 0.20     // hands on the floor, below the shoulders
        let armSegment = 0.16

        let halfFlex = (180.0 - elbowAngle) / 2.0 * .pi / 180.0
        let perpOffset = armSegment * sin(halfFlex)

        let midY = (shoulderY + wristY) / 2.0

        return PushUpDetector.FrameInput(
            nose: CGPoint(x: 0.5, y: bodyY + 0.03), noseConf: 0.9,
            neck: CGPoint(x: 0.5, y: bodyY + 0.01), neckConf: 0.9,
            leftShoulder: CGPoint(x: 0.5 - shoulderSpanHalf, y: shoulderY), leftShoulderConf: 0.9,
            rightShoulder: CGPoint(x: 0.5 + shoulderSpanHalf, y: shoulderY), rightShoulderConf: 0.9,
            leftElbow: CGPoint(x: 0.5 - shoulderSpanHalf - perpOffset, y: midY), leftElbowConf: 0.9,
            rightElbow: CGPoint(x: 0.5 + shoulderSpanHalf + perpOffset, y: midY), rightElbowConf: 0.9,
            leftWrist: CGPoint(x: 0.5 - shoulderSpanHalf, y: wristY), leftWristConf: 0.9,
            rightWrist: CGPoint(x: 0.5 + shoulderSpanHalf, y: wristY), rightWristConf: 0.9
        )
    }

    /// Feeds a frame enough times for the exponential smoothers (alpha 0.35 / 0.4) to settle
    /// on the requested value. One frame only moves ~40% of the way there.
    private func settle(_ detector: PushUpDetector, bodyY: Double, elbowAngle: Double, frames: Int = 12) {
        for _ in 0..<frames {
            detector.processFrame(frame(bodyY: bodyY, elbowAngle: elbowAngle))
        }
    }

    private func makeDetector() -> PushUpDetector {
        let detector = PushUpDetector()
        detector.reset(targetReps: 10)
        // Establish the top baseline at a settled, arms-locked-out top position.
        settle(detector, bodyY: 0.60, elbowAngle: 175)
        XCTAssertEqual(detector.placement, .inFrontOfFace, "Wide shoulder span should read as phone-in-front")
        return detector
    }

    // MARK: - The over-counting regression

    func test_elbowNoiseWithoutBodyMovement_countsNothing() {
        let detector = makeDetector()

        // The user is motionless — body height never changes. Only the elbow angle swings,
        // exactly as foreshortened arm keypoints do when the phone lies in front of them.
        // This used to walk the full rep cycle and count reps.
        for _ in 0..<10 {
            settle(detector, bodyY: 0.60, elbowAngle: 100, frames: 6)
            settle(detector, bodyY: 0.60, elbowAngle: 170, frames: 6)
        }

        XCTAssertEqual(detector.currentRepCount, 0, "Elbow noise with a motionless body must not count reps")
    }

    func test_shallowBodyDip_doesNotCount() {
        let detector = makeDetector()

        // A dip far shallower than frontMinBodyDropForRep (0.038) — a head nod, not a push-up.
        settle(detector, bodyY: 0.585, elbowAngle: 120)
        settle(detector, bodyY: 0.60, elbowAngle: 175)

        XCTAssertEqual(detector.currentRepCount, 0, "A dip under the depth threshold must not count")
    }

    // MARK: - Real reps still register

    func test_fullBodyDropRep_countsOnce() {
        let detector = makeDetector()

        // Genuine push-up: chest drops well past the 0.038 depth threshold, then returns.
        settle(detector, bodyY: 0.50, elbowAngle: 95)
        settle(detector, bodyY: 0.60, elbowAngle: 175)

        XCTAssertEqual(detector.currentRepCount, 1, "A full-depth rep must count")
        XCTAssertEqual(detector.currentState, .top)
    }

    func test_twoSpacedReps_countTwice() {
        let detector = makeDetector()

        settle(detector, bodyY: 0.50, elbowAngle: 95)
        settle(detector, bodyY: 0.60, elbowAngle: 175)
        XCTAssertEqual(detector.currentRepCount, 1)

        // Clear the 0.8 s rep cooldown before the second rep.
        Thread.sleep(forTimeInterval: 0.85)

        settle(detector, bodyY: 0.50, elbowAngle: 95)
        settle(detector, bodyY: 0.60, elbowAngle: 175)
        XCTAssertEqual(detector.currentRepCount, 2, "A second full rep after the cooldown must count")
    }

    func test_repCooldown_blocksRapidFireCounts() {
        let detector = makeDetector()

        settle(detector, bodyY: 0.50, elbowAngle: 95)
        settle(detector, bodyY: 0.60, elbowAngle: 175)
        XCTAssertEqual(detector.currentRepCount, 1)

        // Immediately repeat the same motion with no cooldown gap.
        settle(detector, bodyY: 0.50, elbowAngle: 95)
        settle(detector, bodyY: 0.60, elbowAngle: 175)

        XCTAssertEqual(detector.currentRepCount, 1, "Reps inside the 0.8 s cooldown must not count")
        XCTAssertEqual(detector.currentState, .top, "A blocked rep must still reset to .top, not stick")
    }

    // MARK: - Housekeeping

    func test_lowConfidenceFrame_marksFormInvalidAndDoesNotCount() {
        let detector = makeDetector()

        var blind = frame(bodyY: 0.50, elbowAngle: 95)
        blind.noseConf = 0.05; blind.neckConf = 0.05
        blind.leftShoulderConf = 0.05; blind.rightShoulderConf = 0.05
        blind.leftElbowConf = 0.05; blind.rightElbowConf = 0.05
        blind.leftWristConf = 0.05; blind.rightWristConf = 0.05
        detector.processFrame(blind)

        XCTAssertFalse(detector.isFormValid)
        XCTAssertEqual(detector.currentRepCount, 0)
    }

    func test_resetClearsAllState() {
        let detector = makeDetector()
        settle(detector, bodyY: 0.50, elbowAngle: 95)
        settle(detector, bodyY: 0.60, elbowAngle: 175)
        XCTAssertEqual(detector.currentRepCount, 1)

        detector.reset(targetReps: 5)

        XCTAssertEqual(detector.currentRepCount, 0)
        XCTAssertEqual(detector.currentState, .top)
        XCTAssertEqual(detector.bodyDropRatio, 0.0)
        XCTAssertFalse(detector.isFormValid)
    }
}
