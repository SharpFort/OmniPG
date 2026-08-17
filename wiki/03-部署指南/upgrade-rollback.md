# 升级与回滚

> 状态：骨架占位 · 待补充
> 定位：版本升级、迁移回滚与数据安全

## 内容清单

- [ ] 升级前准备（备份、快照）
- [ ] dbmate up / rollback 的正确姿势（Makefile 目标）
- [ ] 迁移回滚的注意事项（破坏性变更）
- [ ] 脚本部署的幂等重跑
- [ ] 回滚演练清单

---

## 常用命令

```bash
make migrate          # 应用所有待执行迁移
make migrate-rollback # 回滚最近一次
make migrate-status   # 查看迁移状态
```

---

> 参考：本页内容需与当前代码保持一致，补充时请核对 `feature/logto-authn` 分支。
