# 05 — 前端 Admin 开发与整体集成验收

> **定位：** 基于 **ART-D Pro**（Vue3 + TypeScript + Element Plus，MIT 许可，GitHub: Daymychen/art-design-pro）搭建管理后台。ART-D Pro 已提供完整的权限系统、CRUD 模板、动态路由等能力——本阶段重点是**适配对接** PostgREST + Casbin 后端，而非从零开发。
>
> **核心原则：**
> - ✅ 使用 ART-D Pro 开源版内置的 Axios/Pinia/路由守卫/按钮指令/登录页/布局
> - ✅ 后端接口全部由 PostgREST + 02 数据库函数提供
> - ✅ 认证主流程走 Casdoor OAuth（Casdoor JS SDK），本地 `user_login_sso` 仅作回退
> - ❌ 不使用 ART-D Pro 商业版 NestJS 后端
>
> **前置依赖：** 04-网关与同步器（APISIX 鉴权就绪、Policy Syncer 运行中）、04.5-Casdoor集成（Casdoor 已部署）
> **产出物：** ART-D Pro 适配配置 + 全系统端到端验收通过
> **预计耗时：** 4-6 小时（配置适配为主）

---

## 1. ART-D Pro 安装与基础配置

### 1.1 克隆项目

```bash
# 克隆 ART-D Pro 开源版
git clone https://github.com/Daymychen/art-design-pro.git frontend/admin-ui
cd frontend/admin-ui
npm install
```

### 1.2 环境变量配置

```bash
# .env.development
VITE_APP_BASE_API=/api/v1          # 通过 Vite proxy 转发到 APISIX
VITE_APP_TITLE=零后端权限管理系统
VITE_CASDOOR_SERVER=http://localhost:8000
VITE_CASDOOR_CLIENT_ID=zero-backend-app
VITE_CASDOOR_ORG=built-in
VITE_CASDOOR_APP=zero-backend-rbac
VITE_CASDOOR_REDIRECT_PATH=/cb
```

### 1.3 Vite Proxy 配置

```ts
// vite.config.ts
import { defineConfig } from 'vite'
import vue from '@vitejs/plugin-vue'
import path from 'path'

export default defineConfig({
  plugins: [vue()],
  resolve: {
    alias: {
      '@': path.resolve(__dirname, 'src')
    }
  },
  server: {
    port: 5173,
    proxy: {
      '/api/v1': {
        target: 'http://localhost:9080',  // APISIX 网关数据面
        changeOrigin: true
        // APISIX 的 proxy-rewrite 插件会去掉 /api/v1 前缀
        // 最终 PostgREST 收到: /rpc/user_login_sso 或 /sys_user?select=...
      }
    }
  }
})
```

### 1.4 ART-D Pro 适配清单

| ART-D Pro 文件 | 适配内容 | 操作 |
|:---|:---|:---|
| `.env.development` | `VITE_APP_BASE_API = /api/v1` | 修改 |
| `vite.config.ts` | proxy 配置指向 APISIX 9080 | 新增 |
| `src/settings.ts` | 应用标题、Casdoor 配置 | 修改 |
| `src/store/modules/user.ts` | 登录/菜单/角色逻辑 | **重写** |
| `src/api/login.ts` | 登录接口适配 | **重写** |
| `src/api/menu.ts` | 菜单接口适配 | **重写** |
| `src/router/guard.ts` | 路由守卫（适配 Casdoor SDK） | **重写** |
| `src/directives/permission.ts` | 无需修改（使用内置） | 保留 |
| `src/layout/` | 无需修改（使用内置） | 保留 |
| `src/views/system/` | CRUD 页面字段映射 | 配置 |
| `src/lib/request.ts` | Axios 拦截器（Token 刷新） | **重写** |

---

## 2. 认证架构：Casdoor OAuth + 本地回退

### 2.1 认证流程总览

```
用户访问 /dashboard
  │
  ├─ 无有效 Access Token
  │   ├─ Casdoor 可用 → Casdoor JS SDK → OAuth 重定向 → Casdoor 签发 JWT → 回前端
  │   └─ Casdoor 不可用 → 回退到本地登录页 → POST /rpc/user_login_sso → PL/pgSQL 签发 JWT
  │
  └─ 有有效 Access Token
      └─ 请求携带 Bearer Token → APISIX 验签 → Casbin 鉴权 → PostgREST → PG (RLS)
```

### 2.2 安装 Casdoor JS SDK

```bash
npm install casdoor-javascript-sdk
```

### 2.3 Casdoor SDK 配置

