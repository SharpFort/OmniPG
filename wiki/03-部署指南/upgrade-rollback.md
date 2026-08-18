# 升级与回滚

OmniPG 的「升级」主要由三部分组成：**数据库迁移（dbmate + apply-src）**、**网关栈升级（docker compose 重建）**、**Logto 侧配置（webhook/claims）**。回滚的可靠手段是**备份恢复**——当前迁移基线不提供自动 down 语义（见下文），切勿把「回滚」等同于「跑一个 down 迁移」。

## 升级前准备（备份、快照）

### 1. 数据库备份（必须）

```bash
# 逻辑备份（推荐日常升级前）：
pg_dump -h 127.0.0.1 -U app_owner -d app_db -Fc -f backups/app_db_$(date +%Y%m%d_%H%M%S).dump
# 或 SQL 文本格式：
pg_dump -h 127.0.0.1 -U app_owner -d app_db -f backups/app_db_$(date +%Y%m%d_%H%M%S).sql

# 物理备份（PITR 场景参考，Pigsty/pgBackRest 或 pg_basebackup）：
# pg_basebackup -D /backup/base/$(date +%Y%m%d) -Ft -z -P
```

- 备份要验证可恢复：`pg_restore --list backups/xxx.dump | head` 或恢复到 scratch 库试跑（见 [verify-fresh-db.sh](../07-测试/verify-scripts.md)）。
- `backups/` 目录现存 `rebuild_iam_menu_*.sql` 等是历史数据修复脚本，不是备份体系，别混用。

### 2. etcd / APISIX 配置快照

APISIX 配置存在 compose 内 etcd（traditional 模式）。升级网关前可导出当前路由清单留档：

```bash
curl -s http://localhost:9180/apisix/admin/routes -H "X-API-KEY: $APISIX_ADMIN_KEY" > backups/apisix_routes_$(date +%Y%m%d).json
# 恢复：setup_apisix.sh（或 init-apisix-routes.sh）重放
```

### 3. 代码与版本快照

- 发布前打 tag（v0.1.0 先例：历史 62 个迁移留在 `git tag v0.1.0`）：`git tag vX.Y.Z && git push origin vX.Y.Z`；
- 确认 `dbmate status` 账本：Applied / Pending 列表与目标版本一致；
- 迁移评审：跑 `scripts/apply-src.sh <db_uri>` 之前先看 §6.3 扫描是否通过（迁移目录含代码对象会直接失败）。

### 4. 冷启动双闸（18 号文档硬门槛）

任何迁移/部署链变更后：

```bash
bash scripts/verify-fresh-db.sh   # 全新库冷启动 + 结构比对 + pgTAP
make test                         # pgTAP + e2e
```

## dbmate up / rollback 的正确姿势（Makefile 目标）

### 常用命令

```bash
make migrate           # 应用所有待执行迁移（cd db && DATABASE_URL=... dbmate -d migrations/public up）
make migrate-rollback  # 回滚最近一次（dbmate -d migrations/public rollback）
make migrate-status    # 查看迁移状态（dbmate status）

# 或统一入口脚本：
bash scripts/migrate.sh up development
bash scripts/migrate.sh rollback development
bash scripts/migrate.sh status development
bash scripts/migrate.sh create <migration_name>   # 新建迁移
```

- `Makefile` 从 `gateway/.env` 读 `DB_PASSWORD` 拼 `postgres://app_owner:<pwd>@127.0.0.1:5432/app_db`；
- `scripts/migrate.sh` 优先用 `DATABASE_URL`，否则回退默认开发连接串；
- **先 bootstrap 再迁移**：迁移依赖 `src/public/types` 枚举（059/060 引用），正确顺序是 `deploy-db.sh` 的 [1/4]→[2/4]；单独跑 `dbmate up` 前先执行 `apply-src.sh --bootstrap`（或直接跑 `deploy-db.sh`）。

### 当前基线的回滚限制（重要）

`db/migrations/public/` 只有 064/065/066 三个文件，**down 段只有注释、无回滚 DDL**（18 号文档明确「回滚：无 down 语义（squash baseline）」）：

| 迁移 | up 内容 | down 段 |
| --- | --- | --- |
| 064_v010_mirror_tables | Logto 镜像/绑定表 6 张 | 仅注释 |
| 065_v010_baseline | 业务表 18 张 + 序列/索引/约束 | 仅注释 |
| 066_v010_seed_data | 种子数据 80 行（ON CONFLICT DO NOTHING） | 仅注释 |

因此：

- `make migrate-rollback` 对基线迁移是**空操作或不可用**，不能用来撤销结构变更；
- 历史 62 个迁移永久保存在 `git tag v0.1.0`（`git show v0.1.0 -- db/migrations/public/` 可取回），那是「参考历史」，不是可执行的回滚通道；
- **结构回滚 = 备份恢复**，别无他法。

### 067+ 迁移编写约定（为将来回滚做好准备）

