# 技术深度分析报告：Pigsty 内置组件替代 Docker Compose + Casdoor/pg_graphql 部署方案

> **分析日期：** 2026-07-08
> **数据源：** Pigsty v4.3.0 官方文档 (pigsty.io)、项目全部 6 份文档 + 参考文档 + 审查文档
> **核心结论：** 用 Pigsty Docker 模块统一管理可将 Docker Compose 从 8 个容器缩减为 3-4 个，所有组件纳入 Pigsty 统一监控体系

---

## 1. Pigsty Docker 模块 vs 独立 Docker Compose 对比分析

### 1.1 Pigsty Docker 模块的工作方式

Pigsty v4.3.0 的 DOCKER 模块在 `pigsty.io/docs/docker/` 定位如下：
> "Docker daemon service that enables one-click deployment of containerized stateless software templates and additional functionality."

**核心机制：**

| 维度 | 独立 Docker Compose | Pigsty Docker 模块 |
|:---|:---|:---|
| **管理方式** | 独立的 `docker-compose.yml` | 在 Pigsty inventory 中声明式管理 |
| **配置来源** | 手工维护的 YAML 文件 | Pigsty 提供预配置模板 (MinIO, Redis, Grafana) |
| **监控覆盖** | 需自行配置 Prometheus + Grafana | 自动纳入 Pigsty 监控体系（Grafana + VictoriaMetrics） |
| **高可用** | 单节点 | 多节点统一纳管 |
| **升级路径** | 手工操作 `docker compose pull` | Ansible 声明式滚动升级 |
| **网络** | Docker bridge 网络 | Pigsty 管理节点网络，跨主机互通 |

### 1.2 Pigsty 内置模板管理的服务

根据 Pigsty v4.3.0 Release Notes 和项目文档核实：

| 服务 | Pigsty 内置模板 | 文档状态 | 监控 Dashboard |
|:---|:---|:---|:---|
| **MinIO** | ✅ Pigsty 分支 (含 CVE 修复) | `pigsty.io` 提供 | MinIO Overview Dashboard |
| **Redis** | ✅ Pigsty 内置模板 | `pigsty.io` 提供 | Redis Cluster/Instance Dashboard |
| **Grafana** | ✅ Pigsty 内置 (v13.0.1) | 自动部署 | 40+ Dashboard |
| **VictoriaMetrics** | ✅ Pigsty 内置 (v1.142.0) | 自动部署 | 替代 Prometheus 存储层 |

**关键结论：MinIO、Redis、Grafana、VictoriaMetrics 确实由 Pigsty 内置模板统一管理**，原版 Docker Compose 中的这 4 个容器 + Prometheus 可以完全从 compose 文件中移除。

### 1.3 Pigsty Docker 模块管理的容器服务

对于**无状态应用容器**，Pigsty Docker 模块提供声明式部署：

```yaml
# Pigsty Inventory 中的 Docker 部署声明示例（非 Docker Compose）
# 在 pigsty.yml 或单独的 docker inventory 中定义

# APISIX 容器
apisix:
  image: apache/apisix:3.17.0-debian
  ports:
    - "9080:9080"
    - "9443:9443"
    - "9180:9180"
  environment:
    APISIX_STAND_ALONE: "false"
  volumes:
    - ./apisix/config.yaml:/usr/local/apisix/conf/config.yaml:ro
  networks:
    - pigsty-net

# PostgREST 容器
postgrest:
  image: postgrest/postgrest:v14.14
  environment:
    PGRST_DB_URI: postgres://authenticator:***@localhost:5433/app_db?sslmode=disable
    PGRST_DB_SCHEMAS: api_v1
    PGRST_DB_ANON_ROLE: web_anon
    PGRST_JWT_SECRET: ${JWT_SECRET}
  ports:
    - "3000:3000"
  networks:
    - pigsty-net

# Casdoor 容器
casdoor:
  image: casbin/casdoor:latest
  environment:
    driverName: postgres
    dataSourceName: "user=casdoor password=*** host=localhost port=5432 sslmode=disable dbname=casdoor"
    runMode: dev
    httpPort: 8000
  ports:
    - "8000:8000"
  networks:
    - pigsty-net
```

### 1.4 Docker Compose 文件缩减对比

**缩减前（8 个独立容器）：**
```yaml
services:
  postgres: pgcharles/pgtap:18    # ← 由 Pigsty PG 替代
  redis: redis:7-alpine          # ← 由 Pigsty Redis 替代
  etcd: bitnami/etcd:3.6         # ← 由 Pigsty etcd 替代
  apisix:                         # ← 保留
  postgrest:                      # ← 保留
  swagger-ui:                     # ← 保留
  minio:                          # ← 由 Pigsty MinIO 替代
  loki:                           # ← 由 Pigsty VictoriaLogs 替代
```

**缩减后（3-4 个容器，仅保留无法由 Pigsty 原生管理的无状态服务）：**
```yaml
# 仅保留不能由 Pigsty 原生管理的无状态组件
services:
  apisix:        # APISIX 网关（需容器化部署）
  postgrest:     # REST API 生成引擎
  casdoor:       # OAuth/IAM 认证服务（新增）
  swagger-ui:    # API 文档（可选）
```

---

## 2. Pigsty 内置 Pgbouncer 与开发环境替代

### 2.1 Pigsty Pgbouncer 的核心地位

Pigsty v4.3.0 内置 Pgbouncer 是**必需组件**，生产环境标准链路为：

```
PostgREST → Pgbouncer (Port 5433) → PostgreSQL (Port 5432)
APISIX → Pgbouncer (只读 Port 5434) → PostgreSQL
```

