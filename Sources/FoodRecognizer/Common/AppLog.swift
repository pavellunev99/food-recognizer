import Foundation
import OSLog

/// Диагностический логгер. В release-билдах вывод подавлен, поэтому топология
/// провайдера/URL/моделей не попадает в крэш-репорты и Console.app.
///
/// Все методы `nonisolated`: логгер не должен прибиваться к main actor (под
/// Swift 6 `InferIsolatedConformances` без явной аннотации статические методы
/// без выраженной изоляции выводятся в actor-контекст файла — а нам надо звать
/// логгер из любого actor'а, включая `ModelUpgradeCoordinator`).
nonisolated enum AppLog {
    private static let base = "com.nutrilens"

    private static let general = Logger(subsystem: base, category: "general")
    private static let llm = Logger(subsystem: base, category: "llm")
    private static let storage = Logger(subsystem: base, category: "storage")

    nonisolated static func debug(_ message: @autoclosure @escaping () -> String, category: Category = .general) {
        #if DEBUG
        logger(for: category).debug("\(message(), privacy: .public)")
        #endif
    }

    nonisolated static func info(_ message: @autoclosure @escaping () -> String, category: Category = .general) {
        #if DEBUG
        logger(for: category).info("\(message(), privacy: .public)")
        #endif
    }

    nonisolated static func error(_ message: @autoclosure @escaping () -> String, category: Category = .general) {
        logger(for: category).error("\(message(), privacy: .public)")
    }

    enum Category: Sendable {
        case general, llm, storage
    }

    nonisolated private static func logger(for category: Category) -> Logger {
        switch category {
        case .general: return general
        case .llm: return llm
        case .storage: return storage
        }
    }
}
