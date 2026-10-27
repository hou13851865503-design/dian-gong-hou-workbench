#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""抓取指定标题窗口的"屏幕真实像素"。

为什么需要它：Chrome DevTools 的 Page.captureScreenshot 截的是渲染器输出，
即使屏幕上是黑的它也可能返回正常画面。只有 BitBlt 屏幕 DC 才能拿到用户
真正看到的东西——这是判断"黑屏"的唯一可靠方式。

用法：
    python tools/grab_screen.py                 # 列出可见窗口
    python tools/grab_screen.py 工 作 台 out.png  # 抓标题含"工作台"的窗口
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
user32.SetProcessDPIAware()

SRCCOPY = 0x00CC0020
DIB_RGB_COLORS = 0


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


def capture_pixels(hwnd: int) -> tuple[int, int, bytes]:
    """把窗口当前显示的内容从屏幕 DC 拷出来（RGB 字节流）。"""
    if user32.IsIconic(hwnd):
        user32.ShowWindow(hwnd, 9)  # SW_RESTORE
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


def main() -> int:
    args = sys.argv[1:]

    # --check [关键词] [--out 文件]：判定窗口是否黑屏（供启动器调用）
    if args and args[0] == "--check":
        rest = args[1:]
        out_file = None
        if "--out" in rest:
            index = rest.index("--out")
            if index + 1 < len(rest):
                out_file = rest[index + 1]
            rest = rest[:index] + rest[index + 2:]
        keyword = rest[0] if rest else "工作台"
        matches = list_windows(keyword)
        if not matches:
            result, code = "NOWINDOW", 2
        else:
            width, height, rgb = capture_pixels(matches[0][0])
            ratio = dark_ratio(rgb)
            result = f"{'BLACK' if ratio > 0.9 else 'OK'} {ratio:.0%} {width}x{height}"
            code = 1 if ratio > 0.9 else 0
        # 先写结果文件：pythonw 下 sys.stdout 为 None，print 会抛异常
        if out_file:
            Path(out_file).write_text(result, encoding="utf-8")
        try:
            print(result)
        except Exception:
            pass
        return code

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
