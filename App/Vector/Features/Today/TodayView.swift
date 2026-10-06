import SwiftUI
import VectorCore

/// The daily command center ("Fields"). A dark hero field holds the
/// day's three rings; the coach statement and the weekly check-in sit on the
/// plain ground; each area (training, nutrition, body) owns a full-bleed
/// tinted field. Fields run edge to edge with content inset inside them.
struct TodayView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var showsCheckIn = false

    var body: some View {
        NavigationStack {
            ScrollViewReader { _ in
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        TodayHero()
                        if let coaching = model.todayCoaching {
                            VectorCoachCard(coaching: coaching)
                                .padding(.horizontal, Space.fieldInset)
                                .padding(.top, Space.lg)
                                .padding(.bottom, Space.md)
                        }
                        TodayTrainingField()
                        if model.showsWeeklyCheckIn, let review = model.weeklyReview {
                            checkIn(review)
                                .transition(.opacity)
                        }
                        TodayNutritionField()
                        TodayBodyField()
                        if model.shouldShowUpgradeMoment {
                            UpgradeMoment()
                                .transition(.opacity)
                        }
                    }
                    .padding(.bottom, Space.xl)
                }
            }
            .screenBackground()
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(for: WorkoutTemplate.self) { TemplateDetailView(template: $0) }
            .animation(Motion.adaptive(Motion.smooth, reduceMotion: reduceMotion), value: model.coachDecisions.count)
            .onChange(of: model.showsWeeklyCheckIn) { _, shows in
                if !shows { showsCheckIn = false }
            }
            .weeklyCheckInSheet(isPresented: $showsCheckIn)
        }
    }

    /// The check-in row on the plain ground; Review opens the full
    /// check-in as a large sheet.
    private func checkIn(_ review: WeeklyReview) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            CheckInRow(review: review) { showsCheckIn = true }
            Hairline()
        }
    }
}

// MARK: - Hero field

