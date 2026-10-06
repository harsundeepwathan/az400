import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// One food the model believes is on the plate. Everything here is an
/// estimate, so it's fully editable in the review step.
public struct RecognizedFood: Identifiable, Hashable, Sendable {
    public var id: UUID
    public var food: FoodItem
    public var grams: Double
    /// 0...1 model confidence for the identification (not the portion).
    public var confidence: Double
    /// Other plausible identifications, offered as one-tap corrections.
    public var alternatives: [FoodItem]

    public init(id: UUID = UUID(), food: FoodItem, grams: Double, confidence: Double, alternatives: [FoodItem] = []) {
        self.id = id
        self.food = food
        self.grams = grams
        self.confidence = confidence
        self.alternatives = alternatives
    }

    public var macros: Macros { food.macros(grams: grams) }
    public var isLowConfidence: Bool { confidence < 0.6 }
}

public struct MealAnalysis: Hashable, Sendable {
    public var items: [RecognizedFood]
    public var analyzedAt: Date

    public init(items: [RecognizedFood], analyzedAt: Date = Date()) {
        self.items = items
        self.analyzedAt = analyzedAt
    }

    public var total: Macros { items.reduce(.zero) { $0 + $1.macros } }
}

public enum MealRecognitionError: Error, Hashable, Sendable {
    case noFoodDetected
    case imageUnreadable
    case network
    case quotaExceeded

    public var title: String {
        switch self {
        case .noFoodDetected: "We couldn't spot any food"
        case .imageUnreadable: "That photo didn't come through"
        case .network: "You're offline"
        case .quotaExceeded: "You've used this week's free scans"
        }
    }

    public var message: String {
        switch self {
        case .noFoodDetected: "Try again with the whole plate in frame and good lighting, or search for the food instead."
        case .imageUnreadable: "Please retake the photo."
        case .network: "Meal scanning needs a connection. You can still search and log foods manually."
        case .quotaExceeded: "Pro includes unlimited AI meal scans. Search and quick add are always free."
        }
    }
}

public protocol MealRecognizing: Sendable {
    func analyze(imageData: Data) async throws -> MealAnalysis
}

/// Calls the Vector backend, which proxies the vision model so no API key
/// ever ships in the app binary. Contract:
///
///     POST {endpoint}            X-Vector-Key: <app key>
///     { "image": "<base64 jpeg>" }
///     → { "items": [{ "name", "grams", "calories", "protein", "carbs", "fat",
///                      "confidence", "matchId"?, "alternatives"?: [String] }] }
public struct RemoteMealRecognizer: MealRecognizing {
    public let endpoint: URL
    /// Shared secret sent as `X-Vector-Key` (see backend/meal-scan).
    public let appKey: String?
    public let database: FoodDatabase
    public let session: URLSession

    public init(endpoint: URL, appKey: String? = nil, database: FoodDatabase = FoodDatabase(), session: URLSession = .shared) {
        self.endpoint = endpoint
        self.appKey = appKey
        self.database = database
        self.session = session
    }

    struct Response: Decodable {
        struct Item: Decodable {
            var name: String
            var grams: Double
            var calories: Double
            var protein: Double
            var carbs: Double
            var fat: Double
            var confidence: Double
            var matchId: String?
            var alternatives: [String]?
        }
        var items: [Item]
    }

    public func analyze(imageData: Data) async throws -> MealAnalysis {
        guard !imageData.isEmpty else { throw MealRecognitionError.imageUnreadable }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let appKey { request.setValue(appKey, forHTTPHeaderField: "X-Vector-Key") }
        request.httpBody = try JSONSerialization.data(withJSONObject: ["image": imageData.base64EncodedString()])
        request.timeoutInterval = 50

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw MealRecognitionError.network
        }
        if let http = response as? HTTPURLResponse {
            if http.statusCode == 402 { throw MealRecognitionError.quotaExceeded }
            guard (200..<300).contains(http.statusCode) else { throw MealRecognitionError.network }
        }
        return try Self.decode(data, database: database)
    }

    static func decode(_ data: Data, database: FoodDatabase) throws -> MealAnalysis {
        let decoded = try JSONDecoder().decode(Response.self, from: data)
        let items = decoded.items.filter { $0.grams > 0 }.map { item -> RecognizedFood in
            let factor = 100 / item.grams
            let food = item.matchId.flatMap(database.food(id:)) ?? FoodItem(
                id: "ai-" + item.name.lowercased().replacingOccurrences(of: " ", with: "-"),
                name: item.name,
                per100g: Macros(calories: item.calories, protein: item.protein, carbs: item.carbs, fat: item.fat).scaled(by: factor),
                servingName: "1 portion",
                servingGrams: item.grams
            )
            let alternatives = (item.alternatives ?? []).compactMap { database.search($0).first }
            return RecognizedFood(food: food, grams: item.grams, confidence: item.confidence, alternatives: alternatives)
        }
        guard !items.isEmpty else { throw MealRecognitionError.noFoodDetected }
        return MealAnalysis(items: items)
    }
}

/// Offline recognizer used in previews, UI tests and demo mode. It returns a
/// realistic plate so the full review / correction flow can be exercised.
public struct DemoMealRecognizer: MealRecognizing {
    public let database: FoodDatabase
    public let latency: Duration

    public init(database: FoodDatabase = FoodDatabase(), latency: Duration = .seconds(2)) {
        self.database = database
        self.latency = latency
    }

    public func analyze(imageData: Data) async throws -> MealAnalysis {
        try await Task.sleep(for: latency)
        func food(_ id: String) -> FoodItem { database.food(id: id)! }
        return MealAnalysis(items: [
            RecognizedFood(food: food("chicken-breast"), grams: 180, confidence: 0.91,
                           alternatives: [food("chicken-thigh"), food("tofu")]),
            RecognizedFood(food: food("white-rice"), grams: 200, confidence: 0.84,
                           alternatives: [food("brown-rice"), food("quinoa")]),
            RecognizedFood(food: food("mixed-veg"), grams: 120, confidence: 0.58,
                           alternatives: [food("broccoli"), food("salad-greens")])
        ])
    }
}
