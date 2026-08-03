# 04.7 §10 扩展验证 — 可执行脚本集

配套文档：`docs/开发实施方案/04.7-§10-扩展验证清单.md`（判定标准与结果记录区）。

## 文件

| 脚本 | 作用 | 对应验证项 |
|:---|:---|:---|
| `01_receiver.py` | webhook 接收器：请求原样落盘 `out/`，返回 200 | 全部（payload 采集） |
| `02_role_events.sh` | 管理员会话驱动 add/update(挂摘用户)/改名/delete/失败请求 | V1–V7 |
| `03_inspect_payloads.sh` | 汇总解析 `out/` payload：action/operator/requestUri/response/users 完整性 | V1–V7 判定 |
| `04_jwt_claims.sh` | password grant 取 token → 解码检查 roles 结构/顺序/isEnabled/凭据泄漏 | V8–V10、V13 |

## 运行顺序

```bash
# 0) 起接收器（另开终端；WSL2 内 python3，端口默认 8099）
python3 01_receiver.py 8099

#    在 Casdoor 后台新建 webhook：URL=http://<Casdoor 容器可达的地址>:8099/
#    事件=add-role/update-role/delete-role；SingleOrgOnly=false；
#    Headers 可加 X-Webhook-Secret 测试自定义头

# 1) 环境变量
export CASDOOR_URL=http://localhost:8000
export ORG=omnipg
export ADMIN_USER=admin
export ADMIN_PASS='***'
export TEST_USER=omnipg/alice
export CLIENT_ID='***' CLIENT_SECRET='***'   # 04 用（测试应用）
export USERNAME=omnipg/alice PASSWORD='***'   # 04 用（被测用户）

# 2) 触发角色事件 → 3) 解析 payload → 4) JWT 检查
bash 02_role_events.sh
bash 03_inspect_payloads.sh
bash 04_jwt_claims.sh
```

## 注意事项

1. **update-role 500 是待观测对象**（技能库有 v3 实测记录）：02 脚本不 `set -e`，
   每步输出 HTTP 状态码；若 500 复现 → 04.7-修订版 §8 的"硬性否决点"触发，
   按决策门槛处理（Casdoor UI 直管分配 / 回方案 B）。
2. **接收器可达性**：webhook 由 Casdoor 容器发出，URL 必须是容器可访问的地址
   （docker 网络内网 IP / host.docker.internal / 主机端口映射），不是 localhost。
3. **失败请求也会触发事件**（V5）：03 解析时若看到 `response` 含 `status:"error"`
   的事件，属预期行为——验证 RPC 成败守卫的必要性。
4. **手工验证项**（脚本覆盖不到）：
   - V4：Casdoor UI 手工保存一次角色（确认 UI 路径 update-role 正常）；
   - V11：webhook 开 `SingleOrgOnly=true` 重跑 02/03 对照；再用 built-in admin 操作对照；
   - V12：停接收器 → 触发事件（观察 Retrying/Failed）→ 起接收器 → UI Replay → 确认旧事件后到；
   - V10：先在默认 tokenFormat 下跑 04（记录泄漏字段），再配 `JWT-Custom`+tokenFields 复跑。
5. **清理**：验证后删除测试角色与测试 webhook；`out/` 目录可整目录删除。
6. Windows git-bash 下运行：将脚本内 `python3` 替换为 `python`（或直接在 WSL2 跑）。
