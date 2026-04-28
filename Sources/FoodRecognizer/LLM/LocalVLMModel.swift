import Foundation

/// Выбор локальной VLM для `LocalLLMService`.
/// Qwen2-VL-2B-Instruct-4bit — дефолт (1.2 GB, влезает в 2 GB лимит Prefetched
/// Asset Pack и точнее распознаёт нетипичные блюда).
nonisolated enum LocalVLMModel: String, CaseIterable, Codable, Sendable {
    case qwen2VL_2B
    case qwen3VL_4B

    static let `default`: LocalVLMModel = .qwen2VL_2B

    var displayName: String {
        switch self {
        case .qwen2VL_2B: return "Qwen2-VL 2B Instruct (4-bit)"
        case .qwen3VL_4B: return "Qwen3-VL 4B Instruct (4-bit)"
        }
    }

    var repoId: String {
        switch self {
        case .qwen2VL_2B: return "mlx-community/Qwen2-VL-2B-Instruct-4bit"
        case .qwen3VL_4B: return "mlx-community/Qwen3-VL-4B-Instruct-4bit"
        }
    }

    /// Корневое имя директории модели. Используется как префикс для группы
    /// asset packs: `<root>-meta` + `<root>-shard-NN` (см. ModelAssetProvider).
    var assetPackModelRoot: String {
        switch self {
        case .qwen2VL_2B: return "qwen2-vl-2b-instruct-4bit"
        case .qwen3VL_4B: return "qwen3-vl-4b-instruct-4bit"
        }
    }
}

// MARK: - Tier & resource requirements

/// Категория модели. Bootstrap — лёгкая, ставится сразу при первом запуске.
/// Heavy — мощная, скачивается фоном после bootstrap при наличии ресурсов.
nonisolated enum ModelTier: String, Codable, Sendable {
    case bootstrap
    case heavy
}

extension LocalVLMModel {
    nonisolated var tier: ModelTier {
        switch self {
        case .qwen2VL_2B: return .bootstrap
        case .qwen3VL_4B: return .heavy
        }
    }

    /// Минимум физической памяти устройства, ниже которого модель не запускается.
    /// iOS даёт ~50% physicalMemory до jetsam kill.
    nonisolated var minPhysicalMemoryBytes: UInt64 {
        switch tier {
        case .bootstrap: return 4 * 1024 * 1024 * 1024  // 4 GB
        case .heavy:     return 6 * 1024 * 1024 * 1024  // 6 GB
        }
    }

    /// Приблизительный размер весов модели в байтах (4-bit Q4).
    nonisolated var approximateSizeBytes: Int64 {
        switch self {
        case .qwen2VL_2B: return 1_300_000_000
        case .qwen3VL_4B: return 2_600_000_000
        }
    }

    /// Минимум свободного места на диске для установки. 2× размер модели —
    /// нужен запас под атомарную замену (старые файлы остаются до switch).
    nonisolated var minFreeDiskBytes: Int64 {
        2 * approximateSizeBytes
    }

    /// SHA-256 хэш ожидаемого артефакта (если зафиксирован revision).
    /// Stage 1: nil для всех — заполним когда зафиксируем revision на HF.
    nonisolated var sha256: String? { nil }
}

// MARK: - Generation config

extension LocalVLMModel {

    /// Параметры сэмплинга под конкретную VLM.
    /// - `temperature` низкая (0.3) даёт детерминированные числа, но 2B модели
    ///   скатываются в mode collapse на few-shot якорях. Для ретрая —
    ///   заметно выше, чтобы вырваться из того же локального минимума.
    /// - `topP` отсекает хвост распределения, оставляя самые вероятные токены.
    struct GenerationConfig: Sendable {
        let temperature: Float
        let retryTemperature: Float
        let topP: Float
    }

