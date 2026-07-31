# 移除 Docker PG，统一由 Pigsty 管理：实施记录与网络方案（22号）

> **日期**: 2026-08-03
> **分支**: fix/cicd-v2-deployment-issues
> **性质**: 架构对齐实施记录（落地 `ci-cd-方案.v2.1修复版.md` 决策 #4/#10）
> **关联文档**: 20号（部署配置问题排查）、21号（APISIX 全栈可行性分析）

---

## 一、决策背景

`ci-cd-方案.v2.1修复版.md` 决策 #4/#10 明确：**PostgreSQL/pgBouncer/Redis 由 Pigsty 统一管理，Docker Compose 不单独部署数据库**。

commit `f181e97` 为规避"容器 ↔ WSL2 宿主网络隔离"问题，在 compose 中引入了 `pgsql`(PG17) + `pgbouncer` + `casdoor-db` 三个容器，造成：

1. **双数据库分裂**：宿主 Pigsty PG18（跑迁移/源码/角色）与容器 PG17（跑运行时数据）并存，角色/schema/迁移断链；
2. **PostgREST 不可用**：容器 PG 缺少 `authenticator`/`web_anon` 角色、无 `api_v1_*` schema（20号问题4根因）；
3. **凭据漂移**：容器库密码（`casdoor`）与 Pigsty 库密码（`casdoor_dev_pass`）不一致。

**本文件记录移除 docker PG 的全部动作、网络方案与数据迁移步骤。**

---

## 二、删除清单（已完成 ✅）

| 删除项 | 说明 |
|:--|:--|
| `pgsql` 服务（postgres:17-alpine） | 业务数据库容器 |
| `pgbouncer` 服务（edoburu/pgbouncer） | 连接池容器（宿主 pgbouncer 已监听 0.0.0.0:6432） |
| `casdoor-db` 服务 | Casdoor 专用数据库容器 |
| `pgsql_data` / `casdoor_data` 卷 | 容器数据卷 |
| `5433:5432` 端口映射 | 随 pgsql 移除 |
| `gateway/postgres/init/01-roles.sql` | 宿主 PG 角色由 `infra/pigsty.yml` 的 `pg_users` 创建，无需容器侧初始化 |

## 三、改指清单（已完成 ✅）

| 服务 | 原连接（容器内） | 新连接（宿主 Pigsty） |
|:--|:--|:--|
| postgrest | `authenticator:***@pgbouncer:6432` | `authenticator:${AUTHENTICATOR_PASSWORD}@host.docker.internal:6432/app_db` |
| casdoor | `user=casdoor password=casdoor host=casdoor-db` | `user=casdoor password=${CASDOOR_DB_PASSWORD:-casdoor_dev_pass} host=host.docker.internal port=5432 dbname=casdoor` |
| syncer | `DB_HOST=pgbouncer DB_PORT=6432` | `DB_HOST=host.docker.internal DB_PORT=6432` |

三个服务均增加 `extra_hosts: ["host.docker.internal:host-gateway"]`。

**宿主侧就绪核对（已确认 ✅）**：

| 项目 | 状态 |
|:--|:--|
| pgBouncer 监听 | `infra/pgbouncer.ini`: `listen_addr = 0.0.0.0`, `listen_port = 6432` ✅ |
| pgBouncer 路由 | `[databases]` 含 `app_db`、`casdoor` ✅ |
| 认证用户 | `infra/userlist.txt` 含 `app_owner`/`authenticator`/`casdoor` ✅ |
| pg_hba | `127.0.0.1/32` + `172.17.0.0/16` + `172.20.0.0/16` 均放行 scram-sha-256 ✅ |
| PG 角色 | `pigsty.yml` `pg_users` 创建 `authenticator`(LOGIN)/`web_anon`(NOLOGIN)/`casdoor` ✅ |
| PG 库 | `app_db`(owner app_owner)、`casdoor`(owner casdoor) ✅ |

---

## 四、网络方案（关键！容器 → WSL2 宿主服务）

### 4.1 问题本质

