# Policy Syncer 状态检查脚本
# 修复 N-4: 使用 --tail 限制日志量，避免大日志文件导致 OOM

set -euo pipefail

echo "========================================"
echo "  Policy Syncer 状态检查"
echo "========================================"

# 检查容器状态
status=$(docker inspect --format='{{.State.Status}}' policy-syncer 2>/dev/null || echo "not found")
if [ "$status" = "running" ]; then
    echo "✅ 容器状态: running"
else
    echo "❌ 容器状态: $status"
fi

# 最近日志 (只取最后 100 行到内存中)
echo ""
echo "📋 最近 10 行日志："
docker logs --tail=10 policy-syncer 2>/dev/null || echo "（无法读取日志）"

# 关键状态（修复 N-4: 只 grep 最近 100 行，不全量读取）
echo ""
echo "🔍 关键状态："
logs=$(docker logs --tail=100 policy-syncer 2>/dev/null || echo "")
if echo "$logs" | grep -q "正在监听 PostgreSQL\|casbin_channel"; then
    echo "  ✅ PostgreSQL 监听已建立"
fi
if echo "$logs" | grep -q "Advisory Lock"; then
    echo "  ✅ 已成为 leader"
fi
if echo "$logs" | grep -q "已同步.*条策略"; then
    echo "  ✅ 策略已同步"
fi
if echo "$logs" | grep -q "哈希匹配"; then
    echo "  ✅ 对账通过"
fi

echo ""
echo "========================================"
