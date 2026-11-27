#!/usr/bin/env python3
"""Check repository-relative Markdown links and GitHub-style Markdown anchors.

Checks inline, reference and HTML anchor/image links, excluding code samples.
Links to tracked paths are checked even when the destination was not checked
out. Only Markdown targets use the heading and custom-anchor check.
"""
from __future__ import annotations

import argparse
import json
import posixpath
import re
import subprocess
import sys
from collections import Counter
from dataclasses import dataclass
from html import unescape
from html.parser import HTMLParser
from pathlib import Path, PurePosixPath
from unicodedata import category
from urllib.parse import unquote, urlsplit

from guard_baselines import previous_baseline

ROOT = Path(__file__).resolve().parents[2]
BASELINE = "tools/ci/markdown_links_baseline.json"
CODE_SPAN = re.compile(r"(?<!\x60)(\x60+)(?!\x60)(.*?)" r"(?<!\x60)\1(?!\x60)")
ESCAPE = re.compile(r"""\\([!"#$%&'()*+,\-./:;<=>?@\[\]\\^_{}|~]|\x60)""")
FENCE = re.compile(r"^\s*(\x60{3,}|~{3,})(.*)$")
ATX_HEADING = re.compile(r"^ {0,3}#{1,6}(?:\s+|$)(.*)$")
REFERENCE = re.compile(r"^ {0,3}\[(?!\^)([^\[\]]+)\]:\s*(.*)$")
LINK_START = re.compile(r"\\.|(\[)")
HTML_TAG = re.compile(r"<[a-zA-Z/][^<>]*>")


@dataclass(frozen=True)
class LinkProblem:
    file: str
    line: int
    target: str
    reason: str

    @property
    def baseline_key(self) -> str:
        return f"{self.file} | {self.target} | {self.reason}"

    def __str__(self) -> str:
        return f"{self.file}:{self.line}: {self.reason}: {self.target}"


class _HtmlLinks(HTMLParser):
    def __init__(self) -> None:
        super().__init__()
        self.anchors: set[str] = set()
        self.targets: list[str] = []

    def handle_starttag(self, tag: str, attrs: list[tuple[str, str | None]]) -> None:
        values = dict(attrs)
        if values.get("id"):
            self.anchors.add(values["id"])
        if tag == "a" and values.get("name"):
            self.anchors.add(values["name"])
        attr = {"a": "href", "img": "src", "source": "src"}.get(tag)
        if attr and values.get(attr):
            self.targets.append(values[attr])


def _visible_lines(text: str) -> list[str]:
    """Mask comments and code blocks without changing source line numbers."""
    lines = []
    fence = ""
    comment = False
    indent_code = False
    for source in text.splitlines():
        line = re.sub(r"^(?: {0,3}> ?)+", "", source)
        marker = FENCE.match(line)
        if fence:
            if marker and marker[1][0] == fence[0] and len(marker[1]) >= len(fence) and not marker[2].strip():
                fence = ""
            lines.append("")
            continue
        if marker and not comment:
            fence = marker[1]
            lines.append("")
            continue
        if not comment and line.startswith(("    ", "\t")) and (indent_code or not lines or not lines[-1]):
            indent_code = True
            lines.append("")
            continue
        indent_code = False
        if comment:
            _, end, line = line.partition("-->")
            comment = not end
        while (start := CODE_SPAN.sub(lambda match: "x" * len(match[0]), line).find("<!--")) != -1:
            end = line.find("-->", start + 4)
            comment = end == -1
            line = line[:start] if comment else line[:start] + line[end + 3:]
        lines.append(line)
    return lines


def _unescape(value: str) -> str:
    return unescape(ESCAPE.sub(r"\1", value))


def _heading_id(text: str) -> str:
    slug = []
    for char in text.strip().lower():
        if char == " ":
            slug.append("-")
        elif char in "-_" or category(char)[0] in "LM" or category(char) in {"Nd", "Nl", "Pc"}:
            slug.append(char)
    return "".join(slug)


def _closing(text: str, start: int, left: str, right: str) -> int | None:
    depth, index = 1, start + 1
    enclosed = ""
    while index < len(text):
        char = text[index]
        if char == "\\":
            index += 2
            continue
        if enclosed:
            if char == enclosed:
                enclosed = ""
        elif left == "(" and depth == 1 and char == "<" and not text[start + 1:index].strip():
            enclosed = ">"
        elif left == "(" and depth == 1 and char in "\"'" and text[index - 1].isspace():
            enclosed = char
        elif char == left:
            depth += 1
        elif char == right:
            depth -= 1
            if not depth:
                return index
        index += 1
    return None


def _destination(spec: str) -> str | None:
    spec = spec.strip()
    match = re.match(r"^<([^<>]*)>|^((?:\\.|[^\s\\])+)", spec)
    if not match:
        return None
    rest = spec[match.end():].strip()
    if rest and not ((rest[0], rest[-1]) in {('"', '"'), ("'", "'"), ("(", ")")} and len(rest) > 1):
        return None
    return _unescape(match[1] if match[1] is not None else match[2])


def _label(value: str) -> str:
    return " ".join(_unescape(value).casefold().split())


def _inline_links(line: str, references: dict[str, str]):
    """Yield a link's label positions, end position and destination."""
    resume = 0
    for match in LINK_START.finditer(line):
        if match[1] is None or match.start() < resume:
            continue
        start = match.start()
        end = _closing(line, start, "[", "]")
        if end is None:
            continue
        after_label = end + 1
        following = line[after_label:after_label + 1]
        after_link = after_label
        if following == "(":
            close = _closing(line, after_label, "(", ")")
            if close is None:
                continue
            target = _destination(line[after_label + 1:close])
            after_link = close + 1
        else:
            label = line[start + 1:end]
            if following == "[":
                close = _closing(line, after_label, "[", "]")
                if close is None:
                    continue
                label = line[after_label + 1:close] or label
                after_link = close + 1
            target = references.get(_label(label))
        if target is not None:
            resume = after_link
            yield start, end, after_link, target


