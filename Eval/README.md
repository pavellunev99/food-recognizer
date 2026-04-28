# FoodRecognizer VLM Evaluation Harness

Инструмент для итеративной отладки промта и сравнения локальных VLM моделей.
Цель — измерять числовой рейтинг связки «промт + модель» на размеченной базе картинок и
получать стабильный сигнал «стало лучше / стало хуже» при изменениях.

Это отдельный SwiftPM executable (`tools/eval/`), он не зависит от Xcode-проекта iOS,
переиспользует production `LocalLLMService.analyzeFood(...)` и production-промт.

## Quick start

```bash
# 1. Подготовить Metal bundle (один раз; идемпотентно):
./scripts/prepare-metallib.sh

# 2. Полный прогон (~8-10 минут на 93 картинки):
swift run -c release FoodEval run --prompt v1 --model qwen2 --images all

# 3. Сравнить промты:
swift run FoodEval compare --model qwen2 --prompts v1,v2,v3

# 4. Тесты:
swift test
```

Wrapper для удобства из корня репо: `./scripts/run_eval.sh --prompt v1 --model qwen2 --images all`.

## Subcommands

| Команда | Что делает |
| ------- | ---------- |
| `gate-check` | Smoke-проверка SDK / MLX / HF tokenizer — для CI и локальной диагностики. Без скачивания весов. |
| `smoke-infer` | Один inference-запуск (по умолчанию `Fixtures/images/_smoke/`) для отладки модели/промта без полного прогона. |
| `run` | Основной прогон: читает `Fixtures/ground_truth.json`, гоняет каждую картинку через `LocalLLMService`, считает score, пишет отчёт. |
| `compare` | Сравнительная таблица best-runs из `Reports/best/` для разных промтов на одной модели. |
| `score-only` | Прогоняет scorer на готовом raw JSON output модели — для отладки парсера/scoring без повторного inference. |

## Структура

```
tools/eval/
  Package.swift
  Sources/FoodEval/        # Swift CLI (subcommand'ы, runner, scorer)
  Tests/FoodEvalTests/     # unit-тесты (35 кейсов)
  Fixtures/
    ground_truth.json           # 93 размеченных еды-айтема (tier1/2/3)
    LICENSES.md                 # источники картинок
    images/
      _smoke/                   # 1 картинка для smoke-infer
      tier1/                    # 30 single-item, tolerance 10%
      tier2/                    # 23 packaged, tolerance 10%
      tier3/                    # 40 prepared dishes, tolerance 25%
  Prompts/
    v1_baseline.txt             # текущий production-промт
  Reports/
    runs/                       # все запуски (json + summary)
    best/                       # лучший run на (prompt, model)
    latest.md                   # markdown-сравнение последнего vs baseline
    baseline_v1.md              # эталонные числа v1 + qwen2VL_2B
  scripts/
    prepare-metallib.sh         # симлинкует MLX metallib bundle в .build/
```

## Как добавить новый промт

1. Создай `Prompts/v2_my_idea.txt` (просто текст системного промта, без обвязки).
2. Запусти полный прогон:
   ```bash
   swift run -c release FoodEval run --prompt v2_my_idea --model qwen2 --images all
   ```
3. Открой `Reports/latest.md` — увидишь mean / p50 / p90 / pass@0.7 + Δ к baseline,
   per-tier разбивку и список регрессий.
4. Если число лучше baseline — `Reports/best/v2_my_idea_qwen2VL_2B.json` обновится автоматически.

Чтобы поднять промт в production — отредактируй `LocalVLMModel.nutritionSystemPrompt(retry:)`
в основном таргете FoodRecognizer.

## Как добавить новую картинку

1. Положи jpg в `Fixtures/images/tierN/<id>.jpg` (≤220 KB, ≤1024px по длинной стороне).
2. Допиши `GroundTruthItem` в `Fixtures/ground_truth.json`:
   ```json
   {
     "id": "099_my_food",
     "tier": 1,
     "imagePath": "tier1/099_my_food.jpg",
     "nameAliases": ["my food", "канонические алиасы"],
     "weightG": 100,
     "calories": 250,
     "macros": { "protein": 5.0, "carbs": 30.0, "fats": 12.0 }
   }
   ```
3. Обнови `Fixtures/LICENSES.md` (источник + лицензия).
4. Прогон засчитает картинку автоматически — никакой регистрации не требуется.

Для полу-автоматической ingest-помощи: `scripts/ingest_groundtruth.py` (требует USDA API key).

## Scoring

Per-image score [0..1]:

| Поле | Вес | Формула |
| ---- | --- | ------- |
| structural | 0.10 | 0/1 — валидный JSON со всеми обязательными полями |
| name | 0.30 | max similarity по `nameAliases` (substring или нормализованная Levenshtein) |
| calories | 0.30 | `max(0, 1 - |actual - truth| / (truth * tolerance))` |
| macros | 0.30 | avg(protein, carbs, fats), та же формула |

Tolerances:

| Tier | Что | Допуск |
| ---- | --- | ------ |
| tier1 | single-item (фрукты, овощи, простое мясо) | 10% |
| tier2 | packaged (обёртка, точная nutrition info) | 10% |
| tier3 | prepared dishes (рецепты, приближённая nutrition) | 25% |

Aggregates: `mean`, `p50`, `p90`, `passRate@0.7`, плюс per-tier разбивка.

## Baseline

См. [`Reports/baseline_v1.md`](Reports/baseline_v1.md) — эталонные числа для текущего
production-промта + qwen2VL_2B, зафиксированные на 2026-04-28. Любой новый прогон
автоматически сравнивается с лучшим run в `Reports/best/`; baseline_v1.md — отдельный
read-only документ, его не перетирает следующий прогон.

## Troubleshooting

- **"default.metallib not found"** — запусти `scripts/prepare-metallib.sh`. Скрипт
  симлинкует bundle, который собрал Xcode (SwiftPM CLI не компилирует MLX `.metal`).
- **`USDA_API_KEY not set`** при `ingest_groundtruth.py` — получи бесплатный ключ
  на <https://fdc.nal.usda.gov/api-key-signup.html>.
- **OOM на `--model qwen3`** — закрой другие приложения; heavy-варианту нужно ~6 GB
  unified memory. Для smoke возможно работает `--limit 3`; для полного прогона —
  только Apple Silicon с ≥16 GB.
- **HF download fails** — проверь интернет; первый прогон тянет ~1.2 GB (qwen2)
  или ~2.6 GB (qwen3). Кэш HuggingFace: `~/.cache/huggingface/hub/`.
- **Прогон зависает на одной картинке** — current runner записывает scored=0 с note
  `"inference error: ..."` и продолжает дальше; смотри последние строки `stderr`,
  чтобы найти проблемный image id.
