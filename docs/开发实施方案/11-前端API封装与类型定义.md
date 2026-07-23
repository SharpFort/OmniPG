# 11 — 前端 API 封装与类型定义

> **定位：** 提供完整的 TypeScript 类型定义、API 函数封装、请求拦截器和错误处理方案。Agent 按本文档可直接在 ART-D Pro 中实现类型安全的 API 调用层。
> **前置依赖：** 05-前端Admin（ART-D Pro 基础）、03-API与认证层（接口契约）
> **产出物：** TypeScript 接口文件 + API 函数文件 + 拦截器配置
> **预计耗时：** 1-2 小时

---

## 1. 目录结构

```
frontend/admin-ui/src/
├── api/                        # API 封装层
│   ├── request.ts              # Axios 实例 + 拦截器
│   ├── auth.ts                 # 认证相关 API
│   ├── system.ts               # 系统管理 API
│   └── index.ts                # 统一导出
│
├── types/                      # TypeScript 类型定义
│   ├── auth.ts                 # 认证相关类型
│   ├── system.ts               # 系统管理类型
│   ├── menu.ts                 # 菜单/路由类型
│   └── index.ts                # 统一导出
│
├── store/                      # Pinia 状态管理
│   ├── user.ts                 # 用户状态
│   └── permission.ts           # 权限状态
│
└── utils/
    └── menu-builder.ts         # 菜单树构建工具
```

---

## 2. TypeScript 类型定义

### 2.1 认证类型

**文件：** `src/types/auth.ts`

```typescript
// ==============================================================================
// 认证相关类型定义
// ==============================================================================

/** 登录请求参数 */
export interface LoginRequest {
  p_username: string
  p_password: string
}

/** 登录响应数据 */
export interface LoginResponse {
  access_token: string
  username: string
}

/** Token 刷新请求 */
export interface RefreshTokenRequest {
  p_old_rt?: string  // 可选，前端不传（通过 Cookie 自动携带）
}

/** Token 刷新响应 */
export interface RefreshTokenResponse {
  access_token: string
  username: string
}

/** JWT Payload 结构 */
export interface JwtPayload {
  jti: string
  user_id: string
  username: string
  tenant_id: string
  dept_id?: string
  roles: string[]
  exp: number
  iat?: number
}

/** 用户信息 */
export interface UserInfo {
  id: string
  username: string
  email?: string
  phone?: string
  tenant_id: string
  dept_id?: string
  is_active: boolean
  created_at: string
  updated_at: string
}
```

### 2.2 系统管理类型

**文件：** `src/types/system.ts`

```typescript
// ==============================================================================
// 系统管理类型定义（用户/角色/菜单/API）
// ==============================================================================

/** 用户 */
export interface SysUser {
  id: string
  username: string
  password?: string  // [修复 P1-1] 明文密码（服务端触发器自动哈希）
  email?: string
  phone?: string
  tenant_id: string
  dept_id?: string
  is_active: boolean
  created_at: string
  updated_at: string
}

/** 角色 */
export interface SysRole {
  id: string
  role_code: string
  role_name: string
  description?: string
  is_active: boolean
  created_at: string
  updated_at: string
}

/** API 资源 */
export interface SysApi {
  id: string
  path: string
  method: string
  api_name?: string
  description?: string
  is_active: boolean
  created_at: string
  updated_at: string
}

/** 用户-角色关联 */
export interface SysUserRole {
  user_id: string
  role_id: string
  created_at: string
}

/** 角色-API 关联 */
export interface SysRoleApi {
  role_id: string
  api_id: string
  created_at: string
}

/** 角色-菜单关联 */
export interface SysRoleMenu {
  role_id: string
  menu_id: string
  created_at: string
}

/** 部门 */
export interface SysDepartment {
  id: string
  dept_name: string
  parent_id?: string
  created_at: string
  updated_at: string
}

/** 会话 */
export interface SysUserSession {
  id: string
  user_id: string
  refresh_token_hash: string
  active_jti?: string
  is_used: boolean
  client_ip?: string
  user_agent?: string
  created_at: string
  expired_at: string
}

/** Token 黑名单 */
export interface SysTokenBlacklist {
  jti: string
  blacklisted_at: string
  expired_at: string
  reason?: string
}

/** 角色申请 */
export interface SysUserRoleRequest {
  id: string
  user_id: string
  role_id: string
 'approved' | 'rejected'
  applicant_id: string
  approver_id?: string
  created_at: string
  approved_at?: string
  updated_at: string
}

/** 踢用户请求 */
export interface KickUserRequest {
  p_user_id: string
}

/** 审批角色申请请求 */
export interface ApproveRoleRequest {
  p_request_id: string
}
```

