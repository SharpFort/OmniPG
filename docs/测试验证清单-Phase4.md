# OmniPG Phase 4: 测试验证执行清单

> **目标**：验证本地 WSL2 + Docker 环境能完整运行 OmniPG 系统
> **执行环境**: Windows 11 + WSL2 Ubuntu 26.04 + Docker Desktop
> **执行日期**: 2026-07-26

---

## 前置条件检查

### 1.1 Docker Desktop Redis 端口修改

**目的**：避免与 WSL2 Pigsty Redis（端口 6379）冲突

**操作步骤**：
1. 打开 Docker Desktop → Containers
2. 找到 Redis 容器（如 `app-redis` 或其他项目 Redis）
3. 停止容器 → Settings → 修改端口映射：`6379` → `6380`
4. 重启容器

**验证命令**：
```bash
# 在 PowerShell 中
netstat -ano | grep ":6379\|:6380"
# 预期：6380 监听中，6379 未被占用
```

### 1.2 WSL2 基础服务状态

**验证命令**：
```bash
# 进入 WSL2
wsl -d Ubuntu-26.04

# 检查 systemd
systemctl is-system-running
# 预期：degraded（正常）

# 检查 PostgreSQL
PGPASSWORD=dev_password_change_me psql -h 127.0.0.1 -U app_owner -d app_db -c "SELECT 1"
# 预期：返回 1

# 检查 Redis
redis-cli ping
# 预期：PONG

# 检查 etcd
etcdctl endpoint health
# 预期：healthy

# 检查 Docker
docker --version
docker ps
# 预期：Docker 可用
```

---

## Step 1: Pigsty 基础设施验证

### 1.1 配置文件同步

```bash
cd ~/OmniPG

# 确保 infra/pigsty.yml 是最新的
cp infra/pigsty.yml ~/pigsty/pigsty.yml

# 复制 PG 相关配置
sudo cp infra/pg_hba.conf ~/pigsty/pg_hba.conf
sudo cp infra/pgbouncer.ini /etc/pgbouncer/pgbouncer.ini
sudo cp infra/redis.conf /etc/redis/redis.conf
sudo cp infra/userlist.txt /etc/pgbouncer/userlist.txt
sudo chmod 640 /etc/pgbouncer/userlist.txt

# 重启相关服务
pg_ctlcluster 18 main restart
sudo -u postgres /usr/sbin/pgbouncer /etc/pgbouncer/pgbouncer.ini &
sudo systemctl restart redis-server
```

### 1.2 数据库初始化扩展

```bash
# 安装需要 shared_preload_libraries 的扩展
su - postgres -c "psql -d app_db -c \"ALTER SYSTEM SET shared_preload_libraries = 'pg_net,pg_cron';\""
pg_ctlcluster 18 main restart

# 创建扩展
su - postgres -c "psql -d app_db -c \"
CREATE EXTENSION IF NOT EXISTS pgcrypto;
CREATE EXTENSION IF NOT EXISTS pgsodium;
CREATE EXTENSION IF NOT EXISTS pg_net;
CREATE EXTENSION IF NOT EXISTS pgaudit;
CREATE EXTENSION IF NOT EXISTS pgtap;
CREATE EXTENSION IF NOT EXISTS pg_graphql;
CREATE EXTENSION IF NOT EXISTS pg_cron;
\""

# 验证扩展
PGPASSWORD=dev_password_change_me psql -h 127.0.0.1 -U app_owner -d app_db -c "SELECT extname FROM pg_extension ORDER BY extname;"
```

---

## Step 2: 数据库迁移和源码部署

### 2.1 dbmate 迁移

```bash
cd ~/OmniPG

# 检查 dbmate 是否安装
which dbmate || (curl -fsSL https://github.com/amacneil/dbmate/releases/latest/download/dbmate-linux-amd64 -o /usr/local/bin/dbmate && chmod +x /usr/local/bin/dbmate)

# 应用迁移
export DBMATE_DATABASE_URL="postgres://app_owner:dev_password_change_me@127.0.0.1:5432/app_db?sslmode=disable"
cd db
dbmate status
dbmate up
dbmate status
```

