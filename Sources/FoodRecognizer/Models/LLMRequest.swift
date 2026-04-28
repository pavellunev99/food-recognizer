#if canImport(UIKit)

import Foundation
import UIKit

/// Тип запроса к LLM
enum LLMRequestType {
    case textAnalysis(String)
    case imageAnalysis(UIImage, prompt: String?)
    case nutritionExtraction(String)
}

/// Запрос к LLM сервису
struct LLMRequest {
    let type: LLMRequestType
    let systemPrompt: String?
    let temperature: Double
    let maxTokens: Int
    /// `true` — повторная попытка после физически невозможного ответа. LocalLLMService
    /// использует `retryTemperature` и retry-вариант системного промпта, чтобы
    /// вырваться из anchor mode collapse.
    let isRetry: Bool
    /// Полная подмена системного промпта для path `imageAnalysis`. nil (default)
    /// — поведение app не меняется, используется `LocalVLMModel.nutritionSystemPrompt`.
    /// Заполняется только из eval-tool (`tools/eval/`), чтобы итерировать промт
    /// без пересборки app. App никогда не выставляет это поле.
    let systemPromptOverride: String?

    init(
        type: LLMRequestType,
        systemPrompt: String? = nil,
        temperature: Double = 0.7,
        maxTokens: Int = 2000,
        isRetry: Bool = false,
        systemPromptOverride: String? = nil
    ) {
        self.type = type
        self.systemPrompt = systemPrompt
        self.temperature = temperature
        self.maxTokens = maxTokens
        self.isRetry = isRetry
        self.systemPromptOverride = systemPromptOverride
    }
}

/// Ответ от LLM сервиса
struct LLMResponse {
    let content: String
    let finishReason: String?
    let model: String
    let tokensUsed: Int?
}

#endif
