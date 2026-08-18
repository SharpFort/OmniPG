# OmniPG CI/CD 方案设计文档

> **版本**: v2.0  
> **创建日期**: 2026-07-24  
> **更新日期**: 2026-07-25  
> **状态**: 规划定稿，待实施  
> **变更**: 基于审查结果全面优化

---

## 一、决策汇总

| # | 决策项 | 结论 |
|:---|:---|:---|
| 1 | 部署拓扑 | Phase 1 单机 → Phase 2 分离 |
| 2 | 代码管理 | 单一仓库 (Monorepo)，目录分离 |
| 3 | 数据库迁移 | dbmate + 幂等源码 (apply-src.sh) |
| 4 | Redis 部署 | **Pigsty 统一管理**（Phase 1 WSL2 / Phase 2 Docker 模块），Docker Compose 不单独部署 Redis |
| 5 | 目录重组 | 完全重组 (db/gateway/infra) |
| 6 | Syncer 部署 | 与后端同目录 (`db/syncer/`)，**部署在 DB 服务器**，支持 Docker 和 Systemd 二进制运行 |
| 7 | VIBE 模块 | 配置预留，**部署在 DB 服务器**，暂不部署 |
| 8 | CI/CD 触发 | 路径过滤 + 手动部署 |
| 9 | 密钥管理 | **三层架构：本地 `.env` → CI GitHub Secrets → 服务器环境变量** |
| 10 | 基础组件 | Pigsty 统一管理 PostgreSQL/pgBouncer/Redis/etcd/Docker，DB 和网关服务器均需安装 Pigsty |

---

## 二、基础设施文件详解

### 2.1 infra/ 目录文件清单

| 文件 | 是否必须 | 作用 | 更新频率 |
|:---|:---|:---|:---|
| `pigsty.yml` | ✅ 必须 | Phase 1 单机完整配置（PostgreSQL、pgBocker、Redis、etcd、Grafana、VictoriaMetrics、Docker、VIBE） | 仅在基础设施变更时 |
| `pigsty.db.yml` | ✅ 必须 | Phase 2 DB 服务器配置（含全量 INFRA 模块用于监控） | 仅在基础设施变更时 |
| `pigsty.gateway.yml` | ✅ 必须 | Phase 2 网关服务器配置（Docker + Redis），VIBE 部署在 DB 服务器 | 仅在基础设施变更时 |
| `pg_hba.conf` | ✅ 必须 | PostgreSQL 客户端认证规则（scram-sha-256 + Docker 网桥 + 内网） | 新增网络段时 |
| `pgbouncer.ini` | ✅ 必须 | pgBouncer 连接池配置（认证方式、池化模式、数据库路由） | 新增数据库时 |
| `redis.conf` | ✅ 必须 | Redis 服务端配置（绑定地址、持久化、内存策略） | 调整性能参数时 |
| `userlist.txt` | ✅ 必须 | pgBouncer 认证用户列表（存储 3-5 个用户密码） | 新增用户或改密码时 |

### 2.2 各配置文件详细说明

#### pig_hba.conf — PostgreSQL 客户端认证

```
作用：控制"谁"可以从"哪里"用什么"方式"连接 PostgreSQL
内容：
  - 本地 peer 认证（Unix socket）
  - 本地 TCP scram-sha-256
  - Docker 网桥 172.17.0.0/16
  - Docker app-net 172.20.0.0/16
  - 内网 10.0.0.0/8（Phase 2）
为什么需要：Pigsty 默认模板可能不包含 Docker 网桥网段，必须自定义
```

#### pgbouncer.ini — 连接池配置

```
作用：定义 pgBouncer 的监听方式、认证方法、数据库路由、池化参数
关键配置：
  - [databases] 段：定义数据库连接串（app_db, casdoor）
  - auth_type = scram-sha-256（必须与 pg_hba.conf 一致）
  - auth_file = /etc/pgbouncer/userlist.txt
  - pool_mode = session（或 transaction）
  - listen_addr = 0.0.0.0（允许 Docker 访问）
为什么需要：Pigsty 默认配置可能使用 md5 认证，且数据库路由需自定义
```

#### redis.conf — Redis 服务端配置

```
作用：定义 Redis 的监听地址、端口、持久化、内存限制
关键配置：
  - bind 127.0.0.1（生产）或 0.0.0.0（开发，允许 Docker 访问）
  - port 6379
  - appendonly yes（AOF 持久化）
  - maxmemory 256mb
  - maxmemory-policy allkeys-lru
为什么需要：Pigsty 默认配置可能不开启 AOF，且 Docker 需要主机 Redis 监听 0.0.0.0
```

#### userlist.txt — pgBouncer 用户列表

```
作用：pgBouncer 的认证数据库，存储"用户名 → 密码"映射
格式：每行一个用户 "username" "password"
用户列表（3-5 个）：
  - app_owner：应用主账号（CREATEDB 权限）
  - authenticator：PostgREST 认证角色
  - casdoor：Casdoor 数据库账号
  - web_anon：PostgREST 匿名角色（NOLOGIN，仅注释说明）
更新频率：极低，只在新增用户或修改密码时
为什么需要：pgBouncer scram-sha-256 模式必须指定 userlist.txt，存明文密码即可
```

### 2.3 基础设施与脚本的调用关系

