import Foundation
import VectorCore

/// Four tabs, like Apple Fitness and Health: sections, never settings.
/// Profile and settings open from the avatar on Today.
enum AppTab: String, Hashable, CaseIterable {
    case today, train, nutrition, progress

    var title: String { rawValue.capitalized }

    var symbol: String {
        switch self {
        case .today: Icon.today
        case .train: Icon.train
        case .nutrition: Icon.nutrition
        case .progress: Icon.progress
        }
    }
}

/// Why the paywall was opened. It tailors the headline and is recorded so
/// we can learn which moments convert, without ever blocking a workout.
enum PaywallTrigger: String, Hashable {
    case profile, progressionMoment, insight, analytics, mealScanQuota, substitution, routineLimit, history, coach
}

/// Sheets presented from the root, reachable from any tab (insight actions,
/// quick actions, deep links, widgets).
enum RootSheet: Identifiable, Hashable {
    case exercise(String)
    case foodSearch(MealType)
    case quickAdd(MealType)
    case barcode(MealType)
    case savedMeals(MealType)
    case coach
    case recommendations
    case bodyWeight
    case paywall(PaywallTrigger)
    case profile

    var id: String {
        switch self {
        case .exercise(let id): "exercise-\(id)"
        case .foodSearch(let meal): "search-\(meal.rawValue)"
        case .quickAdd(let meal): "quick-\(meal.rawValue)"
        case .barcode(let meal): "barcode-\(meal.rawValue)"
        case .savedMeals(let meal): "saved-\(meal.rawValue)"
        case .coach: "coach"
        case .recommendations: "recommendations"
        case .bodyWeight: "body-weight"
        case .paywall(let trigger): "paywall-\(trigger.rawValue)"
        case .profile: "profile"
        }
    }
}

/// Full-screen flows.
enum RootCover: Identifiable, Hashable {
    case workout
    case scanner(MealType)
    case summary(UUID)

    var id: String {
        switch self {
        case .workout: "workout"
        case .scanner(let meal): "scanner-\(meal.rawValue)"
        case .summary(let id): "summary-\(id)"
        }
    }
}

struct ToastMessage: Identifiable, Equatable {
    let id = UUID()
    var symbol: String
    var title: String
    var subtitle: String?
}
