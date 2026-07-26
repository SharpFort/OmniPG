# OmniPG CI/CD 方案设计文档

> **版本**: v1.0  
> **创建日期**: 2026-07-24  
> **状态**: 决策完成，待实施

---

## 一、决策汇总

| # | 决策项 | 结论 |
|:---|:---|:---|
| 1 | 部署拓扑 | Phase 1 单机 → Phase 2 分离 |
| 2 | 代码管理 | 单一仓库 (Monorepo)，目录分离 |
| 3 | 数据库迁移 | dbmate + 幂等源码 (apply-src.sh) |
| 4 | Redis 部署 | 网关 Docker Redis |
| 5 | 目录重组 | 完全重组 (db/gateway/infra) |
| 6 | Syncer 部署 | 与后端同目录，支持 Docker 和 Systemd |
| 7 | VIBE 模块 | 配置预留，暂不部署 |
| 8 | CI/CD 触发 | 路径过滤 + 手动部署 |
| 9 | 密钥管理 | GitHub Secrets |

---

## 二、目录结构设计

### 2.1 重组后完整结构

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
├── db/                                      # 后端代码
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
│   │   └── internal/
│   │       ├── syncer/
│   │       ├── apisix/
│   │       └── database/
│   ├── schema.sql                           # 全量 schema (参考)
│   └── .dbmate.toml
│
├── gateway/                                 # 网关代码
│   ├── docker-compose.yml                   # 容器编排
│   ├── .env.example                         # 网关环境变量模板
│   ├── apisix/                              # APISIX 配置
│   │   ├── config.yaml
│   │   ├── apisix.yaml
│   │   ├── casbin_model.conf
│   │   └── jwks_route.yaml
│   └── postgrest/                           # PostgREST 配置 (可选)
│       └── postgrest.conf
│
├── infra/                                   # Pigsty 基础设施
│   ├── pigsty.yml                           # Phase 1: 完整配置
│   ├── pigsty.db.yml                        # Phase 2: DB 服务器配置
│   ├── pigsty.gateway.yml                   # Phase 2: 网关服务器配置
│   ├── pg_hba.conf
│   ├── pgbouncer.ini
│   ├── redis.conf
│   └── userlist.txt
│
├── scripts/                                 # 部署脚本
│   ├── deploy-db.sh
│   ├── deploy-gateway.sh
│   ├── migrate.sh
│   ├── apply-src.sh
│   └── e2e-test.sh
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

### 2.2 目录职责说明

| 目录 | 部署目标 | 运行方式 | 说明 |
|:---|:---|:---|:---|
| `db/migrations/` | PostgreSQL | dbmate up | 版本化迁移，不可逆 |
| `db/src/` | PostgreSQL | apply-src.sh | 幂等源码，可重复执行 |
| `db/api_v1/` | PostgreSQL | PostgREST 自动暴露 | API 层函数/视图 |
| `db/init/` | PostgreSQL | 手动执行一次 | 初始化扩展/Schema |
| `db/syncer/` | Docker 或 Systemd | 二进制/Docker | 策略同步器 |
| `gateway/` | Docker Compose | docker-compose up | 所有 Docker 服务 |
| `infra/` | 宿主机 (Pigsty) | Ansible | 基础设施配置 |

---

## 三、CI/CD 流水线设计

### 3.1 触发策略

```
┌─────────────────────────────────────────────────────────────────┐
│                          PR 创建                                 │
│                             │                                    │
│                             ▼                                    │
│  ┌──────────────────────────────────────────────────────────┐   │
│  │                   路径检测                                 │   │
│  │  ┌─────────────┐  ┌──────────────┐  ┌────────────────┐  │   │
│  │  │ db/**       │  │ gateway/**   │  │ infra/**       │  │   │
│  │  │ 变更?       │  │ 变更?        │  │ 变更?          │  │   │
│  │  └──────┬──────┘  └──────┬───────┘  └───────┬────────┘  │   │
│  │         │                │                   │           │   │
│  │         ▼                ▼                   ▼           │   │
│  │  ┌─────────────┐  ┌──────────────┐  ┌────────────────┐  │   │
│  │  │ DB 检查     │  │ 网关检查     │  │ 基础设施检查   │  │   │
│  │  │ - SQL Lint  │  │ - compose    │  │ - YAML lint    │  │   │
│  │  │ - dbmate    │  │   validate   │  │ - pigsty       │  │   │
│  │  │ - pgTAP     │  │ - docker     │  │   validate     │  │   │
│  │  │   tests     │  │   build      │  │                │  │   │
│  │  └─────────────┘  └──────────────┘  └────────────────┘  │   │
│  └──────────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────────┘
```

### 3.2 CI Pipeline (ci.yml)

**触发条件**: PR 到 dev 或 main 分支

**路径过滤规则**:

| 路径 | 触发的检查 |
|:---|:---|
| `db/migrations/**` | SQL Lint + dbmate dry-run + pgTAP tests |
| `db/src/**` | SQL Lint + apply-src.sh dry-run |
| `db/syncer/**` | Go build + Go test |
| `gateway/**` | Docker Compose validate + Docker build |
| `infra/**` | YAML lint + Pigsty config validate |

### 3.3 Deploy Pipeline (手动触发)

**触发方式**: `workflow_dispatch` (GitHub UI 手动点击)

**输入参数**:

