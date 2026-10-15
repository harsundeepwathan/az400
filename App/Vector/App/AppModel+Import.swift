import Foundation
import VectorCore

/// Moving in and out: workout history from Hevy or Strong, and a CSV of
/// Vector's own workouts in the same layout.
extension AppModel {
    struct WorkoutImportSummary: Equatable {
        var source: String
        var added: Int
        var duplicates: Int
        var newExercises: Int
    }

    /// Reads a Hevy or Strong CSV export and adds its workouts. Workouts already
    /// here (same name, same start minute) are skipped, so importing twice is safe.
    func importWorkouts(from url: URL) throws -> WorkoutImportSummary {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let fileData = try Data(contentsOf: url)
        let text = String(decoding: fileData, as: UTF8.self)
        let result = try WorkoutImporter(catalog: catalog, timeZone: calendar.timeZone)
            .importCSV(text, strongUnit: unit)

        func key(_ session: WorkoutSession) -> String {
            "\(session.name.lowercased())|\(Int(session.startedAt.timeIntervalSince1970 / 60))"
        }
        // Against every stored workout, not just the ones the free history window shows.
        var seen = Set(data.sessions.map(key))
        var added: [WorkoutSession] = []
        for session in result.sessions where seen.insert(key(session)).inserted {
            added.append(session)
        }
        let usedIDs = Set(added.flatMap { $0.exercises.map(\.exerciseID) })
        let newExercises = result.newExercises.filter { usedIDs.contains($0.id) }
        mutate { data in
            data.customExercises = (data.customExercises ?? []) + newExercises
            data.sessions.append(contentsOf: added)
        }
        return WorkoutImportSummary(source: result.source.rawValue, added: added.count,
                                    duplicates: result.sessions.count - added.count, newExercises: newExercises.count)
    }

    /// Every finished workout as CSV (Hevy's column layout), written to a temporary file to share.
    func exportWorkoutsCSV() -> URL? {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("vector-workouts.csv")
        let csv = WorkoutExporter(catalog: catalog, timeZone: calendar.timeZone).csv(sessions)
        do {
            try csv.write(to: url, atomically: true, encoding: .utf8)
            return url
        } catch {
            return nil
        }
    }
}
