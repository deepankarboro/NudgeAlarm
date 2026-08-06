import Foundation
import CoreGraphics
import Vision

public enum PushUpState {
    case top
    case goingDown
    case bottom
    case pushingUp
}

/// How the phone is placed relative to the user (auto-detected from pose).
public enum PushUpPhonePlacement: String {
    case inFrontOfFace = "Phone in front"
    case sideProfile = "Phone to the side"
}

@Observable
public final class PushUpDetector {
    public var currentRepCount: Int = 0
    public var currentState: PushUpState = .top
    public var formFeedback: String = "Place phone on the floor in front of you"
    public var currentElbowAngle: Double = 180.0
    public var isFormValid: Bool = false
    /// 0…1 — how far the upper body has lowered this rep (best for phone-in-front layout).
    public var bodyDropRatio: Double = 0.0
    public var placement: PushUpPhonePlacement = .inFrontOfFace

    // MARK: - Diagnostics
    // Temporary instrumentation for tuning rep detection on-device. Rep counting can fail in
    // three different ways that look identical from the outside — the depth gate rejecting the
    // rep, the cooldown rejecting it, or the state machine never completing a cycle at all —
    // so these surface which one actually happened. Remove once the thresholds are settled.

    /// Full top→bottom→top cycles the state machine has completed, counted or not. If this
    /// tracks the reps performed but `currentRepCount` lags, the motion is being seen and a gate
    /// is rejecting it. If it lags too, the state machine isn't cycling.
    public var detectedCycles: Int = 0
    /// Peak depth of the most recent cycle as a fraction of what the gate demands. 1.0 = passes.
    public var lastAttemptDepthRatio: Double = 0.0
    /// Why the most recent cycle didn't count, or nil if it did.
    public var lastRejectionReason: String?
    /// Live top-of-rep baseline, to make drift visible.
    public var debugBaselineY: Double = 0.0
    /// Live unclipped body drop. `bodyDropRatio` saturates at 1.0, so it can't show how far
    /// past — or short of — the threshold the motion actually reaches.
    public var debugLiveDrop: Double = 0.0
    /// The depth the gate currently demands, so the HUD doesn't hardcode it.
    public var debugRequiredDrop: Double { frontMinBodyDropForRep }

    private var targetReps: Int = 10
    private var lastRepCompletedAt: Date = .distantPast
    /// A genuine push-up cycle takes about a second. The old 0.45 s window was short enough
    /// that sensor noise could fire two "reps" back to back.
    private let minSecondsBetweenReps: TimeInterval = 0.8

    private var smoothedElbowAngle: Double = 180.0
    private var smoothedBodyY: Double = 0.5
    private var minElbowAngleInCurrentRep: Double = 180.0
    private var maxBodyDropInCurrentRep: Double = 0.0
    private var topBodyBaselineY: Double?
    private var placementFrontScore: Double = 1.0
    private let angleSmoothingAlpha: Double = 0.35
    private let bodySmoothingAlpha: Double = 0.4

    // Side / elbow-focused thresholds
    private let sideBottomEnterAngle: Double = 115.0
    private let sideBottomHoldAngle: Double = 120.0
    private let sideTopLockoutAngle: Double = 145.0
    private let sideMinDepthAngleForRep: Double = 125.0

    // Front / upper-body drop thresholds (Vision Y: lower value = lower in frame)
    private let frontMinBodyDropForRep: Double = 0.038
    private let frontBottomEnterDrop: Double = 0.030
    private let frontTopReturnDrop: Double = 0.014

    public init(targetReps: Int = 10) {
        self.targetReps = targetReps
    }