### 2.3 菜单类型

**文件：** `src/types/menu.ts`

```typescript
// ==============================================================================
// 菜单/路由类型定义
// ==============================================================================

/** 菜单类型 */
 'MENU' | 'BUTTON'

/** 菜单项（PostgREST 返回格式） */
export interface MenuItem {
  id: string
  parent_id?: string
  name: string
  path?: string
  component?: string
  title: string
  icon?: string
  type: MenuType
  permission_code?: string
  sort_order: number
  is_active: boolean
  meta?: {
    title: string
    icon?: string
  }
  buttons?: string[]  // 按钮权限标识数组
  children?: MenuItem[]
  created_at?: string  // [修复 P2-4] 与 sys_menu 表对齐
  updated_at?: string  // [修复 P2-4]
}

/** 路由配置 */
export interface RouteConfig {
  path: string
  name: string
 (() => Promise<unknown>)
  meta: {
    title: string
    icon?: string
    hidden?: boolean
  }
  children?: RouteConfig[]
  redirect?: string
}

/** 按钮权限 */
export interface ButtonPermission {
  permission_code: string
  name: string
  title: string
}
```

### 2.4 统一导出

**文件：** `src/types/index.ts`

```typescript
// 类型统一导出
export * from './auth'
export * from './system'
export * from './menu'

/** 通用 API 响应包装 */
export interface ApiResponse<T = unknown> {
  data: T
  status: number
  statusText: string
}

/** PostgREST 错误响应 */
export interface PostgrestError {
  message: string
  code: string
  details?: string
  hint?: string
}

/** 分页参数 */
export interface PaginationParams {
  offset?: number
  limit?: number
  order?: string
}

/** 过滤条件 */
 'neq' | 'gt' | 'gte' | 'lt' | 'lte' | 'like' | 'ilike' | 'in' | 'is' | 'not'

export interface FilterCondition {
  field: string
  operator: FilterOperator
 number | boolean | null | Array<string | number>
}
```

---

## 3. Axios 请求封装

### 3.1 请求实例 + 拦截器

**文件：** `src/api/request.ts`

