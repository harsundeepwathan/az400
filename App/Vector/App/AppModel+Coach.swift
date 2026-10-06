import Foundation
import VectorCore

/// The AI-written weekly summary (Pro). The digest is built on device from
/// the user's logs; the server only turns those numbers into sentences.
extension AppModel {
    /// Pro, signed in and a backend configured. Everyone else sees nothing new.
    var canShowCoachSummary: Bool { isPro && isSignedIn && api != nil }

    /// This week's digest from the full history, as the insight engine sees it.
    var coachDigest: CoachDigest? {
        guard let profile = data.profile else { return nil }
        let context = CoachContext(sessions: data.sessions, foodEntries: data.foodEntries, bodyWeights: data.bodyWeights,
                                   program: data.program, profile: profile, now: now())
        return CoachDigestBuilder(catalog: catalog, calendar: calendar).build(context, recommendations: recommendations)
    }

    func coachSummary(for digest: CoachDigest) async throws -> CoachSummary {
        guard let api else { throw CoachSummaryError.signedOut }
        return try await api.coachSummary(digest: digest)
    }
}

/// Nutrition charts on Progress.
extension AppModel {
    var foodEntries: [FoodEntry] { data.foodEntries }
    var nutritionTargets: NutritionTargets? { data.profile?.targets }
}
