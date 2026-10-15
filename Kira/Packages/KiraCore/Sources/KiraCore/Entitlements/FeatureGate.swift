import Foundation

public enum SubscriptionTier: Int, Codable, Comparable, CaseIterable, Sendable {
    case free = 0, plus = 1, premium = 2

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }

    public var displayName: String {
        switch self {
        case .free: return "Free"
        case .plus: return "Plus"
        case .premium: return "Premium"
        }
    }
}

public enum Feature: String, CaseIterable, Sendable {
    // Always free — the user's data is never held hostage.
    case manualTracking, basicBudgets, dashboard, exportData, deleteData, viewHistory, editTransactions, subscriptionTracking
    // Plus
    case unlimitedImports, advancedReceiptExtraction, shortcutsCapture, advancedReconciliation, customRules, detailedAnalytics
    // Premium
    case cashFlowForecast, debtAnalytics, multiAccountInsights, advancedReports, cloudSync

    public var requiredTier: SubscriptionTier {
        switch self {
        case .manualTracking, .basicBudgets, .dashboard, .exportData, .deleteData, .viewHistory, .editTransactions, .subscriptionTracking: return .free
        case .unlimitedImports, .advancedReceiptExtraction, .shortcutsCapture, .advancedReconciliation, .customRules, .detailedAnalytics: return .plus
        case .cashFlowForecast, .debtAnalytics, .multiAccountInsights, .advancedReports, .cloudSync: return .premium
        }
    }
}

/// Central entitlement decisions. Tier comes from StoreKit 2 verified transactions in the app.
public struct FeatureGate: Sendable {
    public var tier: SubscriptionTier
    /// Free-tier statement imports per calendar month.
    public var freeImportsPerMonth: Int

    public init(tier: SubscriptionTier, freeImportsPerMonth: Int = 3) {
        self.tier = tier
        self.freeImportsPerMonth = freeImportsPerMonth
    }

    public func isAvailable(_ feature: Feature) -> Bool {
        tier >= feature.requiredTier
    }

    /// Whether another statement import is allowed this month.
    public func canImport(importsThisMonth: Int) -> Bool {
        isAvailable(.unlimitedImports) || importsThisMonth < freeImportsPerMonth
    }

    public func remainingFreeImports(importsThisMonth: Int) -> Int? {
        isAvailable(.unlimitedImports) ? nil : max(freeImportsPerMonth - importsThisMonth, 0)
    }
}
