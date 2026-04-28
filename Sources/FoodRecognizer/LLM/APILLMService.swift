#if canImport(UIKit)

import Foundation
import UIKit

/// Вкус API, с которым работает сервис.
///
/// OpenAI (и совместимые — LM Studio, Ollama, Groq) используют `/chat/completions`
/// c массивом сообщений. Anthropic использует `/messages` с другим форматом
/// image blocks и хедером `x-api-key`.
public enum APIProviderFlavor {
    case openAICompatible
    case anthropic
}

/// Сервис для работы с LLM через HTTP API.
public final class APILLMService: LLMServiceProtocol {

    private let apiKey: String
    private let baseURL: String
    private let apiModel: String
    private let flavor: APIProviderFlavor
    private let session: URLSession
    private var initialized: Bool = false

    public var isInitialized: Bool { initialized }
    public var modelName: String { apiModel }

    // MARK: - Initialization

    public init(
        apiKey: String,
        baseURL: String = "https://api.openai.com/v1",
        model: String = "gpt-4o-mini",
        flavor: APIProviderFlavor = .openAICompatible,
        session: URLSession = .shared
    ) {
        self.apiKey = apiKey
        self.baseURL = baseURL
        self.apiModel = model
        self.flavor = flavor
        self.session = session
    }

    public func initialize() async throws {
        guard !apiKey.isEmpty else {
            throw LLMServiceError.apiKeyMissing
        }
        let model = apiModel
        let flavorLabel = flavor == .anthropic ? "anthropic" : "openai"
        AppLog.info("API LLM init model=\(model) flavor=\(flavorLabel)", category: .llm)
        initialized = true
    }

    // MARK: - Request Handling

    public func sendRequest(_ request: LLMRequest) async throws -> LLMResponse {
        guard isInitialized else {
            throw LLMServiceError.modelNotLoaded
        }

        switch request.type {
        case .textAnalysis(let text):
            return try await chat(
                systemPrompt: request.systemPrompt,
                userText: text,
                image: nil,
                temperature: request.temperature,
                maxTokens: request.maxTokens
            )

        case .imageAnalysis(let image, let prompt):
            return try await chat(
                systemPrompt: request.systemPrompt,
                userText: prompt ?? "Describe the meal in this photo.",
                image: image,
                temperature: request.temperature,
                maxTokens: request.maxTokens
            )

        case .nutritionExtraction(let text):
            return try await chat(
                systemPrompt: request.systemPrompt,
                userText: text,
                image: nil,
                temperature: request.temperature,
                maxTokens: request.maxTokens
            )
        }
    }

    // MARK: - HTTP

    private func chat(
        systemPrompt: String?,
        userText: String,
        image: UIImage?,
        temperature: Double,
        maxTokens: Int
    ) async throws -> LLMResponse {
        switch flavor {
        case .openAICompatible:
            return try await sendOpenAI(
                systemPrompt: systemPrompt,
                userText: userText,
                image: image,
                temperature: temperature,
                maxTokens: maxTokens
            )
        case .anthropic:
            return try await sendAnthropic(
                systemPrompt: systemPrompt,
                userText: userText,
                image: image,
                temperature: temperature,
                maxTokens: maxTokens
            )
        }
    }

    // MARK: - OpenAI

