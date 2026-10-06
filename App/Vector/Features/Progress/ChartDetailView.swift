import SwiftUI
import VectorCore

struct ChartDetail: Identifiable, Hashable {
    enum Kind: Hashable {
        case volume, frequency, bodyWeight
        case strength(String)
    }

    var kind: Kind
    var range: TimeRange
    var id: String { "\(kind)-\(range.rawValue)" }
}

/// Full-height chart with scrubbing plus the underlying numbers as a table,
/// so the data is never locked inside a picture.
struct ChartDetailView: View {
    @State var detail: ChartDetail
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let points = self.points
        NavigationStack {
            List {
                Section {
                    FieldRangePicker(selection: $detail.range,
                                     isLocked: { $0.requiresPro && !model.isPro },
                                     onLockedTap: { model.presentPaywall(.history) })
                        .listRowInsets(EdgeInsets(top: Space.sm, leading: Space.md, bottom: Space.sm, trailing: Space.md))
                    chart(points)
                        .padding(.vertical, Space.sm)
                }
                Section("Data") {
                    ForEach(points.reversed().filter { $0.value > 0 }) { point in
                        HStack {
                            Text(Format.shortDate(point.date, calendar: model.calendar)).foregroundStyle(VColor.textSecondary)
                            Spacer()
                            Text(format(point.value)).font(VFont.data)
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }

    private var title: String {
        switch detail.kind {
        case .volume: "Training volume"
        case .frequency: "Workouts per week"
        case .bodyWeight: "Body weight"
        case .strength(let id): model.catalog[id]?.name ?? "Strength"
        }
    }

    private var points: [ChartPoint] {
        let now = model.now()
        switch detail.kind {
        case .volume: return model.analytics.volumeSeries(model.sessions, range: detail.range, now: now)
        case .frequency: return model.analytics.frequencySeries(model.sessions, range: detail.range, now: now)
        case .bodyWeight: return model.analytics.bodyWeightSeries(model.bodyWeights, range: detail.range, now: now)
        case .strength(let id): return model.analytics.strengthSeries(model.sessions, exerciseID: id, range: detail.range, now: now)
        }
    }

    private func format(_ value: Double) -> String {
        switch detail.kind {
        case .volume: Format.volume(value, unit: model.unit)
        case .frequency: "\(Int(value)) workouts"
        case .bodyWeight, .strength: Format.estimate(value, unit: model.unit)
        }
    }

    @ViewBuilder
    private func chart(_ points: [ChartPoint]) -> some View {
        switch detail.kind {
        case .volume:
            PeriodBarChart(points: points, unit: detail.range.bucket, valueFormatter: { Format.compact($0) },
                           accessibilityTitle: "Training volume", height: 260)
        case .frequency:
            PeriodBarChart(points: points, unit: .weekOfYear, valueFormatter: { Format.integer($0) },
                           goal: Double(model.profile?.daysPerWeek ?? 4), goalLabel: "Goal",
                           accessibilityTitle: "Workouts per week", height: 260)
        case .bodyWeight:
            WeightTrendChart(points: points, trend: model.analytics.smoothedTrend(points), tint: VColor.inkBody,
                             valueFormatter: { Format.estimate($0, unit: model.unit) }, height: 260)
        case .strength:
            EstimateLineChart(points: points, tint: VColor.inkTraining,
                              valueFormatter: { Format.estimate($0, unit: model.unit) }, height: 260)
        }
    }
}
