import Foundation
import UIKit
import VectorCore

/// Progress photo files. They live only in Application Support/ProgressPhotos
/// with complete file protection (unreadable while the device is locked),
/// excluded from iCloud and device backups, and are never uploaded. Only
/// metadata (`ProgressPhoto`) is kept in `AppData`, and that stays on this
/// device too (`SyncMerge`).
struct ProgressPhotoStore: Sendable {
    static let directoryName = "ProgressPhotos"
    /// Long edge in pixels. Plenty for a side-by-side compare, a fraction of a full-size photo.
    static let maxDimension: CGFloat = 2048
    static let jpegQuality: CGFloat = 0.82

    let directory: URL

    static func standard() throws -> ProgressPhotoStore {
        let support = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                  appropriateFor: nil, create: true)
        return try ProgressPhotoStore(directory: support.appendingPathComponent(directoryName, isDirectory: true))
    }

    init(directory: URL) throws {
        self.directory = directory
        let manager = FileManager.default
        if !manager.fileExists(atPath: directory.path) {
            try manager.createDirectory(at: directory, withIntermediateDirectories: true,
                                        attributes: [.protectionKey: FileProtectionType.complete])
        }
        // Excluding the directory excludes everything in it from iCloud and device backups.
        var excluded = directory
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try excluded.setResourceValues(values)
    }

    func url(for photo: ProgressPhoto) -> URL? {
        guard photo.hasSafeFileName else { return nil }
        return directory.appendingPathComponent(photo.fileName, isDirectory: false)
    }

    /// Re-encodes the image (which also drops EXIF, including location),
    /// downscaled to `maxDimension`, and writes it with complete protection.
    func save(_ image: UIImage, for photo: ProgressPhoto) throws {
        guard let url = url(for: photo), let jpeg = Self.jpeg(from: image) else { throw CocoaError(.fileWriteUnknown) }
        try jpeg.write(to: url, options: [.atomic, .completeFileProtection])
        var fileURL = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? fileURL.setResourceValues(values)
    }

    /// Nil when the file is missing (another device, a reset or a restore
    /// from backup); the UI shows a placeholder instead.
    func image(for photo: ProgressPhoto, maxPixelSize: CGFloat? = nil) -> UIImage? {
        guard let url = url(for: photo), let image = UIImage(contentsOfFile: url.path) else { return nil }
        guard let maxPixelSize else { return image }
        let scale = maxPixelSize / max(image.size.width, image.size.height)
        guard scale < 1 else { return image }
        return image.preparingThumbnail(of: CGSize(width: image.size.width * scale, height: image.size.height * scale)) ?? image
    }

    func delete(_ photo: ProgressPhoto) {
        guard let url = url(for: photo) else { return }
        try? FileManager.default.removeItem(at: url)
    }

    /// Removes files no metadata points to (left behind by "reset all data"
    /// or an interrupted save).
    func removeFiles(notIn photos: [ProgressPhoto]) {
        let keep = Set(photos.map(\.fileName))
        let files = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        for name in files where !keep.contains(name) {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
        }
    }

    static func jpeg(from image: UIImage) -> Data? {
        let largest = max(image.size.width * image.scale, image.size.height * image.scale)
        let ratio = largest > maxDimension ? maxDimension / largest : 1
        let target = CGSize(width: (image.size.width * image.scale * ratio).rounded(),
                            height: (image.size.height * image.scale * ratio).rounded())
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        // Drawing also bakes in the orientation so the file displays upright everywhere.
        let rendered = UIGraphicsImageRenderer(size: target, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: target))
        }
        return rendered.jpegData(compressionQuality: jpegQuality)
    }
}

extension AppModel {
    var measurementsEngine: MeasurementsEngine { MeasurementsEngine(calendar: calendar) }
    var lengthUnit: LengthUnit { LengthUnit(unit) }

    // MARK: Measurements

    var bodyMeasurements: [BodyMeasurementEntry] {
        (data.bodyMeasurements ?? []).sorted { $0.date < $1.date }
    }

    /// Saves a measuring session (same-day sessions merge). An edit that
    /// clears every site deletes the entry.
    func saveMeasurements(_ entry: BodyMeasurementEntry) {
        if entry.isEmpty {
            if data.bodyMeasurements?.contains(where: { $0.id == entry.id }) == true { deleteMeasurements(entry) }
            return
        }
        let engine = measurementsEngine
        mutate({ data in
            let result = engine.upserting(entry, into: data.bodyMeasurements ?? [])
            data.bodyMeasurements = result.entries
        }, refreshInsights: false)
        showToast("checkmark.circle.fill", "Measurements saved")
    }

    func deleteMeasurements(_ entry: BodyMeasurementEntry) {
        mutate({ data in
            data.bodyMeasurements?.removeAll { $0.id == entry.id }
            if data.bodyMeasurements?.isEmpty == true { data.bodyMeasurements = nil }
            data.deletedIDs = (data.deletedIDs ?? []).union([Tombstone.measurement(entry.id)])
        }, refreshInsights: false)
    }

    // MARK: Progress photos

    var progressPhotos: [ProgressPhoto] {
        (data.progressPhotos ?? []).sorted { $0.date > $1.date }
    }

    /// Created once and reused. A failure isn't cached, so a later access
    /// can still succeed (for example once protected data is available).
    var photoStore: ProgressPhotoStore? {
        if let photoStoreCache { return photoStoreCache }
        let store = try? ProgressPhotoStore.standard()
        photoStoreCache = store
        return store
    }

    /// Writes the file first, then records the metadata, so metadata never
    /// points at a file that failed to save.
    @discardableResult
    func addProgressPhoto(_ image: UIImage, pose: PhotoPose, date: Date) -> Bool {
        guard let store = photoStore else { return false }
        let photo = ProgressPhoto(date: date, pose: pose)
        do {
            try store.save(image, for: photo)
        } catch {
            showToast("exclamationmark.triangle", "Couldn't save the photo")
            return false
        }
        mutate({ data in
            data.progressPhotos = ((data.progressPhotos ?? []) + [photo]).sorted { $0.date < $1.date }
        }, refreshInsights: false)
        showToast("checkmark.circle.fill", "Photo saved on this iPhone")
        return true
    }

    /// Deletes the file and its metadata.
    func deleteProgressPhoto(_ photo: ProgressPhoto) {
        photoStore?.delete(photo)
        mutate({ data in
            data.progressPhotos?.removeAll { $0.id == photo.id }
            if data.progressPhotos?.isEmpty == true { data.progressPhotos = nil }
            // No tombstone: photo metadata never syncs, so there is nothing to propagate.
        }, refreshInsights: false)
    }

    /// Deletes orphaned files after "reset all data", which clears the
    /// metadata. Only `resetAll()` calls it: running it on screen appearance
    /// would delete every photo if AppData had failed to load. Runs
    /// synchronously on the main actor so it can't race a photo being added.
    func removeOrphanedPhotoFiles() {
        photoStore?.removeFiles(notIn: data.progressPhotos ?? [])
    }
}