    public func reset(targetReps: Int) {
        self.targetReps = targetReps
        self.currentRepCount = 0
        self.currentState = .top
        self.formFeedback = "Place phone on the floor in front of you — watch the rep count"
        self.currentElbowAngle = 180.0
        self.isFormValid = false
        self.bodyDropRatio = 0.0
        self.placement = .inFrontOfFace
        self.smoothedElbowAngle = 180.0
        self.smoothedBodyY = 0.5
        self.minElbowAngleInCurrentRep = 180.0
        self.maxBodyDropInCurrentRep = 0.0
        self.topBodyBaselineY = nil
        self.placementFrontScore = 1.0
        self.lastRepCompletedAt = .distantPast
        self.detectedCycles = 0
        self.lastAttemptDepthRatio = 0.0
        self.lastRejectionReason = nil
        self.debugBaselineY = 0.0
    }

    /// Plain-value view of a single Vision frame. `processPoseObservation` converts the
    /// Vision observation into one of these and every bit of detection math then runs off
    /// this one representation, so the unit-test seam exercises the *same* code path the
    /// camera does rather than a parallel copy that can silently drift.
    /// Vision normalized coords: (0,0) bottom-left, (1,1) top-right. Confidence in 0…1.
    public struct FrameInput {
        public var nose: CGPoint
        public var noseConf: Float
        public var neck: CGPoint
        public var neckConf: Float
        public var leftShoulder: CGPoint
        public var leftShoulderConf: Float
        public var rightShoulder: CGPoint
        public var rightShoulderConf: Float
        public var leftElbow: CGPoint
        public var leftElbowConf: Float
        public var rightElbow: CGPoint
        public var rightElbowConf: Float
        public var leftWrist: CGPoint
        public var leftWristConf: Float
        public var rightWrist: CGPoint
        public var rightWristConf: Float

        public init(
            nose: CGPoint, noseConf: Float,
            neck: CGPoint, neckConf: Float,
            leftShoulder: CGPoint, leftShoulderConf: Float,
            rightShoulder: CGPoint, rightShoulderConf: Float,
            leftElbow: CGPoint, leftElbowConf: Float,
            rightElbow: CGPoint, rightElbowConf: Float,
            leftWrist: CGPoint, leftWristConf: Float,
            rightWrist: CGPoint, rightWristConf: Float
        ) {
            self.nose = nose; self.noseConf = noseConf
            self.neck = neck; self.neckConf = neckConf
            self.leftShoulder = leftShoulder; self.leftShoulderConf = leftShoulderConf
            self.rightShoulder = rightShoulder; self.rightShoulderConf = rightShoulderConf
            self.leftElbow = leftElbow; self.leftElbowConf = leftElbowConf
            self.rightElbow = rightElbow; self.rightElbowConf = rightElbowConf
            self.leftWrist = leftWrist; self.leftWristConf = leftWristConf
            self.rightWrist = rightWrist; self.rightWristConf = rightWristConf
        }
    }

    public func processPoseObservation(_ observation: VNHumanBodyPoseObservation) {
        do {
            let nose = try observation.recognizedPoint(.nose)
            let neck = try observation.recognizedPoint(.neck)
            let leftShoulder = try observation.recognizedPoint(.leftShoulder)
            let leftElbow = try observation.recognizedPoint(.leftElbow)
            let leftWrist = try observation.recognizedPoint(.leftWrist)
            let rightShoulder = try observation.recognizedPoint(.rightShoulder)
            let rightElbow = try observation.recognizedPoint(.rightElbow)
            let rightWrist = try observation.recognizedPoint(.rightWrist)

            processFrame(FrameInput(
                nose: nose.location, noseConf: nose.confidence,
                neck: neck.location, neckConf: neck.confidence,
                leftShoulder: leftShoulder.location, leftShoulderConf: leftShoulder.confidence,
                rightShoulder: rightShoulder.location, rightShoulderConf: rightShoulder.confidence,
                leftElbow: leftElbow.location, leftElbowConf: leftElbow.confidence,
                rightElbow: rightElbow.location, rightElbowConf: rightElbow.confidence,
                leftWrist: leftWrist.location, leftWristConf: leftWrist.confidence,
                rightWrist: rightWrist.location, rightWristConf: rightWrist.confidence
            ))
        } catch {
            isFormValid = false
            formFeedback = "Angle the phone so your upper body is visible"
        }
    }

