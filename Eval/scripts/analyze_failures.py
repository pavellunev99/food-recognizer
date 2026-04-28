#!/usr/bin/env python3
"""Categorize VLM eval failures into buckets.

Usage:
    python3 analyze_failures.py <run.json> [<run2.json> ...]

Reads run JSON(s) produced by NutriLensEval and prints per-bucket counts plus
fixture id lists. Optional --markdown flag dumps a markdown table.

Buckets:
    STRUCTURAL_NIL              parsed is null
    STRUCTURAL_MISSING_FIELDS   parsed exists but missing one of {calories,protein,carbs,fats,portionGrams}
    NAME_ASIAN                  foodName contains CJK chars
    NAME_GIBBERISH              kyrillic foodName not matching any alias root, len>5
    NAME_HALLUCINATED_DISH      tier1 with composite-dish foodName matching a few-shot example
    CALORIES_ANCHOR_413         calories == 413
    CALORIES_ANCHOR_250         portionGrams == 250
    CALORIES_OVER_2X            calories > 2 * truth
    CALORIES_UNDER_50pct        calories < 0.5 * truth
    MACROS_ZERO                 protein==0 and carbs==0 and fats==0 and calories>30
    PORTION_FALLBACK            portionGrams in {100,150,200,250,300,350,400,450,500}
"""
from __future__ import annotations

import argparse
import json
import re
import sys
from collections import OrderedDict
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
GT_PATH = ROOT / "Fixtures" / "ground_truth.json"

CJK_RE = re.compile(r"[一-鿿぀-ゟ゠-ヿ가-힯]")
CYRILLIC_RE = re.compile(r"[Ѐ-ӿ]")
LATIN_RE = re.compile(r"[A-Za-z]")

REQUIRED_FIELDS = ["calories", "protein", "carbs", "fats", "portionGrams"]
PORTION_FALLBACKS = {100, 150, 200, 250, 300, 350, 400, 450, 500}

# Few-shot dish names from v1_production prompts (these become anchor candidates).
FEW_SHOT_DISHES = {
    "куриная грудка с рисом",
    "греческий салат",
    "паста болоньезе",
    "овсянка с ягодами",
}

BUCKETS = [
    "STRUCTURAL_NIL",
    "STRUCTURAL_MISSING_FIELDS",
    "NAME_ASIAN",
    "NAME_GIBBERISH",
    "NAME_HALLUCINATED_DISH",
    "CALORIES_ANCHOR_413",
    "CALORIES_ANCHOR_250",
    "CALORIES_OVER_2X",
    "CALORIES_UNDER_50pct",
    "MACROS_ZERO",
    "PORTION_FALLBACK",
]


def normalize(s: str) -> str:
    return re.sub(r"[^a-zа-я0-9]+", "", (s or "").lower(), flags=re.IGNORECASE)


def gibberish_kyrillic(name: str, aliases: list[str]) -> bool:
    """Heuristic for invented Russian-looking words.

    Triggers when foodName is cyrillic (no latin), >5 chars, and shares no
    4-letter substring with any normalized alias.
    """
    if not name:
        return False
    if LATIN_RE.search(name):  # mixed alphabet → not pure gibberish
        return False
    if not CYRILLIC_RE.search(name):
        return False
    norm = normalize(name)
    if len(norm) <= 5:
        return False
    alias_norm = [normalize(a) for a in aliases]
    for an in alias_norm:
        if not an:
            continue
        # exact / substring overlap
        if an in norm or norm in an:
            return False
        # 4-char overlap
        if len(an) >= 4:
            for i in range(len(an) - 3):
                if an[i:i+4] in norm:
                    return False
    return True


def hallucinated_dish(food_name: str, tier: int) -> bool:
    if tier != 1:
        return False
    norm = normalize(food_name)
    for d in FEW_SHOT_DISHES:
        if normalize(d) == norm:
            return True
    # Also catch generic single-word dish hallucinations on tier1 single ingredient
    bad_dishes = {"салат", "борщ", "суп", "паста", "плов", "пицца", "рагу", "омлет", "ризотто", "булгур"}
    if norm in bad_dishes:
        return True
    return False


