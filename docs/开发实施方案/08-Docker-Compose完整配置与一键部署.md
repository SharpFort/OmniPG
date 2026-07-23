# 08 — Docker Compose 完整配置与一键部署

> **定位：** 提供完整可执行的 Docker Compose 开发环境编排，包含所有服务、配置文件、环境变量和启动脚本。Agent 按本文档可一键启动全栈开发环境。
> **前置依赖：** 00-项目总纲（架构概念）、01-环境搭建（设计理念）、02-数据库建模（函数/视图/触发器定义）
> **产出物：** 完整的 `docker-compose.yml` + 所有配置文件 + `.env.example` + 启动脚本
> **预计耗时：** 首次配置 1-2 小时（包含文件创建和环境验证）
> **目标目录：** `D:\WeChat Files\xiangmu\源码\`

---

## 1. 项目目录结构

```
D:\WeChat Files\xiangmu\源码\
├── docker-compose.yml              # Docker Compose 编排文件
├── .env                            # 环境变量文件（从 .env.example 复制）
├── .env.example                    # 环境变量模板（不含敏感值）
├── .gitignore
│
├── db/
│   ├── init/
│   │   ├── 01-extensions.sql       # 扩展安装脚本
│   │   ├── 02-schemas.sql          # Schema 和角色创建
│   │   └── 03-casdoor-db.sql       # Casdoor 数据库创建（手动执行）
│   └── migrations/
│       └── 20260707001_init_tables.sql  # Dbmate migration（从 02 提取）
│
├── pgbouncer/
│   ├── pgbouncer.ini               # Pgbouncer 配置文件
│   └── userlist.txt                # 用户认证文件
│
├── apisix/
│   ├── config.yaml                 # APISIX 配置文件
│   └── apisix.yaml                 # 路由初始文件（空）
│
├── syncer/
│   ├── Dockerfile                  # Go Builder + Alpine 多阶段构建
│   └── main.go                     # 从 04 文档提取
│
├── postgrest/
│   └── postgrest.conf              # PostgREST 配置文件（可选，也可环境变量）
│
└── scripts/
    ├── start.ps1                   # PowerShell 一键启动
    ├── start.sh                    # bash 一键启动
    ├── init-db.ps1                 # 数据库初始化（Windows）
    ├── init-db.sh                  # 数据库初始化（Linux/macOS）
    └── health-check.ps1            # 健康检查脚本
```

---

## 2. docker-compose.yml（完整版）

```yaml
# ==============================================================================
# 零后端代码统一权限管理系统 — Docker Compose 开发环境
# 版本：v1.0 (2026-07-08)
# 定位：开发环境仅用于功能验证，生产环境请使用 Pigsty 部署
# ==============================================================================

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
    driver: local
  etcd_data:
    driver: local
  casdoor_data:
    driver: local
  redis_data:
    driver: local  # [修复 P2-2] Redis 数据持久化

