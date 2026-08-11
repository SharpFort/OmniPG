#!/usr/bin/env python3
"""
Phase 4: 数据库迁移 + 源码部署 + Docker Compose 启动
在 Windows 端执行，通过 WSL2 运行 psql 和 docker compose
"""
import subprocess
import os
import sys

WSL = "wsl -d Ubuntu-26.04 -- "
DB_PASS = "dev_password_change_me"
DB_USER = "app_owner"
DB_NAME = "app_db"
DB_HOST = "127.0.0.1"
PROJECT_DIR = "/mnt/e/Projects/OmniPG"

def run(cmd, check=True):
    """执行命令"""
    print(f"\n>>> {cmd[:80]}...")
    result = subprocess.run(cmd, shell=True, capture_output=True)
    stdout = result.stdout.decode('utf-8', errors='replace') if result.stdout else ''
    stderr = result.stderr.decode('utf-8', errors='replace') if result.stderr else ''
    if stdout:
        print(stdout[:500])
    if result.returncode != 0 and check:
        print(f"ERROR: {stderr[:300]}")
    return result

def psql(sql, check=True):
    """执行 SQL"""
    cmd = f'{WSL} bash -c "PGPASSWORD={DB_PASS} psql -h {DB_HOST} -U {DB_USER} -d {DB_NAME} -v ON_ERROR_STOP=0 -c \\"{sql}\\""'
    return run(cmd, check)

def psql_file(filepath, check=True):
    """执行 SQL 文件"""
    cmd = f'{WSL} bash -c "PGPASSWORD={DB_PASS} psql -h {DB_HOST} -U {DB_USER} -d {DB_NAME} -v ON_ERROR_STOP=0 -f {filepath}"'
    return run(cmd, check)

def main():
    print("=" * 60)
    print(" Phase 4: 数据库迁移 + 源码部署")
    print("=" * 60)
    
    # Step 1: 创建缺失的角色
    print("\n[1/7] 创建缺失的角色...")
    psql("CREATE ROLE IF NOT EXISTS authenticated;")
    psql("CREATE ROLE IF NOT EXISTS anonymous;")
    psql("ALTER USER app_owner WITH CREATEROLE;")
    
    # Step 2: 执行迁移文件
    print("\n[2/7] 执行迁移文件...")
    migrations = [
        f"{PROJECT_DIR}/db/migrations/public/001_init_tables.sql",
        f"{PROJECT_DIR}/db/migrations/public/002_create_relation_sessions_blacklist.sql",
        f"{PROJECT_DIR}/db/migrations/public/003_seed_data.sql",
        f"{PROJECT_DIR}/db/migrations/public/004_cleanup_cron.sql",
        f"{PROJECT_DIR}/db/migrations/public/005_audit_log_table.sql",
    ]
    
    for migration in migrations:
        if os.path.exists(migration.replace("/mnt/e", "E:").replace("/", "\\")):
            print(f"\n  执行: {os.path.basename(migration)}")
            psql_file(migration)
        else:
            print(f"\n  跳过（不存在）: {migration}")
    
    # Step 3: 验证迁移结果
    print("\n[3/7] 验证数据库对象...")
    psql("SELECT schemaname, count(*) as tables FROM pg_tables WHERE schemaname NOT LIKE 'pg_%' AND schemaname NOT LIKE 'information_schema' GROUP BY schemaname ORDER BY schemaname;")
    
    # Step 4: 刷入幂等源码
    print("\n[4/7] 刷入幂等源码...")
    
    # Schema 初始化
    for schema in ["sys", "sales", "inventory"]:
        init_file = f"{PROJECT_DIR}/db/src/{schema}/_init_schema.sql"
        if os.path.exists(init_file.replace("/mnt/e", "E:").replace("/", "\\")):
            print(f"\n  {schema}/_init_schema.sql")
            psql_file(init_file)
    
    # 所有源码文件
    for root, dirs, files in os.walk(f"E:\\Projects\\OmniPG\\db\\src"):
        for f in sorted(files):
            if f.endswith('.sql') and not f.startswith('_'):
                filepath = os.path.join(root, f).replace("/", "\\")
                wsl_path = filepath.replace("\\", "/").replace("E:", "/mnt/e")
                print(f"  {os.path.basename(filepath)}")
                psql_file(wsl_path)
    
    # Step 5: 验证 API 对象
    print("\n[5/7] 验证 API 对象...")
    psql("SELECT n.nspname as schema, count(*) as objects FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace WHERE n.nspname LIKE 'api_v1%' OR n.nspname IN ('public', 'sales', 'inventory') GROUP BY n.nspname ORDER BY n.nspname;")
    
    psql("SELECT n.nspname, count(*) as functions FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace WHERE n.nspname LIKE 'api_v1%' GROUP BY n.nspname ORDER BY n.nspname;")
    
    # Step 6: Docker Compose 启动
    print("\n[6/7] Docker Compose 启动...")
    run(f"{WSL} bash -c 'cd {PROJECT_DIR}/gateway && docker compose down 2>/dev/null; docker compose pull && docker compose up -d'")
    
    # Step 7: 健康检查
    print("\n[7/7] 健康检查...")
    import time
    time.sleep(10)
    
    # 检查服务
    services = [
        ("APISIX", "curl -sf http://localhost:9080/apisix/status"),
        ("PostgREST", "curl -sf http://localhost:3001/"),
        ("Casdoor", "curl -sf http://localhost:8000/api/health"),
        ("Swagger UI", "curl -sf http://localhost:8082/"),
    ]
    
    for name, cmd in services:
        result = run(f"{WSL} bash -c '{cmd}'", check=False)
        status = "✅ 正常" if result.returncode == 0 else "❌ 失败"
        print(f"  {name}: {status}")
    
    print("\n" + "=" * 60)
    print(" Phase 4 数据库部署完成!")
    print("=" * 60)
    print("\n请手动验证:")
    print("  - Swagger UI: http://localhost:8082/")
    print("  - Grafana: http://localhost:3000 (admin/pigsty)")
    print("  - PostgREST: http://localhost:3001/")
    print("  - Casdoor: http://localhost:8000")

if __name__ == "__main__":
    main()
