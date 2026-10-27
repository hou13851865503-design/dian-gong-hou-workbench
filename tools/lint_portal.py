#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""门户静态守卫：把"踩过的坑"变成可执行检查。

运行：python tools/lint_portal.py
退出码 0=全部通过，1=发现问题。

检查项（每条都对应一次真实故障）：
  1. 页面禁用全屏 filter:blur / backdrop-filter / background-attachment:fixed
     —— 会让真实 GPU 整屏黑（无头截图看不出来）。
  2. portal_server 的健康检查必须带 portal 标识
     —— 否则启动器会把别人的本地服务误认成门户。
  3. 启动器必须校验门户身份、必须验证窗口真的起来、不得使用 --disable-gpu
     —— --disable-gpu 会让 Chrome 启动即退出（--disable-gpu-compositing 不受限）。
  4. launcher.ps1 必须是 UTF-8 BOM + CRLF
     —— 否则 PowerShell 5.1 读中文乱码。
  5. 不得出现 `| Remove-Item -Force`（管道无输入会报 missing path operand 并中断流程）。
  6. 启动器必须：单实例互斥、按句柄判定、等页面标题加载、profile 自愈、失败存诊断包、
     像素探测用唯一临时文件 —— 这几条分别对应"双击两次互相杀窗口"、"抓到别的窗口"、
     "页面没加载被当成黑屏"、"profile 损坏打开空白窗口"、"黑屏后无从排查"、"读到上次结果"。
  7. 窗口工具（grab_screen.py）的每个子命令都要在限定时间内写出结果文件
     —— 脚本里任何一处抛异常都会导致启动器白等到超时，用户看到的就是"启动卡很久"。
