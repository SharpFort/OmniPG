# 本地开发测试环境 — Docker 镜像与组件配置清单（v2）

> **适用项目：** 零后端代码统一权限管理系统
> **目标：** 在本地 Windows (WSL2 + Docker Desktop) 部署完整前后端测试环境
> **更新日期：** 2026-07-10（v2：PG 改为 WSL2 原生部署）

---

## 一、部署架构总览

```
┌─────────────────────────────────────────────────────────────────────┐
│                        Windows 主机                                 │
│                                                                     │
│  ┌──────────────────────────────────────────────────────────────┐  │
│  │  WSL2 (Ubuntu 22.04) — 后端服务层                            │  │
│  │                                                               │  │
│  │  ┌─────────────────────────────────────────────────────────┐ │  │
│  │  │  PostgreSQL 18 (原生安装，非 Docker)                     │ │  │
│  │  │  ├─ 端口: 5432                                          │ │  │
│  │  │  ├─ 扩展: pgcrypto, pgsodium, pg_net, pgaudit,         │ │  │
│  │  │  │         pgtap, pg_graphql, pg_cron, plpython3u       │ │  │
│  │  │  ├─ 数据库: app_db, casdoor                            │ │  │
│  │  │  └─ 角色: app_owner, authenticator, casdoor, web_anon   │ │  │
│  │  └─────────────────────────────────────────────────────────┘ │  │
│  │                                                               │  │
│  │  ┌─────────────────────────────────────────────────────────┐ │  │
│  │  │  Docker Compose (WSL2 内)                                │ │  │
│  │  │  ┌─────────┐ ┌─────────┐ ┌─────────┐ ┌─────────┐       │ │  │
│  │  │  │ APISIX  │ │PostgREST│ │ Casdoor │ │  Redis  │       │ │  │
│  │  │  │ v3.17.0 │ │ v14.14  │ │ v3.108  │ │  v7.x   │       │ │  │
│  │  │  │ :9080   │ │ :3000   │ │ :8000   │ │ :6379   │       │ │  │
│  │  │  └─────────┘ └─────────┘ └─────────┘ └─────────┘       │ │  │
│  │  │  ┌─────────┐ ┌─────────┐ ┌─────────────────────────┐   │ │  │
│  │  │  │  etcd   │ │ MinIO   │ │  Policy Syncer (Go)     │   │ │  │
│  │  │  │ v3.6    │ │ latest  │ │  :8080 (healthz)        │   │ │  │
│  │  │  │ :2379   │ │ :9000   │ │                         │   │ │  │
│  │  │  └─────────┘ └─────────┘ └─────────────────────────┘   │ │  │
│  │  └─────────────────────────────────────────────────────────┘ │  │
│  │                                                               │  │
│  │  ┌─────────────────────────────────────────────────────────┐ │  │
│  │  │  Pigsty v4.3.0 (可选，用于监控)                          │ │  │
│  │  │  ├─ Prometheus (指标采集)                                │ │  │
│  │  │  ├─ Grafana (可视化)                                     │ │  │
│  │  │  ├─ VictoriaMetrics (长期存储)                           │ │  │
│  │  │  └─ Loki (日志)                                          │ │  │
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

## 二、为何 PostgreSQL 部署在 WSL2 而非 Docker？

| 对比项 | Docker 部署 | WSL2 原生部署（推荐） |
|:---|:---|:---|
| **性能** | 有 Docker 层开销 | 直接访问，无额外开销 |
| **扩展安装** | 需自定义 Dockerfile | `apt install postgresql-18-*` 一条命令 |
| **监控集成** | 需额外配置端口暴露 | Prometheus 可直接连接本地 5432 |
| **数据持久化** | 需要 volume 映射 | 直接存储在 WSL2 文件系统中 |
| **Pigsty 管理** | ❌ Pigsty 无法管理 Docker 内的 PG | ✅ Pigsty 原生管理 |
| **备份恢复** | 需要容器内执行 | 直接 `pg_dump`/`pg_restore` |
| **开发体验** | 容器重启后数据可能丢失 | 服务重启数据保留 |

**结论：** 本地开发环境中，PostgreSQL 直接安装在 WSL2 中更简洁、性能更好、监控集成更方便。

---

## 三、WSL2 原生部署 PostgreSQL 18

### 3.1 安装脚本

```bash
#!/bin/bash
# install-pg18.sh — 在 WSL2 Ubuntu 22.04 中安装 PostgreSQL 18

