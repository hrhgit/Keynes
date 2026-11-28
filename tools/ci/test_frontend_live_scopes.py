import unittest

from check_script_native_access import frontend_live_read_violations


class FrontendLiveScopes(unittest.TestCase):
    file = "scripts/ui/calendar.gd"

    def test_inner_published_local_does_not_shadow_a_later_member_read(self):
        source = """var _economy_facade: EconomyFacade
func redraw(preview):
	if preview:
		var _economy_facade: PublishedView = preview
		return _economy_facade.report()
	return _economy_facade.report()
"""
        errors = frontend_live_read_violations(self.file, source, {})
        self.assertEqual(len(errors), 1, errors)
        self.assertIn(self.file + ":6:", errors[0])

    def test_reflective_read_on_explicit_self_uses_member_even_with_shadow(self):
        source = """var _economy_facade: EconomyFacade
func redraw(_economy_facade: PublishedView):
	var preview = _economy_facade.call("report")
	return self._economy_facade.call("report")
"""
        errors = frontend_live_read_violations(self.file, source, {})
        self.assertEqual(len(errors), 1, errors)
        self.assertIn(self.file + ":4:", errors[0])

    def test_multiline_parameter_list_keeps_its_published_parameter_in_scope(self):
        source = """var _economy_facade: EconomyFacade
func redraw(
    _economy_facade: PublishedView
):
    return _economy_facade.report()
"""
        self.assertEqual(frontend_live_read_violations(self.file, source, {}), [])

    def test_incomplete_report_expression_reports_its_location(self):
        for bad, diagnostic in [("_economy_facade.report(", "unclosed ("),
                                ("_economy_facade.call(\"report\"]", "unexpected ]"),
                                ('"report', "unterminated string")]:
            source = "func redraw():\n    return " + bad
            errors = frontend_live_read_violations(self.file, source, {})
            self.assertEqual(len(errors), 1, errors)
            self.assertIn(self.file + ":2: " + diagnostic, errors[0])

    def test_incomplete_declaration_reports_its_location(self):
        for source, line in [
            ("var\nfunc redraw():\n\tpass", 1),
            ("func redraw():\n\tvar", 2),
            ("class Preview:\n\tvar", 2),
        ]:
            with self.subTest(source=source):
                errors = frontend_live_read_violations(self.file, source, {})
                self.assertEqual(len(errors), 1, errors)
                self.assertIn(self.file + f":{line}:", errors[0])


if __name__ == "__main__":
    unittest.main()
