"""Read, patch and restore Godot texture import settings for the Web build."""
from __future__ import annotations

import hashlib
import os
import re
import shutil
import subprocess
import sys
import time
from dataclasses import dataclass, field
from typing import Any


# --------------------------------------------------------------------------
# .import 读写
# --------------------------------------------------------------------------
SECTION_RE = re.compile(r"^\[([^\]]+)\]\s*$")


@dataclass
class ImportFile:
    res_path: str
    abspath: str
    importer: str = ""
    params: dict[str, str] = field(default_factory=dict)
    dests: list[str] = field(default_factory=list)
    raw: bytes = b""

    @classmethod
    def load(cls, res_path: str, abspath: str) -> "ImportFile":
        with open(abspath, "rb") as fh:
            raw = fh.read()
        text = raw.decode("utf-8", "surrogateescape")
        importer = ""
        params: dict[str, str] = {}
        dests: list[str] = []
        section = ""
        for line in text.splitlines():
            s = line.strip()
            m = SECTION_RE.match(s)
            if m:
                section = m.group(1)
                continue
            if section == "remap" and s.startswith("importer="):
                importer = s.split("=", 1)[1].strip().strip('"')
            elif section == "remap" and s.startswith("path") and "=" in s:
                v = s.split("=", 1)[1].strip().strip('"')
                if v.startswith("res://"):
                    dests.append(v)
            elif section == "deps" and s.startswith("dest_files="):
                body = s.split("=", 1)[1].strip().strip("[]")
                for part in body.split(","):
                    part = part.strip().strip('"')
                    if part.startswith("res://"):
                        dests.append(part)
            elif section == "params" and "=" in s:
                k, v = s.split("=", 1)
                params[k.strip()] = v.strip().strip('"')
        seen: set[str] = set()
        dests = [d for d in dests if not (d in seen or seen.add(d))]
        return cls(res_path, abspath, importer, params, dests, raw)

    def patched(self, changes: dict[str, str], removals: tuple[str, ...] = ()) -> bytes:
        """只改 [params] 里指定的键，其余字节原样保留（行尾/顺序/其它键都不动）。

        removals 里的键会被整行删掉（还原一个"原本不存在"的键时用）。
        """
        if not changes and not removals:
            return self.raw
        text = self.raw.decode("utf-8", "surrogateescape")
        nl = "\r\n" if "\r\n" in text else "\n"
        lines = text.split(nl)
        out: list[str] = []
        section = ""
        params_at = -1
        set_keys: set[str] = set()
        for line in lines:
            s = line.strip()
            m = SECTION_RE.match(s)
            if m:
                section = m.group(1)
                if section == "params":
                    params_at = len(out)
                out.append(line)
                continue
            if section == "params" and "=" in s:
                key = s.split("=", 1)[0].strip()
                if key in removals:
                    continue
                if key in changes:
                    out.append(f"{key}={changes[key]}")
                    set_keys.add(key)
                    continue
            out.append(line)
        missing = [k for k in changes if k not in set_keys]
        if missing:
            if params_at < 0:
                raise RuntimeError(f"{self.res_path}: .import 里没有 [params] 段")
            insert_at = len(out)
            for i in range(params_at + 1, len(out)):
                if SECTION_RE.match(out[i].strip()):
                    insert_at = i
                    break
            for off, key in enumerate(missing):
                out.insert(insert_at + off, f"{key}={changes[key]}")
        return nl.join(out).encode("utf-8", "surrogateescape")


