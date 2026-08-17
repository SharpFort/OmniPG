# 测试体系总览

> 状态：骨架占位 · 待补充
> 定位：pgTAP + E2E + 验证脚本的分层测试策略

## 内容清单

- [ ] 测试分层：数据库测试 / 集成测试 / 冒烟验证
- [ ] 各层入口与命令（Makefile：make test / test-db / test-e2e）
- [ ] 测试运行时机：本地、CI
- [ ] 覆盖范围与盲区
- [ ] 新增功能时应补哪些测试

---

## 命令速查

```bash
make test       # 全部
make test-db    # pgTAP
make test-e2e   # E2E
```

---

> 参考：本页内容需与当前代码保持一致，补充时请核对 `feature/logto-authn` 分支。
