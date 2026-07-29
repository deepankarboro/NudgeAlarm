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

    private var targetReps: Int = 10
    private var lastRepCompletedAt: Date = .distantPast
    private let minSecondsBetweenReps: TimeInterval = 0.45

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

            let leftArmConf = jointConfidence(leftShoulder, leftElbow, leftWrist)
            let rightArmConf = jointConfidence(rightShoulder, rightElbow, rightWrist)
            let shoulderConf = (leftShoulder.confidence + rightShoulder.confidence) / 2.0
            let headConf = max(nose.confidence, neck.confidence)

            guard leftArmConf > 0.2 || rightArmConf > 0.2 || shoulderConf > 0.25 || headConf > 0.3 else {
                isFormValid = false
                formFeedback = "Keep your face, shoulders, and arms in view"
                return
            }

            isFormValid = true
            updatePlacement(
                leftShoulder: leftShoulder, rightShoulder: rightShoulder,
                leftWrist: leftWrist, rightWrist: rightWrist
            )

            let rawAngle = combinedElbowAngle(
                leftShoulder: leftShoulder, leftElbow: leftElbow, leftWrist: leftWrist, leftConf: leftArmConf,
                rightShoulder: rightShoulder, rightElbow: rightElbow, rightWrist: rightWrist, rightConf: rightArmConf
            )
            smoothedElbowAngle = smoothedElbowAngle * (1.0 - angleSmoothingAlpha) + rawAngle * angleSmoothingAlpha
            currentElbowAngle = smoothedElbowAngle

            let rawBodyY = compositeUpperBodyY(
                nose: nose, neck: neck,
                leftShoulder: leftShoulder, rightShoulder: rightShoulder
            )
            if let rawBodyY {
                smoothedBodyY = smoothedBodyY * (1.0 - bodySmoothingAlpha) + rawBodyY * bodySmoothingAlpha
            }

            updateTopBaseline(bodyY: smoothedBodyY, elbowAngle: smoothedElbowAngle)
            let bodyDrop = bodyDropFromTop(bodyY: smoothedBodyY)
            maxBodyDropInCurrentRep = max(maxBodyDropInCurrentRep, bodyDrop)
            bodyDropRatio = min(1.0, bodyDrop / frontMinBodyDropForRep)

            updateStateMachine(elbowAngle: smoothedElbowAngle, bodyDrop: bodyDrop)

        } catch {
            isFormValid = false
            formFeedback = "Angle the phone so your upper body is visible"
        }
    }

    private func updatePlacement(
        leftShoulder: VNRecognizedPoint, rightShoulder: VNRecognizedPoint,
        leftWrist: VNRecognizedPoint, rightWrist: VNRecognizedPoint
    ) {
        let shoulderSpan = Double(abs(leftShoulder.location.x - rightShoulder.location.x))
        let wristSpan = Double(abs(leftWrist.location.x - rightWrist.location.x))
        let shoulderVisible = leftShoulder.confidence > 0.25 && rightShoulder.confidence > 0.25

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

    private func compositeUpperBodyY(
        nose: VNRecognizedPoint, neck: VNRecognizedPoint,
        leftShoulder: VNRecognizedPoint, rightShoulder: VNRecognizedPoint
    ) -> Double? {
        var sum = 0.0
        var weight = 0.0

        if nose.confidence > 0.25 {
            sum += Double(nose.location.y) * 0.45
            weight += 0.45
        }
        if neck.confidence > 0.25 {
            sum += Double(neck.location.y) * 0.25
            weight += 0.25
        }
        let shoulderConf = (leftShoulder.confidence + rightShoulder.confidence) / 2.0
        if shoulderConf > 0.25 {
            let shoulderY = Double((leftShoulder.location.y + rightShoulder.location.y) / 2.0)
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

    private func reachedBottom(elbowAngle: Double, bodyDrop: Double) -> Bool {
        switch placement {
        case .inFrontOfFace:
            return bodyDrop >= frontBottomEnterDrop
                || elbowAngle <= sideBottomEnterAngle + 5.0
        case .sideProfile:
            return elbowAngle <= sideBottomEnterAngle
                || bodyDrop >= frontMinBodyDropForRep * 0.85
        }
    }

    private func reachedTop(elbowAngle: Double, bodyDrop: Double) -> Bool {
        switch placement {
        case .inFrontOfFace:
            return bodyDrop <= frontTopReturnDrop
                || elbowAngle >= sideTopLockoutAngle - 5.0
        case .sideProfile:
            return elbowAngle >= sideTopLockoutAngle
                || bodyDrop <= frontTopReturnDrop
        }
    }

    private func leavingBottom(elbowAngle: Double, bodyDrop: Double) -> Bool {
        switch placement {
        case .inFrontOfFace:
            return bodyDrop <= frontBottomEnterDrop * 0.65
                || elbowAngle > sideBottomHoldAngle
        case .sideProfile:
            return elbowAngle > sideBottomHoldAngle && bodyDrop < frontMinBodyDropForRep * 0.45
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
            } else if bodyDrop > frontBottomEnterDrop * 0.4 || elbowAngle < sideTopLockoutAngle - 15.0 {
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
        guard now.timeIntervalSince(lastRepCompletedAt) >= minSecondsBetweenReps else {
            return
        }

        let angleDepthOK = minElbowAngleInCurrentRep <= sideMinDepthAngleForRep
        let bodyDepthOK = maxBodyDropInCurrentRep >= frontMinBodyDropForRep

        let depthOK: Bool
        switch placement {
        case .inFrontOfFace:
            depthOK = bodyDepthOK || angleDepthOK
        case .sideProfile:
            depthOK = angleDepthOK || bodyDepthOK
        }

        guard depthOK else {
            currentState = .top
            formFeedback = placement == .inFrontOfFace
                ? "Rep too shallow — lower your chest more"
                : "Rep too shallow — bend elbows more"
            minElbowAngleInCurrentRep = 180.0
            maxBodyDropInCurrentRep = 0.0
            return
        }

        lastRepCompletedAt = now
        currentRepCount += 1
        currentState = .top
        minElbowAngleInCurrentRep = 180.0
        maxBodyDropInCurrentRep = 0.0
        formFeedback = "Rep \(currentRepCount) — nice work"
    }

    private func jointConfidence(_ p1: VNRecognizedPoint, _ p2: VNRecognizedPoint, _ p3: VNRecognizedPoint) -> Float {
        (p1.confidence + p2.confidence + p3.confidence) / 3.0
    }

    private func combinedElbowAngle(
        leftShoulder: VNRecognizedPoint, leftElbow: VNRecognizedPoint, leftWrist: VNRecognizedPoint, leftConf: Float,
        rightShoulder: VNRecognizedPoint, rightElbow: VNRecognizedPoint, rightWrist: VNRecognizedPoint, rightConf: Float
    ) -> Double {
        let leftAngle = calculateAngle(p1: leftShoulder.location, p2: leftElbow.location, p3: leftWrist.location)
        let rightAngle = calculateAngle(p1: rightShoulder.location, p2: rightElbow.location, p3: rightWrist.location)

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
