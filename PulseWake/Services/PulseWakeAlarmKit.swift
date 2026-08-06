import Foundation
import AppIntents
import SwiftUI
#if canImport(AlarmKit)
import AlarmKit
import ActivityKit
#endif

#if canImport(AlarmKit)

/// AlarmKit-backed alarms (iOS 26.1+).
///
/// Why this exists: a `UNNotificationRequest` alarm is trivially defeated. Its sound is capped
/// at 30 s, the volume buttons silence it, and once the user force-quits the app the process is
/// gone and nothing can make noise again. AlarmKit alarms are owned by the system — they behave
/// like the Clock app's, break through silent mode and Focus, and keep alerting after the app is
/// closed.
///
/// The presentation deliberately has **no stop button**. As of iOS 26.1 `AlarmPresentation.Alert`
/// exposes an initialiser without one (`stopButton` is deprecated and no longer used), so the only
/// affordance on the system alert is our secondary button, which opens PulseWake straight into
/// rep verification. The alarm keeps alerting until `stopAlerting(id:)` is called, and the only
/// caller is the completed-reps path.
///
/// Naming: the app has its own `AlarmManager`, so every reference to AlarmKit's is written out as
/// `AlarmKit.AlarmManager` to keep the two unambiguous.
@available(iOS 26.1, *)
public struct PulseWakeAlarmMetadata: AlarmMetadata {
    public let exerciseTypeRaw: String
    public let targetReps: Int
    public let soundName: String
    public let label: String

    public init(exerciseTypeRaw: String, targetReps: Int, soundName: String, label: String) {
        self.exerciseTypeRaw = exerciseTypeRaw
        self.targetReps = targetReps
        self.soundName = soundName
        self.label = label
    }
}

/// Runs when the user taps the alert's only button. `openAppWhenRun` foregrounds PulseWake, and
/// `perform()` hands the alarm's details to `AlarmManager` so verification comes up immediately.
///
/// Every field the verification screen needs travels in the intent's own parameters rather than
/// being looked up in SwiftData — the same approach the notification path takes with `userInfo`,
/// and it means this works even when the app was launched cold by the tap.
@available(iOS 26.1, *)
public struct StartPulseWakeVerificationIntent: LiveActivityIntent {
    public static var title: LocalizedStringResource = "Start PulseWake Exercise"
    public static var openAppWhenRun: Bool = true

    @Parameter(title: "Alarm ID") public var alarmID: String
    @Parameter(title: "Exercise") public var exerciseTypeRaw: String
    @Parameter(title: "Target Reps") public var targetReps: Int
    @Parameter(title: "Label") public var label: String
    @Parameter(title: "Sound") public var soundName: String

    public init() {
        self.alarmID = ""
        self.exerciseTypeRaw = ExerciseType.pushUp.rawValue
        self.targetReps = 5
        self.label = "Alarm"
        self.soundName = "Beep"
    }

    public init(alarmID: String, exerciseTypeRaw: String, targetReps: Int, label: String, soundName: String) {
        self.alarmID = alarmID
        self.exerciseTypeRaw = exerciseTypeRaw
        self.targetReps = targetReps
        self.label = label
        self.soundName = soundName
    }

    @MainActor
    public func perform() async throws -> some IntentResult {
        let alarm = AlarmModel(
            id: UUID(uuidString: alarmID) ?? UUID(),
            label: label,
            exerciseType: ExerciseType(rawValue: exerciseTypeRaw) ?? .pushUp,
            targetReps: targetReps,
            isEnabled: true,
            repeatDays: [],
            soundName: soundName
        )
        AlarmManager.shared.startRinging(alarm: alarm)
        return .result()
    }
}

@available(iOS 26.1, *)
public enum PulseWakeAlarmKitScheduler {

    public static var isAuthorized: Bool {
        AlarmKit.AlarmManager.shared.authorizationState == .authorized
    }

    @discardableResult
    public static func requestAuthorization() async -> Bool {
        let current = AlarmKit.AlarmManager.shared.authorizationState
        if current == .authorized { return true }
        if current == .denied { return false }
        do {
            return try await AlarmKit.AlarmManager.shared.requestAuthorization() == .authorized
        } catch {
            print("AlarmKit authorization failed: \(error)")
            return false
        }
    }

