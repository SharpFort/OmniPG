# Casbin RBAC Best Practices for Large-Scale Systems (1M+ Users)

## Executive Summary

This document provides a comprehensive analysis of two critical architectural decisions when deploying Casbin RBAC at scale (1M+ users):

1. **User-Role Mapping Storage Strategy** — Whether to store user-role mappings in Casbin's `casbin_rule` table or externally in application storage
2. **Role-in-JWT vs Server-Side Role Lookup** — Whether to embed roles in JWT tokens or resolve them server-side

Based on official Casbin documentation, source code analysis, benchmarks, and community discussions, this guide provides implementation examples, performance comparisons, and operational recommendations.

---

## 1. Casbin Architecture Overview

### How Casbin Loads Data Into Memory

Casbin's enforcer loads **two types of data** into memory:

| Data Type | Policy Type (ptype) | Storage | Loaded Into |
|-----------|---------------------|---------|-------------|
| Permission rules | `p` | `casbin_rule` | Model's policy assertion (in-memory map) |
| Role inheritance links | `g` | `casbin_rule` | RoleManager's in-memory role tree |

**Critical insight**: When user-role mappings are stored as `g` rules (ptype='g'), they are loaded into the RoleManager's in-memory data structure. For 1M users with an average of 3 roles each, this means **3 million g-rules** in memory.

### Default RoleManager Implementation

The default `RoleManagerImpl` uses:
- `allRoles` — `sync.Map` storing all role/user relationships
- Each `Role` contains `roles`, `users`, `matched`, `matchedBy` — all `sync.Map` instances
- `maxHierarchyLevel` — limits role hierarchy depth (default: 10)
- `matchingFuncCache` — LRU cache for matching function results

**Memory implication**: Each user-role link creates entries in multiple sync.Map structures. For 1M users × 3 roles = 3M links, memory usage becomes significant (~7MB+ just for g-rules based on benchmarks showing 7,606 KB for 100K users/10K roles).

---

## 2. User-Role Mapping Storage Strategy

### Option A: Store User-Role Mappings in casbin_rule (Default)

```ini
# Model definition (rbac_model.conf)
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
-- casbin_rule table
-- Permission rules (ptype='p')
INSERT INTO casbin_rule VALUES ('p', 'admin', '/api/users', 'GET');
INSERT INTO casbin_rule VALUES ('p', 'admin', '/api/users', 'POST');
INSERT INTO casbin_rule VALUES ('p', 'editor', '/api/articles', 'GET');
INSERT INTO casbin_rule VALUES ('p', 'editor', '/api/articles', 'POST');

-- User-role mappings (ptype='g') — PROBLEMATIC AT SCALE
INSERT INTO casbin_rule VALUES ('g', 'alice', 'admin');
INSERT INTO casbin_rule VALUES ('g', 'bob', 'editor');
INSERT INTO casbin_rule VALUES ('g', 'charlie', 'admin');
-- ... 1M+ more rows for large user bases
```

**Enforcement call**:
```go
// Casbin resolves roles internally via g-rules
result, err := enforcer.Enforce("alice", "/api/users", "GET")
```

**Pros:**
- Simple setup, no custom code
- Role resolution is automatic
- Built-in role hierarchy support
- Atomic policy updates

**Cons:**
- **Memory**: All user-role mappings loaded into RoleManager's in-memory maps
- **Load time**: 1M+ g-rules slow down enforcer initialization
- **Scalability**: Each new user adds g-rule rows; table grows linearly with user count
- **Operational**: Database bloat, backup/restore complexity
- **Cache invalidation**: Must rebuild role links when g-rules change

### Option B: External User-Role Storage with Custom RoleManager

This is the **recommended approach for 1M+ users** per Casbin's official documentation.

#### Custom RoleManager Implementation

