#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
04.7 §10 webhook 接收器 — 把 Casdoor webhook 请求原样落盘，返回 200。

用法:
    python3 01_receiver.py [port]     # 默认 8099

落盘:
    out/<时间戳>_<序号>.json       请求体（webhook payload）
    out/<时间戳>_<序号>.json.headers  请求行 + 请求头

注意:
    - 监听 0.0.0.0，确保 Casdoor 容器能访问本机（docker 网络 /
      host.docker.internal / 端口映射，按部署拓扑选择 webhook URL）。
    - 返回 200 → Casdoor 记 Success；返回非 2xx → 自动重试（默认 3 次）。
"""
import os
import sys
import time
from http.server import BaseHTTPRequestHandler, HTTPServer

OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "out")
os.makedirs(OUT, exist_ok=True)


class Handler(BaseHTTPRequestHandler):
    def _handle(self):
        n = int(self.headers.get("Content-Length") or 0)
        body = self.rfile.read(n) if n else b""
        base = time.strftime("%Y%m%d-%H%M%S") + "-%05d" % (time.time_ns() % 100000)
        path = os.path.join(OUT, base + ".json")
        with open(path, "wb") as f:
            f.write(body)
        with open(path + ".headers", "w", encoding="utf-8") as f:
            f.write("%s %s\n" % (self.command, self.path))
            for k, v in self.headers.items():
                f.write("%s: %s\n" % (k, v))
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.end_headers()
        self.wfile.write(b'{"status":"ok"}')
        print("RECV %s %s -> %s (%dB)" % (self.command, self.path, os.path.basename(path), len(body)), flush=True)

    do_POST = _handle
    do_PUT = _handle
    do_GET = _handle
    do_DELETE = _handle


if __name__ == "__main__":
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 8099
    print("[receiver] listening on 0.0.0.0:%d -> %s" % (port, OUT), flush=True)
    HTTPServer(("0.0.0.0", port), Handler).serve_forever()
