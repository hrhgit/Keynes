"""Test the packed tax amount/mode collision and the exact master exception."""

import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

from check_tax_row_keys import LEGACY_PATH, tax_row_key_violations, validate_tax_row_baseline


TAX_ROWS = LEGACY_PATH
PACKED_ROWS = """
    std::unordered_map<uint64_t, int32_t> settlement_default_rows;
    const auto ensure_default_row = [&](int32_t country, int32_t kind,
                                        int32_t base_rate,
                                        int32_t base_mode, bool display_only) -> int32_t {
        const uint64_t settlement_key =
            (static_cast<uint64_t>(static_cast<uint32_t>(country)) << 40U) |
            (static_cast<uint64_t>(static_cast<uint8_t>(kind)) << 32U) |
            (static_cast<uint64_t>(static_cast<uint8_t>(base_mode & 0xff))
             << 24U) |
            static_cast<uint32_t>(base_rate);
        int32_t &row_number = display_only
            ? display_default_rows[std::make_tuple(country, kind, base_rate, base_mode)]
            : settlement_default_rows[settlement_key];
        return row_number;
    };
    const auto compile_cell_policy = [&](int32_t cell, bool display_only) {
        const int32_t row_id = ensure_default_row(
            country, kind, resolved_rate, resolved_mode, display_only);
    };
    compile_cell_policy(cell, false);
    compile_cell_policy(cell, false);
    compile_cell_policy(cell, true);
"""
MASTER_ENTRY = {TAX_ROWS: ["7dcd33574ceaede7d250cdcedee50519b6b83e8297e2497ba40f193cbab414c1"]}
FIXED_ROWS = """
    struct DefaultRowKey {
        int32_t country;
        int32_t kind;
        int32_t amount;
        int32_t mode;
        bool operator==(const DefaultRowKey &) const = default;
    };
    using DefaultRows = std::unordered_map<DefaultRowKey, int32_t, DefaultRowHash>;
    DefaultRows settlement_default_rows;
    const auto ensure_default_row = [&](int32_t country, int32_t kind,
                                        int32_t base_rate, int32_t base_mode) {
        const DefaultRowKey key{country, kind, base_rate, base_mode};
        return settlement_default_rows[key];
    };
"""


