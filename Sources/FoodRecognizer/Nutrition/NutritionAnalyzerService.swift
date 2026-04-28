#if canImport(UIKit)

import Foundation
import UIKit

/// Ошибки сервиса анализа питания
public enum NutritionAnalyzerError: LocalizedError {
    case llmServiceNotInitialized
    case invalidJSONResponse
    case imageProcessingFailed
    case parsingFailed(String)
    case noFoodInImage
    /// Модель вернула физически невозможные числа (например, 200 ккал при 0/0/0 БЖУ).
    /// Внутренняя ошибка — перехватывается в `analyzeFood` для ретрая.
    case suspiciousOutput(String)

    public var errorDescription: String? {
        switch self {
        case .llmServiceNotInitialized:
            return String(localized: "error_nutrition_llm_not_initialized")
        case .invalidJSONResponse:
            return String(localized: "error_nutrition_invalid_json")
        case .imageProcessingFailed:
            return String(localized: "error_nutrition_image_processing")
        case .parsingFailed(let message):
            return String(localized: "error_nutrition_parsing \(message)")
        case .noFoodInImage:
            return String(localized: "error_nutrition_no_food")
        case .suspiciousOutput(let message):
            return String(localized: "error_nutrition_suspicious \(message)")
        }
    }
}

/// Сервис для анализа питательной ценности еды
public final class NutritionAnalyzerService {

    private let llmService: LLMServiceProtocol
    private let ocrService: NutritionLabelOCRService

    public init(
        llmService: LLMServiceProtocol,
        ocrService: NutritionLabelOCRService = NutritionLabelOCRService()
    ) {
        self.llmService = llmService
        self.ocrService = ocrService
    }

    // MARK: - Public Methods

    /// Анализ изображения еды.
    ///
    /// Пайплайн:
    /// 1. OCR через Vision — если на фото этикетка с калориями, берём цифры оттуда
    ///    (2B-VLM плохо читает мелкий текст и часто выдаёт 0/0/0 для ясно видимых
    ///    лейблов). Для `foodName` всё равно зовём VLM коротким промптом.
    /// 2. VLM как основной путь, если OCR не нашёл этикетку.
    /// 3. Post-validation: если ккал > 50, но БЖУ все ≈ 0 — один ретрай.
    public func analyzeFood(from image: UIImage) async throws -> FoodAnalysisResult {
        guard llmService.isInitialized else {
            throw NutritionAnalyzerError.llmServiceNotInitialized
        }

        AppLog.info("Начинаем анализ изображения еды", category: .llm)

        // 1) Fast path: читаем этикетку если она есть.
        if let reading = await ocrService.extract(from: image) {
            AppLog.info(
                "OCR нашёл этикетку: \(Int(reading.calories)) ккал, P=\(reading.protein ?? -1) C=\(reading.carbs ?? -1) F=\(reading.fats ?? -1)",
                category: .llm
            )
            let info = try await buildNutritionInfo(fromOCR: reading, image: image)
            Self.markFirstRecognitionPerformed()
            markHeavyInferenceIfApplicable()
            return FoodAnalysisResult(
                nutritionInfo: info,
                confidence: 0.95,
                suggestions: generateSuggestions(for: info),
                modelName: llmService.modelName
            )
        }

        // 2) VLM с одним авто-ретраем на suspiciousOutput.
        let info = try await analyzeWithVLM(image: image, allowRetry: true)

        AppLog.info("Анализ завершён: \(info.foodName)", category: .llm)
        Self.markFirstRecognitionPerformed()
        markHeavyInferenceIfApplicable()
        return FoodAnalysisResult(
            nutritionInfo: info,
            confidence: 0.85,
            suggestions: generateSuggestions(for: info),
            modelName: llmService.modelName
        )
    }

    /// Триггерит `LocalLLMService.markFirstSuccessfulHeavyInference()` ровно
    /// один раз — после первой успешной prod-inference на heavy. Спецификация:
    /// «первая успешная inference на heavy через прод-флоу». Smoke в координаторе
    /// этот метод не зовёт, поэтому он не путается с пользовательским success.
    /// Также триггерит однократный cleanup HF-кеша bootstrap'а внутри сервиса.
    private func markHeavyInferenceIfApplicable() {
        guard let local = llmService as? LocalLLMService,
              local.currentModel.tier == .heavy else { return }
        local.markFirstSuccessfulHeavyInference()
    }