    public func processFrame(_ input: FrameInput) {
        let leftArmConf = jointConfidence(input.leftShoulderConf, input.leftElbowConf, input.leftWristConf)
        let rightArmConf = jointConfidence(input.rightShoulderConf, input.rightElbowConf, input.rightWristConf)
        let shoulderConf = (input.leftShoulderConf + input.rightShoulderConf) / 2.0
        let headConf = max(input.noseConf, input.neckConf)

        guard leftArmConf > 0.2 || rightArmConf > 0.2 || shoulderConf > 0.25 || headConf > 0.3 else {
            isFormValid = false
            formFeedback = "Keep your face, shoulders, and arms in view"
            return
        }

        isFormValid = true
        updatePlacement(input)

        let rawAngle = combinedElbowAngle(input, leftConf: leftArmConf, rightConf: rightArmConf)
        smoothedElbowAngle = smoothedElbowAngle * (1.0 - angleSmoothingAlpha) + rawAngle * angleSmoothingAlpha
        currentElbowAngle = smoothedElbowAngle

        if let rawBodyY = compositeUpperBodyY(input) {
            smoothedBodyY = smoothedBodyY * (1.0 - bodySmoothingAlpha) + rawBodyY * bodySmoothingAlpha
        }

        updateTopBaseline(bodyY: smoothedBodyY, elbowAngle: smoothedElbowAngle)
        debugBaselineY = topBodyBaselineY ?? 0
        let bodyDrop = bodyDropFromTop(bodyY: smoothedBodyY)
        debugLiveDrop = bodyDrop
        maxBodyDropInCurrentRep = max(maxBodyDropInCurrentRep, bodyDrop)
        bodyDropRatio = min(1.0, bodyDrop / frontMinBodyDropForRep)

        updateStateMachine(elbowAngle: smoothedElbowAngle, bodyDrop: bodyDrop)
    }

    private func updatePlacement(_ input: FrameInput) {
        let shoulderSpan = Double(abs(input.leftShoulder.x - input.rightShoulder.x))
        let wristSpan = Double(abs(input.leftWrist.x - input.rightWrist.x))
        let shoulderVisible = input.leftShoulderConf > 0.25 && input.rightShoulderConf > 0.25

        var frontHint = 0.55
        if shoulderVisible {
            if shoulderSpan >= 0.11 {
                frontHint = 0.85
            } else if shoulderSpan <= 0.06 {
                frontHint = 0.2
            } else {
                frontHint = 0.5
            }
            if wristSpan > shoulderSpan * 0.9 {
                frontHint = min(1.0, frontHint + 0.1)
            }
        }

        placementFrontScore = placementFrontScore * 0.85 + frontHint * 0.15
        placement = placementFrontScore >= 0.5 ? .inFrontOfFace : .sideProfile
    }

    private func compositeUpperBodyY(_ input: FrameInput) -> Double? {
        var sum = 0.0
        var weight = 0.0

        if input.noseConf > 0.25 {
            sum += Double(input.nose.y) * 0.45
            weight += 0.45
        }
        if input.neckConf > 0.25 {
            sum += Double(input.neck.y) * 0.25
            weight += 0.25
        }
        let shoulderConf = (input.leftShoulderConf + input.rightShoulderConf) / 2.0
        if shoulderConf > 0.25 {
            let shoulderY = Double((input.leftShoulder.y + input.rightShoulder.y) / 2.0)
            sum += shoulderY * 0.30
            weight += 0.30
        }

        guard weight > 0.15 else { return nil }
        return sum / weight
    }

    private func updateTopBaseline(bodyY: Double, elbowAngle: Double) {
        guard topBodyBaselineY != nil || currentState == .top || currentState == .pushingUp else { return }

        let nearTop: Bool
        switch placement {
        case .inFrontOfFace:
            nearTop = bodyDropFromTop(bodyY: bodyY) <= frontTopReturnDrop * 1.5
                || (topBodyBaselineY == nil && currentState == .top)
        case .sideProfile:
            nearTop = elbowAngle >= sideTopLockoutAngle - 8.0
        }

        guard nearTop else { return }
        if let baseline = topBodyBaselineY {
            topBodyBaselineY = baseline * 0.9 + bodyY * 0.1
        } else {
            topBodyBaselineY = bodyY
        }
    }

