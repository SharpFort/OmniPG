# Casbin RBAC 大规模系统最佳实践（100万+用户）

## 执行摘要

本文档对在100万+用户规模的 Casbin RBAC 部署中的两个关键架构决策进行全面分析：

1. **用户-角色映射存储策略** — 用户-角色映射应存储在 Casbin 的 `casbin_rule` 表中还是应用外部存储中
2. **JWT内置角色 vs 服务端角色查询** — 角色信息应嵌入到 JWT 令牌中还是在服务端解析

基于 Casbin 官方文档、源码分析、基准测试和社区讨论，本指南提供了实现示例、性能对比和运维建议。

---

## 1. Casbin 架构概览

### Casbin 如何将数据加载到内存

Casbin 的 Enforcer 加载**两种类型**的数据到内存中：

| 数据类型 | 策略类型 (ptype) | 存储位置 | 加载到 |
|----------|-----------------|---------|--------|
| 权限规则 | `p` | `casbin_rule` 表 | Model 的策略断言（内存 Map） |
| 角色继承关系 | `g` | `casbin_rule` 表 | RoleManager 的内存角色树 |

**关键洞察**：当用户-角色映射以 `g` 规则（ptype='g'）存储时，它们会被加载到 RoleManager 的内存数据结构中。对于100万用户、平均每用户3个角色，意味着内存中有 **300万条 g 规则**。

### 默认 RoleManager 实现

默认的 `RoleManagerImpl` 使用：
- `allRoles` — `sync.Map` 存储所有角色/用户关系
- 每个 `Role` 包含 `roles`、`users`、`matched`、`matchedBy` — 均为 `sync.Map` 实例
- `maxHierarchyLevel` — 限制角色层级深度（默认：10）
- `matchingFuncCache` — 匹配函数结果的 LRU 缓存

**内存影响**：每条用户-角色关系会在多个 sync.Map 结构中创建条目。100万用户 × 3角色 = 300万条关系，内存使用会变得非常可观（基于基准测试，10万用户/10千角色约7.6MB）。

---

## 2. 用户-角色映射存储策略

### 方案 A：在 casbin_rule 中存储用户-角色映射（默认）

```ini
# 模型定义 (rbac_model.conf)
[request_definition]
r = sub, obj, act

[policy_definition]
p = sub, obj, act

[role_definition]
g = _, _

[policy_effect]
e = some(where (p.eft == allow))

[matchers]
m = g(r.sub, p.sub) && r.obj == p.obj && r.act == p.act
```

```sql
-- casbin_rule 表

-- 权限规则（ptype='p'）
INSERT INTO casbin_rule VALUES ('p', 'admin', '/api/users', 'GET');
INSERT INTO casbin_rule VALUES ('p', 'admin', '/api/users', 'POST');
INSERT INTO casbin_rule VALUES ('p', 'editor', '/api/articles', 'GET');
INSERT INTO casbin_rule VALUES ('p', 'editor', '/api/articles', 'POST');

-- 用户-角色映射（ptype='g'）— ⚠️ 大规模下有严重性能问题
INSERT INTO casbin_rule VALUES ('g', 'alice', 'admin');
INSERT INTO casbin_rule VALUES ('g', 'bob', 'editor');
INSERT INTO casbin_rule VALUES ('g', 'charlie', 'admin');
-- ... 还有 100万+ 行
```

**权限校验调用**：
```go
// Casbin 通过 g 规则内部解析角色
result, err := enforcer.Enforce("alice", "/api/users", "GET")
```

**优点**：
- 配置简单，无需自定义代码
- 角色解析自动化
- 内置角色层级继承支持
- 策略更新原子性

**缺点**：
- **内存占用高**：所有用户-角色映射加载到 RoleManager 的内存 Map
- **启动慢**：100万+ g 规则拖慢 Enforcer 初始化
- **可扩展性**：每新增用户就增加 g 行，表随用户基数线性增长
- **运维复杂**：数据库膨胀、备份/恢复复杂度高
- **缓存失效**：g 规则变更时必须重建角色关系链接

