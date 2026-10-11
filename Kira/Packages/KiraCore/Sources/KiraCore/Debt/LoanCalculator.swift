import Foundation

public struct AmortizationRow: Equatable, Sendable {
    public let period: Int
    public let payment: Money
    public let interest: Money
    public let principal: Money
    public let balance: Money
}

/// Loan maths for Malaysian products. All arithmetic uses `Decimal` and rounds to sen.
public enum LoanCalculator {
    /// Monthly instalment.
    /// - reducingBalance: standard annuity P·r / (1 − (1+r)^−n)
    /// - flatRate: (P + P·rate·years) / n — Malaysian hire purchase.
    public static func monthlyInstalment(_ terms: DebtTerms) -> Money {
        let n = max(terms.tenureMonths, 1)
        let principal = terms.principal.decimalValue
        switch terms.method {
        case .flatRate:
            let totalInterest = principal * terms.annualRate * Decimal(n) / 12
            return Money.rounded(major: (principal + totalInterest) / Decimal(n), currency: terms.principal.currency)
        case .reducingBalance:
            let r = terms.annualRate / 12
            guard r > 0 else { return Money.rounded(major: principal / Decimal(n), currency: terms.principal.currency) }
            var growth = Decimal(1)
            for _ in 0..<n { growth *= (1 + r) }
            let payment = principal * r * growth / (growth - 1)
            return Money.rounded(major: payment, currency: terms.principal.currency)
        }
    }

    public static func totalInterest(_ terms: DebtTerms) -> Money {
        schedule(terms).map(\.interest).sum(currency: terms.principal.currency)
    }

    /// Full schedule. The final payment absorbs rounding so the balance ends at exactly zero.
    /// For flat-rate loans interest is allocated with the Rule of 78 (sum-of-digits), which is how
    /// Malaysian hire-purchase rebates are computed.
    public static func schedule(_ terms: DebtTerms) -> [AmortizationRow] {
        let n = max(terms.tenureMonths, 1)
        let currency = terms.principal.currency
        let payment = monthlyInstalment(terms)
        var balance = terms.principal
        var rows: [AmortizationRow] = []

        switch terms.method {
        case .reducingBalance:
            let r = terms.annualRate / 12
            for period in 1...n {
                let interest = Money.rounded(major: balance.decimalValue * r, currency: currency)
                var principal = payment - interest
                var thisPayment = payment
                if period == n || principal > balance {
                    principal = balance
                    thisPayment = principal + interest
                }
                balance -= principal
                rows.append(AmortizationRow(period: period, payment: thisPayment, interest: interest, principal: principal, balance: balance))
            }
        case .flatRate:
            let totalInterest = payment.multiplied(by: Decimal(n)) - terms.principal
            let digitsSum = Decimal(n * (n + 1) / 2)
            var allocatedInterest = Money.zero(currency)
            for period in 1...n {
                var interest = Money.rounded(major: totalInterest.decimalValue * Decimal(n - period + 1) / digitsSum, currency: currency)
                if period == n { interest = totalInterest - allocatedInterest }
                allocatedInterest += interest
                var principal = payment - interest
                var thisPayment = payment
                if period == n { principal = balance; thisPayment = principal + interest }
                balance -= principal
                rows.append(AmortizationRow(period: period, payment: thisPayment, interest: interest, principal: principal, balance: balance))
            }
        }
        return rows
    }

    /// Payments made by `date` (one per month from the start date's month).
    public static func paymentsMade(_ terms: DebtTerms, asOf date: Date, calendar: KLCalendar = .shared) -> Int {
        let months = calendar.calendar.dateComponents([.month], from: calendar.startOfDay(terms.startDate), to: calendar.startOfDay(date)).month ?? 0
        return min(max(months + 1, 0), terms.tenureMonths)
    }

    /// Outstanding principal: the lender-stated figure if entered, otherwise from the schedule.
    public static func outstanding(_ terms: DebtTerms, asOf date: Date, calendar: KLCalendar = .shared) -> Money {
        if let stated = terms.statedOutstanding { return stated }
        guard date >= terms.startDate else { return terms.principal }
        let made = paymentsMade(terms, asOf: date, calendar: calendar)
        guard made > 0 else { return terms.principal }
        return schedule(terms)[made - 1].balance
    }

    public static func remainingMonths(_ terms: DebtTerms, asOf date: Date, calendar: KLCalendar = .shared) -> Int {
        terms.tenureMonths - paymentsMade(terms, asOf: date, calendar: calendar)
    }
}
