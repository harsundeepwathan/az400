import SwiftUI
import VectorCore

/// Entry point on the Progress dashboard: measurements and progress photos.
struct BodyProgressLinks: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            SectionHeader("Body")
            VStack(spacing: 0) {
                NavigationLink {
                    MeasurementsView()
                } label: {
                    row(symbol: "ruler", title: "Measurements", detail: measurementsDetail)
                }
                Hairline(leading: 62)
                NavigationLink {
                    ProgressPhotosView()
                } label: {
                    row(symbol: "person.crop.rectangle", title: "Progress photos", detail: photosDetail)
                }
            }
            .buttonStyle(.plain)
            .card(padding: 0)
        }
    }

    private var measurementsDetail: String {
        guard let latest = model.bodyMeasurements.last else { return "Waist, hips, chest, arm, thigh, neck" }
        return "Last logged " + Format.relativeDays(from: latest.date, to: model.now(), calendar: model.calendar).lowercased()
    }

    private var photosDetail: String {
        let count = model.progressPhotos.count
        return count == 0 ? "Stored only on this iPhone" : "\(count) photo\(count == 1 ? "" : "s") on this iPhone"
    }

    private func row(symbol: String, title: String, detail: String) -> some View {
        HStack(spacing: Space.sm) {
            IconBadge(symbol: symbol, size: 34)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(VFont.bodyEmphasized).foregroundStyle(VColor.textPrimary)
                Text(detail).font(VFont.caption).foregroundStyle(VColor.textSecondary)
            }
            Spacer()
            Image(systemName: Icon.chevron)
                .font(.system(.footnote, weight: .semibold))
                .foregroundStyle(VColor.textTertiary)
        }
        .padding(.horizontal, Space.md)
        .padding(.vertical, Space.sm)
        .frame(minHeight: Size.minTouch)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

/// Tape measurements: the latest value per site with its change over the
/// range, a chart of logged values for one site, and the history.
struct MeasurementsView: View {
    @Environment(AppModel.self) private var model
    @State private var range: TimeRange = .threeMonths
    @State private var selectedSite: BodySite?
    @State private var editing: BodyMeasurementEntry?

