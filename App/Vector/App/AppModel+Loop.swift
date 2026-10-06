import Foundation
import VectorCore

/// The closed loop: goal → training and nutrition → body weight and
/// performance → analysis → adjustment → today's recommendation. The weekly
/// decision itself lives in `AppModel+Coaching`.
extension AppModel {
    /// Legacy calorie check-ins (before the Weekly Coach Check-In). Kept so
    /// existing users' last review date carries over.
    var checkIns: [NutritionCheckIn] { data.checkIns ?? [] }
}
