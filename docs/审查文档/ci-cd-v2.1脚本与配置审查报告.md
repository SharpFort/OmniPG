# CI/CD v2.1 脚本与配置审查报告

> **审查日期**: 2026-07-27  
> **审查范围**: Phase 2 脚本 + Phase 3 CI/CD 配置 + 关联基础设施  
> **参考文档**: `ci-cd-方案.v2.1修复版.md` + `测试验证清单-Phase4.md`  
> **代码分支**: `refactor/cicd-v2`  
> **审查方式**: 逐文件逐行对比文档规范 + 基础设施配置验证

---

## 审查摘要

| 等级 | 数量 | 关键问题 |
|:---|:---|:---|
| **P0 (阻断)** | 5 | APISIX 启动失败根因、Syncer 无法构建、Docker 子网冲突 |
| **P1 (严重)** | 5 | Admin Key 不一致、脚本参数反、路径硬编码、PostgreSQL 认证链断裂 |
| **P2 (一般)** | 4 | 幂等性缺陷、`set -e` 陷阱、Redis 绑定、Secret 管理遗漏 |

---

## P0 — 阻断级问题（APISIX/部署完全失败根因）

### P0-1: APISIX `standalone` 模式与 `etcd` 配置互锁

**文件**: `gateway/docker-compose.yml:21` + `gateway/apisix/config.yaml:4,37`

| 配置项 | 当前值 | 规范要求 | 冲突分析 |
|:---|:---|:---|:---|
| `APISIX_STAND_ALONE` (env) | `"true"` | 应移除或统一 | standalone 模式要求 `config_center: yaml`，无需 etcd |
| `deployment.role_traditional.config_provider` | `etcd` | 必须删除 | 与 standalone 模式互斥 |
| `apisix.config_center` | `yaml` | ✅ 正确 | standalone 模式下此值正确 |
| `etcd.host[0]` | `http://host.docker.internal:2379` | 不应存在 | standalone 模式下 APISIX 不读 etcd |

**影响**: APISIX 启动时同时读取两种配置源，行为不确定。实际表现：
- 若优先读取 etcd 配置 → 连接 etcd 失败 → 路由加载失败 → 所有请求 404
- 若优先读取 yaml 配置 → `config_provider: etcd` 被忽略 → 但 `etcd` 段仍存在，可能引发警告

**修复方案**（二选一）：

**方案 A — 纯 standalone（推荐 Phase 1 单机）**：
```yaml
# docker-compose.yml
environment:
  APISIX_STAND_ALONE: "true"
  # 删除 etcd 相关环境变量（若有）
```

```yaml
# config.yaml
deployment:
  role: traditional
  role_traditional:
    config_provider: yaml  # ← 改为 yaml，或删除整个 deployment 段
  admin:
    # ... 保持不变
apisix:
  config_center: yaml
# 删除整个 etcd 段
```

**方案 B — etcd 模式（Phase 2 生产推荐）**：
```yaml
# docker-compose.yml
environment:
  # 删除 APISIX_STAND_ALONE
```

---

### P0-2: etcd 协议错误（HTTP vs HTTPS）— APISIX 无法连接 etcd

**文件**: `gateway/apisix/config.yaml:17`

```yaml
etcd:
  host:
    - "http://host.docker.internal:2379"  # ← 错误！
```

**证据**: `scripts/fix-apisix-etcd.sh:13-16` 显示 Pigsty etcd 使用 mTLS：
```bash
etcdctl --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/etcd/ca.crt \
  --cert=/etc/etcd/server.crt \
  --key=/etc/etcd/server.key \
  user list
```

**影响**: APISIX 尝试用 HTTP 连接仅监听 HTTPS 的 etcd → TLS 握手失败 → APISIX 无法启动或路由无法同步。

**修复**（etcd 模式下）：
```yaml
etcd:
  host:
    - "https://host.docker.internal:2379"
  tls:
    cert: /usr/local/apisix/conf/etcd-client.crt
    key: /usr/local/apisix/conf/etcd-client.key
    verify: false  # 生产环境应使用 true 并配置 CA
```

**附加操作**: 需要从 Pigsty 导出 etcd 客户端证书并挂载到 APISIX 容器。