# ==============================================================================
# 服务定义
# ==============================================================================
services:

  # ============================================================================
  # 1. PostgreSQL 数据库（核心数据库：app_db + casdoor）
  # ============================================================================
  postgres:
    image: pgcharles/pgtap:18
    container_name: app-postgres
    restart: unless-stopped
    environment:
      POSTGRES_DB: app_db
      POSTGRES_USER: app_owner
      POSTGRES_PASSWORD: ${DB_PASSWORD:-dev_password_change_me}
    ports:
      - "${PG_PORT:-5432}:5432"
    volumes:
      - pg_data:/var/lib/postgresql/data
      - ./db/init/01-extensions.sql:/docker-entrypoint-initdb.d/01-extensions.sql:ro
      - ./db/init/02-schemas.sql:/docker-entrypoint-initdb.d/02-schemas.sql:ro
      - ./db/init/03-casdoor-db.sql:/docker-entrypoint-initdb.d/03-casdoor-db.sql:ro  # [修复 P1-2] Casdoor 数据库自动创建
    networks:
      - app-net
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U app_owner -d app_db"]
      interval: 10s
      timeout: 5s
      retries: 5
    command: >
      -c shared_preload_libraries='pgaudit,pg_net'
      -c shared_buffers=256MB
      -c max_connections=100
      -c work_mem=4MB
      -c maintenance_work_mem=64MB
      -c effective_cache_size=768MB
      -c random_page_cost=1.1
      -c effective_io_concurrency=200
      -c wal_buffers=16MB
      -c min_wal_size=80MB
      -c max_wal_size=1GB
      -c checkpoint_completion_target=0.9
      -c default_statistics_target=100
      -c log_min_duration_statement=200
      -c log_checkpoints=on
      -c log_connections=on
      -c log_disconnections=on
      -c log_lock_waits=on

  # ============================================================================
  # 2. Pgbouncer 连接池
  # ============================================================================
  pgbouncer:
    image: pgbouncer/pgbouncer:1.24
    container_name: app-pgbouncer
    restart: unless-stopped
    ports:
      - "${PG_BOUNCER_PORT:-5433}:6432"
    volumes:
      - ./pgbouncer/pgbouncer.ini:/etc/pgbouncer/pgbouncer.ini:ro
      - ./pgbouncer/userlist.txt:/etc/pgbouncer/userlist.txt:ro
    networks:
      - app-net
    depends_on:
      postgres:
        condition: service_healthy

  # ============================================================================
  # 3. etcd（APISIX 配置存储）
  # ============================================================================
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
      ETCD_QUOTA_BACKEND_BYTES: "8589934592"
    ports:
      - "${ETCD_PORT:-2379}:2379"
    volumes:
      - etcd_data:/bitnami/etcd/data
    networks:
      - app-net
    healthcheck:
      test: ["CMD", "etcdctl", "endpoint", "health"]
      interval: 10s
      timeout: 5s
      retries: 5

  # ============================================================================
  # 4. APISIX API 网关
  # ============================================================================
  apisix:
    image: apache/apisix:3.17.0-debian
    container_name: app-apisix
    restart: unless-stopped
    environment:
      APISIX_STAND_ALONE: "false"
      APISIX_WORKER_PROCESSES: "auto"
    ports:
      - "${APISIX_HTTP_PORT:-9080}:9080"
      - "${APISIX_HTTPS_PORT:-9443}:9443"
      - "${APISIX_ADMIN_PORT:-9180}:9180"
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

  # ============================================================================
  # 5. PostgREST API 自动生成引擎
  # ============================================================================
  postgrest:
    image: postgrest/postgrest:v14.14
    container_name: app-postgrest
    restart: unless-stopped
    environment:
      PGRST_DB_URI: postgres://authenticator:***@pgbouncer:6432/app_db?sslmode=disable
      PGRST_DB_SCHEMAS: "api_v1"
      PGRST_DB_ANON_ROLE: web_anon
      PGRST_DB_EXTRA_SEARCH_PATH: "public"
      PGRST_JWT_SECRET: ${JWKS_JSON:-***}
      PGRST_DB_PRE_REQUEST: "api_v1.check_token_blacklist"
      PGRST_OPENAPI_SERVER_PROXY_URI: "http://localhost:3000"
      PGRST_SERVER_HOST: "0.0.0.0"
      PGRST_SERVER_PORT: "3000"
      PGRST_DB_AGGREGATES_ENABLED: "true"
      PGRST_MAX_ROWS: "1000"
      PGRST_PRE_ERROR_EXTENDED: "true"
      PGRST_DB_TX_END: "commit"
    ports:
      - "${PGRST_PORT:-3000}:3000"
    networks:
      - app-net
    depends_on:
      pgbouncer:
        condition: service_started
    healthcheck:
      test: ["CMD", "curl", "-f", "-s", "http://localhost:3000/"]
      interval: 15s
      timeout: 10s
      retries: 5

  # ============================================================================
  # 6. Redis（APISIX limit-req 限流插件所需）
  # ============================================================================
  redis:
    image: redis:7-alpine
    container_name: app-redis
    restart: unless-stopped
    ports:
      - "${REDIS_PORT:-6379}:6379"
    networks:
      - app-net
    volumes:
      - redis_data:/data
    healthcheck:
      test: ["CMD", "redis-cli", "ping"]
      interval: 10s
      timeout: 3s
      retries: 5

  # ============================================================================
  # 7. Casdoor IAM/OAuth 认证服务（直连 PostgreSQL，无需 MySQL）
  # ============================================================================
  casdoor:
    image: casbin/casdoor:latest
    container_name: app-casdoor
    restart: unless-stopped
    ports:
      - "${CASDOOR_PORT:-8000}:8000"
    environment:
      driverName: postgres
      dataSourceName: "user=casdoor password=${CASDOOR_DB_PASSWORD:-casdoor_dev_pass} host=pgbouncer port=6432 sslmode=disable dbname=casdoor"
      runMode: dev
      httpPort: 8000
      logConfig: '{"enable":true,"console":true,"release":true,"save":true,"logFormat":"${dd}/${MM}/${yyyy} ${hh}:${mm}:${ss} ${level}: ${message}"}'
    volumes:
      - casdoor_data:/app/conf
    networks:
      - app-net
    depends_on:
      pgbouncer:
        condition: service_started
    healthcheck:
      test: ["CMD", "curl", "-f", "-s", "http://localhost:8000/api/health"]
      interval: 15s
      timeout: 10s
      retries: 10

  # ============================================================================
  # 7. Swagger UI API 文档
  # ============================================================================
  swagger-ui:
    image: swaggerapi/swagger-ui:v5.18.2
    container_name: app-swagger
    restart: unless-stopped
    environment:
      SWAGGER_JSON: "/openapi.json"
      API_URL: "http://localhost:3000/"
      BASE_URL: "/"
    ports:
      - "${SWAGGER_PORT:-8080}:8080"
    networks:
      - app-net
    depends_on:
      - postgrest
    healthcheck:
      test: ["CMD", "curl", "-f", "-s", "http://localhost:8080/"]
      interval: 15s
      timeout: 10s
      retries: 5

  # ============================================================================
  # 8. Policy Syncer（Go 策略同步器）
  # ============================================================================
  syncer:
    build:
      context: ./syncer
      dockerfile: Dockerfile
    container_name: policy-syncer
    restart: unless-stopped
    environment:
      DB_HOST: postgres
      DB_PORT: "5432"
      DB_USER: app_owner
      DB_PASSWORD: ${DB_PASSWORD:-dev_password_change_me}
      SSL_MODE: disable
      APISIX_ADMIN_URL: http://apisix:9180/apisix/admin/plugin_metadata/authz-casbin
      APISIX_ADMIN_KEY: ${APISIX_ADMIN_KEY:-edd1c9f034335f136f87ad84b625c8f1}
    networks:
      - app-net
    depends_on:
      postgres:
        condition: service_healthy
      apisix:
        condition: service_healthy   # [修复 P0-1] 修正拼写错误
    volumes:
      - /etc/localtime:/etc/localtime:ro
    logging:
      driver: "json-file"
      options:
        max-size: "10m"
        max-file: "3"
    # [修复 P1-5] 使用 /healthz 端点（需 Syncer 实现）
    healthcheck:
      test: ["CMD", "wget", "--no-verbose", "--tries=1", "--spider", "http://localhost:8080/healthz"]
      interval: 30s
      timeout: 5s
      retries: 3
```

---

## 3. 配置文件

### 3.1 .env.example（环境变量模板）

```ini
# ==============================================================================
# 零后端代码统一管理后台 — 开发环境配置
# 用法：复制此文件为 .env 并修改变量值
# cp .env.example .env
# ==============================================================================

# ------------------------------------------------------------------------------
# 应用基础
# ------------------------------------------------------------------------------
APP_ENV=development
APP_NAME=zero-backend-rbac