```go
package customrolemanager

import (
    "sync"
    "time"
    "github.com/casbin/casbin/v3/rbac"
)

// CachedRoleManager implements rbac.RoleManager with external DB + Redis caching
type CachedRoleManager struct {
    db          UserRoleDB      // Your application's user-role database
    redis       RedisClient     // Redis cache for role lookups
    cacheTTL    time.Duration   // Cache expiration (e.g., 5 minutes)
    
    // In-memory cache for hot paths
    localCache  *lru.Cache      // LRU cache for ultra-fast lookups
    mu          sync.RWMutex
    
    maxHierarchyLevel int
}

// UserRoleDB interface — implement with your ORM/raw SQL
type UserRoleDB interface {
    GetUserRoles(userID string) ([]string, error)
    GetRoleUsers(roleID string) ([]string, error)
    GetRoleHierarchy(roleID string) ([]string, error) // parent roles
}

func NewCachedRoleManager(db UserRoleDB, redis RedisClient, cacheTTL time.Duration) *CachedRoleManager {
    rm := &CachedRoleManager{
        db:                db,
        redis:             redis,
        cacheTTL:          cacheTTL,
        maxHierarchyLevel: 10,
    }
    rm.localCache = lru.New(10000) // 10K hot entries
    return rm
}

// GetRoles — called by Casbin during enforcement
func (rm *CachedRoleManager) GetRoles(userID string, domain ...string) ([]string, error) {
    // 1. Check local LRU cache (fastest, ~100ns)
    if roles, ok := rm.localCache.Get(userID); ok {
        return roles.([]string), nil
    }
    
    // 2. Check Redis cache (~1-2ms)
    cacheKey := fmt.Sprintf("casbin:roles:%s", userID)
    if roles, err := rm.redis.Get(cacheKey); err == nil {
        roleList := parseRoles(roles)
        rm.localCache.Add(userID, roleList)
        return roleList, nil
    }
    
    // 3. Query database (~5-20ms)
    roles, err := rm.db.GetUserRoles(userID)
    if err != nil {
        return nil, err
    }
    
    // Populate caches
    rm.redis.Set(cacheKey, serializeRoles(roles), rm.cacheTTL)
    rm.localCache.Add(userID, roles)
    
    return roles, nil
}

// HasLink — checks if user has a specific role (used by g() function)
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

// GetImplicitRoles — resolves role hierarchy
func (rm *CachedRoleManager) GetImplicitRoles(userID string, domain ...string) ([]string, error) {
    // Check cache first
    cacheKey := fmt.Sprintf("casbin:implicit_roles:%s", userID)
    if roles, err := rm.redis.Get(cacheKey); err == nil {
        return parseRoles(roles), nil
    }
    
    // Get direct roles
    directRoles, err := rm.GetRoles(userID, domain...)
    if err != nil {
        return nil, err
    }
    
    // Resolve hierarchy (with max depth protection)
    allRoles := make(map[string]bool)
    for _, role := range directRoles {
        allRoles[role] = true
        rm.resolveRoleHierarchy(role, allRoles, 0)
    }
    
    result := make([]string, 0, len(allRoles))
    for role := range allRoles {
        result = append(result, role)
    }
    
    // Cache the resolved set
    rm.redis.Set(cacheKey, serializeRoles(result), rm.cacheTTL)
    
    return result, nil
}

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

// Clear — invalidate all caches
func (rm *CachedRoleManager) Clear() error {
    rm.localCache.Purge()
    // Invalidate Redis caches (pattern delete or version-based invalidation)
    return rm.redis.DelByPattern("casbin:roles:*")
}

// AddLink — not needed for external storage (roles managed in app DB)
func (rm *CachedRoleManager) AddLink(name1, name2 string, domain ...string) error {
    return nil // No-op: user-role mappings managed externally
}

// DeleteLink — not needed for external storage
func (rm *CachedRoleManager) DeleteLink(name1, name2 string, domain ...string) error {
    return nil // No-op
}

// GetUsers — returns users for a role (requires DB query)
func (rm *CachedRoleManager) GetUsers(roleID string, domain ...string) ([]string, error) {
    return rm.db.GetRoleUsers(roleID)
}

// GetImplicitUsers — returns all users inheriting a role
func (rm *CachedRoleManager) GetImplicitUsers(roleID string, domain ...string) ([]string, error) {
    // Implementation depends on hierarchy direction
    return rm.db.GetRoleUsers(roleID)
}

// GetDomains — not implemented for this use case
func (rm *CachedRoleManager) GetDomains(name string) ([]string, error) {
    return nil, nil
}

func (rm *CachedRoleManager) GetAllDomains() ([]string, error) {
    return nil, nil
}

func (rm *CachedRoleManager) PrintRoles() error { return nil }
func (rm *CachedRoleManager) Match(str, pattern string) bool { return str == pattern }
func (rm *CachedRoleManager) AddMatchingFunc(name string, fn rbac.MatchingFunc) {}
func (rm *CachedRoleManager) AddDomainMatchingFunc(name string, fn rbac.MatchingFunc) {}
func (rm *CachedRoleManager) DeleteDomain(domain string) error { return nil }
func (rm *CachedRoleManager) BuildRelationship(name1, name2 string, domain ...string) error { return nil }
```