---

### 方案 B：外部用户-角色存储 + 自定义 RoleManager

这是 Casbin 官方推荐的**100万+用户场景下的最佳方案**。

#### 自定义 RoleManager 实现

```go
package customrolemanager

import (
    "sync"
    "time"
    "github.com/casbin/casbin/v3/rbac"
)

// CachedRoleManager 实现 rbac.RoleManager 接口
// 使用外部DB + Redis缓存 + 本地LRU三级架构
type CachedRoleManager struct {
    db          UserRoleDB    // 应用自己的用户-角色数据库
    redis       RedisClient   // Redis 缓存
    cacheTTL    time.Duration // 缓存过期时间（如 5 分钟）

    // 本地内存缓存（热路径）
    localCache  *lru.Cache    // LRU 缓存，超快访问
    mu          sync.RWMutex

    maxHierarchyLevel int
}

// UserRoleDB 接口 — 用你应用的 ORM/SQL 实现
type UserRoleDB interface {
    GetUserRoles(userID string) ([]string, error)
    GetRoleUsers(roleID string) ([]string, error)
    GetRoleHierarchy(roleID string) ([]string, error) // 父角色（层级继承）
}

// 构造函数
func NewCachedRoleManager(db UserRoleDB, redis RedisClient, cacheTTL time.Duration) *CachedRoleManager {
    rm := &CachedRoleManager{
        db:                db,
        redis:             redis,
        cacheTTL:          cacheTTL,
        maxHierarchyLevel: 10,
    }
    rm.localCache = lru.New(10000) // 1万条热数据
    return rm
}

// GetRoles — Casbin 在权限校验时调用此方法
func (rm *CachedRoleManager) GetRoles(userID string, domain ...string) ([]string, error) {
    // 1. 检查本地 LRU 缓存（最快，~100ns）
    if roles, ok := rm.localCache.Get(userID); ok {
        return roles.([]string), nil
    }

    // 2. 检查 Redis 缓存（~1-2ms）
    cacheKey := fmt.Sprintf("casbin:roles:%s", userID)
    if roles, err := rm.redis.Get(cacheKey); err == nil {
        roleList := parseRoles(roles)
        rm.localCache.Add(userID, roleList)
        return roleList, nil
    }

    // 3. 查询数据库（~5-20ms）
    roles, err := rm.db.GetUserRoles(userID)
    if err != nil {
        return nil, err
    }

    // 回填缓存
    rm.redis.Set(cacheKey, serializeRoles(roles), rm.cacheTTL)
    rm.localCache.Add(userID, roles)

    return roles, nil
}

// HasLink — 检查用户是否拥有某角色（g() 函数使用）
func (rm *CachedRoleManager) HasLink(name1, name2 string, domain ...string) (bool, error) {
    roles, err := rm.GetRoles(name1, domain...)
    if err != nil {
        return false, err
    }
    for _, role := range roles {
        if role == name2 {
            return true, nil
        }
    }
    return false, nil
}

// GetImplicitRoles — 解析角色层级继承
func (rm *CachedRoleManager) GetImplicitRoles(userID string, domain ...string) ([]string, error) {
    // 先查缓存
    cacheKey := fmt.Sprintf("casbin:implicit_roles:%s", userID)
    if roles, err := rm.redis.Get(cacheKey); err == nil {
        return parseRoles(roles), nil
    }

    // 获取直接角色
    directRoles, err := rm.GetRoles(userID, domain...)
    if err != nil {
        return nil, err
    }

    // 解析层级（带最大深度保护）
    allRoles := make(map[string]bool)
    for _, role := range directRoles {
        allRoles[role] = true
        rm.resolveRoleHierarchy(role, allRoles, 0)
    }

    result := make([]string, 0, len(allRoles))
    for role := range allRoles {
        result = append(result, role)
    }

    // 缓存结果集
    rm.redis.Set(cacheKey, serializeRoles(result), rm.cacheTTL)
    return result, nil
}

// 递归解析角色层级
func (rm *CachedRoleManager) resolveRoleHierarchy(roleID string, visited map[string]bool, depth int) {
    if depth >= rm.maxHierarchyLevel {
        return
    }
    parentRoles, err := rm.db.GetRoleHierarchy(roleID)
    if err != nil {
        return
    }
    for _, parent := range parentRoles {
        if !visited[parent] {
            visited[parent] = true
            rm.resolveRoleHierarchy(parent, visited, depth+1)
        }
    }
}

// Clear — 清空所有缓存
func (rm *CachedRoleManager) Clear() error {
    rm.localCache.Purge()
    return rm.redis.DelByPattern("casbin:roles:*")
}

// 以下方法在外部存储模式下无需操作
func (rm *CachedRoleManager) AddLink(name1, name2 string, domain ...string) error { return nil }
func (rm *CachedRoleManager) DeleteLink(name1, name2 string, domain ...string) error { return nil }
func (rm *CachedRoleManager) PrintRoles() error { return nil }
func (rm *CachedRoleManager) Match(str, pattern string) bool { return str == pattern }
func (rm *CachedRoleManager) AddMatchingFunc(name string, fn rbac.MatchingFunc) {}
func (rm *CachedRoleManager) AddDomainMatchingFunc(name string, fn rbac.MatchingFunc) {}
func (rm *CachedRoleManager) DeleteDomain(domain string) error { return nil }
func (rm *CachedRoleManager) BuildRelationship(name1, name2 string, domain ...string) error { return nil }
func (rm *CachedRoleManager) GetDomains(name string) ([]string, error) { return nil, nil }
func (rm *CachedRoleManager) GetAllDomains() ([]string, error) { return nil, nil }
func (rm *CachedRoleManager) GetUsers(roleID string, domain ...string) ([]string, error) {
    return rm.db.GetRoleUsers(roleID)
}
func (rm *CachedRoleManager) GetImplicitUsers(roleID string, domain ...string) ([]string, error) {
    return rm.db.GetRoleUsers(roleID)
}
```

