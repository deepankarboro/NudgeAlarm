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
    
    private func updateStateMachine(chinToWrist: Double, elbowAngle: Double, shoulderY: Double, wristY: Double) {
        switch currentState {
        case .hanging:
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
            if chinToWrist < -0.12 && elbowAngle > 100.0 {
                currentState = .lowering
                formFeedback = "Lowering down..."
            } else {
                formFeedback = "Chin above bar!"
            }
            
        case .lowering:
            if elbowAngle >= 140.0 {
                currentRepCount += 1
                currentState = .hanging
                formFeedback = "Pull-Up Rep \(currentRepCount) counted! Excellent!"
            } else {
                formFeedback = "Lower fully into dead hang"
            }
        }
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
