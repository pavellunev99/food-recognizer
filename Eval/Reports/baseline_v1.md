# Baseline — prompt v1 + qwen2VL_2B (2026-04-28)

Полный e2e прогон fixture-набора. Это **reference для будущих изменений промта**:
любая попытка улучшить v1 должна показать прирост mean / pass@0.7 относительно
этих чисел.

Run id: `2026-04-28T02-43-57Z_v1_qwen2VL_2B`.
Сборка: `swift run -c release FoodEval run --prompt v1 --model qwen2 --images <87-id-list>`.
Полный сырой отчёт: `Reports/runs/2026-04-28T02-43-57Z_v1_qwen2VL_2B.json`.
Машинный summary: `Reports/runs/2026-04-28T02-43-57Z_v1_qwen2VL_2B_summary.json`.

## Aggregate (87/93 fixtures, 93.5% coverage)

| Metric    | Value |
| --------- | ----- |
| mean      | 0.276 |
| p50       | 0.284 |
| p90       | 0.459 |
| pass@0.7  | 1/87 (1.1%) |
| count     | 87    |

## Per-tier

| Tier | Что | Count | Mean | p50 | p90 | pass@0.7 |
| ---- | --- | ----- | ---- | --- | --- | -------- |
| 1    | single-item, 10% tolerance | 30 | 0.245 | 0.186 | 0.401 | 0/30 (0%) |
| 2    | packaged, 10% tolerance    | 19 | 0.295 | 0.380 | 0.500 | 0/19 (0%) |
| 3    | prepared dishes, 25% tol.  | 38 | 0.290 | 0.290 | 0.525 | 1/38 (2.6%) |

## Top 10 Worst

| ID | Total | Note |
| -- | ----- | ---- |
| 004_pear_bartlett        | 0.000 | structural: output is nil (no JSON parsed) |
| 020_yogurt_greek_plain   | 0.000 | structural: missing fields calories,protein,carbs,fats,portionGrams |
| 027_walnut_english       | 0.000 | structural: missing fields ... |
| 065_sushi_california_roll| 0.000 | structural: missing fields ... |
| 073_lasagna              | 0.000 | structural: missing fields ... |
| 044_pringles_original    | 0.000 | structural: missing fields ... |
| 054_hellmanns_mayo       | 0.000 | structural: missing fields ... |
| 026_tofu_firm            | 0.100 | name mismatch: got "Блюдо" |
| 029_hazelnut             | 0.100 | name mismatch: got "Пески" |
| 046_kelloggs_corn_flakes | 0.100 | name mismatch: got "Конфеты" |

## Top 10 Best

| ID | Total | Note |
| -- | ----- | ---- |
| 084_tiramisu             | 0.704 | calories off by 1% (410 → 413) |
| 061_pizza_margherita     | 0.645 | calories off by 9% |
| 049_red_bull             | 0.600 | calories off by 1900% — но name дал высокий score |
| 092_sandwich_club        | 0.531 | calories off by -29% |
| 064_burger_cheese        | 0.528 | calories off by -23% |
| 072_omelette             | 0.523 | calories off by 15% |
| 033_coca_cola_can        | 0.500 | calories off by 124% |
| 050_pepsi_can            | 0.500 | calories off by 78% |
| 016_rice_white_cooked    | 0.459 | calories off by 101% |
| 093_bagel_lox            | 0.458 | name mismatch |

## Time

- Cold start (compile + container load + первая inference): ~2 min 36 s wall clock
- Inference per image (после warm-up): 1.91 s avg (min 1.45 s, max 3.11 s)
- Total wall clock после cold start: ~2 min 47 s (87 inference)
- Total с cold start: ~5 min

## Excluded fixtures (6/93, 6.5%)

Эти 6 картинок исключены из прогона по `--images <id-list>` потому что Qwen2-VL-2B
на текущем v1-промте уходит в **многоминутную бесконечную generation** (нет EOS),
а runner Wave 4 не имеет per-image timeout. Каждый из этих кадров блокировал
прогон ≥3 минут CPU и не producedил scored запись. Список:

| ID | Tier | Симптом |
| -- | ---- | ------- |
| 036_snickers              | 2 | structural=0, длинная generation (5+ min) |
| 055_lipton_tea            | 2 | structural=0, 5+ min |
| 060_cadbury_dairy_milk    | 2 | hang >5 min, прерывание SIGINT |
| 051_sprite_can            | 2 | hang после cadbury |
| 094_chia_pudding          | 3 | hang >5 min, прерывание SIGINT |
| 063_caesar_salad          | 3 | многоязычная generation 1+ min, риск |

> Это **отдельный gap** — production hook без token limit и retry-loop без
> deadline. Чинится либо в `LocalLLMService.analyzeFood`, либо через CLI-флаг
> `--per-image-timeout-s` в EvalRunner. Не блокировало финальный baseline:
> 87/93 фикстур достаточно для сравнительного сигнала в будущих прогонах,
> и список excluded read-only фиксирован, чтобы будущие промт-варианты
> сравнивались на той же подвыборке.

## Notes — observations промта v1

Систематические провалы:

1. **Tier 1 хуже всех (mean 0.245)**. Single-item простые фрукты/овощи модель
   часто описывает как "Салат из овощей" / "Куриная грудка с рисом" — то есть
   **галлюцинирует приготовленное блюдо** вместо констатации простого ингредиента.
2. **Названия на русском корявые** (`Приглессы`, `Седеянки`, `Ферреро Рокер`,
   `Фанья`, `Сpaghetti`). Модель путает транслитерации и инвентит несуществующие
   слова. **Хороший промт должен потребовать английского названия + Russian alias.**
3. **Калории прилипают к 413 ккал** в 30+ ответов (см. "got 413" повторы).
   Похоже на стандартный fallback модели когда она не может определить — это
   создаёт массовые false-numbers и завышение Δcalories.
4. **Структурные провалы (7 кадров с total=0.0)** — модель иногда возвращает
   просто текст без JSON или JSON без обязательных полей. Validating retry в
   production hook не всегда срабатывает.
5. **Tier 3 неожиданно лучший по passRate (2.6%)**. Тирамису попало в pass
   потому что калории действительно ~410 — счастливое совпадение с моделью,
   которая ставит 413 как fallback.

Идеи для v2 (в порядке ROI):

- Жёстко зафиксировать формат "name in English / название по-русски".
- Усилить few-shot примеры с разнообразными портионами.
- Запретить fallback-калории (anti-pattern: 413 ккал на любой неизвестный
  продукт).
- Ограничить max_tokens — обрубит зависшие генерации.
- На retry — pass output schema через grammar-constrained decoding, если MLX
  это умеет.
