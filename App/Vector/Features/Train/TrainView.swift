import SwiftUI
import VectorCore

/// Program overview. The next workout is emphasized; the rest of the
/// rotation is a compact vertical list (replacing the old carousel, which
/// showed one workout at a time and hid the plan).
struct TrainView: View {
    @Environment(AppModel.self) private var model
    @State private var editing: WorkoutTemplate?
    @State private var showsProgramBrowser = false
    @State private var showsProgramEditor = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Space.section) {
                    if let program = model.program {
                        programHeader(program)
                        if let next = program.nextWorkout {
                            NextWorkoutCard(template: next)
                        }
                        VStack(alignment: .leading, spacing: Space.sm) {
                            SectionHeader("Up next in rotation")
                            VStack(spacing: 0) {
                                let rest = Array(program.upcoming.dropFirst())
                                ForEach(Array(rest.enumerated()), id: \.element.id) { index, template in
                                    WorkoutRow(template: template, onEdit: { editing = template })
                                    if index < rest.count - 1 { Hairline(leading: Space.md) }
                                }
                            }
                            .card(padding: 0)
                        }
                    } else {
                        EmptyStateView(symbol: "list.bullet.rectangle", title: "No program yet",
                                       message: "Pick a program that matches your schedule, or build your own workout.",
                                       actionTitle: "Browse Programs") { showsProgramBrowser = true }
                    }

                    VStack(alignment: .leading, spacing: Space.sm) {
                        SectionHeader("My workouts")
                        if model.customTemplates.isEmpty {
                            Button {
                                createWorkout()
                            } label: {
                                HStack(spacing: Space.sm) {
                                    IconBadge(symbol: Icon.add)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text("Create a workout").font(VFont.bodyEmphasized).foregroundStyle(VColor.textPrimary)
                                        Text("Build a routine from 50+ exercises").font(VFont.secondary).foregroundStyle(VColor.textSecondary)
                                    }
                                    Spacer()
                                }
                                .card()
                            }
                            .buttonStyle(.pressable)
                        } else {
                            VStack(spacing: 0) {
                                ForEach(Array(model.customTemplates.enumerated()), id: \.element.id) { index, template in
                                    WorkoutRow(template: template, onEdit: { editing = template })
                                    if index < model.customTemplates.count - 1 { Hairline(leading: Space.md) }
                                }
                            }
                            .card(padding: 0)
                        }
                    }

                    HStack(spacing: Space.xs) {
                        QuickActionButton(title: "Create Workout", symbol: "plus.square.on.square") { createWorkout() }
                        QuickActionButton(title: "Browse Programs", symbol: "square.grid.2x2") { showsProgramBrowser = true }
                        QuickActionButton(title: "Empty Workout", symbol: "bolt") { model.startEmptyWorkout() }
                    }
                }
                .padding(.horizontal, Space.gutter)
                .padding(.bottom, Space.xl)
            }
            .screenBackground()
            .navigationTitle("Training")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button("Edit Program", systemImage: "slider.horizontal.3") { showsProgramEditor = true }
                            .disabled(model.program == nil)
                        Button("Browse Programs", systemImage: "square.grid.2x2") { showsProgramBrowser = true }
                        Button("Create Workout", systemImage: "plus") { createWorkout() }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                            .frame(width: Size.minTouch, height: Size.minTouch)
                    }
                    .accessibilityLabel("Training options")
                }
            }
            .navigationDestination(for: WorkoutTemplate.self) { TemplateDetailView(template: $0) }
            .sheet(item: $editing) { TemplateEditorView(template: $0) }
            .sheet(isPresented: $showsProgramBrowser) { ProgramBrowserView() }
            .sheet(isPresented: $showsProgramEditor) { ProgramEditorView() }
        }
    }

    private func programHeader(_ program: TrainingProgram) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("CURRENT PROGRAM")
                .font(VFont.sectionHeading)
                .tracking(0.6)
                .foregroundStyle(VColor.textSecondary)
            Text(program.name)
                .font(VFont.title3)
                .foregroundStyle(VColor.textPrimary)
            Text("\(program.workouts.count) workouts · \(program.subtitle)")
                .font(VFont.secondary)
                .foregroundStyle(VColor.textSecondary)
        }
        .padding(.horizontal, Space.xxs)
    }

    private func createWorkout() {
        guard model.canCreateRoutine else {
            model.presentPaywall(.routineLimit)
            return
        }
        editing = WorkoutTemplate(name: "New Workout", exercises: [])
    }
}

