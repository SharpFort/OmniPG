# 本地开发测试环境 — Docker 镜像与组件配置清单（v3）

> **适用项目：** 零后端代码统一权限管理系统
> **目标：** 在本地 Windows (WSL2 + Docker Desktop) 部署完整前后端测试环境，基于 Pigsty 统一管理基础设施
> **更新日期：** 2026-07-20（v3：全面采用 Pigsty 部署 PGSQL/INFRA/REDIS/DOCKER 模块）

---

## 一、部署架构总览

```
┌─────────────────────────────────────────────────────────────────────┐
│                        Windows 主机                                 │
│                                                                     │
│  ┌──────────────────────────────────────────────────────────────┐  │
│  │  WSL2 (Ubuntu 26.04) — Pigsty 基础设施层                     │  │
│  │                                                               │  │
│  │  ┌─────────────────────────────────────────────────────────┐ │  │
│  │  │  ① Pigsty INFRA 模块                                    │ │  │
│  │  │  ├─ Nginx          (:80/:443)     Web 入口/反向代理    │ │  │
│  │  │  ├─ Grafana        (:3000)        可视化仪表盘          │ │  │
│  │  │  ├─ VictoriaMetrics (:8428)       指标存储（替代Prom）  │ │  │
│  │  │  ├─ VictoriaLogs   (:9428)        日志存储（替代Loki）  │ │  │
│  │  │  ├─ VictoriaTraces (:10428)       链路追踪              │ │  │
│  │  │  ├─ DNSMASQ        (:53)          DNS 解析              │ │  │
│  │  │  ├─ Chronyd        (:123)         NTP 时间同步          │ │  │
│  │  │  └─ etcd           (:2379)         服务发现/配置存储     │ │  │
│  │  └─────────────────────────────────────────────────────────┘ │  │
│  │                                                               │  │
│  │  ┌─────────────────────────────────────────────────────────┐ │  │
│  │  │  ② Pigsty PGSQL 模块                                    │ │  │
│  │  │  ├─ PostgreSQL 18     (:5432)    核心数据库引擎         │ │  │
│  │  │  ├─ pgBouncer         (:6432)    连接池                 │ │  │
│  │  │  ├─ pgAdmin           (:5050)    Web 管理工具           │ │  │
│  │  │  ├─ Patroni           (:8008)    高可用管理（可选）      │ │  │
│  │  │  ├─ pgBackRest        (:8081)    备份恢复管理           │ │  │
│  │  │  └─ 扩展: pgcrypto, pgsodium, pg_net, pgaudit,          │ │  │
│  │  │           pgtap, pg_graphql, pg_cron, plpython3u         │ │  │
│  │  │  数据库: app_db, casdoor                                 │ │  │
│  │  │  角色: app_owner, authenticator, casdoor, web_anon       │ │  │
│  │  └─────────────────────────────────────────────────────────┘ │  │
│  │                                                               │  │
│  │  ┌─────────────────────────────────────────────────────────┐ │  │
│  │  │  ③ Pigsty REDIS 模块                                    │ │  │
│  │  │  ├─ Redis Standalone  (:6379)    内存缓存/APISIX 限流   │ │  │
│  │  │  └─ Redis Exporter    (:9121)     Prometheus 指标导出   │ │  │
│  │  └─────────────────────────────────────────────────────────┘ │  │
│  │                                                               │  │
│  │  ┌─────────────────────────────────────────────────────────┐ │  │
│  │  │  ④ Pigsty DOCKER 模块                                   │ │  │
│  │  │  ├─ Docker Engine               容器运行时              │ │  │
│  │  │  └─ Docker Compose              编排工具                 │ │  │
│  │  └─────────────────────────────────────────────────────────┘ │  │
│  │                                                               │  │
│  │  ┌─────────────────────────────────────────────────────────┐ │  │
│  │  │  Docker Compose (WSL2 内，由 Pigsty DOCKER 模块提供)     │ │  │
│  │  │  ┌─────────┐ ┌─────────┐ ┌─────────┐                   │ │  │
│  │  │  │ APISIX  │ │PostgREST│ │ Casdoor │                   │ │  │
│  │  │  │ v3.17.0 │ │ v14.15  │ │ v3.108  │                   │ │  │
│  │  │  │ :9080   │ │ :3000   │ │ :8000   │                   │ │  │
│  │  │  └─────────┘ └─────────┘ └─────────┘                   │ │  │
│  │  │  ┌─────────┐ ┌─────────────────────────────────────┐   │ │  │
│  │  │  │Swagger  │ │  Policy Syncer (Go)                 │   │ │  │
│  │  │  │UI :8080 │ │  :8081 (healthz)                    │   │ │  │
│  │  │  └─────────┘ └─────────────────────────────────────┘   │ │  │
│  │  └─────────────────────────────────────────────────────────┘ │  │
│  └──────────────────────────────────────────────────────────────┘  │
│                                                                     │
│  ┌──────────────────────────────────────────────────────────────┐  │
│  │  Windows 主机 — 前端开发层                                    │  │
│  │  ┌────────────────────────────────────────────────────────┐  │  │
│  │  │  Vite Dev Server (Node.js)                              │  │  │
│  │  │  ├─ 端口: 5173                                          │  │  │
│  │  │  ├─ 代理: /api/v1/* → http://localhost:9080 (APISIX)    │  │  │
│  │  │  └─ 代码: frontend/admin-ui/                            │  │  │
│  │  └────────────────────────────────────────────────────────┘  │  │
│  └──────────────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────────────┘
```

