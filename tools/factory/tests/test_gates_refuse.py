"""Gates, parsers, allowlists and validators are tested with inputs they must refuse (AGENTS.md rule 6).

Every gate-like function in the factory and the listed CI guard modules has at least one refusal in GATES.
The AST scan fails when a gate-named function in those modules is added without an entry.
"""

import ast
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
import check_generated_manifests
import check_markdown_links
import check_script_native_access as script_access
import narrative_save_layout as narrative_layout
import ticket
import verdict
import work
import watch_prs
from check_day_stage_reuse import stage_reuse_violations
from check_tax_row_keys import tax_row_key_violations
from check_test_strictness import validate_test_diff
from common import Result, legacy_lane_gate, load_config
import test_frontend_and_save_guards as continued_state_inputs
from test_day_stage_reuse import WITHOUT_REUSE, gameplay_sources
from test_tax_row_keys import PACKED_ROWS, TAX_ROWS
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


# name -> list of (description, callable returning True when the gate refused the input)
GATES = {
    "stage_reuse_violations": [
        ("the gameplay effect stage runs again when the day is revisited",
         lambda: bool(stage_reuse_violations(gameplay_sources(WITHOUT_REUSE)))),
    ],
    "tax_row_key_violations": [
        ("mode bits overlap a legal tax amount in the settlement cache",
         lambda: bool(tax_row_key_violations({TAX_ROWS: PACKED_ROWS}, {})[0])),
    ],
    "allowed": [
        ("a UI script is outside the owning Economy directory", lambda: not script_access.allowed(
            "scripts/ui/calendar.gd", "economy", {"economy": ["scripts/economy"]})),
    ],
    "frontend_live_read_violations": [
        ("the calendar takes simulation progress from the live Economy facade", lambda: bool(
            script_access.frontend_live_read_violations(
                continued_state_inputs.PLAYER_GAME, continued_state_inputs.HISTORICAL_CALENDAR,
                continued_state_inputs.CALENDAR_BASELINE))),
    ],
    "live_baseline_violations": [
        ("an additional function is added to the historical Economy access exception", lambda: bool(
            script_access.live_baseline_violations({"scripts/ui/calendar.gd": {"read_day": "0" * 64}}, {}))),
    ],
    "layout_violations": [
        ("the last-city state is captured under the same archive version", lambda: bool(
            narrative_layout.layout_violations(
                narrative_layout.archive_shapes(continued_state_inputs.unversioned_last_city_capture()),
                continued_state_inputs.SAVE_BASELINE))),
    ],
    "drained_state_violations": [
        ("the last-city state queued for the next day is absent from the archive", lambda: bool(
            narrative_layout.drained_state_violations(continued_state_inputs.SAVE_SOURCE, [
                (continued_state_inputs.UNREST_FILE, continued_state_inputs.HISTORICAL_DRAIN)]))),
    ],
    "validate_binding_manifest_bytes": [
        ("a hand-edited list omits a discovered binding", lambda: bool(
            check_generated_manifests.validate_binding_manifest_bytes(
                b'{"class":"DCWorldExt","count":0,"methods":[]}', [{"name": "poll_runtime_commit"}]))),
    ],
    "validate_catalog_manifest_bytes": [
        ("a hand-edited fingerprint disagrees with the source bytes", lambda: bool(
            check_generated_manifests.validate_catalog_manifest_bytes(
                b'{"res://data/native_binding_manifest.json":"stale"}',
                {"res://data/native_binding_manifest.json": "0" * 64}, {})[0])),
    ],
    "validate_markdown_links": [
        ("a heading moved out of feature-status without a retained anchor", refuses_moved_heading),
    ],
    "validate_test_diff": [
        ("the stopped-worker test changes its map seed without a local reason",
         lambda: bool(validate_test_diff(SEED_BEFORE, SEED_AFTER))),
    ],
    "legacy_lane_gate": [
        ("the old Issue runner owns the Issue workspace", lambda: refuses_legacy_owner("issue", "run.py")),
        ("the old PR runner owns the shared workspace", lambda: refuses_legacy_owner("issue", "watch_prs.py")),
        ("the old PR runner owns PR processing", lambda: refuses_legacy_owner("pr", "watch_prs.py")),
    ],
    "parse_disputes": [
        ("line without the '- ' marker", lambda: refuses_dispute("f1: evidence")),
        ("id that is only a prefix of a real id", lambda: refuses_dispute("- f: evidence")),
        ("unknown id", lambda: refuses_dispute("- f2: evidence")),
        ("empty evidence", lambda: refuses_dispute("- f1:")),
        ("whitespace-only evidence", lambda: refuses_dispute("- f1:   ")),
        ("no space after the colon", lambda: refuses_dispute("- f1:evidence")),
        ("backtick left inside the id", lambda: refuses_dispute("- `f1: evidence")),
        ("one good line and one bad line", lambda: refuses_dispute("- f1: ok\n- f9: no")),
    ],
    "parse_conflict_resolutions": [
        ("report is not an array", lambda: refuses_resolution({"file.gd": "keep"})),
        ("missing path", lambda: refuses_resolution([])),
        ("unrelated path", lambda: refuses_resolution([{"path": "../file.gd", "action": "keep", "reason": "Merge"}])),
        ("duplicate path", lambda: refuses_resolution([{"path": "file.gd", "action": "keep", "reason": "Merge"}] * 2)),
        ("unknown action", lambda: refuses_resolution([{"path": "file.gd", "action": "skip", "reason": "Merge"}])),
        ("empty reason", lambda: refuses_resolution([{"path": "file.gd", "action": "keep", "reason": "  "}])),
    ],
    "validate_conflict_files": [
        ("declared deletion still exists", lambda: refuses_conflict_file("delete", lambda p: p.touch())),
        ("kept file is missing", lambda: refuses_conflict_file("keep", lambda p: None)),
        ("kept path is a directory", lambda: refuses_conflict_file("keep", lambda p: p.mkdir())),
        ("kept file is a symlink", lambda: refuses_conflict_file("keep", symlink_to_text)),
        ("kept file is binary", lambda: refuses_conflict_file("keep", lambda p: p.write_bytes(b"\0binary"))),
    ],
    "classify_level": [
        ("missing level is unknown", lambda: verdict.classify_level(None) == "unknown"),
        ("misspelled level is unknown", lambda: verdict.classify_level("Informational") == "unknown"),
        ("empty level is unknown", lambda: verdict.classify_level("") == "unknown"),
    ],
    "classify": [
        ("missing status is unknown", lambda: verdict.classify({"action_level": "action_required"}) == "unknown"),
        ("non-string status is unknown", lambda: verdict.classify({"attribution_status": 3}) == "unknown"),
        ("unfamiliar status is unknown", lambda: verdict.classify({"attribution_status": "reopened"}) == "unknown"),
        ("open status with a missing level is unknown", lambda: verdict.classify({"attribution_status": "pending"}) == "unknown"),
    ],
    "unknown_findings": [
        ("an unfamiliar status is reported", lambda: bool(verdict.unknown_findings([{"id": "a", "attribution_status": "x"}]))),
        ("a missing level is reported when required", lambda: bool(
            verdict.unknown_findings([{"id": "a", "attribution_status": "implemented"}], require_level=True))),
    ],
    "native_line": [
        ("a second command after ;", lambda: not checks.native_line(NATIVE + " ; rm x", NATIVE)),
        ("a pipe", lambda: not checks.native_line(NATIVE + " | sh", NATIVE)),
        ("command substitution", lambda: not checks.native_line(NATIVE + " $(id)", NATIVE)),
        ("another script that starts with the same name", lambda: not checks.native_line(NATIVE + "x", NATIVE)),
        ("a redirect", lambda: not checks.native_line(NATIVE + " > out", NATIVE)),
    ],
    "extra_checks": [
        ("a command outside the allowlist is rejected", lambda: checks.extra_checks(["rm -rf x"], r"^godot ")[1] == ["rm -rf x"]),
        ("an allowlisted prefix with a second command is rejected, not accepted",
         lambda: checks.extra_checks(["godot a; rm x"], r"^godot [a-z./_]+$")[:2] == ([], ["godot a; rm x"])),
    ],
    "matches": [
        ("a folder pattern does not match a sibling that shares its prefix", lambda: not ticket.matches("tools/factory2/x.py", "tools/factory/")),
        ("an exact pattern does not match a longer path", lambda: not ticket.matches("a/bc", "a/b")),
        ("a glob does not match across a different name", lambda: not ticket.matches("tools/ci/other.json", "tools/ci/*baseline*.json")),
    ],
    "touching": [
        ("an unprotected file is not reported", lambda: ticket.touching(["docs/a.md"], CFG["paths"]["forbidden"]) == []),
        ("a protected file is reported", lambda: ticket.touching([".github/x.yml"], CFG["paths"]["forbidden"]) == [".github/x.yml"]),
    ],
    "scope": [
        ("a forbidden path is reported as forbidden", lambda: work.scope(CFG, ["tools/factory/a.py"])[0] == ["tools/factory/a.py"]),
        ("a project-keynes binary requires a person",
         lambda: work.scope(CFG, ["Project/project-keynes/addons/dots_ext/bin/macos/libdots_ext.dylib"])[1]
                 == ["Project/project-keynes/addons/dots_ext/bin/macos/libdots_ext.dylib"]),
        ("an ordinary path is reported in no list", lambda: work.scope(CFG, ["docs/a.md"]) == ([], [], [])),
    ],
    "gate": [
        ("empty title", lambda: bool(ticket.gate("", "## Acceptance criteria\n- [ ] a", [], []))),
        ("no criteria heading", lambda: bool(ticket.gate("t", "just text", [], []))),
        ("heading with no items", lambda: bool(ticket.gate("t", "## Acceptance criteria\nnothing", [], []))),
        ("a skip label", lambda: bool(ticket.gate("t", "## Acceptance criteria\n- [ ] a", ["no-agent"], ["no-agent"]))),
    ],
    "update_preflight": [
        ("an unreadable base branch", lambda: preflight_refuses("update", remote_base=None, moved=False)),
        ("a base that moved on the remote", lambda: preflight_refuses("update", remote_base="base2")),
    ],
    "merge_preflight": [
        ("a head that changed before merge", lambda: preflight_refuses("merge")),
    ],
    "skip_before_review": [
        ("a draft PR", lambda: skipped(isDraft=True)),
        ("a PR from another repository", lambda: skipped(isCrossRepository=True)),
        ("a skip label", lambda: skipped(labels=[CFG["skipLabels"][0]])),
        ("an issue branch the runner has not handed over",
         lambda: skipped(headRefName=CFG["issueBranchPrefix"] + "1")),
    ],
}

NAME_PARTS = ("matches", "touching", "scope", "gate", "parse", "classify", "validate", "allowed", "native_line", "extra_checks", "unknown_findings", "preflight")
CI_GUARD_MODULES = (
    "check_day_stage_reuse.py", "check_tax_row_keys.py", "check_generated_manifests.py",
    "check_markdown_links.py", "check_test_strictness.py", "check_script_native_access.py",
    "check_save_contracts.py", "narrative_save_layout.py",
)


def gate_functions():
    found = set()
    for path in (*FACTORY.glob("*.py"), *(CI / name for name in CI_GUARD_MODULES)):
        for node in ast.walk(ast.parse(path.read_text())):
            if isinstance(node, ast.FunctionDef) and not node.name.startswith("_") and \
                    any(p in node.name for p in NAME_PARTS):
                found.add(node.name)
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
    "scope_problems": "calls work.scope, whose refusals are in GATES; the stop is exercised in test_workflow.py",
    "scope_problem": "calls Candidate.scope over work.scope; refusals are in GATES",
    "scope_blocked": "reports scope_problem's result; refusals are in GATES",
}

if __name__ == "__main__":
    unittest.main()
