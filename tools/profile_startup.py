#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""启动耗时剖析：把"双击 → 能进工作台"拆成阶段，找出真正的瓶颈。

做法：完全按桌面快捷方式的方式调 powershell 跑 launcher.ps1，然后解析
portal_launcher.log 里的 [+xx.xs] 标记，换算成阶段耗时。

用法：
    python tools/profile_startup.py            # 热启动（profile 已存在，等价于平时点）
    python tools/profile_startup.py --cold     # 冷启动（清空 profile / 杀干净 chrome）
    python tools/profile_startup.py --runs 3   # 连跑 3 次取中位数
"""
from __future__ import annotations

import re
import shutil
import subprocess
import statistics
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
LAUNCHER = ROOT / "launcher.ps1"
LOG = ROOT / "portal_launcher.log"
PROFILE = Path.home() / "AppData" / "Local" / "DianGongHouWorkbench" / "ChromeApp"

MARK = re.compile(r"\[\+\s*([\d.]+)s\]\s*(.*)")

# 关键阶段：日志关键字 -> 阶段名（按出现顺序取第一次）
PHASES = [
    ("已拉起门户服务", "① 拉起本地服务（含复用判断）"),
    ("复用已在运行的门户", "① 拉起本地服务（含复用判断）"),
    ("门户已就绪", "② 等本地服务监听端口"),
    ("窗口已出现", "③ 启动浏览器 → 窗口出现"),
    ("页面加载=True", "④ 页面加载完成（标题变为工作台）"),
    ("渲染正常", "⑤ 像素自检（确认不是黑屏）"),
]


def kill_chrome() -> None:
    subprocess.run(["powershell", "-NoProfile", "-Command",
                    "Get-Process chrome -ErrorAction SilentlyContinue | "
                    "Where-Object { $_.MainWindowTitle -like '*工作台*' } | "
                    "ForEach-Object { Stop-Process -Id $_.Id -Force -ErrorAction SilentlyContinue }"],
                   capture_output=True)
    time.sleep(1.5)


def run_once(cold: bool) -> dict:
    if cold and PROFILE.exists():
        kill_chrome()
        shutil.rmtree(PROFILE, ignore_errors=True)
    if LOG.exists():
        LOG.unlink()

    started = time.time()
    subprocess.run(["powershell", "-NoProfile", "-STA", "-ExecutionPolicy", "Bypass",
                    "-WindowStyle", "Hidden", "-File", str(LAUNCHER)],
                   capture_output=True, timeout=300)
    total = time.time() - started

    text = LOG.read_text(encoding="utf-8-sig") if LOG.exists() else ""
    marks: dict[str, float] = {}
    self_total = None
    for line in text.splitlines():
        found = MARK.search(line)
        if not found:
            continue
        elapsed, message = float(found.group(1)), found.group(2)
        if "总耗时" in message:
            self_total = elapsed
        for keyword, name in PHASES:
            if keyword in message and name not in marks:
                marks[name] = elapsed
    ordered = sorted(marks.items(), key=lambda kv: kv[1])
    return {"total": total, "self": self_total, "phases": ordered, "log": text}


def report(runs: list[dict]) -> int:
    totals = [r["total"] for r in runs]
    selfs = [r["self"] for r in runs if r["self"] is not None]
    print("\n================ 启动耗时剖析 ================")
    print(f"样本数 {len(runs)}    总耗时 中位数 {statistics.median(totals):.2f}s"
          f"    最快 {min(totals):.2f}s    最慢 {max(totals):.2f}s")
    if selfs:
        median_self = statistics.median(selfs)
        median_total = statistics.median(totals)
        print(f"  启动器内部计时 中位数 {median_self:.2f}s"
              f"    进程启动/退出开销 {median_total - median_self:.2f}s")

    names = list(dict.fromkeys(name for _, name in PHASES))  # 去重且保序
    per_phase: dict[str, list[float]] = {name: [] for name in names}
    for run in runs:
        previous = 0.0
        for name, elapsed in run["phases"]:
            per_phase[name].append(elapsed - previous)
            previous = elapsed

    print("\n阶段耗时（中位数）：")
    print(f"  {'阶段':<34}{'耗时':>8}{'占比':>9}")
    print("  " + "-" * 50)
    median_total = statistics.median(totals)
    for name in names:
        values = per_phase[name]
        if not values:
            print(f"  {name:<34}{'—':>8}{'—':>9}")
            continue
        value = statistics.median(values)
        print(f"  {name:<34}{value:>7.2f}s{value / median_total * 100:>8.0f}%")
    print("  " + "-" * 50)
    phase_sum = sum(statistics.median(v) for v in per_phase.values() if v)
    print(f"  {'阶段合计':<34}{phase_sum:>7.2f}s")
    if selfs:
        residual = statistics.median(selfs) - phase_sum
        print(f"  {'日志未覆盖（互斥锁/路径解析/收尾）':<34}{residual:>7.2f}s")

    slowest = max(((statistics.median(v), k) for k, v in per_phase.items() if v), default=(0, ""))
    print(f"\n首要瓶颈：{slowest[1]}（{slowest[0]:.2f}s）")
    return 0


def main() -> int:
    args = sys.argv[1:]
    cold = "--cold" in args
    runs = 3 if "--runs" in args else 1
    if "--runs" in args:
        index = args.index("--runs")
        if index + 1 < len(args):
            runs = max(1, int(args[index + 1]))

    print(f"模式：{'冷启动' if cold else '热启动'}，跑 {runs} 次")
    samples = []
    for index in range(runs):
        result = run_once(cold=cold)
        samples.append(result)
        print(f"  第 {index + 1} 次：{result['total']:.2f}s")
        if index + 1 < runs:
            kill_chrome()
    return report(samples)


if __name__ == "__main__":
    sys.exit(main())
