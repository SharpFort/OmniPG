# OmniPG 多机拓扑与 CI/CD 演进方案（Phase 2/3 草案）

> **状态**：分析草案（2026-08-20 编写）。本文只澄清模型与给出演进建议，**未改动任何现有配置/脚本/文档**；文中所有 inventory 片段均为「示例（草案）」，不代表当前 `infra/pigsty.yml` 已被修改。
>
> **要回答的问题**：
> 1. Pigsty 是否支持「一个 pigsty.yml 在多台服务器上部署、配好 IP 端口就自动组网」？
> 2. 「-l LIMIT」为什么是单文件多组件多机部署的关键机制？
> 3. 是不是先在一台主机（管理节点）上部署，只要能提供访问权限，就能让它自动在其他机器上部署？
> 4. 每台机器都必须安装 Pigsty 组件吗？其他模块以及 Docker 中安装的服务，也需要用 Pigsty 管理吗？
>
> **官方文档依据**（本文结论均可在下列页面核实）：
> - [配置清单 / Inventory（单文件模型）](https://pigsty.cc/docs/concept/iac/inventory/)
> - [剧本列表](https://pigsty.cc/docs/ref/playbook/)
> - [使用 Ansible 剧本完成部署（-l / -t / -e / -i）](https://pigsty.cc/docs/setup/playbook/)
> - [配置模板（多机多集群单文件示例）](https://pigsty.cc/docs/conf/)
> - [端口列表](https://pigsty.cc/docs/ref/port/)
> - [模块：INFRA（管理节点职责）](https://pigsty.cc/docs/infra/)
> - [Docker 部署（容器单机体验，不适用生产多节点）](https://pigsty.cc/docs/setup/docker/)
> - [INFRA 仓库软件清单（离线源）](https://pigsty.cc/docs/repo/infra/list/)

---

## 1. 背景与目标

OmniPG 当前（Phase 1）是单机全栈：Pigsty 管理 PostgreSQL/pgBouncer/Redis/etcd，Docker Compose 承载 APISIX/PostgREST/Logto/Swagger，入口为 `scripts/deploy-all.sh`。

规划的演进路径：

| 阶段 | 拓扑 | 说明 |
| --- | --- | --- |
| Phase 1（现状） | 单机全栈 | `infra/pigsty.yml` 全部组指向 127.0.0.1；`deploy-all.sh` 一键 |
| Phase 2a | 前后端分离 | 前端静态站（Vue 构建产物）独立部署；DB 与网关仍可同机或分机 |
| Phase 2b | 网关 / DB / 前端三机分离 | DB 机跑 pgsql/infra/etcd；网关机跑 node/docker/redis + compose；前端机跑 Nginx 静态站 |
| Phase 3 | DB 按库（schema 域）拆多机 | 多套 PG 集群（多个 `pg_cluster` 组）分布在不同主机 |

> ⚠️ 术语澄清：PostgreSQL 本身**不能**把同一实例的不同 schema 拆到不同物理机。**「按 schema 拆」落到 Pigsty = 按集群/按库拆**（如业务库 `pg_omnipg`、审计库 `pg_audit`、地理库 `pg_geo`），每套集群独立实例与 pgbouncer，可分布在不同的主机上。详见第 5 节 Phase 3。

> 📌 **2026-08-20 补充（部署基准）**：当前整个 infra **以单机部署（Phase 1）为准**；Phase 2a/2b/3 仅作为本文档的补充说明（第 5 节均为草案示意），落地前不修改 `infra/pigsty.yml` 的功能性配置（只允许注释说明）。7 项待澄清决策已于 2026-08-20 定稿，见第 7 节。

---

## 2. Pigsty 部署模型核心概念

### 2.1 管理节点（Infra/Admin）与托管节点

- **管理节点（Infra/Admin）**：安装 Pigsty 本体的机器（`~/pigsty`：源码、Ansible、playbook、`pigsty.yml`、离线软件源）。所有剧本从这里发起。Pigsty 默认把**当前执行配置过程的节点**标记为 Infra/Admin 节点。
- **托管节点**：被纳管的目标机器（DB 机、网关机……），**不需要安装 Pigsty 本体**，由管理节点经 SSH 执行剧本完成纳管与组件部署。

官方表述（[模块：INFRA](https://pigsty.cc/docs/infra/)）：*「用户会从 Infra/Admin 节点上使用 Ansible 或其他工具发起对数据库节点的管理：执行集群创建、扩缩容、实例/集群回收，创建业务用户、业务数据库……」「Pigsty 默认将使用当前执行此剧本的节点作为 Pigsty 的 Infra 节点与 ADMIN 节点」*。

### 2.2 单文件 inventory（pigsty.yml）

[配置清单](https://pigsty.cc/docs/concept/iac/inventory/) 原文：

> 「每一套 Pigsty 部署都对应着一份配置清单（Inventory）……Pigsty 默认使用 Ansible YAML 配置格式，**使用一个单一 YAML 配置文件 pigsty.yml 作为配置清单**。」
>
> 「配置清单由两部分组成：全局参数（`all.vars`）和多个组（`all.children`）。**每个 Ansible 组可能代表一个集群**，可以是节点集群、PostgreSQL 集群、Redis 集群、Etcd 集群或 Silo 集群等。」

即：**一份文件描述整个环境的全部主机与集群**；集群成员（hosts）与集群参数（vars）都在其中；变量覆盖顺序为 全局 < 组 < 实例。官方示例直接给出同一文件内的 3 节点 HA PG 集群（`pg_seq`/`pg_role` 区分 primary/replica/offline）。

规模变大后官方也支持**拆分配置**（`hosts.yml` + `group_vars/` + `host_vars/`）或用 `-i` 切换多份清单（如按环境 staging/production）。这是组织选项，不是必须，也不改变「集中管理」的模型。

### 2.3 剧本（Playbook）+ 主机限制（-l）

部署动作由模块剧本完成（[剧本列表](https://pigsty.cc/docs/ref/playbook/)）：

| 模块 | 剧本 | 主要用途 |
| --- | --- | --- |
| INFRA | `deploy.yml` | 一次性部署核心链路（Infra/Node/Etcd/PGSQL，按配置启用 MINIO） |
| INFRA | `infra.yml` / `infra-rm.yml` | 初始化 / 移除基础设施组件 |
| NODE | `node.yml` / `node-rm.yml` | 节点纳管与基线配置 / 去纳管 |
| ETCD | `etcd.yml` / `etcd-rm.yml` | ETCD 安装/扩容 / 移除/缩容 |
| PGSQL | `pgsql.yml`（另有 user/db/monitor/migration/pitr 管理剧本） | 初始化 PG 集群或新增实例 |
| REDIS | `redis.yml` / `redis-rm.yml` | Redis 部署 / 移除 |
| DOCKER | `docker.yml` | Docker 引擎部署 |
| VIBE | `vibe.yml` | VIBE 开发环境部署 |

关键规则（[剧本执行](https://pigsty.cc/docs/setup/playbook/) 原文）：

> 「Pigsty 提供了一个“一条龙”部署剧本 `deploy.yml`……Redis、Kafka、原生 MySQL 等可选模块即使已在清单中定义，**也需要分别执行其模块剧本**。」
>
> 「执行剧本时建议使用 `-l` 参数限制命令执行的对象范围。」

**「单文件 + 剧本 + -l」就是「单文件多组件多机部署」的完整拼图**：清单负责声明「有什么」，剧本负责「做什么」，`-l` 负责「在哪台/哪些机器上做」。三者缺一不可。

### 2.4 「自动组网」的真实机制

多机部署后，组件之间不是靠「IP 端口对上了就自动连」，而是靠管理节点剧本在目标机上完成部署后，由以下机制形成网络关系（[模块：INFRA](https://pigsty.cc/docs/infra/)）：

| 机制 | 组件 | 作用 |
| --- | --- | --- |
| DNSMASQ（53） | INFRA 节点 | 各集群/节点域名注册到 `/etc/dnsmasq.d/pigsty/`，节点间按域名互访 |
| Nginx 本地软件源（80/443） | INFRA 节点 | 托管节点安装软件时从 `http://i.pigsty/pigsty.repo` 拉取 |
| VictoriaMetrics（8428）/ VMAlert（8880）/ AlertManager（9059） | INFRA 节点 | 拉取各节点指标、评估告警、分发通知 |
| Vector → VictoriaLogs（9428） | 各节点 → INFRA | 日志结构化采集 |
| etcd（2379/2380） | DCS | Patroni 高可用决策（`pg_*_primary` 等域名由 Patroni + DCS 维护） |
| Chronyd（123） | INFRA 节点 | 全环境 NTP 同步 |
| Ansible | 管理节点 | 编排以上全部 |

**结论**：所谓「自动组网」= 管理节点在目标机部署好服务后，通过 DNSMASQ 域名注册、etcd/Patroni 发现、监控注册、软件源/NTP 依赖关系自动形成网络拓扑。前提是 IP/端口/密码/域名配置正确、网络可达（详见第 4 节前提清单）。

---

## 3. 「-l LIMIT」详解（关键机制）

### 3.1 它是什么

`-l|--limit <pattern>` 是标准 Ansible 参数，Pigsty 剧本全部透传支持。作用：**把剧本的执行范围限制在匹配的主机/组上**。剧本内容不变，只有「作用对象」变化——这正是同一份 inventory 多机复用的核心。

### 3.2 可用的匹配模式（[剧本执行](https://pigsty.cc/docs/setup/playbook/) 原文示例）

| 模式 | 示例 | 含义 |
| --- | --- | --- |
| 主机 IP | `./node.yml -l 10.0.0.10` | 只在该主机上执行 |
| 组名 | `./pgsql.yml -l pg_omnipg` | 在该组全部主机上执行 |
| 通配符 | `./pgsql.yml -l 'pg-*'` | glob 匹配 |
| 交集 | `./pgsql.yml -l '10.0.0.11,&pg-test'` | 既属于组又是该主机 |
| 排除 | `./pgsql-rm.yml -l 'pg-test,!10.0.0.11'` | 组内去掉某主机 |
| 多目标 | `./node.yml -l '10.0.0.10,10.0.0.11'` | 多台主机 |

### 3.3 与模块剧本的组合（OmniPG 角色映射）

| OmniPG 角色 | 主机（示例 IP） | 模块剧本组合 | 说明 |
| --- | --- | --- | --- |
| DB 机 | 10.0.0.10 | `pgsql.yml -l 10.0.0.10` → `infra.yml -l 10.0.0.10` → `etcd.yml -l 10.0.0.10`（→ `vibe.yml` 可选） | PG + 基础设施 + DCS |
| 网关机 | 10.0.0.20 | `node.yml -l 10.0.0.20` → `docker.yml -l 10.0.0.20` → `redis.yml -l 10.0.0.20` | 节点纳管 + Docker 引擎 + Redis（Redis 归属见第 7 节待澄清） |
| 前端机 | 10.0.0.30 | Nginx 静态站（见第 6 节，通常不进 Pigsty 模块） | 构建产物 + 反代/静态托管 |

> 注意：`-l` 匹配的是 inventory 中**主机的键**（IP）。多机后必须把各组的 `hosts` 从 127.0.0.1 改成真实 IP，`-l 10.0.0.10` 才能命中对应主机。

### 3.4 在 OmniPG 脚本中的实际用法（现状）

`scripts/deploy-infra.sh` 已实现该模型：

```bash
# 单机全量（Phase 1）
bash scripts/deploy-infra.sh all development          # → ./deploy.yml + ./etcd.yml（无 -l，作用于全部）

# DB 服务器（Phase 2）：本机 IP 经 LIMIT 传入
LIMIT=10.0.0.10 bash scripts/deploy-infra.sh db production
#   → ./pgsql.yml -l 10.0.0.10
#   → ./infra.yml -l 10.0.0.10
#   → ./etcd.yml -l 10.0.0.10
#   → ./vibe.yml -l 10.0.0.10

# 网关服务器（Phase 2）
LIMIT=10.0.0.20 bash scripts/deploy-infra.sh gateway production
#   → ./node.yml -l 10.0.0.20
#   → ./docker.yml -l 10.0.0.20
#   → ./redis.yml -l 10.0.0.20
```

`.github/workflows/deploy-infra.yml` 中即为 `LIMIT=$SERVER_HOST`（GitHub Secrets 注入的目标机 IP），GitHub Actions runner SSH 到目标机后在本机执行带 `-l` 的剧本——这是**分散本地模式**（每台机器都装 Pigsty，各自跑本机角色），能工作但不是官方推荐形态（见 4.1）。

### 3.5 注意事项与常见误区

1. **没有 -l 的剧本很危险**。官方原文：「谨慎运行没有主机限制的剧本！在大多数时候，缺少这个值可能会有危险，因为大多数剧本将在 all 主机上执行。」多机后**不要**直接跑裸 `./deploy.yml`，否则会全量推送到 inventory 里所有相关组的主机。
2. **-l 只管「对象」，-t 只管「任务」**：`./infra.yml -t repo` 只跑本地软件源子任务；`./infra.yml -l 10.0.0.10 -t repo` 才是「在指定主机上只跑该子任务」。
3. **-e 传参数**：如 `./pgsql-rm.yml -l pg-omnipg -e pg_safeguard=false`（保护开关强制覆盖）。
4. **-i 换清单**：`./infra.yml -i conf/myenv.yml` 可切换另一份 inventory（多环境时用）。
5. **幂等性**：Pigsty 剧本为幂等设计，同参数重跑不会重建已存在对象；配置变更后重跑会覆盖相关配置文件（如 `~/pigsty/pigsty.yml` 与 /etc 下组件配置）——这正是「配置即部署」的基础。
6. **-l 命中主机所属的所有组**：单机模式下 `-l 127.0.0.1` 命中所有组，但模块剧本只部署自己模块的东西，所以无冲突；多机后每个主机通常只属于少数角色组，行为更清晰。

---

## 4. 两个关键确认

### 4.1 「先在一台主机上部署，提供访问权限后自动部署其他机器？」—— 是，但要区分两种形态

**集中管理模式（官方推荐）**：
- 一台**管理节点**安装 Pigsty 本体（`~/pigsty` 源码 + Ansible + playbook + inventory + 软件源）。
- 管理节点持有到所有目标机的 **SSH 免密密钥**（`ssh-copy-id` 分发公钥）。
- 从管理节点执行：`./pgsql.yml -l 10.0.0.10`、`./node.yml -l 10.0.0.20`……剧本自动 SSH 到目标机完成部署。
- **目标机无需预装 Pigsty**，无需复制 pigsty.yml（清单只在管理节点）。

这正是官方设计（[模块：INFRA](https://pigsty.cc/docs/infra/)：「从 Infra/Admin 节点发起对数据库节点的管理」），也最契合「优雅 CI/CD」：CI 只对接管理节点一台机器，其余机器都是被纳管对象。

**分散本地模式（现状 `deploy-infra.sh`）**：
- 每台机器都装 Pigsty、都复制同一份 `infra/pigsty.yml` 到 `~/pigsty/`，再各自 `-l 本机IP` 跑对应模块剧本。
- 能用、与单机脚本天然兼容，但存在配置漂移风险（每台机器的 `~/pigsty` 都要与仓库同步）、重复安装成本、多机后验证脚本（`verify-stack.sh`/`e2e-test.sh`）难以跨机。

**自动部署的前提条件（两种形态通用）**：

| # | 前提 | 说明 |
| --- | --- | --- |
| 1 | SSH 可达 | 管理节点 → 各目标机 22 端口可达、免密登录（或 ansible_password） |
| 2 | sudo 可用 | 剧本需要 root/免密 sudo（或配置的 admin 用户） |
| 3 | 清单真实 IP | 各组 `hosts` 填目标机真实 IP；`admin_ip` 为管理节点 IP |
| 4 | DNS 可达 | 目标机可解析 `i.pigsty` 等域名（DNSMASQ 或 `node_etc_hosts` 静态条目兜底） |
| 5 | 软件源可达 | 目标机能访问管理节点 Nginx 本地源（或公网在线安装） |
| 6 | 防火墙放行 | 按角色收敛开放端口（见 5.4），至少 22 + 角色所需端口 |
| 7 | 密码/令牌一致 | PG 用户密码、pgBouncer userlist、etcd root、patroni、grafana 等在清单内一致，多机后跨机一致更关键 |
| 8 | 版本一致 | 全环境 Pigsty 版本锁定（当前 v4.4.0） |

### 4.2 「每台机器必须装 Pigsty 组件吗？其他模块和 Docker 服务呢？」—— 边界澄清

| 对象 | 是否需要/由谁管理 | 说明 |
| --- | --- | --- |
| Pigsty 本体（源码/Ansible/playbook/pigsty.yml/软件源） | **只需管理节点** | 托管节点不装；由 `node.yml` 纳管（基础软件、exporter、内核参数、防火墙、repo 指向等） |
| PG/pgBouncer/etcd/Redis/Docker 引擎等「模块」 | **由 Pigsty 管理** | 在 inventory 声明 + 对应模块剧本部署（pgsql/etcd/redis/docker），生命周期、监控、配置都由 Pigsty 管 |
| 应用容器（APISIX/PostgREST/Logto/Swagger） | **不由 Pigsty 管理** | Pigsty DOCKER 模块只管理 **Docker 引擎本身**；应用容器生命周期仍由 `gateway/docker-compose.yml` + `deploy-gateway.sh` 管理 |
| 应用层可观测性 | **可由 Pigsty 纳管** | Blackbox 探测、exporter、日志采集（Vector→VictoriaLogs）可纳入 Pigsty 监控，属于可观测性而非生命周期管理 |
| 前端静态站 | **不进 Pigsty 模块**（可选） | Nginx 静态站可复用 Pigsty INFRA 的 Nginx 或独立 Nginx/CDN |

一句话：**「每台机器装 Pigsty」不是必须的（那是分散模式的做法）；官方模型是「一台管理节点装 Pigsty，其余机器被 Ansible 纳管」。Pigsty 管「基础设施组件 + 引擎」，Docker Compose 管「应用容器」，两者职责分离。**

---

## 5. 分阶段拓扑与 inventory 演化（示例，未应用）

> 以下 YAML 均为**草案示意**，用于说明「同一份文件如何随阶段变化」，**不修改当前 `infra/pigsty.yml`**。真实落地时按第 7 节待澄清项定稿后再改。

### 5.1 Phase 2a：前后端分离（DB + 网关同机）

```yaml
# 草案：DB/网关仍同一台，前端静态站独立
all:
  children:
    pg_omnipg: { hosts: { 10.0.0.10: { pg_seq: 1, pg_role: primary } }, vars: { pg_cluster: pg_omnipg } }
    infra:     { hosts: { 10.0.0.10: { infra_seq: 1 } } }
    etcd:      { hosts: { 10.0.0.10: { etcd_seq: 1 } }, vars: { etcd_cluster: etcd } }
    redis:     { hosts: { 10.0.0.10: { redis_node: 1, redis_instances: { 6379: {} } } }, vars: { redis_cluster: redis } }
    docker:    { hosts: { 10.0.0.10: { docker_seq: 1 } } }
    vibe:      { hosts: { 10.0.0.10: { vibe_seq: 1 } }, vars: { vibe_enabled: true } }
  vars: { admin_ip: 10.0.0.10 }
```

前端机：`nginx.conf` 静态站（构建产物 + 反代 9080 或前端直连 API）。此阶段 Pigsty 侧几乎不变，只把 127.0.0.1 换成真实 IP。

### 5.2 Phase 2b：网关 / DB / 前端三机分离

```yaml
# 草案：DB 机 10.0.0.10；网关机 10.0.0.20；前端机 10.0.0.30（不进 Pigsty）
all:
  children:
    pg_omnipg: { hosts: { 10.0.0.10: { pg_seq: 1, pg_role: primary } }, vars: { pg_cluster: pg_omnipg } }
    infra:     { hosts: { 10.0.0.10: { infra_seq: 1 } } }   # 监控/DNS/源 留在 DB 机（或独立管理机）
    etcd:      { hosts: { 10.0.0.10: { etcd_seq: 1 } }, vars: { etcd_cluster: etcd } }
    redis:     { hosts: { 10.0.0.20: { redis_node: 1, redis_instances: { 6379: {} } } }, vars: { redis_cluster: redis } }   # 归属待定，见 7.1
    docker:    { hosts: { 10.0.0.20: { docker_seq: 1 } } }
    vibe:      { hosts: { 10.0.0.10: { vibe_seq: 1 } }, vars: { vibe_enabled: true } }
  vars: { admin_ip: 10.0.0.10 }
```

执行矩阵：

```bash
# 管理节点（10.0.0.10 自身或独立管理机）
./pgsql.yml -l 10.0.0.10 && ./infra.yml -l 10.0.0.10 && ./etcd.yml -l 10.0.0.10
./node.yml -l 10.0.0.20 && ./docker.yml -l 10.0.0.20 && ./redis.yml -l 10.0.0.20
```

> 网关容器访问 DB：compose 中 `DB_HOST` 从 `host.docker.internal` 改为 DB 机内网 IP（或 DNSMASQ 域名），走 pgbouncer 6432；pg_hba 需放行网关机网段（当前已含 `10.0.0.0/8`）。
>
> 📄 **可填 IP 的完整示例文件**：`infra/pigsty.phase2.example.yml`（草案，**未启用**；启用步骤见该文件头部注释）。

### 5.3 Phase 3：DB 按库（schema 域）拆多机

```yaml
# 草案：业务库 / 审计库 / 地理库 各自独立 PG 集群，分布不同主机
all:
  children:
    pg_omnipg: { hosts: { 10.0.0.10: { pg_seq: 1, pg_role: primary } }, vars: { pg_cluster: pg_omnipg, pg_databases: [ { name: app_db, owner: app_owner } ] } }
    pg_audit:  { hosts: { 10.0.0.11: { pg_seq: 1, pg_role: primary } }, vars: { pg_cluster: pg_audit,  pg_databases: [ { name: audit_db, owner: app_owner } ] } }
    pg_geo:    { hosts: { 10.0.0.12: { pg_seq: 1, pg_role: primary } }, vars: { pg_cluster: pg_geo,    pg_databases: [ { name: geo_db,    owner: app_owner } ] } }
    infra:     { hosts: { 10.0.0.10: { infra_seq: 1 } } }
    etcd:      { hosts: { 10.0.0.10: { etcd_seq: 1 } }, vars: { etcd_cluster: etcd } }
    redis:     { hosts: { 10.0.0.20: { redis_node: 1, redis_instances: { 6379: {} } } }, vars: { redis_cluster: redis } }
    docker:    { hosts: { 10.0.0.20: { docker_seq: 1 } } }
  vars: { admin_ip: 10.0.0.10 }
```

**关键约束**：跨集群 join 需要 `postgres_fdw`、逻辑复制或应用层聚合；当前「数据库即后端、RLS 集中清单」设计在分库后，跨 schema 的 RPC/视图会变成跨库调用，属**架构级决策**，需单独评审后再动。部署链侧反而简单：`scripts/deploy-db.sh` 已支持 `DB_URI`/`DB_PORT` 参数化，CI 对每个目标库跑一次即可。

### 5.4 端口收敛建议（随拓扑演进）

| 角色 | 最小开放（示例） | 说明 |
| --- | --- | --- |
| DB 机 | 22 + 5432/6432（内网）+ 2379/2380（etcd，内网）+ 监控面（3000/8428 等仅内网） | 不对外暴露数据库 |
| 网关机 | 22 + **9080（唯一对外）** + 9180（仅内网管理）+ 6379（Redis，仅内网） | 参考 [端口列表](https://pigsty.cc/docs/ref/port/) 公网开放建议 `[22,80,443]` |
| 前端机 | 22 + 80/443 | 静态站/反代 |
| 管理节点 | 22 + 80/443 + 8428/3000（内网监控） | Infra 面 |

> 当前 `infra/pigsty.yml` 的 `node_firewall_public_port` 是单机大并集，分机后应按组收敛（`node_firewall_public_port` 是组级参数，可在各角色组 vars 内分别设置）。

---

## 6. CI/CD 演进建议（目标：优雅自动化）

### 6.1 推荐形态：集中管理（管理节点 = 部署锚点）

```
GitHub Actions runner
   │  SSH（1 个密钥：SSH_PRIVATE_KEY）
   ▼
管理节点（Infra/Admin，安装 Pigsty + 持有各目标机密钥）
   │  Ansible + -l（inventory 唯一：infra/pigsty.yml）
   ▼
DB 机 / 网关机 / 前端机（被纳管对象）
```

好处：CI 只对接一台机器；inventory 只在一处；目标机无需装 Pigsty；密钥集中管理；剧本幂等可重放。

### 6.2 Workflow 矩阵（按角色 × 环境）

| Workflow | 目标 | 执行内容 |
| --- | --- | --- |
| deploy-infra | DB 机 / 网关机 | 管理节点跑 `pgsql/infra/etcd` 或 `node/docker/redis`（带 `-l 目标IP`） |
| deploy-db | 每个目标库 | `deploy-db.sh`（bootstrap → dbmate up → apply-src），`DB_URI` 参数化，Phase 3 按库矩阵化 |
| deploy-gateway | 网关机 | `deploy-gateway.sh` + `init-apisix-routes.sh` |
| deploy-frontend（新增） | 前端机 | 构建产物上传 + Nginx 静态站/反代 reload |
| ci.yml | — | 不变（静态检查） |

### 6.3 需要参数化的现有环节

- `verify-stack.sh` / `e2e-test.sh` 目前假设「本机即全栈」；多机后需要按部署目标传参（`BASE_URL`/`PGRST_URL` 已有部分支持，`DB_HOST` 需外置）。
- 密钥：集中模式下 GitHub Secrets 只需管理机访问密钥；管理机到各目标机的密钥落在管理机 `~/.ssh/`（或 CI 注入）。
- 占位符展开：`.env.staging/.env.production` 的 `${VAR}` 仍需在 CI 中预展开后再下发。

### 6.4 前端静态站（非 Pigsty）

前端不进 Pigsty 模块：CI 构建 → 产物上传前端机 → Nginx 托管 + 反代 `/api` 到网关机 9080（或保持跨域直连）。如需统一入口可让前端机 Nginx 反代 9080，保持唯一对外端口语义。

### 6.5 路线图

1. **已定稿（2026-08-20）**：Redis 归属、logto 库、pg_hba、防火墙、密码、DNS、版本口径（见 7 节决策记录）；剩余：管理节点选型 + Phase 2 实际主机 IP 定稿。
2. **Phase 2a**：inventory 改真实 IP；前端静态站上线；e2e 参数化。
3. **Phase 2b**：`deploy-infra.sh` 保持 db/gateway 模式；CI 改为「管理节点集中执行」形态。
4. **Phase 3**：新增 PG 集群组与目标库矩阵；跨库方案评审（FDW/逻辑复制/应用层聚合）。

### 6.6 密码渲染与密钥注入（2026-08-20 已实施）

```bash
# 任意环境渲染（development 用 .env.development 字面值；staging/production 用 CI Secrets 展开占位符）
bash scripts/render-config.sh <environment> [render_dir]   # 默认输出 .deploy-render/（gitignore）
```

- **产物**：`.env` / `pigsty.yml` / `userlist.txt` 三处一致；staging/production 的 `pigsty.yml` 取自 `infra/pigsty.yml.tpl`，`userlist.txt` 取自 `infra/userlist.txt.tpl`（由开发文件派生，CI 有同步检查）。
- **白名单令牌**：`DB_PASSWORD`、`AUTHENTICATOR_PASSWORD`、`LOGTO_DB_PASSWORD`、`APISIX_ADMIN_KEY`、`JWKS_JSON`、`LOGTO_WEBHOOK_SIGNING_KEY`；其余 `${...}`（如 `${admin_ip}`）保留给 Pigsty 自身使用。
- **fail-closed**：渲染产物残留未替换令牌（`${admin_ip}` 除外）即退出，防止把占位符当密码下发。
- **deploy 脚本自动调用**：`deploy-infra.sh` / `deploy-db.sh` / `deploy-gateway.sh` 首步均执行 render-config.sh 并 source 渲染后的 `.env`。
- **GitHub Actions**：`deploy-all.yml` / `deploy-infra.yml` / `deploy-db.yml` / `deploy-gateway.yml` 的 SSH 部署步骤已注入 6 个 Secrets 到远程环境；密钥仅存于 Environment Secrets（staging/production 分开）。
- **限制**：Secret 值请避免包含单引号（`'`）与空格（SSH 命令内联注入的限制）；密码建议 `openssl rand -base64 18` 级别并规避上述字符。

---

## 7. 决策记录（2026-08-20 用户定稿）与剩余动作

> 本节原为「风险与待澄清问题」，2026-08-20 由项目方逐条定稿。**当前整个 infra 仍以单机部署（Phase 1）为准**；Phase 2a/2b/3 仅作文档补充说明（第 5 节草案），落地需按「剩余动作」执行后再改 `infra/pigsty.yml` 的功能性配置（当前只允许注释说明）。

| # | 决策项 | 决策（用户定稿） | 评估 | 剩余动作 |
| --- | --- | --- | --- | --- |
| 1 | Redis 归属 | 由 **Pigsty REDIS 模块**统一管理（standalone 原生部署），**不进 Docker**；取代 ci-cd v2.1 决策 4「Phase 2 Redis 走 Docker 模块」 | ✅ 合理：与现状（`redis.yml` + `infra/redis.conf` + exporter/监控）一致，单实例无容器化收益；Redis 当前为预留缓存/限流（tech-stack），不参与授权链路 | ✅ **已落地（2026-08-20）**：默认随网关机；多机示例见 `infra/pigsty.phase2.example.yml`（DB 10.0.0.10 / 网关 10.0.0.20 / 前端 10.0.0.30 占位，启用时替换为实际 IP） |
| 2 | logto 库 | 多机后 **logto 库与业务库（app_db）及 public 权限认证模块永远同机同集群** | ✅ 合理：消除跨机依赖；代价是同故障域（Logto 与 DB 同挂），当前规模可接受 | ✅ **已落地（2026-08-20）**：logto 库/用户已声明进 `infra/pigsty.yml` 与 `infra/pigsty.yml.tpl`（pg_databases/pg_users）；`LOGTO_DB_PASSWORD` 已加入 `.env.*` 与 `gateway/.env.example`；compose `DB_URL` 5433 不变 |
| 3 | pg_hba 网段 | 继续**按最小权限收窄** | ✅ 正确：`10.0.0.0/8` 过宽 | 单机阶段不动；Phase 2 落地时收窄为具体网段（如 `10.0.0.0/24`）或逐主机 `/32`（网关机/管理机），保留 127.0.0.1、::1、172.17/172.20（Docker 网段） |
| 4 | 防火墙大并集 | 按角色**收敛端口面** | ✅ 正确：`node_firewall_public_port` 是组级参数，可在各角色组 vars 分别设置 | 单机阶段保留并集；分机后 DB 机、网关机、前端机分别收敛（见 5.4）；注意 Pigsty zone 语义（内网互访走 private/trusted zone 或加内网来源） |
| 5 | 密码一致性 | **CI 渲染 + 密钥管理**（GitHub Secrets） | ✅ 即 GitHub 的 Secrets 能力（仓库/环境级 Secrets，加密存储、运行时注入）；三处一致（pigsty.yml / userlist.txt / .env）由渲染模板保证 | ✅ **已落地（2026-08-20）**：`scripts/render-config.sh` + `deploy-infra/deploy-db/deploy-gateway.sh` 自动渲染（残留令牌 fail-closed）；4 个 deploy workflow 已注入 Secrets；CI 增加 tpl 同步检查（见 §6.6）；进阶可接 Vault/云 Secret Manager（初期不必） |
| 6 | DNS 域名冲突 | 按环境区分域名 | ✅ 合理：多环境并存时用环境前缀（如 `i.staging.pigsty`/`i.prod.pigsty`）或隔离网络 | 单环境阶段维持现状；落地时改 `node_etc_hosts` 与 DNSMASQ 记录 |
| 7 | 版本口径 | **以最终/当前版本为准**；不逐一修改其他文档中的版本号，在 Home 等主要位置提醒 | ✅ 同意：避免文档漂移；相关机制结论在 v4.4/v4.5 一致 | 已在 `wiki/Home.md` 顶部加版本口径提醒；其他文档版本号保持现状 |
| 8 | 部署基准 | **当前以单机部署为准**；Phase 2a/2b/3 仅文档补充说明 + `infra/pigsty.yml` 注释说明 | ✅ 同意：避免提前引入多机复杂度 | ✅ **已落地（2026-08-20）**：`infra/pigsty.yml` 仅注释 + `pigsty.yml.tpl`/`userlist.txt.tpl` 派生；多机示例 `infra/pigsty.phase2.example.yml`（未启用）；单机行为不变 |

---

## 8. 参考资料

- 配置清单（单文件模型）：https://pigsty.cc/docs/concept/iac/inventory/
- 剧本列表：https://pigsty.cc/docs/ref/playbook/
- 剧本执行（-l/-t/-e/-i）：https://pigsty.cc/docs/setup/playbook/
- 配置模板（多机多集群单文件示例）：https://pigsty.cc/docs/conf/
- Docker 部署（容器单机体验）：https://pigsty.cc/docs/setup/docker/
- 端口列表：https://pigsty.cc/docs/ref/port/
- 模块：INFRA：https://pigsty.cc/docs/infra/
- INFRA 仓库软件清单：https://pigsty.cc/docs/repo/infra/list/
- 仓库相关：`infra/pigsty.yml`、`scripts/deploy-infra.sh`、`.github/workflows/deploy-*.yml`、`wiki/03-部署指南/*`、`docs/ci-cd-方案.v2.1修复版.md`