```
┌──────────────────────────────────────────────────────────────────────┐
│                        基础设施部署调用关系                            │
│                                                                      │
│  ┌─────────────────┐                                                 │
│  │  deploy-infra.sh │ ← 一键部署基础设施（首次/全量）                  │
│  └────────┬────────┘                                                 │
│           │                                                          │
│           ├─→ ① 检测 Pigsty 是否安装，未安装则下载 v4.4.0            │
│           ├─→ ② 复制 infra/pigsty.yml → ~/pigsty/pigsty.yml          │
│           ├─→ ③ 复制 infra/pg_hba.conf → 覆盖 Pigsty 配置            │
│           ├─→ ④ 复制 infra/pgbouncer.ini → /etc/pgbouncer/           │
│           ├─→ ⑤ 复制 infra/redis.conf → /etc/redis/                  │
│           ├─→ ⑥ 复制 infra/userlist.txt → /etc/pgbouncer/            │
│           ├─→ ⑦ 执行 ~/pigsty/deploy.yml（部署所有 PG/Redis/etcd）   │
│           ├─→ ⑧ 执行 ~/pigsty/etcd.yml（部署 etcd 集群）             │
│           └─→ ⑨ 验证所有服务健康状态                                 │
│                                                                      │
│  Phase 2 时：                                                        │
│  deploy-infra.sh db      → 调用 infra/pigsty.db.yml                  │
│  deploy-infra.sh gateway → 调用 infra/pigsty.gateway.yml             │
└──────────────────────────────────────────────────────────────────────┘
```

---

## 三、目录结构设计

### 3.1 重组后完整结构

```
OmniPG/
├── .github/
│   └── workflows/
│       ├── ci.yml                           # PR 触发：路径过滤检查
│       ├── deploy-db-staging.yml            # 手动触发：DB 部署到 Staging
│       ├── deploy-db-production.yml         # 手动触发：DB 部署到 Production
│       ├── deploy-gateway-staging.yml       # 手动触发：网关部署到 Staging
│       └── deploy-gateway-production.yml    # 手动触发：网关部署到 Production
│
├── db/                                      # 后端代码（迁移 + 幂等源码）
│   ├── migrations/                          # dbmate 版本化迁移
│   │   ├── sys/001_init_tables.sql
│   │   ├── sys/002_create_relation_sessions_blacklist.sql
│   │   └── .dbmate.toml
│   ├── src/                                 # 幂等源码 (CREATE OR REPLACE)
│   │   ├── sys/
│   │   │   ├── functions/
│   │   │   ├── triggers/
│   │   │   ├── privileges/
│   │   │   └── views/
│   │   ├── sales/
│   │   ├── inventory/
│   │   └── public/
│   ├── api_v1/                              # PostgREST API Schema
│   │   ├── sys/
│   │   ├── sales/
│   │   └── inventory/
│   ├── init/                                # 一次性初始化
│   │   ├── 01-extensions.sql
│   │   ├── 02-schemas.sql
│   │   └── 03-casdoor-db.sql
│   ├── fixtures/                            # 测试数据
│   ├── extensions/                          # PG 扩展清单
│   ├── tests/                               # pgTAP 测试
│   ├── syncer/                              # Policy Syncer (Go)
│   │   ├── Dockerfile
│   │   ├── go.mod
│   │   ├── cmd/
│   │   │   └── main.go
│   │   ├── internal/
│   │   │   ├── syncer/
│   │   │   ├── apisix/
│   │   │   └── database/
│   │   └── bin/                             # 编译后的二进制输出目录
│   ├── schema.sql                           # 全量 schema (参考)
│   └── .dbmate.toml
│
├── gateway/                                 # 网关代码
│   ├── docker-compose.yml                   # 容器编排
│   ├── .env.example                         # 网关环境变量模板（从根目录复制）
│   ├── apisix/                              # APISIX 配置
│   │   ├── config.yaml
│   │   ├── apisix.yaml
│   │   ├── casbin_model.conf
│   │   └── jwks_route.yaml
│   └── postgrest/                           # PostgREST 配置 (可选)
│       └── postgrest.conf
│
├── infra/                                   # Pigsty 基础设施
│   ├── pigsty.yml                           # Phase 1: 完整配置（单机）
│   ├── pigsty.db.yml                        # Phase 2: DB 服务器配置
│   ├── pigsty.gateway.yml                   # Phase 2: 网关服务器配置
│   ├── pg_hba.conf                          # PG 客户端认证规则
│   ├── pgbouncer.ini                        # pgBouncer 连接池配置
│   ├── redis.conf                           # Redis 服务端配置
│   └── userlist.txt                         # pgBouncer 用户列表
│
├── scripts/                                 # 部署脚本
│   ├── deploy-infra.sh                      # 一键部署基础设施（Pigsty + 配置同步）
│   ├── deploy-db.sh                         # 数据库迁移 + 幂等源码
│   ├── deploy-gateway.sh                    # 网关 Docker Compose 部署
│   ├── deploy-all.sh                        # 测试环境一键部署（编排以上三个脚本）
│   ├── apply-src.sh                         # 幂等源码刷入
│   ├── migrate.sh                           # 数据库迁移快捷入口
│   ├── setup_apisix.sh                      # APISIX 路由初始化
│   ├── e2e-test.sh                          # 端到端验收测试
│   ├── start.sh                             # 开发环境一键启动
│   └── stop.sh                              # 开发环境一键停止
│
├── docs/                                    # 文档
│   ├── 配置说明文档.md
│   ├── ci-cd-方案.md                        # 本文档
│   └── 部署手册.md
│
├── .env.development
├── .env.staging
├── .env.production
├── .gitignore
└── Makefile
```

### 3.2 目录职责说明