# 1. 添加 PostgreSQL 官方源
sudo sh -c 'echo "deb http://apt.postgresql.org/pub/repos/apt $(lsb_release -cs)-pgdg main" > /etc/apt/sources.list.d/pgdg.list'
wget --quiet -O - https://www.postgresql.org/media/keys/ACCC4CF8.asc | sudo apt-key add -
sudo apt-get update

# 2. 安装 PostgreSQL 18 及扩展
sudo apt-get install -y \
    postgresql-18 \
    postgresql-18-pgtap \
    postgresql-18-plpython3 \
    postgresql-contrib \
    postgresql-18-pgaudit \
    postgresql-18-pgsodium

# 3. 启动服务
sudo systemctl enable postgresql
sudo systemctl start postgresql

# 4. 创建数据库和角色
sudo -u postgres psql -c "CREATE ROLE app_owner LOGIN PASSWORD 'dev_password_change_me';"
sudo -u postgres psql -c "CREATE ROLE authenticator LOGIN PASSWORD 'authenticator_dev_pass';"
sudo -u postgres psql -c "CREATE ROLE casdoor LOGIN PASSWORD 'casdoor_dev_pass';"
sudo -u postgres psql -c "CREATE DATABASE app_db OWNER app_owner;"
sudo -u postgres psql -c "CREATE DATABASE casdoor OWNER casdoor;"

# 5. 安装扩展
sudo -u postgres psql -d app_db -c "CREATE EXTENSION IF NOT EXISTS pgcrypto;"
sudo -u postgres psql -d app_db -c "CREATE EXTENSION IF NOT EXISTS pgsodium;"
sudo -u postgres psql -d app_db -c "CREATE EXTENSION IF NOT EXISTS pg_net;"
sudo -u postgres psql -d app_db -c "CREATE EXTENSION IF NOT EXISTS pgaudit;"
sudo -u postgres psql -d app_db -c "CREATE EXTENSION IF NOT EXISTS pgtap;"
sudo -u postgres psql -d app_db -c "CREATE EXTENSION IF NOT EXISTS pg_graphql;"
sudo -u postgres psql -d app_db -c "CREATE EXTENSION IF NOT EXISTS pg_cron;"
sudo -u postgres psql -d app_db -c "CREATE EXTENSION IF NOT EXISTS plpython3u;"

echo "✅ PostgreSQL 18 安装完成"
```

### 3.2 配置监听地址

```bash
# 编辑 /etc/postgresql/18/main/postgresql.conf
sudo sed -i "s/#listen_addresses = 'localhost'/listen_addresses = 'localhost'/" /etc/postgresql/18/main/postgresql.conf

# 编辑 /etc/postgresql/18/main/pg_hba.conf 允许本地连接
echo "host    all             all             127.0.0.1/32            scram-sha-256" | sudo tee -a /etc/postgresql/18/main/pg_hba.conf
echo "host    all             all             ::1/128                 scram-sha-256" | sudo tee -a /etc/postgresql/18/main/pg_hba.conf

# 重启
sudo systemctl restart postgresql
```

---

## 四、Docker Compose 配置（WSL2 内，不含 PostgreSQL）

```yaml
# docker-compose.yml (WSL2 内执行)
version: '3.8'

networks:
  app-net:
    driver: bridge

volumes:
  etcd_data:
  casdoor_data:
  redis_data:
  minio_data:

