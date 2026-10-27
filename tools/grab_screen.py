#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""抓取指定窗口的"屏幕真实像素"，并区分「黑屏」和「压根没看到它」。

为什么需要它：Chrome DevTools 的 Page.captureScreenshot 截的是渲染器输出，
即使屏幕上是黑的它也可能返回正常画面。只有 BitBlt 屏幕 DC 才能拿到用户
真正看到的东西。

为什么还要判遮挡：BitBlt 是按窗口矩形从屏幕 DC 拷像素，如果窗口被别的窗口
盖住（开机后一堆自启程序抢焦点），拷到的就是覆盖窗口的内容——看着是黑的，
但页面本身没问题。所以先 SetForegroundWindow+置顶，再把"矩形中心点属于哪个
窗口"查清楚；不是自己的窗口就返回 OCCLUDED，让启动器不要据此杀进程。

用法：
    python tools/grab_screen.py                        # 列出可见窗口
    python tools/grab_screen.py 工作台 out.png          # 抓标题含"工作台"的窗口
    python tools/grab_screen.py --check --hwnd 12345 --out r.txt
    python tools/grab_screen.py --focus --hwnd 12345

--check 结果（写文件 + 标准输出）：
    OK ok       0% 1120x860     正常
    BLACK      98% 1120x860     窗口就在最前面，但整片是黑的
    OCCLUDED                    窗口不在最前/被盖住，无法判断
    NOWINDOW                    窗口不存在或不可见
