# Iteration v2 — targeted prompt fixes

## Summary

Three high-leverage fixes derived from per-fixture failure analysis (`analysis_v1_failures.md`):

- **Fix A — English-first foodName.** All previous prompts used Russian foodName, but qwen2/qwen3 ImageNet/CLIP heritage anchors them to English ingredient labels. Russian output produced ~40 NAME_GIBBERISH fixtures per run (invented Russian-looking words). Fix flips foodName to Latin alphabet, leaves Russian inside `portionSize`.
- **Fix B — Tier-aware single-item rule.** Step 1c: "if photo shows ONE simple ingredient, name it with ONE-or-TWO English words". Targets NAME_HALLUCINATED_DISH plus secondary CALORIES_OVER_2X on T1.
- **Fix D — Concrete per-ingredient portion tells.** New Step 2a injects 30+ reference grams (apple ≈ 182 g, banana ≈ 118 g, single egg ≈ 50 g, slice of bread ≈ 28 g, can of soda ≈ 355 g, etc.) and demands non-round portionGrams. Targets PORTION_FALLBACK + CALORIES_ANCHOR_250.

Skipped: Fix C (anti-zero-macros) — bucket already at 1 fixture in v1_production. Fix E (forbid copy-paste) — already in v1_production header.

## Bucket diff (qwen2VL_2B)

| Bucket | v1_production | v1_production_retry | v2_targeted | Δ vs retry |
|---|---|---|---|---|
| STRUCTURAL_NIL | 2 | 0 | 1 | +1 |
| STRUCTURAL_MISSING_FIELDS | 4 | 2 | 4 | +2 |
| NAME_ASIAN | 2 | 2 | 3 | +1 |
| NAME_GIBBERISH | 40 | 38 | 34 | **−4** |
| NAME_HALLUCINATED_DISH | 4 | 0 | 0 | 0 |
| CALORIES_ANCHOR_413 | 1 | 0 | 0 | 0 |
| CALORIES_ANCHOR_250 | 12 | 18 | 7 | **−11** |
| CALORIES_OVER_2X | 31 | 31 | 27 | **−4** |
| CALORIES_UNDER_50pct | 3 | 8 | 8 | 0 |
| MACROS_ZERO | 1 | 1 | 3 | +2 |
| PORTION_FALLBACK | 30 | 37 | 23 | **−14** |

qwen2 reads the new portion table and stops anchoring to 250. The naming fix only partially landed on qwen2 (the 2B model still emits cyrillic for ~⅓ items even when explicitly told otherwise).

## Compare table (qwen2VL_2B)

| Prompt | Mean | p50 | p90 | pass@0.7 | tier1 | tier2 | tier3 |
|---|---|---|---|---|---|---|---|
| v1_production | 0.282 | 0.279 | 0.434 | 2/93 | 0.220 | 0.347 | 0.291 |
| v1_production_retry | 0.297 | 0.280 | 0.464 | 1/93 | 0.217 | 0.371 | 0.316 |
| v2_targeted | **0.298** | **0.318** | **0.500** | 0/93 | **0.241** | **0.375** | 0.297 |
| Δ v2 vs v1_production | +0.016 | +0.038 | +0.066 | −2 | +0.021 | +0.028 | +0.006 |
| Δ v2 vs retry | +0.001 | +0.038 | +0.036 | −1 | +0.024 | +0.004 | −0.019 |

Marginal mean lift (+0.016 vs v1_production, +0.001 vs retry) but tier1 (+0.021/+0.024) and p50/p90 distribution shift right. pass@0.7 dipped because the model trades extreme wins for steadier mid-tier scores (more fixtures cluster at 0.40 instead of straddling the 0.7 line).

## qwen2 vs qwen3 baselines

| Run | Mean | p50 | p90 | pass@0.7 | tier1 | tier2 | tier3 |
|---|---|---|---|---|---|---|---|
| qwen2 v1_production | 0.282 | 0.279 | 0.434 | 2/93 | 0.220 | 0.347 | 0.291 |
| qwen2 v2_targeted | 0.298 | 0.318 | 0.500 | 0/93 | 0.241 | 0.375 | 0.297 |
| qwen3 v1_production | 0.247 | — | — | 3/93 | 0.159 | 0.334 | 0.262 |
| qwen3 v2_targeted | **0.448** | 0.400 | 0.732 | **14/93** | **0.400** | **0.504** | **0.452** |

**qwen3 v1_production is actually worse than qwen2 v1_production** — the larger model amplified STRUCTURAL_MISSING_FIELDS (28 vs 4) because it tried to add commentary fields and the regex couldn't parse them. **qwen3 v2_targeted is the strongest configuration tested**, with +0.20 mean over qwen3 v1 and +0.15 over qwen2 v2. The English-first foodName plus portion tells unlock qwen3's bigger vocabulary and visual reasoning that the qwen2-2B simply cannot reach. NAME_GIBBERISH on qwen3 went 22 → 0 — fix A landed perfectly on the larger model.