    private func sendOpenAI(
        systemPrompt: String?,
        userText: String,
        image: UIImage?,
        temperature: Double,
        maxTokens: Int
    ) async throws -> LLMResponse {
        guard let url = URL(string: baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/chat/completions") else {
            throw LLMServiceError.processingFailed(String(localized: "error_invalid_base_url"))
        }

        var userContent: [[String: Any]] = [["type": "text", "text": userText]]
        if let imageDataURL = image.flatMap({ Self.jpegDataURL(for: $0) }) {
            userContent.append([
                "type": "image_url",
                "image_url": ["url": imageDataURL],
            ])
        }

        var messages: [[String: Any]] = []
        if let systemPrompt, !systemPrompt.isEmpty {
            messages.append(["role": "system", "content": systemPrompt])
        }
        messages.append(["role": "user", "content": userContent])

        let body: [String: Any] = [
            "model": apiModel,
            "messages": messages,
            "temperature": temperature,
            "max_tokens": maxTokens,
        ]

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.timeoutInterval = 60

        let (data, response) = try await session.data(for: request)
        try Self.validate(response: response, data: data)

        guard
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let choices = json["choices"] as? [[String: Any]],
            let firstChoice = choices.first,
            let message = firstChoice["message"] as? [String: Any],
            let content = message["content"] as? String
        else {
            throw LLMServiceError.processingFailed(String(localized: "error_failed_parse_openai"))
        }

        let finishReason = firstChoice["finish_reason"] as? String ?? "stop"
        let usage = json["usage"] as? [String: Any]
        let tokens = usage?["total_tokens"] as? Int

        return LLMResponse(content: content, finishReason: finishReason, model: apiModel, tokensUsed: tokens)
    }

    // MARK: - Anthropic

    private func sendAnthropic(
        systemPrompt: String?,
        userText: String,
        image: UIImage?,
        temperature: Double,
        maxTokens: Int
    ) async throws -> LLMResponse {
        guard let url = URL(string: baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/messages") else {
            throw LLMServiceError.processingFailed(String(localized: "error_invalid_base_url"))
        }

        var content: [[String: Any]] = []
        if let image, let jpeg = image.jpegData(compressionQuality: 0.8) {
            content.append([
                "type": "image",
                "source": [
                    "type": "base64",
                    "media_type": "image/jpeg",
                    "data": jpeg.base64EncodedString(),
                ],
            ])
        }
        content.append(["type": "text", "text": userText])

        var body: [String: Any] = [
            "model": apiModel,
            "max_tokens": maxTokens,
            "temperature": temperature,
            "messages": [["role": "user", "content": content]],
        ]
        if let systemPrompt, !systemPrompt.isEmpty {
            body["system"] = systemPrompt
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.timeoutInterval = 60

        let (data, response) = try await session.data(for: request)
        try Self.validate(response: response, data: data)

        guard
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let contentArray = json["content"] as? [[String: Any]]
        else {
            throw LLMServiceError.processingFailed(String(localized: "error_failed_parse_anthropic"))
        }

        let text = contentArray
            .compactMap { ($0["type"] as? String) == "text" ? $0["text"] as? String : nil }
            .joined()

        let stopReason = json["stop_reason"] as? String ?? "stop"
        let usage = json["usage"] as? [String: Any]
        let inputTokens = usage?["input_tokens"] as? Int ?? 0
        let outputTokens = usage?["output_tokens"] as? Int ?? 0
        let total = inputTokens + outputTokens

        return LLMResponse(content: text, finishReason: stopReason, model: apiModel, tokensUsed: total > 0 ? total : nil)
    }

    // MARK: - Helpers

    private static func validate(response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else {
            throw LLMServiceError.processingFailed(String(localized: "error_no_http_response"))
        }
        switch http.statusCode {
        case 200..<300:
            return
        case 401:
            throw LLMServiceError.apiKeyMissing
        case 429:
            throw LLMServiceError.rateLimitExceeded
        default:
            let snippet = String(data: data, encoding: .utf8)?.prefix(256) ?? ""
            throw LLMServiceError.processingFailed(String(localized: "error_http_status \(http.statusCode) \(String(snippet))"))
        }
    }

    private static func jpegDataURL(for image: UIImage) -> String? {
        guard let jpeg = image.jpegData(compressionQuality: 0.8) else { return nil }
        return "data:image/jpeg;base64,\(jpeg.base64EncodedString())"
    }

    // MARK: - Cleanup

    public func cleanup() async {
        AppLog.debug("API LLM cleanup", category: .llm)
        initialized = false
    }
}

#endif
