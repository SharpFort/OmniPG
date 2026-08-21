# APISIX 端口收敛与安全访问方案（2026-08-20）

> 适用范围：OmniPG 网关栈（gateway/docker-compose.yml + gateway/apisix/config.yaml + 相关脚本/wiki）。
> 本文档是「APISIX 四端口（9080/9180/7085/9443）是否都要开放」的落地结论：**对外只保留 9080 一个端口**；管理能力（Admin API + 内置 Dashboard）**仅限内网访问**；运维探针与内部接口按最小暴露原则收窄。

## 1. 背景与目标

历史配置把 APISIX 的 4 个默认端口全部映射到宿主机：

| 端口 | 角色 | 问题 |
|:---:|:---|:---|
| 9080 | 数据面 HTTP | ✅ 对外入口，保留 |
| 9443 | 数据面 HTTPS | ⚠️ 无证书、无流量，纯“预留”，白占暴露面 |
| 9180 | Admin API + 内置 Dashboard | ⚠️ 管理接口暴露到所有网卡，依赖 Admin Key 单点保护 |
| 7085 | Status API | ⚠️ 健康探针，无需对外 |

本次收敛目标：

1. **对外仅保留 9080**（业务流量入口）。
2. **9180 仅内网管理**：允许局域网内管理员浏览器访问 Dashboard，不允许公网访问；`allow_admin` 从 `0.0.0.0/0` 收窄为私网段。
3. **7085 仅本机回环**：宿主绑定 `127.0.0.1:7085`，部署/验证脚本照常可用，局域网不可达。
4. **9443 不再映射宿主**（预留；需要时由外层 LB/反代终结 TLS，或配置证书后恢复）。
5. **9092 Control API 改绑容器内回环** `127.0.0.1`（官方默认值，内部运维接口）。

## 2. 变更总览（before / after）

| 端口 | 变更前（宿主映射） | 变更后（宿主映射） | 说明 |
|:---:|:---|:---|:---|
| 9080 | `9080:9080` | `9080:9080` | 唯一对外端口（数据面 HTTP） |
| 9180 | `9180:9180` | `9180:9180` | Admin API + Dashboard，仅内网管理（allow_admin 收窄私网段） |
| 7085 | `7085:7085` | `127.0.0.1:7085:7085` | 仅本机回环；健康检查脚本仍可用 |
| 9443 | `9443:9443` | 不映射 | 预留；HTTPS 由外层 LB/反代终结后转发 9080 |
| 9092 | 容器内 `0.0.0.0` | 容器内 `127.0.0.1` | Control API 仅容器自身可达 |
| 2379（etcd） | 不映射（保持） | 不映射（保持） | 容器间 `app-etcd:2379`，避免与 Pigsty etcd 冲突 |

## 3. 配置改动明细

### 3.1 gateway/docker-compose.yml

```yaml
    ports:
      - "9080:9080"               # 数据面 HTTP —— 唯一对外端口
      - "9180:9180"               # Admin API + 内置 Dashboard（仅内网管理；浏览器 http://localhost:9180/ui）
      - "127.0.0.1:7085:7085"     # Status API（仅本机回环：供健康检查脚本，不暴露局域网）
      # 9443（数据面 HTTPS）不再映射宿主：预留；需要 HTTPS 时由外层 LB/反代终结 TLS 后转发 9080，
      # 或在 config.yaml 配置 ssl 证书后恢复映射
```

- `9443:9443` 行已删除；`7085:7085` 改为 `127.0.0.1:7085:7085`。
- 头部变更记录新增 ⑥（2026-08-20 端口收敛）。

### 3.2 gateway/apisix/config.yaml

```yaml
apisix:
  node_listen: 9080   # 数据面 HTTP —— 唯一对外端口
  # 数据面 HTTPS 沿用镜像默认监听 9443，但 compose 不再映射宿主端口（预留）；
  # 需要 HTTPS 时由外层 LB/反代终结 TLS，或在本文件配置 ssl 证书后恢复 9443 映射
  enable_ipv6: false

  # Control API（内部运维接口）：仅本容器回环可达，勿暴露公网
  enable_control: true
  control:
    ip: "127.0.0.1"
    port: 9092

  # Status API（健康/就绪探针，供部署脚本与 e2e 使用）
  # 容器内保持 0.0.0.0 供 Docker healthcheck/脚本使用；宿主映射已限 127.0.0.1:7085
  status:
    ip: "0.0.0.0"
    port: 7085
```