# ------------------------------------------------------------------------------
# PostgreSQL
# ------------------------------------------------------------------------------
PG_PORT=5432
DB_PASSWORD=dev_password_change_me
DB_USER=app_owner
DB_NAME=app_db

# ------------------------------------------------------------------------------
# Pgbouncer 连接池
# ------------------------------------------------------------------------------
PG_BOUNCER_PORT=5433
AUTHENTICATOR_PASSWORD=authenticator_dev_pass

# ------------------------------------------------------------------------------
# APISIX
# ------------------------------------------------------------------------------
APISIX_HTTP_PORT=9080
APISIX_HTTPS_PORT=9443
APISIX_ADMIN_PORT=9180
APISIX_ADMIN_KEY=edd1c9f034335f136f87ad84b625c8f1

# ------------------------------------------------------------------------------
# PostgREST
# ------------------------------------------------------------------------------
PGRST_PORT=3000
# JWT Secret：开发环境使用 HS256 对称密钥，生产环境使用 Casdoor JWKS RS256
# [修复 P1-4] 开发环境：使用预生成的 HS256 JWKS（base64编码的32字节密钥）
JWK_JSON={"keys":[{"kty":"oct","kid":"dev-hs256","alg":"HS256","k":"c2VjcmV0X2RldmVsb3BtZW50X2tleV9hdF9sZWFzdF9zZXZlbl9jaGFyYWN0ZXJzIQ=="}]}

# ------------------------------------------------------------------------------
# Casdoor
# ------------------------------------------------------------------------------
CASDOOR_PORT=8000
CASDOOR_DB_PASSWORD=casdoor_dev_pass
CASDOOR_ENDPOINT=http://localhost:8000
CASDOOR_CLIENT_ID=zero-backend-app

# ------------------------------------------------------------------------------
# etcd
# ------------------------------------------------------------------------------
ETCD_PORT=2379

# ------------------------------------------------------------------------------
# Swagger UI
# ------------------------------------------------------------------------------
SWAGGER_PORT=8080

# ------------------------------------------------------------------------------
# 前端开发
# ------------------------------------------------------------------------------
VITE_APP_PORT=5173

# ------------------------------------------------------------------------------
# JWT (开发环境临时配置 — 生产环境替换为 Casdoor JWKS)
# ------------------------------------------------------------------------------
# [修复 P1-4] 开发环境：使用 HS256 对称密钥
JWKS_JSON={"keys":[{"kty":"oct","kid":"dev-hs256","alg":"HS256","k":"c2VjcmV0X2RldmVsb3BtZW50X2tleV9hdF9sZWFzdF9zZXZlbl9jaGFyYWN0ZXJzIQ=="}]}
# 生产环境：从 Casdoor JWKS 自动获取（参考 04.5-Casdoor集成文档）
# JWKS_JSON={"keys":[{"kty":"RSA","kid":"cert-rsa","use":"sig","alg":"RS256","n":"...","e":"AQAB"}]}

# ------------------------------------------------------------------------------
# RLS 租户配置
# ------------------------------------------------------------------------------
DEFAULT_TENANT_ID=tenant_default
```

### 3.2 pgbouncer/pgbouncer.ini

```ini
# ==============================================================================
# Pgbouncer 配置 — 开发环境
# ==============================================================================

[databases]
; 数据库别名 = 连接串
; 使用 Docker Compose 容器名作为 host
app_db = host=postgres port=5432 dbname=app_db
casdoor = host=postgres port=5432 dbname=casdoor

[pgbouncer]
# 监听配置
listen_port = 6432
listen_addr = 0.0.0.0
auth_type = md5
auth_file = /etc/pgbouncer/userlist.txt

# 连接池模式
# session 模式：开发环境兼容性更好，支持 LISTEN/NOTIFY（Syncer 必需）
# transaction 模式：生产 Pigsty 默认，资源效率更高但不支持 LISTEN/NOTIFY
pool_mode = session

# 连接池大小（开发环境最小值）
max_client_conn = 100
default_pool_size = 10
reserve_pool_size = 5
reserve_pool_timeout = 3

# 超时配置
server_idle_timeout = 600
server_lifetime = 3600
client_idle_timeout = 0
client_login_timeout = 60
server_login_retry = 1

# TCP 配置
tcp_keepalive = 1
tcp_keepidle = 30
tcp_keepintvl = 10
tcp_keepcnt = 3

# 日志配置
# [修复 P2-3] pgbouncer 官方镜像会自动创建 /var/log/pgbouncer 和 /var/run/pgbouncer
logfile = /var/log/pgbouncer/pgbouncer.log
pidfile = /var/run/pgbouncer/pgbouncer.pid

# 管理界面（可选）
admin_users = pgadmin
stats_users = stats
```

### 3.3 pgbouncer/userlist.txt

```ini
# ==============================================================================
# Pgbouncer 用户认证文件
# 格式："username" "password"
# ==============================================================================
# 注意：以下密码与 .env 中的 DB_PASSWORD 和 AUTHENTICATOR_PASSWORD 一致
"app_owner" "dev_password_change_me"
"authenticator" "authenticator_dev_pass"
"casdoor" "casdoor_dev_pass"
"pgadmin" "pgadmin_dev_pass"
"stats" "stats_dev_pass"
"web_anon" "web_anon_pass"
"authenticated" "authenticated_pass"
```

### 3.4 apisix/config.yaml

```yaml
# ==============================================================================
# APISIX 配置文件
# ==============================================================================

deployment:
  role: traditional
  role_traditional:
    config_provider: etcd

  admin:
    allow_admin:
      - 0.0.0.0/0
    admin_listen:
      ip: 0.0.0.0
      port: 9180
    admin_key:
      - name: admin
        key: edd1c9f034335f136f87ad84b625c8f1
        role: admin

  etcd:
    host:
      - "http://etcd:2379"
    prefix: "/apisix"
    timeout: 30

