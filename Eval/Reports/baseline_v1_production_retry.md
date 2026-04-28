# Baseline — prompt v1_production_retry + qwen2VL_2B (2026-04-28)

Production retry-промт. Тот же few-shots placeholder, но с retry-блоком
(жёстче формат-инструкции, повторяет требования по name+macros+portionGrams).
Запускается в production когда первая попытка возвращает невалидный JSON.
В eval — на всех 93 фикстурах сразу (без условного gating), чтобы измерить
quality с включённой retry-логикой.

Run id: `2026-04-28T05-46-10Z_v1_production_retry_qwen2VL_2B`.
Сборка: `swift run -c release FoodEval run --prompt v1_production_retry --model qwen2 --images all`.
Полный сырой отчёт: `Reports/runs/2026-04-28T05-46-10Z_v1_production_retry_qwen2VL_2B.json`.
Машинный summary: `Reports/runs/2026-04-28T05-46-10Z_v1_production_retry_qwen2VL_2B_summary.json`.

## Aggregate (93/93 fixtures, 100% coverage)

| Metric    | Value         |
| --------- | ------------- |
| mean      | 0.297         |
| p50       | 0.280         |
| p90       | 0.464         |
| pass@0.7  | 1/93 (1.08%)  |
| count     | 93            |

## Per-tier

| Tier | Что                        | Count | Mean  | p50   | p90   | pass@0.7      |
| ---- | -------------------------- | ----- | ----- | ----- | ----- | ------------- |
| 1    | single-item, 10% tolerance | 30    | 0.217 | 0.147 | 0.400 | 0/30 (0%)     |
| 2    | packaged, 10% tolerance    | 23    | 0.371 | 0.400 | 0.631 | 0/23 (0%)     |
| 3    | prepared dishes, 25% tol.  | 40    | 0.316 | 0.314 | 0.498 | 1/40 (2.5%)   |

## Top 10 Worst

| ID                        | Total | Note                                                            |
| ------------------------- | ----- | --------------------------------------------------------------- |
| 013_spinach_baby          | 0.043 | structural: missing fields ...                                  |
| 027_walnut_english        | 0.043 | structural: missing fields ...                                  |
| 001_apple_red             | 0.100 | name mismatch: got "苹果"                                        |
| 015_bread_wheat_slice     | 0.100 | name mismatch: got "Сердюк"                                     |
| 016_rice_white_cooked     | 0.100 | name mismatch: got "白米饭"                                      |
| 020_yogurt_greek_plain    | 0.100 | name mismatch: got "Сливки"                                     |
| 029_hazelnut              | 0.100 | name mismatch: got "Пеканы"                                     |
| 004_pear_bartlett         | 0.115 | name mismatch: got "4 яблоки"                                   |
| 079_gnocchi               | 0.115 | name mismatch: got "Приготовленный салат"                       |
| 097_buddha_bowl           | 0.126 | name mismatch: got "Салат с овощами и яйцом"                    |

## Top 10 Best

| ID                        | Total | Note                                            |
| ------------------------- | ----- | ----------------------------------------------- |
| 061_pizza_margherita      | 0.737 | calories off by 5% (expected 285, got 300)      |
| 032_nutella               | 0.694 | calories off by 0% (expected 539, got 540)      |
| 060_cadbury_dairy_milk    | 0.690 | calories off by 0% (expected 57.8, got 58)      |
| 064_burger_cheese         | 0.681 | calories off by -7% (expected 535, got 500)     |
| 042_mms_peanut            | 0.639 | calories off by -2% (expected 247, got 242)     |
| 051_sprite_can            | 0.600 | calories off by 83%                             |
| 077_paella                | 0.554 | name mismatch                                   |
| 086_apple_pie             | 0.499 | calories off by 60%                             |
| 091_avocado_toast         | 0.498 | name mismatch                                   |
| 065_sushi_california_roll | 0.464 | calories off by 87%                             |

## Time

- Total wall clock (после cold start): ~3 min 48 s (228 s inference на 93 fixtures)
- Inference per image: 2.45 s avg (min 1.98 s, max 3.24 s)
- p50/p90 per-image: 2.44 s / 2.67 s
- Retry-блок добавляет ~370 ms на запрос (длиннее prompt → дольше prefill).

## Excluded fixtures

Нет. Все 93 фикстуры обработаны.

## Notes — observations промта v1_production_retry

1. **Якорь 413 ккал устранён полностью.** В retry — 0 совпадений из 93 (vs 46
   на статическом v1, 1 на v1_production). Retry-инструкции переопределяют
   формат настолько, что старые memorized-числа не всплывают совсем.
