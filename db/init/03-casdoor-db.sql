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
