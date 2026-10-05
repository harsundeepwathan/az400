import Foundation

/// Food lookup. The bundled table covers common whole foods so search,
/// barcode fallbacks and AI-scan corrections work offline; a production
/// build would back this protocol with a remote nutrition API.
public protocol FoodSearching: Sendable {
    func search(_ query: String) -> [FoodItem]
    func food(id: String) -> FoodItem?
    func food(barcode: String) -> FoodItem?
}

public struct FoodDatabase: FoodSearching {
    public let foods: [FoodItem]

    public init(foods: [FoodItem] = FoodDatabase.bundled) {
        self.foods = foods
    }

    public func search(_ query: String) -> [FoodItem] {
        let terms = query.lowercased().split(separator: " ").map(String.init)
        guard !terms.isEmpty else { return foods }
        var scored: [(food: FoodItem, score: Int)] = []
        for food in foods {
            let haystack = (food.name + " " + (food.brand ?? "")).lowercased()
            var score = 0
            for term in terms {
                if haystack.hasPrefix(term) {
                    score += 3
                } else if haystack.contains(" " + term) {
                    score += 2
                } else if haystack.contains(term) {
                    score += 1
                }
            }
            if score > 0 { scored.append((food, score)) }
        }
        scored.sort { $0.score == $1.score ? $0.food.name < $1.food.name : $0.score > $1.score }
        return scored.map(\.food)
    }

    public func food(id: String) -> FoodItem? { foods.first { $0.id == id } }
    public func food(barcode: String) -> FoodItem? { foods.first { $0.barcode == barcode } }

    private static func item(_ id: String, _ name: String, _ kcal: Double, _ p: Double, _ c: Double, _ f: Double,
                             serving: String, grams: Double, barcode: String? = nil) -> FoodItem {
        FoodItem(id: id, name: name, per100g: Macros(calories: kcal, protein: p, carbs: c, fat: f),
                 servingName: serving, servingGrams: grams, barcode: barcode)
    }