#### 注册自定义 RoleManager

```go
import (
    "github.com/casbin/casbin/v3"
    "github.com/casbin/casbin/v3/model"
)

func main() {
    // 加载模型（无需为存储用户-角色映射而创建 g 规则）
    m, err := model.NewModelFromFile("rbac_model_no_g.conf")
    if err != nil {
        panic(err)
    }

    // 创建 Enforcer（只加载权限规则）
    enforcer, err := casbin.NewEnforcer(m, adapter)
    if err != nil {
        panic(err)
    }

    // 注册自定义 RoleManager
    rm := customrolemanager.NewCachedRoleManager(db, redis, 5*time.Minute)
    enforcer.SetRoleManager(rm)

    // 构建角色链接（仅角色层级，不构建用户-角色关系）
    enforcer.BuildRoleLinks()
}
```

### 缓存策略对比

| 策略 | 延迟 | 命中率 | 复杂度 | 内存 | 一致性 |
|------|------|--------|--------|------|--------|
| **不缓存** | 5-20ms (DB) | N/A | 低 | 无 | 强一致 |
| **仅 Redis** | 1-2ms | 90-95% | 中 | ~100MB (100万用户) | 最终一致(TTL) |
| **仅 LRU** | ~100ns | 60-80% | 低 | ~50MB (1万热用户) | 存在脏读 |
| **两级 (LRU + Redis)** | ~100ns(L1)/1-2ms(L2) | 95-99% | 高 | ~150MB 总 | 最终一致 |
| **版本失效** | ~100ns | 99%+ | 非常高 | ~200MB 总 | 强一致 |

### 推荐缓存架构

```
请求 → L1 (内存 LRU) → L2 (Redis) → L3 (数据库)
       ~100ns命中          ~1-2ms命中     ~5-20ms命中

缓存失效策略：
- 用户角色变更 → 失效该用户的 L1 + L2
- 角色权限变更 → 失效所有持有该角色的用户
- 全局策略重载 → 版本号递增所有缓存 Key
```

