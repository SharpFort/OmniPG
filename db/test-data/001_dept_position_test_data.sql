-- =============================================================================
-- 001_dept_position_test_data.sql — 部门管理 / 岗位管理 / 用户岗位 测试数据
-- =============================================================================
-- 适用: D27 双语义 schema（tenant_id = Logto 部署租户, organization_id = Logto Organization）
-- 挂载: Logto 租户 'default' + 业务组织 'q8xan57gksx5'（默认租户）
-- 前置: platform.tenants 含 'default'; public.organizations 含 'q8xan57gksx5'
-- 执行: 分两段用不同角色执行（app_owner 对 Logto 基表无写权限）:
--   第 1-2 节(用户+组织成员)  → psql -U logto   ...（或超级用户）
--   第 3-6 节(部门/岗位/关联) → psql -U app_owner ...
-- 幂等: 全部 ON CONFLICT DO NOTHING，可重复执行
-- 设计的测试点:
--   部门: 3 级树(总部→中心→组/部)、双根(总部+华南分公司)、停用部门(运维组)、
--         软删除部门(战略投资部，回收站测试)、排序字段
--   岗位: 4 级职级树(总经理→总监→经理→工程师)、停用岗位(实习生)、
--         软删除岗位(高级顾问)、pos_code 职级编码
--   用户岗位: 一人多岗(主岗+兼岗)、多人同岗、挂停用岗位的用户、
--             仅兼岗无主岗的边界用户(yangfan)
--   用户档案: 挂停用部门的用户(chenchen)、未分配部门用户(yangfan)、
--             gender 枚举/hobbies 数组/preferences jsonb 富字段
-- =============================================================================

BEGIN;

-- -----------------------------------------------------------------------------
-- 1. Logto 测试用户（public.users，租户 default；password_encrypted 置空=不可登录，仅作业务数据）
-- -----------------------------------------------------------------------------
INSERT INTO public.users (id, tenant_id, username, name, primary_email, profile, custom_data)
VALUES
  ('test00000001', 'default', 'zhangwei01', '张伟', 'zhangwei01@test.local', '{"gender":"male"}'::jsonb, '{"source":"test-seed"}'::jsonb),
  ('test00000002', 'default', 'lina02',     '李娜', 'lina02@test.local',     '{"gender":"female"}'::jsonb, '{"source":"test-seed"}'::jsonb),
  ('test00000003', 'default', 'wangqiang03','王强', 'wangqiang03@test.local','{"gender":"male"}'::jsonb, '{"source":"test-seed"}'::jsonb),
  ('test00000004', 'default', 'zhaomin04',  '赵敏', 'zhaomin04@test.local',  '{"gender":"female"}'::jsonb, '{"source":"test-seed"}'::jsonb),
  ('test00000005', 'default', 'sunli05',    '孙丽', 'sunli05@test.local',    '{"gender":"female"}'::jsonb, '{"source":"test-seed"}'::jsonb),
  ('test00000006', 'default', 'zhoujie06',  '周杰', 'zhoujie06@test.local',  '{"gender":"male"}'::jsonb, '{"source":"test-seed"}'::jsonb),
  ('test00000007', 'default', 'wuyan07',    '吴艳', 'wuyan07@test.local',    '{"gender":"female"}'::jsonb, '{"source":"test-seed"}'::jsonb),
  ('test00000008', 'default', 'zhenghao08', '郑浩', 'zhenghao08@test.local', '{"gender":"male"}'::jsonb, '{"source":"test-seed"}'::jsonb),
  ('test00000009', 'default', 'fengxue09',  '冯雪', 'fengxue09@test.local',  '{"gender":"female"}'::jsonb, '{"source":"test-seed"}'::jsonb),
  ('test00000010', 'default', 'chenchen10', '陈晨', 'chenchen10@test.local', '{"gender":"male"}'::jsonb, '{"source":"test-seed"}'::jsonb),
  ('test00000011', 'default', 'xujing11',   '许静', 'xujing11@test.local',   '{"gender":"female"}'::jsonb, '{"source":"test-seed"}'::jsonb),
  ('test00000012', 'default', 'hebin12',    '何斌', 'hebin12@test.local',    '{"gender":"male"}'::jsonb, '{"source":"test-seed"}'::jsonb),
  ('test00000013', 'default', 'yangfan13',  '杨帆', 'yangfan13@test.local',  '{"gender":"other"}'::jsonb, '{"source":"test-seed"}'::jsonb)
