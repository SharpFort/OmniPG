# 关键决策记录

> 状态：骨架占位 · 待补充
> 定位：为什么这样设计——每个决策的背景、方案对比与结论

## 内容清单

- [ ] ADR 1：从 casbin/casdoor 迁移到 Logto（认证与授权统一）
- [ ] ADR 2：后端吸收部分 casbin 方案（RBAC 数据模型）
- [ ] ADR 3：选择 PostgREST 作为 API 层
- [ ] ADR 4：选择 Pigsty 作为基础设施
- [ ] ADR 5：业务逻辑下沉到数据库（RPC/触发器/RLS）
- [ ] ADR 6：按 schema 划分模块而非按服务拆分（单体数据库）
- [ ] ADR 7：dbmate 作为迁移工具
- [ ] 每篇 ADR 模板：背景 → 方案对比 → 结论 → 影响

---

## ADR 模板

```markdown
## 背景
## 可选方案
## 决策
## 影响与代价
```

---

> 参考：本页内容需与当前代码保持一致，补充时请核对 `feature/logto-authn` 分支。
