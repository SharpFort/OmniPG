# 一键搭建本地开发环境

> 状态：骨架占位 · 待补充
> 定位：从克隆仓库到跑通第一个接口的完整本地流程（make dev 全流程拆解）

## 内容清单

- [ ] 克隆仓库与分支说明（feature/logto-authn）
- [ ] 复制 .env：.env.example → gateway/.env 等
- [ ] make dev 内部做了什么（docker compose up + setup_apisix.sh）
- [ ] dbmate 迁移：make migrate
- [ ] 数据初始化/种子数据
- [ ] 验证：make test-db / make test-e2e
- [ ] 停止环境：make dev-down

---

## 最小操作序列

```bash
git clone <repo> && cd OmniPG
git checkout feature/logto-authn
# 1. 配置环境变量
cp .env.example .env        # 按需修改
cd gateway && cp .env.example .env
cd ..
# 2. 一键启动
make dev
# 3. 数据库迁移
make migrate
# 4. 验证
make test-db
```

## make dev 逐步拆解

1. `cd gateway && docker compose up -d`：启动 PostgREST / APISIX / Logto 等容器
2. 等待服务就绪
3. `scripts/setup_apisix.sh`：初始化 APISIX 路由
> 补充：各步骤失败时的表现与排查见 [troubleshooting](troubleshooting.md)

---

> 参考：本页内容需与当前代码保持一致，补充时请核对 `feature/logto-authn` 分支。
