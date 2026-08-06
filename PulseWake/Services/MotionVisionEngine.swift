import Foundation
import AVFoundation
import Vision
import CoreMotion
import SwiftUI
import ImageIO

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
    /// Single shared capture pipeline — avoids crashes when opening verification twice in a row.
    public static let shared = MotionVisionEngine()

    public var isSessionRunning: Bool = false
    public var cameraPermissionGranted: Bool = false
    public var cameraPermissionDenied: Bool = false
    public var setupError: String?
    public var currentSkeleton: PoseSkeleton = PoseSkeleton()

    public var pushUpDetector: PushUpDetector = PushUpDetector()
    public var pullUpDetector: PullUpDetector = PullUpDetector()

    public var activeExercise: ExerciseType = .pushUp
    public var isDevicePitchValid: Bool = true
    public var devicePitchAngle: Double = 0.0

    /// Whether the active capture device is the front camera (for preview mirroring).
    public private(set) var usesFrontCamera: Bool = true
    public private(set) var previewVideoOrientation: AVCaptureVideoOrientation = .portrait

    public let captureSession = AVCaptureSession()
    private let videoOutput = AVCaptureVideoDataOutput()
    private let sessionQueue = DispatchQueue(label: "com.pulsewake.vision.sessionQueue")
    private let videoQueue = DispatchQueue(label: "com.pulsewake.vision.videoQueue")

    private let motionManager = CMMotionManager()
    private var visionImageOrientation: CGImagePropertyOrientation = .right
    /// NOTE: must only be mutated on `sessionQueue` (inside startEngine's `async` block).
    /// Capture callbacks snapshot this via the local in `captureOutput` so they never see a
    /// half-written value even though `captureOutput` runs on `videoQueue`.
    private var processingExercise: ExerciseType = .pushUp
    private var lastPoseDispatchTime: CFAbsoluteTime = 0
    private let minPoseUIInterval: CFAbsoluteTime = 1.0 / 30.0

    /// Re-entrancy guard: set inside `sessionQueue` blocks, prevents two overlapping
    /// `beginConfiguration`/`commitConfiguration` cycles when scene-phase `.active` re-arms
    /// the engine (ExerciseVerificationView.handleScenePhaseChange) or the test-alarm flow
    /// opens verification twice in a row.
    private var isConfiguringSession = false

    /// Optional Vision-failure callback used by ExerciseVerificationView to surface an escape
    /// hatch when detection repeatedly fails. The engine never owns UI directly; consumers
    /// subscribe via this property. Set from the main thread only.
    public var onVisionError: ((Error) -> Void)?

    private override init() {
        super.init()
        setupMotionTracking()
    }

    public func startEngine(exercise: ExerciseType, targetReps: Int) {
        sessionQueue.async { [weak self] in
            guard let self else { return }

            // Re-entrancy guard: if a teardown/configuration is already in flight (e.g. the
            // user backgrounded and re-foregrounded faster than session teardown completes), do
            // not interleave another begin/commit cycle - AVCapture throws "configuration in
            // progress" and that propagates as a crash.
            guard !self.isConfiguringSession else { return }

            self.processingExercise = exercise
            DispatchQueue.main.async {
                self.activeExercise = exercise
                self.setupError = nil
                if exercise == .pushUp {
                    self.pushUpDetector.reset(targetReps: targetReps)
                } else {
                    self.pullUpDetector.reset(targetReps: targetReps)
                }
            }
            self.checkPermissionsAndSetupCameraOnSessionQueue()
            DispatchQueue.main.async {
                self.startMotionUpdates()
            }
        }
    }

    public func stopEngine() {
        stopMotionUpdates()
        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.videoOutput.setSampleBufferDelegate(nil, queue: nil)
            self.tearDownCaptureSession()
            DispatchQueue.main.async {
                self.isSessionRunning = false
            }
        }
    }

    private func checkPermissionsAndSetupCameraOnSessionQueue() {
        #if DEBUG
        dispatchPrecondition(condition: .onQueue(sessionQueue))
        #endif
        let status = AVCaptureDevice.authorizationStatus(for: .video)
        switch status {
        case .authorized:
            DispatchQueue.main.async {
                self.cameraPermissionDenied = false
                self.cameraPermissionGranted = true
            }
            self.setupCaptureSession()
        case .notDetermined:
            DispatchQueue.main.async {
                self.cameraPermissionDenied = false
            }
            AVCaptureDevice.requestAccess(for: .video) { granted in
                DispatchQueue.main.async {
                    self.cameraPermissionGranted = granted
                    self.cameraPermissionDenied = !granted
                }
                if granted {
                    self.sessionQueue.async {
                        self.setupCaptureSession()
                    }
                }
            }
        default:
            DispatchQueue.main.async {
                self.cameraPermissionGranted = false
                self.cameraPermissionDenied = true
            }
        }
    }

    private func checkPermissionsAndSetupCamera() {
        sessionQueue.async { [weak self] in
            self?.checkPermissionsAndSetupCameraOnSessionQueue()
        }
    }

    private func tearDownCaptureSession() {
        #if DEBUG
        dispatchPrecondition(condition: .onQueue(sessionQueue))
        #endif
        // Mark config in progress so a concurrent startEngine re-arm cannot interleave its own
        // beginConfiguration on top of this teardown.
        isConfiguringSession = true
        defer { isConfiguringSession = false }

        if captureSession.isRunning {
            captureSession.stopRunning()
        }
        videoOutput.setSampleBufferDelegate(nil, queue: nil)
        captureSession.beginConfiguration()
        for input in captureSession.inputs {
            captureSession.removeInput(input)
        }
        for output in captureSession.outputs {
            captureSession.removeOutput(output)
        }
        captureSession.commitConfiguration()
    }

    private func setupCaptureSession() {
        // Caller (checkPermissionsAndSetupCameraOnSessionQueue) already runs on sessionQueue.
        // We must NOT nest another sessionQueue.async here: doing so reorders teardown/setup
        // across two startEngine invocations and triggers the "configuration already in
        // progress" crash that this whole file is hardening against.
        #if DEBUG
        dispatchPrecondition(condition: .onQueue(sessionQueue))
        #endif

        self.tearDownCaptureSession()
        self.captureSession.beginConfiguration()
        self.captureSession.sessionPreset = .high

        let position: AVCaptureDevice.Position = self.activeExercise == .pushUp ? .front : .back

        guard let cameraDevice = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: position) ??
                AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: position == .front ? .back : .front) else {
            self.captureSession.commitConfiguration()
            DispatchQueue.main.async {
                self.setupError = "No camera available on this device."
            }
            return
        }

        do {
            let input = try AVCaptureDeviceInput(device: cameraDevice)
            guard self.captureSession.canAddInput(input) else {
                self.captureSession.commitConfiguration()
                DispatchQueue.main.async {
                    self.setupError = "Could not add camera input to capture session."
                }
                return
            }
            self.captureSession.addInput(input)
        } catch {
            self.captureSession.commitConfiguration()
            DispatchQueue.main.async {
                self.setupError = "Camera setup failed: \(error.localizedDescription)"
            }
            return
        }

        self.videoOutput.setSampleBufferDelegate(self, queue: self.videoQueue)
        self.videoOutput.alwaysDiscardsLateVideoFrames = true

        guard self.captureSession.canAddOutput(self.videoOutput) else {
            self.captureSession.commitConfiguration()
            DispatchQueue.main.async {
                self.setupError = "Could not add video output to capture session."
            }
            return
        }
        self.captureSession.addOutput(self.videoOutput)

        let isFront = cameraDevice.position == .front
        let orientation = Self.visionOrientation(for: cameraDevice.position)
        self.visionImageOrientation = orientation
        if let connection = self.videoOutput.connection(with: .video) {
            if connection.isVideoOrientationSupported {
                connection.videoOrientation = .portrait
            }
            if connection.isVideoMirroringSupported {
                connection.isVideoMirrored = isFront
            }
        }

        self.captureSession.commitConfiguration()
        self.captureSession.startRunning()

        DispatchQueue.main.async {
            self.usesFrontCamera = isFront
            self.previewVideoOrientation = .portrait
            self.visionImageOrientation = orientation
            self.isSessionRunning = self.captureSession.isRunning
            if !self.captureSession.isRunning {
                self.setupError = "Camera session failed to start."
            }
        }
    }

    private static func visionOrientation(for position: AVCaptureDevice.Position) -> CGImagePropertyOrientation {
        switch position {
        case .front:
            return .leftMirrored
        case .back:
            return .right
        default:
            return .right
        }
    }

    // MARK: - AVCaptureVideoDataOutputSampleBufferDelegate
    public func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        let now = CFAbsoluteTimeGetCurrent()
        guard now - lastPoseDispatchTime >= minPoseUIInterval else { return }
        lastPoseDispatchTime = now

        let orientation = visionImageOrientation
        let exercise = processingExercise
        // A fresh request per frame. This used to be one long-lived `VNDetectHumanBodyPoseRequest`
        // stored on the engine: `perform` ran here on `videoQueue` while the main thread was
        // still reading the observation from the *previous* frame off that same request object.
        // Vision recycles a request's results on each `perform`, so the two raced. Giving each
        // frame its own request means the observation handed to the main thread is owned solely
        // by that dispatch. Vision caches the underlying model, so this is cheap.
        let request = VNDetectHumanBodyPoseRequest()
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: orientation, options: [:])
        do {
            try handler.perform([request])
            guard let observation = request.results?.first else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.extractSkeleton(from: observation)
                if exercise == .pushUp {
                    self.pushUpDetector.processPoseObservation(observation)
                } else {
                    self.pullUpDetector.processPoseObservation(observation)
                }
            }
        } catch {
            // Route to the optional consumer callback (used by ExerciseVerificationView to
            // surface a "silence alarm" escape hatch after repeated failures). The print stays
            // for debuggability.
            print("Vision error: \(error)")
            let cb = self.onVisionError
            DispatchQueue.main.async {
                cb?(error)
            }
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

            if self.activeExercise == .pushUp {
                self.isDevicePitchValid = abs(pitchDegrees) < 65.0
            } else {
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
