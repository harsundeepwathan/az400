import SwiftUI

// Building blocks for the open-canvas screens of the Fields design (Train,
// Exercise detail, history, programs): a custom large title for a field that
// runs under the status bar, 20 pt section titles, hairline rows with a
// trailing value, and canvas sections separated by full-width hairlines.
// No cards, no shadows: spacing, titles and hairlines do the separating.

// MARK: - Large title inside a field

/// "Train" at large-title size on a field, with one trailing accessory (a
/// toolbar-style menu). Used when the screen hides the navigation bar so the
/// field can run up under the status bar.
struct CanvasLargeTitle<Accessory: View>: View {
    var title: String
    @ViewBuilder var accessory: () -> Accessory

    init(_ title: String, @ViewBuilder accessory: @escaping () -> Accessory) {
        self.title = title
        self.accessory = accessory
    }

    var body: some View {
        HStack(alignment: .center, spacing: Space.sm) {
            Text(title)
                .font(VFont.largeTitle)
                .foregroundStyle(VColor.textPrimary)
                .accessibilityAddTraits(.isHeader)
                .lineLimit(2)
                .minimumScaleFactor(0.8)
            Spacer(minLength: Space.sm)
            accessory()
        }
    }
}

extension CanvasLargeTitle where Accessory == EmptyView {
    init(_ title: String) {
        self.init(title) { EmptyView() }
    }
}

/// The `ellipsis.circle` toolbar glyph in the accent colour, 44 pt target.
struct CanvasMoreMenuLabel: View {
    var body: some View {
        Image(systemName: "ellipsis.circle")
            .font(.system(.title3, weight: .regular))
            .foregroundStyle(VColor.accentText)
            .frame(width: Size.minTouch, height: Size.minTouch)
            .contentShape(Rectangle())
    }
}

// MARK: - Section title

/// The only section marker on the open canvas: a 20 pt bold sentence-case
/// title, with an optional trailing text link ("See all", "Edit").
struct CanvasSectionTitle: View {
    var title: String
    var actionTitle: String?
    var action: (() -> Void)?

    init(_ title: String, actionTitle: String? = nil, action: (() -> Void)? = nil) {
        self.title = title
        self.actionTitle = actionTitle
        self.action = action
    }

    var body: some View {
        HStack(alignment: .center, spacing: Space.sm) {
            Text(title)
                .font(VFont.title3.weight(.bold))
                .foregroundStyle(VColor.textPrimary)
                .accessibilityAddTraits(.isHeader)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: Space.sm)
            if let actionTitle, let action {
                Button(action: action) {
                    Text(actionTitle)
                        .font(VFont.secondaryEmphasized)
                        .foregroundStyle(VColor.accentText)
                        .frame(minWidth: Size.minTouch, minHeight: Size.minTouch, alignment: .trailing)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .frame(minHeight: Size.minTouch)
    }
}

// MARK: - Canvas section

/// One section on the plain ground: title, then content, inset 20 pt. Every
/// section after the first gets a full-width hairline on its top edge.
struct CanvasSection<Content: View>: View {
    var title: String?
    var actionTitle: String?
    var action: (() -> Void)?
    var showsTopRule: Bool
    @ViewBuilder var content: () -> Content

    init(_ title: String? = nil, actionTitle: String? = nil, showsTopRule: Bool = true,
         action: (() -> Void)? = nil, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.actionTitle = actionTitle
        self.action = action
        self.showsTopRule = showsTopRule
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.xxs) {
            if let title {
                CanvasSectionTitle(title, actionTitle: actionTitle, action: action)
            }
            content()
        }
        .padding(.horizontal, Space.fieldInset)
        // The 44 pt title row carries ~10 pt of its own air, so trim the top.
        .padding(.top, title == nil ? Space.lg : Space.md)
        .padding(.bottom, Space.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .top) {
            if showsTopRule { Hairline() }
        }
        .accessibilityElement(children: .contain)
    }
}

// MARK: - Hairline row

/// A row on the canvas or inside a field: title and secondary line on the
/// leading side; a bold tabular value with a small caption on the trailing
/// side; an optional chevron. No fill. The caller places hairlines between
/// rows (`Hairline()`), inset to the text edge.
struct CanvasRow: View {
    var title: String
    var subtitle: String?
    var value: String?
    var valueCaption: String?
    /// Quiet trailing text instead of a bold value ("Next", "3 Oct").
    var detail: String?
    var showsChevron = false
    var minHeight: CGFloat = 52

