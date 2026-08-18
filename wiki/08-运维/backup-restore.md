# 备份与恢复

本文面向 OmniPG 运维，说明 backups/ 目录用途、pg_dump / pg_basebackup 备份策略、恢复流程、迁移前备份强制要求与 RTO/RPO 建议。所有事实以当前代码为准（分支 docs/wiki-rewrite，2026-08-18 核对）。

## 1. backups/ 目录的用途

backups/ **不是自动化备份目录**，而是手工执行的**迁移/重建前置快照与脚本**的归档位置：

| 文件 | 内容 |
| --- | --- |
| iam_menu_20260814_before_rebuild.sql | 2026-08-14 菜单清空重建（055 单表化）**之前**的 iam_menu 数据快照（pg_dump 输出） |
| rebuild_iam_menu_20260814.sql | 菜单清空重建脚本（TRUNCATE + rpc_create_menu 建树） |
| rebuild_iam_menu_20260814_bind.sql | 角色绑定脚本（role_super_admin / tenant_admin 绑定） |
| rebuild_iam_menu_20260814_dirfix.sql | 目录行 router/route_name 修补 |

约定：**任何破坏性迁移/重建操作前，先把受影响表的数据 dump 到 backups/**，文件名带日期与意图（如 <表>_<日期>_before_<操作>.sql）。这不等同于系统备份，恢复演练仍需按第 3-4 节执行。

## 2. 当前备份能力现状（2026-08-18 代码核对）

| 项 | 现状 |
| --- | --- |
| 集群拓扑 | 单实例主库（infra/pigsty.yml：pg_omnipg 仅 127.0.0.1 primary，无 standby） |
| 逻辑备份 | **无自动化脚本**（scripts/ 无 backup 脚本）；依赖手工 pg_dump |
| 物理备份 | infra/postgresql.conf 中 archive_mode 为注释（off）、wal_level 默认 replica 未显式配置 → **当前无法 PITR**（TODO） |
| WAL 归档 | 未配置 archive_command |
| Redis | appendonly yes + appendfsync everysec（AOF 已开） |
| etcd / APISIX 配置 | etcd 数据在 compose 卷 etcd_data；路由可经 init-apisix-routes.sh 重放（配置即代码） |
| Logto | logto 库也在宿主 Pigsty PG 内（业务库走宿主 5433），随库备份覆盖（Pigsty 侧 logto 角色/库条目待补齐，见 [生产问题排查](production-troubleshooting.md)） |
| 冷启动验证 | scripts/verify-fresh-db.sh（8 步：重建库 → 扩展 → bootstrap → dbmate up → apply-src ×2 → 结构比对 → pgTAP） |

## 3. 备份策略建议

### 3.1 pg_dump 逻辑备份（日常 + 迁移前，必须）

数据库规模小、单实例，逻辑备份是最低成本的兜底：

    # 全库自定义格式（可压缩、可选择性恢复）
    mkdir -p backups
    pg_dump -h 127.0.0.1 -p 5432 -U app_owner -d app_db -Fc \
      -f "backups/app_db_$(date +%Y%m%d_%H%M%S).dump"

    # 迁移前单表快照（示例：audit_log）
    pg_dump -h 127.0.0.1 -U app_owner -d app_db -Fc \
      -t public.audit_log -f backups/audit_log_$(date +%Y%m%d).dump

建议频率：**每日一次** + **每次迁移/发布前一次**；保留最近 7-30 份（配合对象存储异地保存）。凭据用 PGPASSWORD 环境变量（避免连接串含特殊字符问题，见历史部署踩坑 17 号）。

### 3.2 pg_basebackup 物理备份（PITR 前提，需先配置）

当前未启用归档，启用路径：

1. infra/postgresql.conf（或 Pigsty pg_conf）设置：
   - wal_level = replica（默认即 replica，显式确认）
   - archive_mode = on
   - archive_command = 'cp %p /var/lib/postgresql/archives/%f'（生产建议 rsync 到独立磁盘）
   - restore_command 在恢复端配置
2. 基础备份：

    sudo -u postgres pg_basebackup -D /var/lib/postgresql/backup/base_$(date +%Y%m%d) -Ft -z -P

3. 配合 WAL 归档可实现**时间点恢复（PITR）**。**以上均为建议，尚未在仓库中落地（TODO）**。

### 3.3 其他数据

- Redis：AOF everysec，冷备直接复制 dump/appendonly 文件；生产建议加 requirepass 并定期 RDB 快照。
- APISIX 路由：存在 etcd（compose 卷 etcd_data）；恢复 = 重建容器后重跑 bash scripts/init-apisix-routes.sh（Logto 版）。⚠️ setup_apisix.sh 为遗留脚本，勿用。
- 环境配置：infra/ 与 gateway/ 均为代码，git 即备份；敏感值在 .env / Secrets，需另行保管。

## 4. 恢复流程

### 4.1 逻辑恢复（pg_restore）

    # ① 先建好库与扩展（deploy-db.sh 已保证 schema/迁移/源码就绪，避免对象冲突）
    bash scripts/deploy-db.sh development

    # ② 恢复到目标库（--clean 清掉已有对象；如恢复到新库则去掉 --clean）
    PGPASSWORD=... pg_restore -h 127.0.0.1 -U app_owner -d app_db \
      --clean --if-exists backups/app_db_YYYYMMDD_HHMMSS.dump

    # ③ 验证
    bash scripts/verify-fresh-db.sh        # 冷启动结构比对 + pgTAP（参照 app_db）
    bash scripts/e2e-test.sh               # 网关链路验收

### 4.2 物理恢复（pg_basebackup + WAL，启用归档后）

1. 停止目标实例，清空 PGDATA；
2. pg_basebackup 恢复基础备份；配置 restore_command 指向归档目录；
3. 启动进入恢复，回放到目标时间点（recovery_target_time）后 promote；
4. 用 verify-fresh-db.sh / e2e-test.sh 验收。

### 4.3 恢复演练要求

- 演练必须落到**临时实例/scratch 库**（如 app_db_verify），不得直接覆盖生产；
- 演练后记录：备份文件是否可读、恢复耗时、数据行数核对（表数/种子数）、pgTAP 是否通过。

## 5. 迁移前备份的强制要求

- **任何 db/migrations 变更（067+）或 apply-src 结构级变更前，先执行全库 pg_dump -Fc 并确认文件大小非零**。
- 破坏性操作（TRUNCATE / DROP / 重建）前，按 backups/ 惯例补**单表快照**（参考 2026-08-14 iam_menu 重建前备份）。
- 部署链 scripts/deploy-db.sh（bootstrap → dbmate up → apply-src → dbmate status）**本身不包含备份步骤**，迁移前备份是人工责任（TODO：可考虑在 deploy-db.sh 加 --backup 开关）。
- 备份完成后将文件复制到仓库外（对象存储/另一台机器），避免与数据库同机丢失。

## 6. RTO / RPO 目标建议

| 方案 | RPO | RTO | 说明 |
| --- | --- | --- | --- |
| 每日 pg_dump（现状建议） | ≤24h（丢失一天） | 1-4h（视库大小） | 最低成本，先落地 |
| 每日 pg_dump + 迁移前快照 | ≤24h / 迁移点零丢失 | 1-4h | 推荐开发期 |
| pg_basebackup + WAL 归档（PITR） | 秒级-分钟级 | 0.5-2h（需基础备份+归档就绪） | 生产启用前提：archive_mode on（当前未配置，TODO） |
| 增加 Pigsty standby（流复制） | 0（同步/异步复制） | 分钟级（failover） | 单机架构尚未规划（TODO） |

> 以上为**建议目标，尚未实测**；恢复演练完成后回填实际 RTO/RPO。

## 7. 恢复演练清单

- [ ] 全量备份成功（pg_dump -Fc 文件存在且非空）
- [ ] 恢复到临时实例（app_db_verify）成功，无 ERROR
- [ ] 表/列/约束/种子/函数/视图/触发器/策略/索引与参照库一致（verify-fresh-db.sh [7/8]）
- [ ] pgTAP 通过（现库基线 115/115；全新库允许 test_casbin_view 3 例预期差异）
- [ ] e2e-test.sh 全绿（Logto 登录 → API → 镜像表 → RLS）
- [ ] 关键表行数抽查（audit_log / login_log / iam_menu / users / tenants / role）
- [ ] 记录 RTO / RPO 实测值

> 参考：[部署指南总览](../03-部署指南/deployment-overview.md) · [迁移指南](../05-开发指南/migrations.md) · [迁移基线 Squash 与冷启动验证指南](../../docs/开发实施方案/18-迁移基线Squash与冷启动验证指南.md) · [生产问题排查](production-troubleshooting.md) · [安全设计](security.md)