ON CONFLICT DO NOTHING;

-- -----------------------------------------------------------------------------
-- 2. 组织成员关系（public.organization_user_relations → platform.user_tenants）
--    identity_refs_guard 触发器要求 user_position/user_profile 的用户必须是组织成员
-- -----------------------------------------------------------------------------
INSERT INTO public.organization_user_relations (tenant_id, organization_id, user_id)
SELECT 'default', 'q8xan57gksx5', u.id FROM public.users u WHERE u.id LIKE 'test000000%'
ON CONFLICT DO NOTHING;

-- -----------------------------------------------------------------------------
-- 3. 部门树（platform.department）
--    层级: 1=总部 2=中心 3=组/部；另含第二根「华南分公司」、停用部门、软删除部门
-- -----------------------------------------------------------------------------
INSERT INTO platform.department (id, dept_name, organization_id, tenant_id, parent_id, sort_order, is_active, deleted_at, created_by) VALUES
  -- 根 1：集团总部
  ('a0000000-0000-7000-8000-000000000001', '集团总部',     'q8xan57gksx5', 'default', NULL,                                     1, true,  NULL, 'jhofj1o262q8'),
  -- 2 级：四大中心
  ('a0000000-0000-7000-8000-000000000002', '研发中心',     'q8xan57gksx5', 'default', 'a0000000-0000-7000-8000-000000000001',   1, true,  NULL, 'jhofj1o262q8'),
  ('a0000000-0000-7000-8000-000000000007', '产品中心',     'q8xan57gksx5', 'default', 'a0000000-0000-7000-8000-000000000001',   2, true,  NULL, 'jhofj1o262q8'),
  ('a0000000-0000-7000-8000-00000000000a', '市场运营中心', 'q8xan57gksx5', 'default', 'a0000000-0000-7000-8000-000000000001',   3, true,  NULL, 'jhofj1o262q8'),
  ('a0000000-0000-7000-8000-00000000000d', '职能中心',     'q8xan57gksx5', 'default', 'a0000000-0000-7000-8000-000000000001',   4, true,  NULL, 'jhofj1o262q8'),
  -- 3 级：研发中心下属 4 组（运维组=停用）
  ('a0000000-0000-7000-8000-000000000003', '前端开发组',   'q8xan57gksx5', 'default', 'a0000000-0000-7000-8000-000000000002',   1, true,  NULL, 'jhofj1o262q8'),
  ('a0000000-0000-7000-8000-000000000004', '后端开发组',   'q8xan57gksx5', 'default', 'a0000000-0000-7000-8000-000000000002',   2, true,  NULL, 'jhofj1o262q8'),
  ('a0000000-0000-7000-8000-000000000005', '测试组',       'q8xan57gksx5', 'default', 'a0000000-0000-7000-8000-000000000002',   3, true,  NULL, 'jhofj1o262q8'),
  ('a0000000-0000-7000-8000-000000000006', '运维组',       'q8xan57gksx5', 'default', 'a0000000-0000-7000-8000-000000000002',   4, false, NULL, 'jhofj1o262q8'),
  -- 3 级：产品中心
  ('a0000000-0000-7000-8000-000000000008', '产品规划部',   'q8xan57gksx5', 'default', 'a0000000-0000-7000-8000-000000000007',   1, true,  NULL, 'jhofj1o262q8'),
  ('a0000000-0000-7000-8000-000000000009', '用户体验部',   'q8xan57gksx5', 'default', 'a0000000-0000-7000-8000-000000000007',   2, true,  NULL, 'jhofj1o262q8'),
  -- 3 级：市场运营中心
  ('a0000000-0000-7000-8000-00000000000b', '市场推广部',   'q8xan57gksx5', 'default', 'a0000000-0000-7000-8000-00000000000a',   1, true,  NULL, 'jhofj1o262q8'),
  ('a0000000-0000-7000-8000-00000000000c', '客户成功部',   'q8xan57gksx5', 'default', 'a0000000-0000-7000-8000-00000000000a',   2, true,  NULL, 'jhofj1o262q8'),
  -- 3 级：职能中心
  ('a0000000-0000-7000-8000-00000000000e', '人力资源部',   'q8xan57gksx5', 'default', 'a0000000-0000-7000-8000-00000000000d',   1, true,  NULL, 'jhofj1o262q8'),
  ('a0000000-0000-7000-8000-00000000000f', '财务部',       'q8xan57gksx5', 'default', 'a0000000-0000-7000-8000-00000000000d',   2, true,  NULL, 'jhofj1o262q8'),
  -- 根 2：华南分公司（双根结构测试）+ 下属部门
  ('a0000000-0000-7000-8000-000000000010', '华南分公司',   'q8xan57gksx5', 'default', NULL,                                     2, true,  NULL, 'jhofj1o262q8'),
  ('a0000000-0000-7000-8000-000000000011', '华南研发部',   'q8xan57gksx5', 'default', 'a0000000-0000-7000-8000-000000000010',   1, true,  NULL, 'jhofj1o262q8'),
  -- 软删除部门（回收站/过滤逻辑测试）
  ('a0000000-0000-7000-8000-000000000012', '战略投资部',   'q8xan57gksx5', 'default', NULL,                                     5, true,  now(), 'jhofj1o262q8')
