import SwiftUI
import Charts
import KiraCore

/// Cash-flow forecast with explicit confidence and assumptions. Projected values are drawn
/// dashed and labelled "Estimate" — never presented as a confirmed balance.
struct CashFlowView: View {
    @Environment(FinanceStore.self) private var store

    var body: some View {
        let forecast = store.forecast()
        ScrollView {
            VStack(alignment: .leading, spacing: KiraSpacing.xl) {
                Surface {
                    VStack(alignment: .leading, spacing: KiraSpacing.s) {
                        Text("Safe to spend until month end").font(.subheadline).foregroundStyle(KiraColor.textSecondary)
                        MoneyText(money: forecast.safeToSpend, font: .kiraHero)
                        Text("About \(forecast.safeToSpendPerDay.formatted) a day · Estimate").font(.footnote).foregroundStyle(KiraColor.textSecondary)
                        ConfidenceLabel(confidence: forecast.confidence)
                    }
                }

                if !forecast.days.isEmpty {
                    Surface {
                        VStack(alignment: .leading, spacing: KiraSpacing.s) {
                            Text("Projected cash").font(.headline)
                            Chart {
                                ForEach(forecast.days, id: \.date) { day in
                                    LineMark(x: .value("Date", day.date, unit: .day), y: .value("Balance", Double(day.closingBalance.minorUnits) / 100))
                                        .foregroundStyle(KiraColor.accent)
                                        .lineStyle(StrokeStyle(lineWidth: 2, dash: [5, 4]))
                                        .interpolationMethod(.monotone)
                                }
                                RuleMark(y: .value("Buffer", 200))
                                    .foregroundStyle(KiraColor.warning.opacity(0.6))
                                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [2, 3]))
                                    .annotation(position: .top, alignment: .leading) { Text("Buffer").font(.caption2).foregroundStyle(KiraColor.textSecondary) }
                            }
                            .chartYAxis {
                                AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { value in
                                    AxisGridLine().foregroundStyle(KiraColor.separator)
                                    AxisValueLabel { if let amount = value.as(Double.self) { Text("RM\(Int(amount))").font(.caption2) } }
                                }
                            }
                            .frame(height: 200)
                            .accessibilityLabel("Projected cash balance, from \(forecast.startingBalance.formatted) to \(forecast.endBalance.formatted)")
                            Text("Dashed line = projection, not a bank balance.").font(.caption).foregroundStyle(KiraColor.textSecondary)
                        }
                    }
                }

                Surface {
                    VStack(spacing: KiraSpacing.m) {
                        row("Starting position", forecast.startingBalance, "From balances you entered")
                        row("Expected income", forecast.expectedIncome, "Scheduled")
                        row("Commitments due", forecast.scheduledCommitments.negated, "Scheduled")
                        row("Everyday spending", forecast.estimatedDiscretionary.negated, "Estimate")
                        Divider()
                        row("Projected month end", forecast.endBalance, "Estimate")
                        if let date = forecast.lowestBalanceDate {
                            row("Lowest point (\(date.kiraShort))", forecast.lowestBalance, "Estimate")
                        }
                    }
                }

                if !forecast.lowBalancePeriods.isEmpty {
                    NoticeBanner(tone: .caution, text: "Cash may fall below your buffer from \(forecast.lowBalancePeriods[0].start.kiraShort). Consider moving a bill or reducing spending before then.")
                }

                VStack(alignment: .leading, spacing: KiraSpacing.s) {
                    Text("Assumptions").font(.headline)
                    ForEach(forecast.assumptions, id: \.self) { assumption in
                        Label(assumption, systemImage: "info.circle").font(.footnote).foregroundStyle(KiraColor.textSecondary)
                    }
                }
            }
            .padding(KiraSpacing.l)
        }
        .kiraScreen()
        .navigationTitle("Cash flow")
    }

    private func row(_ title: String, _ value: Money, _ note: String) -> some View {
        HStack {
            VStack(alignment: .leading) {
                Text(title).font(.subheadline)
                Text(note).font(.caption).foregroundStyle(KiraColor.textSecondary)
            }
            Spacer()
            MoneyText(money: value, style: MoneyFormatter(signStyle: .minusOnly), font: .subheadline.weight(.medium))
        }
        .accessibilityElement(children: .combine)
    }
}

struct ConfidenceLabel: View {
    let confidence: ForecastConfidence

    var body: some View {
        let (text, color): (String, Color) = {
            switch confidence {
            case .high: return ("High confidence", KiraColor.accent)
            case .medium: return ("Medium confidence", KiraColor.warning)
            case .low: return ("Low confidence — see assumptions", KiraColor.error)
            }
        }()
        Label(text, systemImage: confidence == .high ? "checkmark.circle" : "exclamationmark.circle")
            .font(.caption.weight(.medium)).foregroundStyle(color)
    }
}
