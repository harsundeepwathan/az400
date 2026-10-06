import SwiftUI
import VectorCore

/// The daily command center. Answers, top to bottom: what am I training,
/// what should I lift, how am I eating, and am I progressing.
struct TodayView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Space.section) {
                    TodayHeader()
                    if let brief = model.dailyBrief {
                        TodayBriefCard(brief: brief)
                    }
                    VStack(alignment: .leading, spacing: Space.sm) {
                        SectionHeader("Today's training")
                        TodayTrainingCard()
                    }
                    VStack(alignment: .leading, spacing: Space.sm) {
                        SectionHeader("Daily nutrition", actionTitle: "Details") { model.selectedTab = .nutrition }
                        TodayNutritionCard()
                    }
                    if let checkIn = model.nutritionCheckIn, showsCheckIn(checkIn) {
                        NutritionCheckInCard(result: checkIn)
                            .transition(.opacity.combined(with: .scale(scale: 0.97)))
                    }
                    if model.shouldShowUpgradeMoment {
                        UpgradeMomentCard()
                            .transition(.opacity.combined(with: .scale(scale: 0.97)))
                    }
                    VStack(alignment: .leading, spacing: Space.sm) {
                        SectionHeader("Daily insight", actionTitle: model.visibleInsights.isEmpty ? nil : "Coach") {
                            model.sheet = .coach
                        }
                        DailyInsightSection()
                    }
                    VStack(alignment: .leading, spacing: Space.sm) {
                        SectionHeader("This week")
                        WeekStrip()
                    }
                }
                .padding(.horizontal, Space.gutter)
                .padding(.bottom, Space.xl)
            }
            .screenBackground()
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(for: WorkoutTemplate.self) { TemplateDetailView(template: $0) }
            .animation(Motion.smooth, value: model.checkIns.count)
        }
    }

    /// The "needs more data" version only appears once the user has started
    /// logging, so day one isn't a list of chores.
    private func showsCheckIn(_ result: CheckInResult) -> Bool {
        if case .ready = result { return true }
        return model.bodyWeights.count >= 2 || model.sessions.count >= 3
    }
}

private struct TodayHeader: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let now = model.now()
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 2) {
                Text(Format.longDate(now, calendar: model.calendar))
                    .font(VFont.secondaryEmphasized)
                    .foregroundStyle(VColor.textSecondary)
                Text("\(Format.greeting(for: now, calendar: model.calendar)), \(model.firstName)")
                    .font(VFont.title)
                    .foregroundStyle(VColor.textPrimary)
                    .lineLimit(2)
                    .minimumScaleFactor(0.8)
            }
            Spacer(minLength: Space.sm)
            if model.proteinStreak >= 2 {
                Chip(text: "\(model.proteinStreak)", symbol: Icon.flame, tint: VColor.warning, fill: VColor.warningSoft)
                    .accessibilityLabel("Protein target streak, \(model.proteinStreak) days")
            }
            Button {
                model.selectedTab = .profile
            } label: {
                Text(String(model.firstName.prefix(1)).uppercased())
                    .font(VFont.headline)
                    .foregroundStyle(VColor.accentText)
                    .frame(width: Size.minTouch, height: Size.minTouch)
                    .background(VColor.accentSoft, in: Circle())
            }
            .accessibilityLabel("Profile")
        }
        .padding(.top, Space.md)
    }
}

// MARK: - Training

