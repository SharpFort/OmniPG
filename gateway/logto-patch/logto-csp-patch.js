#!/usr/bin/env node
/**
 * Logto OSS v1.42 CSP + XFO 补丁（OmniPG 定制）
 *
 * 背景：
 * 1. Logto sign-in 体验页的 CSP frame-ancestors 在源码中硬编码为
 *    ["'self'", ...adminOrigins]，UrlSet 仅读取 PORT/ENDPOINT/DISABLE_LOCALHOST，
 *    没有官方配置可以把应用域名加入 frame-ancestors；
 * 2. 更关键的是：/oidc/* 路由走 basicSecurityHeaderSettings（UserApps.Oidc 挂载），
 *    默认带 helmet 的 X-Frame-Options: SAMEORIGIN——即便 experience 页 CSP 已放行，
 *    浏览器仍会在 iframe 第一步（/oidc/auth 303）就拒绝 display。
 *
 * 本脚本在容器启动时（compose entrypoint）做两件事：
 *   1) 把 LOGTO_EXTRA_FRAME_ANCESTOR 注入编译产物的 frameAncestors 数组；
 *   2) 对 basicSecurityHeaderSettings 关闭 helmet frameguard，
 *      使 /oidc/* 不再输出 X-Frame-Options: SAMEORIGIN。
 * 安全说明：关闭 frameguard 后，最终 /sign-in 体验页仍由 CSP frame-ancestors 限制嵌入来源，
 * /oidc/auth 本身只是 303 重定向与 set-cookie，不渲染业务内容。
 *
 * 支持空格分隔的多个 origin（如 "http://localhost:3006 http://localhost:3007"）。
 * 容错：Logto 镜像升级后编译产物结构变化会导致 target 找不到——打印 WARN 并继续启动；
 * 已补丁的文件会幂等跳过。
 */
'use strict';

const fs = require('node:fs');
const path = require('node:path');

const BUILD_DIR = '/etc/logto/packages/core/build';
const extras = (process.env.LOGTO_EXTRA_FRAME_ANCESTOR || 'http://localhost:3006 http://localhost:3007')
  .split(/\s+/)
  .filter(Boolean);
// origin 白名单校验（批次2d前置修复）：值被直接内插进编译产物 JS 源码——
// 含引号/反斜杠/JS 元字符的值会破坏生成代码；非法项剔除并告警
const ORIGIN_RE = /^https?:\/\/[A-Za-z0-9._~:-]+$/;
const validOrigins = extras.filter((o) => ORIGIN_RE.test(o));
const invalidOrigins = extras.filter((o) => !ORIGIN_RE.test(o));
if (invalidOrigins.length) {
  console.warn('[logto-csp-patch] WARN 忽略非法 origin（须匹配 ' + ORIGIN_RE + '）: ' + invalidOrigins.join(' '));
}
if (validOrigins.length === 0) {
  // 空列表会产生 `"'self'", , ...adminOrigins` 的非法 JS（批次2d前置修复）
  console.warn('[logto-csp-patch] WARN: 无有效 LOGTO_EXTRA_FRAME_ANCESTOR——跳过 frame-ancestors 注入');
}

const TARGET = 'frameAncestors: ["\'self\'", ...adminOrigins]';
const REPLACEMENT =
  validOrigins.length > 0
    ? 'frameAncestors: ["\'self\'", ' + validOrigins.map((o) => '"' + o + '"').join(', ') + ', ...adminOrigins]'
    : null;
const BASIC_TARGET = 'basicSecurityHeaderSettings = {';
const BASIC_REPLACEMENT = 'basicSecurityHeaderSettings = { frameguard: false,';

if (!fs.existsSync(BUILD_DIR)) {
  console.warn('[logto-csp-patch] WARN: build dir not found: ' + BUILD_DIR);
  process.exit(0);
}

const files = fs.readdirSync(BUILD_DIR).filter((f) => /^main-.+\.js$/.test(f));
let patched = 0;

for (const file of files) {
  const p = path.join(BUILD_DIR, file);
  let src = fs.readFileSync(p, 'utf8');
  let changed = false;

  // 1) CSP frame-ancestors
  if (REPLACEMENT === null) {
    // 无有效 origin——跳过本项（上方已 WARN），不影响 frameguard 补丁
  } else if (src.includes(REPLACEMENT)) {
    console.log('[logto-csp-patch] ' + file + ': frame-ancestors already patched');
  } else if (src.includes(TARGET)) {
    src = src.split(TARGET).join(REPLACEMENT);
    console.log('[logto-csp-patch] ' + file + ': patched (frame-ancestors += ' + validOrigins.join(' ') + ')');
    changed = true;
  } else {
    console.warn('[logto-csp-patch] WARN ' + file + ': frame-ancestors target not found');
  }

  // 2) OIDC 路由去除 X-Frame-Options（basicSecurityHeaderSettings.frameguard = false）
  if (src.includes(BASIC_REPLACEMENT)) {
    console.log('[logto-csp-patch] ' + file + ': basic frameguard already patched');
  } else if (src.includes(BASIC_TARGET)) {
    src = src.split(BASIC_TARGET).join(BASIC_REPLACEMENT);
    console.log('[logto-csp-patch] ' + file + ': patched (basic frameguard disabled)');
    changed = true;
  } else {
    console.warn('[logto-csp-patch] WARN ' + file + ': basicSecurityHeaderSettings not found');
  }

  if (changed) {
    fs.writeFileSync(p, src);
  }
  patched += changed ? 1 : 0;
}

if (patched === 0) {
  console.warn('[logto-csp-patch] WARN: no file patched — iframe 嵌入登录可能仍被 CSP/XFO 拦截');
}