nginx_config:
  user: root
  error_log: /usr/local/apisix/logs/error.log
  error_log_level: "warn"
  worker_processes: auto
  worker_rlimit_nofile: 20480

apisix:
  node_listen: 9080
  enable_heartbeat: true
  enable_admin: true
  enable_admin_cors: true
  enable_debug: true
  enable_dev_mode: true
  enable_reuseport: true
  enable_ipv6: true
  config_center: yaml

  allow_admin:
    - 0.0.0.0/0

  # SSL（开发环境不启用，生产环境通过 HAProxy 终止 SSL）
  enable_ssl: false

plugin_attr:
  prometheus:
    export_uri: /apisix/prometheus/metrics

  # 日志插件
  file-logger:
    path: /usr/local/apisix/logs/access.log

  # 限流（[修复 P1-1] 需要 Redis 容器支持）
  limit-req:
    allow_degradation: false
    rejected_code: 429
    rejected_msg: '{"error":"rate_limit","message":"Too many requests"}'
    policy: redis
    redis_host: app-redis   # [修复] 使用容器名而非简写 redis
    redis_port: 6379
    redis_timeout: 1000
```

### 3.5 apisix/apisix.yaml

```yaml
# ==============================================================================
# APISIX 路由初始配置
# ==============================================================================
# 阶段4（网关与同步器）会通过 APISIX Admin API 动态添加路由
# 此文件初始为空占位，用于容器挂载
# ==============================================================================

routes: []
upstreams: []

global_rules: []
consumers: []
plugin_configs: []
```

### 3.6 syncer/Dockerfile

```dockerfile
# ==============================================================================
# Policy Syncer Docker 构建文件
# 多阶段构建：Go Builder + Alpine 运行时
# ==============================================================================

# 第一阶段：Go 编译
FROM golang:1.22-alpine AS builder

RUN apk add --no-cache git ca-certificates

WORKDIR /app

# 复制源码
COPY main.go .

# 初始化 Go 模块并下载依赖
 true
RUN go get github.com/lib/pq@v1.10.9

# 编译为静态二进制
RUN CGO_ENABLED=0 GOOS=linux go build \
    -ldflags='-w -s -extldflags "-static"' \
    -o policy-syncer main.go

# 第二阶段：运行镜像
FROM alpine:3.19

RUN apk add --no-cache ca-certificates tzdata

# 复制二进制
COPY --from=builder /app/policy-syncer /usr/local/bin/policy-syncer

# 健康检查脚本
RUN echo '#!/bin/sh' > /usr/local/bin/healthcheck && \
 grep policy-syncer || exit 1' >> /usr/local/bin/healthcheck && \
    chmod +x /usr/local/bin/healthcheck

ENTRYPOINT ["policy-syncer"]
```

### 3.7 db/init/01-extensions.sql

```sql
-- ==============================================================================
-- PostgreSQL 扩展安装脚本（容器首次启动自动执行）
-- 此脚本挂载到 /docker-entrypoint-initdb.d/ 目录，PG 容器启动时自动执行
-- ==============================================================================

-- 核心扩展（02 系统依赖）
CREATE EXTENSION IF NOT EXISTS "pgcrypto";        -- 密码加密、gen_random_uuid()
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";       -- UUID 生成（备用）

-- 安全审计
CREATE EXTENSION IF NOT EXISTS "pgaudit";         -- SQL 审计日志
CREATE EXTENSION IF NOT EXISTS "pgsodium";        -- 透明列加密

-- 网络
CREATE EXTENSION IF NOT EXISTS "pg_net";          -- 异步 HTTP 请求、LISTEN/NOTIFY

-- 测试
CREATE EXTENSION IF NOT EXISTS "pgtap";           -- pgTAP 单元测试

-- 日志
\echo '扩展安装完成：pgcrypto, uuid-ossp, pgaudit, pgsodium, pg_net, pgtap'
```

### 3.8 db/init/02-schemas.sql

```sql
-- ==============================================================================
-- 初始 Schema 和角色创建（容器首次启动自动执行）
-- ==============================================================================

-- 创建业务 Schema
CREATE SCHEMA IF NOT EXISTS api_v1;
COMMENT ON SCHEMA api_v1 IS 'PostgREST 暴露的业务 API Schema';

-- 创建 pg_net 使用的 schema
CREATE SCHEMA IF NOT EXISTS net;
COMMENT ON SCHEMA net IS 'pg_net 异步 HTTP 请求 Schema';

-- ==============================================================================
-- 角色创建
-- ==============================================================================

-- 1. 匿名角色（无权访问数据）
DO $$
BEGIN
    IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'web_anon') THEN
        CREATE ROLE web_anon NOLOGIN NOINHERIT;
    END IF;
END
$$;

-- 2. 认证用户角色
DO $$
BEGIN
    IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'authenticated') THEN
        CREATE ROLE authenticated NOLOGIN NOINHERIT;
    END IF;
END
$$;

-- 3. authenticator 角色（PostgREST 连接用的 LOGIN 角色）
DO $$
BEGIN
    IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'authenticator') THEN
        CREATE ROLE authenticator LOGIN NOINHERIT PASSWORD 'authenticator_dev_pass';
    END IF;
END
$$;

-- 4. casdoor 角色（Casdoor 服务专用）
DO $$
BEGIN
    IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'casdoor') THEN
        CREATE ROLE casdoor LOGIN PASSWORD 'casdoor_dev_pass';
    END IF;
END
$$;

-- [修复 P1-2] 业务角色（JWT roles 数组映射到 PG 角色，与 sys_role.role_code 一致）
DO $$
BEGIN
    IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'super_admin') THEN
        CREATE ROLE super_admin NOLOGIN NOINHERIT;
    END IF;
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

-- 将业务角色授予 authenticator（允许 SET ROLE 切换）
GRANT super_admin TO authenticator;
GRANT role_admin TO authenticator;
GRANT role_editor TO authenticator;
GRANT role_guest TO authenticator;

