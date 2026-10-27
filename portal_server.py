#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""工作台门户服务
================
托管「电工猴的此思妙想工作台」门户页，并提供一键启动两个本机应用的接口。

为什么需要它：浏览器能直接用原生 DPI 渲染网页（清晰、与 GitHub 上一致），
但网页本身无法启动本地程序。加这一层本地服务后，门户里的「打开」按钮
调用 /api/launch 即可启动应用，无需注册 workbench:// 协议。

用法：
    pythonw portal_server.py --port 8770

接口：
    GET /                 门户页
    GET /api/health       健康检查
    GET /api/launch?app=homework|ai   启动对应应用（等待端口就绪后返回 url）
    GET /<静态文件>        仅放行 html/png/ico/css/js/svg，且禁止访问 apps/ 与 .git
"""
from __future__ import annotations

import json
import mimetypes
import os
import socket
import subprocess
import sys
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, unquote, urlparse

ROOT = Path(__file__).resolve().parent
AI_DIR = ROOT / "apps" / "domestic-global-ai-workbench"
HW_DIR = ROOT / "apps" / "qq-email-homework-assistant"
AI_EXE = AI_DIR / "AI多Agent流水线.exe"
AI_PY = AI_DIR / "platform.py"
HW_PY = HW_DIR / "app.pyw"
PORTAL_HTML = ROOT / "电工猴的此思妙想工作台.html"

ALLOWED_SUFFIX = {".html", ".htm", ".png", ".ico", ".css", ".js", ".svg"}
CREATE_NO_WINDOW = getattr(subprocess, "CREATE_NO_WINDOW", 0)
DRY_RUN = False


def find_pythonw() -> str:
    exe = Path(sys.executable)
    cand = exe.with_name("pythonw.exe")
    if cand.exists():
        return str(cand)
    return str(exe)


def port_open(port: int, host: str = "127.0.0.1", timeout: float = 0.4) -> bool:
    try:
        with socket.socket() as s:
            s.settimeout(timeout)
            return s.connect_ex((host, port)) == 0
    except Exception:
        return False


def wait_port(port: int, seconds: float = 12.0) -> bool:
    deadline = time.time() + seconds
    while time.time() < deadline:
        if port_open(port):
            return True
        time.sleep(0.25)
    return False


def launch(app: str) -> tuple[bool, str, str]:
    """返回 (ok, msg, url)"""
    if app == "homework":
        url = "http://127.0.0.1:8765/"
        if port_open(8765):
            return True, "QQ 邮箱助手已在运行", url
        if not HW_PY.exists():
            return False, f"找不到 {HW_PY}", ""
        if DRY_RUN:
            return True, "[dry-run] 将启动 QQ 邮箱助手", url
        subprocess.Popen([find_pythonw(), str(HW_PY)], cwd=str(HW_DIR),
                         creationflags=CREATE_NO_WINDOW)
        ok = wait_port(8765)
        return ok, ("已启动 QQ 邮箱助手" if ok else "已启动，但端口 8765 未就绪"), url

    if app == "ai":
        url = "http://127.0.0.1:8767/"
        if port_open(8767):
            return True, "AI 工作台已在运行", url
        if DRY_RUN:
            return True, "[dry-run] 将启动 AI 工作台", url
        if AI_EXE.exists():
            try:
                os.startfile(str(AI_EXE))  # noqa: S606
            except Exception as exc:
                return False, f"启动 exe 失败：{exc}", ""
        elif AI_PY.exists():
            subprocess.Popen([find_pythonw(), str(AI_PY)], cwd=str(AI_DIR),
                             creationflags=CREATE_NO_WINDOW)
        else:
            return False, "找不到 AI 工作台（exe 与 platform.py 都不存在）", ""
        ok = wait_port(8767)
        return ok, ("已启动 AI 工作台" if ok else "已启动，但端口 8767 未就绪"), url

    return False, "未知应用", ""


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def _send(self, code: int, body: bytes, ctype: str) -> None:
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        try:
            self.wfile.write(body)
        except (BrokenPipeError, ConnectionResetError):
            pass

    def _json(self, data: dict, code: int = 200) -> None:
        self._send(code, json.dumps(data, ensure_ascii=False).encode("utf-8"),
                   "application/json; charset=utf-8")

    def do_GET(self) -> None:
        u = urlparse(self.path)
        path = unquote(u.path)
        qs = parse_qs(u.query)

        if path in ("/", "/index.html"):
            if not PORTAL_HTML.exists():
                return self._send(500, "门户页缺失".encode("utf-8"), "text/plain; charset=utf-8")
            return self._send(200, PORTAL_HTML.read_bytes(), "text/html; charset=utf-8")

        if path == "/api/health":
            # portal 字段用于让启动器识别"这是我们自己的服务"，
            # 避免把别的程序（例如 8787 上的 New API）误当成本地门户复用。
            return self._json({"ok": True, "portal": "workbench", "version": 1, "root": str(ROOT)})

        if path == "/api/launch":
            app = (qs.get("app") or [""])[0]
            try:
                ok, msg, url = launch(app)
            except Exception as exc:
                return self._json({"ok": False, "msg": f"{type(exc).__name__}: {exc}"}, 500)
            return self._json({"ok": ok, "msg": msg, "url": url}, 200 if ok else 500)

        # ---- 静态文件（白名单）----
        rel = path.lstrip("/")
        if not rel:
            return self._send(404, b"not found", "text/plain; charset=utf-8")
        target = (ROOT / rel).resolve()
        try:
            target.relative_to(ROOT)
        except ValueError:
            return self._send(403, b"forbidden", "text/plain; charset=utf-8")
        parts = target.relative_to(ROOT).parts
        if parts and (parts[0] in ("apps", ".git", "docs") or parts[0].startswith("_")):
            return self._send(403, b"forbidden", "text/plain; charset=utf-8")
        if target.suffix.lower() not in ALLOWED_SUFFIX or not target.is_file():
            return self._send(404, b"not found", "text/plain; charset=utf-8")
        ctype = mimetypes.guess_type(str(target))[0] or "application/octet-stream"
        if ctype.startswith("text/") or ctype == "application/javascript":
            ctype += "; charset=utf-8"
        return self._send(200, target.read_bytes(), ctype)


def main() -> None:
    global DRY_RUN
    import argparse
    ap = argparse.ArgumentParser(description="工作台门户服务")
    ap.add_argument("--port", type=int, default=8770)
    ap.add_argument("--dry-run", action="store_true", help="只返回将要做的事，不真正启动应用")
    args = ap.parse_args()
    DRY_RUN = bool(args.dry_run)

    srv = ThreadingHTTPServer(("127.0.0.1", args.port), Handler)
    print(f"portal server: http://127.0.0.1:{args.port}/")
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
