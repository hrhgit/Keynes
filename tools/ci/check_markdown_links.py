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
from collections.abc import Callable
from dataclasses import dataclass
from html import unescape
from html.parser import HTMLParser
from io import BytesIO
from pathlib import Path, PurePosixPath
from unicodedata import category
from urllib.parse import unquote, urlsplit

from guard_baselines import previous_baseline

ROOT = Path(__file__).resolve().parents[2]
BASELINE = "tools/ci/markdown_links_baseline.json"
CODE_SPAN = re.compile(r"(?<!\x60)(\x60+)(?!\x60)(.*?)" r"(?<!\x60)\1(?!\x60)", re.S)
ESCAPE = re.compile(r"""\\([!"#$%&'()*+,\-./:;<=>?@\[\]\\^_{}|~]|\x60)""")
FENCE = re.compile(r"^ {0,3}(\x60{3,}|~{3,})(.*)$")
LIST_ITEM = re.compile(r"^ {0,3}(?:[-+*]|[0-9]{1,9}[.)])(?P<pad> +|$)")
THEMATIC_BREAK = re.compile(r"^ {0,3}([*_-])(?: *\1){2,} *$")
PRE_OPEN = re.compile(r"^ {0,3}<pre(?=[ >]|$)", re.IGNORECASE)
PRE_CLOSE = re.compile(r"</pre *>", re.IGNORECASE)
QUOTE_MARKER = re.compile(r" {0,3}> ?")
ATX_HEADING = re.compile(r"^ {0,3}#{1,6}(?:\s+|$)(.*)$")
REFERENCE = re.compile(r"^ {0,3}\[(?!\^)([^\[\]]+)\]:\s*(.*)$")
INLINE_START = re.compile(r"\\.|[\x60]+|\[|<")
HTML_TAG = re.compile(r"""</?[a-zA-Z][a-zA-Z0-9-]*(?=[\s/>])(?:[^<>'"]|'[^']*'|"[^"]*")*>""")


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


def _html_only(line: str) -> str:
    """Mask raw HTML text while retaining explicit HTML links and anchors."""
    visible = []
    end = 0
    for tag in HTML_TAG.finditer(line):
        visible.extend((" " * (tag.start() - end), tag[0]))
        end = tag.end()
    return "".join(visible)


def _preformatted_line(line: str, header: str | None) -> tuple[str, str | None, bool]:
    if header is not None:
        joined = header + line
        tag = HTML_TAG.match(joined, len(joined) - len(joined.lstrip()))
        if tag is None:
            return line, joined + "\n", True
        start = tag.end() - len(header)
    else:
        start = 0
    return line[:start] + _html_only(line[start:]), None, PRE_CLOSE.search(line[start:]) is None


def _paragraph_text(line: str) -> bool:
    return bool(line.strip()) and not line.lstrip().startswith("<") and not any(
        pattern.match(line) for pattern in (FENCE, LIST_ITEM, THEMATIC_BREAK, ATX_HEADING)
    )


