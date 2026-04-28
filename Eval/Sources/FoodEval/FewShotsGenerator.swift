import Foundation

// MARK: - FewShotsGenerator
//
// Faithful copy production-логики `LocalVLMModel.randomizedFewShots(count:)`
// (см. FoodRecognizer/Services/LLM/LocalVLMModel.swift:134). Цель — давать тот же
// вид few-shot блока, что app использует в runtime, но с детерминизмом per
// image_id, чтобы прогон harness был воспроизводим.
//
// Разница с production:
//  - production использует `Int.random(in:)` / `Double.random(in:)` —
//    SystemRandomNumberGenerator. Здесь то же самое, когда `seed == nil`.
//  - при `seed != nil` подменяем RNG на splitmix64 (детерминированный 64-bit
//    PRNG). Это даёт `harness rerun X` → те же few-shots для одного image_id.
//
// Числовые диапазоны / dish-templates — БУКВАЛЬНО те же, что в production.
// Любое изменение здесь должно быть отражено и там одновременно.

public struct FewShotsGenerator {

    /// Точная копия `LocalVLMModel.dishes` (production source of truth).
    /// Если меняешь production — меняй и здесь, иначе harness уйдёт в дрифт.
    private static let dishes: [(ru: String, portion: String, gRange: ClosedRange<Int>)] = [
        ("Куриная грудка с рисом", "1 порция", 220...360),
        ("Греческий салат", "небольшая тарелка", 150...260),
        ("Паста болоньезе", "1 порция", 280...400),
        ("Овсянка с ягодами", "миска", 200...290),
        ("Лосось на гриле", "кусок филе", 130...210),
        ("Борщ со сметаной", "тарелка", 280...360),
        ("Омлет с овощами", "1 порция", 150...260),
        ("Жареная картошка с луком", "1 порция", 200...310)
    ]

    /// Генерирует `count` JSON-строк few-shots в том же формате, что production.
    /// - Parameters:
    ///   - count: сколько примеров вернуть (production вызывает с 4).
    ///   - seed: nil → SystemRandomNumberGenerator (как в app). Иначе —
    ///           splitmix64 от seed для воспроизводимости.
    public static func generate(count: Int, seed: UInt64? = nil) -> [String] {
        if var rng = seed.map({ SplitMix64(seed: $0) }) {
            return generate(count: count, using: &rng)
        } else {
            var rng = SystemRandomNumberGenerator()
            return generate(count: count, using: &rng)
        }
    }

    /// Перегрузка с явным RNG. Тестам удобно прокидывать свой mock,
    /// production-копии — `SystemRandomNumberGenerator`.
    public static func generate<R: RandomNumberGenerator>(
        count: Int,
        using rng: inout R
    ) -> [String] {
        // 1) shuffled().prefix(count) — буквально как в production.
        let picks = dishes.shuffled(using: &rng).prefix(count)
        // 2) per-dish числа. Диапазоны — копия production.
        return picks.map { dish in
            let grams = Int.random(in: dish.gRange, using: &rng)
            let protein = Double.random(in: 2.0...38.0, using: &rng)
            let carbs = Double.random(in: 4.0...68.0, using: &rng)
            let fats = Double.random(in: 1.5...26.0, using: &rng)
            let calories = Int((protein * 4 + carbs * 4 + fats * 9).rounded())
            // Формат строки 1-в-1 как в production (см. LocalVLMModel.swift:153).
            return #"{"foodName":"\#(dish.ru)","portionSize":"\#(dish.portion)","portionGrams":\#(grams),"calories":\#(calories),"protein":\#(String(format: "%.1f", protein)),"carbs":\#(String(format: "%.1f", carbs)),"fats":\#(String(format: "%.1f", fats))}"#
        }
    }

    /// Детерминированный seed по image_id. Используется EvalRunner'ом, чтобы
    /// один и тот же image у одного и того же promptVersion давал одни и те
    /// же shots между прогонами (а значит дельты vs baseline были честные).
    /// Алгоритм: djb2-hash на UInt64. Не криптографически стойкий — нам нужна
    /// только воспроизводимость, не равномерность распределения.
    public static func seed(forImageId imageId: String) -> UInt64 {
        var hash: UInt64 = 5381
        for scalar in imageId.unicodeScalars {
            hash = hash &* 33 &+ UInt64(scalar.value)
        }
        return hash
    }
}

// MARK: - SplitMix64

/// Детерминированный 64-bit PRNG. Стандартный splitmix64 из reference-папера
/// Vigna (использется как seeder для xorshift/xoroshiro). Достаточно качества
/// для тестового детерминизма, не криптография.
struct SplitMix64: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        // Защита от seed == 0: splitmix корректно работает и из нуля,
        // но полезно нормализовать.
        self.state = seed
    }

    mutating func next() -> UInt64 {
        state = state &+ 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
