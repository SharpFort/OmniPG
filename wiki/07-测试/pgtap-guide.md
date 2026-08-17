# pgTAP 测试指南

> 状态：骨架占位 · 待补充
> 定位：如何编写与运行数据库测试

## 内容清单

- [ ] pgTAP 扩展安装与测试目录（db/tests）
- [ ] 测试文件组织与命名
- [ ] 常用断言（ok/eq/is/cmp_ok/has_table 等）
- [ ] 事务包裹与回滚（保证测试可重复）
- [ ] 测试数据准备与清理
- [ ] 运行：make test-db / pg_prove 参数说明

---

## 最小示例（待补全）

```sql
BEGIN;
SELECT plan(2);
SELECT ok(true, '示例');
SELECT has_table('public', 'sys_user');
SELECT * FROM finish();
ROLLBACK;
```

---

> 参考：本页内容需与当前代码保持一致，补充时请核对 `feature/logto-authn` 分支。