def categorize(record: dict, gt_item: dict) -> set[str]:
    buckets: set[str] = set()
    parsed = record.get("parsed")
    tier = gt_item.get("tier", 0)
    aliases = gt_item.get("nameAliases", [])

    if parsed is None:
        # noFood vs nil — both produce parsed=null in our pipeline; treat as STRUCTURAL_NIL
        buckets.add("STRUCTURAL_NIL")
        return buckets

    # Missing required fields
    missing = [f for f in REQUIRED_FIELDS if f not in parsed or parsed.get(f) is None]
    if missing:
        buckets.add("STRUCTURAL_MISSING_FIELDS")

    name = parsed.get("foodName") or ""
    if CJK_RE.search(name):
        buckets.add("NAME_ASIAN")
    if gibberish_kyrillic(name, aliases):
        buckets.add("NAME_GIBBERISH")
    if hallucinated_dish(name, tier):
        buckets.add("NAME_HALLUCINATED_DISH")

    cal = parsed.get("calories")
    pg = parsed.get("portionGrams")
    p = parsed.get("protein")
    c = parsed.get("carbs")
    f = parsed.get("fats")

    if isinstance(cal, (int, float)) and cal == 413:
        buckets.add("CALORIES_ANCHOR_413")
    if isinstance(pg, (int, float)) and pg == 250:
        buckets.add("CALORIES_ANCHOR_250")

    truth_cal = gt_item.get("calories")
    if isinstance(cal, (int, float)) and isinstance(truth_cal, (int, float)) and truth_cal > 0:
        if cal > 2 * truth_cal:
            buckets.add("CALORIES_OVER_2X")
        if cal < 0.5 * truth_cal:
            buckets.add("CALORIES_UNDER_50pct")

    if (
        isinstance(p, (int, float)) and p == 0 and
        isinstance(c, (int, float)) and c == 0 and
        isinstance(f, (int, float)) and f == 0 and
        isinstance(cal, (int, float)) and cal > 30
    ):
        buckets.add("MACROS_ZERO")

    if isinstance(pg, (int, float)) and int(pg) in PORTION_FALLBACKS:
        buckets.add("PORTION_FALLBACK")

    return buckets


def analyze_run(run_path: Path, gt_by_id: dict) -> dict:
    with run_path.open() as f:
        data = json.load(f)
    records = data.get("records", [])
    summary = data.get("summary", {})
    bucket_ids: dict[str, list[str]] = {b: [] for b in BUCKETS}
    record_buckets: dict[str, set[str]] = {}
    for rec in records:
        rid = rec.get("id")
        gt = gt_by_id.get(rid, {})
        b = categorize(rec, gt)
        record_buckets[rid] = b
        for bucket in b:
            bucket_ids[bucket].append(rid)
    return {
        "run_id": summary.get("runId") or run_path.stem,
        "prompt": summary.get("promptVersion"),
        "model": summary.get("modelName"),
        "mean": summary.get("mean"),
        "p50": summary.get("p50"),
        "p90": summary.get("p90"),
        "pass07": summary.get("passRateAt07"),
        "perTier": summary.get("perTier"),
        "buckets": bucket_ids,
        "record_buckets": record_buckets,
        "count": len(records),
    }


def fmt_table(analyses: list[dict]) -> str:
    """Markdown bucket table."""
    headers = ["Bucket"] + [a["run_id"][-25:] for a in analyses]
    lines = ["| " + " | ".join(headers) + " |",
             "|" + "|".join(["---"] * len(headers)) + "|"]
    for b in BUCKETS:
        row = [b]
        for a in analyses:
            cnt = len(a["buckets"][b])
            row.append(str(cnt))
        lines.append("| " + " | ".join(row) + " |")
    return "\n".join(lines)


def fmt_summary(a: dict) -> str:
    pt = a.get("perTier") or {}
    parts = []
    for tk in sorted(pt.keys()):
        t = pt[tk]
        parts.append(f"T{tk}={t.get('mean', 0):.3f}")
    pass07 = a.get("pass07") or 0
    return f"mean={a.get('mean', 0):.3f} pass@0.7={pass07:.3f} {' '.join(parts)}"


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("runs", nargs="+", help="Run JSON files")
    ap.add_argument("--markdown", action="store_true")
    ap.add_argument("--list-ids", action="store_true",
                    help="Print id lists per bucket")
    args = ap.parse_args()

    with GT_PATH.open() as f:
        gt = json.load(f)
    gt_by_id = {item["id"]: item for item in gt["items"]}

    analyses = [analyze_run(Path(p), gt_by_id) for p in args.runs]

    if args.markdown:
        print("# Failure analysis\n")
        for a in analyses:
            print(f"- **{a['run_id']}** ({a['prompt']}, {a['model']}): {fmt_summary(a)}")
        print()
        print(fmt_table(analyses))
        if args.list_ids:
            for b in BUCKETS:
                print(f"\n### {b}")
                for a in analyses:
                    ids = a["buckets"][b]
                    if ids:
                        print(f"- {a['run_id']}: {', '.join(ids)}")
    else:
        for a in analyses:
            print(f"\n== {a['run_id']} ({a['prompt']}, {a['model']}) ==")
            print(fmt_summary(a))
            for b in BUCKETS:
                ids = a["buckets"][b]
                print(f"  {b:30s} {len(ids):3d}  {', '.join(ids[:6])}{'...' if len(ids) > 6 else ''}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