---

## 3. JWT内置角色 vs 用户-角色存 casbin_rule

### 方案 A：JWT内置角色 (Role-in-JWT)

**架构图**：
```
┌─────────────┐     ┌─────────────┐     ┌─────────────┐
│   客户端     │────▶│   后端服务   │────▶│   Casbin    │
│             │     │             │     │  Enforcer   │
│  JWT Token  │     │ 从JWT的     │     │             │
│  {roles:    │     │ claims中提取 │     │ 只存储权限  │
│   ["admin", │     │ 角色信息     │     │ 规则(p)     │
│   "editor"]}│     │             │     │             │
└─────────────┘     └─────────────┘     └─────────────┘
```

**实现代码**：

```go
// ===== 1. JWT Claims 定义 =====
type Claims struct {
    UserID string   `json:"sub"`
    Roles  []string `json:"roles"`  // 角色列表放在这里
    jwt.RegisteredClaims
}

// ===== 2. 登录时签发 JWT =====
func Login(userID string) (string, error) {
    roles := getUserRolesFromDB(userID)  // 从你的 user_roles 表查

    claims := &Claims{
        UserID: userID,
        Roles:  roles,
        RegisteredClaims: jwt.RegisteredClaims{
            ExpiresAt: jwt.NewNumericDate(time.Now().Add(15 * time.Minute)),
        },
    }

    token := jwt.NewWithClaims(jwt.SigningMethodRS256, claims)
    return token.SignedString(privateKey)
}

// ===== 3. 中间件：从JWT提取角色 =====
func AuthMiddleware() gin.HandlerFunc {
    return func(c *gin.Context) {
        tokenString := c.GetHeader("Authorization")
        claims, err := validateAndExtract(tokenString)
        if err != nil {
            c.AbortWithStatus(401)
            return
        }
        c.Set("userRoles", claims.Roles)
        c.Set("userID", claims.UserID)
        c.Next()
    }
}

// ===== 4. 权限校验：遍历角色 =====
func EnforceHandler(enforcer *casbin.Enforcer) gin.HandlerFunc {
    return func(c *gin.Context) {
        userRoles := c.MustGet("userRoles").([]string)
        resource := c.FullPath()
        action := c.Request.Method

        allowed := false
        for _, role := range userRoles {
            // 注意：这里传的是 role 而不是 userID
            if result, _ := enforcer.Enforce(role, resource, action); result {
                allowed = true
                break
            }
        }

        if !allowed {
            c.AbortWithStatus(403)
            return
        }
        c.Next()
    }
}
```

**Casbin 策略（只有 p 规则）**：
```sql
-- casbin_rule 表：仅 2万行权限定义
INSERT INTO casbin_rule VALUES ('p', 'admin', '/api/users', 'GET');
INSERT INTO casbin_rule VALUES ('p', 'admin', '/api/users', 'POST');
INSERT INTO casbin_rule VALUES ('p', 'editor', '/api/articles', 'GET');
INSERT INTO casbin_rule VALUES ('p', 'editor', '/api/articles', 'POST');
-- ... 共 40×500 = 20,000 行
```

**优点**：
- **无状态**：无需服务端会话存储
- **可扩展**：Casbin 内存中不含用户-角色数据
- **配置简单**：Casbin 只加载权限规则
- **校验快速**：角色到权限的直接映射
- **跨服务**：任何服务都可以验证 JWT

**缺点**：
- **Token 体积膨胀**：JWT 随角色数量增长（5角色≈200字节，50角色≈2KB）
- **角色撤销延迟**：必须等待 JWT 过期（除非实现 Token 黑名单）
- **角色过期**：用户在令牌过期前保持原有角色
- **无法实时更新**：无法立即撤销权限
- **安全性**：JWT 包含授权数据（虽然签名但未加密）