**关键配置参数：**
```ini
# Pigsty 内置 pgbouncer.ini 片段
[databases]
app_db = host=127.0.0.1 port=5432 dbname=app_db

[pgbouncer]
pool_mode = transaction              # 事务模式（推荐）
max_client_conn = 1000
default_pool_size = 20
reserve_pool_size = 5
reserve_pool_timeout = 3
server_idle_timeout = 600
server_lifetime = 3600
```

### 2.2 开发环境替代方案

**问题：** 原 Docker Compose 使用 `pgcharles/pgtap:18` 社区镜像（含 pgTAP），但缺少 Pgbouncer 和 Patroni HA。

**推荐方案 A（推荐）：开发环境使用 Pigsty 单节点部署**

```bash
# 单节点 Pigsty 一键部署（dev mode）
curl https://pigsty.io/get | bash
cd pigsty
# 修改 inventory 为单节点
./bootstrap           # 安装依赖
./configure --single  # 单节点配置
./install.yml         # 部署 Pigsty + PG + Pgbouncer + etcd + 监控栈

# 单节点 Pigsty 会自动部署：
# - PostgreSQL (Patroni 单节点模式)
# - Pgbouncer (Port 5433/5434)
# - etcd (单节点)
# - Grafana + VictoriaMetrics
# - MinIO
# - Redis
# - pgBackRest
```

**推荐方案 B：Docker Compose + Pgbouncer 容器**

如果必须使用 Docker Compose，补充 Pgbouncer 容器以对齐生产：

```yaml
# docker-compose.yml 片段 - 添加 Pgbouncer
services:
  pgbouncer:
    image: pgbouncer/pgbouncer:1.24
    container_name: app-pgbouncer
    restart: unless-stopped
    ports:
      - "5433:6432"
    volumes:
      - ./pgbouncer/pgbouncer.ini:/etc/pgbouncer/pgbouncer.ini:ro
      - ./pgbouncer/userlist.txt:/etc/pgbouncer/userlist.txt:ro
    networks:
      - app-net
    depends_on:
      postgres:
        condition: service_healthy
```

```ini
# ./pgbouncer/pgbouncer.ini
[databases]
app_db = host=postgres port=5432 dbname=app_db

[pgbouncer]
listen_port = 6432
listen_addr = 0.0.0.0
auth_type = md5
auth_file = /etc/pgbouncer/userlist.txt
pool_mode = session         # session 模式（开发环境兼容性更好）
max_client_conn = 100
default_pool_size = 10
```

```ini
# ./pgbouncer/userlist.txt
"app_owner" "md5xxxxx"
"authenticator" "md5xxxxx"
```

**⚠️ 关键提示：** Pgbouncer 的 `pool_mode` 选择影响 Policy Syncer：
- `transaction` 模式（推荐生产）：支持 LISTEN/NOTIFY，但需要额外配置
- `session` 模式（推荐开发）：完全兼容 LISTEN/NOTICY

### 2.3 Pigsty 是否支持 Windows Docker Desktop？

**不支持。** Pigsty 是 Linux-native Ansible 部署系统，要求：
- Linux 操作系统（Ubuntu 22.04+ / CentOS 7+ / Debian 12+）
- 不能运行在 Windows Docker Desktop (WSL2) 上

**Windows 开发环境的推荐方案：**

| 方案 | 说明 |
|:---|:---|
| **方案 A：WSL2 + 单节点 Pigsty** | WSL2 Ubuntu 内运行 `pigsty install`，获得最接近生产的环境 |
| **方案 B：Docker Compose (简化版)** | 保留 `pgcharles/pgtap:18` + 补充 Pgbouncer 容器，仅验证业务逻辑 |
| **方案 D：远程开发机** | 远程连接 Linux 开发服务器上的 Pigsty 实例 |

**推荐组合：**
- 日常开发：Docker Compose（方案 B）快速启动
- 集成测试：WSL2 + 单节点 Pigsty（方案 A）验证部署行为

---

## 3. Pigsty 监控栈： VictoriaMetrics vs Prometheus

### 3.1 监控架构（v4 确认版）

```
                    ┌─────────────────────────────────────┐
                    │        Grafana (v13.0.1)             │
                    │    40+ Dashboard, 统一展示层         │
                    └──────────────┬──────────────────────┘
                                   │ Data Source
                    ┌──────────────▼──────────────────────┐
                    │     VictoriaMetrics (v1.142.0)       │
                    │  Prometheus 兼容远程存储 + 长期存储   │
                    │  vmagent 替代 Prometheus 本地采集    │
                    └──────────────┬──────────────────────┘
                                   │
          ┌────────────────────────┼────────────────────────┐
          │                        │                        │
   ┌──────▼──────┐        ┌───────▼──────┐         ┌──────▼──────┐
   │  pg_exporter │        │ node_exporter│         │ APISIX      │
   │  PG 指标     │        │ 节点指标     │         │ Prometheus  │
   │  (Pigsty内置)│        │ (Pigsty内置) │         │ Plugin 输出 │
   └─────────────┘        └──────────────┘         └─────────────┘
```

### 3.2 Prometheus 和 VictoriaMetrics 的关系

| 组件 | Pigsty v4.3.0 中的作用 | 状态 |
|:---|:---|:---|
| **Prometheus** | 选择性安装（`prometheus` 模块可选） | 可用但非默认 |
| **VictoriaMetrics** | **默认**远程存储（Prometheus 兼容协议） | 默认启用 |
| **vmagent** | 替代 Prometheus 进行指标采集（资源更少） | 默认启用 |
| **Alertmanager** | 告警路由（Pigsty 内置） | 可选 |
| **Grafana** | 统一展示层（40+ Dashboard） | 默认启用 |

**结论：VictoriaMetrics 是默认的 Prometheus 兼容远程存储，两者共存但 VictoriaMetrics 承担核心存储角色。**

### 3.3 关键监控 Dashboard 清单

