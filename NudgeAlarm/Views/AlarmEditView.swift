import SwiftUI
import SwiftData

public struct AlarmEditView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    
    public var alarmToEdit: AlarmModel?
    
    @State private var time: Date = Date()
    @State private var label: String = "Morning Wake Up"
    @State private var selectedExercise: ExerciseType = .pushUp
    @State private var targetReps: Int = 10
    @State private var selectedDays: Set<Int> = [2, 3, 4, 5, 6] // Mon-Fri default
    @State private var soundName: String = "Radar Loud"
    
    private let dayLabels = [
        (1, "Sun"), (2, "Mon"), (3, "Tue"), (4, "Wed"), (5, "Thu"), (6, "Fri"), (7, "Sat")
    ]
    
    public init(alarmToEdit: AlarmModel? = nil) {
        self.alarmToEdit = alarmToEdit
    }
    
    public var body: some View {
        NavigationStack {
            Form {
                // Time Picker
                Section {
                    #if os(iOS)
                    DatePicker("Alarm Time", selection: $time, displayedComponents: .hourAndMinute)
                        .datePickerStyle(.wheel)
                        .labelsHidden()
                        .frame(maxWidth: .infinity)
                    #else
                    DatePicker("Alarm Time", selection: $time, displayedComponents: .hourAndMinute)
                    #endif
                } header: {
                    Text("Time")
                }
                
                // Details
                Section {
                    HStack {
                        Text("Label")
                        Spacer()
                        TextField("Alarm Name", text: $label)
                            .multilineTextAlignment(.trailing)
                            .foregroundColor(.gray)
                    }
                    
                    Picker("Verification Action", selection: $selectedExercise) {
                        ForEach(ExerciseType.allCases) { type in
                            Label(type.rawValue, systemImage: type.iconName)
                                .tag(type)
                        }
                    }
                    
                    Stepper(value: $targetReps, in: 3...50, step: 1) {
                        HStack {
                            Text("Target Reps")
                            Spacer()
                            Text("\(targetReps) reps")
                                .bold()
                                .foregroundColor(.cyan)
                        }
                    }
                } header: {
                    Text("Nudge Exercise Configuration")
                } footer: {
                    Text(selectedExercise.instructions)
                        .font(.caption)
                }
                
                // Repeat Schedule
                Section {
                    HStack {
                        ForEach(dayLabels, id: \.0) { day, name in
                            let isSelected = selectedDays.contains(day)
                            Text(name)
                                .font(.system(size: 13, weight: .bold))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 8)
                                .background(isSelected ? Color.cyan : Color.gray.opacity(0.2))
                                .foregroundColor(isSelected ? .black : .primary)
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                                .onTapGesture {
                                    if isSelected {
                                        selectedDays.remove(day)
                                    } else {
                                        selectedDays.insert(day)
                                    }
                                }
                        }
                    }
                    .padding(.vertical, 4)
                } header: {
                    Text("Repeat Days")
                }
            }
            .navigationTitle(alarmToEdit == nil ? "New Nudge Alarm" : "Edit Alarm")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        saveAlarm()
                    }
                    .bold()
                    .foregroundColor(.cyan)
                }
            }
            .onAppear {
                if let alarm = alarmToEdit {
                    self.time = alarm.time
                    self.label = alarm.label
                    self.selectedExercise = alarm.exerciseType
                    self.targetReps = alarm.targetReps
                    self.selectedDays = alarm.repeatDays
                    self.soundName = alarm.soundName
                }
            }
        }
    }
    
    private func saveAlarm() {
        if let alarm = alarmToEdit {
            alarm.time = time
            alarm.label = label
            alarm.exerciseType = selectedExercise
            alarm.targetReps = targetReps
            alarm.repeatDays = selectedDays
            alarm.soundName = soundName
            AlarmManager.shared.scheduleAlarm(alarm)
        } else {
            let newAlarm = AlarmModel(
                time: time,
                label: label.isEmpty ? "Alarm" : label,
                exerciseType: selectedExercise,
                targetReps: targetReps,
                isEnabled: true,
                repeatDays: selectedDays,
                soundName: soundName
            )
            modelContext.insert(newAlarm)
            AlarmManager.shared.scheduleAlarm(newAlarm)
        }
        
        try? modelContext.save()
        dismiss()
    }
}