    public static let bundled: [FoodItem] = [
        item("chicken-breast", "Chicken breast, grilled", 165, 31, 0, 3.6, serving: "1 breast", grams: 170),
        item("chicken-thigh", "Chicken thigh, roasted", 209, 26, 0, 10.9, serving: "1 thigh", grams: 110),
        item("salmon", "Salmon, baked", 206, 22, 0, 12.4, serving: "1 fillet", grams: 150),
        item("tuna-canned", "Tuna, canned in water", 116, 25.5, 0, 0.8, serving: "1 can", grams: 140),
        item("beef-mince-5", "Beef mince 5% fat, cooked", 174, 27, 0, 7, serving: "1 portion", grams: 125),
        item("steak-sirloin", "Sirloin steak, grilled", 206, 29, 0, 9.5, serving: "1 steak", grams: 200),
        item("egg", "Egg, whole", 143, 12.6, 0.7, 9.5, serving: "1 large", grams: 50),
        item("egg-white", "Egg white", 52, 10.9, 0.7, 0.2, serving: "1 large", grams: 33),
        item("greek-yogurt", "Greek yogurt, 0% fat", 59, 10.3, 3.6, 0.4, serving: "1 pot", grams: 170),
        item("cottage-cheese", "Cottage cheese", 98, 11.1, 3.4, 4.3, serving: "1/2 cup", grams: 113),
        item("whey", "Whey protein", 400, 80, 8, 6, serving: "1 scoop", grams: 30, barcode: "5060469985054"),
        item("tofu", "Tofu, firm", 144, 15.8, 2.8, 8.7, serving: "1/2 block", grams: 175),
        item("white-rice", "White rice, cooked", 130, 2.7, 28.2, 0.3, serving: "1 cup", grams: 158),
        item("brown-rice", "Brown rice, cooked", 123, 2.7, 25.6, 1, serving: "1 cup", grams: 195),
        item("pasta", "Pasta, cooked", 158, 5.8, 30.9, 0.9, serving: "1 cup", grams: 140),
        item("oats", "Rolled oats", 379, 13.2, 67.7, 6.5, serving: "1/2 cup", grams: 40),
        item("bread-wholegrain", "Wholegrain bread", 247, 13, 41, 3.4, serving: "1 slice", grams: 40),
        item("bagel", "Bagel, plain", 257, 10, 50, 1.6, serving: "1 bagel", grams: 100),
        item("potato", "Potato, boiled", 87, 1.9, 20.1, 0.1, serving: "1 medium", grams: 170),
        item("sweet-potato", "Sweet potato, baked", 90, 2, 20.7, 0.2, serving: "1 medium", grams: 150),
        item("quinoa", "Quinoa, cooked", 120, 4.4, 21.3, 1.9, serving: "1 cup", grams: 185),
        item("tortilla", "Flour tortilla", 304, 8, 50, 7.5, serving: "1 large", grams: 64),
        item("mixed-veg", "Mixed vegetables, steamed", 58, 2.9, 11.6, 0.3, serving: "1 cup", grams: 120),
        item("broccoli", "Broccoli, steamed", 35, 2.4, 7.2, 0.4, serving: "1 cup", grams: 156),
        item("spinach", "Spinach, raw", 23, 2.9, 3.6, 0.4, serving: "1 cup", grams: 30),
        item("salad-greens", "Mixed salad greens", 17, 1.3, 3.3, 0.2, serving: "1 bowl", grams: 85),
        item("avocado", "Avocado", 160, 2, 8.5, 14.7, serving: "1/2 fruit", grams: 100),
        item("banana", "Banana", 89, 1.1, 22.8, 0.3, serving: "1 medium", grams: 118),
        item("apple", "Apple", 52, 0.3, 13.8, 0.2, serving: "1 medium", grams: 182),
        item("blueberries", "Blueberries", 57, 0.7, 14.5, 0.3, serving: "1 cup", grams: 148),
        item("orange", "Orange", 47, 0.9, 11.8, 0.1, serving: "1 medium", grams: 131),
        item("almonds", "Almonds", 579, 21.2, 21.6, 49.9, serving: "1 handful", grams: 28),
        item("peanut-butter", "Peanut butter", 588, 25, 20, 50, serving: "1 tbsp", grams: 16),
        item("olive-oil", "Olive oil", 884, 0, 0, 100, serving: "1 tbsp", grams: 13.5),
        item("butter", "Butter", 717, 0.9, 0.1, 81, serving: "1 tsp", grams: 5),
        item("cheddar", "Cheddar cheese", 403, 25, 1.3, 33, serving: "1 slice", grams: 28),
        item("mozzarella", "Mozzarella", 280, 28, 3.1, 17, serving: "1 portion", grams: 30),
        item("milk-semi", "Milk, semi-skimmed", 47, 3.5, 4.8, 1.7, serving: "1 glass", grams: 250),
        item("oat-milk", "Oat milk", 46, 1, 6.7, 1.5, serving: "1 glass", grams: 250),
        item("hummus", "Hummus", 166, 7.9, 14.3, 9.6, serving: "2 tbsp", grams: 30),
        item("lentils", "Lentils, cooked", 116, 9, 20, 0.4, serving: "1 cup", grams: 198),
        item("black-beans", "Black beans, cooked", 132, 8.9, 23.7, 0.5, serving: "1/2 cup", grams: 86),
        item("pizza-margherita", "Pizza, margherita", 250, 11, 31, 9, serving: "1 slice", grams: 107),
        item("burger", "Beef burger in bun", 254, 13, 24, 12, serving: "1 burger", grams: 220),
        item("fries", "French fries", 312, 3.4, 41, 15, serving: "1 medium", grams: 117),
        item("sushi-salmon", "Salmon sushi roll", 150, 6, 26, 2.5, serving: "6 pieces", grams: 170),
        item("granola", "Granola", 471, 10, 64, 20, serving: "1/2 cup", grams: 60),
        item("protein-bar", "Protein bar", 360, 33, 37, 11, serving: "1 bar", grams: 60, barcode: "0722252100900"),
        item("dark-chocolate", "Dark chocolate 70%", 598, 7.8, 46, 43, serving: "2 squares", grams: 20),
        item("honey", "Honey", 304, 0.3, 82, 0, serving: "1 tbsp", grams: 21),
        item("coffee-latte", "Latte, semi-skimmed", 56, 3.8, 5.4, 2.1, serving: "1 grande", grams: 360),
        item("orange-juice", "Orange juice", 45, 0.7, 10.4, 0.2, serving: "1 glass", grams: 250)
    ]
}