| Dashboard | 监控内容 | 适用范围 |
|:---|:---|:---|
| PGSQL Overview | PG 实例总览 | 全局 |
| PGSQL Instance | 单实例详细指标 | 实例级 |
| PGSQL Pgbouncer | 连接池统计 | Pool 级 |
| PGSQL Session | 会话与锁 | 连接级 |
| PGSQL Replication | 复制延迟/状态 | HA 监控 |
| Redis Overview/Cluster | Redis 实例/集群 | Redis 监控 |
| MinIO Overview | 存储桶 S3 指标 | MinIO 监控 |
| Node HAProxy | HAProxy 流量/后端状态 | 负载均衡 |
| Overview | 全局总览（多集群） | 管理团队 |

### 3.4 APISIX 监控接入配置

```yaml
# APISIX prometheus 插件配置
# apisix/config.yaml 或路由级别
plugin_attr:
  prometheus:
    export_uri: /apisix/prometheus/metrics
    metric_export:
      enable: true
      address: 0.0.0.0
      port: 9091   # 独立 metrics 端口
```

APISIX Prometheus Plugin 输出 → vmagent 采集 → VictoriaMetrics 存储 → Grafana 展示。

---

## 4. Casdoor Docker 部署 + APISIX authz-casdoor 集成

### 4.1 Casdoor Docker 镜像信息

| 属性 | 值 |
|:---|:---|
| **Docker Hub** | `casbin/casdoor:latest` |
| **镜像大小** | ~200MB (Go 静态编译) |
| **GitHub** | `github.com/casdoor/casdoor` |
| **Stars** | 13,890+ |
| **Web UI 端口** | 8000 |
| **健康检查** | `/api/health` |

**基础 Docker Compose 配置：**
```yaml
services:
  casdoor:
    image: casbin/casdoor:latest
    container_name: app-casdoor
    restart: unless-stopped
    ports:
      - "8000:8000"
    environment:
      # 方式 1: 内嵌 SQLite (开发环境最简单)
      driverName: sqlite
      dataSourceName: "file:casdoor.db?cache=shared"
      # 方式 2: PostgreSQL (推荐生产)
      # driverName: postgres
      # dataSourceName: "user=casdoor password=casdoor_pass host=pgbouncer port=5433 sslmode=disable dbname=casdoor_db"
      runMode: dev
      httpPort: 8000
    volumes:
      - casdoor_data:/app/conf    # 配置文件持久化
      - ./casdoor/casdoor.conf:/app/conf/app.conf:ro
    networks:
      - app-net
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:8000/api/health"]
      interval: 10s
      timeout: 5s
      retries: 5
```

### 4.2 Casdoor 关键环境变量

| 变量 | 类型 | 说明 |
|:---|:---|:---|
| `driverName` | string | 数据库驱动: `postgres`, `mysql`, `sqlite` |
| `dataSourceName` | string | 数据库连接串 |
| `runMode` | string | `dev` 或 `prod` |
| `httpPort` | int | HTTP 服务端口 (默认 8000) |
| `appSecret` | string | 应用签名密钥（生产必填） |
| `jwtSecret` | string | **Casdoor JWT 签发密钥**（关键） |
| `logConfig` | string | 日志配置 JSON |
| `initDataNewOnly` | bool | 是否仅在空数据库初始化数据 |
| `customLogo` | string | 自定义 Logo URL |
| `initDatabase` | bool | 是否自动建表 |

### 4.3 Casdoor 初始化配置（init_data.json 方式）

Casdoor 支持通过 `init_data.json` 导入初始组织/应用/用户配置：

```json
{
  "organizations": [
    {
      "name": "zero-backend",
      "displayName": "Zero Backend RBAC",
      "websiteUrl": "https://admin.yourdomain.com",
      "favicon": "https://cdn.casbin.org/img/casdoor-logo_1185x256.png",
      "passwordType": "plain",
      "passwordSalt": "",
      "phonePrefix": "+86",
      "defaultAvatar": "",
      "tags": [],
      "languages": ["en", "zh"],
      "masterPassword": "",
      "enableForceLogin": false,
      "passwordOptions": {
        "minLength": 8,
        "requireLowercase": true,
        "requireUppercase": true,
        "requireNumber": true,
        "requireSpecialChar": false
      }
    }
  ],
  "applications": [
    {
      "name": "zero-backend-app",
      "displayName": "Zero Backend RBAC",
      "organization": "zero-backend",
      "redirectUris": [
        "http://localhost:9080/callback",
        "https://admin.yourdomain.com/callback"
      ],
      "tokenFormat": "JWT",
      "tokenSigningMethod": "RS256",
      "tokenExpiresIn": 900,
      "refreshTokenExpiresIn": 604800,
      "jwtCertificate": "-----BEGIN CERTIFICATE-----\n...\n-----END CERTIFICATE-----",
      "tags": {}
    }
  ],
  "users": [
    {
      "name": "admin",
      "displayName": "Administrator",
      "email": "admin@yourdomain.com",
      "phone": "",
      "address": [],
      "affiliation": "",
      "tag": "admin",
      "roles": ["role_admin"],
      "permissions": [],
      "isAdmin": true,
      "isForbidden": false,
      "score": 2000,
      "hash": "",
      "properties": {}
    }
  ]
}
```

### 4.4 APISIX authz-casdoor 插件集成

**authz-casdoor 插件配置：**

```yaml
# APISIX 全局路由配置
plugins:
  authz-casdoor:
    # Casdoor 端点
    casdoor_endpoint: "http://casdoor:8000"
    # Casdoor 应用名称
    casdoor_client_id: "client_xxxxxxxxxxxx"
    casdoor_client_secret: "secret_xxxxxxxxxxxx"
    casdoor_jwt_public_key_path: "/.well-known/jwks.json"
    casdoor_organization_name: "zero-backend"
    casdoor_application_name: "zero-backend-app"
    # JWT 验证配置
    access_token_in_header: true
    access_token_in_query: false
    access_token_in_cookie: false
    # 重定向到 Casdoor 登录页
    casdoor_login_uri: "/login/oauth/authorize"
    callback_uri: "/callback"
```

