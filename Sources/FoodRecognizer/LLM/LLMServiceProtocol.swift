#if canImport(UIKit)

import Foundation
import UIKit

/// Ошибки LLM сервиса
public enum LLMServiceError: LocalizedError {
    case modelNotLoaded
    case invalidInput
    case processingFailed(String)
    case networkError(Error)
    case apiKeyMissing
    case rateLimitExceeded

    public var errorDescription: String? {
        switch self {
        case .modelNotLoaded:
            return String(localized: "error_llm_model_not_loaded")
        case .invalidInput:
            return String(localized: "error_llm_invalid_input")
        case .processingFailed(let message):
            return String(localized: "error_llm_processing \(message)")
        case .networkError(let error):
            return String(localized: "error_llm_network \(error.localizedDescription)")
        case .apiKeyMissing:
            return String(localized: "error_llm_api_key_missing")
        case .rateLimitExceeded:
            return String(localized: "error_llm_rate_limit")
        }
    }
}

/// Протокол для LLM сервиса (локальный или API)
public protocol LLMServiceProtocol: AnyObject {

    /// Инициализирован ли сервис
    var isInitialized: Bool { get }

    /// Название используемой модели
    var modelName: String { get }

    /// Инициализация сервиса
    func initialize() async throws

    /// Отправка запроса к модели
    func sendRequest(_ request: LLMRequest) async throws -> LLMResponse

    /// Анализ изображения еды
    func analyzeFood(image: UIImage, prompt: String?) async throws -> String

    /// Извлечение информации о пищевой ценности из текста
    func extractNutritionInfo(from text: String) async throws -> String

    /// Освобождение ресурсов. Async — у локальной VLM нужно дренировать
    /// in-flight inference и дёрнуть `MLX.Memory.clearCache()` после, иначе
    /// очистка кеша попадёт под только что загруженный новый контейнер при
    /// rebuild сервиса.
    func cleanup() async
}

// Default implementations
extension LLMServiceProtocol {
    public func analyzeFood(image: UIImage, prompt: String? = nil) async throws -> String {
        try await analyzeFood(image: image, prompt: prompt, isRetry: false)
    }

    /// Перегрузка с `isRetry` — `LocalLLMService` подмешает более высокую
    /// температуру и «retry»-вариант системного промпта.
    public func analyzeFood(image: UIImage, prompt: String?, isRetry: Bool) async throws -> String {
        let defaultPrompt = """
        Проанализируй изображение еды и предоставь следующую информацию в формате JSON:
        {
            "foodName": "название блюда",
            "calories": количество калорий,
            "protein": граммы белка,
            "carbs": граммы углеводов,
            "fats": граммы жиров,
            "portionSize": "описание порции"
        }
        Если на изображении несколько блюд, укажи общую информацию.
        """

        let request = LLMRequest(
            type: .imageAnalysis(image, prompt: prompt ?? defaultPrompt),
            temperature: 0.3,
            isRetry: isRetry
        )

        let response = try await sendRequest(request)
        return response.content
    }

    public func extractNutritionInfo(from text: String) async throws -> String {
        let systemPrompt = """
        Извлеки информацию о пищевой ценности из текста и верни в формате JSON:
        {
            "foodName": "название блюда",
            "calories": количество калорий,
            "protein": граммы белка,
            "carbs": граммы углеводов,
            "fats": граммы жиров,
            "portionSize": "описание порции"
        }
        """
        
        let request = LLMRequest(
            type: .nutritionExtraction(text),
            systemPrompt: systemPrompt,
            temperature: 0.2
        )
        
        let response = try await sendRequest(request)
        return response.content
    }
}

#endif
