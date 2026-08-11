# Phase 4 部署测试问题记录

> **测试日期**: 2026-07-27  
> **分支**: `fix/cicd-v2-deployment-issues`  
> **测试环境**: WSL2 Ubuntu 26.04 + Docker Desktop  
> **WSL2 IP**: `192.168.0.128`

---

## 测试结果汇总

| 服务 | 状态 | 说明 |
|:---|:---|:---|
| PostgreSQL 18 | ✅ 正常 | `psql -h 127.0.0.1 -U app_owner -d app_db` 连接成功 |
| Redis | ✅ 正常 | `redis-cli ping` 返回 PONG |
| etcd | ✅ 正常 | `systemctl status etcd` active (running) |
| Docker | ✅ 正常 | Docker 29.5.3 可用 |
| Casdoor | ✅ 正常 | `http://192.168.0.128:8000` 可访问 |
| Swagger UI | ✅ 正常 | `http://192.168.0.128:8082` HTTP 200 |
| PostgREST | ✅ 正常 | `http://192.168.0.128:3001` 返回 OpenAPI JSON |
| APISIX | ✅ 正常 | `http://192.168.0.128:9080` 路由加载成功 |
| Pigsty/Nginx | ✅ 正常 | `http://192.168.0.128:8080` 端口从80改为8080 |

---

## 问题 #1: PostgREST 401 Unauthorized (role "web_anon")

**现象**:
```bash
curl http://localhost:3001/
# 返回: {"code":"42501","details":null,"hint":null,"message":"permission denied to set role \"web_anon\""}
```

**原因**: `authenticator` 角色未被授权 `web_anon` 角色，PostgREST 无法切换到匿名角色。

**修复**:
```bash
su - postgres -c "psql -d app_db -c 'GRANT web_anon TO authenticator;'"
docker restart app-postgrest
```

**状态**: ✅ 已修复

---

## 问题 #2: PostgREST 缺少 Schema 权限

**现象**:
```bash
curl http://localhost:3001/
# 返回: {"code":"42501","details":null,"hint":null,"message":"permission denied for schema api_v1_sys"}
```

**原因**: `authenticator` 角色缺少 `api_v1_sys`、`api_v1_sales`、`api_v1_inventory` 三个 Schema 的 USAGE 权限。

**修复**:
```bash
PGPASSWORD=dev_password_change_me psql -h 127.0.0.1 -U app_owner -d app_db -c "
  GRANT USAGE ON SCHEMA api_v1_sys TO authenticator;
  GRANT USAGE ON SCHEMA api_v1_sales TO authenticator;
  GRANT USAGE ON SCHEMA api_v1_inventory TO authenticator;
  GRANT ALL ON ALL TABLES IN SCHEMA api_v1_sys TO authenticator;
  GRANT ALL ON ALL TABLES IN SCHEMA api_v1_sales TO authenticator;
  GRANT ALL ON ALL TABLES IN SCHEMA api_v1_inventory TO authenticator;
  GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA api_v1_sys TO authenticator;
  GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA api_v1_sales TO authenticator;
  GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA api_v1_inventory TO authenticator;
"
docker restart app-postgrest
```

**状态**: ✅ 已修复

---

## 问题 #3: check_token_blacklist 函数缺失

**现象**:
```bash
curl http://localhost:3001/
# 返回: {"code":"42883","details":null,"hint":"No function matches...","message":"function api_v1_sys.check_token_blacklist() does not exist"}
```

**原因**: 
1. `db/src/public/functions/check_token_blacklist.sql` 文件存在
2. `apply-src.sh` 脚本使用 `psql "$DB_URL"` 方式连接，密码中的特殊字符导致认证失败
3. 幂等源码未被刷入数据库

**临时修复**:
```bash
export PGPASSWORD=dev_password_change_me
cd ~/OmniPG
for f in $(find db/src -name '*.sql' -not -name '_*' | sort); do
  psql -h 127.0.0.1 -U app_owner -d app_db -v ON_ERROR_STOP=0 -f "$f"
done
docker restart app-postgrest
```

**手动修复函数**:
```bash
psql -h 127.0.0.1 -U app_owner -d app_db -f db/src/public/functions/check_token_blacklist.sql
psql -h 127.0.0.1 -U app_owner -d app_db -c "ALTER FUNCTION check_token_blacklist() SET SCHEMA api_v1_sys;"
psql -h 127.0.0.1 -U app_owner -d app_db -c "GRANT EXECUTE ON FUNCTION api_v1_sys.check_token_blacklist() TO authenticator;"
```

**根本修复建议**: 修改 `apply-src.sh` 使用 `PGPASSWORD` 环境变量替代 URL 传递密码。

**状态**: ✅ 已修复

---

## 问题 #4: APISIX 容器启动失败 — apisix.yaml 缺少 #END

**现象**:
```bash
docker ps -a
# app-apisix: Exited (1)

docker logs app-apisix --tail 10
# /usr/local/openresty//luajit/bin/luajit: /usr/local/apisix/apisix/cli/ops.lua:783: 
# bad argument #1 to 'floor' (number expected, got nil)
```

**原因**: 
1. `apisix.yaml` 文件缺少末尾的 `#END` 标记符（APISIX standalone 模式要求）
2. `authz-casbin` 插件的 `target_value: "request_uri"` 格式无效
3. `casbin_rule` 文件不存在（被 `.gitignore` 忽略）
4. `config.yaml` 缺少 `nginx_config` 配置段