---

### 方案 B：用户-角色存 casbin_rule

**架构图**：
```
┌─────────────┐     ┌─────────────┐     ┌─────────────┐
│   客户端     │────▶│   后端服务   │────▶│   Casbin    │
│             │     │             │     │  Enforcer   │
│  JWT Token  │     │ 从JWT中提取  │     │             │
│  {user_id:  │     │ user_id     │     │ 同时存储    │
│   "12345"}  │     │             │     │ 权限规则(p) │
└─────────────┘     └─────────────┘     │ 和用户-角色 │
                                        │ 映射(g)     │
                                        └─────────────┘
```

**实现代码**：

```go
// ===== 1. JWT Claims（极简，只有用户身份）=====
type Claims struct {
    UserID string `json:"sub"`
    jwt.RegisteredClaims
}

// ===== 2. 权限校验：传 userID =====
func EnforceHandler(enforcer *casbin.Enforcer) gin.HandlerFunc {
    return func(c *gin.Context) {
        userID := c.MustGet("userID").(string)
        resource := c.FullPath()
        action := c.Request.Method

        // Casbin 内部：先查 g-rule 找到用户角色，再查 p-rule 匹配权限
        result, err := enforcer.Enforce(userID, resource, action)
        if err != nil || !result {
            c.AbortWithStatus(403)
            return
        }
        c.Next()
    }
}
```

**Casbin 策略（同时存 p 和 g 规则）**：
```sql
-- p 规则：2万行（角色→权限）
INSERT INTO casbin_rule VALUES ('p', 'admin', '/api/users', 'GET');
INSERT INTO casbin_rule VALUES ('p', 'admin', '/api/users', 'POST');
INSERT INTO casbin_rule VALUES ('p', 'editor', '/api/articles', 'GET');

-- g 规则：100万行（用户→角色）— ⚠️ 可扩展性瓶颈
INSERT INTO casbin_rule VALUES ('g', 'alice', 'admin');
INSERT INTO casbin_rule VALUES ('g', 'bob', 'editor');
INSERT INTO casbin_rule VALUES ('g', 'charlie', 'admin');
-- ... 1,000,000 行
```

**优点**：
- **实时更新**：角色变更立即生效
- **Token 精简**：JWT 只放用户身份
- **统一管理**：所有授权数据存储在一个位置
- **撤销便捷**：删除 g-rule 即可撤销角色
- **审计跟踪**：所有角色分配记录在数据库

**缺点**：
- **内存密集型**：所有用户-角色映射加载到内存
- **可扩展性问题**：100万用户 × 3角色 = 300万 g-rule 在内存
- **启动慢**：启动时加载百万级 g-rule
- **数据库膨胀**：casbin_rule 表随用户基数增长
- **运维复杂**：大规模 g-rule 的管理复杂度高

---

## 4. 详细对比矩阵

| 维度 | JWT内置角色 (A) | User-Role存casbin_rule (B) | 自定义RoleManager (C) |
|------|:--:|:--:|:--:|
| **Enforce 延迟** | ~0.02ms（直接匹配） | ~0.02-240ms（取决于规则数量） | ~0.001-5ms（取决于缓存） |
| **内存占用** | 极小（仅p） | **非常高**（p + 所有用户的g） | 中低（仅p + 缓存） |
| **100万用户可扩展性** | ✅ 优秀 | ❌ 差 | ✅ 优秀 |
| **角色撤销** | ⚠️ 延迟到JWT过期 | ✅ 立即 | ⚠️ 近实时(TTL) |
| **Token 体积** | 随角色增长(~50B/role) | 极小(~50B) | 极小(~50B) |
| **运维复杂度** | 低 | 中 | 高 |
| **实时更新** | ❌ 不支持 | ✅ 支持 | ✅ 支持(缓存失效) |
| **跨服务认证** | ✅ 优秀（无状态） | ⚠ 需Casbin实例 | ⚠ 需共享缓存/DB |
| **离线吊销** | ❌ 困难（需黑名单） | ✅ 容易(删g-rule) | ✅ 容易(清缓存) |
| **启动速度** | 快 | 慢(加载百万g-rules) | 快 |
| **数据库压力** | 无（角色在Token里） | 高（g-rules表增长） | 中（缓存 + DB） |

