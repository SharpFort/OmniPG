-- 072_search_user_positions.sql
-- 072（2026-08-30）：新增用户-岗位搜索 RPC（search_user_positions）
-- 背景：user_position 视图仅 ID 列，前端用户岗位页此前全量拉取（limit 1000）+
--   本地 join 用户名/岗位名 + 客户端分页，数据超限会静默缺失。
-- 内容：search_user_positions(p_user_id, p_query, p_position_name, p_limit, p_offset)
--   后端 join platform.users（用户名/邮箱/姓名）与岗位树路径（与 rpc_get_position_tree
--   同法递归 CTE），返回 {total, limit, offset, items}；LIMIT 上限 100。
--   SECURITY DEFINER + has_permission('platform:position:list')；DEFINER 不走 RLS，
--   组织/租户隔离由 current_organization_id()/current_logto_tenant_id() 显式过滤。
--   p_user_id 用于编辑回填（取某用户全部分配，供全量覆盖式 assign 前置查询）。
-- 前置：rpc_get_position_tree 所需的 has_permission/current_organization_id/
--   current_logto_tenant_id 均已存在；platform.users 视图已就绪（065 baseline）。
-- P0-5 归位（2026-11-02）：函数定义迁出迁移目录，终态归位
--   db/api_v1/platform/rpc/rpc_search_user_positions.sql（签名/COMMENT/GRANT 一致）。
--   §6.3 零容忍扫描要求迁移目录不含代码对象；且 apply-src 回放顺序中 migrations
--   在 privileges 之后，函数定义留在迁移内会绕过 99_revoke_public 的 PUBLIC 回收。
--   （已应用环境 dbmate 不重跑本迁移；apply-src 经 rpc 文件幂等重建，结果一致。）
-- migrate:up

SELECT 1;  -- no-op：代码对象已归位 db/api_v1（本迁移保留版本号占位）

-- migrate:down

SELECT 1;  -- no-op：函数生命周期由 db/api_v1 终态文件管理
