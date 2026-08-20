# =============================================================================
# OmniPG 统一 Pigsty 配置（唯一 inventory，官方单文件模型，2026-08-19 方案 A 定稿）
#   - 单机 Phase 1：所有组指向 127.0.0.1，./install.yml / ./deploy.yml 全量部署
#   - 多机 Phase 2：各组 hosts 填不同服务器 IP，按官方剧本 + -l 主机限制分角色部署
#     （db → pgsql/infra/etcd/vibe；gateway → node/docker/redis）
#   官方文档: 配置清单 https://doc.pigsty.cc/docs/concept/iac/inventory/
#            剧本列表 http://pigsty.cc/docs/ref/playbook/
#            生产安装 https://doc.pigsty.io/docs/deploy/install/
#   pgaudit/pgsodium 已于 2026-08-19 移除；pg_pwhash 已于 2026-08-19 退役
#   已废弃: infra/pigsty.db.yml / infra/pigsty.gateway.yml（2026-08-19 合并删除）
#
#   决策记录（2026-08-20 定稿；当前仍以单机 Phase 1 部署为准，Phase 2a/2b/3 仅文档补充）：
#     ① Redis 始终由 Pigsty REDIS 模块管理（standalone 原生），不进 Docker（取代 ci-cd v2.1 决策 4）
#     ② 多机后 logto 库与业务库/权限认证模块同机同集群；落地时在此文件 pg_databases/pg_users 声明
#     ③ pg_hba 10.0.0.0/8 为 Phase 2 过渡网段，落地时按最小权限收窄（具体网段/主机）
#     ④ node_firewall_public_port 为单机大并集；分机后按角色组 vars 收敛（见下方端口注释）
#     ⑤ 生产密码一致性 = CI 渲染（.env / pigsty.yml / userlist.txt 三处一致）+ GitHub Secrets
#     ⑥ DNS 域名按环境区分（如 i.staging.pigsty / i.prod.pigsty）
#     ⑦ 版本口径以仓库锁定版本为准（Pigsty v4.4.0）；pigsty.cc 在线文档可能更新（v4.5），机制通用
#   多机拓扑与 CI/CD 演进说明：wiki/03-部署指南/multi-node-cicd-evolution.md
#   渲染说明：本文件为 development/单机字面值；staging/production 由 scripts/render-config.sh
#             使用 infra/pigsty.yml.tpl + infra/userlist.txt.tpl 渲染（三处一致：.env / pigsty.yml / userlist.txt）
# =============================================================================
all:

  children:

    pg_omnipg:
      hosts:
        127.0.0.1: { pg_seq: 1, pg_role: primary }
      vars:
        pg_cluster: pg_omnipg
        pg_extensions:
          - pgcrypto
          - pg_net
          - pgtap
          - pg_graphql
          - pg_cron
          # ---- 2026-08-05 新增（24-扩展引入分析 决策）----
          - safeupdate            # P0 防误删（需 shared_preload，装包后需 edit-config 加 preload + 重启）
          - plpgsql_check         # P0 静态检查
          - pg_jsonschema         # P0 update_config 校验
          - omni_csv              # P0 export/import_csv 重写
          - pgmemento             # P1 审计时间旅行（试点）
          - pg_mockable           # P1 pgtap 配套单测
          - jsquery               # P1 JSONB 查询语言
          - index_advisor         # P1 索引建议工具
          - pg_repack             # P1 膨胀治理
        pg_users:
          - name: app_owner
            password: ${DB_PASSWORD}
            pgbouncer: true
            privileges: CREATEDB
            comment: 'app owner'
          - name: authenticator
            password: ${AUTHENTICATOR_PASSWORD}
            pgbouncer: true
            comment: 'PostgREST auth role'
          - name: web_anon
            comment: 'PostgREST anonymous role (NOLOGIN)'
          - name: logto
            password: ${LOGTO_DB_PASSWORD}
            comment: 'Logto OIDC service account（与业务库同机同集群，2026-08-20 决策）'
        pg_databases:
          - name: app_db
            owner: app_owner
            comment: 'OmniPG main database'
            extensions:
              - { name: pgcrypto }
              - { name: pg_net }
              - { name: pgtap }
              - { name: pg_graphql }
              - { name: pg_cron }
              # ---- 2026-08-05 新增（24-扩展引入分析 决策）----
              - { name: plpgsql_check }
              - { name: pg_jsonschema }
              - { name: omni_csv }
              - { name: pgmemento }
              - { name: pg_mockable }
              - { name: jsquery }
              - { name: index_advisor }
              - { name: pg_repack }
              # 注: safeupdate 无需 CREATE EXTENSION（Load=是 Create=否），仅装包 + preload
          - name: logto
            owner: logto
            comment: 'Logto OIDC 数据库（与业务库同机同集群，2026-08-20 决策；直连 5433，不经 pgbouncer）'
        pg_hba_builtin: []  # 禁用内置规则，使用自定义规则
        pg_hba_rules:
          - type: host
            database: all
            user: all
            address: 127.0.0.1/32
            method: scram-sha-256
            comment: 'local IPv4'
          - type: host
            database: all
            user: all
            address: ::1/128
            method: scram-sha-256
            comment: 'local IPv6'
          - type: host
            database: all
            user: all
            address: 172.17.0.0/16
            method: scram-sha-256
            comment: 'Docker bridge'
          - type: host
            database: all
            user: all
            address: 172.20.0.0/16
            method: scram-sha-256
            comment: 'Docker app-net'
          - type: host
            database: all
            user: all
            address: 10.0.0.0/8
            method: scram-sha-256
            comment: '内网 (Phase 2 过渡网段，落地时按最小权限收窄为具体网段/主机，2026-08-20 决策)'

    infra:
      hosts:
        127.0.0.1: { infra_seq: 1 }
      vars:
        repo_enabled: false
        nginx_enabled: true
        grafana_enabled: true
        victoriametrics_enabled: true
        victorialogs_enabled: true
        victoriatraces_enabled: true
        dnsmasq_enabled: true
        chrony_enabled: true

    etcd:
      hosts:
        127.0.0.1: { etcd_seq: 1 }
      vars:
        etcd_cluster: etcd
        etcd_safeguard: false

    # Redis：Pigsty REDIS 模块统一管理（standalone 原生部署，不进 Docker，2026-08-20 决策）
    # 多机时默认随网关机（与 deploy-infra.sh gateway 模式一致），Phase 2 定稿实际主机时确认
    redis:
      hosts:
        127.0.0.1: { redis_node: 1, redis_instances: { 6379: {} } }
      vars:
        redis_cluster: redis
        redis_mode: standalone
        redis_exporter_enabled: true

    docker:
      hosts:
        127.0.0.1: { docker_seq: 1 }

    vibe:
      hosts:
        127.0.0.1: { vibe_seq: 1 }
      vars:
        vibe_enabled: true
        vibe_packages:
          - claude
          - nodejs
        vibe_features:
          claude_code: true

  vars:

    version: v4.4.0
    admin_ip: 127.0.0.1
    region: china
    proxy_env:
      no_proxy: "localhost,127.0.0.1,10.0.0.0/8,192.168.0.0/16,*.pigsty,*.aliyun.com,mirrors.*,*.myqcloud.com,*.tsinghua.edu.cn"

    infra_portal:
      home         : { domain: i.pigsty }
      grafana      : { domain: g.pigsty, endpoint: "${admin_ip}:3000", websocket: true }
      vmetrics     : { domain: p.pigsty, endpoint: "${admin_ip}:8428" }
      pgadmin      : { domain: adm.pigsty, endpoint: "${admin_ip}:8885" }
      code         : { domain: code.pigsty, endpoint: "${admin_ip}:8080" }
      jupyter      : { domain: jupyter.pigsty, endpoint: "${admin_ip}:8889" }

    nodename_overwrite: false
    node_tune: oltp
    node_etc_hosts: ['${admin_ip} i.pigsty sss.pigsty']
    node_repo_modules: 'node,infra,pgsql'
    node_repo_remove: true
    # Phase 1 单机全栈 + Phase 2 分离（db: 6432/8428/2379；gw: 9080/9180/8082/6379）端口并集
    # 2026-08-20 端口收敛：9080 为唯一对外端口；9180 仅内网管理（按内网来源放行）；9443 已从列表移除（预留，不映射）
    # 2026-08-20 决策：单机阶段保留并集；分机后按角色组 vars 收敛（见 wiki/03-部署指南/multi-node-cicd-evolution.md §5.4）
    node_firewall_public_port: [22, 80, 443, 5432, 6432, 3000, 8428, 2379, 9080, 9180, 8000, 8082, 6379]

    pg_version: 18
    pg_locale: C.UTF-8
    pg_lc_collate: C.UTF-8
    pg_lc_ctype: C.UTF-8
    pg_conf: oltp.yml
    pg_safeguard: false
    pg_packages: [ pgsql-main, pgsql-common ]

    grafana_admin_password: pigsty
    grafana_view_password: DBUser.Viewer
    pg_admin_password: DBUser.DBA
    pg_monitor_password: DBUser.Monitor
    pg_replication_password: DBUser.Replicator
    patroni_password: Patroni.API
    haproxy_admin_password: pigsty
    etcd_root_password: Etcd.Root
