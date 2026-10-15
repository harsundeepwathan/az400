import Foundation

/// Reads workout history exported from Hevy or Strong (their CSV exports)
/// into Vector sessions, so switching keeps every set. Exercise names are
/// matched to the catalog; names that don't match become custom exercises.
public struct WorkoutImporter: Sendable {
    public enum Source: String, Sendable { case hevy = "Hevy", strong = "Strong" }

    public enum ImportError: Error, Equatable, Sendable {
        /// The header matches neither app's export.
        case unrecognizedFormat
        /// The file was recognised but had no usable sets.
        case noWorkouts
    }

    public struct Result: Sendable {
        public var source: Source
        public var sessions: [WorkoutSession]
        /// Exercises created for names the catalog didn't have.
        public var newExercises: [Exercise]
        public var matchedNames: Int
        public var skippedRows: Int
    }

    public let catalog: ExerciseCatalog
    public let timeZone: TimeZone

    public init(catalog: ExerciseCatalog, timeZone: TimeZone = .current) {
        self.catalog = catalog
        self.timeZone = timeZone
    }

    /// `strongUnit` is the unit the Strong export was written in (Strong
    /// writes weights in the user's unit; Hevy always writes kilograms).
    public func importCSV(_ text: String, strongUnit: WeightUnit = .kilograms) throws -> Result {
        let rows = CSV.rows(text)
        guard let header = rows.first?.map({ $0.trimmingCharacters(in: .whitespaces).lowercased() }) else {
            throw ImportError.unrecognizedFormat
        }
        let body = Array(rows.dropFirst())
        if header.contains("exercise_title"), header.contains("start_time") {
            return try build(.hevy, rows: body.compactMap { hevyRow($0, header: header) }, skipped: body.count)
        }
        if header.contains("exercise name"), header.contains("set order") {
            return try build(.strong, rows: body.compactMap { strongRow($0, header: header, unit: strongUnit) }, skipped: body.count)
        }
        throw ImportError.unrecognizedFormat
    }

    // MARK: Rows

    struct Row {
        var workout: String
        var start: Date
        var end: Date?
        var exercise: String
        var kind: SetKind
        var weight: Double
        var reps: Int
        var rpe: Double?
        var note: String
    }

    private func value(_ row: [String], _ header: [String], _ name: String) -> String {
        guard let index = header.firstIndex(of: name), index < row.count else { return "" }
        return row[index].trimmingCharacters(in: .whitespaces)
    }

    private func formatter(_ format: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = format
        return formatter
    }

    private func date(_ text: String, formats: [String]) -> Date? {
        for format in formats {
            if let date = formatter(format).date(from: text) { return date }
        }
        return ISO8601DateFormatter().date(from: text)
    }

    private func number(_ text: String) -> Double? {
        Double(text.replacingOccurrences(of: ",", with: "."))
    }

    func hevyRow(_ row: [String], header: [String]) -> Row? {
        let v = { (name: String) in self.value(row, header, name) }
        let formats = ["d MMM yyyy, HH:mm", "dd MMM yyyy, HH:mm", "yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd'T'HH:mm:ss"]
        guard let start = date(v("start_time"), formats: formats), !v("exercise_title").isEmpty,
              let reps = number(v("reps")).map({ Int($0) }), reps > 0 else { return nil }
        let kind: SetKind = switch v("set_type").lowercased() {
        case "warmup", "warm_up", "warm-up": .warmup
        case "dropset", "drop_set", "drop": .drop
        case "failure": .failure
        default: .working
        }
        return Row(workout: v("title").isEmpty ? "Workout" : v("title"), start: start,
                   end: date(v("end_time"), formats: formats), exercise: v("exercise_title"), kind: kind,
                   weight: number(v("weight_kg")) ?? 0, reps: reps, rpe: number(v("rpe")).flatMap { (6...10).contains($0) ? $0 : nil },
                   note: v("exercise_notes"))
    }

    func strongRow(_ row: [String], header: [String], unit: WeightUnit) -> Row? {
        let v = { (name: String) in self.value(row, header, name) }
        let order = v("set order").lowercased()
        guard order != "rest timer", let start = date(v("date"), formats: ["yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd HH:mm"]),
              !v("exercise name").isEmpty, let reps = number(v("reps")).map({ Int($0) }), reps > 0 else { return nil }
        let kind: SetKind = switch order {
        case "w": .warmup
        case "d": .drop
        case "f": .failure
        default: .working
        }
        let weight = number(v("weight")).map { unit.toKilograms($0) } ?? 0
        return Row(workout: v("workout name").isEmpty ? "Workout" : v("workout name"), start: start,
                   end: Self.duration(v("duration")).map { start.addingTimeInterval($0) },
                   exercise: v("exercise name"), kind: kind, weight: weight, reps: reps,
                   rpe: number(v("rpe")).flatMap { (6...10).contains($0) ? $0 : nil }, note: v("notes"))
    }