# --------------------------------------------------------------------------
# 工具函数
# --------------------------------------------------------------------------
def sha256_file(path: str) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as fh:
        for chunk in iter(lambda: fh.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def dest_size(project: str, res_dest: str) -> int:
    p = os.path.join(project, res_dest.replace("res://", "").replace("/", os.sep))
    try:
        return os.path.getsize(p)
    except OSError:
        return -1


def human(n: int) -> str:
    if n < 0:
        return "?"
    x = float(n)
    for unit in ("B", "KB", "MB", "GB"):
        if abs(x) < 1024.0 or unit == "GB":
            return f"{n} B" if unit == "B" else f"{x:.2f} {unit}"
        x /= 1024.0
    return f"{x:.2f} GB"


def find_godot(repo: str, explicit: str) -> str:
    if explicit and os.path.isfile(explicit):
        return explicit
    env = os.environ.get("GODOT_BIN", "")
    if env and os.path.isfile(env):
        return env
    # 与 scripts/Build-Web.cmd 一致：<repo>\..\..\Godot_v4.6.2-stable_win64.exe\<exe>
    base = repo
    for _ in range(3):
        for cand in (
            os.path.join(base, "Godot_v4.6.2-stable_win64.exe",
                         "Godot_v4.6.2-stable_win64.exe"),
            os.path.join(base, "Godot_v4.6.2-stable_win64.exe"),
        ):
            if os.path.isfile(cand):
                return cand
        base = os.path.dirname(base)
    raise SystemExit("找不到 Godot 可执行文件，请用 --godot 指定（或设 GODOT_BIN）")


def collect_imports(project: str) -> list[ImportFile]:
    out: list[ImportFile] = []
    skip_dirs = {".git", ".godot", "__pycache__", "tmp", "test_output", "docs", "android"}
    for root, dirs, files in os.walk(project):
        dirs[:] = [d for d in dirs if d not in skip_dirs]
        rel = os.path.relpath(root, project).replace("\\", "/")
        for fn in files:
            if not fn.endswith(".import"):
                continue
            abspath = os.path.join(root, fn)
            res = "res://" + (f"{rel}/{fn[:-7]}" if rel != "." else fn[:-7])
            try:
                out.append(ImportFile.load(res, abspath))
            except OSError as exc:
                print(f"[warn] 读不了 {abspath}: {exc}", file=sys.stderr)
    out.sort(key=lambda i: i.res_path)
    return out


def run_import(godot: str, project: str, log_path: str) -> None:
    cmd = [godot, "--headless", "--path", project, "--import"]
    t0 = time.time()
    os.makedirs(os.path.dirname(log_path), exist_ok=True)
    with open(log_path, "wb") as log:
        proc = subprocess.run(cmd, stdout=log, stderr=subprocess.STDOUT)
    dt = time.time() - t0
    if proc.returncode != 0:
        tail = ""
        try:
            with open(log_path, "r", encoding="utf-8", errors="replace") as fh:
                tail = "".join(fh.readlines()[-25:])
        except OSError:
            pass
        raise RuntimeError(f"godot --import 失败 (exit={proc.returncode}, {dt:.1f}s)\n{tail}")
    print(f"[import] ok  {dt:.1f}s  (log: {log_path})")


def _restore_files(entries: list[dict[str, Any]]) -> None:
    """把 .import **整文件**还原成 begin 之前的样子，并用整文件 sha256 校验。

    2026-11-01 事故（必须记住）：早期版本在"构建窗口内有人改过同一个文件"时会退化成
    "只把我们改过的键还原、别人的改动保留"。那不是安全策略，而是**制造混合态**：
    当时 77 个 .import 被并行工具改成了 web 变体，end 只回滚了我们那几个键，于是
    paper 图集留下 `vram_texture: true` + `path.bptc/astc` —— 下一次构建每个 UI 图集
    都会多带一份 s3tc/astc 变体（+5~10 MB），桌面导入设置也被悄悄改掉。

    整文件还原才是唯一正确解：begin 前备份的是原件，end 把原件字节写回，
    "桌面/编辑器字节级不变"就自动成立，不需要读懂别人改了什么。校验用备份的整文件
    sha256；不一致就抛错中止 —— 宁可不还原，也不要带着脏状态继续导出。
    """
    restored = 0
    for e in entries:
        backup = e.get("backup", "")
        path = e["import_abspath"]
        expected = e.get("import_sha_before", "")
        if not backup or not os.path.exists(backup):
            raise RuntimeError(f"缺少 .import 备份，拒绝继续（状态未知）: {path}")
        if not expected or sha256_file(backup) != expected:
            raise RuntimeError(f"备份文件自身不完整/已损坏，拒绝写回: {backup}")
        shutil.copy2(backup, path)
        got = sha256_file(path)
        if got != expected:
            raise RuntimeError(
                "整文件还原后 sha256 不匹配，已中止（导入缓存可能处于混合态）:\n"
                f"  file     = {path}\n  expected = {expected}\n  got      = {got}\n"
                "  处理：python tools\\web_tex_downgrade.py restore，"
                "或对该文件 git checkout -- 恢复 HEAD 版本")
        restored += 1
    if restored:
        print(f"[tex] 已整文件还原 {restored} 个 .import（每个都用 sha256 校验过）")