-- ==============================================================================
-- 角色权限授予
-- ==============================================================================

-- authenticator 可以切换到 web_anon 和 authenticated
GRANT web_anon TO authenticator;
GRANT authenticated TO authenticator;

-- Schema 使用权
GRANT USAGE ON SCHEMA api_v1 TO web_anon;
GRANT USAGE ON SCHEMA api_v1 TO authenticated;
GRANT USAGE ON SCHEMA api_v1 TO authenticator;

-- web_anon 默认无任何表权限（安全第一）
-- authenticated 的权限在后续 migration 中根据表逐步授予

-- pg_net 权限
GRANT USAGE ON SCHEMA net TO authenticated;
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA net TO authenticated;

\echo 'Schema 和角色创建完成'

-- ==============================================================================
-- [修复 P1-3] api_v1.check_token_blacklist 包装函数
-- PostgREST PGRST_DB_PRE_REQUEST = api_v1.check_token_blacklist
-- 实际函数在 public schema（07 Migration 005 创建）
-- 需要在 api_v1 schema 中创建 SECURITY DEFINER 包装函数供 PostgREST 调用
-- ==============================================================================
CREATE OR REPLACE FUNCTION api_v1.check_token_blacklist()
RETURNS void
LANGUAGE sql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$ SELECT public.check_token_blacklist() $$;
COMMENT ON FUNCTION api_v1.check_token_blacklist() IS 'PostgREST db-pre-request 包装（委托 public.check_token_blacklist）';
```

### 3.9 db/init/03-casdoor-db.sql

```sql
-- ==============================================================================
-- Casdoor 数据库初始化脚本
-- 使用方法：
--   docker exec -i app-postgres psql -U app_owner -d app_db -f /path/to/03-casdoor-db.sql
-- 或：
--   docker exec -it app-postgres psql -U app_owner -d app_db -c "\i /docker-entrypoint-initdb.d/03-casdoor-db.sql"
-- ==============================================================================

-- 1. 创建 casdoor 用户（如果不存在）
DO $$
BEGIN
    IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'casdoor') THEN
        CREATE ROLE casdoor LOGIN PASSWORD 'casdoor_dev_pass';
    END IF;
END
$$;

-- 2. 创建 casdoor 数据库
SELECT 'CREATE DATABASE casdoor OWNER casdoor'
WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = 'casdoor')\gexec

-- 3. 授予权限
GRANT ALL PRIVILEGES ON DATABASE casdoor TO casdoor;

-- 4. 连接到 casdoor 数据库，启用必要扩展
\connect casdoor

CREATE EXTENSION IF NOT EXISTS "uuid-ossp";
CREATE EXTENSION IF NOT EXISTS "pgcrypto";

-- 5. 确认创建成功
SELECT current_database(), current_user;

\echo 'Casdoor 数据库初始化完成'
```

---

## 4. 启动脚本

### 4.1 scripts/start.ps1（Windows PowerShell）

```powershell
# ==============================================================================
# 一键启动脚本（Windows PowerShell）
# 用法：.\scripts\start.ps1
# ==============================================================================

$ErrorActionPreference = "Stop"
$ProjectRoot = Split-Path -Parent $PSScriptRoot

Write-Host "========================================" -ForegroundColor Cyan
Write-Host "  零后端代码统一管理后台 — 开发环境启动" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan

# 检查 .env 文件
if (-not (Test-Path "$ProjectRoot\.env")) {
    Write-Host "⚠️  .env 文件不存在，从 .env.example 复制..." -ForegroundColor Yellow
    Copy-Item "$ProjectRoot\.env.example" "$ProjectRoot\.env"
    Write-Host "✅ .env 文件已创建，请检查配置后重新运行" -ForegroundColor Green
    Write-Host "   编辑 $ProjectRoot\.env 修改默认密码" -ForegroundColor Yellow
    exit 0
}

# 检查 Docker
try {
 Out-Null
    Write-Host "✅ Docker 已安装" -ForegroundColor Green
} catch {
    Write-Host "❌ Docker 未安装，请先安装 Docker Desktop" -ForegroundColor Red
    exit 1
}

# 创建必要目录
# [修复 P2-1] PowerShell 中统一使用 / 作为路径分隔符（兼容 PowerShell 7+）
$dirs = @(
    "$ProjectRoot/db/init",
    "$ProjectRoot/db/migrations",
    "$ProjectRoot/pgbouncer",
    "$ProjectRoot/apisix",
    "$ProjectRoot/syncer",
    "$ProjectRoot/postgrest"
)

foreach ($dir in $dirs) {
    if (-not (Test-Path $dir)) {
 Out-Null
    }
}

# 启动服务
Write-Host ""
Write-Host "🚀 正在启动服务..." -ForegroundColor Cyan
Set-Location $ProjectRoot

docker compose up -d --build

Write-Host ""
Write-Host "⏳ 等待服务就绪（约 30 秒）..." -ForegroundColor Yellow
Start-Sleep -Seconds 30

# 检查服务状态
Write-Host ""
Write-Host "📊 服务状态：" -ForegroundColor Cyan
docker compose ps

# 检查健康状态
Write-Host ""
Write-Host "🏥 健康检查：" -ForegroundColor Cyan