    /// Strong durations look like "1h 5m", "45m" or "3600" (seconds).
    static func duration(_ text: String) -> TimeInterval? {
        if let seconds = Double(text) { return seconds }
        var total: TimeInterval = 0
        var matched = false
        for part in text.lowercased().split(separator: " ") {
            if part.hasSuffix("h"), let h = Double(part.dropLast()) { total += h * 3600; matched = true }
            else if part.hasSuffix("m"), let m = Double(part.dropLast()) { total += m * 60; matched = true }
            else if part.hasSuffix("s"), let s = Double(part.dropLast()) { total += s; matched = true }
        }
        return matched ? total : nil
    }

    // MARK: Sessions

    private func build(_ source: Source, rows: [Row], skipped: Int) throws -> Result {
        guard !rows.isEmpty else { throw ImportError.noWorkouts }
        let matcher = ExerciseMatcher(catalog: catalog)
        var resolved: [String: Exercise] = [:]
        var created: [Exercise] = []
        var matched = 0
        func exercise(for name: String) -> Exercise {
            let key = name.lowercased()
            if let known = resolved[key] { return known }
            let exercise: Exercise
            if let match = matcher.match(name) {
                exercise = match
                matched += 1
            } else {
                exercise = .custom(name: name, primaryMuscle: ExerciseMatcher.guessMuscle(name),
                                   equipment: ExerciseMatcher.guessEquipment(name))
                created.append(exercise)
            }
            resolved[key] = exercise
            return exercise
        }

        // Group rows into workouts (same title and start), keeping file order.
        var order: [String] = []
        var groups: [String: [Row]] = [:]
        for row in rows {
            let key = "\(row.workout)|\(row.start.timeIntervalSince1970)"
            if groups[key] == nil { order.append(key) }
            groups[key, default: []].append(row)
        }

        let sessions: [WorkoutSession] = order.map { key in
            let group = groups[key]!
            var logs: [ExerciseLog] = []
            var indexByExercise: [String: Int] = [:]
            for row in group {
                let ex = exercise(for: row.exercise)
                let set = SetLog(kind: row.kind, weight: row.weight, reps: row.reps, isCompleted: true,
                                 completedAt: row.start, rpe: row.rpe)
                if let index = indexByExercise[ex.id] {
                    logs[index].sets.append(set)
                } else {
                    indexByExercise[ex.id] = logs.count
                    logs.append(ExerciseLog(exerciseID: ex.id, sets: [set], repRange: RepRange(8, 12),
                                            restSeconds: ex.defaultRestSeconds, note: row.note))
                }
            }
            let first = group[0]
            let end = first.end.flatMap { $0 > first.start ? $0 : nil } ?? first.start.addingTimeInterval(3600)
            return WorkoutSession(name: first.workout, startedAt: first.start, endedAt: end, exercises: logs)
        }
        return Result(source: source, sessions: sessions.sorted { $0.startedAt > $1.startedAt },
                      newExercises: created, matchedNames: matched, skippedRows: skipped - rows.count)
    }
}

/// Writes finished sessions as CSV in the same column layout Hevy exports,
/// so the user's data can always leave Vector too.
public struct WorkoutExporter: Sendable {
    public let catalog: ExerciseCatalog
    public let timeZone: TimeZone

    public init(catalog: ExerciseCatalog, timeZone: TimeZone = .current) {
        self.catalog = catalog
        self.timeZone = timeZone
    }

    public func csv(_ sessions: [WorkoutSession]) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "d MMM yyyy, HH:mm"
        var lines = ["title,start_time,end_time,description,exercise_title,superset_id,exercise_notes,set_index,set_type,weight_kg,reps,distance_km,duration_seconds,rpe"]
        for session in sessions.filter(\.isFinished).sorted(by: { $0.startedAt > $1.startedAt }) {
            for log in session.exercises {
                let name = catalog[log.exerciseID]?.name ?? log.exerciseID
                for (index, set) in log.sets.enumerated() where set.isCompleted {
                    let type = switch set.kind {
                    case .warmup: "warmup"
                    case .drop: "dropset"
                    case .failure: "failure"
                    case .working: "normal"
                    }
                    let fields = [
                        session.name, formatter.string(from: session.startedAt),
                        session.endedAt.map(formatter.string) ?? "", "", name,
                        log.supersetGroup.map(String.init) ?? "", log.note, String(index), type,
                        Self.number(set.weight), String(set.reps), "", "", set.rpe.map(Self.number) ?? ""
                    ]
                    lines.append(fields.map(CSV.field).joined(separator: ","))
                }
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    static func number(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(format: "%.2f", value)
            .replacingOccurrences(of: #"0+$"#, with: "", options: .regularExpression)
    }
}
