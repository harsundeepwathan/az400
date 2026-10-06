import Foundation

/// Read-only library of exercises, keyed by stable string ids so logged
/// history stays valid when names or instructions are edited.
public struct ExerciseCatalog: Sendable {
    public let all: [Exercise]
    private let byID: [String: Exercise]

    public init(_ exercises: [Exercise]) {
        all = exercises
        byID = Dictionary(exercises.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    }

    public subscript(id: String) -> Exercise? { byID[id] }

    /// Ranked search: name prefix beats word prefix beats substring, and the
    /// hand-curated core lifts rank above the long tail of the library.
    public func search(_ query: String) -> [Exercise] {
        let trimmed = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !trimmed.isEmpty else {
            return all.sorted { lhs, rhs in
                lhs.isCurated == rhs.isCurated ? lhs.name < rhs.name : lhs.isCurated
            }
        }
        var scored: [(exercise: Exercise, score: Int)] = []
        for exercise in all {
            let name = exercise.name.lowercased()
            var score = 0
            if name.hasPrefix(trimmed) {
                score = 30
            } else if name.contains(" " + trimmed) || name.contains("-" + trimmed) {
                score = 20
            } else if name.contains(trimmed) {
                score = 10
            } else if exercise.primaryMuscles.contains(where: { $0.displayName.lowercased().hasPrefix(trimmed) }) {
                score = 5
            }
            guard score > 0 else { continue }
            if exercise.isCurated { score += 8 }
            scored.append((exercise, score))
        }
        scored.sort { $0.score == $1.score ? $0.exercise.name < $1.exercise.name : $0.score > $1.score }
        return scored.map(\.exercise)
    }

    /// The hand-written core library plus the bundled public-domain import.
    /// Curated exercises keep their ids (history depends on them) and gain
    /// demonstration images from the import.
    public static let standard: ExerciseCatalog = {
        let bundled = BundledLibrary.load()
        let curated = library.map { exercise -> Exercise in
            var exercise = exercise
            exercise.images = bundled.curatedImages[exercise.id] ?? []
            return exercise
        }
        let curatedNames = Set(curated.map { $0.name.lowercased() })
        let imported = bundled.exercises.filter { !curatedNames.contains($0.name.lowercased()) }
        return ExerciseCatalog(curated + imported)
    }()

    /// Only the hand-written library, for tests that need stable fixtures.
    public static let curatedOnly = ExerciseCatalog(library)

    struct BundledLibrary: Decodable {
        var curatedImages: [String: [String]]
        var exercises: [Exercise]

        static func load() -> BundledLibrary {
            guard let url = Bundle.module.url(forResource: "exercises", withExtension: "json"),
                  let data = try? Data(contentsOf: url),
                  let library = try? JSONDecoder().decode(BundledLibrary.self, from: data) else {
                return BundledLibrary(curatedImages: [:], exercises: [])
            }
            return library
        }
    }

    // swiftlint:disable line_length
    static let library: [Exercise] = [
        // Squat pattern
        Exercise(id: "back-squat", name: "Back Squat", primaryMuscles: [.quads, .glutes], secondaryMuscles: [.hamstrings, .core], equipment: .barbell, pattern: .squat,
                 instructions: ["Set the bar on your upper back, just below the base of the neck.", "Brace your core, break at the hips and knees together.", "Descend until hips are at or below knee height.", "Drive up through the mid-foot, keeping the chest tall."],
                 defaultRestSeconds: 180, loadIncrement: 2.5, symbol: "figure.strengthtraining.traditional"),
        Exercise(id: "front-squat", name: "Front Squat", primaryMuscles: [.quads], secondaryMuscles: [.glutes, .core], equipment: .barbell, pattern: .squat,
                 instructions: ["Rack the bar on the front delts with elbows high.", "Sit straight down between the hips.", "Keep the torso upright and drive up."],
                 defaultRestSeconds: 180),
        Exercise(id: "hack-squat", name: "Hack Squat", primaryMuscles: [.quads], secondaryMuscles: [.glutes], equipment: .machine, pattern: .squat,
                 instructions: ["Shoulders under the pads, feet mid-platform.", "Lower under control to full depth.", "Press through the whole foot."],
                 defaultRestSeconds: 150, loadIncrement: 5),
        Exercise(id: "goblet-squat", name: "Goblet Squat", primaryMuscles: [.quads, .glutes], secondaryMuscles: [.core], equipment: .dumbbell, pattern: .squat,
                 instructions: ["Hold a dumbbell vertically at your chest.", "Sit down between the knees, elbows inside the thighs.", "Stand tall without letting the chest drop."],
                 defaultRestSeconds: 90, loadIncrement: 2),
        Exercise(id: "leg-press", name: "Leg Press", primaryMuscles: [.quads, .glutes], equipment: .machine, pattern: .squat,
                 instructions: ["Feet shoulder-width on the platform.", "Lower until knees reach about 90°.", "Press without locking the knees hard."],
                 defaultRestSeconds: 120, loadIncrement: 5),
        Exercise(id: "bodyweight-squat", name: "Bodyweight Squat", primaryMuscles: [.quads, .glutes], equipment: .bodyweight, pattern: .squat,
                 instructions: ["Feet shoulder-width, arms forward for balance.", "Sit to full depth.", "Stand up tall."],
                 defaultRestSeconds: 60, loadIncrement: 0),
        // Hinge
        Exercise(id: "romanian-deadlift", name: "Romanian Deadlift", primaryMuscles: [.hamstrings, .glutes], secondaryMuscles: [.back], equipment: .barbell, pattern: .hinge,
                 instructions: ["Hold the bar at hip height, soft knees.", "Push the hips back, sliding the bar down the thighs.", "Stop when hamstrings are fully stretched, then drive hips forward."],
                 defaultRestSeconds: 150),
        Exercise(id: "deadlift", name: "Deadlift", primaryMuscles: [.hamstrings, .glutes, .back], secondaryMuscles: [.quads, .core], equipment: .barbell, pattern: .hinge,
                 instructions: ["Bar over mid-foot, hips set, back flat.", "Push the floor away and keep the bar close.", "Lock out by squeezing the glutes."],
                 defaultRestSeconds: 180, loadIncrement: 5),
        Exercise(id: "db-romanian-deadlift", name: "Dumbbell RDL", primaryMuscles: [.hamstrings, .glutes], equipment: .dumbbell, pattern: .hinge,
                 instructions: ["Dumbbells in front of the thighs.", "Hinge back until a deep hamstring stretch.", "Return by driving the hips through."],
                 defaultRestSeconds: 120, loadIncrement: 2),
        Exercise(id: "hip-thrust", name: "Hip Thrust", primaryMuscles: [.glutes], secondaryMuscles: [.hamstrings], equipment: .barbell, pattern: .hinge,
                 instructions: ["Upper back on a bench, bar over the hips.", "Drive the hips up to full extension.", "Pause and lower under control."],
                 defaultRestSeconds: 120),
        Exercise(id: "kb-swing", name: "Kettlebell Swing", primaryMuscles: [.glutes, .hamstrings], secondaryMuscles: [.core], equipment: .kettlebell, pattern: .hinge,
                 instructions: ["Hike the bell back between the legs.", "Snap the hips forward to float it to chest height."],
                 defaultRestSeconds: 90, loadIncrement: 4),
        Exercise(id: "glute-bridge", name: "Glute Bridge", primaryMuscles: [.glutes], equipment: .bodyweight, pattern: .hinge,
                 instructions: ["Lie on your back, knees bent.", "Drive through the heels to lift the hips.", "Squeeze at the top."],
                 defaultRestSeconds: 60, loadIncrement: 0, isCompound: false),
        // Lunge
        Exercise(id: "bulgarian-split-squat", name: "Bulgarian Split Squat", primaryMuscles: [.quads, .glutes], equipment: .dumbbell, pattern: .lunge,
                 instructions: ["Rear foot on a bench.", "Lower straight down until the back knee nearly touches.", "Drive through the front foot."],
                 defaultRestSeconds: 90, loadIncrement: 2),
        Exercise(id: "walking-lunge", name: "Walking Lunge", primaryMuscles: [.quads, .glutes], equipment: .dumbbell, pattern: .lunge,
                 instructions: ["Step forward and lower the back knee.", "Drive up and step through."],
                 defaultRestSeconds: 90, loadIncrement: 2),
        Exercise(id: "reverse-lunge", name: "Reverse Lunge", primaryMuscles: [.quads, .glutes], equipment: .bodyweight, pattern: .lunge,
                 instructions: ["Step back and lower.", "Return to standing through the front foot."],
                 defaultRestSeconds: 60, loadIncrement: 0),
        // Lower isolation
        Exercise(id: "leg-curl", name: "Seated Leg Curl", primaryMuscles: [.hamstrings], equipment: .machine, pattern: .isolationLower,
                 instructions: ["Pad just above the heels.", "Curl to full flexion and squeeze.", "Return slowly."],
                 defaultRestSeconds: 90, loadIncrement: 5, isCompound: false, symbol: "figure.cooldown"),
        Exercise(id: "nordic-curl", name: "Nordic Curl", primaryMuscles: [.hamstrings], equipment: .bodyweight, pattern: .isolationLower,
                 instructions: ["Anchor the ankles.", "Lower the torso as slowly as possible.", "Catch yourself and push back up."],
                 defaultRestSeconds: 90, loadIncrement: 0, isCompound: false),
        Exercise(id: "leg-extension", name: "Leg Extension", primaryMuscles: [.quads], equipment: .machine, pattern: .isolationLower,
                 instructions: ["Pad on the lower shin.", "Extend fully and pause.", "Lower under control."],
                 defaultRestSeconds: 90, loadIncrement: 5, isCompound: false),
        Exercise(id: "standing-calf-raise", name: "Standing Calf Raise", primaryMuscles: [.calves], equipment: .machine, pattern: .isolationLower,
                 instructions: ["Balls of the feet on the edge.", "Full stretch at the bottom, pause at the top."],
                 defaultRestSeconds: 60, loadIncrement: 5, isCompound: false),
        Exercise(id: "single-leg-calf-raise", name: "Single-Leg Calf Raise", primaryMuscles: [.calves], equipment: .bodyweight, pattern: .isolationLower,
                 instructions: ["Stand on one foot on a step.", "Lower fully and rise high."],
                 defaultRestSeconds: 45, loadIncrement: 0, isCompound: false),
        // Horizontal push
        Exercise(id: "bench-press", name: "Bench Press", primaryMuscles: [.chest], secondaryMuscles: [.triceps, .shoulders], equipment: .barbell, pattern: .horizontalPush,
                 instructions: ["Eyes under the bar, shoulder blades pinned.", "Lower to the lower chest with elbows ~45°.", "Press back up and slightly toward the face."],
                 defaultRestSeconds: 180, symbol: "figure.strengthtraining.traditional"),
        Exercise(id: "incline-db-press", name: "Incline Dumbbell Press", primaryMuscles: [.chest], secondaryMuscles: [.shoulders, .triceps], equipment: .dumbbell, pattern: .horizontalPush,
                 instructions: ["Bench at 30°.", "Lower the dumbbells to upper-chest level.", "Press up and slightly in."],
                 defaultRestSeconds: 120, loadIncrement: 2),
        Exercise(id: "db-bench-press", name: "Dumbbell Bench Press", primaryMuscles: [.chest], secondaryMuscles: [.triceps, .shoulders], equipment: .dumbbell, pattern: .horizontalPush,
                 instructions: ["Dumbbells over the chest.", "Lower with control to a deep stretch.", "Press up."],
                 defaultRestSeconds: 120, loadIncrement: 2),
        Exercise(id: "machine-chest-press", name: "Machine Chest Press", primaryMuscles: [.chest], secondaryMuscles: [.triceps], equipment: .machine, pattern: .horizontalPush,
                 instructions: ["Handles at mid-chest.", "Press without locking out hard.", "Return to a full stretch."],
                 defaultRestSeconds: 120, loadIncrement: 5),
        Exercise(id: "push-up", name: "Push-Up", primaryMuscles: [.chest], secondaryMuscles: [.triceps, .shoulders, .core], equipment: .bodyweight, pattern: .horizontalPush,
                 instructions: ["Hands just outside shoulder width.", "Body in a straight line.", "Chest to the floor, then press."],
                 defaultRestSeconds: 60, loadIncrement: 0),
        Exercise(id: "cable-fly", name: "Cable Fly", primaryMuscles: [.chest], equipment: .cable, pattern: .isolationUpper,
                 instructions: ["Slight bend in the elbows.", "Hug the handles together in an arc.", "Open up to a full stretch."],
                 defaultRestSeconds: 75, loadIncrement: 2.5, isCompound: false),
        // Vertical push
        Exercise(id: "overhead-press", name: "Overhead Press", primaryMuscles: [.shoulders], secondaryMuscles: [.triceps, .core], equipment: .barbell, pattern: .verticalPush,
                 instructions: ["Bar on the front delts, glutes tight.", "Press straight up, moving the head back then through.", "Lock out over mid-foot."],
                 defaultRestSeconds: 150),
        Exercise(id: "db-shoulder-press", name: "Dumbbell Shoulder Press", primaryMuscles: [.shoulders], secondaryMuscles: [.triceps], equipment: .dumbbell, pattern: .verticalPush,
                 instructions: ["Dumbbells at ear height.", "Press overhead without arching.", "Lower under control."],
                 defaultRestSeconds: 120, loadIncrement: 2),
        Exercise(id: "pike-push-up", name: "Pike Push-Up", primaryMuscles: [.shoulders], secondaryMuscles: [.triceps], equipment: .bodyweight, pattern: .verticalPush,
                 instructions: ["Hips high, head between the arms.", "Lower the head toward the floor.", "Press back up."],
                 defaultRestSeconds: 75, loadIncrement: 0),
        Exercise(id: "lateral-raise", name: "Lateral Raise", primaryMuscles: [.shoulders], equipment: .dumbbell, pattern: .isolationUpper,
                 instructions: ["Slight forward lean.", "Raise to shoulder height leading with the elbows.", "Lower slowly."],
                 defaultRestSeconds: 60, loadIncrement: 1, isCompound: false),
        Exercise(id: "cable-lateral-raise", name: "Cable Lateral Raise", primaryMuscles: [.shoulders], equipment: .cable, pattern: .isolationUpper,
                 instructions: ["Cable at hand height, across the body.", "Raise to shoulder height."],
                 defaultRestSeconds: 60, loadIncrement: 1.25, isCompound: false),
        // Horizontal pull
        Exercise(id: "barbell-row", name: "Barbell Row", primaryMuscles: [.back], secondaryMuscles: [.biceps], equipment: .barbell, pattern: .horizontalPull,
                 instructions: ["Hinge to ~45°, flat back.", "Row the bar to the lower ribs.", "Lower under control."],
                 defaultRestSeconds: 150),
        Exercise(id: "chest-supported-row", name: "Chest-Supported Row", primaryMuscles: [.back], secondaryMuscles: [.biceps], equipment: .dumbbell, pattern: .horizontalPull,
                 instructions: ["Chest on an incline bench.", "Row elbows back toward the hips.", "Full stretch at the bottom."],
                 defaultRestSeconds: 120, loadIncrement: 2),
        Exercise(id: "seated-cable-row", name: "Seated Cable Row", primaryMuscles: [.back], secondaryMuscles: [.biceps], equipment: .cable, pattern: .horizontalPull,
                 instructions: ["Sit tall, slight knee bend.", "Pull the handle to the stomach.", "Let the shoulders reach forward on the return."],
                 defaultRestSeconds: 120, loadIncrement: 5),
        Exercise(id: "inverted-row", name: "Inverted Row", primaryMuscles: [.back], secondaryMuscles: [.biceps], equipment: .bodyweight, pattern: .horizontalPull,
                 instructions: ["Hang under a bar, body straight.", "Pull the chest to the bar."],
                 defaultRestSeconds: 75, loadIncrement: 0),
        Exercise(id: "band-row", name: "Band Row", primaryMuscles: [.back], equipment: .band, pattern: .horizontalPull,
                 instructions: ["Anchor the band at chest height.", "Row and squeeze the shoulder blades."],
                 defaultRestSeconds: 60, loadIncrement: 0),
        // Vertical pull
        Exercise(id: "lat-pulldown", name: "Lat Pulldown", primaryMuscles: [.back], secondaryMuscles: [.biceps], equipment: .cable, pattern: .verticalPull,
                 instructions: ["Grip slightly wider than the shoulders.", "Pull the bar to the upper chest.", "Control the return to a full stretch."],
                 defaultRestSeconds: 120, loadIncrement: 5),
        Exercise(id: "pull-up", name: "Pull-Up", primaryMuscles: [.back], secondaryMuscles: [.biceps], equipment: .bodyweight, pattern: .verticalPull,
                 instructions: ["Dead hang, overhand grip.", "Pull until the chin clears the bar.", "Lower all the way."],
                 defaultRestSeconds: 150, loadIncrement: 2.5),
        Exercise(id: "band-pulldown", name: "Band Pulldown", primaryMuscles: [.back], equipment: .band, pattern: .verticalPull,
                 instructions: ["Anchor the band high.", "Pull elbows down to the ribs."],
                 defaultRestSeconds: 60, loadIncrement: 0),
        Exercise(id: "face-pull", name: "Face Pull", primaryMuscles: [.shoulders], secondaryMuscles: [.back], equipment: .cable, pattern: .isolationUpper,
                 instructions: ["Rope at face height.", "Pull toward the eyes, elbows high, rotate out."],
                 defaultRestSeconds: 60, loadIncrement: 2.5, isCompound: false),
        // Arms
        Exercise(id: "db-curl", name: "Dumbbell Curl", primaryMuscles: [.biceps], equipment: .dumbbell, pattern: .elbowFlexion,
                 instructions: ["Elbows pinned at the sides.", "Curl and supinate.", "Lower slowly."],
                 defaultRestSeconds: 60, loadIncrement: 1, isCompound: false),
        Exercise(id: "ez-bar-curl", name: "EZ-Bar Curl", primaryMuscles: [.biceps], equipment: .barbell, pattern: .elbowFlexion,
                 instructions: ["Grip the angled handles.", "Curl without swinging."],
                 defaultRestSeconds: 75, loadIncrement: 2.5, isCompound: false),
        Exercise(id: "cable-curl", name: "Cable Curl", primaryMuscles: [.biceps], equipment: .cable, pattern: .elbowFlexion,
                 instructions: ["Stand tall facing the stack.", "Curl to full contraction."],
                 defaultRestSeconds: 60, loadIncrement: 2.5, isCompound: false),
        Exercise(id: "band-curl", name: "Band Curl", primaryMuscles: [.biceps], equipment: .band, pattern: .elbowFlexion,
                 instructions: ["Stand on the band.", "Curl to the shoulders."],
                 defaultRestSeconds: 45, loadIncrement: 0, isCompound: false),
        Exercise(id: "triceps-pushdown", name: "Triceps Pushdown", primaryMuscles: [.triceps], equipment: .cable, pattern: .elbowExtension,
                 instructions: ["Elbows tucked.", "Extend fully and squeeze.", "Return to ~90°."],
                 defaultRestSeconds: 60, loadIncrement: 2.5, isCompound: false),
        Exercise(id: "overhead-triceps-extension", name: "Overhead Triceps Extension", primaryMuscles: [.triceps], equipment: .dumbbell, pattern: .elbowExtension,
                 instructions: ["Hold a dumbbell overhead with both hands.", "Lower behind the head to a deep stretch.", "Extend back up."],
                 defaultRestSeconds: 60, loadIncrement: 2, isCompound: false),
        Exercise(id: "dips", name: "Dips", primaryMuscles: [.triceps, .chest], secondaryMuscles: [.shoulders], equipment: .bodyweight, pattern: .verticalPush,
                 instructions: ["Lock out on the bars.", "Lower until the shoulders are just below the elbows.", "Press back up."],
                 defaultRestSeconds: 120, loadIncrement: 2.5),
        Exercise(id: "diamond-push-up", name: "Diamond Push-Up", primaryMuscles: [.triceps], secondaryMuscles: [.chest], equipment: .bodyweight, pattern: .elbowExtension,
                 instructions: ["Hands together under the chest.", "Lower and press keeping elbows in."],
                 defaultRestSeconds: 60, loadIncrement: 0, isCompound: false),
        // Core
        Exercise(id: "hanging-leg-raise", name: "Hanging Leg Raise", primaryMuscles: [.core], equipment: .bodyweight, pattern: .core,
                 instructions: ["Dead hang.", "Raise the legs by curling the pelvis up.", "Lower without swinging."],
                 defaultRestSeconds: 60, loadIncrement: 0, isCompound: false),
        Exercise(id: "cable-crunch", name: "Cable Crunch", primaryMuscles: [.core], equipment: .cable, pattern: .core,
                 instructions: ["Kneel facing the stack, rope by the head.", "Crunch the ribs toward the hips."],
                 defaultRestSeconds: 60, loadIncrement: 2.5, isCompound: false),
        Exercise(id: "plank", name: "Plank", primaryMuscles: [.core], equipment: .bodyweight, pattern: .core,
                 instructions: ["Forearms under the shoulders.", "Squeeze glutes and brace.", "Log seconds held as reps."],
                 defaultRestSeconds: 45, loadIncrement: 0, isCompound: false)
    ]
    // swiftlint:enable line_length
}

extension Exercise {
    /// Imported exercises carry a `fedb-` id prefix; everything else is hand-curated.
    public var isCurated: Bool { !id.hasPrefix("fedb-") }
}
