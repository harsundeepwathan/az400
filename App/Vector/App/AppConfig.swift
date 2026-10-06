import Foundation

/// Values that differ per environment live in Info.plist (set in project.yml),
/// never in code.
enum AppConfig {
    private static func string(_ key: String) -> String? {
        guard let value = Bundle.main.object(forInfoDictionaryKey: key) as? String,
              !value.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        return value
    }

    /// Base URL of `backend/api`, e.g. https://api.example.com
    static var apiBaseURL: URL? { string("VectorAPIBaseURL").flatMap(URL.init(string:)) }

    static var mealScanEndpoint: URL? { apiBaseURL?.appendingPathComponent("v1/meal-scan") }

    static var termsURL: URL { string("VectorTermsURL").flatMap(URL.init(string:)) ?? URL(string: "https://www.apple.com/legal/internet-services/itunes/dev/stdeula/")! }

    static var privacyURL: URL { string("VectorPrivacyURL").flatMap(URL.init(string:)) ?? URL(string: "https://www.apple.com/legal/privacy/")! }
}
