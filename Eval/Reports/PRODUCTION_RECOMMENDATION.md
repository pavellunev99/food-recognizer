# Production Recommendation — VLM prompt + model

## Winner: qwen3VL_4B + v2_targeted

After 9 iterations (v1_static → v1_production → v1_retry → v2_targeted → v3_targeted)
across qwen2VL_2B and qwen3VL_4B on 93 ground-truth fixtures.

| Metric | qwen2 + v1 (static) | qwen3 + v1_prod | qwen2 + v2_targeted | **qwen3 + v2_targeted** | qwen3 + v3 |
|---|---|---|---|---|---|
| mean | 0.276 | 0.247 | 0.298 | **0.448** | 0.435 |
| p50 | 0.284 | — | 0.318 | 0.400 | 0.400 |
| p90 | 0.459 | — | 0.500 | **0.732** | 0.672 |
| pass@0.7 | 1/87 | 3/93 | 0/93 | **14/93** | 8/93 |
| tier1 mean | 0.245 | 0.159 | 0.241 | **0.400** | 0.365 |
| tier2 mean | 0.295 | 0.334 | 0.375 | **0.504** | 0.494 |
| tier3 mean | 0.290 | 0.262 | 0.297 | 0.452 | 0.455 |

**Recommended config:** qwen3VL_4B (Heavy tier) as primary, qwen2VL_2B (Bootstrap)
as fallback for memory-constrained devices.

## Что класть в production-промт

Содержимое `tools/eval/Prompts/v2_targeted.txt` нужно перенести в
[`Sources/FoodRecognizer/LLM/LocalVLMModel.swift`](Sources/FoodRecognizer/LLM/LocalVLMModel.swift)
в функцию `qwenPrompt(retry:shots:)`. Конкретные изменения относительно текущего
production-промта:

### Добавить Step 1a (после Step 1)

```
Step 1a (internal, NAMING — CRITICAL): foodName MUST be in English using the
Latin alphabet. Use the simplest accurate English name. Examples: "apple",
"banana", "boiled egg", "white rice", "grilled chicken breast", "greek salad",
"spaghetti carbonara". DO NOT write Russian, Chinese, Japanese, Korean, Thai,
or any non-Latin script in foodName. Russian translations belong only inside
portionSize (e.g. "1 яблоко"). NEVER invent a word — if you cannot identify
the food precisely, fall back to the broadest correct English category
("fruit", "vegetable", "nut", "snack", "drink").
```

### Добавить Step 1c (после Step 1b)

```
Step 1c (internal, SINGLE-ITEM RULE — CRITICAL): if the photo shows ONE simple
ingredient on a plain background (one fruit, one vegetable, one nut variety,
one egg, one slice of bread, one piece of cheese, a glass of one drink) — name
it with ONE-or-TWO English words naming that ingredient. Examples: "apple",
"banana", "carrot", "cucumber", "walnut", "boiled egg", "bread slice", "milk",
"cheddar cheese". DO NOT describe it as a composite dish ("salad", "bulgur",
"stew", "porridge"). DO NOT add ingredients that are not visible.
```

### Добавить Step 2a (после Step 2)

```
Step 2a (internal, REFERENCE PORTIONS — CRITICAL for portionGrams): use these
typical single-serving weights for whole, single-ingredient photos. Pick a
SPECIFIC non-round value near (but never equal to) these anchors:
medium apple ≈ 182 g, banana ≈ 118 g, navel orange ≈ 154 g, pear ≈ 178 g,
large grapes cluster ≈ 138 g, strawberries cup ≈ 144 g, blueberries cup ≈ 148 g,
single carrot ≈ 72 g, cucumber ≈ 132 g, tomato cluster ≈ 96 g,
broccoli florets ≈ 156 g, baby spinach ≈ 28 g, single baked potato ≈ 173 g,
slice of wheat bread ≈ 28 g, cooked rice cup ≈ 158 g, one boiled egg ≈ 50 g,
one raw large egg ≈ 56 g, glass of whole milk ≈ 244 g,
plain Greek yogurt cup ≈ 227 g, slice of cheddar ≈ 28 g,
cooked chicken breast ≈ 172 g, salmon fillet ≈ 154 g,
canned tuna drained ≈ 142 g, firm tofu block ≈ 126 g, almonds handful ≈ 28 g,
walnuts handful ≈ 28 g, hazelnuts handful ≈ 28 g, dark chocolate square ≈ 24 g,
can of soda ≈ 355 g, can of energy drink ≈ 248 g, restaurant pasta plate ≈ 318 g,
pizza slice ≈ 107 g, burger ≈ 232 g, sandwich ≈ 186 g, sushi roll plate ≈ 184 g.
```

### НЕ добавлять (это пробовали в v3 — стало хуже)

- ❌ Low-density caps ("If calories exceed cap, recompute with smaller grams") —
  сломал Single-item rule на qwen3, привёл к hang на qwen2.
- ❌ Restaurant plate-size hint block — даёт слабый прирост tier3 mean
  (+0.003) ценой -6 pass@0.7 overall.
- ❌ Last-digit-not-0/5 правило — внесло шум, неулучшимый эффект.

## Если нужно ещё качество — v4 hypotheses (untested)

В порядке ROI (см. `iteration_v3.md` для деталей):

1. **Dual-name field** `foodNameEn` + `foodNameRu` — требует Scorer change
   (~30 строк). Снимает конфликт у qwen2, который не подчиняется English-rule.
   Expected: NAME_GIBBERISH на qwen2 c 34 → ~10.
2. **FewShotsGenerator** расширить с 8 composite dishes до 30 включая
   single-item ingredients (apple, cucumber, chicken breast). Сейчас модель
   никогда не видит single-item пример → подталкивает к halucinated dish.
3. **Per-tier prompts** — отдельный для T1/T2/T3. Тяжёлый refactor.
4. **Trim v2_targeted**: проверить, не делает ли Step 2a portion table всю
   работу. Удалить остальное и сравнить.

## Eval baseline (для будущих итераций)

```bash
cd tools/eval
swift run -c release FoodEval run --prompt v2_targeted --model qwen3 --images all
# Должно дать: mean ~0.45, pass@0.7 ~14/93
swift run FoodEval compare --model qwen3 --prompts v2_targeted,<новый>
# Любой новый промт сравнивается с этим baseline
```

Reference reports:
- `tools/eval/Reports/best/v2_targeted_qwen3VL_4B.json` — production-baseline
- `tools/eval/Reports/iteration_v2.md` — почему v2 победил v1
- `tools/eval/Reports/iteration_v3.md` — почему v3 откачен
- `tools/eval/Reports/analysis_v1_failures.md` — категоризация провалов