---

## 二、为何采用 Pigsty 统一管理？

| 对比项 | 手动安装（旧方案） | Pigsty 统一管理（推荐） |
|:---|:---|:---|
| **安装复杂度** | 手动配置 apt 源、编译扩展、配置服务 | 一条命令完成所有模块安装 |
| **版本管理** | 各组件版本分散，兼容性难保证 | Pigsty 统一测试，版本兼容有保障 |
| **监控集成** | 需手动配置 Prometheus/Grafana | 内置 VictoriaMetrics + VictoriaLogs + Grafana |
| **扩展安装** | 手动下载编译 PostgreSQL 扩展 | 531 个预编译扩展，一键启用 |
| **备份恢复** | 自行配置 pg_dump/pgBackRest | 内置 pgBackRest，声明式配置 |
| **高可用** | 自行搭建 Patroni/etcd | 内置 Patroni + etcd 高可用方案 |
| **Redis** | 单独维护 Docker 容器 | 原生部署，与 PG 共享基础设施 |
| **Docker** | 需单独安装配置 | DOCKER 模块统一管理 |

**结论：** Pigsty 是企业级 PostgreSQL 发行版，提供开箱即用的完整基础设施栈。本地开发环境中，使用 Pigsty 统一管理 PGSQL/INFRA/REDIS/DOCKER 模块，可以大幅简化环境搭建和维护成本。

---

## 三、Pigsty 部署（Ubuntu 26.04 WSL2 原生）

### 3.1 系统要求

| 项目 | 要求 |
|:---|:---|
| **操作系统** | Ubuntu 26.04 (WSL2) |
| **CPU** | 至少 2 核 |
| **内存** | 至少 4GB |
| **磁盘** | 至少 30GB 可用空间 |
| **网络** | 能访问互联网（下载 Pigsty 及依赖） |

### 3.2 安装 Pigsty

```bash
# 在 WSL2 Ubuntu 26.04 中执行
# 下载并安装 Pigsty v4.4.0（最新稳定版）
curl -fsSL https://pigsty.cc/get | bash -s v4.4.0

# 进入 Pigsty 目录
cd ~/pigsty

# 生成默认配置（会自动检测系统信息）
./configure
```

### 3.3 配置要启用的模块

编辑 `pigsty.yml`，启用以下模块：

