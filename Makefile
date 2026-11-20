# =============================================================================
# OmniPG 统一 Makefile
# =============================================================================

.PHONY: help dev dev-down deploy-db deploy-gateway test test-db test-e2e migrate migrate-rollback migrate-status

# 默认目标
help:
	@echo "OmniPG 开发工具"
	@echo ""
	@echo "开发环境:"
	@echo "  make dev              - 启动本地开发环境"
	@echo "  make dev-down         - 停止本地开发环境"
	@echo ""
	@echo "部署:"
	@echo "  make deploy-db ENV=staging           - 部署数据库"
	@echo "  make deploy-gateway ENV=staging      - 部署网关"
	@echo ""
	@echo "数据库迁移:"
	@echo "  make migrate           - 应用所有待执行迁移"
	@echo "  make migrate-rollback  - 回滚最近一次迁移"
	@echo "  make migrate-status    - 查看迁移状态"
	@echo ""
	@echo "测试:"
	@echo "  make test              - 运行全部测试"
	@echo "  make test-db           - 运行 pgTAP 数据库测试"
	@echo "  make test-e2e          - 运行 E2E 集成测试"

# =============================================================================
# 开发环境
# =============================================================================

dev:
	cd gateway && docker compose up -d
	@echo "等待服务启动..."
	@sleep 10
	cd gateway && bash -c '[ -f .env ] && export $$(grep -v "^#" .env | xargs); bash ../scripts/init-apisix-routes.sh'

dev-down:
	cd gateway && docker compose down

# =============================================================================
# 部署
# =============================================================================

deploy-db:
	bash scripts/deploy-db.sh $(ENV)

deploy-gateway:
	bash scripts/deploy-gateway.sh $(ENV)

# =============================================================================
# 数据库迁移
# =============================================================================

# =============================================================================
# 数据库迁移（阶段3前置修复：委托 scripts/migrate.sh——含 --no-dump-schema、
# 显式 --url（DBMATE_DATABASE_URL 优先级）、.env 契约与 fail-fast；
# 原内联 dbmate 调用在迁移后会 dump db/schema.sql 并因 public 权限失败）
# =============================================================================
migrate:
	bash scripts/migrate.sh up $(ENV)

migrate-rollback:
	bash scripts/migrate.sh down $(ENV)

migrate-status:
	bash scripts/migrate.sh status $(ENV)

# =============================================================================
# 测试
# =============================================================================

test: test-db test-e2e

# 阶段3前置修复：凭据经 gateway/.env（原依赖 WSL 侧 .pgpass 侥幸工作）；
# 移除 `|| true`——测试失败必须传导到 make 退出码（原恒 exit 0 是假绿灯）
test-db:
	cd db && PGPASSWORD="$$(sed -n 's/^DB_PASSWORD=//p' ../gateway/.env | tr -d '\r')" pg_prove -h 127.0.0.1 -U app_owner -d app_db --ext .sql -r tests/

test-e2e:
	bash scripts/e2e-test.sh
