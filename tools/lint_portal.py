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
     —— --disable-gpu 会让 Chrome 启动即退出。
  4. launcher.ps1 必须是 UTF-8 BOM + CRLF
     —— 否则 PowerShell 5.1 读中文乱码。
  5. 不得出现 `| Remove-Item -Force`（管道无输入会报 missing path operand 并中断流程）。
"""
from __future__ import annotations

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
PORTAL_HTML = ROOT / "电工猴的此思妙想工作台.html"
PORTAL_SERVER = ROOT / "portal_server.py"
LAUNCHER = ROOT / "launcher.ps1"

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


def code_lines(path: Path, encoding: str = "utf-8-sig"):
    """只产出非注释行（注释里提到禁用项不算违规）。"""
    for number, line in enumerate(path.read_text(encoding=encoding).splitlines(), 1):
        if line.strip().startswith("#"):
            continue
        yield number, line


def check_launcher(problems: list[str]) -> None:
    text = LAUNCHER.read_text(encoding="utf-8-sig")
    if "Wait-AppWindow" not in text:
        problems.append(f"{LAUNCHER.name}: 缺少 Wait-AppWindow，打开窗口后没有验证是否成功")
    if "data.portal" not in text:
        problems.append(f"{LAUNCHER.name}: 缺少门户身份校验（data.portal），可能误复用其他服务端口")
    for number, line in code_lines(LAUNCHER):
        if "--disable-gpu" in line:
            problems.append(f"{LAUNCHER.name}:{number} 使用 --disable-gpu（会导致 Chrome 启动即退出）")
        if re.search(r"\|\s*Remove-Item\s+-Force", line):
            problems.append(f"{LAUNCHER.name}:{number} 使用 `| Remove-Item -Force`，无匹配项会中断流程，应改用 ForEach-Object")


def check_launcher_encoding(problems: list[str]) -> None:
    raw = LAUNCHER.read_bytes()
    if not raw.startswith(b"\xef\xbb\xbf"):
        problems.append(f"{LAUNCHER.name}: 缺少 UTF-8 BOM（PowerShell 5.1 会把中文读成乱码）")
    head = raw[:4096]
    if b"\r\n" not in head:
        problems.append(f"{LAUNCHER.name}: 换行不是 CRLF")


def main() -> int:
    problems: list[str] = []
    check_portal_css(problems)
    check_server_marker(problems)
    check_launcher(problems)
    check_launcher_encoding(problems)

    if problems:
        print("✗ 静态检查未通过：")
        for item in problems:
            print("  -", item)
        return 1
    print("✓ 静态检查通过（CSS 安全 / 服务标识 / 启动器流程 / 编码）")
    return 0


if __name__ == "__main__":
    sys.exit(main())
