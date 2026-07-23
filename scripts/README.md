# OmniPG 开发环境 — 一键启动/停止指南

> **适用项目：** 零后端代码统一权限管理系统  
> **更新日期：** 2026-07-23  
> **位置：** `E:\Projects\OmniPG\scripts\`

---

## 一、脚本说明

| 脚本 | 用途 | 执行方式 |
|:---|:---|:---|
| `start.sh` | 一键启动整个开发环境 | `cd scripts && ./start.sh` |
| `stop.sh` | 一键停止 Docker Compose + 可选停止核心服务 | `cd scripts && ./stop.sh` |

---

## 二、快速启动

### 前提条件

1. **WSL2 Ubuntu 26.04** 已安装
2. **Pigsty v4.4.0** 已部署（首次部署见下文）
3. **Docker Desktop WSL2 集成** 已启用（可选，用于 Docker Compose 服务）

### 一键启动

```bash
cd ~/OmniPG/scripts   # 或 cd /mnt/e/Projects/OmniPG/scripts
./start.sh
```

启动脚本会自动：
1. 启动 PostgreSQL 18 + pgBouncer
2. 启动 Redis + etcd
3. 启动 Grafana
4. 检查并启动 Docker
5. 启动 Docker Compose 服务（APISIX/PostgREST/Casdoor）
6. 验证所有服务健康状态

---

## 三、一键停止

```bash
./stop.sh
```

---

## 四、首次部署（全新环境）

如果是首次从零开始部署，按以下顺序执行：

### 1. 准备 WSL2

```bash
# 更新系统
sudo apt update && sudo apt upgrade -y

# 确保 systemd 已启用
cat /etc/wsl.conf
# 应有 [boot] systemd=true
```

### 2. 安装 Pigsty

```bash
# 下载 Pigsty
curl -fsSL https://pigsty.cc/get | bash -s v4.4.0

cd ~/pigsty

# 配置
./configure -i $(hostname -I | awk '{print $1}') -n -s

# 编辑 pigsty.yml 启用模块
vim pigsty.yml

# 部署所有模块
./deploy.yml
```

### 3. 部署 etcd（如未包含在 deploy.yml）

```bash
cd ~/pigsty
./etcd.yml
```

### 4. 配置 PostgreSQL

```bash
# 创建用户和数据库
su - postgres -c "psql -c \"CREATE USER app_owner WITH PASSWORD 'dev_password_change_me' CREATEDB;\""
su - postgres -c "psql -c \"CREATE USER authenticator WITH PASSWORD 'authenticator_dev_pass';\""
su - postgres -c "psql -c \"CREATE USER casdoor WITH PASSWORD 'casdoor_dev_pass';\""
su - postgres -c "psql -c \"CREATE ROLE web_anon NOLOGIN;\""
su - postgres -c "psql -c \"CREATE DATABASE app_db OWNER app_owner;\""
su - postgres -c "psql -c \"CREATE DATABASE casdoor OWNER casdoor;\""

# 安装扩展
su - postgres -c "psql -d app_db -c \"CREATE EXTENSION IF NOT EXISTS pgcrypto, pgsodium, pgaudit, pgtap, pg_graphql, pg_cron;\""

# 配置 shared_preload_libraries
echo "shared_preload_libraries = 'pg_net,pg_cron'" >> /etc/postgresql/18/main/postgresql.conf
su - postgres -c "psql -d app_db -c \"CREATE EXTENSION IF NOT EXISTS pg_net;\""

# 重启
systemctl restart postgresql@18-main
```

### 5. 配置 pgBouncer

```bash
sudo mkdir -p /etc/pgbouncer
sudo tee /etc/pgbouncer/pgbouncer.ini > /dev/null <<EOF
[databases]
app_db = host=127.0.0.1 port=5432 dbname=app_db
casdoor = host=127.0.0.1 port=5432 dbname=casdoor

[pgbouncer]
listen_addr = 0.0.0.0
listen_port = 6432
auth_type = md5
auth_file = /etc/pgbouncer/userlist.txt
pool_mode = session
max_client_conn = 100
default_pool_size = 20
EOF

