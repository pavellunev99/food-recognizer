# Fixture licenses

All images are sourced under permissive Creative Commons licenses (CC0, CC-BY, CC-BY-SA) or public domain so FoodRecognizer (commercial product) can use them in its evaluation harness. Tier-1 and tier-3 images come from Wikimedia Commons; tier-2 images are taken from Open Food Facts product pages (their image data is contributed under CC-BY-SA 4.0).

Source helpers (Wave 6):

- `scripts/_eval/collect_fixtures.py` — Wikimedia Commons collector (used for tier-1, tier-3)
- `scripts/_eval/collect_tier2_off.py` — Open Food Facts text-search + image_front_url downloader (tier-2)
- `scripts/_eval/build_tier1_groundtruth.py` — tier-1 ground truth builder (offline USDA reference table; used because the public DEMO_KEY for FoodData Central was rate-limited at the time of harvesting)
- `scripts/_eval/build_tier3_groundtruth.py` — tier-3 ground truth builder (aggregate Nutritionix/USDA per-typical-serving table, ±25 % tolerance)

For tier-2 the canonical pipeline `scripts/ingest_groundtruth.py --tier2-input scripts/seeds/tier2_barcodes.txt` was rerun against the verified barcode list to produce `ground_truth.json`. Each tier-2 image is named after its `id` and originates from the OFF `image_front_url` (rescaled to 1024 px long-side, JPEG q=85) — credit the contributing OFF community per the entry below and follow OFF Terms of Use.

Re-running collection: re-execute the helper for the relevant tier (e.g. `python3 scripts/_eval/collect_fixtures.py --plan scripts/_eval/wave6_plan.tsv --only-id 001_apple_red --out-images tools/eval/Fixtures/images --licenses tools/eval/Fixtures/LICENSES.md`). Existing files are skipped unless `--skip-existing` is overridden manually.