```yaml
    allow_admin:                     # 仅内网管理：私网段 + 回环；生产可按需再加公司出口/VPN 段
      - 127.0.0.0/8
      - 10.0.0.0/8
      - 172.16.0.0/12
      - 192.168.0.0/16
```

要点：

- `allow_admin` 从 `0.0.0.0/0` 收窄为私网段。172.16.0.0/12 覆盖 Docker bridge 网段（app-net 172.20.0.0/16），保证经 docker-proxy 转发的本机请求不被 403。
- `control.ip` 从 `0.0.0.0` 改回官方默认 `127.0.0.1`（Control API 当前无消费方，纯运维接口）。
- Status API 容器内保留 `0.0.0.0`（暴露面由宿主映射 `127.0.0.1:7085` 控制；若改成容器内 127.0.0.1 会导致 Docker 端口映射失效，勿改）。

### 3.3 环境变量（根目录 .env.example / .env.development / .env.staging / .env.production）

APISIX 段注释更新，变量值不变：

```bash
# APISIX（端口收敛策略 2026-08-20：对外仅 9080；9180 仅内网管理；9443 预留未映射宿主）
APISIX_HTTP_PORT=9080
APISIX_HTTPS_PORT=9443   # 预留：compose 当前未映射宿主（需要时由外层 LB 终结 TLS 或恢复映射）
APISIX_ADMIN_PORT=9180   # 仅内网管理（Admin API + 内置 Dashboard /ui）
```

### 3.4 infra/pigsty.yml（节点防火墙端口清单）

- `node_firewall_public_port` 中移除 9443；保留 9180 并注释为「仅内网管理」（按内网来源放行）。
- 9080 为唯一对外端口。

### 3.5 脚本提示（无功能变化）

- `scripts/start.sh`：访问地址输出标注「9080 唯一对外入口」「9180 仅内网管理」。
- `scripts/verify-stack.sh`：Status/Dashboard/Admin 检查提示补充「仅本机回环 / 仅内网管理」。
- `scripts/README.md`：服务端口速查补充 9180、7085 行与暴露说明。

> 脚本功能本身不受影响：7085 仍映射到宿主回环，`curl http://localhost:7085/status`、`curl http://localhost:9180/...` 全部照常。

## 4. 安全边界说明

| 项 | 现状 | 说明 |
|:---|:---|:---|
| 对外端口 | 仅 9080 | 业务 API 入口（jwt-auth 验签 + 路由 + CORS） |
| Admin API 9180 | 内网可达 | `allow_admin` 收窄为私网段；生产建议再按公司网段/出口 IP 细化 |
| Dashboard /ui | 与 9180 同端口 | 浏览器内网访问 `http://<内网IP>:9180/ui`，输入 Admin Key |
| Status 7085 | 仅本机回环 | 局域网/公网不可达 |
| Control 9092 | 容器内回环 | 其他容器亦不可达 |
| 9443 | 未映射宿主 | 容器内默认监听但对外不可达 |
| etcd 2379 | 未映射宿主 | 容器间 `app-etcd:2379` |
| Admin Key | ⚠️ 需更换 | compose 兜底值仍是官方示例 `edd1c9f034335f136f87ad84b625c8f1`，**非本地环境必须更换**（`openssl rand -hex 16`） |

> Dashboard 只能管理**运行时资源**（路由/插件/上游/消费者）；启动配置（端口、etcd、Admin Key、`enable_admin_ui` 本身）仍只能改 `config.yaml` 后重启容器。

## 5. 应用变更（重启容器）

config.yaml 是只读挂载，且 compose 端口映射已变，需重建 APISIX 容器：

```bash
cd gateway
docker compose up -d --force-recreate apisix
# 确认端口绑定
docker compose ps apisix
# 输出应显示:
#   0.0.0.0:9080->9080/tcp, 0.0.0.0:9180->9180/tcp, 127.0.0.1:7085->7085/tcp
```

路由数据存 etcd，重建容器后无需重跑 `init-apisix-routes.sh`（除非路由缺失，见验证）。

## 6. 验证清单

本机：