- 必须带 `-- migrate:up` 与 `-- migrate:down` 标记（dbmate 缺标记拒绝执行）；
- 按 18 号文档：down 段只写注释（项目惯例不提供自动回滚 DDL），所以新迁移的「回滚」仍靠备份；
- 幂等三件套：CREATE TABLE/SEQUENCE/INDEX → `IF NOT EXISTS`；ADD CONSTRAINT → DO 块守卫；种子 → `ON CONFLICT (id) DO NOTHING`；
- 17 号铁律：迁移只承载表结构+数据；函数/视图/触发器/枚举/RLS/授权一律归 `db/src/` 与 `db/api_v1/`（apply-src 部署），迁移内出现代码对象会被 §6.3 扫描拒绝。

## 迁移回滚的注意事项（破坏性变更）

| 变更类型 | 风险 | 处理 |
| --- | --- | --- |
| 删除/重命名表、列 | 破坏性，无法用 down 恢复 | 走备份恢复；或先做「软删除」迁移（加 deleted_at）再择机清理 |
| 修改枚举值 | 值只增不删不重排（18 号文档约定） | 枚举归 `db/src/public/types/`；改值需评估所有引用 |
| 破坏性 DROP（无 IF EXISTS 保护） | apply-src 重放必炸 | 全部放 DO 块 + IF EXISTS 守卫 |
| seed 数据变化 | 幂等种子只做 INSERT DO NOTHING，不更新已存在行 | 需要改种子值时要显式 UPDATE 迁移 |
| 代码对象（函数/视图等） | 迁移内出现 = 扫描失败 | 归位 db/src / db/api_v1，apply-src 幂等重放 |
| squash（合并迁移） | 账本与文件不一致 | 按 18 号文档 SOP：tag 留存 → 存量库账本收敛（DELETE/INSERT schema_migrations）→ 冷启动验证 → 发布 |
| 回滚到旧版本镜像 | compose 降级 | 拉旧镜像 + `docker compose down && up -d`；APISIX 路由重放；Logto 配置以 init-logto.py --verify 核对 |

## 脚本部署的幂等重跑

| 场景 | 重跑行为 | 安全前提 |
| --- | --- | --- |
| `deploy-all.sh` 整体重跑 | infra（已安装检测）→ db（bootstrap 幂等 + dbmate 跳过 + apply-src 重放）→ gateway（重建容器）→ setup_apisix（PUT 覆盖）→ e2e | 迁移幂等、网关 .env 已就绪 |
| `deploy-db.sh` 重跑 | bootstrap 不炸（IF NOT EXISTS）；dbmate 跳过已应用；apply-src 二遍验证 | 代码对象全部归 src；迁移无代码对象 |
| `deploy-gateway.sh` 重跑 | down/up 重建容器；⚠️ `docker compose build syncer` 遗留会失败（见 [script-deploy.md](script-deploy.md)） | 先移除遗留行 |
| `setup_apisix.sh` 重跑 | Admin API PUT 幂等，路由/元数据覆盖 | 与 Logto 版 init-apisix-routes.sh 二选一，勿混用 |
| 数据导入（ip2region/geolite2） | TRUNCATE + 全量重灌 | 会清空再导入，非增量 |

## 回滚演练清单

- [ ] 升级前已做逻辑备份并验证 dump 可读（`pg_restore --list`）
- [ ] `dbmate status` 记录了升级前的 Applied 版本号
- [ ] 路由清单已导出（Admin API GET /routes）
- [ ] 演练在 scratch 库进行：恢复备份 → 跑目标版本迁移 → `verify-fresh-db.sh` 结构比对 → pgTAP → 业务冒烟（登录/菜单/写操作）
- [ ] 确认回滚 = 恢复到备份（不依赖 down 迁移）
- [ ] 网关回滚路径：旧 compose 镜像 + 重跑 APISIX 路由 + Logto 配置核对（`init-logto.py --verify`）
- [ ] 记录 RTO/RPO 目标（例如：恢复到最近一次备份 + 丢失该窗口内数据）并在演练中实测
- [ ] 演练结束后用 `verify-fresh-db.sh` 重建干净验证库，避免演练数据污染

## 相关页面

- [部署指南总览](deployment-overview.md)
- [脚本部署（一键方案）](script-deploy.md)
- [手动部署（逐步方案）](manual-deploy.md)
- [环境变量配置](environment-config.md)
- [05-开发指南/数据库迁移](../05-开发指南/migrations.md)
- [07-测试/验证脚本](../07-测试/verify-scripts.md)
- [08-运维/备份恢复](../08-运维/backup-restore.md)

> 参考：本页以 `Makefile`、`scripts/migrate.sh`、`db/migrations/public/064-066`、18 号迁移基线文档与 `scripts/verify-fresh-db.sh` 当前代码为准；历史迁移文件清单见 `git tag v0.1.0`。
