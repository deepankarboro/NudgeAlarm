import SwiftUI
import SwiftData

public struct DashboardView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \AlarmModel.time) private var alarms: [AlarmModel]
    
    @State private var showingAddAlarmSheet = false
    @State private var alarmToEdit: AlarmModel?
    @State private var activeVerificationTest: (ExerciseType, Int, String)?
    @State private var showingStatsSheet = false
    
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
                                ForEach(alarms) { alarm in
                                    AlarmRowView(alarm: alarm) {
                                        alarmToEdit = alarm
                                    } toggleAction: {
                                        alarm.isEnabled.toggle()
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
                    Button(action: {
                        // Launch interactive test using current settings or default 5 pushups
                        let type = nextActiveAlarm?.exerciseType ?? .pushUp
                        let reps = 5
                        activeVerificationTest = (type, reps, "Test Alarm Run")
                    }) {
                        HStack(spacing: 10) {
                            Image(systemName: "play.circle.fill")
                                .font(.title3)
                            Text("Test Exercise Camera Verification Now")
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
            .navigationTitle("NudgeAlarm")
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
            .fullScreenCover(item: Binding(
                get: { activeVerificationTest.map { IdentifiableTest(type: $0.0, reps: $0.1, label: $0.2) } },
                set: { if $0 == nil { activeVerificationTest = nil } }
            )) { test in
                ExerciseVerificationView(
                    exerciseType: test.type,
                    targetReps: test.reps,
                    alarmLabel: test.label,
                    onComplete: {
                        activeVerificationTest = nil
                    }
                )
            }
        }
        .onAppear {
            AlarmManager.shared.requestPermissions()
        }
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

public struct IdentifiableTest: Identifiable {
    public let id = UUID()
    public let type: ExerciseType
    public let reps: Int
    public let label: String
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
            
            Toggle("", isOn: $alarm.isEnabled)
                .labelsHidden()
                .tint(.cyan)
                .onChange(of: alarm.isEnabled) { _, _ in
                    toggleAction()
                }
        }
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .onTapGesture {
            onEdit()
        }
    }
}