```bash
# ① 数据面（对外入口）
curl -sf http://localhost:9080/logto/oidc/.well-known/openid-configuration | head -c 120

# ② Status API（仅本机回环）
curl -sf http://localhost:7085/status        # {"status":"ok"}

# ③ Admin API + Dashboard（内网管理）
curl -sf http://localhost:9180/ui | grep -qi html && echo "Dashboard OK"
curl -s http://localhost:9180/apisix/admin/routes -H "X-API-KEY: $APISIX_ADMIN_KEY" | python3 -m json.tool | head

# ④ 无 token 业务请求应 401
curl -s -o /dev/null -w '%{http_code}\n' http://localhost:9080/api/v1/platform/role   # 401
```

局域网另一台机器：

```bash
# 管理可达（内网放行 9180 时）
curl -s http://<服务器内网IP>:9180/apisix/admin/routes -H "X-API-KEY: <key>" | head -c 200

# 业务可达
curl -s -o /dev/null -w '%{http_code}\n' http://<服务器内网IP>:9080/api/v1/platform/role   # 401（未带 token）

# 探针不可达（回环绑定，预期失败）
curl -s --max-time 3 http://<服务器内网IP>:7085/status && echo "⚠️ 不应成功" || echo "OK 不可达"
```

## 7. 内网/远程管理方式

1. **同机管理**：浏览器打开 `http://localhost:9180/ui`，输入 Admin Key。
2. **内网管理**：浏览器打开 `http://<服务器内网IP>:9180/ui`（需主机防火墙放行 9180 的内网来源，见 §3.4）。
3. **远程/公网管理（推荐 SSH 隧道）**：不要把 9180 直接暴露公网：

   ```bash
   ssh -L 9180:127.0.0.1:9180 user@服务器公网IP
   # 然后本机浏览器打开 http://localhost:9180/ui
   ```

4. **脚本/自动化**：在服务器本机执行（`init-apisix-routes.sh`、`verify-stack.sh` 均走 localhost），或经 SSH 执行。

## 8. HTTPS 恢复方式（9443 预留说明）

当前无证书、无 HTTPS 流量，故不映射 9443。两种恢复路径：

- **外层反代**（推荐）：Nginx/Caddy/云 LB 终结 TLS（443），转发到 `127.0.0.1:9080`；APISIX 配置不变。
- **APISIX 自持证书**：在 `config.yaml` 配置 `apisix.ssl`（证书文件或 ssl 插件），恢复 compose 映射 `9443:9443`，并用 Admin API 创建 ssl 资源绑定域名。

## 9. 回滚

```bash
git checkout gateway/docker-compose.yml gateway/apisix/config.yaml infra/pigsty.yml \
  scripts/start.sh scripts/verify-stack.sh scripts/README.md .env.example
cd gateway && docker compose up -d --force-recreate apisix
```

回滚后 `allow_admin` 恢复 `0.0.0.0/0`、7085/9443 恢复全映射——仅用于临时排查，之后应重新套用本方案。

## 10. 官方文档依据

- [Getting Started with Apache APISIX](https://apisix.apache.org/docs/apisix/getting-started/README/)——9080 数据面 + 9180 Admin API 标准用法
- [Port Reference（端口参考）](https://docs.apiseven.com/apisix/networking/port-reference)（[英文版](https://docs.api7.ai/apisix/networking/port-reference)）——9080/9443/9180/9092/7085 官方端口语义
- [Dashboard（内置 UI）](https://apisix.apache.org/zh/docs/apisix/dashboard/)——`/ui` 挂在 Admin API 端口，经 Admin API 交互，需 Admin Key
- [Deployment Modes（部署模式）](https://apisix.apache.org/zh/docs/apisix/deployment-modes/)——traditional 模式 = 数据面 + 控制面同一实例
- [Status API](https://apisix.apache.org/zh/docs/apisix/status-api/)——7085 健康探针

## 11. 关联文档

- [网关路由（对外端口与服务映射表）](../06-API参考/网关路由.md)
- [安全（端口收敛清单）](安全设计.md)
- [部署指南总览](../03-部署指南/部署总览.md)
- [环境配置（APISIX 端口变量）](../03-部署指南/环境配置.md)
- [21 号审查文档（APISIX 全栈部署可行性分析）](../../docs/审查文档/21-APISIX全栈部署可行性分析-网关AdminAPI与Dashboard.md)
