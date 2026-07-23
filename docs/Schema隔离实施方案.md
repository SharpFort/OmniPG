# Schema 隔离实施方案

> **版本：** v1.0  
> **日期：** 2026-07-23  
> **项目：** OmniPG 零后端代码统一权限管理平台  

---

## 1. 总体策略

### 1.1 核心原则

| 原则 | 说明 |
|:---|:---|
| **存量不动** | 现有 `sys` 模块（用户/角色/权限/菜单/审计）保留在 `public` Schema |
| **增量隔离** | 新模块（`sales`、`inventory` 等）使用独立 Schema |
| **灵活外键** | 允许跨 Schema 外键引用（如 `sales.orders.user_id → public.sys_user(id)`） |
| **枚举分离** | 模块专用枚举放各自 Schema，跨模块复用枚举放 `public` |

### 1.2 Schema 规划

```
Schema          用途                    状态
─────────────────────────────────────────────────────────
public          系统管理模块（存量）      已有，保持不变
                sys_user, sys_role, sys_api, sys_menu, sys_tenant...
                跨模块复用枚举类型
                扩展启用（pgcrypto, pg_pwhash）
                跨模块辅助函数

sales           销售域（新模块）         新建，Schema 隔离
                orders, order_items, customers...

inventory       库存域（新模块）         新建，Schema 隔离
                stock, warehouse, products...

api_v1          API 暴露层              已有，保持不变
                PostgREST 暴露的视图和 RPC
```

---

## 2. 新模块创建清单

### 2.1 目录结构

创建新模块 `xxx` 时，需要创建以下目录和文件：

```
db/
├── migrations/
│   └── xxx/                          # 迁移文件目录
│       ├── 001_create_schema.sql     # 创建 Schema + 基础表
│       └── 002_xxx.sql               # 后续迁移
│
├── src/
│   └── xxx/                          # 业务源码目录
│       ├── _init_schema.sql          # Schema 初始化（幂等）
│       ├── functions/                # 内部函数
│       ├── views/                    # 内部视图
│       ├── triggers/                 # 触发器
│       ├── types/                    # 模块专用枚举
│       └── privileges/               # 权限授予
│
├── api_v1/
│   └── xxx/                          # API 暴露层
│       ├── views/                    # API 视图
│       └── rpc/                      # API RPC 函数
│
├── tests/
│   └── xxx/                          # 测试文件
│
└── fixtures/
    └── xxx/                          # 测试数据
```

### 2.2 PostgreSQL Schema 核心机制（必读）

> ⚠️ **关键事实：PostgreSQL 不会根据文件路径自动路由对象到 Schema。**

#### 2.2.1 Schema 前缀决定对象位置

```sql
-- ❌ 错误认知：文件放在 db/src/sales/ 就自动创建到 sales Schema
-- 无论文件放在哪个目录，以下代码都创建在 public Schema：
CREATE FUNCTION create_order() ...   -- → public.create_order
CREATE TABLE orders (...)            -- → public.orders
CREATE VIEW v_orders AS ...          -- → public.v_orders

-- ✅ 正确做法：必须显式指定 Schema 前缀
CREATE FUNCTION sales.create_order() ...  → sales.create_order
CREATE TABLE sales.orders (...)           → sales.orders
CREATE VIEW sales.v_orders AS ...         → sales.v_orders
```

**结论：文件路径是给人看的，Schema 前缀是给 PostgreSQL 看的。两者没有自动关联。**

#### 2.2.2 _init_schema.sql 的作用

| 问题 | 答案 |
|:---|:---|
| `_init_schema.sql` 创建 Schema | ✅ `CREATE SCHEMA IF NOT EXISTS sales` |
| `_init_schema.sql` 设置权限 | ✅ `GRANT USAGE ON SCHEMA sales TO ...` |
| `_init_schema.sql` 自动路由后续对象 | ❌ **不会**！后续 SQL 仍需写 Schema 前缀 |

#### 2.2.3 各路径下 Schema 前缀要求

| 文件路径 | SQL 中是否需要写 Schema 前缀 | 示例 |
|:---|:---|:---|
| `db/src/sales/functions/create_order.sql` | ✅ 需要 | `CREATE FUNCTION sales.create_order()` |
| `db/src/sales/views/v_summary.sql` | ✅ 需要 | `CREATE VIEW sales.v_summary AS ...` |
| `db/src/sales/triggers/trg_orders.sql` | ✅ 需要 | `CREATE TRIGGER ... ON sales.orders` |
| `db/src/sales/types/order_status.sql` | ✅ 需要 | `CREATE TYPE sales.order_status AS ENUM` |
| `db/migrations/sales/001_init.sql` | ✅ 需要 | `CREATE TABLE sales.orders (...)` |
| `db/api_v1/sales/views/v_orders.sql` | ❌ 不需要（在 api_v1 中） | `CREATE VIEW api_v1.v_orders AS ...` |
| `db/api_v1/sales/rpc/rpc_checkout.sql` | ❌ 不需要（在 api_v1 中） | `CREATE FUNCTION api_v1.checkout()` |

