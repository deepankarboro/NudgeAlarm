import SwiftUI
import SwiftData
#if canImport(UIKit)
import UIKit
#endif

public struct ExerciseVerificationView: View {
    @Environment(\.modelContext) private var modelContext

    public let exerciseType: ExerciseType
    public let targetReps: Int
    public let alarmLabel: String
    public let alarmSoundName: String
    public let onComplete: () -> Void

    @Bindable private var engine = MotionVisionEngine.shared
    @State private var startTime = Date()
    @State private var lastSpokenRep = 0
    @State private var hasCompleted = false
    @State private var showCelebration = false
    @Environment(\.scenePhase) private var scenePhase
    @Bindable private var sensors = WorkoutSensorHub.shared

    // Endpoint F: Detection-failure escape hatch state.
    // After repeated Vision failures (~1 s of 30 fps) OR no skeleton detected for 20 s,
    // surface a non-dismissible "Silence alarm" button so the user is never trapped
    // if detection breaks (especially on a real wake-up).
    @State private var consecutiveVisionFailures = 0
    @State private var lastSkeletonSeenAt: Date = Date()
    @State private var showEscapeHatch = false
    private let visionFailureThreshold = 30
    private let noSkeletonSeconds = 20.0

    public init(
        exerciseType: ExerciseType,
        targetReps: Int,
        alarmLabel: String = "Morning Alarm",
        alarmSoundName: String = "Beep",
        onComplete: @escaping () -> Void
    ) {
        self.exerciseType = exerciseType
        self.targetReps = targetReps
        self.alarmLabel = alarmLabel
        self.alarmSoundName = alarmSoundName
        self.onComplete = onComplete
    }

    private var currentReps: Int {
        if exerciseType == .pushUp {
            return engine.pushUpDetector.currentRepCount
        } else {
            return engine.pullUpDetector.currentRepCount
        }
    }

    private var currentFeedback: String {
        if exerciseType == .pushUp {
            return engine.pushUpDetector.formFeedback
        } else {
            return engine.pullUpDetector.formFeedback
        }
    }

    private var isFormValid: Bool {
        if exerciseType == .pushUp {
            return engine.pushUpDetector.isFormValid
        } else {
            return engine.pullUpDetector.isFormValid
        }
    }

    private var progressRatio: Double {
        min(Double(currentReps) / Double(max(1, targetReps)), 1.0)
    }

