"""Gates, parsers, allowlists and validators are tested with inputs they must refuse (AGENTS.md rule 6).

Every gate-like function in the factory and CI tools has at least one refusal in GATES.
Entries identify the repository-relative file and the function's qualified name.
"""

import ast
from contextlib import redirect_stderr
from io import StringIO
import json
import sys
import unittest
from pathlib import Path
from tempfile import TemporaryDirectory
from unittest.mock import patch

FACTORY = Path(__file__).resolve().parents[1]
CI = FACTORY.parent / "ci"
sys.path.insert(0, str(FACTORY))
sys.path.insert(1, str(CI))

import agent
import checks
import check_cpp_deps
import check_committed_views
import check_cross_domain_inventory
import check_module_map
import check_module_contracts
import check_save_contracts
import check_save_section_contracts
import check_size_ratchet
import check_fault_taxonomy
import check_generated_manifests
import check_large_blobs
import check_markdown_links
import check_module_api
import check_script_native_access as script_access
import inspect_incident
import narrative_save_layout as narrative_layout
import ticket
import verdict
import work
import watch_prs
import world_ext_bindings
from check_day_stage_reuse import stage_reuse_violations
from check_tax_row_keys import tax_row_key_violations, validate_tax_row_baseline
from check_test_strictness import validate_test_diff
from common import Result, legacy_lane_gate, load_config
import test_architecture_guards
import test_frontend_and_save_guards as continued_state_inputs
from test_day_stage_reuse import WITHOUT_REUSE, gameplay_sources
from test_tax_row_keys import MASTER_ENTRY, PACKED_ROWS, TAX_ROWS
from test_test_strictness import SEED_AFTER, SEED_BEFORE

CFG = load_config()
NATIVE = CFG["checks"]["nativeRuntimeCheck"]
FINDINGS = [{"id": "f1"}, {"id": "f10"}]


def refuses_dispute(text):
    try:
        agent.parse_disputes(text, FINDINGS)
    except ValueError:
        return True
    return False


def refuses_resolution(entries):
    try:
        agent.parse_conflict_resolutions(json.dumps(entries), ["file.gd"])
    except ValueError:
        return True
    return False


def refuses_conflict_file(action, make_file):
    with TemporaryDirectory() as tmp:
        path = Path(tmp) / "file.gd"
        make_file(path)
        try:
            work.validate_conflict_files(tmp, {path.name: (action, "Combine both edits")})
        except ValueError:
            return True
        return False


def symlink_to_text(path):
    target = path.with_name("target.txt")
    target.write_text("Valid text")
    path.symlink_to(target)


def pr(**kw):
    base = {"headRefOid": "abc", "labels": [], "isDraft": False, "isCrossRepository": False,
            "headRefName": "feature/x"}
    base.update(kw)
    return base


def skipped(**kw):
    return watch_prs.skip_before_review(pr(**kw), watch_prs.PrState(), CFG) is not None


def preflight_refuses(kind, *, remote_base="base1", moved=True):
    """Run a preflight on a fake watcher; True when it returned a refusal."""
    from types import SimpleNamespace
    from unittest.mock import Mock, patch
    p = {"number": 7, "headRefOid": "head1", "headRefName": "agent/issue-1", "baseRefName": "master",
         "baseRefOid": "base1", "labels": [], "changedFiles": 1}
    fresh = {**p, "state": "OPEN", "isDraft": False, "isCrossRepository": False, "mergeable": "MERGEABLE"}
    if kind == "update":
        fresh["labels"] = [CFG["labels"]["working"]]
    me = SimpleNamespace(cfg=CFG, workdir="/nonexistent", gh=Mock(errors=[]),
                         base_moved=lambda *a: moved)
    me.gh.pr_merge_state.return_value = fresh
    with patch("work.remote_head", return_value=remote_base):
        if kind == "update":
            return watch_prs.Watcher.update_preflight(me, p, "master", "base1", Mock()) is not None
        fresh["headRefOid"] = "other"
        return watch_prs.Watcher.merge_preflight(me, p) is not None


def refuses_legacy_owner(lane, entry):
    with TemporaryDirectory() as tmp:
        root = Path(tmp)
        (root / "lock").write_text("42")
        owner = Result(0, f"python3 tools/factory/{entry}", "")
        with patch("common.sh", return_value=owner):
            return legacy_lane_gate(root, lane)