```typescript
// ==============================================================================
// Axios 请求封装（ART-D Pro 适配版）
// ==============================================================================

import axios, { AxiosInstance, AxiosRequestConfig, AxiosResponse, InternalAxiosRequestConfig } from 'axios'
import { useUserStore } from '@/store/user'
import router from '@/router'
import { message } from 'ant-design-vue'  // 或 Element Plus 的 ElMessage

// API 基础路径（Vite proxy 转发到 APISIX）
| '/api/v1'
const TIMEOUT = 15000

// 创建 Axios 实例
const service: AxiosInstance = axios.create({
  baseURL: BASE_URL,
  timeout: TIMEOUT,
  withCredentials: true,  // 允许跨域携带 Cookie（RT 刷新必需）
  // [修复 P1-2] CSRF 防护：每个非 GET 请求携带自定义 Header
  headers: {
    'Content-Type': 'application/json',
    'Accept': 'application/json',
    'X-Requested-With': 'XMLHttpRequest'  // 自定义 Header 防止 CSRF
  }
  headers: {
    'Content-Type': 'application/json',
    'Accept': 'application/json'
  }
})

// 刷新状态管理
let isRefreshing = false
let pendingRequests: Array<(token: string) => void> = []
let refreshAttempts = 0
const MAX_REFRESH_ATTEMPTS = 3

// ==============================================================================
// 请求拦截器
// ==============================================================================
service.interceptors.request.use(
  (config: InternalAxiosRequestConfig) => {
    const userStore = useUserStore()
    
    // 自动携带 Access Token
    if (userStore.token) {
      config.headers.Authorization = `Bearer ${userStore.token}`
    }
    
    // PostgREST 特有头
    if (config.method === 'get') {
      // GET 请求默认返回 JSON 数组
      config.headers.Accept = 'application/json'
    }
| '')) {
      // 写操作要求返回表示
      config.headers.Prefer = 'return=representation'
    }
    
    return config
  },
  (error) => {
    console.error('请求错误:', error)
    return Promise.reject(error)
  }
)

// ==============================================================================
// 响应拦截器
// ==============================================================================
service.interceptors.response.use(
  (response: AxiosResponse) => {
    // 直接返回 data（PostgREST 响应就是数据本身）
    return response.data
  },
  async (error) => {
    const { config, response } = error
    const userStore = useUserStore()
    
    // 401 未授权 → 尝试刷新 Token
    if (response?.status === 401 && !config._retry) {
      // 如果已经在刷新中，将请求排队
      if (isRefreshing) {
        return new Promise((resolve) => {
          pendingRequests.push((token: string) => {
            config.headers.Authorization = `Bearer ${token}`
            resolve(service(config))
          })
        })
      }
      
      // 检查是否为刷新接口本身（避免死循环）
| 
          config.url?.includes('/rpc/user_login_sso')) {
        userStore.resetAll()
        router.push('/login')
        return Promise.reject(error)
      }
      
      config._retry = true
      isRefreshing = true
      refreshAttempts++
      
      // 超过最大重试次数，不再重试
      if (refreshAttempts > MAX_REFRESH_ATTEMPTS) {
        isRefreshing = false
        refreshAttempts = 0
        pendingRequests = []
        userStore.resetAll()
        router.push('/login')
        return Promise.reject(error)
      }
      
      try {
        // 调用刷新接口（不传参数，浏览器自动携带 httpOnly Cookie）
        const { data } = await axios.post(`${BASE_URL}/rpc/refresh_token_rtr`, {}, {
          withCredentials: true
        })
        
        const newToken = data.access_token
        userStore.setToken(newToken)
        refreshAttempts = 0
        
        // 重放排队的请求
        pendingRequests.forEach((cb) => cb(newToken))
        pendingRequests = []
        
        // 重试原请求
        config.headers.Authorization = `Bearer ${newToken}`
        return service(config)
      } catch (refreshError) {
        // 刷新失败 → 跳转登录
        userStore.resetAll()
        router.push('/login')
        return Promise.reject(refreshError)
      } finally {
        isRefreshing = false
      }
    }
    
    // 403 无权限
    if (response?.status === 403) {
      message.error('没有权限执行此操作')
    }
    
    // 其他错误
| error.message || '请求失败'
    console.error(`API 错误 [${response?.status}]:`, errorMessage)
    
    return Promise.reject(error)
  }
)

export default service
```

---

## 4. API 函数封装

### 4.1 认证 API

**文件：** `src/api/auth.ts`