    var body: some View {
        let entries = model.bodyMeasurements
        ScrollView {
            VStack(alignment: .leading, spacing: Space.section) {
                if entries.isEmpty {
                    EmptyStateView(symbol: "ruler", title: "Track more than the scale",
                                   message: "Waist and other measurements show changes in shape that body weight can hide. Measure every 2 to 4 weeks, at the same time of day.",
                                   actionTitle: "Log Measurements") {
                        editing = BodyMeasurementEntry(date: model.now())
                    }
                } else {
                    RangePicker(selection: $range,
                                isLocked: { $0.requiresPro && !model.isPro },
                                onLockedTap: { model.presentPaywall(.history) })
                    summaries(entries)
                    chart(entries)
                    history(entries)
                }
            }
            .padding(.horizontal, Space.gutter)
            .padding(.bottom, Space.xl)
            .animation(Motion.smooth, value: range)
        }
        .screenBackground()
        .navigationTitle("Measurements")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { editing = BodyMeasurementEntry(date: model.now()) } label: {
                    Label("Log Measurements", systemImage: Icon.add)
                }
            }
        }
        .sheet(item: $editing) { entry in
            MeasurementEntryView(entry: entry, isNew: !model.bodyMeasurements.contains { $0.id == entry.id })
        }
    }

    private func currentSite(_ entries: [BodyMeasurementEntry]) -> BodySite? {
        let tracked = model.measurementsEngine.trackedSites(entries)
        if let selectedSite, tracked.contains(selectedSite) { return selectedSite }
        return tracked.first
    }

    // MARK: Summary

    private func summaries(_ entries: [BodyMeasurementEntry]) -> some View {
        let summaries = model.measurementsEngine.summaries(entries, range: range, now: model.now())
        let unit = model.lengthUnit
        let current = currentSite(entries)
        return LazyVGrid(columns: [GridItem(.flexible(), spacing: Space.sm), GridItem(.flexible())], spacing: Space.sm) {
            ForEach(summaries) { summary in
                Button {
                    withAnimation(Motion.snappy) { selectedSite = summary.site }
                } label: {
                    VStack(alignment: .leading, spacing: Space.xxs) {
                        Text(summary.site.displayName)
                            .font(VFont.caption)
                            .foregroundStyle(VColor.textSecondary)
                        Text(Format.length(summary.latestCm, unit: unit))
                            .font(VFont.metric)
                            .foregroundStyle(VColor.textPrimary)
                            .minimumScaleFactor(0.7)
                            .lineLimit(1)
                        Text(summary.changeCm.map { Format.signedLength($0, unit: unit) + " " + range.label } ?? "No change yet")
                            .font(VFont.caption.monospacedDigit())
                            .foregroundStyle(VColor.textTertiary)
                    }
                    .card(padding: Space.sm, radius: Radius.md)
                    .overlay {
                        if current == summary.site {
                            RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
                                .strokeBorder(VColor.accent, lineWidth: 1.5)
                        }
                    }
                }
                .buttonStyle(.pressable)
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(current == summary.site ? .isSelected : [])
                .accessibilityHint("Shows the chart for \(summary.site.displayName.lowercased())")
            }
        }
        .sensoryFeedback(.selection, trigger: selectedSite)
    }

    // MARK: Chart

    @ViewBuilder
    private func chart(_ entries: [BodyMeasurementEntry]) -> some View {
        if let site = currentSite(entries) {
            let unit = model.lengthUnit
            let points = model.measurementsEngine.series(entries, site: site, range: range, now: model.now())
            ChartCard(title: site.displayName, subtitle: "Logged values only, in \(unit.symbol)") {
                if points.count >= 2 {
                    ProgressChart(points: points, style: .line, valueFormatter: { Format.length($0, unit: unit) })
                } else {
                    Text(points.isEmpty
                         ? "No \(site.displayName.lowercased()) measurements in this range."
                         : "Log \(site.displayName.lowercased()) once more to see a trend.")
                        .font(VFont.secondary)
                        .foregroundStyle(VColor.textSecondary)
                        .frame(maxWidth: .infinity, minHeight: 120)
                }
            }
        }
    }

    // MARK: History

    private func history(_ entries: [BodyMeasurementEntry]) -> some View {
        let recent = Array(entries.reversed().prefix(20))
        let unit = model.lengthUnit
        return VStack(alignment: .leading, spacing: Space.sm) {
            SectionHeader("History")
            VStack(spacing: 0) {
                ForEach(Array(recent.enumerated()), id: \.element.id) { index, entry in
                    Button { editing = entry } label: {
                        HStack(alignment: .firstTextBaseline, spacing: Space.sm) {
                            Text(Format.shortDate(entry.date, calendar: model.calendar))
                                .font(VFont.bodyEmphasized)
                                .foregroundStyle(VColor.textPrimary)
                            Spacer()
                            Text(entry.measuredSites.map { "\($0.displayName) \(Format.length(entry[$0] ?? 0, unit: unit, includeUnit: false))" }
                                .joined(separator: " · "))
                                .font(VFont.dataSecondary)
                                .foregroundStyle(VColor.textSecondary)
                                .multilineTextAlignment(.trailing)
                        }
                        .padding(.horizontal, Space.md)
                        .padding(.vertical, Space.sm)
                        .frame(minHeight: Size.minTouch)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint("Edit or delete")
                    if index < recent.count - 1 { Hairline(leading: Space.md) }
                }
            }
            .card(padding: 0)
            Text("Values in \(unit.symbol). Tap an entry to edit or delete it.")
                .font(VFont.caption)
                .foregroundStyle(VColor.textTertiary)
                .padding(.horizontal, Space.xxs)
        }
    }
}

