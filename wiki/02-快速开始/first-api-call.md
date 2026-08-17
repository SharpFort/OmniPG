# 第一个 API 调用

> 状态：骨架占位 · 待补充
> 定位：注册/登录 → 获取 token → 调用 PostgREST 的完整链路

## 内容清单

- [ ] Logto 注册/登录入口与端口
- [ ] 获取 access token（OIDC/OAuth2 流程简述）
- [ ] PostgREST 入口与鉴权头（Authorization: Bearer）
- [ ] 示例：查询一个公开视图
- [ ] 示例：调用一个 RPC
- [ ] 常见报错与含义（401/403/404）

---

## 调用示例

```bash
# 伪代码：先用 Logto 拿到 token
TOKEN=<your_access_token>
# 查询视图
curl -H 'Authorization: Bearer $TOKEN' \
  http://127.0.0.1:<postgrest-port>/<schema>/<view>
# 调用 RPC
curl -X POST -H 'Authorization: Bearer $TOKEN' \
  -H 'Content-Type: application/json' \
  -d '{}' \
  http://127.0.0.1:<postgrest-port>/rpc/<rpc_name>
```

---

> 参考：本页内容需与当前代码保持一致，补充时请核对 `feature/logto-authn` 分支。
