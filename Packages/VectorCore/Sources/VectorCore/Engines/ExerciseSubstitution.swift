import Foundation

public struct Substitution: Identifiable, Hashable, Sendable {
    public var exercise: Exercise
    public var score: Int
    public var reasons: [String]
    public var id: String { exercise.id }
}

/// Ranks replacement exercises the way a coach would: same movement first,
/// then the same muscles, limited to equipment the athlete actually has and
/// excluding anything they've marked to avoid.
public struct ExerciseSubstitutionEngine: Sendable {
    public let catalog: ExerciseCatalog

    public init(catalog: ExerciseCatalog = .standard) {
        self.catalog = catalog
    }

    public func alternatives(
        for exercise: Exercise,
        availableEquipment: Set<Equipment> = Set(Equipment.allCases),
        avoiding avoided: Set<String> = [],
        excluding excluded: Set<String> = [],
        limit: Int = 6
    ) -> [Substitution] {
        catalog.all
            .filter { $0.id != exercise.id && !avoided.contains($0.id) && !excluded.contains($0.id) }
            .filter { availableEquipment.contains($0.equipment) }
            .compactMap { candidate -> Substitution? in
                var score = 0
                var reasons: [String] = []
                let primaryOverlap = Set(candidate.primaryMuscles).intersection(exercise.primaryMuscles)
                if candidate.pattern == exercise.pattern {
                    score += 6
                    reasons.append("Same \(exercise.pattern.displayName.lowercased()) pattern")
                }
                if !primaryOverlap.isEmpty {
                    score += 3 * primaryOverlap.count
                    let names = exercise.primaryMuscles.filter(primaryOverlap.contains).map(\.displayName)
                    reasons.append("Targets " + names.joined(separator: " & ").lowercased())
                } else if !Set(candidate.secondaryMuscles).intersection(exercise.primaryMuscles).isEmpty {
                    score += 1
                }
                guard score >= 3 else { return nil }
                if candidate.isCompound == exercise.isCompound { score += 1 }
                if candidate.equipment == exercise.equipment {
                    score += 1
                } else {
                    reasons.append("Uses \(candidate.equipment.displayName.lowercased())")
                }
                return Substitution(exercise: candidate, score: score, reasons: reasons)
            }
            .sorted { $0.score == $1.score ? $0.exercise.name < $1.exercise.name : $0.score > $1.score }
            .prefix(limit)
            .map { $0 }
    }
}