| 目录 | 部署目标 | 运行方式 | 说明 |
|:---|:---|:---|:---|
| `db/migrations/` | PostgreSQL | dbmate up | 版本化迁移，不可逆 |
| `db/src/` | PostgreSQL | apply-src.sh | 幂等源码，可重复执行 |
| `db/api_v1/` | PostgreSQL | PostgREST 自动暴露 | API 层函数/视图 |
| `db/init/` | PostgreSQL | 手动执行一次 | 初始化扩展/Schema |
| `db/syncer/` | Docker 或 Systemd | 二进制/Docker | 策略同步器（Go 编译为二进制） |
| `gateway/` | Docker Compose | docker-compose up | 所有 Docker 服务 |
| `infra/` | 宿主机 (Pigsty) | Ansible (deploy.yml) | 基础设施配置 |

### 3.3 当前仓库迁移对照

| 当前位置 | 目标位置 | 操作 |
|:---|:---|:---|
| `deploy/pigsty.yml` | `infra/pigsty.yml` | 移动 |
| `deploy/pg_hba.conf` | `infra/pg_hba.conf` | 移动 |
| `deploy/pgbouncer.ini` | `infra/pgbouncer.ini` | 移动 |
| `deploy/redis.conf` | `infra/redis.conf` | 移动 |
| `deploy/userlist.txt` | `infra/userlist.txt` | 移动 |
| `deploy/postgresql.conf` | `infra/postgresql.conf` | 移动（可选，Pigsty 默认配置） |
| `syncer/` | `db/syncer/` | 移动 |
| `docker-compose.yml` | `gateway/docker-compose.yml` | 移动 |
| `apisix/` | `gateway/apisix/` | 移动 |
| `postgrest/` | `gateway/postgrest/` | 移动 |
| `infra/pigsty.db.yml` | 不变 | — |
| `infra/pigsty.gateway.yml` | 不变 | — |

---

## 四、部署脚本详解

### 4.1 脚本清单与职责

| 脚本 | 职责 | 调用对象 | 运行环境 |
|:---|:---|:---|:---|
| `deploy-infra.sh` | Pigsty 安装 + 配置同步 + 基础设施部署 | `infra/` 全部文件 | 宿主机 |
| `deploy-db.sh` | 数据库迁移 + 幂等源码 + 验证 | `db/` 全部文件 | 宿主机或 CI |
| `deploy-gateway.sh` | Docker Compose 部署 + 健康检查 | `gateway/` 全部文件 | 宿主机或 CI |
| `deploy-all.sh` | 一键编排：infra → db → gateway | 以上三个脚本 | 测试环境 |
| `apply-src.sh` | 遍历 `db/src/*.sql` 并刷入数据库 | `db/src/` | 被 deploy-db.sh 调用 |
| `migrate.sh` | 快捷入口：封装 dbmate 命令 | `db/migrations/` | 本地开发 |
| `setup_apisix.sh` | 初始化 APISIX 路由和插件 | `gateway/apisix/` | 首次部署后 |
| `e2e-test.sh` | 端到端验收测试 | 全部服务 | CI |

### 4.2 各脚本详细分析

#### deploy-infra.sh（新增）

```bash
#!/bin/bash
# =============================================================================
# 基础设施部署脚本
# 用法: 
#   首次部署: ./scripts/deploy-infra.sh <environment>
#   Phase 2 DB: ./scripts/deploy-infra.sh db <environment>
#   Phase 2 GW: ./scripts/deploy-infra.sh gateway <environment>
# 示例: ./scripts/deploy-infra.sh development
# =============================================================================

# 执行流程:
# 1. 检测 WSL2 / Linux 环境
# 2. 检测 Pigsty 是否已安装（~/pigsty/ 目录是否存在）
#    - 未安装: curl -fsSL https://pigsty.cc/get | bash -s v4.4.0
#    - 已安装: 检查版本是否匹配 v4.4.0
# 3. 复制配置文件到 Pigsty 目录
#    - cp infra/pigsty.yml ~/pigsty/pigsty.yml
#    - cp infra/pg_hba.conf ~/pigsty/pg_hba.conf  
#    - cp infra/pgbouncer.ini /etc/pgbouncer/pgbouncer.ini
#    - cp infra/redis.conf /etc/redis/redis.conf
#    - cp infra/userlist.txt /etc/pgbouncer/userlist.txt
# 4. 执行 Pigsty 部署
#    - cd ~/pigsty && ./deploy.yml
#    - cd ~/pigsty && ./etcd.yml
# 5. 验证服务健康
#    - PostgreSQL: psql -h 127.0.0.1 -U app_owner -d app_db -c "SELECT 1"
#    - pgBouncer: psql -h 127.0.0.1 -p 6432 -U app_owner -d app_db -c "SELECT 1"
#    - Redis: redis-cli ping
#    - etcd: curl -sk https://127.0.0.1:2379/health
```

**关键设计决策**：
- **幂等性**：可以重复执行。如果 Pigsty 已安装且版本正确，则跳过安装
- **配置覆盖**：每次执行都会同步最新配置，确保基础设施状态一致
- **Phase 2 支持**：通过参数指定部署模式
  - `deploy-infra.sh db` → 使用 `infra/pigsty.db.yml`，复制 `pg_hba.conf`、`pgbouncer.ini`、`userlist.txt`、`redis.conf`
  - `deploy-infra.sh gateway` → 使用 `infra/pigsty.gateway.yml`，仅 Docker 模块，**不复制** pg_hba/pgbouncer/userlist
  - `deploy-infra.sh`（无参数）→ 默认单机模式，使用 `infra/pigsty.yml`

#### deploy-db.sh