- **Pigsty 运行在 WSL2 Ubuntu 发行版**内（PG/pgbouncer 监听 0.0.0.0）；
- **Docker 容器运行在 docker-desktop 发行版**内；
- `host.docker.internal` 在 Docker Desktop WSL2 后端下解析为 **Windows 宿主 IP**，**不是** Ubuntu 发行版 IP；
- WSL2 发行版 IP 每次重启漂移 → 不能硬编码进 compose。

### 4.2 方案 A（推荐）：Windows 11 22H2+ 的 mirrored 网络模式

`%USERPROFILE%\.wslconfig`：

```ini
[wsl2]
networkingMode=mirrored
```

效果：WSL2 与 Windows 共享 IP 与回环地址，`127.0.0.1` 双向直达。容器内 `host.docker.internal:6432` → Windows 6432 → WSL2 pgbouncer（源 IP 为 127.0.0.1/172.20.0.0/16，pg_hba 已放行）。**一次配置，重启免疫。**

生效方式：`wsl --shutdown` 后重新进入 WSL2。

### 4.3 方案 B：Windows 10（现状）端口转发 + 开机脚本

Windows 上把 6432/5432 转发到 WSL2 发行版 IP（脚本每次开机/WSL 重启后执行）：

```powershell
# scripts/wsl-portproxy.ps1（新增，放 Windows 侧计划任务或启动项）
$ErrorActionPreference = "SilentlyContinue"
$wslIp = (wsl hostname -I).Trim().Split(' ')[0]
if (-not $wslIp) { Write-Host "WSL2 未启动"; exit 1 }

foreach ($port in 5432, 6432) {
    netsh interface portproxy delete v4tov4 listenport=$port listenaddress=0.0.0.0
    netsh interface portproxy add v4tov4 listenport=$port listenaddress=0.0.0.0 connectport=$port connectaddress=$wslIp
    Write-Host "portproxy $port -> $wslIp ok"
}
# 验证
netsh interface portproxy show all
```

要求：Windows 防火墙放行 5432/6432（`New-NetFirewallRule` 或 netsh advfirewall）。

### 4.4 连通性验证（家庭电脑上执行，先于整体启动）

```bash
# 从容器内验证到宿主 pgbouncer
docker run --rm --network gateway_app-net alpine sh -c \
  'apk add --no-cache postgresql-client >/dev/null 2>&1; PGPASSWORD=authenticator_dev_pass psql -h host.docker.internal -p 6432 -U authenticator -d app_db -c "SELECT 1"'
# 预期输出: 1 行 "1"
```

或简化：

```bash
docker exec app-postgrest sh -c 'wget -qO- http://host.docker.internal:6432 >/dev/null && echo 可达 || echo 不可达'
# 注意: pgbouncer 非 HTTP，用 nc 更准确:
docker exec app-postgrest sh -c 'nc -zv host.docker.internal 6432 2>&1'
```

---

## 五、数据迁移步骤（容器卷 → 宿主 PG）

> 若容器卷内无重要数据（本地开发重置可接受），直接跳到 §5.3 重新初始化即可。

### 5.1 app_db 数据迁移（如需要保留）

```bash
# ① 在旧容器还在时导出（若已删除容器，卷数据可用 docker run 挂载临时容器导出）
docker exec pgsql pg_dump -U app_owner -d app_db -Fc -f /tmp/app_db.dump
docker cp pgsql:/tmp/app_db.dump ./app_db.dump

# ② 导入宿主 Pigsty PG（先确保 schema/迁移已就绪，避免对象冲突）
bash scripts/deploy-db.sh development            # dbmate up + apply-src
PGPASSWORD=dev_password_change_me pg_restore -h 127.0.0.1 -U app_owner -d app_db --clean --if-exists ./app_db.dump
```

### 5.2 Casdoor 数据迁移（组织/应用/用户）

