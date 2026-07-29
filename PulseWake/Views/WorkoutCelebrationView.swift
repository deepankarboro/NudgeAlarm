import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// Full-screen confetti + message shown after reps are completed; alarm stops when dismissed.
public struct WorkoutCelebrationView: View {
    public let exerciseType: ExerciseType
    public let targetReps: Int
    public let onFinished: () -> Void

    @State private var particles: [ConfettiParticle] = []
    @State private var titleScale: CGFloat = 0.6
    @State private var titleOpacity: Double = 0
    @State private var hasStartedExit = false

    public init(
        exerciseType: ExerciseType,
        targetReps: Int,
        onFinished: @escaping () -> Void
    ) {
        self.exerciseType = exerciseType
        self.targetReps = targetReps
        self.onFinished = onFinished
    }

    public var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(red: 0.05, green: 0.12, blue: 0.22),
                    Color.black
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            TimelineView(.animation) { timeline in
                Canvas { context, size in
                    let time = timeline.date.timeIntervalSinceReferenceDate
                    for particle in particles {
                        let age = time - particle.birthTime
                        guard age >= 0, age < particle.lifetime else { continue }
                        let progress = age / particle.lifetime
                        let x = particle.origin.x + particle.velocity.dx * age
                        let y = particle.origin.y + particle.velocity.dy * age + 120 * age * age
                        let opacity = 1.0 - progress
                        var rect = CGRect(x: x, y: y, width: particle.size, height: particle.size * 0.6)
                        rect = rect.offsetBy(dx: -particle.size / 2, dy: -particle.size / 2)
                        context.opacity = opacity
                        context.fill(
                            Path(roundedRect: rect, cornerRadius: 2),
                            with: .color(particle.color)
                        )
                    }
                }
            }
            .ignoresSafeArea()
            .allowsHitTesting(false)

            VStack(spacing: 20) {
                Image(systemName: "party.popper.fill")
                    .font(.system(size: 56))
                    .foregroundStyle(
                        LinearGradient(colors: [.yellow, .cyan, .green], startPoint: .topLeading, endPoint: .bottomTrailing)
                    )
                    .symbolEffect(.bounce, value: titleOpacity)

                Text("Cheers — you did it!")
                    .font(.system(size: 34, weight: .heavy, design: .rounded))
                    .multilineTextAlignment(.center)
                    .foregroundColor(.white)
                    .scaleEffect(titleScale)
                    .opacity(titleOpacity)

                Text("\(targetReps) \(exerciseType.rawValue) complete")
                    .font(.title3.weight(.semibold))
                    .foregroundColor(.cyan)
                    .opacity(titleOpacity)

                Text("Alarm silenced. Great wake-up.")
                    .font(.subheadline)
                    .foregroundColor(.gray)
                    .opacity(titleOpacity * 0.9)
            }
            .padding(32)
        }
        .onAppear {
            AlarmManager.shared.silenceAlarmAudioForCelebration()
            spawnConfetti()
            withAnimation(.spring(response: 0.55, dampingFraction: 0.72)) {
                titleScale = 1.0
                titleOpacity = 1.0
            }
            SoundEngine.shared.playSuccessBeep()
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.8) {
                finishCelebration()
            }
        }
    }

    private func spawnConfetti() {
        let colors: [Color] = [.cyan, .green, .yellow, .orange, .pink, .mint, .white]
        let now = Date.timeIntervalSinceReferenceDate
        let width: CGFloat
        #if canImport(UIKit)
        width = UIScreen.main.bounds.width
        #else
        width = 400
        #endif
        particles = (0..<120).map { _ in
            ConfettiParticle(
                origin: CGPoint(x: CGFloat.random(in: 0...width), y: CGFloat.random(in: -40...0)),
                velocity: CGVector(
                    dx: CGFloat.random(in: -80...80),
                    dy: CGFloat.random(in: 40...160)
                ),
                size: CGFloat.random(in: 6...12),
                color: colors.randomElement() ?? .cyan,
                birthTime: now + Double.random(in: 0...0.4),
                lifetime: Double.random(in: 2.2...3.4)
            )
        }
    }

    private func finishCelebration() {
        guard !hasStartedExit else { return }
        hasStartedExit = true
        withAnimation(.easeOut(duration: 0.35)) {
            titleOpacity = 0
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            onFinished()
        }
    }
}

private struct ConfettiParticle {
    var origin: CGPoint
    var velocity: CGVector
    var size: CGFloat
    var color: Color
    var birthTime: TimeInterval
    var lifetime: TimeInterval
}
