"""Test the packed tax amount/mode collision and the exact master exception."""

import unittest

from check_tax_row_keys import LEGACY_PATH, _baseline_growth, tax_row_key_violations


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
        return settlement_default_rows[settlement_key];
    };
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

    def test_rejects_scalar_key_moved_into_a_default_row_helper_alias(self):
        path = "gdext/src/economy_cell_tax_default_rows.h"
        source = "using ByKey = std::unordered_map<std::uint64_t, int32_t>;"
        errors, _ = tax_row_key_violations({path: source}, MASTER_ENTRY)
        self.assertEqual(len(errors), 1)
        self.assertIn("ByKey uses a scalar tax row key", errors[0])

    def test_baseline_only_keeps_the_exact_old_cache(self):
        self.assertEqual(tax_row_key_violations({TAX_ROWS: PACKED_ROWS}, MASTER_ENTRY), ([], MASTER_ENTRY))
        for source in (PACKED_ROWS.replace("24U", "23U"), PACKED_ROWS + PACKED_ROWS):
            with self.subTest(source=source):
                errors, _ = tax_row_key_violations({TAX_ROWS: source}, MASTER_ENTRY)
                self.assertTrue(errors)
        self.assertEqual(tax_row_key_violations({TAX_ROWS: FIXED_ROWS}, MASTER_ENTRY), ([], {}))

    def test_refuses_added_or_increased_baseline_entries(self):
        self.assertEqual(_baseline_growth({}, MASTER_ENTRY), [])
        self.assertTrue(_baseline_growth(MASTER_ENTRY, {}))
        self.assertTrue(_baseline_growth({TAX_ROWS: MASTER_ENTRY[TAX_ROWS] * 2}, MASTER_ENTRY))


if __name__ == "__main__":
    unittest.main()