退出码：0=OK 1=BLACK 2=NOWINDOW 3=OCCLUDED
"""
from __future__ import annotations

import ctypes
import ctypes.wintypes as wt
import struct
import sys
import time
import zlib
from pathlib import Path

user32 = ctypes.windll.user32
gdi32 = ctypes.windll.gdi32
kernel32 = ctypes.windll.kernel32
user32.SetProcessDPIAware()

# 64 位下必须声明返回值类型，否则 HWND 会被截断成 32 位，比较永远失败
user32.GetForegroundWindow.restype = wt.HWND
user32.WindowFromPoint.restype = wt.HWND
user32.GetAncestor.restype = wt.HWND

SRCCOPY = 0x00CC0020
DIB_RGB_COLORS = 0
SW_RESTORE = 9
HWND_TOPMOST = wt.HWND(-1)
HWND_NOTOPMOST = wt.HWND(-2)
SWP_NOSIZE = 0x0001
SWP_NOMOVE = 0x0002
GA_ROOT = 2


class BITMAPINFOHEADER(ctypes.Structure):
    _fields_ = [
        ("biSize", wt.DWORD), ("biWidth", wt.LONG), ("biHeight", wt.LONG),
        ("biPlanes", wt.WORD), ("biBitCount", wt.WORD), ("biCompression", wt.DWORD),
        ("biSizeImage", wt.DWORD), ("biXPelsPerMeter", wt.LONG),
        ("biYPelsPerMeter", wt.LONG), ("biClrUsed", wt.DWORD), ("biClrImportant", wt.DWORD),
    ]


class BITMAPINFO(ctypes.Structure):
    _fields_ = [("bmiHeader", BITMAPINFOHEADER), ("bmiColors", wt.DWORD * 3)]


def list_windows(keyword: str = ""):
    found = []
    proc = ctypes.WINFUNCTYPE(wt.BOOL, wt.HWND, wt.LPARAM)

    def callback(hwnd, _):
        length = user32.GetWindowTextLengthW(hwnd)
        if length and user32.IsWindowVisible(hwnd):
            buf = ctypes.create_unicode_buffer(length + 1)
            user32.GetWindowTextW(hwnd, buf, length + 1)
            title = buf.value
            if keyword in title:
                found.append((hwnd, title))
        return True

    user32.EnumWindows(proc(callback), 0)
    return found


def window_title(hwnd: int) -> str:
    length = user32.GetWindowTextLengthW(hwnd)
    if not length:
        return ""
    buf = ctypes.create_unicode_buffer(length + 1)
    user32.GetWindowTextW(hwnd, buf, length + 1)
    return buf.value


def bring_to_front(hwnd: int) -> bool:
    """置前 + 置顶闪一下 + 强制重画，尽量让窗口真的显示在用户眼前。"""
    if user32.IsIconic(hwnd):
        user32.ShowWindow(hwnd, SW_RESTORE)
    foreground = user32.GetForegroundWindow()
    if foreground != hwnd:
        # Windows 的前台锁：跨进程 SetForegroundWindow 通常会被忽略，
        # 借用当前前台线程的输入队列可以绕过。
        target_thread = user32.GetWindowThreadProcessId(foreground, None)
        this_thread = kernel32.GetCurrentThreadId()
        attached = user32.AttachThreadInput(this_thread, target_thread, True)
        user32.SetForegroundWindow(hwnd)
        user32.BringWindowToTop(hwnd)
        if attached:
            user32.AttachThreadInput(this_thread, target_thread, False)
    user32.SetWindowPos(hwnd, HWND_TOPMOST, 0, 0, 0, 0, SWP_NOMOVE | SWP_NOSIZE)
    user32.SetWindowPos(hwnd, HWND_NOTOPMOST, 0, 0, 0, 0, SWP_NOMOVE | SWP_NOSIZE)
    user32.InvalidateRect(hwnd, None, True)
    user32.UpdateWindow(hwnd)
    time.sleep(0.45)
    return user32.GetForegroundWindow() == hwnd


def occlusion_hits(hwnd: int) -> int:
    """9 宫格采样，统计有多少个点被别的窗口盖住（0~9）。

    只看中心点会被桌面小挂件之类的东西一票否决，所以要多点统计；
    真正被盖住时是整片都被盖住，命中数会很高。
    """
    rect = wt.RECT()
    if not user32.GetWindowRect(hwnd, ctypes.byref(rect)):
        return 9
    width, height = rect.right - rect.left, rect.bottom - rect.top
    if width <= 0 or height <= 0:
        return 9
    hits = 0
    for fx in (0.15, 0.5, 0.85):
        for fy in (0.15, 0.5, 0.85):
            point = wt.POINT(int(rect.left + width * fx), int(rect.top + height * fy))
            top = user32.WindowFromPoint(point)
            if not top or user32.GetAncestor(top, GA_ROOT) != hwnd:
                hits += 1
    return hits


def occluded(hwnd: int) -> bool:
    """命中 5 个及以上采样点就算被遮挡（半个窗口以上看不见）。"""
    return occlusion_hits(hwnd) >= 5


def capture_pixels(hwnd: int) -> tuple[int, int, bytes]:
    """把窗口当前显示的内容从屏幕 DC 拷出来（RGB 字节流）。"""
    if user32.IsIconic(hwnd):
        user32.ShowWindow(hwnd, SW_RESTORE)
    user32.SetForegroundWindow(hwnd)
    time.sleep(0.9)

    rect = wt.RECT()
    user32.GetWindowRect(hwnd, ctypes.byref(rect))
    width, height = rect.right - rect.left, rect.bottom - rect.top
    if width <= 0 or height <= 0:
        raise SystemExit("窗口尺寸无效")

    screen_dc = user32.GetDC(0)
    mem_dc = gdi32.CreateCompatibleDC(screen_dc)
    bitmap = gdi32.CreateCompatibleBitmap(screen_dc, width, height)
    gdi32.SelectObject(mem_dc, bitmap)
    gdi32.BitBlt(mem_dc, 0, 0, width, height, screen_dc, rect.left, rect.top, SRCCOPY)

    info = BITMAPINFO()
    info.bmiHeader.biSize = ctypes.sizeof(BITMAPINFOHEADER)
    info.bmiHeader.biWidth = width
    info.bmiHeader.biHeight = -height
    info.bmiHeader.biPlanes = 1
    info.bmiHeader.biBitCount = 32
    info.bmiHeader.biCompression = 0

    size = width * height * 4
    buffer = ctypes.create_string_buffer(size)
    gdi32.GetDIBits(mem_dc, bitmap, 0, height, buffer, ctypes.byref(info), DIB_RGB_COLORS)

    gdi32.DeleteObject(bitmap)
    gdi32.DeleteDC(mem_dc)
    user32.ReleaseDC(0, screen_dc)

    raw = buffer.raw
    rgb = bytearray(width * height * 3)
    for i in range(width * height):
        b, g, r = raw[i * 4], raw[i * 4 + 1], raw[i * 4 + 2]
        rgb[i * 3] = r
        rgb[i * 3 + 1] = g
        rgb[i * 3 + 2] = b
    return width, height, bytes(rgb)


def capture(hwnd: int, out_path: str) -> tuple[int, int]:
    width, height, rgb = capture_pixels(hwnd)
    write_png(out_path, width, height, rgb)
    return width, height


def write_png(path: str, width: int, height: int, rgb: bytes) -> None:
    stride = width * 3
    raw = b"".join(b"\x00" + rgb[y * stride:(y + 1) * stride] for y in range(height))

    def chunk(tag: bytes, data: bytes) -> bytes:
        return (struct.pack(">I", len(data)) + tag + data
                + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF))

    png = b"\x89PNG\r\n\x1a\n"
    png += chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0))
    png += chunk(b"IDAT", zlib.compress(raw, 6))
    png += chunk(b"IEND", b"")
    with open(path, "wb") as stream:
        stream.write(png)


def dark_ratio(rgb: bytes) -> float:
    samples = dark = 0
    for index in range(0, len(rgb) - 2, 291):
        if max(rgb[index], rgb[index + 1], rgb[index + 2]) < 30:
            dark += 1
        samples += 1
    return dark / samples if samples else 0.0


def emit(result: str, code: int, out_file: str | None) -> int:
    # 先写结果文件：pythonw 下 sys.stdout 为 None，print 会抛异常
    if out_file:
        try:
            Path(out_file).write_text(result, encoding="utf-8")
        except OSError:
            pass
    try:
        print(result)
    except Exception:
        pass
    return code


def check_window(hwnd: int, out_file: str | None, attempts: int = 3) -> int:
    if not hwnd or not user32.IsWindowVisible(hwnd):
        return emit("NOWINDOW 0% 0x0", 2, out_file)
    # 采样期间可能被别的窗口抢一下前台，重试几次即可；
    # 只有在"确实在最前"的时候采到的像素才算证据。
    for attempt in range(1, attempts + 1):
        bring_to_front(hwnd)
        if user32.GetForegroundWindow() != hwnd:
            time.sleep(0.3)
            continue
        hits = occlusion_hits(hwnd)
        if hits >= 5:
            time.sleep(0.3)
            continue
        width, height, rgb = capture_pixels(hwnd)
        if user32.GetForegroundWindow() != hwnd or occlusion_hits(hwnd) >= 5:
            time.sleep(0.3)
            continue
        ratio = dark_ratio(rgb)
        verdict = "BLACK" if ratio > 0.9 else "OK"
        return emit(f"{verdict} {ratio:.0%} {width}x{height}", 1 if verdict == "BLACK" else 0, out_file)
    return emit(f"OCCLUDED 0% 0x0 title={window_title(hwnd)}", 3, out_file)


def windows_of_pid(process_id: int):
    """按进程号枚举可见顶层窗口（.NET 的 MainWindowHandle 对 Chrome 应用窗口不可靠）。"""
    found = []
    proc = ctypes.WINFUNCTYPE(wt.BOOL, wt.HWND, wt.LPARAM)

    def callback(hwnd, _):
        owner = wt.DWORD()
        user32.GetWindowThreadProcessId(hwnd, ctypes.byref(owner))
        if owner.value == process_id and user32.IsWindowVisible(hwnd):
            title = window_title(hwnd)
            if title:
                found.append((hwnd, title))
        return True

    user32.EnumWindows(proc(callback), 0)
    return found


def wait_window(process_id: int, hint: str, timeout: float) -> str:
    """等到"本进程的窗口"或"标题带 hint 的窗口"出现。

    进程号对不上时（Chrome 把启动请求转发给了已有实例）用标题兜底。
    """
    deadline = time.time() + timeout
    while time.time() < deadline:
        if process_id:
            for hwnd, title in windows_of_pid(process_id):
                return f"HWND {hwnd} {process_id} {title}"
        if hint:
            matches = list_windows(hint)
            if matches:
                hwnd, title = matches[0]
                return f"HWND {hwnd} 0 {title}"
        time.sleep(0.2)
    return "NONE 0 0 "


def wait_title(hwnd: int, hint: str, timeout: float) -> str:
    """等到窗口标题变成页面标题——只有页面真的加载了才会变。"""
    deadline = time.time() + timeout
    title = ""
    while time.time() < deadline:
        if not user32.IsWindowVisible(hwnd):
            return f"LOADED 0 title=(窗口不可见)"
        title = window_title(hwnd) or ""
        if hint in title:
            return f"LOADED 1 title={title}"
        time.sleep(0.2)
    return f"LOADED 0 title={title}"


def main() -> int:
    args = sys.argv[1:]

    if args and args[0] in ("--wait-window", "--wait-title"):
        rest = args[1:]

        def option(name: str, default: str = "") -> str:
            if name in rest:
                index = rest.index(name)
                if index + 1 < len(rest):
                    return rest[index + 1]
            return default

        out_file = option("--out") or None
        timeout = float(option("--timeout", "12") or 12)
        if args[0] == "--wait-window":
            result = wait_window(int(option("--pid", "0") or 0), option("--hint"), timeout)
        else:
            result = wait_title(int(option("--hwnd", "0") or 0), option("--hint"), timeout)
        return emit(result, 0 if not result.startswith(("NONE", "LOADED 0")) else 1, out_file)

    if args and args[0] == "--focus":
        rest = args[1:]
        hwnd = 0
        if "--hwnd" in rest:
            index = rest.index("--hwnd")
            if index + 1 < len(rest):
                hwnd = int(rest[index + 1])
        if not hwnd:
            return emit("NOWINDOW", 2, None)
        ok = bring_to_front(hwnd)
        return emit(f"FOCUSED {1 if ok else 0} title={window_title(hwnd)}", 0 if ok else 3,
                    rest[rest.index("--out") + 1] if "--out" in rest else None)

    # --check [关键词] [--hwnd N] [--out 文件]：判定窗口是否黑屏（供启动器调用）
    if args and args[0] == "--check":
        rest = args[1:]
        out_file = None
        if "--out" in rest:
            index = rest.index("--out")
            if index + 1 < len(rest):
                out_file = rest[index + 1]
            rest = rest[:index] + rest[index + 2:]
        hwnd = 0
        if "--hwnd" in rest:
            index = rest.index("--hwnd")
            if index + 1 < len(rest):
                hwnd = int(rest[index + 1])
            rest = rest[:index] + rest[index + 2:]
        if not hwnd:
            keyword = rest[0] if rest else "工作台"
            matches = list_windows(keyword)
            if not matches:
                return emit("NOWINDOW 0% 0x0", 2, out_file)
            hwnd = matches[0][0]
        return check_window(hwnd, out_file)

    if not args:
        for hwnd, title in list_windows():
            print(hwnd, title)
        return 0
    out_path = args[-1]
    keyword = "".join(args[:-1])
    matches = list_windows(keyword)
    if not matches:
        print(f"未找到标题包含「{keyword}」的可见窗口")
        return 1
    hwnd, title = matches[0]
    width, height = capture(hwnd, out_path)
    print(f"captured {width}x{height} '{title}' -> {out_path}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
