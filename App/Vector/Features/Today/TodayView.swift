import SwiftUI
import VectorCore

/// The daily dashboard: a grid of tiles on a grey canvas. Today's insight
/// leads (something new every day), then the workout tile with the one
/// primary action (Start), then Calories and Body side by side. The weekly
/// check-in and the upgrade moment join as full-width tiles when they apply.
struct TodayView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var showsCheckIn = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 12) {
                    header
                    let highlights = model.dailyHighlights
                    if !highlights.isEmpty {
                        InsightTile(highlights: highlights)
                    }
                    WorkoutTile(volumeRise: volumeRise(highlights))
                    if model.showsWeeklyCheckIn, let review = model.weeklyReview {
                        CheckInTile(review: review) { showsCheckIn = true }
                            .transition(.opacity)
                    }
                    pair
                    if model.shouldShowUpgradeMoment {
                        UpgradeTile().transition(.opacity)
                    }
                }
                .padding(.horizontal, Space.gutter)
                .padding(.bottom, Space.lg)
            }
            .background(WColor.canvas.ignoresSafeArea())
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(for: WorkoutTemplate.self) { TemplateDetailView(template: $0) }
            .animation(Motion.adaptive(Motion.smooth, reduceMotion: reduceMotion), value: model.coachDecisions.count)
            .onChange(of: model.showsWeeklyCheckIn) { _, shows in
                if !shows { showsCheckIn = false }
            }
            .weeklyCheckInSheet(isPresented: $showsCheckIn)
        }
    }

    private var header: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 0) {
                Text(Format.longDate(model.now(), calendar: model.calendar))
                    .font(.system(.subheadline, weight: .medium))
                    .foregroundStyle(WColor.textSecondary)
                Text("Today")
                    .font(.system(.largeTitle, weight: .bold))
                    .foregroundStyle(WColor.textPrimary)
                    .accessibilityAddTraits(.isHeader)
            }
            Spacer(minLength: Space.sm)
            Button {
                model.sheet = .profile
            } label: {
                Text(String(model.firstName.prefix(1)).uppercased())
                    .font(.system(.subheadline, weight: .semibold))
                    .foregroundStyle(WColor.textPrimary)
                    .frame(width: 38, height: 38)
                    .background(WColor.innerStrong, in: Circle())
                    .frame(width: Size.minTouch, height: Size.minTouch)
                    .contentShape(Circle())
            }
            .buttonStyle(.pressable)
            .accessibilityLabel("Profile")
        }
        .padding(.horizontal, 4)
        .padding(.top, Space.xs)
        .padding(.bottom, Space.xxs)
    }

    /// Calories and Body side by side at equal height; stacked at accessibility text sizes.
    @ViewBuilder private var pair: some View {
        if dynamicTypeSize.isAccessibilitySize {
            VStack(spacing: 12) { CaloriesTile(); BodyTile() }
        } else {
            HStack(alignment: .top, spacing: 12) { CaloriesTile(); BodyTile() }
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// The workout tile's "+x% volume" chip appears only when the highlight
    /// rules found a real rise against the same point last week.
    private func volumeRise(_ highlights: [DailyHighlight]) -> Double? {
        for highlight in highlights {
            if case .weeklyVolume(let now, let before) = highlight.fact, before > 0 { return now / before - 1 }
        }
        return nil
    }
}

// MARK: - Today's insight

private struct InsightTile: View {
    var highlights: [DailyHighlight]
    @Environment(AppModel.self) private var model
    @State private var page = 0

    var body: some View {
        WidgetTile(tint: .insight, title: "Today's insight", symbol: "bolt.fill", titleIsTinted: true,
                   open: { model.selectedTab = .progress }) {
            TabView(selection: $page) {
                ForEach(Array(highlights.enumerated()), id: \.element.id) { index, highlight in
                    InsightPage(display: HighlightDisplay(highlight, model: model))
                        .tag(index)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .frame(height: 196)
            if highlights.count > 1 {
                PageDots(count: highlights.count, current: page, tint: .insight)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 4)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityHint(highlights.count > 1 ? "Swipe left or right for more" : "")
    }
}

private struct InsightPage: View {
    var display: HighlightDisplay

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(display.value)
                    .font(.system(size: 48, weight: .bold, design: .default).monospacedDigit())
                    .foregroundStyle(WColor.textPrimary)
                    .minimumScaleFactor(0.6)
                Text(display.unit)
                    .font(.system(.headline))
                    .foregroundStyle(WColor.textSecondary)
            }
            display.sentence
                .font(.subheadline)
                .foregroundStyle(WColor.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 2)
            Spacer(minLength: 10)
            if !display.bars.isEmpty {
                ComparisonBars(rows: display.bars, tint: .insight)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(.top, 8)
        .accessibilityElement(children: .combine)
    }
}

/// How each highlight reads: a big value, a unit, one sentence with the
/// important words in bold, and the comparison it rests on.
private struct HighlightDisplay {
    var value: String
    var unit: String
    var sentence: Text
    var bars: [ComparisonBars.Row]

    @MainActor init(_ highlight: DailyHighlight, model: AppModel) {
        let unitSymbol = model.unit.symbol
        func name(_ id: String) -> String { (model.catalog[id]?.name ?? id).lowercased() }
        func percent(_ now: Double, _ before: Double) -> String { "\(Int(((now / before - 1) * 100).rounded()))%" }

        switch highlight.fact {
        case .liftReps(let id, let thisWeek, let lastWeek):
            value = "\(thisWeek)"
            unit = "reps"
            sentence = Text("of ") + Text(name(id)).bold().foregroundColor(WColor.textPrimary)
                + Text(" this week. That's ") + Text("\(percent(Double(thisWeek), Double(lastWeek))) more").bold().foregroundColor(WColor.textPrimary)
                + Text(" than this point last week.")
            bars = [.init(label: "Last week", value: Double(lastWeek), display: "\(lastWeek)", isCurrent: false),
                    .init(label: "This week", value: Double(thisWeek), display: "\(thisWeek)", isCurrent: true)]
        case .liftGain(let id, let from, let to, let weeks):
            value = "+" + Format.weight(to - from, unit: model.unit, includeUnit: false)
            unit = unitSymbol
            sentence = Text("on your ") + Text(name(id)).bold().foregroundColor(WColor.textPrimary)
                + Text(" in \(weeks) weeks, from your own logged sets.")
            bars = [.init(label: "\(weeks) wk ago", value: from, display: Format.weight(from, unit: model.unit, includeUnit: false), isCurrent: false),
                    .init(label: "Now", value: to, display: Format.weight(to, unit: model.unit, includeUnit: false), isCurrent: true)]
        case .weeklyVolume(let thisWeek, let lastWeek):
            value = "+" + percent(thisWeek, lastWeek)
            unit = "volume"
            sentence = Text("more weight moved than at this point last week.")
            bars = [.init(label: "Last week", value: lastWeek, display: Format.volume(lastWeek, unit: model.unit), isCurrent: false),
                    .init(label: "This week", value: thisWeek, display: Format.volume(thisWeek, unit: model.unit), isCurrent: true)]
        case .proteinDays(let onTarget, let days):
            value = "\(onTarget) of \(days)"
            unit = "days"
            sentence = Text("on your ") + Text("protein target").bold().foregroundColor(WColor.textPrimary) + Text(" this past week.")
            bars = [.init(label: "On target", value: Double(onTarget), display: "\(onTarget)/\(days)", isCurrent: true, scale: Double(days))]
        case .milestone(let workouts):
            value = "\(workouts)"
            unit = workouts == 1 ? "workout" : "workouts"
            sentence = Text("logged so far. After two weeks, Vector starts comparing you with your own history.")
            bars = []
        }
    }
}

// MARK: - Workouts

private struct WorkoutTile: View {
    var volumeRise: Double?
    @Environment(AppModel.self) private var model

    var body: some View {
        WidgetTile(tint: .training, title: "Workouts", symbol: "dumbbell.fill",
                   open: { model.selectedTab = .train }) {
            if let volumeRise {
                WidgetChip(title: "+\(Int((volumeRise * 100).rounded()))% volume", symbol: "arrow.up.right",
                           foreground: WColor.rise, background: WColor.riseSoft)
                    .accessibilityLabel("Volume up \(Int((volumeRise * 100).rounded())) percent on last week")
            }
        } content: {
            HStack(alignment: .top, spacing: 14) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Last 7 days").font(.footnote).foregroundStyle(WColor.textSecondary)
                    WeekBars(days: lastSevenDays, tint: .training)
                        .frame(height: 132)
                }
                TodayPanel()
                    .frame(width: 158)
            }
            .padding(.top, 10)

            if let target = nextTarget {
                divider
                HStack(spacing: 12) {
                    Image(systemName: "scope")
                        .font(.system(.body, weight: .semibold))
                        .foregroundStyle(WidgetTint.training.ink)
                        .frame(width: 36, height: 36)
                        .background(WColor.innerStrong, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Next target · \(target.exercise)").font(.footnote).foregroundStyle(WColor.textSecondary)
                        Text(target.load).font(.system(.body, weight: .semibold).monospacedDigit()).foregroundStyle(WColor.textPrimary)
                    }
                    Spacer(minLength: 8)
                    if let delta = target.delta {
                        Text(delta)
                            .font(.system(.subheadline, weight: .bold).monospacedDigit())
                            .foregroundStyle(WidgetTint.training.ink)
                    }
                }
                .accessibilityElement(children: .combine)
            }

            if let last = model.sessions.first {
                divider
                (Text("Last workout · ") + Text(last.name).bold().foregroundColor(WColor.textPrimary)
                 + Text(", \(last.startedAt.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated)))"))
                    .font(.footnote)
                    .foregroundStyle(WColor.textSecondary)
                HStack(alignment: .top) {
                    stat("Sets", "\(last.completedSetCount)")
                    stat("Exercises", "\(last.exercises.count)")
                    stat("Time", Format.clock(last.duration))
                    stat("Volume", Format.volume(last.volume, unit: model.unit))
                }
                .padding(.top, 8)
            }
        }
    }

    private var divider: some View {
        Rectangle().fill(WColor.divider).frame(height: 1).padding(.vertical, 14)
    }

    private func stat(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.footnote).foregroundStyle(WColor.textSecondary)
            Text(value)
                .font(.system(.title3, weight: .bold).monospacedDigit())
                .foregroundStyle(WColor.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    /// Volume per day for the last seven days, ending today.
    private var lastSevenDays: [WeekBars.Day] {
        let calendar = model.calendar
        let today = calendar.startOfDay(for: model.now())
        let days = (0..<7).reversed().compactMap { calendar.date(byAdding: .day, value: -$0, to: today) }
        let volumes = days.map { day in
            model.sessions.filter { calendar.isDate($0.startedAt, inSameDayAs: day) }.reduce(0) { $0 + $1.volume }
        }
        let top = volumes.max() ?? 0
        return zip(days, volumes).map { day, volume in
            let letter = calendar.veryShortWeekdaySymbols[calendar.component(.weekday, from: day) - 1]
            return WeekBars.Day(id: day, letter: letter, fraction: volume > 0 && top > 0 ? volume / top : nil,
                                isToday: day == today)
        }
    }

    /// The first lift of the next workout, when the engine moves it up.
    private var nextTarget: (exercise: String, load: String, delta: String?)? {
        guard model.activeWorkout == nil, let template = model.nextWorkout,
              let item = template.exercises.first, let exercise = model.catalog[item.exerciseID],
              let recommendation = model.recommendations.first(where: { $0.exerciseID == item.exerciseID }),
              recommendation.action.isProgression, let weight = recommendation.weight else { return nil }
        let load = "\(Format.weight(weight, unit: model.unit)) × \(recommendation.reps)"
        let previous = model.sessions.lazy.compactMap { $0.log(for: item.exerciseID)?.heaviestSet?.weight }.first
        let delta = previous.flatMap { weight > $0 ? "+" + Format.weight(weight - $0, unit: model.unit) : nil }
        return (exercise.name, load, delta)
    }
}

/// The inner panel of the workout tile: what's on today and the one action.
private struct TodayPanel: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Label(state.label, systemImage: state.symbol)
                .font(.system(.footnote, weight: .semibold))
                .foregroundStyle(WColor.textSecondary)
            Text(state.title)
                .font(.system(.title2, weight: .bold))
                .foregroundStyle(WColor.textPrimary)
                .lineLimit(2)
                .minimumScaleFactor(0.7)
                .padding(.top, 8)
            if let detail = state.detail {
                Text(detail)
                    .font(.footnote.monospacedDigit())
                    .foregroundStyle(WColor.textSecondary)
                    .padding(.top, 2)
            }
            Spacer(minLength: 12)
            if let action = state.action {
                Button(action: action.run) {
                    Label(action.title, systemImage: action.symbol)
                        .font(.system(.subheadline, weight: .bold))
                        .foregroundStyle(WColor.onStrong)
                        .frame(maxWidth: .infinity)
                        .frame(height: Size.minTouch)
                        .background(WColor.strong, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                .buttonStyle(.pressable)
            }
        }
        .padding(14)
        .frame(maxHeight: .infinity, alignment: .topLeading)
        .background(WColor.inner, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    private struct PanelState {
        var label: String
        var symbol: String
        var title: String
        var detail: String?
        var action: (title: String, symbol: String, run: () -> Void)?
    }

    private var state: PanelState {
        if let workout = model.activeWorkout {
            return PanelState(label: "In progress", symbol: "timer", title: workout.session.name,
                              detail: "\(workout.completedSets) of \(workout.totalSets) sets",
                              action: ("Resume", "play.fill", { model.resumeWorkout() }))
        }
        if let done = model.sessions.first(where: { model.calendar.isDate($0.startedAt, inSameDayAs: model.now()) }) {
            return PanelState(label: "Done today", symbol: "checkmark.circle.fill", title: done.name,
                              detail: model.nextWorkout.map { "Next: \($0.name)" }, action: nil)
        }
        if let next = model.nextWorkout {
            return PanelState(label: "Today", symbol: "calendar", title: next.name,
                              detail: "\(next.estimatedMinutes(catalog: model.catalog)) min · \(next.exercises.count) exercises",
                              action: ("Start", "play.fill", { model.startWorkout(next) }))
        }
        return PanelState(label: "Today", symbol: "calendar", title: "No workout planned", detail: nil,
                          action: ("Start", "play.fill", { model.startEmptyWorkout() }))
    }
}

// MARK: - Calories and Body

private struct CaloriesTile: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let day = model.nutrition(on: model.now())
        let remaining = day.caloriesRemaining
        WidgetTile(tint: .calories, title: "Calories", symbol: "fork.knife",
                   open: { model.selectedTab = .nutrition }) {
            ZStack {
                GradientRing(progress: day.targets.calories > 0 ? day.consumed.calories / day.targets.calories : 0,
                             lineWidth: 12, colors: [WidgetTint.calories.accent, WidgetTint.calories.accentEnd])
                VStack(spacing: 0) {
                    Text(Format.integer(abs(remaining)))
                        .font(.system(.title, weight: .bold).monospacedDigit())
                        .foregroundStyle(WColor.textPrimary)
                        .contentTransition(.numericText())
                    Text(remaining >= 0 ? "kcal left" : "kcal over")
                        .font(.footnote)
                        .foregroundStyle(remaining >= 0 ? WColor.textSecondary : VColor.warning)
                }
            }
            .frame(width: 124, height: 124)
            .frame(maxWidth: .infinity)
            .padding(.top, 10)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Calories")
            .accessibilityValue("\(Format.integer(day.consumed.calories)) of \(Format.integer(day.targets.calories)), "
                                + "\(Format.integer(abs(remaining))) \(remaining >= 0 ? "left" : "over")")

            (Text(Format.integer(day.consumed.calories)).bold().foregroundColor(WColor.textPrimary)
             + Text(" / \(Format.integer(day.targets.calories)) kcal"))
                .font(.footnote.monospacedDigit())
                .foregroundStyle(WColor.textSecondary)
                .frame(maxWidth: .infinity)
                .padding(.top, 8)
                .accessibilityHidden(true)

            HStack {
                WidgetMacroRing(letter: "P", name: "Protein", consumed: day.consumed.protein, target: day.targets.protein, color: WColor.protein)
                Spacer(minLength: 4)
                WidgetMacroRing(letter: "C", name: "Carbs", consumed: day.consumed.carbs, target: day.targets.carbs, color: WColor.carbs)
                Spacer(minLength: 4)
                WidgetMacroRing(letter: "F", name: "Fat", consumed: day.consumed.fat, target: day.targets.fat, color: WColor.fat)
            }
            .padding(.top, 12)
        }
    }
}

private struct BodyTile: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        WidgetTile(tint: .body, title: "Body", symbol: "figure.stand",
                   open: { model.selectedTab = .progress }) {
            if let latest = model.latestBodyWeight {
                let recent = model.bodyWeights.suffix(7).map(\.kilograms)
                let trend = CoachMetrics(calendar: model.calendar).weightTrend(model.bodyWeights, days: 28, now: model.now())

                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(Format.weight(latest.kilograms, unit: model.unit, includeUnit: false))
                        .font(.system(size: 38, weight: .bold).monospacedDigit())
                        .foregroundStyle(WColor.textPrimary)
                        .minimumScaleFactor(0.6)
                    Text(model.unit.symbol)
                        .font(.system(.headline))
                        .foregroundStyle(WColor.textSecondary)
                }
                .padding(.top, 10)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Latest weigh-in \(Format.weight(latest.kilograms, unit: model.unit))")

                if recent.count >= 2 {
                    WidgetSparkline(values: Array(recent), tint: .body)
                        .frame(height: 60)
                        .padding(.top, 8)
                }
                if let trend {
                    Text("\(signed(trend.kgPerWeek))/wk")
                        .font(.system(.subheadline, weight: .semibold).monospacedDigit())
                        .foregroundStyle(WidgetTint.body.ink)
                        .padding(.top, 10)
                        .accessibilityLabel("Trend \(signed(trend.kgPerWeek)) a week")
                }
                if let goal = model.profile?.targetWeightKg, goal > 0 {
                    Text("Goal \(Format.weight(goal, unit: model.unit))")
                        .font(.footnote)
                        .foregroundStyle(WColor.textSecondary)
                        .padding(.top, 2)
                }
            } else {
                Text("Log your weight to start a trend.")
                    .font(.subheadline)
                    .foregroundStyle(WColor.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 10)
            }
            Spacer(minLength: 12)
            Button {
                model.sheet = .bodyWeight
            } label: {
                WidgetChip(title: "Weigh in", symbol: "plus")
                    .frame(minHeight: Size.minTouch)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.pressable)
        }
    }

    private func signed(_ kgPerWeek: Double) -> String {
        let sign = kgPerWeek >= 0 ? "+" : "\u{2212}"
        return "\(sign)\(Format.weight(abs(kgPerWeek), unit: model.unit))"
    }
}

