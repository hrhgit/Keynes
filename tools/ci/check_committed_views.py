#!/usr/bin/env python3
"""Guard the reviewed committed read boundaries."""
from pathlib import Path
import argparse
import re
from check_cpp_deps import code_only
from cpp_source import read_cpp_source
ROOT = Path(__file__).resolve().parents[2]

def borrowed_owner(code, owner, owner_type, allow_hash=False):
    # Hash-only diagnostics outside the migrated Effect consumer remain legal.
    if allow_hash:
        code = re.sub(rf"{owner}\s*\.\s*snapshot\s*\(\s*\)\s*\.\s*deterministic_state_hash\b", "", code)
    return bool(re.search(rf"\b{owner}\s*\.\s*(?:snapshot|planned_snapshot)\b|"
                          rf"\b{owner}\b(?!\s*\.)|"
                          rf"\b{owner_type}\s*::\s*(?:snapshot|planned_snapshot)\b", code))

def consumer_body(code, name):
    at = code.find(name + "(")
    if at < 0: return ""
    start = code.find("{", at)
    depth = 1
    end = start + 1
    while end < len(code) and depth:
        depth += (code[end] == "{") - (code[end] == "}")
        end += 1
    return code[start:end]

def published_view_violations(opinion, annual):
    errors = []
    for code, label, factory, cursor, forbidden in [
        (opinion, "Economy opinion -> Ideology", "copy_economy_opinion_view", "_opinion_view_version",
         r"_ideology_opinion_snapshot|_ideology_reference_opinions|pin_ideology_reference_opinion|country_class_opinion_snapshot"),
        (annual, "Ideology -> annual report", "copy_annual_ideology_view", "_annual_ideology_view_version",
         r"ideology_pod_snapshot|_ideology_snapshot|_ideology_pod_authority")]:
        if re.search(r"\b(?:" + forbidden + r")\b", code):
            errors.append(label + " bypasses owned committed view")
        if factory not in code or not re.search(r"assert\s*\([^;]*\.observe\s*\(\s*" + cursor + r"\s*\)", code):
            errors.append(label + " missing generation/day assertion")
    return errors

def country_ai_violations(code):
    errors = []
    if re.search(r"\bcountry_ai_digest\b", code):
        errors.append("Country AI bypasses Economy committed view")
    if "copy_country_ai_economy_view" not in code or "economy_view.observe(_country_ai_economy_view_version)" not in code:
        errors.append("Country AI missing generation/day assertion")
    return errors

def annual_country_violations(code):
    errors=[]
    if re.search(r"\b(?:country_asset_snapshot|_country_snapshot|_country_pod_authority)\b", code): errors.append("annual report bypasses Country view")
    if "copy_annual_country_view" not in code or "country_view.observe(_annual_country_view_version)" not in code: errors.append("annual Country view missing assertion")
    return errors

def lineage_opinion_violations(code):
    errors = []
    if re.search(r"\b(?:country_class_opinion_snapshot|_class_opinion_buffers|_class_opinion_committed_buffer)\b", code):
        errors.append("Family metrics bypass Economy committed opinion")
    if "copy_lineage_opinion_view" not in code or "view.observe(_lineage_opinion_view_version)" not in code:
        errors.append("Family opinion missing generation/day assertion")
    return errors

def tax_display_violations(bindings, packing):
    errors = []
    live = r"\b(?:_modifier_runtime|_economy_modifier_view|country_asset_snapshot|get_runtime_modifier_snapshot)\b"
    for binding, query, argument in [
            ("get_country_tax_policy_snapshot", "tax_policy_snapshot", "handle"),
            ("get_country_cell_tax_policy_snapshot", "cell_tax_policy_snapshot", "cell_idx")]:
        route = consumer_body(bindings, "DCWorldExt::" + binding)
        owned = consumer_body(route, "uses_published_modifier_tax")
        if (re.search(live + r"|\bcountry_query_runtime(?:_for_tax)?\s*\(", route.partition("uses_published_modifier_tax")[0])
                or not re.search(r"if\s*\(\s*uses_published_modifier_tax\s*\(\s*\)\s*\)", route)
                or not re.search(r"published_tax_country\s*\(", owned)
                or not re.search(r"published_tax_values\s*\(\s*\*\s*_modifier_read_view\s*,\s*_frozen_tax_view", owned)
                or not re.search(rf"return\s+\w+\s*->\s*{query}\s*\(\s*{argument}\s*,\s*&\s*\w+\s*\)", owned)
                or re.search(live + r"|\bcountry_query_runtime(?:_for_tax)?\s*\(", owned)):
            errors.append(binding + " bypasses the received tax frame")
        rows = consumer_body(packing, "NativeCountryRuntime::" + query)
        if re.search(live, rows) or not re.search(r"effective_tax_for_display\s*\(\s*read\s*,", rows):
            errors.append(query + " bypasses the selected tax source")

    panel = consumer_body(bindings, "DCWorldExt::get_country_ui_snapshot")
    if re.search(live + r"|\btax_policy_snapshot\b", panel) or not re.search(r"\bget_country_tax_policy_snapshot\s*\(", panel):
        errors.append("country panel bypasses the national tax query")
    frame_source = re.search(r"(\w+)\s*=\s*published_fiscal\s*\?\s*country_query_runtime_from_snapshot"
                             r"\s*\(\s*_display_country_snapshot\s*\)", panel)
    fields = ("country_summary", "generation", "completed_technology_ids", "treasury_snapshot",
              "research_snapshot", "research_signal_snapshot", "political_regime_snapshot")
    if (not frame_source or any(not re.search(rf"\b{frame_source[1]}\s*->\s*{field}\s*\(", panel) for field in fields)
            or not re.search(rf"\bsummary\s*=\s*{frame_source[1]}\s*->\s*country_summary\s*\(", panel)
            or not re.search(r"published_fiscal\s*=\s*fiscal\s*&&\s*uses_published_modifier_tax\s*\(", panel)
            or not re.search(r"published_fiscal\s*\?\s*Variant\s*\(\s*_display_country_day\s*\)", panel)):
        errors.append("fiscal panel Country data must come from the received day tail")
    replica = consumer_body(bindings, "DCWorldExt::country_query_runtime_from_snapshot")
    if (re.search(live + r"|\b(?:_runtime_host|_frozen_tax_view|country_query_runtime|published_tax_country)\b", replica)
            or not re.search(r"apply_committed_read_snapshot\s*\(\s*\*\s*snapshot\s*\)", replica)):
        errors.append("Country replica must install the selected immutable snapshot")
    country = consumer_body(bindings, "DCWorldExt::published_tax_country")
    if re.search(live, country) or "_modifier_read_country" not in country or "_frozen_tax_view" not in country:
        errors.append("tax policy must use the received Country snapshot")
    sources = consumer_body(bindings, "published_tax_values")
    if re.search(live, sources) or "frozen->lookup" not in sources or "modifier.effective_value" not in sources:
        errors.append("tax values must use the fiscal freeze or opening Modifier view")
    values = consumer_body(packing, "NativeCountryRuntime::effective_tax_for_display")
    frozen = re.search(r"if\s*\(\s*read\s*&&\s*read->frozen_rate\s*\)\s*return\s+read->frozen_rate\s*\(", values)
    opening = re.search(r"if\s*\(\s*read\s*\)\s*\{([^{}]*)\}", values)
    if (not frozen or re.search(live, values[:frozen.start()]) or not opening
            or re.search(live, opening[1]) or "read->modifier_value" not in opening[1]):
        errors.append("published tax rows must finish without consulting the local Modifier")
    unowned = consumer_body(bindings, "DCWorldExt::country_query_runtime_for_tax")
    if not re.search(r"RuntimeSimulationMode::OFF\s*\)\s*return\s+country_runtime_from\s*\(\s*_country_runtime\s*\)", unowned):
        errors.append("explicit synchronous tax queries must read the local Country owner")
    return errors

