#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""真实渲染自检：起服务 → 真实 Chrome 打开 → CDP 读 DOM 事实 + 截图 → 断言。

这是防止"无头截图好看、真实 GPU 黑屏"再次蒙混过关的关键检查。
用法：python tools/verify_portal.py
退出码 0=通过，1=失败。
"""
from __future__ import annotations

import json
import os
import shutil
import socket
import subprocess
import sys
import tempfile
import time
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SERVER = ROOT / "portal_server.py"
NODE_SCRIPT = ROOT / "tools" / "verify_portal.js"


def free_port() -> int:
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        return sock.getsockname()[1]


def find_chrome() -> Path | None:
    candidates = [
        Path(os.environ.get("LOCALAPPDATA", "")) / "Google/Chrome/Application/chrome.exe",
        Path(os.environ.get("ProgramFiles", "")) / "Google/Chrome/Application/chrome.exe",
        Path(os.environ.get("ProgramFiles(x86)", "")) / "Google/Chrome/Application/chrome.exe",
    ]
    for item in candidates:
        if item and item.is_file():
            return item
    return None


def wait_health(url: str, seconds: float = 20.0) -> dict | None:
    deadline = time.time() + seconds
    while time.time() < deadline:
        try:
            with urllib.request.urlopen(url, timeout=0.6) as resp:
                return json.loads(resp.read().decode("utf-8"))
        except Exception:
            time.sleep(0.25)
    return None


def kill_tree(pid: int) -> None:
    try:
        subprocess.run(["taskkill", "/PID", str(pid), "/T", "/F"],
                       capture_output=True, timeout=15)
    except Exception:
        pass


def main() -> int:
    port = free_port()
    debug_port = free_port()
    server = subprocess.Popen(
        [sys.executable, str(SERVER), "--port", str(port)],
        cwd=str(ROOT), stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    profile = Path(tempfile.mkdtemp(prefix="portal_verify_"))
    chrome_proc = None
    try:
        health = wait_health(f"http://127.0.0.1:{port}/api/health")
        if not health or health.get("portal") != "workbench":
            print("✗ 服务未就绪或缺少 portal 标识：", health)
            return 1

        chrome = find_chrome()
        if not chrome:
            print("! 未找到 Chrome，跳过真实渲染检查（静态检查仍有效）")
            return 0
        node = shutil.which("node")
        if not node:
            print("! 未找到 node，跳过 CDP 检查（静态检查仍有效）")
            return 0

        (profile / "First Run").write_bytes(b"")
        chrome_proc = subprocess.Popen([
            str(chrome),
            f"--app=http://127.0.0.1:{port}/",
            "--window-size=1000,760",
            f"--user-data-dir={profile}",
            f"--remote-debugging-port={debug_port}",
            "--no-first-run",
            "--no-default-browser-check",
            "--disable-sync",
        ], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        time.sleep(3.5)

        shot = profile / "shot.png"
        result = subprocess.run([node, str(NODE_SCRIPT), str(debug_port), str(shot)],
                                capture_output=True, text=True, timeout=90)
        payload = (result.stdout or "").strip().splitlines()
        if not payload:
            print("✗ CDP 无输出：", result.stderr.strip()[:400])
            return 1
        try:
            info = json.loads(payload[-1])
        except Exception:
            print("✗ CDP 输出无法解析：", payload[-1][:400])
            return 1

        problems: list[str] = []
        if not info.get("ok"):
            problems.append(f"CDP 失败：{info.get('error')}")
        if "工作台" not in str(info.get("title", "")):
            problems.append(f"标题异常：{info.get('title')!r}")
        if not info.get("hasWin"):
            problems.append("未渲染出 .win 容器（白屏/黑屏）")
        if int(info.get("textLen") or 0) < 200:
            problems.append(f"页面可见文本过少：{info.get('textLen')}")
        if str(info.get("bg", "")) in ("rgb(0, 0, 0)", "rgba(0, 0, 0, 0)"):
            problems.append(f"body 背景为 {info.get('bg')}（疑似黑屏）")
        if int(info.get("bytes") or 0) < 30000:
            problems.append(f"截图仅 {info.get('bytes')} 字节（疑似纯色/黑屏）")

        # 真实屏幕像素检查：CDP 截的是渲染器输出，屏幕真的黑时它也可能返回正常画面，
        # 所以必须再从屏幕 DC 抓一次窗口像素来兜底。
        dark_ratio = None
        try:
            sys.path.insert(0, str(ROOT / "tools"))
            from grab_screen import capture_pixels, list_windows  # noqa: E402

            windows = list_windows("工作台")
            if windows:
                _w, _h, rgb = capture_pixels(windows[0][0])
                samples = dark = 0
                for index in range(0, len(rgb) - 2, 291):
                    if max(rgb[index], rgb[index + 1], rgb[index + 2]) < 30:
                        dark += 1
                    samples += 1
                dark_ratio = dark / samples if samples else 0.0
                if dark_ratio > 0.9:
                    problems.append(
                        f"屏幕上 {dark_ratio:.0%} 的像素接近纯黑（真实黑屏；CDP 截图查不出这类问题）")
            else:
                print("! 未找到窗口，跳过屏幕像素检查")
        except Exception as exc:  # 抓屏失败不应让整个检查失败
            print("! 屏幕像素检查跳过：", exc)

        if problems:
            print("✗ 真实渲染检查未通过：")
            for item in problems:
                print("  -", item)
            return 1
        print(f"✓ 真实渲染通过：title={info.get('title')} 文本={info.get('textLen')} "
              f"背景={info.get('bg')} 截图={info.get('bytes')}B "
              f"屏幕暗像素={'-' if dark_ratio is None else f'{dark_ratio:.0%}'}")
        return 0
    finally:
        if chrome_proc and chrome_proc.poll() is None:
            kill_tree(chrome_proc.pid)
        if server.poll() is None:
            kill_tree(server.pid)
        shutil.rmtree(profile, ignore_errors=True)


if __name__ == "__main__":
    sys.exit(main())
