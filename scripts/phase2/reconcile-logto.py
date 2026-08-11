#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
reconcile-logto.py — Logto ↔ 镜像表对账任务（33 号审查文档 §5 + §9 D9）

背景: 五张镜像表 = 项目基础数据唯一来源（2026-08-11 拍板）；webhook 单向推送
      （丢事件/重试耗尽/存量污染）由对账兜底；user_role 无 webhook 事件，
      对账是其唯一权威通道（JIT 仅登录快照）。

对账范围（Management API 端点 → sync_* 函数，全部幂等）:
  users               GET /api/users（分页 500）             → sync_user_upsert / sync_user_delete（软删）
  tenants             GET /api/organizations                 → sync_tenant_upsert / sync_tenant_delete（软删）
  user_tenants        GET /api/organizations/:id/users       → 全量重建（JOIN 语义）+ 软删用户联动
  role                GET /api/roles                         → sync_role_upsert / sync_role_delete（硬删）
  organization_role   GET /api/organization-roles            → sync_organization_role_upsert / _delete（硬删）
  user_role           GET /api/users/:id/roles（逐用户）      → 全量重建（organization_id='' 全局段）
  profile 补拉        GET /api/users 列表响应含 profile      → sync_user_upsert 注入（D2 列唯一来源）
  ssoIdentities       GET /api/users/:id/profile（--sso）    → 同上（默认不拉，N 次调用成本）

说明:
  - 组织角色分配（用户↔组织角色）Logto 无批量端点，对账成本 O(org×user) → 默认不做，
    由组织 token 登录 JIT 精确镜像 + 本脚本 --org-roles 可选全量（遍历组织成员逐个拉角色）；
  - 删除检测: Logto 全量 id 集合 vs 镜像表差集 → 调对应 sync_delete（幂等）；
  - user_role 全量重建前清空（表小；重建失败回滚——单事务）。

用法:
  python reconcile-logto.py --endpoint http://localhost:3001 \
      --m2m-id omnipg_m2m_app --m2m-secret <secret> --pg-dsn "postgresql://app_owner@127.0.0.1:5432/app_db" \
      [--dry-run] [--sso] [--org-roles] [--verbose]

调度（部署机 crontab，每日; Pigsty 宿主）:
  0 3 * * * cd /opt/omnipg && python3 scripts/phase2/reconcile-logto.py \
      --m2m-id ... --m2m-secret ... --pg-dsn ... >> /var/log/omnipg-reconcile.log 2>&1