#### 2.2.4 执行顺序（严格）

```
┌─────────────────────────────────────────────────────────────────┐
│                   新模块 Schema 创建流程                          │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│  Step 1: 执行 _init_schema.sql                                  │
│  ┌─────────────────────────────────────────────────────────┐   │
│  │ CREATE SCHEMA IF NOT EXISTS sales;                      │   │
│  │ GRANT USAGE ON SCHEMA sales TO app_owner;               │   │
│  │ GRANT USAGE ON SCHEMA sales TO authenticated;           │   │
│  └─────────────────────────────────────────────────────────┘   │
│                                                                 │
│  Step 2: 执行迁移文件（db/migrations/sales/001_init.sql）       │
│  ┌─────────────────────────────────────────────────────────┐   │
│  │ CREATE TABLE sales.orders (...);  ← 必须写 sales. 前缀  │   │
│  │ CREATE TABLE sales.order_items (...);                   │   │
│  │ CREATE INDEX idx_orders_user ON sales.orders(user_id);  │   │
│  └─────────────────────────────────────────────────────────┘   │
│                                                                 │
│  Step 3: 执行业务源码（db/src/sales/）                          │
│  ┌─────────────────────────────────────────────────────────┐   │
│  │ CREATE FUNCTION sales.create_order(...)  ← 必须写前缀   │   │
│  │ CREATE VIEW sales.v_order_summary    ← 必须写前缀       │   │
│  │ CREATE TRIGGER trg_xxx ON sales.orders  ← 必须写前缀    │   │
│  └─────────────────────────────────────────────────────────┘   │
│                                                                 │
│  Step 4: 执行 API 层（db/api_v1/sales/）                        │
│  ┌─────────────────────────────────────────────────────────┐   │
│  │ CREATE VIEW api_v1.v_my_orders                          │   │
│  │ AS SELECT * FROM sales.orders;  ← 引用源表 Schema       │   │
│  │                                                         │   │
│  │ CREATE FUNCTION api_v1.checkout(p_items JSONB)          │   │
│  │ AS $$ SELECT sales.create_order(p_items) $$;            │   │
│  └─────────────────────────────────────────────────────────┘   │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

#### 2.2.5 常见错误示例

| 错误写法 | 实际创建位置 | 正确写法 |
|:---|:---|:---|
| `CREATE FUNCTION create_order()` | `public.create_order` | `CREATE FUNCTION sales.create_order()` |
| `CREATE TABLE orders (...)` | `public.orders` | `CREATE TABLE sales.orders (...)` |
| `CREATE VIEW v_orders AS ...` | `public.v_orders` | `CREATE VIEW sales.v_orders AS ...` |
| `CREATE TYPE order_status AS ENUM` | `public.order_status` | `CREATE TYPE sales.order_status AS ENUM` |

#### 2.2.6 search_path 的影响

```sql
-- 设置 search_path
SET search_path = sales, public, pg_temp;

-- 此时可以省略前缀（不推荐，建议始终显式写前缀）
CREATE FUNCTION create_order() ...  → sales.create_order（因为 sales 在 search_path 第一位）