```bash
#!/bin/bash
# =============================================================================
# 数据库部署脚本
# 用法: ./scripts/deploy-db.sh <environment>
# 依赖: deploy-infra.sh 必须先执行（确保 PostgreSQL 已就绪）
# 前提: 目标服务器已安装 dbmate（安装方式见下文）
# =============================================================================

# 执行流程:
# 1. 加载 .env.<environment> 环境变量
# 2. 设置 DBMATE_DATABASE_URL
# 3. cd db/
# 4. dbmate up          ← 应用版本化迁移
# 5. bash apply-src.sh  ← 刷入幂等源码
# 6. dbmate status      ← 验证迁移状态

# 设计决策:
# - 不负责 Pigsty 安装（由 deploy-infra.sh 负责）
# - 仅处理数据库层面的变更
# - 可被 CI/CD 独立调用（当仅 db/ 变更时）
```

**dbmate 安装说明：**

```
dbmate 需要在目标服务器上安装。
安装方式（二选一）：
  1. 通过 Pigsty DOCKER 模块部署（推荐 Phase 2）
  2. 直接下载二进制：
     curl -fsSL https://github.com/amacneil/dbmate/releases/latest/download/dbmate-linux-amd64 -o /usr/local/bin/dbmate
     chmod +x /usr/local/bin/dbmate
```

#### deploy-gateway.sh

```bash
#!/bin/bash
# =============================================================================
# 网关部署脚本
# 用法: ./scripts/deploy-gateway.sh <environment>
# =============================================================================

# 执行流程:
# 1. cd gateway/
# 2. 复制 .env.<environment> → .env
# 3. docker compose pull   ← 拉取最新镜像
# 4. docker compose down   ← 停止旧容器
# 5. docker compose up -d  ← 启动新容器
# 6. sleep 15              ← 等待服务就绪
# 7. 健康检查（APISIX/PostgREST/Casdoor/Syncer/Swagger）

# 设计决策:
# - 不负责 APISIX 路由初始化（由 setup_apisix.sh 负责）
# - 使用 down + up 确保干净状态（避免残留数据）
# - 健康检查失败时返回非零退出码，供 CI/CD 捕获
```

#### apply-src.sh

```bash
#!/bin/bash
# =============================================================================
# 幂等源码刷入脚本
# 用法: ./scripts/apply-src.sh <database_url>
# 被调用: deploy-db.sh 内部
# =============================================================================

# 执行流程:
# 1. 遍历 db/src/ 下所有 *.sql 文件（按字母顺序）
# 2. 逐个执行 psql $DB_URL -v ON_ERROR_STOP=1 -f $file
# 3. 全部成功则输出 "All src files applied successfully"

# 幂等性保证:
# - 所有 SQL 使用 CREATE OR REPLACE（函数/视图/触发器）
# - 所有 SQL 使用 IF NOT EXISTS（权限/索引）
# - 可重复执行，不会报错
```

#### deploy-all.sh（新增）

```bash
#!/bin/bash
# =============================================================================
# 测试环境一键部署脚本
# 用法: ./scripts/deploy-all.sh <environment>
# 功能: 编排 deploy-infra.sh → deploy-db.sh → deploy-gateway.sh → setup_apisix.sh
# =============================================================================

# 执行流程:
# 1. deploy-infra.sh $ENV     ← 检查/安装 Pigsty + 同步配置
# 2. deploy-db.sh $ENV        ← 数据库迁移 + 幂等源码
# 3. deploy-gateway.sh $ENV   ← Docker Compose 部署
# 4. setup_apisix.sh           ← APISIX 路由初始化
# 5. e2e-test.sh              ← 端到端验收测试

# 幂等性:
# - 每个子脚本都支持幂等，可安全重复执行
# - 如果某步骤已完成，会自动跳过或快速通过
# 适用场景:
# - ⚠️ 仅适用于 Phase 1 单机环境（DB + 网关在同一服务器）
# - WSL2 开发环境初始化
# - 测试服务器重建
# - 灾难恢复
# Phase 2 分离环境请分别执行 deploy-infra.sh db / gateway + deploy-db.sh + deploy-gateway.sh
```

### 4.3 完整部署文件调用图

