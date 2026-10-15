import SwiftUI
import UIKit
import KiraCore

/// A service's logo in the iOS app-icon shape: the provider's official App Store icon when
/// available, otherwise an Apple-style tile (white glyph on a system-colour gradient, or a
/// monogram for custom entries). Decorative — the service name is always shown beside it.
struct ServiceIcon: View {
    let service: SubscriptionService?
    let name: String
    var size: CGFloat
    /// Draws a ring in the given colour so overlapping icons stay distinct (icon stacks).
    var ring: Color?

    @ScaledMetric(relativeTo: .body) private var scale = 1.0
    @AppStorage(ServiceLogoStore.preferenceKey) private var showLogos = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// One-time seed from the in-memory cache so known logos render on the first frame;
    /// `task(id:)` keeps it current when the service changes.
    @State private var logo: UIImage?
    @State private var logoAppID: Int?

    init(subscription: ServiceSubscription, size: CGFloat = 44, ring: Color? = nil) {
        self.init(service: SubscriptionCatalog.service(id: subscription.serviceID), name: subscription.name, size: size, ring: ring)
    }

    init(service: SubscriptionService?, name: String, size: CGFloat = 44, ring: Color? = nil) {
        self.service = service
        self.name = name
        self.size = size
        self.ring = ring
        let cached = service?.appStoreID.flatMap(ServiceLogoStore.shared.cachedLogo(for:))
        _logo = State(initialValue: cached)
        _logoAppID = State(initialValue: cached == nil ? nil : service?.appStoreID)
    }

    var body: some View {
        let side = size * scale
        // iOS app icons use a continuous corner of ~22.4% of the side.
        let shape = RoundedRectangle(cornerRadius: side * 0.2237, style: .continuous)
        ZStack {
            if showLogos, let logo, logoAppID == service?.appStoreID {
                Image(uiImage: logo)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fill)
                    .transition(.opacity)
            } else {
                ServiceGlyphTile(service: service, name: name, side: side)
            }
        }
        .frame(width: side, height: side)
        .clipShape(shape)
        // Hairline edge, as the App Store draws it, so white icons hold their shape on white rows.
        .overlay { shape.strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5) }
        .padding(ring == nil ? 0 : max(1.5, side * 0.06))
        .background {
            if let ring {
                RoundedRectangle(cornerRadius: side * 0.2237 + max(1.5, side * 0.06), style: .continuous).fill(ring)
            }
        }
        .accessibilityHidden(true)
        .task(id: showLogos ? service?.appStoreID : nil) {
            guard showLogos, let appID = service?.appStoreID, logoAppID != appID else { return }
            let image = await ServiceLogoStore.shared.logo(for: appID)
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) {
                logo = image
                logoAppID = image == nil ? nil : appID
            }
        }
    }
}

/// Fallback tile in the style of Apple's own icons (Settings, iCloud): a white SF Symbol on a
/// gradient of the service's system colour. Custom subscriptions get a rounded monogram.
struct ServiceGlyphTile: View {
    let service: SubscriptionService?
    let name: String
    let side: CGFloat

    var body: some View {
        let tint = KiraColor.tint(service?.tint ?? "slate")
        ZStack {
            Rectangle().fill(tint.gradient)
            if let service {
                Image(systemName: service.symbol)
                    .symbolVariant(.fill)
                    .font(.system(size: side * 0.46, weight: .semibold))
                    .foregroundStyle(.white)
            } else {
                Text(monogram)
                    .font(.system(size: side * 0.44, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .minimumScaleFactor(0.5)
            }
        }
    }

    private var monogram: String {
        let words = name.split(separator: " ").prefix(2)
        let letters = words.compactMap(\.first).map(String.init).joined()
        return letters.isEmpty ? "?" : letters.uppercased()
    }
}

/// Overlapping logos for a small set of services (e.g. what's due next).
struct ServiceIconStack: View {
    let subscriptions: [ServiceSubscription]
    var size: CGFloat = 26
    var limit = 4

    var body: some View {
        HStack(spacing: -size * 0.18) {
            ForEach(subscriptions.prefix(limit)) { subscription in
                ServiceIcon(subscription: subscription, size: size, ring: KiraColor.surface)
            }
            if subscriptions.count > limit {
                Text("+\(subscriptions.count - limit)")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(KiraColor.textSecondary)
                    .padding(.leading, size * 0.4)
            }
        }
        .accessibilityHidden(true)
    }
}