def refuses_moved_heading():
    with TemporaryDirectory() as tmp:
        root = Path(tmp)
        (root / "current-state.md").write_text("[状态](feature-status.md#同日重访)\n", encoding="utf-8")
        (root / "feature-status.md").write_text("## 按模块查阅\n", encoding="utf-8")
        return bool(check_markdown_links.validate_markdown_links(root, {"current-state.md", "feature-status.md"}))


def refuses_unknown_fault_flag():
    with redirect_stderr(StringIO()):
        try:
            check_fault_taxonomy.parse_args(["--unknown"])
        except SystemExit as error:
            return error.code == 2
    return False


def refuses_commented_binding():
    with TemporaryDirectory() as tmp:
        root = Path(tmp)
        path = root / "binding.cpp"
        path.write_text('// ClassDB::bind_method(D_METHOD("hidden"), &DCWorldExt::hidden);\n', encoding="utf-8")
        return world_ext_bindings.parse_bindings(root, path.name) == []


def refuses_unrelated_cpp_baseline():
    try:
        check_cpp_deps.reclassify_family_baseline("{}", {}, {})
    except ValueError as error:
        return "original" in str(error)
    return False


def refuses_invalid_catalog_input():
    try:
        check_generated_manifests.parse_catalog_inputs('{\n"directories": ["res://data"],\n"extensions": [1]}')
    except ValueError as error:
        return "loading_catalog_sources.json:3" in str(error)
    return False


def architecture_case(name):
    # Reuse the existing mutation fixture, including its assertion on the refusal.
    def exercise():
        case = test_architecture_guards.GuardsTest(name)
        getattr(case, name)()
        return True
    return exercise


def refuses_files(check, files, reason):
    with TemporaryDirectory() as directory:
        root = Path(directory)
        for filename, content in files.items():
            path = root / filename
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(content, encoding="utf-8")
        return any(reason in message for message in check(root))