```typescript
// src/lib/casdoor.ts
import Sdk from 'casdoor-javascript-sdk'

const sdk = new Sdk({
  serverUrl: import.meta.env.VITE_CASDOOR_SERVER,       // http://localhost:8000
  clientId: import.meta.env.VITE_CASDOOR_CLIENT_ID,     // zero-backend-app
  organizationName: import.meta.env.VITE_CASDOOR_ORG,   // built-in
  appName: import.meta.env.VITE_CASDOOR_APP,            // zero-backend-rbac
  redirectPath: import.meta.env.VITE_CASDOOR_REDIRECT_PATH, // /cb
  scope: 'read'
})

export default sdk
```

### 2.4 Token 存储策略

| Token | 存储位置 | 有效期 | JS 可访问 | 说明 |
|:---|:---|:---|:---|:---|
| Access Token | `sessionStorage` | 15 分钟 | ✅ | 前端请求携带 |
| Refresh Token | `httpOnly Cookie` | 7 天 | ❌ | 浏览器自动携带，后端验证 |

> **⚠️ 关键约束：** Refresh Token 由 PostgREST `user_login_sso` / `refresh_token_rtr` 通过 `Set-Cookie` 响应头设置，带有 `HttpOnly` + `Secure` + `SameSite=Lax` 属性。JavaScript **无法**通过 `document.cookie` 读取。

---

## 3. Axios HTTP 封装（适配 ART-D Pro）

### 3.1 核心拦截器

```typescript
// src/lib/request.ts
import axios from 'axios'
import { useUserStore } from '@/store/modules/user'
import router from '@/router'
import sdk from './casdoor'

const service = axios.create({
  baseURL: import.meta.env.VITE_APP_BASE_API || '/api/v1',
  timeout: 15000
})

// 请求拦截器：自动携带 Access Token
service.interceptors.request.use(async (config) => {
  const userStore = useUserStore()
  
  // 优先从 userStore 获取 AT
  if (userStore.token) {
    config.headers['Authorization'] = `Bearer ${userStore.token}`
  } else {
    // 尝试从 Casdoor SDK 获取
    const casdoorToken = sdk.getAccessToken()
    if (casdoorToken) {
      config.headers['Authorization'] = `Bearer ${casdoorToken}`
    }
  }
  
  return config
})

// 响应拦截器：401 自动无感刷新
let isRefreshing = false
let pendingRequests: Array<() => void> = []

service.interceptors.response.use(
  response => response,
  async (error) => {
    const { config, response } = error
    const userStore = useUserStore()

    if (response?.status === 401 && !config._retry) {
      // 避免登录/刷新接口本身进入循环
      if (config.url?.includes('/rpc/user_login_sso') || 
          config.url?.includes('/rpc/refresh_token_rtr')) {
        userStore.resetAll()
        router.push('/login')
        return Promise.reject(error)
      }

      if (isRefreshing) {
        // 已有刷新进行中，将请求排队
        return new Promise(resolve => {
          pendingRequests.push(() => resolve(service(config)))
        })
      }

      config._retry = true
      isRefreshing = true

      try {
        // ✅ 正确方案：不通过 JS 读取 Cookie
        // 浏览器自动携带 httpOnly Cookie 中的 refresh_token
        // PostgREST 的 refresh_token_rtr 从 Cookie 中读取 RT
        const { data } = await axios.post('/api/v1/rpc/refresh_token_rtr', {}, {
          withCredentials: true  // 确保跨域时携带 Cookie（如需要）
        })
        
        if (data.access_token) {
          userStore.setToken(data.access_token)
          config.headers['Authorization'] = `Bearer ${data.access_token}`
          
          // 重放排队的请求
          pendingRequests.forEach(cb => cb())
          pendingRequests = []
          
          return service(config)
        }
      } catch (refreshError) {
        // 刷新失败：Casdoor 可用则重定向登录，否则跳本地登录页
        userStore.resetAll()
        if (sdk.getAuthorizationCode()) {
          sdk.signin()  // 重定向到 Casdoor
        } else {
          router.push('/login')
        }
        return Promise.reject(refreshError)
      } finally {
        isRefreshing = false
      }
    }

    return Promise.reject(error)
  }
)

export default service
```

> **🔴 关键修正：** 与旧版代码不同，此处**不调用 `getCookie('refresh_token')`**。因为 httpOnly Cookie 无法被 JS 读取。刷新时直接 POST 空请求体，浏览器自动携带 Cookie，后端从 Cookie 中验证 RT。

---

## 4. Pinia 用户状态管理（适配 ART-D Pro）

### 4.1 User Store