def _visible_lines(text: str) -> list[str]:
    """Mask comments and code blocks without changing source line numbers."""
    lines = []
    fence = ""
    comment = False
    indent_code = False
    preformatted = False
    pre_header = None
    block_scope = (0, 0)
    lists_by_quote: dict[int, list[int]] = {}
    previous_quote = 0
    for source in text.splitlines():
        block_quote, block_column = block_scope
        quote_depth, quote_end = 0, 0
        while (not (fence or preformatted) or quote_depth < block_quote) and (
            quote := QUOTE_MARKER.match(source, quote_end)
        ):
            quote_depth += 1
            quote_end = quote.end()
        line = source[quote_end:].expandtabs(4)
        leading = len(line) - len(line.lstrip())
        if quote_depth < previous_quote:
            lists_by_quote = {depth: columns for depth, columns in lists_by_quote.items() if depth <= quote_depth}
        list_columns = lists_by_quote.setdefault(quote_depth, [])
        lazy = (quote_depth == previous_quote and lines and _paragraph_text(lines[-1]) and _paragraph_text(line))
        previous_quote = quote_depth
        if quote_depth < block_quote or (quote_depth == block_quote and leading < block_column and line.strip()):
            fence, preformatted, pre_header = "", False, None
        if not fence and not preformatted and line.strip():
            while list_columns and leading < list_columns[-1] and not lazy:
                list_columns.pop()
        column = list_columns[-1] if list_columns else 0
        if line.startswith(" " * column):
            line = line[column:]
        if fence:
            marker = FENCE.match(line)
            if marker and marker[1][0] == fence[0] and len(marker[1]) >= len(fence) and not marker[2].strip():
                fence = ""
            lines.append("")
            continue
        if not preformatted and not comment and line.startswith("    ") and (
            indent_code or not lines or not lines[-1].strip()
        ):
            indent_code = True
            lines.append("")
            continue
        indent_code = False
        if comment:
            _, end, line = line.partition("-->")
            comment = not end
        while True:
            comment_text = line if preformatted else CODE_SPAN.sub(lambda match: "x" * len(match[0]), line)
            start = comment_text.find("<!--")
            if start == -1:
                break
            end = line.find("-->", start + 4)
            comment = end == -1
            line = line[:start] if comment else line[:start] + line[end + 3:]
        if preformatted:
            visible, pre_header, preformatted = _preformatted_line(line, pre_header)
            lines.append(visible)
            continue
        item = LIST_ITEM.match(line)
        if item and not THEMATIC_BREAK.fullmatch(line):
            padding = len(item["pad"])
            indent = item.start("pad") + (padding if 1 <= padding <= 4 else 1)
            column += indent
            list_columns.append(column)
            line = line[indent:]
        if marker := FENCE.match(line):
            fence = marker[1]
            block_scope = quote_depth, column
            lines.append("")
            continue
        if PRE_OPEN.match(line):
            line, pre_header, preformatted = _preformatted_line(line, "")
            block_scope = quote_depth, column
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
        elif left == "[" and char == "\x60" and (code := CODE_SPAN.match(text, index)):
            index = code.end()
            continue
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
    match = re.match(r"^<([^<>\n]*)>|^((?:\\.|[^\s\\])+)", spec)
    if not match:
        return None
    rest = spec[match.end():].strip()
    if rest and not _is_title(rest):
        return None
    return _unescape(match[1] if match[1] is not None else match[2])


def _label(value: str) -> str:
    return " ".join(_unescape(value).casefold().split())


def _is_title(value: str) -> bool:
    return len(value) > 1 and (value[0], value[-1]) in {('"', '"'), ("'", "'"), ("(", ")")}


def _inline_links(text: str, references: dict[str, str], html: _HtmlLinks | None = None):
    """Yield a link's label positions, end position and destination."""
    resume = 0
    for match in INLINE_START.finditer(text):
        start = match.start()
        if start < resume:
            continue
        if match[0].startswith("\x60"):
            if code := CODE_SPAN.match(text, start):
                resume = code.end()
            continue
        if match[0] == "<":
            if tag := HTML_TAG.match(text, start):
                resume = tag.end()
                if html is not None:
                    html.feed(tag[0])
                    for target in html.targets:
                        yield start, start, resume, target
                    html.targets.clear()
            continue
        if match[0] != "[":
            continue
        end = _closing(text, start, "[", "]")
        if end is None:
            continue
        after_label = end + 1
        following = text[after_label:after_label + 1]
        after_link = after_label
        if following == "(":
            close = _closing(text, after_label, "(", ")")
            if close is None:
                continue
            target = _destination(text[after_label + 1:close])
            after_link = close + 1
        else:
            label = text[start + 1:end]
            if following == "[":
                close = _closing(text, after_label, "[", "]")
                if close is None:
                    continue
                label = text[after_label + 1:close] or label
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


