import Foundation
import HealthKit

@Observable
public final class HealthKitManager {
    public static let shared = HealthKitManager()

    public private(set) var isAuthorized = false
    public private(set) var todayStepCount: Int = 0

    private let store = HKHealthStore()

    private init() {}

    public var isAvailable: Bool {
        HKHealthStore.isHealthDataAvailable()
    }

    public func requestAuthorization(completion: @escaping (Bool) -> Void = { _ in }) {
        guard isAvailable else {
            DispatchQueue.main.async { completion(false) }
            return
        }

        let typesToRead: Set<HKObjectType> = [
            HKObjectType.quantityType(forIdentifier: .stepCount)!,
            HKObjectType.quantityType(forIdentifier: .activeEnergyBurned)!,
            HKObjectType.workoutType()
        ]
        let typesToWrite: Set<HKSampleType> = [
            HKObjectType.quantityType(forIdentifier: .stepCount)!,
            HKObjectType.workoutType()
        ]

        store.requestAuthorization(toShare: typesToWrite, read: typesToRead) { [weak self] success, _ in
            DispatchQueue.main.async {
                self?.isAuthorized = success
                if success {
                    self?.enableBackgroundStepDelivery()
                    self?.refreshTodayStepCount()
                }
                completion(success)
            }
        }
    }

    public func refreshTodayStepCount() {
        guard isAvailable,
              let stepType = HKQuantityType.quantityType(forIdentifier: .stepCount) else { return }

        let start = Calendar.current.startOfDay(for: Date())
        let predicate = HKQuery.predicateForSamples(withStart: start, end: Date(), options: .strictStartDate)

        let query = HKStatisticsQuery(
            quantityType: stepType,
            quantitySamplePredicate: predicate,
            options: .cumulativeSum
        ) { [weak self] _, result, _ in
            let steps = result?.sumQuantity()?.doubleValue(for: .count()) ?? 0
            DispatchQueue.main.async {
                self?.todayStepCount = Int(steps.rounded())
            }
        }
        store.execute(query)
    }

    public func saveCompletedWorkout(
        exerciseType: ExerciseType,
        reps: Int,
        durationSeconds: TimeInterval,
        sessionSteps: Int,
        startDate: Date
    ) {
        guard isAvailable, isAuthorized else { return }

        let endDate = startDate.addingTimeInterval(durationSeconds)
        let activity: HKWorkoutActivityType = exerciseType == .pushUp
            ? .traditionalStrengthTraining
            : .functionalStrengthTraining

        let metadata: [String: Any] = [
            HKMetadataKeyWorkoutBrandName: "PulseWake",
            "PulseWakeExercise": exerciseType.rawValue,
            "PulseWakeReps": reps,
            "PulseWakeSessionSteps": sessionSteps
        ]

        let workout = HKWorkout(
            activityType: activity,
            start: startDate,
            end: endDate,
            duration: durationSeconds,
            totalEnergyBurned: nil,
            totalDistance: nil,
            metadata: metadata
        )

        store.save(workout) { success, error in
            if let error {
                print("HealthKit workout save failed: \(error)")
            } else if success, sessionSteps > 0,
                      let stepType = HKQuantityType.quantityType(forIdentifier: .stepCount) {
                let quantity = HKQuantity(unit: .count(), doubleValue: Double(sessionSteps))
                let sample = HKQuantitySample(
                    type: stepType,
                    quantity: quantity,
                    start: startDate,
                    end: endDate,
                    metadata: ["PulseWakeSource": "session_pedometer"]
                )
                self.store.save(sample) { _, err in
                    if let err { print("HealthKit step sample save failed: \(err)") }
                }
            }
        }
    }

    private func enableBackgroundStepDelivery() {
        guard let stepType = HKQuantityType.quantityType(forIdentifier: .stepCount) else { return }
        store.enableBackgroundDelivery(for: stepType, frequency: .hourly) { success, error in
            if let error {
                print("HealthKit background delivery failed: \(error)")
            } else if success {
                self.observeStepCountChanges(stepType: stepType)
            }
        }
    }

    private func observeStepCountChanges(stepType: HKQuantityType) {
        let query = HKObserverQuery(sampleType: stepType, predicate: nil) { [weak self] _, _, error in
            if error == nil {
                self?.refreshTodayStepCount()
            }
        }
        store.execute(query)
    }
}