```typescript
// ==============================================================================
// 认证相关 API
// ==============================================================================

import request from './request'
import type { LoginRequest, LoginResponse, RefreshTokenResponse, JwtPayload } from '@/types/auth'

/** 用户登录 */
export function loginApi(data: LoginRequest): Promise<LoginResponse> {
  return request.post('/rpc/user_login_sso', data)
}

/** 刷新 Token（httpOnly Cookie 自动携带） */
export function refreshTokenApi(): Promise<RefreshTokenResponse> {
  return request.post('/rpc/refresh_token_rtr', {})
}

/** 退出登录 [修复 P1-3] 调用后端接口使 RT 失效 */
export function logoutApi(): Promise<void> {
  return request.post('/rpc/user_logout', {})
}

/** 解析 JWT Payload（前端只读，不验证签名） */
 null {
  try {
    const base64Url = token.split('.')[1]
    const base64 = base64Url.replace(/-/g, '+').replace(/_/g, '/')
    const jsonPayload = decodeURIComponent(
      atob(base64)
        .split('')
        .map((c) => '%' + ('00' + c.charCodeAt(0).toString(16)).slice(-2))
        .join('')
    )
    return JSON.parse(jsonPayload)
  } catch {
    return null
  }
}

/** 检查 Token 是否即将过期（5 分钟内） */
export function isTokenExpiringSoon(token: string, thresholdMinutes = 5): boolean {
  const payload = parseJwtPayload(token)
  if (!payload) return true
  
  const expiresAt = payload.exp * 1000  // 转为毫秒
  const now = Date.now()
  return expiresAt - now < thresholdMinutes * 60 * 1000
}
```

### 4.2 系统管理 API

**文件：** `src/api/system.ts`

