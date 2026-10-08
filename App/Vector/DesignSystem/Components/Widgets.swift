import SwiftUI

// MARK: - Tile

/// The unit of the widget dashboard: a rounded tile with its area's hue
/// glowing from one corner, a header (symbol, title, optional accessory and
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

/// White (or near-black) tile with a soft wash of the area's hue in one corner.
struct WidgetBackground: View {
    var tint: WidgetTint

    var body: some View {
        WColor.tile.overlay {
            RadialGradient(colors: [tint.glow, tint.glow.opacity(0)], center: tint.glowCorner,
                           startRadius: 0, endRadius: 280)
        }
    }
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
struct MacroRing: View {
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
                                        .fill(LinearGradient(colors: [tint.accent, tint.accent.opacity(0.75)],
                                                             startPoint: .top, endPoint: .bottom))
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
                        .foregroundStyle(WColor.textSecondary)
                    GeometryReader { proxy in
                        ZStack(alignment: .leading) {
                            Capsule().fill(WColor.track)
                            Capsule()
                                .fill(row.isCurrent ? tint.accent : WColor.quiet)
                                .frame(width: proxy.size.width * CGFloat(top > 0 ? min(row.value / (row.scale ?? top), 1) : 0))
                        }
                    }
                    .frame(height: 10)
                    Text(row.display)
                        .font(.system(.footnote, weight: .bold).monospacedDigit())
                        .foregroundStyle(WColor.textPrimary)
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
                    .fill(index == current ? tint.accent : WColor.quiet)
                    .frame(width: index == current ? 18 : 6, height: 6)
            }
        }
        .animation(.easeOut(duration: 0.2), value: current)
        .accessibilityHidden(true)
    }
}

// MARK: - Tab bar

/// A floating tab bar: four destinations and, in the middle, a + that opens
/// the quick-log menu. Sits over content; tabs reserve `reservedHeight` at the bottom.
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
        HStack(spacing: 0) {
            tab(.today)
            tab(.train)
            Menu {
                ForEach(quickLog) { item in
                    Button(action: item.action) { Label(item.title, systemImage: item.symbol) }
                }
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 26, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 60, height: 60)
                    .background(WColor.add, in: Circle())
                    .shadow(color: WColor.add.opacity(0.4), radius: 10, y: 5)
            }
            .menuOrder(.fixed)
            .frame(width: 76)
            .accessibilityLabel("Log")
            .accessibilityHint("Start a workout, log food or weigh in")
            tab(.nutrition)
            tab(.progress)
        }
        .padding(.horizontal, 6)
        .frame(height: 68)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(WColor.edge, lineWidth: 1))
        .shadow(color: .black.opacity(0.12), radius: 16, y: 8)
        .padding(.horizontal, 16)
    }

    private func tab(_ tab: AppTab) -> some View {
        let isSelected = selection == tab
        return Button {
            selection = tab
        } label: {
            VStack(spacing: 2) {
                Image(systemName: tab.symbol)
                    .font(.system(size: 20, weight: .semibold))
                    .symbolVariant(isSelected ? .fill : .none)
                Text(tab.title)
                    .font(.system(size: 11, weight: .semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .foregroundStyle(isSelected ? WColor.onStrong : WColor.textSecondary)
            .frame(maxWidth: .infinity)
            .frame(height: 56)
            .background { if isSelected { Capsule().fill(WColor.strong) } }
            .contentShape(Capsule())
        }
        .buttonStyle(.pressable)
        .accessibilityLabel(tab.title)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }
}