"""
from __future__ import annotations

import re
import subprocess
import sys
import tempfile
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
PORTAL_HTML = ROOT / "电工猴的此思妙想工作台.html"
PORTAL_SERVER = ROOT / "portal_server.py"
LAUNCHER = ROOT / "launcher.ps1"
GRAB_TOOL = ROOT / "tools" / "grab_screen.py"

CSS_BANS = [
    (r"filter\s*:\s*blur\(", "全屏/图层 filter:blur 在部分 GPU 上整屏黑"),
    (r"backdrop-filter\s*:", "backdrop-filter 依赖合成层，易黑屏"),
    (r"background-attachment\s*:\s*fixed", "fixed 背景会触发合成/滚动异常"),
]


def check_portal_css(problems: list[str]) -> None:
    text = PORTAL_HTML.read_text(encoding="utf-8")
    for pattern, why in CSS_BANS:
        for m in re.finditer(pattern, text, re.I):
            line = text[: m.start()].count("\n") + 1
            problems.append(f"{PORTAL_HTML.name}:{line} 命中 `{pattern}` → {why}")


def check_server_marker(problems: list[str]) -> None:
    text = PORTAL_SERVER.read_text(encoding="utf-8")
    if '"portal": "workbench"' not in text:
        problems.append(f"{PORTAL_SERVER.name}: /api/health 缺少 portal 标识，启动器无法识别服务身份")
    # Windows 的 SO_REUSEADDR 允许第二个进程绑同一端口 → 会静默起两个服务。
    # 所以必须用关掉 allow_reuse_address 的子类来构造服务，不能直接用 ThreadingHTTPServer。
    if re.search(r"srv\s*=\s*ThreadingHTTPServer\(", text):
        problems.append(f"{PORTAL_SERVER.name}: 直接用 ThreadingHTTPServer 绑定端口，"
                        "Windows 的 SO_REUSEADDR 会让第二个进程也绑成功（应改用 PortalServer）")
    if "allow_reuse_address" not in text:
        problems.append(f"{PORTAL_SERVER.name}: 没有显式关闭 allow_reuse_address，端口会失去独占性")


def code_lines(path: Path, encoding: str = "utf-8-sig"):
    """只产出非注释行（注释里提到禁用项不算违规）。"""
    for number, line in enumerate(path.read_text(encoding=encoding).splitlines(), 1):
        if line.strip().startswith("#"):
            continue
        yield number, line


LAUNCHER_REQUIRED = [
    ("Open-ChromeWindow", "打开窗口后没有验证是否成功（并且要能识别『Chrome 启动即退出』）"),
    ("data.portal", "缺少门户身份校验（data.portal），可能误复用其他服务端口"),
    ("Local\\DianGongHouWorkbenchLauncher", "缺少单实例互斥，双击两次会互相杀掉对方的窗口"),
    ("--hwnd", "像素判定没有按窗口句柄，可能抓到别的窗口（如桌宠）"),
    ("Wait-PageLoaded", "缺少页面加载判定，页面没加载会被误当成黑屏"),
    ("Initialize-ChromeProfile", "缺少 profile 自愈，状态文件损坏会打开空白窗口"),
    ("Save-Diagnostics", "失败时没有保存诊断包，黑屏无从排查"),
    ("[guid]::NewGuid()", "临时结果文件不是唯一命名，可能读到上一次的残留结果"),
]


def check_launcher(problems: list[str]) -> None:
    text = LAUNCHER.read_text(encoding="utf-8-sig")
    for token, why in LAUNCHER_REQUIRED:
        if token not in text:
            problems.append(f"{LAUNCHER.name}: {why}")
    for number, line in code_lines(LAUNCHER):
        # 只禁 --disable-gpu 本身（会让 Chrome 启动即退出）；
        # --disable-gpu-compositing 是黑屏时的软件合成降级手段，允许使用。
        if re.search(r"--disable-gpu(?![\w-])", line):
            problems.append(f"{LAUNCHER.name}:{number} 使用 --disable-gpu（会导致 Chrome 启动即退出）")
        if re.search(r"\|\s*Remove-Item\s+-Force", line):
            problems.append(f"{LAUNCHER.name}:{number} 使用 `| Remove-Item -Force`，无匹配项会中断流程，应改用 ForEach-Object")
        if "wb_pixel_check.txt" in line:
            problems.append(f"{LAUNCHER.name}:{number} 使用固定临时文件名，会读到上一次的黑屏判定结果")


def check_launcher_encoding(problems: list[str]) -> None:
    raw = LAUNCHER.read_bytes()
    if not raw.startswith(b"\xef\xbb\xbf"):
        problems.append(f"{LAUNCHER.name}: 缺少 UTF-8 BOM（PowerShell 5.1 会把中文读成乱码）")
    head = raw[:4096]
    if b"\r\n" not in head:
        problems.append(f"{LAUNCHER.name}: 换行不是 CRLF")


def check_grab_tool(problems: list[str]) -> None:
    """冒烟测试：每个子命令都必须在限定时间内写出结果文件。

    这条对应一次真实故障：--settle 只在某个分支里赋值，换个分支就是
    未定义变量 → 脚本崩溃 → 不写结果文件 → 启动器干等 20 秒超时。
    静态扫描看不出来，只有真跑一遍才能发现。
    """
    if not GRAB_TOOL.exists():
        problems.append("tools/grab_screen.py 不存在")
        return
    cases = [
        ["--check", "--hwnd", "0", "--settle", "0.2"],
        ["--check", "--hwnd", "0"],
        ["--wait-window", "--pid", "0", "--hint", "不存在的窗口名", "--timeout", "1"],
        ["--wait-title", "--hwnd", "0", "--hint", "不存在的窗口名", "--timeout", "1"],
        ["--focus", "--hwnd", "0"],
    ]
    for case in cases:
        out_file = Path(tempfile.mkdtemp(prefix="wb_lint_")) / "r.txt"
        started = time.time()
        try:
            subprocess.run([sys.executable, str(GRAB_TOOL), *case, "--out", str(out_file)],
                           capture_output=True, timeout=25)
        except subprocess.TimeoutExpired:
            problems.append(f"grab_screen {' '.join(case)} 超过 25 秒没有退出（会让启动器卡死）")
            continue
        elapsed = time.time() - started
        if not out_file.exists():
            problems.append(f"grab_screen {' '.join(case)} 没有写出结果文件（脚本抛异常，启动器只能等超时）")
            continue
        verdict = out_file.read_text(encoding="utf-8").strip()
        if verdict.startswith("TOOLFAIL"):
            problems.append(f"grab_screen {' '.join(case)} 出错：{verdict}")
        elif elapsed > 8:
            problems.append(f"grab_screen {' '.join(case)} 用了 {elapsed:.1f}s，超出启动预算")


def main() -> int:
    problems: list[str] = []
    check_portal_css(problems)
    check_server_marker(problems)
    check_launcher(problems)
    check_launcher_encoding(problems)
    check_grab_tool(problems)

    if problems:
        print("✗ 静态检查未通过：")
        for item in problems:
            print("  -", item)
        return 1
    print("✓ 静态检查通过（CSS 安全 / 服务标识 / 启动器流程 / 编码 / 窗口工具冒烟）")
    return 0


if __name__ == "__main__":
    sys.exit(main())