```
┌──────────────────────────────────────────────────────────────────────────────────┐
│                                    开发环境                                       │
│                                                                                  │
│   ┌──────────────────────────────────────────────────────────────────────────┐   │
│   │                          deploy-all.sh                                    │   │
│   │                        (一键部署编排)                                     │   │
│   └────────┬─────────────────┬─────────────────┬─────────────────┬───────────┘   │
│            │                 │                 │                 │               │
│            ▼                 ▼                 ▼                 ▼               │
│   ┌───────────────┐ ┌───────────────┐ ┌───────────────┐ ┌───────────────┐       │
│   │deploy-infra.sh│ │ deploy-db.sh  │ │deploy-gw.sh   │ │ setup_apisix  │       │
│   └───────┬───────┘ └───────┬───────┘ └───────┬───────┘ └───────────────┘       │
│           │                 │                 │                                 │
│           ├→ infra/         ├→ db/            ├→ gateway/                       │
│           │  pigsty.yml     │  migrations/    │  docker-compose.yml             │
│           │  pg_hba.conf    │  src/           │  apisix/                         │
│           │  pgbouncer.ini  │  api_v1/        │  postgrest/                      │
│           │  redis.conf     │  init/          │  .env.example                    │
│           │  userlist.txt   │                 │                                 │
│           │                 │                 │                                 │
│           ├→ ~/pigsty/      ├→ dbmate up     ├→ docker compose pull            │
│           │  ./deploy.yml   ├→ apply-src.sh  ├→ docker compose down            │
│           │  ./etcd.yml     │   (遍历 *.sql)  └→ docker compose up -d           │
│           │                 └→ psql 刷入                                        │
│           │                                                                     │
│           └→ 启动 PostgreSQL / pgBouncer / Redis / etcd / Grafana              │
│                                                                                  │
└──────────────────────────────────────────────────────────────────────────────────┘

┌──────────────────────────────────────────────────────────────────────────────────┐
│                                    生产环境                                       │
│                                                                                  │
│   ┌──────────────────────────────────────────────────────────────────────────┐   │
│   │                      GitHub Actions Workflows                             │   │
│   │                                                                            │   │
│   │  ┌─────────────┐  ┌─────────────┐  ┌─────────────┐  ┌─────────────┐     │   │
│   │  │ deploy-db-  │  │ deploy-db-  │  │deploy-gw-   │  │deploy-gw-   │     │   │
│   │  │ staging     │  │ production  │  │staging      │  │production   │     │   │
│   │  │ (手动触发)  │  │ (手动触发)  │  │ (手动触发)  │  │ (手动触发)  │     │   │
│   │  └──────┬──────┘  └──────┬──────┘  └──────┬──────┘  └──────┬──────┘     │   │
│   │         │                │                │                │              │   │
│   │         ▼                ▼                ▼                ▼              │   │
│   │    SSH → DB Server   SSH → DB Server  SSH → GW Server  SSH → GW Server   │   │
│   │    deploy-db.sh      deploy-db.sh     deploy-gw.sh      deploy-gw.sh      │   │
│   └──────────────────────────────────────────────────────────────────────────┘   │
│                                                                                  │
│   注: 生产环境 deploy-infra.sh 不通过 CI 触发，而是手动预先在各服务器上执行        │
│                                                                                  │
└──────────────────────────────────────────────────────────────────────────────────┘
```

### 4.4 部署触发策略

| 环境 | 触发方式 | 目标 | 说明 |
|:---|:---|:---|:---|
| **开发环境 (WSL2)** | 本地执行 `deploy-all.sh` | 全部组件 | 开发者手动触发，一键完成 |
| **测试/Staging** | GitHub Actions `workflow_dispatch` | DB 或网关分离部署 | 手动选择环境后触发 |
| **生产环境** | GitHub Actions `workflow_dispatch` | DB 或网关分离部署 | 手动选择环境后触发，需审批 |
| **基础设施首次** | 手动执行 `deploy-infra.sh` | 服务器基础环境 | 新服务器上手动执行一次 |

---

## 五、CI/CD 流水线设计

### 5.1 CI Pipeline (ci.yml)

**触发条件**: PR 到 dev 或 main 分支

| 路径 | 触发的检查 |
|:---|:---|
| `db/migrations/**` | SQL Lint + dbmate dry-run + pgTAP tests |
| `db/src/**` | SQL Lint + apply-src.sh dry-run |
| `db/syncer/**` | Go build + Go test |
| `gateway/**` | Docker Compose validate + Docker build |
| `infra/**` | YAML lint + Pigsty config validate |

### 5.2 Deploy Pipeline (手动触发)

**触发方式**: `workflow_dispatch` (GitHub UI 手动点击)

**输入参数**:

| 参数 | 类型 | 默认值 | 说明 |
|:---|:---|:---|:---|
| `environment` | choice | staging | 部署环境 (staging/production) |
| `migration_only` | boolean | false | 仅执行数据库迁移 |
| `skip_tests` | boolean | false | 跳过 E2E 测试 |

### 5.3 GitHub Actions Workflow 文件清单

```
.github/workflows/
├── ci.yml                           # PR 触发：路径过滤检查
├── deploy-db.yml                    # 手动触发：DB 部署（environment: staging/production）
├── deploy-gateway.yml               # 手动触发：网关部署（environment: staging/production）
├── deploy-infra.yml                 # 手动触发：基础设施部署（mode: all/db/gateway）
└── deploy-all.yml                   # 手动触发：一键部署（编排以上三个脚本）
```

### 5.4 Phase 3 简化说明（实际实施 vs 原始文档差异）

#### 差异对比

| 文档方案（原始规划） | 实际方案（实施） |
|:---|:---|
| 4 个 deploy workflow（staging/production 分离） | 3 个 deploy workflow（通过 `environment` 参数选择环境） |
| `deploy-db-staging.yml` + `deploy-db-production.yml` | `deploy-db.yml`（带 `environment` 输入，可选 staging/production） |
| `deploy-gateway-staging.yml` + `deploy-gateway-production.yml` | `deploy-gateway.yml`（带 `environment` 输入，可选 staging/production） |
| — | 额外创建 `deploy-infra.yml`（基础设施部署） |
| — | 额外创建 `deploy-all.yml`（一键部署编排） |

#### 简化理由

1. **GitHub Actions 原生支持环境管理**
   - `environment` 字段支持 staging/production 分离
   - 每个 environment 可配置独立的 Secrets、保护规则、审批人
   - 避免重复代码，符合 DRY 原则

2. **减少文件数量**
   - 原始方案：4 个 deploy workflow（每个环境一个）
   - 实际方案：3 个 deploy workflow（environment 参数化）
   - 文件减少 25%，维护成本降低

3. **环境差异通过 Secrets 管理**
   - staging 和 production 使用相同的脚本和 workflow
   - 差异仅在于 GitHub Secrets（`DB_SERVER_HOST`、`SSH_PRIVATE_KEY` 等）
   - 环境切换只需选择 `environment` 参数，无需切换文件

