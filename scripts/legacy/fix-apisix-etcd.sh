#!/bin/bash
set -e

echo "========================================"
echo " APISIX etcd 模式完整修复"
echo "========================================"
echo ""

# Step 1: 修复 etcd 认证
echo "[1/5] 修复 etcd 认证..."

# 检查是否已有 root 用户
USER_EXISTS=$(ETCDCTL_API=3 etcdctl --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/etcd/ca.crt \
  --cert=/etc/etcd/server.crt \
  --key=/etc/etcd/server.key \
  user list 2>&1 | grep -c "root" || echo "0")

if [ "$USER_EXISTS" = "0" ]; then
  echo "  创建 root 用户..."
  ETCDCTL_API=3 etcdctl --endpoints=https://127.0.0.1:2379 \
    --cacert=/etc/etcd/ca.crt \
    --cert=/etc/etcd/server.crt \
    --key=/etc/etcd/server.key \
    user add root:Etcd.Root 2>&1 | tail -3
  
  echo "  授予 root 角色..."
  ETCDCTL_API=3 etcdctl --endpoints=https://127.0.0.1:2379 \
    --cacert=/etc/etcd/ca.crt \
    --cert=/etc/etcd/server.crt \
    --key=/etc/etcd/server.key \
    user grant-role root root 2>&1 | tail -3
else
    # etcd 运行正常
    echo "  root 用户已存在"
    etcdctl endpoint health 2>&1 | head -3
fi

# Step 2: 配置 APISIX 使用 etcd
echo ""
echo "[2/5] 配置 APISIX..."

cd /root/OmniPG/gateway

# 复制配置
cp /mnt/e/Projects/OmniPG/gateway/apisix/config.yaml apisix/config.yaml

echo "  配置已更新"

# Step 3: 清理 etcd 中的旧 APISIX 数据
echo ""
echo "[3/5] 清理 etcd 中的旧数据..."
ETCDCTL_API=3 etcdctl --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/etcd/ca.crt \
  --cert=/etc/etcd/server.crt \
  --key=/etc/etcd/server.crt \
  --user=root:Etcd.Root \
  del /apisix --prefix 2>&1 | tail -3

echo "  旧数据已清理"

# Step 4: 重建 APISIX
echo ""
echo "[4/5] 重建 APISIX..."
docker compose down apisix 2>/dev/null
docker compose up -d apisix

echo ""
echo "[5/5] 等待 APISIX 启动..."
sleep 15

echo ""
echo "=== 健康检查 ==="
echo -n "  APISIX: "
curl -sf http://localhost:9080/apisix/status > /dev/null 2>&1 && echo "✅" || echo "❌"

echo ""
echo "=== APISIX 日志 ==="
docker logs app-apisix --tail 10

echo ""
echo "========================================"
echo " 修复完成!"
echo "========================================"
