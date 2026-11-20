-- S-G2（2026-11-20）：pgbouncer userlist 角色集契约
-- 本文件不再承载 ${PASSWORD} 明文令牌：SCRAM passthrough 要求 userlist 中的
-- verifier 与库端 pg_authid 逐字节一致（离线渲染必漂移），故部署期用
-- scripts/pgbouncer-userlist-scram.sh 从 pg_authid 生成，明文不落地：
--   sudo -u postgres ./scripts/pgbouncer-userlist-scram.sh app_owner,authenticator,logto \
--     > /etc/pgbouncer/userlist.txt && psql -p 6432 -U app_owner -d pgbouncer -c RELOAD
-- casdoor 已随 T7（Logto 替换 Casdoor）退役移除；pigsty 部署时自动追加
-- dbuser_monitor（监控探活）。
"app_owner"
"authenticator"
"logto"