---

### P0-3: Syncer Dockerfile 引用不存在的 `main.go`

**文件**: `db/syncer/Dockerfile:18`

```dockerfile
COPY main.go ./           # ← 错误！文件不存在
RUN ... -o policy-syncer main.go
```

**实际文件结构**:
```
db/syncer/
├── main.go.bak           # 备份文件
├── cmd/syncer/syncer.go  # 实际入口
├── internal/
│   ├── syncer/
│   ├── apisix/
│   └── database/
└── Dockerfile
```

**影响**: `docker compose build syncer` → COPY 失败 → Syncer 容器永远无法构建。

**修复**:
```dockerfile
# 方案 1: 引用 cmd 目录
COPY cmd/ ./cmd/
COPY internal/ ./internal/
COPY go.mod go.sum ./
RUN go mod download
RUN CGO_ENABLED=0 GOOS=linux go build \
    -ldflags='-w -s -extldflags "-static"' \
    -o policy-syncer ./cmd/syncer/
```

---

### P0-4: Docker Compose 子网使用公网 IP 段

**文件**: `gateway/docker-compose.yml:6`

```yaml
networks:
  app-net:
    driver: bridge
    ipam:
      config:
        - subnet: 172.0.0.0/16   # ← 严重错误！
```

**问题**:
1. `172.0.0.0/16` **不是** RFC 1918 私有地址（私有段为 `172.16.0.0/12`，即 172.16.0.0 – 172.31.255.255）
2. 该段已被 IANA 分配给多个公网机构（如 `172.0.0.0/24` 分配给 Amazon）
3. 与 `pg_hba.conf:27` 中配置的 `172.20.0.0/16` 不一致

**影响**: 
- Docker 容器可能获得公网 IP，导致路由混乱
- `pg_hba.conf` 中 `172.20.0.0/16` 规则不会匹配实际 Docker 网段（`172.0.0.0/16`）
- Docker 容器无法连接 PostgreSQL（认证被拒绝）

**修复**:
```yaml
networks:
  app-net:
    driver: bridge
    ipam:
      config:
        - subnet: 172.20.0.0/16   # ← 与 pg_hba.conf 一致
```

同步更新 `infra/pigsty.yml` 中的 `pg_hba_rules`（若使用自定义 HBA 文件）：
```yaml
pg_hba_builtin:
  - type: host
    address: 172.20.0.0/16
```

---

### P0-5: `deploy-infra.sh` 参数顺序反转

**文件**: `scripts/deploy-infra.sh:13-14`

```bash
ENV=${1:-development}
MODE=${2:-all}  # ← 参数顺序错误！
```

**文档规范**（`ci-cd-方案.v2.1修复版.md:276-279`）:
```
./scripts/deploy-infra.sh db <environment>
./scripts/deploy-infra.sh gateway <environment>
```

**实际调用**: `bash scripts/deploy-infra.sh db development`
- `ENV=db` ← 错误！应该加载 `.env.db`（不存在）
- `MODE=development` ← 错误！应该执行 db 模式部署

**影响**: 
- 找不到 `.env.db` → 回退到默认值
- MODE=`development` → 不匹配 `db|gateway|all` → 报错退出

**修复**:
```bash
MODE=${1:-all}
ENV=${2:-development}
```

同步更新 `deploy-all.sh:51` 中的调用：
```bash
bash "$SCRIPT_DIR/deploy-infra.sh" all "$ENV"
```

---

## P1 — 严重级问题

### P1-1: APISIX Admin Key 三处不一致

| 位置 | Key 值 |
|:---|:---|
| `gateway/apisix/config.yaml:13` | `edd1c9f034335f136f87ad84b625c8f1` |
| `gateway/.env.example:28` | `a1b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6` |
| `scripts/setup_apisix.sh:5` | `a1b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6` |

**影响**: `setup_apisix.sh` 用错误的 Key 调用 Admin API → 401 Forbidden → 路由/JWT 插件配置失败。

**修复**: 统一使用 `config.yaml` 中的 `edd1c9f034335f136f87ad84b625c8f1`。

---

### P1-2: `start.sh` 硬编码 Windows 路径

**文件**: `scripts/start.sh:95`