-- 但强烈建议：无论 search_path 如何，始终写 Schema 前缀
CREATE FUNCTION sales.create_order() ...  → 明确、可读、无歧义
```

---

### 2.3 实施步骤

#### Step 1: 创建 Schema 初始化脚本

**文件：** `db/src/{module}/_init_schema.sql`

**重要：sys 模块不需要 CREATE SCHEMA**

| 模块 | 是否需要 CREATE SCHEMA | 说明 |
|:---|:---|:---|
| `sys` | ❌ 不需要 | 保持在 `public` Schema，仅设置权限 |
| `sales` | ✅ 需要 | `CREATE SCHEMA IF NOT EXISTS sales` |
| `inventory` | ✅ 需要 | `CREATE SCHEMA IF NOT EXISTS inventory` |
| 新模块 | ✅ 需要 | `CREATE SCHEMA IF NOT EXISTS {module}` |

**sys 模块示例（仅权限设置）：**

```sql
-- db/src/sys/_init_schema.sql
-- 注意：sys 模块保持在 public Schema，不创建新 Schema
REVOKE ALL ON SCHEMA public FROM PUBLIC;
GRANT USAGE ON SCHEMA public TO app_owner;
GRANT ALL ON ALL TABLES IN SCHEMA public TO app_owner;
GRANT USAGE ON SCHEMA public TO authenticated;
GRANT SELECT ON ALL TABLES IN SCHEMA public TO authenticated;
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA public TO authenticated;
```

**新模块示例（创建 Schema + 权限）：**

```sql
-- db/src/{module}/_init_schema.sql
CREATE SCHEMA IF NOT EXISTS {module};
COMMENT ON SCHEMA {module} IS '{模块说明}';
GRANT USAGE ON SCHEMA {module} TO app_owner;
GRANT ALL ON ALL TABLES IN SCHEMA {module} TO app_owner;
GRANT ALL ON ALL FUNCTIONS IN SCHEMA {module} TO app_owner;
GRANT USAGE ON SCHEMA {module} TO authenticated;
GRANT SELECT ON ALL TABLES IN SCHEMA {module} TO authenticated;
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA {module} TO authenticated;
```

#### Step 2: 创建迁移文件

**文件：** `db/migrations/{module}/001_create_schema.sql`

```sql
-- 迁移 001: 创建 {module} Schema 和基础表
CREATE SCHEMA IF NOT EXISTS {module};

-- 创建表（使用 Schema 前缀）
CREATE TABLE {module}.orders (
    id UUID PRIMARY KEY DEFAULT uuidv7(),
    -- 跨模块外键引用
    user_id UUID REFERENCES public.sys_user(id) ON DELETE CASCADE,
    ...
);
```

#### Step 3: 创建业务源码

**文件：** `db/src/{module}/functions/xxx.sql`

```sql
-- 函数使用 Schema 前缀
CREATE OR REPLACE FUNCTION {module}.create_order(p_items JSONB)
RETURNS json
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = {module}, public, pg_temp
AS $$ ... $$;
```

#### Step 4: 创建 API 暴露层

**文件：** `db/api_v1/{module}/rpc/xxx.sql`

```sql
-- API RPC 包装函数（在 api_v1 Schema 中）
CREATE OR REPLACE FUNCTION api_v1.create_order(p_items JSONB)
RETURNS json
LANGUAGE sql
SECURITY DEFINER
SET search_path = {module}, public, pg_temp
AS $$ SELECT {module}.create_order(p_items) $$;
```

**重要：API 层 Schema 前缀规则**

| 模块 | 源表所在 Schema | API 层 SQL 中文件路径 | API 层 SQL 中表名前缀 |
|:---|:---|:---|:---|
| sys | `public` | `db/api_v1/sys/views/` | `public.sys_user`（不需要 `sys.`） |
| sales | `sales` | `db/api_v1/sales/views/` | `sales.orders`（需要 `sales.`） |
| inventory | `inventory` | `db/api_v1/inventory/views/` | `inventory.stock`（需要 `inventory.`） |

**规则：**
- 文件路径已经包含模块信息（如 `db/api_v1/sys/views/`）
- SQL 代码中只需要写源表所在 Schema 的前缀
- sys 模块源表在 `public`，所以用 `public.sys_user`
- sales 模块源表在 `sales`，所以用 `sales.orders`

---

## 3. 跨模块外键规则

### 3.1 允许的跨 Schema 引用

| 源 Schema | 目标 Schema | 示例 |
|:---|:---|:---|
| `sales` | `public` | `sales.orders.user_id → public.sys_user(id)` |
| `inventory` | `public` | `inventory.audit_logs.user_id → public.sys_user(id)` |
| `sales` | `inventory` | `sales.order_items.product_id → inventory.products(id)` |

### 3.2 外键约束规范

```sql
-- 跨模块外键示例
ALTER TABLE sales.orders 
ADD CONSTRAINT fk_orders_user_id 
FOREIGN KEY (user_id) REFERENCES public.sys_user(id) ON DELETE CASCADE;
```

**注意：**
- 跨 Schema 外键需要确保目标表已创建
- 迁移文件需要按依赖顺序执行（先 `public`，后 `sales`）
- 使用 `ON DELETE CASCADE` 或 `ON DELETE SET NULL` 避免数据孤岛

---

## 4. 枚举类型管理

### 4.1 枚举放置规则

| 枚举类型 | 放置 Schema | 说明 |
|:---|:---|:---|
| `public.tenant_status` | `public` | 跨模块复用（租户状态） |
| `public.audit_operation` | `public` | 跨模块复用（审计操作） |
| `sales.order_status` | `sales` | 模块专用（订单状态） |
| `inventory.stock_type` | `inventory` | 模块专用（库存类型） |

### 4.2 创建模块专用枚举

```sql
-- db/src/{module}/types/order_status.sql
DO $$ BEGIN
    CREATE TYPE {module}.order_status AS ENUM ('pending', 'paid', 'shipped', 'completed', 'cancelled');