    private func bodyDropFromTop(bodyY: Double) -> Double {
        guard let baseline = topBodyBaselineY else { return 0 }
        return max(0, baseline - bodyY)
    }

    // MARK: - Rep gating
    //
    // Each placement is gated on the ONE signal that camera geometry makes trustworthy for
    // it, and never on the other as an independent trigger:
    //
    //   .inFrontOfFace — phone on the floor facing the user. The arms point at the lens, so
    //     the projected 2D elbow angle is heavily foreshortened and noisy; it swings across
    //     the 115°/145° thresholds while the user is motionless. Upper-body drop is the
    //     honest signal here.
    //   .sideProfile — phone side-on. The elbow bend is now in the image plane and measures
    //     cleanly, while vertical head/shoulder travel is small and easily confused with the
    //     user shifting position. Elbow angle is the honest signal here.
    //
    // These were previously `||` of both signals at every gate, which let noise on the
    // untrustworthy signal drive a whole rep cycle and pass the depth check on its own —
    // the cause of phantom reps.

    private func isDescending(elbowAngle: Double, bodyDrop: Double) -> Bool {
        switch placement {
        case .inFrontOfFace:
            return bodyDrop > frontBottomEnterDrop * 0.4
        case .sideProfile:
            return elbowAngle < sideTopLockoutAngle - 15.0
        }
    }

    private func reachedBottom(elbowAngle: Double, bodyDrop: Double) -> Bool {
        switch placement {
        case .inFrontOfFace:
            return bodyDrop >= frontBottomEnterDrop
        case .sideProfile:
            return elbowAngle <= sideBottomEnterAngle
        }
    }

    private func reachedTop(elbowAngle: Double, bodyDrop: Double) -> Bool {
        switch placement {
        case .inFrontOfFace:
            return bodyDrop <= frontTopReturnDrop
        case .sideProfile:
            return elbowAngle >= sideTopLockoutAngle
        }
    }

    private func leavingBottom(elbowAngle: Double, bodyDrop: Double) -> Bool {
        switch placement {
        case .inFrontOfFace:
            return bodyDrop <= frontBottomEnterDrop * 0.65
        case .sideProfile:
            return elbowAngle > sideBottomHoldAngle
        }
    }

    private func updateStateMachine(elbowAngle: Double, bodyDrop: Double) {
        let depthReached = reachedBottom(elbowAngle: elbowAngle, bodyDrop: bodyDrop)

        switch currentState {
        case .top:
            minElbowAngleInCurrentRep = elbowAngle
            maxBodyDropInCurrentRep = bodyDrop
            if depthReached {
                currentState = .bottom
                formFeedback = "Good depth — push back up"
            } else if isDescending(elbowAngle: elbowAngle, bodyDrop: bodyDrop) {
                currentState = .goingDown
                formFeedback = placement == .inFrontOfFace
                    ? "Lower chest toward the floor"
                    : "Lower your chest"
            } else {
                formFeedback = placement == .inFrontOfFace
                    ? "Start from the top — arms straight"
                    : "Arms straight — begin the rep"
            }

        case .goingDown:
            minElbowAngleInCurrentRep = min(minElbowAngleInCurrentRep, elbowAngle)
            maxBodyDropInCurrentRep = max(maxBodyDropInCurrentRep, bodyDrop)
            if depthReached {
                currentState = .bottom
                formFeedback = "Good depth — push back up"
            } else {
                formFeedback = "A bit lower"
            }

        case .bottom:
            minElbowAngleInCurrentRep = min(minElbowAngleInCurrentRep, elbowAngle)
            maxBodyDropInCurrentRep = max(maxBodyDropInCurrentRep, bodyDrop)
            if leavingBottom(elbowAngle: elbowAngle, bodyDrop: bodyDrop) {
                currentState = .pushingUp
                formFeedback = "Push up to the top"
            } else {
                formFeedback = "Press through the floor"
            }

        case .pushingUp:
            if reachedTop(elbowAngle: elbowAngle, bodyDrop: bodyDrop) {
                registerCompletedRep()
            } else {
                formFeedback = placement == .inFrontOfFace
                    ? "Come back up — face the screen"
                    : "Lock out at the top"
            }
        }
    }