**修复**:
1. 在 `apisix.yaml` 末尾添加 `#END`
2. 暂时移除 `authz-casbin` 插件，保留 `jwt-auth` 验证链路
3. 创建空的 `casbin_rule` 文件并挂载到容器
4. 重写 `config.yaml` 使用标准 standalone 配置

**关键发现**: APISIX standalone 模式（`config_provider: yaml`）严格要求 `apisix.yaml` 末尾必须有 `#END`，否则解析失败。

**状态**: ✅ 已修复

---

## 问题 #5: postgrest.conf 连接地址错误

**现象**: PostgREST 容器启动后无法连接到 PostgreSQL。

**原因**: `postgrest.conf` 中 `db-uri = "postgres://authenticator:***@pgbouncer:6432/app_db"` 使用了容器内部 DNS `pgbouncer`，但 PostgREST 和 pgbouncer 不在同一 Docker 网络中。

**修复**: 改为宿主机地址：
```toml
db-uri = "postgres://authenticator:dev_password_change_me@host.docker.internal:6432/app_db?sslmode=disable"
```

**状态**: ✅ 已修复

---

## 问题 #6: Docker Compose 未挂载 postgrest.conf

**现象**: 修改 `postgrest.conf` 后，PostgREST 容器内部配置未更新。

**原因**: `docker-compose.yml` 中 postgrest 服务缺少 `postgrest.conf` 的 volume 挂载。

**修复**: 添加挂载：
```yaml
volumes:
  - ./postgrest/postgrest.conf:/etc/postgrest.conf:ro
```

**状态**: ✅ 已修复

---

## 问题 #7: Swagger UI CORS 失败

**现象**: Windows 浏览器访问 Swagger UI 时，API 请求被 CORS 策略阻止。

**原因**: Swagger UI 容器环境变量 `API_URL: "http://localhost:3001/"` 指向容器内部地址，Windows 浏览器无法解析。

**修复**: 改为 WSL2 IP 地址：
```yaml
environment:
  API_URL: "http://192.168.0.128:3001/"
```

**状态**: ✅ 已修复

---

## 问题 #8: Nginx 端口 80 被占用

**现象**: 访问 Pigsty Web 管理界面返回 Nginx 默认页或无法访问。

**原因**: Windows 主机上 PID 26268 (dllhost.exe) 占用了 80 端口。

**修复**: 修改 `/etc/nginx/conf.d/home.conf`：
```nginx
server {
    listen 8080;
    # ... 其他配置不变
}
```

**状态**: ✅ 已修复（Pigsty 现通过 8080 端口访问）

---

## 问题 #9: e2e-test.sh 使用 docker exec

**现象**: E2E 测试脚本执行 `docker exec app-postgrest psql` 失败。

**原因**: 容器内未安装 `psql` 客户端。

**修复**: 改为使用宿主机 `psql`：
```bash
psql -h 127.0.0.1 -U app_owner -d app_db -c "SELECT 1"
```

**状态**: ✅ 已修复

---

## 问题 #10: setup_apisix.sh 过度复杂

**现象**: 初始化脚本尝试通过 Admin API 动态创建路由，但与静态 `apisix.yaml` 配置冲突。

**原因**: APISIX standalone 模式下路由由 `apisix.yaml` 静态加载，Admin API 创建的持久化路由在重启后会丢失。

**修复**: 简化为仅配置插件（jwt-auth、authz-casbin 参数校验等），路由由 `apisix.yaml` 管理。

**状态**: ✅ 已修复

---

## 问题 #11: deploy-infra.sh 复制无效文件

**现象**: `deploy-infra.sh` 尝试复制 `infra/pg_hba.conf` 到 `/etc/postgresql/18/main/pg_hba.conf`，但路径不存在。

**原因**: Pigsty 管理的 PostgreSQL 配置文件路径与原生安装不同。

**修复**: 删除该复制步骤，直接使用 Pigsty 默认的 pg_hba 配置。

**状态**: ✅ 已修复

---

## 可访问服务链接

| 服务 | URL | 说明 |
|:---|:---|:---|
| Casdoor | `http://192.168.0.128:8000` | 用户认证服务（admin / 123） |
| Swagger UI | `http://192.168.0.128:8082` | API 文档（OpenAPI） |
| PostgREST | `http://192.168.0.128:3001` | REST API 直连 |
| APISIX 网关 | `http://192.168.0.128:9080` | API 网关入口 |
| APISIX Admin | `http://192.168.0.128:9180` | 网关管理 API |
| Pigsty | `http://192.168.0.128:8080` | PostgreSQL 管理面板 |

---

## 后续改进建议

1. **apply-src.sh 改用 PGPASSWORD** — 避免密码特殊字符解析问题
2. **启用 authz-casbin 完整配置** — 修正 `target_value` 变量格式（需查阅 APISIX 3.17 文档）
3. **Pigsty 接入 Nginx 80 端口** — 需要释放 Windows 80 端口或配置反向代理
4. **Syncer 容器化** — 将 Syncer 纳入 Docker Compose 统一管理
5. **自动化部署脚本** — 整合所有修复步骤为一键部署脚本
