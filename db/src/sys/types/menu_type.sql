-- db/src/sys/types/menu_type.sql
-- 菜单类型枚举
-- 来源: sys_menu.type 字段

DO $$ BEGIN
    CREATE TYPE public.menu_type AS ENUM ('DIR', 'MENU', 'BUTTON');
EXCEPTION WHEN duplicate_object THEN null; END $$;

COMMENT ON TYPE public.menu_type IS '菜单类型：DIR=目录, MENU=菜单, BUTTON=按钮';