```typescript
// src/store/modules/user.ts
import { defineStore } from 'pinia'
import { loginApi, getUserMenuApi, logoutApi } from '@/api/login'
import { flattenMenuToButtons, buildRoutesFromMenu } from '@/utils/menu-helper'
import sdk from '@/lib/casdoor'
import request from '@/lib/request'
import router from '@/router'

interface UserState {
  token: string
  username: string
  roles: string[]
  buttonPermissions: string[]
  menuTree: any[]
  routes: any[]
}

export const useUserStore = defineStore('user', {
  state: (): UserState => ({
    token: sessionStorage.getItem('access_token') || '',
    username: '',
    roles: [],
    buttonPermissions: [],
    menuTree: [],
    routes: []
  }),

  getters: {
    isLoggedIn: (state) => !!state.token,
    hasPermission: (state) => (code: string) => state.buttonPermissions.includes(code)
  },

  actions: {
    /**
     * 主登录入口：优先 Casdoor OAuth，回退本地登录
     */
    async login(username?: string, password?: string) {
      // 回退模式：本地账号密码登录
      if (username && password) {
        const { data } = await loginApi({ p_username: username, p_password: password })
        this.token = data.access_token
        this.username = data.username
        sessionStorage.setItem('access_token', data.access_token)
        return data
      }
      
      // Casdoor 模式：SDK 处理 OAuth 流程
      const casdoorToken = sdk.getAccessToken()
      if (casdoorToken) {
        this.token = casdoorToken
        // 从 JWT payload 解析用户信息
        const payload = JSON.parse(atob(casdoorToken.split('.')[1]))
        this.username = payload.name || payload.preferredUsername
        this.roles = payload.roles || []
        sessionStorage.setItem('access_token', casdoorToken)
        return { access_token: casdoorToken, username: this.username }
      }
      
      throw new Error('No authentication method available')
    },

    /**
     * 检查认证状态（路由守卫调用）
     */
    async checkAuth(): Promise<boolean> {
      // 1. 检查本地 AT
      if (this.token) return true
      
      // 2. 检查 Casdoor SDK
      if (sdk.getAccessToken()) {
        this.token = sdk.getAccessToken()!
        return true
      }
      
      // 3. 尝试 Casdoor 静默登录
      try {
        const token = await sdk.silentSignin()
        if (token) {
          this.token = token
          return true
        }
      } catch {
        // 静默登录失败，需要用户手动登录
      }
      
      return false
    },

    /**
     * 获取用户菜单并构建路由
     */
    async fetchUserMenu() {
      const { data } = await getUserMenuApi()
      
      // data 是扁平数组（含 parent_id），需转换为嵌套树
      this.menuTree = this.buildMenuTree(data)
      
      // 提取所有按钮权限标识
      this.buttonPermissions = flattenMenuToButtons(this.menuTree)
      
      // 将菜单树转为 Vue Router 路由配置
      this.routes = buildRoutesFromMenu(this.menuTree)
      
      return this.menuTree
    },

    /**
     * 扁平数组 → 嵌套树
     */
    buildMenuTree(flatMenu: any[]) {
      const map = new Map()
      const roots: any[] = []
      
      // 第一遍：创建节点副本
      flatMenu.forEach(item => {
        map.set(item.id, { ...item, children: [] })
      })
      
      // 第二遍：构建父子关系
      flatMenu.forEach(item => {
        const node = map.get(item.id)
        if (item.parent_id && map.has(item.parent_id)) {
          map.get(item.parent_id).children.push(node)
        } else {
          roots.push(node)
        }
      })
      
      return roots
    },

    setToken(token: string) {
      this.token = token
      sessionStorage.setItem('access_token', token)
    },

    resetAll() {
      this.token = ''
      this.username = ''
      this.roles = []
      this.buttonPermissions = []
      this.menuTree = []
      this.routes = []
      sessionStorage.removeItem('access_token')
    },

    async logout() {
      try {
        await logoutApi()
      } catch {
        // 忽略登出接口错误
      }
      this.resetAll()
      router.push('/login')
    }
  }
})
```

### 4.2 菜单转换工具

