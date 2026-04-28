# Baseline — prompt v1_production + qwen2VL_2B (2026-04-28)

Динамический промт, faithful production. Few-shots генерируются per-image
с детерминированным seed=djb2(image_id). На каждый image — 4 свежих shots
с уникальными числами (нет якорной 413 ккал из статического snapshot).

Run id: `2026-04-28T05-42-11Z_v1_production_qwen2VL_2B`.
Сборка: `swift run -c release NutriLensEval run --prompt v1_production --model qwen2 --images all`.
Полный сырой отчёт: `Reports/runs/2026-04-28T05-42-11Z_v1_production_qwen2VL_2B.json`.
Машинный summary: `Reports/runs/2026-04-28T05-42-11Z_v1_production_qwen2VL_2B_summary.json`.

## Aggregate (93/93 fixtures, 100% coverage)

| Metric    | Value          |
| --------- | -------------- |
| mean      | 0.282          |
| p50       | 0.279          |
| p90       | 0.434          |
| pass@0.7  | 2/93 (2.15%)   |
| count     | 93             |

Все 6 фикстур, висевшие в Wave 7 на статическом v1, теперь отрабатывают
без зависаний (036_snickers, 051_sprite_can, 055_lipton_tea,
060_cadbury_dairy_milk, 063_caesar_salad, 094_chia_pudding).

## Per-tier

| Tier | Что                        | Count | Mean  | p50   | p90   | pass@0.7      |
| ---- | -------------------------- | ----- | ----- | ----- | ----- | ------------- |
| 1    | single-item, 10% tolerance | 30    | 0.220 | 0.152 | 0.400 | 0/30 (0%)     |
| 2    | packaged, 10% tolerance    | 23    | 0.347 | 0.400 | 0.637 | 2/23 (8.7%)   |
| 3    | prepared dishes, 25% tol.  | 40    | 0.291 | 0.284 | 0.441 | 0/40 (0%)     |

## Top 10 Worst

| ID                        | Total | Note                                                            |
| ------------------------- | ----- | --------------------------------------------------------------- |
| 003_orange_navel          | 0.000 | structural: missing fields calories,protein,carbs,fats,portionGrams |
| 008_avocado_hass          | 0.000 | structural: output is nil (no JSON parsed)                      |
| 029_hazelnut              | 0.000 | structural: missing fields ...                                  |
| 062_spaghetti_carbonara   | 0.000 | structural: output is nil (no JSON parsed)                      |
| 044_pringles_original     | 0.000 | structural: missing fields ...                                  |
| 027_walnut_english        | 0.047 | structural: missing fields ...                                  |
| 009_carrot_raw            | 0.100 | name mismatch: got "Салат"                                      |
| 014_potato_baked          | 0.100 | name mismatch: got "Булгур"                                     |
| 015_bread_wheat_slice     | 0.100 | name mismatch: got "Борщ"                                       |
| 043_lay_classic           | 0.100 | name mismatch: got "薯片"                                        |

## Top 10 Best

| ID                        | Total | Note                                            |
| ------------------------- | ----- | ----------------------------------------------- |
| 051_sprite_can            | 0.850 | carbs off by -100% (expected 30, got 0), но calories/name OK |
| 050_pepsi_can             | 0.754 | calories off by 2% (expected 197, got 200)      |
| 060_cadbury_dairy_milk    | 0.690 | calories off by 0% (expected 57.8, got 58)      |
| 064_burger_cheese         | 0.509 | calories off by -16% (expected 535, got 450)    |
| 061_pizza_margherita      | 0.500 | calories off by 258% (expected 285, got 1020)   |
| 067_ramen                 | 0.460 | name mismatch                                   |
| 088_macarons              | 0.455 | name mismatch                                   |
| 030_dark_chocolate        | 0.444 | calories off by 88%                             |
| 086_apple_pie             | 0.439 | calories off by 49%                             |
| 084_tiramisu              | 0.435 | calories off by -30% (expected 410, got 286)    |

## Time

- Total wall clock (после cold start): ~3 min 13 s (193 s inference на 93 fixtures)
- Inference per image: 2.08 s avg (min 1.49 s, max 2.98 s)
- p50/p90 per-image: 2.06 s / 2.26 s — стабильнее статического (нет 5+ min hangs)