class TaxRowKeyTests(unittest.TestCase):
    def test_rejects_the_actual_packed_cache(self):
        errors, retained = tax_row_key_violations({TAX_ROWS: PACKED_ROWS}, {})
        self.assertEqual(len(errors), 1)
        self.assertIn("settlement_default_rows uses a scalar tax row key", errors[0])
        self.assertEqual(retained, {})

    def test_accepts_full_width_key_and_other_single_id_cache(self):
        source = FIXED_ROWS + "std::unordered_map<uint64_t, uint32_t> compiled_policy_ids;"
        self.assertEqual(tax_row_key_violations({TAX_ROWS: source}, {}), ([], {}))

    def test_rejects_packed_key_using_integer_type_aliases(self):
        declarations = [
            "using PackedKey = uint64_t;",
            "typedef std::uint64_t RawKey;\nusing PackedKey = RawKey;",
        ]
        for declaration in declarations:
            with self.subTest(declaration=declaration):
                rows = PACKED_ROWS.replace("unordered_map<uint64_t,", "unordered_map<PackedKey,")
                errors, _ = tax_row_key_violations({TAX_ROWS: declaration + rows}, MASTER_ENTRY)
                self.assertTrue(any("settlement_default_rows uses a scalar tax row key" in error
                                    for error in errors))

    def test_accepts_a_single_id_lookup_in_the_default_rows_file(self):
        path = "gdext/src/economy_cell_tax_default_rows.h"
        source = """
            std::unordered_map<uint64_t, Policy> policy_by_id;
            const auto policy = policy_by_id.find(policy_id);
        """
        self.assertEqual(tax_row_key_violations({path: source}, {}), ([], {}))

    def test_accepts_ordinary_lookup_and_insert_by_a_country_handle(self):
        path = "gdext/src/economy_cell_tax_default_rows.h"
        source = """
            std::unordered_map<uint64_t, Policy> lookup;
            lookup.insert({country_handle, row});
            const auto policy = lookup.find(country_handle);
        """
        self.assertEqual(tax_row_key_violations({path: source}, {}), ([], {}))

    def test_accepts_explicit_pairs_with_simple_id_keys(self):
        path = "gdext/src/economy_cell_tax_default_rows.h"
        source = """
            std::unordered_map<uint64_t, Policy> lookup;
            lookup.insert(std::make_pair(entry.country_handle, row));
            lookup.insert(std::pair<uint64_t, Policy>{0xFFu, row});
        """
        self.assertEqual(tax_row_key_violations({path: source}, {}), ([], {}))

    def test_rejects_packed_insert_into_a_single_id_named_table(self):
        path = "gdext/src/economy_cell_tax_default_rows.h"
        source = """
            std::unordered_map<uint64_t, Policy> policy_by_id;
            const auto policy = policy_by_id.find(policy_id);
            policy_by_id.insert({(country_handle << 24U) | amount, row});
        """
        errors, retained = tax_row_key_violations({path: source}, {})
        self.assertTrue(any("policy_by_id uses a scalar tax row key" in error for error in errors))
        self.assertEqual(retained, {})

    def test_header_only_id_table_is_not_a_packed_key(self):
        header = "gdext/src/economy_cell_tax_default_rows.h"
        impl = "gdext/src/economy_cell_tax_default_rows.cpp"
        self.assertEqual(tax_row_key_violations({
            header: "std::unordered_map<uint64_t, Policy> policy_by_id;",
            impl: "auto read(uint64_t id) { return policy_by_id.at(id); }",
        }, {}), ([], {}))

    def test_rejects_brace_initialized_and_hint_inserted_keys(self):
        path = "gdext/src/economy_cell_tax_default_rows.cpp"
        declaration = "std::unordered_map<uint64_t, Policy> default_rows;\n"
        for use in (
            "const uint64_t row_id{(uint64_t(country_id) << 24) | amount};\n"
            "default_rows.emplace(row_id, row);",
            "auto it = default_rows.find(country_id);\n"
            "default_rows.emplace_hint(it, (uint64_t(country_id) << 24) | amount, row);",
        ):
            with self.subTest(use=use):
                errors, _ = tax_row_key_violations({path: declaration + use}, {})
                self.assertTrue(errors, use)

    def test_packed_outer_key_is_detected_across_blocks(self):
        path = "gdext/src/economy_cell_tax_default_rows.cpp"
        src = """std::map<uint64_t, Row> rows;
            void store() {
                const uint64_t key{(country << 24) | amount};
                Row defaults{}; if (active) { rows[key] = value; }
            }"""
        self.assertTrue(tax_row_key_violations({path: src}, {})[0])
        # The same spelling in a different function is an ordinary handle.
        sibling = src.replace("rows[key] = value;", "").replace(
            "void store()", "void build()") + "void get(uint64_t key) { rows[key]; }"
        self.assertEqual(tax_row_key_violations({path: sibling}, {}), ([], {}))

    def test_structured_pair_key_can_hold_independent_fields(self):
        path = "gdext/src/economy_cell_tax_default_rows.cpp"
        source = """std::map<std::pair<uint32_t, uint32_t>, Row> rows;
                    rows.emplace(std::make_pair(country, flags << 4 | 1), row);"""
        self.assertEqual(tax_row_key_violations({path: source}, {}), ([], {}))

    def test_packed_key_into_a_map_declared_using_a_type_alias(self):
        path = "gdext/src/economy_cell_tax_default_rows.cpp"
        source = """using Table = std::map<uint64_t, Policy>;
                    Table rows;
                    rows.emplace((country << 24) | amount, value);"""
        self.assertTrue(tax_row_key_violations({path: source}, {})[0])

    def test_row_value_can_be_calculated_by_a_lambda(self):
        path = "gdext/src/economy_cell_tax_default_rows.cpp"
        source = """std::map<uint64_t, Policy> rows;
                    rows.emplace(id, [&]{ return make_policy(); }());"""
        self.assertEqual(tax_row_key_violations({path: source}, {}), ([], {}))

    def test_invalid_baseline_exits_with_a_source_location(self):
        script = Path(__file__).with_name("check_tax_row_keys.py")
        for malformed, line in (("[]", 1), ('{\n  "a":', 2), ('{"a":[{}]}', 1)):
            with self.subTest(malformed=malformed), tempfile.TemporaryDirectory() as tmp:
                path = Path(tmp, "tools/ci/tax_row_keys_baseline.json")
                path.parent.mkdir(parents=True)
                path.write_text(malformed, encoding="utf-8")
                result = subprocess.run([sys.executable, script, "--root", tmp],
                                        capture_output=True, text=True)
                self.assertEqual(result.returncode, 1)
                self.assertIn(f"tax_row_keys_baseline.json:{line}:", result.stdout)
                self.assertNotIn("Traceback", result.stderr)

    def test_unfinished_cache_access_reports_file_and_line(self):
        path = "gdext/src/economy_cell_tax_default_rows.cpp"
        errors, _ = tax_row_key_violations({path:
            "std::unordered_map<uint64_t, Policy> default_rows;\n"
            "default_rows.emplace_hint(it, (country << 24) | amount"
        }, {})
        self.assertRegex(" ".join(errors), r"economy_cell_tax_default_rows.cpp:2:.*incomplete")

    def test_rejects_an_id_named_key_that_was_computed_by_packing(self):
        path = "gdext/src/economy_cell_tax_default_rows.h"
        source = """
            std::unordered_map<uint64_t, Policy> policy_by_id;
            const auto policy_id = (country_handle << 24U) | amount;
            policy_by_id.insert(std::make_pair(policy_id, row));
        """
        errors, _ = tax_row_key_violations({path: source}, {})
        self.assertTrue(any("policy_by_id uses a scalar tax row key" in error for error in errors))

    def test_rejects_packing_in_a_table_named_like_a_single_id_index(self):
        path = "gdext/src/economy_cell_tax_default_rows.h"
        source = PACKED_ROWS.replace("settlement_default_rows", "policy_by_id")
        errors, _ = tax_row_key_violations({path: source}, {})
        self.assertTrue(any("policy_by_id uses a scalar tax row key" in error for error in errors))

    def test_the_master_key_collides_for_two_legal_absolute_amounts(self):
        country, kind, mode = 5, 3, 1
        low, high = 1, 16777217
        prefix = (country << 40) | (kind << 32) | (mode << 24)
        self.assertNotEqual(low, high)
        self.assertEqual(prefix | low, prefix | high)

    def test_accepts_tuple_with_four_separate_fields(self):
        source = "std::map<std::tuple<int32_t, int32_t, int32_t, int32_t>, int32_t> display_default_rows;"
        self.assertEqual(tax_row_key_violations({TAX_ROWS: source}, {}), ([], {}))

    def test_accepts_followup_array_with_four_separate_fields(self):
        source = """
            class CellTaxDefaultRows {
            public:
                int32_t &row_number(int32_t country, int32_t kind, int32_t amount, int32_t mode) {
                    return _rows[{country, kind, amount, mode}];
                }
            private:
                std::map<std::array<int32_t, 4>, int32_t> _rows;
            };
        """
        path = "gdext/src/economy_cell_tax_default_rows.h"
        self.assertEqual(tax_row_key_violations({path: source}, {}), ([], {}))

    def test_single_id_type_alias_is_legal_without_uses(self):
        path = "gdext/src/economy_cell_tax_default_rows.h"
        source = "using ByKey = std::unordered_map<std::uint64_t, int32_t>;"
        errors, _ = tax_row_key_violations({path: source}, {})
        # test-guard[assertion]: 单凭别名看不出键是否拼接，实际拼接写入由同组反例验证。
        self.assertEqual(errors, [])

    def test_baseline_only_keeps_the_exact_old_cache(self):
        self.assertEqual(tax_row_key_violations({TAX_ROWS: PACKED_ROWS}, MASTER_ENTRY), ([], MASTER_ENTRY))
        for source in (PACKED_ROWS.replace("24U", "23U"), PACKED_ROWS + PACKED_ROWS):
            with self.subTest(source=source):
                errors, _ = tax_row_key_violations({TAX_ROWS: source}, MASTER_ENTRY)
                self.assertTrue(errors)
        self.assertEqual(tax_row_key_violations({TAX_ROWS: FIXED_ROWS}, MASTER_ENTRY), ([], {}))

    def test_settlement_routing_is_measured_by_the_runtime_regression(self):
        source = PACKED_ROWS.replace("compile_cell_policy(cell, true)", "compile_cell_policy(cell, display_only)")
        # test-guard[assertion]: cell_tax_row_settlement_test.gd 核对展示地块的实际缓存条数和扣款，允许等价改写调用。
        self.assertEqual(tax_row_key_violations({TAX_ROWS: source}, MASTER_ENTRY), ([], MASTER_ENTRY))

    def test_refuses_added_or_increased_baseline_entries(self):
        self.assertEqual(validate_tax_row_baseline({}, MASTER_ENTRY), [])
        self.assertTrue(validate_tax_row_baseline(MASTER_ENTRY, {}))
        self.assertTrue(validate_tax_row_baseline({TAX_ROWS: MASTER_ENTRY[TAX_ROWS] * 2}, MASTER_ENTRY))


if __name__ == "__main__":
    unittest.main()