    nonisolated var generationConfig: GenerationConfig {
        switch self {
        case .qwen2VL_2B:
            // Qwen2-VL 2B/4-bit: выше 0.6 модель начинает генерить не JSON, а
            // русский freeform («недостаточно данных»). 0.5 — компромисс между
            // выходом из anchor mode collapse и сохранением строгого формата.
            return GenerationConfig(temperature: 0.35, retryTemperature: 0.5, topP: 0.9)
        case .qwen3VL_4B:
            // Heavy модель того же семейства Qwen, safe defaults как у 2B.
            // Промпт-тюнинг под heavy — отдельная задача.
            return GenerationConfig(temperature: 0.35, retryTemperature: 0.5, topP: 0.9)
        }
    }

    // MARK: - Prompts

    /// Системный промпт для извлечения пищевой ценности с фото. `retry=true` —
    /// повторная попытка после suspiciousOutput: усиливаем запрет на якорные
    /// числа и форсируем уникальные значения. Few-shot значения рандомизируются
    /// при каждом вызове, чтобы модель не копировала конкретные цифры из промпта.
    nonisolated func nutritionSystemPrompt(retry: Bool) -> String {
        let shots = Self.randomizedFewShots(count: 4)
        switch self {
        case .qwen2VL_2B:
            return Self.qwenPrompt(retry: retry, shots: shots)
        case .qwen3VL_4B:
            // Heavy того же семейства Qwen, промпт переиспользуем.
            return Self.qwenPrompt(retry: retry, shots: shots)
        }
    }

    // MARK: - Few-shot randomization

    /// Генерит список JSON-примеров с полностью уникальными числами на каждый
    /// запрос. Это фундаментально ломает anchor mode collapse: модель не может
    /// «скопировать 287 ккал из примера», потому что этих 287 в промпте уже нет.
    /// Числа подобраны так, чтобы 4·P + 4·C + 9·F ≈ calories (±5%) — заодно учим
    /// модель соблюдать macro-баланс.
    nonisolated private static func randomizedFewShots(count: Int) -> [String] {
        let dishes: [(ru: String, portion: String, gRange: ClosedRange<Int>)] = [
            ("Куриная грудка с рисом", "1 порция", 220...360),
            ("Греческий салат", "небольшая тарелка", 150...260),
            ("Паста болоньезе", "1 порция", 280...400),
            ("Овсянка с ягодами", "миска", 200...290),
            ("Лосось на гриле", "кусок филе", 130...210),
            ("Борщ со сметаной", "тарелка", 280...360),
            ("Омлет с овощами", "1 порция", 150...260),
            ("Жареная картошка с луком", "1 порция", 200...310)
        ]
        let picks = dishes.shuffled().prefix(count)
        return picks.map { dish in
            let grams = Int.random(in: dish.gRange)
            // Сгенерим реалистичные БЖУ с вариацией, потом подгоним калории.
            let protein = Double.random(in: 2.0...38.0)
            let carbs = Double.random(in: 4.0...68.0)
            let fats = Double.random(in: 1.5...26.0)
            let calories = Int((protein * 4 + carbs * 4 + fats * 9).rounded())
            return #"{"foodName":"\#(dish.ru)","portionSize":"\#(dish.portion)","portionGrams":\#(grams),"calories":\#(calories),"protein":\#(String(format: "%.1f", protein)),"carbs":\#(String(format: "%.1f", carbs)),"fats":\#(String(format: "%.1f", fats))}"#
        }
    }

    // MARK: - Model-specific prompt bodies