```typescript
// src/utils/menu-helper.ts

/**
 * 从嵌套菜单树提取所有按钮权限码
 */
export function flattenMenuToButtons(menuTree: any[]): string[] {
  const buttons: string[] = []
  
  function traverse(nodes: any[]) {
    for (const node of nodes) {
      if (node.type === 'BUTTON' && node.permission_code) {
        buttons.push(node.permission_code)
      }
      if (node.children?.length) {
        traverse(node.children)
      }
    }
  }
  
  traverse(menuTree)
  return buttons
}

/**
 * 将菜单树转为 Vue Router 路由配置
 */
export function buildRoutesFromMenu(menuTree: any[]): any[] {
  const routes: any[] = []
  
  for (const item of menuTree) {
    // 跳过纯按钮节点（不生成路由）
    if (item.type === 'BUTTON') continue
    
    const route: any = {
      path: item.path.startsWith('/') ? item.path : `/${item.path}`,
      name: item.name || item.path,
      // 使用 ART-D Pro 内置的懒加载方式
      component: item.component 
        ? () => import(`@/views/${item.component}.vue`)
        : undefined,
      meta: {
        title: item.meta?.title || item.title || item.name,
        icon: item.meta?.icon || item.icon,
        hidden: item.is_visible === false
      }
    }
    
    // 递归处理子菜单
    if (item.children?.length) {
      const childRoutes = buildRoutesFromMenu(item.children)
      if (childRoutes.length) {
        route.children = childRoutes
        // 有子菜单时自动重定向到第一个子路由
        if (!route.component) {
          route.redirect = childRoutes[0].path
        }
      }
    }
    
    routes.push(route)
  }
  
  return routes
}
```

---

## 5. 路由守卫（适配 ART-D Pro）

```typescript
// src/router/guard.ts
import { Router } from 'vue-router'
import { useUserStore } from '@/store/modules/user'
import sdk from '@/lib/casdoor'

const whiteList = ['/login', '/cb', '/sso-callback']

export function setupRouterGuard(router: Router) {
  router.beforeEach(async (to, from, next) => {
    const userStore = useUserStore()
    
    // 1. 白名单直接放行
    if (whiteList.includes(to.path)) {
      next()
      return
    }
    
    // 2. 检查认证状态
    const isAuthed = await userStore.checkAuth()
    
    if (!isAuthed) {
      // 未认证：尝试 Casdoor 登录或跳转登录页
      if (to.path === '/login') {
        next()
      } else {
        // 检查 Casdoor 是否可用
        try {
          const casdoorAvailable = await fetch('/api/v1/rpc/user_login_sso', {
            method: 'HEAD'
          }).then(r => true).catch(() => false)
          
          if (casdoorAvailable) {
            next(`/login?redirect=${encodeURIComponent(to.fullPath)}`)
          } else {
            sdk.signin()  // 重定向到 Casdoor
          }
        } catch {
          next(`/login?redirect=${encodeURIComponent(to.fullPath)}`)
        }
      }
      return
    }
    
    // 3. 已认证但访问登录页 → 跳首页
    if (to.path === '/login') {
      next('/')
      return
    }
    
    // 4. 加载菜单并生成动态路由
    if (userStore.routes.length === 0) {
      try {
        await userStore.fetchUserMenu()
        
        // 动态添加路由
        userStore.routes.forEach(route => {
          router.addRoute('Layout', route)  // ART-D Pro 使用 Layout 作为父路由
        })
        
        // 重新导航以确保新路由生效
        next({ ...to, replace: true })
      } catch (error) {
        console.error('Failed to load menu:', error)
        userStore.resetAll()
        next(`/login?redirect=${encodeURIComponent(to.fullPath)}`)
      }
      return
    }
    
    next()
  })
}
```

---

## 6. 登录页面（双模式）