    /// UserDefaults-ключ флага первой успешной inference. Дублируется в
    /// host-app (см. `AppController.firstRecognitionFlagKey`) — обе стороны
    /// читают/пишут одно значение.
    public static let firstRecognitionFlagKey = "has_performed_first_recognition"

    /// Идемпотентный сетер UserDefaults-флага. Координатор апгрейда читает его
    /// перед стартом фонового скачивания heavy: пока хотя бы раз не сработала
    /// успешная inference на bootstrap, тратить трафик на heavy не имеет смысла.
    private static func markFirstRecognitionPerformed() {
        let defaults = UserDefaults.standard
        let key = firstRecognitionFlagKey
        if defaults.bool(forKey: key) { return }
        defaults.set(true, forKey: key)
    }

    private func analyzeWithVLM(image: UIImage, allowRetry: Bool) async throws -> NutritionInfo {
        let responseText = try await llmService.analyzeFood(
            image: image,
            prompt: nil,
            isRetry: !allowRetry
        )
        do {
            // `strict: true` даёт шанс на retry. На повторной попытке
            // (allowRetry=false) парсим лояльно — если модель опять отдала
            // нули, отдаём пользователю результат с foodName и пустыми БЖУ,
            // чтобы он мог отредактировать вручную, а не видел ошибку.
            return try parseNutritionInfo(from: responseText, strict: allowRetry)
        } catch NutritionAnalyzerError.suspiciousOutput(let reason) where allowRetry {
            AppLog.info("Suspicious VLM output (\(reason)), retrying once with elevated temperature", category: .llm)
            return try await analyzeWithVLM(image: image, allowRetry: false)
        }
    }

    /// Строит `NutritionInfo` по данным OCR + короткий VLM-запрос только для названия.
    /// Если VLM не смог дать название — fallback на «Продукт с этикетки».
    private func buildNutritionInfo(
        fromOCR reading: NutritionLabelReading,
        image: UIImage
    ) async throws -> NutritionInfo {
        let foodName = (try? await llmService.analyzeFood(
            image: image,
            prompt: Self.foodNameOnlyPrompt
        ))
        .flatMap { Self.extractFoodName(from: $0) } ?? String(localized: "nutrition_fallback_product")

        let calories = reading.calories
        let protein = reading.protein ?? 0
        let carbs = reading.carbs ?? 0
        let fats = reading.fats ?? 0

        // Если OCR дал полные БЖУ — reconcile пропорции; если какие-то nil, не трогаем.
        let (finalCalories, p, c, f): (Double, Double, Double, Double) = {
            guard reading.protein != nil, reading.carbs != nil, reading.fats != nil else {
                return (calories, protein, carbs, fats)
            }
            return Self.reconcileCaloriesAndMacros(calories: calories, protein: protein, carbs: carbs, fats: fats)
        }()

        return NutritionInfo(
            foodName: foodName,
            calories: finalCalories,
            protein: p,
            carbs: c,
            fats: f,
            portionSize: reading.portionGrams.map { "\(Int($0)) \(String(localized: "nutrition_unit_g_ml"))" } ?? String(localized: "nutrition_one_serving"),
            portionGrams: reading.portionGrams ?? NutritionInfo.defaultPortionGrams
        )
    }

    private static let foodNameOnlyPrompt = """
    Look at this photo. Respond with ONLY a short Russian name of the product or dish \
    (2-5 words), no JSON, no explanation. Examples: "Зелёный чай", "Сок апельсиновый", \
    "Жареная картошка".
    """

    /// Выдёргивает короткое название из ответа модели. Срезает JSON/markdown, если
    /// VLM случайно его вернула (2B часто игнорирует инструкции).
    private static func extractFoodName(from text: String) -> String? {
        // Если модель всё же вернула JSON — попробуем взять foodName оттуда.
        if let jsonStart = text.firstIndex(of: "{"),
           let jsonEnd = text.lastIndex(of: "}"),
           jsonStart < jsonEnd {
            let jsonPart = String(text[jsonStart...jsonEnd])
            if let data = jsonPart.data(using: .utf8),
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let name = obj["foodName"] as? String, !name.isEmpty {
                return name.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }

        // Иначе — первая непустая строка, обрезанная до 80 символов.
        let firstLine = text
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty } ?? ""
        let cleaned = firstLine
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'`"))
            .prefix(80)
        return cleaned.isEmpty ? nil : String(cleaned)
    }
    
