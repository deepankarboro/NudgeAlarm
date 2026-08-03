import Foundation
import CoreGraphics
import Vision

public enum PullUpState {
    case hanging
    case pullingUp
    case chinAboveBar
    case lowering
}

@Observable
public final class PullUpDetector {
    public var currentRepCount: Int = 0
    public var currentState: PullUpState = .hanging
    public var formFeedback: String = "Stand/hang facing camera with pull-up bar visible"
    public var isFormValid: Bool = false
    public var verticalDisplacementRatio: Double = 0.0

    private var targetReps: Int = 10
    private var lastRepCompletedAt: Date = .distantPast
    private let minSecondsBetweenReps: TimeInterval = 0.4

    /// Endpoint G: per-cycle guard that prevents a single pull-up rep from being counted
    /// twice in the same physical cycle. The `chinAboveBar` branch and the `lowering`
    /// branch could each call `registerCompletedRep` while the user is paused at the top;
    /// the 0.4s cooldown was the only safeguard and could be bypassed by a deliberate
    /// 0.5s pause. This flag is set true the first time a rep registers, and cleared only
    /// when the user returns to a fresh `.hanging` (dead-hang) state — i.e. the start of
    /// the NEXT rep cycle.
    private var repCountedThisCycle: Bool = false

    public init(targetReps: Int = 10) {
        self.targetReps = targetReps
    }

    public func reset(targetReps: Int) {
        self.targetReps = targetReps
        self.currentRepCount = 0
        self.currentState = .hanging
        self.formFeedback = "Stand/hang facing camera"
        self.isFormValid = false
        self.verticalDisplacementRatio = 0.0
        self.lastRepCompletedAt = .distantPast
        self.repCountedThisCycle = false
    }
    
    public func processPoseObservation(_ observation: VNHumanBodyPoseObservation) {
        do {
            let nose = try observation.recognizedPoint(.nose)
            let neck = try observation.recognizedPoint(.neck)
            let leftWrist = try observation.recognizedPoint(.leftWrist)
            let rightWrist = try observation.recognizedPoint(.rightWrist)
            let leftShoulder = try observation.recognizedPoint(.leftShoulder)
            let rightShoulder = try observation.recognizedPoint(.rightShoulder)
            let leftElbow = try observation.recognizedPoint(.leftElbow)
            let rightElbow = try observation.recognizedPoint(.rightElbow)
            
            let wristConf = (leftWrist.confidence + rightWrist.confidence) / 2.0
            let shoulderConf = (leftShoulder.confidence + rightShoulder.confidence) / 2.0
            
            guard wristConf > 0.35 && shoulderConf > 0.35 else {
                isFormValid = false
                formFeedback = "Ensure pull-up bar, arms, and head are in camera view"
                return
            }
            
            isFormValid = true
            
            // In Vision normalized coordinates: (0,0) is bottom-left, (1,1) is top-right.
            // High Y means higher in camera view.
            let avgWristY = (leftWrist.location.y + rightWrist.location.y) / 2.0
            let avgShoulderY = (leftShoulder.location.y + rightShoulder.location.y) / 2.0
            let chinY = nose.confidence > 0.3 ? nose.location.y : neck.location.y
            
            // Calculate elbow angles
            let leftAngle = calculateAngle(p1: leftShoulder.location, p2: leftElbow.location, p3: leftWrist.location)
            let rightAngle = calculateAngle(p1: rightShoulder.location, p2: rightElbow.location, p3: rightWrist.location)
            let avgElbowAngle = (leftAngle + rightAngle) / 2.0
            
            // Chin height relative to wrists (positive when chin is near or above bar height)
            let relativeChinToBarHeight = chinY - avgWristY
            self.verticalDisplacementRatio = relativeChinToBarHeight
            
            updateStateMachine(chinToWrist: relativeChinToBarHeight, elbowAngle: avgElbowAngle, shoulderY: avgShoulderY, wristY: avgWristY)
            
        } catch {
            isFormValid = false
            formFeedback = "Position camera to view upper body and hands on bar"
        }
    }

    /// Test seam: same per-frame math as `processPoseObservation` but accepts plain CGPoint and
    /// Float inputs (no Vision dependency). Lets unit tests drive the state machine
    /// deterministically on the simulator. Vision normalized coords: (0,0) bottom-left,
    /// (1,1) top-right. Confidence in 0...1.
    public struct FrameInput {
        public var nose: CGPoint
        public var noseConf: Float
        public var neck: CGPoint
        public var neckConf: Float
        public var leftWrist: CGPoint
        public var leftWristConf: Float
        public var rightWrist: CGPoint
        public var rightWristConf: Float
        public var leftShoulder: CGPoint
        public var leftShoulderConf: Float
        public var rightShoulder: CGPoint
        public var rightShoulderConf: Float
        public var leftElbow: CGPoint
        public var rightElbow: CGPoint