sudo tee /etc/pgbouncer/userlist.txt > /dev/null <<EOF
"app_owner" "dev_password_change_me"
"authenticator" "authenticator_dev_pass"
"casdoor" "casdoor_dev_pass"
EOF

sudo chown postgres:postgres /etc/pgbouncer/*
sudo chmod 640 /etc/pgbouncer/userlist.txt
```

### 6. 启动 pgBouncer

```bash
sudo -u postgres /usr/sbin/pgbouncer /etc/pgbouncer/pgbouncer.ini &
```

### 7. 启用 Docker Desktop WSL2 集成

在 Windows 端：
1. 打开 Docker Desktop
2. Settings → Resources → WSL Integration
3. 勾选 "Ubuntu-26.04"
4. Apply & Restart

### 8. 验证

```bash
# 测试 PG
PGPASSWORD=dev_password_change_me psql -h 127.0.0.1 -U app_owner -d app_db -c "SELECT 1"

# 测试 pgBouncer
PGPASSWORD=dev_password_change_me psql -h 127.0.0.1 -p 6432 -U app_owner -d app_db -c "SELECT 1"

# 测试 Redis
redis-cli ping

# 测试 etcd
curl -sk https://127.0.0.1:2379/health

# 测试 Grafana
curl -s http://localhost:3000/api/health
```

---

## 五、服务端口速查

| 端口 | 组件 | 访问地址 |
|:---|:---|:---|
| 5432 | PostgreSQL | `psql -h localhost -U app_owner -d app_db` |
| 6432 | pgBouncer | `psql -h localhost -p 6432 -U app_owner -d app_db` |
| 6379 | Redis | `redis-cli -h localhost ping` |
| 2379 | etcd | `curl -k https://localhost:2379/health` |
| 3000 | Grafana | http://localhost:3000 (admin/pigsty) |
| 8428 | VictoriaMetrics | http://localhost:8428 |
| 9428 | VictoriaLogs | http://localhost:9428 |
| 9080 | APISIX (Docker) | http://localhost:9080 |
| 8000 | Casdoor (Docker) | http://localhost:8000 |
| 8082 | Swagger UI (Docker) | http://localhost:8082 |

---

## 六、常见问题

### Redis 无法启动

```bash
# 检查端口占用
ss -tlnp | grep 6379
# 清理
sudo fuser -k 6379/tcp 2>/dev/null
sudo systemctl start redis-server
```

### pgBouncer 连接失败

```bash
# 重启 pgBouncer
pkill pgbouncer
sudo -u postgres /usr/sbin/pgbouncer /etc/pgbouncer/pgbouncer.ini &
```

### PostgreSQL TCP 连接超时

```bash
# 确保 listen_addresses 包含 localhost
grep listen_addresses /etc/postgresql/18/main/postgresql.conf
# 确保 pg_hba.conf 允许本地 TCP 连接
grep -v '^#' /etc/postgresql/18/main/pg_hba.conf | grep -v '^$'
```

### Docker 不可用

在 Docker Desktop Settings 中启用 WSL2 Integration for Ubuntu-26.04

---

## 七、目录结构

```
E:\Projects\OmniPG\
├── scripts\
│   ├── start.sh          # 一键启动
│   ├── stop.sh           # 一键停止
│   └── README.md         # 本文档
├── deploy\
│   ├── pigsty.yml        # Pigsty 完整配置
│   ├── pgbouncer.ini     # pgBouncer 配置
│   ├── userlist.txt      # pgBouncer 用户列表
│   ├── redis.conf        # Redis 配置
│   ├── pg_hba.conf       # PostgreSQL HBA 配置
│   └── postgresql.conf   # PostgreSQL 配置
├── docs\                 # 文档
├── db\                   # 数据库脚本
├── apisix\               # APISIX 配置
├── syncer\               # Policy Syncer
├── docker-compose.yml    # Docker Compose 配置
└── .env                  # 环境变量
```