```typescript
// ==============================================================================
// 系统管理 API（用户/角色/菜单/API）
// ==============================================================================

import request from './request'
import type {
  SysUser, SysRole, SysApi, SysDepartment,
  SysUserRole, SysRoleApi, SysRoleMenu,
  SysUserSession, SysTokenBlacklist,
  SysUserRoleRequest, KickUserRequest, ApproveRoleRequest
} from '@/types/system'
import type { MenuItem } from '@/types/menu'

// ==============================================================================
// 用户管理
// ==============================================================================

/** 获取用户列表 */
export function getUsers(params?: {
  select?: string
  tenant_id?: string
  dept_id?: string
  is_active?: boolean
  order?: string
  offset?: number
  limit?: number
}): Promise<SysUser[]> {
  const query = new URLSearchParams()
  if (params?.select) query.set('select', params.select)
  if (params?.tenant_id) query.set('tenant_id', `eq.${params.tenant_id}`)
  if (params?.dept_id) query.set('dept_id', `eq.${params.dept_id}`)
  if (params?.is_active !== undefined) query.set('is_active', `eq.${params.is_active}`)
  if (params?.order) query.set('order', params.order)
  if (params?.offset !== undefined) query.set('offset', String(params.offset))
  if (params?.limit) query.set('limit', String(params.limit))
  
  return request.get(`/sys_user?${query.toString()}`)
}

/** 获取单个用户 */
export function getUserById(id: string): Promise<SysUser> {
  return request.get(`/sys_user?id=eq.${id}`)
}

/** 创建用户 */
export function createUser(data: Partial<SysUser>): Promise<SysUser[]> {
  return request.post('/sys_user', data)
}

/** 更新用户 */
export function updateUser(id: string, data: Partial<SysUser>): Promise<SysUser[]> {
  return request.patch(`/sys_user?id=eq.${id}`, data)
}

/** 删除用户（soft delete） */
export function deleteUser(id: string): Promise<void> {
  return request.patch(`/sys_user?id=eq.${id}`, { is_active: false })
}

/** 硬删除用户 */
export function hardDeleteUser(id: string): Promise<void> {
  return request.delete(`/sys_user?id=eq.${id}`)
}

// ==============================================================================
// 角色管理
// ==============================================================================

/** 获取角色列表 */
export function getRoles(params?: {
  select?: string
  order?: string
}): Promise<SysRole[]> {
  const query = new URLSearchParams()
  if (params?.select) query.set('select', params.select)
  if (params?.order) query.set('order', params.order)
  
  return request.get(`/sys_role?${query.toString()}`)
}

/** 创建角色 */
export function createRole(data: Partial<SysRole>): Promise<SysRole[]> {
  return request.post('/sys_role', data)
}

/** 更新角色 */
export function updateRole(id: string, data: Partial<SysRole>): Promise<SysRole[]> {
  return request.patch(`/sys_role?id=eq.${id}`, data)
}

/** 删除角色 */
export function deleteRole(id: string): Promise<void> {
  return request.delete(`/sys_role?id=eq.${id}`)
}

// ==============================================================================
// 菜单管理
// ==============================================================================

/** 获取菜单列表 */
export function getMenus(params?: {
  select?: string
  type?: string
  order?: string
}): Promise<MenuItem[]> {
  const query = new URLSearchParams()
  if (params?.select) query.set('select', params.select)
  if (params?.type) query.set('type', `eq.${params.type}`)
| 'sort_order.asc')
  
  return request.get(`/sys_menu?${query.toString()}`)
}

/** 获取当前用户菜单树（含按钮权限） */
export function getUserMenu(): Promise<MenuItem[]> {
  return request.get('/rpc/get_user_menu')
}

/** 创建菜单 */
export function createMenu(data: Partial<MenuItem>): Promise<MenuItem[]> {
  return request.post('/sys_menu', data)
}

/** 更新菜单 */
export function updateMenu(id: string, data: Partial<MenuItem>): Promise<MenuItem[]> {
  return request.patch(`/sys_menu?id=eq.${id}`, data)
}

/** 删除菜单 */
export function deleteMenu(id: string): Promise<void> {
  return request.delete(`/sys_menu?id=eq.${id}`)
}

// ==============================================================================
// API 资源管理
// ==============================================================================

/** 获取 API 列表 */
export function getApis(params?: {
  select?: string
  order?: string
}): Promise<SysApi[]> {
  const query = new URLSearchParams()
  if (params?.select) query.set('select', params.select)
  if (params?.order) query.set('order', params.order)
  
  return request.get(`/sys_api?${query.toString()}`)
}

/** 创建 API */
export function createApi(data: Partial<SysApi>): Promise<SysApi[]> {
  return request.post('/sys_api', data)
}

/** 更新 API */
export function updateApi(id: string, data: Partial<SysApi>): Promise<SysApi[]> {
  return request.patch(`/sys_api?id=eq.${id}`, data)
}

/** 删除 API */
export function deleteApi(id: string): Promise<void> {
  return request.delete(`/sys_api?id=eq.${id}`)
}

// ==============================================================================
// 关联表操作
// ==============================================================================

/** 给用户分配角色 */
export function assignRolesToUser(userId: string, roleIds: string[]): Promise<SysUserRole[]> {
  const data = roleIds.map(roleId => ({
    user_id: userId,
    role_id: roleId
  }))
  return request.post('/sys_user_role', data)
}

/** 删除用户角色 */
export function removeRoleFromUser(userId: string, roleId: string): Promise<void> {
  return request.delete(`/sys_user_role?user_id=eq.${userId}&role_id=eq.${roleId}`)
}

/** 给角色分配菜单权限 */
export function assignMenusToRole(roleId: string, menuIds: string[]): Promise<SysRoleMenu[]> {
  const data = menuIds.map(menuId => ({
    role_id: roleId,
    menu_id: menuId
  }))
  return request.post('/sys_role_menu', data)
}

/** 给角色分配 API 权限 */
export function assignApisToRole(roleId: string, apiIds: string[]): Promise<SysRoleApi[]> {
  const data = apiIds.map(apiId => ({
    role_id: roleId,
    api_id: apiId
  }))
  return request.post('/sys_role_api', data)
}

// ==============================================================================
// 会话管理
// ==============================================================================

/** 获取用户会话列表 */
export function getUserSessions(userId?: string): Promise<SysUserSession[]> {
  const query = userId ? `?user_id=eq.${userId}` : ''
  return request.get(`/sys_user_session${query}`)
}

/** 踢用户下线 */
export function kickUser(data: KickUserRequest): Promise<boolean> {
  return request.post('/rpc/kick_user', data)
}

// ==============================================================================
// 角色申请审批
// ==============================================================================

/** 获取角色申请列表 */
export function getRoleRequests(status?: string): Promise<SysUserRoleRequest[]> {
  const query = status ? `?status=eq.${status}` : ''
  return request.get(`/sys_user_role_request${query}`)
}

/** 审批角色申请 */
export function approveRoleRequest(data: ApproveRoleRequest): Promise<boolean> {
  return request.post('/rpc/approve_role_request', data)
}

// ==============================================================================
// 部门管理
// ==============================================================================

/** 获取部门列表 */
export function getDepartments(): Promise<SysDepartment[]> {
  return request.get('/sys_department?order=sort_order.asc')
}

/** 创建部门 */
export function createDepartment(data: Partial<SysDepartment>): Promise<SysDepartment[]> {
  return request.post('/sys_department', data)
}

/** 更新部门 */
export function updateDepartment(id: string, data: Partial<SysDepartment>): Promise<SysDepartment[]> {
  return request.patch(`/sys_department?id=eq.${id}`, data)
}

/** 删除部门 */
export function deleteDepartment(id: string): Promise<void> {
  return request.delete(`/sys_department?id=eq.${id}`)
}
```

