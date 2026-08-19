#!/bin/bash
# =============================================================================
# check-extensions.sh — 扩展声明一致性检查（CI 漂移检查，无数据库依赖）
#
# 扩展管理模型（2026-08-16 拍板；2026-08-19 方案 A 单文件）：权威 = infra/pigsty.yml
#   - pg_extensions            节点级装包（可用清单）
#   - pg_databases[].extensions 库级启用（CREATE EXTENSION）
#   - 说明文档                  wiki/01-项目简介/extensions/<name>.md
# 检查项：
#   1) 退役禁令：pgaudit / pgsodium 不得出现在任何 infra/*.yml 扩展清单
#   2) 声明→文档：每个声明的扩展在 wiki/01-项目简介/extensions/ 下都有 <name>.md
#   3) 文档→声明：目录内每个 *.md 都对应声明中的扩展（无孤立文档）
#   4) 残留引用：db/init/01-extensions.sql 已移除；scripts/*.sh 不得引用
# 用法: bash scripts/check-extensions.sh
# 依赖: python3 + PyYAML（CI: pip install pyyaml）
# =============================================================================
set -euo pipefail
REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_DIR"

${PYTHON:-python3} - <<'PY'
import glob
import os
import sys

try:
    import yaml
except ImportError:
    sys.exit("ERROR: 需要 PyYAML（pip install pyyaml）")


def load(path):
    with open(path, encoding="utf-8") as f:
        return yaml.safe_load(f)


declared = set()  # 所有声明过的扩展名
errors = []

for yml in ("infra/pigsty.yml",):
    if not os.path.exists(yml):
        continue
    data = load(yml)
    children = ((data or {}).get("all") or {}).get("children") or {}
    for child in children.values():
        vars_ = child.get("vars") or {}
        for ext in vars_.get("pg_extensions") or []:
            declared.add(str(ext))
        for db in vars_.get("pg_databases") or []:
            for e in db.get("extensions") or []:
                declared.add(str(e["name"]) if isinstance(e, dict) else str(e))

# 1) 退役禁令
for banned in ("pgaudit", "pgsodium"):
    if banned in declared:
        errors.append(f"退役扩展 {banned} 仍出现在 infra/*.yml 扩展清单中（应从 pg_extensions 与 pg_databases[].extensions 移除）")

# 2) 声明 → 说明页
ext_dir = "wiki/01-项目简介/extensions"
for ext in sorted(declared):
    if not os.path.exists(os.path.join(ext_dir, f"{ext}.md")):
        errors.append(f"声明扩展 {ext} 缺少说明页 {ext_dir}/{ext}.md")

# 3) 说明页 → 声明（无孤立文档）
for f in sorted(glob.glob(os.path.join(ext_dir, "*.md"))):
    name = os.path.basename(f)[:-3]
    if name not in declared:
        errors.append(f"说明页 {f} 对应扩展 {name} 未在 infra/*.yml 中声明（孤立文档？）")

# 4) 01-extensions.sql 残留
if os.path.exists("db/init/01-extensions.sql"):
    errors.append("db/init/01-extensions.sql 应已移除（扩展权威 = Pigsty infra/*.yml，db/init 仅保留 02-schemas.sql）")

for f in sorted(glob.glob("scripts/*.sh")):
    if os.path.basename(f) == "check-extensions.sh":
        continue  # 本脚本自身含检查逻辑关键字，排除
    with open(f, encoding="utf-8", errors="ignore") as fh:
        if "01-extensions" in fh.read():
            errors.append(f"{f} 仍引用 db/init/01-extensions.sql")

if errors:
    print("❌ 扩展一致性检查失败：")
    for e in errors:
        print("  -", e)
    sys.exit(1)

print(f"✅ 扩展一致性检查通过：{len(declared)} 个扩展声明，说明页完整，无退役扩展，无残留引用")
print("   声明扩展: " + ", ".join(sorted(declared)))
PY