### 2.2 幂等源码刷入

```bash
cd ~/OmniPG
bash scripts/apply-src.sh "postgres://app_owner:dev_password_change_me@127.0.0.1:5432/app_db?sslmode=disable"
```

### 2.3 初始化数据（首次）

```bash
cd ~/OmniPG/db/init

# 执行初始化脚本（仅首次）
PGPASSWORD=dev_password_change_me psql -h 127.0.0.1 -U app_owner -d app_db -f 01-extensions.sql
PGPASSWORD=dev_password_change_me psql -h 127.0.0.1 -U app_owner -d app_db -f 02-schemas.sql
PGPASSWORD=dev_password_change_me psql -h 127.0.0.1 -U app_owner -d app_db -f 03-casdoor-db.sql
```

### 2.4 验证数据库

```bash
# 检查 Schema
PGPASSWORD=dev_password_change_me psql -h 127.0.0.1 -U app_owner -d app_db -c "\dn"

# 检查 API 函数
PGPASSWORD=dev_password_change_me psql -h 127.0.0.1 -U app_owner -d app_db -c "SELECT routine_schema, routine_name FROM information_schema.routines WHERE routine_schema LIKE 'api_v1%' ORDER BY routine_schema, routine_name LIMIT 20;"

# 检查 Casdoor 数据库
PGPASSWORD=casdoor_dev_pass psql -h 127.0.0.1 -U casdoor -d casdoor -c "SELECT 1"
```

---

## Step 3: Docker Compose 服务部署

### 3.1 环境配置

```bash
cd ~/OmniPG

# 复制环境变量
cp .env.development gateway/.env

# 检查 gateway/.env 内容
cat gateway/.env
```

### 3.2 启动 Docker Compose

```bash
cd ~/OmniPG/gateway

# 拉取最新镜像
docker compose pull

# 启动服务
docker compose down
docker compose up -d

# 查看状态
docker compose ps
```

### 3.3 服务健康检查

```bash
# APISIX
curl -sf http://localhost:9080/apisix/status
# 预期：200 OK

# PostgREST
curl -sf http://localhost:3001/
# 预期：200 OpenAPI 描述

# Casdoor
curl -sf http://localhost:8000/api/health
# 预期：healthy

# Swagger UI
curl -sf http://localhost:8082/
# 预期：HTML 页面

# Policy Syncer
wget --no-verbose --tries=1 --spider http://localhost:8080/healthz
# 预期：OK
```

---

## Step 4: APISIX 路由初始化

```bash
cd ~/OmniPG
bash scripts/setup_apisix.sh
```

**预期输出**：
- [1/6] 写入 Casbin model 配置... ✅ 完成
- [2/6] 获取 Casdoor JWKS 公钥... ✅ 完成
- [3/6] 配置 jwt-auth 插件... ✅ 完成
- [4/6] 创建 JWKS 公钥端点路由... ✅ 完成
- [5/6] 创建业务路由 (api-v1)... ✅ 完成
- [6/6] 创建 Casdoor Callback 路由... ✅ 完成

---

## Step 5: 前端开发环境启动

```bash
# 在 Windows PowerShell 中（非 WSL2）
cd E:\Projects\OmniPG

# 启动 Vite 开发服务器
npm run dev
# 或
pnpm dev
```

**预期**：前端启动在 http://localhost:5173

---

## Step 6: 最终验收检查

### 6.1 Swagger UI 访问

```
浏览器访问: http://localhost:8082/

预期：
- Swagger UI 页面加载成功
- API 列表显示以下 3 个 Tag 分组：
  - api_v1_sys（系统管理：用户/角色/权限/菜单/审计）
  - api_v1_sales（销售域：订单/客户）
  - api_v1_inventory（库存域：库存/仓储/产品）
```

### 6.2 模块切换测试

```
在 Swagger UI 中：
1. 点击顶部下拉框，选择 "api_v1_sys"
   - 预期：显示 sys_user, sys_role, sys_api, sys_menu 等接口
2. 点击顶部下拉框，选择 "api_v1_sales"
   - 预期：显示 v_my_orders, rpc_checkout 等接口
3. 点击顶部下拉框，选择 "api_v1_inventory"
   - 预期：显示 v_stock_summary 等接口
```

