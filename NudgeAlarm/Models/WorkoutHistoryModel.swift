import Foundation
import SwiftData

/// SwiftData model representing completed workout verification logs when an alarm is dismissed.
@Model
public final class WorkoutHistoryModel: Identifiable {
    public var id: UUID
    public var timestamp: Date
    public var alarmLabel: String
    public var exerciseTypeRaw: String
    public var completedReps: Int
    public var durationSeconds: Double
    
    public init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        alarmLabel: String,
        exerciseType: ExerciseType,
        completedReps: Int,
        durationSeconds: Double
    ) {
        self.id = id
        self.timestamp = timestamp
        self.alarmLabel = alarmLabel
        self.exerciseTypeRaw = exerciseType.rawValue
        self.completedReps = completedReps
        self.durationSeconds = durationSeconds
    }
    
    public var exerciseType: ExerciseType {
        ExerciseType(rawValue: exerciseTypeRaw) ?? .pushUp
    }
    
    public var formattedDate: String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: timestamp)
    }
    
    public var formattedDuration: String {
        let seconds = Int(durationSeconds)
        let mins = seconds / 60
        let secs = seconds % 60
        if mins > 0 {
            return "\(mins)m \(secs)s"
        }
        return "\(secs)s"
    }
}
