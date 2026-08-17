# 新增一个 API 的完整流程

> 状态：骨架占位 · 待补充
> 定位：从迁移到 RPC/视图 → 权限 → 暴露 → 测试的端到端清单

## 内容清单

- [ ] Step 1：迁移新增表/字段
- [ ] Step 2：在 src/public 编写函数/触发器/RLS（如需）
- [ ] Step 3：在 api_v1 建对外视图或 RPC（db/api_v1/public/views、rpc）
- [ ] Step 4：配置权限（RLS 策略、角色授权）
- [ ] Step 5：PostgREST 暴露检查（openapi / 路由）
- [ ] Step 6：APISIX 路由（如需对外网暴露）
- [ ] Step 7：pgTAP 测试 + 手动 curl 验证
- [ ] Step 8：更新本 wiki 的 rpc-reference.md

---

## 端到端清单（待补全）

- [ ] 迁移文件已创建并 up
- [ ] RPC/视图已建
- [ ] 权限与 RLS 已配置
- [ ] 测试已编写且 make test-db 通过
- [ ] API 参考已更新

---

> 参考：本页内容需与当前代码保持一致，补充时请核对 `feature/logto-authn` 分支。
