# 分支策略与发布流程

本文记录 OmniPG 当前分支现状（2026-08-18 实测）、wiki 完成后向单长期分支收敛的计划、日常开发分支流程、master 保护与 CI 要求、版本发布流程。

## 1. 当前分支现状（git 实测 2026-08-18）

| 分支 | 状态 | 说明 |
| --- | --- | --- |
| docs/wiki-rewrite | **当前工作分支**（HEAD = 5cd0434） | 承载 wiki 骨架与重写工作 |
| master | 远程默认分支（origin/HEAD → origin/master） | 唯一长期分支候选；HEAD 已包含 master 全部提交（master...HEAD = 0/177） |
| feature/logto-authn | 活跃特性分支（origin 存在） | Logto 认证授权改造主线；与当前 HEAD 仅差 1 个 commit（5cd0434 文档清理） |
| dev | 历史分支 | 早期开发分支，内容已并入主线 |
| feature/casdoor-managed-roles | **本地遗留**（未推远程） | Casdoor 时代方案，应归档删除 |
| fix/cicd-v2-deployment-issues | 历史修复分支（origin 存在） | 部署修复已落地，可归档 |
| refactor/cicd-v2 | 历史重构分支（origin 存在） | CI/CD v2 重构，可归档 |

Tag：`v0.1.0`（迁移基线 squash 0.1，历史 62 个迁移存档于此 tag）。

## 2. 收敛计划：wiki 完成后收缩为 master/main

目标：**wiki 评审合并后，master 成为唯一长期分支**，其余分支打 archive tag 后删除。

| 步骤 | 动作 | 命令示例 |
| --- | --- | --- |
| 1 | 完成 wiki 重写并自查（本批次 5 个运维页面 + 其余骨架页） | git status / git diff --stat |
| 2 | 评审通过后，将 docs/wiki-rewrite 合并进 feature/logto-authn（或直接进 master） | git checkout feature/logto-authn && git merge docs/wiki-rewrite |
| 3 | 将 feature/logto-authn 合并进 master 并推送 | git checkout master && git merge --no-ff feature/logto-authn && git push origin master |
| 4 | 为将被删除的分支打归档 tag | git tag archive/logto-authn-final feature/logto-authn && git push origin archive/logto-authn-final |
| 5 | 删除本地与远程旧分支 | git branch -d feature/logto-authn dev ... && git push origin --delete feature/logto-authn ... |
| 6 | 配置分支保护 + CI（见第 5 节） | GitHub Settings → Branches |

> 说明：仓库当前默认分支名是 **master**（origin/HEAD 指向 origin/master）；骨架清单写作 main。若团队要求统一为 main，需在 GitHub 仓库 Settings 重命名默认分支后同步本地 remote（git branch -m master main），否则以 master 为准即可。

## 3. main 收敛 Checklist

- [ ] 提交/合并当前未提交改动（db、docs、wiki 等）：git status 干净
- [ ] wiki 全部页面（含 08-运维 5 页）内容评审通过
- [ ] 合并顺序确认：docs/wiki-rewrite → feature/logto-authn → master
- [ ] 为将被删除的分支打归档 tag（archive/logto-authn-final 等）
- [ ] 删除旧分支（dev、feature/casdoor-managed-roles、fix/cicd-v2-deployment-issues、refactor/cicd-v2、feature/logto-authn）
- [ ] 配置 branch protection：master 禁止直接推送、PR 必须、状态检查必须（CI 通过）
- [ ] CI 全绿：make test（pgTAP 115 + e2e）、verify-fresh-db.sh
- [ ] 更新本页（勾选完成项）

## 4. 归档策略：archive/* tag 保留历史

- 归档 tag 命名：archive/<分支名>-final（如 archive/logto-authn-final、archive/casdoor-managed-roles-final）。
- 历史数据保留示例：**v0.1.0 tag 内保留了被 squash 的 62 个迁移文件**：

    git show v0.1.0 -- db/migrations/public/

- 归档 tag 只读、不参与日常开发；需要追溯旧实现时从 tag checkout 只读查看。

## 5. 日常开发流程：短生命周期分支 + PR

- 分支命名：feature/<功能>、hotfix/<问题>、docs/<主题>、fix/<问题>。
- 流程：从 master 拉分支 → 开发 + 本地验证（make test）→ PR 到 master → CI 状态检查通过 → review → merge → 删除分支。
- 部署不依赖分支名：CI 为 PR 触发（.github/workflows/ci.yml，路径过滤）；部署 workflow（deploy-db / deploy-gateway / deploy-infra / deploy-all）为 workflow_dispatch 手动触发，按 environment（staging/production）区分。

## 6. master 保护与 CI 要求

- CI 路径过滤（ci.yml）：

| 变更路径 | 检查 |
| --- | --- |
| db/migrations/**、db/src/**、db/api_v1/**、db/init/**、db/tests/** | SQL Lint（sqlfluff，容错）+ dbmate up --dry-run（postgres:18 服务） |
| gateway/** | docker compose config --quiet + docker compose build |
| db/syncer/** | Go build + go test（syncer 已退役，检查保留） |
| infra/** | yamllint（pigsty.yml / pigsty.db.yml / pigsty.gateway.yml） |

- Go syncer 已退役：ci.yml 的 syncer-check 作业与 deploy-gateway.sh 的 docker compose build syncer 段为历史遗留（检查保留，不影响部署）。

- 本地双闸：**verify-fresh-db.sh**（冷启动结构比对 + pgTAP）+ **make test**（pgTAP 115/115 + e2e-test.sh 34 项，Logto 版）。
- 建议保护规则：master 禁止 force push 与直接推送；PR 至少 1 个 review；状态检查（CI）必须通过；environment 规则（staging/production）用于部署 workflow。

## 7. 版本发布流程

1. **冻结**：连续观察期无新迁移（参考 15 号文档 F1/F2 判定）。
2. **质量闸**：make test 全绿 + verify-fresh-db.sh 通过 + 迁移幂等两遍重放不炸。
3. **迁移治理（如需）**：发布时 squash 一次（历史迁移 → 新 baseline），旧迁移以 tag 留存（参考 18 号文档 §2 SOP：pg_dump 反写 → 幂等三件套 → 账本收敛 → 冷启动验证 → git tag）。
4. **打 tag**：git tag vX.Y.Z && git push origin vX.Y.Z；tag 内保留被 squash 的历史。
5. **Changelog**：按域列出（db 迁移/源码、gateway 配置、infra、脚本、文档），并记录备份情况（见 [备份与恢复](backup-restore.md)）。
6. **部署**：deploy-infra → deploy-db → deploy-gateway → init-apisix-routes.sh（Logto 版）→ e2e 验收；生产环境经 workflow_dispatch + environment 审批。

> 参考：[项目主页](../Home.md) · [测试总览](../07-测试/testing-overview.md) · [部署指南总览](../03-部署指南/deployment-overview.md) · [迁移指南](../05-开发指南/migrations.md) · [备份与恢复](backup-restore.md)
