import Foundation
import VectorCore

/// The AI-written weekly summary (Pro). The digest is built on device from
/// the user's logs; the server only turns those numbers into sentences.
extension AppModel {
    /// Pro, signed in and a backend configured. Everyone else sees nothing new.
    var canShowCoachSummary: Bool { isPro && isSignedIn && api != nil }

    /// This week's digest from the full history, as the insight engine sees it.
    /// While insights are still computing, `recommendations` is empty or stale,
    /// so the builder computes them itself rather than sending none. The
    /// summary card waits for insights anyway; this keeps the digest right
    /// for any other caller.
    var coachDigest: CoachDigest? {
        guard let profile = data.profile else { return nil }
        let context = CoachContext(sessions: data.sessions, foodEntries: data.foodEntries, bodyWeights: data.bodyWeights,
                                   program: data.program, profile: profile, now: now())
        return CoachDigestBuilder(catalog: catalog, calendar: calendar)
            .build(context, recommendations: isComputingInsights ? nil : recommendations)
    }

    /// The summary plus the digest it was written from. A fresh summary's
    /// digest is stored; a cached one (the server keeps one per UTC day) is
    /// matched to the stored digest, or falls back to today's, flagged as
    /// possibly newer than the summary.
    func coachSummary(for digest: CoachDigest) async throws -> (summary: CoachSummary, shown: CoachDigestShown) {
        guard let api else { throw CoachSummaryError.signedOut }
        let summary = try await api.coachSummary(digest: digest)
        guard let archive = coachSummaryArchive else {
            return (summary, CoachDigestShown(digest: digest, isExact: !summary.cached))
        }
        return (summary, archive.digestShown(for: summary, sent: digest, userID: api.userID, now: now()))
    }

    /// Nil only if Application Support is unavailable.
    var coachSummaryArchive: CoachSummaryArchive? { try? CoachSummaryArchive.standard() }
}

/// Nutrition charts on Progress.
extension AppModel {
    var foodEntries: [FoodEntry] { data.foodEntries }
    var nutritionTargets: NutritionTargets? { data.profile?.targets }
}