        public init(
            nose: CGPoint, noseConf: Float,
            neck: CGPoint, neckConf: Float,
            leftWrist: CGPoint, leftWristConf: Float,
            rightWrist: CGPoint, rightWristConf: Float,
            leftShoulder: CGPoint, leftShoulderConf: Float,
            rightShoulder: CGPoint, rightShoulderConf: Float,
            leftElbow: CGPoint, rightElbow: CGPoint
        ) {
            self.nose = nose; self.noseConf = noseConf
            self.neck = neck; self.neckConf = neckConf
            self.leftWrist = leftWrist; self.leftWristConf = leftWristConf
            self.rightWrist = rightWrist; self.rightWristConf = rightWristConf
            self.leftShoulder = leftShoulder; self.leftShoulderConf = leftShoulderConf
            self.rightShoulder = rightShoulder; self.rightShoulderConf = rightShoulderConf
            self.leftElbow = leftElbow; self.rightElbow = rightElbow
        }
    }

    public func processFrame(_ input: FrameInput) {
        let wristConf = (input.leftWristConf + input.rightWristConf) / 2.0
        let shoulderConf = (input.leftShoulderConf + input.rightShoulderConf) / 2.0

        guard wristConf > 0.35 && shoulderConf > 0.35 else {
            isFormValid = false
            formFeedback = "Ensure pull-up bar, arms, and head are in camera view"
            return
        }

        isFormValid = true

        let avgWristY = (input.leftWrist.y + input.rightWrist.y) / 2.0
        let avgShoulderY = (input.leftShoulder.y + input.rightShoulder.y) / 2.0
        let chinY = input.noseConf > 0.3 ? input.nose.y : input.neck.y

        let leftAngle = calculateAngle(p1: input.leftShoulder, p2: input.leftElbow, p3: input.leftWrist)
        let rightAngle = calculateAngle(p1: input.rightShoulder, p2: input.rightElbow, p3: input.rightWrist)
        let avgElbowAngle = (leftAngle + rightAngle) / 2.0

        let relativeChinToBarHeight = chinY - avgWristY
        self.verticalDisplacementRatio = relativeChinToBarHeight

        updateStateMachine(chinToWrist: relativeChinToBarHeight, elbowAngle: avgElbowAngle, shoulderY: avgShoulderY, wristY: avgWristY)
    }
    
    private func updateStateMachine(chinToWrist: Double, elbowAngle: Double, shoulderY: Double, wristY: Double) {
        switch currentState {
        case .hanging:
            // Starting a new rep cycle: clear the per-cycle double-count guard.
            if repCountedThisCycle {
                repCountedThisCycle = false
            }
            if elbowAngle < 135.0 || shoulderY > (wristY - 0.25) {
                currentState = .pullingUp
                formFeedback = "Pulling up..."
            } else {
                formFeedback = "Dead hang position. Pull up!"
            }

        case .pullingUp:
            if chinToWrist >= -0.08 || elbowAngle < 75.0 {
                currentState = .chinAboveBar
                formFeedback = "Chin over bar! Hold..."
            } else {
                formFeedback = "Pull higher! Get chin past wrists"
            }

        case .chinAboveBar:
            // Only register a rep here if no rep has been counted in this cycle yet.
            if !repCountedThisCycle, chinToWrist >= -0.10, elbowAngle < 90.0 {
                registerCompletedRep()
            } else if chinToWrist < -0.14 && elbowAngle > 95.0 {
                currentState = .lowering
                formFeedback = "Lowering down..."
            } else {
                formFeedback = "Chin above bar!"
            }

        case .lowering:
            // Only register a rep here if no rep has been counted in this cycle yet.
            // This catches reps that finish via the lowering-to-dead-hang path rather than
            // the chin-above-bar path; the per-cycle flag prevents the same rep from
            // firing both branches.
            if !repCountedThisCycle, elbowAngle >= 135.0 {
                registerCompletedRep()
            } else {
                formFeedback = "Lower fully into dead hang"
            }
        }
    }

    private func registerCompletedRep() {
        let now = Date()
        guard now.timeIntervalSince(lastRepCompletedAt) >= minSecondsBetweenReps else { return }
        lastRepCompletedAt = now
        currentRepCount += 1
        repCountedThisCycle = true
        currentState = .hanging
        formFeedback = "Pull-Up Rep \(currentRepCount) counted! Excellent!"
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
