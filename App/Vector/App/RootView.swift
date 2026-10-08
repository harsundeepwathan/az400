import SwiftUI
import VectorCore

struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Group {
            if model.hasOnboarded {
                MainTabView()
            } else {
                OnboardingFlow()
                    .transition(.opacity)
            }
        }
        .animation(Motion.smooth, value: model.hasOnboarded)
        .sheet(item: $model.sheet) { sheet in
            RootSheetContent(sheet: sheet)
        }
        .fullScreenCover(item: $model.cover) { cover in
            RootCoverContent(cover: cover)
        }
        .overlay(alignment: .top) {
            ToastHost(toast: $model.toast)
        }
    }
}

struct MainTabView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        // The system tab bar is hidden; a floating bar with the quick-log +
        // sits over every tab instead.
        TabView(selection: $model.selectedTab) {
            tab(.today) { TodayView() }
            tab(.train) { TrainView() }
            tab(.nutrition) { NutritionView() }
            tab(.progress) { ProgressDashboardView() }
        }
        .overlay(alignment: .bottom) {
            FloatingTabBar(selection: $model.selectedTab, quickLog: model.quickLogItems)
                .padding(.bottom, Space.xxs)
        }
        .ignoresSafeArea(.keyboard, edges: .bottom)
        .sensoryFeedback(.selection, trigger: model.selectedTab)
    }

    private func tab<Content: View>(_ tab: AppTab, @ViewBuilder content: () -> Content) -> some View {
        content()
            .toolbar(.hidden, for: .tabBar)
            // Content scrolls clear of the floating bar; the mini player sits
            // just above it while a workout is minimized.
            .safeAreaInset(edge: .bottom, spacing: 0) {
                VStack(spacing: 0) {
                    if model.activeWorkout != nil, model.cover == nil {
                        WorkoutMiniPlayer()
                            .padding(.horizontal, Space.gutter)
                            .padding(.bottom, Space.xs)
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                    Color.clear.frame(height: FloatingTabBar.reservedHeight - 20)
                }
            }
            .tag(tab)
    }
}

struct RootSheetContent: View {
    var sheet: RootSheet
    @Environment(AppModel.self) private var model

    var body: some View {
        switch sheet {
        case .exercise(let id):
            if let exercise = model.catalog[id] {
                ExerciseDetailView(exercise: exercise)
            }
        case .foodSearch(let meal):
            FoodSearchView(meal: meal, date: model.now())
        case .quickAdd(let meal):
            QuickAddView(meal: meal, date: model.now())
        case .barcode(let meal):
            BarcodeScanView(meal: meal, date: model.now())
        case .savedMeals(let meal):
            SavedMealsView(meal: meal, date: model.now())
        case .coach:
            CoachView()
                .onAppear { model.track(.aiRecommendationViewed, ["surface": "coach"]) }
        case .recommendations:
            RecommendationsView()
                .onAppear { model.track(.aiRecommendationViewed, ["surface": "progressions"]) }
        case .bodyWeight:
            BodyWeightEntryView()
                .presentationDetents([.height(320)])
        case .paywall(let trigger):
            PaywallView(trigger: trigger)
        case .profile:
            ProfileView(isSheet: true)
        }
    }
}

struct RootCoverContent: View {
    var cover: RootCover
    @Environment(AppModel.self) private var model

    var body: some View {
        switch cover {
        case .workout:
            ActiveWorkoutView()
        case .scanner(let meal):
            if let recognizer = model.recognizer {
                MealScannerFlow(meal: meal, recognizer: recognizer)
            } else {
                ScanUnavailableView(meal: meal)
            }
        case .summary:
            if let summary = model.lastSummary {
                WorkoutSummaryView(summary: summary)
            }
        }
    }
}

/// Shows a toast briefly, then clears it.
struct ToastHost: View {
    @Binding var toast: ToastMessage?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            if let toast {
                Toast(symbol: toast.symbol, title: toast.title, subtitle: toast.subtitle,
                      tint: toast.symbol == Icon.trophy ? VColor.warning : VColor.accentText)
                    .padding(.horizontal, Space.gutter)
                    .padding(.top, Space.xs)
                    .transition(Motion.slide(.top, reduceMotion: reduceMotion))
                    .onTapGesture { dismiss() }
                    .task(id: toast.id) {
                        try? await Task.sleep(for: .seconds(2.6))
                        dismiss()
                    }
            }
        }
        .animation(Motion.snappy, value: toast)
    }

    private func dismiss() {
        withAnimation(Motion.snappy) { toast = nil }
    }
}

/// Compact "now playing" style bar for a minimized workout.
struct WorkoutMiniPlayer: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let workout = model.activeWorkout {
            Button {
                model.resumeWorkout()
            } label: {
                HStack(spacing: Space.sm) {
                    ZStack {
                        ProgressRing(progress: workout.progress, tint: VColor.accent, lineWidth: 4)
                        Image(systemName: "figure.strengthtraining.traditional")
                            .font(.system(.caption, weight: .bold))
                            .foregroundStyle(VColor.accentText)
                    }
                    .frame(width: 34, height: 34)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(workout.session.name)
                            .font(VFont.secondaryEmphasized)
                            .foregroundStyle(VColor.textPrimary)
                        TimelineView(.periodic(from: .now, by: 1)) { context in
                            Group {
                                if let rest = model.restTimer, !rest.isFinished(at: context.date) {
                                    Text("Rest \(Format.clock(rest.remaining(at: context.date)))")
                                        .foregroundStyle(VColor.accentText)
                                } else {
                                    Text(Format.clock(context.date.timeIntervalSince(workout.session.startedAt), alwaysShowHours: true))
                                        .foregroundStyle(VColor.textSecondary)
                                }
                            }
                            .font(VFont.caption.monospacedDigit())
                        }
                    }
                    Spacer()
                    Text("Resume")
                        .font(VFont.secondaryEmphasized)
                        .foregroundStyle(VColor.accentText)
                }
                .padding(.horizontal, Space.md)
                .padding(.vertical, Space.sm)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
                .shadow(color: .black.opacity(0.12), radius: 12, y: 4)
            }
            .buttonStyle(.pressable)
            .accessibilityLabel("Workout in progress, \(workout.session.name). Resume.")
        }
    }
}
