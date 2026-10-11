import SwiftUI
import KiraCore

struct TransactionRow: View {
    @Environment(FinanceStore.self) private var store
    let record: TransactionRecord

    var body: some View {
        HStack(spacing: KiraSpacing.m) {
            CategoryIcon(category: store.category(LedgerCalculator.effectiveCategory(of: record)))
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(record.displayName).font(.kiraRowTitle).foregroundStyle(KiraColor.textPrimary).lineLimit(1)
                    StatusBadge(status: record.status)
                }
                Text(subtitle).font(.caption).foregroundStyle(KiraColor.textSecondary).lineLimit(1)
            }
            Spacer(minLength: KiraSpacing.s)
            VStack(alignment: .trailing, spacing: 3) {
                amountText
                if record.flags.contains(.amountMissing) {
                    Text("Amount needed").font(.caption2).foregroundStyle(KiraColor.warning)
                }
            }
        }
        .padding(.vertical, KiraSpacing.m)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityHint("Opens transaction details")
    }

    private var subtitle: String {
        var parts = [record.transactionDate.kiraShort]
        if record.kind != .expense { parts.append(record.kind.displayName) }
        else if let category = store.category(record.categoryID) { parts.append(category.name) }
        parts.append(record.channel.displayName)
        if let account = store.account(record.accountID) { parts.append(account.name) }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private var amountText: some View {
        let isInflow = record.direction == .inflow
        let style = MoneyFormatter(signStyle: .never)
        Text((isInflow ? "+" : "") + style.string(from: record.amount))
            .font(.body.weight(.semibold))
            .monospacedDigit()
            .foregroundStyle(isInflow ? KiraColor.accent : (record.kind.isInternalMovement || record.kind == .debtRepayment ? KiraColor.textSecondary : KiraColor.textPrimary))
            .strikethrough(record.status == .draft, color: KiraColor.textSecondary)
            .accessibilityLabel((isInflow ? "received " : "spent ") + MoneyFormatter.standard.accessibilityString(from: record.amount))
    }
}
