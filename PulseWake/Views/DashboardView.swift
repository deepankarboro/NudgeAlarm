import SwiftUI
import SwiftData

public struct DashboardView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \AlarmModel.time) private var alarms: [AlarmModel]
    
    @State private var showingAddAlarmSheet = false
    @State private var alarmToEdit: AlarmModel?
    @State private var showingStatsSheet = false
    @State private var hasRequestedPermissions = false
    
    private var nextActiveAlarm: AlarmModel? {
        alarms.first(where: { $0.isEnabled })
    }
    
    public var body: some View {
        NavigationStack {
            ZStack {
                // Background Gradient
                LinearGradient(
                    colors: [Color.black, Color(red: 0.05, green: 0.08, blue: 0.15)],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .ignoresSafeArea()
                
                VStack(spacing: 20) {
                    // Next Alarm Countdown Header Banner
                    if let nextAlarm = nextActiveAlarm {
                        VStack(spacing: 12) {
                            HStack {
                                Label("NEXT ACTIVE NUDGE", systemImage: "alarm.fill")
                                    .font(.caption.weight(.bold))
                                    .foregroundColor(.cyan)
                                Spacer()
                                Text(nextAlarm.exerciseType.rawValue)
                                    .font(.caption.bold())
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 4)
                                    .background(Color.cyan.opacity(0.2))
                                    .foregroundColor(.cyan)
                                    .clipShape(Capsule())
                            }
                            
                            HStack(alignment: .firstTextBaseline) {
                                Text(nextAlarm.formattedTime)
                                    .font(.system(size: 44, weight: .bold, design: .rounded))
                                    .foregroundColor(.white)
                                
                                Spacer()
                                
                                VStack(alignment: .trailing, spacing: 2) {
                                    Text("\(nextAlarm.targetReps) Reps Required")
                                        .font(.subheadline.bold())
                                        .foregroundColor(.green)
                                    Text(nextAlarm.repeatDaysSummary)
                                        .font(.caption)
                                        .foregroundColor(.gray)
                                }
                            }
                        }
                        .padding(20)
                        .background(.ultraThinMaterial)
                        .cornerRadius(20)
                        .overlay(
                            RoundedRectangle(cornerRadius: 20)
                                .stroke(LinearGradient(colors: [.cyan.opacity(0.6), .blue.opacity(0.2)], startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 1.5)
                        )
                        .padding(.horizontal, 16)
                    }
                    
                    // Alarms List Section
                    List {
                        Section(header: Text("Scheduled Alarms").font(.caption.bold()).foregroundColor(.gray)) {
                            if alarms.isEmpty {
                                VStack(spacing: 12) {
                                    Image(systemName: "alarm")
                                        .font(.system(size: 40))
                                        .foregroundColor(.gray)
                                    Text("No Alarms Scheduled")
                                        .font(.headline)
                                        .foregroundColor(.white)
                                    Text("Tap '+' to set a new motion-verified wake up alarm.")
                                        .font(.caption)
                                        .foregroundColor(.gray)
                                        .multilineTextAlignment(.center)
                                }
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 24)
                                .listRowBackground(Color.clear)
                            } else {
                                // Endpoint D: snapshot the live `@Query` array so a
                                // notification-driven SwiftData invalidation mid-render
                                // cannot mutate the iteration source and trigger an
                                // out-of-bounds access while we're rendering rows.
                                ForEach(Array(alarms)) { alarm in
                                    AlarmRowView(alarm: alarm) {
                                        alarmToEdit = alarm
                                    } toggleAction: {
                                        // Do NOT flip `isEnabled` here — the Toggle's binding has
                                        // already applied the user's change. Flipping it again used
                                        // to fight the binding and spin forever. `scheduleAlarm`
                                        // reads the new value and cancels or schedules accordingly.
                                        AlarmManager.shared.scheduleAlarm(alarm)
                                        try? modelContext.save()
                                    }
                                    .listRowBackground(Color.white.opacity(0.05))
                                }
                                .onDelete(perform: deleteAlarms)
                            }
                        }
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                    
                    // Instant Test Exercise Verification Button
                    Button(action: startFullAlarmFlowTest) {
                        HStack(spacing: 10) {
                            Image(systemName: "play.circle.fill")
                                .font(.title3)
                            Text("Test Full Alarm Flow Now")
                                .font(.subheadline.bold())
                        }
                        .foregroundColor(.black)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                        .background(LinearGradient(colors: [.cyan, Color(red: 0.2, green: 0.9, blue: 0.7)], startPoint: .leading, endPoint: .trailing))
                        .cornerRadius(16)
                        .shadow(color: .cyan.opacity(0.4), radius: 10, x: 0, y: 4)
                        .padding(.horizontal, 16)
                        .padding(.bottom, 10)
                    }
                }
            }
            .navigationTitle("PulseWake")
            .toolbar {
                #if os(iOS)
                ToolbarItem(placement: .topBarLeading) {
                    Button(action: {
                        showingStatsSheet = true
                    }) {
                        Image(systemName: "chart.bar.fill")
                            .foregroundColor(.cyan)
                    }
                }
                
                ToolbarItem(placement: .topBarTrailing) {
                    Button(action: {
                        showingAddAlarmSheet = true
                    }) {
                        Image(systemName: "plus.circle.fill")
                            .font(.title2)
                            .foregroundColor(.cyan)
                    }
                }
                #else
                ToolbarItem(placement: .automatic) {
                    Button(action: {
                        showingStatsSheet = true
                    }) {
                        Image(systemName: "chart.bar.fill")
                    }
                }
                #endif
            }
            .sheet(isPresented: $showingAddAlarmSheet) {
                AlarmEditView()
            }
            .sheet(item: $alarmToEdit) { alarm in
                AlarmEditView(alarmToEdit: alarm)
            }
            .sheet(isPresented: $showingStatsSheet) {
                StatsView()
            }
        }
        .onAppear {
            guard !hasRequestedPermissions else { return }
            hasRequestedPermissions = true
            requestPermissionsInSequence()
        }
    }

    /// Chains the four permission requests so each dialog waits for the previous answer.
    /// Firing them together stacked notifications, HealthKit, microphone, and AlarmKit on top
    /// of one another, and the user could not read what they were agreeing to.
    private func requestPermissionsInSequence() {
        AlarmManager.shared.requestPermissions { _ in
            WorkoutSensorHub.shared.requestPermissions {
                #if canImport(AlarmKit)
                if #available(iOS 26.1, *) {
                    Task { await PulseWakeAlarmKitScheduler.requestAuthorization() }
                }
                #endif
            }
        }
    }

    private func startFullAlarmFlowTest() {
        let alarm = nextActiveAlarm
        let testAlarm = AlarmModel(
            label: alarm.map { "Test: \($0.label)" } ?? "Test Alarm Run",
            exerciseType: alarm?.exerciseType ?? .pushUp,
            targetReps: alarm?.targetReps ?? 5,
            isEnabled: true,
            repeatDays: [],
            soundName: alarm?.soundName ?? "Beep"
        )
        AlarmManager.shared.startRinging(alarm: testAlarm)
    }

    private func deleteAlarms(at offsets: IndexSet) {
        for index in offsets {
            let alarm = alarms[index]
            AlarmManager.shared.cancelAlarm(alarm)
            modelContext.delete(alarm)
        }
        try? modelContext.save()
    }
}

