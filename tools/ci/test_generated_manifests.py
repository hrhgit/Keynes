import hashlib
import json
import subprocess
import unittest
from pathlib import Path
from tempfile import TemporaryDirectory

from check_generated_manifests import (
    BAKE,
    CACHE,
    PROJECT,
    _catalog_fingerprints,
    _catalog_recipe,
    catalog_baseline_at,
    validate_binding_manifest_bytes,
    validate_catalog_manifest_bytes,
)

SOURCE = "res://data/native_binding_manifest.json"
# The first SHA is the pre-bake fingerprint committed before f99752785.
STALE_HASH = "6cff89dea05338d18a0d5324672b666262feea3bf77f970e5f51f68b570df554"
UPSTREAM_LF_HASH = "27a934af7c1673f1f3be97b409badbb9930b8a2ac32aabcb24dca62a62a0f021"
UPSTREAM_CRLF_HASH = "d81c18cf4529755fe4f8e12cb1a611a5ce74f92a13863de97bf2f1f5a923b5da"
CANONICAL_BINDINGS = b'{\n  "class": "DCWorldExt",\n  "count": 1,\n  "methods": [\n    "take_day"\n  ]\n}\n'


def catalog(*entries: tuple[str, str]) -> bytes:
    rows = ",\n".join(f'\t"{path}": "{digest}"' for path, digest in sorted(entries))
    return ("{\n" + rows + "\n}").encode("utf-8")


def stage_sources(root: Path, files: dict[str, bytes]) -> None:
    subprocess.run(["git", "init", "-q"], cwd=root, check=True)
    for path, content in files.items():
        target = root / path
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(content)
    subprocess.run(["git", "add", "."], cwd=root, check=True)


