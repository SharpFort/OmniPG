#!/usr/bin/env node
/**
 * Logto OSS v1.42 CSP 补丁（OmniPG 定制）
 *
 * 背景：Logto sign-in 体验页的 CSP frame-ancestors 在源码中硬编码为
 *   ["'self'", ...adminOrigins]
 * （packages/core/src/middleware/koa-security-headers.ts），且 UrlSet 仅读取
 * PORT/ENDPOINT/DISABLE_LOCALHOST 环境变量——没有官方配置可以把应用域名加入
 * frame-ancestors。因此 OmniAdmin 无法直接 iframe 嵌入 Logto 托管登录页。
 *
 * 本脚本在容器启动时（compose entrypoint）把 LOGTO_EXTRA_FRAME_ANCESTOR
 * 注入编译产物的 frameAncestors 数组，放行前端域名嵌入。
 *
 * 容错：Logto 镜像升级后编译产物结构变化会导致 target 找不到——此时打印 WARN
 * 并继续启动（嵌入登录失效，但直接跳转登录不受影响；前端登录页有"在新窗口打开"
 * 兜底按钮）。已补丁的文件会幂等跳过。
 */
'use strict';

const fs = require('node:fs');
const path = require('node:path');

const BUILD_DIR = '/etc/logto/packages/core/build';
const extra = process.env.LOGTO_EXTRA_FRAME_ANCESTOR || 'http://localhost:5173';
const TARGET = 'frameAncestors: ["\'self\'", ...adminOrigins]';
const REPLACEMENT = 'frameAncestors: ["\'self\'", "' + extra + '", ...adminOrigins]';

if (!fs.existsSync(BUILD_DIR)) {
  console.warn('[logto-csp-patch] WARN: build dir not found: ' + BUILD_DIR);
  process.exit(0);
}

const files = fs.readdirSync(BUILD_DIR).filter((f) => /^main-.+\.js$/.test(f));
let patched = 0;

for (const file of files) {
  const p = path.join(BUILD_DIR, file);
  let src = fs.readFileSync(p, 'utf8');

  if (src.includes(REPLACEMENT)) {
    console.log('[logto-csp-patch] ' + file + ': already patched, skip');
    patched += 1;
    continue;
  }
  if (!src.includes(TARGET)) {
    console.warn('[logto-csp-patch] WARN ' + file + ': target not found, skip');
    continue;
  }

  fs.writeFileSync(p, src.split(TARGET).join(REPLACEMENT));
  console.log('[logto-csp-patch] ' + file + ': patched (frame-ancestors += ' + extra + ')');
  patched += 1;
}

if (patched === 0) {
  console.warn('[logto-csp-patch] WARN: no file patched — iframe 嵌入登录可能被 CSP 拦截');
}