### 4.3 统一导出

**文件：** `src/api/index.ts`

```typescript
// API 统一导出
export * from './auth'
export * from './system'
export { default as request } from './request'
```

---

## 5. 菜单树构建工具

**文件：** `src/utils/menu-builder.ts`

```typescript
// ==============================================================================
// 菜单树构建工具（扁平数组 → 嵌套树）
// ==============================================================================

import type { MenuItem, RouteConfig } from '@/types/menu'

/**
 * 将 PostgREST 返回的扁平菜单数组转换为嵌套树
 * @param flatMenu 扁平菜单数组
 */
export function buildMenuTree(flatMenu: MenuItem[]): MenuItem[] {
  const menuMap = new Map<string, MenuItem>()
  const roots: MenuItem[] = []

  // 第一遍：建立 id → menu 映射
  flatMenu.forEach(item => {
    menuMap.set(item.id, { ...item, children: [] })
  })

  // 第二遍：构建父子关系
  flatMenu.forEach(item => {
    const menuItem = menuMap.get(item.id)!
    
    if (item.parent_id && menuMap.has(item.parent_id)) {
      const parent = menuMap.get(item.parent_id)!
| []
      parent.children.push(menuItem)
    } else {
      roots.push(menuItem)
    }
  })

  // 清理空 children 数组
  const cleanChildren = (items: MenuItem[]): MenuItem[] => {
    return items.map(item => {
      if (item.children && item.children.length === 0) {
        delete item.children
      } else if (item.children) {
        item.children = cleanChildren(item.children)
      }
      return item
    })
  }

  return cleanChildren(roots)
}

/**
 * 从菜单树中提取所有按钮权限标识
 * @param menuTree 嵌套菜单树
 */
export function extractButtonPermissions(menuTree: MenuItem[]): string[] {
  const permissions: string[] = []
  
  const traverse = (items: MenuItem[]) => {
    items.forEach(item => {
      if (item.type === 'BUTTON' && item.permission_code) {
        permissions.push(item.permission_code)
      }
      if (item.buttons && item.buttons.length > 0) {
        permissions.push(...item.buttons)
      }
      if (item.children) {
        traverse(item.children)
      }
    })
  }
  
  traverse(menuTree)
  return [...new Set(permissions)]  // 去重
}

/**
 * 将菜单树转换为 Vue Router 路由配置
 * @param menuTree 嵌套菜单树
 */
export function buildRoutes(menuTree: MenuItem[]): RouteConfig[] {
  const routes: RouteConfig[] = []
  
  const traverse = (items: MenuItem[]) => {
    items.forEach(item => {
| item.type === 'MENU') {
        const route: RouteConfig = {
| item.name}`,
          name: item.name,
          component: item.component 
            ? () => import(`@/views/${item.component}/index.vue`)
            : () => import('@/views/error/404.vue'),
          meta: {
| item.title,
| item.icon
          }
        }
        
        if (item.children && item.children.length > 0) {
          route.children = traverse(item.children)
        }
        
        routes.push(route)
      }
    })
  }
  
  traverse(menuTree)
  return routes
}

