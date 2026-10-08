import Foundation
import VectorCore

extension AppModel {
    /// "Today's insight": up to three positive, checkable facts from the
    /// user's own logs, lead first. Empty when nothing passes the rules.
    var dailyHighlights: [DailyHighlight] {
        DailyHighlightEngine(calendar: calendar)
            .highlights(sessions: sessions, foodEntries: data.foodEntries,
                        proteinTarget: profile?.targets.protein ?? 0, now: now())
    }

    /// The quick-log menu behind the + in the tab bar.
    var quickLogItems: [FloatingTabBar.QuickLogItem] {
        let meal = MealType.suggested(forHour: calendar.component(.hour, from: now()))
        let workout: FloatingTabBar.QuickLogItem = if activeWorkout != nil {
            .init(title: "Resume workout", symbol: "play.fill") { [weak self] in self?.resumeWorkout() }
        } else if let next = nextWorkout {
            .init(title: "Start \(next.name)", symbol: "play.fill") { [weak self] in self?.startWorkout(next) }
        } else {
            .init(title: "Start workout", symbol: "play.fill") { [weak self] in self?.startEmptyWorkout() }
        }
        return [
            workout,
            .init(title: "Scan a meal", symbol: Icon.scan) { [weak self] in self?.cover = .scanner(meal) },
            .init(title: "Log food", symbol: Icon.search) { [weak self] in self?.sheet = .foodSearch(meal) },
            .init(title: "Quick add calories", symbol: Icon.add) { [weak self] in self?.sheet = .quickAdd(meal) },
            .init(title: "Weigh in", symbol: "scalemass") { [weak self] in self?.sheet = .bodyWeight }
        ]
    }
}