    /// Анализ текстового описания еды
    public func analyzeFood(from text: String) async throws -> FoodAnalysisResult {
        guard llmService.isInitialized else {
            throw NutritionAnalyzerError.llmServiceNotInitialized
        }

        AppLog.info("Анализ текстового описания еды", category: .llm)

        let responseText = try await llmService.extractNutritionInfo(from: text)
        let nutritionInfo = try parseNutritionInfo(from: responseText)
        let suggestions = generateSuggestions(for: nutritionInfo)

        AppLog.info("Анализ текста завершён: \(nutritionInfo.foodName)", category: .llm)
        
        return FoodAnalysisResult(
            nutritionInfo: nutritionInfo,
            confidence: 0.75,
            suggestions: suggestions,
            modelName: llmService.modelName
        )
    }
    
    /// Получение рекомендаций по питанию
    public func getNutritionRecommendations(
        currentCalories: Double,
        targetCalories: Double
    ) -> [String] {
        let remaining = targetCalories - currentCalories
        
        var recommendations: [String] = []
        
        if remaining > 0 {
            recommendations.append(String(localized: "nutrition_rec_calories_left \(Int(remaining))"))

            if remaining < 200 {
                recommendations.append(String(localized: "nutrition_rec_light_snack"))
            } else if remaining < 500 {
                recommendations.append(String(localized: "nutrition_rec_small_meal"))
            } else {
                recommendations.append(String(localized: "nutrition_rec_full_meal"))
            }
        } else {
            let excess = abs(remaining)
            recommendations.append(String(localized: "nutrition_rec_exceeded \(Int(excess))"))
            recommendations.append(String(localized: "nutrition_rec_more_activity"))
        }
        
        return recommendations
    }
    
    // MARK: - Private Methods
    
    private func parseNutritionInfo(from jsonString: String, strict: Bool = true) throws -> NutritionInfo {
        // Извлекаем JSON из ответа (может быть обернут в текст)
        let cleanedJSON = extractJSON(from: jsonString)

        guard let jsonData = cleanedJSON.data(using: .utf8) else {
            throw NutritionAnalyzerError.invalidJSONResponse
        }

        let decoder = JSONDecoder()

        // Сначала проверяем флаг noFood — модель явно сообщает об отсутствии блюда.
        if let marker = try? decoder.decode(NoFoodMarker.self, from: jsonData), marker.noFood == true {
            AppLog.error("Модель вернула noFood=true. Raw: \(jsonString.prefix(400))", category: .llm)
            throw NutritionAnalyzerError.noFoodInImage
        }

        do {
            let response = try decoder.decode(NutritionResponse.self, from: jsonData)

            // VLM часто пишет "Нет еды"/"unknown" прямо в foodName вместо
            // структурного `{"noFood": true}`. Раньше требовали placeholder в
            // ОБА текстовых поля — но реальные провалы выглядят как
            // foodName="Нет идентификации" + portionSize="порция из …" или
            // foodName="недостаточно информации" + такой же portionSize.
            // Поэтому: placeholder в foodName И отсутствие численных данных
            // (нули по ккал/БЖУ) — гарантированный noFood.
            let macroSum = response.protein + response.carbs + response.fats
            let hasNoNumbers = response.calories < 1 && macroSum < 0.5
            if Self.looksLikePlaceholder(response.foodName),
               Self.looksLikePlaceholder(response.portionSize) || hasNoNumbers {
                AppLog.error(
                    "VLM вернул placeholder foodName='\(response.foodName)'. Raw: \(jsonString.prefix(400))",
                    category: .llm
                )
                throw NutritionAnalyzerError.noFoodInImage
            }

            // Физически невозможные / явно "сдались" комбинации.
            // 1) calories > 50 с нулевыми БЖУ — physically impossible.
            // 2) ВСЁ по нулям — VLM распознал foodName но не дал количеств.
            //    Вода/воздух — редкий легит-кейс, пользователь скорее всего
            //    снимал лейбл продукта. Лучше ретрай.
            if strict {
                if response.calories > 50, macroSum < 0.5 {
                    throw NutritionAnalyzerError.suspiciousOutput(
                        "calories=\(response.calories) но P+C+F=\(macroSum)"
                    )
                }
                if response.calories < 1, macroSum < 0.5, !response.foodName.isEmpty {
                    throw NutritionAnalyzerError.suspiciousOutput(
                        "VLM назвал '\(response.foodName)' но выдал 0 ккал/0 БЖУ"
                    )
                }
            }

            let (finalCalories, p, c, f) = Self.reconcileCaloriesAndMacros(
                calories: response.calories,
                protein: response.protein,
                carbs: response.carbs,
                fats: response.fats
            )
            // Tolerant decoder возвращает 0 вместо nil для non-numeric строк —
            // поэтому `?? extractGrams` не срабатывает при portionGrams=0.
            // Трактуем 0 как «не дал» и падаем на extractGrams из текста
            // portionSize, иначе — дефолт. Иначе UI стартует с portionGrams=0 и
            // первый тап +/- ломает всю пропорцию макросов.
            let decodedGrams = response.portionGrams ?? 0
            let portionGrams: Double = decodedGrams > 0
                ? decodedGrams
                : (Self.extractGrams(fromPortionText: response.portionSize)
                    ?? NutritionInfo.defaultPortionGrams)
            return NutritionInfo(
                foodName: response.foodName,
                calories: finalCalories,
                protein: p,
                carbs: c,
                fats: f,
                portionSize: response.portionSize,
                portionGrams: portionGrams
            )
        } catch let error as NutritionAnalyzerError {
            // suspiciousOutput не обрабатываем здесь — пусть поднимется в analyzeFood для ретрая.
            throw error
        } catch {
            // Невалидный JSON часто означает «модель запуталась / нет блюда».
            // Логируем исходный ответ, чтобы отличать реальный noFood от парсер-фейла.
            AppLog.error("Не удалось распарсить ответ модели: \(error.localizedDescription). Raw: \(jsonString.prefix(400))", category: .llm)
            throw NutritionAnalyzerError.noFoodInImage
        }
    }
    
