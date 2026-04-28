# Failure analysis

- **2026-04-28T02-43-57Z** (v1, qwen2VL_2B): mean=0.276 pass@0.7=0.011 T1=0.245 T2=0.295 T3=0.290
- **2026-04-28T05-42-11Z** (v1_production, qwen2VL_2B): mean=0.282 pass@0.7=0.022 T1=0.220 T2=0.347 T3=0.291
- **2026-04-28T05-46-10Z** (v1_production_retry, qwen2VL_2B): mean=0.297 pass@0.7=0.011 T1=0.217 T2=0.371 T3=0.316

## Top failure patterns to address in v2

Ranked by **fixture-weight × fixability via prompt** on the strongest baseline run (v1_production_retry):

| Rank | Pattern | Counts (v1 / v1_prod / retry) | Why this matters | Prompt lever |
|---|---|---|---|---|
| 1 | NAME_GIBBERISH | 37 / 40 / 38 | ~40 % of all fixtures get an invented Russian-looking word that satisfies no alias → name score = 0. Stable across all three prompts → unaffected by retry/anchor changes. | **Force English foodName** (Latin) — model knows English ImageNet labels far better than Russian ingredient names. Russian gibberish disappears if we leave Russian out entirely. |
| 2 | CALORIES_OVER_2X | 35 / 31 / 31 | A third of fixtures overshoot calories by 2×+. Driven mainly by T1/T2 single ingredients (apple → 280-400 kcal, cucumber → 80 kcal). Density unit confusion (per-100g treated as per-portion). | **Tier-aware single-ingredient rule** + concrete portion tells (apple ~ 180 g, cucumber ~ 130 g, slice of bread ~ 30 g). Forces model to anchor portionGrams correctly so derived calories collapse. |
| 3 | PORTION_FALLBACK | 6 / 30 / 37 | Retry-prompt **made this worse** (×6) — model now lazy-falls back to round 100/200/250/300 g. Worst on T1 fixtures with strict tolerancePercent. | **Stronger forbid + per-category tells.** Add explicit "use a non-round number ending in non-0" instruction. |
| 4 | CALORIES_ANCHOR_250 | 5 / 12 / 18 | Same lazy-fallback path as PORTION_FALLBACK — portionGrams=250 dominates retry-prompt regressions. Tightly correlated with #3. | Same fix as #3. |
| 5 | NAME_HALLUCINATED_DISH | 3 / 4 / 0 | Tier1 single ingredient (carrot, potato, bread, tomato) named "Салат" / "Булгур" — copies few-shot dish names. Retry already cleaned this. | **Tier-aware single-item rule** ("if photo shows ONE simple ingredient, name it with ONE word"). |
| 6 | STRUCTURAL_MISSING_FIELDS | 6 / 4 / 2 | Walnut/hazelnut/spinach/pringles repeatedly drop fields. Already healing with retry. | Strengthen via clearer field-list reminder; not the limiting factor. |
| 7 | CALORIES_UNDER_50pct | 2 / 3 / 8 | Rose with retry — model hedged toward smaller numbers when forbidden from anchors. T3 fixtures dominate. | Watch for regression — don't add more "smaller is better" hints. |
| 8 | NAME_ASIAN | 0 / 2 / 2 | Sporadic CJK output (apple → 苹果). Cheap to fix with English-first rule. | Subsumed by fix A. |
| 9 | STRUCTURAL_NIL | 1 / 2 / 0 | Rare. Already at 0 with retry. | No action. |
| 10 | MACROS_ZERO | 1 / 1 / 1 | Constant low. Already addressed in v1_production. | No action. |
| 11 | CALORIES_ANCHOR_413 | 45 / 1 / 0 | Solved by dynamic few-shots. | Done. |

### Selected v2 fixes (2-3 highest-leverage levers)

- **Fix A — English-first naming.** Switch `foodName` to English (Latin alphabet). Targets the dominant NAME_GIBBERISH bucket (~40 fixtures) and incidentally NAME_ASIAN. Russian alias is allowed inside `portionSize`, but `foodName` must be English.
- **Fix B — Tier-aware single-item rule.** Add an explicit rule: "if the photo shows ONE simple ingredient on a plain background, name it with ONE English word naming that ingredient (e.g. 'apple', 'banana', 'carrot', 'walnut', 'bread slice'). DO NOT describe a composite dish." Targets NAME_HALLUCINATED_DISH plus secondary CALORIES_OVER_2X on T1.
- **Fix D — Concrete per-ingredient portion tells.** Inject 8-10 reference grams ("medium apple ~ 180 g, banana ~ 120 g, single egg ~ 50 g, slice of bread ~ 30 g, handful of nuts ~ 30 g, glass of milk ~ 250 ml, slice of cheese ~ 30 g, 1 cucumber ~ 130 g"). Targets PORTION_FALLBACK + CALORIES_ANCHOR_250 + half of CALORIES_OVER_2X.

