#!/usr/bin/env python3
"""Check the day executor's registered stages for recognized same-day reuse paths."""

import argparse
from pathlib import Path
import re

from check_cpp_deps import code_only
from cpp_source import read_cpp_source


ROOT = Path(__file__).resolve().parents[2]
SRC = "gdext/src"
HOST = "native_simulation_host.cpp"
STAGE_TABLE = re.compile(r"\bRuntimeModuleDescriptor\s*<\s*StageFunction\s*>[^{};]*\{")
REGISTERED = re.compile(r"&\s*NativeSimulationHost\s*::\s*(stage_\w+)\b")
ENTRY = re.compile(
    r"\bbool\s+NativeSimulationHost\s*::\s*(stage_\w+)\s*\(\s*"
    r"DayExecution\s*&\s*(\w+)\s*,\s*RuntimeDomainPlan\s*&\s*(\w+)\s*\)\s*\{"
)
# These stages deliberately rebuild per-attempt data or use a different owner.
# A new exception needs a review of what the stage does on a same-day revisit.
ALTERNATIVES = {
    "stage_input_capture": "Reads the retained immutable input manifest for this attempt.",
    "stage_climate": "Accounts for the prelude result; prepare_climate_day skips the committed day.",
    "stage_country": "Skips the committed POD day and queues late packets for the next day.",
    "stage_effect": "Skips the committed POD day while draining late transport and emitting ACKs.",
    "stage_modifier": "The Modifier owner reuses receipts by delivery identity and accepts new commands.",
    "stage_events": "Keeps an uncommitted plan open so late events can join in stable order.",
    "stage_visual": "Rebuilds visual accounting from this attempt's dirty families.",
    "stage_commit": "Rebuilds the day commit header; publication is outside the stage loop.",
}
# These calls start/perform the known mutable work, after any read-only checks
# or staging needed to recognize a revisited day.
STAGE_WORK = {
    "stage_trigger_input": r"execute_trigger_worker_stage",
    "stage_ideology": r"execute_ideology_worker_stage",
    "stage_gameplay_effect": (r"gameplay_event_commands\s*\.\s*push_back|"
                              r"queue_ideology_pod_commands|_gameplay_effect_generation\s*\.\s*fetch_add"),
    "stage_economy": r"open_granted_economy_d7_gates",
}
MODIFIER_OWNER = "runtime_modifier_pod_daily_authority.inc"
MODIFIER_PLAN = re.compile(r"\bRuntimeModifierPodAuthority::plan_day\s*\([^{}]*\)\s*\{")
MODIFIER_COMMIT = re.compile(r"\bRuntimeModifierPodAuthority::commit_day\s*\([^{}]*\)\s*\{")
RECEIPT_ACCESS = re.compile(r"\b(?:_current|_next)\s*\.\s*day_receipts\b(?:\s*\.\s*(\w+)\s*\()?")
MODIFIER_DEDUP = (
    r"\bconst\s+bool\s+same_day\s*=\s*day\s*==\s*_current\.committed_day\s*;",
    r"\b_next\s*=\s*_current\s*;",
    r"\bconst\s+auto\s+previous\s*=\s*_next\.day_receipts\.find\s*\(\s*item\.id\s*\)\s*;"
    r"\s*if\s*\(\s*previous\s*!=\s*_next\.day_receipts\.end\s*\(\s*\)\s*\)\s*\{"
    r"[^{}]*\bcontinue\s*;",
    r"\bconst\s+auto\s+previous\s*=\s*_next\.day_receipts\.find\s*\(\s*id\s*\)\s*;"
    r"\s*if\s*\(\s*previous\s*!=\s*_next\.day_receipts\.end\s*\(\s*\)\s*\)\s*\{"
    r"[^{}]*\bcontinue\s*;",
)
NEW_DAY_RECEIPT_RESET = re.compile(
    r"\bif\s*\(\s*!\s*same_day\s*\)\s*\{\s*(?P<reset>_next\s*\.\s*day_receipts\s*\.\s*clear\s*\()"
)
RETENTION_CONDITION = {"stage_trigger_input": "trigger_ok", "stage_ideology": "ideology_ok"}
RETENTION_SCOPE = {"stage_trigger_input": "trigger_ok || trigger_soft"}
RETURN = re.compile(r"\breturn\b")