#### Registering Custom RoleManager

```go
import (
    "github.com/casbin/casbin/v3"
    "github.com/casbin/casbin/v3/model"
)

func main() {
    // Load model (without g rules for user-role mappings)
    m, err := model.NewModelFromFile("rbac_model_no_g.conf")
    if err != nil {
        panic(err)
    }
    
    // Create enforcer with only permission rules
    enforcer, err := casbin.NewEnforcer(m, adapter)
    if err != nil {
        panic(err)
    }
    
    // Register custom RoleManager
    rm := customrolemanager.NewCachedRoleManager(db, redis, 5*time.Minute)
    enforcer.SetRoleManager(rm)
    
    // Build role links (only role hierarchy, not user-role mappings)
    enforcer.BuildRoleLinks()
}
```

#### Modified Model (No g Rules for User-Role)

```ini
# rbac_model_no_g.conf
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

**Key difference**: The `g` function still exists for role hierarchy, but user-role mappings are resolved by the custom RoleManager instead of g-rules.

### Caching Strategies Comparison

| Strategy | Latency | Hit Rate | Complexity | Memory | Consistency |
|----------|---------|----------|------------|--------|-------------|
| **No Cache** | 5-20ms (DB) | N/A | Low | None | Strong |
| **Redis Only** | 1-2ms | 90-95% | Medium | ~100MB for 1M users | Eventual (TTL-based) |
| **LRU Only** | ~100ns | 60-80% | Low | ~50MB for 10K hot users | Stale reads |
| **Two-Level (LRU + Redis)** | ~100ns (L1) / 1-2ms (L2) | 95-99% | High | ~150MB total | Eventual |
| **Version-Based Invalidation** | ~100ns | 99%+ | Very High | ~200MB total | Strong |

### Recommended Caching Architecture

```
Request → L1 (In-Memory LRU) → L2 (Redis) → L3 (Database)
          ~100ns hit           ~1-2ms hit    ~5-20ms hit
          
Cache Invalidation:
- User role change → Invalidate L1 + L2 for that user
- Role permission change → Invalidate all users with that role (pattern delete)
- Global policy reload → Version-bump all cache keys
```

---

## 3. Role-in-JWT vs User-Role in casbin_rule

### Approach A: Role-in-JWT

**Architecture:**
```
┌─────────────┐     ┌─────────────┐     ┌─────────────┐
│   Client    │────▶│   Backend   │────▶│   Casbin    │
│             │     │             │     │  Enforcer   │
│  JWT Token  │     │ Extract     │     │             │
│  {roles:    │     │ roles from  │     │ Only stores │
│   ["admin", │     │ JWT claims  │     │ permission  │
│   "editor"]}│     │             │     │ rules (p)   │
└─────────────┘     └─────────────┘     └─────────────┘
```

**Implementation:**

```go
// JWT Claims
type Claims struct {
    UserID string   `json:"sub"`
    Roles  []string `json:"roles"`
    jwt.RegisteredClaims
}

// Middleware to extract roles from JWT
func AuthMiddleware(enforcer *casbin.Enforcer) gin.HandlerFunc {
    return func(c *gin.Context) {
        tokenString := c.GetHeader("Authorization")
        claims, err := validateAndExtractClaims(tokenString)
        if err != nil {
            c.AbortWithStatus(401)
            return
        }
        
        // Store roles in context for enforcement
        c.Set("userRoles", claims.Roles)
        c.Set("userID", claims.UserID)
        c.Next()
    }
}

