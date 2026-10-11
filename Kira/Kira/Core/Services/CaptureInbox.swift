import Foundation
import KiraCore
import os

/// File-based inbox for Shortcut captures.
///
/// The main store uses `NSFileProtectionComplete`, so it cannot be opened while the device is
/// locked — which is exactly when a Wallet "Transaction" automation may fire (Apple Pay can be
/// used from the Lock Screen). Each capture is therefore written as its own small file with
/// `completeUnlessOpen` protection, which iOS allows to be *created* while locked but not read
/// back until the user unlocks. The app drains the inbox whenever it becomes active.
struct CaptureInbox: Sendable {
    let directory: URL
    private static let logger = Logger(subsystem: "my.kira.app", category: "inbox")

    init(directory: URL = PersistenceController.storeDirectory.appendingPathComponent("Inbox", isDirectory: true)) {
        self.directory = directory
    }

    func enqueue(_ item: CaptureInboxItem) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.protectionKey: FileProtectionType.completeUnlessOpen])
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        let data = try encoder.encode(item)
        let url = directory.appendingPathComponent("\(item.id.uuidString).json")
        try data.write(to: url, options: [.atomic, .completeFileProtectionUnlessOpen])
    }

    /// Reads all pending items. Unreadable files (e.g. still locked) are left for the next drain.
    func pending() -> [(url: URL, item: CaptureInboxItem)] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        guard let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return [] }
        return files.filter { $0.pathExtension == "json" }.compactMap { url in
            guard let data = try? Data(contentsOf: url) else { return nil }
            guard let item = try? decoder.decode(CaptureInboxItem.self, from: data) else {
                // Corrupt entry: remove it rather than retrying forever.
                Self.logger.error("Discarding unreadable inbox entry")
                try? FileManager.default.removeItem(at: url)
                return nil
            }
            return (url, item)
        }
        .sorted { $0.item.receivedAt < $1.item.receivedAt }
    }

    func remove(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    func removeAll() {
        try? FileManager.default.removeItem(at: directory)
    }
}
