import Foundation
import SwiftData

/// Represents the type of exercise required to turn off an alarm.
public enum ExerciseType: String, Codable, CaseIterable, Identifiable {
    case pushUp = "Push-Ups"
    case pullUp = "Pull-Ups"
    
    public var id: String { self.rawValue }
    
    public var iconName: String {
        switch self {
        case .pushUp: return "figure.pushups"
        case .pullUp: return "figure.pullups"
        }
    }
    
    public var instructions: String {
        switch self {
        case .pushUp:
            return "Place your phone on the floor facing you. Lower your chest until your elbows bend under 90°, then push back up."
        case .pullUp:
            return "Prop your phone up facing your pull-up bar. Hang fully, then pull up until your chin passes your wrists."
        }
    }
}

/// SwiftData model representing a scheduled alarm with motion verification.
@Model
public final class AlarmModel: Identifiable {
    public var id: UUID
    public var time: Date
    public var label: String
    public var exerciseTypeRaw: String
    public var targetReps: Int
    public var isEnabled: Bool
    public var repeatDaysRaw: String // Comma-separated integers e.g. "1,2,3,4,5"
    public var soundName: String
    public var createdAt: Date
    
    public init(
        id: UUID = UUID(),
        time: Date = Date(),
        label: String = "Morning Wake Up",
        exerciseType: ExerciseType = .pushUp,
        targetReps: Int = 10,
        isEnabled: Bool = true,
        repeatDays: Set<Int> = [2, 3, 4, 5, 6], // Mon-Fri
        soundName: String = "Radar Emergency",
        createdAt: Date = Date()
    ) {
        self.id = id
        self.time = time
        self.label = label
        self.exerciseTypeRaw = exerciseType.rawValue
        self.targetReps = targetReps
        self.isEnabled = isEnabled
        self.repeatDaysRaw = repeatDays.map { String($0) }.joined(separator: ",")
        self.soundName = soundName
        self.createdAt = createdAt
    }
    
    public var exerciseType: ExerciseType {
        get { ExerciseType(rawValue: exerciseTypeRaw) ?? .pushUp }
        set { exerciseTypeRaw = newValue.rawValue }
    }
    
    public var repeatDays: Set<Int> {
        get {
            let items = repeatDaysRaw.split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
            return Set(items)
        }
        set {
            repeatDaysRaw = newValue.sorted().map { String($0) }.joined(separator: ",")
        }
    }
    
    public var formattedTime: String {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        return formatter.string(from: time)
    }
    
    public var repeatDaysSummary: String {
        if repeatDays.count == 7 { return "Every day" }
        if repeatDays.isEmpty { return "Never" }
        if repeatDays == [2, 3, 4, 5, 6] { return "Weekdays" }
        if repeatDays == [1, 7] { return "Weekends" }
        
        let dayNames = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
        let sorted = repeatDays.sorted()
        return sorted.map { dayNames[$0 - 1] }.joined(separator: ", ")
    }
}
