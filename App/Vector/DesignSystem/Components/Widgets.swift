import SwiftUI
import VectorCore

// MARK: - Tile

/// The unit of the widget dashboard: a plain rounded tile, a header (symbol, title, optional accessory and
/// an ↗ that opens the full screen) and free content below.
struct WidgetTile<Accessory: View, Content: View>: View {
    var tint: WidgetTint
    var title: String
    var symbol: String
    var titleIsTinted = false
    var open: (() -> Void)?
    @ViewBuilder var accessory: Accessory
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            content
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background { WidgetBackground(tint: tint) }
        .clipShape(RoundedRectangle(cornerRadius: Radius.xl, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Radius.xl, style: .continuous)
                .strokeBorder(WColor.edge, lineWidth: 1)
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.system(.body, weight: .semibold))
                .foregroundStyle(titleIsTinted ? tint.ink : WColor.textSecondary)
            Text(title)
                .font(.system(.headline))
                .foregroundStyle(titleIsTinted ? tint.ink : WColor.textSecondary)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 4)
            accessory
            if let open {
                Button(action: open) {
                    Image(systemName: "arrow.up.right")
                        .font(.system(.body, weight: .bold))
                        .foregroundStyle(tint.ink)
                        .frame(width: Size.minTouch, height: Size.minTouch)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.pressable)
                .padding(.trailing, -12)
                .accessibilityLabel("Open \(title)")
            }
        }
        .frame(minHeight: 28)
        .padding(.top, -8)
        .padding(.bottom, -6)
    }
}

extension WidgetTile where Accessory == EmptyView {
    init(tint: WidgetTint, title: String, symbol: String, titleIsTinted: Bool = false, open: (() -> Void)? = nil,
         @ViewBuilder content: () -> Content) {
        self.init(tint: tint, title: title, symbol: symbol, titleIsTinted: titleIsTinted, open: open,
                  accessory: { EmptyView() }, content: content)
    }
}

/// White (or near-black) tile.
struct WidgetBackground: View {
    var tint: WidgetTint

    var body: some View { tint.fill }
}

/// Small rounded label inside a tile header or footer.
struct WidgetChip: View {
    var title: String
    var symbol: String?
    var foreground: Color = WColor.textPrimary
    var background: Color = WColor.innerStrong

    var body: some View {
        HStack(spacing: 5) {
            if let symbol {
                Image(systemName: symbol).font(.system(.caption, weight: .bold))
            }
            Text(title).font(.system(.footnote, weight: .semibold)).monospacedDigit()
        }
        .foregroundStyle(foreground)
        .padding(.horizontal, 10)
        .frame(minHeight: 28)
        .background(background, in: Capsule())
    }
}

// MARK: - Rings

/// A progress ring with rounded ends, drawn clockwise from the top. Over 100%
/// stays a full ring; the number beside it says by how much.
struct GradientRing: View {
    var progress: Double
    var lineWidth: CGFloat
    var colors: [Color]
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var drawn = 0.0

    var body: some View {
        ZStack {
            Circle().stroke(WColor.track, lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: drawn)
                .stroke(LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing),
                        style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .padding(lineWidth / 2)
        .onAppear { fill() }
        .onChange(of: progress) { _, _ in fill() }
        .accessibilityHidden(true)
    }

    private func fill() {
        let target = min(max(progress, 0), 1)
        if reduceMotion { drawn = target } else { withAnimation(.easeOut(duration: 0.8)) { drawn = target } }
    }
}

/// One macro: a small ring with its letter inside, grams below.
struct WidgetMacroRing: View {
    var letter: String
    var name: String
    var consumed: Double
    var target: Double
    var color: Color