Skipped on this iteration: Fix C (anti-zero-macros) — bucket already solved (only 1 fixture). Fix E (forbid copy-paste) — already in v1_production header text.


| Bucket | 2026-04-28T02-43-57Z | 2026-04-28T05-42-11Z | 2026-04-28T05-46-10Z |
|---|---|---|---|
| STRUCTURAL_NIL | 1 | 2 | 0 |
| STRUCTURAL_MISSING_FIELDS | 6 | 4 | 2 |
| NAME_ASIAN | 0 | 2 | 2 |
| NAME_GIBBERISH | 37 | 40 | 38 |
| NAME_HALLUCINATED_DISH | 3 | 4 | 0 |
| CALORIES_ANCHOR_413 | 45 | 1 | 0 |
| CALORIES_ANCHOR_250 | 5 | 12 | 18 |
| CALORIES_OVER_2X | 35 | 31 | 31 |
| CALORIES_UNDER_50pct | 2 | 3 | 8 |
| MACROS_ZERO | 1 | 1 | 1 |
| PORTION_FALLBACK | 6 | 30 | 37 |

### STRUCTURAL_NIL
- 2026-04-28T02-43-57Z: 004_pear_bartlett
- 2026-04-28T05-42-11Z: 008_avocado_hass, 062_spaghetti_carbonara

### STRUCTURAL_MISSING_FIELDS
- 2026-04-28T02-43-57Z: 020_yogurt_greek_plain, 027_walnut_english, 065_sushi_california_roll, 073_lasagna, 044_pringles_original, 054_hellmanns_mayo
- 2026-04-28T05-42-11Z: 003_orange_navel, 027_walnut_english, 029_hazelnut, 044_pringles_original
- 2026-04-28T05-46-10Z: 013_spinach_baby, 027_walnut_english

### NAME_ASIAN
- 2026-04-28T05-42-11Z: 070_french_fries, 043_lay_classic
- 2026-04-28T05-46-10Z: 001_apple_red, 016_rice_white_cooked

### NAME_GIBBERISH
- 2026-04-28T02-43-57Z: 006_strawberry, 007_blueberry, 009_carrot_raw, 010_cucumber, 011_tomato_grape, 013_spinach_baby, 014_potato_baked, 015_bread_wheat_slice, 022_cheddar_cheese, 024_salmon_atlantic_cooked, 066_pad_thai, 067_ramen, 070_french_fries, 071_pancakes, 074_tacos, 076_dumplings, 079_gnocchi, 080_falafel, 081_pho, 082_kebab, 083_donut_glazed, 085_cheesecake_ny, 087_chocolate_brownie, 088_macarons, 089_croissant, 090_smoothie_bowl, 091_avocado_toast, 093_bagel_lox, 095_granola_bowl, 096_tom_yum, 098_mac_and_cheese, 099_kimchi_jjigae, 100_eggs_benedict, 039_milka, 041_ferrero_rocher, 043_lay_classic, 046_kelloggs_corn_flakes
- 2026-04-28T05-42-11Z: 004_pear_bartlett, 007_blueberry, 010_cucumber, 011_tomato_grape, 013_spinach_baby, 014_potato_baked, 017_oatmeal_cooked, 018_egg_boiled, 022_cheddar_cheese, 023_chicken_breast_cooked, 025_tuna_canned_water, 026_tofu_firm, 027_walnut_english, 066_pad_thai, 067_ramen, 069_caprese_salad, 071_pancakes, 073_lasagna, 076_dumplings, 078_risotto_mushroom, 079_gnocchi, 082_kebab, 083_donut_glazed, 085_cheesecake_ny, 087_chocolate_brownie, 089_croissant, 090_smoothie_bowl, 093_bagel_lox, 094_chia_pudding, 095_granola_bowl, 096_tom_yum, 097_buddha_bowl, 098_mac_and_cheese, 099_kimchi_jjigae, 100_eggs_benedict, 036_snickers, 041_ferrero_rocher, 046_kelloggs_corn_flakes, 047_quaker_oats, 051_sprite_can
- 2026-04-28T05-46-10Z: 003_orange_navel, 004_pear_bartlett, 007_blueberry, 011_tomato_grape, 015_bread_wheat_slice, 017_oatmeal_cooked, 018_egg_boiled, 020_yogurt_greek_plain, 022_cheddar_cheese, 024_salmon_atlantic_cooked, 025_tuna_canned_water, 026_tofu_firm, 029_hazelnut, 066_pad_thai, 067_ramen, 071_pancakes, 075_chicken_curry, 079_gnocchi, 081_pho, 083_donut_glazed, 085_cheesecake_ny, 088_macarons, 089_croissant, 091_avocado_toast, 092_sandwich_club, 093_bagel_lox, 094_chia_pudding, 096_tom_yum, 097_buddha_bowl, 098_mac_and_cheese, 099_kimchi_jjigae, 036_snickers, 039_milka, 041_ferrero_rocher, 044_pringles_original, 046_kelloggs_corn_flakes, 049_red_bull, 054_hellmanns_mayo

