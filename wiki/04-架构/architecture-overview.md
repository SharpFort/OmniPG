# 架构概览

> 状态：骨架占位 · 待补充
> 定位：系统拓扑、请求链路与分层设计

## 内容清单

- [ ] 系统拓扑图（Client → APISIX → PostgREST → PostgreSQL，Logto 旁路）
- [ ] 请求主链路：认证、鉴权、数据访问
- [ ] 分层说明：网关层 / API 层 / 数据层
- [ ] 模块划分总览（按 schema）
- [ ] 架构关键特性：数据库即后端、RLS 数据隔离

---

## 拓扑示意（待补图）

```text
Client
  │
  ▼
APISIX ──────► Logto（认证/授权）
  │
  ▼
PostgREST
  │
  ▼
PostgreSQL（Pigsty 集群 + pgbouncer + redis）
```

---

> 参考：本页内容需与当前代码保持一致，补充时请核对 `feature/logto-authn` 分支。
