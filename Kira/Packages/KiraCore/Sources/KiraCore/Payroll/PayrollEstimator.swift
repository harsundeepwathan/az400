import Foundation

/// A versioned set of statutory contribution assumptions. Rates and ceilings change (e.g. the
/// SOCSO/EIS wage ceiling rose to RM 6,000 in October 2024), so they are data, not code, and
/// carry their source and whether the user has checked them.
public struct StatutoryRuleSet: Identifiable, Hashable, Codable, Sendable {
    public var id: String
    public var name: String
    public var effectiveFrom: Date
    public var source: String
    /// EPF/KWSP employee share (e.g. 0.11).
    public var epfEmployeeRate: Decimal
    /// EPF contributions are rounded up to the next ringgit.
    public var epfRoundUpToRinggit: Bool
    /// SOCSO/PERKESO employee share (Employment Injury + Invalidity scheme).
    public var socsoEmployeeRate: Decimal
    public var socsoWageCeiling: Money
    /// EIS/SIP employee share.
    public var eisEmployeeRate: Decimal
    public var eisWageCeiling: Money
    /// True once the user confirms the values against their payslip or official tables.
    public var userVerified: Bool

    public init(id: String, name: String, effectiveFrom: Date, source: String, epfEmployeeRate: Decimal, epfRoundUpToRinggit: Bool = true,
                socsoEmployeeRate: Decimal, socsoWageCeiling: Money, eisEmployeeRate: Decimal, eisWageCeiling: Money, userVerified: Bool = false) {
        self.id = id
        self.name = name
        self.effectiveFrom = effectiveFrom
        self.source = source
        self.epfEmployeeRate = epfEmployeeRate
        self.epfRoundUpToRinggit = epfRoundUpToRinggit
        self.socsoEmployeeRate = socsoEmployeeRate
        self.socsoWageCeiling = socsoWageCeiling
        self.eisEmployeeRate = eisEmployeeRate
        self.eisWageCeiling = eisWageCeiling
        self.userVerified = userVerified
    }

    /// Reference assumptions for a Malaysian citizen employee under 60. NOT authoritative:
    /// EPF uses the Third Schedule wage bands and SOCSO/EIS use contribution tables, which these
    /// percentage approximations only estimate. Users are asked to confirm against their payslip.
    public static let malaysiaReference2024 = StatutoryRuleSet(
        id: "my-reference-2024-10",
        name: "Malaysia reference (Oct 2024)",
        effectiveFrom: KLCalendar.shared.date(2024, 10, 1),
        source: "Approximation of KWSP Third Schedule (11% employee) and PERKESO/EIS tables (0.5% / 0.2%, RM 6,000 ceiling). Verify at kwsp.gov.my and perkeso.gov.my.",
        epfEmployeeRate: Decimal(string: "0.11")!,
        socsoEmployeeRate: Decimal(string: "0.005")!,
        socsoWageCeiling: Money(minorUnits: 600_000),
        eisEmployeeRate: Decimal(string: "0.002")!,
        eisWageCeiling: Money(minorUnits: 600_000)
    )

    /// Picks the latest rule set effective on `date`.
    public static func applicable(_ sets: [StatutoryRuleSet], on date: Date) -> StatutoryRuleSet? {
        sets.filter { $0.effectiveFrom <= date }.max { $0.effectiveFrom < $1.effectiveFrom }
    }
}

public struct PayslipEstimate: Equatable, Sendable {
    public let gross: Money
    public let epf: Money
    public let socso: Money
    public let eis: Money
    /// PCB/MTD is never calculated by Kira: it depends on reliefs and LHDN schedules. User-provided.
    public let pcb: Money
    public var totalDeductions: Money { epf + socso + eis + pcb }
    public var net: Money { gross - totalDeductions }
    /// True when any figure is derived from approximate rules instead of the user's payslip.
    public let isEstimate: Bool
    public let ruleSetID: String
}

/// User-entered payslip values override estimates field by field.
public struct PayslipOverrides: Equatable, Sendable {
    public var epf: Money?
    public var socso: Money?
    public var eis: Money?
    public var pcb: Money?

    public init(epf: Money? = nil, socso: Money? = nil, eis: Money? = nil, pcb: Money? = nil) {
        self.epf = epf
        self.socso = socso
        self.eis = eis
        self.pcb = pcb
    }
}

public enum PayrollEstimator {
    public static func estimate(basic: Money, additional: Money = .zero(), rules: StatutoryRuleSet, overrides: PayslipOverrides = PayslipOverrides()) -> PayslipEstimate {
        let gross = basic + additional

        var epf = gross.multiplied(by: rules.epfEmployeeRate)
        if rules.epfRoundUpToRinggit && epf.minorUnits % 100 != 0 {
            epf = Money(minorUnits: (epf.minorUnits / 100 + 1) * 100, currency: epf.currency)
        }
        let socsoBase = min(gross, rules.socsoWageCeiling)
        let eisBase = min(gross, rules.eisWageCeiling)
        let socso = socsoBase.multiplied(by: rules.socsoEmployeeRate)
        let eis = eisBase.multiplied(by: rules.eisEmployeeRate)

        let usedEstimate = overrides.epf == nil || overrides.socso == nil || overrides.eis == nil || !rules.userVerified
        return PayslipEstimate(gross: gross, epf: overrides.epf ?? epf, socso: overrides.socso ?? socso, eis: overrides.eis ?? eis,
                               pcb: overrides.pcb ?? .zero(gross.currency), isEstimate: usedEstimate, ruleSetID: rules.id)
    }
}