/**
 * 构建 ART-D Pro 侧边栏菜单数据
 * @param menuTree 嵌套菜单树
 */
export function buildSidebarMenus(menuTree: MenuItem[]) {
  return menuTree.map(item => ({
    id: item.id,
    name: item.name,
    path: item.path,
    meta: {
| item.title,
| item.icon
    },
    children: item.children ? buildSidebarMenus(item.children) : undefined
  }))
}
```

---

## 6. Pinia Store 适配

**文件：** `src/store/user.ts`（ART-D Pro 适配版）

```typescript
// ==============================================================================
// Pinia 用户状态管理（ART-D Pro 适配版）
// ==============================================================================

import { defineStore } from 'pinia'
import { ref, computed } from 'vue'
import { loginApi, refreshTokenApi, getUserMenu, parseJwtPayload } from '@/api'
import { buildMenuTree, extractButtonPermissions, buildRoutes } from '@/utils/menu-builder'
import type { MenuItem } from '@/types/menu'
import type { LoginRequest } from '@/types/auth'
import router from '@/router'

export const useUserStore = defineStore('user', () => {
  // ========== State ==========
| '')
  const username = ref<string>('')
  const roles = ref<string[]>([])
  const menuTree = ref<MenuItem[]>([])
  const buttonPermissions = ref<string[]>([])
  const dynamicRoutes = ref<any[]>([])

  // ========== Getters ==========
  const isLoggedIn = computed(() => !!token.value)
  const hasTokenExpiringSoon = computed(() => {
    if (!token.value) return false
    const payload = parseJwtPayload(token.value)
    if (!payload) return true
    return payload.exp * 1000 - Date.now() < 5 * 60 * 1000
  })

  // ========== Actions ==========
  
  /** 登录 */
  async function login(loginData: LoginRequest) {
    const data = await loginApi(loginData)
    token.value = data.access_token
    username.value = data.username
    sessionStorage.setItem('access_token', data.access_token)
    
    // 解析 JWT 获取角色
    const payload = parseJwtPayload(data.access_token)
    if (payload) {
| []
    }
    
    return data
  }

  /** 加载用户菜单 */
  async function loadUserMenu() {
    const flatMenu = await getUserMenu()
    menuTree.value = buildMenuTree(flatMenu)
    buttonPermissions.value = extractButtonPermissions(menuTree.value)
    dynamicRoutes.value = buildRoutes(menuTree.value)
    
    // 动态添加路由
    dynamicRoutes.value.forEach(route => {
      router.addRoute(route)
    })
    
    return menuTree.value
  }

  /** 刷新 Token */
  async function refreshToken() {
    try {
      const data = await refreshTokenApi()
      token.value = data.access_token
      sessionStorage.setItem('access_token', data.access_token)
      return data.access_token
    } catch (error) {
      resetAll()
      throw error
    }
  }

  /** 设置 Token */
  function setToken(newToken: string) {
    token.value = newToken
    sessionStorage.setItem('access_token', newToken)
    refreshAttempts = 0  // [修复 P2-5] 新 Token 重置重试计数
    
    // 更新角色
    const payload = parseJwtPayload(newToken)
    if (payload) {
| []
    }
  }

  /** 重置所有状态 */
  function resetAll() {
    token.value = ''
    username.value = ''
    roles.value = []
    menuTree.value = []
    buttonPermissions.value = []
    dynamicRoutes.value = []
    sessionStorage.removeItem('access_token')
  }

  /** 退出登录 [修复 P1-3] 调用后端接口 + 清除 Cookie */
  async function logout() {
    try {
      await logoutApi()
    } catch {
      // 忽略错误，继续清除前端状态
    }
    resetAll()
    router.push('/login')
  }

  /** 检查按钮权限 */
 string[]): boolean {
    if (roles.value.includes('super_admin')) return true
    
    if (Array.isArray(permission)) {
      return permission.some(p => buttonPermissions.value.includes(p))
    }
    return buttonPermissions.value.includes(permission)
  }

  return {
    // State
    token,
    username,
    roles,
    menuTree,
    buttonPermissions,
    dynamicRoutes,
    // Getters
    isLoggedIn,
    hasTokenExpiringSoon,
    // Actions
    login,
    loadUserMenu,
    refreshToken,
    setToken,
    resetAll,
    logout,
    hasPermission
  }
})
```

---

## 7. 环境变量配置

**文件：** `frontend/admin-ui/.env.development`

```ini
# 开发环境配置
VITE_APP_BASE_API=/api/v1

