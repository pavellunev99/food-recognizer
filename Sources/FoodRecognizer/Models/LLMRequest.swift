#if canImport(UIKit)

import Foundation
import UIKit

/// Тип запроса к LLM
public enum LLMRequestType {
    case textAnalysis(String)
    case imageAnalysis(UIImage, prompt: String?)
    case nutritionExtraction(String)
}

/// Запрос к LLM сервису
public struct LLMRequest {
    public let type: LLMRequestType
    public let systemPrompt: String?
    public let temperature: Double
    public let maxTokens: Int
    /// `true` — повторная попытка после физически невозможного ответа. LocalLLMService
    /// использует `retryTemperature` и retry-вариант системного промпта, чтобы
    /// вырваться из anchor mode collapse.
    public let isRetry: Bool
    /// Полная подмена системного промпта для path `imageAnalysis`. nil (default)
    /// — поведение app не меняется, используется `LocalVLMModel.nutritionSystemPrompt`.
    /// Заполняется только из eval-tool (`tools/eval/`), чтобы итерировать промт
    /// без пересборки app. App никогда не выставляет это поле.
    public let systemPromptOverride: String?

    public init(
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
public struct LLMResponse {
    public let content: String
    public let finishReason: String?
    public let model: String
    public let tokensUsed: Int?

    public init(
        content: String,
        finishReason: String?,
        model: String,
        tokensUsed: Int?
    ) {
        self.content = content
        self.finishReason = finishReason
        self.model = model
        self.tokensUsed = tokensUsed
    }
}

#endif