EXCEPTION WHEN duplicate_object THEN null; END $$;
```

---

## 5. 权限管理

### 5.1 角色层次

```
super_admin     → 所有 Schema 的完全控制
role_admin      → 业务 Schema 的管理权限
authenticated   → 所有 Schema 的读权限 + API RPC 执行权限
web_anon        → 仅 api_v1 Schema 的登录函数执行权限
```

### 5.2 Schema 权限脚本模板

```sql
-- 创建 Schema 后执行
REVOKE ALL ON SCHEMA {module} FROM PUBLIC;

GRANT USAGE ON SCHEMA {module} TO app_owner;
GRANT ALL ON ALL TABLES IN SCHEMA {module} TO app_owner;
GRANT ALL ON ALL FUNCTIONS IN SCHEMA {module} TO app_owner;
GRANT ALL ON ALL SEQUENCES IN SCHEMA {module} TO app_owner;

GRANT USAGE ON SCHEMA {module} TO authenticated;
GRANT SELECT ON ALL TABLES IN SCHEMA {module} TO authenticated;
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA {module} TO authenticated;
```

---

## 6. 当前实施状态

### 6.1 已完成

| 模块 | Schema | 状态 | 说明 |
|:---|:---|:---|:---|
| `sys` | `public` | ✅ 保持不变 | 用户/角色/权限/菜单/审计 |
| `sales` | `sales` | 🔄 进行中 | 初始化脚本已创建 |
| `inventory` | `inventory` | 🔄 进行中 | 初始化脚本已创建 |

### 6.2 PostgREST 多 Schema 配置

**文件：** `postgrest/postgrest.conf`

```ini
# 暴露的 Schema（Swagger 按 Schema 名称分组 Tag）
db-schemas = "api_v1_sys, api_v1_sales, api_v1_inventory"

# 额外搜索路径（确保 API 包装函数能找到内部 Schema 的对象）
db-extra-search-path = "api_v1_sys, api_v1_sales, api_v1_inventory, public, sales, inventory, pg_temp"
```

**Swagger UI 分组效果：**

| Schema | Tag 名称 | 包含接口 |
|:---|:---|:---|
| `api_v1_sys` | api_v1_sys | sys_user, sys_role, rpc_user_login, v_user_list, ... |
| `api_v1_sales` | api_v1_sales | v_my_orders, rpc_checkout |
| `api_v1_inventory` | api_v1_inventory | v_stock_summary |

**搜索路径说明：**

| 顺序 | Schema | 作用 |
|:---|:---|:---|
| 1 | `api_v1_sys` | 系统管理 API 函数（优先级最高） |
| 2 | `api_v1_sales` | 销售域 API 函数 |
| 3 | `api_v1_inventory` | 库存域 API 函数 |
| 4 | `public` | 系统管理模块（sys 模块的表和函数） |
| 5 | `sales` | 销售域内部对象 |
| 6 | `inventory` | 库存域内部对象 |
| 7 | `pg_temp` | 临时对象（PostgREST 内部使用） |

**执行链路示例：**

```
浏览器请求：GET /api/v1/sales/v_my_orders
                ↓
APISIX 路径重写：/api_v1_sales/v_my_orders
                ↓
PostgREST 映射：api_v1_sales schema → v_my_orders 视图
                ↓
执行 SQL：SELECT * FROM api_v1_sales.v_my_orders
                ↓