def violations(root):
    path = root / "gdext/src/native_simulation_stage_economy.cpp"
    code = code_only(read_cpp_source(path))
    errors = []
    if re.search(r"\b(?:store|planned_store)\s*\(\s*\)|RuntimeClimateAuthority\s*::\s*(?:store|planned_store)|\b(?:snapshot|snapshot_into)\s*\(", code):
        errors.append("Economy stage bypasses Climate committed view")
    if not re.search(r"assert\s*\(\s*_climate_authority\.observe_economy_view\s*\(climate_view\)\s*\)", code):
        errors.append("missing consumer generation/day assertion")
    if "copy_committed_view" not in code:
        errors.append("missing owned committed projection")
    event_code = code_only(read_cpp_source(root / "gdext/src/native_simulation_host_trigger.cpp"))
    if re.search(r"\bsnapshot\s*\(|RuntimeEventsAuthority\s*::\s*snapshot\b", event_code):
        errors.append("Trigger forwarding bypasses Events committed view")
    if "copy_committed_view" not in event_code:
        errors.append("missing owned Events projection")
    if not re.search(r"assert\s*\(\s*_events_authority\.observe_trigger_view\s*\(events_view\)\s*\)", event_code):
        errors.append("missing Events generation/day assertion")
    ideology_code = code_only(read_cpp_source(root / "gdext/src/native_simulation_host_ideology.cpp"))
    if borrowed_owner(ideology_code, "_modifier_pod_authority", "RuntimeModifierPodAuthority"):
        errors.append("Ideology bypasses Modifier committed view")
    if "copy_committed_view" not in ideology_code or not re.search(r"assert\s*\(\s*_modifier_pod_authority\.observe_committed_view", ideology_code):
        errors.append("missing Modifier generation/day assertion")
    modifier_code = code_only(read_cpp_source(root / "gdext/src/native_simulation_host_modifier.cpp"))
    if borrowed_owner(modifier_code, "_effect_pod_authority", "RuntimeEffectPodAuthority", allow_hash=True):
        errors.append("Modifier bypasses Effect committed view")
    if "copy_committed_view" not in modifier_code or not re.search(r"assert\s*\(\s*_effect_pod_authority\.observe_committed_view", modifier_code):
        errors.append("missing Effect generation/day assertion")
    annual_code = code_only(read_cpp_source(root / "gdext/src/annual_development_host.cpp"))
    errors += published_view_violations(
        consumer_body(ideology_code, "execute_ideology_worker_stage"),
        consumer_body(annual_code, "commit_annual_worker_day"))
    ai_path = root / "gdext/src/native_simulation_host_country_stage.cpp"
    errors += country_ai_violations(code_only(read_cpp_source(ai_path)))
    errors += annual_country_violations(consumer_body(annual_code, "commit_annual_worker_day"))
    family = code_only(read_cpp_source(root / "gdext/src/economy_runtime_family_effect_inputs_metrics.cpp"))
    errors += lineage_opinion_violations(consumer_body(family, "refresh_class_opinion_metrics"))
    return errors

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=ROOT)
    args = parser.parse_args()
    errors = violations(args.root)
    src = args.root / "gdext/src"
    errors += tax_display_violations(
        code_only(read_cpp_source(src / "world_ext_country.cpp")),
        code_only(read_cpp_source(src / "country_runtime_queries_tax.cpp")))
    for error in errors: print(error)
    print(f"committed views: 10 guarded edges, {len(errors)} violations")
    return bool(errors)
if __name__ == "__main__":
    raise SystemExit(main())