/// Large title, date and avatar on the dark hero field, then the rings and
/// their legend. The field runs up under the status bar.
private struct TodayHero: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let now = model.now()
        let day = model.nutrition(on: now)
        let workouts = workoutsThisWeek(now: now)
        let goal = max(model.profile?.daysPerWeek ?? 4, 1)

        VStack(alignment: .leading, spacing: 22) {
            HStack(alignment: .bottom, spacing: Space.sm) {
                VStack(alignment: .leading, spacing: 0) {
                    Text("Today")
                        .font(VFont.largeTitle)
                        .foregroundStyle(VColor.heroText)
                        .accessibilityAddTraits(.isHeader)
                    Text(Format.longDate(now, calendar: model.calendar))
                        .font(VFont.secondary)
                        .foregroundStyle(VColor.heroTextSecondary)
                }
                Spacer(minLength: Space.sm)
                Button {
                    model.sheet = .profile
                } label: {
                    Text(String(model.firstName.prefix(1)).uppercased())
                        .font(VFont.secondaryEmphasized)
                        .foregroundStyle(VColor.heroText)
                        .frame(width: 36, height: 36)
                        .background(VColor.heroQuiet, in: Circle())
                        .frame(width: Size.minTouch, height: Size.minTouch)
                        .contentShape(Circle())
                }
                .buttonStyle(.pressable)
                .accessibilityLabel("Profile")
            }

            let ringData = rings(day: day, workouts: workouts, goal: goal)
            let spoken = summary(day: day, workouts: workouts, goal: goal)

            // Side by side when it fits; rings above the legend at large text sizes.
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .center, spacing: 22) {
                    ActivityRings(rings: ringData, accessibilitySummary: spoken)
                    legend(day: day, workouts: workouts, goal: goal)
                }
                VStack(alignment: .leading, spacing: Space.md) {
                    ActivityRings(rings: ringData, accessibilitySummary: spoken)
                        .frame(maxWidth: .infinity)
                    legend(day: day, workouts: workouts, goal: goal)
                }
            }
        }
        .padding(.horizontal, Space.fieldInset)
        .padding(.top, 6)
        .padding(.bottom, 26)
        .frame(maxWidth: .infinity, alignment: .leading)
        // Extends up under the status bar and into the top overscroll, so the
        // field never shows the ground above it.
        .background { VColor.heroField.padding(.top, -1000) }
    }

    private func rings(day: DailyNutrition, workouts: Int, goal: Int) -> [ActivityRing] {
        [
            ActivityRing(label: "Workouts this week", progress: Double(workouts) / Double(goal), color: VColor.ringWorkouts),
            ActivityRing(label: "Calories", progress: ratio(day.consumed.calories, day.targets.calories), color: VColor.ringCalories),
            ActivityRing(label: "Protein", progress: ratio(day.consumed.protein, day.targets.protein), color: VColor.ringProtein)
        ]
    }

    private func summary(day: DailyNutrition, workouts: Int, goal: Int) -> String {
        let calories = "calories \(Format.integer(day.consumed.calories)) of \(Format.integer(day.targets.calories))"
        let protein = "protein \(Format.integer(day.consumed.protein)) of \(Format.integer(day.targets.protein)) grams"
        return "Workouts \(workouts) of \(goal), \(calories), \(protein)"
    }

    private func legend(day: DailyNutrition, workouts: Int, goal: Int) -> some View {
        let calories = Format.integer(day.consumed.calories)
        let calorieTarget = Format.integer(day.targets.calories)
        let protein = Format.integer(day.consumed.protein)
        let proteinTarget = Format.integer(day.targets.protein)
        return VStack(spacing: 0) {
            RingLegendRow(label: "Workouts this week", value: "\(workouts)", target: "\(goal)",
                          color: VColor.ringWorkouts, accessibilityValue: "\(workouts) of \(goal)")
            heroHairline
            RingLegendRow(label: "Calories", value: calories, target: calorieTarget, color: VColor.ringCalories,
                          accessibilityValue: "\(calories) of \(calorieTarget) kilocalories")
            heroHairline
            RingLegendRow(label: "Protein", value: protein, target: "\(proteinTarget) g", color: VColor.ringProtein,
                          accessibilityValue: "\(protein) of \(proteinTarget) grams")
        }
    }

    private var heroHairline: some View {
        Rectangle().fill(VColor.heroHairline).frame(height: 0.5)
    }

    private func ratio(_ value: Double, _ target: Double) -> Double {
        target > 0 ? value / target : 0
    }

    /// Finished workouts in the current calendar week.
    private func workoutsThisWeek(now: Date) -> Int {
        guard let week = model.calendar.dateInterval(of: .weekOfYear, for: now) else { return 0 }
        return model.sessions.filter { week.contains($0.startedAt) }.count
    }
}

// MARK: - Training field