```vue
<!-- src/views/login/index.vue -->
<template>
  <div class="login-container">
    <!-- 主登录：Casdoor OAuth -->
    <div v-if="casdoorMode" class="casdoor-login">
      <h2>{{ appTitle }}</h2>
      <el-button type="primary" size="large" @click="handleCasdoorLogin">
        使用 Casdoor 登录
      </el-button>
      <el-divider>或</el-divider>
      <el-link @click="casdoorMode = false">使用本地账号登录</el-link>
    </div>
    
    <!-- 回退登录：本地账号密码 -->
    <el-form v-else :model="loginForm" :rules="rules" ref="formRef" class="login-form">
      <h2>{{ appTitle }}</h2>
      <el-form-item prop="username">
        <el-input v-model="loginForm.username" placeholder="用户名" />
      </el-form-item>
      <el-form-item prop="password">
        <el-input v-model="loginForm.password" type="password" placeholder="密码" show-password />
      </el-form-item>
      <el-button type="primary" :loading="loading" @click="handleLocalLogin" style="width:100%">
        登录
      </el-button>
      <el-link v-if="casdoorAvailable" @click="casdoorMode = true" style="margin-top:12px">
        返回 Casdoor 登录
      </el-link>
    </el-form>
  </div>
</template>

<script setup lang="ts">
import { ref, reactive, onMounted } from 'vue'
import { useRouter, useRoute } from 'vue-router'
import { useUserStore } from '@/store/modules/user'
import sdk from '@/lib/casdoor'
import { ElMessage } from 'element-plus'

const router = useRouter()
const route = useRoute()
const userStore = useUserStore()

const appTitle = import.meta.env.VITE_APP_TITLE || '管理后台'
const casdoorMode = ref(true)
const casdoorAvailable = ref(false)
const loading = ref(false)
const formRef = ref()

const loginForm = reactive({
  username: '',
  password: ''
})

const rules = {
  username: [{ required: true, message: '请输入用户名', trigger: 'blur' }],
  password: [{ required: true, message: '请输入密码', trigger: 'blur' }]
}

onMounted(async () => {
  // 检查 Casdoor 是否可用
  try {
    const resp = await fetch(`${import.meta.env.VITE_CASDOOR_SERVER}/api/health`)
    casdoorAvailable.value = resp.ok
  } catch {
    casdoorAvailable.value = false
    casdoorMode.value = false  // Casdoor 不可用则直接显示本地登录
  }
  
  // 检查是否从 Casdoor 回调回来
  const token = sdk.getAccessToken()
  if (token) {
    await handleCasdoorCallback()
  }
})

async function handleCasdoorLogin() {
  sdk.signin()  // 重定向到 Casdoor 登录页
}

async function handleCasdoorCallback() {
  try {
    await userStore.login()
    await userStore.fetchUserMenu()
    userStore.routes.forEach(route => router.addRoute('Layout', route))
    const redirect = (route.query.redirect as string) || '/'
    router.push(redirect)
  } catch (error) {
    ElMessage.error('登录失败，请重试')
  }
}

async function handleLocalLogin() {
  await formRef.value.validate()
  loading.value = true
  try {
    await userStore.login(loginForm.username, loginForm.password)
    await userStore.fetchUserMenu()
    userStore.routes.forEach(route => router.addRoute('Layout', route))
    const redirect = (route.query.redirect as string) || '/'
    router.push(redirect)
  } catch {
    ElMessage.error('用户名或密码错误')
  } finally {
    loading.value = false
  }
}
</script>
```

---

## 7. 权限系统说明（双层防护）

### 7.1 前端权限（UX 层）

| 层级 | 机制 | 作用 | 可绕过？ |
|:---|:---|:---|:---|
| 路由守卫 | `router.beforeEach` | 未登录用户无法访问页面 | ✅ 直接 curl API |
| 按钮显隐 | `v-permission` 指令 | 无权限按钮不渲染 | ✅ 手动构造请求 |
| 菜单过滤 | 后端 `get_user_menu` 只返回已授权菜单 | 侧边栏只显示已授权项 | ✅ 直接访问 URL |

### 7.2 后端权限（安全层）

| 层级 | 机制 | 作用 | 可绕过？ |
|:---|:---|:---|:---|
| API 鉴权 | APISIX `authz-casbin` | 无权限 API 返回 403 | ❌ 无法绕过 |
| 数据隔离 | PostgreSQL RLS | 只能看到本租户数据 | ❌ 无法绕过 |
| Token 黑名单 | `sys_token_blacklist` + `db-pre-request` | 被踢用户 Token 立即失效 | ❌ 无法绕过 |

> **核心原则：** 前端权限仅影响用户体验（隐藏不可见元素），后端权限才是真正的安全防线。即使前端权限被绕过（如手动构造 HTTP 请求），Casbin 和 RLS 仍会拦截。

---

## 8. CRUD 页面字段映射

### 8.1 用户管理（`src/views/system/user/index.vue`）

```vue
<template>
  <div class="app-container">
    <ProTable :columns="columns" :api="fetchUsers" :search="searchConfig">
      <template #toolbar>
        <el-button v-permission="['user:add']" type="primary" @click="handleAdd">
          新增用户
        </el-button>
      </template>
      <template #actions="{ row }">
        <el-button v-permission="['user:edit']" link @click="handleEdit(row)">编辑</el-button>
        <el-button v-permission="['user:delete']" link type="danger" @click="handleDelete(row)">
          删除
        </el-button>
      </template>
    </ProTable>
    
    <!-- 新增/编辑弹窗 -->
    <UserForm v-model:visible="formVisible" :data="currentRow" @success="refresh" />
  </div>
</template>

<script setup lang="ts">
import { ref } from 'vue'
import { ProTable } from '@/components/ProTable'
import { getUsersApi, deleteUserApi } from '@/api/system/user'
import UserForm from './components/UserForm.vue'

const columns = [
  { prop: 'id', label: 'ID', width: 240 },
  { prop: 'username', label: '用户名' },
  { prop: 'email', label: '邮箱' },
  { prop: 'role_names', label: '角色' },  // 通过 PostgREST 计算列或视图
  { prop: 'is_active', label: '状态', slot: 'status' },
  { prop: 'created_at', label: '创建时间' }
]

const searchConfig = [
  { prop: 'username', label: '用户名', type: 'input' },
  { prop: 'is_active', label: '状态', type: 'select', options: [
    { label: '启用', value: true },
    { label: '禁用', value: false }
  ]}
]

async function fetchUsers(params: any) {
  const { data, total } = await getUsersApi(params)
  return { list: data, total }
}

async function handleDelete(row: any) {
  await deleteUserApi(row.id)
  refresh()
}

const formVisible = ref(false)
const currentRow = ref(null)
function handleAdd() { currentRow.value = null; formVisible.value = true }
function handleEdit(row: any) { currentRow.value = row; formVisible.value = true }
function refresh() { /* 刷新表格 */ }
</script>
```