ON CONFLICT (id) DO NOTHING;

-- -----------------------------------------------------------------------------
-- 4. 岗位树（platform."position"）
--    4 级职级树 + pos_code 职级编码 + 停用岗位 + 软删除岗位
-- -----------------------------------------------------------------------------
INSERT INTO platform."position" (id, pos_name, pos_code, organization_id, tenant_id, parent_id, sort_no, status, remark, deleted_at, created_by) VALUES
  ('b0000000-0000-7000-8000-000000000001', '总经理',     'M9-01', 'q8xan57gksx5', 'default', NULL,                                    1, true,  '公司最高管理岗位',      NULL, 'jhofj1o262q8'),
  -- 技术序列
  ('b0000000-0000-7000-8000-000000000002', '技术总监',   'M6-01', 'q8xan57gksx5', 'default', 'b0000000-0000-7000-8000-000000000001',  1, true,  '技术条线负责人',        NULL, 'jhofj1o262q8'),
  ('b0000000-0000-7000-8000-000000000003', '开发经理',   'M4-01', 'q8xan57gksx5', 'default', 'b0000000-0000-7000-8000-000000000002',  1, true,  NULL,                    NULL, 'jhofj1o262q8'),
  ('b0000000-0000-7000-8000-000000000004', '测试经理',   'M4-02', 'q8xan57gksx5', 'default', 'b0000000-0000-7000-8000-000000000002',  2, true,  NULL,                    NULL, 'jhofj1o262q8'),
  ('b0000000-0000-7000-8000-000000000005', '高级工程师', 'P6-01', 'q8xan57gksx5', 'default', 'b0000000-0000-7000-8000-000000000003',  1, true,  NULL,                    NULL, 'jhofj1o262q8'),
  ('b0000000-0000-7000-8000-000000000006', '软件工程师', 'P5-01', 'q8xan57gksx5', 'default', 'b0000000-0000-7000-8000-000000000003',  2, true,  NULL,                    NULL, 'jhofj1o262q8'),
  ('b0000000-0000-7000-8000-000000000007', '测试工程师', 'P5-02', 'q8xan57gksx5', 'default', 'b0000000-0000-7000-8000-000000000004',  1, true,  NULL,                    NULL, 'jhofj1o262q8'),
  -- 市场序列
  ('b0000000-0000-7000-8000-000000000008', '市场总监',   'M6-02', 'q8xan57gksx5', 'default', 'b0000000-0000-7000-8000-000000000001',  2, true,  NULL,                    NULL, 'jhofj1o262q8'),
  ('b0000000-0000-7000-8000-000000000009', '市场经理',   'M3-01', 'q8xan57gksx5', 'default', 'b0000000-0000-7000-8000-000000000008',  1, true,  NULL,                    NULL, 'jhofj1o262q8'),
  ('b0000000-0000-7000-8000-00000000000a', '市场专员',   'P4-01', 'q8xan57gksx5', 'default', 'b0000000-0000-7000-8000-000000000009',  1, true,  NULL,                    NULL, 'jhofj1o262q8'),
  -- 职能序列
  ('b0000000-0000-7000-8000-00000000000b', '人事经理',   'M3-02', 'q8xan57gksx5', 'default', 'b0000000-0000-7000-8000-000000000001',  3, true,  NULL,                    NULL, 'jhofj1o262q8'),
  ('b0000000-0000-7000-8000-00000000000c', '人事专员',   'P3-01', 'q8xan57gksx5', 'default', 'b0000000-0000-7000-8000-00000000000b',  1, true,  NULL,                    NULL, 'jhofj1o262q8'),
  ('b0000000-0000-7000-8000-00000000000d', '财务总监',   'M5-02', 'q8xan57gksx5', 'default', 'b0000000-0000-7000-8000-000000000001',  4, true,  NULL,                    NULL, 'jhofj1o262q8'),
  -- 停用岗位（用户岗位列表边界测试）
  ('b0000000-0000-7000-8000-00000000000e', '实习生',     'P1-01', 'q8xan57gksx5', 'default', NULL,                                    5, false, '停用状态测试岗位',      NULL, 'jhofj1o262q8'),
  -- 软删除岗位（回收站测试）
  ('b0000000-0000-7000-8000-00000000000f', '高级顾问',   'P7-01', 'q8xan57gksx5', 'default', NULL,                                    6, true,  '已软删除',              now(), 'jhofj1o262q8')
