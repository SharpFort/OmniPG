#!/bin/bash
# =============================================================================
# render-config.sh — 运行时配置渲染（2026-08-20 决策⑤：.env / pigsty.yml / userlist.txt 三处一致）
# 用法:
#   ./scripts/render-config.sh <environment> [render_dir]
#     environment : development | staging | production（读取 .env.<environment>）
#     render_dir  : 输出目录，默认 $PROJECT_DIR/.deploy-render（已被 .gitignore 忽略）
# 密钥来源: 当前环境变量（CI GitHub Secrets 注入）；staging/production 的 .env.* 中
#           ${VAR} 占位符由本脚本替换，真实值一律来自环境变量，不在仓库落盘。
# 白名单令牌（仅替换这些，其余 ${...}（如 ${admin_ip}）保留给 Pigsty 自身使用）：
#   DB_PASSWORD AUTHENTICATOR_PASSWORD LOGTO_DB_PASSWORD APISIX_ADMIN_KEY JWKS_JSON LOGTO_WEBHOOK_SIGNING_KEY
# 产物:
#   $render_dir/.env          -> 渲染后的环境变量（deploy-*.sh source 用；gateway/.env 来源）
#   $render_dir/pigsty.yml    -> 渲染后的 Pigsty inventory（staging/production 用 tpl；development 与 infra/pigsty.yml 一致）
#   $render_dir/userlist.txt  -> SCRAM verifier 校验后复制（S-G2：不渲染令牌；
#                                权威生成 = scripts/pgbouncer-userlist-scram.sh）
# 安全: 渲染后若仍有白名单外的残留令牌（${admin_ip} 除外）即 fail-closed 退出。
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

ENV=${1:-development}
RENDER_DIR=${2:-"$PROJECT_DIR/.deploy-render"}
ENV_FILE="$PROJECT_DIR/.env.$ENV"

# 允许替换的令牌白名单（顺序即 envsubst SHELL-FORMAT 顺序）
TOKENS="DB_PASSWORD AUTHENTICATOR_PASSWORD LOGTO_DB_PASSWORD APISIX_ADMIN_KEY JWKS_JSON LOGTO_WEBHOOK_SIGNING_KEY"

if [ ! -f "$ENV_FILE" ]; then
    echo "❌ 环境文件不存在: $ENV_FILE" >&2
    exit 1
fi

mkdir -p "$RENDER_DIR"

# ---------------------------------------------------------------
# 1) 加载 .env.$ENV：仅导入「当前环境未设置」的变量（CI Secrets 优先，不覆盖）
# ---------------------------------------------------------------
while IFS='=' read -r key val; do
    key="${key%%[[:space:]]*}"
    [ -z "$key" ] && continue
    [[ "$key" == \#* ]] && continue
    # 去掉首尾引号
    val="${val%\"}"; val="${val#\"}"
    val="${val%\'}"; val="${val#\'}"
    # 环境已存在（CI 注入）则不覆盖
    if [ -z "${!key+x}" ]; then
        export "$key=$val"
    fi
done < "$ENV_FILE"

# ---------------------------------------------------------------
# 1.5) 校验白名单注入值：禁止单引号 / 换行（SSH 内联注入限制，GitHub Secrets 值同理）
# ---------------------------------------------------------------
for t in $TOKENS; do
    v="${!t:-}"
    [ -z "$v" ] && continue
    case "$v" in
        *"'"*)
            echo "❌ 环境变量 $t 含单引号（SSH 内联注入限制），请更换 GitHub Secret 值" >&2
            exit 1
            ;;
        *$'\n'*)
            echo "❌ 环境变量 $t 含换行符，请更换 GitHub Secret 值" >&2
            exit 1
            ;;
    esac
done

# ---------------------------------------------------------------
# 2) 替换实现（python3 优先；退化 python / envsubst）
#    仅替换白名单令牌，其余 ${...}（如 ${admin_ip}）原样保留
# ---------------------------------------------------------------
SUBST_IMPL=""
if command -v python3 >/dev/null 2>&1; then
    SUBST_IMPL="python3"
elif command -v python >/dev/null 2>&1; then
    SUBST_IMPL="python"
elif command -v envsubst >/dev/null 2>&1; then
    SUBST_IMPL="envsubst"
else
    echo "❌ 需要 python3 / python 或 envsubst 之一" >&2
    exit 1
fi