依赖: psycopg2（Pigsty 自带）；Logto Management API 需 M2M 应用已授管理角色（init-logto.py step1）。
"""

import argparse
import json
import sys
import time
import urllib.parse
import urllib.request

PAGE_SIZE = 500

# ---------------------------------------------------------------------------
# HTTP 工具（同 init-logto.py 风格，无外部依赖）
# ---------------------------------------------------------------------------


def http_get(url, token):
    req = urllib.request.Request(url, headers={"Authorization": f"Bearer {token}"})
    with urllib.request.urlopen(req, timeout=30) as resp:
        return json.loads(resp.read().decode())


def get_m2m_token(endpoint, app_id, app_secret):
    """client_credentials grant 换取 Management API token"""
    body = urllib.parse.urlencode({
        "client_id": app_id,
        "client_secret": app_secret,
        "grant_type": "client_credentials",
        "resource": "https://default.logto.app/api",
        "scope": "all",
    }).encode()
    req = urllib.request.Request(f"{endpoint}/oidc/token", data=body, method="POST")
    req.add_header("Content-Type", "application/x-www-form-urlencoded")
    with urllib.request.urlopen(req, timeout=30) as resp:
        return json.loads(resp.read().decode()).get("access_token")


def paginate(url, token):
    """Management API 分页拉全量（page/page_size）"""
    out = []
    page = 1
    while True:
        sep = "&" if "?" in url else "?"
        batch = http_get(f"{url}{sep}page={page}&page_size={PAGE_SIZE}", token)
        if not batch:
            break
        out.extend(batch)
        if len(batch) < PAGE_SIZE:
            break
        page += 1
    return out


# ---------------------------------------------------------------------------
# 对账核心
# ---------------------------------------------------------------------------


class Reconcile:
    def __init__(self, endpoint, token, pg_conn, dry_run=False, verbose=False):
        self.endpoint = endpoint
        self.token = token
        self.pg = pg_conn          # psycopg2 connection 或 None（dry-run 用假连接）
        self.dry_run = dry_run
        self.verbose = verbose
        self.stats = {"users": 0, "tenants": 0, "members": 0, "roles": 0,
                      "org_roles": 0, "user_roles": 0, "deletes": 0}

    def log(self, msg):
        print(msg, flush=True)

    # -- sync 调用（单事务内批量执行；dry-run 只统计） -----------------------
    def sync_json(self, fn, data):
        """sync_* jsonb 参数函数（payload 形状 = Logto 实体，webhook 同款）"""
        if self.dry_run:
            return
        with self.pg.cursor() as cur:
            cur.execute(f"SELECT {fn}(%s::jsonb)", [json.dumps(data, ensure_ascii=False)])

    def sync_id(self, fn, id_):
        if self.dry_run:
            return
        with self.pg.cursor() as cur:
            cur.execute(f"SELECT {fn}(%s)", [id_])

    def run_query(self, sql):
        if self.dry_run:
            return []
        with self.pg.cursor() as cur:
            cur.execute(sql)
            return cur.fetchall()

    # -- 各实体对账 -----------------------------------------------------------
    def reconcile_users(self):
        users = paginate(f"{self.endpoint}/api/users", self.token)
        ids = set()
        for u in users:
            ids.add(u["id"])
            self.sync_json("sync_user_upsert", u)          # 全字段（含 profile——D2 列来源）
            self.stats["users"] += 1
        # 删除检测: 镜像有而 Logto 无 → 软删
        for (mid,) in self.run_query("SELECT id FROM users WHERE deleted_at IS NULL"):
            if mid not in ids:
                self.sync_id("sync_user_delete", mid)
                self.stats["deletes"] += 1
        return users

    def reconcile_roles(self):
        roles = paginate(f"{self.endpoint}/api/roles", self.token)
        ids = set()
        for r in roles:
            ids.add(r["id"])
            self.sync_json("sync_role_upsert", r)
            self.stats["roles"] += 1
        for (mid,) in self.run_query("SELECT id FROM role"):
            if mid not in ids:
                self.sync_id("sync_role_delete", mid)      # 硬删 + user_role FK CASCADE
                self.stats["deletes"] += 1
        return roles

    def reconcile_org_roles(self):
        roles = paginate(f"{self.endpoint}/api/organization-roles", self.token)
        ids = set()
        for r in roles:
            ids.add(r["id"])
            self.sync_json("sync_organization_role_upsert", r)
            self.stats["org_roles"] += 1
        for (mid,) in self.run_query("SELECT id FROM organization_role"):
            if mid not in ids:
                self.sync_id("sync_organization_role_delete", mid)
                self.stats["deletes"] += 1

    def reconcile_tenants_and_members(self):
        orgs = paginate(f"{self.endpoint}/api/organizations", self.token)
        ids = set()
        for o in orgs:
            ids.add(o["id"])
            self.sync_json("sync_tenant_upsert", o)
            self.stats["tenants"] += 1
        for (mid,) in self.run_query("SELECT id FROM tenants WHERE deleted_at IS NULL"):
            if mid not in ids:
                self.sync_id("sync_tenant_delete", mid)
                self.stats["deletes"] += 1
        # 成员关系全量重建（user_tenants）
        if not self.dry_run:
            with self.pg.cursor() as cur:
                cur.execute("DELETE FROM user_tenants")
        for o in orgs:
            members = paginate(f"{self.endpoint}/api/organizations/{o['id']}/users", self.token)
            for m in members:
                self.sync_json("sync_user_upsert", m)      # 成员可能不在镜像（先建）
                self.stats["members"] += 1
                if not self.dry_run:
                    with self.pg.cursor() as cur:
                        cur.execute(
                            "INSERT INTO user_tenants (organization_id, user_id) "
                            "VALUES (%s, %s) ON CONFLICT DO NOTHING",
                            [o["id"], m["id"]])
        return orgs

    def reconcile_user_roles(self):
        """全局角色分配全量重建（user_role 对账 = 唯一权威通道）"""
        if not self.dry_run:
            with self.pg.cursor() as cur:
                cur.execute("DELETE FROM user_role WHERE organization_id = ''")
        users = paginate(f"{self.endpoint}/api/users", self.token)
        for u in users:
            roles = paginate(f"{self.endpoint}/api/users/{u['id']}/roles", self.token)
            for r in roles:
                self.stats["user_roles"] += 1
                if not self.dry_run:
                    with self.pg.cursor() as cur:
                        cur.execute(
                            "INSERT INTO user_role (user_id, organization_id, role_code, role_id) "
                            "VALUES (%s, '', %s, %s) ON CONFLICT (user_id, organization_id, role_code) DO UPDATE "
                            "SET role_id = EXCLUDED.role_id",
                            [u["id"], r["name"], r["id"]])

    def run(self):
        t0 = time.time()
        self.log(f"[reconcile] start dry_run={self.dry_run}")
        users = self.reconcile_users()
        self.reconcile_roles()
        self.reconcile_org_roles()
        orgs = self.reconcile_tenants_and_members()
        self.reconcile_user_roles()
        if not self.dry_run:
            self.pg.commit()
        self.log(f"[reconcile] done in {time.time() - t0:.1f}s "
                 f"users={self.stats['users']} tenants={self.stats['tenants']} "
                 f"members={self.stats['members']} roles={self.stats['roles']} "
                 f"org_roles={self.stats['org_roles']} user_roles={self.stats['user_roles']} "
                 f"deletes={self.stats['deletes']}")


def main():
    parser = argparse.ArgumentParser(description="Logto ↔ 镜像表对账")
    parser.add_argument("--endpoint", default="http://localhost:3001")
    parser.add_argument("--m2m-id", required=True)
    parser.add_argument("--m2m-secret", required=True)
    parser.add_argument("--pg-dsn", required=True, help="postgresql://app_owner@127.0.0.1:5432/app_db")
    parser.add_argument("--dry-run", action="store_true", help="只输出差异不执行写入")
    parser.add_argument("--sso", action="store_true", help="额外拉取 ssoIdentities（N 次 profile 调用）")
    parser.add_argument("--org-roles", action="store_true", help="额外对账组织角色分配（O(org×user) 调用）")
    parser.add_argument("--verbose", action="store_true")
    args = parser.parse_args()

    token = get_m2m_token(args.endpoint, args.m2m_id, args.m2m_secret)
    if not token:
        print("无法获取管理 token（检查 m2m secret / 角色授权）", file=sys.stderr)
        sys.exit(1)

    pg = None
    if not args.dry_run:
        try:
            import psycopg2
        except ImportError:
            print("需要 psycopg2（Pigsty 自带；pip install psycopg2-binary）", file=sys.stderr)
            sys.exit(1)
        pg = psycopg2.connect(args.pg_dsn)
        pg.autocommit = False

    Reconcile(args.endpoint, token, pg, dry_run=args.dry_run, verbose=args.verbose).run()
    if pg:
        pg.close()


if __name__ == "__main__":
    main()
