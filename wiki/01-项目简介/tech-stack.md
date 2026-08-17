# 技术栈全景

> 状态：骨架占位 · 待补充
> 定位：各技术组件、选型理由与职责边界一览

## 内容清单

- [ ] Pigsty：基础设施与 PostgreSQL 集群
- [ ] PostgreSQL 扩展清单（db/extensions 下的扩展及用途）
- [ ] PostgREST：API 层职责与限制
- [ ] APISIX：网关职责与插件使用
- [ ] Logto：认证授权职责
- [ ] Redis：缓存/会话用途
- [ ] dbmate、pgTAP 等开发工具链
- [ ] 多环境：development / staging / production

---

## 组件职责速查表

| 组件 | 职责 | 配置位置 |
| --- | --- | --- |
| Pigsty | 集群部署 | infra/pigsty*.yml |
| PostgreSQL | 数据+业务逻辑 | db/ |
| PostgREST | REST 暴露 | gateway/postgrest/postgrest.conf |
| APISIX | 路由网关 | gateway/apisix/ |
| Logto | 认证授权 | 由 APISIX 转发 |

---

> 参考：本页内容需与当前代码保持一致，补充时请核对 `feature/logto-authn` 分支。
