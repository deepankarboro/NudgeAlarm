import Foundation
import AVFoundation
import Vision
import CoreMotion
import SwiftUI

public struct KeypointNode: Identifiable {
    public let id = UUID()
    public let point: CGPoint
    public let confidence: Float
    public let name: VNHumanBodyPoseObservation.JointName
}

public struct PoseSkeleton {
    public var points: [VNHumanBodyPoseObservation.JointName: CGPoint] = [:]
    public var confidences: [VNHumanBodyPoseObservation.JointName: Float] = [:]
}

@Observable
public final class MotionVisionEngine: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    public var isSessionRunning: Bool = false
    public var cameraPermissionGranted: Bool = false
    public var currentSkeleton: PoseSkeleton = PoseSkeleton()
    
    public var pushUpDetector: PushUpDetector = PushUpDetector()
    public var pullUpDetector: PullUpDetector = PullUpDetector()
    
    public var activeExercise: ExerciseType = .pushUp
    public var isDevicePitchValid: Bool = true
    public var devicePitchAngle: Double = 0.0
    
    public let captureSession = AVCaptureSession()
    private let videoOutput = AVCaptureVideoDataOutput()
    private let sessionQueue = DispatchQueue(label: "com.nudgealarm.vision.sessionQueue")
    
    private let motionManager = CMMotionManager()
    private var bodyPoseRequest = VNDetectHumanBodyPoseRequest()
    
    public override init() {
        super.init()
        setupMotionTracking()
    }
    
    public func startEngine(exercise: ExerciseType, targetReps: Int) {
        self.activeExercise = exercise
        if exercise == .pushUp {
            pushUpDetector.reset(targetReps: targetReps)
        } else {
            pullUpDetector.reset(targetReps: targetReps)
        }
        
        checkPermissionsAndSetupCamera()
        startMotionUpdates()
    }
    
    public func stopEngine() {
        sessionQueue.async { [weak self] in
            guard let self = self else { return }
            if self.captureSession.isRunning {
                self.captureSession.stopRunning()
            }
            DispatchQueue.main.async {
                self.isSessionRunning = false
            }
        }
        stopMotionUpdates()
    }
    
    private func checkPermissionsAndSetupCamera() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            self.cameraPermissionGranted = true
            self.setupCaptureSession()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { granted in
                DispatchQueue.main.async {
                    self.cameraPermissionGranted = granted
                    if granted {
                        self.setupCaptureSession()
                    }
                }
            }
        default:
            self.cameraPermissionGranted = false
        }
    }
    
    private func setupCaptureSession() {
        sessionQueue.async { [weak self] in
            guard let self = self else { return }
            self.captureSession.beginConfiguration()
            self.captureSession.sessionPreset = .high
            
            // Prefer front camera for pushups/pullups, fallback to wide angle back camera
            guard let cameraDevice = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front) ??
                    AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
                  let input = try? AVCaptureDeviceInput(device: cameraDevice) else {
                self.captureSession.commitConfiguration()
                return
            }
            
            if self.captureSession.canAddInput(input) {
                self.captureSession.addInput(input)
            }
            
            self.videoOutput.setSampleBufferDelegate(self, queue: DispatchQueue(label: "com.nudgealarm.vision.videoQueue"))
            self.videoOutput.alwaysDiscardsLateVideoFrames = true
            
            if self.captureSession.canAddOutput(self.videoOutput) {
                self.captureSession.addOutput(self.videoOutput)
            }
            
            self.captureSession.commitConfiguration()
            self.captureSession.startRunning()
            
            DispatchQueue.main.async {
                self.isSessionRunning = self.captureSession.isRunning
            }
        }
    }
    
    // MARK: - AVCaptureVideoDataOutputSampleBufferDelegate
    public func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .up, options: [:])
        do {
            try handler.perform([bodyPoseRequest])
            if let observation = bodyPoseRequest.results?.first {
                DispatchQueue.main.async {
                    self.extractSkeleton(from: observation)
                    if self.activeExercise == .pushUp {
                        self.pushUpDetector.processPoseObservation(observation)
                    } else {
                        self.pullUpDetector.processPoseObservation(observation)
                    }
                }
            }
        } catch {
            print("Vision error: \(error)")
        }
    }
    
    private func extractSkeleton(from observation: VNHumanBodyPoseObservation) {
        var skeleton = PoseSkeleton()
        let joints: [VNHumanBodyPoseObservation.JointName] = [
            .nose, .neck, .leftShoulder, .rightShoulder,
            .leftElbow, .rightElbow, .leftWrist, .rightWrist,
            .leftHip, .rightHip, .leftKnee, .rightKnee, .leftAnkle, .rightAnkle
        ]
        
        for joint in joints {
            if let point = try? observation.recognizedPoint(joint), point.confidence > 0.2 {
                skeleton.points[joint] = point.location
                skeleton.confidences[joint] = point.confidence
            }
        }
        self.currentSkeleton = skeleton
    }
    
    // MARK: - CoreMotion Management
    private func setupMotionTracking() {
        motionManager.deviceMotionUpdateInterval = 0.2
    }
    
    private func startMotionUpdates() {
        guard motionManager.isDeviceMotionAvailable else { return }
        motionManager.startDeviceMotionUpdates(to: .main) { [weak self] motion, _ in
            guard let self = self, let attitude = motion?.attitude else { return }
            let pitchDegrees = attitude.pitch * 180.0 / .pi
            self.devicePitchAngle = pitchDegrees
            
            // Validate pitch relative to exercise type
            if self.activeExercise == .pushUp {
                // Phone flat on floor or propped low (-30° to 45°)
                self.isDevicePitchValid = abs(pitchDegrees) < 65.0
            } else {
                // Phone upright (45° to 90°)
                self.isDevicePitchValid = abs(pitchDegrees) > 25.0
            }
        }
    }
    
    private func stopMotionUpdates() {
        if motionManager.isDeviceMotionActive {
            motionManager.stopDeviceMotionUpdates()
        }
    }
}