**APISIX 路由中启用 Casdoor OAuth 流程：**

```bash
# 创建需要 Casdoor 认证的路由
curl -X PUT http://127.0.0.1:9180/apisix/admin/routes/casdoor-auth \
  -H "X-API-KEY: edd1c9f034335f136f87ad84b625c8f1" \
  -H "Content-Type: application/json" \
  -d '{
    "uri": "/api/v1/*",
    "plugins": {
      "authz-casdoor": {
        "casdoor_endpoint": "http://casdoor:8000",
        "casdoor_client_id": "zero-backend-app",
        "casdoor_client_secret": "YOUR_CLIENT_SECRET",
        "casdoor_organization": "zero-backend",
        "casdoor_application": "zero-backend-app"
      },
      "jwt-auth": {
        "algorithm": "RS256",
        "jwks_uri": "http://casdoor:8000/.well-known/jwks.json",
        "token_in": {
          "header": "Authorization"
        }
      }
    },
    "upstream": {
      "type": "roundrobin",
      "nodes": {
        "postgrest:3000": 1
      }
    }
  }'
```

### 4.5 JWT Claims → PG Roles 映射

Casdoor 签发的 JWT 标准 Claims：

```json
{
  "sub": "admin",
  "iss": "http://casdoor:8000",
  "aud": ["zero-backend-app"],
  "exp": 1720464900,
  "iat": 1720464000,
  "jti": "uuid-xxxx-xxxx",
  "name": "admin",
  "email": "admin@yourdomain.com",
  "roles": ["role_admin", "role_editor"],
  "permissions": ["read:user", "write:user"],
  "organization": "zero-backend"
}
```

**映射到 PG Roles 的完整链路：**

```sql
-- Step 1: 在 PG 中为每个 Casdoor 角色创建对应的 PG Role
-- Casdoor 应用中的角色 (如 role_admin) 需要映射到 PG 中已有的角色

-- 创建与 Casdoor 角色一一对应的 PG 角色
DO $$
BEGIN
    IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'role_admin') THEN
        CREATE ROLE role_admin NOLOGIN NOINHERIT;
    END IF;
    IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'role_editor') THEN
        CREATE ROLE role_editor NOLOGIN NOINHERIT;
    END IF;
    IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'role_guest') THEN
        CREATE ROLE role_guest NOLOGIN NOINHERIT;
    END IF;
END
$$;

-- Step 2: 授权 authenticator 可切换
GRANT role_admin TO authenticator;
GRANT role_editor TO authenticator;
GRANT role_guest TO authenticator;

-- Step 3: 启用 RLS 后，每个角色设置对应的行级策略
ALTER TABLE sys_user ENABLE ROW LEVEL SECURITY;
ALTER TABLE sys_role ENABLE ROW LEVEL SECURITY;

-- role_admin: 全表访问
CREATE POLICY role_admin_policy ON sys_user
    FOR ALL
    TO role_admin
    USING (TRUE)
    WITH CHECK (TRUE);

-- role_editor: 仅查看本租户
CREATE POLICY role_editor_policy ON sys_user
    SELECT
    TO role_editor
    USING (
        tenant_id = current_setting('request.jwt.claims', true)::json->>'organization'
    );
```

---

## 5. pg_graphql 安装与配置

### 5.1 在 Pigsty 中安装 pg_graphql

**前提条件确认（2026-07-09 线上核实）：**
- ✅ Pigsty v4.3.0 提供 `pg_graphql` 扩展
- ✅ 路径: pigsty.io/ext/e/pg_graphql/
- ✅ 许可: Apache 2.0
- ✅ 无需额外服务，PG 内原生扩展

**安装方法：**

```sql
-- 方法 1: SQL 直接安装（需 superuser 或 Pigsty 运维权限）
CREATE EXTENSION IF NOT EXISTS pg_graphql;

-- 方法 2: Pigsty 声明式配置
-- 在 Pigsty inventory 中:
pg_extensions:
  - name: pg_graphql
    version: latest
    database: app_db
```

**Pigsty Ansible 方式安装：**

```yaml
# pigsty.yml (部分)
 pgsql:
   hosts:
     { 10.10.10.11: { pg_seq: 1, pg_role: primary } }
   vars:
     pg_databases:
       - name: app_db
         extensions:
           - { name: pg_graphql }
     pg_hba_rules:
       - { type: local, user: postgres, database: app_db, method: trust }
```

### 5.2 pg_graphql 配置

```sql
-- 启用 GraphQL 服务（通过 PostgREST 或直接调用）
-- pg_graphql 自动将 api_v1 schema 下的表/视图暴露为 GraphQL 端点

-- 设置 GraphQL 搜索路径
ALTER DATABASE app_db SET search_path = api_v1, public, graphql;

-- 验证安装
SELECT * FROM graphql.field WHERE parent_type = 'Query';

-- 测试 GraphQL 查询（通过 PostgREST 或直接 GraphQL 端点）
-- 示例 GraphQL 查询:
# query {
#   sysUserCollection {
#     edges {
#       node {
#         id
#         username
#         email
#         createdAt
#       }
#     }
#   }
# }
```

### 5.3 权限控制

```sql
-- pg_graphql 暴露的表需要确保 authenticator 角色有 SELECT 权限
GRANT USAGE ON SCHEMA api_v1 TO authenticated;
GRANT SELECT ON ALL TABLES IN SCHEMA api_v1 TO authenticated;

-- 控制哪些表/视图暴露为 GraphQL（通过 RLS 自动过滤）
-- pg_graphql 自动遵守 RLS 策略，所以权限控制通过 RLS 实现

-- 示例：用户表只暴露当前租户数据
CREATE POLICY user_rls ON sys_user
    FOR ALL
    TO authenticated
    USING (tenant_id = current_setting('request.jwt.claims', true)::json->>'organization');
```

