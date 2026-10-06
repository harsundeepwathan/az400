import SwiftUI
import VectorCore

/// "This week": a short AI-written summary of the user's own digest, with
/// the digest one tap away. Shown only to signed-in Pro users (the caller
/// checks `canShowCoachSummary`); the server re-checks Pro and caches one
/// summary per day. If the server says the account isn't Pro, or there is
/// nothing logged, the card removes itself rather than showing a teaser.
struct CoachSummaryCard: View {
    @Environment(AppModel.self) private var model

    private enum Phase: Equatable {
        case loading
        case loaded(CoachSummary)
        case failed(String)
        case hidden
    }

    /// Reload when the day changes, and once insights finish computing (the
    /// digest's recommendations come from them).
    private struct LoadKey: Equatable {
        var day: Date
        var insightsReady: Bool
    }

    /// A 429 with a wait this short means another request is still writing
    /// today's summary; anything longer is the daily cap.
    private static let pendingRetryThreshold = 60
    /// Longest the card waits before its single retry.
    private static let maxRetryDelay = 10

    @State private var phase: Phase = .loading
    /// The digest the shown summary was written from, or today's when that
    /// isn't known (`isExact == false`).
    @State private var shown: CoachDigestShown?
    @State private var loadedDay: Date?

    var body: some View {
        Group {
            switch phase {
            case .hidden:
                EmptyView()
            case .loading:
                card { loadingLines }
            case .loaded(let summary):
                card {
                    Text(summary.text)
                        .font(VFont.body)
                        .foregroundStyle(VColor.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                    Text(writtenLabel(summary))
                        .font(VFont.caption)
                        .foregroundStyle(VColor.textTertiary)
                }
            case .failed(let message):
                card {
                    HStack(alignment: .firstTextBaseline, spacing: Space.xs) {
                        Image(systemName: "exclamationmark.triangle")
                            .foregroundStyle(VColor.warning)
                            .accessibilityHidden(true)
                        Text(message)
                            .font(VFont.secondary)
                            .foregroundStyle(VColor.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Button("Try again") { Task { await load(force: true) } }
                        .buttonStyle(QuietCapsuleButtonStyle(fullWidth: false))
                }
            }
        }
        // Re-run when the day changes so a new day gets a new summary, and
        // when insights finish so the digest carries their recommendations.
        .task(id: LoadKey(day: model.calendar.startOfDay(for: model.now()), insightsReady: !model.isComputingInsights)) {
            await load()
        }
    }

    // MARK: Layout

    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            HStack(alignment: .firstTextBaseline) {
                Text("This week").font(VFont.headline).foregroundStyle(VColor.textPrimary)
                Spacer()
                ProBadge()
            }
            Label("AI summary of your logged data", systemImage: Icon.recommendation)
                .font(VFont.caption)
                .foregroundStyle(VColor.textSecondary)
            content()
            if let shown {
                NavigationLink {
                    CoachDigestDataView(digest: shown.digest, isExact: shown.isExact)
                } label: {
                    HStack(spacing: Space.xxs) {
                        Text("See the data it used")
                        Image(systemName: Icon.chevron).imageScale(.small)
                    }
                    .font(VFont.secondaryEmphasized)
                    .foregroundStyle(VColor.accentText)
                    .frame(minHeight: Size.minTouch)
                }
            }
        }
        .card()
    }

    private var loadingLines: some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            ForEach([1.0, 0.92, 0.6], id: \.self) { fraction in
                GeometryReader { proxy in
                    RoundedRectangle(cornerRadius: Radius.xs, style: .continuous)
                        .fill(VColor.surfaceSunken)
                        .frame(width: proxy.size.width * fraction)
                }
                .frame(height: 14)
            }
        }
        .skeleton(true)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Loading this week's summary")
    }

    /// "Written Tue 6 Oct, 08:00 from your logged data" in the user's locale.
    private func writtenLabel(_ summary: CoachSummary) -> String {
        guard let generatedAt = summary.generatedAt else { return "Written from your logged data" }
        let when = generatedAt.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated).hour().minute())
        return "Written \(when) from your logged data"
    }

    // MARK: Loading

    private func load(force: Bool = false) async {
        guard model.canShowCoachSummary else {
            phase = .hidden
            return
        }
        // The digest's recommendations come from the insight engine; wait
        // for it rather than send an empty list. The task re-runs when it's done.
        guard !model.isComputingInsights else {
            if case .loaded = phase {} else { phase = .loading }
            return
        }
        let day = model.calendar.startOfDay(for: model.now())
        // Already showing today's summary: an insights refresh after a new
        // log doesn't need another request (the server returns the same one).
        if !force, loadedDay == day, case .loaded = phase { return }
        guard let digest = model.coachDigest, digest.hasLoggedData else {
            phase = .hidden
            return
        }
        if case .loaded = phase {} else { phase = .loading }
        do {
            let result = try await requestSummary(digest)
            shown = result.shown
            loadedDay = day
            withAnimation(Motion.smooth) { phase = .loaded(result.summary) }
        } catch let error as CoachSummaryError {
            switch error {
            case .proRequired, .signedOut:
                // The server is the authority on Pro; no locked teaser.
                phase = .hidden
            case .offline:
                phase = .failed("You're offline. This week's summary will load when you're back online.")
            case .rateLimited(let retryAfter?) where retryAfter <= Self.pendingRetryThreshold:
                phase = .failed("This week's summary is still being written. Try again in a minute.")
            case .rateLimited, .unavailable:
                phase = .failed("The summary isn't available right now. Your insights below are unaffected.")
            case .invalidDigest, .rejected:
                phase = .failed("Couldn't summarise this week's data.")
            }
        } catch is CancellationError {
            return
        } catch {
            phase = .failed("Couldn't load this week's summary.")
        }
    }

    /// One retry when the server says another request is still writing
    /// today's summary (a short `retry_after_seconds`), after that wait
    /// capped at `maxRetryDelay`, instead of showing an error straight away.
    private func requestSummary(_ digest: CoachDigest) async throws -> (summary: CoachSummary, shown: CoachDigestShown) {
        do {
            return try await model.coachSummary(for: digest)
        } catch CoachSummaryError.rateLimited(let retryAfter?) where retryAfter <= Self.pendingRetryThreshold {
            try await Task.sleep(for: .seconds(min(max(retryAfter, 1), Self.maxRetryDelay)))
            return try await model.coachSummary(for: digest)
        }
    }
}