```yaml
# pigsty.yml — 本地开发环境配置
all:
  vars:
    pg_version: 18                    # PostgreSQL 18
    pg_packages:
      - postgresql-18
      - postgresql-18-pgtap
      - postgresql-18-plpython3
      - postgresql-contrib
      - postgresql-18-pgaudit
      - postgresql-18-pgsodium
    
    # 启用 PostgreSQL 扩展
    pg_extensions:
      - pgcrypto
      - pgsodium
      - pg_net
      - pgaudit
      - pgtap
      - pg_graphql
      - pg_cron
      - plpython3u

  children:
    # ============ INFRA 模块 ============
    infra:
      hosts:
        127.0.0.1: { infra_seq: 1 }
      vars:
        # 启用 INFRA 组件
        nginx_enabled: true
        grafana_enabled: true
        victoriametrics_enabled: true
        victorialogs_enabled: true
        victoriatraces_enabled: true
        dnsmasq_enabled: true
        chrony_enabled: true
        etcd_enabled: true

    # ============ PGSQL 模块 ============
    pgsql:
      hosts:
        127.0.0.1: { pg_seq: 1, pg_role: primary }
      vars:
        pg_cluster: pg-omnipg
        pg_databases:
          - name: app_db
            owner: app_owner
            extensions:
              - { name: pgcrypto }
              - { name: pgsodium }
              - { name: pg_net }
              - { name: pgaudit }
              - { name: pgtap }
              - { name: pg_graphql }
              - { name: pg_cron }
              - { name: plpython3u }
          - name: casdoor
            owner: casdoor
        pg_users:
          - name: app_owner
            password: dev_password_change_me
            privileges: CREATEDB
          - name: authenticator
            password: authenticator_dev_pass
          - name: casdoor
            password: casdoor_dev_pass
          - name: web_anon
            password: anon_dev_pass
        pg_hba_rules:
          - type: host
            database: all
            user: all
            address: 127.0.0.1/32
            method: scram-sha-256
          - type: host
            database: all
            user: all
            address: ::1/128
            method: scram-sha-256
          - type: host
            database: all
            user: all
            address: 172.17.0.0/16
            method: scram-sha-256  # Docker 容器访问

    # ============ REDIS 模块 ============
    redis:
      hosts:
        127.0.0.1: { redis_seq: 1 }
      vars:
        redis_cluster: redis-omnipg
        redis_mode: standalone      # 开发环境用 standalone
        redis_exporter_enabled: true

    # ============ DOCKER 模块 ============
    docker:
      hosts:
        127.0.0.1: { docker_seq: 1 }
```

### 3.4 执行安装

```bash
# 安装所有启用的模块
./install.yml
```

安装完成后，Pigsty 会自动完成：
- ✅ INFRA：Nginx + Grafana + VictoriaMetrics + VictoriaLogs + DNSMASQ + Chrony + etcd
- ✅ PGSQL：PostgreSQL 18 + pgBouncer + pgAdmin + 所有扩展 + 数据库和角色
- ✅ REDIS：Redis Standalone + Exporter
- ✅ DOCKER：Docker Engine + Docker Compose

### 3.5 验证 Pigsty 安装

```bash
# 查看 Pigsty 状态
make status

# 验证 PostgreSQL
psql -h localhost -U app_owner -d app_db -c "SELECT version();"

# 验证 Redis
redis-cli -h localhost -p 6379 ping

# 验证 Docker
docker --version
docker compose version

# 验证 etcd
etcdctl endpoint health

# 验证 Grafana（浏览器访问）
# http://localhost:3000/  (admin/grafana_admin_password)
```

---

## 四、Docker Compose 配置（WSL2 内，由 Pigsty DOCKER 模块管理）

> ⚠️ 以下服务运行在 Docker 中，由 Pigsty 的 DOCKER 模块提供容器运行时。
> **注意：** PostgreSQL 和 Redis 已由 Pigsty 原生部署，不再通过 Docker 运行。

