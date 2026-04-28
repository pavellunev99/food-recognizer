#if canImport(UIKit)

import Foundation
import Combine

/// В какой фазе сейчас прогресс. UI разделяет первичную загрузку и фоновый
/// upgrade — текст баннера у них разный. `.failed` — координатор остановился
/// после fatal ошибки в pipeline; банер показывает retry-action.
enum ModelDownloadPhase: Sendable, Equatable {
    case initialDownload
    case upgrade
    case failed
}

/// Shared state прогресса загрузки локальной VLM. Слушает
/// `LocalLLMService.progressNotification` и отдаёт значения в любой SwiftUI
/// view через `@Published`. Используется на главной и на экране анализа.
@MainActor
final class ModelDownloadState: ObservableObject {

    static let shared = ModelDownloadState()

    @Published private(set) var fraction: Double = 0
    /// true с момента первой нотификации до прихода fraction ≥ 1.0.
    @Published private(set) var isDownloading: Bool = false
    /// Источник прогресса: первичная загрузка bootstrap-модели или фоновый
    /// upgrade на heavy. Координатор выставляет `.upgrade` на время своего
    /// download-этапа и сбрасывает обратно в `.initialDownload` после.
    @Published var phase: ModelDownloadPhase = .initialDownload
    /// Текст ошибки последней неудачной попытки — отображается в subtitle банера
    /// при `.failed`. Координатор пишет сюда `error.localizedDescription` в
    /// rollback и чистит при старте новой попытки/успехе.
    @Published var errorMessage: String?

    /// Выставить `.failed` + текст причины. Безопасно дёргать с MainActor.
    func markFailure(_ message: String) {
        self.errorMessage = message
        self.phase = .failed
    }

    /// Сбросить текст ошибки при старте новой попытки или успехе.
    func clearFailure() {
        if errorMessage != nil { errorMessage = nil }
    }

    private var observer: NSObjectProtocol?

    private init() {
        observer = NotificationCenter.default.addObserver(
            forName: LocalLLMService.progressNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let fraction = note.userInfo?["fraction"] as? Double else { return }
            MainActor.assumeIsolated {
                self?.fraction = fraction
                self?.isDownloading = fraction < 1.0
            }
        }
    }

    deinit {
        if let observer {
            NotificationCenter.default.removeObserver(observer)
        }
    }
}

#endif