ON CONFLICT (id) DO NOTHING;

-- -----------------------------------------------------------------------------
-- 5. 用户岗位（platform.user_position，多对多 + 主岗标记）
--    覆盖: 一人多岗(主岗+兼岗)、多人同岗、挂停用岗位、仅兼岗无主岗
-- -----------------------------------------------------------------------------
INSERT INTO platform.user_position (user_id, position_id, organization_id, tenant_id, is_primary, created_by) VALUES
  -- 张伟: 开发经理(主) 兼 高级工程师
  ('test00000001', 'b0000000-0000-7000-8000-000000000003', 'q8xan57gksx5', 'default', true,  'jhofj1o262q8'),
  ('test00000001', 'b0000000-0000-7000-8000-000000000005', 'q8xan57gksx5', 'default', false, 'jhofj1o262q8'),
  -- 李娜: 软件工程师(主)
  ('test00000002', 'b0000000-0000-7000-8000-000000000006', 'q8xan57gksx5', 'default', true,  'jhofj1o262q8'),
  -- 王强: 软件工程师(主) —— 与李娜同岗
  ('test00000003', 'b0000000-0000-7000-8000-000000000006', 'q8xan57gksx5', 'default', true,  'jhofj1o262q8'),
  -- 赵敏: 测试经理(主)
  ('test00000004', 'b0000000-0000-7000-8000-000000000004', 'q8xan57gksx5', 'default', true,  'jhofj1o262q8'),
  -- 孙丽: 测试工程师(主) 兼 软件工程师(跨序列兼岗)
  ('test00000005', 'b0000000-0000-7000-8000-000000000007', 'q8xan57gksx5', 'default', true,  'jhofj1o262q8'),
  ('test00000005', 'b0000000-0000-7000-8000-000000000006', 'q8xan57gksx5', 'default', false, 'jhofj1o262q8'),
  -- 周杰: 市场经理(主) 兼 市场总监(上下级兼岗)
  ('test00000006', 'b0000000-0000-7000-8000-000000000009', 'q8xan57gksx5', 'default', true,  'jhofj1o262q8'),
  ('test00000006', 'b0000000-0000-7000-8000-000000000008', 'q8xan57gksx5', 'default', false, 'jhofj1o262q8'),
  -- 吴艳: 市场专员(主)
  ('test00000007', 'b0000000-0000-7000-8000-00000000000a', 'q8xan57gksx5', 'default', true,  'jhofj1o262q8'),
  -- 郑浩: 人事经理(主)
  ('test00000008', 'b0000000-0000-7000-8000-00000000000b', 'q8xan57gksx5', 'default', true,  'jhofj1o262q8'),
  -- 冯雪: 人事专员(主)
  ('test00000009', 'b0000000-0000-7000-8000-00000000000c', 'q8xan57gksx5', 'default', true,  'jhofj1o262q8'),
  -- 陈晨: 高级工程师(主) 兼 软件工程师
  ('test00000010', 'b0000000-0000-7000-8000-000000000005', 'q8xan57gksx5', 'default', true,  'jhofj1o262q8'),
  ('test00000010', 'b0000000-0000-7000-8000-000000000006', 'q8xan57gksx5', 'default', false, 'jhofj1o262q8'),
  -- 许静: 财务总监(主)
  ('test00000011', 'b0000000-0000-7000-8000-00000000000d', 'q8xan57gksx5', 'default', true,  'jhofj1o262q8'),
  -- 何斌: 软件工程师(主) + 实习生(挂停用岗位)
  ('test00000012', 'b0000000-0000-7000-8000-000000000006', 'q8xan57gksx5', 'default', true,  'jhofj1o262q8'),
  ('test00000012', 'b0000000-0000-7000-8000-00000000000e', 'q8xan57gksx5', 'default', false, 'jhofj1o262q8'),
  -- 杨帆: 高级工程师(仅兼岗、无主岗 —— 边界用例)
  ('test00000013', 'b0000000-0000-7000-8000-000000000005', 'q8xan57gksx5', 'default', false, 'jhofj1o262q8')
