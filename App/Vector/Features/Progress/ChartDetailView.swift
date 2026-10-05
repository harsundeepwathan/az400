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
                    RangePicker(selection: $detail.range,
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
        case .volume: "Training Volume"
        case .frequency: "Workout Frequency"
        case .bodyWeight: "Body Weight"
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
            ProgressChart(points: points, style: .bars, unit: detail.range.bucket, valueFormatter: { Format.compact($0) }, height: 260)
        case .frequency:
            ProgressChart(points: points, style: .bars, unit: .weekOfYear, valueFormatter: { Format.integer($0) }, height: 260)
        case .bodyWeight:
            ProgressChart(points: points, style: .trend(smoothed: model.analytics.smoothedTrend(points)),
                          valueFormatter: { Format.estimate($0, unit: model.unit) }, height: 260)
        case .strength:
            ProgressChart(points: points, style: .line, valueFormatter: { Format.estimate($0, unit: model.unit) }, height: 260)
        }
    }
}