2. **Tier 2 — лучший (mean 0.371).** Retry форсирует попадание в правильный
   формат полей, packaged-snacks выигрывают: Nutella exact (540 vs 539),
   M&M's exact (242 vs 247), Cadbury exact (58 vs 57.8). Но pass@0.7 здесь
   не зачлось — где-то портится name (`Ферреро Рокер`, `Хеллманн Мейсон`).
3. **Tier 3 значительно лучше (+0.025 vs production, +0.026 vs static).**
   Сложные блюда — пицца 0.737, бургер 0.681, паэлья 0.554 — retry хорошо
   стабилизирует JSON-структуру для prepared dishes.
4. **Tier 1 хуже всех trio** (0.217 — против 0.245 на static, 0.220 на
   production). Retry-инструкция склоняет модель к "более развёрнутому"
   названию, и она впадает в галлюцинации (`苹果`, `Сердюк`, `Сливки`,
   `Пеканы` — даже на простом фундуке промахивается).
5. **0 структурных провалов calories=0 / nil-output**, но 2 кадра
   (013_spinach_baby, 027_walnut_english) дали неполный набор полей.
   То есть retry чинит тип ошибок "no JSON" / "no required fields" — но не
   спасает от семантических провалов name.
6. **Pass@0.7 упал** до 1/93 (тирамису не вошёл, его место занял пицца).
   То есть retry **поднимает mean но смещает peak вниз** — меньше
   "случайных" попаданий за счёт более структурного, но более
   усреднённого вывода.

## Сравнение со static v1 и v1_production

| Metric         | v1 (static)   | v1_production | v1_production_retry | Δ retry/static | Δ retry/prod |
| -------------- | ------------- | ------------- | ------------------- | -------------- | ------------ |
| mean           | 0.276         | 0.282         | 0.297               | +0.022         | +0.015       |
| p50            | 0.284         | 0.279         | 0.280               | -0.004         | +0.001       |
| p90            | 0.459         | 0.434         | 0.464               | +0.005         | +0.030       |
| pass@0.7       | 1/87 (1.1%)   | 2/93 (2.15%)  | 1/93 (1.08%)        | 0              | -1           |
| 413-anchor cnt | 46            | 1             | 0                   | -46            | -1           |
| coverage       | 87/93         | 93/93         | 93/93               | +6             | 0            |
| inference time | ~1.91 s/img   | ~2.08 s/img   | ~2.45 s/img         | +0.54 s        | +0.37 s      |

> Retry-промт — best-in-mean (0.297), best-in-tier3 (0.316), best-in-tier2
> (0.371). Минусы: -1 pass@0.7 vs production, +0.37 s/img inference,
> чуть хуже tier1. Эффективен как **fallback-промт после первого
> failure**, не как primary.

### Топ-5 улучшений retry vs static v1

| ID                        | v1    | retry | Δ      |
| ------------------------- | ----- | ----- | ------ |
| 065_sushi_california_roll | 0.000 | 0.464 | +0.464 |
| 073_lasagna               | 0.000 | 0.441 | +0.441 |
| 044_pringles_original     | 0.000 | 0.390 | +0.390 |
| 069_caprese_salad         | 0.143 | 0.464 | +0.321 |
| 032_nutella               | 0.400 | 0.694 | +0.294 |

### Топ-5 регрессий retry vs static v1

| ID                        | v1    | retry | Δ      |
| ------------------------- | ----- | ----- | ------ |
| 049_red_bull              | 0.600 | 0.233 | -0.367 |
| 016_rice_white_cooked     | 0.459 | 0.100 | -0.359 |
| 001_apple_red             | 0.400 | 0.100 | -0.300 |
| 092_sandwich_club         | 0.531 | 0.243 | -0.288 |
| 025_tuna_canned_water     | 0.411 | 0.134 | -0.277 |

### Топ-5 улучшений retry vs v1_production

| ID                        | prod  | retry | Δ      |
| ------------------------- | ----- | ----- | ------ |
| 042_mms_peanut            | 0.180 | 0.639 | +0.459 |
| 008_avocado_hass          | 0.000 | 0.448 | +0.448 |
| 044_pringles_original     | 0.000 | 0.390 | +0.390 |
| 062_spaghetti_carbonara   | 0.000 | 0.311 | +0.311 |
| 043_lay_classic           | 0.100 | 0.400 | +0.300 |

### Топ-5 регрессий retry vs v1_production

| ID                        | prod  | retry | Δ      |
| ------------------------- | ----- | ----- | ------ |
| 050_pepsi_can             | 0.754 | 0.400 | -0.354 |
| 088_macarons              | 0.455 | 0.140 | -0.315 |
| 020_yogurt_greek_plain    | 0.400 | 0.100 | -0.300 |
| 016_rice_white_cooked     | 0.400 | 0.100 | -0.300 |
| 001_apple_red             | 0.400 | 0.100 | -0.300 |
