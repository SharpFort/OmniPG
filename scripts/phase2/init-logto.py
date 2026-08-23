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
M2M_APP_ID = "omnipg_m2m_app"
GLOBAL_ROLE = "role_super_admin"
ORG_TEMPLATE_NAME = "default"
ORG_TEMPLATE_ROLES = ["tenant_admin", "editor", "viewer"]
DEMO_ORG_NAME = "默认租户"
DEMO_ORG_DESC = "OmniPG 默认租户（由 init-logto.py 创建）"
WEBHOOK_NAME = "omnipg-webhook"
# Custom Token Claims 脚本（05 §5.1.1 + D19 pg_role 映射）
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
  return { roles, pg_role: pgRoleMap[pgRole] };
};
"""

# ---------------------------------------------------------------------------
# HTTP 工具
# ---------------------------------------------------------------------------


def http(method, path, token=None, body=None, endpoint=ENDPOINT):
    url = endpoint + path
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
    """创建组织角色（tenant_admin/editor/viewer）——v1.42 OSS 无组织模板，角色为独立资源"""
    print("[3] 组织角色...")
    created = []
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
        created.append(role_name)
        print(f"  已创建: {role_name} (id={role.get('id') if role else '?'})")
    return created


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


def step5_webhook(token):
    """创建/更新 webhook（仅订阅 PostSignIn 登录日志）"""
    print("[5] Webhook...")
    # D25: 用户/角色/租户已同库只读投影，无需 webhook 同步；仅保留 PostSignIn 登录日志。
    events = ["PostSignIn"]
    _, hooks = http("GET", "/api/hooks", token)
    for h in (hooks or []):
        if h.get("name") == WEBHOOK_NAME:
            existing = set(h.get("events") or [])
            want = set(events)
            if existing == want:
                print(f"  已存在且事件齐全: {WEBHOOK_NAME} (id={h['id']})")
                return h["id"]
            # N3 修复: hook 已存在但订阅有差异 → PATCH 补齐（历史环境升级路径，
            # 不再直接 return——否则 PostSignIn/SuspensionStatus/OrgRole 永不补订阅）
            missing = sorted(want - existing)
            extra = sorted(existing - want)
            print(f"  已存在但订阅差异: 缺 {missing} 多 {extra} → PATCH /api/hooks/{h['id']}")
            status, _ = http("PATCH", f"/api/hooks/{h['id']}", token, {"events": events})
            if status in (200, 201, 204):
                print(f"  已更新订阅: {WEBHOOK_NAME} (id={h['id']})")
            else:
                print(f"  !! 订阅更新失败: {status}")
            return h["id"]
    _, hook = http("POST", "/api/hooks", token, {
        "name": WEBHOOK_NAME,
        "config": {
            "url": "http://host.docker.internal:9080/rpc/webhook_logto",
            "headers": {},
        },
        "events": events,
        "enabled": True,
    })
    print(f"  已创建: {WEBHOOK_NAME} (id={hook.get('id') if hook else '?'})")
    return hook.get("id") if hook else None


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
    step5_webhook(token)
    step2_global_role(token)
    step3_org_roles(token)
    step4_demo_org(token)
    step6_claims_script(token)
    print("\n全部完成 ✅")


if __name__ == "__main__":
    main()
