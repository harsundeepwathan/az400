import UIKit
import ImageIO
import os

/// Official service logos: each catalog service's own App Store app icon, downloaded from Apple
/// and cached on device.
///
/// Privacy: the only requests go to Apple (`itunes.apple.com` for the public lookup and
/// Apple's image CDN `*.mzstatic.com` for the icon). They carry the app's public App Store ID —
/// never prices, accounts or anything you've entered — use an ephemeral session without cookies,
/// and each logo is fetched once, then served from the cache. People can turn logos off in
/// Settings › Privacy & data; the cache is removed with "Delete all data".
actor ServiceLogoStore {
    static let shared = ServiceLogoStore()
    /// `@AppStorage` key; on by default.
    static let preferenceKey = "kira.showServiceLogos"

    /// Decoded logos for synchronous first-frame rendering. NSCache is thread-safe.
    nonisolated(unsafe) private let memory = NSCache<NSNumber, UIImage>()
    private var inFlight: [Int: Task<UIImage?, Never>] = [:]
    /// IDs that failed this session, so a missing app isn't retried on every row.
    private var failed: Set<Int> = []
    private let directory: URL
    private let session: URLSession
    private let log = Logger(subsystem: "app.kira", category: "logos")

    /// Logos are rendered at most ~100 pt; 256 px covers @3x at list sizes and the detail header.
    private static let maxPixelSize = 256

    init() {
        directory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appending(path: "ServiceLogos", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 15
        configuration.waitsForConnectivity = false
        session = URLSession(configuration: configuration)
        memory.countLimit = 64
    }

    /// Already-decoded logo, if any. Safe to call from a view's init.
    nonisolated func cachedLogo(for appID: Int) -> UIImage? {
        memory.object(forKey: NSNumber(value: appID))
    }

    /// Logo for an App Store app ID: memory, then disk, then one download shared by all callers.
    func logo(for appID: Int) async -> UIImage? {
        if let image = cachedLogo(for: appID) { return image }
        let file = directory.appending(path: "\(appID).png")
        if let data = try? Data(contentsOf: file), let image = UIImage(data: data) {
            memory.setObject(image, forKey: NSNumber(value: appID))
            return image
        }
        guard !failed.contains(appID) else { return nil }
        if let task = inFlight[appID] { return await task.value }

        let task = Task { await download(appID, to: file) }
        inFlight[appID] = task
        let image = await task.value
        inFlight[appID] = nil
        if let image { memory.setObject(image, forKey: NSNumber(value: appID)) } else { failed.insert(appID) }
        return image
    }

    /// Removes cached logos (they reveal which services someone tracks).
    func removeAll() {
        memory.removeAllObjects()
        failed.removeAll()
        try? FileManager.default.removeItem(at: directory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    // MARK: Download

    private struct Lookup: Decodable {
        struct Result: Decodable { let artworkUrl512: String? }
        let results: [Result]
    }

    private func download(_ appID: Int, to file: URL) async -> UIImage? {
        var components = URLComponents(string: "https://itunes.apple.com/lookup")!
        components.queryItems = [URLQueryItem(name: "id", value: String(appID)), URLQueryItem(name: "country", value: "my")]
        do {
            guard let lookupURL = components.url else { return nil }
            let (data, response) = try await session.data(from: lookupURL)
            guard (response as? HTTPURLResponse)?.statusCode == 200,
                  let artwork = try JSONDecoder().decode(Lookup.self, from: data).results.first?.artworkUrl512.flatMap(URL.init(string:)),
                  // Only ever load images from Apple's CDN.
                  artwork.scheme == "https", artwork.host?.hasSuffix(".mzstatic.com") == true
            else { return nil }
            let (imageData, imageResponse) = try await session.data(from: artwork)
            guard (imageResponse as? HTTPURLResponse)?.statusCode == 200,
                  let image = Self.downsample(imageData, maxPixelSize: Self.maxPixelSize) else { return nil }
            if let png = image.pngData() {
                try? png.write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            }
            return image
        } catch {
            log.info("Logo \(appID, privacy: .public) unavailable: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// Decodes straight to a small bitmap with ImageIO instead of `UIImage(data:)` at full size.
    private static func downsample(_ data: Data, maxPixelSize: Int) -> UIImage? {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions) else { return nil }
        let options = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ] as CFDictionary
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options) else { return nil }
        return UIImage(cgImage: image)
    }
}