render_file() {
    local src="$1" dst="$2"
    # Windows Git Bash：把 POSIX 路径转成 Windows 路径再交给原生 python（Linux/WSL 无 cygpath，不受影响）
    if command -v cygpath >/dev/null 2>&1; then
        src="$(cygpath -w "$src")"
        dst="$(cygpath -w "$dst")"
    fi
    if [ "$SUBST_IMPL" = "python3" ] || [ "$SUBST_IMPL" = "python" ]; then
        "$SUBST_IMPL" - "$src" "$dst" "$TOKENS" <<'PYEOF'
import os, re, sys
src, dst = sys.argv[1], sys.argv[2]
tokens = set(sys.argv[3].split())
pat = re.compile(r'\$\{([A-Za-z_][A-Za-z0-9_]*)\}|\$([A-Za-z_][A-Za-z0-9_]*)')
def repl(m):
    k = m.group(1) or m.group(2)
    if k in tokens and k in os.environ:
        return os.environ[k]
    return m.group(0)
s = open(src, encoding='utf-8').read()
open(dst, 'w', encoding='utf-8', newline='\n').write(pat.sub(repl, s))
PYEOF
    else
        local fmt=""
        for t in $TOKENS; do fmt="$fmt\${$t} "; done
        envsubst "$fmt" < "$src" > "$dst"
    fi
}

# ---------------------------------------------------------------
# 3) 渲染产物
# ---------------------------------------------------------------
render_file "$ENV_FILE" "$RENDER_DIR/.env"

# pigsty.yml：优先 tpl（staging/production 令牌版）；否则用字面值文件
PIGSTY_SRC="$PROJECT_DIR/infra/pigsty.yml"
[ -f "$PROJECT_DIR/infra/pigsty.yml.tpl" ] && PIGSTY_SRC="$PROJECT_DIR/infra/pigsty.yml.tpl"
render_file "$PIGSTY_SRC" "$RENDER_DIR/pigsty.yml"

# userlist.txt（S-G2 2026-11-20）：SCRAM verifier 形态——pgbouncer SCRAM passthrough
# 要求 verifier 与库端 pg_authid 逐字节一致，不可由 ${PASSWORD} 明文令牌渲染
# （verifier 含随机盐，离线渲染必与库端漂移）。权威生成通道 =
# scripts/pgbouncer-userlist-scram.sh（部署时从 pg_authid 读取，明文不落地）；
# 此处仅做格式校验 + tpl 角色集契约校验后原样复制。
USERLIST_SRC="$PROJECT_DIR/infra/userlist.txt"
if [ ! -f "$USERLIST_SRC" ]; then
    echo "❌ $USERLIST_SRC 不存在" >&2
    exit 1
fi
BAD_LINES=$(grep -vE '^[[:space:]]*(#|--.*)?$' "$USERLIST_SRC" \
    | grep -cvE '^"[A-Za-z_][A-Za-z0-9_]*" "SCRAM-SHA-256\$[0-9]+:[A-Za-z0-9+/=]+:[A-Za-z0-9+/=]+:[A-Za-z0-9+/=]+"$' || true)
if [ "$BAD_LINES" -gt 0 ]; then
    echo "❌ userlist.txt 有 $BAD_LINES 行非 SCRAM verifier 形态（S-G2：明文/md5 不再允许；用 scripts/pgbouncer-userlist-scram.sh 从 pg_authid 重新生成）" >&2
    exit 1
fi
TPL_USERS=$(grep -oE '^"[A-Za-z_][A-Za-z0-9_]*"' "$PROJECT_DIR/infra/userlist.txt.tpl" 2>/dev/null | tr -d '"' | sort -u || true)
for u in $TPL_USERS; do
    grep -q "^\"$u\"" "$USERLIST_SRC" || {
        echo "❌ userlist.txt 缺少 tpl 契约角色: $u" >&2
        exit 1
    }
done
cp "$USERLIST_SRC" "$RENDER_DIR/userlist.txt"

# ---------------------------------------------------------------
# 4) fail-closed：残留令牌检查（允许 ${admin_ip}，它是 Pigsty 自身变量）
# ---------------------------------------------------------------
check_tokens() {
    local f="$1"
    local leftover
    leftover=$(grep -oE '\$\{[A-Za-z_][A-Za-z0-9_]*\}' "$f" | sed 's/.*{\(.*\)}/\1/' | sort -u | grep -v '^admin_ip$' || true)
    if [ -n "$leftover" ]; then
        echo "❌ $f 仍有未替换令牌: $leftover（请确认 CI Secrets / 环境变量已注入）" >&2
        return 1
    fi
    return 0
}
check_tokens "$RENDER_DIR/.env"
check_tokens "$RENDER_DIR/pigsty.yml"
check_tokens "$RENDER_DIR/userlist.txt"

echo "✅ render-config.sh: $ENV -> $RENDER_DIR"
echo "   产物: .env / pigsty.yml / userlist.txt（三处一致）"
