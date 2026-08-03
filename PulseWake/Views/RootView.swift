import SwiftUI

/// App shell: dashboard plus automatic exercise verification when an alarm is ringing.
public struct RootView: View {
    @Bindable private var alarmManager = AlarmManager.shared

    /// Real dismissible state driving the fullScreenCover. SwiftUI can now retract the cover
    /// on its own (the previous getter-only binding with a no-op setter would hang if the
    /// celebration path ever failed to flip `isRinging`).
    @State private var isCoverPresented = false

    private var shouldShowRingingVerification: Bool {
        alarmManager.isRinging && alarmManager.activeRingingAlarm != nil
    }

    public init() {}

    public var body: some View {
        DashboardView()
            .fullScreenCover(isPresented: $isCoverPresented) {
                if let alarm = alarmManager.activeRingingAlarm {
                    ExerciseVerificationView(
                        exerciseType: alarm.exerciseType,
                        targetReps: alarm.targetReps,
                        alarmLabel: alarm.label,
                        alarmSoundName: alarm.soundName,
                        onComplete: {}
                    )
                    .interactiveDismissDisabled(true)
                }
            }
            .id(alarmManager.verificationPresentationToken)
            // Observe the manager's presentation state: when it flips on, present; when it
            // flips off (celebration finish / abort / escape hatch), dismiss. Doing this via
            // `.onChange` rather than a getter-only binding keeps the cover always dismissible
            // and ensures we never re-mount on every body re-render.
            .onChange(of: shouldShowRingingVerification) { _, newValue in
                if newValue && !isCoverPresented {
                    isCoverPresented = true
                } else if !newValue && isCoverPresented {
                    isCoverPresented = false
                }
            }
            .onChange(of: alarmManager.verificationPresentationToken) { _, _ in
                // Token re-bump means a new alarm re-fired while the cover is already up
                // (e.g. repeat-day schedule). Force a fresh mount of the cover by toggling off
                // and on; the `.id(token)` modifier guarantees a fresh view instance.
                guard shouldShowRingingVerification else { return }
                if isCoverPresented {
                    isCoverPresented = false
                    DispatchQueue.main.async {
                        isCoverPresented = true
                    }
                } else {
                    isCoverPresented = true
                }
            }
    }
}