    var body: some View {
        VStack(spacing: 4) {
            ZStack {
                GradientRing(progress: target > 0 ? consumed / target : 0, lineWidth: 4, colors: [color, color])
                Text(letter).font(.system(.footnote, weight: .bold)).foregroundStyle(color)
            }
            .frame(width: 40, height: 40)
            Text("\(Format.integer(consumed))g")
                .font(.system(.footnote, weight: .semibold).monospacedDigit())
                .foregroundStyle(WColor.textPrimary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(name)
        .accessibilityValue("\(Format.integer(consumed)) of \(Format.integer(target)) grams")
    }
}

// MARK: - Charts

/// Seven days of training as rounded columns: filled to the day's volume,
/// a dot on rest days, today outlined.
struct WeekBars: View {
    struct Day: Identifiable {
        var id: Date
        var letter: String
        /// 0...1 of the week's biggest day; nil on rest days.
        var fraction: Double?
        var isToday: Bool
    }

    var days: [Day]
    var tint: WidgetTint

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 6) {
                ForEach(days) { day in
                    ZStack(alignment: .bottom) {
                        RoundedRectangle(cornerRadius: 11, style: .continuous)
                            .fill(day.isToday ? Color.clear : WColor.inner)
                            .overlay {
                                if day.isToday {
                                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                                        .strokeBorder(tint.accent, lineWidth: 1.5)
                                }
                            }
                        if let fraction = day.fraction {
                            GeometryReader { proxy in
                                VStack {
                                    Spacer(minLength: 0)
                                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                                        .fill(tint.accent)
                                        .frame(height: max(proxy.size.height * fraction, 10))
                                }
                            }
                            .padding(4)
                        } else if !day.isToday {
                            Circle().fill(WColor.quiet).frame(width: 4, height: 4).padding(.bottom, 10)
                        }
                    }
                }
            }
            HStack(spacing: 6) {
                ForEach(days) { day in
                    Text(day.letter)
                        .font(.system(.footnote, weight: day.isToday ? .bold : .medium))
                        .foregroundStyle(day.isToday ? WColor.textPrimary : WColor.textSecondary)
                        .frame(maxWidth: .infinity)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Last 7 days")
        .accessibilityValue("\(days.filter { $0.fraction != nil }.count) workouts")
    }
}

/// A line through recent values with a soft area under it, latest point emphasized.
struct WidgetSparkline: View {
    var values: [Double]
    var tint: WidgetTint

    var body: some View {
        GeometryReader { proxy in
            let points = layout(in: proxy.size)
            ZStack {
                if let first = points.first, let last = points.last {
                    Path { path in
                        path.move(to: CGPoint(x: first.x, y: proxy.size.height))
                        points.forEach { path.addLine(to: $0) }
                        path.addLine(to: CGPoint(x: last.x, y: proxy.size.height))
                        path.closeSubpath()
                    }
                    .fill(LinearGradient(colors: [tint.accent.opacity(0.28), tint.accent.opacity(0)],
                                         startPoint: .top, endPoint: .bottom))
                    Path { path in
                        path.move(to: first)
                        points.dropFirst().forEach { path.addLine(to: $0) }
                    }
                    .stroke(tint.accent, style: StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
                    ForEach(Array(points.dropLast().enumerated()), id: \.offset) { _, point in
                        Circle().fill(tint.accent.opacity(0.55)).frame(width: 5, height: 5).position(point)
                    }
                    Circle().fill(tint.accent)
                        .frame(width: 10, height: 10)
                        .overlay(Circle().stroke(WColor.tile, lineWidth: 2))
                        .position(last)
                }
            }
        }
        .accessibilityHidden(true)
    }

    private func layout(in size: CGSize) -> [CGPoint] {
        guard values.count >= 2, let low = values.min(), let high = values.max() else { return [] }
        let span = max(high - low, 0.2)
        let inset: CGFloat = 6
        return values.enumerated().map { index, value in
            CGPoint(x: inset + CGFloat(index) / CGFloat(values.count - 1) * (size.width - inset * 2),
                    y: inset + CGFloat((high - value) / span) * (size.height - inset * 2))
        }
    }
}

/// Two (or one) labelled bars on one scale: the earlier value quiet, the current one in the area's hue.
struct ComparisonBars: View {
    struct Row: Identifiable {
        var id: String { label }
        var label: String
        var value: Double
        var display: String
        var isCurrent: Bool
        /// Scale for a single-row bar (e.g. 5 of 7 days).
        var scale: Double?
    }

    var rows: [Row]
    var tint: WidgetTint

    var body: some View {
        let top = rows.map { $0.scale ?? $0.value }.max() ?? 1
        Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
            ForEach(rows) { row in
                GridRow {
                    Text(row.label)
                        .font(.footnote)
                        .foregroundStyle(tint.textSecondary)
                    GeometryReader { proxy in
                        ZStack(alignment: .leading) {
                            Capsule().fill(tint.track)
                            Capsule()
                                .fill(row.isCurrent ? tint.accent : tint.quiet)
                                .frame(width: proxy.size.width * CGFloat(top > 0 ? min(row.value / (row.scale ?? top), 1) : 0))
                        }
                    }
                    .frame(height: 10)
                    Text(row.display)
                        .font(.system(.footnote, weight: .bold).monospacedDigit())
                        .foregroundStyle(tint.text)
                        .gridColumnAlignment(.trailing)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(row.label)
                .accessibilityValue(row.display)
            }
        }
    }
}

/// Page indicator for the insight tile: the current page is a short bar.
struct PageDots: View {
    var count: Int
    var current: Int
    var tint: WidgetTint

    var body: some View {
        HStack(spacing: 6) {
            ForEach(0..<count, id: \.self) { index in
                Capsule()
                    .fill(index == current ? tint.accent : tint.quiet)
                    .frame(width: index == current ? 18 : 6, height: 6)
            }
        }
        .animation(.easeOut(duration: 0.2), value: current)
        .accessibilityHidden(true)
    }
}

// MARK: - Tab bar

/// A floating tab bar: four icon-only destinations in a pill, and beside it a
/// round blue + that opens the quick-log menu. Sits over content; tabs
/// reserve `reservedHeight` at the bottom.
struct FloatingTabBar: View {
    @Binding var selection: AppTab
    var quickLog: [QuickLogItem]

    static let reservedHeight: CGFloat = 92

    struct QuickLogItem: Identifiable {
        var id: String { title }
        var title: String
        var symbol: String
        var action: () -> Void
    }

    var body: some View {
        HStack(spacing: 10) {
            HStack(spacing: 0) {
                tab(.today)
                tab(.train)
                tab(.nutrition)
                tab(.progress)
            }
            .padding(.horizontal, 8)
            .frame(height: 64)
            .background(.regularMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(WColor.edge, lineWidth: 1))
            .shadow(color: .black.opacity(0.14), radius: 16, y: 8)

            Menu {
                ForEach(quickLog) { item in
                    Button(action: item.action) { Label(item.title, systemImage: item.symbol) }
                }
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 26, weight: .bold))
                    .foregroundStyle(WColor.onStrong)
                    .frame(width: 64, height: 64)
                    .background(WColor.strong, in: Circle())
                    .shadow(color: WColor.glow, radius: 14, y: 6)
            }
            .menuOrder(.fixed)
            .accessibilityLabel("Log")
            .accessibilityHint("Start a workout, log food or weigh in")
        }
        .padding(.horizontal, 16)
    }

    private func tab(_ tab: AppTab) -> some View {
        let isSelected = selection == tab
        return Button {
            selection = tab
        } label: {
            Image(systemName: tab.symbol)
                .font(.system(size: 21, weight: .semibold))
                .symbolVariant(isSelected ? .fill : .none)
                .foregroundStyle(isSelected ? WColor.onSelected : WColor.textSecondary)
                .frame(maxWidth: .infinity)
                .frame(height: 48)
                .background { if isSelected { Capsule().fill(WColor.selected) } }
                .contentShape(Capsule())
        }
        .buttonStyle(.pressable)
        .accessibilityLabel(tab.title)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }
}

// MARK: - Tiles in lists and plain sections

/// Where a row sits in a tile drawn across several list rows.
enum TilePosition {
    case only, first, middle, last

