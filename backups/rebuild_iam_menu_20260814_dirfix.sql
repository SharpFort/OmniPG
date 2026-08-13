-- 目录行补 router/route_name（虚拟英文值：子菜单全为绝对路径，目录 path 不参与拼接；
-- 避免 MenuProcessor rawPath = path || name 回退成中文；日志管理用 system-log 防与 system 冲突）
UPDATE public.iam_menu SET router = CASE menu_name
    WHEN '仪表盘'   THEN 'dashboard'
    WHEN '只读镜像' THEN 'mirror'
    WHEN '系统管理' THEN 'system'
    WHEN '日志管理' THEN 'system-log'
    WHEN '结果页面' THEN 'result'
    WHEN '异常页面' THEN 'exception'
    END,
    route_name = CASE menu_name
    WHEN '仪表盘'   THEN 'Dashboard'
    WHEN '只读镜像' THEN 'Mirror'
    WHEN '系统管理' THEN 'System'
    WHEN '日志管理' THEN 'Log'
    WHEN '结果页面' THEN 'Result'
    WHEN '异常页面' THEN 'Exception'
    END
WHERE menu_type = 'directory' AND menu_name IN
    ('仪表盘','只读镜像','系统管理','日志管理','结果页面','异常页面');

-- 验证
SELECT menu_name, router, route_name FROM public.iam_menu WHERE menu_type='directory' ORDER BY order_num;