---

## 5. 性能基准测试

基于 Casbin 官方基准测试（Go, i7-6700HQ）：

| 场景 | 规则数 | 时间/op | 内存 |
|------|--------|---------|------|
| RBAC（小规模） | 1,100 条（1K用户, 100角色） | 0.164ms | 80.6 KB |
| RBAC（中等） | 11,000 条（10K用户, 1K角色） | 2.258ms | 765 KB |
| RBAC（大规模） | 110,000 条（100K用户, 10K角色） | 23.9ms | 7.6 MB |
| **RBAC（100万用户, 外推）** | **~1100万条** | **~240ms+** | **~760 MB+** |

**100万用户外推结果**：
- 使用 g-rules：~240ms 每次校验，~760MB 内存
- 使用 JWT内置角色：~0.02ms 每次校验，~8MB 内存（仅p-rules）
- 使用自定义RoleManager：~0.001-5ms 每次校验，~50MB 内存

---

## 6. 安全考量

### 方案A（JWT内置角色）安全

1. **Token 体积**：角色多的 JWT 可能超过 Cookie 大小限制（4KB）或 Header 限制（8KB）
2. **信息泄露**：JWT payload 是 base64 编码不是加密 — 角色信息可见
3. **撤销问题**：必须实现 Token 黑名单或短有效期 + Refresh Token
4. **篡改防护**：使用强签名算法（RS256/ES256），每个请求都要验证签名

### 方案B（User-Role存casbin_rule）安全

1. **数据暴露**：所有用户角色映射集中在一张表
2. **注入风险**：g-rule 管理必须使用参数化查询
3. **访问控制**：casbin_rule 表必须防止未授权访问

### 方案C（自定义RoleManager）安全

1. **缓存污染**：Redis 必须开启认证 + TLS 加密
2. **脏数据**：角色变更时必须正确实现缓存失效
3. **时序攻击**：角色比对应使用恒定时间比较

---

## 7. 推荐架构：100万+用户的混合方案

### 最佳实践：自定义RoleManager + 短效JWT

```
┌─────────────┐     ┌─────────────┐     ┌─────────────┐     ┌─────────────┐
│   客户端     │────▶│   后端服务   │────▶│   Casbin    │────▶│    Redis    │
│             │     │             │     │  Enforcer   │     │   缓存层    │
│  JWT Token  │     │ 1. 验证JWT  │     │             │     │             │
│  {user_id,  │     │ 2. 从中提取  │     │ 仅加载      │     │ 用户角色    │
│   exp: 5min}│     │    user_id  │     │ 权限规则(p) │     │ 存在这里    │
└─────────────┘     │ 3. 通过      │     └─────────────┘     └──────┬──────┘
                    │    Casbin    │                               │
                    │    执行校验   │     ┌─────────────┐         │
                    └─────────────┘     │  数据库     │◀────────┘
                                        │ (user_roles)│
                                        └─────────────┘
```

**核心设计决策：**

1. **JWT 只包含用户身份**（不放角色） — 保持 Token 精简
2. **短效 JWT**（5-15分钟）+ Refresh Token（7-30天）保持会话连续性
3. **自定义 RoleManager** 带两级缓存（LRU + Redis）
4. **Casbin 只存权限规则**（ptype='p'） — 没有用户-角色的 g-rule
5. **角色层级**在应用数据库中管理中，不在 Casbin

**缓存失效策略**：

