import Foundation
import VectorCore

/// Keeps the user's data in step across their devices.
protocol CloudSync: AnyObject {
    /// True when an iCloud account is signed in and the container is reachable.
    var isAvailable: Bool { get }
    /// Starts watching for changes written by other devices. `onRemote` is
    /// called with the cloud copy at launch and after each remote change.
    func start(onRemote: @escaping @Sendable (AppData) -> Void)
    /// Writes this device's latest copy (debounced, merged before writing).
    func push(_ data: AppData)
}

/// iCloud Drive document sync. The whole `AppData` lives in one JSON file in
/// the app's ubiquity container; every write first merges with whatever is
/// in the cloud (`SyncMerge`), so two devices editing offline both keep
/// their work. Reads and writes go through `NSFileCoordinator`, and an
/// `NSMetadataQuery` reports writes from other devices.
final class ICloudDocumentSync: NSObject, CloudSync, @unchecked Sendable {
    static let containerIdentifier = "iCloud.app.vector"
    private static let fileName = "vector-data.json"

    private let queue = DispatchQueue(label: "vector.icloud-sync", qos: .utility)
    private var documentURL: URL?
    private var query: NSMetadataQuery?
    private var onRemote: (@Sendable (AppData) -> Void)?
    private var pendingPush: DispatchWorkItem?
    private var lastWrittenModifiedAt: Date?

    var isAvailable: Bool { FileManager.default.ubiquityIdentityToken != nil }

    func start(onRemote: @escaping @Sendable (AppData) -> Void) {
        guard isAvailable else { return }
        self.onRemote = onRemote
        queue.async { [weak self] in
            guard let self else { return }
            // Resolving the container can block; never do it on the main thread.
            guard let container = FileManager.default.url(forUbiquityContainerIdentifier: Self.containerIdentifier) else { return }
            let documents = container.appendingPathComponent("Documents", isDirectory: true)
            try? FileManager.default.createDirectory(at: documents, withIntermediateDirectories: true)
            let url = documents.appendingPathComponent(Self.fileName)
            self.documentURL = url
            if let remote = self.read(url) { onRemote(remote) }
            DispatchQueue.main.async { self.startQuery() }
        }
    }

    func push(_ data: AppData) {
        guard isAvailable else { return }
        pendingPush?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.write(data) }
        pendingPush = work
        queue.asyncAfter(deadline: .now() + 2, execute: work)
    }

    // MARK: File access

    private func read(_ url: URL) -> AppData? {
        var result: AppData?
        var error: NSError?
        NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &error) { readURL in
            guard let data = try? Data(contentsOf: readURL) else { return }
            result = try? JSONFileStore.decoder.decode(AppData.self, from: data)
        }
        return result
    }

    private func write(_ local: AppData) {
        guard let url = documentURL else { return }
        var error: NSError?
        NSFileCoordinator().coordinate(writingItemAt: url, options: .forMerging, error: &error) { writeURL in
            // Merge with the cloud copy first so another device's offline work survives.
            var toWrite = local
            if let data = try? Data(contentsOf: writeURL),
               let remote = try? JSONFileStore.decoder.decode(AppData.self, from: data) {
                toWrite = SyncMerge.merge(local: local, remote: remote)
            }
            // Device-local state (in-progress workout, rest timer, progress-photo
            // metadata) never goes to iCloud.
            toWrite = SyncMerge.cloudCopy(toWrite)
            guard let encoded = try? JSONFileStore.encoder.encode(toWrite) else { return }
            try? encoded.write(to: writeURL, options: .atomic)
            lastWrittenModifiedAt = toWrite.modifiedAt
        }
    }

    // MARK: Remote change notifications

    private func startQuery() {
        let query = NSMetadataQuery()
        query.searchScopes = [NSMetadataQueryUbiquitousDocumentsScope]
        query.predicate = NSPredicate(format: "%K == %@", NSMetadataItemFSNameKey, Self.fileName)
        NotificationCenter.default.addObserver(self, selector: #selector(remoteChanged),
                                               name: .NSMetadataQueryDidUpdate, object: query)
        NotificationCenter.default.addObserver(self, selector: #selector(remoteChanged),
                                               name: .NSMetadataQueryDidFinishGathering, object: query)
        query.start()
        self.query = query
    }

    @objc private func remoteChanged(_ notification: Notification) {
        guard let query = notification.object as? NSMetadataQuery else { return }
        query.disableUpdates()
        defer { query.enableUpdates() }
        for case let item as NSMetadataItem in query.results {
            guard let url = item.value(forAttribute: NSMetadataItemURLKey) as? URL else { continue }
            // Make sure the latest version is downloaded before reading it.
            try? FileManager.default.startDownloadingUbiquitousItem(at: url)
            queue.async { [weak self] in
                guard let self, let remote = self.read(url), remote.modifiedAt != self.lastWrittenModifiedAt else { return }
                self.onRemote?(remote)
            }
        }
    }
}

enum CloudSyncPreference {
    static let key = "vector.icloud-sync-enabled"
}