    var top: CGFloat { self == .only || self == .first ? Radius.xl : 0 }
    var bottom: CGFloat { self == .only || self == .last ? Radius.xl : 0 }
}

/// The white tile behind one list row; rows in sequence join into one tile.
struct TileRowBackground: View {
    var position: TilePosition

    var body: some View {
        UnevenRoundedRectangle(topLeadingRadius: position.top, bottomLeadingRadius: position.bottom,
                               bottomTrailingRadius: position.bottom, topTrailingRadius: position.top,
                               style: .continuous)
            .fill(WColor.tile)
            .padding(.horizontal, Space.gutter)
    }
}

extension View {
    /// A list row drawn as part of a tile. Content supplies its own inner
    /// padding (usually `Space.fieldInset`); the tile sits on the gutter.
    func tileRow(_ position: TilePosition) -> some View {
        listRowInsets(EdgeInsets(top: 0, leading: Space.gutter, bottom: 0, trailing: Space.gutter))
            .listRowSeparator(.hidden)
            .listRowBackground(TileRowBackground(position: position))
    }

    /// A list row directly on the canvas (titles, gaps, whole tiles).
    func canvasListRow(horizontal: CGFloat = Space.gutter) -> some View {
        listRowInsets(EdgeInsets(top: 0, leading: horizontal, bottom: 0, trailing: horizontal))
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
    }