### 6.3 Schema 隔离验证

```bash
# 验证 API 层对象存在于正确的 Schema 中
PGPASSWORD=dev_password_change_me psql -h 127.0.0.1 -U app_owner -d app_db -c "
SELECT schemaname, tablename 
FROM pg_tables 
WHERE schemaname LIKE 'api_v1%'
ORDER BY schemaname, tablename;
"
# 预期：看到 api_v1_sys, api_v1_sales, api_v1_inventory 三个 Schema

# 验证业务域 Schema 存在
PGPASSWORD=dev_password_change_me psql -h 127.0.0.1 -U app_owner -d app_db -c "
SELECT schema_name 
FROM information_schema.schemata 
WHERE schema_name IN ('sales', 'inventory')
ORDER BY schema_name;
"
# 预期：看到 sales, inventory
```

### 6.4 APISIX 路径重写验证

```bash
# sys 模块路径重写测试
curl -sf http://localhost:9080/api/v1/sys/v_user_list | head -c 200
# 预期：返回 JSON 数据

# sales 模块路径重写测试
curl -sf http://localhost:9080/api/v1/sales/v_my_orders | head -c 200
# 预期：返回 JSON 数据

# inventory 模块路径重写测试
curl -sf http://localhost:9080/api/v1/inventory/v_stock_summary | head -c 200
# 预期：返回 JSON 数据
```

### 6.5 认证流程测试

```bash
# 登录获取 Token
curl -X POST http://localhost:9080/api/v1/rpc/user_login_sso \
  -H "Content-Type: application/json" \
  -d '{"p_username":"admin","p_password":"admin123"}'

# 使用 Token 访问受保护接口
curl http://localhost:9080/api/v1/sys_user \
  -H "Authorization: Bearer <token>"
```

### 6.6 监控面板

```
浏览器访问:
- Grafana: http://localhost:3000 (admin/pigsty)
- VictoriaMetrics: http://localhost:8428
```

---

## 故障排查

### 问题 1: 端口冲突

```bash
# 检查端口占用
netstat -ano | grep ":5432\|:6379\|:6432\|:9080\|:3001"

# 解决：停止冲突服务或修改端口映射
```

### 问题 2: Docker 容器无法连接主机服务

```bash
# 检查 extra_hosts 配置
docker exec app-apisix cat /etc/hosts | grep host.docker.internal

# 解决：确保 docker-compose.yml 中有 extra_hosts 配置
```

### 问题 3: APISIX JWT 验证失败

```bash
# 检查插件元数据
curl -s http://localhost:9180/apisix/admin/plugin_metadata/jwt-auth \
  -H "X-API-KEY: edd1c9f034335f136f87ad84b625c8f1"

# 解决：重新运行 setup_apisix.sh
```

---

## 验收签字

| 检查项 | 状态 | 备注 |
|:---|:---|:---|
| Docker Redis 端口改为 6380 | ⬜ | |
| PostgreSQL 运行正常 | ⬜ | |
| Redis 运行正常 | ⬜ | |
| etcd 运行正常 | ⬜ | |
| Docker Compose 服务启动（无 Redis） | ⬜ | |
| PostgREST 多 Schema 配置正确 | ⬜ | |
| APISIX 3 个模块路由正常 | ⬜ | |
| 数据库迁移成功 | ⬜ | |
| 幂等源码刷入成功 | ⬜ | |
| APISIX 路由初始化成功 | ⬜ | |
| Swagger UI 可访问 | ⬜ | |
| api_v1_sys 模块显示 | ⬜ | |
| api_v1_sales 模块显示 | ⬜ | |
| api_v1_inventory 模块显示 | ⬜ | |
| 模块切换正常 | ⬜ | |
| Schema 隔离验证通过 | ⬜ | |
| APISIX 路径重写验证通过 | ⬜ | |
| 认证流程正常 | ⬜ | |