ON CONFLICT (user_id, position_id) DO NOTHING;

-- -----------------------------------------------------------------------------
-- 6. 用户档案（platform.user_profile：部门归属 dept_id + 富字段）
--    覆盖: 挂停用部门(chenchen→运维组)、未分配部门(yangfan→NULL)、跨根挂部门(hebin→华南)
-- -----------------------------------------------------------------------------
INSERT INTO platform.user_profile
  (user_id, tenant_id, organization_id, dept_id, nickname, gender, birthday, bio, location, hobbies, preferences, created_by)
VALUES
  ('test00000001', 'default', 'q8xan57gksx5', 'a0000000-0000-7000-8000-000000000004', '张伟', 'male',   '1990-03-15', '后端开发组负责人，擅长高并发架构', '广东深圳南山区', '{篮球,摄影,跑步}',        '{"theme":"dark","lang":"zh-CN","notify_email":true}',  'jhofj1o262q8'),
  ('test00000002', 'default', 'q8xan57gksx5', 'a0000000-0000-7000-8000-000000000003', '李娜', 'female', '1994-07-22', '前端工程师，专注可视化方向',       '广东深圳福田区', '{插画,瑜伽}',             '{"theme":"light","lang":"zh-CN","notify_email":false}','jhofj1o262q8'),
  ('test00000003', 'default', 'q8xan57gksx5', 'a0000000-0000-7000-8000-000000000004', '王强', 'male',   '1992-11-08', '后端工程师，中间件方向',           '广东深圳宝安区', '{足球,下棋}',             '{"theme":"dark","lang":"zh-CN"}',                      'jhofj1o262q8'),
  ('test00000004', 'default', 'q8xan57gksx5', 'a0000000-0000-7000-8000-000000000005', '赵敏', 'female', '1991-05-30', '测试经理，自动化测试体系建设',     '广东深圳龙华区', '{阅读,马拉松}',           '{"theme":"auto","lang":"zh-CN"}',                      'jhofj1o262q8'),
  ('test00000005', 'default', 'q8xan57gksx5', 'a0000000-0000-7000-8000-000000000005', '孙丽', 'female', '1995-09-12', '测试工程师，接口测试方向',         '广东深圳龙岗区', '{烘焙,滑雪}',             '{"theme":"light","lang":"zh-CN"}',                     'jhofj1o262q8'),
  ('test00000006', 'default', 'q8xan57gksx5', 'a0000000-0000-7000-8000-00000000000b', '周杰', 'male',   '1988-01-25', '市场条线负责人',                   '广东广州天河区', '{高尔夫,品酒}',  '{"theme":"dark","lang":"zh-CN"}',                      'jhofj1o262q8'),
  ('test00000007', 'default', 'q8xan57gksx5', 'a0000000-0000-7000-8000-00000000000c', '吴艳', 'female', '1996-04-18', '客户成功专员',                     '广东广州越秀区', '{手工,旅行}',             '{"theme":"light","lang":"zh-CN"}',                     'jhofj1o262q8'),
  ('test00000008', 'default', 'q8xan57gksx5', 'a0000000-0000-7000-8000-00000000000e', '郑浩', 'male',   '1989-12-03', '人力资源负责人',                   '广东深圳南山区', '{茶艺}',                  '{"theme":"auto","lang":"zh-CN"}',                      'jhofj1o262q8'),
  ('test00000009', 'default', 'q8xan57gksx5', 'a0000000-0000-7000-8000-00000000000e', '冯雪', 'female', '1997-06-28', '人事专员，招聘方向',               '湖南长沙岳麓区', '{唱歌,滑雪}',             '{"theme":"light","lang":"zh-CN"}',                     'jhofj1o262q8'),
  ('test00000010', 'default', 'q8xan57gksx5', 'a0000000-0000-7000-8000-000000000006', '陈晨', 'male',   '1993-02-14', '高级工程师，SRE 方向（所属部门已停用）', '广东东莞', '{骑行,开源}',             '{"theme":"dark","lang":"zh-CN"}',                      'jhofj1o262q8'),
  ('test00000011', 'default', 'q8xan57gksx5', 'a0000000-0000-7000-8000-00000000000f', '许静', 'female', '1990-08-09', '财务总监',                         '广东深圳盐田区', '{钢琴}',                  '{"theme":"light","lang":"zh-CN"}',                     'jhofj1o262q8'),
  ('test00000012', 'default', 'q8xan57gksx5', 'a0000000-0000-7000-8000-000000000011', '何斌', 'male',   '2000-10-05', '实习生（同时挂停用岗位），base 华南', '广西南宁青秀区', '{桌游,羽毛球}',        '{"theme":"auto","lang":"zh-CN"}',                      'jhofj1o262q8'),
  ('test00000013', 'default', 'q8xan57gksx5', NULL,                                   '杨帆', 'other',  '1999-03-31', '外部顾问（未分配部门、无主岗）',   NULL,             '{写作}',                  '{"theme":"auto","lang":"zh-CN"}',                      'jhofj1o262q8')