```yaml
# docker-compose.yml (WSL2 内执行)
version: '3.8'

networks:
  app-net:
    driver: bridge

volumes:
  casdoor_data:
  syncer_build:

services:
  # 1. APISIX (API 网关)
  apisix:
    image: apache/apisix:3.17.0-debian
    container_name: app-apisix
    restart: unless-stopped
    environment:
      APISIX_STAND_ALONE: "false"
    ports:
      - "9080:9080"
      - "9180:9180"
      - "9443:9443"
    volumes:
      - ./apisix/config.yaml:/usr/local/apisix/conf/config.yaml:ro
      - ./apisix/apisix.yaml:/usr/local/apisix/conf/apisix.yaml:ro
    extra_hosts:
      - "host.docker.internal:host-gateway"
    networks:
      - app-net
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:9080/apisix/status"]
      interval: 10s
      timeout: 5s
      retries: 5

  # 2. PostgREST (REST API 生成)
  postgrest:
    image: postgrest/postgrest:v14.15
    container_name: app-postgrest
    restart: unless-stopped
    environment:
      PGRST_DB_URI: postgres://authenticator:authenticator_dev_pass@host.docker.internal:5432/app_db?sslmode=disable
      PGRST_DB_SCHEMAS: "api_v1"
      PGRST_DB_ANON_ROLE: web_anon
      PGRST_DB_EXTRA_SEARCH_PATH: "public"
      PGRST_JWT_SECRET: ${JWKS_JSON:-***}
      PGRST_DB_PRE_REQUEST: "api_v1.check_token_blacklist"
      PGRST_OPENAPI_SERVER_PROXY_URI: "http://localhost:3000"
      PGRST_SERVER_PORT: "3000"
      PGRST_DB_AGGREGATES_ENABLED: "true"
      PGRST_MAX_ROWS: "1000"
      PGRST_PRE_ERROR_EXTENDED: "true"
      PGRST_DB_TX_END: "commit"
    ports:
      - "3000:3000"
    extra_hosts:
      - "host.docker.internal:host-gateway"
    networks:
      - app-net
    healthcheck:
      test: ["CMD", "curl", "-f", "-s", "http://localhost:3000/"]
      interval: 15s
      timeout: 10s
      retries: 5

  # 3. Casdoor (OAuth/IAM)
  casdoor:
    image: casbin/casdoor:latest
    container_name: app-casdoor
    restart: unless-stopped
    ports:
      - "8000:8000"
    environment:
      driverName: postgres
      dataSourceName: "user=casdoor password=casdoor_dev_pass host=host.docker.internal port=5432 sslmode=disable dbname=casdoor"
      runMode: dev
    volumes:
      - casdoor_data:/app/conf
    extra_hosts:
      - "host.docker.internal:host-gateway"
    networks:
      - app-net
    healthcheck:
      test: ["CMD", "curl", "-f", "-s", "http://localhost:8000/api/health"]
      interval: 15s
      timeout: 10s
      retries: 10

  # 4. Swagger UI (API 文档)
  # ⚠️ 注意：PostgREST v14 自带 OpenAPI 支持，根路径 / 返回 OpenAPI JSON
  # Swagger UI 仅用于可视化展示，API_URL 指向 PostgREST 容器
  swagger-ui:
    image: swaggerapi/swagger-ui:v5.2.0
    container_name: app-swagger
    restart: unless-stopped
    environment:
      API_URL: "http://postgrest:3000/"
    ports:
      - "8080:8080"
    networks:
      - app-net
    depends_on:
      postgrest:
        condition: service_healthy

  # 5. Policy Syncer (策略同步器)
  # ⚠️ 端口从 8080 改为 8081，避免与 Swagger UI 冲突
  syncer:
    build:
      context: ./syncer
      dockerfile: Dockerfile
    container_name: policy-syncer
    restart: unless-stopped
    environment:
      DB_HOST: host.docker.internal
      DB_PORT: "5432"
      DB_USER: app_owner
      DB_PASSWORD: dev_password_change_me
      SSL_MODE: disable
      APISIX_ADMIN_URL: http://apisix:9180/apisix/admin/plugin_metadata/authz-casbin
      APISIX_ADMIN_KEY: edd1c9f034335f136f87ad84b625c8f1
    ports:
      - "8081:8081"
    extra_hosts:
      - "host.docker.internal:host-gateway"
    networks:
      - app-net
    depends_on:
      apisix:
        condition: service_healthy
    healthcheck:
      test: ["CMD", "wget", "--no-verbose", "--tries=1", "--spider", "http://localhost:8081/healthz"]
      interval: 30s
      timeout: 5s
      retries: 3
```