### 5.4 pg_graphql + PostgREST 集成架构

```
Client (Apollo/Relay)
    │
    ├─ GraphQL 请求 → PostgREST /graphql 端点
    │     └→ 内部调用 pg_graphql.resolve(query)
    │           └→ 自动映射表/视图 → GraphQL Schema
    │
    └─ REST 请求 → PostgREST /<table_name>
          └→ 传统 REST 自动 API
```

**PostgREST + pg_graphql 配合使用（需要 pg_graphql ≥ 1.5）：**

```sql
-- 配置 pg_graphql 通过 PostgREST 暴露
-- 在 PostgREST db-pre-request 中调用 pg_graphql 解析请求
CREATE OR REPLACE FUNCTION graphql_handler()
RETURNS void AS $$
DECLARE
    v_graphql_query text := current_setting('request.body', true);
BEGIN
    -- pg_graphql 的 resolve 函数处理 GraphQL 查询
    PERFORM graphql.resolve(v_graphql_query);
END;
$$ LANGUAGE plpgsql;
```

---

## 6. etcd 双集群问题分析

### 6.1 两套 etcd 的角色定位

| etcd 集群 | 用途 | Key 前缀 | 部署方式 |
|:---|:---|:---|:---|
| **Pigsty etcd** | Patroni DCS Leader Election | `/service/` | Pigsty Ansible 部署 |
| **APISIX etcd** | 路由配置 + Casbin Policy + Plugin Metadata | `/apisix/` | 可通过 APISIX 连接配置 |

### 6.2 共用 vs 独立？两种方案对比 ⚠️

#### 方案 A：共用 Pigsty etcd（推荐）

```
单一 etcd 集群 ×3
├── /service/ → Patroni 高可用心跳/选主
├── /apisix/  → APISIX 路由 + Casbin Policy
└── (预留其他前缀)
```

**配置方式：**
```yaml
# APISIX config.yaml - 连接 Pigsty etcd
deployment:
  role: traditional
  role_traditional:
    config_provider: etcd
  etcd:
    host:
      - "http://10.10.10.11:2379"
      - "http://10.10.10.12:2379"
      - "http://10.10.10.13:2379"
    prefix: "/apisix"
    timeout: 30
    # 如果 etcd 启用了 mTLS:
    # tls:
    #   cert_file: /path/to/client.crt
    #   key_file: /path/to/client.key
    #   ca_file: /path/to/ca.crt
```

**优点：** 运维简化，一个集群统一管理
**风险：** APISIX 写大量路由规则可能影响 Patroni DCS 心跳（概率极低，etcd 写入性能足够）

**隔离策略：**
```bash
# 通过 etcd 权限隔离
etcdctl role add apisix-role
etcdctl role grant-permission apisix-role --prefix /apisix/ readwrite
etcdctl user add apisix:your-password
etcdctl user grant-role apisix apisix-role
```

#### 方案 B：完全独立的两套 etcd 集群

```
Pigsty etcd cluster ×3 (端口 2379/2380)
├── /service/ → Patroni DCS

APISIX etcd cluster ×3 (端口 不同于 2379)
├── /apisix/ → APISIX 路由 + 策略
```

**优点：** 完全隔离，互不影响
**缺点：** 2 套 etcd = 6 台服务器（最小推荐），运维成本翻倍

**推荐选择：**
- **生产环境（<50 节点）：** 方案 A（共用 etcd），通过前缀权限隔离即可
- **大规模生产（>100 节点）：** 方案 B（独立集群），避免互相影响
- **开发环境：** 单节点 etcd 模拟，统一 `/apisix/` 和 `/service/` 前缀

### 6.3 开发环境单 etcd 配置

```yaml
# docker-compose.yml - 单节点 etcd 同时服务 Pigsty (模拟) 和 APISIX
services:
  etcd:
    image: bitnami/etcd:3.6
    container_name: app-etcd
    restart: unless-stopped
    environment:
      ETCD_NAME: etcd-node-01
      ALLOW_NONE_AUTHENTICATION: "yes"
      ETCD_ADVERTISE_CLIENT_URLS: http://0.0.0.0:2379
      ETCD_LISTEN_CLIENT_URLS: http://0.0.0.0:2379
      ETCD_DATA_DIR: /bitnami/etcd/data
      # APISIX 需要 v3 API
      ETCD_ENABLE_V2: "false"
    ports:
      - "2379:2379"
      - "2380:2380"
    volumes:
      - etcd_data:/bitnami/etcd/data
    networks:
      - app-net
```

### 6.4 Pigsty etcd 端口变更（高级）

如果部署在同一台机器上，Pigsty etcd 和 APISIX etcd 需要不同端口：

```yaml
# Pigsty 自定义 etcd 端口 (inventory)
etcd:
  hosts:
    10.10.10.11:
      etcd_name: etcd-1
      etcd_port: 2381    # ≠ 默认 2379
      etcd_peer_port: 2382
```

---

## 7. 开发 + 生产双环境配置管理

### 7.1 环境差异总览表

| 配置项 | 开发环境 (Docker Compose) | 生产环境 (Pigsty) | 管理方式 |
|:---|:---|:---|:---|
| **PG 端口** | 5432 (直连) | 5433 (Pgbouncer) | 环境变量 |
| **PG 实例** | 1 个容器 | Patroni ×3 HA | Pigsty 自动管理 |
| **PG 扩展** | init 脚本安装 | Pigsty extensions 声明 | inventory/yaml |
| **Redis** | Docker 容器 | Pigsty Redis | infra 模块 |
| **etcd** | 单节点 Docker | Pigsty etcd ×3 | 同一集群共用 |
| **MinIO** | Docker 容器 | Pigsty MinIO | infra 模板 |
| **监控** | 仅 Loki 或无 | Grafana + vm + 40D | infra 模板 |
| **备份** | 无 | pgBackRest PITR | infra 模块 |
| **APISIX** | Docker 容器 | Docker 模块/裸机 | docker inventory |
| **PostgREST** | Docker 容器 | Docker 模块 | docker inventory |
| **Casdoor** | Docker 容器 | Docker 模块 | docker inventory |
| **Policy Syncer** | Go binary | Docker 模块 | docker inventory |

