import Foundation

/// Информация о пищевой ценности продукта
public struct NutritionInfo: Codable, Identifiable {

    /// Размер «стандартной» порции в граммах, когда модель не вернула точное значение.
    public static let defaultPortionGrams: Double = 250

    public let id: UUID
    public var foodName: String
    public var calories: Double
    public var protein: Double
    public var carbs: Double
    public var fats: Double
    public var portionSize: String
    public var portionGrams: Double
    public let timestamp: Date

    public init(
        id: UUID = UUID(),
        foodName: String,
        calories: Double,
        protein: Double,
        carbs: Double,
        fats: Double,
        portionSize: String,
        portionGrams: Double = NutritionInfo.defaultPortionGrams,
        timestamp: Date = Date()
    ) {
        self.id = id
        self.foodName = foodName
        self.calories = calories
        self.protein = protein
        self.carbs = carbs
        self.fats = fats
        self.portionSize = portionSize
        self.portionGrams = portionGrams
        self.timestamp = timestamp
    }
}

/// Результат анализа еды
public struct FoodAnalysisResult {
    public let nutritionInfo: NutritionInfo
    public let confidence: Double
    public let suggestions: [String]
    /// Человекочитаемое имя модели, фактически вернувшей результат
    /// (`LLMServiceProtocol.modelName`). Опционально — для будущих
    /// провайдеров без понятия «модель» можно передавать nil.
    /// Используется в `MealConfirmationView` для бледного бейджа
    /// «Модель: …», чтобы юзер видел, что после апгрейда работает heavy.
    public let modelName: String?

    public init(
        nutritionInfo: NutritionInfo,
        confidence: Double,
        suggestions: [String],
        modelName: String? = nil
    ) {
        self.nutritionInfo = nutritionInfo
        self.confidence = confidence
        self.suggestions = suggestions
        self.modelName = modelName
    }
}
