# 常见问题排查

> 状态：骨架占位 · 待补充
> 定位：本地开发环境高频问题与解法

## 内容清单

- [ ] 端口被占用 / 容器起不来
- [ ] 数据库连接失败（密码、pg_hba、pgbouncer）
- [ ] 迁移失败与回滚
- [ ] APISIX 路由未生效（重跑 setup_apisix.sh）
- [ ] Logto 登录回调/CORS 问题
- [ ] WSL2 下 Windows 访问端口的 portproxy 说明（scripts/wsl-portproxy.ps1）

---

## 快速定位建议

1. 先看 `docker compose ps` 确认容器健康
2. 再看 `docker compose logs <svc>`
3. 数据库问题查 infra/ 下 pg_hba.conf、pgbouncer.ini
4. 网关问题查 gateway/apisix/*.yaml 与 setup_apisix.sh

---

> 参考：本页内容需与当前代码保持一致，补充时请核对 `feature/logto-authn` 分支。