    var body: some View {
        HStack(alignment: .center, spacing: Space.sm) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(VFont.body)
                    .foregroundStyle(VColor.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(VFont.fieldCaption.monospacedDigit())
                        .foregroundStyle(VColor.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .layoutPriority(1)

            if value != nil || valueCaption != nil {
                VStack(alignment: .trailing, spacing: 1) {
                    if let value {
                        Text(value)
                            .font(VFont.data)
                            .foregroundStyle(VColor.textPrimary)
                            .contentTransition(.numericText())
                    }
                    if let valueCaption {
                        Text(valueCaption)
                            .font(VFont.fieldCaption.monospacedDigit())
                            .foregroundStyle(VColor.textSecondary)
                    }
                }
                .multilineTextAlignment(.trailing)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            }
            if let detail {
                Text(detail)
                    .font(VFont.secondary.monospacedDigit())
                    .foregroundStyle(VColor.textSecondary)
                    .lineLimit(1)
            }
            if showsChevron {
                Image(systemName: Icon.chevron)
                    .font(.system(.footnote, weight: .semibold))
                    .foregroundStyle(VColor.textTertiary)
                    .accessibilityHidden(true)
            }
        }
        .padding(.vertical, 10)
        .frame(minHeight: minHeight)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Text link with a symbol

/// "+ New routine": an accent text action with a leading symbol, 44 pt tall.
struct CanvasTextAction: View {
    var title: String
    var symbol: String
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .font(VFont.bodyEmphasized)
                .foregroundStyle(VColor.accentText)
                .frame(maxWidth: .infinity, minHeight: Size.minTouch, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Stat line

/// Numbers in one row instead of tiles: "**54 min** · **18** sets ·
/// **7,860 kg**". Values are rounded bold, labels secondary. Wraps to one
/// stat per line when it doesn't fit (large text sizes).
struct CanvasStatLine: View {
    struct Stat: Hashable {
        var value: String
        var label: String
    }

    var stats: [Stat]

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline, spacing: Space.xs) {
                ForEach(Array(stats.enumerated()), id: \.offset) { index, stat in
                    if index > 0 {
                        Text("·").font(VFont.secondary).foregroundStyle(VColor.textTertiary).accessibilityHidden(true)
                    }
                    text(stat)
                }
            }
            .lineLimit(1)
            VStack(alignment: .leading, spacing: Space.xxs) {
                ForEach(Array(stats.enumerated()), id: \.offset) { _, stat in text(stat) }
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func text(_ stat: Stat) -> Text {
        Text(stat.value).font(VFont.fieldStat).foregroundStyle(VColor.textPrimary)
            + Text(stat.label.isEmpty ? "" : " \(stat.label)").font(VFont.secondary).foregroundStyle(VColor.textSecondary)
    }
}

// MARK: - Numbered steps

/// How-to steps as plain numbered text: an accent numeral, then the step.
struct CanvasNumberedSteps: View {
    var steps: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: Space.md) {
            ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                HStack(alignment: .firstTextBaseline, spacing: Space.md) {
                    Text("\(index + 1)")
                        .font(VFont.bodyEmphasized.monospacedDigit())
                        .foregroundStyle(VColor.accentText)
                        .frame(minWidth: 16, alignment: .leading)
                        .accessibilityHidden(true)
                    Text(step)
                        .font(VFont.body)
                        .foregroundStyle(VColor.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Step \(index + 1). \(step)")
            }
        }
    }
}

// MARK: - Field hero helpers

extension View {
    /// Paints a field behind a hero that sits at the top of a scroll view and
    /// extends it up under the (transparent at rest) navigation bar and into
    /// the top overscroll, so the ground never shows above the field.
    func fieldHeroBackground(_ fill: Color) -> some View {
        background { fill.padding(.top, -1000) }
    }

    /// Keeps the navigation title for the back button and the app switcher
    /// but shows nothing in the bar, because the field below carries the
    /// title at large size.
    func fieldTitleInBody() -> some View {
        toolbar {
            ToolbarItem(placement: .principal) {
                Color.clear.frame(width: 1, height: 1).accessibilityHidden(true)
            }
        }
    }
}