/// Log or edit one measuring session. Every site is optional.
struct MeasurementEntryView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var entry: BodyMeasurementEntry
    /// What's typed in each field, parsed on every keystroke (no Return
    /// needed) with `MeasurementInput`, in the locale's decimal format.
    @State private var texts: [BodySite: String] = [:]
    /// Text as first shown (rounded, in the display unit), so untouched
    /// fields keep their exact stored value instead of a rounded round-trip.
    @State private var initialTexts: [BodySite: String] = [:]
    @State private var confirmDelete = false
    @FocusState private var focusedSite: BodySite?
    var isNew: Bool

    init(entry: BodyMeasurementEntry, isNew: Bool) {
        _entry = State(initialValue: entry)
        self.isNew = isNew
    }

    var body: some View {
        let unit = model.lengthUnit
        NavigationStack {
            Form {
                Section {
                    DatePicker("Date", selection: $entry.date, in: ...model.now(), displayedComponents: .date)
                }
                Section {
                    ForEach(BodySite.allCases) { site in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(site.displayName).font(VFont.body).foregroundStyle(VColor.textPrimary)
                                Text(site.guidance).font(VFont.caption).foregroundStyle(VColor.textTertiary)
                            }
                            Spacer(minLength: Space.sm)
                            TextField("–", text: binding(for: site))
                                .keyboardType(.decimalPad)
                                .multilineTextAlignment(.trailing)
                                .font(VFont.data)
                                .foregroundStyle(isInvalid(site) ? VColor.danger : VColor.textPrimary)
                                .frame(width: 72)
                                .focused($focusedSite, equals: site)
                                .accessibilityLabel("\(site.displayName) in \(unit == .centimeters ? "centimetres" : "inches")")
                                .accessibilityValue(isInvalid(site) ? "\(texts[site] ?? ""), not a valid number" : (texts[site] ?? ""))
                            Text(unit.symbol)
                                .font(VFont.secondary)
                                .foregroundStyle(VColor.textSecondary)
                        }
                        .frame(minHeight: Size.minTouch)
                    }
                } footer: {
                    if hasInvalidInput {
                        Text("Enter each measurement as a number above zero, or leave it blank.")
                            .foregroundStyle(VColor.danger)
                    } else {
                        Text("Leave a site blank if you didn't measure it. Only what you log is charted.")
                    }
                }
                if !isNew {
                    Section {
                        Button("Delete Entry", role: .destructive) { confirmDelete = true }
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .screenBackground()
            .navigationTitle(isNew ? "Log Measurements" : "Edit Measurements")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        focusedSite = nil
                        model.saveMeasurements(finalEntry(unit: unit))
                        dismiss()
                    }
                    .fontWeight(.semibold)
                    .disabled(hasInvalidInput || (isNew && finalEntry(unit: unit).isEmpty))
                }
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") { focusedSite = nil }
                        .fontWeight(.semibold)
                }
            }
            .confirmationDialog("Delete this entry?", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("Delete", role: .destructive) {
                    model.deleteMeasurements(entry)
                    dismiss()
                }
            }
            .onAppear {
                guard initialTexts.isEmpty else { return }
                for site in BodySite.allCases {
                    if let cm = entry[site] { texts[site] = MeasurementInput.text(unit.fromCentimeters(cm)) }
                }
                initialTexts = texts
            }
        }
    }

    private func binding(for site: BodySite) -> Binding<String> {
        Binding(get: { texts[site] ?? "" }, set: { texts[site] = $0 })
    }

    private func isInvalid(_ site: BodySite) -> Bool {
        MeasurementInput.parse(texts[site] ?? "") == .invalid
    }

    private var hasInvalidInput: Bool { BodySite.allCases.contains(where: isInvalid) }

    /// Untouched fields keep their stored value; edited ones are parsed.
    /// Invalid text never reaches here (Save is disabled), but is ignored if it does.
    private func finalEntry(unit: LengthUnit) -> BodyMeasurementEntry {
        var result = entry
        for site in BodySite.allCases where (texts[site] ?? "") != (initialTexts[site] ?? "") {
            switch MeasurementInput.parse(texts[site] ?? "") {
            case .empty: result[site] = nil
            case .value(let value): result[site] = unit.toCentimeters(value)
            case .invalid: break
            }
        }
        return result
    }
}

#Preview {
    NavigationStack { MeasurementsView() }.environment(AppModel.preview(pro: true))
}