$services = @("postgres", "pgbouncer", "etcd", "apisix", "postgrest", "casdoor", "swagger-ui", "syncer")
foreach ($svc in $services) {
    $status = docker inspect --format='{{.State.Health.Status}}' "app-$svc" 2>$null
    if ($status -eq "healthy") {
        Write-Host "  ✅ $svc : $status" -ForegroundColor Green
    } elseif ($status -eq "starting") {
        Write-Host "  ⏳ $svc : $status" -ForegroundColor Yellow
    } else {
        Write-Host "  ❌ $svc : $status" -ForegroundColor Red
    }
}

Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "  启动完成！" -ForegroundColor Green
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "📌 访问地址：" -ForegroundColor Cyan
Write-Host "  • Swagger UI:    http://localhost:8080"
Write-Host "  • Casdoor:       http://localhost:8000  (admin/123)"
Write-Host "  • APISIX Admin:  http://localhost:9180  (edd1c9f034335f136f87ad84b625c8f1)"
Write-Host "  • PostgREST:     http://localhost:3000"
Write-Host "  • APISIX 网关:   http://localhost:9080"
Write-Host ""
Write-Host "📌 下一步：" -ForegroundColor Cyan
Write-Host "  1. 初始化 Casdoor 数据库：.\scripts\init-db.ps1"
Write-Host "  2. 执行 Dbmate migration：cd db && dbmate up"
Write-Host "  3. 启动前端：cd frontend/admin-ui && npm run dev"
Write-Host ""
Write-Host "📌 常用命令：" -ForegroundColor Cyan
Write-Host "  • 查看日志：docker compose logs -f [service]"
Write-Host "  • 停止服务：docker compose down"
Write-Host "  • 重启服务：docker compose restart [service]"
Write-Host "  • 清理数据：docker compose down -v"
```

### 4.2 scripts/start.sh（Linux/macOS bash）

```bash
#!/bin/bash
# ==============================================================================
# 一键启动脚本（Linux/macOS）
# 用法：bash scripts/start.sh
# ==============================================================================

set -e

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

echo -e "\033[36m========================================\033[0m"
echo -e "\033[36m  零后端代码统一管理后台 — 开发环境启动\033[0m"
echo -e "\033[36m========================================\033[0m"

# 检查 .env 文件
if [ ! -f "$PROJECT_ROOT/.env" ]; then
    echo -e "\033[33m⚠️  .env 文件不存在，从 .env.example 复制...\033[0m"
    cp "$PROJECT_ROOT/.env.example" "$PROJECT_ROOT/.env"
    echo -e "\033[32m✅ .env 文件已创建\033[0m"
    echo -e "\033[33m   请编辑 $PROJECT_ROOT/.env 修改默认密码后重新运行\033[0m"
    exit 0
fi

# 检查 Docker
if ! command -v docker &> /dev/null; then
    echo -e "\033[31m❌ Docker 未安装\033[0m"
    exit 1
fi

# 创建必要目录
mkdir -p "$PROJECT_ROOT"/{db/{init,migrations},pgbouncer,apisix,syncer,postgrest}

# 启动服务
echo ""
echo -e "\033[36m🚀 正在启动服务...\033[0m"
cd "$PROJECT_ROOT"
docker compose up -d --build

echo ""
echo -e "\033[33m⏳ 等待服务就绪（约 30 秒）...\033[0m"
sleep 30

# 检查服务状态
echo ""
echo -e "\033[36m📊 服务状态：\033[0m"
docker compose ps

echo ""
echo -e "\033[36m🏥 健康检查：\033[0m"

for svc in postgres pgbouncer etcd apisix postgrest casdoor swagger-ui syncer; do
 echo "unknown")
    if [ "$status" = "healthy" ]; then
        echo -e "  \033[32m✅ $svc : $status\033[0m"
    elif [ "$status" = "starting" ]; then
        echo -e "  \033[33m⏳ $svc : $status\033[0m"
    else
        echo -e "  \033[31m❌ $svc : $status\033[0m"
    fi
done

echo ""
echo -e "\033[36m========================================\033[0m"
echo -e "\033[32m  启动完成！\033[0m"
echo -e "\033[36m========================================\033[0m"
echo ""
echo -e "\033[36m📌 访问地址：\033[0m"
echo "  • Swagger UI:    http://localhost:8080"
echo "  • Casdoor:       http://localhost:8000  (admin/123)"
echo "  • APISIX Admin:  http://localhost:9180"
echo "  • PostgREST:     http://localhost:3000"
echo "  • APISIX 网关:   http://localhost:9080"
echo ""
echo -e "\033[36m📌 下一步：\033[0m"
echo "  1. 初始化 Casdoor 数据库：bash scripts/init-db.sh"
echo "  2. 执行 Dbmate migration：cd db && dbmate up"
echo "  3. 启动前端：cd frontend/admin-ui && npm run dev"
```

### 4.3 scripts/init-db.ps1（Windows 数据库初始化）

```powershell
# ==============================================================================
# 数据库初始化脚本（Windows）
# 用途：创建 Casdoor 数据库、执行 Dbmate migration
# ==============================================================================

$ErrorActionPreference = "Stop"
$ProjectRoot = Split-Path -Parent $PSScriptRoot

Write-Host "========================================" -ForegroundColor Cyan
Write-Host "  数据库初始化" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan

# 1. 检查 PG 是否就绪
Write-Host ""
Write-Host "⏳ 等待 PostgreSQL 就绪..." -ForegroundColor Yellow
$retries = 0
do {
    Start-Sleep -Seconds 5
    $retries++
    $pgReady = docker exec app-postgres pg_isready -U app_owner -d app_db 2>$null
} while (-not $pgReady -and $retries -lt 12)

if (-not $pgReady) {
    Write-Host "❌ PostgreSQL 未就绪，请检查 docker compose logs postgres" -ForegroundColor Red
    exit 1
}
Write-Host "✅ PostgreSQL 就绪" -ForegroundColor Green

# 2. 创建 Casdoor 数据库
Write-Host ""
Write-Host "📦 创建 Casdoor 数据库..." -ForegroundColor Cyan
docker exec -i app-postgres psql -U app_owner -d app_db -f /docker-entrypoint-initdb.d/03-casdoor-db.sql 2>$null
if ($LASTEXITCODE -ne 0) {
    # 如果挂载失败，尝试直接执行
 docker exec -i app-postgres psql -U app_owner -d app_db
}
Write-Host "✅ Casdoor 数据库创建完成" -ForegroundColor Green