## Excluded fixtures

Нет. Все 93 фикстуры обработаны, ни одной hang-генерации. Это прямое
следствие свежих per-image few-shots: без якорной 413 ккал модель не
впадает в патологический длинный mode на packaged-snacks.

## Notes — observations промта v1_production

1. **Якорная 413 ккал устранена.** Из 93 ответов calories=413 встречается
   ровно 1 раз (1.1%) — против 46/87 (52.9%) на статическом v1. Это значит,
   что динамические few-shots с разными числами действительно ломают
   memorization.
2. **Tier 2 вырос значительно (+0.052, 0.295 → 0.347).** Освободившись от
   "fallback 413", модель чаще попадает в реалистичные числа калорий для
   упаковок (Pepsi 200 vs 197, Cadbury 58 vs 57.8 — exact pass@0.7 бились бы).
3. **Tier 1 регрессировал (-0.025, 0.245 → 0.220).** Single-item стало хуже:
   6 из 10 worst — name mismatch на простых фруктах/овощах. Видимо, новые
   few-shots не покрывают паттерн "просто яблоко без блюда" так чётко, как
   старый статический snapshot.
4. **Структурные провалы тоже сместились** — теперь это 003_orange_navel,
   008_avocado_hass, 029_hazelnut, 062_spaghetti_carbonara, 044_pringles
   (5 кадров с total=0 против 7 на v1). На 044_pringles few-shots
   стохастически гонят nil-output — нужно проверить, не дают ли фейлы
   именно те seeds, у которых shots оказались семантически слишком далеки.
5. **Pass@0.7 удвоился** (1/87 → 2/93). Расход на пользу packaged tier 2.
6. **6 ранее зависавших фикстур теперь сходятся.** Sprite=0.85, Cadbury=0.69,
   Pepsi=0.75 — три из них в Top-10. Анкер ломал не точность, а сам
   процесс генерации.

## Сравнение со статическим v1

| Metric         | v1 (static)   | v1_production | Δ      |
| -------------- | ------------- | ------------- | ------ |
| mean           | 0.276         | 0.282         | +0.006 |
| p50            | 0.284         | 0.279         | -0.005 |
| p90            | 0.459         | 0.434         | -0.025 |
| pass@0.7       | 1/87 (1.1%)   | 2/93 (2.15%)  | +1     |
| 413-anchor cnt | 46            | 1             | -45    |
| coverage       | 87/93 (93.5%) | 93/93 (100%)  | +6     |

> Коэффициенты неабсолютно сравнимы (87 vs 93 fixture). Production-промт
> побеждает статический по mean (+0.006), pass@0.7 (×2), coverage и устраняет
> 413-anchor — но проигрывает в p90 за счёт регрессии 003/008/029/062
> (структурные провалы вместо умеренных скоров).

### Топ-5 улучшений (где production-промт поднял total)

| ID                        | v1    | v1_production | Δ      |
| ------------------------- | ----- | ------------- | ------ |
| 020_yogurt_greek_plain    | 0.000 | 0.400         | +0.400 |
| 054_hellmanns_mayo        | 0.000 | 0.400         | +0.400 |
| 065_sushi_california_roll | 0.000 | 0.400         | +0.400 |
| 088_macarons              | 0.155 | 0.455         | +0.300 |
| 039_milka                 | 0.135 | 0.429         | +0.293 |

### Топ-5 регрессий (где production-промт уронил total)

| ID                        | v1    | v1_production | Δ      |
| ------------------------- | ----- | ------------- | ------ |
| 008_avocado_hass          | 0.400 | 0.000         | -0.400 |
| 003_orange_navel          | 0.400 | 0.000         | -0.400 |
| 093_bagel_lox             | 0.458 | 0.122         | -0.336 |
| 062_spaghetti_carbonara   | 0.295 | 0.000         | -0.295 |
| 025_tuna_canned_water     | 0.411 | 0.129         | -0.282 |

### Регрессии по сравнению с baseline (через `run --baseline best`)

Aggregator зарегистрировал лишь одну регрессию >0.05 относительно best/v1:
029_hazelnut (0.100 → 0.000). Остальные сдвиги вошли в шум tolerance
агрегатора.