def _body(code: str, start: int) -> str:
    depth = 1
    for brace in re.finditer(r"[{}]", code[start:]):
        depth += 1 if brace[0] == "{" else -1
        if depth == 0:
            return code[start:start + brace.start()]
    return ""


def _modifier_reuses_receipts(code: str) -> bool:
    plan = MODIFIER_PLAN.search(code)
    commit = MODIFIER_COMMIT.search(code)
    if not plan or not commit:
        return False
    body = _body(code, plan.end())
    reset = NEW_DAY_RECEIPT_RESET.search(body)
    if not reset or not all(re.search(pattern, body) for pattern in MODIFIER_DEDUP):
        return False
    allowed_reset = plan.end() + reset.start("reset")
    for access in RECEIPT_ACCESS.finditer(code):
        if access.start() == allowed_reset:
            continue
        if access[1] not in {"at", "contains", "count", "emplace", "end", "find", "size", "try_emplace"}:
            return False
    return bool(re.search(r"\b_current\s*=\s*std::move\s*\(\s*_next\s*\)\s*;", _body(code, commit.end())))


def _scopes_at(body: str, position: int) -> tuple[int, ...]:
    scopes = []
    for brace in re.finditer(r"[{}]", body[:position]):
        if brace[0] == "{":
            scopes.append(brace.start())
        else:
            scopes.pop()
    return tuple(scopes)


def _starts_statement(body: str, position: int) -> bool:
    prefix = body[:position].rstrip()
    return not prefix or prefix[-1] in "{};"


def _reuse_positions(body: str, name: str, day: str, stage: str):
    call = rf"\b{day}\s*\.\s*reuse_completed\s*\(\s*{stage}\s*\)"
    # The reuse result controls an early return. Calling the helper and then
    # still running the stage does not recognize already-completed work.
    direct = rf"\bif\s*\(\s*{call}\s*\)\s*"
    local = (rf"\b(?:const\s+)?(?:bool|auto)\s+(?P<reused>\w+)\s*=\s*{call}\s*;\s*"
             rf"if\s*\(\s*(?P=reused)\s*\)\s*")
    for branch in re.finditer(rf"{direct}|{local}", body):
        if not _starts_statement(body, branch.start()):
            continue
        after = body[branch.end():]
        if after.startswith("{"):
            block = _body(after, 1)
            returns = re.search(r"\breturn\s+true\s*;\s*$", block)
            if returns and _starts_statement(block, returns.start()):
                yield branch.start()
        elif re.match(r"return\s+true\s*;", after):
            yield branch.start()
    if name == "stage_gameplay_effect":
        # Gameplay accepts newer packets even when the stage completed once.
        late_orders = (rf"\bif\s*\(\s*previously_completed\s*&&\s*latest_order\s*==\s*"
                       rf"{day}\s*\.\s*progress\s*\.\s*gameplay_submit_order\s*\)\s*")
        returns = rf"return\s+{call}\s*;"
        for branch in re.finditer(rf"{late_orders}(?:{returns}|\{{\s*{returns}\s*\}})", body):
            if _starts_statement(body, branch.start()):
                yield branch.start()


def _reuse_before_work(body: str, name: str, day: str, stage: str):
    work_pattern = STAGE_WORK.get(name)
    work = [call.start() for call in re.finditer(rf"\b(?:{work_pattern})\s*\(", body)] if work_pattern else []
    for position in _reuse_positions(body, name, day, stage):
        scope = _scopes_at(body, position)
        if all(position < start and _scopes_at(body, start)[:len(scope)] == scope for start in work):
            yield position, max(work, default=position), scope


def _condition_before(body: str, position: int, condition: str) -> bool:
    expression = r"\s*".join(map(re.escape, condition.split()))
    guard = re.search(rf"\bif\s*\(\s*{expression}\s*\)\s*$", body[:position])
    return bool(guard and _starts_statement(body, guard.start()))


