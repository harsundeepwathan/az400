import Foundation
import SwiftData
import os

/// Creates the SwiftData container in a protected location.
enum PersistenceController {
    static let logger = Logger(subsystem: "my.kira.app", category: "persistence")

    static var storeDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Kira", isDirectory: true)
    }

    static func makeContainer(inMemory: Bool = false) throws -> ModelContainer {
        let schema = Schema(KiraSchema.models)
        if inMemory {
            return try ModelContainer(for: schema, configurations: ModelConfiguration(schema: schema, isStoredInMemoryOnly: true))
        }
        let directory = storeDirectory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.protectionKey: FileProtectionType.complete])
        let storeURL = directory.appendingPathComponent("Kira.store")
        let configuration = ModelConfiguration(schema: schema, url: storeURL, allowsSave: true, cloudKitDatabase: .none)
        let container = try ModelContainer(for: schema, configurations: configuration)
        applyProtection(in: directory)
        return container
    }

    /// Ensures the SQLite file and its -wal/-shm siblings carry Complete protection.
    static func applyProtection(in directory: URL) {
        let manager = FileManager.default
        guard let files = try? manager.contentsOfDirectory(atPath: directory.path) else { return }
        for file in files {
            let path = directory.appendingPathComponent(file).path
            do {
                try manager.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: path)
            } catch {
                logger.error("Could not set file protection on a store file: \(error.localizedDescription, privacy: .public)")
            }
        }
    }
}
