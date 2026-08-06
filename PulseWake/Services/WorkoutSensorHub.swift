import Foundation
import CoreMotion
import AVFoundation
import SwiftUI

/// Activity, steps, device motion, and microphone exertion — including while alarm audio runs in background.
@Observable
public final class WorkoutSensorHub {
    public static let shared = WorkoutSensorHub()

    public private(set) var isWakeSessionActive = false
    public private(set) var isExerciseSessionActive = false

    public var sessionSteps: Int = 0
    public var activitySummary: String = "Waiting for motion…"
    public var isPhysicallyActive: Bool = false
    public var exertionLevel: Float = 0
    public var microphoneAuthorized: Bool = false

    private let activityManager = CMMotionActivityManager()
    private let pedometer = CMPedometer()
    private var sessionStartDate: Date?
    private var audioEngine: AVAudioEngine?
    private var exertionTimer: Timer?
    /// Tracks whether a tap is currently installed on `audioEngine?.inputNode`. Must only be
    /// mutated on the main thread. Prevents `removeTap` from being called on an engine whose
    /// tap was never installed (which throws EXC_BAD_ACCESS on iOS) and prevents double
    /// `installTap` (which throws "tap already installed").
    private var hasInstalledTap = false

    private init() {}

    // MARK: - Permissions

    /// Asks for HealthKit, then the microphone — one after the other. Firing both at once
    /// stacks their system dialogs on top of each other.
    public func requestPermissions(completion: @escaping () -> Void = {}) {
        HealthKitManager.shared.requestAuthorization { _ in
            self.requestMicrophoneAccess { _ in
                completion()
            }
        }
    }

    private func requestMicrophoneAccess(completion: @escaping (Bool) -> Void = { _ in }) {
        AVAudioApplication.requestRecordPermission { [weak self] granted in
            DispatchQueue.main.async {
                self?.microphoneAuthorized = granted
                completion(granted)
            }
        }
    }

    // MARK: - Alarm / background wake session

    /// Starts when alarm rings (audio background mode keeps the process eligible for motion updates).
    public func startWakeSession() {
        guard !isWakeSessionActive else { return }
        isWakeSessionActive = true
        sessionStartDate = Date()
        sessionSteps = 0
        activitySummary = "Monitoring wake activity…"
        startActivityUpdates()
        startPedometerUpdates()
    }

    public func stopWakeSession() {
        isWakeSessionActive = false
        stopExerciseSession()
        stopActivityUpdates()
        stopPedometerUpdates()
        sessionStartDate = nil
    }

    // MARK: - Exercise verification (camera screen)

    public func startExerciseSession() {
        if !isWakeSessionActive {
            startWakeSession()
        }
        isExerciseSessionActive = true
        startMicrophoneExertionMonitor()
    }

    public func stopExerciseSession() {
        isExerciseSessionActive = false
        stopMicrophoneExertionMonitor()
    }

    public func finishWorkout(
        exerciseType: ExerciseType,
        reps: Int,
        durationSeconds: TimeInterval,
        startDate: Date
    ) {
        HealthKitManager.shared.saveCompletedWorkout(
            exerciseType: exerciseType,
            reps: reps,
            durationSeconds: durationSeconds,
            sessionSteps: sessionSteps,
            startDate: startDate
        )
        HealthKitManager.shared.refreshTodayStepCount()
    }

    // MARK: - CMMotionActivity

    private func startActivityUpdates() {
        guard CMMotionActivityManager.isActivityAvailable() else {
            activitySummary = "Activity sensors unavailable"
            return
        }
        activityManager.startActivityUpdates(to: .main) { [weak self] activity in
            guard let self, let activity else { return }
            self.isPhysicallyActive = activity.walking || activity.running || activity.cycling
                || (activity.confidence == .high && !activity.stationary)
            self.activitySummary = self.describe(activity)
        }
    }

    private func stopActivityUpdates() {
        activityManager.stopActivityUpdates()
    }

    private func describe(_ activity: CMMotionActivity) -> String {
        if activity.running { return "Running" }
        if activity.walking { return "Walking" }
        if activity.cycling { return "Cycling" }
        if activity.automotive { return "In vehicle" }
        if activity.stationary { return "Stationary" }
        return "Moving"
    }

    // MARK: - Pedometer (Fitness / steps)

    private func startPedometerUpdates() {
        guard CMPedometer.isStepCountingAvailable(), let start = sessionStartDate else { return }
        pedometer.startUpdates(from: start) { [weak self] data, error in
            guard let self, error == nil, let data else { return }
            DispatchQueue.main.async {
                self.sessionSteps = data.numberOfSteps.intValue
            }
        }
    }

    private func stopPedometerUpdates() {
        pedometer.stopUpdates()
    }

    // MARK: - Microphone exertion (movement / breath proxy during reps)

    private func startMicrophoneExertionMonitor() {
        guard microphoneAuthorized else {
            requestMicrophoneAccess()
            return
        }
        stopMicrophoneExertionMonitor()

        let engine = AVAudioEngine()
        let input = engine.inputNode
        let format = input.inputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { return }

        // Capture a weak ref so the tap callback never dereferences a hub we've torn down.
        // The `audioEngine === engine && .isRunning` check defends against buffers arriving
        // after stop() was called.
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            guard let self else { return }
            guard let activeEngine = self.audioEngine, activeEngine === engine, activeEngine.isRunning else { return }
            guard let channelData = buffer.floatChannelData?[0] else { return }
            let frameCount = Int(buffer.frameLength)
            var sum: Float = 0
            for i in 0..<frameCount {
                let sample = channelData[i]
                sum += sample * sample
            }
            let rms = sqrt(sum / Float(max(frameCount, 1)))
            let normalized = min(max(rms * 12, 0), 1)
            DispatchQueue.main.async {
                self.exertionLevel = normalized
            }
        }

        do {
            try engine.start()
            audioEngine = engine
            hasInstalledTap = true
        } catch {
            // Engine did not start: roll back the tap installation so stopMicrophoneExertionMonitor
            // does not call removeTap on an engine that was never run (which would crash).
            // The guard `engine.isRunning` is belt-and-suspenders.
            if engine.isRunning {
                input.removeTap(onBus: 0)
            }
            hasInstalledTap = false
            audioEngine = nil
            print("Microphone exertion monitor failed: \(error)")
        }
    }

    private func stopMicrophoneExertionMonitor() {
        // Capture synchronously; never reach into a nil audioEngine.
        guard let engine = audioEngine else {
            hasInstalledTap = false
            exertionLevel = 0
            exertionTimer?.invalidate()
            exertionTimer = nil
            return
        }

        // Only remove the tap if we actually installed one AND the engine is currently running.
        // Calling removeTap on a stopped engine, or one whose tap was never installed, throws
        // EXC_BAD_ACCESS on iOS 17+.
        if hasInstalledTap, engine.isRunning {
            engine.inputNode.removeTap(onBus: 0)
        }
        hasInstalledTap = false

        if engine.isRunning {
            engine.stop()
        }
        audioEngine = nil
        exertionLevel = 0
        exertionTimer?.invalidate()
        exertionTimer = nil
    }
}