4. **新增 workflow 的合理性**
   - `deploy-infra.sh`：Pigsty 基础设施部署是独立职责，应独立触发
   - `deploy-all.sh`：测试环境一键部署（Phase 1 单机），提高开发效率

#### deploy-db.yml 实际结构

```yaml
name: Deploy Database
on:
  workflow_dispatch:
    inputs:
      environment:
        type: choice
        options: [staging, production]
      migration_only:
        type: boolean
        default: false
jobs:
  deploy:
    environment: ${{ inputs.environment }}
    steps:
      - uses: actions/checkout@v4
      - uses: webfactory/ssh-agent@v0.9.0
        with: { ssh-private-key: ${{ secrets.SSH_PRIVATE_KEY }} }
      - name: Deploy
        run: ssh ... "cd OmniPG && bash scripts/deploy-db.sh ${{ inputs.environment }}"
      - name: Verify
        run: ssh ... "cd OmniPG && dbmate status && psql ..."

---

## 六、数据库迁移管理 (dbmate)

### 6.1 迁移 vs 幂等源码

| 类型 | 目录 | 适用场景 | 执行方式 | 可逆性 |
|:---|:---|:---|:---|:---|
| **迁移** | `db/migrations/` | 表结构变更 | dbmate up | 可回滚 (dbmate rollback) |
| **幂等源码** | `db/src/` | 函数/触发器/视图 | apply-src.sh | 无需回滚 (CREATE OR REPLACE) |
| **初始化** | `db/init/` | 扩展/Schema | 手动执行 | 一次性 |

### 6.2 dbmate 与 apply-src.sh 的关系（重要澄清）

```
┌─────────────────────────────────────────────────────────────────┐
│                    数据库部署的两个层面                          │
│                                                                 │
│  1. dbmate 迁移（db/migrations/）                               │
│     - 用途：表结构变更（CREATE TABLE、ALTER TABLE、DROP COLUMN） │
│     - 特点：只执行一次，不可逆（需手动编写 down 回滚）           │
│     - 时机：每次部署前执行 `dbmate up`                          │
│                                                                 │
│  2. apply-src.sh 幂等源码（db/src/）                            │
│     - 用途：函数、视图、触发器、权限、索引                       │
│     - 特点：可重复执行（CREATE OR REPLACE）                      │
│     - 时机：每次部署后执行，确保代码最新                         │
│                                                                 │
│  结论：deploy-db.sh = dbmate up + apply-src.sh，缺一不可        │
└─────────────────────────────────────────────────────────────────┘
```

### 6.3 db/init 目录与 Pigsty 的职责边界

| 文件 | 职责 | Pigsty 是否管理？ | 建议 |
|:---|:---|:---|:---|
| `01-extensions.sql` | 安装 PG 扩展 | ⚠️ 部分 | Pigsty 负责基础扩展安装；init 处理需要额外配置的扩展（如 pg_net、pg_cron 需要 shared_preload_libraries） |
| `02-schemas.sql` | 创建业务 Schema | ❌ 不管理 | init 一次性创建基础 Schema；src 中幂等维护（CREATE IF NOT EXISTS） |
| `03-casdoor-db.sql` | 创建 Casdoor 数据库及初始配置 | ⚠️ 部分 | Pigsty 的 `pg_databases` 负责数据库创建；init 处理自定义初始数据 |

**init 目录执行时机：**
- 首次部署时手动执行一次
- 后续变更通过 dbmate 迁移或 apply-src.sh 处理
- 不应包含幂等逻辑（与 src/ 不同），表示一次性操作

### 6.4 schema.sql 说明

`db/schema.sql` 是**开发时生成的全量 DDL 导出**，用途：
- 参考：查看当前数据库完整结构
- 文档：作为数据库设计的文档
- 对比：与迁移文件对比，验证迁移完整性

⚠️ **此文件不用于部署！仅作参考。**

### 6.5 迁移工作流

```bash
# 创建迁移
dbmate new create_order_table

# 编写迁移 SQL
# migrations/20260724120000_create_order_table.sql
-- migrate:up
CREATE TABLE sales_order (...);
-- migrate:down
DROP TABLE sales_order;

# 本地测试
export DBMATE_DATABASE_URL="postgres://..."
dbmate up

# 查看状态
dbmate status

# 回滚
dbmate rollback
```

---

## 七、Syncer 部署方案

### 7.1 部署方式对比

| 方式 | 命令 | 适用场景 | 编译步骤 |
|:---|:---|:---|:---|
| Docker | `docker compose up -d syncer` | Phase 1 (单机) | 自动构建（Dockerfile） |
| Systemd 二进制 | `systemctl start omnipg-syncer` | Phase 2 (分离) | `go build -o bin/syncer ./cmd/` |
| 直接运行 | `./bin/syncer` | 开发调试 | 同上 |

### 7.2 二进制部署流程

```bash
# 1. 在 CI 或本地编译（静态链接）
cd db/syncer/
CGO_ENABLED=0 GOOS=linux go build -a -installsuffix cgo -o bin/syncer ./cmd/

# 2. 部署到服务器（scp 二进制 + 配置文件）
scp bin/syncer user@server:/opt/omnipg/bin/
scp syncer.env user@server:/opt/omnipg/config/

