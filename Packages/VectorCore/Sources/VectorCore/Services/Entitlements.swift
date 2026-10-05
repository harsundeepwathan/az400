import Foundation

public enum SubscriptionTier: String, Codable, Hashable, Sendable {
    case free, pro
}

public enum ProFeature: String, CaseIterable, Hashable, Sendable {
    case aiMealScanning
    case aiWorkoutRecommendations
    case progressiveOverload
    case advancedAnalytics
    case unlimitedPrograms
    case nutritionInsights
    case exerciseSubstitution
    case unlimitedHistory
    case aiCoach
    case watchEnhanced

    public var title: String {
        switch self {
        case .aiMealScanning: "Unlimited AI meal scans"
        case .aiWorkoutRecommendations: "AI workout recommendations"
        case .progressiveOverload: "Smart progressive overload"
        case .advancedAnalytics: "Advanced progress analytics"
        case .unlimitedPrograms: "Unlimited routines & programs"
        case .nutritionInsights: "Advanced nutrition insights"
        case .exerciseSubstitution: "Intelligent exercise swaps"
        case .unlimitedHistory: "Unlimited history"
        case .aiCoach: "Personalized coaching insights"
        case .watchEnhanced: "Enhanced Apple Watch experience"
        }
    }

    public var symbol: String {
        switch self {
        case .aiMealScanning: "camera.viewfinder"
        case .aiWorkoutRecommendations: "sparkles"
        case .progressiveOverload: "chart.line.uptrend.xyaxis"
        case .advancedAnalytics: "chart.bar.xaxis"
        case .unlimitedPrograms: "list.bullet.rectangle"
        case .nutritionInsights: "leaf"
        case .exerciseSubstitution: "arrow.triangle.swap"
        case .unlimitedHistory: "clock.arrow.circlepath"
        case .aiCoach: "brain.head.profile"
        case .watchEnhanced: "applewatch"
        }
    }
}

/// Free-tier limits and the rules for when it's appropriate to talk about
/// upgrading. The core principle: never interrupt training, and only pitch
/// Pro after the product has demonstrated value with the user's own data.
public struct EntitlementPolicy: Sendable {
    public static let freeMealScansPerWeek = 3
    public static let freeCustomRoutines = 3
    public static let freeHistoryDays = 90
    /// Minimum finished workouts before an in-product upgrade moment appears.
    public static let upgradeMomentMinimumWorkouts = 3
    public static let upgradeMomentCooldown: TimeInterval = 7 * 86_400

    public let calendar: Calendar

    public init(calendar: Calendar = .current) {
        self.calendar = calendar
    }

    public func scansRemaining(tier: SubscriptionTier, scanDates: [Date], now: Date) -> Int? {
        guard tier == .free else { return nil }
        let week = calendar.dateInterval(of: .weekOfYear, for: now)
        let used = scanDates.filter { week?.contains($0) ?? false }.count
        return max(Self.freeMealScansPerWeek - used, 0)
    }

    public func canScan(tier: SubscriptionTier, scanDates: [Date], now: Date) -> Bool {
        (scansRemaining(tier: tier, scanDates: scanDates, now: now) ?? 1) > 0
    }

    public func canCreateRoutine(tier: SubscriptionTier, existingCustomRoutines: Int) -> Bool {
        tier == .pro || existingCustomRoutines < Self.freeCustomRoutines
    }

    /// Earliest date a free user can browse history from.
    public func historyCutoff(tier: SubscriptionTier, now: Date) -> Date? {
        guard tier == .free else { return nil }
        return calendar.date(byAdding: .day, value: -Self.freeHistoryDays, to: calendar.startOfDay(for: now))
    }

    public func shouldShowUpgradeMoment(
        tier: SubscriptionTier,
        finishedWorkouts: Int,
        progressionOpportunities: Int,
        isWorkoutActive: Bool,
        lastShown: Date?,
        now: Date
    ) -> Bool {
        guard tier == .free, !isWorkoutActive else { return false }
        guard finishedWorkouts >= Self.upgradeMomentMinimumWorkouts, progressionOpportunities > 0 else { return false }
        if let lastShown, now.timeIntervalSince(lastShown) < Self.upgradeMomentCooldown { return false }
        return true
    }
}
