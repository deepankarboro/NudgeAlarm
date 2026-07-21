import SwiftUI
import SwiftData

@main
struct NudgeAlarmApp: App {
    var sharedModelContainer: ModelContainer = {
        let schema = Schema([
            AlarmModel.self,
            WorkoutHistoryModel.self
        ])
        let modelConfiguration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)

        do {
            return try ModelContainer(for: schema, configurations: [modelConfiguration])
        } catch {
            fatalError("Could not create ModelContainer: \(error)")
        }
    }()

    var body: some Scene {
        WindowGroup {
            DashboardView()
                .preferredColorScheme(.dark)
        }
        .modelContainer(sharedModelContainer)
    }
}