### NAME_HALLUCINATED_DISH
- 2026-04-28T02-43-57Z: 011_tomato_grape, 017_oatmeal_cooked, 023_chicken_breast_cooked
- 2026-04-28T05-42-11Z: 009_carrot_raw, 011_tomato_grape, 014_potato_baked, 015_bread_wheat_slice

### CALORIES_ANCHOR_413
- 2026-04-28T02-43-57Z: 001_apple_red, 002_banana, 003_orange_navel, 005_grape_red, 006_strawberry, 007_blueberry, 011_tomato_grape, 012_broccoli, 013_spinach_baby, 016_rice_white_cooked, 018_egg_boiled, 019_egg_raw_large, 022_cheddar_cheese, 023_chicken_breast_cooked, 024_salmon_atlantic_cooked, 026_tofu_firm, 028_almond_whole, 029_hazelnut, 030_dark_chocolate, 064_burger_cheese, 066_pad_thai, 067_ramen, 069_caprese_salad, 072_omelette, 075_chicken_curry, 076_dumplings, 078_risotto_mushroom, 082_kebab, 083_donut_glazed, 084_tiramisu, 085_cheesecake_ny, 086_apple_pie, 090_smoothie_bowl, 092_sandwich_club, 093_bagel_lox, 096_tom_yum, 097_buddha_bowl, 099_kimchi_jjigae, 100_eggs_benedict, 032_nutella, 034_oreo, 035_kitkat, 037_twix, 042_mms_peanut, 053_heinz_ketchup
- 2026-04-28T05-42-11Z: 092_sandwich_club

### CALORIES_ANCHOR_250
- 2026-04-28T02-43-57Z: 025_tuna_canned_water, 068_borscht, 080_falafel, 098_mac_and_cheese, 039_milka
- 2026-04-28T05-42-11Z: 018_egg_boiled, 020_yogurt_greek_plain, 021_milk_whole, 024_salmon_atlantic_cooked, 066_pad_thai, 068_borscht, 074_tacos, 094_chia_pudding, 035_kitkat, 049_red_bull, 055_lipton_tea, 051_sprite_can
- 2026-04-28T05-46-10Z: 006_strawberry, 007_blueberry, 009_carrot_raw, 014_potato_baked, 015_bread_wheat_slice, 016_rice_white_cooked, 018_egg_boiled, 019_egg_raw_large, 021_milk_whole, 023_chicken_breast_cooked, 074_tacos, 082_kebab, 091_avocado_toast, 034_oreo, 047_quaker_oats, 048_haagen_dazs_vanilla, 053_heinz_ketchup, 051_sprite_can