```bash
cd /mnt/e/Projects/OmniPG/gateway   # ← 硬编码！
```

**实际路径**: `D:\WeChat Files\OmniPG\gateway`

**影响**: 脚本在 `D:\` 盘路径下运行时失败。

**修复**:
```bash
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
cd "$PROJECT_DIR/gateway"
```

---

### P1-3: `e2e-test.sh` 引用不存在的容器名

**文件**: `scripts/e2e-test.sh:127,154`

```bash
docker exec app-postgres psql -U app_owner -d app_db -c "..."
#                  ^^^^^^^^^^^ 不存在！
```

**实际容器名**: `app-postgrest`（`docker-compose.yml:45`）

**影响**: E2E 测试直接崩溃，脚本因 `set -e` 退出。

**修复**: 使用 `app-postgrest`，或直接在宿主机用 psql 连接。

---

### P1-4: `deploy-gateway.sh` 缺少 `setup_apisix.sh` 前置环境变量

**文件**: `scripts/deploy-gateway.sh:47-54`

```bash
# deploy-all.sh 中调用
cd "$PROJECT_DIR/gateway"
bash "$SCRIPT_DIR/setup_apisix.sh"
```

**问题**: `setup_apisix.sh` 依赖 `APISIX_ADMIN_KEY` 环境变量，但 `deploy-gateway.sh` 没有导出该变量到子进程。`.env` 文件被复制到了 `gateway/.env`，但 `setup_apisix.sh` 不会自动加载 `.env`（它依赖环境变量）。

**影响**: `setup_apisix.sh` 使用默认 Key（错误的 `a1b2c3d4...`）→ 路由创建失败。

**修复**: 在调用 `setup_apisix.sh` 前 source `.env`：
```bash
cd "$PROJECT_DIR/gateway"
[ -f .env ] && export $(grep -v '^#' .env | xargs)
bash "$SCRIPT_DIR/setup_apisix.sh"
```

---

### P1-5: `infra/pigsty.yml` 缺少 `pg_hba_builtin` 声明

**文件**: `infra/pigsty.yml:49-73`

**问题**: Pigsty 使用 `pg_hba_rules` 自定义规则，但没有 `pg_hba_builtin` 声明。Pigsty 默认会在自定义规则前插入 built-in 规则（如 local peer 认证）。如果意图是**完全覆盖**默认规则，需要：

```yaml
pg_hba_builtin: []  # 禁用所有内置规则
pg_hba_rules:
  - ...
```

否则 Docker 网段的规则可能被 built-in 的 `local all all peer` 等规则优先级覆盖（取决于 Pigsty 模板实现）。

---

## P2 — 一般级问题

### P2-1: `e2e-test.sh` 的 `set -e` + `((FAILED++))` 陷阱

**文件**: `scripts/e2e-test.sh:6,21-24`

```bash
set -e
# ...
((FAILED++))  # 当 FAILED=0 时返回 exit code 1
```

**Bash 语义**: `((expr))` 当结果为 0 时返回 exit status 1。`((0++))` 中 0 是 falsy，所以返回 1，触发 `set -e` 立即退出。

**影响**: 第一个 FAIL 的测试就会导致脚本退出，而非继续测试。

**修复**:
```bash
FAILED=$((FAILED + 1))  # 替代 ((FAILED++))
# 或
FAILED+=1
```

---

### P2-2: `redis.conf` 绑定地址限制 Docker 访问

**文件**: `infra/redis.conf:1`

```
bind 127.0.0.1
```

**影响**: Docker 容器通过 `host.docker.internal` 连接 Redis 时，数据包从 Docker 网桥到达宿主机的非 127.0.0.1 接口，Redis 不监听该接口 → 连接失败。

**开发环境修复**:
```
bind 0.0.0.0
protected-mode no
```

**生产环境修复**: 使用 `bind 127.0.0.1 <wsl_interface_ip>` 多地址绑定。

---

### P2-3: `deploy-all.sh` 对 `setup_apisix.sh` 失败的错误处理

**文件**: `scripts/deploy-all.sh:50-54`

```bash
if ! bash "$SCRIPT_DIR/setup_apisix.sh"; then
    echo "⚠️ APISIX 初始化失败（可能路由已存在）"