---

## 五、前端与后端的通信

### 5.1 通信链路

```
浏览器 (Windows)
    │
    ├─ http://localhost:5173  ← Vite Dev Server (Windows 本地)
    │
    ├─ /api/v1/* 请求
    │       │
    │       ▼
    │   Vite Proxy 转发
    │       │
    │       ▼
    │   http://localhost:9080  ← APISIX (Docker，端口映射到 Windows)
    │       │
    │       ├─ JWT 验证 (jwt-auth 插件)
    │       ├─ Casbin 鉴权 (authz-casbin 插件)
    │       └─ 转发到 PostgREST
    │               │
    │               ▼
    │           http://localhost:3000  ← PostgREST (Docker)
    │               │
    │               └─ SQL 查询
    │                       │
    │                       ▼
    │                   PostgreSQL (Pigsty 原生，端口 5432)
    │
    └─ http://localhost:8000  ← Casdoor (Docker，OAuth 登录)
```

### 5.2 Vite 代理配置

```typescript
// frontend/admin-ui/vite.config.ts
import { defineConfig } from 'vite'
import vue from '@vitejs/plugin-vue'

export default defineConfig({
  plugins: [vue()],
  server: {
    host: '0.0.0.0',
    port: 5173,
    proxy: {
      '/api/v1': {
        target: 'http://localhost:9080',  // APISIX 网关
        changeOrigin: true,
      },
      '/casdoor': {
        target: 'http://localhost:8000',  // Casdoor
        changeOrigin: true,
      },
    },
  },
})
```

### 5.3 为何前端和后端能互相访问？

| 服务 | 地址 | 说明 |
|:---|:---|:---|
| Vite Dev Server | `localhost:5173` (Windows) | 前端开发服务器 |
| APISIX | `localhost:9080` (WSL2 → Windows) | Docker 端口映射 |
| PostgREST | `localhost:3000` (WSL2 → Windows) | Docker 端口映射 |
| PostgreSQL | `localhost:5432` (Pigsty 原生) | WSL2 原生，自动监听 |
| Redis | `localhost:6379` (Pigsty 原生) | WSL2 原生 |
| Casdoor | `localhost:8000` (WSL2 → Windows) | Docker 端口映射 |
| Swagger UI | `localhost:8080` (WSL2 → Windows) | Docker 端口映射 |

**关键点：**
- WSL2 中的服务通过端口映射暴露给 Windows 的 `localhost`
- Docker 容器使用 `host.docker.internal` 访问 WSL2 原生服务（如 PostgreSQL、Redis）
- 前端代码中所有请求都走 `/api/v1` 前缀，由 Vite Proxy 转发到 APISIX
- PostgreSQL 已配置允许 Docker 网段（172.17.0.0/16）访问

---

## 六、PostgREST + OpenAPI/Swagger 配置说明

### 6.1 PostgREST 内置 OpenAPI 支持

PostgREST v14 **原生支持 OpenAPI 规范**，根路径 `/` 会自动返回当前数据库 Schema 对应的 OpenAPI JSON 文档。无需额外配置：