ON CONFLICT (user_id) DO NOTHING;

COMMIT;

-- =============================================================================
-- 验证查询（执行后人工核对）
-- =============================================================================
-- 部门树:      SELECT d.dept_name, p.dept_name AS parent, d.is_active, d.deleted_at IS NOT NULL AS deleted
--              FROM platform.department d LEFT JOIN platform.department p ON p.id = d.parent_id
--              WHERE d.organization_id='q8xan57gksx5' ORDER BY d.sort_order;
-- 岗位树:      SELECT p.pos_name, p.pos_code, pp.pos_name AS parent, p.status, p.deleted_at IS NOT NULL AS deleted
--              FROM platform."position" p LEFT JOIN platform."position" pp ON pp.id = p.parent_id
--              WHERE p.organization_id='q8xan57gksx5' ORDER BY p.sort_no;
-- 用户岗位:    SELECT u.name, p.pos_name, up.is_primary, p.status
--              FROM platform.user_position up
--              JOIN platform."position" p ON p.id = up.position_id
--              JOIN platform.users u ON u.id = up.user_id
--              WHERE up.organization_id='q8xan57gksx5' ORDER BY u.id, up.is_primary DESC;
-- 用户-部门:   SELECT u.name, d.dept_name FROM platform.user_profile up
--              LEFT JOIN platform.department d ON d.id = up.dept_id
--              JOIN platform.users u ON u.id = up.user_id
--              WHERE up.organization_id='q8xan57gksx5';
