# 冒烟验证脚本

> 状态：骨架占位 · 待补充
> 定位：verify-stack / verify-fresh-db 等部署后自检

## 内容清单

- [ ] verify-stack.sh：组件健康检查
- [ ] verify-fresh-db.sh：全新数据库校验
- [ ] 055-t1-precheck.sql 等 precheck 脚本
- [ ] 在 CI/部署流水线中的使用

---

## 执行示例

```bash
bash scripts/verify-stack.sh
bash scripts/verify-fresh-db.sh
```

---

> 参考：本页内容需与当前代码保持一致，补充时请核对 `feature/logto-authn` 分支。
