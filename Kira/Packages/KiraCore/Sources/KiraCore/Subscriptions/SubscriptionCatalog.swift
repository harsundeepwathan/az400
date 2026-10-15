import Foundation

/// A well-known subscription service available in Malaysia.
///
/// Prices are intentionally NOT included: plans and prices change and vary by tier, so the
/// user enters what they actually pay (or Kira reads it from a matched charge).
public struct SubscriptionService: Identifiable, Hashable, Sendable {
    public let id: String
    public let name: String
    /// Statement / receipt text this service appears under (normalised by MerchantNormalizer).
    public let aliases: [String]
    /// SF Symbol shown when no logo is available.
    public let symbol: String
    /// Category tint token (see KiraColor.tint).
    public let tint: String
    public let categoryID: String
    /// Usually purchased through the App Store (managed in Apple ID › Subscriptions).
    public let billedThroughAppleByDefault: Bool

    public init(id: String, name: String, aliases: [String], symbol: String, tint: String,
                category: BuiltInCategory = .subscriptions, billedThroughApple: Bool = false) {
        self.id = id
        self.name = name
        self.aliases = ([name] + aliases).map { MerchantNormalizer.key($0) }.filter { !$0.isEmpty }
        self.symbol = symbol
        self.tint = tint
        self.categoryID = category.id
        self.billedThroughAppleByDefault = billedThroughApple
    }
}

