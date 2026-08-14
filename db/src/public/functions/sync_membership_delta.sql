-- src/public/functions/sync_membership_delta.sql
-- FUNCTION: public.sync_membership_delta（17 号文档归位：迁移 051_logto_guard_cleanup.sql 删定义段，本文件为唯一权威）
-- 回放终态: 051_logto_guard_cleanup.sql；幂等写法（§9 模板）

CREATE OR REPLACE FUNCTION sync_membership_delta(
    org_id  text,
    added   jsonb,
    removed jsonb
) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
    v_user_id text;
BEGIN
    -- N21: 缺失字段视为无变更（Logto 无变更事件也可能推送 Membership.Updated）
    IF added IS NULL OR jsonb_typeof(added) <> 'array' THEN
        added := '[]'::jsonb;
    END IF;
    IF removed IS NULL OR jsonb_typeof(removed) <> 'array' THEN
        removed := '[]'::jsonb;
    END IF;

    -- N21: 空 delta 早退（无变更不空转）
    IF jsonb_array_length(added) = 0 AND jsonb_array_length(removed) = 0 THEN
        RETURN;
    END IF;

    -- 新增成员
    FOR v_user_id IN SELECT * FROM jsonb_array_elements_text(added)
    LOOP
        INSERT INTO user_tenants (organization_id, user_id)
        VALUES (org_id, v_user_id)
        ON CONFLICT DO NOTHING;
    END LOOP;

    -- 移除成员
    FOR v_user_id IN SELECT * FROM jsonb_array_elements_text(removed)
    LOOP
        DELETE FROM user_tenants
        WHERE organization_id = org_id AND user_id = v_user_id;
    END LOOP;
END $$;
