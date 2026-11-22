#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
init-logto.py — Logto OSS 配置自动化（T3，06-开发路线 §3 T3）

功能（全部幂等）：
  1. 创建 M2M 应用（管理端集成用）并授予 Management API role
  2. 创建全局角色 role_super_admin（type=User）
  3. 创建组织模板 default：组织角色 tenant_admin/editor/viewer
  4. 创建演示组织（租户）+ 关联模板
  5. 创建/更新 webhook（仅订阅 PostSignIn 登录日志事件；镜像同步事件已退役 D25）
     signingKey 由 Logto 服务端生成且 Management API 不可写入，故以 Logto 实际 key 为
     事实源，自动回写 gateway/.env（git-ignored；2026-11-22 P2-3 起 .env.development
     为入库模板不再回写。回写后需重跑 init-apisix-routes.sh）。
     背景事故：两边 key 漂移时 APISIX 验签恒 401，PostSignIn 全部投递失败、登录日志为空
     （2026-08-29 排查：39 次 PostSignIn 投递全部 401）
  6. 配置 access-token Custom Token Claims 脚本（D19：roles + pg_role 注入）
  7. --verify 模式：核对全部配置并输出

用法:
  python scripts/phase2/init-logto.py [--endpoint http://localhost:3001] [--verify]

前置: Logto 运行 + Console 已创建首个管理员（OSS 单管理员）
依赖: requests（pip install requests 或系统自带）
"""
import argparse
import json
import os
import secrets
import sys
import urllib.parse
import urllib.request

ENDPOINT = "http://localhost:3001"
# Logto 默认 Management API resource（OSS seed 内置）
MGMT_RESOURCE = "https://default.logto.app/api"
# 默认管理角色（seed 内置，M2M 应用需授予才能调管理 API）
MGMT_ROLE_NAME = "14eqvuyw66mbhdcykbbaw"  # 'Logto Management API access'（default 租户 API）

# ---------------------------------------------------------------------------
# 配置区（可按需修改）
# ---------------------------------------------------------------------------
M2M_APP_NAME = "omnipg-management"
# 与 main()/--m2m-app-id 默认值对齐（批次2d前置修复：原 'omnipg_m2m_app' 与
# CLI 默认 'omnipg_management_m2m' 不一致，--m2m-app-id 不传时 step1 永远查不到既有应用）
M2M_APP_ID = "omnipg_management_m2m"
GLOBAL_ROLE = "role_super_admin"
ORG_TEMPLATE_NAME = "default"
ORG_TEMPLATE_ROLES = ["tenant_admin", "editor", "viewer"]
DEMO_ORG_NAME = "默认租户"
DEMO_ORG_DESC = "OmniPG 默认租户（由 init-logto.py 创建）"
WEBHOOK_NAME = "omnipg-webhook"
# Webhook HMAC 验签 key 的事实源是 Logto hook 的 signingKey（Management API 只读，
# 2026-08-29 实测 PATCH 传 signingKey 返回 200 但字段被忽略，key 始终由 Logto 生成）。
# step5 会把 Logto 实际 key 回写 gateway/.env（杜绝与网关 init-apisix-routes.sh 验签
# key 漂移导致的 401；2026-11-22 前还回写入库的 .env.development，P2-3 收口已移除）。
# 此处仅作为 gateway/.env 缺失时的兜底比对值。
WEBHOOK_SIGNING_KEY = os.environ.get("LOGTO_WEBHOOK_SIGNING_KEY", "")
PROJECT_ROOT = os.path.abspath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", ".."))
# Custom Token Claims 脚本（05 §5.1.1 + D19 pg_role 映射 + D27 tenant_id/organization_id）
CLAIMS_SCRIPT = r"""
const getCustomJwtClaims = async ({ token, context }) => {
  // ① 全局角色：context.user.roles（Logto roles 表，type=User）
  const globalRoles = (context.user?.roles ?? []).map((r) => r.name);
  // ② 组织角色：仅组织 token 存在 context.organization
  const orgId = context.organization?.id;
  const orgRoles = orgId
    ? (context.user?.organizationRoles ?? [])
        .filter((r) => r.organizationId === orgId)
        .map((r) => r.roleName)
    : [];
  // ③ 并集注入（网关/current_user_roles 判定用）
  const roles = [...new Set([...globalRoles, ...orgRoles])];
  // ④ D19: pg_role 映射（最高优先级 → PostgREST DB 角色）
  const priority = ['role_super_admin', 'role_admin', 'role_editor'];
  const pgRoleMap = {
    role_super_admin: 'super_admin',
    role_admin: 'role_admin',
    role_editor: 'role_editor',
    role_guest: 'role_guest'
  };
  const pgRole = priority.find((r) => roles.includes(r)) ?? 'role_guest';
  // ⑤ D27: Logto Tenant id 从 context.application.tenantId 取得（恒存在）；
  //    Organization id 仅组织 token（context.organization?.id）存在，全局 token 为 null。
  const tenantId = context.application?.tenantId ?? 'default';
  const organizationId = orgId ?? null;
  return {
    roles,
    global_roles: globalRoles,
    org_roles: orgRoles,
    pg_role: pgRoleMap[pgRole],
    tenant_id: tenantId,
    organization_id: organizationId,
  };
};
"""

# ---------------------------------------------------------------------------
# HTTP 工具
# ---------------------------------------------------------------------------


def http(method, path, token=None, body=None, endpoint=None):
    # endpoint 延迟解析（批次2d前置修复）：原 endpoint=ENDPOINT 在 import 时绑定默认值，
    # main() 里 global ENDPOINT = args.endpoint 的重绑定对本函数默认值不生效
    #——--endpoint 参数除 get_m2m_token 外全部静默失效
    url = (endpoint or ENDPOINT) + path
    req = urllib.request.Request(url, method=method)
    req.add_header("Content-Type", "application/json")
    if token:
        req.add_header("Authorization", f"Bearer {token}")
    data = json.dumps(body).encode() if body is not None else None
    try:
        with urllib.request.urlopen(req, data=data) as resp:
            raw = resp.read().decode()
            return resp.status, json.loads(raw) if raw else None
    except urllib.error.HTTPError as e:
        raw = e.read().decode()[:500]
        print(f"  HTTP {e.code} {method} {path}: {raw}")
        return e.code, None


# ---------------------------------------------------------------------------
# M2M token
# ---------------------------------------------------------------------------


def get_m2m_token(app_id, app_secret):
    """client_credentials grant 换取 Management API token"""
    body = urllib.parse.urlencode({
        "client_id": app_id,
        "client_secret": app_secret,
        "grant_type": "client_credentials",
        "resource": MGMT_RESOURCE,
        "scope": "all",
    }).encode()
    req = urllib.request.Request(f"{ENDPOINT}/oidc/token", data=body, method="POST")
    req.add_header("Content-Type", "application/x-www-form-urlencoded")
    try:
        with urllib.request.urlopen(req) as resp:
            return json.loads(resp.read().decode()).get("access_token")
    except urllib.error.HTTPError as e:
        print(f"  M2M token failed: {e.code} {e.read().decode()[:300]}")
        return None


# ---------------------------------------------------------------------------
# 各配置步骤
# ---------------------------------------------------------------------------


def step1_m2m_app(token):
    """创建 M2M 应用 + 授予管理角色"""
    print("[1] M2M 应用...")
    # 查已有
    _, apps = http("GET", "/api/applications", token)
    if apps:
        for a in apps:
            if a.get("id") == M2M_APP_ID:
                print(f"  已存在: {M2M_APP_ID} (type={a.get('type')})")
                return a["id"], a.get("oidcClientMetadata", {}).get("clientSecret", "")
    secret = secrets.token_urlsafe(32)
    status, app = http("POST", "/api/applications", token, {
        "id": M2M_APP_ID,
        "name": M2M_APP_NAME,
        "type": "machineToMachine",
        "oidcClientMetadata": {
            "clientSecret": secret,
        },
    })
    if status not in (200, 201):
        print(f"  !! 创建失败: {status}")
        return None, None
    print(f"  已创建: {M2M_APP_ID} (secret 已生成)")
    # 授予管理 API role
    _, _ = http("POST", f"/api/applications/{M2M_APP_ID}/roles", token, {
        "roleIds": [MGMT_ROLE_NAME],
    })
    print("  已授予管理角色:", MGMT_ROLE_NAME)
    return M2M_APP_ID, secret


def step2_global_role(token):
    """创建全局角色 role_super_admin"""
    print("[2] 全局角色...")
    _, roles = http("GET", "/api/roles", token)
    if roles:
        for r in roles:
            if r.get("name") == GLOBAL_ROLE:
                print(f"  已存在: {GLOBAL_ROLE} (id={r['id']})")
                return r["id"]
    _, role = http("POST", "/api/roles", token, {
        "name": GLOBAL_ROLE,
        "description": "全局超级管理员（OmniPG）",
        "type": "User",
    })
    print(f"  已创建: {GLOBAL_ROLE} (id={role.get('id') if role else '?'})")
    return role.get("id") if role else None


def step3_org_roles(token):
    """创建组织角色（tenant_admin/editor/viewer）——v1.42 OSS 无组织模板，角色为独立资源
    返回失败角色名列表（空 = 全部成功；批次2d前置修复：原实现 POST 失败仍记为已创建）"""
    print("[3] 组织角色...")
    created = []
    failed = []
    _, roles = http("GET", "/api/organization-roles", token)
    existing = {r.get("name") for r in (roles or [])}
    for role_name in ORG_TEMPLATE_ROLES:
        if role_name in existing:
            print(f"  已存在: {role_name}")
            continue
        _, role = http("POST", "/api/organization-roles", token, {
            "name": role_name,
            "description": f"组织角色 {role_name}（OmniPG）",
        })
        if not role:
            print(f"  !! 创建失败: {role_name}（HTTP 响应异常）", file=sys.stderr)
            failed.append(role_name)
            continue
        created.append(role_name)
        print(f"  已创建: {role_name} (id={role.get('id')})")
    return failed


def step4_demo_org(token, _template_id=None):
    """创建演示组织（租户）"""
    print("[4] 演示组织...")
    _, orgs = http("GET", "/api/organizations", token)
    for o in (orgs or []):
        if o.get("name") == DEMO_ORG_NAME:
            print(f"  已存在: {DEMO_ORG_NAME} (id={o['id']})")
            return o["id"]
    _, org = http("POST", "/api/organizations", token, {
        "name": DEMO_ORG_NAME,
        "description": DEMO_ORG_DESC,
    })
    print(f"  已创建: {DEMO_ORG_NAME} (id={org.get('id') if org else '?'})")
    return org.get("id") if org else None


def step5_webhook(token, check_only=False):
    """创建/更新 webhook（仅订阅 PostSignIn 登录日志），并把 Logto 实际 signingKey
    回写 gateway/.env 与 .env.development（事实源 = Logto，防止网关验签 key 漂移）。

    check_only=True: --verify 模式，仅核对不修改；返回 hook id=一致，None=漂移/缺失。
    """
    print("[5] Webhook...")
    # D25: 用户/角色/租户已同库只读投影，无需 webhook 同步；仅保留 PostSignIn 登录日志。
    events = ["PostSignIn"]
    _, hooks = http("GET", "/api/hooks", token)
    hook = next((h for h in (hooks or []) if h.get("name") == WEBHOOK_NAME), None)

    if hook is None:
        if check_only:
            print(f"  !! webhook 不存在: {WEBHOOK_NAME}")
            return None
        _, hook = http("POST", "/api/hooks", token, {
            "name": WEBHOOK_NAME,
            "config": {
                "url": "http://host.docker.internal:9080/rpc/webhook_logto",
                "headers": {},
            },
            "events": events,
            "enabled": True,
        })
        if not hook:
            print("  !! 创建失败", file=sys.stderr)
            return None
        print(f"  已创建: {WEBHOOK_NAME} (id={hook.get('id')})")

    # N3 修复: 订阅差异 PATCH 补齐（历史环境升级路径）
    patch = {}
    if sorted(hook.get("events") or []) != sorted(events):
        patch["events"] = events
    if patch:
        if check_only:
            print(f"  !! 订阅漂移: 现有 {sorted(hook.get('events') or [])} ≠ 期望 {sorted(events)}")
            return None
        status, _ = http("PATCH", f"/api/hooks/{hook['id']}", token, patch)
        if status not in (200, 201, 204):
            print(f"  !! 订阅更新失败: {status}", file=sys.stderr)
            return None
        print(f"  已更新订阅: {WEBHOOK_NAME}")

    # signingKey 只读（Logto 服务端生成）→ 反向同步到网关配置
    actual_key = hook.get("signingKey") or ""
    if not actual_key:
        print("  !! hook 响应未含 signingKey，无法同步网关验签 key", file=sys.stderr)
        return None
    gateway_key = _read_configured_signing_key()
    if gateway_key == actual_key:
        print("  signingKey 与网关配置一致 ✅")
    elif check_only:
        print("  !! signingKey 漂移: Logto 实际值 ≠ 网关配置值 → 运行本脚本同步后重跑 init-apisix-routes.sh")
        return None
    else:
        n = _sync_signing_key(actual_key)
        if n:
            print(f"  已把 Logto 实际 signingKey 回写 {n}（原值与 Logto 漂移，401 事故根因）")
            print("  ⚠️ 请重跑 scripts/init-apisix-routes.sh 使网关验签 key 生效")
        else:
            print("  gateway 配置文件未找到，signingKey 未同步（手动配置 LOGTO_WEBHOOK_SIGNING_KEY）")
    return hook["id"]


def _read_configured_signing_key():
    """读取网关侧当前配置的 LOGTO_WEBHOOK_SIGNING_KEY
    （2026-11-22 P2-3 收口：真实 key 只存 git-ignored 的 gateway/.env——
    .env.development 已改为入库模板，不再承载真实密钥，也不参与读写）"""
    path = os.path.join(PROJECT_ROOT, "gateway", ".env")
    try:
        with open(path, "r", encoding="utf-8") as f:
            for line in f:
                if line.startswith("LOGTO_WEBHOOK_SIGNING_KEY="):
                    return line.strip().split("=", 1)[1]
    except OSError:
        pass
    return WEBHOOK_SIGNING_KEY or None


def _sync_signing_key(actual_key):
    """把 Logto 实际 signingKey 回写 gateway/.env（git-ignored），返回更新的文件列表
    （2026-11-22 P2-3：不再回写 .env.development——入库模板写真实 key = 密钥入库，
    此前该行为会在每次运行时把已占位符化的模板重新填回真实值）"""
    new_line = f"LOGTO_WEBHOOK_SIGNING_KEY={actual_key}\n"
    updated = []
    for path in (os.path.join(PROJECT_ROOT, "gateway", ".env"),):
        try:
            with open(path, "r", encoding="utf-8") as f:
                lines = f.readlines()
        except OSError:
            continue
        found = False
        changed = False
        for i, line in enumerate(lines):
            if line.startswith("LOGTO_WEBHOOK_SIGNING_KEY="):
                found = True
                if line != new_line:
                    lines[i] = new_line
                    changed = True
                break
        if not found:
            lines.append("" if not lines or lines[-1].endswith("\n") else "\n")
            lines.append(new_line)
            changed = True
        if changed:
            with open(path, "w", encoding="utf-8") as f:
                f.writelines(lines)
            updated.append(os.path.relpath(path, PROJECT_ROOT))
    return updated


def step6_claims_script(token):
    """配置 access-token Custom Token Claims 脚本（tokenType 走路径参数，body 不含）"""
    print("[6] Custom Token Claims 脚本...")
    path = "/api/configs/jwt-customizer/access-token"
    status, _ = http("PUT", path, token, {
        "script": CLAIMS_SCRIPT,
        "environmentVariables": {},
        "blockIssuanceOnError": False,
    })
    if status in (200, 201, 204):
        print("  已配置 access-token claims 脚本")
    else:
        print(f"  !! 配置失败: {status}")
    return status


# ---------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------


def main():
    global ENDPOINT
    parser = argparse.ArgumentParser(description="Logto OSS 配置自动化")
    parser.add_argument("--endpoint", default=ENDPOINT)
    parser.add_argument("--verify", action="store_true", help="仅核对配置")
    parser.add_argument("--m2m-app-id", default="", help="M2M 应用 ID（默认 omnipg_management_m2m）")
    parser.add_argument("--m2m-secret", default="", help="M2M 应用 Secret（DB 直插或 Console 创建）")
    args = parser.parse_args()

    ENDPOINT = args.endpoint

    print(f"Logto endpoint: {ENDPOINT}")

    if args.verify:
        print("== verify 模式 ==")
        # 核对需读 Logto 实际配置 → 同样需要管理 token
        app_secret = args.m2m_secret or os.environ.get("LOGTO_M2M_SECRET", "")
        if not app_secret:
            print("verify 模式需核对 Logto 实际配置：请用 --m2m-secret 或环境变量 LOGTO_M2M_SECRET 提供",
                  file=sys.stderr)
            sys.exit(1)
        token = get_m2m_token(args.m2m_app_id or "omnipg_management_m2m", app_secret)
        if not token:
            print("无法获取管理 token（检查 secret / 角色授权）", file=sys.stderr)
            sys.exit(1)
        if step5_webhook(token, check_only=True) is None:
            sys.exit(1)
        print("verify 通过 ✅")
        return

    app_id = args.m2m_app_id or "omnipg_management_m2m"
    # N23（2026-08-11）: 移除硬编码默认 secret——参数或环境变量提供，缺失即拒绝（防泄露）
    app_secret = args.m2m_secret or os.environ.get("LOGTO_M2M_SECRET", "")
    if not app_secret:
        print("缺少 M2M Secret：请用 --m2m-secret 参数或环境变量 LOGTO_M2M_SECRET 提供（N23：不再使用硬编码默认值）",
              file=sys.stderr)
        sys.exit(1)

    token = get_m2m_token(app_id, app_secret)
    if not token:
        print("无法获取管理 token（检查 secret / 角色授权）")
        sys.exit(1)
    print("管理 token 获取成功\n")

    # 步骤顺序（D25）：webhook 仅 PostSignIn，逻辑上建角色/组织后生效即可；
    # 保留 webhook 先配置，避免登录日志事件在配置前发生。
    # 步骤结果聚合（批次2d前置修复）：原实现丢弃全部返回值、步骤全失败仍打印
    # "全部完成 ✅" 且 exit 0——失败必须反映在退出码（CI 可感知）
    failures = []

    if step5_webhook(token) is None:
        failures.append("step5_webhook")
    if step2_global_role(token) is None:
        failures.append("step2_global_role")
    org_role_failed = step3_org_roles(token)
    if org_role_failed:
        failures.append("step3_org_roles(" + ",".join(org_role_failed) + ")")
    if step4_demo_org(token) is None:
        failures.append("step4_demo_org")
    status6 = step6_claims_script(token)
    if not (isinstance(status6, int) and 200 <= status6 < 300):
        failures.append("step6_claims_script")

    if failures:
        print("\n⚠️ 失败步骤: " + "; ".join(failures) + "（详见上方输出）", file=sys.stderr)
        sys.exit(1)
    print("\n全部完成 ✅")


if __name__ == "__main__":
    main()