# name -> list of (description, callable returning True when the gate refused the input)
GATES = {
    "tools/ci/check_committed_views.py:violations": [
        ("the Economy stage reads the Climate store directly",
         architecture_case("test_committed_view_rejects_real_bypass_and_missing_version_check")),
    ],
    "tools/ci/check_committed_views.py:published_view_violations": [
        ("an Ideology snapshot bypasses the committed annual view",
         lambda: "Ideology -> annual report bypasses owned committed view" in
                 check_committed_views.published_view_violations("", "ideology_pod_snapshot")),
    ],
    "tools/ci/check_committed_views.py:country_ai_violations": [
        ("Country AI reads the Economy digest directly", lambda: "Country AI bypasses Economy committed view" in
         check_committed_views.country_ai_violations("country_ai_digest")),
    ],
    "tools/ci/check_committed_views.py:annual_country_violations": [
        ("the annual report reads Country's snapshot directly", lambda: "annual report bypasses Country view" in
         check_committed_views.annual_country_violations("country_asset_snapshot()")),
    ],
    "tools/ci/check_committed_views.py:lineage_opinion_violations": [
        ("family metrics read Economy's mutable buffers", lambda: "Family metrics bypass Economy committed opinion" in
         check_committed_views.lineage_opinion_violations("_class_opinion_buffers")),
    ],
    "tools/ci/check_committed_views.py:tax_display_violations": [
        ("a tax panel with no published-frame query", lambda: "country panel bypasses the national tax query" in
         check_committed_views.tax_display_violations("", "")),
    ],
    "tools/ci/check_cpp_deps.py:violations": [
        ("a new cross-module include", lambda: bool(check_cpp_deps.violations({"country->economy": 1}, {}))),
    ],
    "tools/ci/check_cross_domain_inventory.py:violations": [
        ("a dependency pair is missing from inventory", lambda: refuses_files(check_cross_domain_inventory.violations,
         {"tools/ci/cpp_deps_baseline.json": '{"references":{"source|a->b|type":1}}',
          "tools/ci/cross_domain_inventory.json": '{}'}, "pair missing from inventory: a->b")),
    ],
    "tools/ci/check_fault_taxonomy.py:fatal_field_violations": [
        ("a fatal without replay evidence", lambda: bool(check_fault_taxonomy.fatal_field_violations(
            [{"id": "fatal", "kind": "fatal"}]))),
    ],
    "tools/ci/check_module_contracts.py:freeze_read_violations": [
        ("the Economy stage omits the frozen read", lambda: refuses_files(check_module_contracts.freeze_read_violations,
         {check_module_contracts.FREEZE_READS["economy"]: ""}, "economy missing frozen input registration")),
    ],
    "tools/ci/check_module_contracts.py:stage_order_violations": [
        ("a stage reads a later stage", lambda: bool(check_module_contracts.stage_order_violations(
            {"modules": [{"id": "a", "reads": "b"}, {"id": "b", "reads": ""}]}))),
    ],
    "tools/ci/check_module_contracts.py:violations": [
        ("the generated header loses the module declarations", lambda: refuses_files(
            lambda root: check_module_contracts.violations(root, {"modules": [], "reviewed_reads": []}),
            {check_module_contracts.HEADER: ""}, "generated module contracts differ")),
    ],
    "tools/ci/check_module_map.py:violations": [
        ("the module map points to a missing file", lambda: refuses_files(check_module_map.violations,
         {check_module_map.MAP: "`gdext/missing.h`"}, "does not exist")),
    ],
    "tools/ci/check_resolve_apply.py:violations": [
        ("a resolve entry uses a raw queue", architecture_case("test_resolve_apply_actual_source_negatives")),
    ],
    "tools/ci/check_runtime_advancers.py:violations": [
        ("the host gains an unregistered date cursor",
         architecture_case("test_advancer_inventory_rejects_missing_fields_methods_and_header")),
    ],
    "tools/ci/check_save_contracts.py:violations": [
        ("Country reads Economy-owned bytes", lambda: refuses_files(check_save_contracts.violations,
         {check_save_contracts.BASE + "save_modules/country_state.gd": "extends Node\nfunc write(): return ecp2",
          check_save_contracts.BASE + "save_modules/economy_state.gd": "",
          check_save_contracts.BASE + "world_state_modules.gd": ""}, "foreign section byte access ecp2")),
    ],
    "tools/ci/check_save_section_contracts.py:violations": [
        ("the section directory omits all owners", lambda: refuses_files(check_save_section_contracts.violations,
         {check_save_section_contracts.REGISTRY: '{}'}, "12 unique domains")),
    ],
    "tools/ci/check_script_native_access.py:violations": [
        ("UI gains an unregistered native call", lambda: bool(script_access.violations({"ui.gd": {"economy": 1}}, {}))),
    ],
    "tools/ci/check_size_ratchet.py:violations": [
        ("a new file reaches 800 lines", lambda: bool(check_size_ratchet.violations(
            {"new.cpp": {"limit": 799, "lines": 800}}, {}))),
    ],
    "tools/ci/check_world_ext_bindings.py:violations": [
        ("a binding lives in the wrong module", architecture_case("test_world_ext_binding_guard_rejects_misplaced_and_entry_bindings")),
    ],
    "tools/ci/check_cpp_deps.py:reclassify_family_baseline": [
        ("unrelated content cannot be treated as the reviewed dependency baseline", refuses_unrelated_cpp_baseline),
    ],
    "tools/ci/check_fault_taxonomy.py:parse_args": [
        ("the fault taxonomy rejects an unknown flag", refuses_unknown_fault_flag),
    ],
    "tools/ci/check_large_blobs.py:allowed_limit": [
        ("an unrelated binary gets no allowlisted budget",
         lambda: check_large_blobs.allowed_limit("other.bin", [{"path": "known.bin"}], 5) is None),
    ],
    "tools/ci/check_module_api.py:matches": [
        ("an unrelated header is outside the API pattern",
         lambda: not check_module_api.matches("private/economy.h", ["public/*.h"])),
    ],
    "tools/ci/inspect_incident.py:type_matches": [
        ("a boolean is not an integer witness", lambda: inspect_incident.type_matches("i32", True) is False),
    ],
    "tools/ci/world_ext_bindings.py:parse_bindings": [
        ("a commented-out binding is absent", refuses_commented_binding),
    ],
    "tools/factory/checks.py:Candidate.scope": [
        ("a protected path is refused through the candidate entry", lambda: checks.Candidate(
            CFG, "/nonexistent", verdict.NativeFacts()).scope(["tools/factory/a.py"])[0] == ["tools/factory/a.py"]),
    ],
    "tools/ci/check_day_stage_reuse.py:stage_reuse_violations": [
        ("the gameplay effect stage runs again when the day is revisited",
         lambda: bool(stage_reuse_violations(gameplay_sources(WITHOUT_REUSE)))),
    ],
    "tools/ci/check_tax_row_keys.py:tax_row_key_violations": [
        ("mode bits overlap a legal tax amount in the settlement cache",
         lambda: bool(tax_row_key_violations({TAX_ROWS: PACKED_ROWS}, {})[0])),
    ],
    "tools/ci/check_tax_row_keys.py:validate_tax_row_baseline": [
        ("a new exception cannot be added to an empty tax row baseline",
         lambda: bool(validate_tax_row_baseline(MASTER_ENTRY, {}))),
    ],
    "tools/ci/check_script_native_access.py:allowed": [
        ("a UI script is outside the owning Economy directory", lambda: not script_access.allowed(
            "scripts/ui/calendar.gd", "economy", {"economy": ["scripts/economy"]})),
    ],
    "tools/ci/check_script_native_access.py:frontend_live_read_violations": [
        ("the calendar takes simulation progress from the live Economy facade", lambda: bool(
            script_access.frontend_live_read_violations(
                continued_state_inputs.PLAYER_GAME, continued_state_inputs.HISTORICAL_CALENDAR,
                continued_state_inputs.CALENDAR_BASELINE))),
        ("a calendar initializer reads the live report before its first method", lambda: bool(
            script_access.frontend_live_read_violations("scripts/ui/calendar.gd",
                "var day = _economy_facade.report()\nfunc update():\n\tpass\n", {}))),
    ],
    "tools/ci/check_script_native_access.py:native_baseline_violations": [
        ("a removed reference cannot leave an unused allowance behind",
         lambda: bool(script_access.native_baseline_violations({}, {"scripts/ui/calendar.gd": {"economy": 1}}))),
    ],
    "tools/ci/check_script_native_access.py:live_baseline_violations": [
        ("an additional function is added to the historical Economy access exception", lambda: bool(
            script_access.live_baseline_violations({"scripts/ui/calendar.gd": {"read_day": "0" * 64}}, {}))),
    ],
    "tools/ci/narrative_save_layout.py:layout_violations": [
        ("the last-city state is captured under the same archive version", lambda: bool(
            narrative_layout.layout_violations(
                narrative_layout.archive_shapes(continued_state_inputs.unversioned_last_city_capture()),
                continued_state_inputs.SAVE_BASELINE))),
    ],
    "tools/ci/narrative_save_layout.py:narrative_violations": [
        ("an unversioned last-city queue reaches the repository entry point", lambda: refuses_files(
            narrative_layout.narrative_violations,
            {narrative_layout.SOURCE: continued_state_inputs.unversioned_last_city_capture(),
             narrative_layout.BASELINE: json.dumps(continued_state_inputs.SAVE_BASELINE)},
            "pending_independence_clears")),
    ],
    "tools/ci/narrative_save_layout.py:drained_state_violations": [
        ("the last-city state queued for the next day is absent from the archive", lambda: bool(
            narrative_layout.drained_state_violations(continued_state_inputs.SAVE_SOURCE, [
                (continued_state_inputs.UNREST_FILE, continued_state_inputs.HISTORICAL_DRAIN)]))),
    ],
    "tools/ci/check_generated_manifests.py:validate_binding_manifest_bytes": [
        ("a hand-edited list omits a discovered binding", lambda: bool(
            check_generated_manifests.validate_binding_manifest_bytes(
                b'{"class":"DCWorldExt","count":0,"methods":[]}', [{"name": "poll_runtime_commit"}]))),
    ],
    "tools/ci/check_generated_manifests.py:parse_catalog_inputs": [
        ("the recipe contains a non-string file extension", refuses_invalid_catalog_input),
    ],
    "tools/ci/check_generated_manifests.py:validate_catalog_manifest_bytes": [
        ("a hand-edited fingerprint disagrees with the source bytes", lambda: bool(
            check_generated_manifests.validate_catalog_manifest_bytes(
                b'{"res://data/native_binding_manifest.json":"stale"}',
                {"res://data/native_binding_manifest.json": "0" * 64}, {})[0])),
    ],
    "tools/ci/check_markdown_links.py:validate_markdown_links": [
        ("a heading moved out of feature-status without a retained anchor", refuses_moved_heading),
    ],
    "tools/ci/check_test_strictness.py:validate_test_diff": [
        ("the stopped-worker test changes its map seed without a local reason",
         lambda: bool(validate_test_diff(SEED_BEFORE, SEED_AFTER))),
    ],
    "tools/factory/common.py:legacy_lane_gate": [
        ("the old Issue runner owns the Issue workspace", lambda: refuses_legacy_owner("issue", "run.py")),
        ("the old PR runner owns the shared workspace", lambda: refuses_legacy_owner("issue", "watch_prs.py")),
        ("the old PR runner owns PR processing", lambda: refuses_legacy_owner("pr", "watch_prs.py")),
    ],
    "tools/factory/agent.py:parse_disputes": [
        ("line without the '- ' marker", lambda: refuses_dispute("f1: evidence")),
        ("id that is only a prefix of a real id", lambda: refuses_dispute("- f: evidence")),
        ("unknown id", lambda: refuses_dispute("- f2: evidence")),
        ("empty evidence", lambda: refuses_dispute("- f1:")),
        ("whitespace-only evidence", lambda: refuses_dispute("- f1:   ")),
        ("no space after the colon", lambda: refuses_dispute("- f1:evidence")),
        ("backtick left inside the id", lambda: refuses_dispute("- `f1: evidence")),
        ("one good line and one bad line", lambda: refuses_dispute("- f1: ok\n- f9: no")),
    ],
    "tools/factory/agent.py:parse_conflict_resolutions": [
        ("report is not an array", lambda: refuses_resolution({"file.gd": "keep"})),
        ("missing path", lambda: refuses_resolution([])),
        ("unrelated path", lambda: refuses_resolution([{"path": "../file.gd", "action": "keep", "reason": "Merge"}])),
        ("duplicate path", lambda: refuses_resolution([{"path": "file.gd", "action": "keep", "reason": "Merge"}] * 2)),
        ("unknown action", lambda: refuses_resolution([{"path": "file.gd", "action": "skip", "reason": "Merge"}])),
        ("empty reason", lambda: refuses_resolution([{"path": "file.gd", "action": "keep", "reason": "  "}])),
    ],
    "tools/factory/work.py:validate_conflict_files": [
        ("declared deletion still exists", lambda: refuses_conflict_file("delete", lambda p: p.touch())),
        ("kept file is missing", lambda: refuses_conflict_file("keep", lambda p: None)),
        ("kept path is a directory", lambda: refuses_conflict_file("keep", lambda p: p.mkdir())),
        ("kept file is a symlink", lambda: refuses_conflict_file("keep", symlink_to_text)),
        ("kept file is binary", lambda: refuses_conflict_file("keep", lambda p: p.write_bytes(b"\0binary"))),
    ],
    "tools/factory/verdict.py:classify_level": [
        ("missing level is unknown", lambda: verdict.classify_level(None) == "unknown"),
        ("misspelled level is unknown", lambda: verdict.classify_level("Informational") == "unknown"),
        ("empty level is unknown", lambda: verdict.classify_level("") == "unknown"),
    ],
    "tools/factory/verdict.py:classify": [
        ("missing status is unknown", lambda: verdict.classify({"action_level": "action_required"}) == "unknown"),
        ("non-string status is unknown", lambda: verdict.classify({"attribution_status": 3}) == "unknown"),
        ("unfamiliar status is unknown", lambda: verdict.classify({"attribution_status": "reopened"}) == "unknown"),
        ("open status with a missing level is unknown", lambda: verdict.classify({"attribution_status": "pending"}) == "unknown"),
    ],
    "tools/factory/verdict.py:unknown_findings": [
        ("an unfamiliar status is reported", lambda: bool(verdict.unknown_findings([{"id": "a", "attribution_status": "x"}]))),
        ("a missing level is reported when required", lambda: bool(
            verdict.unknown_findings([{"id": "a", "attribution_status": "implemented"}], require_level=True))),
    ],
    "tools/factory/checks.py:native_line": [
        ("a second command after ;", lambda: not checks.native_line(NATIVE + " ; rm x", NATIVE)),
        ("a pipe", lambda: not checks.native_line(NATIVE + " | sh", NATIVE)),
        ("command substitution", lambda: not checks.native_line(NATIVE + " $(id)", NATIVE)),
        ("another script that starts with the same name", lambda: not checks.native_line(NATIVE + "x", NATIVE)),
        ("a redirect", lambda: not checks.native_line(NATIVE + " > out", NATIVE)),
    ],
    "tools/factory/checks.py:extra_checks": [
        ("a command outside the allowlist is rejected", lambda: checks.extra_checks(["rm -rf x"], r"^godot ")[1] == ["rm -rf x"]),
        ("an allowlisted prefix with a second command is rejected, not accepted",
         lambda: checks.extra_checks(["godot a; rm x"], r"^godot [a-z./_]+$")[:2] == ([], ["godot a; rm x"])),
    ],
    "tools/factory/ticket.py:matches": [
        ("a folder pattern does not match a sibling that shares its prefix", lambda: not ticket.matches("tools/factory2/x.py", "tools/factory/")),
        ("an exact pattern does not match a longer path", lambda: not ticket.matches("a/bc", "a/b")),
        ("a glob does not match across a different name", lambda: not ticket.matches("tools/ci/other.json", "tools/ci/*baseline*.json")),
    ],
    "tools/factory/ticket.py:touching": [
        ("an unprotected file is not reported", lambda: ticket.touching(["docs/a.md"], CFG["paths"]["forbidden"]) == []),
        ("a protected file is reported", lambda: ticket.touching([".github/x.yml"], CFG["paths"]["forbidden"]) == [".github/x.yml"]),
    ],
    "tools/factory/work.py:scope": [
        ("a forbidden path is reported as forbidden", lambda: work.scope(CFG, ["tools/factory/a.py"])[0] == ["tools/factory/a.py"]),
        ("a project-keynes binary requires a person",
         lambda: work.scope(CFG, ["Project/project-keynes/addons/dots_ext/bin/macos/libdots_ext.dylib"])[1]
                 == ["Project/project-keynes/addons/dots_ext/bin/macos/libdots_ext.dylib"]),
        ("an ordinary path is reported in no list", lambda: work.scope(CFG, ["docs/a.md"]) == ([], [], [])),
    ],
    "tools/factory/ticket.py:gate": [
        ("empty title", lambda: bool(ticket.gate("", "## Acceptance criteria\n- [ ] a", [], []))),
        ("no criteria heading", lambda: bool(ticket.gate("t", "just text", [], []))),
        ("heading with no items", lambda: bool(ticket.gate("t", "## Acceptance criteria\nnothing", [], []))),
        ("a skip label", lambda: bool(ticket.gate("t", "## Acceptance criteria\n- [ ] a", ["no-agent"], ["no-agent"]))),
    ],
    "tools/factory/watch_prs.py:Watcher.update_preflight": [
        ("an unreadable base branch", lambda: preflight_refuses("update", remote_base=None, moved=False)),
        ("a base that moved on the remote", lambda: preflight_refuses("update", remote_base="base2")),
    ],
    "tools/factory/watch_prs.py:Watcher.merge_preflight": [
        ("a head that changed before merge", lambda: preflight_refuses("merge")),
    ],
    "tools/factory/watch_prs.py:skip_before_review": [
        ("a draft PR", lambda: skipped(isDraft=True)),
        ("a PR from another repository", lambda: skipped(isCrossRepository=True)),
        ("a skip label", lambda: skipped(labels=[CFG["skipLabels"][0]])),
        ("an issue branch the runner has not handed over",
         lambda: skipped(headRefName=CFG["issueBranchPrefix"] + "1")),
    ],
}