def _reference_definitions(lines: list[str]) -> tuple[dict[str, str], set[int]]:
    references = {}
    definitions = set()
    for index, line in enumerate(lines):
        if index in definitions:
            continue
        reference = REFERENCE.match(line)
        if not reference:
            continue
        end = index
        destination = reference[2].strip()
        if not destination and index + 1 < len(lines):
            end += 1
            destination = lines[end].strip()
        target = _destination(destination)
        if target is None:
            continue
        if end + 1 < len(lines) and _is_title(lines[end + 1].strip()):
            end += 1
        references.setdefault(_label(reference[1]), target)
        definitions.update(range(index, end + 1))
    return references, definitions


def _inline_blocks(lines: list[str], definitions: set[int]):
    """Join soft line breaks without letting a destination cross a block boundary."""
    start = 0
    body = []
    for index, line in enumerate(lines):
        if not line.strip() or index in definitions or ATX_HEADING.match(line):
            if body:
                yield start, "\n".join(body)
                body = []
            if ATX_HEADING.match(line) and index not in definitions:
                yield index, line
            continue
        if not body:
            start = index
        body.append(line)
    if body:
        yield start, "\n".join(body)


def _document(text: str) -> tuple[set[str], list[tuple[int, str]]]:
    lines = _visible_lines(text)
    references, definitions = _reference_definitions(lines)
    html = _HtmlLinks()
    headings = set()
    links = []
    paragraph = ""
    for index, line in enumerate(lines):
        if index in definitions:
            paragraph = ""
            continue
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
    for index, text in _inline_blocks(lines, definitions):
        for start, end, _, target in _inline_links(text, references, html):
            line = index + 1 + text.count("\n", 0, start)
            links.append((line, target))
            links.extend((line + text.count("\n", start + 1, start + 1 + inner), nested)
                         for inner, _, _, nested in _inline_links(text[start + 1:end], references, html))
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
    return _link_problems(tracked_paths, lambda path: (root / path).read_text(encoding="utf-8"))


def _link_problems(tracked_paths: set[str], read_markdown: Callable[[str], str]) -> list[LinkProblem]:
    markdown = {path for path in tracked_paths if PurePosixPath(path).suffix.lower() == ".md"}
    directories = {parent.as_posix() for path in tracked_paths for parent in PurePosixPath(path).parents}
    documents = {}
    problems = []
    for path in sorted(markdown):
        try:
            documents[path] = _document(read_markdown(path))
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


def markdown_baseline_at(root: Path, ref: str) -> dict[str, int]:
    """Reproduce existing broken links from the versioned base tree."""
    tree = subprocess.check_output(["git", "ls-tree", "-r", "-z", ref], cwd=root)
    paths = set()
    object_ids = {}
    for entry in filter(None, tree.split(b"\0")):
        metadata, raw_path = entry.split(b"\t", 1)
        _, kind, object_id = metadata.split()
        path = raw_path.decode("utf-8")
        paths.add(path)
        if kind == b"blob" and PurePosixPath(path).suffix.lower() == ".md":
            object_ids[path] = object_id
    if not object_ids:
        return {}
    requested = list(dict.fromkeys(object_ids.values()))
    data = subprocess.check_output(["git", "cat-file", "--batch"], cwd=root,
                                   input=b"\n".join(requested) + b"\n")
    stream = BytesIO(data)
    contents = {}
    for expected in requested:
        header = stream.readline().split()
        if len(header) != 3 or header[:2] != [expected, b"blob"]:
            raise ValueError(f"git cat-file: expected Markdown blob {expected.decode()}")
        contents[expected] = stream.read(int(header[2]))
        if stream.read(1) != b"\n":
            raise ValueError(f"git cat-file: incomplete Markdown blob {expected.decode()}")
    problems = _link_problems(paths, lambda path: contents[object_ids[path]].decode("utf-8"))
    return dict(Counter(problem.baseline_key for problem in problems))


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
        previous = previous_baseline(root, BASELINE, markdown_baseline_at)
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