fi
# 继续执行 e2e-test.sh
```

**问题**: 注释说"可能路由已存在"，但实际上 `setup_apisix.sh` 的 `curl -X PUT` 是幂等的（覆盖式写入），失败原因通常是 Key 错误或网络不通，而非"已存在"。

**影响**: 掩盖真实问题，用户以为路由已配置，但实际 Admin API 返回错误。

**修复**: 输出实际错误信息：
```bash
if ! bash "$SCRIPT_DIR/setup_apisix.sh"; then
    echo "❌ APISIX 初始化失败，请检查:"
    echo "   1. APISIX Admin API 是否可达 (curl http://localhost:9180)"
    echo "   2. APISIX_ADMIN_KEY 是否与 config.yaml 一致"
    echo "   3. 运行 'docker logs app-apisix' 查看详细错误"
    exit 1
fi
```

---

### P2-4: GitHub Actions Secrets 缺少 `GATEWAY_SERVER_HOST`

**文件**: `.github/workflows/deploy-gateway.yml:34`

```yaml
env:
  SERVER_HOST: ${{ secrets.GATEWAY_SERVER_HOST }}  # ← 未在 Secrets 清单中列出
```

**文档** `ci-cd-方案.v2.1修复版.md:789` 的 Secrets 清单有 `GATEWAY_SERVER_HOST`，但实际 `.github/workflows/deploy-gateway.yml` 在 "Initialize APISIX Routes" 步骤中引用了：
```yaml
SERVER_HOST: ${{ secrets.GATEWAY_SERVER_HOST }}
```

而 `deploy-infra.yml:38` 只引用了 `DB_SERVER_HOST`。如果 gateway 和 DB 在不同服务器（Phase 2），则 `deploy-infra.yml` 也应该根据 mode 选择不同的 SERVER_HOST。

---

## 基础设施配置交叉验证

### 与 Pigsty 官方模板对比

| 配置项 | Pigsty 默认 | OmniPG 当前 | 状态 |
|:---|:---|:---|:---|
| etcd 监听协议 | HTTPS + mTLS | config.yaml 用 HTTP | ❌ 不兼容 |
| etcd root 用户 | 自动创建 | 脚本手动创建 | ⚠️ 重复但可接受 |
| Redis 持久化 | 取决于配置 | AOF everysec | ✅ 正确 |
| pgBouncer auth_type | scram-sha-256 | scram-sha-256 | ✅ 一致 |
| Docker 网络 | 自动分配 | 172.0.0.0/16 | ❌ 冲突 |
| PostgreSQL 版本 | 用户指定 | 18 | ✅ 正确 |

### 与 APISIX Docker 官方文档对比

| 配置项 | APISIX Docker 推荐 | OmniPG 当前 | 状态 |
|:---|:---|:---|:---|
| Standalone 模式 | `APISIX_STAND_ALONE=true` + yaml config | 混合 etcd 配置 | ❌ 冲突 |
| Admin Key 一致性 | 全局统一 | 三处不同值 | ❌ 不一致 |
| 路由定义方式 | apisix.yaml 文件或 Admin API | 两者混用 | ⚠️ 可行但不清晰 |

---

## 根因分析：为什么 Phase 4 测试"部分成功"

根据截图信息（"部分成功" + "APISIX 有问题"），根因链路如下：

```
1. APISIX_STAND_ALONE=true 与 config_provider: etcd 冲突
   → APISIX 启动行为不确定
   
2. etcd 使用 HTTP 但 Pigsty etcd 仅支持 HTTPS
   → 若 APISIX 尝试连 etcd → TLS 握手失败 → 路由同步失败
   
3. Admin Key 不一致（config.yaml vs setup_apisix.sh）
   → setup_apisix.sh 调用 Admin API → 401 → 路由/JWT 插件未配置
   
4. Docker 子网 172.0.0.0/16 与 pg_hba.conf 172.20.0.0/16 不匹配
   → PostgREST/Casdoor/Syncer 连接 pgBouncer 失败
   
5. Syncer Dockerfile 引用不存在的 main.go
   → docker compose build syncer 失败 → 8080 端口无服务