services:
  # 1. etcd (APISIX 配置存储)
  etcd:
    image: bitnami/etcd:3.6
    container_name: app-etcd
    restart: unless-stopped
    environment:
      ETCD_NAME: etcd-dev-node
      ALLOW_NONE_AUTHENTICATION: "yes"
      ETCD_ADVERTISE_CLIENT_URLS: http://0.0.0.0:2379
      ETCD_LISTEN_CLIENT_URLS: http://0.0.0.0:2379
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

  # 2. Redis (APISIX 限流)
  redis:
    image: redis:7-alpine
    container_name: app-redis
    restart: unless-stopped
    ports:
      - "6379:6379"
    volumes:
      - redis_data:/data
    networks:
      - app-net
    healthcheck:
      test: ["CMD", "redis-cli", "ping"]
      interval: 10s
      timeout: 3s
      retries: 5

  # 3. APISIX (API 网关)
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

  # 4. PostgREST (REST API 生成)
  postgrest:
    image: postgrest/postgrest:v14.14
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
    networks:
      - app-net
    healthcheck:
      test: ["CMD", "curl", "-f", "-s", "http://localhost:3000/"]
      interval: 15s
      timeout: 10s
      retries: 5

  # 5. Casdoor (OAuth/IAM)
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
    networks:
      - app-net
    healthcheck:
      test: ["CMD", "curl", "-f", "-s", "http://localhost:8000/api/health"]
      interval: 15s
      timeout: 10s
      retries: 10

  # 6. Swagger UI (API 文档)
  swagger-ui:
    image: swaggerapi/swagger-ui:v5.18.2
    container_name: app-swagger
    restart: unless-stopped
    environment:
      API_URL: "http://localhost:3000/"
    ports:
      - "8080:8080"
    networks:
      - app-net
    depends_on:
      - postgrest

  # 7. Policy Syncer (策略同步器)
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
    networks:
      - app-net
    depends_on:
      apisix:
        condition: service_healthy
    healthcheck:
      test: ["CMD", "wget", "--no-verbose", "--tries=1", "--spider", "http://localhost:8080/healthz"]
      interval: 30s
      timeout: 5s
      retries: 3

  # 8. MinIO (对象存储，可选)
  minio:
    image: minio/minio:latest
    container_name: app-minio
    restart: unless-stopped
    environment:
      MINIO_ROOT_USER: minioadmin
      MINIO_ROOT_PASSWORD: minioadmin
    ports:
      - "9000:9000"
      - "9001:9001"
    volumes:
      - minio_data:/data
    networks:
      - app-net
    command: server /data --console-address ":9001"
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
    │   http://localhost:9080  ← APISIX (WSL2/Docker，端口映射到 Windows)
    │       │
    │       ├─ JWT 验证 (jwt-auth 插件)
    │       ├─ Casbin 鉴权 (authz-casbin 插件)
    │       └─ 转发到 PostgREST
    │               │
    │               ▼
    │           http://localhost:3000  ← PostgREST (WSL2/Docker)
    │               │
    │               └─ SQL 查询
    │                       │
    │                       ▼
    │                   PostgreSQL (WSL2 原生，端口 5432)
    │
    └─ http://localhost:8000  ← Casdoor (WSL2/Docker，OAuth 登录)
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
| PostgreSQL | `localhost:5432` (WSL2 → Windows) | WSL2 原生，自动监听 |
| Casdoor | `localhost:8000` (WSL2 → Windows) | Docker 端口映射 |

**关键点：**
- WSL2 中的服务通过端口映射暴露给 Windows 的 `localhost`
- Docker 容器使用 `host.docker.internal` 访问 WSL2 原生服务（如 PostgreSQL）
- 前端代码中所有请求都走 `/api/v1` 前缀，由 Vite Proxy 转发到 APISIX

---

## 六、Policy Syncer — 功能回顾

### 6.1 作用

Policy Syncer 是一个 **Go 编写的 Sidecar 服务**，负责将数据库中的 Casbin 策略**实时同步**到 APISIX 网关。

### 6.2 核心流程

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

### 6.3 详细功能

| 功能 | 说明 |
|:---|:---|
| **实时监听** | 通过 PostgreSQL `LISTEN casbin_channel` 接收 `pg_notify` 事件 |
| **防抖合并** | 1 秒内的多次通知合并为一次同步，避免频繁写入 APISIX |
| **全量同步** | 从 `casbin_rule` 视图读取所有策略，CSV 格式推送到 APISIX Admin API |
| **SHA256 对账** | 每 10 分钟计算 DB 和 APISIX 的策略哈希，不一致时触发全量同步 |
| **Advisory Lock** | 多实例部署时通过 PostgreSQL Advisory Lock 选主，避免并发写入 |
| **冷启动** | 首次启动时执行一次全量同步 |
| **健康检查** | HTTP `/healthz` 端点返回 PG 连接状态 |

