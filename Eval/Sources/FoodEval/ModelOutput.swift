import Foundation

// MARK: - Model Output
//
// Свободно-форматный output VLM. Все поля опциональные — модель может выдать
// неполный JSON, и мы хотим различать "поле было, но =0" и "поля нет".
// Структура соответствует production-формату NutritionInfo, но без app-зависимостей.

public struct ModelOutput: Codable, Sendable, Equatable {
    public let foodName: String?
    public let calories: Double?
    public let protein: Double?
    public let carbs: Double?
    public let fats: Double?
    public let portionGrams: Double?

    public init(
        foodName: String? = nil,
        calories: Double? = nil,
        protein: Double? = nil,
        carbs: Double? = nil,
        fats: Double? = nil,
        portionGrams: Double? = nil
    ) {
        self.foodName = foodName
        self.calories = calories
        self.protein = protein
        self.carbs = carbs
        self.fats = fats
        self.portionGrams = portionGrams
    }
}

extension ModelOutput {
    /// Лояльный парсер. Принимает grязное содержимое от модели:
    ///   - чистый JSON: `{"foodName": "apple", ...}`
    ///   - markdown-обёртку: ```` ```json {...} ``` ````
    ///   - prose preamble: `Here is the analysis: {...}`
    /// Возвращает nil только если совсем не удалось извлечь JSON-объект.
    public static func parse(rawJSON: String) -> ModelOutput? {
        let trimmed = rawJSON.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        // Найти первый '{' и последний '}' — захватывает наибольший объект.
        guard
            let start = trimmed.firstIndex(of: "{"),
            let end = trimmed.lastIndex(of: "}"),
            start < end
        else {
            return nil
        }
        let candidate = String(trimmed[start...end])

        guard let data = candidate.data(using: .utf8) else { return nil }
        let decoder = JSONDecoder()
        if let parsed = try? decoder.decode(ModelOutput.self, from: data) {
            return parsed
        }

        // Фолбэк: модель могла прислать числа строками ("calories": "95").
        // Пробуем через AnyJSON и руками собираем.
        guard
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return nil
        }

        return ModelOutput(
            foodName: stringValue(object["foodName"]),
            calories: doubleValue(object["calories"]),
            protein: doubleValue(object["protein"]),
            carbs: doubleValue(object["carbs"]),
            fats: doubleValue(object["fats"]),
            portionGrams: doubleValue(object["portionGrams"])
        )
    }

    private static func stringValue(_ any: Any?) -> String? {
        guard let any else { return nil }
        if let s = any as? String { return s.isEmpty ? nil : s }
        return nil
    }

    private static func doubleValue(_ any: Any?) -> Double? {
        guard let any else { return nil }
        if let d = any as? Double { return d }
        if let i = any as? Int { return Double(i) }
        if let n = any as? NSNumber { return n.doubleValue }
        if let s = any as? String {
            let cleaned = s.trimmingCharacters(in: .whitespaces)
            return Double(cleaned)
        }
        return nil
    }
}
