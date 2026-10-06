import SwiftUI
import VectorCore

/// "Report discomfort": fixed safety guidance first, then an optional note of
/// what, where and when. Vector never diagnoses, and nothing here is sent to
/// the backend, analytics or the AI.
struct DiscomfortReportSheet: View {
    var exerciseID: String?
    var exerciseName: String?
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var location = ""
    @State private var timing: DiscomfortNote.Timing = .duringSet

    private let commonAreas = ["Shoulder", "Elbow", "Wrist", "Lower back", "Hip", "Knee", "Ankle"]

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(SafetyGuidance.pain)
                        .font(VFont.body)
                        .foregroundStyle(VColor.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(SafetyGuidance.scope)
                        .font(VFont.caption)
                        .foregroundStyle(VColor.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Section {
                    TextField("Where (e.g. left shoulder)", text: $location)
                        .textInputAutocapitalization(.sentences)
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: Space.xs) {
                            ForEach(commonAreas, id: \.self) { area in
                                Button(area) { location = area }
                                    .buttonStyle(QuietCapsuleButtonStyle(fullWidth: false))
                                    .accessibilityAddTraits(location == area ? .isSelected : [])
                            }
                        }
                    }
                    Picker("When", selection: $timing) {
                        ForEach(DiscomfortNote.Timing.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                } header: {
                    Text("Note it for yourself (optional)")
                } footer: {
                    Text("Saved on this device and in your iCloud only\(exerciseName.map { ", with \($0)" } ?? ""). Vector doesn't use notes to make recommendations.")
                }
            }
            .navigationTitle("Report discomfort")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save note") {
                        model.reportDiscomfort(exerciseID: exerciseID, location: location, timing: timing)
                        dismiss()
                    }
                    .disabled(location.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
        .presentationDetents([.large])
    }
}

/// The user's own discomfort notes, newest first (Progress → Coaching).
struct DiscomfortNotesList: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let notes = model.discomfortNotes.sorted { $0.date > $1.date }
        if !notes.isEmpty {
            VStack(alignment: .leading, spacing: Space.xs) {
                Text("Discomfort notes").font(VFont.secondaryEmphasized).foregroundStyle(VColor.textPrimary)
                ForEach(notes) { note in
                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(note.location).font(VFont.secondary).foregroundStyle(VColor.textPrimary)
                            Text([note.exerciseID.flatMap { model.catalog[$0]?.name }, note.timing.title,
                                  note.date.formatted(date: .abbreviated, time: .omitted)].compactMap { $0 }.joined(separator: " · "))
                                .font(VFont.caption)
                                .foregroundStyle(VColor.textSecondary)
                        }
                        Spacer()
                        Button {
                            model.deleteDiscomfortNote(note)
                        } label: {
                            Image(systemName: "trash").foregroundStyle(VColor.textTertiary)
                                .frame(width: Size.minTouch, height: Size.minTouch)
                        }
                        .accessibilityLabel("Delete note")
                    }
                }
                Text(SafetyGuidance.pain)
                    .font(VFont.caption)
                    .foregroundStyle(VColor.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
