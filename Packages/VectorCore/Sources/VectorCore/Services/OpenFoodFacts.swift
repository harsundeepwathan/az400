import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// A food source that needs the network (millions of packaged products).
public protocol RemoteFoodSearching: Sendable {
    func search(_ query: String, limit: Int) async throws -> [FoodItem]
    func product(barcode: String) async throws -> FoodItem?
}

public enum RemoteFoodError: Error, Equatable, Sendable {
    case offline
    case unavailable
}

/// Open Food Facts: a free, open (ODbL) database of 3M+ products with
/// barcodes. Search uses the search-a-licious service; barcode lookups use
/// the product API. No key needed; OFF asks for a descriptive User-Agent.
public struct OpenFoodFactsClient: RemoteFoodSearching {
    public let session: URLSession
    public let userAgent: String

    static let fields = "code,product_name,brands,nutriments,serving_quantity,serving_size"

    public init(session: URLSession = .shared, userAgent: String = "Vector/1.0 (iOS; support@vector.app)") {
        self.session = session
        self.userAgent = userAgent
    }

    public func search(_ query: String, limit: Int = 20) async throws -> [FoodItem] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2 else { return [] }
        var components = URLComponents(string: "https://search.openfoodfacts.org/search")!
        components.queryItems = [
            URLQueryItem(name: "q", value: trimmed),
            URLQueryItem(name: "page_size", value: String(limit)),
            URLQueryItem(name: "fields", value: Self.fields)
        ]
        let data = try await get(components.url!)
        return Self.parseSearch(data)
    }

    public func product(barcode: String) async throws -> FoodItem? {
        let digits = barcode.filter(\.isNumber)
        guard digits.count >= 6 else { return nil }
        let url = URL(string: "https://world.openfoodfacts.org/api/v2/product/\(digits).json?fields=\(Self.fields)")!
        return Self.parseProduct(try await get(url))
    }

    private func get(_ url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 12
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw RemoteFoodError.offline
        }
        if let http = response as? HTTPURLResponse, http.statusCode == 404 { return Data() }
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw RemoteFoodError.unavailable
        }
        return data
    }

    // MARK: Parsing

    static func parseSearch(_ data: Data) -> [FoodItem] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let hits = root["hits"] as? [[String: Any]] else { return [] }
        var seen = Set<String>()
        return hits.compactMap(parseProductObject).filter { seen.insert($0.name.lowercased() + ($0.brand ?? "")).inserted }
    }

    static func parseProduct(_ data: Data) -> FoodItem? {
        guard !data.isEmpty,
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              (root["status"] as? Int ?? 0) == 1,
              var product = root["product"] as? [String: Any] else { return nil }
        if product["code"] == nil { product["code"] = root["code"] }
        return parseProductObject(product)
    }

    /// Crowd-sourced data needs checking: products without a name or usable
    /// nutrition are dropped, and when the stated calories contradict the
    /// macros (a common data-entry error) the macros win.
    static func parseProductObject(_ product: [String: Any]) -> FoodItem? {
        guard let rawName = product["product_name"] as? String else { return nil }
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, let nutriments = product["nutriments"] as? [String: Any] else { return nil }

        func number(_ key: String) -> Double? {
            if let value = nutriments[key] as? Double { return value }
            if let value = nutriments[key] as? Int { return Double(value) }
            if let value = nutriments[key] as? String { return Double(value) }
            return nil
        }
        let protein = number("proteins_100g")
        let carbs = number("carbohydrates_100g")
        let fat = number("fat_100g")
        let statedKcal = number("energy-kcal_100g") ?? number("energy_100g").map { $0 / 4.184 }
        guard protein != nil || carbs != nil || fat != nil || statedKcal != nil else { return nil }

        let p = max(protein ?? 0, 0), c = max(carbs ?? 0, 0), f = max(fat ?? 0, 0)
        guard p + c + f <= 101 else { return nil }
        let fromMacros = p * 4 + c * 4 + f * 9
        var kcal = statedKcal ?? fromMacros
        if fromMacros > 0, abs(kcal - fromMacros) > max(40, fromMacros * 0.35) { kcal = fromMacros }
        guard kcal <= 902 else { return nil }

        let brand: String? = {
            if let brands = product["brands"] as? [String] { return brands.first }
            if let brands = product["brands"] as? String { return brands.split(separator: ",").first.map { $0.trimmingCharacters(in: .whitespaces) } }
            return nil
        }()
        let code = (product["code"] as? String) ?? (product["code"] as? Int).map(String.init) ?? UUID().uuidString
        let servingGrams: Double? = {
            if let value = product["serving_quantity"] as? Double { return value }
            if let value = product["serving_quantity"] as? Int { return Double(value) }
            if let value = product["serving_quantity"] as? String { return Double(value) }
            return nil
        }()
        let validServing = servingGrams.flatMap { $0 > 0 && $0 <= 2000 ? $0 : nil }
        let servingName = (product["serving_size"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "100 g"

        return FoodItem(
            id: "off-\(code)",
            name: name,
            brand: brand?.isEmpty == true ? nil : brand,
            per100g: Macros(calories: kcal, protein: p, carbs: c, fat: f),
            servingName: validServing == nil ? "100 g" : servingName,
            servingGrams: validServing ?? 100,
            barcode: code
        )
    }
}
