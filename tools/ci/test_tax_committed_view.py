"""Exercise the three tax presentation entry points against live-read regressions."""
import unittest

import check_committed_views as views
from cpp_source import read_cpp_source


def tax_sources():
    src = views.ROOT / "gdext/src"
    return [views.code_only(read_cpp_source(src / name))
            for name in ("world_ext_country.cpp", "country_runtime_queries_tax.cpp")]


class TaxCommittedViewTests(unittest.TestCase):
    def test_tax_display_rejects_live_reads(self):
        sources = tax_sources()
        self.assertEqual(views.tax_display_violations(*sources), [])
        changes = [
            (0, "country->tax_policy_snapshot(handle, &read)", "country_query_runtime()->tax_policy_snapshot(handle)"),
            (0, "country->cell_tax_policy_snapshot(cell_idx, &read)", "country->cell_tax_policy_snapshot(cell_idx)"),
            (0, "= get_country_tax_policy_snapshot(handle);", "= runtime->tax_policy_snapshot(handle);"),
            (0, "published_fiscal ? published_tax_country() : detail", "country_query_runtime()"),
            (0, "summary = runtime->country_summary(handle)", "summary = detail->country_summary(handle)"),
            (0, "if (uses_published_modifier_tax())", "if (!uses_published_modifier_tax())"),
            (0, ": _modifier_read_country;", ": _runtime_host->country_asset_snapshot();"),
            (0, "return frozen->lookup(", "return _economy_modifier_view->lookup("),
            (0, "return country_runtime_from(_country_runtime);", "return country_query_runtime();"),
            (1, "effective_tax_for_display(read, handle, -1", "effective_tax_for_display(nullptr, handle, -1"),
            (1, "effective_tax_for_display(read, handle, cell", "effective_tax_for_display(nullptr, handle, cell"),
            (1, "return read->frozen_rate(", "return _modifier_runtime->frozen_rate("),
            (1, "value = read->modifier_value(", "value = _modifier_runtime->modifier_value("),
        ]
        for index, before, after in changes:
            with self.subTest(bypass=after):
                self.assertIn(before, sources[index])
                changed = sources.copy()
                changed[index] = changed[index].replace(before, after, 1)
                self.assertTrue(views.tax_display_violations(*changed))


if __name__ == "__main__":
    unittest.main()
