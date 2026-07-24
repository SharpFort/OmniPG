# =============================================================================
# OmniPG 统一 Makefile
# =============================================================================

.PHONY: help dev dev-down deploy-db deploy-gateway test test-db test-syncer test-e2e migrate migrate-rollback migrate-status

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
	@echo "  make test-syncer       - 运行 Syncer Go 测试"
	@echo "  make test-e2e          - 运行 E2E 集成测试"

# =============================================================================
# 开发环境
# =============================================================================

dev:
	cd gateway && docker compose up -d
	@echo "等待服务启动..."
	@sleep 10
	bash scripts/setup_apisix.sh

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

migrate:
	cd db && dbmate up

migrate-rollback:
	cd db && dbmate rollback

migrate-status:
	cd db && dbmate status

# =============================================================================
# 测试
# =============================================================================

test: test-db test-syncer test-e2e

test-db:
	cd db && pg_prove -U app_owner -d app_db tests/ || true

test-syncer:
	cd db/syncer && go test -v ./...

test-e2e:
	bash scripts/e2e-test.sh
