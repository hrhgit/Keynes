import subprocess
import unittest
from pathlib import Path
from tempfile import TemporaryDirectory
from urllib.parse import quote

from check_markdown_links import LinkProblem, markdown_baseline_at, validate_markdown_links

FEATURE_INDEX = "docs/architecture/feature-status.md"
CURRENT_STATE = "docs/architecture/current-state.md"
VOLUME = "docs/architecture/feature-status-01.md"
LEGACY_ANCHOR = "正式会话的推进镜像与脚本2026-11-26"
FEATURE_LINK = f"feature-status.md#{LEGACY_ANCHOR}"
HISTORICAL_LINK = f"经济停等的本机运行条件见[专项核查]({FEATURE_LINK})。\n"
FEATURE_HEADING = "## 正式会话的推进、镜像与脚本（2026-11-26）\n"


def split_feature_status(index_alias: str) -> list[LinkProblem]:
    """Use the PR #11 link with and without its compatibility anchor in the index."""
    return markdown_fixture({
        CURRENT_STATE: HISTORICAL_LINK,
        FEATURE_INDEX: f"# 专项现状与验证记录\n\n{index_alias}\n"
                       f"[目录](feature-status-01.md#{LEGACY_ANCHOR})\n",
        VOLUME: FEATURE_HEADING,
    })


def markdown_fixture(files: dict[str, str]) -> list[LinkProblem]:
    with TemporaryDirectory() as directory:
        root = Path(directory)
        for name, content in files.items():
            path = root / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(content, encoding="utf-8")
        return validate_markdown_links(root, set(files))


class MarkdownLinkTests(unittest.TestCase):
    def test_accepts_pr_11_link_when_split_index_keeps_its_alias(self):
        self.assertEqual(split_feature_status(f'<a id="{LEGACY_ANCHOR}"></a>'), [])

    def test_refuses_pr_11_link_when_split_index_loses_its_alias(self):
        self.assertEqual(split_feature_status(""), [
            LinkProblem(CURRENT_STATE, 1, FEATURE_LINK, "missing Markdown anchor"),
        ])

    def test_accepts_github_headings_and_relative_markdown_syntax(self):
        encoded = quote("中文-代码_name-1")
        errors = markdown_fixture({
            "docs/a.md": "[named anchor](/docs/b.md#kept)\n"
                         f"[second heading](b.md?render=1#{encoded})\n"
                         "[alternate heading][ref]\n"
                         "[ref]: <./b.md#setext-heading> \"Title\"\n"
                         "![image](../assets/example(foo).svg)\n"
                         "![image](<../assets/example(a.svg> \"Unpaired ) in title\")\n"
                         "<img src='../assets/File%20Name.svg' alt='demo'>\n"
                         "[directory README](../manual/#quick-start)\n",
            "docs/b.md": "# 中文： \x60代码_name\x60\n\n# 中文： \x60代码_name\x60\n\n"
                         "<a name='kept'></a>\n\nSetext Heading\n------\n",
            "manual/README.md": "## Quick Start\n",
            "assets/example(foo).svg": "",
            "assets/example(a.svg": "",
            "assets/File Name.svg": "",
        })
        self.assertEqual(errors, [])

    def test_ignores_code_samples_comments_and_external_links(self):
        self.assertEqual(markdown_fixture({
            "README.md": "# Intro\n\n\x60\x60\x60\x60md\n[one](missing.md)\n\x60\x60\x60\n[two](missing.md)\n"
                         "\x60\x60\x60\x60\n\n"
                         "    [three](missing.md)\n\n"
                         "> ~~~markdown\n> [four](missing.md)\n> ~~~\n\n"
                         "Write \x60[five](missing.md)\x60 as code.\n"
                         "Write \x60<!--\x60 to start a comment.\n"
                         "<!-- [six](missing.md)\n[seven](missing.md) -->\n"
                         "[external](https://example.org/nowhere#none)\n"
                         "[protocol relative](//example.org/none)\n",
        }), [])

    def test_refuses_wrong_case_and_unknown_heading_suffix(self):
        self.assertEqual(markdown_fixture({
            "README.md": "[wrong file](DOC.md)\n[wrong anchor](doc.md#intro-1 \"See )\")\n",
            "doc.md": "# Intro\n",
        }), [
            LinkProblem("README.md", 1, "DOC.md", "missing repository path"),
            LinkProblem("README.md", 2, "doc.md#intro-1", "missing Markdown anchor"),
        ])

    def test_checks_multiline_inline_links_and_reference_definitions(self):
        self.assertEqual(markdown_fixture({
            "README.md": "[inline](\n  missing-inline.md\n  \"Title\"\n)\n\n"
                         "[ref]:\n  <missing-reference.md>\n  \"Title\"\n\n"
                         "[reference][ref]\n",
        }), [
            LinkProblem("README.md", 1, "missing-inline.md", "missing repository path"),
            LinkProblem("README.md", 10, "missing-reference.md", "missing repository path"),
        ])

    def test_preserves_literal_backticks_in_link_and_html_destinations(self):
        self.assertEqual(markdown_fixture({
            "README.md": "[link](doc\x60\x60name\x60\x60.md#heading)\n"
                         "<a href='doc\x60name\x60.md#heading'>HTML link</a>\n"
                         "[reference][ref]\n"
                         "[ref]: <doc\x60name\x60.md#heading>\n",
            "doc\x60\x60name\x60\x60.md": "# Heading\n",
            "doc\x60name\x60.md": "# Heading\n",
        }), [])

    def test_links_inside_multiline_code_spans_and_across_paragraphs_are_ignored(self):
        self.assertEqual(markdown_fixture({
            "README.md": "A literal \x60prefix\n [x](missing.md)\x60.\n\n"
                         "[fragment](\n\nmissing.md\n)\n",
        }), [])

    def test_bootstrap_uses_the_original_tree_and_counts_each_broken_link(self):
        with TemporaryDirectory() as directory:
            root = Path(directory)
            subprocess.run(["git", "init", "-q"], cwd=root, check=True)
            source = root / "README.md"
            source.write_text("[old](missing.md)\n[duplicate](missing.md)\n", encoding="utf-8")
            subprocess.run(["git", "add", "--", source.name], cwd=root, check=True)
            base = subprocess.check_output(["git", "write-tree"], text=True, cwd=root).strip()
            source.write_text("[introduced](different.md)\n", encoding="utf-8")
            key = LinkProblem(source.name, 1, "missing.md", "missing repository path").baseline_key
            self.assertEqual(markdown_baseline_at(root, base), {key: 2})


if __name__ == "__main__":
    unittest.main()