/// Hero card for the next workout in the rotation.
private struct NextWorkoutCard: View {
    var template: WorkoutTemplate
    @Environment(AppModel.self) private var model

    var body: some View {
        let last = model.lastSession(for: template)
        VStack(alignment: .leading, spacing: Space.md) {
            NavigationLink(value: template) {
                VStack(alignment: .leading, spacing: Space.xs) {
                    HStack {
                        Chip(text: "Next", symbol: "arrow.right.circle.fill", tint: VColor.accentText, fill: VColor.accentSoft)
                        Spacer()
                        if let last {
                            Text("Last: \(Format.shortDate(last.startedAt, calendar: model.calendar))")
                                .font(VFont.caption)
                                .foregroundStyle(VColor.textSecondary)
                        }
                    }
                    Text(template.name)
                        .font(VFont.largeTitle)
                        .foregroundStyle(VColor.textPrimary)
                    Text("\(template.exercises.count) exercises · ~\(template.estimatedMinutes(catalog: model.catalog)) min · \(template.totalSets) sets")
                        .font(VFont.secondary)
                        .foregroundStyle(VColor.textSecondary)
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(template.exercises.prefix(4)) { item in
                            HStack {
                                Text(model.catalog[item.exerciseID]?.name ?? item.exerciseID)
                                    .font(VFont.secondary)
                                    .foregroundStyle(VColor.textPrimary)
                                Spacer()
                                Text("\(item.sets) × \(item.repRange.label)")
                                    .font(VFont.dataSecondary)
                                    .foregroundStyle(VColor.textSecondary)
                            }
                        }
                        if template.exercises.count > 4 {
                            Text("+\(template.exercises.count - 4) more")
                                .font(VFont.caption)
                                .foregroundStyle(VColor.textTertiary)
                        }
                    }
                    .padding(.top, Space.xs)
                }
            }
            .buttonStyle(.pressable)

            PrimaryButton("Start \(template.name)", symbol: "play.fill") { model.startWorkout(template) }
        }
        .card(padding: Space.lg)
    }
}

/// Compact rotation row with swipe actions and a context menu.
struct WorkoutRow: View {
    var template: WorkoutTemplate
    var onEdit: () -> Void
    @Environment(AppModel.self) private var model

    var body: some View {
        let last = model.lastSession(for: template)
        NavigationLink(value: template) {
            HStack(spacing: Space.sm) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(template.name)
                        .font(VFont.bodyEmphasized)
                        .foregroundStyle(VColor.textPrimary)
                    Text("\(template.exercises.count) exercises · ~\(template.estimatedMinutes(catalog: model.catalog)) min")
                        .font(VFont.secondary)
                        .foregroundStyle(VColor.textSecondary)
                }
                Spacer()
                if let last {
                    Text("Last: \(Format.shortDate(last.startedAt, calendar: model.calendar))")
                        .font(VFont.caption)
                        .foregroundStyle(VColor.textTertiary)
                }
                Image(systemName: Icon.chevron)
                    .font(.system(.footnote, weight: .semibold))
                    .foregroundStyle(VColor.textTertiary)
            }
            .padding(.horizontal, Space.md)
            .padding(.vertical, Space.sm)
            .frame(minHeight: 60)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Start Workout", systemImage: "play.fill") { model.startWorkout(template) }
            if model.isProgramTemplate(template) {
                Button("Make Next", systemImage: "arrow.uturn.up") { withAnimation(Motion.smooth) { model.makeNext(template) } }
            }
            Button("Edit", systemImage: "pencil", action: onEdit)
            Button("Duplicate", systemImage: "plus.square.on.square") { model.duplicate(template) }
            Divider()
            Button("Delete", systemImage: "trash", role: .destructive) { withAnimation { model.deleteTemplate(template) } }
        }
    }
}

#Preview {
    TrainView().environment(AppModel.preview())
}
