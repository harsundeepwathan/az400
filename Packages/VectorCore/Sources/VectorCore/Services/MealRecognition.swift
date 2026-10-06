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

    /// Calories and macros the user typed in, for `overrideGrams` of food.
    /// They scale with later portion changes.
    public var macroOverride: Macros?
    public var overrideGrams: Double?

    public init(id: UUID = UUID(), food: FoodItem, grams: Double, confidence: Double, alternatives: [FoodItem] = []) {
        self.id = id
        self.food = food
        self.grams = grams
        self.confidence = confidence
        self.alternatives = alternatives
    }

    public var macros: Macros {
        if let macroOverride, let overrideGrams {
            return overrideGrams > 0 ? macroOverride.scaled(by: grams / overrideGrams) : macroOverride
        }
        return food.macros(grams: grams)
    }

    public var isLowConfidence: Bool { confidence < 0.6 }
    public var hasEditedMacros: Bool { macroOverride != nil }

    /// Sets the nutrition for the current portion. Passing the computed values clears the override.
    public mutating func setMacros(_ macros: Macros) {
        let computed = food.macros(grams: grams)
        let unchanged = abs(macros.calories - computed.calories) < 0.5 && abs(macros.protein - computed.protein) < 0.05
            && abs(macros.carbs - computed.carbs) < 0.05 && abs(macros.fat - computed.fat) < 0.05
        if unchanged {
            macroOverride = nil
            overrideGrams = nil
        } else {
            macroOverride = macros
            overrideGrams = grams
        }
    }

    /// A different food means the old typed-in numbers no longer apply.
    public mutating func replaceFood(_ newFood: FoodItem) {
        food = newFood
        macroOverride = nil
        overrideGrams = nil
    }
}

/// How the user changed an AI estimate before logging it. Sent (without the
/// photo) so scan accuracy can be measured and improved.
public struct ScanCorrection: Hashable, Codable, Sendable {
    public var itemsDetected: Int
    public var itemsLogged: Int
    public var renamed: Int
    public var removed: Int
    public var added: Int
    public var portionsChanged: Int
    public var macrosEdited: Int
    public var estimatedCalories: Double
    public var loggedCalories: Double

    public var wasCorrected: Bool {
        renamed + removed + added + portionsChanged + macrosEdited > 0
    }

    /// Relative calorie change from the AI estimate to what was logged.
    public var calorieError: Double {
        estimatedCalories > 0 ? (loggedCalories - estimatedCalories) / estimatedCalories : 0
    }

    /// Portions within 10% of the estimate count as accepted.
    public static func compare(original: [RecognizedFood], final: [RecognizedFood]) -> ScanCorrection {
        let originalByID = Dictionary(original.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var renamed = 0, portions = 0, edited = 0, added = 0
        for item in final {
            guard let source = originalByID[item.id] else {
                added += 1
                continue
            }
            if item.food.id != source.food.id { renamed += 1 }
            if source.grams > 0 ? abs(item.grams - source.grams) / source.grams > 0.1 : item.grams > 0 { portions += 1 }
            if item.hasEditedMacros { edited += 1 }
        }
        let finalIDs = Set(final.map(\.id))
        return ScanCorrection(
            itemsDetected: original.count,
            itemsLogged: final.count,
            renamed: renamed,
            removed: original.filter { !finalIDs.contains($0.id) }.count,
            added: added,
            portionsChanged: portions,
            macrosEdited: edited,
            estimatedCalories: original.reduce(0) { $0 + $1.macros.calories },
            loggedCalories: final.reduce(0) { $0 + $1.macros.calories }
        )
    }
}

public struct MealAnalysis: Hashable, Sendable {
    public var items: [RecognizedFood]
    public var analyzedAt: Date
    /// Server id for this scan, used to report corrections. Nil offline/demo.
    public var scanID: String?
    /// The server's view of the user's remaining scans after this one.
    public var allowance: ScanAllowance?

    public init(items: [RecognizedFood], analyzedAt: Date = Date(), scanID: String? = nil, allowance: ScanAllowance? = nil) {
        self.items = items
        self.analyzedAt = analyzedAt
        self.scanID = scanID
        self.allowance = allowance
    }
}

public enum MealRecognitionError: Error, Hashable, Sendable {
    case noFoodDetected
    case imageUnreadable
    case network
    case quotaExceeded
    case signInRequired
    case busy

    public var title: String {
        switch self {
        case .noFoodDetected: "We couldn't spot any food"
        case .imageUnreadable: "That photo didn't come through"
        case .network: "You're offline"
        case .quotaExceeded: "You've used this week's free scans"
        case .signInRequired: "Sign in to scan meals"
        case .busy: "Scanning is busy right now"
        }
    }

    public var message: String {
        switch self {
        case .noFoodDetected: "Try again with the whole plate in frame and good lighting, or search for the food instead."
        case .imageUnreadable: "Please retake the photo."
        case .network: "Meal scanning needs a connection. You can still search and log foods manually."
        case .quotaExceeded: "Pro includes up to 30 AI meal scans a day. Search, barcode and quick add are always free."
        case .signInRequired: "Meal scanning uses your account so your free scans are counted fairly. Search and quick add work without one."
        case .busy: "Please try again in a minute, or search for the food instead."
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
    public let api: APIClient
    public let database: FoodDatabase

    public init(api: APIClient, database: FoodDatabase = FoodDatabase()) {
        self.api = api
        self.database = database
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
        let response: APIClient.ScanResponse
        do {
            response = try await api.scanMeal(jpeg: imageData)
        } catch let error as APIError {
            switch error {
            case .signedOut: throw MealRecognitionError.signInRequired
            case .offline: throw MealRecognitionError.network
            case .scanQuotaExceeded: throw MealRecognitionError.quotaExceeded
            case .rateLimited, .unavailable: throw MealRecognitionError.busy
            case .rejected(_, let code) where code == "unsupported_image" || code == "image_too_large":
                throw MealRecognitionError.imageUnreadable
            case .rejected: throw MealRecognitionError.busy
            }
        }
        var analysis = try Self.decode(response.body, database: database)
        analysis.scanID = response.scanID
        analysis.allowance = response.allowance
        return analysis
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
