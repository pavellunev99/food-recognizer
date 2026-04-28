import Testing
import Foundation
@testable import NutriLensEval

// MARK: - FewShotsGeneratorTests
//
// Контракт FewShotsGenerator:
//  1. count → ровно столько строк
//  2. seed → детерминизм между вызовами
//  3. seed nil → случайность (sanity)
//  4. каждая строка — валидный JSON с обязательными полями + macro-баланс ±5%
//
// Если эти тесты падают — нарушен faithful-perity с production
// `LocalVLMModel.randomizedFewShots(count:)` и harness начнёт давать ложные
// сигналы (числа из shots не соответствуют тем, что app фактически суёт в VLM).

@Suite struct FewShotsGeneratorTests {

    @Test func returnsRequestedCount() {
        let shots = FewShotsGenerator.generate(count: 4, seed: 42)
        #expect(shots.count == 4)

        let shots2 = FewShotsGenerator.generate(count: 1, seed: 42)
        #expect(shots2.count == 1)

        let shots3 = FewShotsGenerator.generate(count: 8, seed: 42)
        #expect(shots3.count == 8) // у нас ровно 8 dish-templates, count==8 берёт все
    }

    @Test func sameSeedProducesSameOutput() {
        // Главный инвариант детерминизма: harness должен давать одинаковые
        // shots для одного и того же image_id между прогонами.
        let a = FewShotsGenerator.generate(count: 4, seed: 12_345)
        let b = FewShotsGenerator.generate(count: 4, seed: 12_345)
        #expect(a == b)
    }

    @Test func differentSeedsProduceDifferentOutput() {
        // Sanity: разные image_id дают разные shots. Если этот тест падает —
        // RNG не зависит от seed, и детерминизм ничего не даёт.
        let a = FewShotsGenerator.generate(count: 4, seed: 1)
        let b = FewShotsGenerator.generate(count: 4, seed: 2)
        #expect(a != b)
    }

    @Test func eachShotIsValidJSONWithMacroBalance() throws {
        let shots = FewShotsGenerator.generate(count: 4, seed: 7)
        for shot in shots {
            let data = Data(shot.utf8)
            let obj = try #require(
                try JSONSerialization.jsonObject(with: data) as? [String: Any]
            )
            // Обязательные поля production-формата.
            let foodName = try #require(obj["foodName"] as? String)
            let portionSize = try #require(obj["portionSize"] as? String)
            let portionGrams = try #require(obj["portionGrams"] as? Int)
            let calories = try #require(obj["calories"] as? Int)
            let protein = try #require((obj["protein"] as? NSNumber)?.doubleValue)
            let carbs = try #require((obj["carbs"] as? NSNumber)?.doubleValue)
            let fats = try #require((obj["fats"] as? NSNumber)?.doubleValue)

            #expect(!foodName.isEmpty)
            #expect(!portionSize.isEmpty)
            #expect(portionGrams > 0)
            #expect(calories > 0)

            // Macro-баланс: 4·P + 4·C + 9·F ≈ calories. Production генерит
            // calories точно по формуле + .rounded(), значит расхождение
            // должно быть только из-за rounding (≤ 0.5 ккал, далеко в пределах 5%).
            let predicted = protein * 4 + carbs * 4 + fats * 9
            let delta = abs(Double(calories) - predicted)
            let tolerance = max(2.0, predicted * 0.05) // ±5% или ±2 ккал
            #expect(delta <= tolerance, "predicted=\(predicted) calories=\(calories) delta=\(delta)")
        }
    }

    @Test func deterministicSeedFromImageId() {
        // Hash-функция не должна меняться между релизами: harness ожидает
        // тот же seed для того же image_id, чтобы shots не «дрифтили».
        let a = FewShotsGenerator.seed(forImageId: "001_apple_red")
        let b = FewShotsGenerator.seed(forImageId: "001_apple_red")
        #expect(a == b)
        let c = FewShotsGenerator.seed(forImageId: "002_banana_ripe")
        #expect(a != c)
    }
}