### CALORIES_OVER_2X
- 2026-04-28T02-43-57Z: 001_apple_red, 002_banana, 003_orange_navel, 005_grape_red, 006_strawberry, 007_blueberry, 009_carrot_raw, 010_cucumber, 011_tomato_grape, 012_broccoli, 013_spinach_baby, 016_rice_white_cooked, 018_egg_boiled, 019_egg_raw_large, 021_milk_whole, 022_cheddar_cheese, 023_chicken_breast_cooked, 024_salmon_atlantic_cooked, 025_tuna_canned_water, 026_tofu_firm, 028_almond_whole, 029_hazelnut, 068_borscht, 096_tom_yum, 031_chobani_yogurt, 033_coca_cola_can, 034_oreo, 035_kitkat, 039_milka, 043_lay_classic, 047_quaker_oats, 048_haagen_dazs_vanilla, 049_red_bull, 052_fanta_orange, 053_heinz_ketchup
- 2026-04-28T05-42-11Z: 002_banana, 005_grape_red, 006_strawberry, 007_blueberry, 009_carrot_raw, 010_cucumber, 011_tomato_grape, 012_broccoli, 013_spinach_baby, 014_potato_baked, 015_bread_wheat_slice, 018_egg_boiled, 019_egg_raw_large, 020_yogurt_greek_plain, 023_chicken_breast_cooked, 025_tuna_canned_water, 026_tofu_firm, 061_pizza_margherita, 065_sushi_california_roll, 068_borscht, 031_chobani_yogurt, 035_kitkat, 036_snickers, 039_milka, 043_lay_classic, 046_kelloggs_corn_flakes, 047_quaker_oats, 049_red_bull, 053_heinz_ketchup, 054_hellmanns_mayo, 055_lipton_tea
- 2026-04-28T05-46-10Z: 001_apple_red, 002_banana, 003_orange_navel, 004_pear_bartlett, 005_grape_red, 006_strawberry, 007_blueberry, 009_carrot_raw, 010_cucumber, 011_tomato_grape, 012_broccoli, 015_bread_wheat_slice, 017_oatmeal_cooked, 018_egg_boiled, 020_yogurt_greek_plain, 022_cheddar_cheese, 023_chicken_breast_cooked, 025_tuna_canned_water, 026_tofu_firm, 068_borscht, 096_tom_yum, 031_chobani_yogurt, 037_twix, 039_milka, 043_lay_classic, 046_kelloggs_corn_flakes, 049_red_bull, 052_fanta_orange, 053_heinz_ketchup, 054_hellmanns_mayo, 055_lipton_tea

### CALORIES_UNDER_50pct
- 2026-04-28T02-43-57Z: 015_bread_wheat_slice, 041_ferrero_rocher
- 2026-04-28T05-42-11Z: 076_dumplings, 095_granola_bowl, 041_ferrero_rocher
- 2026-04-28T05-46-10Z: 062_spaghetti_carbonara, 066_pad_thai, 071_pancakes, 078_risotto_mushroom, 095_granola_bowl, 097_buddha_bowl, 100_eggs_benedict, 041_ferrero_rocher

### MACROS_ZERO
- 2026-04-28T02-43-57Z: 049_red_bull
- 2026-04-28T05-42-11Z: 051_sprite_can
- 2026-04-28T05-46-10Z: 036_snickers

### PORTION_FALLBACK
- 2026-04-28T02-43-57Z: 025_tuna_canned_water, 068_borscht, 080_falafel, 098_mac_and_cheese, 039_milka, 046_kelloggs_corn_flakes
- 2026-04-28T05-42-11Z: 007_blueberry, 018_egg_boiled, 020_yogurt_greek_plain, 021_milk_whole, 022_cheddar_cheese, 024_salmon_atlantic_cooked, 030_dark_chocolate, 066_pad_thai, 068_borscht, 074_tacos, 075_chicken_curry, 080_falafel, 083_donut_glazed, 087_chocolate_brownie, 089_croissant, 090_smoothie_bowl, 094_chia_pudding, 095_granola_bowl, 097_buddha_bowl, 031_chobani_yogurt, 034_oreo, 035_kitkat, 036_snickers, 048_haagen_dazs_vanilla, 049_red_bull, 050_pepsi_can, 054_hellmanns_mayo, 055_lipton_tea, 060_cadbury_dairy_milk, 051_sprite_can
- 2026-04-28T05-46-10Z: 002_banana, 006_strawberry, 007_blueberry, 009_carrot_raw, 014_potato_baked, 015_bread_wheat_slice, 016_rice_white_cooked, 018_egg_boiled, 019_egg_raw_large, 021_milk_whole, 022_cheddar_cheese, 023_chicken_breast_cooked, 025_tuna_canned_water, 030_dark_chocolate, 061_pizza_margherita, 066_pad_thai, 068_borscht, 069_caprese_salad, 071_pancakes, 074_tacos, 079_gnocchi, 082_kebab, 087_chocolate_brownie, 090_smoothie_bowl, 091_avocado_toast, 093_bagel_lox, 095_granola_bowl, 034_oreo, 036_snickers, 037_twix, 039_milka, 043_lay_classic, 047_quaker_oats, 048_haagen_dazs_vanilla, 053_heinz_ketchup, 054_hellmanns_mayo, 051_sprite_can