    private func registerCompletedRep() {
        let now = Date()

        // Diagnostics: record the attempt before any gate can reset the accumulators.
        detectedCycles += 1
        let elapsed = now.timeIntervalSince(lastRepCompletedAt)
        switch placement {
        case .inFrontOfFace:
            lastAttemptDepthRatio = maxBodyDropInCurrentRep / frontMinBodyDropForRep
        case .sideProfile:
            lastAttemptDepthRatio = minElbowAngleInCurrentRep <= sideMinDepthAngleForRep ? 1.0 : 0.0
        }

        guard elapsed >= minSecondsBetweenReps else {
            // Too soon to be a real rep. Reset to the top so the cycle can restart cleanly
            // rather than leaving the machine parked in .pushingUp.
            lastRejectionReason = String(format: "too soon (%.2fs)", elapsed)
            currentState = .top
            minElbowAngleInCurrentRep = 180.0
            maxBodyDropInCurrentRep = 0.0
            return
        }

        // The rep must have actually reached depth on this placement's trusted signal.
        let depthOK: Bool
        switch placement {
        case .inFrontOfFace:
            depthOK = maxBodyDropInCurrentRep >= frontMinBodyDropForRep
        case .sideProfile:
            depthOK = minElbowAngleInCurrentRep <= sideMinDepthAngleForRep
        }

        guard depthOK else {
            lastRejectionReason = String(format: "too shallow (%.0f%%)", lastAttemptDepthRatio * 100)
            currentState = .top
            formFeedback = placement == .inFrontOfFace
                ? "Rep too shallow — lower your chest more"
                : "Rep too shallow — bend elbows more"
            minElbowAngleInCurrentRep = 180.0
            maxBodyDropInCurrentRep = 0.0
            return
        }

        lastRejectionReason = nil
        lastRepCompletedAt = now
        currentRepCount += 1
        currentState = .top
        minElbowAngleInCurrentRep = 180.0
        maxBodyDropInCurrentRep = 0.0
        formFeedback = "Rep \(currentRepCount) — nice work"
    }

    private func jointConfidence(_ c1: Float, _ c2: Float, _ c3: Float) -> Float {
        (c1 + c2 + c3) / 3.0
    }

    private func combinedElbowAngle(_ input: FrameInput, leftConf: Float, rightConf: Float) -> Double {
        let leftAngle = calculateAngle(p1: input.leftShoulder, p2: input.leftElbow, p3: input.leftWrist)
        let rightAngle = calculateAngle(p1: input.rightShoulder, p2: input.rightElbow, p3: input.rightWrist)

        if leftConf > 0.35 && rightConf > 0.35 {
            let weightLeft = Double(leftConf)
            let weightRight = Double(rightConf)
            let total = weightLeft + weightRight
            return (leftAngle * weightLeft + rightAngle * weightRight) / total
        }
        if leftConf >= rightConf {
            return leftAngle
        }
        return rightAngle
    }

    private func calculateAngle(p1: CGPoint, p2: CGPoint, p3: CGPoint) -> Double {
        let v1 = CGVector(dx: p1.x - p2.x, dy: p1.y - p2.y)
        let v2 = CGVector(dx: p3.x - p2.x, dy: p3.y - p2.y)

        let angleV1 = atan2(v1.dy, v1.dx)
        let angleV2 = atan2(v2.dy, v2.dx)

        var angleInDegrees = abs((angleV1 - angleV2) * 180.0 / .pi)
        if angleInDegrees > 180.0 {
            angleInDegrees = 360.0 - angleInDegrees
        }
        return angleInDegrees
    }
}