/// The numbers the summary was written from, so every sentence can be
/// checked. When those aren't known, today's numbers with a note saying so.
struct CoachDigestDataView: View {
    var digest: CoachDigest
    /// False when the digest the summary was written from isn't stored on
    /// this device (for example it was written on another device): today's
    /// numbers are shown instead, and may differ.
    var isExact: Bool = true

    var body: some View {
        List {
            if !isExact {
                Section {
                    Label("Your data may have changed since this summary was written.", systemImage: "info.circle")
                        .font(VFont.secondary)
                        .foregroundStyle(VColor.textSecondary)
                } footer: {
                    Text("These are your current numbers, not necessarily the ones the summary used.")
                }
            }
            Section {
                row("Workouts, last 7 days", "\(digest.training.workoutsLast7d)")
                row("Workouts, previous 7 days", "\(digest.training.workoutsPrev7d)")
                row("Planned per week", "\(digest.training.plannedPerWeek)")
                row("Volume vs previous week", digest.training.volumeChangePct.map { Format.signedPercent($0 / 100) })
                if let lift = digest.training.mainLift {
                    row("\(lift.exercise) estimated max now", weight(lift.e1rmNow))
                    row("\(lift.exercise) estimated max ~30 days ago", lift.e1rm30dAgo.map(weight))
                }
                ForEach(Array(digest.training.prsLast14d.enumerated()), id: \.offset) { _, pr in
                    row("PR · \(pr.exercise)", pr.weight > 0 ? "\(weight(pr.weight)) × \(pr.reps)" : "\(pr.reps) reps")
                }
            } header: {
                Text("Training")
            }

            Section {
                row("Days logged, last 7", "\(digest.nutrition.daysLoggedLast7d)")
                row("Average calories", digest.nutrition.avgCalories.map { "\(Format.integer($0)) kcal" })
                row("Calorie target", "\(Format.integer(digest.nutrition.targetCalories)) kcal")
                row("Average protein", digest.nutrition.avgProtein.map(Format.grams))
                row("Protein target", Format.grams(digest.nutrition.targetProtein))
                row("Days on protein target", "\(digest.nutrition.proteinDaysHit) of \(digest.nutrition.daysLoggedLast7d)")
            } header: {
                Text("Nutrition")
            } footer: {
                Text("Complete days before today. Unlogged days aren't counted.")
            }

            Section {
                row("Trend weight now", digest.body.trendWeightNow.map(weight))
                row("Trend weight 14 days ago", digest.body.trendWeight14dAgo.map(weight))
                row("Weigh-ins, last 14 days", "\(digest.body.weighInsLast14d)")
            } header: {
                Text("Body weight")
            }

            if !digest.recommendations.isEmpty {
                Section {
                    ForEach(digest.recommendations, id: \.self) { line in
                        Text(line).font(VFont.secondary).foregroundStyle(VColor.textPrimary)
                    }
                } header: {
                    Text("Next-session recommendations")
                }
            }
        }
        .navigationTitle("Summary data")
        .navigationBarTitleDisplayMode(.inline)
    }

    /// Digest weights are already in the user's unit.
    private func weight(_ value: Double) -> String {
        "\(value.formatted(.number.precision(.fractionLength(0...2)).grouping(.never))) \(digest.unit)"
    }

    private func row(_ label: String, _ value: String?) -> some View {
        HStack {
            Text(label).foregroundStyle(VColor.textSecondary)
            Spacer()
            Text(value ?? "Not enough data")
                .font(value == nil ? VFont.secondary : VFont.data)
                .foregroundStyle(value == nil ? VColor.textTertiary : VColor.textPrimary)
        }
        .accessibilityElement(children: .combine)
    }
}