NAME_PARTS = ("matches", "touching", "scope", "gate", "parse", "classify", "validate", "allowed", "native_line", "extra_checks", "unknown_findings", "preflight")


def _is_gate_name(name: str) -> bool:
    if name == "violations" or name.endswith("_violations"):
        return True
    if name.startswith("_"):
        return name.lstrip("_").startswith("validate_")
    return any(part in name for part in NAME_PARTS)


def _named_gates(node, prefix=()):
    for child in ast.iter_child_nodes(node):
        if isinstance(child, (ast.ClassDef, ast.FunctionDef, ast.AsyncFunctionDef)):
            qualified = (*prefix, child.name)
            if not isinstance(child, ast.ClassDef) and _is_gate_name(child.name):
                yield ".".join(qualified)
            yield from _named_gates(child, qualified)
        else:
            yield from _named_gates(child, prefix)


def gate_functions():
    found = set()
    for path in (*FACTORY.rglob("*.py"), *CI.rglob("*.py")):
        if path.name.startswith("test_") or "tests" in path.relative_to(FACTORY.parent).parts:
            continue
        source = ast.parse(path.read_text(encoding="utf-8"))
        file = path.relative_to(FACTORY.parents[1]).as_posix()
        found.update(f"{file}:{name}" for name in _named_gates(source))
    return found