    nonisolated private static func qwenPrompt(retry: Bool, shots: [String]) -> String {
        // Retry-блок намеренно ПОЗИТИВНЫЙ. В прошлой версии писали «physically
        // impossible result» — модель интерпретировала как «я не разобралась» и
        // выдавала `"calories": "недостаточно данных"` вместо чисел.
        let retryBlock = retry ? """

        RETRY NOTE: you gave zero macros last time. That means the result was \
        unusable. ALWAYS provide your best numeric estimate even if uncertain. \
        For packaged drinks estimate 15-80 kcal per 100ml with realistic \
        protein/carbs/fats. For packaged sweets / confectionery (мармелад/jelly \
        candy ≈ 330 kcal/100g, chocolate ≈ 530, cookies ≈ 470, hard candy ≈ 390, \
        chips/snacks ≈ 540) use the category density for the shown net weight \
        even if you cannot read the label. For mixed dishes estimate based on \
        visible ingredients. NEVER write text like "unknown" or "insufficient" \
        in numeric fields — those fields MUST be numbers.
        """ : ""

        return """
        You are a precise nutrition estimator. Follow this procedure:

        Step 1 (internal, do NOT output): identify every visible food item and estimate its \
        weight in grams. Use plate/utensils/hand as scale reference when visible. For packaged \
        products read the net weight from the label if visible; otherwise infer from package size.
        Step 1a (internal, NAMING — CRITICAL): foodName MUST be in English using the Latin \
        alphabet. Use the simplest accurate English name. Examples: "apple", "banana", \
        "boiled egg", "white rice", "grilled chicken breast", "greek salad", "spaghetti \
        carbonara". DO NOT write Russian, Chinese, Japanese, Korean, Thai, or any non-Latin \
        script in foodName. Russian translations belong only inside portionSize \
        (e.g. "1 яблоко"). NEVER invent a word — if you cannot identify the food precisely, \
        fall back to the broadest correct English category ("fruit", "vegetable", "nut", \
        "snack", "drink").
        Step 1b (internal, OCR/labels — CRITICAL): if a Nutrition Facts table or any printed \
        per-serving values are visible on packaging in ANY language (English, Russian, Thai, \
        Chinese, Japanese, Korean, Arabic, etc.) — READ the printed numbers directly. \
        Common headers to recognize: "Nutrition Facts", "Пищевая ценность", "พลังงาน/น้ำตาล/\
        ไขมัน/โซเดียม" (energy/sugar/fat/sodium in Thai), "栄養成分表示" (Japanese), "营养成分" \
        (Chinese). Multiply per-serving values by the number of servings shown. If both \
        per-serving and per-100g/ml are present, prefer per-serving × servings_per_container. \
        DO NOT return zeros when label numbers are clearly readable.
        Step 1c (internal, SINGLE-ITEM RULE — CRITICAL): if the photo shows ONE simple \
        ingredient on a plain background (one fruit, one vegetable, one nut variety, one egg, \
        one slice of bread, one piece of cheese, a glass of one drink) — name it with \
        ONE-or-TWO English words naming that ingredient. Examples: "apple", "banana", \
        "carrot", "cucumber", "walnut", "boiled egg", "bread slice", "milk", "cheddar cheese". \
        DO NOT describe it as a composite dish ("salad", "bulgur", "stew", "porridge"). \
        DO NOT add ingredients that are not visible.
        Step 2 (internal, do NOT output): for each item without a label, multiply weight by \
        actual nutrient density per 100g (cooked chicken breast ≈ 165 kcal / 31g protein / \
        0g carbs / 3.6g fat; white rice ≈ 130 kcal / 2.7g protein / 28g carbs / 0.3g fat; \
        olive oil ≈ 884 kcal / 0g protein / 0g carbs / 100g fat; jelly candy / мармелад ≈ \
        330 kcal / 0.5g protein / 80g carbs / 0g fat; milk chocolate ≈ 530 kcal / 7g protein \
        / 58g carbs / 30g fat; cookies ≈ 470 kcal / 6g protein / 65g carbs / 20g fat; \
        potato chips ≈ 540 kcal / 6g protein / 53g carbs / 35g fat; watermelon ≈ 30 kcal / \
        0.6g protein / 7.6g carbs / 0.2g fat; pomelo / помело ≈ 38 kcal / 0.8g protein / \
        9.6g carbs / 0g fat). Sum across items.
        Step 2a (internal, REFERENCE PORTIONS — CRITICAL for portionGrams): use these typical \
        single-serving weights for whole, single-ingredient photos. Pick a SPECIFIC non-round \
        value near (but never equal to) these anchors: medium apple ≈ 182 g, banana ≈ 118 g, \
        navel orange ≈ 154 g, pear ≈ 178 g, large grapes cluster ≈ 138 g, strawberries cup ≈ \
        144 g, blueberries cup ≈ 148 g, single carrot ≈ 72 g, cucumber ≈ 132 g, tomato \
        cluster ≈ 96 g, broccoli florets ≈ 156 g, baby spinach ≈ 28 g, single baked potato ≈ \
        173 g, slice of wheat bread ≈ 28 g, cooked rice cup ≈ 158 g, one boiled egg ≈ 50 g, \
        one raw large egg ≈ 56 g, glass of whole milk ≈ 244 g, plain Greek yogurt cup ≈ \
        227 g, slice of cheddar ≈ 28 g, cooked chicken breast ≈ 172 g, salmon fillet ≈ 154 g, \
        canned tuna drained ≈ 142 g, firm tofu block ≈ 126 g, almonds handful ≈ 28 g, \
        walnuts handful ≈ 28 g, hazelnuts handful ≈ 28 g, dark chocolate square ≈ 24 g, \
        can of soda ≈ 355 g, can of energy drink ≈ 248 g, restaurant pasta plate ≈ 318 g, \
        pizza slice ≈ 107 g, burger ≈ 232 g, sandwich ≈ 186 g, sushi roll plate ≈ 184 g.
        Step 3 (output): respond with ONLY a valid JSON object. After the closing `}`, \
        output NOTHING — no prose, no explanation, no markdown, no code fences. \
        All numeric fields (calories, protein, carbs, fats, portionGrams) MUST be \
        unquoted numbers like 287 or 14.2 — never strings, never words.

        HARD CONSTRAINTS (failure to meet any = invalid output):
        1. protein·4 + carbs·4 + fats·9 MUST equal calories within ±10%.
        2. If calories > 30 then protein + carbs + fats MUST be > 0. A non-zero energy value \
           with zero macros is physically impossible.
        3. Numbers must be specific and non-round. Forbidden anchor values: \
           calories 100/150/200/250/300/350/400/420/450/500; \
           protein/carbs/fats 0/5/10/15/20/25/30/35/40/45/50/55/60 when food is actually \
           present; portionGrams 100/150/200/250/300/350/400/450/500. \
           Use values like 287, 413, 6.3, 14.2, 231g, 17g protein, 23g protein.
        4. portionGrams MUST be estimated from the ACTUAL visible food (plate size, utensils, \
           hand, package size). DO NOT default to 250g — that is the most common WRONG answer. \
           Examples of CORRECT estimates: small fruit container 130g, slice of cake 95g, \
           bowl of soup 320g, restaurant pasta plate 340g, packaged drink 180-330ml. \
           Small side dish ≈ 110-180g, normal plate ≈ 220-340g, generous portion ≈ 360-480g.
        5. Protein-to-mass ratio must match the food. The combo "portionGrams=250 with \
           protein=25" is the model's most common lazy fallback — produce real estimates \
           instead. Salad ~ 4-12g protein. Pasta with seafood ~ 18-28g. Burger ~ 22-35g. \
           Fruit ~ 0.5-2g. Sweet drink ~ 0-2g.

        SCOPE:
        - Estimate nutrition for ANY visible food, even partially eaten, blurry, unusual, or \
          hard to identify. Mixed dishes, snacks, drinks, fruit, packaged items — all count.
        - Respond with {"noFood": true} ONLY if ZERO edible items are visible (empty plate, \
          landscape, face without food, pure text screenshot with no product in frame).
        - If you see a product package, treat it as food. Do not return noFood for packaged \
          foods or drinks. Read the label.
        - For peeled / cut / unpackaged fruit (citrus segments, watermelon chunks, apple \
          slices) — identify by colour, texture, and shape; never return "не идентифицировано".

        OUTPUT FORMAT:
        {"foodName": string (short English name), "portionSize": string (human-readable, can be Russian), \
        "portionGrams": number, "calories": number, "protein": number, "carbs": number, \
        "fats": number}

        Examples of the expected JSON FORMAT. The VALUES in these examples are random \
        placeholders — DO NOT copy any of these numbers. Generate fresh numbers based on \
        the actual photo:
        \(shots.joined(separator: "\n"))\(retryBlock)
        """
    }
}
