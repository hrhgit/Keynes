"""Read rebalance inputs and calculate building recipe values."""

import glob
import json
import os
import re

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
PROJ = os.path.join(ROOT, "Project", "project-keynes")
GOODS_DIR = os.path.join(PROJ, "data", "goods")
BUILDINGS_DIR = os.path.join(PROJ, "data", "economy", "buildings")
CURATED_DIR = os.path.join(ROOT, "tools", "codegen", "economy_content", "buildings")
PLANS_DIR = os.path.join(PROJ, "data", "economy", "consumption_plans")
PROFESSIONS_DIR = os.path.join(PROJ, "data", "economy", "professions")
TECH_NETWORK = os.path.join(PROJ, "data", "technology", "technology_network.json")

Q16_ONE = 65536
GOODS_SCALE = 1000.0
MONEY_SCALE = 10000.0

ERA_IDS = [
    "stone", "agrarian", "kingdom", "empire", "exploration", "enlightenment",
    "steam", "electrical", "atomic", "information", "intelligent",
]

FOOD_EQUIVALENT_GOODS = {
    "prepared_staples", "bread", "grain", "gathered_plants", "potatoes",
    "game_meat", "meat", "fish", "canned_fish", "dairy_products",
    "vegetables", "processed_food", "wheat_grain", "rice_grain",
    "corn_grain", "livestock_products", "frozen_food", "edible_oil",
}

# ─── .tres helpers ────────────────────────────────────────────────────────────

def parse_str_field(txt: str, key: str, default: str = "") -> str:
    m = re.search(rf'^{re.escape(key)}\s*=\s*&?"([^"]*)"', txt, re.M)
    return m.group(1) if m else default


def parse_int_field(txt: str, key: str, default: int = 0) -> int:
    m = re.search(rf'^{re.escape(key)}\s*=\s*(-?[0-9]+)', txt, re.M)
    return int(m.group(1)) if m else default


def parse_str_array(txt: str, key: str) -> list:
    m = re.search(rf'^{re.escape(key)}\s*=\s*PackedStringArray\(([^)]*)\)', txt, re.M)
    if not m or not m.group(1).strip():
        return []
    return re.findall(r'"([^"]*)"', m.group(1))


def parse_num_array(txt: str, key: str) -> list:
    m = re.search(rf'^{re.escape(key)}\s*=\s*PackedInt(?:32|64)Array\(([^)]*)\)', txt, re.M)
    if not m or not m.group(1).strip():
        return []
    return [int(x.strip()) for x in m.group(1).split(",") if x.strip()]


def replace_num_array(txt: str, key: str, arr_type: str, values: list) -> str:
    formatted = f"{key} = {arr_type}(" + ", ".join(str(int(v)) for v in values) + ")"
    pat = rf'(?m)^{re.escape(key)}\s*=\s*{arr_type}\([^)]*\)\r?$'
    if re.search(pat, txt):
        return re.sub(pat, formatted, txt, count=1)
    # Insert right after input_quantities_per_day if adding input_required_q16
    if key == "input_required_q16":
        anchor = r'(?m)^input_quantities_per_day\s*=\s*PackedInt64Array\([^)]*\)\r?$'
        m = re.search(anchor, txt)
        if m:
            return txt[:m.end()] + "\n" + formatted + txt[m.end():]
    return txt.rstrip() + "\n" + formatted + "\n"


def load_goods():
    goods = {}
    for p in sorted(glob.glob(os.path.join(GOODS_DIR, "*.tres"))):
        txt = open(p, encoding="utf-8").read()
        gid = parse_str_field(txt, "id", os.path.splitext(os.path.basename(p))[0])
        price = parse_int_field(txt, "default_price", 10000) / MONEY_SCALE
        cats = parse_str_array(txt, "substitution_category_ids")
        cat = parse_str_field(txt, "category_id", "misc")
        if cat and cat not in cats:
            cats.append(cat)
        qual = parse_int_field(txt, "production_quality_level", 0)
        eff = parse_int_field(txt, "production_efficiency_q16", Q16_ONE) / float(Q16_ONE)
        goods[gid] = {
            "price": price,
            "categories": cats,
            "quality": qual,
            "efficiency": max(0.01, eff),
        }
    return goods


