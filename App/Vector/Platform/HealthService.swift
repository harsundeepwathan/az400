import Foundation
import HealthKit
import VectorCore

/// Apple Health bridge. The app works fully without it; when connected,
/// finished workouts are written to Health and body weight is read back.
protocol HealthSyncing: AnyObject {
    var isAvailable: Bool { get }
    func requestAuthorization() async throws
    func save(_ session: WorkoutSession) async throws
    func save(bodyWeight: BodyWeightEntry) async throws
    func bodyWeights(since date: Date) async throws -> [BodyWeightEntry]
}

final class HealthKitService: HealthSyncing {
    private let store = HKHealthStore()
    private let bodyMass = HKQuantityType(.bodyMass)

    var isAvailable: Bool { HKHealthStore.isHealthDataAvailable() }

    func requestAuthorization() async throws {
        guard isAvailable else { return }
        try await store.requestAuthorization(toShare: [HKObjectType.workoutType(), bodyMass], read: [bodyMass])
    }

    func save(_ session: WorkoutSession) async throws {
        guard isAvailable, let end = session.endedAt else { return }
        let configuration = HKWorkoutConfiguration()
        configuration.activityType = .traditionalStrengthTraining
        configuration.locationType = .indoor
        let builder = HKWorkoutBuilder(healthStore: store, configuration: configuration, device: .local())
        try await builder.beginCollection(at: session.startedAt)
        try await builder.addMetadata([HKMetadataKeyWorkoutBrandName: "Vector", "VectorWorkoutName": session.name])
        try await builder.endCollection(at: end)
        _ = try await builder.finishWorkout()
    }

    func save(bodyWeight: BodyWeightEntry) async throws {
        guard isAvailable else { return }
        let quantity = HKQuantity(unit: .gramUnit(with: .kilo), doubleValue: bodyWeight.kilograms)
        let sample = HKQuantitySample(type: bodyMass, quantity: quantity, start: bodyWeight.date, end: bodyWeight.date)
        try await store.save(sample)
    }

    func bodyWeights(since date: Date) async throws -> [BodyWeightEntry] {
        guard isAvailable else { return [] }
        let descriptor = HKSampleQueryDescriptor(
            predicates: [.quantitySample(type: bodyMass, predicate: HKQuery.predicateForSamples(withStart: date, end: nil))],
            sortDescriptors: [SortDescriptor(\.startDate, order: .forward)]
        )
        let samples = try await descriptor.result(for: store)
        return samples.map {
            BodyWeightEntry(date: $0.startDate, kilograms: $0.quantity.doubleValue(for: .gramUnit(with: .kilo)))
        }
    }
}