class GatesRefuse(unittest.TestCase):
    def test_every_gate_refuses_its_bad_inputs(self):
        for name, cases in GATES.items():
            self.assertTrue(cases, name)
            for description, refused in cases:
                with self.subTest(gate=name, case=description):
                    self.assertTrue(refused())

    def test_every_gate_function_is_registered(self):
        missing = sorted(gate_functions() - set(GATES) - set(KNOWN_UNLISTED))
        self.assertEqual(missing, [], "gate-like functions with no refusal test; add them to GATES")

    def test_same_named_gates_in_different_checkers_need_separate_registrations(self):
        with TemporaryDirectory() as tmp:
            root = Path(tmp)
            factory, ci = root / "tools/factory", root / "tools/ci"
            factory.mkdir(parents=True)
            ci.mkdir()
            for file in ("check_test_strictness.py", "check_another_rule.py"):
                (ci / file).write_text("def validate_test_diff(): return True\n", encoding="utf-8")
            with patch(f"{__name__}.FACTORY", factory), patch(f"{__name__}.CI", ci):
                self.assertEqual(gate_functions() - set(GATES), {
                    "tools/ci/check_another_rule.py:validate_test_diff",
                })

    def test_private_validation_entries_require_refusals(self):
        module = ast.parse("def _validate_archive(): pass\ndef _restore_violations(): pass\n"
                           "def _scan_tokens(): pass\n")
        self.assertEqual(set(_named_gates(module)), {"_validate_archive", "_restore_violations"})

    def test_unregistered_public_violations_in_a_new_checker_are_reported(self):
        with TemporaryDirectory() as tmp:
            root = Path(tmp)
            factory, ci = root / "tools/factory", root / "tools/ci"
            factory.mkdir(parents=True)
            ci.mkdir()
            (ci / "archive").mkdir()
            (ci / "archive/check_archive.py").write_text("def archive_violations(data): return []\n")
            with patch(f"{__name__}.FACTORY", factory), patch(f"{__name__}.CI", ci):
                self.assertEqual(gate_functions() - GATES.keys(), {"tools/ci/archive/check_archive.py:archive_violations"})

    def test_rule_text_matches_the_evidence_and_names_this_test(self):
        rules = FACTORY.parents[1] / "AGENTS.md"
        if not rules.is_file():
            self.skipTest("the repository rules are outside this checkout")
        import count_findings
        c = count_findings.count()
        text = rules.read_text()
        self.assertIn(f"{c['gate_input']} of {c['total']} findings", text)
        self.assertIn("test_gates_refuse.py", text)


# Functions whose names match but that are not gates; each needs a reason.
KNOWN_UNLISTED = {
    "tools/ci/check_fault_taxonomy.py:report_fatal_field_violations": "prints the results already checked by fatal_field_violations",
    "tools/factory/run.py:Run.scope_problems": "calls work.scope, whose refusals are in GATES; the stop is exercised in test_workflow.py",
    "tools/factory/watch_prs.py:Watcher.scope_problem": "calls Candidate.scope and reports its refusals",
    "tools/factory/watch_prs.py:Watcher.scope_blocked": "reports scope_problem's result; refusals are in GATES",
}

if __name__ == "__main__":
    unittest.main()