class GeneratedManifestTests(unittest.TestCase):
    def test_accepts_binding_generator_bytes(self):
        self.assertEqual(validate_binding_manifest_bytes(CANONICAL_BINDINGS, [{"name": "take_day"}]), [])

    def test_refuses_equivalent_but_hand_edited_binding_json(self):
        manual = CANONICAL_BINDINGS.replace(b"  ", b"\t")
        self.assertEqual(json.loads(manual), json.loads(CANONICAL_BINDINGS))
        self.assertIn("bytes differ from regenerated bindings",
                      validate_binding_manifest_bytes(manual, [{"name": "take_day"}])[0])

    def test_accepts_catalog_generated_from_disk_fingerprints(self):
        self.assertEqual(
            validate_catalog_manifest_bytes(catalog((SOURCE, UPSTREAM_LF_HASH)), {SOURCE: UPSTREAM_LF_HASH}, {}),
            ([], []),
        )

    def test_refuses_historical_stale_and_crlf_hashes(self):
        for stale in (STALE_HASH, UPSTREAM_CRLF_HASH):
            with self.subTest(stale=stale):
                errors, known = validate_catalog_manifest_bytes(
                    catalog((SOURCE, stale)), {SOURCE: UPSTREAM_LF_HASH}, {},
                )
                self.assertEqual(known, [])
                self.assertEqual(errors, [f"{SOURCE}: recorded {stale}, actual {UPSTREAM_LF_HASH}"])

    def test_refuses_hand_spliced_manifest_that_omits_new_source(self):
        new = "res://scripts/economy/new.gd"
        errors, _ = validate_catalog_manifest_bytes(
            catalog((SOURCE, UPSTREAM_LF_HASH)), {SOURCE: UPSTREAM_LF_HASH, new: "a" * 64}, {},
        )
        self.assertEqual(errors, [f"{new}: missing from catalog sources"])

    def test_baseline_tolerates_only_the_same_mismatched_pair(self):
        baseline = {SOURCE: [STALE_HASH, UPSTREAM_LF_HASH]}
        errors, known = validate_catalog_manifest_bytes(
            catalog((SOURCE, STALE_HASH)), {SOURCE: UPSTREAM_LF_HASH}, baseline,
        )
        self.assertEqual(errors, [])
        self.assertEqual(len(known), 1)
        errors, known = validate_catalog_manifest_bytes(
            catalog((SOURCE, STALE_HASH)), {SOURCE: "b" * 64}, baseline,
        )
        self.assertEqual(known, [])
        self.assertIn("historical mismatch changed", errors[0])
        errors, known = validate_catalog_manifest_bytes(
            catalog((SOURCE, UPSTREAM_LF_HASH)), {SOURCE: UPSTREAM_LF_HASH}, baseline,
        )
        self.assertEqual(known, [])
        self.assertIn("remove its entry", errors[0])

    def test_catalog_recipe_fingerprints_tracked_sources_and_skips_its_outputs(self):
        with TemporaryDirectory() as directory:
            root = Path(directory)
            subprocess.run(["git", "init", "-q"], cwd=root, check=True)
            fixture = {
                BAKE: '\tfor dir in ["res://data", "res://scripts/economy"]:\n'
                      '\t\t_collect_sources(dir, files)\n'
                      '\t\tif name.get_extension() in ["gd","tres","json","csv"]:\n'
                      '\tfile.store_string(JSON.stringify(files,"\\t",true))\n',
                CACHE: 'const DIRECTORY := "res://data/loading_catalog_v1/"\n',
                f"{PROJECT}/data/native_binding_manifest.json": "{}",
                f"{PROJECT}/data/loading_catalog_v1/sources.json": "{}",
                f"{PROJECT}/data/.hidden/ignored.tres": "",
                f"{PROJECT}/data/ignored.png": "",
                f"{PROJECT}/scripts/economy/default.gd": "pass\n",
                f"{PROJECT}/scripts/ui/unrelated.gd": "pass\n",
            }
            for path, content in fixture.items():
                target = root / path
                target.parent.mkdir(parents=True, exist_ok=True)
                target.write_bytes(content.encode())
            subprocess.run(["git", "add", "."], cwd=root, check=True)
            self.assertEqual(
                _catalog_fingerprints(root, *_catalog_recipe(root)),
                {SOURCE: hashlib.sha256(b"{}").hexdigest(),
                 "res://scripts/economy/default.gd": hashlib.sha256(b"pass\n").hexdigest()},
            )

    def test_reads_new_source_extension_from_index_only_if_sparse(self):
        with TemporaryDirectory() as directory:
            root = Path(directory)
            subprocess.run(["git", "init", "-q"], cwd=root, check=True)
            source = "data/new-source.cfg"
            path = f"{PROJECT}/{source}"
            (root / path).parent.mkdir(parents=True)
            actual = b"setting=value\n"
            (root / path).write_bytes(actual)
            subprocess.run(["git", "add", "--", path], cwd=root, check=True)
            subprocess.run(["git", "update-index", "--skip-worktree", "--", path], cwd=root, check=True)
            (root / path).unlink()
            self.assertEqual(
                _catalog_fingerprints(root, ("data/",), {"cfg"}, "data/loading_catalog_v1"),
                {f"res://{source}": hashlib.sha256(actual).hexdigest()},
            )
            subprocess.run(["git", "update-index", "--no-skip-worktree", "--", path], cwd=root, check=True)
            with self.assertRaises(FileNotFoundError):
                _catalog_fingerprints(root, ("data/",), {"cfg"}, "data/loading_catalog_v1")

            object_id = subprocess.check_output(["git", "rev-parse", ":" + path], cwd=root).strip()
            subprocess.run(["git", "update-index", "--cacheinfo", f"120000,{object_id.decode()},{path}"],
                           cwd=root, check=True)
            subprocess.run(["git", "update-index", "--skip-worktree", "--", path], cwd=root, check=True)
            with self.assertRaises(FileNotFoundError):
                _catalog_fingerprints(root, ("data/",), {"cfg"}, "data/loading_catalog_v1")

    def test_bootstrap_only_recovers_native_binding_debt_from_original_tree(self):
        with TemporaryDirectory() as directory:
            root = Path(directory)
            expected = hashlib.sha256(CANONICAL_BINDINGS).hexdigest()
            stage_sources(root, {
                BAKE: b'\tfor dir in ["res://data"]:\n'
                      b'\t\t_collect_sources(dir, files)\n'
                      b'\t\tif name.get_extension() in ["json"]:\n'
                      b'\tfile.store_string(JSON.stringify(files,"\\t",true))\n',
                CACHE: b'const DIRECTORY := "res://data/loading_catalog_v1/"\n',
                f"{PROJECT}/data/native_binding_manifest.json": CANONICAL_BINDINGS,
                f"{PROJECT}/data/loading_catalog_v1/sources.json":
                    catalog((SOURCE, STALE_HASH), ("res://data/other.json", "a" * 64)),
                f"{PROJECT}/data/other.json": b"{}\n",
            })
            base = subprocess.check_output(["git", "write-tree"], text=True, cwd=root).strip()
            (root / f"{PROJECT}/data/native_binding_manifest.json").write_bytes(b"mutated\n")
            self.assertEqual(catalog_baseline_at(root, base), {SOURCE: [STALE_HASH, expected]})


if __name__ == "__main__":
    unittest.main()
