# dbmate 数据表演进管理

> 状态：骨架占位 · 待补充
> 定位：迁移规范：如何新增/修改/回滚数据库结构

## 内容清单

- [ ] dbmate 安装与 dbmate.toml 配置
- [ ] 迁移目录：db/migrations/public，命名规范
- [ ] 新增迁移的标准流程（dbmate new → 编写 → make migrate）
- [ ] 可回滚性要求：up/down 成对
- [ ] 种子数据与基线迁移（如 066_v010_seed_data.sql、065_v010_baseline.sql）
- [ ] 迁移与 src/（函数/触发器/RLS）的关系：apply-src.sh
- [ ] 常见坑：已上线环境的破坏性变更

---

## 标准流程

```bash
cd db
dbmate new create_xxx_table
# 编辑新迁移文件
cd .. && make migrate
```

---

> 参考：本页内容需与当前代码保持一致，补充时请核对 `feature/logto-authn` 分支。