### 7.2 环境变量分离方案

```ini
# .env.development
# ==================== 开发环境配置 ====================
APP_ENV=development

# PostgreSQL (开发环境直连 PG 容器端口)
DB_HOST=postgres
DB_PORT=5432
DB_NAME=app_db
DB_USER=app_owner
PGRST_DB_URI=postgres://authenticator:***@postgres:5432/app_db?sslmode=disable

# APISIX
APISIX_HOST=apisix
APISIX_PORT=9080
APISIX_ADMIN=http://apisix:9180

# Casdoor
CASDOOR_HOST=casdoor
CASDOOR_PORT=8000
CASDOOR_CLIENT_ID=dev_zero_backend
CASDOOR_REDIRECT_URI=http://localhost:9080/callback

# etcd (单节点共享)
ETCD_HOST=etcd
ETCD_PORT=2379

# Redis
REDIS_HOST=redis
REDIS_PORT=6379

# 开发环境简化配置
DEBUG=true
LOG_LEVEL=debug
ENABLE_MONITORING=false
```

```ini
# .env.production
# ==================== 生产环境配置 ====================
APP_ENV=production

# PostgreSQL (生产环境通过 Pgbouncer 连接)
DB_HOST=10.10.10.11      # Pgbouncer 地址
DB_PORT=5433             # Pgbouncer 写端口
DB_NAME=app_db
DB_USER=app_owner
PGRST_DB_URI=postgres://authenticator:***@10.10.10.11:5433/app_db?sslmode=verify-full&sslcert=/path/to/client.crt

# APISIX (HA 节点列表)
APISIX_HOST=10.10.10.20
APISIX_PORT=443          # HTTPS
APISIX_ADMIN=https://10.10.10.20:9180

# Casdoor
CASDOOR_HOST=casdoor.internal
CASDOOR_PORT=8000
CASDOOR_CLIENT_ID=prod_zero_backend
CASDOOR_REDIRECT_URI=https://admin.yourdomain.com/callback

# etcd (Pigsty 集群)
ETCD_HOSTS=http://10.10.10.11:2379,http://10.10.10.12:2379,http://10.10.10.13:2379
ETCD_PREFIX=/apisix

# Redis (Pigsty 托管)
REDIS_HOST=10.10.10.11
REDIS_PORT=6379

# 生产严格配置
DEBUG=false
LOG_LEVEL=warn
ENABLE_MONITORING=true
ENABLE_PBACKREST=true
SSL_MODE=verify-full
```

### 7.3 PostgREST 多环境配置文件

```properties
# postgrest.dev.conf
server-host = "0.0.0.0"
server-port = 3000
db-uri = "postgresql://authenticator:pass@postgres:5432/app_db?sslmode=disable"
db-schemas = "api_v1, public"
db-anon-role = "web_anon"
jwt-secret = "dev_jwt_secret_at_least_32_chars_long_change_me"
db-pre-request = "check_token_blacklist"
openapi-server-proxy-uri = "http://localhost:3000"
db-extra-search-path = "public"
# 开发环境宽松配置
jwt-cache-ttl = 2               # 秒，开发环境快速刷新
db-pool = 10
db-pool-timeout = 10
```

```properties
# postgrest.prod.conf
server-host = "0.0.0.0"
server-port = 3000
db-uri = "postgresql://authenticator:***@pgbouncer.node1:5433/app_db?sslmode=verify-full&sslrootcert=/path/to/ca.crt&sslcert=/path/to/client.crt&sslkey=/path/to/client.key"
db-schemas = "api_v1"
db-anon-role = "web_anon"
# JWKS 验证（生产使用 Casdoor 公钥）
jwt-secret = "{\"keys\": [{\"kty\":\"RSA\",\"kid\":\"casdoor-key-1\",\"use\":\"sig\",\"alg\":\"RS256\",\"n\":\"...\",\"e\":\"AQAB\"}]}"
jwt-cache-ttl = 300              # JWKS 缓存 5 分钟
db-pre-request = "check_token_blacklist"
db-extra-search-path = "public"
# 生产连接池优化
db-pool = 50
db-pool-timeout = 30
db-pool-release-connection = true
pre-request = "api_v1.set_search_path"
max-rows = 1000
```

### 7.4 Policy Syncer 多环境配置（Go）

```go
// config.go
type Config struct {
    Environment string // "development" | "production"
    PostgresDSN string
    ApisixURL   string
    ApisixKey   string
}

func LoadConfig() Config {
    env := os.Getenv("APP_ENV")
    if env == "production" {
        return Config{
            Environment: "production",
            PostgresDSN: "postgres://app_owner:***@pgbouncer:5433/app_db?sslmode=verify-full",
            ApisixURL:   "https://apisix.internal:9180/apisix/admin/plugin_metadata/authz-casbin",
            ApisixKey:   os.Getenv("APISIX_ADMIN_KEY"),
        }
    }
    return Config{
        Environment: "development",
        PostgresDSN: "postgres://app_owner:***@postgres:5432/app_db?sslmode=disable",
        ApisixURL:   "http://apisix:9180/apisix/admin/plugin_metadata/authz-casbin",
        ApisixKey:   "edd1c9f034335f136f87ad84b625c8f1",
    }
}
```

### 7.5 文档组织建议