private struct TodayTrainingField: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let workout = model.activeWorkout {
            inProgress(workout)
        } else if let done = trainedToday {
            completed(done)
        } else if let next = model.nextWorkout {
            upNext(next)
        } else {
            empty
        }
    }

    private var trainedToday: WorkoutSession? {
        model.sessions.first { model.calendar.isDate($0.startedAt, inSameDayAs: model.now()) }
    }

    private func upNext(_ template: WorkoutTemplate) -> some View {
        let last = model.lastSession(for: template)
        let muscles = template.primaryMuscles(catalog: model.catalog).prefix(3).map { $0.displayName.lowercased() }
        let meta = (["~\(template.estimatedMinutes(catalog: model.catalog)) min", "\(template.exercises.count) exercises"]
                    + (muscles.isEmpty ? [] : [muscles.joined(separator: ", ")])).joined(separator: " · ")

        return FieldSection(.training, symbol: Icon.train, title: "Next workout", detail: "Program",
                            action: { model.selectedTab = .train }) {
            NavigationLink(value: template) {
                VStack(alignment: .leading, spacing: Space.xxs) {
                    Text(template.name)
                        .font(VFont.fieldTitle)
                        .foregroundStyle(VColor.textPrimary)
                    Text(meta)
                        .font(VFont.secondary)
                        .foregroundStyle(VColor.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.pressable)
            .accessibilityHint("Shows the exercises")

            FieldStatPair(
                leading: .init(value: last.map { Format.relativeDays(from: $0.startedAt, to: model.now(), calendar: model.calendar) } ?? "First time",
                               label: "Last \(template.name)"),
                trailing: .init(value: last.map { Format.volume($0.volume, unit: model.unit) } ?? "None yet",
                                label: "Previous volume"))
                .padding(.top, Space.xxs)

            Button {
                model.startWorkout(template)
            } label: {
                Label("Start workout", systemImage: "play.fill")
            }
            .buttonStyle(.accentCapsule)
            .padding(.top, Space.xs)
        }
    }

    private func inProgress(_ workout: ActiveWorkout) -> some View {
        FieldSection(.training, symbol: Icon.train, title: "Workout in progress") {
            Text(workout.session.name)
                .font(VFont.fieldTitle)
                .foregroundStyle(VColor.textPrimary)
            Text("\(workout.completedSets) of \(workout.totalSets) sets done")
                .font(VFont.secondary.monospacedDigit())
                .foregroundStyle(VColor.textSecondary)
            LinearProgress(progress: workout.progress, tint: VColor.accent, height: 5)
                .padding(.top, Space.xxs)
            Button {
                model.resumeWorkout()
            } label: {
                Label("Resume workout", systemImage: "play.fill")
            }
            .buttonStyle(.accentCapsule)
            .padding(.top, Space.xs)
        }
    }

    private func completed(_ session: WorkoutSession) -> some View {
        FieldSection(.training, symbol: Icon.train, title: "Training", detail: "Program",
                     action: { model.selectedTab = .train }) {
            Label("Done for today", systemImage: "checkmark.circle.fill")
                .font(VFont.fieldTitle)
                .foregroundStyle(VColor.textPrimary)
                .labelStyle(DoneLabelStyle())
            Text("\(session.name) · \(Format.duration(session.duration)) · \(Format.volume(session.volume, unit: model.unit))")
                .font(VFont.secondary.monospacedDigit())
                .foregroundStyle(VColor.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            if let next = model.nextWorkout {
                Hairline().padding(.top, Space.xs)
                HStack {
                    Text("Next up").font(VFont.secondary).foregroundStyle(VColor.textSecondary)
                    Spacer()
                    Text(next.name).font(VFont.secondaryEmphasized).foregroundStyle(VColor.textPrimary)
                }
                .accessibilityElement(children: .combine)
            }
        }
    }

    private var empty: some View {
        FieldSection(.training, symbol: Icon.train, title: "Training") {
            Text("Ready for your first session?")
                .font(VFont.fieldTitle)
                .foregroundStyle(VColor.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            Text("Start your first workout and we'll begin building your strength profile.")
                .font(VFont.secondary)
                .foregroundStyle(VColor.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Button {
                model.startEmptyWorkout()
            } label: {
                Label("Start workout", systemImage: "play.fill")
            }
            .buttonStyle(.accentCapsule)
            .padding(.top, Space.xs)
        }
    }
}

/// Accent check before the title: status paired with its label.
private struct DoneLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Space.xs) {
            configuration.icon.foregroundStyle(VColor.accentText)
            configuration.title
        }
    }
}

// MARK: - Weekly check-in row

/// "Weekly check-in ready" on the plain ground with the decision (Pro) and
/// an outlined Review capsule.
private struct CheckInRow: View {
    var review: WeeklyReview
    var onReview: () -> Void
    @Environment(AppModel.self) private var model

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: Space.md) {
                summary
                Spacer(minLength: 0)
                button
            }
            VStack(alignment: .leading, spacing: Space.sm) {
                summary
                button
            }
        }
        .padding(.horizontal, Space.fieldInset)
        .padding(.vertical, Space.lg)
    }

    private var summary: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Weekly check-in ready")
                .font(VFont.bodyEmphasized)
                .foregroundStyle(VColor.textPrimary)
                .accessibilityAddTraits(.isHeader)
            result
        }
    }

    @ViewBuilder private var result: some View {
        if model.isPro, case .adjustCalories(let from, let to, _) = review.recommendation {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(Format.integer(from))
                    .font(VFont.changeValue)
                    .foregroundStyle(VColor.textTertiary)
                Image(systemName: "arrow.right")
                    .font(.system(.title3, weight: .semibold))
                    .foregroundStyle(VColor.textPrimary)
                Text(Format.integer(to))
                    .font(VFont.changeValue)
                    .foregroundStyle(VColor.textPrimary)
                Text("kcal")
                    .font(VFont.secondaryEmphasized)
                    .foregroundStyle(VColor.textSecondary)
            }
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("From \(Format.integer(from)) to \(Format.integer(to)) kilocalories a day")
        } else {
            Text(line)
                .font(VFont.secondary)
                .foregroundStyle(VColor.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// One line on what the review holds. Free users see their week; the decision is Pro.
    private var line: String {
        guard model.isPro else { return "Your week in numbers" }
        return switch review.recommendation {
        case .onTrack: "Everything is on track. No changes."
        case .watch: "Hold steady for one more week."
        case .improveAdherence: "Focus on consistency first."
        case .learningBaseline: "Vector is still learning your baseline."
        case .adjustCalories: "A calorie change is ready."
        }
    }

    private var button: some View {
        Button("Review", action: onReview)
            .buttonStyle(.outlinedCapsule)
            .accessibilityHint("Opens the weekly check-in")
    }
}

// MARK: - Nutrition field

private struct TodayNutritionField: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        let day = model.nutrition(on: model.now())
        let meal = MealType.suggested(forHour: model.calendar.component(.hour, from: model.now()))
        let remaining = day.caloriesRemaining
        let proteinToGo = max(day.targets.protein - day.consumed.protein, 0)

        FieldSection(.nutrition, symbol: Icon.nutrition, title: "Nutrition", detail: "Details",
                     action: { model.selectedTab = .nutrition }) {
            (Text(Format.integer(abs(remaining)))
                .font(VFont.fieldNumber)
                .foregroundStyle(VColor.textPrimary)
             + Text(remaining >= 0 ? " kcal left" : " kcal over")
                .font(VFont.secondary)
                .foregroundStyle(remaining >= 0 ? VColor.textSecondary : VColor.warning)
             + Text(proteinToGo > 0 ? " · \(Format.integer(proteinToGo)) g protein to go" : " · protein target met")
                .font(VFont.secondary)
                .foregroundStyle(VColor.textSecondary))
                .contentTransition(.numericText())
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Calories")
                .accessibilityValue("\(Format.integer(abs(remaining))) \(remaining >= 0 ? "remaining" : "over") of \(Format.integer(day.targets.calories)). "
                                    + (proteinToGo > 0 ? "\(Format.integer(proteinToGo)) grams of protein to go." : "Protein target met."))

            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 14) { macros(day) }
                VStack(alignment: .leading, spacing: Space.sm) { macros(day) }
            }
            .padding(.top, Space.xxs)

            // Equal-width capsules in a row (labels scale down slightly on
            // narrow phones); stacked at accessibility text sizes.
            Group {
                if dynamicTypeSize.isAccessibilitySize {
                    VStack(spacing: Space.xs) { actions(meal) }
                } else {
                    HStack(spacing: Space.xs) { actions(meal) }
                }
            }
            .padding(.top, Space.xs)
        }
    }

    @ViewBuilder private func macros(_ day: DailyNutrition) -> some View {
        MacroColumn(title: "Protein", consumed: day.consumed.protein, target: day.targets.protein, tint: VColor.protein)
        MacroColumn(title: "Carbs", consumed: day.consumed.carbs, target: day.targets.carbs, tint: VColor.carbs)
        MacroColumn(title: "Fat", consumed: day.consumed.fat, target: day.targets.fat, tint: VColor.fat)
    }

    @ViewBuilder private func actions(_ meal: MealType) -> some View {
        QuickActionButton(title: "Scan meal", symbol: Icon.scan, variant: .capsule) { model.cover = .scanner(meal) }
        QuickActionButton(title: "Log food", symbol: Icon.search, variant: .capsule) { model.sheet = .foodSearch(meal) }
        QuickActionButton(title: "Quick add", symbol: Icon.add, variant: .capsule) { model.sheet = .quickAdd(meal) }
    }
}

