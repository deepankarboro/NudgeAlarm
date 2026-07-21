import SwiftUI
import SwiftData

public struct StatsView: View {
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \WorkoutHistoryModel.timestamp, order: .reverse) private var logs: [WorkoutHistoryModel]
    
    private var totalPushUps: Int {
        logs.filter { $0.exerciseType == .pushUp }.reduce(0) { $0 + $1.completedReps }
    }
    
    private var totalPullUps: Int {
        logs.filter { $0.exerciseType == .pullUp }.reduce(0) { $0 + $1.completedReps }
    }
    
    private var totalAlarmsDefeated: Int {
        logs.count
    }
    
    public var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()
                
                ScrollView {
                    VStack(spacing: 20) {
                        // Metric Cards Header
                        HStack(spacing: 12) {
                            StatCard(title: "Push-Ups", value: "\(totalPushUps)", icon: "figure.pushups", color: .cyan)
                            StatCard(title: "Pull-Ups", value: "\(totalPullUps)", icon: "figure.pullups", color: .green)
                            StatCard(title: "Alarms Defeated", value: "\(totalAlarmsDefeated)", icon: "checkmark.seal.fill", color: .orange)
                        }
                        .padding(.horizontal, 16)
                        .padding(.top, 10)
                        
                        // Recent Workout History
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Workout & Alarm Logs")
                                .font(.headline)
                                .foregroundColor(.white)
                                .padding(.horizontal, 16)
                            
                            if logs.isEmpty {
                                VStack(spacing: 8) {
                                    Image(systemName: "clock.badge.exclamationmark")
                                        .font(.system(size: 36))
                                        .foregroundColor(.gray)
                                    Text("No workout logs yet")
                                        .font(.subheadline)
                                        .foregroundColor(.gray)
                                }
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 40)
                            } else {
                                ForEach(logs) { log in
                                    HStack {
                                        Image(systemName: log.exerciseType.iconName)
                                            .font(.title2)
                                            .foregroundColor(.cyan)
                                            .frame(width: 40)
                                        
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text("\(log.completedReps) \(log.exerciseType.rawValue)")
                                                .font(.subheadline.bold())
                                                .foregroundColor(.white)
                                            Text(log.formattedDate)
                                                .font(.caption)
                                                .foregroundColor(.gray)
                                        }
                                        
                                        Spacer()
                                        
                                        Text(log.formattedDuration)
                                            .font(.caption.monospaced())
                                            .padding(.horizontal, 10)
                                            .padding(.vertical, 4)
                                            .background(Color.white.opacity(0.1))
                                            .foregroundColor(.green)
                                            .clipShape(Capsule())
                                    }
                                    .padding(16)
                                    .background(.ultraThinMaterial)
                                    .cornerRadius(12)
                                    .padding(.horizontal, 16)
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Nudge Metrics")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        dismiss()
                    }
                    .bold()
                    .foregroundColor(.cyan)
                }
            }
        }
    }
}

public struct StatCard: View {
    public let title: String
    public let value: String
    public let icon: String
    public let color: Color
    
    public var body: some View {
        VStack(spacing: 8) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundColor(color)
            
            Text(value)
                .font(.title.bold())
                .foregroundColor(.white)
            
            Text(title)
                .font(.caption2.bold())
                .foregroundColor(.gray)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 16)
        .background(.ultraThinMaterial)
        .cornerRadius(16)
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(color.opacity(0.3), lineWidth: 1)
        )
    }
}