public struct AlarmRowView: View {
    @Bindable var alarm: AlarmModel
    public let onEdit: () -> Void
    public let toggleAction: () -> Void
    
    public var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(alarm.formattedTime)
                        .font(.system(size: 32, weight: .bold, design: .rounded))
                        .foregroundColor(alarm.isEnabled ? .white : .gray)
                    
                    Text(alarm.label)
                        .font(.subheadline)
                        .foregroundColor(.gray)
                }
                
                HStack(spacing: 8) {
                    Label("\(alarm.targetReps) \(alarm.exerciseType.rawValue)", systemImage: alarm.exerciseType.iconName)
                        .font(.caption.bold())
                        .foregroundColor(alarm.isEnabled ? .cyan : .gray)
                    
                    Text("•")
                        .foregroundColor(.gray)
                    
                    Text(alarm.repeatDaysSummary)
                        .font(.caption)
                        .foregroundColor(.gray)
                }
            }
            
            Spacer()
            
            // The side effect runs in the binding's setter rather than via `.onChange`, so the
            // model is written exactly once per tap and there is no change-notification path
            // back into this view. An `.onChange` here would also re-fire for changes made
            // anywhere else (SwiftData refresh, edit sheet), re-scheduling the alarm needlessly.
            Toggle("", isOn: Binding(
                get: { alarm.isEnabled },
                set: { newValue in
                    guard newValue != alarm.isEnabled else { return }
                    alarm.isEnabled = newValue
                    toggleAction()
                }
            ))
            .labelsHidden()
            .tint(.cyan)
        }
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .onTapGesture {
            onEdit()
        }
    }
}