# [修复 P2-1] Vite 代理配置（vite.config.ts）
# server: { proxy: { '/api/v1': { target: 'http://localhost:9080', changeOrigin: true } } }
VITE_APP_TITLE=零后端统一管理后台
VITE_APP_PORT=5173

# Casdoor 配置
VITE_CASDOOR_ENDPOINT=http://localhost:8000
VITE_CASDOOR_CLIENT_ID=zero-backend-app
VITE_CASDOOR_REDIRECT_URI=http://localhost:5173/callback

# [修复 P2-2] JWT 有效期由后端控制（Casdoor 配置），前端从 JWT exp claim 读取
# VITE_JWT_EXPIRES_MINUTES=15  # 已移除
```

**文件：** `frontend/admin-ui/.env.production`

```ini
# 生产环境配置
VITE_APP_BASE_API=/api/v1
VITE_APP_TITLE=零后端统一管理后台

# Casdoor 配置
VITE_CASDOOR_ENDPOINT=https://casdoor.internal
VITE_CASDOOR_CLIENT_ID=zero-backend-app
VITE_CASDOOR_REDIRECT_URI=https://admin.example.com/callback
```

---

## 8. 使用示例

### 8.1 在 Vue 组件中使用

```vue
<template>
  <div>
    <h1>用户管理</h1>
    <button v-permission="['user:add']" @click="handleAdd">新增用户</button>
    <button v-permission="['user:edit']" @click="handleEdit">编辑</button>
    <button v-permission="['user:delete']" @click="handleDelete">删除</button>
  </div>
</template>

<script setup lang="ts">
import { getUsers, createUser, updateUser, deleteUser } from '@/api'
import { useUserStore } from '@/store/user'

const userStore = useUserStore()

// 查询用户
const fetchUsers = async () => {
  const users = await getUsers({ 
    tenant_id: 'tenant_default',
    order: 'created_at.desc'
  })
  console.log('用户列表:', users)
}

// 创建用户
const handleAdd = async () => {
  await createUser({
    username: 'newuser',
    password_hash: 'hashed_password',
    tenant_id: 'tenant_default'
  })
}

// 检查权限
const canDelete = userStore.hasPermission('user:delete')
</script>
```

### 8.2 在路由守卫中使用

```typescript
// src/router/index.ts
import { useUserStore } from '@/store/user'

router.beforeEach(async (to, from, next) => {
  const userStore = useUserStore()
  
  if (userStore.isLoggedIn) {
    if (to.path === '/login') {
      next('/')
    } else {
      if (userStore.dynamicRoutes.length === 0) {
        // [修复 P2-3] 添加 try/catch 防止 API 错误导致页面卡死
        try {
          await userStore.loadUserMenu()
          next({ ...to, replace: true })
        } catch (e) {
          userStore.resetAll()
          next('/login')
          return
        }
      } else {
        next()
      }
    }
  } else {
    if (to.meta.public) {
      next()
    } else {
      next('/login')
    }
  }
})
```

---

## 9. 下一步

完成本文档后，Agent 可以：

1. ✅ 实现所有前端页面（用户/角色/菜单/API 管理）
2. ✅ 执行 `12-端到端集成测试方案.md` 进行全链路验收

---

**✅ 阶段完成标志：** 前端 API 层类型安全、拦截器正确处理 Token 刷新、菜单树构建正确。
**➡ 下一阶段：** `12-端到端集成测试方案.md` → 全链路验收。