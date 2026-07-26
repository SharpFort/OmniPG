# refactor/cicd-v2 进度

## ✅ 已完成

### Step 1: 创建 gateway/ 目录并移动文件
- [x] docker-compose.yml → gateway/
- [x] apisix/ → gateway/
- [x] postgrest/ → gateway/

### Step 2: 移动 deploy/ 到 infra/
- [x] pigsty.yml → infra/
- [x] pg_hba.conf → infra/
- [x] pgbouncer.ini → infra/
- [x] redis.conf → infra/
- [x] userlist.txt → infra/
- [x] postgresql.conf → infra/
- [x] 删除空 deploy/ 目录

### Step 3: 移动 syncer/ 到 db/
- [x] syncer/ → db/syncer/

## ⏳ 待做

### Step 4: 从 Pigsty 官方获取最新配置
- [ ] 网络问题，GitHub 连接被重置，等网络恢复后执行
- [ ] 需更新三个 pigsty.yml 文件（Phase 1 / DB / Gateway）
- [ ] 参考：https://github.com/pgsty/pigsty/blob/main/conf/app

### Step 5: 更新 Makefile 和脚本路径
- [ ] Makefile 中的 docker-compose.yml 路径
- [ ] deploy-gateway.sh 中的路径
- [ ] start.sh / stop.sh 中的路径
- [ ] setup_apisix.sh 中的路径

### Step 6: 更新 .gitignore
- [ ] 如有需要添加新的忽略规则

### Step 7: 创建新脚本
- [ ] scripts/deploy-infra.sh
- [ ] scripts/deploy-all.sh
- [ ] scripts/migrate.sh
