import SwiftUI
import VectorCore

/// What to load on each side of the bar for a set's weight, drawn as plates.
struct PlateCalculatorSheet: View {
    /// Target in kilograms (shown in the user's unit).
    var kilograms: Double
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    private var calculator: PlateCalculator { model.unit == .pounds ? .pounds : .kilograms }
    private var target: Double { model.unit.fromKilograms(kilograms) }
    private var load: PlateCalculator.Load { calculator.load(for: target) }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: Space.lg) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(Format.weight(kilograms, unit: model.unit))
                        .font(.system(.largeTitle, design: .rounded, weight: .bold).monospacedDigit())
                    Text(load.perSide.isEmpty ? "Just the bar (\(number(calculator.bar)) \(model.unit.symbol))"
                         : "Bar \(number(calculator.bar)) \(model.unit.symbol), then on each side:")
                        .font(.subheadline)
                        .foregroundStyle(WColor.textSecondary)
                }
                barDrawing
                    .frame(height: 120)
                    .accessibilityHidden(true)
                if !load.perSide.isEmpty {
                    FlowLayout(spacing: Space.xs) {
                        ForEach(Array(grouped.enumerated()), id: \.offset) { _, item in
                            Text("\(item.count) × \(number(item.plate))")
                                .font(.system(.headline, design: .rounded).monospacedDigit())
                                .padding(.horizontal, 12)
                                .frame(minHeight: 36)
                                .background(WColor.innerStrong, in: Capsule())
                        }
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Each side: " + grouped.map { "\($0.count) of \(number($0.plate))" }.joined(separator: ", "))
                }
                if load.isApproximate {
                    Label("Closest you can load is \(number(load.total)) \(model.unit.symbol).", systemImage: "info.circle")
                        .font(.footnote)
                        .foregroundStyle(WColor.textSecondary)
                }
                Spacer()
            }
            .padding(Space.gutter + 4)
            .widgetCanvas()
            .navigationTitle("Plates")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .presentationDetents([.medium])
    }

    private var grouped: [(plate: Double, count: Int)] {
        var result: [(plate: Double, count: Int)] = []
        for plate in load.perSide {
            if let last = result.last, last.plate == plate { result[result.count - 1].count += 1 } else { result.append((plate, 1)) }
        }
        return result
    }

    /// The bar with one side's plates, heaviest (tallest, darkest) nearest the centre.
    private var barDrawing: some View {
        GeometryReader { proxy in
            let heaviest = calculator.plates.first ?? 1
            HStack(spacing: 3) {
                RoundedRectangle(cornerRadius: 3).fill(WColor.quiet).frame(width: 40, height: 14)
                RoundedRectangle(cornerRadius: 3).fill(WColor.textSecondary).frame(width: 10, height: 34)
                ForEach(Array(load.perSide.enumerated()), id: \.offset) { _, plate in
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(WidgetTint.training.color.opacity(0.45 + 0.55 * plate / heaviest))
                        .frame(width: max(10, 22 * min(1, plate / heaviest + 0.25)),
                               height: proxy.size.height * (0.35 + 0.65 * plate / heaviest))
                }
                RoundedRectangle(cornerRadius: 3).fill(WColor.quiet).frame(height: 14)
            }
            .frame(maxHeight: .infinity)
        }
    }

    private func number(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(format: "%g", value)
    }
}