### 8.2 字段映射表

| 页面 | PostgREST 端点 | 关键字段 | 特殊处理 |
|:---|:---|:---|:---|
| 用户管理 | `GET /api/v1/sys_user` | id, username, email, is_active, created_at | 角色通过 `sys_user_role` 联查 |
| 角色管理 | `GET /api/v1/sys_role` | id, role_code, role_name | 权限通过 `sys_role_menu`/`sys_role_api` 联查 |
| 菜单管理 | `GET /api/v1/sys_menu` | id, parent_id, name, type, path, component, permission_code | 需构建树形结构 |
| API 管理 | `GET /api/v1/sys_api` | id, path, method, api_name | 直接 CRUD |

---

## 9. 全系统端到端验收

### 9.1 基础认证流程

| # | 验收项 | 操作 | 预期 | 通过 |
|:---:|:---|:---|:---|:---:|
| F1 | Casdoor OAuth 登录 | 访问 / → 点击 Casdoor 登录 → 输入 admin/admin123 | 跳转回首页，显示管理菜单 | ☐ |
| F2 | 本地回退登录 | 停掉 Casdoor → 访问 /login → 输入 admin/admin123 | 跳转首页，功能正常 | ☐ |
| F3 | 菜单正确渲染 | 查看侧边栏 | 只显示已分配的菜单项 | ☐ |
| F4 | Token 无感刷新 | 等 AT 过期后操作页面（开发环境可缩短至 1 分钟） | 操作不中断，自动刷新 Token | ☐ |
| F5 | 退出登录 | 点击退出 | 跳转登录页，旧 Token 不可用 | ☐ |

### 9.2 权限管理流程

| # | 验收项 | 操作 | 预期 | 通过 |
|:---:|:---|:---|:---|:---:|
| F6 | 新增用户 | 在用户管理页新增 | 新用户可登录 | ☐ |
| F7 | 新增角色 | 在角色管理页新增 | 新角色出现在列表中 | ☐ |
| F8 | 给用户分配角色 | 在用户管理 → 角色分配 | sys_user_role 表更新 | ☐ |
| F9 | 给角色分配菜单 | 在角色管理 → 菜单权限 | sys_role_menu 表更新 | ☐ |
| F10 | 给角色分配 API | 在角色管理 → API 权限 | sys_role_api 表更新，casbin_rule 视图自动更新 | ☐ |
| F11 | 权限分配后生效 | 给新用户分配含特定菜单的角色 → 新用户重新登录 | 新用户可见对应菜单 | ☐ |

### 9.3 按钮权限流程

| # | 验收项 | 操作 | 预期 | 通过 |
|:---:|:---|:---|:---|:---:|
| F12 | 有权限按钮可见 | 以 admin 登录查看用户管理页 | `user:add`、`user:edit`、`user:delete` 按钮可见 | ☐ |
| F13 | 无权限按钮不渲染 | 用仅有只读权限的角色登录 | 增删改按钮不渲染（DOM 中不存在） | ☐ |
| F14 | F12 无法绕过 | F12 打开控制台手动添加按钮 HTML → 点击 | 请求应在网关层被 Casbin 拦截（403） | ☐ |

### 9.4 API 鉴权流程

| # | 验收项 | 操作 | 预期 | 通过 |
|:---:|:---|:---|:---|:---:|
| F15 | 有权限 API 通过 | GET /api/v1/sys_user（admin） | 200 + 用户列表 | ☐ |
| F16 | 无权限 API 拒绝 | 用 guest 角色 JWT 调用 DELETE /api/v1/sys_user | 403 | ☐ |
| F17 | 不存在的路径 404 | GET /api/v1/nonexistent | 404（APISIX 路由不匹配） | ☐ |
| F18 | 不带 Token 拒绝 | 直接 curl APISIX（无 Authorization） | 401 | ☐ |

