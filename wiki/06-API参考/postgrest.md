# PostgREST 使用指南

> 状态：骨架占位 · 待补充
> 定位：入口、端口、鉴权、查询语法、OpenAPI

## 内容清单

- [ ] PostgREST 入口与端口（gateway/postgrest/postgrest.conf 中的配置）
- [ ] 鉴权头：Authorization: Bearer <token>
- [ ] schemas 暴露范围（public / api_v1）
- [ ] 查询语法：过滤、排序、分页、嵌入（embed）
- [ ] RPC 调用：POST /rpc/<name>
- [ ] OpenAPI / Swagger 文档地址
- [ ] 常见错误码与排查

---

## 查询示例（待补全）

```bash
# 过滤与排序
curl -H 'Authorization: Bearer $TOKEN' \
  'http://<host>:<port>/<view>?col=eq.xxx&order=id.desc&limit=10'
# RPC
curl -X POST -H 'Authorization: Bearer $TOKEN' \
  -H 'Content-Type: application/json' -d '{}' \
  'http://<host>:<port>/rpc/<rpc_name>'
```

---

> 参考：本页内容需与当前代码保持一致，补充时请核对 `feature/logto-authn` 分支。
