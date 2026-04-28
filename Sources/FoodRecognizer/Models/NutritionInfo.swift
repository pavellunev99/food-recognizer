import Foundation

/// Информация о пищевой ценности продукта
struct NutritionInfo: Codable, Identifiable {

    /// Размер «стандартной» порции в граммах, когда модель не вернула точное значение.
    static let defaultPortionGrams: Double = 250

    let id: UUID
    var foodName: String
    var calories: Double
    var protein: Double
    var carbs: Double
    var fats: Double
    var portionSize: String
    var portionGrams: Double
    let timestamp: Date

    init(
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
struct FoodAnalysisResult {
    let nutritionInfo: NutritionInfo
    let confidence: Double
    let suggestions: [String]
    /// Человекочитаемое имя модели, фактически вернувшей результат
    /// (`LLMServiceProtocol.modelName`). Опционально — для будущих
    /// провайдеров без понятия «модель» можно передавать nil.
    /// Используется в `MealConfirmationView` для бледного бейджа
    /// «Модель: …», чтобы юзер видел, что после апгрейда работает heavy.
    let modelName: String?

    init(
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
