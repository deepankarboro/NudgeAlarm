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
                SoundEngine.shared.speakRepCount(newReps, target: targetReps)
                SoundEngine.shared.playSuccessBeep()

                if newReps >= targetReps {
                    hasCompleted = true
                    completeExercise()
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

        let log = WorkoutHistoryModel(
            alarmLabel: alarmLabel,
            exerciseType: exerciseType,
            completedReps: targetReps,
            durationSeconds: duration
        )
        modelContext.insert(log)
        try? modelContext.save()

        sensors.finishWorkout(
            exerciseType: exerciseType,
            reps: targetReps,
            durationSeconds: duration,
            startDate: startTime
        )

        engine.stopEngine()
        sensors.stopExerciseSession()

        withAnimation(.spring(response: 0.45, dampingFraction: 0.82)) {
            showCelebration = true
        }
    }

    private func finishAfterCelebration() {
        AlarmManager.shared.stopRingingAfterCelebration()
        onComplete()
    }

    private func beginVerificationSession() {
        hasCompleted = false
        showCelebration = false
        startTime = Date()
        lastSpokenRep = 0
        #if canImport(UIKit)
        UIApplication.shared.isIdleTimerDisabled = true
        #endif
        AlarmManager.shared.configureAudioSessionForExerciseVerification()
        AlarmManager.shared.ensureVerificationAlarmActive(
            exerciseType: exerciseType,
            targetReps: targetReps,
            label: alarmLabel,
            soundName: alarmSoundName
        )
        engine.startEngine(exercise: exerciseType, targetReps: targetReps)
        sensors.startExerciseSession()
        AlarmManager.shared.speakInstruction("Alarm active! Perform \(targetReps) \(exerciseType.rawValue) to dismiss.")
    }

    private func endVerificationSession() {
        #if canImport(UIKit)
        UIApplication.shared.isIdleTimerDisabled = false
        #endif
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