private struct TodayTrainingCard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let workout = model.activeWorkout {
            inProgress(workout)
        } else if let done = trainedToday {
            completed(done)
        } else if let next = model.nextWorkout {
            upNext(next)
        } else {
            EmptyStateView(symbol: Icon.train, title: "Ready for your first session?",
                           message: "Start your first workout and we'll begin building your strength profile.",
                           actionTitle: "Start Workout") { model.startEmptyWorkout() }
        }
    }

    private var trainedToday: WorkoutSession? {
        model.sessions.first { model.calendar.isDate($0.startedAt, inSameDayAs: model.now()) }
    }

    private func upNext(_ template: WorkoutTemplate) -> some View {
        let last = model.lastSession(for: template)
        let muscles = template.primaryMuscles(catalog: model.catalog).map(\.displayName)
        let main = template.exercises.first
        let rec = main.flatMap { model.recommendation(for: $0.exerciseID, repRange: $0.repRange, sets: $0.sets) }

        return VStack(alignment: .leading, spacing: Space.md) {
            NavigationLink(value: template) {
                VStack(alignment: .leading, spacing: Space.xs) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(template.name)
                            .font(VFont.title)
                            .foregroundStyle(VColor.textPrimary)
                        Spacer()
                        Image(systemName: Icon.chevron)
                            .font(.system(.footnote, weight: .semibold))
                            .foregroundStyle(VColor.textTertiary)
                    }
                    Text("~\(template.estimatedMinutes(catalog: model.catalog)) min · \(template.exercises.count) exercises")
                        .font(VFont.secondary)
                        .foregroundStyle(VColor.textSecondary)
                    MuscleChips(muscles: muscles)
                        .padding(.top, 2)
                }
            }
            .buttonStyle(.pressable)

            HStack(spacing: 0) {
                MetricView(label: "Last \(template.name)",
                           value: last.map { Format.relativeDays(from: $0.startedAt, to: model.now(), calendar: model.calendar) } ?? "First time",
                           font: VFont.metricSmall)
                Spacer()
                MetricView(label: "Previous volume",
                           value: last.map { Format.volume($0.volume, unit: model.unit) } ?? "—",
                           font: VFont.metricSmall)
                Spacer()
            }
            .padding(Space.sm)
            .background(VColor.surfaceSunken, in: RoundedRectangle(cornerRadius: Radius.sm, style: .continuous))

            if let rec, let exercise = main.flatMap({ model.catalog[$0.exerciseID] }), rec.action.isProgression, let weight = rec.weight {
                Button {
                    model.sheet = .exercise(exercise.id)
                } label: {
                    HStack(spacing: Space.xs) {
                        Image(systemName: Icon.sparkles).foregroundStyle(VColor.accentText)
                        (Text("\(exercise.name): ").foregroundStyle(VColor.textSecondary)
                         + Text("\(Format.weight(weight, unit: model.unit)) × \(rec.reps)").foregroundStyle(VColor.textPrimary).bold())
                            .font(VFont.secondary)
                        Spacer()
                        Text("Why?").font(VFont.captionEmphasized).foregroundStyle(VColor.accentText)
                    }
                    .frame(minHeight: Size.minTouch)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Recommended \(exercise.name), \(Format.weight(weight, unit: model.unit)) for \(rec.reps) reps. Show reasoning.")
            }

            PrimaryButton("Start Workout", symbol: "play.fill") { model.startWorkout(template) }
        }
        .card()
    }

    private func inProgress(_ workout: ActiveWorkout) -> some View {
        VStack(alignment: .leading, spacing: Space.md) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("In progress").font(VFont.captionEmphasized).foregroundStyle(VColor.accentText)
                    Text(workout.session.name).font(VFont.title).foregroundStyle(VColor.textPrimary)
                }
                Spacer()
                Text("\(workout.completedSets)/\(workout.totalSets) sets")
                    .font(VFont.dataSecondary)
                    .foregroundStyle(VColor.textSecondary)
            }
            LinearProgress(progress: workout.progress)
            PrimaryButton("Resume Workout", symbol: "play.fill") { model.resumeWorkout() }
        }
        .card()
    }

    private func completed(_ session: WorkoutSession) -> some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            HStack(spacing: Space.sm) {
                IconBadge(symbol: "checkmark", tint: VColor.success, fill: VColor.successSoft)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Done for today").font(VFont.headline).foregroundStyle(VColor.textPrimary)
                    Text("\(session.name) · \(Format.duration(session.duration)) · \(Format.volume(session.volume, unit: model.unit))")
                        .font(VFont.secondary)
                        .foregroundStyle(VColor.textSecondary)
                }
            }
            if let next = model.nextWorkout {
                Hairline()
                HStack {
                    Text("Next up").font(VFont.secondary).foregroundStyle(VColor.textSecondary)
                    Spacer()
                    Text(next.name).font(VFont.secondaryEmphasized).foregroundStyle(VColor.textPrimary)
                }
            }
        }
        .card()
    }
}

// MARK: - Nutrition

private struct TodayNutritionCard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let day = model.nutrition(on: model.now())
        let meal = MealType.suggested(forHour: model.calendar.component(.hour, from: model.now()))
        VStack(alignment: .leading, spacing: Space.md) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(Format.integer(day.consumed.calories))
                    .font(VFont.metric)
                    .foregroundStyle(VColor.textPrimary)
                    .contentTransition(.numericText())
                Text("/ \(Format.integer(day.targets.calories)) kcal")
                    .font(VFont.secondary)
                    .foregroundStyle(VColor.textSecondary)
                Spacer()
            }
            .accessibilityElement(children: .combine)
            NutritionSummary(day: day, compact: true)
            HStack(spacing: Space.xs) {
                QuickActionButton(title: "Scan Meal", symbol: Icon.scan, prominent: true) { model.cover = .scanner(meal) }
                QuickActionButton(title: "Log Food", symbol: Icon.search) { model.sheet = .foodSearch(meal) }
                QuickActionButton(title: "Quick Add", symbol: Icon.quickAdd) { model.sheet = .quickAdd(meal) }
            }
        }
        .card()
    }
}

