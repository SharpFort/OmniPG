# 分支策略与发布流程

> 状态：骨架占位 · 待补充
> 定位：分支收敛计划、PR 流程与版本发布

## 内容清单

- [ ] 当前分支现状与 wiki 完成后收缩为 main 的计划
- [ ] main 收敛 checklist（提交未提交改动 → 合并 → tag 归档 → 删除分支）
- [ ] 归档策略：archive/* tag 保留历史
- [ ] 日常开发流程：短生命周期 feature/hotfix 分支 + PR
- [ ] main 保护与 CI 要求
- [ ] 版本发布流程（tag、changelog）

---

## 收敛 Checklist

- [ ] 提交/合并当前未提交改动（db、docs 等）
- [ ] wiki 内容评审并合并
- [ ] 为将被删除的分支打归档 tag（如 archive/logto-authn-final）
- [ ] 删除旧分支，main 设为唯一长期分支
- [ ] 配置 branch protection + CI

---

> 参考：本页内容需与当前代码保持一致，补充时请核对 `feature/logto-authn` 分支。
