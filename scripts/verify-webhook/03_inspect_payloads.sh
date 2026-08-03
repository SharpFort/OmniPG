#!/usr/bin/env bash
# =============================================================================
# 04.7 §10 payload 解析脚本 —— 汇总 out/ 下接收到的 webhook，输出判定要点：
#   action / operator(user) / requestUri / response / object.users 完整性
# 用法: bash 03_inspect_payloads.sh
# 依赖: python3
# =============================================================================
cd "$(dirname "$0")" || exit 1

count=$(ls out/*.json 2>/dev/null | wc -l)
echo "payload 文件数: $count"
[ "$count" -eq 0 ] && { echo "（空——先运行 01 接收器 + 02 触发脚本）"; exit 0; }

for f in out/*.json; do
  [ -e "$f" ] || continue
  echo "---- $(basename "$f")"
  python3 - "$f" <<'PY'
import json, sys
p = json.load(open(sys.argv[1], encoding="utf-8"))
obj = p.get("object") or ""
try:
    o = json.loads(obj)
except Exception:
    o = None
users = o.get("users") if isinstance(o, dict) else None
print("action      :", p.get("action"))
print("operator    :", p.get("user"))
print("requestUri  :", p.get("requestUri"))
print("response    :", p.get("response"))
if isinstance(users, list):
    print("object.users: 完整(%d) -> %s" % (len(users), users))
else:
    print("object.users: 缺失/非数组; object 前 120 字符:", obj[:120])
PY
done
