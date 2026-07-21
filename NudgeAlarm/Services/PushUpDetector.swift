import Foundation
import CoreGraphics
import Vision

public enum PushUpState {
    case top
    case goingDown
    case bottom
    case pushingUp
}

@Observable
public final class PushUpDetector {
    public var currentRepCount: Int = 0
    public var currentState: PushUpState = .top
    public var formFeedback: String = "Get into push-up position facing camera"
    public var currentElbowAngle: Double = 180.0
    public var isFormValid: Bool = false
    
    private var minElbowAngleInCurrentRep: Double = 180.0
    private var targetReps: Int = 10
    
    public init(targetReps: Int = 10) {
        self.targetReps = targetReps
    }
    
    public func reset(targetReps: Int) {
        self.targetReps = targetReps
        self.currentRepCount = 0
        self.currentState = .top
        self.formFeedback = "Get into position facing camera"
        self.currentElbowAngle = 180.0
        self.isFormValid = false
    }
    
    /// Processes human body pose observations from Vision framework
    public func processPoseObservation(_ observation: VNHumanBodyPoseObservation) {
        do {
            let leftShoulder = try observation.recognizedPoint(.leftShoulder)
            let leftElbow = try observation.recognizedPoint(.leftElbow)
            let leftWrist = try observation.recognizedPoint(.leftWrist)
            
            let rightShoulder = try observation.recognizedPoint(.rightShoulder)
            let rightElbow = try observation.recognizedPoint(.rightElbow)
            let rightWrist = try observation.recognizedPoint(.rightWrist)
            
            // Pick arm with highest confidence score
            let leftConf = leftShoulder.confidence * leftElbow.confidence * leftWrist.confidence
            let rightConf = rightShoulder.confidence * rightElbow.confidence * rightWrist.confidence
            
            guard leftConf > 0.3 || rightConf > 0.3 else {
                isFormValid = false
                formFeedback = "Ensure upper body & arms are visible in camera feed"
                return
            }
            
            isFormValid = true
            
            let angle: Double
            if leftConf >= rightConf {
                angle = calculateAngle(p1: leftShoulder.location, p2: leftElbow.location, p3: leftWrist.location)
            } else {
                angle = calculateAngle(p1: rightShoulder.location, p2: rightElbow.location, p3: rightWrist.location)
            }
            
            self.currentElbowAngle = angle
            updateStateMachine(elbowAngle: angle)
            
        } catch {
            isFormValid = false
            formFeedback = "Position camera to view your torso and arms"
        }
    }
    
    private func updateStateMachine(elbowAngle: Double) {
        switch currentState {
        case .top:
            if elbowAngle < 145.0 {
                currentState = .goingDown
                minElbowAngleInCurrentRep = elbowAngle
                formFeedback = "Lower your chest..."
            } else {
                formFeedback = "Bend arms to start push-up rep"
            }
            
        case .goingDown:
            minElbowAngleInCurrentRep = min(minElbowAngleInCurrentRep, elbowAngle)
            if elbowAngle <= 95.0 {
                currentState = .bottom
                formFeedback = "Great depth! Now push back up!"
            } else {
                formFeedback = "Lower chest further down (< 90°)"
            }
            
        case .bottom:
            if elbowAngle > 110.0 {
                currentState = .pushingUp
                formFeedback = "Pushing up..."
            } else {
                formFeedback = "Hold... Now extend your arms!"
            }
            
        case .pushingUp:
            if elbowAngle >= 155.0 {
                // Completed 1 full rep!
                currentRepCount += 1
                currentState = .top
                formFeedback = "Rep \(currentRepCount) completed! Good form!"
            } else {
                formFeedback = "Lock out arms at top"
            }
        }
    }
    
    /// Calculates angle at vertex p2 (elbow) formed by p1 (shoulder) and p3 (wrist)
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
