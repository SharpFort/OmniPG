# 手动部署（逐步方案）

> 状态：骨架占位 · 待补充
> 定位：不依赖一键脚本的逐步操作，便于理解每一步做什么

## 内容清单

- [ ] Step 1：安装并初始化 Pigsty（infra/pigsty.yml、pigsty.db.yml、pigsty.gateway.yml）
- [ ] Step 2：启动 PostgreSQL 集群与 pgbouncer、redis
- [ ] Step 3：应用数据库初始化（db/init、db/schema.sql）
- [ ] Step 4：dbmate 迁移（db/migrations/public）
- [ ] Step 5：配置并启动 PostgREST（gateway/postgrest/postgrest.conf）
- [ ] Step 6：配置并启动 APISIX（gateway/apisix/）
- [ ] Step 7：接入 Logto（应用注册、webhook 配置）
- [ ] Step 8：导入辅助数据（ip2region / geolite2）
- [ ] Step 9：验证

---

## 与脚本的对应关系

每个 Step 对应 scripts/ 下哪个脚本，便于"手动排查时知道脚本做了什么"

---

> 参考：本页内容需与当前代码保持一致，补充时请核对 `feature/logto-authn` 分支。