def _heading_text(heading: str, references: dict[str, str]) -> str:
    heading = re.sub(r"\s+#+\s*$", "", heading)
    # Preserve literal contents of code spans and remove the link destinations.
    code = []

    def code_placeholder(match: re.Match) -> str:
        code.append(match[2])
        return f"\0{len(code) - 1}\0"

    heading = HTML_TAG.sub("", CODE_SPAN.sub(code_placeholder, heading))
    for start, end, after, _ in reversed(list(_inline_links(heading, references))):
        heading = heading[:start] + heading[start + 1:end] + heading[after:]
    heading = re.sub(r"(?<!\w)_{1,3}(\S(?:.*?\S)?)_{1,3}(?!\w)", r"\1", heading)
    return re.sub(r"\0(\d+)\0", lambda match: code[int(match[1])], _unescape(heading))


def _document(text: str) -> tuple[set[str], list[tuple[int, str]]]:
    lines = _visible_lines(text)
    references = {}
    definitions = set()
    for index, line in enumerate(lines):
        reference = REFERENCE.match(line)
        if reference and (target := _destination(reference[2])) is not None:
            references.setdefault(_label(reference[1]), target)
            definitions.add(index)
    html = _HtmlLinks()
    headings = set()
    links = []
    paragraph = ""
    for index, line in enumerate(lines):
        if index in definitions:
            paragraph = ""
            continue
        masked = CODE_SPAN.sub(lambda match: "x" * len(match[0]), line)
        atx = ATX_HEADING.match(line)
        heading = atx[1] if atx else ""
        if not atx and paragraph and re.fullmatch(r" {0,3}(?:=+|-+)\s*", line):
            heading = paragraph
        paragraph = "" if atx or heading else line.strip()
        if heading:
            base = _heading_id(_heading_text(heading, references))
            anchor, duplicate = base, 0
            while anchor in headings:
                duplicate += 1
                anchor = f"{base}-{duplicate}"
            headings.add(anchor)
        html.feed(masked + "\n")
        links.extend((index + 1, target) for target in html.targets)
        html.targets.clear()
        for start, end, _, target in _inline_links(masked, references):
            links.append((index + 1, target))
            links.extend((index + 1, inner) for *_, inner in _inline_links(masked[start + 1:end], references))
    return headings | html.anchors, links


def _local_target(source: str, target: str) -> tuple[str, str] | None:
    url = urlsplit(target)
    if url.scheme or url.netloc or target.startswith("//"):
        return None
    relative = unquote(url.path)
    if not relative:
        path = source
    elif relative.startswith("/"):
        path = posixpath.normpath(relative.lstrip("/"))
    else:
        path = posixpath.normpath(posixpath.join(posixpath.dirname(source), relative))
    return path, unquote(url.fragment)


def validate_markdown_links(root: Path, tracked_paths: set[str]) -> list[LinkProblem]:
    markdown = {path for path in tracked_paths if PurePosixPath(path).suffix.lower() == ".md"}
    directories = {parent.as_posix() for path in tracked_paths for parent in PurePosixPath(path).parents}
    documents = {}
    problems = []
    for path in sorted(markdown):
        try:
            documents[path] = _document((root / path).read_text(encoding="utf-8"))
        except (OSError, UnicodeError):
            problems.append(LinkProblem(path, 1, path, "could not read tracked Markdown"))
    for source, (_, destinations) in documents.items():
        for line, target in destinations:
            try:
                local = _local_target(source, target)
            except ValueError:
                continue  # This is not a recognizable relative URI.
            if local is None:
                continue
            path, anchor = local
            shown = unquote(target)
            if path not in tracked_paths and path not in directories:
                problems.append(LinkProblem(source, line, shown, "missing repository path"))
                continue
            if path in directories:
                path = posixpath.join(path, "README.md").removeprefix("./")
            if anchor and path in documents and anchor not in documents[path][0]:
                problems.append(LinkProblem(source, line, shown, "missing Markdown anchor"))
    return problems


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=ROOT)
    root = parser.parse_args().root
    try:
        raw = subprocess.check_output(["git", "ls-files", "-z"], cwd=root)
        tracked = set(raw.decode("utf-8").split("\0")[:-1])
        problems = validate_markdown_links(root, tracked)
        baseline = json.loads((root / BASELINE).read_text(encoding="utf-8"))
        if not isinstance(baseline, dict) or any(type(count) is not int or count < 1 for count in baseline.values()):
            raise ValueError(f"{BASELINE}: expected positive occurrence counts")
        previous = previous_baseline(root, BASELINE)
        errors = []
        if previous is not None:
            errors.extend(f"{BASELINE}: new or increased historical entry: {key}"
                          for key, count in baseline.items() if count > previous.get(key, 0))
        seen = Counter()
        for problem in problems:
            key = problem.baseline_key
            seen[key] += 1
            if seen[key] > baseline.get(key, 0):
                errors.append(str(problem))
        errors.extend(f"{BASELINE}: shrink fixed historical entry: {key}"
                      for key, count in baseline.items() if seen[key] < count)
    except (OSError, ValueError, subprocess.CalledProcessError) as error:
        print(error, file=sys.stderr)
        return 1
    for error in errors:
        print(error, file=sys.stderr)
    known = sum((seen & Counter(baseline)).values())
    print(f"Markdown links: {len(errors)} violations, {known} historical broken links")
    return int(bool(errors))


if __name__ == "__main__":
    sys.exit(main())
