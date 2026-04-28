# Iteration v3 — REGRESSION (rolled back to v2 as production winner)

## TL;DR

v3_targeted gambled on three new fixes layered onto v2_targeted (low-density caps,
restaurant plate sizes, last-digit-not-0/5). On qwen3 it **regressed**:
mean 0.448 → 0.435, pass@0.7 14/93 → 8/93. On qwen2 v3 hung indefinitely on
fixture 29_hazelnut after producing the broccoli=413 anchor regression at #12.

**Decision: v2_targeted stays as production winner. v3 rolled back conceptually
(file kept for reference). v4 would attack different levers.**

## Compare table (qwen3VL_4B)

| Prompt | Mean | p50 | p90 | pass@0.7 | tier1 | tier2 | tier3 |
|---|---|---|---|---|---|---|---|
| v1_production | 0.247 | — | — | 3/93 | 0.159 | 0.334 | 0.262 |
| v2_targeted | **0.448** | 0.400 | **0.732** | **14/93** | **0.400** | **0.504** | 0.452 |
| v3_targeted | 0.435 | 0.400 | 0.672 | 8/93 | 0.365 | 0.494 | **0.455** |
| Δ v3 vs v2 | -0.013 | 0 | -0.060 | -6 | -0.035 | -0.010 | +0.003 |

Only tier3 marginally improved (+0.003). All other metrics regressed.

## qwen2VL_2B

qwen2 v3 was killed at fixture 28/93 after a 7+ minute hang on 29_hazelnut.
Partial signals from the first 28 fixtures:
- 12_broccoli got calories=413 — the **anchor that v2 had eliminated returned**
- 6_strawberry got calories=350 (low-density cap < 80 ignored entirely)
- 19_egg_raw got calories=340 (+376%)
- Multiple NAME_GIBBERISH cases ("Сахаробедро", "Atún Claro", "heart-shaped wooden pieces")

The qwen2-2B model **cannot follow** the layered cap-reasoning from H3.1
("if calories exceed cap, recompute with smaller grams"). The "recompute"
instruction sent the model into an internal reasoning loop on harder fixtures,
producing the hang.

**v3 is a net negative for both models. Do not deploy.**

## Why each fix failed

### H3.1 — Low-density caps (target: CALORIES_OVER_2X on raw produce)

Did the **opposite** on qwen3 — model responded with "vegetable platter" /
"greek salad" / "lentil dal" for cucumber/broccoli/spinach to make the
low-calorie answer "fit" the cap (since one cucumber doesn't normally appear
at a "platter" scale, but a platter does). Net effect: NAME_GIBBERISH on
single-ingredient produce went up, breaking the v2 single-item rule.

### H3.2 — Restaurant plate sizes (target: CALORIES_UNDER_50pct on tier3)

Marginally positive (+0.003 on tier3 mean) but pass@0.7 on tier3 dropped
from 14% (v2) to 5% (v3). Model interpreted plate-size hints as upper bound
rather than typical, leaning toward smaller plates to be "safe".

### H3.3 — Last-digit-not-0/5 portionGrams

Inconclusive. On qwen3 most portionGrams ended in non-zero digit but
NAME_GIBBERISH and structural failures dominated, so we couldn't isolate
the H3.3 effect.

## Top 5 fixtures broken by v3 vs v2 (qwen3)

| ID | v2 | v3 | What broke |
|---|---|---|---|
| 002_banana | 0.40 | 0.00 | structural — JSON missing all numeric fields |
| 088_macarons | 0.46 | 0.00 | structural — model output cut mid-JSON |
| 014_potato_baked | 0.40 | 0.00 | structural — same |
| 020_yogurt_greek_plain | 0.40 | 0.00 | structural — same |
| 010_cucumber | 0.40 | 0.15 | foodName=vegetable platter (cap-driven hallucination) |

Four structural failures introduced by v3 alone — almost certainly the longer
prompt exceeded some internal context limit on edge fixtures. v2 had zero
structural failures on qwen3.

## Top 3 fixtures improved (qwen3, v3 vs v2)

Marginal improvements only:

| ID | v2 | v3 |
|---|---|---|
| 067_ramen | 0.46 | 0.59 |
| 086_apple_pie | 0.44 | 0.67 |
| 095_granola_bowl | 0.78 | 0.80 |

Not enough to compensate for the structural regressions.

## v4 hypotheses (different levers, since v3-style cap-stacking failed)

1. **Dual-name field** (`foodNameEn` + `foodNameRu`). Requires Scorer change
   (cheap: ~30 lines). Lets qwen2 keep its Russian instinct on `foodNameRu`
   while satisfying alias-match on `foodNameEn`. Expected: NAME_GIBBERISH on
   qwen2 from 34 → ~10. Highest-leverage change still on the table.
2. **Few-shots template upgrade**: extend FewShotsGenerator's dish list
   from 8 to 30 dishes covering single-item ingredients (apple, cucumber,
   chicken breast). Currently all 8 dishes are composite — model never sees
   a single-item example, fueling NAME_HALLUCINATED_DISH. Expected:
   single-item naming improves on both models.
3. **Per-tier prompts** (separate v_t1 / v_t2 / v_t3). Heavier refactor —
   needs runner change to route by tier. T2 packaged products have totally
   different failure modes than T1 produce.
4. **Trim v2_targeted**: maybe v2 is closer to optimum than we thought,
   and the marginal returns on additional rules are negative. Try
   _removing_ Step 2a portion table and see if mean drops materially —
   could reveal the table is doing most of the work.

**Skip:** more cap rules, more "if X then recompute" reasoning, more
language guidance — all of those failed in v3.

## Production recommendation

**Use `v2_targeted` content for `LocalVLMModel.qwenPrompt`.**
**Use qwen3VL_4B as primary model.** Use qwen2VL_2B only as fallback for
devices that cannot run qwen3 (memory constraints).

Configuration: mean 0.448, pass@0.7 = 14/93 (15%), p90 0.732. Tier-2
(packaged) is best at 0.504 — strong on Pepsi/Cadbury/Nutella/M&M's exact
calorie matches. Tier-1 at 0.400 — weaker but acceptable for single-item
fallback. Tier-3 at 0.452 — usable for restaurant dishes.

Run id: `2026-04-28T06-25-42Z_v2_targeted_qwen3VL_4B`.

## Files

- `tools/eval/Prompts/v3_targeted.txt` — kept for historical reference
- `tools/eval/Reports/runs/2026-04-28T07-15-25Z_v3_targeted_qwen3VL_4B.json`
- `tools/eval/Reports/best/v3_targeted_qwen3VL_4B.json`
- `tools/eval/Reports/iteration_v3.md` (this file)
- (production winner) `tools/eval/Reports/best/v2_targeted_qwen3VL_4B.json`