| 参数 | 类型 | 默认值 | 说明 |
|:---|:---|:---|:---|
| `environment` | choice | staging | 部署环境 (staging/production) |
| `migration_only` | boolean | false | 仅执行数据库迁移 |
| `skip_tests` | boolean | false | 跳过 E2E 测试 |

---

## 四、GitHub Actions 配置

### 4.1 CI Workflow

```yaml
# .github/workflows/ci.yml
```

### 4.2 Deploy DB Workflow

```yaml
# .github/workflows/deploy-db.yml
```

### 4.3 Deploy Gateway Workflow

```yaml
# .github/workflows/deploy-gateway.yml
```

---

## 五、部署脚本

### 5.1 deploy-db.sh

```bash
#!/bin/bash
# 数据库部署脚本
```

### 5.2 deploy-gateway.sh

```bash
#!/bin/bash
# 网关部署脚本
```

---

## 六、Makefile

```makefile
# OmniPG 统一 Makefile
```

---

## 七、GitHub Secrets 清单

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

## 八、环境配置对比

### 8.1 开发环境 (development)

| 组件 | 部署位置 | 访问地址 |
|:---|:---|:---|
| PostgreSQL | WSL2 (Pigsty) | localhost:5432 |
| pgBouncer | WSL2 (Pigsty) | localhost:6432 |
| APISIX | Docker Desktop | localhost:9080 |
| PostgREST | Docker Desktop | localhost:3001 |
| Casdoor | Docker Desktop | localhost:8000 |
| Redis | Docker Desktop | localhost:6379 |
| Syncer | Docker Desktop | localhost:8080 |

### 8.2 生产环境 (production) - Phase 1

| 组件 | 部署位置 | 访问地址 |
|:---|:---|:---|
| PostgreSQL | 单机 (Pigsty) | 127.0.0.1:5432 |
| pgBouncer | 单机 (Pigsty) | 127.0.0.1:6432 |
| APISIX | 单机 (Docker) | 0.0.0.0:9080 |
| PostgREST | 单机 (Docker) | 127.0.0.1:3001 |
| Casdoor | 单机 (Docker) | 0.0.0.0:8000 |
| Redis | 单机 (Docker) | 127.0.0.1:6379 |
| Syncer | 单机 (Docker) | 127.0.0.1:8080 |

### 8.3 生产环境 (production) - Phase 2

| 组件 | 部署位置 | 访问地址 |
|:---|:---|:---|
| PostgreSQL | DB 服务器 (Pigsty) | 内网:5432 |
| pgBouncer | DB 服务器 (Pigsty) | 内网:6432 |
| APISIX | 网关服务器 (Docker) | 0.0.0.0:9080 |
| PostgREST | 网关服务器 (Docker) | 内网:3001 |
| Casdoor | 网关服务器 (Docker) | 0.0.0.0:8000 |
| Redis | 网关服务器 (Docker) | 内网:6379 |
| Syncer | 网关服务器 (Systemd) | 内网:8080 |

---

## 九、数据库迁移管理 (dbmate)

### 9.1 迁移 vs 幂等源码

| 类型 | 目录 | 适用场景 | 执行方式 | 可逆性 |
|:---|:---|:---|:---|:---|
| **迁移** | `db/migrations/` | 表结构变更 | dbmate up | 可回滚 (dbmate rollback) |
| **幂等源码** | `db/src/` | 函数/触发器/视图 | apply-src.sh | 无需回滚 (CREATE OR REPLACE) |
| **初始化** | `db/init/` | 扩展/Schema | 手动执行 | 一次性 |

### 9.2 迁移工作流

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

## 十、Syncer 部署方案

### 10.1 部署方式对比

| 方式 | 命令 | 适用场景 |
|:---|:---|:---|
| Docker | `docker compose up -d syncer` | Phase 1 (单机) |
| Systemd | `systemctl start omnipg-syncer` | Phase 2 (分离) |
| 直接运行 | `./bin/syncer` | 开发调试 |

### 10.2 Systemd 服务文件 (Phase 2)

```ini
# /etc/systemd/system/omnipg-syncer.service
[Unit]
Description=OmniPG Policy Syncer
After=network.target

[Service]
Type=simple
User=omnipg
WorkingDirectory=/opt/omnipg/db/syncer
ExecStart=/opt/omnipg/bin/syncer
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
```

---

## 十一、实施计划

### Phase 1: 目录重组 (仅本地)

- [ ] 创建 `gateway/` 目录，移动 `docker-compose.yml`、`apisix/`
- [ ] 创建 `infra/` 目录，移动 `deploy/pigsty.yml` 等
- [ ] 移动 `db/syncer/` 到 `db/syncer/`
- [ ] 更新 `Makefile`
- [ ] 更新 `.gitignore`

### Phase 2: CI/CD 配置

- [ ] 创建 `.github/workflows/ci.yml`
- [ ] 创建 `.github/workflows/deploy-db.yml`
- [ ] 创建 `.github/workflows/deploy-gateway.yml`
- [ ] 配置 GitHub Secrets
- [ ] 测试 PR 触发

### Phase 3: 部署脚本

- [ ] 创建 `scripts/deploy-db.sh`
- [ ] 创建 `scripts/deploy-gateway.sh`
- [ ] 测试 staging 部署
- [ ] 测试 production 部署

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

---

> **文档状态**: 决策完成，待实施  
> **下一步**: 生成具体的 GitHub Actions YAML 文件和部署脚本