| id | source | license | author / product |
|---|---|---|---|
| `001_apple_red` | [File:Liat Portal for Foodie Disorder - Red Apple (Whole Fruit).jpg](https://commons.wikimedia.org/wiki/File:Liat_Portal_for_Foodie_Disorder_-_Red_Apple_(Whole_Fruit).jpg) | CC BY-SA 4.0 | HaJunkiyada |
| `002_banana` | [File:Banana from Kerala.jpg](https://commons.wikimedia.org/wiki/File:Banana_from_Kerala.jpg) | CC BY-SA 2.0 | Ramesh NG |
| `003_orange_navel` | [File:Orange-Fruit-Pieces.jpg](https://commons.wikimedia.org/wiki/File:Orange-Fruit-Pieces.jpg) | CC BY-SA 3.0 | Evan-Amos |
| `004_pear_bartlett` | [File:Four pears.jpg](https://commons.wikimedia.org/wiki/File:Four_pears.jpg) | CC BY-SA 4.0 | Rhododendrites |
| `005_grape_red` | [File:2019-10-11 00 15 02 A bunch of Dayka Hackett Flavor Grown Fresh and Delicious Red Seedless Table Grapes in the Franklin Farm section of Oak Hill, Fairfax County, Virginia.jpg](https://commons.wikimedia.org/wiki/File:2019-10-11_00_15_02_A_bunch_of_Dayka_Hackett_Flavor_Grown_Fresh_and_Delicious_Red_Seedless_Table_Grapes_in_the_Franklin_Farm_section_of_Oak_Hill,_Fairfax_County,_Virginia.jpg) | CC BY-SA 4.0 | Famartin |
| `006_strawberry` | [File:Fresh strawberry pie.jpg](https://commons.wikimedia.org/wiki/File:Fresh_strawberry_pie.jpg) | CC BY-SA 2.0 | An Mai |
| `007_blueberry` | [File:Crepe with blueberries and fresh cream in it - 2.jpg](https://commons.wikimedia.org/wiki/File:Crepe_with_blueberries_and_fresh_cream_in_it_-_2.jpg) | CC BY-SA 4.0 | KKPCW |
| `008_avocado_hass` | [File:Avocado Hass - single and halved.jpg](https://commons.wikimedia.org/wiki/File:Avocado_Hass_-_single_and_halved.jpg) | CC BY-SA 4.0 | Ivar Leidus |
| `009_carrot_raw` | [File:Crudites Platter.JPG](https://commons.wikimedia.org/wiki/File:Crudites_Platter.JPG) | CC BY-SA 3.0 | Phoenixcatering |
| `010_cucumber` | [File:Crudites Platter.JPG](https://commons.wikimedia.org/wiki/File:Crudites_Platter.JPG) | CC BY-SA 3.0 | Phoenixcatering |
| `012_broccoli` | [File:Broccoli salad.jpg](https://commons.wikimedia.org/wiki/File:Broccoli_salad.jpg) | CC BY 3.0 | NorskPower |
| `013_spinach_baby` | [File:Palak Paneer (Pureed Spinach with cottage cheese) (1517531815).jpg](https://commons.wikimedia.org/wiki/File:Palak_Paneer_(Pureed_Spinach_with_cottage_cheese)_(1517531815).jpg) | CC BY 2.0 | rovingI |
| `014_potato_baked` | [File:2022-02-14 21 53 42 Baked potato skin from an Outback Steakhouse Bloomin' Fried Chicken meal in the Franklin Farm section of Oak Hill, Fairfax County, Virginia.jpg](https://commons.wikimedia.org/wiki/File:2022-02-14_21_53_42_Baked_potato_skin_from_an_Outback_Steakhouse_Bloomin%27_Fried_Chicken_meal_in_the_Franklin_Farm_section_of_Oak_Hill,_Fairfax_County,_Virginia.jpg) | CC BY-SA 4.0 | Famartin |
| `015_bread_wheat_slice` | [File:Vegan no-knead whole wheat bread loaf, sliced, September 2010.jpg](https://commons.wikimedia.org/wiki/File:Vegan_no-knead_whole_wheat_bread_loaf,_sliced,_September_2010.jpg) | CC BY-SA 2.0 | Veganbaking.net |
| `016_rice_white_cooked` | [File:A bowl of rice.jpg](https://commons.wikimedia.org/wiki/File:A_bowl_of_rice.jpg) | CC0 | Douglas Perkins |
| `017_oatmeal_cooked` | [File:Oatmeal porridge 1-minute with additional ingredients.jpg](https://commons.wikimedia.org/wiki/File:Oatmeal_porridge_1-minute_with_additional_ingredients.jpg) | CC BY-SA 4.0 | UserTwoSix |
| `018_egg_boiled` | [File:Frankfurter grüne Soße mit Eiern, Oberauroff.jpg](https://commons.wikimedia.org/wiki/File:Frankfurter_gr%C3%BCne_So%C3%9Fe_mit_Eiern,_Oberauroff.jpg) | CC0 | Gerda Arendt |
| `019_egg_raw_large` | [File:Chicken raw egg with broken shell.jpg](https://commons.wikimedia.org/wiki/File:Chicken_raw_egg_with_broken_shell.jpg) | CC BY-SA 4.0 | Sauvagette |
| `021_milk_whole` | [File:Buttermilk-(right)-and-Milk-(left).jpg](https://commons.wikimedia.org/wiki/File:Buttermilk-(right)-and-Milk-(left).jpg) | CC BY-SA 3.0 | Ukko-wc |
| `022_cheddar_cheese` | [File:White cheddar cheese sliced CNE.jpg](https://commons.wikimedia.org/wiki/File:White_cheddar_cheese_sliced_CNE.jpg) | CC BY-SA 4.0 | CNEcija12345 |
| `023_chicken_breast_cooked` | [File:Butterflied chicken breast.jpg](https://commons.wikimedia.org/wiki/File:Butterflied_chicken_breast.jpg) | CC BY-SA 4.0 | The Bushranger |
| `024_salmon_atlantic_cooked` | [File:Liat Portal for Foodie Disorder - Salmon Fillet with Green Chili and Garlic.jpg](https://commons.wikimedia.org/wiki/File:Liat_Portal_for_Foodie_Disorder_-_Salmon_Fillet_with_Green_Chili_and_Garlic.jpg) | CC BY-SA 4.0 | HaJunkiyada |
| `025_tuna_canned_water` | [File:Tuna can (2).jpg](https://commons.wikimedia.org/wiki/File:Tuna_can_(2).jpg) | CC BY-SA 3.0 | I would appreciate being notified if you use my work outside Wikimedia.
Do not copy this image illegally by ignoring the |
| `026_tofu_firm` | [File:Tuesday bento ^ ^ (recipe included) (2903007011).jpg](https://commons.wikimedia.org/wiki/File:Tuesday_bento_%5E_%5E_(recipe_included)_(2903007011).jpg) | CC BY 2.0 | Maria from McLean, Virginia, USA |
| `027_walnut_english` | [File:Walnut Shell Two halves.jpg](https://commons.wikimedia.org/wiki/File:Walnut_Shell_Two_halves.jpg) | CC BY-SA 4.0 | Isodomesticity |
| `028_almond_whole` | [File:Liat Portal for Foodie Disorder - Raw almonds in a bowl.jpg](https://commons.wikimedia.org/wiki/File:Liat_Portal_for_Foodie_Disorder_-_Raw_almonds_in_a_bowl.jpg) | CC BY-SA 4.0 | HaJunkiyada |
| `030_dark_chocolate` | [File:Bellarom dark chocolate.jpg](https://commons.wikimedia.org/wiki/File:Bellarom_dark_chocolate.jpg) | CC BY-SA 4.0 | Tiia Monto |
| `011_tomato_grape` | [File:Red peppers, Red cherry tomatoes, Food collage, Rostov-on-Don, Russia.jpg](https://commons.wikimedia.org/wiki/File:Red_peppers,_Red_cherry_tomatoes,_Food_collage,_Rostov-on-Don,_Russia.jpg) | CC BY 4.0 | Vyacheslav Argenberg |
| `020_yogurt_greek_plain` | [File:Lakh au yaourt.jpg](https://commons.wikimedia.org/wiki/File:Lakh_au_yaourt.jpg) | CC BY-SA 4.0 | Cheikh cherif |
| `029_hazelnut` | [File:Pecans, hazelnuts, walnuts, almonds, Brazil nuts on a table with logs 3.jpg](https://commons.wikimedia.org/wiki/File:Pecans,_hazelnuts,_walnuts,_almonds,_Brazil_nuts_on_a_table_with_logs_3.jpg) | CC0 | Baileynorwood |
| `061_pizza_margherita` | [File:Our Original Margherita Pizza - Large 8 slices. Made with fresh mozzarella San Marzano tomato sauce and topped with pecorino Romano and fresh basil - 9348564022.jpg](https://commons.wikimedia.org/wiki/File:Our_Original_Margherita_Pizza_-_Large_8_slices._Made_with_fresh_mozzarella_San_Marzano_tomato_sauce_and_topped_with_pecorino_Romano_and_fresh_basil_-_9348564022.jpg) | CC BY 2.0 | City Foodsters |
| `062_spaghetti_carbonara` | [File:Spaghetti alla Carbonara 2.jpg](https://commons.wikimedia.org/wiki/File:Spaghetti_alla_Carbonara_2.jpg) | CC BY-SA 4.0 | Amin |
| `063_caesar_salad` | [File:Chicken fettuccine alfredo.JPG](https://commons.wikimedia.org/wiki/File:Chicken_fettuccine_alfredo.JPG) | CC BY-SA 4.0 | Dllu |
| `065_sushi_california_roll` | [File:California Rolls.JPG](https://commons.wikimedia.org/wiki/File:California_Rolls.JPG) | CC BY-SA 3.0 | Mk2010 |
| `066_pad_thai` | [File:Pad Thai Noodles - Little Thai, Brighton 2024-03-21.jpg](https://commons.wikimedia.org/wiki/File:Pad_Thai_Noodles_-_Little_Thai,_Brighton_2024-03-21.jpg) | CC0 | Andy Li |
| `067_ramen` | [File:Onomichi ramen and jiaozi by The Other View in Onomichi.jpg](https://commons.wikimedia.org/wiki/File:Onomichi_ramen_and_jiaozi_by_The_Other_View_in_Onomichi.jpg) | CC BY-SA 2.0 | The Other View from Onomichi, Hiroshima |
| `068_borscht` | [File:A bowl of Borscht soup, made from beets - 20130420-051-of-365 (8666575157).jpg](https://commons.wikimedia.org/wiki/File:A_bowl_of_Borscht_soup,_made_from_beets_-_20130420-051-of-365_(8666575157).jpg) | CC BY 2.0 | Calgary Reviews from Calgary, Canada |
| `069_caprese_salad` | [File:Caprese salad in hk.jpg](https://commons.wikimedia.org/wiki/File:Caprese_salad_in_hk.jpg) | CC BY-SA 4.0 | Peachyeung316 |
| `070_french_fries` | [File:Hesburger French fries on a plate.jpg](https://commons.wikimedia.org/wiki/File:Hesburger_French_fries_on_a_plate.jpg) | CC BY-SA 4.0 | JIP |
| `071_pancakes` | [File:2019-04-21 11 41 12 A stack of blueberry pancakes with syrup in the Franklin Farm section of Oak Hill, Fairfax County, Virginia.jpg](https://commons.wikimedia.org/wiki/File:2019-04-21_11_41_12_A_stack_of_blueberry_pancakes_with_syrup_in_the_Franklin_Farm_section_of_Oak_Hill,_Fairfax_County,_Virginia.jpg) | CC BY-SA 4.0 | Famartin |
| `072_omelette` | [File:Omelette on a plate.jpg](https://commons.wikimedia.org/wiki/File:Omelette_on_a_plate.jpg) | CC BY 2.0 | Infrogmation of New Orleans |
| `074_tacos` | [File:Tacos rojos de deshebrada con cueritos de cerdo.jpg](https://commons.wikimedia.org/wiki/File:Tacos_rojos_de_deshebrada_con_cueritos_de_cerdo.jpg) | CC BY-SA 4.0 | 1000b |
| `075_chicken_curry` | [File:Friday dinner - Curry chicken with bell peppers and rice - 02.jpg](https://commons.wikimedia.org/wiki/File:Friday_dinner_-_Curry_chicken_with_bell_peppers_and_rice_-_02.jpg) | CC BY-SA 4.0 | Infrogmation of New Orleans |
| `076_dumplings` | [File:Steamed pork spareribs Douchi 豆豉 dumplings Chinese New Year 農曆新年 food 29 January 2025 蛇 Philippines7.jpg](https://commons.wikimedia.org/wiki/File:Steamed_pork_spareribs_Douchi_%E8%B1%86%E8%B1%89_dumplings_Chinese_New_Year_%E8%BE%B2%E6%9B%86%E6%96%B0%E5%B9%B4_food_29_January_2025_%E8%9B%87_Philippines7.jpg) | CC BY-SA 4.0 | Unknown |
| `077_paella` | [File:Paella Marinera 1.jpg](https://commons.wikimedia.org/wiki/File:Paella_Marinera_1.jpg) | CC BY-SA 4.0 | PapiPijuan |
| `078_risotto_mushroom` | [File:뽁식당 머쉬룸 크림 리조또 2.jpg](https://commons.wikimedia.org/wiki/File:%EB%BD%81%EC%8B%9D%EB%8B%B9_%EB%A8%B8%EC%89%AC%EB%A3%B8_%ED%81%AC%EB%A6%BC_%EB%A6%AC%EC%A1%B0%EB%98%90_2.jpg) | CC BY 2.0 kr | 사랑스런은탱님 |
| `079_gnocchi` | [File:Sweet potato gnocchi (10693912404).jpg](https://commons.wikimedia.org/wiki/File:Sweet_potato_gnocchi_(10693912404).jpg) | CC BY 2.0 | Ruth Hartnup from Vancouver, Canada |
| `080_falafel` | [File:Mixed Plate (3186676853).jpg](https://commons.wikimedia.org/wiki/File:Mixed_Plate_(3186676853).jpg) | CC BY-SA 2.0 | Charles Haynes from Hobart, Australia |
| `081_pho` | [File:Pho Vietnamese noodle soup in Ho Chi Minh City, Vietnam.jpg](https://commons.wikimedia.org/wiki/File:Pho_Vietnamese_noodle_soup_in_Ho_Chi_Minh_City,_Vietnam.jpg) | CC BY 4.0 | Vyacheslav Argenberg |
| `083_donut_glazed` | [File:Round Rock Glazed Donuts.jpg](https://commons.wikimedia.org/wiki/File:Round_Rock_Glazed_Donuts.jpg) | CC BY 4.0 | TerraFrost |
| `084_tiramisu` | [File:Tiramisu in Ankara.jpg](https://commons.wikimedia.org/wiki/File:Tiramisu_in_Ankara.jpg) | CC BY-SA 4.0 | E4024 |
| `085_cheesecake_ny` | [File:New York cheesecake 2.jpg](https://commons.wikimedia.org/wiki/File:New_York_cheesecake_2.jpg) | CC BY-SA 4.0 | EvanProdromou |
| `086_apple_pie` | [File:Apple cake with vanilla ice cream 2.jpg](https://commons.wikimedia.org/wiki/File:Apple_cake_with_vanilla_ice_cream_2.jpg) | CC0 | W.carter |
| `087_chocolate_brownie` | [File:Chocolate Brownie Donut - Down to Earth Coffee 2025-04-25.jpg](https://commons.wikimedia.org/wiki/File:Chocolate_Brownie_Donut_-_Down_to_Earth_Coffee_2025-04-25.jpg) | CC0 | Andy Li |
| `088_macarons` | [File:Drawing, Design for a Painted Porcelain Plate, Les Oranges (Oranges) from Service des Objets de Dessert (Dessert Service), 1819–20 (CH 18632313).jpg](https://commons.wikimedia.org/wiki/File:Drawing,_Design_for_a_Painted_Porcelain_Plate,_Les_Oranges_(Oranges)_from_Service_des_Objets_de_Dessert_(Dessert_Service),_1819%E2%80%9320_(CH_18632313).jpg) | Public domain | Unknown artistUnknown artist |
| `089_croissant` | [File:Recipe croissant hk DIY.jpg](https://commons.wikimedia.org/wiki/File:Recipe_croissant_hk_DIY.jpg) | CC BY-SA 4.0 | SUBARU sti 2020 |
| `090_smoothie_bowl` | [File:Açai.jpg](https://commons.wikimedia.org/wiki/File:A%C3%A7ai.jpg) | CC BY-SA 2.0 | Jorge Láscar from Bogotá, Colombia |
| `091_avocado_toast` | [File:Avocado & Smoked Salmon On Sourdough Toast - Amo 2026-02-04.jpg](https://commons.wikimedia.org/wiki/File:Avocado_%26_Smoked_Salmon_On_Sourdough_Toast_-_Amo_2026-02-04.jpg) | CC0 | Andy Li |
| `092_sandwich_club` | [File:Club Sandwich Toast and Tea.jpg](https://commons.wikimedia.org/wiki/File:Club_Sandwich_Toast_and_Tea.jpg) | CC BY-SA 4.0 | Mayejiro |
| `093_bagel_lox` | [File:Lox Bagel Sandwich with Cream Cheese Schmear Onion Tomato.jpg](https://commons.wikimedia.org/wiki/File:Lox_Bagel_Sandwich_with_Cream_Cheese_Schmear_Onion_Tomato.jpg) | CC0 | LinguisticsGirl.Librarian |
| `094_chia_pudding` | [File:Chia pudding with coconut milk and berries (KETO, LCHF, Low Carb, Gluten free, FIT) - 52774529156.jpg](https://commons.wikimedia.org/wiki/File:Chia_pudding_with_coconut_milk_and_berries_(KETO,_LCHF,_Low_Carb,_Gluten_free,_FIT)_-_52774529156.jpg) | CC BY 2.0 | epodrez |
| `095_granola_bowl` | [File:Yogurt, fruit, granola bowl (34999358091).jpg](https://commons.wikimedia.org/wiki/File:Yogurt,_fruit,_granola_bowl_(34999358091).jpg) | CC BY 2.0 | T.Tseng |
| `096_tom_yum` | [File:Panangbeefcurry.jpg](https://commons.wikimedia.org/wiki/File:Panangbeefcurry.jpg) | CC BY-SA 2.0 | Alpha from Melbourne, Australia |
| `098_mac_and_cheese` | [File:Mac and cheese - Morelli Zorelli 2024-08-29.jpg](https://commons.wikimedia.org/wiki/File:Mac_and_cheese_-_Morelli_Zorelli_2024-08-29.jpg) | CC0 | Andy Li |
| `099_kimchi_jjigae` | [File:Korean.cuisine-Kimchi jjigae-01.jpg](https://commons.wikimedia.org/wiki/File:Korean.cuisine-Kimchi_jjigae-01.jpg) | CC BY-SA 2.0 | by avlxyz |
| `100_eggs_benedict` | [File:Eggs Benedict with green Hollandaise sauce, smoked pastrami, and hash browns - Auckland, New Zealand.jpg](https://commons.wikimedia.org/wiki/File:Eggs_Benedict_with_green_Hollandaise_sauce,_smoked_pastrami,_and_hash_browns_-_Auckland,_New_Zealand.jpg) | CC0 | Daderot |
| `064_burger_cheese` | [File:Cheeseburger.jpg](https://commons.wikimedia.org/wiki/File:Cheeseburger.jpg) | Public domain | Renee Comet (photographer) |
| `073_lasagna` | [File:Vegetable lasagne, Hahn.jpg](https://commons.wikimedia.org/wiki/File:Vegetable_lasagne,_Hahn.jpg) | CC0 | Gerda Arendt |
| `082_kebab` | [File:Döner Kebab, Berlin, 2010 (01).jpg](https://commons.wikimedia.org/wiki/File:D%C3%B6ner_Kebab,_Berlin,_2010_(01).jpg) | CC BY 2.0 | AleGranholm |
| `097_buddha_bowl` | [File:Quinoa grain bowl brunch at Caravan Bankside, London, UK (36736487911).jpg](https://commons.wikimedia.org/wiki/File:Quinoa_grain_bowl_brunch_at_Caravan_Bankside,_London,_UK_(36736487911).jpg) | CC BY 2.0 | Bex Walton from London, England |
| `031_chobani_yogurt` | [OFF product 0894700010151](https://world.openfoodfacts.org/product/0894700010151) | CC-BY-SA 4.0 (Open Food Facts) | Greek Yogurt Pomegranate |
| `032_nutella` | [OFF product 3017624010701](https://world.openfoodfacts.org/product/3017624010701) | CC-BY-SA 4.0 (Open Food Facts) | Nutella |
| `033_coca_cola_can` | [OFF product 5449000000996](https://world.openfoodfacts.org/product/5449000000996) | CC-BY-SA 4.0 (Open Food Facts) | Original Taste |
| `034_oreo` | [OFF product 7622210449283](https://world.openfoodfacts.org/product/7622210449283) | CC-BY-SA 4.0 (Open Food Facts) | Prince Goût Chocolat au Blé Complet |
| `035_kitkat` | [OFF product 8901058005233](https://world.openfoodfacts.org/product/8901058005233) | CC-BY-SA 4.0 (Open Food Facts) | Kitkat mini chocolate coated wafer |
| `036_snickers` | [OFF product 5000159541374](https://world.openfoodfacts.org/product/5000159541374) | CC-BY-SA 4.0 (Open Food Facts) | Snickers Ice Cream New Recipe |
| `037_twix` | [OFF product 5900951313592](https://world.openfoodfacts.org/product/5900951313592) | CC-BY-SA 4.0 (Open Food Facts) | Twix |
| `039_milka` | [OFF product 7622300631574](https://world.openfoodfacts.org/product/7622300631574) | CC-BY-SA 4.0 (Open Food Facts) | Chocolate con leche Oreo |
| `041_ferrero_rocher` | [OFF product 8000500273296](https://world.openfoodfacts.org/product/8000500273296) | CC-BY-SA 4.0 (Open Food Facts) | Ferrero Rocher |
| `042_mms_peanut` | [OFF product 5000159492737](https://world.openfoodfacts.org/product/5000159492737) | CC-BY-SA 4.0 (Open Food Facts) | M&M's peanut |
| `043_lay_classic` | [OFF product 0028400200592](https://world.openfoodfacts.org/product/0028400200592) | CC-BY-SA 4.0 (Open Food Facts) | Classic Lightly Salted Potato Chips |
| `044_pringles_original` | [OFF product 5053990156009](https://world.openfoodfacts.org/product/5053990156009) | CC-BY-SA 4.0 (Open Food Facts) | Pringles Original |
| `046_kelloggs_corn_flakes` | [OFF product 3159470000120](https://world.openfoodfacts.org/product/3159470000120) | CC-BY-SA 4.0 (Open Food Facts) | CORN FLAKES |
| `047_quaker_oats` | [OFF product 0030000010402](https://world.openfoodfacts.org/product/0030000010402) | CC-BY-SA 4.0 (Open Food Facts) | OLD FASHIONED 100% WHOLE GRAIN ROLLED OATS |
| `048_haagen_dazs_vanilla` | [OFF product 3415581101928](https://world.openfoodfacts.org/product/3415581101928) | CC-BY-SA 4.0 (Open Food Facts) | Vanilla Ice Cream |
| `049_red_bull` | [OFF product 9002490100070](https://world.openfoodfacts.org/product/9002490100070) | CC-BY-SA 4.0 (Open Food Facts) | Energy Drink |
| `050_pepsi_can` | [OFF product 0012000030284](https://world.openfoodfacts.org/product/0012000030284) | CC-BY-SA 4.0 (Open Food Facts) | Pepsi Cola 16 Fluid Ounce Aluminum Can |
| `051_sprite_can` | [OFF product 8901764031250](https://world.openfoodfacts.org/product/8901764031250) | CC-BY-SA 4.0 (Open Food Facts) | Sprite Lemon drink 300ml can |
| `052_fanta_orange` | [OFF product 5449000052926](https://world.openfoodfacts.org/product/5449000052926) | CC-BY-SA 4.0 (Open Food Facts) | Fanta orange 1.5l |
| `053_heinz_ketchup` | [OFF product 8715700407760](https://world.openfoodfacts.org/product/8715700407760) | CC-BY-SA 4.0 (Open Food Facts) | Tomato Ketchup BIO |
| `054_hellmanns_mayo` | [OFF product 5000184321064](https://world.openfoodfacts.org/product/5000184321064) | CC-BY-SA 4.0 (Open Food Facts) | REAL MAYONNAISE |
| `055_lipton_tea` | [OFF product 8711200461646](https://world.openfoodfacts.org/product/8711200461646) | CC-BY-SA 4.0 (Open Food Facts) | Flavoured black tea, 50 tea bags |
| `060_cadbury_dairy_milk` | [OFF product 7622202334009](https://world.openfoodfacts.org/product/7622202334009) | CC-BY-SA 4.0 (Open Food Facts) | dairy milk |