// MARK: - Weekly check-in and upgrade

private struct CheckInTile: View {
    var review: WeeklyReview
    var onReview: () -> Void
    @Environment(AppModel.self) private var model

    var body: some View {
        WidgetTile(tint: .training, title: "Weekly check-in", symbol: "calendar.badge.checkmark") {
            HStack(alignment: .center, spacing: Space.md) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Ready to review")
                        .font(.system(.title3, weight: .bold))
                        .foregroundStyle(WColor.textPrimary)
                    Text(line)
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(WColor.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                Button("Review", action: onReview)
                    .font(.system(.subheadline, weight: .bold))
                    .foregroundStyle(WColor.onStrong)
                    .padding(.horizontal, 18)
                    .frame(height: Size.minTouch)
                    .background(WColor.strong, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .buttonStyle(.pressable)
                    .accessibilityHint("Opens the weekly check-in")
            }
            .padding(.top, 10)
        }
    }

    /// Free users see their week; the decision itself is Pro.
    private var line: String {
        guard model.isPro else { return "Your week in numbers" }
        return switch review.recommendation {
        case .onTrack: "Everything is on track. No changes."
        case .watch: "Hold steady for one more week."
        case .improveAdherence: "Focus on consistency first."
        case .learningBaseline: "Vector is still learning your baseline."
        case .adjustCalories(let from, let to, _): "Calories \(Format.integer(from)) → \(Format.integer(to)) a day"
        }
    }
}

/// Shown once value has been demonstrated (several workouts, real
/// progression opportunities), never during a workout, at most weekly.
private struct UpgradeTile: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let count = model.progressionOpportunities.count
        WidgetTile(tint: .training, title: "Progression", symbol: "chart.line.uptrend.xyaxis") {
            Button {
                withAnimation(Motion.adaptive(Motion.smooth, reduceMotion: reduceMotion)) { model.dismissUpgradeMoment() }
            } label: {
                Image(systemName: "xmark")
                    .font(.system(.footnote, weight: .bold))
                    .foregroundStyle(WColor.textSecondary)
                    .frame(width: Size.minTouch, height: Size.minTouch)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.pressable)
            .padding(.trailing, -12)
            .accessibilityLabel("Dismiss")
        } content: {
            Text("We found \(count) progression \(count == 1 ? "opportunity" : "opportunities")")
                .font(.system(.title3, weight: .bold))
                .foregroundStyle(WColor.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 10)
            Text("Based on your last \(model.sessions.count) workouts.")
                .font(.subheadline)
                .foregroundStyle(WColor.textSecondary)
                .padding(.top, 2)
            Button {
                model.sheet = .recommendations
            } label: {
                Text("See recommendations")
                    .font(.system(.subheadline, weight: .bold))
                    .foregroundStyle(WidgetTint.training.ink)
                    .frame(minHeight: Size.minTouch)
            }
            .buttonStyle(.pressable)
        }
    }
}

#Preview("Today") {
    TodayView().environment(AppModel.preview())
}

#Preview("Today · Pro · Dark") {
    TodayView().environment(AppModel.preview(pro: true)).preferredColorScheme(.dark)
}

#Preview("Today · Empty") {
    TodayView().environment(AppModel.preview(empty: true))
}
