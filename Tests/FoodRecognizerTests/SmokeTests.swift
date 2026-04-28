import Testing
@testable import FoodRecognizer

// MARK: - SmokeTests
//
// Минимальный smoke-тест что модуль импортируется и базовый тип `LocalVLMModel`
// доступен. Полные качественные тесты VLM выполняются в `Eval/` — там
// используются MLX inference + ground-truth fixtures (93 картинки).
//
// Для расширения unit-coverage модуля кладите тесты сюда. Хорошие кандидаты:
//   - LocalVLMModel.nutritionSystemPrompt(retry:) — что строка не пустая
//   - LocalVLMModel.randomizedFewShots(count:) — формат JSON
//   - parsing помощников из NutritionAnalyzerService

@Suite("FoodRecognizer smoke")
struct SmokeTests {

    @Test("LocalVLMModel cases доступны")
    func vlmModelCasesAvailable() {
        let cases = LocalVLMModel.allCases
        #expect(cases.contains(.qwen2VL_2B))
        #expect(cases.contains(.qwen3VL_4B))
    }

    @Test("Bootstrap — qwen2VL_2B")
    func bootstrapTier() {
        #expect(LocalVLMModel.qwen2VL_2B.tier == .bootstrap)
    }

    @Test("Heavy — qwen3VL_4B")
    func heavyTier() {
        #expect(LocalVLMModel.qwen3VL_4B.tier == .heavy)
    }
}
