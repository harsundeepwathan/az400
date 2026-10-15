import SwiftUI
import KiraCore

/// Month grid of renewals: each billing day shows the services due, the month shows its total,
/// and tapping a day lists what renews. Weeks start on Monday, as is usual in Malaysia.
struct SubscriptionCalendarView: View {
    @Environment(FinanceStore.self) private var store
    /// Months from the current month; 0 = this month.
    @State private var monthOffset = 0
    @State private var selectedDay: Date?

    private static let columns = Array(repeating: GridItem(.flexible(), spacing: 4), count: 7)

    private var calendar: Calendar {
        var calendar = KLCalendar.shared.calendar
        calendar.firstWeekday = 2
        return calendar
    }

    var body: some View {
        let today = KLCalendar.shared.startOfDay(store.now())
        let monthDate = KLCalendar.shared.addingMonths(monthOffset, to: today)
        let month = store.renewalCalendar(containing: monthDate)
        let selected = selectedDay.flatMap { month.month.contains($0) && $0 < month.month.end ? $0 : nil }
            ?? (monthOffset == 0 ? today : nil)
        List {
            Section {
                VStack(spacing: KiraSpacing.m) {
                    header(month)
                    weekdayRow
                    LazyVGrid(columns: Self.columns, spacing: 4) {
                        ForEach(cells(for: month.month)) { cell in
                            switch cell {
                            case .blank:
                                Color.clear.frame(height: 1)
                            case .day(let day):
                                DayCell(day: day, renewals: month.renewalsByDay[day] ?? [],
                                        isToday: day == today, isSelected: day == selected) {
                                    selectedDay = day
                                }
                            }
                        }
                    }
                }
                .padding(.vertical, KiraSpacing.s)
            }

            if let selected {
                daySection(selected, renewals: month.renewalsByDay[selected] ?? [])
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Renewal Calendar")
        .navigationBarTitleDisplayMode(.inline)
        .sensoryFeedback(.selection, trigger: selectedDay)
    }

    // MARK: Header

    private func header(_ month: RenewalCalendarMonth) -> some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 2) {
                Text(month.month.start.formatted(.dateTime.month(.wide).year()))
                    .font(.title3.weight(.semibold))
                HStack(spacing: 4) {
                    Text("Total cost").foregroundStyle(KiraColor.textSecondary)
                    MoneyText(money: month.total, font: .subheadline.weight(.semibold))
                }
                .font(.subheadline)
                .accessibilityElement(children: .combine)
            }
            Spacer()
            HStack(spacing: KiraSpacing.s) {
                Button("Previous Month", systemImage: "chevron.left") { changeMonth(-1) }
                Button("Next Month", systemImage: "chevron.right") { changeMonth(1) }
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.bordered)
            .buttonBorderShape(.circle)
        }
    }

    private func changeMonth(_ delta: Int) {
        monthOffset += delta
        selectedDay = nil
    }

    private var weekdayRow: some View {
        // Monday-first very short symbols (M T W T F S S). Identified by weekday number,
        // since the symbols themselves repeat.
        let symbols = calendar.veryShortStandaloneWeekdaySymbols
        let weekdays = (0..<7).map { offset in
            let weekday = (calendar.firstWeekday - 1 + offset) % 7 + 1
            return Weekday(id: weekday, symbol: symbols[weekday - 1])
        }
        return HStack(spacing: 4) {
            ForEach(weekdays) { weekday in
                Text(weekday.symbol)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(KiraColor.textSecondary)
                    .frame(maxWidth: .infinity)
            }
        }
        // Each day button already speaks its weekday.
        .accessibilityHidden(true)
    }

    private struct Weekday: Identifiable {
        let id: Int
        let symbol: String
    }

    // MARK: Day detail

    @ViewBuilder
    private func daySection(_ day: Date, renewals: [UpcomingRenewal]) -> some View {
        let items = renewals.compactMap { renewal in store.subscription(renewal.subscriptionID).map { (renewal: renewal, subscription: $0) } }
        Section {
            if items.isEmpty {
                Text("Nothing renews on this day.").foregroundStyle(KiraColor.textSecondary)
            } else {
                ForEach(items, id: \.renewal.id) { item in
                    NavigationLink(value: SubscriptionRoute(id: item.subscription.id)) {
                        UpcomingRenewalRow(renewal: item.renewal, subscription: item.subscription, now: store.now())
                    }
                }
            }
        } header: {
            Text(day.formatted(.dateTime.weekday(.wide).day().month(.wide)))
        } footer: {
            Text("Shows full prices for active plans and trials that convert to paid. Plans billed in other currencies aren’t in the total.")
        }
    }

    // MARK: Grid

    enum Cell: Identifiable {
        case blank(Int)
        case day(Date)

        var id: String {
            switch self {
            case .blank(let index): return "blank-\(index)"
            case .day(let date): return "day-\(date.timeIntervalSinceReferenceDate)"
            }
        }
    }

    private func cells(for month: DateInterval) -> [Cell] {
        let weekday = calendar.component(.weekday, from: month.start)
        let leading = (weekday - calendar.firstWeekday + 7) % 7
        let dayCount = calendar.range(of: .day, in: .month, for: month.start)?.count ?? 30
        let days = (0..<dayCount).compactMap { calendar.date(byAdding: .day, value: $0, to: month.start) }
        return (0..<leading).map(Cell.blank) + days.map { .day(KLCalendar.shared.startOfDay($0)) }
    }
}

/// One day: number, up to two service icons and a "+N" overflow. A button so VoiceOver can
/// select it and hear what renews.
private struct DayCell: View {
    @Environment(FinanceStore.self) private var store
    let day: Date
    let renewals: [UpcomingRenewal]
    let isToday: Bool
    let isSelected: Bool
    var onSelect: () -> Void
    @ScaledMetric(relativeTo: .body) private var cellHeight = 58.0

    var body: some View {
        let subscriptions = renewals.compactMap { store.subscription($0.subscriptionID) }
        Button(action: onSelect) {
            VStack(spacing: 3) {
                Text(day.formatted(.dateTime.day()))
                    .font(.footnote.weight(isToday ? .bold : .regular))
                    .monospacedDigit()
                    .foregroundStyle(isToday ? Color.white : KiraColor.textPrimary)
                    .frame(width: 24, height: 24)
                    .background { if isToday { Circle().fill(KiraColor.accent) } }
                HStack(spacing: -4) {
                    ForEach(subscriptions.prefix(2)) { subscription in
                        ServiceIcon(subscription: subscription, size: 18)
                    }
                }
                .frame(height: 18)
                Text(subscriptions.count > 2 ? "+\(subscriptions.count - 2)" : " ")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(KiraColor.textSecondary)
            }
            .frame(maxWidth: .infinity, minHeight: cellHeight)
            .background {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(isSelected ? KiraColor.accentSoft : Color.clear)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel(subscriptions))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func accessibilityLabel(_ subscriptions: [ServiceSubscription]) -> String {
        var label = day.formatted(.dateTime.weekday(.wide).day().month(.wide))
        if isToday { label = "Today, " + label }
        if !subscriptions.isEmpty {
            label += ". \(subscriptions.count) renewal\(subscriptions.count == 1 ? "" : "s"): " + subscriptions.map(\.name).joined(separator: ", ")
        }
        return label
    }
}

#if DEBUG
#Preview("Renewal Calendar") {
    NavigationStack { SubscriptionCalendarView() }
        .environment(PreviewData.store())
}
#endif
