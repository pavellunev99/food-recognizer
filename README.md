# FoodRecognizer

Swift Package для распознавания еды по фото через локальную VLM (Vision-Language Model). Используется в приложении [Nutrilens](https://github.com/pavellunev99) для оффлайн-определения блюда, его веса и пищевой ценности (КБЖУ).

## Стек

- **MLX** + **mlx-swift-lm** — локальный inference 4-bit квантованных моделей на Apple Silicon
- **Qwen2-VL-2B-Instruct-4bit** (~1.2 GB) — bootstrap модель, малая RAM
- **Qwen3-VL-4B-Instruct-4bit** (~2.6 GB) — heavy модель с лучшим качеством
- **swift-huggingface** + **swift-transformers** — токенайзеры и Hugging Face Hub fallback
- **BackgroundAssets** (iOS 26+) — AssetPack-доставка весов из App Store
- **Vision** — OCR этикеток упаковки

## Платформы

- **iOS 17+** — главная цель.
- **macOS 14+** — формально объявлен ради SPM dep-resolve, public API под `#if canImport(UIKit)`. На macOS используйте Eval-инструмент.

## Установка

В `Package.swift` mobile-приложения:

```swift
.package(url: "https://github.com/pavellunev99/food-recognizer.git", branch: "main"),
```

Или local path при разработке:

```swift
.package(path: "../food-recognizer"),
```

## API (актуально на этап A)

```swift
import FoodRecognizer

// Создаём local VLM сервис на Qwen2 (bootstrap)
let llm = LocalLLMService(model: .qwen2VL_2B)
try await llm.initialize()

// Анализ фото еды → JSON-строка с КБЖУ
let json = try await llm.analyzeFood(image: uiImage, prompt: nil)
// {"foodName":"apple","portionSize":"1 яблоко","portionGrams":182,...}

// Дальше — парсинг через NutritionAnalyzerService
let analyzer = NutritionAnalyzerService(llmService: llm)
let result: FoodAnalysisResult = try await analyzer.analyzeFood(from: uiImage)
```

## Сценарий использования двух моделей

`ModelUpgradeCoordinator` живёт в mobile-host (зависит от SwiftData). Bootstrap → Heavy перевод делается на app-уровне:

1. Cold start → инициализируется `LocalLLMService(model: .qwen2VL_2B)` (быстро, ~1.2 GB)
2. После первого успешного inference → фоном начинается download Qwen3-VL-4B
3. Когда загружено → `cleanup()` старого + создаётся новый `LocalLLMService(model: .qwen3VL_4B)`
4. UpgradeStatus трекается через SwiftData @Model в mobile-host

## Структура репо

```
food-recognizer/
├── Package.swift
├── Sources/FoodRecognizer/
│   ├── LLM/
│   │   ├── LocalLLMService.swift          (MLX inference)
│   │   ├── LocalVLMModel.swift            (модель + промт + few-shots)
│   │   ├── LLMServiceProtocol.swift       (общий интерфейс)
│   │   ├── APILLMService.swift            (fallback через OpenAI/Anthropic API)
│   │   ├── ModelAssetProvider.swift       (iOS 26+ BackgroundAssets + HF fallback)
│   │   └── ModelDownloadState.swift       (@Published прогресс для UI)
│   ├── Nutrition/
│   │   ├── NutritionAnalyzerService.swift (orchestrator: OCR → VLM → retry)
│   │   └── NutritionLabelOCRService.swift (Vision OCR этикеток)
│   ├── Models/
│   │   ├── LLMRequest.swift               (request/response типы)
│   │   └── NutritionInfo.swift            (parsed result)
│   └── Common/
│       └── AppLog.swift                   (OSLog wrapper)
├── Tests/FoodRecognizerTests/             (unit-тесты модуля)
├── Eval/                                  (отдельный SwiftPM tool — см. ниже)
├── docs/                                  (внутренняя документация)
└── scripts/                               (helper-скрипты)
```

## Eval-инструмент

В `Eval/` лежит **standalone SwiftPM executable** `NutriLensEval` для оффлайн-измерения качества промта на 93 размеченных fixture-картинках. Не depend от FoodRecognizer-as-library — работает с MLX напрямую через CIImage.

### Quick start

```bash
cd Eval

# 1. Подготовка Metal bundle (один раз):
./scripts/prepare-metallib.sh

# 2. Полный прогон production-промта на qwen2/qwen3:
swift run -c release NutriLensEval run --prompt v2_targeted --model qwen2 --images all
swift run -c release NutriLensEval run --prompt v2_targeted --model qwen3 --images all

# 3. Сравнить промт-варианты:
swift run NutriLensEval compare --model qwen3 --prompts v1_production,v2_targeted

# 4. Тесты scorer'а:
swift test
```

### Workflow итерации промта

1. Скопируй `Eval/Prompts/v2_targeted.txt` в новый файл `vN_*.txt`, отредактируй
2. Прогон: `swift run -c release NutriLensEval run --prompt vN_* --model qwen3 --images all`
3. Открой `Eval/Reports/latest.md` — увидишь mean и Δ к baseline
4. Когда промт стал лучше — портируй текст в [`LocalVLMModel.qwenPrompt`](Sources/FoodRecognizer/LLM/LocalVLMModel.swift)

См. также:
- [`Eval/README.md`](Eval/README.md) — детали harness'а
- [`Eval/Reports/PRODUCTION_RECOMMENDATION.md`](Eval/Reports/PRODUCTION_RECOMMENDATION.md) — текущий production winner
- [`Eval/Reports/iteration_v2.md`](Eval/Reports/iteration_v2.md) и [`iteration_v3.md`](Eval/Reports/iteration_v3.md) — ход итераций

## Scoring rubric (per-image, [0..1])

```
structural   = 1 if (валидный JSON, все 5 number-полей) else 0
name         = max similarity по nameAliases (substring + Levenshtein)
calories     = max(0, 1 - |actual - truth| / (truth × tolerance))
macros       = avg(protein, carbs, fats) по той же формуле
total        = 0.10·structural + 0.30·name + 0.30·calories + 0.30·macros
```

Tolerances: tier-1/2 — 10%, tier-3 (готовые блюда) — 25%.

## Текущий baseline (qwen3VL_4B + v2_targeted)

| Metric | Value |
|---|---|
| mean | **0.448** |
| p90 | 0.732 |
| pass@0.7 | **14/93 (15%)** |
| tier1 / tier2 / tier3 | 0.400 / 0.504 / 0.452 |

vs baseline (qwen3VL_4B + старый promt): mean 0.247, pass@0.7 = 3/93. Прирост **+62% mean**.

## Roadmap

- **Этап A (сделан)** — извлечение в SPM модуль, eval-инструмент работает standalone.
- **Этап B (сейчас)** — mobile-app переключается на FoodRecognizer как SPM dependency, удаляются дубликаты.
- **Этап C** — снижение iOS deployment target до 17 (с условной AssetPack-логикой только для iOS 26+), хранение весов в GitHub Releases food-recognizer репо для xcodecloud-сборки без HF rate-limit.

## Лицензия

TBD — обсуждается. Внутренняя разработка Nutrilens.
