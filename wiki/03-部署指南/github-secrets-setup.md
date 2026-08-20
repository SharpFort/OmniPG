# GitHub Secrets 与 Actions 环境配置指南（deploy 前置）

> **适用范围**：staging / production 部署（`deploy-all` / `deploy-infra` / `deploy-db` / `deploy-gateway` workflow）
> **关联实现**：`scripts/render-config.sh`（2026-08-20 决策⑤ 密码渲染：`.env` / `pigsty.yml` / `userlist.txt` 三处一致）
> **本文所有操作均在 GitHub 网站完成**（Settings → Secrets and variables），仓库侧无需再改代码。

---

## 一、为什么需要配置

- staging / production 的 `.env.*` 中敏感值一律是 ${VAR} 占位符（真实值不入库）。
- `deploy-*.sh` 首步会执行 `scripts/render-config.sh`，用**当前环境变量**（即 CI Secrets 注入值）展开占位符，生成 `.env` / `pigsty.yml` / `userlist.txt`。
- workflow 的 SSH 部署步骤把这些 Secret 注入到服务器远程环境后执行脚本。
- **未配置对应 Secret 时渲染会 fail-closed 退出**（防止把占位符当密码下发），部署将失败——这是安全设计，不是故障。

---

## 二、操作步骤

### 1. 创建环境（Environments）

仓库 Settings → **Environments** → **New environment**，创建：

| 环境名 | 说明 |
| --- | --- |
| `staging` | 名称必须与 workflow 的 `inputs.environment` 选项一致 |
| `production` | 同上 |

可选：在环境里配置 Protection rules（如 Required reviewers / Wait timer），按团队规范决定。

### 2. 添加环境级 Secrets

对每个环境：Settings → **Environments** → `staging` / `production` → **Environment secrets** → **Add secret**。

> 也可以放仓库级 Secrets（Actions secrets）共用；环境级优先，推荐**环境级**（staging / production 各自独立，互不串用）。

### 3. Secrets 清单（6 个渲染令牌，必配）

| Secret 名称 | 用途（渲染到哪） | 生成建议 | 约束 |
| --- | --- | --- | --- |
| `DB_PASSWORD` | app_owner 密码 → `pigsty.yml` / `userlist.txt` / `gateway/.env` / dbmate | `openssl rand -base64 24` | 无单引号、无换行 |
| `AUTHENTICATOR_PASSWORD` | authenticator 角色密码 → `pigsty.yml` / `userlist.txt` / PostgREST 连接串 | `openssl rand -base64 24` | 同上 |
| `LOGTO_DB_PASSWORD` | logto 库/用户密码 → `pigsty.yml` / `userlist.txt` / compose `DB_URL` | `openssl rand -base64 24` | 同上 |
| `APISIX_ADMIN_KEY` | APISIX Admin API Key → `gateway/.env`（生产**必须**更换默认值） | `openssl rand -hex 16` | 同上 |
| `JWKS_JSON` | JWT 验签 JWKS → PostgREST `PGRST_JWT_SECRET` / APISIX jwt-auth 插件 | **从 Logto 控制台获取**（minified JSON，形如 `{"keys":[...]}`） | 同上（JSON 用双引号、无单引号即可） |
| `LOGTO_WEBHOOK_SIGNING_KEY` | Logto webhook HMAC-SHA256 验签 → `gateway/.env`（init-apisix-routes.sh 缺它 fail-closed） | **Logto 控制台 → Webhook → signing key** | 同上 |

> ⚠️ `JWKS_JSON` 算法口径：当前实现为 **Logto RS256 公钥**；仓库个别注释仍写 ES384（遗留不一致），以 Logto 实际签发算法为准。
> ⚠️ 已有 Secrets 继续沿用（非本次新增）：`SSH_PRIVATE_KEY`、`DB_SERVER_HOST`、`GATEWAY_SERVER_HOST`、`SERVER_USER`、`DBMATE_DATABASE_URL`、`DB_URI`（后者可选，deploy-db 验证用；渲染后可用渲染值替代）。