```bash
# ① 导出旧库
docker exec casdoor-db pg_dump -U casdoor -d casdoor -Fc -f /tmp/casdoor.dump
docker cp casdoor-db:/tmp/casdoor.dump ./casdoor.dump

# ② 导入宿主 casdoor 库
PGPASSWORD=casdoor_dev_pass pg_restore -h 127.0.0.1 -U casdoor -d casdoor --clean --if-exists ./casdoor.dump
```

### 5.3 全新初始化（推荐，本地开发）

```bash
# ① 数据库: 宿主 PG 已有角色/库（pigsty.yml），直接迁移+源码
bash scripts/deploy-db.sh development

# ② Casdoor: 首次启动连宿主 casdoor 库会自动建表；随后访问 http://localhost:8000
#    初始管理员: admin / 123（首次登录后务必修改）

# ③ 网关
cd gateway && docker compose up -d
bash ../scripts/setup_apisix.sh
```

---

## 六、架构落地后的最终形态

```
Windows / WSL2 Ubuntu 26.04
├── Pigsty v4.4.0（宿主）
│   ├── PostgreSQL 18  (5432)   ← app_db / casdoor 唯一数据源
│   ├── pgBouncer      (6432)   ← 容器接入点（listen 0.0.0.0）
│   ├── Redis          (6379)
│   ├── etcd           (2379)   ← Pigsty 自身使用
│   ├── Nginx WebUI    (80/8080)
│   └── Grafana/VM     (3000/8428)
│
└── Docker Desktop（compose 网关栈）
    ├── app-etcd       (容器内 2379)  ← APISIX 配置中心（不映射宿主端口）
    ├── app-apisix     (9080/9443/9180/7085)  ← 网关 + Admin API + 内置 Dashboard
    ├── app-postgrest  (3001)  → host.docker.internal:6432
    ├── app-swagger    (8082)  → app-postgrest:3000 (spec) / localhost:3001 (浏览器)
    ├── app-casdoor    (8000)  → host.docker.internal:5432 (casdoor 库)
    └── policy-syncer  (容器内) → host.docker.internal:6432 + apisix:9180
```

**单一数据源**：所有业务数据、Casdoor 数据、策略数据均落在宿主 Pigsty PG；compose 只承载无状态网关组件。

---

## 七、验证清单

| # | 验证项 | 命令 | 预期 |
|:--|:--|:--|:--|
| 1 | 网络链路 | §4.4 nc 测试 | 端口可达 |
| 2 | 宿主 pgbouncer | `PGPASSWORD=authenticator_dev_pass psql -h 127.0.0.1 -p 6432 -U authenticator -d app_db -c "SELECT 1"` | 返回 1 |
| 3 | PostgREST | `curl -s http://localhost:3001/ \| wc -c` | >2000 字符（完整 OpenAPI） |
| 4 | Casdoor | `curl -sf http://localhost:8000/api/health` | healthy |
| 5 | APISIX 就绪 | `curl -sf http://localhost:7085/status` | `{"status":"ok"}` |
| 6 | Dashboard | 浏览器 `http://localhost:9180/ui` | 输入 Admin Key 后可用 |
| 7 | 路由 | `bash scripts/setup_apisix.sh` | 8 条路由全部 ✅ |
| 8 | 登录链路 | `curl -X POST http://localhost:9080/api/v1/rpc/user_login_sso -d '{"p_username":"admin","p_password":"admin123"}'` | 返回 JWT |
| 9 | Syncer | `docker logs policy-syncer --tail 10` | 无连接错误 |
| 10 | 无 docker PG 残留 | `docker compose ps` | 仅 6 个服务，无 pgsql/pgbouncer/casdoor-db |

---

## 八、与既有文档的关系

| 文档 | 状态 |
|:--|:--|
| 20号 §4.3 方案 A（移除 docker PG 连宿主） | **已实施**（本文件）；方案 B（保留 docker PG 补角色）**已废弃** |
| 20号 §4.3 方案 B 涉及的 `gateway/postgres/init` | 已删除 |
| `测试验证清单-Phase4.md` Step 3 | 措辞隐含 docker PG，建议下次修订时按 §六 最终形态更新 |
| 21号（APISIX 全栈） | 不受影响，继续有效 |