### 6.4 相关文档

| 文档 | 内容 |
|:---|:---|
| **06-Policy-Syncer-Go实现.md** | 完整 Go 源码、Dockerfile、运维脚本 |
| **审查文档/06-审查报告.md** | 原始审查报告（P0/P1/P2 问题） |
| **08-Docker-Compose.md** | Syncer 在 docker-compose.yml 中的服务定义 |
| **10-APISIX路由批量配置.md** | Syncer 推送策略的目标（APISIX plugin_metadata） |

---

## 七、部署步骤清单

### 步骤 1：WSL2 中安装 PostgreSQL 18

```bash
# 在 WSL2 中执行
chmod +x install-pg18.sh
./install-pg18.sh
```

### 步骤 2：初始化数据库

```bash
# 执行 Dbmate migration
cd /d/WeChat\ Files/xiangmu/源码/db
dbmate up
```

### 步骤 3：启动 Docker Compose

```bash
cd /d/WeChat\ Files/xiangmu/源码
docker compose up -d
```

### 步骤 4：验证服务

```bash
# PostgreSQL
psql -h localhost -U app_owner -d app_db -c "SELECT 1"

# APISIX
curl http://localhost:9080/apisix/status

# PostgREST
curl http://localhost:3000/

# Casdoor
curl http://localhost:8000/api/health

# Policy Syncer
curl http://localhost:8080/healthz
```

### 步骤 5：启动前端

```bash
cd frontend/admin-ui
npm install
npm run dev
# 浏览器打开 http://localhost:5173
```

---

## 八、组件端口速查表

| 端口 | 组件 | 位置 | 协议 |
|:---|:---|:---|:---|
| 5432 | PostgreSQL 18 | WSL2 原生 | TCP |
| 3000 | PostgREST | Docker (WSL2) | HTTP |
| 9080 | APISIX (数据面) | Docker (WSL2) | HTTP |
| 9180 | APISIX (控制面) | Docker (WSL2) | HTTP |
| 2379 | etcd | Docker (WSL2) | HTTP |
| 6379 | Redis | Docker (WSL2) | TCP |
| 8000 | Casdoor | Docker (WSL2) | HTTP |
| 8080 | Swagger UI | Docker (WSL2) | HTTP |
| 8080 | Policy Syncer | Docker (WSL2) | HTTP |
| 5173 | Vite Dev Server | Windows 本地 | HTTP |
| 9000 | MinIO | Docker (WSL2) | HTTP |

---

## 九、Pigsty 监控集成（可选）

由于 PostgreSQL 部署在 WSL2 原生环境中，Pigsty 可以直接管理监控：

```bash
# 在 WSL2 中安装 Pigsty
curl -fsSL https://pigsty.cc/get | bash

# 配置 Pigsty 监控 PostgreSQL
cat >> /opt/pigsty/pigsty.yml <<EOF
pg_instances:
  - host: localhost
    port: 5432
    db: app_db
    user: app_owner
    password: dev_password_change_me
EOF

# 部署监控
cd /opt/pigsty
ansible-playbook monitor.yml
```

**Pigsty 提供的监控能力：**
- Prometheus 指标采集（pg_exporter）
- Grafana Dashboard（40+ PG 相关面板）
- VictoriaMetrics 长期存储
- Loki 日志采集
- Alertmanager 告警

---

## 十、总结

| 组件 | 部署方式 | 理由 |
|:---|:---|:---|
| **PostgreSQL 18** | WSL2 原生 | 性能更好、扩展易安装、监控集成方便、Pigsty 原生管理 |
| **APISIX/PostgREST/Casdoor/Redis/etcd** | Docker Compose | 快速启停、环境隔离、版本可控 |
| **Policy Syncer** | Docker Compose | 需要与 APISIX 同网络 |
| **前端 (Vite)** | Windows 本地 | 开发体验好、热更新快 |
| **监控 (Pigsty)** | WSL2 原生 | 直接连接本地 PG，无需穿透 Docker |