```bash
# 获取 OpenAPI JSON
curl http://localhost:3000/

# 输出示例（OpenAPI 3.0 格式）
{
  "openapi": "3.0.0",
  "info": {
    "title": "PostgREST API",
    "version": "14.15"
  },
  "paths": {
    "/": { "get": { "summary": "OpenAPI description" } },
    "/api_v1/users": { "get": {...}, "post": {...} },
    ...
  }
}
```

### 6.2 Swagger UI 配置说明

Swagger UI 仅用于**可视化展示** PostgREST 的 OpenAPI JSON。

**正确配置：**
```yaml
swagger-ui:
  image: swaggerapi/swagger-ui:v5.2.0
  environment:
    # ✅ 正确：指向 Docker 网络内的 PostgREST 容器
    API_URL: "http://postgrest:3000/"
```

**常见错误：**
```yaml
# ❌ 错误：指向 localhost（Swagger 容器自身没有 3000 端口）
API_URL: "http://localhost:3000/"

# ❌ 错误：指向 Windows localhost（Swagger 容器无法访问宿主机网络）
API_URL: "http://host.docker.internal:3000/"
```

### 6.3 访问方式

| 访问地址 | 说明 |
|:---|:---|
| `http://localhost:3000/` | PostgREST 原生 OpenAPI JSON |
| `http://localhost:8080/` | Swagger UI 可视化界面 |

---

## 七、Policy Syncer — 功能回顾

### 7.1 作用

Policy Syncer 是一个 **Go 编写的 Sidecar 服务**，负责将数据库中的 Casbin 策略**实时同步**到 APISIX 网关。

### 7.2 核心流程

```
┌─────────────────────────────────────────────────────────┐
│                    Policy Syncer 架构                     │
├─────────────────────────────────────────────────────────┤
│                                                         │
│  ┌──────────┐    pg_notify    ┌──────────────────┐     │
│  │ PostgreSQL │ ─────────────► │  Event Loop      │     │
│  │ casbin_   │                │  - 1s 防抖        │     │
│  │ channel   │                │  - 10min 对账     │     │
│  └──────────┘                │  - 冷启动同步     │     │
│                               └────────┬─────────┘     │
│                                        │               │
│                    ┌───────────────────┼────────┐      │
│                    │                   │        │      │
│              ┌─────▼─────┐      ┌─────▼──┐  ┌──▼────┐ │
│              │ Sync()    │      │Reconci-│  │Advisory│ │
│              │ 全量同步  │      │cile()  │  │Lock   │ │
│              │           │      │SHA256  │  │选主   │ │
│              └─────┬─────┘      │对账    │  └───────┘ │
│                    │            └─────┬──┘             │
│                    │                  │                │
│                    └─────────┬────────┘                │
│                              │                         │
│                    ┌─────────▼─────────┐               │
│                    │ APISIX Admin API  │               │
│                    │ PUT plugin_meta   │               │
│                    └───────────────────┘               │
│                                                         │
└─────────────────────────────────────────────────────────┘
```

### 7.3 详细功能

| 功能 | 说明 |
|:---|:---|
| **实时监听** | 通过 PostgreSQL `LISTEN casbin_channel` 接收 `pg_notify` 事件 |
| **防抖合并** | 1 秒内的多次通知合并为一次同步，避免频繁写入 APISIX |
| **全量同步** | 从 `casbin_rule` 视图读取所有策略，CSV 格式推送到 APISIX Admin API |
| **SHA256 对账** | 每 10 分钟计算 DB 和 APISIX 的策略哈希，不一致时触发全量同步 |
| **Advisory Lock** | 多实例部署时通过 PostgreSQL Advisory Lock 选主，避免并发写入 |
| **冷启动** | 首次启动时执行一次全量同步 |
| **健康检查** | HTTP `/healthz` 端点返回 PG 连接状态 |

### 7.4 相关文档