```go
// 当用户角色变更时（管理员操作）
func (s *AuthService) UpdateUserRoles(userID string, roles []string) error {
    // 1. 更新数据库
    if err := s.db.UpdateUserRoles(userID, roles); err != nil {
        return err
    }

    // 2. 删除 Redis 缓存
    cacheKey := fmt.Sprintf("casbin:roles:%s", userID)
    s.redis.Del(cacheKey)

    // 3. 通知所有实例清除本地 LRU（通过发布/订阅）
    s.redis.Publish("cache:invalidate", userID)

    // 4. 可选：通过递增 Token 版本强制 JWT 刷新
    s.db.IncrementTokenVersion(userID)

    return nil
}

// 订阅缓存失效消息
func (s *AuthService) StartCacheInvalidationListener() {
    pubsub := s.redis.Subscribe("cache:invalidate")
    for msg := range pubsub.Channel() {
        userID := msg.Payload
        s.localCache.Remove(userID)
    }
}
```

---

## 8. 实现检查清单

### Jwt内置角色方案

- [ ] 设计 JWT Claims 结构（包含 roles 数组）
- [ ] 设置合理的 Token 过期时间（Access: 5-15min，Refresh: 7-30天）
- [ ] 实现 Token 刷新端点
- [ ] 如需立即撤销，添加 Token 黑名单
- [ ] Casbin 只用 p-rules 配置（无 g-rules 用于用户-角色）
- [ ] 实现角色提取中间件
- [ ] 添加速率限制防止 Token 滥用
- [ ] 监控 JWT 体积（> 4KB 告警）

### 自定义RoleManager方案

- [ ] 实现 `rbac.RoleManager` 接口
- [ ] 搭建 Redis 集群用于分布式缓存
- [ ] 实现两级缓存（LRU + Redis）
- [ ] 设计缓存失效策略（推荐发布/订阅）
- [ ] 为热用户实现缓存预热
- [ ] 实现 DB 熔断机制
- [ ] 添加缓存指标监控（命中率/未命中率）
- [ ] 建立缓存脏数据监控
- [ ] 用自定义 RoleManager 配置 Casbin
- [ ] 用生产级数据量做负载测试

### 用户-Role存casbin_rule方案

- [ ] **仅适用于 < 10万用户**
- [ ] 对 ptype、v0、v1 列做索引
- [ ] 如需要，设置策略分片
- [ ] 随用户基数增长监控内存使用
- [ ] 规划扩展到自定义 RoleManager 的迁移路径

---

## 9. 迁移路径：从 casbin_rule 到自定义RoleManager

如果你已经在使用 g-rule 做用户-角色映射且需要扩展，可以按以下步骤迁移：

```go
// 步骤1：导出现有 g-rule
gRules, _ := enforcer.GetFilteredPolicy(1, "") // 获取所有 g 规则 (v0, v1)

// 步骤2：迁移到应用数据库
for _, rule := range gRules {
    userID := rule[0]  // v0
    roleID := rule[1]  // v1
    db.AssignRole(userID, roleID)
}

// 步骤3：从 Casbin 中删除 g-rule
enforcer.RemoveFilteredPolicy(1, "") // 删除所有 g 规则

// 步骤4：注册自定义 RoleManager
enforcer.SetRoleManager(customRM)

// 步骤5：重建角色链接（仅角色层级，非用户-角色）
enforcer.BuildRoleLinks()
```

---

## 10. 结论

### 100万+用户最佳方案：自定义RoleManager + 短效JWT

**为何这是最佳方案**：

1. **内存高效**：Casbin 只加载权限规则（~10-100KB），不加载用户-角色映射
2. **可扩展**：新增用户不会增加 Casbin 内存占用
3. **性能优异**：缓存命中 ~100ns（LRU）or ~1-2ms（Redis），vs 240ms+（100万g-rules 方案）
4. **灵活性强**：可实现复杂的缓存、失效和监控策略
5. **运维便捷**：数据库精简，备份更快，迁移更容易

### 何时使用 JWT内置角色

- 每个用户角色数量较少（< 10）
- 微服务架构中服务无法访问中心认证数据库
- 有严格的架构无状态要求
- 无需实时撤销角色

### 何时使用 用户-角色存casbin_rule