public enum SubscriptionCatalog {
    public static let services: [SubscriptionService] = [
        // Video
        SubscriptionService(id: "netflix", name: "Netflix", aliases: ["NETFLIX COM", "NETFLIX"], symbol: "play.tv", tint: "red", category: .entertainment),
        SubscriptionService(id: "disney-hotstar", name: "Disney+ Hotstar", aliases: ["DISNEY PLUS", "DISNEY", "HOTSTAR"], symbol: "play.tv", tint: "blue", category: .entertainment),
        SubscriptionService(id: "prime-video", name: "Prime Video", aliases: ["PRIME VIDEO", "AMAZON PRIME", "PRIMEVIDEO"], symbol: "play.tv", tint: "blue", category: .entertainment),
        SubscriptionService(id: "viu", name: "Viu", aliases: ["VIU"], symbol: "play.tv", tint: "amber", category: .entertainment),
        SubscriptionService(id: "iqiyi", name: "iQIYI", aliases: ["IQIYI"], symbol: "play.tv", tint: "green", category: .entertainment),
        SubscriptionService(id: "sooka", name: "sooka", aliases: ["SOOKA"], symbol: "play.tv", tint: "violet", category: .entertainment),
        SubscriptionService(id: "astro", name: "Astro", aliases: ["ASTRO", "ASTRO MALAYSIA"], symbol: "tv", tint: "violet", category: .entertainment),
        SubscriptionService(id: "youtube-premium", name: "YouTube Premium", aliases: ["YOUTUBE PREMIUM", "GOOGLE YOUTUBE", "YOUTUBEPREMIUM"], symbol: "play.rectangle", tint: "red", category: .entertainment),
        SubscriptionService(id: "apple-tv", name: "Apple TV+", aliases: ["APPLE TV"], symbol: "appletv", tint: "slate", category: .entertainment, billedThroughApple: true),
        // Music & audio
        SubscriptionService(id: "spotify", name: "Spotify", aliases: ["SPOTIFY", "SPOTIFY AB", "SPOTIFY P"], symbol: "music.note", tint: "green", category: .entertainment),
        SubscriptionService(id: "apple-music", name: "Apple Music", aliases: ["APPLE MUSIC"], symbol: "music.note", tint: "rose", category: .entertainment, billedThroughApple: true),
        SubscriptionService(id: "youtube-music", name: "YouTube Music", aliases: ["YOUTUBE MUSIC"], symbol: "music.note", tint: "red", category: .entertainment),
        // Apple & cloud
        SubscriptionService(id: "icloud", name: "iCloud+", aliases: ["ICLOUD"], symbol: "icloud", tint: "blue", billedThroughApple: true),
        SubscriptionService(id: "apple-one", name: "Apple One", aliases: ["APPLE ONE"], symbol: "apple.logo", tint: "slate", billedThroughApple: true),
        SubscriptionService(id: "apple-arcade", name: "Apple Arcade", aliases: ["APPLE ARCADE"], symbol: "gamecontroller", tint: "rose", category: .entertainment, billedThroughApple: true),
        SubscriptionService(id: "google-one", name: "Google One", aliases: ["GOOGLE ONE", "GOOGLE STORAGE"], symbol: "externaldrive.badge.icloud", tint: "blue"),
        SubscriptionService(id: "dropbox", name: "Dropbox", aliases: ["DROPBOX"], symbol: "shippingbox", tint: "blue"),
        // Productivity & AI
        SubscriptionService(id: "microsoft-365", name: "Microsoft 365", aliases: ["MICROSOFT 365", "MICROSOFT", "MSFT", "OFFICE 365"], symbol: "doc.richtext", tint: "amber"),
        SubscriptionService(id: "chatgpt", name: "ChatGPT Plus", aliases: ["OPENAI", "CHATGPT"], symbol: "sparkles", tint: "green"),
        SubscriptionService(id: "canva", name: "Canva Pro", aliases: ["CANVA"], symbol: "paintpalette", tint: "violet"),
        SubscriptionService(id: "adobe", name: "Adobe Creative Cloud", aliases: ["ADOBE"], symbol: "paintbrush", tint: "red"),
        SubscriptionService(id: "notion", name: "Notion", aliases: ["NOTION"], symbol: "note.text", tint: "slate"),
        SubscriptionService(id: "duolingo", name: "Duolingo", aliases: ["DUOLINGO"], symbol: "character.book.closed", tint: "green", category: .education),
        // Gaming
        SubscriptionService(id: "playstation-plus", name: "PlayStation Plus", aliases: ["PLAYSTATION", "SONY INTERACTIVE", "PSN"], symbol: "gamecontroller", tint: "blue", category: .entertainment),
        SubscriptionService(id: "xbox-game-pass", name: "Xbox Game Pass", aliases: ["XBOX"], symbol: "gamecontroller", tint: "green", category: .entertainment),
        SubscriptionService(id: "nintendo-online", name: "Nintendo Switch Online", aliases: ["NINTENDO"], symbol: "gamecontroller", tint: "red", category: .entertainment),
        // Local memberships
        SubscriptionService(id: "grab-unlimited", name: "GrabUnlimited", aliases: ["GRABUNLIMITED", "GRAB UNLIMITED"], symbol: "car", tint: "green"),
        SubscriptionService(id: "pandapro", name: "foodpanda pandapro", aliases: ["PANDAPRO", "PANDA PRO"], symbol: "takeoutbag.and.cup.and.straw", tint: "rose"),
        SubscriptionService(id: "anytime-fitness", name: "Anytime Fitness", aliases: ["ANYTIME FITNESS"], symbol: "figure.run", tint: "violet", category: .fitness)
    ]

    public static func service(id: String?) -> SubscriptionService? {
        guard let id else { return nil }
        return services.first { $0.id == id }
    }

    /// Finds the catalog service a statement line or merchant name refers to (longest alias wins).
    public static func match(_ text: String) -> SubscriptionService? {
        let key = " " + fullKey(text) + " "
        let compact = key.replacingOccurrences(of: " ", with: "")
        var best: (service: SubscriptionService, length: Int)?
        for service in services {
            for alias in service.aliases {
                let squashed = alias.replacingOccurrences(of: " ", with: "")
                let hit = key.contains(" \(alias) ") || (squashed.count >= 6 && compact.contains(squashed))
                if hit && alias.count > (best?.length ?? 0) { best = (service, alias.count) }
            }
        }
        return best?.service
    }

    /// Normalised key that keeps text after "*" — card networks write "GOOGLE *YOUTUBE PREMIUM",
    /// where the brand that matters comes after the asterisk.
    public static func fullKey(_ text: String) -> String {
        MerchantNormalizer.key(text.replacingOccurrences(of: "*", with: " "))
    }

    /// Case-insensitive search for the service picker.
    public static func search(_ query: String) -> [SubscriptionService] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return services }
        return services.filter { $0.name.range(of: trimmed, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
    }
}