    public var body: some View {
        ZStack {
            verificationContent

            if showCelebration {
                WorkoutCelebrationView(
                    exerciseType: exerciseType,
                    targetReps: targetReps,
                    onFinished: finishAfterCelebration
                )
                .transition(.opacity.combined(with: .scale(scale: 1.02)))
                .zIndex(10)
            }

            // Endpoint F: Escape-hatch overlay. Drawn above everything except the celebration.
            if showEscapeHatch && !hasCompleted && !showCelebration {
                VStack(spacing: 14) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 44))
                        .foregroundStyle(.linearGradient(colors: [.orange, .red], startPoint: .top, endPoint: .bottom))
                    Text("Detection unavailable")
                        .font(.title3.weight(.bold))
                        .foregroundColor(.white)
                    Text("PulseWake couldn't detect reps. Silence the alarm and make sure your body and the camera are well-positioned.")
                        .font(.subheadline)
                        .foregroundColor(.gray)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 28)
                    Button(action: silenceAlarmAndAbort) {
                        Text("Silence Alarm")
                            .font(.headline.weight(.semibold))
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .background(LinearGradient(colors: [.orange, .red], startPoint: .leading, endPoint: .trailing))
                            .cornerRadius(14)
                    }
                    .padding(.horizontal, 36)
                    .padding(.top, 4)
                }
                .padding(28)
                .background(.regularMaterial)
                .cornerRadius(24)
                .padding(.horizontal, 24)
                .transition(.opacity.combined(with: .scale(scale: 0.96)))
                .zIndex(9)
                .animation(.spring(response: 0.4, dampingFraction: 0.85), value: showEscapeHatch)
            }
        }
        .interactiveDismissDisabled(true)
        .onAppear(perform: beginVerificationSession)
        .onDisappear(perform: endVerificationSession)
        .onChange(of: scenePhase) { _, newPhase in
            handleScenePhaseChange(newPhase)
        }
        .onChange(of: currentReps) { _, newReps in
            guard !hasCompleted else { return }
            if newReps > lastSpokenRep {
                lastSpokenRep = newReps
                SoundEngine.shared.playSuccessBeep()

                if newReps >= targetReps {
                    hasCompleted = true
                    completeExercise()
                }
            }
        }
        // Endpoint F watchdog: a frame with a non-empty skeleton resets the failure clock.
        .onChange(of: engine.currentSkeleton.points.count) { _, count in
            if count > 0 {
                consecutiveVisionFailures = 0
                lastSkeletonSeenAt = Date()
                if showEscapeHatch {
                    showEscapeHatch = false
                }
            }
        }
        // Endpoint F watchdog: a single shot timer that wakes every 2 s and checks the
        // two failure conditions (vision errors / no skeleton). Cheaper than running a
        // Timer.publish on the body itself.
        .task {
            while !hasCompleted && !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                guard !hasCompleted && !showCelebration else { return }

                let elapsedSinceSkeleton = Date().timeIntervalSince(lastSkeletonSeenAt)
                if elapsedSinceSkeleton >= noSkeletonSeconds || consecutiveVisionFailures >= visionFailureThreshold {
                    if !showEscapeHatch {
                        showEscapeHatch = true
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var verificationContent: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if engine.cameraPermissionGranted {
                CameraPreviewView(
                    captureSession: engine.captureSession,
                    videoOrientation: engine.previewVideoOrientation,
                    isMirrored: engine.usesFrontCamera
                )
                .ignoresSafeArea()

                PoseOverlayCanvas(
                    skeleton: engine.currentSkeleton,
                    isFormValid: isFormValid
                )
                .ignoresSafeArea()
            } else {
                VStack(spacing: 16) {
                    Image(systemName: "camera.metering.unknown")
                        .font(.system(size: 56))
                        .foregroundColor(.yellow)
                    Text("Camera Access Required")
                        .font(.title2.bold())
                        .foregroundColor(.white)
                    Text("Please enable camera access in Settings so PulseWake can detect your exercise reps.")
                        .multilineTextAlignment(.center)
                        .font(.subheadline)
                        .foregroundColor(.gray)
                        .padding(.horizontal, 32)

                    if engine.cameraPermissionDenied {
                        Button(action: openAppSettings) {
                            Text("Open Settings")
                                .font(.headline)
                                .foregroundColor(.black)
                                .padding(.horizontal, 24)
                                .padding(.vertical, 12)
                                .background(Color.cyan)
                                .cornerRadius(12)
                        }
                        .padding(.top, 8)
                    }
                }
            }

            if let setupError = engine.setupError {
                VStack {
                    Spacer()
                    Text(setupError)
                        .font(.subheadline.weight(.semibold))
                        .foregroundColor(.white)
                        .multilineTextAlignment(.center)
                        .padding()
                        .background(Color.red.opacity(0.85))
                        .cornerRadius(12)
                        .padding(.horizontal, 24)
                        .padding(.bottom, 120)
                }
            }

            VStack {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 8) {
                            Image(systemName: exerciseType.iconName)
                                .font(.title3)
                                .foregroundColor(.cyan)
                            Text(exerciseType.rawValue.uppercased())
                                .font(.headline.weight(.heavy))
                                .foregroundColor(.white)
                        }
                        Text(alarmLabel)
                            .font(.caption)
                            .foregroundColor(.gray)
                    }
                    .padding(12)
                    .background(.ultraThinMaterial)
                    .cornerRadius(12)

                    Spacer()

                    ZStack {
                        Circle()
                            .stroke(Color.white.opacity(0.2), lineWidth: 8)
                            .frame(width: 80, height: 80)

                        Circle()
                            .trim(from: 0, to: progressRatio)
                            .stroke(
                                LinearGradient(colors: [.cyan, .green], startPoint: .topLeading, endPoint: .trailing),
                                style: StrokeStyle(lineWidth: 8, lineCap: .round)
                            )
                            .rotationEffect(.degrees(-90))
                            .frame(width: 80, height: 80)

                        VStack(spacing: 0) {
                            Text("\(currentReps)")
                                .font(.system(size: 28, weight: .bold, design: .rounded))
                                .foregroundColor(.white)
                            Text("/ \(targetReps)")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundColor(.gray)
                        }
                    }
                    .padding(8)
                    .background(.ultraThinMaterial)
                    .clipShape(Circle())
                }
                .padding(.horizontal, 16)
                .padding(.top, 50)

                Text("Complete all reps to silence the alarm")
                    .font(.caption.weight(.semibold))
                    .foregroundColor(.orange)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
                    .background(Color.orange.opacity(0.2))
                    .clipShape(Capsule())
                    .padding(.top, 8)

                Spacer()

                VStack(spacing: 16) {
                    HStack(spacing: 12) {
                        Image(systemName: engine.isDevicePitchValid ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                            .foregroundColor(engine.isDevicePitchValid ? .green : .orange)

                        Text(engine.isDevicePitchValid ? "Phone Position OK" : "Adjust Phone Tilt")
                            .font(.caption.bold())
                            .foregroundColor(.white)

                        Spacer()

                        if exerciseType == .pushUp {
                            VStack(alignment: .trailing, spacing: 2) {
                                Text(engine.pushUpDetector.placement.rawValue)
                                    .font(.caption2)
                                    .foregroundColor(.gray)
                                Text("Depth: \(Int(engine.pushUpDetector.bodyDropRatio * 100))% · Elbow \(Int(engine.pushUpDetector.currentElbowAngle))°")
                                    .font(.caption.monospaced())
                                    .foregroundColor(.cyan)
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(.ultraThinMaterial)
                    .cornerRadius(20)
                    .padding(.horizontal, 24)

                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Image(systemName: "figure.walk")
                                .foregroundColor(sensors.isPhysicallyActive ? .green : .orange)
                            Text(sensors.activitySummary)
                                .font(.caption.bold())
                                .foregroundColor(.white)
                            Spacer()
                            Text("\(sensors.sessionSteps) steps")
                                .font(.caption.monospaced())
                                .foregroundColor(.cyan)
                        }
                        HStack(spacing: 8) {
                            Image(systemName: "waveform")
                                .font(.caption)
                                .foregroundColor(.gray)
                            GeometryReader { geo in
                                ZStack(alignment: .leading) {
                                    Capsule()
                                        .fill(Color.white.opacity(0.15))
                                    Capsule()
                                        .fill(
                                            LinearGradient(
                                                colors: [.green, .cyan],
                                                startPoint: .leading,
                                                endPoint: .trailing
                                            )
                                        )
                                        .frame(width: geo.size.width * CGFloat(sensors.exertionLevel))
                                }
                            }
                            .frame(height: 8)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(.ultraThinMaterial)
                    .cornerRadius(16)
                    .padding(.horizontal, 16)

                    HStack {
                        Image(systemName: "figure.walk.motion")
                            .font(.title2)
                            .foregroundColor(isFormValid ? .green : .yellow)

                        Text(currentFeedback)
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundColor(.white)
                            .multilineTextAlignment(.leading)

                        Spacer()
                    }
                    .padding(16)
                    .background(isFormValid ? Color.blue.opacity(0.3) : Color.orange.opacity(0.3))
                    .background(.ultraThinMaterial)
                    .cornerRadius(16)
                    .overlay(
                        RoundedRectangle(cornerRadius: 16)
                            .stroke(isFormValid ? Color.cyan.opacity(0.5) : Color.orange.opacity(0.5), lineWidth: 1.5)
                    )
                    .padding(.horizontal, 16)
                    .padding(.bottom, 24)
                }
            }
        }
    }

    private func completeExercise() {
        let duration = Date().timeIntervalSince(startTime)

        // Endpoint G: store the actual count of reps the detector counted (clamped to target).
        // Previously this always stored `targetReps`, hiding overshoot bugs in the detectors.
        let finalReps = min(max(currentReps, 0), targetReps)
        let log = WorkoutHistoryModel(
            alarmLabel: alarmLabel,
            exerciseType: exerciseType,
            completedReps: finalReps,
            durationSeconds: duration
        )
        modelContext.insert(log)
        try? modelContext.save()

        sensors.finishWorkout(
            exerciseType: exerciseType,
            reps: finalReps,
            durationSeconds: duration,
            startDate: startTime
        )

        engine.stopEngine()
        sensors.stopExerciseSession()

        withAnimation(.spring(response: 0.45, dampingFraction: 0.82)) {
            showCelebration = true
        }
    }

    /// Endpoint F: User-tap escape hatch. Silences the alarm and dismisses the cover so
    /// the user is never trapped if detection fails. Logs a 0-rep `WorkoutHistoryModel`
    /// so the user has a record they overslept/aborted. Does NOT count toward workout totals
    /// in HealthKit (we skip `finishWorkout`).
    private func silenceAlarmAndAbort() {
        guard !hasCompleted, !showCelebration else { return }
        hasCompleted = true
        showEscapeHatch = false

        let duration = Date().timeIntervalSince(startTime)
        let log = WorkoutHistoryModel(
            alarmLabel: alarmLabel,
            exerciseType: exerciseType,
            completedReps: 0,
            durationSeconds: duration
        )
        modelContext.insert(log)
        try? modelContext.save()

        engine.stopEngine()
        sensors.stopExerciseSession()

        AlarmManager.shared.stopRingingAfterCelebration()
        onComplete()
    }

    private func finishAfterCelebration() {
        AlarmManager.shared.stopRingingAfterCelebration()
        onComplete()
    }

    private func beginVerificationSession() {
        hasCompleted = false
        showCelebration = false
        showEscapeHatch = false
        consecutiveVisionFailures = 0
        startTime = Date()
        lastSpokenRep = 0
        lastSkeletonSeenAt = Date()
        #if canImport(UIKit)
        UIApplication.shared.isIdleTimerDisabled = true
        #endif
        // Endpoint F: subscribe to Vision failures from the engine. The callback fires on the
        // main thread (engine guarantees this). We increment a counter; when it exceeds the
        // threshold the watchdog `.task` will surface the escape hatch.
        engine.onVisionError = { _ in
            consecutiveVisionFailures += 1
        }
        AlarmManager.shared.configureAudioSessionForExerciseVerification()
        AlarmManager.shared.ensureVerificationAlarmActive(
            exerciseType: exerciseType,
            targetReps: targetReps,
            label: alarmLabel,
            soundName: alarmSoundName
        )
        engine.startEngine(exercise: exerciseType, targetReps: targetReps)
        sensors.startExerciseSession()
    }

    private func endVerificationSession() {
        #if canImport(UIKit)
        UIApplication.shared.isIdleTimerDisabled = false
        #endif
        // Disconnect the Vision failure callback so we don't keep accumulating onto a
        // released view's @State after dismissal.
        engine.onVisionError = nil
        if !showCelebration {
            engine.stopEngine()
            sensors.stopExerciseSession()
        }
        if hasCompleted {
            sensors.stopWakeSession()
        } else if !AlarmManager.shared.isRinging {
            sensors.stopWakeSession()
        } else if !showCelebration {
            AlarmManager.shared.resumeAlarmPlaybackIfNeeded()
        }
        AlarmManager.shared.restoreAudioSessionAfterExerciseVerification()
    }

    private func handleScenePhaseChange(_ phase: ScenePhase) {
        guard !hasCompleted, !showCelebration else { return }
        switch phase {
        case .active:
            if !engine.cameraPermissionGranted {
                engine.startEngine(exercise: exerciseType, targetReps: targetReps)
            }
            AlarmManager.shared.resumeAlarmPlaybackIfNeeded()
        case .inactive, .background:
            AlarmManager.shared.ensureVerificationAlarmActive(
                exerciseType: exerciseType,
                targetReps: targetReps,
                label: alarmLabel,
                soundName: alarmSoundName
            )
            AlarmManager.shared.resumeAlarmPlaybackIfNeeded()
        @unknown default:
            break
        }
    }

    private func openAppSettings() {
        #if canImport(UIKit)
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
        #endif
    }
}