视图内部：SELECT * FROM sales.orders WHERE user_id = current_user_id()
```

---

### 6.3 APISIX 多模块路由配置

**文件：** `apisix/apisix.yaml`

```yaml
# sys 模块路由（优先级 50）
- uri: /api/v1/sys/*
  plugins:
    proxy-rewrite:
      regex_uri: ["^/api/v1/sys/(.*)", "/api_v1_sys/$1"]
    jwt-auth:
      secret: "${JWKS_JSON}"
    authz-casbin:
      model_path: "/usr/local/apisix/conf/casbin_model.conf"
      policy_path: "/usr/local/apisix/conf/casbin_rule"
  priority: 50

# sales 模块路由（优先级 20）
- uri: /api/v1/sales/*
  plugins:
    proxy-rewrite:
      regex_uri: ["^/api/v1/sales/(.*)", "/api_v1_sales/$1"]
    jwt-auth:
      secret: "${JWKS_JSON}"
    authz-casbin:
      model_path: "/usr/local/apisix/conf/casbin_model.conf"
      policy_path: "/usr/local/apisix/conf/casbin_rule"
  priority: 20

# inventory 模块路由（优先级 20）
- uri: /api/v1/inventory/*
  plugins:
    proxy-rewrite:
      regex_uri: ["^/api/v1/inventory/(.*)", "/api_v1_inventory/$1"]
    jwt-auth:
      secret: "${JWKS_JSON}"
    authz-casbin:
      model_path: "/usr/local/apisix/conf/casbin_model.conf"
      policy_path: "/usr/local/apisix/conf/casbin_rule"
  priority: 20
```

**路径重写规则说明：**

| 浏览器请求 URL | APISIX 重写后 | 数据库对象 |
|:---|:---|:---|
| `/api/v1/sys/v_user_list` | `/api_v1_sys/v_user_list` | `api_v1_sys.v_user_list` |
| `/api/v1/sys/rpc/user_login` | `/api_v1_sys/rpc_user_login` | `api_v1_sys.user_login_sso()` |
| `/api/v1/sales/v_my_orders` | `/api_v1_sales/v_my_orders` | `api_v1_sales.v_my_orders` |
| `/api/v1/sales/rpc/checkout` | `/api_v1_sales/rpc_checkout` | `api_v1_sales.checkout()` |
| `/api/v1/inventory/v_stock_summary` | `/api_v1_inventory/v_stock_summary` | `api_v1_inventory.v_stock_summary` |

**优先级说明：**

| 优先级 | 路由 | 说明 |
|:---|:---|:---|
| 100 | `/well-known/jwks` | 公开端点 |
| 90 | `/rpc/user_login_sso`, `/rpc/refresh_token_rtr` | 认证端点 |
| 50 | `/api/v1/sys/*` | sys 模块（最高业务优先级） |
| 40 | `/rpc/*` | 通用 RPC 函数 |
| 20 | `/api/v1/sales/*`, `/api/v1/inventory/*` | 新模块 |
| 10 | `/*` | 通用 CRUD（最低优先级） |

---

### 6.4 新模块添加检查清单

添加新模块时，**必须同步更新以下 3 个地方**：

| # | 更新位置 | 文件 | 说明 |
|:---|:---|:---|:---|
| 1 | PostgREST 搜索路径 | `postgrest/postgrest.conf` | `db-extra-search-path` 添加新 Schema |
| 2 | APISIX 路由规则 | `apisix/apisix.yaml` | 添加新模块的路径重写规则 |
| 3 | Schema 初始化脚本 | `db/src/{module}/_init_schema.sql` | 创建 Schema + 权限设置 |

**遗漏任何一项都会导致模块无法正常工作！**

---

## 7. 注意事项

### 7.1 迁移文件执行顺序

```
1. public Schema 的迁移（sys 模块）
2. sales Schema 的迁移
3. inventory Schema 的迁移
4. 跨模块外键约束（在所有相关表创建后）
```

### 7.2 search_path 设置

```sql
-- 业务函数中设置 search_path
SET search_path = {module}, public, pg_temp;

-- 说明：
-- {module} → 优先查找当前 Schema 的对象
-- public → 查找跨模块共享对象（sys_user 等）
-- pg_temp → 临时对象（PostgREST 需要）
```

### 7.3 测试建议

- 每个模块创建独立的测试目录 `db/tests/{module}/`
- 测试数据使用 `db/fixtures/{module}/` 加载
- 跨模块测试需要确保依赖模块的数据已存在

---

## 8. 快速创建新模块命令

```bash
# 创建模块目录结构
MODULE=new_module
mkdir -p db/migrations/$MODULE db/src/$MODULE/{functions,views,triggers,types,privileges} db/api_v1/$MODULE/{views,rpc} db/tests/$MODULE db/fixtures/$MODULE

# 创建 Schema 初始化脚本
cat > db/src/$MODULE/_init_schema.sql << 'EOF'
CREATE SCHEMA IF NOT EXISTS new_module;
COMMENT ON SCHEMA new_module IS '新模块说明';
GRANT USAGE ON SCHEMA new_module TO app_owner;
GRANT ALL ON ALL TABLES IN SCHEMA new_module TO app_owner;
GRANT ALL ON ALL FUNCTIONS IN SCHEMA new_module TO app_owner;
GRANT USAGE ON SCHEMA new_module TO authenticated;
GRANT SELECT ON ALL TABLES IN SCHEMA new_module TO authenticated;
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA new_module TO authenticated;
EOF
```
