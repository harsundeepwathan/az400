import Foundation

/// Matches exercise names from other apps ("Bench Press (Barbell)",
/// "Lat Pulldown - Cable") to Vector's catalog by their words, and guesses
/// equipment and muscle for names it can't match, so they can become custom
/// exercises instead of being dropped.
public struct ExerciseMatcher: Sendable {
    public let catalog: ExerciseCatalog
    /// Minimum word overlap (Jaccard) to call two names the same exercise.
    public var threshold: Double = 0.6

    public init(catalog: ExerciseCatalog) {
        self.catalog = catalog
    }

    static let equipmentWords: [String: Equipment] = [
        "barbell": .barbell, "bb": .barbell, "dumbbell": .dumbbell, "dumbbells": .dumbbell, "db": .dumbbell,
        "machine": .machine, "smith": .machine, "cable": .cable, "cables": .cable, "kettlebell": .kettlebell, "kb": .kettlebell,
        "band": .band, "bands": .band, "bodyweight": .bodyweight, "assisted": .bodyweight
    ]
    static let synonyms: [String: String] = [
        "dumbbells": "dumbbell", "db": "dumbbell", "bb": "barbell", "kb": "kettlebell", "cables": "cable",
        "pulldown": "pulldown", "pull": "pull", "ups": "up", "pushups": "push", "pullups": "pull", "chinups": "chin",
        "rdl": "romanian", "ohp": "overhead", "flyes": "fly", "flys": "fly", "raises": "raise", "curls": "curl",
        "extensions": "extension", "rows": "row", "presses": "press", "squats": "squat", "lunges": "lunge"
    ]

    static func words(_ name: String) -> [String] {
        let lowered = name.lowercased()
            .replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: "/", with: " ")
        let raw = lowered.components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
        return raw.map { synonyms[$0] ?? $0 }
    }

    /// The catalog exercise this name means, or nil.
    public func match(_ name: String) -> Exercise? {
        let target = Set(Self.words(name))
        guard !target.isEmpty else { return nil }
        let targetEquipment = target.compactMap { Self.equipmentWords[$0] }.first
        if let exact = catalog.all.first(where: { Set(Self.words($0.name)) == target }) { return exact }
        var best: (exercise: Exercise, score: Double)?
        for exercise in catalog.all {
            var words = Set(Self.words(exercise.name))
            // Catalog names often leave the equipment implicit ("Bench Press" is a barbell lift).
            if targetEquipment == exercise.equipment { words.insert(exercise.equipment.rawValue) }
            if let targetEquipment, targetEquipment != exercise.equipment { continue }
            let score = Double(words.intersection(target).count) / Double(words.union(target).count)
            if score > (best?.score ?? 0) || (score == best?.score && exercise.isCurated && !(best?.exercise.isCurated ?? true)) {
                best = (exercise, score)
            }
        }
        guard let best, best.score >= threshold else { return nil }
        return best.exercise
    }

    public static func guessEquipment(_ name: String) -> Equipment {
        words(name).compactMap { equipmentWords[$0] }.first ?? .other
    }

    public static func guessMuscle(_ name: String) -> MuscleGroup {
        let w = Set(words(name))
        let rules: [([String], MuscleGroup)] = [
            (["calf", "calves"], .calves), (["curl"], .biceps),
            (["tricep", "triceps", "pushdown", "skullcrusher", "dip"], .triceps),
            (["hamstring", "romanian", "deadlift", "leg curl"], .hamstrings),
            (["glute", "hip", "thrust", "bridge"], .glutes),
            (["squat", "leg", "lunge", "quad", "quads"], .quads),
            (["bench", "chest", "fly", "push"], .chest),
            (["row", "pulldown", "pull", "lat", "chin", "back"], .back),
            (["shoulder", "overhead", "lateral", "raise", "military", "arnold", "delt"], .shoulders),
            (["crunch", "plank", "ab", "abs", "core", "sit"], .core),
            (["wrist", "forearm"], .forearms)
        ]
        for (keys, muscle) in rules where keys.contains(where: { w.contains($0) }) { return muscle }
        return .core
    }
}
