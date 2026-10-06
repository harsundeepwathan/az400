import Foundation

/// Which digest "See the data it used" shows for a summary.
public struct CoachDigestShown: Hashable, Sendable {
    public var digest: CoachDigest
    /// True when `digest` is exactly what the summary was written from.
    /// False means it is today's digest and the summary may be older than it.
    public var isExact: Bool

    public init(digest: CoachDigest, isExact: Bool) {
        self.digest = digest
        self.isExact = isExact
    }
}

/// Keeps the digest that today's coach summary was generated from, so the
/// app can show the numbers the summary actually used. The server stores
/// one summary per user per UTC day and returns it with `cached: true` for
/// the rest of that day, even if the user has logged more since; the digest
/// sent with that later request is not what the summary was written from.
///
/// One small JSON file on this device (the latest summary only); it holds
/// the user's own numbers, so it uses complete file protection on iOS.
public struct CoachSummaryArchive: Sendable {
    public struct Record: Codable, Hashable, Sendable {
        /// The server's UTC day (`yyyy-MM-dd`) the summary belongs to.
        public var day: String
        public var generatedAt: Date?
        /// The account it was generated for, so a different sign-in never sees it.
        public var userID: String?
        public var digest: CoachDigest
    }

    public let fileURL: URL

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    /// `Application Support/coach-summary-digest.json`.
    public static func standard() throws -> CoachSummaryArchive {
        let support = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                  appropriateFor: nil, create: true)
        return CoachSummaryArchive(fileURL: support.appendingPathComponent("coach-summary-digest.json", isDirectory: false))
    }

    /// The server keys summaries by UTC day.
    public static func serverDay(_ date: Date) -> String {
        CoachDigestBuilder.dayString(date, timeZone: TimeZone(identifier: "UTC") ?? TimeZone(secondsFromGMT: 0)!)
    }

    /// Records a freshly generated summary's digest, or looks up the stored
    /// one for a cached summary. `sent` is the digest sent with this request;
    /// `now` is used only when the server sent no `generated_at`.
    public func digestShown(for summary: CoachSummary, sent: CoachDigest, userID: String?, now: Date) -> CoachDigestShown {
        let day = Self.serverDay(summary.generatedAt ?? now)
        if !summary.cached {
            save(Record(day: day, generatedAt: summary.generatedAt, userID: userID, digest: sent))
            return CoachDigestShown(digest: sent, isExact: true)
        }
        if let stored = load(), stored.day == day, stored.userID == userID, Self.sameMoment(stored.generatedAt, summary.generatedAt) {
            return CoachDigestShown(digest: stored.digest, isExact: true)
        }
        return CoachDigestShown(digest: sent, isExact: false)
    }

    public func load() -> Record? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? JSONDecoder().decode(Record.self, from: data)
    }

    public func save(_ record: Record) {
        guard let data = try? JSONEncoder().encode(record) else { return }
        #if os(iOS) || os(watchOS) || os(tvOS) || os(visionOS)
        try? data.write(to: fileURL, options: [.atomic, .completeFileProtection])
        #else
        try? data.write(to: fileURL, options: [.atomic])
        #endif
    }

    /// Deletes the stored digest (reset, sign-out).
    public func clear() {
        try? FileManager.default.removeItem(at: fileURL)
    }

    /// Both timestamps come from the same server value; a missing one can't
    /// contradict the day match.
    static func sameMoment(_ a: Date?, _ b: Date?) -> Bool {
        guard let a, let b else { return true }
        return abs(a.timeIntervalSince(b)) < 1
    }
}
