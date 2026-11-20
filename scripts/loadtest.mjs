// scripts/loadtest.mjs — 零依赖并发压测（阶段 4 门禁固化入库，2026-11-20）
// 用法: TARGET_URL='http://localhost:9080/api/v1/platform/role?select=role_code,role_name&limit=5' \
//       TOKEN=xxx CONCURRENCY=50 DURATION=10 node scripts/loadtest.mjs
// 输出: {ok, qps, p50, p90, p99, errors}（keep-alive，node ≥18）
import http from 'node:http';

const url = new URL(process.env.TARGET_URL);
const token = process.env.TOKEN;
const CONC = parseInt(process.env.CONCURRENCY || '50', 10);
const DUR = parseFloat(process.env.DURATION || '10', 10);
const isTLS = url.protocol === 'https:';
const lib = isTLS ? (await import('node:https')) : http;

if (!token) { console.error('missing TOKEN'); process.exit(2); }

const agent = new lib.Agent({ keepAlive: true, maxSockets: CONC });
const lat = [];
let ok = 0, err = 0, bytes = 0;
const stop = Date.now() + DUR * 1000;

function one() {
  if (Date.now() >= stop) return Promise.resolve();
  const t0 = process.hrtime.bigint();
  return new Promise((resolve) => {
    const req = lib.get({
      host: url.hostname, port: url.port || (isTLS ? 443 : 80),
      path: url.pathname + url.search, agent,
      headers: { Authorization: `Bearer ${token}`, Accept: 'application/json' },
    }, (res) => {
      let n = 0; res.on('data', (c) => { n += c.length; });
      res.on('end', () => {
        const us = Number(process.hrtime.bigint() - t0) / 1000;
        lat.push(us); bytes += n;
        if (res.statusCode === 200) ok++; else err++;
        resolve();
      });
    });
    req.on('error', () => { err++; resolve(); });
  });
}

async function worker() {
  while (Date.now() < stop) { await one(); }
}

const t0 = Date.now();
await Promise.all(Array.from({ length: CONC }, worker));
const wall = (Date.now() - t0) / 1000;
lat.sort((a, b) => a - b);
const pct = (p) => (lat.length ? lat[Math.min(lat.length - 1, Math.floor(lat.length * p))] : 0).toFixed(1);
console.log(JSON.stringify({
  target: url.host + url.pathname, concurrency: CONC, duration_s: wall,
  ok, err, qps: (ok / wall).toFixed(1),
  p50_us: +pct(0.5), p90_us: +pct(0.9), p99_us: +pct(0.99),
}));
