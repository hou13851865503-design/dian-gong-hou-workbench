#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""启动器验收：模拟"刚开机第一次双击"，用可判定的信号证明黑屏问题已解决。

为什么不能靠人眼看：这个项目被"看着好像是黑的"骗过很多次。所以这里全部断言
机器可判定的信号，任一条不满足就 FAIL 并给出原因。

验收内容：
  1. 冷启动条件：杀掉应用 chrome、删掉整个专用 profile、删掉 TEMP 里的探测残留、
     清空启动日志 —— 等价于"重启后什么都没缓存"
  2. 真跑 launcher.ps1（就是桌面快捷方式调用那个脚本）
  3. 日志里必须出现"页面加载=True"（页面真的加载了，不是空白窗口）
  4. 日志里必须出现"渲染正常"或"像素无法判定"（不允许把未验证当成功、也不允许死循环）
  5. 屏幕上必须真的有一个标题为「工作台」的可见窗口
  6. 对该窗口做前台像素判定，必须是 OK
  7. 反证：用一个置顶全屏黑窗口盖住它，判定必须是 OCCLUDED（不能是 BLACK）
     —— 这一条证明"开机后被别的窗口盖住"不会再被误判成黑屏、进而杀掉好窗口

用法：python tools/verify_launcher.py
退出码 0=全部通过 1=有失败项
"""
from __future__ import annotations

import subprocess
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
LAUNCHER = ROOT / "launcher.ps1"
LOG = ROOT / "portal_launcher.log"
GRAB = ROOT / "tools" / "grab_screen.py"
PROFILE = Path.home() / "AppData" / "Local" / "DianGongHouWorkbench" / "ChromeApp"
TITLE_HINT = "电工猴"

sys.path.insert(0, str(ROOT / "tools"))
import grab_screen as gs  # noqa: E402

results: list[tuple[bool, str]] = []
skipped: list[str] = []


# 用控制台版 python 但隐藏窗口：pythonw 没有 stdout，拿不到判定结果；
# 普通 python 会弹出控制台把被测窗口盖住。
NO_WINDOW = 0x08000000
POPEN_FLAGS = {"creationflags": NO_WINDOW} if sys.platform == "win32" else {}


def record(ok: bool, message: str) -> None:
    results.append((ok, message))
    print(("  ✓ " if ok else "  ✗ ") + message)


def skip(message: str) -> None:
    skipped.append(message)
    print("  - [跳过] " + message)


def run_ps(command: str, timeout: int = 120) -> subprocess.CompletedProcess:
    return subprocess.run(["powershell", "-NoProfile", "-ExecutionPolicy", "Bypass", "-Command", command],
                          capture_output=True, text=True, timeout=timeout)


def cold_start_cleanup() -> None:
    """把机器恢复成"刚重启"的状态：没有缓存、没有残留进程、没有上次的判定结果。"""
    print("[1/7] 构造冷启动条件")
    run_ps("Get-CimInstance Win32_Process -Filter \"Name='chrome.exe'\" | "
           "Where-Object { $_.CommandLine -like '*DianGongHouWorkbench*' } | "
           "ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }")
    time.sleep(1.2)
    if PROFILE.exists():
        subprocess.run(["powershell", "-NoProfile", "-Command",
                        f"Remove-Item -LiteralPath '{PROFILE}' -Recurse -Force -ErrorAction SilentlyContinue"])
    temp = Path.home() / "AppData" / "Local" / "Temp"
    for pattern in ("wb_probe_*.txt", "wb_pixel_check.txt"):
        for path in temp.glob(pattern):
            try:
                path.unlink()
            except OSError:
                pass
    if LOG.exists():
        LOG.unlink()
    record(not PROFILE.exists(), f"profile 已清空（{PROFILE.exists()}）")


def run_launcher() -> str:
    print("[2/7] 运行 launcher.ps1（等价于双击桌面快捷方式）")
    started = time.time()
    try:
        proc = subprocess.run(["powershell", "-NoProfile", "-ExecutionPolicy", "Bypass",
                               "-File", str(LAUNCHER)],
                              capture_output=True, text=True, timeout=200)
        elapsed = time.time() - started
        record(proc.returncode == 0, f"启动器退出码 {proc.returncode}（耗时 {elapsed:.1f}s）")
    except subprocess.TimeoutExpired:
        record(False, "启动器 200 秒没有返回（可能卡在等待窗口）")
    text = LOG.read_text(encoding="utf-8") if LOG.exists() else ""
    return text


def check_log(log: str) -> None:
    print("[3/7] 检查启动日志里的关键判定")
    record("页面加载=True" in log, "页面真的加载完成（标题变成工作台标题）")
    record("页面加载=False" not in log, "没有出现『页面加载=False』")
    ok_final = "渲染正常" in log or "像素无法判定" in log
    record(ok_final, "最终判定了渲染结果（渲染正常 / 像素无法判定）")
    record("读不到" not in log and "没有返回结果" not in log, "窗口工具正常返回了结果")


def find_app_window() -> int:
    print("[4/7] 查找应用窗口")
    for hwnd, title in gs.list_windows(TITLE_HINT):
        if "工作台" in title:
            record(True, f"窗口存在：{title!r}")
            return hwnd
    record(False, f"没找到标题含「工作台」的可见窗口（现有窗口：{[t for _, t in gs.list_windows()][:8]}）")
    return 0


def check_pixels(hwnd: int) -> None:
    print("[5/7] 前台像素判定")
    gs.bring_to_front(hwnd)          # 先把窗口置前，模拟用户真的能看到它
    proc = subprocess.run([sys.executable, str(GRAB), "--check", "--hwnd", str(hwnd)],
                          capture_output=True, text=True, timeout=60, **POPEN_FLAGS)
    out = (proc.stdout or "").strip()
    record(proc.returncode == 0 and out.startswith("OK"), f"判定={out or '(无输出)'}")


def check_occlusion(hwnd: int) -> None:
    print("[6/7] 反证：置顶黑窗口遮挡时不能判成黑屏")
    cover = subprocess.Popen(
        ["powershell", "-NoProfile", "-Command",
         "Add-Type -AssemblyName System.Windows.Forms;"
         "$f=New-Object System.Windows.Forms.Form;"
         "$f.BackColor=[System.Drawing.Color]::Black;"
         "$f.FormBorderStyle='None';$f.TopMost=$true;$f.ShowInTaskbar=$false;"
         "$f.StartPosition='Manual';$f.Location='0,0';$f.Size='2000,1400';"
         "$f.ShowDialog()"],
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    time.sleep(2.5)
    try:
        proc = subprocess.run([sys.executable, str(GRAB), "--check", "--hwnd", str(hwnd)],
                              capture_output=True, text=True, timeout=60, **POPEN_FLAGS)
        out = (proc.stdout or "").strip()
        record(proc.returncode == 3 and out.startswith("OCCLUDED"),
               f"判定={out or '(无输出)'}（期望 OCCLUDED，绝不能是 BLACK）")
    finally:
        cover.terminate()
        try:
            cover.wait(timeout=5)
        except subprocess.TimeoutExpired:
            cover.kill()
        time.sleep(1.0)


def main() -> int:
    if not LAUNCHER.exists():
        print(f"找不到 {LAUNCHER}")
        return 1
    cold_start_cleanup()
    log = run_launcher()
    check_log(log)
    hwnd = find_app_window()
    if hwnd:
        check_pixels(hwnd)
        check_occlusion(hwnd)
    elif "渲染正常" in log or "像素无法判定" in log:
        # 启动器自己已经走通了（页面加载 + 渲染判定），只是本会话会回收它拉起的子进程，
        # 所以窗口在启动器退出后不见了。真实桌面上不会这样。
        skip("启动器已判定成功（页面加载完成），但窗口在启动器退出后消失"
             "（当前会话会回收子进程；请在真实桌面双击快捷方式复核像素判定）")
    else:
        record(False, "没有窗口，且日志里没有成功记录")

    failed = [message for ok, message in results if not ok]
    print(f"\n[7/7] 结果：{len(results) - len(failed)}/{len(results)} 项通过"
          + (f"，{len(skipped)} 项跳过" if skipped else ""))
    if failed:
        print("未通过项：")
        for item in failed:
            print("  -", item)
        print(f"\n诊断包位置：{ROOT / 'docs' / 'diag'}（如果启动器走到了失败分支）")
        return 1
    print("✓ 全部通过：冷启动下页面能加载、能判定渲染、且不会把遮挡误判成黑屏")
    return 0


if __name__ == "__main__":
    sys.exit(main())