// MARK: - Insight

private struct DailyInsightSection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let insight = model.dailyInsight {
            InsightCard(insight: insight, onAction: { model.handle($0) })
                .skeleton(model.isComputingInsights)
                .contextMenu {
                    Button("Hide this insight", systemImage: "eye.slash") { withAnimation { model.dismiss(insight) } }
                }
        } else if model.sessions.isEmpty {
            EmptyStateView(symbol: Icon.sparkles, title: "Your coach is warming up",
                           message: "After a couple of workouts and a few days of logging, you'll get insights built from your own data.",
                           actionTitle: model.nextWorkout == nil ? nil : "Start \(model.nextWorkout?.name ?? "")") {
                if let next = model.nextWorkout { model.startWorkout(next) }
            }
        } else {
            EmptyStateView(symbol: Icon.sparkles, title: "All caught up",
                           message: "Log today's meals to unlock nutrition insights.",
                           actionTitle: "Log Food") { model.handle(.logFood) }
        }
    }
}

/// Shown once value has been demonstrated (several workouts, real
/// progression opportunities), never during a workout, at most weekly.
private struct UpgradeMomentCard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let count = model.progressionOpportunities.count
        VStack(alignment: .leading, spacing: Space.sm) {
            HStack {
                IconBadge(symbol: "chart.line.uptrend.xyaxis", tint: VColor.success, fill: VColor.successSoft)
                Spacer()
                Button {
                    withAnimation(Motion.smooth) { model.dismissUpgradeMoment() }
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(.footnote, weight: .semibold))
                        .foregroundStyle(VColor.textTertiary)
                        .frame(width: Size.minTouch, height: Size.minTouch)
                }
                .accessibilityLabel("Dismiss")
            }
            Text("You're getting stronger.")
                .font(VFont.title3)
                .foregroundStyle(VColor.textPrimary)
            Text("We found \(count) progression \(count == 1 ? "opportunity" : "opportunities") based on your last \(model.sessions.count) workouts.")
                .font(VFont.secondary)
                .foregroundStyle(VColor.textSecondary)
            Button("See recommendations") { model.sheet = .recommendations }
                .buttonStyle(.primary)
        }
        .card()
    }
}

// MARK: - Week

/// Seven-day strip: trained days are filled, today is outlined.
private struct WeekStrip: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let calendar = model.calendar
        let today = calendar.startOfDay(for: model.now())
        let week = calendar.dateInterval(of: .weekOfYear, for: today)?.start ?? today
        let days = (0..<7).compactMap { calendar.date(byAdding: .day, value: $0, to: week) }
        let trained = Set(model.sessions.map { calendar.startOfDay(for: $0.startedAt) })
        let count = days.filter { trained.contains($0) }.count
        let goal = model.profile?.daysPerWeek ?? 4

        VStack(alignment: .leading, spacing: Space.sm) {
            HStack {
                Text("\(count) of \(goal) workouts")
                    .font(VFont.secondaryEmphasized)
                    .foregroundStyle(VColor.textPrimary)
                Spacer()
                if let weight = model.latestBodyWeight {
                    Button {
                        model.sheet = .bodyWeight
                    } label: {
                        Label(Format.weight(weight.kilograms, unit: model.unit), systemImage: "scalemass")
                            .font(VFont.secondaryEmphasized.monospacedDigit())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(VColor.accentText)
                    .frame(minHeight: Size.minTouch)
                    .accessibilityLabel("Body weight \(Format.weight(weight.kilograms, unit: model.unit)). Log weigh-in.")
                }
            }
            HStack(spacing: 0) {
                ForEach(days, id: \.self) { day in
                    let isToday = day == today
                    let done = trained.contains(day)
                    VStack(spacing: 6) {
                        Text(day.formatted(.dateTime.weekday(.narrow)))
                            .font(VFont.caption)
                            .foregroundStyle(isToday ? VColor.textPrimary : VColor.textSecondary)
                        ZStack {
                            Circle()
                                .fill(done ? VColor.accent : VColor.surfaceSunken)
                            if isToday && !done {
                                Circle().strokeBorder(VColor.accentText, lineWidth: 1.5)
                            }
                            if done {
                                Image(systemName: Icon.check)
                                    .font(.system(.caption2, weight: .bold))
                                    .foregroundStyle(VColor.textOnAccent)
                            }
                        }
                        .frame(width: 30, height: 30)
                    }
                    .frame(maxWidth: .infinity)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(day.formatted(.dateTime.weekday(.wide)) + (done ? ", trained" : ""))
                }
            }
        }
        .card()
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