### 4. 生成与本地预演

```bash
# 生成（base64 天然不含空格与单引号；hex 更保守）
openssl rand -base64 24     # DB_PASSWORD / AUTHENTICATOR_PASSWORD / LOGTO_DB_PASSWORD
openssl rand -hex 16        # APISIX_ADMIN_KEY

# 本地预演渲染（替换为真实值；JWKS_JSON 从 Logto 获取后原样填入）
DB_PASSWORD='...' AUTHENTICATOR_PASSWORD='...' LOGTO_DB_PASSWORD='...' \
APISIX_ADMIN_KEY='...' JWKS_JSON='{"keys":[...]}' LOGTO_WEBHOOK_SIGNING_KEY='...' \
bash scripts/render-config.sh staging /tmp/preview

# 检查三处产物一致
cat /tmp/preview/.env
cat /tmp/preview/pigsty.yml   # 应看到真实密码，无 ${...} 残留（${admin_ip} 除外）
cat /tmp/preview/userlist.txt
```

- 残留未替换令牌 → 对应 Secret 未注入（fail-closed）。
- 报"含单引号/换行" → 重新生成 Secret 值。

### 5. 首次部署顺序（参考）

1. `deploy-infra`（staging 或 production）→ Pigsty 建 PG 集群 / 用户 / 库（含 `logto` 库与用户，2026-08-20 已声明进 `infra/pigsty.yml`）
2. `deploy-gateway` → compose 起网关 + `init-apisix-routes.sh`（路由/JWKS/webhook 验签）
3. Logto 初始化：`scripts/phase2/init-logto.py`（管理员/应用/角色/组织/webhook/claims，首次手动一次）
4. `deploy-db` → bootstrap + dbmate up + apply-src
5. `deploy-all`（或 e2e）验收

> 详细步骤以 `wiki/03-部署指南/script-deploy.md` 与 `manual-deploy.md` 为准；本文聚焦密钥准备。

### 6. 排障

| 现象 | 原因 | 处理 |
| --- | --- | --- |
| 渲染报"仍有未替换令牌: DB_PASSWORD ..." | 该 Secret 未设置，或设置在别的环境 | 在对应环境补 Secret 后重跑 |
| 渲染报"含单引号/换行" | Secret 值含非法字符 | 用 `openssl rand` 重新生成 |
| 部署成功但登录失败 | 密码与既有库不一致（如已手工建过库） | 确认 `~/pigsty/pigsty.yml`、`/etc/pgbouncer/userlist.txt`、`gateway/.env` 三处一致（渲染保证）；Logto 侧需 `--swe` 重灌或改密码 |

---

## 三、Secret 值约束（重要）

1. **禁止**：单引号 `'`、换行符（SSH 内联注入 + render-config.sh 双重校验）。
2. **建议避免**：空格（单引号包裹时虽合法，但增加出错面）。
3. `base64` 输出含 `+``/``=` 是正常的，不影响注入。
4. **不要**把仓库内的开发默认值（`dev_password_change_me` 等）用于 staging/production。
5. 改密码 = 改 GitHub Secret → 重跑 `deploy-infra`（重新渲染 pigsty.yml/userlist 并落盘）→ 重跑 `deploy-gateway`（PostgREST/Logto 连接串）→ 验证。

---

## 四、关联文件

- `scripts/render-config.sh`（渲染 + 校验）
- `.github/workflows/deploy-all.yml` / `deploy-infra.yml` / `deploy-db.yml` / `deploy-gateway.yml`（Secrets 注入）
- `infra/pigsty.yml` / `infra/pigsty.yml.tpl` / `infra/userlist.txt` / `infra/userlist.txt.tpl`
- `.env.example` / `.env.development` / `.env.staging` / `.env.production` / `gateway/.env.example`
- `wiki/03-部署指南/multi-node-cicd-evolution.md` §6.6（渲染方案说明）
