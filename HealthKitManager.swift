import Foundation
import HealthKit

final class HealthKitManager {
    static let shared = HealthKitManager()
    private let healthStore = HKHealthStore()
    private init() {}

    func requestAuthorization() async throws {
        guard HKHealthStore.isHealthDataAvailable() else {
            throw NSError(domain: "HealthKit", code: 1, userInfo: [NSLocalizedDescriptionKey: "Health data not available on this device."])
        }

        let readTypes: Set<HKObjectType> = [
            HKObjectType.workoutType(),
            HKObjectType.quantityType(forIdentifier: .heartRate)!
        ]

        try await healthStore.requestAuthorization(toShare: [], read: readTypes)
    }

    func fetchMostRecentWorkout() async throws -> HKWorkout? {
        let workoutType = HKObjectType.workoutType()
        let sort = NSSortDescriptor(key: HKSampleSortIdentifierEndDate, ascending: false)
        let predicate: NSPredicate? = nil

        return try await withCheckedThrowingContinuation { continuation in
            let query = HKSampleQuery(sampleType: workoutType,
                                      predicate: predicate,
                                      limit: 1,
                                      sortDescriptors: [sort]) { _, samples, error in
                if let error = error {
                    continuation.resume(throwing: error)
                    return
                }
                let workout = samples?.first as? HKWorkout
                continuation.resume(returning: workout)
            }
            healthStore.execute(query)
        }
    }

    private func predicate(for workout: HKWorkout) -> NSPredicate {
        return HKQuery.predicateForSamples(withStart: workout.startDate, end: workout.endDate, options: .strictStartDate)
    }

    struct HeartRateStats {
        let averageBPM: Double?
        let maxBPM: Double?
        let minBPM: Double?
        let sampleCount: Int
    }

    func fetchHeartRateStats(during workout: HKWorkout) async throws -> HeartRateStats {
        guard let hrType = HKObjectType.quantityType(forIdentifier: .heartRate) else {
            throw NSError(domain: "HealthKit", code: 2, userInfo: [NSLocalizedDescriptionKey: "Heart rate type unavailable."])
        }

        let predicate = predicate(for: workout)
        let unit = HKUnit.count().unitDivided(by: HKUnit.minute())

        return try await withCheckedThrowingContinuation { continuation in
            let query = HKSampleQuery(sampleType: hrType,
                                      predicate: predicate,
                                      limit: HKObjectQueryNoLimit,
                                      sortDescriptors: nil) { _, samples, error in
                if let error = error {
                    continuation.resume(throwing: error)
                    return
                }

                let quantitySamples = (samples as? [HKQuantitySample]) ?? []
                let values: [Double] = quantitySamples.map { $0.quantity.doubleValue(for: unit) }

                let count = values.count
                let avg = count > 0 ? values.reduce(0, +) / Double(count) : nil
                let max = values.max()
                let min = values.min()

                continuation.resume(returning: HeartRateStats(averageBPM: avg, maxBPM: max, minBPM: min, sampleCount: count))
            }
            healthStore.execute(query)
        }
    }
}