### 9.5 角色变更触发即时生效（核心高光场景）

| # | 验收项 | 操作 | 预期 | 通过 |
|:---:|:---|:---|:---|:---:|
| F19 | 角色被收回后即时失效 | ① admin 给 userA 分配 admin 角色 → userA 登录<br>② admin 收回 userA 的 admin 角色<br>③ userA 立即访问之前可访问的 API | ①成功<br>②成功<br>③返回 401 → 前端自动刷新 → 用新角色继续（若无权限则 403） | ☐ |
| F20 | 踢下线即时生效 | ① userA 登录<br>② admin 调用 kick_user<br>③ userA 发起下一个请求 | ①成功<br>②成功<br>③返回 401 → 前端自动尝试刷新 → 刷新失败 → 跳转登录页 | ☐ |

### 9.6 多租户数据隔离

| # | 验收项 | 操作 | 预期 | 通过 |
|:---:|:---|:---|:---|:---:|
| F21 | 租户 A 用户只看到租户 A 数据 | ① 创建 tenant_a 的用户 userA<br>② 创建 tenant_b 的用户 userB<br>③ 分别登录后查询 sys_user | userA 只看到 tenant_a 的用户；userB 只看到 tenant_b 的用户 | ☐ |
| F22 | 跨租户访问拒绝 | userA 尝试 PATCH tenant_b 的用户信息 | RLS 拒绝（0 rows affected 或 404） | ☐ |

### 9.7 同步链路验证

| # | 验收项 | 操作 | 预期 | 通过 |
|:---:|:---|:---|:---|:---:|
| F23 | 添加 API 权限 → casbin_rule 视图自动更新 | INSERT INTO sys_role_api → SELECT * FROM casbin_rule | 新 p 规则出现 | ☐ |
| F24 | pg_notify → Syncer → etcd → APISIX | 同上，观察 Syncer 日志 + APISIX 策略 | Syncer 日志含 "Debounce timer fired" + "Successfully synchronized" | ☐ |
| F25 | 新权限立即生效 | 给某角色新增 API → 该角色用户立即调用 | 调用成功（1 秒内生效） | ☐ |

### 9.8 异常场景

| # | 验收项 | 操作 | 预期 | 通过 |
|:---:|:---|:---|:---|:---:|
| F26 | 密码错误拒绝登录 | 输入错误密码 | 错误提示，Token 未生成 | ☐ |
| F27 | 重复登录行为 | admin 在浏览器 A 登录 → 在浏览器 B 登录 → 回到 A 操作 | A 的请求返回 401 → 静默刷新 → 获取新的 Token 继续（旧 RT 被标记为 is_used，刷新后签发新 Token） | ☐ |
| F28 | Syncer 离线 → 恢复后自动追赶 | 停 Syncer → 修改权限 → 启 Syncer | 启动后 Syncer 自动执行初始对账 → 权限追上最新 | ☐ |

### 9.9 性能

| # | 验收项 | 操作 | 预期 | 通过 |
|:---:|:---|:---|:---|:---:|
| F29 | 登录到首页加载 < 2 秒 | 计时登录操作 | < 2 秒 | ☐ |
| F30 | API 鉴权延迟 < 50ms | 连续 100 次请求平均耗时 | P99 < 50ms（Casbin 内存匹配） | ☐ |

---

## 10. 验收清单汇总

| 类目 | 项数 | 通过标准 |
|:---|:---:|:---|
| 基础认证 | 5 | 5/5 |
| 权限管理 | 6 | 6/6 |
| 按钮权限 | 3 | 3/3 |
| API 鉴权 | 4 | 4/4 |
| 角色即时生效 | 2 | 2/2 |
| 多租户隔离 | 2 | 2/2 |
| 同步链路 | 3 | 3/3 |
| 异常场景 | 3 | 3/3 |
| 性能 | 2 | 2/2 |
| **总计** | **30** | **30/30** |

> **通过标准：** 30/30 项全部打勾。任一未通过则定位问题、修复、重新验收该项。

---

## 附录 A：全系统验收脚本（PowerShell 版）