| 文档 | 内容 |
|:---|:---|
| **06-Policy-Syncer-Go实现.md** | 完整 Go 源码、Dockerfile、运维脚本 |
| **审查文档/06-审查报告.md** | 原始审查报告（P0/P1/P2 问题） |
| **08-Docker-Compose.md** | Syncer 在 docker-compose.yml 中的服务定义 |
| **10-APISIX路由批量配置.md** | Syncer 推送策略的目标（APISIX plugin_metadata） |

---

## 八、部署步骤清单

### 步骤 1：准备 WSL2 环境

```bash
# 确保 WSL2 已安装 Ubuntu 26.04
wsl --list --versions
# 如果未安装，从 Microsoft Store 安装 "Ubuntu 26.04 LTS"

# 启动 WSL2
wsl -d Ubuntu-26.04
```

### 步骤 2：安装 Pigsty 并部署所有模块

```bash
# 下载 Pigsty
curl -fsSL https://pigsty.cc/get | bash -s v4.4.0

cd ~/pigsty

# 编辑配置文件，启用 INFRA/PGSQL/REDIS/DOCKER 模块
# （参考第三节的 pigsty.yml 示例）
vim pigsty.yml

# 生成配置
./configure

# 安装所有模块
./install.yml
```

### 步骤 3：初始化数据库

```bash
# 执行 Dbmate migration
cd /d/WeChat\ Files/xiangmu/源码/db
dbmate up

# 验证迁移结果
psql -h localhost -U app_owner -d app_db -c "\dt"
```

### 步骤 4：启动 Docker Compose（不含 PG/Redis）

```bash
cd /d/WeChat\ Files/xiangmu/源码
docker compose up -d
```

### 步骤 5：验证服务

```bash
# PostgreSQL (Pigsty 原生)
psql -h localhost -U app_owner -d app_db -c "SELECT 1"

# Redis (Pigsty 原生)
redis-cli -h localhost -p 6379 ping

# APISIX
curl http://localhost:9080/apisix/status

# PostgREST
curl http://localhost:3000/

# Swagger UI
curl http://localhost:8080/

# Casdoor
curl http://localhost:8000/api/health

# Policy Syncer
curl http://localhost:8081/healthz

# Grafana (Pigsty INFRA 模块)
curl http://localhost:3000/api/health

# VictoriaMetrics (Pigsty INFRA 模块)
curl http://localhost:8428/health
```

### 步骤 6：启动前端

```bash
cd frontend/admin-ui
npm install
npm run dev
# 浏览器打开 http://localhost:5173
```

---

## 九、组件端口速查表

| 端口 | 组件 | 部署方式 | 说明 |
|:---|:---|:---|:---|
| **5432** | PostgreSQL 18 | Pigsty PGSQL 模块 | 核心数据库 |
| **6432** | pgBouncer | Pigsty PGSQL 模块 | 连接池 |
| **5050** | pgAdmin | Pigsty PGSQL 模块 | Web 管理工具 |
| **6379** | Redis | Pigsty REDIS 模块 | 内存缓存 |
| **9121** | Redis Exporter | Pigsty REDIS 模块 | Prometheus 指标 |
| **80** | Nginx | Pigsty INFRA 模块 | Web 入口 |
| **443** | Nginx | Pigsty INFRA 模块 | HTTPS |
| **3000** | Grafana | Pigsty INFRA 模块 | 可视化仪表盘 |
| **8428** | VictoriaMetrics | Pigsty INFRA 模块 | 指标存储 |
| **9428** | VictoriaLogs | Pigsty INFRA 模块 | 日志存储 |
| **10428** | VictoriaTraces | Pigsty INFRA 模块 | 链路追踪 |
| **2379** | etcd | Pigsty INFRA 模块 | 服务发现 |
| **53** | DNSMASQ | Pigsty INFRA 模块 | DNS 解析 |
| **123** | Chronyd | Pigsty INFRA 模块 | NTP 时间同步 |
| **8080** | Patroni | Pigsty PGSQL 模块 | 高可用管理（可选） |
| **8081** | pgBackRest | Pigsty PGSQL 模块 | 备份恢复 |
| **9080** | APISIX (数据面) | Docker | API 网关 |
| **9180** | APISIX (控制面) | Docker | API 网关管理 |
| **9443** | APISIX (HTTPS) | Docker | API 网关 TLS |
| **3000** | PostgREST | Docker | REST API 生成 |
| **8000** | Casdoor | Docker | OAuth/IAM |
| **8080** | Swagger UI | Docker | API 文档可视化 |
| **8081** | Policy Syncer | Docker | Casbin 策略同步 |
| **5173** | Vite Dev Server | Windows 本地 | 前端开发服务器 |