    /// Приводит калории и БЖУ к согласованной паре. Было две поломки:
    /// - Иногда модель даёт ~правильные калории, но БЖУ не сходятся по 4/4/9
    ///   (521 ккал при 8P/48C/13F = 341) — тут подгоняем БЖУ под калории.
    /// - Qwen2-VL 2B часто анкорится на 200 ккал и выдаёт мелкие макросы
    ///   (P=0 C=20 F=0 = 80 ккал, claimed 200) — тут надо ДОВЕРЯТЬ макросам
    ///   и уменьшить калории, иначе reconcile раздует макросы в реверс.
    ///
    /// Эвристика выбора направления:
    /// - Если claimed_calories > 2·computed И суммарная масса БЖУ < 50г —
    ///   модель анкорится на калориях для мелкой порции, трастим макросы.
    /// - Иначе — стандартное поведение: калории — якорь, пересчитываем БЖУ.
    private static func reconcileCaloriesAndMacros(
        calories: Double,
        protein: Double,
        carbs: Double,
        fats: Double
    ) -> (calories: Double, protein: Double, carbs: Double, fats: Double) {
        let computed = protein * 4 + carbs * 4 + fats * 9
        guard calories > 0, computed > 0 else { return (calories, protein, carbs, fats) }

        let massG = protein + carbs + fats

        // Case 1: модель переоценила калории для маленькой порции.
        // Доверяем макросам, понижаем калории до вычисленных.
        if calories > computed * 2, massG < 50 {
            let correctedCalories = computed.rounded()
            AppLog.info(
                "Overclaimed calories: P=\(protein) C=\(carbs) F=\(fats) = \(computed) kcal vs claimed \(calories). Trusting macros → calories=\(correctedCalories)",
                category: .llm
            )
            return (correctedCalories, protein, carbs, fats)
        }

        let deviation = abs(computed - calories) / calories
        guard deviation > 0.10 else { return (calories, protein, carbs, fats) }

        // Остаток калорий после белка распределяем пропорционально между
        // углеводами и жирами в их текущем калорийном соотношении.
        let proteinCals = protein * 4
        let remainingCals = max(calories - proteinCals, 0)
        let currentCarbCals = carbs * 4
        let currentFatCals = fats * 9
        let currentSum = currentCarbCals + currentFatCals

        guard currentSum > 0 else {
            // Нет BJU для перекладки — fallback: 50/50 между углеводами и жирами.
            return (calories, protein, (remainingCals * 0.5) / 4, (remainingCals * 0.5) / 9)
        }

        let carbShare = currentCarbCals / currentSum
        let newCarbs = (remainingCals * carbShare) / 4
        let newFats = (remainingCals * (1 - carbShare)) / 9

        AppLog.info(
            "Skewed macros: P=\(protein) C=\(carbs) F=\(fats) → \(computed) kcal, claimed \(calories). Corrected: C=\(String(format: "%.1f", newCarbs)) F=\(String(format: "%.1f", newFats))",
            category: .llm
        )

        return (calories, protein, newCarbs, newFats)
    }