// MARK: - Body field

private struct TodayBodyField: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        FieldSection(.body, symbol: "scalemass", title: "Body", detail: "Weigh in",
                     action: { model.sheet = .bodyWeight }) {
            if let latest = model.latestBodyWeight {
                let now = model.now()
                let points = model.analytics.bodyWeightSeries(model.bodyWeights, range: .month, now: now)
                let trend = CoachMetrics(calendar: model.calendar).weightTrend(model.bodyWeights, days: 28, now: now)

                HStack(alignment: .bottom, spacing: Space.md) {
                    VStack(alignment: .leading, spacing: 2) {
                        (Text(Format.weight(latest.kilograms, unit: model.unit, includeUnit: false))
                            .font(VFont.fieldNumber)
                            .foregroundStyle(VColor.textPrimary)
                         + Text(" \(model.unit.symbol)")
                            .font(VFont.headline)
                            .foregroundStyle(VColor.textSecondary))
                            .accessibilityLabel("Latest weigh-in \(Format.weight(latest.kilograms, unit: model.unit))")
                        Group {
                            if let trend {
                                Text(signed(trend.kgPerWeek))
                                    .font(VFont.secondaryEmphasized.monospacedDigit())
                                    .foregroundStyle(VColor.inkBody)
                                + Text(" a week")
                                    .font(VFont.secondary)
                                    .foregroundStyle(VColor.textSecondary)
                            } else {
                                Text("Log 3+ weigh-ins a week for a trend")
                                    .font(VFont.secondary)
                                    .foregroundStyle(VColor.textSecondary)
                            }
                        }
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityLabel(trend.map { "Trend \(signed($0.kgPerWeek)) a week" } ?? "Log 3 or more weigh-ins a week for a trend")
                    }
                    Spacer(minLength: Space.md)
                    if points.count >= 2 {
                        TrendSparkline(points: points, trend: model.analytics.smoothedTrend(points), tint: VColor.inkBody)
                            .frame(maxWidth: 150)
                            .frame(height: 44)
                    }
                }
            } else {
                Text("Log your weight to see your trend.")
                    .font(VFont.secondary)
                    .foregroundStyle(VColor.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func signed(_ kgPerWeek: Double) -> String {
        let sign = kgPerWeek >= 0 ? "+" : "\u{2212}"
        return "\(sign)\(Format.weight(abs(kgPerWeek), unit: model.unit))"
    }
}

// MARK: - Upgrade moment

/// Shown once value has been demonstrated (several workouts, real
/// progression opportunities), never during a workout, at most weekly.
/// Sits on the plain ground after the fields.
private struct UpgradeMoment: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let count = model.progressionOpportunities.count
        VStack(alignment: .leading, spacing: Space.xs) {
            HStack(alignment: .firstTextBaseline) {
                Text("You're getting stronger.")
                    .font(VFont.title3)
                    .foregroundStyle(VColor.textPrimary)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: Space.sm)
                Button {
                    withAnimation(Motion.adaptive(Motion.smooth, reduceMotion: reduceMotion)) { model.dismissUpgradeMoment() }
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(.footnote, weight: .semibold))
                        .foregroundStyle(VColor.textTertiary)
                        .frame(width: Size.minTouch, height: Size.minTouch)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Dismiss")
            }
            Text("We found \(count) progression \(count == 1 ? "opportunity" : "opportunities") based on your last \(model.sessions.count) workouts.")
                .font(VFont.secondary)
                .foregroundStyle(VColor.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("See recommendations") { model.sheet = .recommendations }
                .buttonStyle(.outlinedCapsule)
                .padding(.top, Space.xxs)
        }
        .padding(.horizontal, Space.fieldInset)
        .padding(.vertical, Space.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
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