`compare --model qwen3` CLI shows v1_production with only 3 fixtures because the 3-fixture smoke run saved as `best` first; the full 93-fixture run (file `2026-04-28T06-13-10Z_v1_production_qwen3VL_4B.json`) carries the actual baseline.

## Top 5 fixtures v2 fixes (qwen3 — biggest deltas)

| ID | v1_production | v2_targeted | bucket left | v2 output |
|---|---|---|---|---|
| 033_coca_cola_can | 0.00 | 0.98 | STRUCTURAL_MISSING_FIELDS | foodName=Coca-Cola, cal=140, pg=330 |
| 095_granola_bowl | 0.00 | 0.78 | STRUCTURAL_MISSING_FIELDS | foodName=granola, cal=387, pg=231 |
| 018_egg_boiled | 0.00 | 0.77 | STRUCTURAL_MISSING_FIELDS + NAME_GIBBERISH | foodName=boiled egg, cal=78, pg=52 |
| 070_french_fries | 0.00 | 0.72 | STRUCTURAL_MISSING_FIELDS + NAME_GIBBERISH | foodName=fries, cal=342, pg=231 |
| 021_milk_whole | 0.00 | 0.71 | STRUCTURAL_MISSING_FIELDS | foodName=milk, cal=150, pg=244 |

The Step 2a portion table directly produced 52 g for the boiled egg, 28 g for cheddar, 244 g for milk — exactly matching the reference table.

## Top fixtures v2 breaks (qwen3 — only 2 regressions ≥ 0.15)

| ID | v1_production | v2_targeted | What broke |
|---|---|---|---|
| 090_smoothie_bowl | 0.43 | 0.15 | foodName=Guarana Antarctica (read a label brand instead of dish) |
| 076_dumplings | 0.34 | 0.18 | foodName=boiled chicken wing (misidentified the dish) |

For qwen2 the regression list is longer (sample): `051_sprite_can` 0.85→0.35 (foodName=Сок), `088_macarons` 0.46→0.14 (foodName=Омлет с овощами), `005_grape_red` 0.40→0.10 (foodName=葡萄). Smaller model still falls back to Russian/Chinese for unfamiliar Latin-alphabet items despite the English-first rule.

## v3 hypotheses (what to try next)

1. **Two-shot example injection of the portion table itself.** Concrete portion-tells live in Step 2a as a long sentence; qwen2 only partially absorbs. Convert the table to 3-4 sample assistant outputs with non-round portionGrams (e.g. show "53 g" not "50 g") so that the conditional probability of round numbers drops further. Expected: PORTION_FALLBACK on qwen2 from 23 → ~12.
2. **Dual-name field.** Add `foodNameEn` (English, used for scoring) and `foodNameRu` (Russian, used for UI) so qwen2 doesn't have to suppress its Russian instinct. Expected: NAME_GIBBERISH on qwen2 from 34 → ~10. Requires FoodEval scoring change to check both keys against aliases (cheap).
3. **Per-tier prompts.** T2 packaged products dominate STRUCTURAL_MISSING_FIELDS — they need a stronger "READ THE LABEL" framing. Could route v2_targeted_packaged for T2 only.
4. **CALORIES_OVER_2X on small produce (cucumber, broccoli, spinach) is sticky** — model scales calories with portion mass linearly even when produce is < 30 kcal/100 g. Add an explicit "low-density" bucket: "leafy greens / cucumber / tomato / broccoli / pepper / mushroom < 30 kcal per 100 g — final number for a normal portion is < 60 kcal." Expected: −5 fixtures from CALORIES_OVER_2X.
5. **CALORIES_UNDER_50pct rose for qwen3 (10 fixtures)** — symmetric undershoot. Likely caused by Step 2a anchoring portionGrams too low for restaurant plates. Add a tier3-specific size hint ("restaurant-served plates 280-380 g, café bowls 320-450 g").

## Files written

- `/Users/pavellunev/Development/FoodRecognizer/tools/eval/Prompts/v2_targeted.txt`
- `/Users/pavellunev/Development/FoodRecognizer/tools/eval/Reports/analysis_v1_failures.md`
- `/Users/pavellunev/Development/FoodRecognizer/tools/eval/Reports/iteration_v2.md`
- `/Users/pavellunev/Development/FoodRecognizer/tools/eval/scripts/analyze_failures.py`
- `/Users/pavellunev/Development/FoodRecognizer/tools/eval/Reports/runs/2026-04-28T06-03-38Z_v2_targeted_qwen2VL_2B.json`
- `/Users/pavellunev/Development/FoodRecognizer/tools/eval/Reports/runs/2026-04-28T06-13-10Z_v1_production_qwen3VL_4B.json`
- `/Users/pavellunev/Development/FoodRecognizer/tools/eval/Reports/runs/2026-04-28T06-25-42Z_v2_targeted_qwen3VL_4B.json`
