import SwiftUI
import SwiftData

public struct ExerciseVerificationView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    
    public let exerciseType: ExerciseType
    public let targetReps: Int
    public let alarmLabel: String
    public let onComplete: () -> Void
    
    @State private var engine = MotionVisionEngine()
    @State private var startTime = Date()
    @State private var showEmergencySnoozeAlert = false
    @State private var lastSpokenRep = 0
    
    public init(
        exerciseType: ExerciseType,
        targetReps: Int,
        alarmLabel: String = "Morning Alarm",
        onComplete: @escaping () -> Void
    ) {
        self.exerciseType = exerciseType
        self.targetReps = targetReps
        self.alarmLabel = alarmLabel
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
            Color.black.ignoresSafeArea()
            
            // Live Camera Feed
            if engine.cameraPermissionGranted {
                CameraPreviewView(captureSession: engine.captureSession)
                    .ignoresSafeArea()
                
                // Real-time Vision Skeleton Joint Canvas Overlay
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
                    Text("Please enable camera access in Settings so NudgeAlarm can detect your exercise reps.")
                        .multilineTextAlignment(.center)
                        .font(.subheadline)
                        .foregroundColor(.gray)
                        .padding(.horizontal, 32)
                }
            }
            
            // Top HUD Bar: Exercise Title & Progress Ring
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
                    
                    // Rep Counter Widget
                    ZStack {
                        Circle()
                            .stroke(Color.white.opacity(0.2), lineWidth: 8)
                            .frame(width: 80, height: 80)
                        
                        Circle()
                            .trim(from: 0, to: progressRatio)
                            .stroke(
                                LinearGradient(colors: [.cyan, .green], startPoint: .topLeading, endPoint: .bottomTrailing),
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
                
                Spacer()
                
                // Bottom HUD: Form Guidance Banner & Angle Stats
                VStack(spacing: 16) {
                    // Position Pitch Angle Sensor Status
                    HStack(spacing: 12) {
                        Image(systemName: engine.isDevicePitchValid ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                            .foregroundColor(engine.isDevicePitchValid ? .green : .orange)
                        
                        Text(engine.isDevicePitchValid ? "Phone Position OK" : "Adjust Phone Tilt")
                            .font(.caption.bold())
                            .foregroundColor(.white)
                        
                        Spacer()
                        
                        if exerciseType == .pushUp {
                            Text("Elbow: \(Int(engine.pushUpDetector.currentElbowAngle))°")
                                .font(.caption.monospaced())
                                .foregroundColor(.cyan)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(.ultraThinMaterial)
                    .cornerRadius(20)
                    .padding(.horizontal, 24)
                    
                    // Form Live Audio Feedback Card
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
                    
                    // Emergency Emergency Snooze Button
                    Button(action: {
                        showEmergencySnoozeAlert = true
                    }) {
                        Text("Emergency 5-Min Snooze")
                            .font(.footnote.weight(.semibold))
                            .foregroundColor(.red.opacity(0.9))
                            .padding(.vertical, 8)
                    }
                    .padding(.bottom, 20)
                }
            }
        }
        .onAppear {
            engine.startEngine(exercise: exerciseType, targetReps: targetReps)
            AlarmManager.shared.speakInstruction("Alarm active! Perform \(targetReps) \(exerciseType.rawValue) to dismiss.")
        }
        .onDisappear {
            engine.stopEngine()
        }
        .onChange(of: currentReps) { _, newReps in
            if newReps > lastSpokenRep {
                lastSpokenRep = newReps
                SoundEngine.shared.speakRepCount(newReps, target: targetReps)
                SoundEngine.shared.playSuccessBeep()
                
                if newReps >= targetReps {
                    completeExercise()
                }
            }
        }
        .alert("Emergency Snooze", isPresented: $showEmergencySnoozeAlert) {
            Button("Snooze 5 Mins (Penalty +5 Reps Next Time)", role: .destructive) {
                AlarmManager.shared.stopRinging()
                onComplete()
                dismiss()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Are you sure you want to snooze? Completing your reps now is the best way to wake up!")
        }
    }
    
    private func completeExercise() {
        let duration = Date().timeIntervalSince(startTime)
        
        // Log completed workout session to SwiftData
        let log = WorkoutHistoryModel(
            alarmLabel: alarmLabel,
            exerciseType: exerciseType,
            completedReps: targetReps,
            durationSeconds: duration
        )
        modelContext.insert(log)
        try? modelContext.save()
        
        AlarmManager.shared.stopRinging()
        onComplete()
        dismiss()
    }
}