```

**结果**: APISIX 容器虽然启动了，但路由未配置（404），JWT 插件未启用（请求被拒），子网不匹配（数据库连接失败）。

---

## 修复优先级建议

| 顺序 | 问题 | 修复耗时 | 影响范围 |
|:---|:---|:---|:---|
| 1 | P0-4: Docker 子网修正 | 2分钟 | 全链路连通 |
| 2 | P0-1 + P0-2: APISIX 模式统一 + etcd 协议 | 10分钟 | APISIX 启动 |
| 3 | P0-5: deploy-infra.sh 参数修正 | 2分钟 | 基础设施部署 |
| 4 | P0-3: Syncer Dockerfile 修正 | 5分钟 | Syncer 构建 |
| 5 | P1-1: Admin Key 统一 | 2分钟 | APISIX 配置 |
| 6 | P1-2 + P1-3: 路径硬编码 + 容器名 | 5分钟 | 脚本可运行 |
| 7 | P1-4: setup_apisix.sh 环境变量 | 3分钟 | 路由初始化 |
| 8 | P2-1 + P2-2 + P2-3 + P2-4: 小修补 | 10分钟 | 稳定性 |

**总计修复时间**: ~40分钟（不含测试验证）

---

## 附录：完整文件清单与审查状态

### Phase 2 脚本（8个）

| 文件 | 行数 | 状态 | 问题数 |
|:---|:---|:---|:---|
| `deploy-infra.sh` | 157 | ❌ 需修复 | P0-5 |
| `deploy-all.sh` | 68 | ⚠️ 需调整 | P2-3 |
| `deploy-db.sh` | 49 | ✅ 基本正确 | 0 |
| `deploy-gateway.sh` | 71 | ⚠️ 需调整 | P1-4 |
| `migrate.sh` | 53 | ✅ 正确 | 0 |
| `start.sh` | 177 | ⚠️ 需调整 | P1-2 |
| `apply-src.sh` | 17 | ✅ 正确 | 0 |
| `setup_apisix.sh` | 126 | ❌ 需修复 | P1-1 |

### Phase 3 CI/CD（5个 workflow）

| 文件 | 状态 | 问题 |
|:---|:---|:---|
| `ci.yml` | ✅ 路径过滤正确 | 0 |
| `deploy-db.yml` | ⚠️ 缺少 .env 加载 | 小 |
| `deploy-gateway.yml` | ⚠️ 缺少 GATEWAY_SERVER_HOST 导出 | P2-4 |
| `deploy-infra.yml` | ⚠️ 参数顺序依赖脚本修复 | 0 (脚本修复后自动解决) |
| `deploy-all.yml` | ⚠️ 参数顺序依赖脚本修复 | 0 (脚本修复后自动解决) |

### 基础设施配置

| 文件 | 状态 | 问题 |
|:---|:---|:---|
| `infra/pigsty.yml` | ⚠️ 缺少 pg_hba_builtin 声明 | P1-5 |
| `infra/pg_hba.conf` | ✅ Docker 网段规则正确（需子网修正后生效） | 0 |
| `infra/pgbouncer.ini` | ✅ 配置正确 | 0 |
| `infra/redis.conf` | ⚠️ 绑定地址限制 Docker | P2-2 |
| `infra/userlist.txt` | ✅ 用户列表正确 | 0 |

### 网关配置

| 文件 | 状态 | 问题 |
|:---|:---|:---|
| `gateway/docker-compose.yml` | ❌ 子网冲突 + APISIX 模式冲突 | P0-4, P0-1 |
| `gateway/apisix/config.yaml` | ❌ etcd 协议错误 | P0-2 |
| `gateway/apisix/apisix.yaml` | ✅ 路由结构正确 | 0 |
| `gateway/apisix/casbin_model.conf` | ✅ 模型正确 | 0 |
| `gateway/.env.example` | ⚠️ Admin Key 不一致 | P1-1 |

---

> **审查人**: Hermes Agent (LongCat-2.0)  
> **审查方法**: 全文件逐行对比 + 基础设施交叉验证 + 官方文档对照  
> **建议**: 按"修复优先级建议"顺序执行修复后，重新运行 `make dev` 或 `./scripts/deploy-all.sh development` 验证