    /// Schedules `alarm` as a system alarm. Returns false if AlarmKit could not take it, so the
    /// caller can fall back to the legacy notification path rather than leaving the user with no
    /// alarm at all.
    @discardableResult
    public static func schedule(_ alarm: AlarmModel) async -> Bool {
        guard await requestAuthorization() else { return false }

        let components = Calendar.current.dateComponents([.hour, .minute], from: alarm.time)
        let time = Alarm.Schedule.Relative.Time(
            hour: components.hour ?? 7,
            minute: components.minute ?? 0
        )
        let recurrence: Alarm.Schedule.Relative.Recurrence = alarm.repeatDays.isEmpty
            ? .never
            : .weekly(alarm.repeatDays.compactMap(weekday(from:)))
        let schedule = Alarm.Schedule.relative(.init(time: time, repeats: recurrence))

        // No stop button — the only way off this screen is into the exercise.
        let alert = AlarmPresentation.Alert(
            title: LocalizedStringResource(stringLiteral: "PULSEWAKE — \(alarm.label)"),
            secondaryButton: AlarmButton(
                text: LocalizedStringResource(
                    stringLiteral: "Do \(alarm.targetReps) \(alarm.exerciseType.rawValue)"
                ),
                textColor: .white,
                systemImageName: alarm.exerciseType.iconName
            ),
            secondaryButtonBehavior: .custom
        )

        let attributes = AlarmAttributes<PulseWakeAlarmMetadata>(
            presentation: AlarmPresentation(alert: alert),
            metadata: PulseWakeAlarmMetadata(
                exerciseTypeRaw: alarm.exerciseTypeRaw,
                targetReps: alarm.targetReps,
                soundName: alarm.soundName,
                label: alarm.label
            ),
            tintColor: Color.cyan
        )

        let intent = StartPulseWakeVerificationIntent(
            alarmID: alarm.id.uuidString,
            exerciseTypeRaw: alarm.exerciseTypeRaw,
            targetReps: alarm.targetReps,
            label: alarm.label,
            soundName: alarm.soundName
        )

        let configuration = AlarmKit.AlarmManager.AlarmConfiguration<PulseWakeAlarmMetadata>.alarm(
            schedule: schedule,
            attributes: attributes,
            secondaryIntent: intent,
            sound: alarmSound(named: alarm.soundName)
        )

        do {
            _ = try await AlarmKit.AlarmManager.shared.schedule(
                id: alarm.id,
                configuration: configuration
            )
            return true
        } catch {
            print("AlarmKit schedule failed: \(error)")
            return false
        }
    }

    public static func cancel(_ alarm: AlarmModel) {
        do {
            try AlarmKit.AlarmManager.shared.cancel(id: alarm.id)
        } catch {
            // Cancelling an alarm AlarmKit never accepted is expected and harmless.
            print("AlarmKit cancel skipped for \(alarm.id): \(error)")
        }
    }

    /// The single exit. Called only once the required reps are logged.
    public static func stopAlerting(id: UUID) {
        do {
            try AlarmKit.AlarmManager.shared.stop(id: id)
        } catch {
            print("AlarmKit stop skipped for \(id): \(error)")
        }
    }

    private static func alarmSound(named soundName: String) -> AlertConfiguration.AlertSound {
        guard Bundle.main.url(forResource: soundName, withExtension: "mp3") != nil else {
            return .default
        }
        return .named("\(soundName).mp3")
    }

    /// Maps `Calendar` weekday numbers (1 = Sunday) onto `Locale.Weekday`.
    private static func weekday(from calendarWeekday: Int) -> Locale.Weekday? {
        switch calendarWeekday {
        case 1: return .sunday
        case 2: return .monday
        case 3: return .tuesday
        case 4: return .wednesday
        case 5: return .thursday
        case 6: return .friday
        case 7: return .saturday
        default: return nil
        }
    }
}

#endif