```
文档位置: 01-环境搭建-基础设施部署与验收.md

## 新增章节结构:

### X. 双环境配置管理

#### X.1 环境定义
- 开发环境（本文档主体）：Docker Compose + Pgbouncer 容器
- 生产环境（Pigsty Ansible）：参考独立的生产环境手册

#### X.2 配置差异对照表
（上面 7.1 表放这里）

#### X.3 环境变量文件
- .env.development → 开发环境（仓库提交模板）
- .env.production  → 生产环境（仅在部署服务器上存在，git 不提交）
- 验证命令：`echo $APP_ENV && cat .env.$APP_ENV`

#### X.4 运行时的环境检测
# Docker Compose 启动前检查
if [ "$APP_ENV" = "production" ]; then
    echo "生产环境请通过 Pigsty Ansible 部署，不要使用 docker-compose"
    exit 1
fi
```

---

## 附录 A：精简后 Docker Compose 完整文件

```yaml
version: '3.8'

# ==============================================================================
# 网络定义
# ==============================================================================
networks:
  app-net:
    driver: bridge
    ipam:
      config:
        - subnet: 172.20.0.0/16

# ==============================================================================
# 数据卷定义
# ==============================================================================
volumes:
  pg_data:
  etcd_data:
  casdoor_data:

# ==============================================================================
# 服务定义（精简后仅保留 4 个无法由 Pigsty 原生管理的无状态服务）
# ==============================================================================
services:

  # ==========================================================================
  # 1. PostgreSQL + pgTAP（开发环境）
  # ==========================================================================
  # 注意：此容器仅用于开发环境功能验证
  # 生产环境使用 Pigsty 部署 PostgreSQL + Patroni HA + Pgbouncer
  # ==========================================================================
  postgres:
    image: pgcharles/pgtap:18
    container_name: app-postgres
    restart: unless-stopped
    environment:
      POSTGRES_DB: app_db
      POSTGRES_USER: app_owner
      POSTGRES_PASSWORD: ${DB_PASSWORD:-dev_password_change_me}
    ports:
      - "5432:5432"
    volumes:
      - pg_data:/var/lib/postgresql/data
      - ./db/init:/docker-entrypoint-initdb.d
    networks:
      - app-net
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U app_owner -d app_db"]
      interval: 10s
      timeout: 5s
      retries: 5
    command: >
      -c shared_preload_libraries='pgaudit,pg_cron,pgsodium,pg_net,pg_graphql'
      -c cron.database_name='app_db'
      -c pg_net.database_name='app_db'

  # ==========================================================================
  # 2. etcd (APISIX 配置存储)
  # ==========================================================================
  # 开发环境单节点，生产环境使用 Pigsty etcd ×3
  # Pigsty 的 etcd 和 APISIX 的 etcd 共用同一集群，/service/ 和 /apisix/ 前缀
  # ==========================================================================
  etcd:
    image: bitnami/etcd:3.6
    container_name: app-etcd
    restart: unless-stopped
    environment:
      ETCD_NAME: etcd-dev-node
      ALLOW_NONE_AUTHENTICATION: "yes"
      ETCD_ADVERTISE_CLIENT_URLS: http://0.0.0.0:2379
      ETCD_LISTEN_CLIENT_URLS: http://0.0.0.0:2379
      ETCD_DATA_DIR: /bitnami/etcd/data
    ports:
      - "2379:2379"
    volumes:
      - etcd_data:/bitnami/etcd/data
    networks:
      - app-net
    healthcheck:
      test: ["CMD", "etcdctl", "endpoint", "health"]
      interval: 10s
      timeout: 5s
      retries: 5

  # ==========================================================================
  # 3. PostgreSQL 连接池（开发环境补充）
  # ==========================================================================
  # 生产环境此路由由 Pigsty Pdbouncer 替代（Port 5433/5434）
  # ==========================================================================
  pgbouncer:
    image: pgbouncer/pgbouncer:1.24
    container_name: app-pgbouncer
    restart: unless-stopped
    ports:
      - "5433:6432"
    volumes:
      - ./pgbouncer/pgbouncer.ini:/etc/pgbouncer/pgbouncer.ini:ro
      - ./pgbouncer/userlist.txt:/etc/pgbouncer/userlist.txt:ro
    networks:
      - app-net
    depends_on:
      postgres:
        condition: service_healthy

  # ==========================================================================
  # 4. APISIX API 网关
  # ==========================================================================
  apisix:
    image: apache/apisix:3.17.0-debian
    container_name: app-apisix
    restart: unless-stopped
    environment:
      APISIX_STAND_ALONE: "false"
    ports:
      - "9080:9080"
      - "9443:9443"
      - "9180:9180"
    volumes:
      - ./apisix/config.yaml:/usr/local/apisix/conf/config.yaml:ro
      - ./apisix/apisix.yaml:/usr/local/apisix/conf/apisix.yaml:ro
    networks:
      - app-net
    depends_on:
      etcd:
        condition: service_healthy
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:9080/apisix/status"]
      interval: 10s
      timeout: 5s
      retries: 5

  # ==========================================================================
  # 5. PostgREST API 自动生成引擎
  # ==========================================================================
  postgrest:
    image: postgrest/postgrest:v14.14
    container_name: app-postgrest
    restart: unless-stopped
    environment:
      PGRST_DB_URI: postgres://authenticator:***@pgbouncer:6432/app_db?sslmode=disable
      PGRST_DB_SCHEMAS: api_v1
      PGRST_DB_ANON_ROLE: web_anon
      PGRST_JWT_SECRET: ${JWT_SECRET}
      PGRST_DB_PRE_REQUEST: api_v1.check_token_blacklist
      PGRST_OPENAPI_SERVER_PROXY_URI: http://localhost:3000
      PGRST_SERVER_HOST: 0.0.0.0
      PGRST_SERVER_PORT: "3000"
    ports:
      - "3000:3000"
    networks:
      - app-net
    depends_on:
      pgbouncer:
        condition: service_started

  # ==========================================================================
  # 6. Casdoor IAM/OAuth 服务（新增）
  # ==========================================================================
  casdoor:
    image: casbin/casdoor:latest
    container_name: app-casdoor
    restart: unless-stopped
    ports:
      - "8000:8000"
    environment:
      driverName: mysql
      dataSourceName: "root:${MYSQL_ROOT_PASSWORD}@tcp(mysql:3306)/"
      runMode: dev
      httpPort: 8000
    volumes:
      - casdoor_data:/app/conf
    networks:
      - app-net
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:8000/api/health"]
      interval: 10s
      timeout: 5s
      retries: 5

  # ==========================================================================
  # 7. MySQL for Casdoor (Casdoor 需要独立 MySQL，不用 PG)
  # ==========================================================================
  mysql:
    image: mysql:8.0
    container_name: app-mysql
    restart: unless-stopped
    environment:
      MYSQL_ROOT_PASSWORD: ${MYSQL_ROOT_PASSWORD:-root_dev_pass}
      MYSQL_DATABASE: casdoor
    ports:
      - "3306:3306"
    volumes:
      - mysql_data:/var/lib/mysql
    networks:
      - app-net
    healthcheck:
      test: ["CMD", "mysqladmin", "ping", "-h", "localhost"]
      interval: 10s
      timeout: 5s
      retries: 5

  # ==========================================================================
  # 8. Swagger UI API 文档
  # ==========================================================================
  swagger-ui:
    image: swaggerapi/swagger-ui:v5.18.2
    container_name: app-swagger
    restart: unless-stopped
    environment:
      API_URL: http://localhost:3000/
    ports:
      - "8080:8080"
    networks:
      - app-net
    depends_on:
      postgrest:
        condition: service_started
```