    /// Признак «модель отказалась распознавать», написанный в виде обычной
    /// строки в поле `foodName`/`portionSize` вместо структурного маркера
    /// `{"noFood": true}`. Покрывает русские/английские варианты.
    private static func looksLikePlaceholder(_ text: String) -> Bool {
        let lowered = text
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: ".!?"))
        guard !lowered.isEmpty else { return true }
        let placeholders: Set<String> = [
            "нет", "нет еды", "нет блюда", "нет данных", "нет информации",
            "ничего", "ничего не найдено", "ничего не видно",
            "недостаточно данных", "недостаточно информации",
            "не определено", "не распознано", "не идентифицировано",
            "не идентификация", "не идентифицирована",
            "no food", "unknown", "n/a", "na", "none",
            "not identified", "not recognized",
            "insufficient", "insufficient data", "insufficient information",
            "no data"
        ]
        return placeholders.contains(lowered)
    }

    /// Вытаскивает число граммов/мл из строки порции: "100 ml", "250 г",
    /// "1 порция (180g)", "1 банка". Возвращает nil если не нашёл.
    /// Масса в мл ≈ гр для жидкостей (для наших нужд эквивалент).
    private static func extractGrams(fromPortionText text: String) -> Double? {
        let patterns = [
            #"(\d{2,4}(?:\.\d+)?)\s*(?:г|гр|грамм)"#,
            #"(\d{2,4}(?:\.\d+)?)\s*(?:ml|мл)"#,
            #"(\d{2,4}(?:\.\d+)?)\s*g\b"#
        ]
        let lowered = text.lowercased()
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { continue }
            let range = NSRange(lowered.startIndex..., in: lowered)
            if let match = regex.firstMatch(in: lowered, range: range),
               match.numberOfRanges >= 2,
               let captureRange = Range(match.range(at: 1), in: lowered),
               let value = Double(lowered[captureRange]),
               (10...3000).contains(value) {
                return value
            }
        }
        return nil
    }

    private func extractJSON(from text: String) -> String {
        // Срезаем markdown code fences (```json … ``` / ``` … ```), которые
        // часто добавляют LLM поверх JSON.
        var cleaned = text
        if let fenceStart = cleaned.range(of: "```") {
            var afterFence = cleaned[fenceStart.upperBound...]
            if afterFence.hasPrefix("json") {
                afterFence = afterFence.dropFirst("json".count)
            }
            if let fenceEnd = afterFence.range(of: "```") {
                cleaned = String(afterFence[..<fenceEnd.lowerBound])
            } else {
                cleaned = String(afterFence)
            }
        }

        if let start = cleaned.firstIndex(of: "{"),
           let end = cleaned.lastIndex(of: "}") {
            cleaned = String(cleaned[start...end])
        }

        return Self.sanitizeJSON(cleaned)
    }

    /// Чинит невалидный JSON из VLM. Qwen2-VL иногда вставляет единицы сразу
    /// после числа БЕЗ кавычек: `"protein": 1 грамм,` — это сломанный JSON,
    /// JSONSerialization его не переварит даже с толерантным декодером.
    /// Приводим такие поля к `"protein": 1,`.
    private static func sanitizeJSON(_ json: String) -> String {
        var result = json

        // 1) `: <number> <unit>` → `: <number>` перед `,` или `}`.
        //    Захватывает г/гр/грамм/g/ml/мл/ккал/kcal/%/kg/кг и прочие суффиксы.
        //    Не ест кавычки: если значение уже "100 ккал" в строке — не трогаем.
        let numberWithUnit = #":\s*(-?\d+(?:\.\d+)?)\s+[^,}"\s]+(?:\s+[^,}"\s]+)?\s*([,}])"#
        if let regex = try? NSRegularExpression(pattern: numberWithUnit) {
            let range = NSRange(result.startIndex..., in: result)
            result = regex.stringByReplacingMatches(
                in: result, range: range, withTemplate: ": $1$2"
            )
        }

        // 2) `: <unquoted word>` (одиночный bareword без кавычек) → `"<word>"`.
        //    Только если слово состоит из букв и это явно не true/false/null.
        let barewordString = #":\s*([A-Za-zА-Яа-яЁё][A-Za-zА-Яа-яЁё\s\-]{0,40}?)([,}])"#
        if let regex = try? NSRegularExpression(pattern: barewordString) {
            let range = NSRange(result.startIndex..., in: result)
            let matches = regex.matches(in: result, range: range).reversed()
            for match in matches {
                guard match.numberOfRanges >= 3,
                      let wordRange = Range(match.range(at: 1), in: result) else { continue }
                let word = result[wordRange].trimmingCharacters(in: .whitespaces)
                if ["true", "false", "null"].contains(word.lowercased()) { continue }
                if let full = Range(match.range, in: result),
                   let tail = Range(match.range(at: 2), in: result) {
                    result.replaceSubrange(full, with: #": "\#(word)"\#(result[tail])"#)
                }
            }
        }

        return result
    }
    
    private func generateSuggestions(for nutrition: NutritionInfo) -> [String] {
        var suggestions: [String] = []
        
        // Анализ белков
        if nutrition.protein < 20 {
            suggestions.append(String(localized: "nutrition_sug_more_protein"))
        }

        // Анализ калорий
        if nutrition.calories > 800 {
            suggestions.append(String(localized: "nutrition_sug_high_calorie"))
        } else if nutrition.calories < 200 {
            suggestions.append(String(localized: "nutrition_sug_light_snack"))
        }

        // Анализ жиров
        if nutrition.fats > 30 {
            suggestions.append(String(localized: "nutrition_sug_high_fats"))
        }

        // Анализ углеводов
        if nutrition.carbs > 60 {
            suggestions.append(String(localized: "nutrition_sug_high_carbs"))
        }
        
        return suggestions
    }
}