# 3. 执行 Dbmate migration
Write-Host ""
Write-Host "🗄️  执行 Dbmate migration..." -ForegroundColor Cyan

# 检查 dbmate 是否安装
$dbmate = Get-Command dbmate -ErrorAction SilentlyContinue
if (-not $dbmate) {
    Write-Host "⚠️  dbmate 未安装，尝试通过 Docker 运行..." -ForegroundColor Yellow
    docker run --rm -v "$ProjectRoot\db:/db" --network=app-net amacneil/dbmate up
} else {
    Set-Location "$ProjectRoot\db"
    dbmate up
}
Write-Host "✅ Migration 执行完成" -ForegroundColor Green

# 4. 验证
Write-Host ""
Write-Host "🔍 验证数据库..." -ForegroundColor Cyan
$tables = docker exec app-postgres psql -U app_owner -d app_db -c "\dt" 2>$null
Write-Host $tables

Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "  数据库初始化完成！" -ForegroundColor Green
Write-Host "========================================" -ForegroundColor Cyan
```

### 4.4 scripts/init-db.sh（Linux/macOS 数据库初始化）

```bash
#!/bin/bash
# ==============================================================================
# 数据库初始化脚本（Linux/macOS）
# ==============================================================================

set -e
PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

echo -e "\033[36m========================================\033[0m"
echo -e "\033[36m  数据库初始化\033[0m"
echo -e "\033[36m========================================\033[0m"

# 1. 等待 PG 就绪
echo ""
echo -e "\033[33m⏳ 等待 PostgreSQL 就绪...\033[0m"
retries=0
until docker exec app-postgres pg_isready -U app_owner -d app_db &>/dev/null; do
    sleep 5
    retries=$((retries + 1))
    if [ $retries -ge 12 ]; then
        echo -e "\033[31m❌ PostgreSQL 未就绪\033[0m"
        exit 1
    fi
done
echo -e "\033[32m✅ PostgreSQL 就绪\033[0m"

# 2. 创建 Casdoor 数据库
echo ""
echo -e "\033[36m📦 创建 Casdoor 数据库...\033[0m"
 docker exec -i app-postgres psql -U app_owner -d app_db
echo -e "\033[32m✅ Casdoor 数据库创建完成\033[0m"

# 3. 执行 Dbmate migration
echo ""
echo -e "\033[36m🗄️  执行 Dbmate migration...\033[0m"
cd "$PROJECT_ROOT/db"

if command -v dbmate &>/dev/null; then
    dbmate up
else
    echo -e "\033[33m⚠️  dbmate 未安装，通过 Docker 运行...\033[0m"
    docker run --rm -v "$PROJECT_ROOT/db:/db" --network=app-net amacneil/dbmate up
fi
echo -e "\033[32m✅ Migration 执行完成\033[0m"

# 4. 验证
echo ""
echo -e "\033[36m🔍 验证数据库...\033[0m"
docker exec app-postgres psql -U app_owner -d app_db -c "\dt"

echo ""
echo -e "\033[36m========================================\033[0m"
echo -e "\033[32m  数据库初始化完成！\033[0m"
echo -e "\033[36m========================================\033[0m"
```

### 4.5 scripts/health-check.ps1（健康检查）

```powershell
# ==============================================================================
# 健康检查脚本（Windows）
# 用法：.\scripts\health-check.ps1
# ==============================================================================

$ErrorActionPreference = "SilentlyContinue"

Write-Host "========================================" -ForegroundColor Cyan
Write-Host "  全栈健康检查" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan

$services = @(
    @{ Name = "postgres"; Port = 5432; Check = { docker exec app-postgres pg_isready -U app_owner -d app_db } },
    @{ Name = "pgbouncer"; Port = 5433; Check = { docker exec app-pgbouncer psql -h localhost -p 6432 -U pgadmin pgbouncer -c "SHOW VERSION;" } },
    @{ Name = "etcd"; Port = 2379; Check = { docker exec app-etcd etcdctl endpoint health } },
    @{ Name = "apisix"; Port = 9080; Check = { Invoke-WebRequest -Uri "http://localhost:9080/apisix/status" -UseBasicParsing } },
    @{ Name = "postgrest"; Port = 3000; Check = { Invoke-WebRequest -Uri "http://localhost:3000/" -UseBasicParsing } },
    @{ Name = "casdoor"; Port = 8000; Check = { Invoke-WebRequest -Uri "http://localhost:8000/api/health" -UseBasicParsing } },
    @{ Name = "swagger"; Port = 8080; Check = { Invoke-WebRequest -Uri "http://localhost:8080/" -UseBasicParsing } },
 Select-String "listening" } }
)

$passed = 0
$failed = 0

foreach ($svc in $services) {
    Write-Host ""
    Write-Host "🔍 检查 $($svc.Name)..." -ForegroundColor Yellow
    try {
        $result = & $svc.Check
        if ($result) {
            Write-Host "  ✅ $($svc.Name) 正常" -ForegroundColor Green
            $passed++
        } else {
            Write-Host "  ❌ $($svc.Name) 异常" -ForegroundColor Red
            $failed++
        }
    } catch {
        Write-Host "  ❌ $($svc.Name) 异常: $_" -ForegroundColor Red
        $failed++
    }
}

Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "  检查结果：$passed 通过 / $failed 失败" -ForegroundColor $(if ($failed -eq 0) { "Green" } else { "Red" })
Write-Host "========================================" -ForegroundColor Cyan

if ($failed -gt 0) {
    Write-Host ""
    Write-Host "📋 查看日志：" -ForegroundColor Yellow
    Write-Host "  docker compose logs -f [service-name]" -ForegroundColor White
}
```

### 4.6 scripts/stop.ps1（停机/清理脚本 — [修复 P2-4]）

```powershell
# ==============================================================================
# 停机/清理脚本（Windows PowerShell）
# 用法：.\scripts\stop.ps1           — 停止服务（保留数据卷）
#       .\scripts\stop.ps1 -Reset    — 停止并删除数据卷（完全重置）
# ==============================================================================