---

## 附录 B：关键命令速查

### B.1 Docker Compose 开发环境操作

```bash
# 启动所有服务
docker compose up -d

# 查看所有服务状态
docker compose ps --format "table {{.Name}}\t{{.Status}}\t{{.Ports}}"

# 查看特定服务日志
docker compose logs -f --tail 100 apisix

# 重建单个服务（配置变更后）
docker compose up -d --build pgbouncer

# 进入 PG 容器
docker exec -it app-postgres psql -U app_owner -d app_db

# 进入 Pgbouncer 管理
docker exec -it app-pgbouncer psql -h localhost -p 6432 -U pgadmin pgbouncer
```

### B.2 Casdoor 初始化配置

```bash
# 1. 启动 Casdoor
docker compose up -d casdoor mysql

# 2. 等待健康检查通过
docker compose ps casdoor | grep healthy

# 3. 打开浏览器访问 http://localhost:8000
# 默认用户名: admin  默认密码: 123

# 4. 应用配置示例（通过 API 创建）
curl -X POST http://localhost:8000/api/update-application \
  -H "Content-Type: application/json" \
  -d '{"organization":"built-in","applicationName":"zero-backend-app",...}'
```

### B.3 pg_graphql 安装验证

```bash
# 连接到 PG
docker exec -it app-postgres psql -U app_owner -d app_db

# 安装扩展
CREATE EXTENSION pg_graphql;

-- 验证
SELECT * FROM graphql.field WHERE parent_type = 'Query' LIMIT 10;

-- 测试 GraphQL 查询
SELECT graphql.resolve('{
  sysUserCollection {
    edges { node { id username } }
  }
}');
```

### B.4 APISIX + Casdoor 集成验证

```bash
# 1. 未认证请求 → 重定向到 Casdoor
curl -v http://localhost:9080/api/v1/sys_user
# 预期: 302 → http://localhost:8000/login/oauth/authorize?...

# 2. 获取 Token（模拟 Casdoor 登录后）
curl -X POST http://localhost:8000/api/login/oauth/access_token \
  -d "client_id=YOUR_CLIENT_ID&client_secret=YOUR_SECRET&grant_type=password&username=admin&password=123"
# 预期: {"access_token":"eyJ...","token_type":"Bearer",...}

# 3. 带 Token 访问 API
TOKEN="eyJ..."
curl -H "Authorization: Bearer $TOKEN" http://localhost:9080/api/v1/sys_user
# 预期: 200 + JSON 用户列表
```

---

## 总结

### ✅ 核心结论

1. **Pigsty Docker 模块可完全替代 80% 的 Docker Compose 容器**，仅保留 APISIX、PostgREST、Casdoor、Swagger UI 四个无状态服务
2. **VictoriaMetrics 是 Pigsty 默认的 Prometheus 兼容存储**，两者共存但 VictoriaMetrics 承担主要角色
3. **Pgbouncer 应纳入开发环境**（Docker Compose 补充 pgbouncer 容器）以对齐生产行为
4. **etcd 单集群共用**：`/service/` (Patroni) 和 `/apisix/` (APISIX) 前缀隔离，减少运维复杂度
5. **Casdoor 需独立 MySQL**，不强制要求 PostgreSQL，通过 authz-casdoor 插件与 APISIX 集成
6. **pg_graphql 零成本安装**：Pigsty v4.3.0 内可直接 `CREATE EXTENSION`，无需额外服务
7. **开发/生产环境差异**应通过环境变量 + 双 `.env` 文件管理，文档中明确标注差异项

### ⚠️ 需关注的已知限制

- Pigsty 不原生支持 Windows Docker Desktop → 开发环境需 WSL2 或 Docker Compose 简化版
- Casdoor 需要 MySQL → 增加一个容器，无法由 Pigsty 统一管理
- pg_graphql 在 PG 18 上的兼容性需运行时验证
- APISIX `authz-casdoor` 插件在不同 APISIX 版本的 API 可能有差异