---

## 十、Pigsty 监控体系

Pigsty 采用 **VictoriaMetrics + VictoriaLogs** 替代 Prometheus + Loki，提供更高效的监控栈：

```bash
# 查看监控状态（Pigsty 自带）
make status

# 访问 Grafana
# http://localhost:3000/
# 默认账号: admin / grafana_admin_password

# 导入 PostgreSQL 仪表盘（Pigsty 自带 40+ 面板）
# 路径: Grafana → Dashboards → PGSQL Overview
```

### Pigsty 提供的监控能力

| 组件 | 端口 | 说明 |
|:---|:---|:---|
| **VictoriaMetrics** | 8428 | 时序数据库，替代 Prometheus，更高压缩率 |
| **VictoriaLogs** | 9428 | 日志存储，替代 Loki，查询更快 |
| **VictoriaTraces** | 10428 | 链路追踪，替代 Jaeger |
| **Grafana** | 3000 | 可视化，统一展示指标/日志/追踪 |
| **Alertmanager** | 9093 | 告警通知 |
| **pg_exporter** | 9630 | PostgreSQL 指标采集 |
| **node_exporter** | 9100 | 系统指标采集 |

### 监控配置（Pigsty 自动完成）

Pigsty 部署时会自动配置：
- PostgreSQL 指标采集（pg_exporter）
- 系统指标采集（node_exporter）
- Redis 指标采集（redis_exporter）
- 预置 Grafana Dashboard（40+ PostgreSQL 相关面板）
- 预置告警规则

---

## 十一、总结

| 组件 | 部署方式 | 理由 |
|:---|:---|:---|
| **PostgreSQL 18** | Pigsty PGSQL 模块 | 原生部署，性能最优，扩展丰富，备份恢复完善 |
| **Redis** | Pigsty REDIS 模块 | 原生部署，与 PG 共享基础设施，监控集成 |
| **INFRA (监控/DNS/NTP/etcd)** | Pigsty INFRA 模块 | 开箱即用，VictoriaMetrics/Logs 高效替代 Prom/Loki |
| **DOCKER** | Pigsty DOCKER 模块 | 统一管理容器运行时 |
| **APISIX/PostgREST/Casdoor** | Docker Compose | 快速启停、环境隔离、版本可控 |
| **Policy Syncer** | Docker Compose | 需要与 APISIX 同网络 |
| **Swagger UI** | Docker Compose | 可视化 PostgREST OpenAPI |
| **前端 (Vite)** | Windows 本地 | 开发体验好、热更新快 |

---

## 参考文档

| 资源 | 链接 |
|:---|:---|
| Pigsty 官方文档 | https://pigsty.cc/docs/ |
| Pigsty Docker 部署 | https://pigsty.cc/docs/setup/docker/ |
| Pigsty Linux 兼容性 | https://pigsty.cc/docs/ref/linux/ |
| Pigsty PGSQL 模块 | https://pigsty.cc/docs/pgsql/ |
| Pigsty DOCKER 模块 | https://pigsty.cc/docs/docker/ |
| PostgREST v14 文档 | https://docs.postgrest.org/en/v14/ |
| PostgREST OpenAPI 参考 | https://docs.postgrest.org/en/v14/references/openapi.html |
| Casbin 访问控制模型 | https://casbin.apache.org/docs/category/access-control-models |