def _has_earlier_return(body: str, reuse_at: int, retain_at: int, scope: tuple[int, ...]) -> bool:
    for earlier in RETURN.finditer(body, reuse_at, retain_at):
        if _starts_statement(body, earlier.start()):
            return_scope = _scopes_at(body, earlier.start())
            if scope[:len(return_scope)] == return_scope:
                return True
    return False


def _retains_completion(body: str, name: str, day: str, stage: str, reuse: tuple) -> bool:
    reuse_at, last_work, work_scope = reuse
    success_condition = RETENTION_CONDITION.get(name)
    outer_success = RETENTION_SCOPE.get(name)
    remember = rf"\b{day}\s*\.\s*remember_completed\s*\(\s*{stage}\s*\)\s*;"
    for call in re.finditer(remember, body):
        if call.start() <= last_work:
            continue
        scope = _scopes_at(body, call.start())
        parent_scopes = scope
        is_statement = _starts_statement(body, call.start())
        if success_condition:
            # Trigger and Ideology can return after a soft completion. Only
            # the explicitly successful path records a result to be reused.
            if is_statement and scope and _condition_before(body, scope[-1], success_condition):
                parent_scopes = scope[:-1]
            elif not _condition_before(body, call.start(), success_condition):
                continue
        elif not is_statement:
            continue
        if outer_success:
            if not parent_scopes or not _condition_before(body, parent_scopes[-1], outer_success):
                continue
            parent_scopes = parent_scopes[:-1]
        if parent_scopes != work_scope:
            continue
        if _has_earlier_return(body, reuse_at, call.start(), scope):
            continue
        return True
    return False


def _registered_stages(host: str) -> set[str]:
    code = code_only(host)
    table = STAGE_TABLE.search(code)
    return set(REGISTERED.findall(_body(code, table.end()))) if table else set()


def stage_reuse_violations(sources: dict[str, str]) -> list[str]:
    registered = _registered_stages(sources.get(HOST, ""))
    if not registered:
        return [f"{HOST}: no registered day stages found"]
    errors = []
    defined = set()
    for path, source in sorted(sources.items()):
        if not path.startswith("native_simulation_stage_"):
            continue
        code = code_only(source)
        for entry in ENTRY.finditer(code):
            name, day, stage = entry.groups()
            line = code.count("\n", 0, entry.start()) + 1
            label = f"{SRC}/{path}:{line}: {name}"
            defined.add(name)
            body = _body(code, entry.end())
            if not body.strip():
                errors.append(f"{label} has no readable stage body")
            elif name == "stage_modifier":
                if not _modifier_reuses_receipts(code_only(sources.get(MODIFIER_OWNER, ""))):
                    errors.append(f"{label} does not preserve same-day delivery receipts in {MODIFIER_OWNER}")
            elif name not in ALTERNATIVES:
                reuse_paths = list(_reuse_before_work(body, name, day, stage))
                if not reuse_paths:
                    errors.append(f"{label} must return through {day}.reuse_completed({stage}) before repeating stage work")
                elif not any(_retains_completion(body, name, day, stage, path) for path in reuse_paths):
                    errors.append(f"{label} must retain its completed stage with {day}.remember_completed({stage}) on the success path")
    for name in sorted(registered - defined):
        errors.append(f"{HOST}: no readable definition for registered day stage {name}")
    return errors


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=ROOT)
    src = parser.parse_args().root / SRC
    paths = [src / HOST, src / MODIFIER_OWNER, *src.glob("native_simulation_stage_*.cpp")]
    sources = {path.name: read_cpp_source(path) for path in paths if path.is_file()}
    errors = stage_reuse_violations(sources)
    count = len(_registered_stages(sources.get(HOST, "")))
    print(f"day stage reuse: {count} registered stages, {len(errors)} violations")
    for error in errors:
        print(error)
    return int(bool(errors))


if __name__ == "__main__":
    raise SystemExit(main())
