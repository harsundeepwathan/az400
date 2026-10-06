import SwiftUI
import VectorCore

@main
struct VectorWatchApp: App {
    @State private var session = WatchSessionModel()

    var body: some Scene {
        WindowGroup {
            WatchRootView().environment(session)
        }
    }
}

private let accent = Color(red: 0.30, green: 0.55, blue: 1.0)
private let success = Color(red: 0.20, green: 0.78, blue: 0.48)

struct WatchRootView: View {
    @Environment(WatchSessionModel.self) private var session

    var body: some View {
        NavigationStack {
            if let workout = session.workout {
                WatchWorkoutView(workout: workout)
            } else {
                WatchStartView()
            }
        }
    }
}

/// Idle: start the next workout from the wrist.
struct WatchStartView: View {
    @Environment(WatchSessionModel.self) private var session

    var body: some View {
        VStack(spacing: 10) {
            Text("NEXT").font(.caption2.weight(.bold)).foregroundStyle(.secondary)
            Text(session.state?.nextWorkoutName ?? "Open Vector on iPhone")
                .font(.title3.weight(.bold))
                .multilineTextAlignment(.center)
            if session.state?.nextWorkoutName != nil {
                Button {
                    session.startNextWorkout()
                } label: {
                    Label("Start", systemImage: "play.fill").frame(maxWidth: .infinity)
                }
                .tint(accent)
                .disabled(!session.isPhoneReachable)
            }
            if !session.isPhoneReachable {
                Text("iPhone not reachable").font(.caption2).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Vector")
    }
}

/// One page per exercise; the rest timer takes over the screen while running.
struct WatchWorkoutView: View {
    var workout: ActiveWorkout
    @Environment(WatchSessionModel.self) private var session
    @State private var confirmFinish = false

    var body: some View {
        @Bindable var session = session
        Group {
            if let timer = session.restTimer, !timer.isFinished(at: Date()) {
                WatchRestView(timer: timer)
            } else {
                TabView(selection: $session.selectedExercise) {
                    ForEach(Array(workout.session.exercises.enumerated()), id: \.element.id) { index, log in
                        WatchExercisePage(index: index, log: log)
                            .tag(index)
                    }
                }
                .tabViewStyle(.verticalPage)
            }
        }
        .navigationTitle(workout.session.name)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Finish") { confirmFinish = true }
                    .tint(success)
            }
        }
        .confirmationDialog("Finish workout?", isPresented: $confirmFinish) {
            Button("Finish") { session.finish() }
            Button("Keep Training", role: .cancel) {}
        }
    }
}

struct WatchExercisePage: View {
    var index: Int
    var log: ExerciseLog
    @Environment(WatchSessionModel.self) private var session
    @State private var editing: Field = .weight
    @State private var crown: Double = 0

    enum Field { case weight, reps }

    /// Next set to do in this exercise, or the last one if all are done.
    private var setIndex: Int { log.sets.firstIndex { !$0.isCompleted } ?? max(log.sets.count - 1, 0) }
    private var position: SetPosition { SetPosition(exercise: index, set: setIndex) }
    private var set: SetLog? { log.sets[safe: setIndex] }

    var body: some View {
        VStack(spacing: 6) {
            Text(session.name(of: log.exerciseID))
                .font(.headline)
                .lineLimit(2)
                .minimumScaleFactor(0.7)
                .multilineTextAlignment(.center)
            Text(log.isComplete ? "All sets done" : "Set \(setIndex + 1) of \(log.sets.count)")
                .font(.caption2)
                .foregroundStyle(.secondary)
            if let set {
                HStack(spacing: 6) {
                    valueButton(Format.weight(set.weight, unit: session.unit, includeUnit: false), unit: session.unit.symbol, field: .weight)
                    valueButton("\(set.reps)", unit: "reps", field: .reps)
                }
                .focusable()
                .digitalCrownRotation($crown, from: -1000, through: 1000, by: 1, sensitivity: .low, isContinuous: true)
                .onChange(of: crown) { old, new in step(Int(new.rounded()) - Int(old.rounded())) }
                Button {
                    session.complete(position)
                } label: {
                    Label(set.isCompleted ? "Done" : "Complete Set", systemImage: "checkmark")
                        .frame(maxWidth: .infinity)
                }
                .tint(success)
                .disabled(set.isCompleted)
            }
        }
        .padding(.horizontal, 2)
    }

    private func valueButton(_ value: String, unit: String, field: Field) -> some View {
        Button {
            editing = field
        } label: {
            VStack(spacing: 0) {
                Text(value).font(.title3.weight(.bold)).monospacedDigit()
                Text(unit).font(.caption2).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, minHeight: 44)
            .background(editing == field ? accent.opacity(0.3) : Color.gray.opacity(0.2), in: RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(value) \(unit). Turn the Digital Crown to adjust.")
    }

    /// One Digital Crown detent = one plate step or one rep.
    private func step(_ detents: Int) {
        guard detents != 0, let set else { return }
        switch editing {
        case .weight:
            let next = max(set.weight + Double(detents) * session.increment(of: log.exerciseID), 0)
            session.setWeight(next, at: position)
        case .reps:
            session.setReps(max(set.reps + detents, 0), at: position)
        }
    }
}

struct WatchRestView: View {
    var timer: RestTimer
    @Environment(WatchSessionModel.self) private var session

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            VStack(spacing: 8) {
                ZStack {
                    Circle().stroke(Color.gray.opacity(0.3), lineWidth: 8)
                    Circle()
                        .trim(from: 0, to: 1 - timer.progress(at: context.date))
                        .stroke(accent, style: StrokeStyle(lineWidth: 8, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                    VStack(spacing: 0) {
                        Text("REST").font(.caption2.weight(.bold)).foregroundStyle(.secondary)
                        Text(Format.clock(timer.remaining(at: context.date).rounded(.up)))
                            .font(.title2.weight(.bold))
                            .monospacedDigit()
                    }
                }
                .frame(width: 100, height: 100)
                HStack {
                    Button("−15") { session.adjustRest(by: -15) }
                    Button("+15") { session.adjustRest(by: 15) }
                    Button("Skip") { session.skipRest() }.tint(accent)
                }
                .font(.footnote.weight(.semibold))
            }
        }
        .task(id: timer) {
            let delay = timer.remaining(at: Date())
            if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
            guard !Task.isCancelled else { return }
            session.restFinished()
        }
    }
}

extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
