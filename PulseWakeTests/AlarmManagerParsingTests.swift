import XCTest
import UserNotifications
@testable import PulseWake

/// Endpoint D / Notification round-trip contract tests for AlarmManager.
///
/// Validates that:
///  - `intFromUserInfo` tolerates both `Int` and `NSNumber` payloads (iOS encodes `userInfo`
///    values as NSNumber when the app is launched from a notification).
///  - `alarmFromNotificationContent` returns nil on missing/malformed keys.
///  - `alarmFromNotificationContent` round-trips every field the schedule path writes into
///    `userInfo` (alarmId, exerciseType, targetReps, soundName).
///  - The reconstructed alarm is *not* persisted — it has no modelContext — purely ephemeral.
final class AlarmManagerParsingTests: XCTestCase {

    private func makeContent(userInfo: [AnyHashable: Any], title: String = "⚡️ PULSEWAKE: Morning Alarm") -> UNNotificationContent {
        let content = UNMutableNotificationContent()
        content.title = title
        content.userInfo = userInfo
        return content
    }

    func test_intFromUserInfo_acceptsBareInt() {
        XCTAssertTrue(AlarmManager.shared.intFromUserInfo(["targetReps": 7], key: "targetReps") == 7)
    }

    func test_intFromUserInfo_acceptsNSNumber() {
        // iOS serializes userInfo ints as NSNumber on cold-launch from a notification.
        let n = NSNumber(value: 12)
        XCTAssertTrue(AlarmManager.shared.intFromUserInfo(["targetReps": n], key: "targetReps") == 12)
    }

    func test_intFromUserInfo_returnsNilForMissingKey() {
        XCTAssertNil(AlarmManager.shared.intFromUserInfo([:], key: "targetReps"))
    }

    func test_intFromUserInfo_returnsNilForWrongType() {
        XCTAssertNil(AlarmManager.shared.intFromUserInfo(["targetReps": "seven"], key: "targetReps"))
    }

    func test_alarmFromNotificationContent_returnsNilWhenAlarmIdMissing() {
        let content = makeContent(userInfo: [
            "exerciseType": "Push-Ups",
            "targetReps": 5,
            "soundName": "Beep"
        ])
        XCTAssertNil(AlarmManager.shared.alarmFromNotificationContent(content))
    }

    func test_alarmFromNotificationContent_returnsNilWhenExerciseTypeMissing() {
        let content = makeContent(userInfo: [
            "alarmId": "00000000-0000-0000-0000-000000000000",
            "targetReps": 5,
            "soundName": "Beep"
        ])
        XCTAssertNil(AlarmManager.shared.alarmFromNotificationContent(content))
    }

    func test_alarmFromNotificationContent_returnsNilWhenTargetRepsMissing() {
        let content = makeContent(userInfo: [
            "alarmId": "00000000-0000-0000-0000-000000000000",
            "exerciseType": "Push-Ups",
            "soundName": "Beep"
        ])
        XCTAssertNil(AlarmManager.shared.alarmFromNotificationContent(content))
    }

    func test_alarmFromNotificationContent_returnsNilWhenSoundNameMissing() {
        let content = makeContent(userInfo: [
            "alarmId": "00000000-0000-0000-0000-000000000000",
            "exerciseType": "Push-Ups",
            "targetReps": 5
        ])
        XCTAssertNil(AlarmManager.shared.alarmFromNotificationContent(content))
    }

    func test_alarmFromNotificationContent_returnsNilForMalformedUUID() {
        let content = makeContent(userInfo: [
            "alarmId": "not-a-uuid",
            "exerciseType": "Push-Ups",
            "targetReps": 5,
            "soundName": "Beep"
        ])
        XCTAssertNil(AlarmManager.shared.alarmFromNotificationContent(content))
    }

    func test_alarmFromNotificationContent_roundTripsAllFields() {
        let uuid = UUID()
        let content = makeContent(userInfo: [
            "alarmId": uuid.uuidString,
            "exerciseType": "Pull-Ups",
            "targetReps": 8,
            "soundName": "Chiptune"
        ])
        guard let alarm = AlarmManager.shared.alarmFromNotificationContent(content) else {
            return XCTFail("Expected non-nil reconstruction")
        }
        XCTAssertEqual(alarm.id, uuid)
        XCTAssertEqual(alarm.exerciseType, .pullUp)
        XCTAssertEqual(alarm.targetReps, 8)
        XCTAssertEqual(alarm.soundName, "Chiptune")
        // The reconstructed alarm is ephemeral: by convention the schedule path always
        // writes an empty repeatDays payload, so the rebuilt alarm's repeatDays should be
        // empty too (this is a load-bearing assumption — never `modelContext.insert` this).
        XCTAssertTrue(alarm.repeatDays.isEmpty)
        // Label is derived from the title by stripping the "⚡️ PULSEWAKE: " prefix.
        XCTAssertEqual(alarm.label, "Morning Alarm")
    }

    func test_alarmFromNotificationContent_acceptsNSNumberTargetReps() {
        let uuid = UUID()
        let content = makeContent(userInfo: [
            "alarmId": uuid.uuidString,
            "exerciseType": "Push-Ups",
            "targetReps": NSNumber(value: 6),
            "soundName": "Beep"
        ])
        XCTAssertEqual(AlarmManager.shared.alarmFromNotificationContent(content)?.targetReps, 6)
    }

    func test_alarmFromNotificationContent_fallsBackToPushUpForUnknownExerciseRaw() {
        // If somehow the raw string doesn't match "Push-Ups" or "Pull-Ups", the parser
        // falls back to .pushUp rather than returning nil — this preserves the alarm sound
        // + rep target even if the enum is malformed.
        let uuid = UUID()
        let content = makeContent(userInfo: [
            "alarmId": uuid.uuidString,
            "exerciseType": "Squats", // unknown
            "targetReps": 1,
            "soundName": "Beep"
        ])
        XCTAssertEqual(AlarmManager.shared.alarmFromNotificationContent(content)?.exerciseType, .pushUp)
    }
}
