.PHONY: dev-env db-migrate db-rollback apply-src test-db test-syncer test-e2e test-all run-syncer

# 启动本地开发环境
dev-env:
	docker compose up -d --build

# 执行数据库向前迁移
db-migrate:
	cd db && dbmate up

# 回滚最近一次迁移
db-rollback:
	cd db && dbmate rollback --single

# 将 db/src 中的幂等源码刷入数据库
apply-src:
	bash scripts/apply-src.sh "postgres://app_owner:dev_password_change_me@localhost:5432/app_db?sslmode=disable"

# 运行 pgTAP 单元测试
test-db:
	docker exec app-postgres pg_prove -U app_owner -d app_db db/tests/

# 运行 Go 同步器单元测试
test-syncer:
	cd syncer && go test -v ./...

# 运行全链路 E2E 集成测试
test-e2e:
	bash scripts/e2e-test.sh

# 一键执行全栈测试
test-all: test-db test-syncer test-e2e

# 启动 Policy Syncer
run-syncer:
	docker compose up -d syncer