// Enforcement handler
func EnforceHandler(enforcer *casbin.Enforcer) gin.HandlerFunc {
    return func(c *gin.Context) {
        userRoles := c.MustGet("userRoles").([]string)
        resource := c.Param("resource")
        action := c.Request.Method
        
        // Check each role for permission
        allowed := false
        for _, role := range userRoles {
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

**Casbin Policy (only permission rules):**
```sql
-- casbin_rule: ONLY p rules, NO g rules
INSERT INTO casbin_rule VALUES ('p', 'admin', '/api/users', 'GET');
INSERT INTO casbin_rule VALUES ('p', 'admin', '/api/users', 'POST');
INSERT INTO casbin_rule VALUES ('p', 'editor', '/api/articles', 'GET');
INSERT INTO casbin_rule VALUES ('p', 'editor', '/api/articles', 'POST');
```

**Pros:**
- **Stateless**: No server-side session storage needed
- **Scalable**: No user-role data in Casbin memory
- **Simple Casbin config**: Only permission rules loaded
- **Fast enforcement**: Direct role-to-permission lookup
- **Cross-service**: JWT can be verified by any service

**Cons:**
- **Token size**: JWT grows with number of roles (5 roles ≈ 200 bytes, 50 roles ≈ 2KB)
- **Role revocation delay**: Must wait for JWT expiry (or implement token blacklist)
- **Stale roles**: User keeps roles until token expires
- **No real-time updates**: Can't revoke permissions immediately
- **Security**: JWT contains authorization data (though signed, not encrypted)

### Approach B: User-Role in casbin_rule

**Architecture:**
```
┌─────────────┐     ┌─────────────┐     ┌─────────────┐
│   Client    │────▶│   Backend   │────▶│   Casbin    │
│             │     │             │     │  Enforcer   │
│  JWT Token  │     │ Extract     │     │             │
│  {user_id:  │     │ user_id     │     │ Stores BOTH │
│   "12345"}  │     │ from JWT    │     │ permission  │
└─────────────┘     └─────────────┘     │ rules (p)   │
                                        │ AND user-    │
                                        │ role maps (g)│
                                        └─────────────┘
```

**Implementation:**

```go
// JWT Claims (minimal — only user identity)
type Claims struct {
    UserID string `json:"sub"`
    jwt.RegisteredClaims
}

// Enforcement handler
func EnforceHandler(enforcer *casbin.Enforcer) gin.HandlerFunc {
    return func(c *gin.Context) {
        userID := c.MustGet("userID").(string)
        resource := c.Param("resource")
        action := c.Request.Method
        
        // Casbin resolves roles internally via g-rules
        result, err := enforcer.Enforce(userID, resource, action)
        if err != nil || !result {
            c.AbortWithStatus(403)
            return
        }
        c.Next()
    }
}
```

**Casbin Policy (both p and g rules):**
```sql
-- casbin_rule: Permission rules (p)
INSERT INTO casbin_rule VALUES ('p', 'admin', '/api/users', 'GET');
INSERT INTO casbin_rule VALUES ('p', 'admin', '/api/users', 'POST');
INSERT INTO casbin_rule VALUES ('p', 'editor', '/api/articles', 'GET');

-- casbin_rule: User-role mappings (g) — SCALABILITY BOTTLENECK
INSERT INTO casbin_rule VALUES ('g', 'alice', 'admin');
INSERT INTO casbin_rule VALUES ('g', 'bob', 'editor');
INSERT INTO casbin_rule VALUES ('g', 'charlie', 'admin');
-- ... 1M+ more rows
```

**Pros:**
- **Real-time updates**: Role changes take effect immediately
- **Small JWT**: Only user identity in token
- **Centralized management**: All auth data in one place
- **Easy revocation**: Remove g-rule to revoke role
- **Audit trail**: All role assignments in database

**Cons:**
- **Memory intensive**: All user-role mappings loaded into memory
- **Scalability issues**: 1M users × 3 roles = 3M g-rules in memory
- **Slower startup**: Loading millions of g-rules at boot
- **Database bloat**: casbin_rule table grows with user base
- **Operational complexity**: Managing g-rules at scale

---

## 4. Detailed Comparison Matrix

| Criteria | Role-in-JWT (A) | User-Role in casbin_rule (B) | Custom RoleManager (C) |
|----------|------------------|------------------------------|------------------------|
| **Enforcement Latency** | ~0.02ms (direct) | ~0.02-24ms (depends on rule count) | ~0.001-5ms (cache-dependent) |
| **Memory Usage** | Minimal (only p-rules) | Very High (p + g rules for all users) | Low-Medium (only p-rules + cache) |
| **Scalability (1M users)** | Excellent | Poor | Excellent |
| **Role Revocation** | Delayed (JWT expiry) | Immediate | Near-immediate (cache TTL) |
| **Token Size** | Grows with roles (~50 bytes/role) | Minimal (~50 bytes) | Minimal (~50 bytes) |
| **Operational Complexity** | Low | Medium | High |
| **Real-time Updates** | No | Yes | Yes (with cache invalidation) |
| **Cross-service Auth** | Excellent (stateless) | Requires Casbin instance | Requires shared cache/DB |
| **Offline Revocation** | Difficult (need blacklist) | Easy (delete g-rule) | Easy (invalidate cache) |
| **Startup Time** | Fast | Slow (load all g-rules) | Fast |
| **Database Load** | None (roles in token) | High (g-rules table grows) | Medium (cache + DB) |

---

## 5. Performance Benchmarks

Based on official Casbin benchmarks (Go, i7-6700HQ):

| Scenario | Rule Size | Time/op | Memory |
|----------|-----------|---------|--------|
| RBAC (small) | 1,100 rules (1K users, 100 roles) | 0.164ms | 80.6 KB |
| RBAC (medium) | 11,000 rules (10K users, 1K roles) | 2.258ms | 765 KB |
| RBAC (large) | 110,000 rules (100K users, 10K roles) | 23.9ms | 7.6 MB |
| **RBAC (1M users, estimated)** | **~11M rules** | **~240ms+** | **~760 MB+** |

**Extrapolation for 1M users:**
- With g-rules: ~240ms per enforcement, ~760MB memory
- With Role-in-JWT: ~0.02ms per enforcement, ~8MB memory (only p-rules)
- With Custom RoleManager: ~0.001-5ms per enforcement, ~50MB memory

---

## 6. Security Considerations

### Role-in-JWT Security

1. **Token Size**: JWTs with many roles can exceed cookie size limits (4KB) or header limits (8KB)
2. **Information Disclosure**: JWT payload is base64-encoded, not encrypted — roles are visible
3. **Revocation**: Must implement token blacklist or short expiry + refresh tokens
4. **Tampering**: Use strong signing (RS256/ES256) and validate on every request

### User-Role in casbin_rule Security

1. **Data Exposure**: All user-role mappings in single table
2. **Injection Risk**: Parameterized queries essential for g-rule management
3. **Access Control**: casbin_rule table must be protected from unauthorized access

### Custom RoleManager Security

1. **Cache Poisoning**: Secure Redis with authentication and TLS
2. **Stale Data**: Implement proper cache invalidation on role changes
3. **Timing Attacks**: Use constant-time comparison for role checks

---

## 7. Recommended Architecture for 1M+ Users

### Hybrid Approach: Custom RoleManager + Short-Lived JWT

```
┌─────────────┐     ┌─────────────┐     ┌─────────────┐     ┌─────────────┐
│   Client    │────▶│   Backend   │────▶│   Casbin    │────▶│   Redis     │
│             │     │             │     │  Enforcer   │     │   Cache     │
│  JWT Token  │     │ 1. Validate │     │             │     │             │
│  {user_id,  │     │    JWT      │     │ Only loads  │     │ User roles  │
│   exp: 5min}│     │ 2. Extract  │     │ permission  │     │ cached here │
└─────────────┘     │    user_id  │     │ rules (p)   │     └──────┬──────┘
                    │ 3. Enforce  │     └─────────────┘            │
                    │    via      │                                 │
                    │    Casbin   │     ┌─────────────┐            │
                    └─────────────┘     │  Database   │◀───────────┘
                                        │ (user_roles)│
                                        └─────────────┘
```

**Key Design Decisions:**

1. **JWT contains only user identity** (not roles) — keeps token small
2. **Short-lived JWT** (5-15 minutes) with refresh token for session continuity
3. **Custom RoleManager** with two-level caching (LRU + Redis)
4. **Casbin only stores permission rules** (ptype='p') — no g-rules for user-role
5. **Role hierarchy** managed in application database, not Casbin

**Cache Invalidation Strategy:**

```go
// When user roles change (admin action)
func (s *AuthService) UpdateUserRoles(userID string, roles []string) error {
    // 1. Update database
    if err := s.db.UpdateUserRoles(userID, roles); err != nil {
        return err
    }
    
    // 2. Invalidate Redis cache
    cacheKey := fmt.Sprintf("casbin:roles:%s", userID)
    s.redis.Del(cacheKey)
    
    // 3. Invalidate local LRU cache on all instances (via pub/sub)
    s.redis.Publish("cache:invalidate", userID)
    
    // 4. Optionally: force JWT refresh by incrementing token version
    s.db.IncrementTokenVersion(userID)
    
    return nil
}

// Subscribe to invalidation messages
func (s *AuthService) StartCacheInvalidationListener() {
    pubsub := s.redis.Subscribe("cache:invalidate")
    for msg := range pubsub.Channel() {
        userID := msg.Payload
        s.localCache.Remove(userID)
    }
}
```

---

## 8. Implementation Checklist

### For Role-in-JWT Approach

- [ ] Design JWT claims structure (include roles array)
- [ ] Set appropriate token expiry (5-15 min for access, 7-30 days for refresh)
- [ ] Implement token refresh endpoint
- [ ] Add token blacklist for immediate revocation (if needed)
- [ ] Configure Casbin with only p-rules (no g-rules for user-role)
- [ ] Implement role extraction middleware
- [ ] Add rate limiting to prevent token abuse
- [ ] Monitor JWT size (alert if > 4KB)

### For Custom RoleManager Approach

- [ ] Implement `rbac.RoleManager` interface
- [ ] Set up Redis cluster for distributed caching
- [ ] Implement two-level cache (LRU + Redis)
- [ ] Design cache invalidation strategy (pub/sub recommended)
- [ ] Add cache warming for hot users
- [ ] Implement circuit breaker for DB fallback
- [ ] Add metrics for cache hit/miss rates
- [ ] Set up monitoring for cache staleness
- [ ] Configure Casbin with custom RoleManager
- [ ] Load-test with production-like data volume

### For User-Role in casbin_rule (NOT recommended for 1M+ users)

- [ ] Only suitable for < 100K users
- [ ] Implement database indexing on ptype, v0, v1 columns
- [ ] Set up policy sharding if needed
- [ ] Monitor memory usage as user base grows
- [ ] Plan migration path to Custom RoleManager when scaling

---

## 9. Migration Path: From casbin_rule to Custom RoleManager

If you're currently using g-rules for user-role mappings and need to scale:

```go
// Step 1: Export existing g-rules
gRules, _ := enforcer.GetFilteredPolicy(1, "") // Get all g rules (v0, v1)

// Step 2: Migrate to application database
for _, rule := range gRules {
    userID := rule[0]  // v0
    roleID := rule[1]  // v1
    db.AssignRole(userID, roleID)
}

// Step 3: Remove g-rules from Casbin
enforcer.RemoveFilteredPolicy(1, "") // Remove all g rules

// Step 4: Register custom RoleManager
enforcer.SetRoleManager(customRM)

// Step 5: Rebuild role links (only role hierarchy, not user-role)
enforcer.BuildRoleLinks()
```

---

## 10. Conclusion

### For 1M+ Users: Use Custom RoleManager + Short-Lived JWT

**Why this is the best approach:**

1. **Memory efficiency**: Casbin only loads permission rules (~10-100KB), not user-role mappings
2. **Scalability**: Adding users doesn't increase Casbin memory usage
3. **Performance**: Cache hits are ~100ns (LRU) or ~1-2ms (Redis) vs ~240ms for 1M g-rules
4. **Flexibility**: Can implement complex caching, invalidation, and monitoring
5. **Operational**: Database stays lean, backups are faster, migrations are easier

### When to Use Role-in-JWT

- Small number of roles per user (< 10)
- Microservices architecture where services can't access central auth DB
- Stateless architecture requirements
- When immediate role revocation isn't critical

### When to Use User-Role in casbin_rule

- Small user base (< 100K users)
- Simple architecture requirements
- When operational simplicity outweighs scalability
- When you need built-in role hierarchy without custom code

---

## References

- [Casbin Official Documentation](https://casbin.apache.org/docs/)
- [Casbin Role Managers](https://casbin.apache.org/docs/role-managers)
- [Casbin Performance Optimization](https://casbin.apache.org/docs/performance)
- [Casbin Benchmarks](https://casbin.apache.org/docs/benchmark)
- [Casbin GitHub Repository](https://github.com/casbin/casbin)
- [Session Role Manager (Reference Implementation)](https://github.com/casbin/session-role-manager)
- [Casbin Issue #681 — Large Scale Discussion](https://github.com/casbin/casbin/issues/681)
