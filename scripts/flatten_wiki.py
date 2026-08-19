#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
flatten_wiki.py — 将仓库内组织化的 wiki/（NN-分类/xxx.md 文件夹结构）拍平成
GitHub Wiki 兼容的平铺布局（NN-分类-xxx.md），并重写全部相对链接。

GitHub Wiki 不支持子目录：页面只能从 wiki 仓库根目录访问。
本脚本把每个页面重命名为 "NN-分类-子路径" 平铺名，并把所有 .md 相对链接
改写为平铺页面名（裸链接，GitHub wiki 风格），同时生成 _Sidebar.md 导航
和目录索引页（如 extensions/ 这种只链接目录的页面）。

用法: python3 scripts/flatten_wiki.py [OUTPUT_DIR]
默认输出到 <repo>/wiki-flat/（CI 中为临时目录，不入库）。
"""
import os
import posixpath
import re
import shutil
import sys

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SRC = os.path.join(REPO, "wiki")
OUT = sys.argv[1] if len(sys.argv) > 1 else os.path.join(REPO, "wiki-flat")
BLOB = "https://github.com/SharpFort/OmniPG/blob/master/"

LINK_RE = re.compile(r"\[([^\]]*)\]\(([^)\s]+)(?:\s+[^)]*)?\)")


def flat_name(rel: str) -> str:
    """wiki-relative path -> 平铺页面名（不含扩展名；Home.md 固定为 Home）"""
    rel = rel.replace("\\", "/")
    if rel == "Home.md":
        return "Home"
    base, _ext = os.path.splitext(rel)
    return base.replace("/", "-")


def main() -> int:
    # ---------- 1. 收集页面 ----------
    pages: dict[str, str] = {}          # wiki 相对路径 -> 平铺名（.md 页）
    non_md: dict[str, str] = {}         # 非 md 文件：路径 -> 平铺输出名（含扩展名）
    dirs: set[str] = set()              # 含文件的目录（相对路径）
    for root, _dirs, files in os.walk(SRC):
        for f in sorted(files):
            rel = os.path.relpath(os.path.join(root, f), SRC).replace("\\", "/")
            d = os.path.dirname(rel) or ""
            if d:
                dirs.add(d)
            if f == "Home.md":
                pages[rel] = "Home"
            elif f.endswith(".md"):
                pages[rel] = flat_name(rel)
            else:
                non_md[rel] = flat_name(rel) + os.path.splitext(f)[1]

    # 检查平铺名唯一性
    seen: dict[str, str] = {}
    for rel, name in pages.items():
        if name in seen:
            print(f"[warn] 平铺名冲突: {name} <- {seen[name]} 与 {rel}", file=sys.stderr)
        seen[name] = rel

    # 目录索引页：每个含文件的目录生成一个索引页
    index_pages: dict[str, str] = {}    # 目录相对路径 -> 索引页平铺名
    for d in sorted(dirs):
        members = sorted(r for r, _n in pages.items() if os.path.dirname(r) == d)
        if not members:
            continue
        index_pages[d] = d.replace("/", "-")

    all_pages = set(pages.values()) | set(index_pages.values())

    def resolve(src_rel: str, target: str) -> str | None:
        """把链接 target（相对 src_rel 所在文件）解析为平铺页面名；解析失败返回 None"""
        path_part = target.split("#")[0].split("?")[0]
        if not path_part:
            return None
        joined = posixpath.normpath(posixpath.join(posixpath.dirname(src_rel), path_part))
        joined = joined.replace("\\", "/")
        if joined in pages:
            return pages[joined]
        if joined in index_pages:
            return index_pages[joined]
        # 仓库根目录下的其他文件（如 docs/ 归档）-> 指向 blob URL
        if joined.startswith("../"):
            repo_rel = joined[3:]
            if os.path.exists(os.path.join(REPO, repo_rel.replace("/", os.sep))):
                return BLOB + repo_rel
        return None

    # ---------- 2. 生成输出 ----------
    if os.path.isdir(OUT):
        shutil.rmtree(OUT)
    os.makedirs(OUT)
    warnings: list[str] = []

    for rel, outname in pages.items():
        src_path = os.path.join(SRC, rel.replace("/", os.sep))
        out_path = os.path.join(OUT, outname + ".md")
        with open(src_path, encoding="utf-8") as fh:
            text = fh.read()

        def repl(m: re.Match) -> str:
            label, target = m.group(1), m.group(2)
            frag = ""
            rest = ""
            t = target
            if "#" in t:
                t, frag = t.split("#", 1)
                frag = "#" + frag
            if t.lower().startswith(("http://", "https://", "mailto:")) or t.startswith("#"):
                return m.group(0)
            newt = resolve(rel, t)
            if newt is None:
                warnings.append(f"{rel}: 无法映射链接 '{target}'")
                return m.group(0)
            return f"[{label}]({newt}{frag}{rest})"

        text = LINK_RE.sub(repl, text)
        with open(out_path, "w", encoding="utf-8") as fh:
            fh.write(text)
        print(f"  {rel} -> {outname}.md")

    for rel, outname in non_md.items():
        src_path = os.path.join(SRC, rel.replace("/", os.sep))
        shutil.copy2(src_path, os.path.join(OUT, outname))
        print(f"  {rel} -> {outname} (非 md，原样拷贝)")

    # 目录索引页
    for d, idx_name in index_pages.items():
        members = sorted(r for r in pages if os.path.dirname(r) == d)
        lines = [f"# {d}", ""]
        for m in members:
            title = os.path.splitext(os.path.basename(m))[0]
            lines.append(f"- [{title}]({pages[m]})")
        with open(os.path.join(OUT, idx_name + ".md"), "w", encoding="utf-8") as fh:
            fh.write("\n".join(lines) + "\n")
        print(f"  [索引页] {d}/ -> {idx_name}.md")

    # _Sidebar.md 导航
    groups: dict[str, list[tuple[str, str]]] = {}
    for rel, outname in sorted(pages.items()):
        if outname == "Home":
            continue
        d = os.path.dirname(rel)
        groups.setdefault(d, []).append((os.path.splitext(os.path.basename(rel))[0], outname))
    sidebar = ["- [Home](Home)"]
    for d in sorted(groups, key=lambda x: (x != "Home", x)):
        sidebar.append(f"- **{d or '(根)'}**")
        for title, outname in groups[d]:
            sidebar.append(f"  - [{title}]({outname})")
    for d, idx in sorted(index_pages.items()):
        if d not in groups:
            sidebar.append(f"- [{d}]({idx})")
    with open(os.path.join(OUT, "_Sidebar.md"), "w", encoding="utf-8") as fh:
        fh.write("\n".join(sidebar) + "\n")

    print(f"\n输出目录: {OUT}（{len(pages)} 个页面 + {len(index_pages)} 个索引页 + {len(non_md)} 个非 md 文件）")
    if warnings:
        print("\n[警告] 以下链接未映射（保持原样，在 GitHub wiki 上可能不可用）：", file=sys.stderr)
        for w in warnings:
            print("  - " + w, file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
