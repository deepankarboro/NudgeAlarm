import SwiftUI

/// App shell: dashboard plus automatic exercise verification when an alarm is ringing.
public struct RootView: View {
    @Bindable private var alarmManager = AlarmManager.shared

    private var shouldShowRingingVerification: Bool {
        alarmManager.isRinging && alarmManager.activeRingingAlarm != nil
    }

    public init() {}

    public var body: some View {
        DashboardView()
            .fullScreenCover(isPresented: ringingVerificationPresented) {
                if let alarm = alarmManager.activeRingingAlarm {
                    ExerciseVerificationView(
                        exerciseType: alarm.exerciseType,
                        targetReps: alarm.targetReps,
                        alarmLabel: alarm.label,
                        alarmSoundName: alarm.soundName,
                        onComplete: {}
                    )
                    .interactiveDismissDisabled(true)
                    .id(alarmManager.verificationPresentationToken)
                }
            }
    }

    private var ringingVerificationPresented: Binding<Bool> {
        Binding(
            get: { shouldShowRingingVerification },
            set: { _ in }
        )
    }
}