# 3. 在服务器上配置 Systemd
sudo cp systemd/omnipg-syncer.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable omnipg-syncer
sudo systemctl start omnipg-syncer
```

**配置策略**：Go 二进制通过**环境变量**读取配置（DB_HOST、DB_PORT、APISIX_ADMIN_URL 等），无需先配置后编译。配置在运行时通过 Systemd 的 `EnvironmentFile` 注入。

### 7.3 Systemd 服务文件 (Phase 2)

```ini
# /etc/systemd/system/omnipg-syncer.service
[Unit]
Description=OmniPG Policy Syncer
After=network.target

[Service]
Type=simple
User=omnipg
WorkingDirectory=/opt/omnipg
ExecStart=/opt/omnipg/bin/syncer
EnvironmentFile=/opt/omnipg/config/syncer.env
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
```

---

## 八、环境配置对比

### 8.1 开发环境 (development)

| 组件 | 部署位置 | 访问地址 | 端口 |
|:---|:---|:---|:---|
| PostgreSQL | WSL2 (Pigsty) | localhost:5432 | 5432 |
| pgBouncer | WSL2 (Pigsty) | localhost:6432 | 6432 |
| Redis | WSL2 (Pigsty) | localhost:6379 | 6379 |
| etcd | WSL2 (Pigsty) | localhost:2379 | 2379 |
| Grafana | WSL2 (Pigsty) | localhost:3000 | 3000 |
| VictoriaMetrics | WSL2 (Pigsty) | localhost:8428 | 8428 |
| Nginx | WSL2 (Pigsty) | localhost:80/443 | 80/443 |
| APISIX | Docker Desktop | localhost:9080 | 9080/9443/9180 |
| PostgREST | Docker Desktop | localhost:3001 | 3001 |
| Casdoor | Docker Desktop | localhost:8000 | 8000 |
| Swagger UI | Docker Desktop | localhost:8082 | 8082 |
| Syncer | Docker Desktop | localhost:8080 | 8080 |
| ~~Redis (Docker)~~ | ~~已移除~~ | ~~冲突~~ | ~~6380~~ |

> 🔔 **开发环境注意**：Docker 中的 Redis 已移除，统一使用 WSL2 Pigsty Redis。如其他项目需要 Docker Redis，请使用不同端口（如 6380）。

### 8.2 生产环境 (production) - Phase 1

| 组件 | 部署位置 | 访问地址 | 说明 |
|:---|:---|:---|:---|
| PostgreSQL | 单机 (Pigsty) | 127.0.0.1:5432 | 不暴露公网 |
| pgBouncer | 单机 (Pigsty) | 127.0.0.1:6432 | Docker 通过 host.docker.internal 访问 |
| Redis | 单机 (Pigsty) | 127.0.0.1:6379 | Docker 通过 host.docker.internal 访问 |
| etcd | 单机 (Pigsty) | 127.0.0.1:2379 | APISIX standalone 不需要，但保留 |
| APISIX | 单机 (Docker) | 0.0.0.0:9080 | 公网入口 |
| PostgREST | 单机 (Docker) | 127.0.0.1:3001 | 仅 APISIX 可访问 |
| Casdoor | 单机 (Docker) | 0.0.0.0:8000 | 公网入口 |
| Syncer | 单机 (Docker) | 127.0.0.1:8080 | APISIX 可访问 |

### 8.3 生产环境 (production) - Phase 2

| 组件 | 部署位置 | 访问地址 | 说明 |
|:---|:---|:---|:---|
| PostgreSQL | DB 服务器 (Pigsty) | 内网:5432 | 仅网关服务器可访问 |
| pgBouncer | DB 服务器 (Pigsty) | 内网:6432 | 网关服务器通过内网访问 |
| Redis | 网关服务器 (Pigsty Docker) | 内网:6379 | 网关服务器本地 |
| etcd | DB 服务器 (Pigsty) | 内网:2379 | DB 服务器本地 |
| APISIX | 网关服务器 (Docker) | 0.0.0.0:9080 | 公网入口 |
| PostgREST | 网关服务器 (Docker) | 内网:3001 | 仅 APISIX 可访问 |
| Casdoor | 网关服务器 (Docker) | 0.0.0.0:8000 | 公网入口 |
| Syncer | DB 服务器 (Systemd 二进制) | 内网:8080 | 系统级进程，高可靠 |

---

### 9.1 密钥管理三层架构

| 层级 | 环境 | 管理方式 | 说明 |
|:---|:---|:---|:---|
| 本地开发 | 开发者机器 | `.env` 文件 | 不提交到 Git，通过 `source .env` 或工具加载 |
| CI/CD | GitHub Actions | GitHub Secrets | 存储在仓库 Settings → Secrets，workflow 中通过 `${{ secrets.XXX }}` 引用 |
| 服务器运行 | 生产/Staging 服务器 | 环境变量或配置文件 | CI/CD 部署时注入，或通过 Systemd `EnvironmentFile` 加载 |

**配置预留：**
- `.env.example` 文件中列出所有需要的变量（不含真实值）
- 本地复制为 `.env` 并填写实际值
- GitHub Secrets 中添加同名变量
- 部署脚本中通过环境变量读取（不硬编码到代码）

> 本地测试环境**不使用** GitHub Secrets，仅 CI/CD 和生产环境使用。

### 9.2 Secrets 清单

| Secret | 说明 | 环境 |
|:---|:---|:---|
| `SSH_PRIVATE_KEY` | 服务器 SSH 私钥 | 全局 |
| `DB_SERVER_HOST` | 数据库服务器 IP | staging / production |
| `GATEWAY_SERVER_HOST` | 网关服务器 IP | staging / production |
| `SERVER_USER` | SSH 用户名 | staging / production |
| `DBMATE_DATABASE_URL` | dbmate 连接 URL | staging / production |
| `DB_URI` | 应用数据库 URI | staging / production |
| `APISIX_ADMIN_KEY` | APISIX Admin Key | staging / production |
| `CASDOOR_DB_PASSWORD` | Casdoor 数据库密码 | staging / production |
| `JWKS_JSON` | JWT 签名密钥 | staging / production |
| `REDIS_PASSWORD` | Redis 密码 (可选) | staging / production |

---

## 十、部署手册

### 10.1 首次部署完整流程（新服务器）

```bash
# ============================================
# 步骤 0: 准备（在目标服务器上执行）
# ============================================
# 确保 WSL2 Ubuntu 26.04 已安装并启用 systemd
cat /etc/wsl.conf  # 应有 [boot] systemd=true

