# Phase 0 验证脚本归档（Casdoor v3.133.0）

> 来源：2026-08-02 Phase 0 验证会话。原 `.hermes_tmp/` 下 6 个临时脚本已清理，
> 按用户要求重建为合并版归档于此。功能与原脚本等价，另加角色注入验证。

## 文件

| 文件 | 说明 |
|---|---|
| `casdoor-verify.sh` | 合并版验证脚本（原 6 个脚本 + 角色注入验证） |

## 用法

```bash
bash casdoor-verify.sh all        # 全量验证
bash casdoor-verify.sh login      # 仅登录 + 应用/组织/用户查询
bash casdoor-verify.sh token      # password grant + JWT claims 解码
bash casdoctor-verify.sh d8       # 用户管理 API 链路（add-user/set-password/登录/清理）
bash casdoor-verify.sh pkce       # authorization_code + PKCE 端点
bash casdoor-verify.sh role       # 角色 → JWT roles claim 注入
```

## 已验证的关键事实（2026-08-02，Casdoor 3.133.0）

1. **登录 API**：`POST /api/login` 用 JSON body，`type="login"`（v1.x 的 `signin` 已废弃）；
   admin 初始密码 `123`（见 docs/开发实施方案/01-环境搭建，服务速查手册写的 pigsty 有误）。
2. **built-in 组织禁止 add-user**（v3 安全加固，该组织用户均为全局管理员）→ 业务用户必须建在
   业务组织（如 `omnipg`）下。
3. **grantTypes 白名单**：应用默认全禁；password/authorization_code 需显式配置。
4. **JWT claims**：`sub` = 用户 UUID（= `id`）；`jti` 存在（黑名单可用）；`aud` = clientId；
   **`roles` 是角色对象数组**（`[{"name":"authenticated",...}]`）→ PostgREST 应配
   `jwt-role-claim-key = "roles[0].name"`（原 `roles[0]` 取到对象，恒匹配失败）。
5. **JWT 默认携带 password/passwordSalt 等敏感字段** → 必须配置 `tokenFields` 白名单。
6. **authorization_endpoint 曾指向 :7001**（origin 配置遗留）→ 需修正 origin。
7. **set-password**：form 表单，`userOwner`/`userName` 分字段（不是 JSON userName="org/name"）。
8. **APISIX jwt-auth 插件**：metadata 为 HS256 开发密钥，与 Casdoor RS256 不匹配 → 需改 JWKS/公钥验证。

## 凭据说明

脚本内为 dev 环境凭据（admin/123、测试 clientSecret），与 docs/服务访问速查手册、gateway/.env 一致。
生产环境不得使用。