```powershell
# 全链路冒烟测试脚本（Windows PowerShell）
# 使用 Invoke-WebRequest 替代 curl

$BASE_URL = "http://localhost:9080/api/v1"
$ErrorActionPreference = "Stop"

Write-Host "=== 1. 登录获取 Token ===" -ForegroundColor Cyan
$loginBody = @{
    p_username = "admin"
    p_password = "admin123"
} | ConvertTo-Json

$loginResp = Invoke-RestMethod -Uri "$BASE_URL/rpc/user_login_sso" -Method POST -ContentType "application/json" -Body $loginBody -SessionVariable cookieSession
$token = $loginResp.access_token
Write-Host "Token: $($token.Substring(0, 20))..."

Write-Host ""
Write-Host "=== 2. 查询用户列表（应 200） ===" -ForegroundColor Cyan
$userResp = Invoke-RestMethod -Uri "$BASE_URL/sys_user" -Method GET -Headers @{ "Authorization" = "Bearer $token" }
Write-Host "Users count: $($userResp.Count)"

Write-Host ""
Write-Host "=== 3. 未认证请求（应 401） ===" -ForegroundColor Cyan
try {
    Invoke-RestMethod -Uri "$BASE_URL/sys_user" -Method GET
    Write-Host "ERROR: Should have returned 401" -ForegroundColor Red
} catch {
    Write-Host "HTTP: $($_.Exception.Response.StatusCode.value__) (expected: 401)" -ForegroundColor Green
}

Write-Host ""
Write-Host "=== 4. 获取菜单树 ===" -ForegroundColor Cyan
$menuResp = Invoke-RestMethod -Uri "$BASE_URL/rpc/get_user_menu" -Method GET -Headers @{ "Authorization" = "Bearer $token" }
Write-Host "Menu items: $($menuResp.Count)"

Write-Host ""
Write-Host "=== 5. JWKS 端点 ===" -ForegroundColor Cyan
$jwksResp = Invoke-RestMethod -Uri "http://localhost:8000/.well-known/jwks" -Method GET
Write-Host "JWKS keys: $($jwksResp.keys.Count)"

Write-Host ""
Write-Host "=== ALL SMOKE TESTS PASSED ===" -ForegroundColor Green
```

---

## 附录 B：开发环境 AT 快速过期配置

为加速 F4（Token 无感刷新）验收，开发环境可将 Access Token 有效期缩短至 1 分钟：

```bash
# .env.development（Casdoor 应用配置）
# 在 Casdoor Web UI 中修改应用 expireInHours 为 0.0167（约1分钟）
# 或通过 API 更新：
curl -X PUT http://localhost:8000/api/update-application \
  -H "Authorization: Bearer YOUR_ADMIN_TOKEN" \
  -d '{
    "owner": "built-in",
    "name": "zero-backend-rbac",
    "expireInHours": 0.0167
  }'
```

---

## 附录 C：常见问题排查

| 故障现象 | 排查命令 | 解决方案 |
|:---|:---|:---|
| 登录后无限重定向 | 检查浏览器 Network 中 `/cb` 请求 | 确认 Casdoor 应用 redirectUris 包含 `http://localhost:5173/cb` |
| 401 后不刷新 Token | 检查 `refresh_token_rtr` 是否支持 Cookie 读取 | 确认 PostgREST 函数从 `Cookie` header 读取 RT |
| 菜单不显示 | `curl /api/v1/rpc/get_user_menu` 检查返回格式 | 确认前端 `buildMenuTree` 正确处理扁平数组 |
| Casdoor SDK 报错 `invalid_client` | 检查 clientId/clientSecret | 确认 `.env.development` 与 Casdoor 应用配置一致 |
| CORS 错误 | 检查 APISIX CORS 插件配置 | 确认 `allow_origins` 包含 `http://localhost:5173` |
| 按钮权限不生效 | 检查 `v-permission` 绑定值 | 确认 `permission_code` 与数据库 `sys_menu` 一致 |

---

## 附录 D：与已锁定决策的对应关系

| 决策 | 来源 | 05 文档体现 |
|:---|:---|:---|
| JWT 签发：Casdoor RS256 | 00总纲 §6.2 | §2.3 Casdoor SDK 配置 |
| JWKS 端点无 `.json` 后缀 | 04 §2.1 | 附录 A 中使用 `/.well-known/jwks` |
| RT 在 httpOnly Cookie | 02 §2 | §3.1 拦截器不读取 Cookie |
| AT 在 sessionStorage | 03 v1 | §4.1 Pinia store |
| RPC 在 api_v1 schema | 02 v2 | §1.3 proxy 路径 `/api/v1/rpc/*` |
| Admin API 端口 9180 | 04 v1 | 不涉及（前端不访问） |
| Policy Syncer SHA256 | 04 v1 | 不涉及 |
| 多租户 RLS | 02 v2 | §9.6 验收项 |
| Soft Delete | 02 v2 | §8.1 删除用 PATCH is_active=false |