    /// A white tile behind a section that draws its own content and padding.
    func widgetSurface() -> some View {
        background(WColor.tile, in: RoundedRectangle(cornerRadius: Radius.xl, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: Radius.xl, style: .continuous).strokeBorder(WColor.edge, lineWidth: 1)
            }
            .padding(.horizontal, Space.gutter)
    }
}

/// Vertical space between tiles in a list.
struct TileGap: View {
    var height: CGFloat = 12

    var body: some View {
        Color.clear.frame(height: height).canvasListRow().accessibilityHidden(true)
    }
}

/// A screen's large title on the canvas, with an optional line under it and an accessory.
struct WidgetScreenHeader<Accessory: View>: View {
    var title: String
    var subtitle: String?
    @ViewBuilder var accessory: Accessory

    var body: some View {
        HStack(alignment: .center, spacing: Space.sm) {
            VStack(alignment: .leading, spacing: 0) {
                if let subtitle {
                    Text(subtitle)
                        .font(.system(.subheadline, weight: .medium))
                        .foregroundStyle(WColor.textSecondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
                Text(title)
                    .font(.system(.largeTitle, weight: .bold))
                    .foregroundStyle(WColor.textPrimary)
                    .accessibilityAddTraits(.isHeader)
            }
            Spacer(minLength: Space.sm)
            accessory
        }
        .padding(.horizontal, 4)
        .padding(.top, Space.xs)
        .padding(.bottom, Space.xs)
    }
}

// MARK: - Buttons

/// The one primary action in a tile: Vector blue fill with a soft glow, white label, 16 pt corners.
struct WidgetPrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(.body, weight: .bold))
            .foregroundStyle(WColor.onStrong)
            .frame(maxWidth: .infinity, minHeight: 52)
            .padding(.horizontal, Space.md)
            .background(WColor.strong, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .shadow(color: isEnabled ? WColor.glow : .clear, radius: 14, y: 8)
            .opacity(isEnabled ? 1 : 0.4)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.easeOut(duration: 0.15), value: configuration.isPressed)
    }
}

/// Secondary actions in a tile: a soft fill and ink text.
struct WidgetSecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(.subheadline, weight: .semibold))
            .foregroundStyle(WColor.textPrimary)
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .frame(maxWidth: .infinity, minHeight: Size.minTouch)
            .padding(.horizontal, Space.xs)
            .background(WColor.innerStrong, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.easeOut(duration: 0.15), value: configuration.isPressed)
    }
}

extension ButtonStyle where Self == WidgetPrimaryButtonStyle {
    static var widgetPrimary: WidgetPrimaryButtonStyle { WidgetPrimaryButtonStyle() }
}

extension ButtonStyle where Self == WidgetSecondaryButtonStyle {
    static var widgetSecondary: WidgetSecondaryButtonStyle { WidgetSecondaryButtonStyle() }
}

/// A labelled progress bar for a tile: name and value above, an 8 pt rounded bar below.
struct WidgetBar: View {
    var title: String
    var value: Double
    var target: Double
    var unit: String
    var color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(.subheadline).foregroundStyle(WColor.textPrimary)
                Spacer(minLength: Space.xs)
                (Text(Format.integer(value)).bold().foregroundColor(WColor.textPrimary)
                 + Text(" / \(Format.integer(target)) \(unit)"))
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(WColor.textSecondary)
            }
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(WColor.track)
                    Capsule().fill(color)
                        .frame(width: target > 0 ? max(proxy.size.width * min(value / target, 1), value > 0 ? 8 : 0) : 0)
                }
            }
            .frame(height: 8)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue("\(Format.integer(value)) of \(Format.integer(target)) \(unit)")
    }
}