def load_tech_eras():
    data = json.load(open(TECH_NETWORK, encoding="utf-8"))
    return {n["id"]: n["era_id"] for n in data["nodes"]}


def load_professions():
    profs = {}
    for p in sorted(glob.glob(os.path.join(PROFESSIONS_DIR, "*.tres"))):
        txt = open(p, encoding="utf-8").read()
        pid = parse_str_field(txt, "id", os.path.splitext(os.path.basename(p))[0])
        plan = parse_str_field(txt, "consumption_plan_id", "agrarian_household")
        profs[pid] = plan
    return profs


def building_era_id(b, tech_eras):
    latest = -1
    latest_id = "stone"
    for tag in b["tech_tags"] + b["req_tech_tags"]:
        if tag in tech_eras:
            eid = tech_eras[tag]
            idx = ERA_IDS.index(eid) if eid in ERA_IDS else -1
            if idx > latest:
                latest = idx
                latest_id = eid
    return latest_id


def parse_building(path, tech_eras):
    txt = open(path, encoding="utf-8").read()
    bid = parse_str_field(txt, "id", os.path.splitext(os.path.basename(path))[0])
    b = {
        "path": path,
        "txt": txt,
        "id": bid,
        "kind": parse_str_field(txt, "building_kind", "industrial"),
        "sector": parse_str_field(txt, "economic_sector_id", ""),
        "state_role": parse_str_field(txt, "state_role", "none"),
        "chain": parse_str_field(txt, "industry_chain_id", ""),
        "family": parse_str_field(txt, "upgrade_family_id", ""),
        "tier": parse_int_field(txt, "upgrade_tier", 0),
        "owner_prof": parse_str_field(txt, "owner_profession_id", "farmer"),
        "owner_slots": max(1, parse_int_field(txt, "owner_slots_per_building", 1)),
        "emp_profs": parse_str_array(txt, "employee_profession_ids"),
        "emp_slots": parse_num_array(txt, "employee_slots_per_building"),
        "in_goods": parse_str_array(txt, "input_good_ids"),
        "in_qty": parse_num_array(txt, "input_quantities_per_day"),
        "in_req": parse_num_array(txt, "input_required_q16"),
        "in_cats": parse_str_array(txt, "input_category_ids"),
        "out_goods": parse_str_array(txt, "output_good_ids"),
        "out_qty": parse_num_array(txt, "output_quantities_per_day"),
        "res_ids": parse_str_array(txt, "resource_ids"),
        "res_qty": parse_num_array(txt, "resource_quantities_per_day"),
        "res_modes": parse_str_array(txt, "resource_interaction_modes"),
        "tech_tags": parse_str_array(txt, "technology_tags"),
        "req_tech_tags": parse_str_array(txt, "required_technology_tags"),
    }
    if not b["in_req"] and b["in_goods"]:
        b["in_req"] = [Q16_ONE] * len(b["in_goods"])
    b["era"] = building_era_id(b, tech_eras)
    b["era_idx"] = ERA_IDS.index(b["era"]) if b["era"] in ERA_IDS else 0
    b["labor"] = b["owner_slots"] + sum(b["emp_slots"])
    return b


def calc_values(b, goods):
    in_val = 0.0
    hard_in_val = 0.0
    for i, g in enumerate(b["in_goods"]):
        req = b["in_req"][i] if i < len(b["in_req"]) else Q16_ONE
        if req <= 0:
            continue
        p = goods.get(g, {}).get("price", 1.0)
        v = (b["in_qty"][i] / GOODS_SCALE) * p
        in_val += v
        if req >= Q16_ONE:
            hard_in_val += v
    out_val = 0.0
    food_out = 0.0
    for i, g in enumerate(b["out_goods"]):
        p = goods.get(g, {}).get("price", 1.0)
        out_val += (b["out_qty"][i] / GOODS_SCALE) * p
        if g in FOOD_EQUIVALENT_GOODS:
            food_out += b["out_qty"][i]
    food_in = 0.0
    for i, g in enumerate(b["in_goods"]):
        req = b["in_req"][i] if i < len(b["in_req"]) else Q16_ONE
        if req > 0 and g in FOOD_EQUIVALENT_GOODS:
            food_in += b["in_qty"][i]
    return in_val, hard_in_val, out_val, food_in, food_out
