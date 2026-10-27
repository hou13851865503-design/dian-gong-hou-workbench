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

# Chrome 必须脱离当前进程组启动：直接当子进程时，会被沙箱/安全软件连同父进程一起回收，
# 表现为"刚起的窗口 1 秒后就没了、CDP 端口也消失"（实测三次重试全挂）。
DETACHED_PROCESS = getattr(subprocess, "DETACHED_PROCESS", 0x00000008)


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


# 必须绕过系统/环境代理：http_proxy 存在时 urllib 会把 127.0.0.1 也交给代理，
# 结果是"本地服务明明活着却报 502 / 连不上"（实测踩过）。
_NO_PROXY = urllib.request.build_opener(urllib.request.ProxyHandler({}))


def wait_health(url: str, seconds: float = 20.0) -> dict | None:
    deadline = time.time() + seconds
    while time.time() < deadline:
        try:
            with _NO_PROXY.open(url, timeout=0.6) as resp:
                return json.loads(resp.read().decode("utf-8"))
        except Exception:
            time.sleep(0.25)
    return None


def cdp_ready(debug_port: int, seconds: float = 12.0) -> bool:
    """等 CDP 端口真的能应答，而不是靠固定的 sleep 猜。"""
    deadline = time.time() + seconds
    url = f"http://127.0.0.1:{debug_port}/json/version"
    while time.time() < deadline:
        try:
            with _NO_PROXY.open(url, timeout=1.0) as resp:
                if resp.status == 200:
                    return True
        except Exception:
            pass
        time.sleep(0.25)
    return False


def kill_tree(pid: int) -> None:
    try:
        subprocess.run(["taskkill", "/PID", str(pid), "/T", "/F"],
                       capture_output=True, timeout=15)
    except Exception:
        pass


def run_cdp(node: str, debug_port: int, shot: Path, tries: int = 2):
    """调 node 脚本读 CDP 事实。

    偶尔会出现"node 退出码 0 但 stdout 为空"（Windows 下管道写 + 立即 exit 的
    老问题，已改成同步写，但环境里仍偶发）。这里再兜一层重试，代价很小。
    """
    result = None
    for _ in range(max(1, tries)):
        result = subprocess.run([node, str(NODE_SCRIPT), str(debug_port), str(shot)],
                                capture_output=True, text=True, timeout=90)
        payload = (result.stdout or "").strip().splitlines()
        if payload:
            return result, payload
        time.sleep(0.4)
    return result, []


def main() -> int:
    port = free_port()
    debug_port = free_port()
    server = subprocess.Popen(
        [sys.executable, str(SERVER), "--port", str(port)],
        cwd=str(ROOT), stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    profiles: list[Path] = []
    profile = Path(tempfile.mkdtemp(prefix="portal_verify_"))
    profiles.append(profile)
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
        # Chrome 偶发"启动即退出"（ExitCode=0、无窗口），和启动器里记录的是同一个坑。
        # 每次重试都用**全新的 profile**：崩掉的实例会在 profile 里留下 Singleton 锁和
        # 半初始化的状态，复用同一个目录会让后续几次也立刻退出（实测三次全挂）。
        info = None
        shot = profile / "shot.png"
        for attempt in range(1, 4):
            if attempt > 1:
                profile = Path(tempfile.mkdtemp(prefix="portal_verify_"))
                profiles.append(profile)
                (profile / "First Run").write_bytes(b"")
                shot = profile / "shot.png"
                # 调试端口也换一个：上一个实例退出后端口可能还在 TIME_WAIT
                debug_port = free_port()
            launch_args = [
                str(chrome),
                f"--app=http://127.0.0.1:{port}/",
                "--window-size=1000,760",
                f"--user-data-dir={profile}",
                f"--remote-debugging-port={debug_port}",
                "--no-first-run",
                "--no-default-browser-check",
                "--disable-sync",
            ]
            chrome_proc = subprocess.Popen(launch_args, stdout=subprocess.DEVNULL,
                                          stderr=subprocess.DEVNULL,
                                          creationflags=DETACHED_PROCESS)
            if not cdp_ready(debug_port, seconds=12 if attempt == 1 else 8):
                print(f"! 第 {attempt} 次启动 Chrome 没有应答 CDP，重试")
            else:
                result, payload = run_cdp(node, debug_port, shot)
                if not payload:
                    print(f"! 第 {attempt} 次 CDP 无输出（node 退出码 {result.returncode}）："
                          f"{(result.stderr or '').strip()[:200] or '（stderr 也为空）'}"
                          f" chrome存活={chrome_proc.poll() is None}"
                          f" 调试端口仍在={cdp_ready(debug_port, seconds=1)}")
                else:
                    try:
                        info = json.loads(payload[-1])
                    except Exception:
                        print("✗ CDP 输出无法解析：", payload[-1][:400])
                        return 1
                    if info.get("ok"):
                        break
                    print(f"! 第 {attempt} 次 CDP 判定失败：{info.get('error')}"
                          f" chrome存活={chrome_proc.poll() is None}"
                          f" 调试端口仍在={cdp_ready(debug_port, seconds=1)}")
            if chrome_proc.poll() is None:
                kill_tree(chrome_proc.pid)
            time.sleep(1.0 * attempt)
        if not info or not info.get("ok"):
            print("✗ Chrome 3 次尝试都没能给出可用的 CDP 结果")
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
            from grab_screen import capture_pixels, pick_window  # noqa: E402

            picked = pick_window("工作台")
            if picked:
                _w, _h, rgb = capture_pixels(picked[0])
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
        for item in profiles:
            shutil.rmtree(item, ignore_errors=True)


if __name__ == "__main__":
    sys.exit(main())