extension WidgetScreenHeader where Accessory == EmptyView {
    init(title: String, subtitle: String? = nil) {
        self.init(title: title, subtitle: subtitle, accessory: { EmptyView() })
    }
}

// MARK: - Flows and sheets

extension View {
    /// The grey dashboard canvas behind a whole screen or sheet.
    func widgetCanvas() -> some View {
        background(WColor.canvas.ignoresSafeArea())
    }
}

/// The one solid blue tile on a screen (as Today's insight): the decision,
/// the plan or the offer, in white type.
struct WidgetHero<Content: View>: View {
    var label: String?
    var symbol: String?
    var spacing: CGFloat = Space.xs
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: spacing) {
            if let label {
                HStack(spacing: 8) {
                    if let symbol {
                        Image(systemName: symbol).font(.system(.body, weight: .semibold))
                    }
                    Text(label).font(.system(.headline))
                }
                .foregroundStyle(WColor.onHero)
                .accessibilityAddTraits(.isHeader)
                .padding(.bottom, 2)
            }
            content
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(WColor.strong, in: RoundedRectangle(cornerRadius: Radius.xl, style: .continuous))
        .padding(.horizontal, Space.gutter)
    }
}

/// A plain tile with an optional grey title, for content below the hero.
struct WidgetSection<Content: View>: View {
    var title: String?
    var symbol: String?
    var spacing: CGFloat = Space.xs
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: spacing) {
            if let title {
                HStack(spacing: 8) {
                    if let symbol {
                        Image(systemName: symbol).font(.system(.body, weight: .semibold))
                    }
                    Text(title).font(.system(.headline))
                }
                .foregroundStyle(WColor.textSecondary)
                .accessibilityAddTraits(.isHeader)
                .padding(.bottom, 2)
            }
            content
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .widgetSurface()
    }
}

/// A selectable row inside a tile: the chosen one takes the soft blue fill,
/// a blue symbol and a check.
struct WidgetChoiceRow: View {
    var title: String
    var detail: String?
    var symbol: String?
    var isSelected: Bool
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                if let symbol {
                    Image(systemName: symbol)
                        .font(.system(.title3, weight: .semibold))
                        .foregroundStyle(isSelected ? WColor.onSelected : WColor.textSecondary)
                        .frame(width: 32)
                        .accessibilityHidden(true)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(.body, weight: .semibold))
                        .foregroundStyle(WColor.textPrimary)
                    if let detail {
                        Text(detail)
                            .font(.subheadline)
                            .foregroundStyle(WColor.textSecondary)
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: Space.sm)
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(.title3))
                    .foregroundStyle(isSelected ? WColor.onSelected : WColor.quiet)
                    .contentTransition(.symbolEffect(.replace))
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, minHeight: Size.minTouch, alignment: .leading)
            .background(isSelected ? WColor.selected : .clear,
                        in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        .buttonStyle(.pressable)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : .isButton)
    }
}

/// Actions pinned to the bottom of a flow or sheet, on the canvas.
struct WidgetActionBar<Content: View>: View {
    var spacing: CGFloat = Space.xs
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: spacing) {
            content
        }
        .padding(.horizontal, Space.gutter + 4)
        .padding(.top, Space.sm)
        .padding(.bottom, Space.xs)
        .frame(maxWidth: .infinity)
        .background(WColor.canvas.opacity(0.94).ignoresSafeArea(edges: .bottom))
        .background(.ultraThinMaterial)
    }
}

/// Plain blue text action with a 44 pt target ("Not now", "Keep current").
struct WidgetTextButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(.body, weight: .semibold))
            .foregroundStyle(WidgetTint.training.ink)
            .frame(maxWidth: .infinity, minHeight: Size.minTouch)
            .contentShape(Rectangle())
            .opacity(configuration.isPressed ? 0.6 : 1)
    }
}

extension ButtonStyle where Self == WidgetTextButtonStyle {
    static var widgetText: WidgetTextButtonStyle { WidgetTextButtonStyle() }
}