// MARK: - Helper Models

/// Толерантный декодер ответа VLM. Qwen2-VL после ужесточения промпта иногда
/// заворачивает числа в строки (`"calories": "100"`), некоторые модели могут
/// отдавать mixed форматы. Вручную парсим числовые поля, принимая и Number, и
/// String-представление. `portionSize` может прилететь числом — приводим к
/// строке.
private struct NutritionResponse: Decodable {
    let foodName: String
    let calories: Double
    let protein: Double
    let carbs: Double
    let fats: Double
    let portionSize: String
    let portionGrams: Double?

    private enum CodingKeys: String, CodingKey {
        case foodName, calories, protein, carbs, fats, portionSize, portionGrams
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.foodName = try c.decode(String.self, forKey: .foodName)
        self.calories = try Self.decodeNumber(c, key: .calories)
        self.protein = try Self.decodeNumber(c, key: .protein)
        self.carbs = try Self.decodeNumber(c, key: .carbs)
        self.fats = try Self.decodeNumber(c, key: .fats)
        self.portionSize = Self.decodeFlexibleString(c, key: .portionSize) ?? String(localized: "nutrition_one_serving")
        self.portionGrams = try? Self.decodeNumber(c, key: .portionGrams)
    }

    /// Принимает Double, Int, Bool, либо String с числом ("100", "12.5", "0г").
    /// Если VLM отдал non-numeric текст ("недостаточно данных", "unknown") —
    /// возвращаем 0, чтобы декодирование прошло. Нулевые значения потом ловит
    /// `suspiciousOutput` check и, при возможности, делаем ретрай. Без этого
    /// fallback'а весь парсинг падает и user видит generic «не распарсить».
    private static func decodeNumber(_ c: KeyedDecodingContainer<CodingKeys>, key: CodingKeys) throws -> Double {
        if let v = try? c.decode(Double.self, forKey: key) { return v }
        if let v = try? c.decode(Int.self, forKey: key) { return Double(v) }
        if let s = try? c.decode(String.self, forKey: key) {
            let trimmed = s
                .replacingOccurrences(of: ",", with: ".")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let numberPart = trimmed.prefix { $0.isNumber || $0 == "." || $0 == "-" }
            if let v = Double(numberPart) { return v }
            // Non-numeric текст: логируем и возвращаем 0
            AppLog.info("VLM отдал non-numeric для \(key.stringValue): '\(s)', defaulting to 0", category: .llm)
            return 0
        }
        // null / missing тоже дефолтится в 0
        return 0
    }

    private static func decodeFlexibleString(_ c: KeyedDecodingContainer<CodingKeys>, key: CodingKeys) -> String? {
        if let s = try? c.decode(String.self, forKey: key) { return s }
        if let v = try? c.decode(Double.self, forKey: key) { return String(v) }
        if let v = try? c.decode(Int.self, forKey: key) { return String(v) }
        return nil
    }
}

private struct NoFoodMarker: Codable {
    let noFood: Bool?
}

#endif