- 用户基数较少（< 10万）
- 追求架构简单
- 运维简单性优先于可扩展性
- 需要内置角色层级而不想写自定义代码

---

## 参考资源

- [Casbin 官方文档](https://casbin.apache.org/docs/)
- [Casbin 角色管理器](https://casbin.apache.org/docs/role-managers)
- [Casbin 性能优化](https://casbin.apache.org/docs/performance)
- [Casbin 基准测试](https://casbin.apache.org/docs/benchmark)
- [Casbin GitHub 仓库](https://github.com/casbin/casbin)
- [Session Role Manager（参考实现）](https://github.com/casbin/session-role-manager)
- [Casbin Issue #681 — 大规模讨论](https://github.com/casbin/casbin/issues/681)

---

## 审查报告（2026-07-21）

> **审查背景：** 项目已确认采用 **Role-in-JWT + casbin_rule 仅存 p 规则** 方案。审查旨在发现与决策不符的根本性错误。

### 审查结果

| # | 位置 | 严重度 | 问题 | 建议修复 |
|---|------|--------|------|----------|
| **1** | **§3 方案A — Casbin 模型定义** | 🔴 根本错误 | 定义了 `[role_definition] g = _, _` 和 `[matchers] m = g(r.sub, p.sub) && ...`。但你的方案中 `sub` 直接传 role（从 JWT 提取），**不需要 `g()` 函数**。`g()` 是 Casbin 内部解析用户→角色用的，你没有 g-rules，`g()` 就是死代码。 | 模型简化为：`[matchers] m = r.sub == p.sub && r.obj == p.obj && r.act == p.act`（完全不需要 role_definition） |
| **2** | **§2 自定义RoleManager — Go 代码** | 🔴 根本错误 | import 路径写 `github.com/casbin/casbin/v3/rbac` 和 `github.com/casbin/casbin/v3`，但 **Casbin 官方稳定版是 v2**（`github.com/casbin/casbin/v2`），v3 尚未发布稳定版。 | 改为 `github.com/casbin/casbin/v2/rbac` 和 `github.com/casbin/casbin/v2` |
| **3** | **§7 推荐架构** | 🟡 与决策不符 | 推荐"自定义RoleManager + 短效JWT"（方案C），但你的最终方案是 **"JWT内置角色 + casbin_rule 仅存 p 规则 + APISIX authz-casbin 做匹配"**。推荐与决策相反。 | 重写推荐章节，对齐你的决策：最佳方案是"Role-in-JWT + casbin_rule 仅存 p 规则" |
| **4** | **§5 性能基准** | 🟡 严重误导 | 外推"100万用户 ~240ms、~760MB"是基于 1100 万条规则（p+g 混合），但你的 casbin_rule **只有 p 规则**（几万条），不存在此问题。数字严重误导。 | 应说明：你的方案 Enforce 延迟取决于 p 规则数量（几万条 ≈ 几ms），并引用官方"Policy Sharding"思路佐证 |

### 额外发现

| 项目 | 说明 |
|------|------|
| **APISIX 端口冲突** | 文档未提及：Pigsty INFRA 的 Grafana（:3000）与 PostgREST（:3000）在 Windows 侧端口冲突，需修改其中一个端口 |
| **JWT 认证职责** | `authz-casbin` 本身不做 JWT 验证，只匹配权限。需明确哪个组件负责 JWT 签发/验证（Casdoor 或 `jwt-auth` 插件），并说明 roles 如何从 JWT 传递到 `authz-casbin` |

### 验证来源

- Apache APISIX `authz-casbin` 官方文档：https://apisix.apache.org/zh/docs/apisix/plugins/authz-casbin/
- Casbin 官方 RBAC 文档：https://casbin.org/docs/rbac
- Casbin 官方性能优化：https://casbin.org/docs/performance
- 关键确认：Casbin 官方明确 `[role_definition]` 是可选的，支持只存 p 规则不存 g 规则的 RBAC 方案