# 克隆仓库
git clone https://github.com/SnugglePuff/OmniPG.git /opt/omnipg
cd /opt/omnipg
git checkout dev

# ============================================
# 步骤 1: 部署基础设施（一次性）
# ============================================
# 执行脚本会自动：
# - 检测 Pigsty 是否安装，未安装则下载 v4.4.0
# - 复制 infra/ 中的配置文件到正确位置
# - 执行 Pigsty 部署（PostgreSQL + pgBouncer + Redis + etcd + Grafana）
./scripts/deploy-infra.sh production

# ============================================
# 步骤 2: 部署数据库（每次更新执行）
# ============================================
./scripts/deploy-db.sh production

# ============================================
# 步骤 3: 部署网关（每次更新执行）
# ============================================
./scripts/deploy-gateway.sh production

# ============================================
# 步骤 4: 初始化 APISIX（一次性，或路由变更时）
# ============================================
./scripts/setup_apisix.sh

# ============================================
# 步骤 5: 验证
# ============================================
./scripts/e2e-test.sh
```

### 10.2 日常更新流程（已有环境）

```bash
cd /opt/omnipg
git pull origin dev

# 如果 db/ 有变更：
./scripts/deploy-db.sh production

# 如果 gateway/ 有变更：
./scripts/deploy-gateway.sh production

# 如果 infra/ 有变更（较少发生）：
./scripts/deploy-infra.sh production
```

### 10.3 测试环境一键部署

```bash
# WSL2 开发环境（可重复执行，幂等）
cd /mnt/e/Projects/OmniPG
./scripts/deploy-all.sh development
```

---

## 十一、实施计划

### Phase 1: 目录重组（仅本地，不改变运行逻辑）

- [x] 创建 `gateway/` 目录，移动 `docker-compose.yml`、`apisix/`、`postgrest/`
- [x] 创建 `gateway/.env.example`（从根目录 `.env.example` 复制并适配）
- [x] 将 `pigsty.yml`、`pg_hba.conf`、`pgbouncer.ini`、`redis.conf`、`userlist.txt` 从 `deploy/` 移动到 `infra/`
- [x] 将 `syncer/` 移动到 `db/syncer/`
- [x] 更新 `Makefile` 中的路径引用
- [x] 更新 `.gitignore`
- [x] 更新 `docker-compose.yml`（移除 Redis 服务，改用主机 Redis）

### Phase 2: 脚本补充

- [x] 创建 `scripts/deploy-infra.sh`（Pigsty 安装 + 配置同步）
- [x] 创建 `scripts/deploy-all.sh`（一键编排）
- [x] 创建 `scripts/migrate.sh`（dbmate 快捷入口）
- [x] 修复 `scripts/deploy-gateway.sh` 中的路径（`gateway/` 目录）
- [x] 更新 `scripts/start.sh` 适配新目录结构

### Phase 3: CI/CD 配置

- [x] 创建 `.github/workflows/ci.yml`（已存在，已更新路径）
- [x] 创建 `.github/workflows/deploy-db.yml`（environment 参数化）
- [x] 创建 `.github/workflows/deploy-gateway.yml`（environment 参数化）
- [x] 创建 `.github/workflows/deploy-infra.yml`（基础设施部署）
- [x] 创建 `.github/workflows/deploy-all.yml`（一键部署编排）
- [ ] 配置 GitHub Secrets（待用户在 GitHub 仓库配置）
- [ ] 测试 PR 路径过滤（待首次 PR 验证）

### Phase 4: 测试验证

- [ ] 在 WSL2 测试 `deploy-all.sh` 一键部署
- [ ] 测试 `deploy-db.sh` 独立执行
- [ ] 测试 `deploy-gateway.sh` 独立执行
- [ ] 测试 E2E 测试脚本
- [ ] 验证 APISIX 路由和 JWT 认证链路

---

## 十二、参考文档

| 组件 | 文档 |
|:---|:---|
| PostgREST | https://postgrest.org/en/v14/references/api.html |
| dbmate | https://github.com/amacneil/dbmate |
| APISIX | https://apisix.apache.org/docs/apisix/deployment-modes/ |
| GitHub Actions | https://docs.github.com/en/actions |
| GitHub Secrets | https://docs.github.com/en/actions/security-guides/using-secrets-in-github-actions |
| Pigsty | https://pigsty.cc/docs/ |
| Pigsty INFRA | https://pigsty.cc/docs/infra/ |
| Pigsty PGSQL | https://pigsty.cc/docs/pgsql/ |
| Pigsty REDIS | https://pigsty.cc/docs/redis/ |
| Pigsty DOCKER | https://pigsty.cc/docs/docker/ |

---

> **文档状态**: v2.0 规划定稿，待实施  
> **下一步**: 按 Phase 1 开始目录重组和脚本创建
