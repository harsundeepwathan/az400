import Foundation

/// Compile-time feature flags for integrations that are not verified for Malaysia.
///
/// - financeKit: FinanceKit requires the managed `com.apple.developer.financekit` entitlement,
///   granted by Apple on request, and covers Apple Wallet accounts only in the regions Apple
///   lists (it launched with Apple Card, Apple Cash and Savings in the US). We have found no
///   evidence that Malaysian cards are supported as of this build. Kept OFF until Apple confirms
///   eligibility for Malaysian accounts and the entitlement is approved. No FinanceKit code is
///   linked while the flag is off.
/// - cloudSync: Optional Supabase sync. The schema (with Row Level Security) is in
///   `supabase/migrations`, but the client is not implemented or validated; OFF.
enum FeatureFlags {
    static let financeKit = false
    static let cloudSync = false
}
