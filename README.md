# OmniPG

**OmniPG** = **"Omnipotent"（全能的）+ Postgres**。

寓意：这是一个**全能的、自包含的数据库驱动应用引擎**"Omni" 代表全能、无所不在。暗示有了它，Postgres 可以搞定一切，具备很强的平台感（类似 Supabase 的定位）。

---

## 项目简介

OmniPG 是一个以 PostgreSQL 为核心的全方位数据库驱动应用引擎。它围绕 Postgres 构建了一整套开箱即用的工程能力，让开发者能够快速搭建现代化的数据驱动应用。

### 核心组件

| 组件 | 说明 |
|------|------|
| **PostgreSQL** | 核心数据库引擎 |
| **pgBouncer** | 连接池管理 |
| **PostgREST** | 自动将数据库暴露为 RESTful API |
| **APISIX** | API 网关层 |
| **Syncer** | 数据同步工具 |

### 项目结构

```
OmniPG/
├── apisix/          # API 网关配置
├── db/              # 数据库相关
├── pgbouncer/       # 连接池配置
├── postgrest/       # PostgREST 配置
├── syncer/          # 数据同步服务
├── scripts/         # 工具脚本
├── docker-compose.yml
└── Makefile
```

## 快速开始

```bash
# 克隆项目
git clone https://github.com/SharpFort/OmniPG.git
cd OmniPG

# 启动所有服务
docker-compose up -d
```

## 文档

- [开发实施方案](./开发实施方案/)
- [参考文档](./参考文档/)

## 许可证

MIT