param([switch]$Reset)

$ErrorActionPreference = "Stop"
$ProjectRoot = Split-Path -Parent $PSScriptRoot
Set-Location $ProjectRoot

if ($Reset) {
    Write-Host "⚠️  完全重置：停止服务并删除数据卷..." -ForegroundColor Yellow
    docker compose down -v
    Write-Host "✅ 重置完成。下次启动将重新初始化数据库。" -ForegroundColor Green
} else {
    Write-Host "🛑 停止所有服务..." -ForegroundColor Yellow
    docker compose down
    Write-Host "✅ 服务已停止（数据卷保留）" -ForegroundColor Green
}
```

---

## 5. 端口规划

 组件 | 用途 | 协议 |
:---|:---|:---|
 PostgreSQL | 数据库直连（开发调试） | TCP |
 Pgbouncer | 数据库连接池 | TCP |
 PostgREST | RESTful API | HTTP |
 APISIX | API 网关（数据面） | HTTP |
 APISIX | API 网关（数据面） | HTTPS |
 APISIX | Admin API（控制面） | HTTP |
 etcd | APISIX 配置存储 | HTTP |
 Casdoor | OAuth/IAM 认证 | HTTP |
 Swagger UI | API 文档 | HTTP |
 Vite Dev Server | 前端开发服务器 | HTTP |

---

## 6. 启动流程

### 6.1 首次启动

```powershell
# 1. 克隆项目（如果还没有）
cd "D:\WeChat Files\xiangmu"
git clone <repo-url> 源码
cd 源码

# 2. 复制环境变量
Copy-Item .env.example .env

# 3. 编辑 .env（修改默认密码）
notepad .env

# 4. 一键启动
.\scripts\start.ps1

# 5. 初始化数据库
.\scripts\init-db.ps1

# 6. 验证
.\scripts\health-check.ps1
```

### 6.2 日常启动

```powershell
# 启动所有服务
docker compose up -d

# 查看状态
docker compose ps

# 查看日志
docker compose logs -f postgrest
```

### 6.3 停止和清理

```powershell
# 停止服务（保留数据）
docker compose down

# 停止并删除数据卷（完全重置）
docker compose down -v

# 重启单个服务
docker compose restart postgrest
```

---

## 7. 常见问题排查

 原因 | 解决方案 |
:---|:---|
 本地已占用端口 | 修改 `.env` 中的端口映射 |
 pg_data 卷权限问题 | `docker compose down -v` 后重启 |
 userlist.txt 密码不匹配 | 确认 `.env` 与 `userlist.txt` 密码一致 |
 casdoor 数据库不存在 | 执行 `.\scripts\init-db.ps1` |
 JWT secret 不匹配 | 确认 `.env` 中 `JWKS_JSON` 正确 |
 etcd 未就绪 | 等待 etcd healthy 后重试 |
 Go 依赖下载失败 | 检查网络，或本地预编译 |
 反斜杠 vs 正斜杠 | 所有路径使用 `/` 或 `\\` |

---

## 8. 与生产环境的差异

 开发环境（本文档） | 生产环境（Pigsty） |
:---|:---|
 单容器 `pgcharles/pgtap:18` | Patroni ×3 HA + Pgbouncer |
 单节点 Docker | Pigsty etcd ×3 |
 Docker 单实例 | Pigsty Docker 模块 |
 Docker 单实例 | Pigsty Docker 模块 |
 Docker 直连 PG | Pigsty Docker 模块 |
 Docker 单实例 | Pigsty Docker 模块（多实例选主） |
 未包含 | Pigsty 内置 |
 未包含 | Pigsty 内置 |
 无 | Grafana + VictoriaMetrics |
 无 | pgBackRest PITR |
 无 | HAProxy 终止 SSL |

---

## 9. 验收清单

 验收项 | 验证命令 | 预期 | 通过 |
:---|:---|:---|:---:|
 所有容器运行 | `docker compose ps` | 8 个容器 running | ☐ |
 PostgreSQL 健康 | `docker exec app-postgres pg_isready` | accepting connections | ☐ |
 Pgbouncer 可连接 | `docker exec app-pgbouncer psql -h localhost -p 6432 -U pgadmin pgbouncer -c "SHOW VERSION;"` | 返回版本号 | ☐ |
 etcd 健康 | `docker exec app-etcd etcdctl endpoint health` | is healthy | ☐ |
 APISIX 状态 | `curl http://localhost:9080/apisix/status` | 200 | ☐ |
 PostgREST 响应 | `Invoke-WebRequest http://localhost:3000/` | 200 + OpenAPI JSON | ☐ |
 Casdoor 健康 | `Invoke-WebRequest http://localhost:8000/api/health` | `{"status":"ok"}` | ☐ |
 Swagger UI | 浏览器打开 `http://localhost:8080` | 显示 API 文档 | ☐ |
 Syncer 运行 | `docker logs policy-syncer --tail=10` | 含 "listening" | ☐ |
 网络互通 | `docker exec app-postgrest curl -s http://apisix:9080/apisix/status` | 200 | ☐ |

> **通过标准：** 10/10 项全部打勾。

---

## 10. 下一步

完成本文档后，Agent 可以：

1. ✅ 执行 `02-数据库建模` 中的 DDL 和函数创建
2. ✅ 执行 `03-API与认证层` 中的 PostgREST 配置
3. ✅ 执行 `04-网关与同步器` 中的 APISIX 路由配置
4. ✅ 执行 `04.5-Casdoor集成` 中的 Casdoor 应用配置
5. ✅ 执行 `05-前端Admin` 中的 ART-D Pro 适配

---

**✅ 阶段完成标志：** 验收清单 D1-D10 全部打勾通过。
**➡ 下一阶段：** `02-数据库建模`（执行 migration 文件）