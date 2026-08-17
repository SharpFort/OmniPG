# 脚本部署（一键方案）

> 状态：骨架占位 · 待补充
> 定位：逐脚本讲解 deploy-all / deploy-infra / deploy-db / deploy-gateway 的全过程

## 内容清单

- [ ] 总入口 scripts/deploy-all.sh 执行顺序
- [ ] deploy-infra.sh：Pigsty 基础设施
- [ ] deploy-db.sh：数据库 schema 与迁移（dbmate）
- [ ] deploy-gateway.sh：PostgREST / APISIX / Logto
- [ ] setup_apisix.sh：网关路由初始化
- [ ] 初始化数据：种子数据、导入 ip2region/geolite2
- [ ] 部署后验证：verify-stack.sh / verify-fresh-db.sh
- [ ] 幂等性与重跑注意事项

---

## 一键部署命令

```bash
# 一键全量部署
bash scripts/deploy-all.sh
# 或分步
bash scripts/deploy-infra.sh
bash scripts/deploy-db.sh
bash scripts/deploy-gateway.sh
```

## 部署后验证

```bash
bash scripts/verify-stack.sh
bash scripts/verify-fresh-db.sh
```

---

> 参考：本页内容需与当前代码保持一致，补充时请核对 `feature/logto-authn` 分支。
