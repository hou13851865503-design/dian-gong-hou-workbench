# 电工猴的此思妙想工作台

一个本地「应用中心」：把两个本机应用（国内外 AI 协同工作台、QQ 邮箱作业班长助手）收进一个悬浮窗口 / 门户页，点一下就能启动。

## 界面预览

工作台门户页（含实时「运行概览」）：

![工作台门户页](docs/portal.png)

QQ 邮箱作业班长助手：

![QQ 邮箱作业班长助手](docs/qq-assistant.png)

## 组成

| 文件 | 作用 |
|---|---|
| `电工猴的此思妙想工作台.html` | 应用中心门户页（仿微信/QQ 布局，含"运行概览"实时仪表盘） |
| `launcher.ps1` | 桌面快捷方式的入口：拉起本地门户服务，再用**应用窗口**（无地址栏）打开门户页 |
| `portal_server.py` | 本地门户服务：托管门户页，并提供「一键启动两个应用」的接口 |
| `launch-handler.ps1` | `workbench://` 本地协议的处理器（备用方案，现默认不需要） |
| `build-icon.ps1` | 由 PNG 生成多尺寸 `.ico` |
| `*.ico` / `*.png` | 图标素材 |
| `workbench-url-protocol.reg.example` | 注册 `workbench://` 协议的示例（需改成你的实际路径） |

## 目录约定

启动器用相对路径查找两个应用，请把它们克隆到 `apps/` 下并保持文件夹名：

```
工作台/
├─ launcher.ps1
├─ 电工猴的此思妙想工作台.html
└─ apps/
   ├─ domestic-global-ai-workbench/
   └─ qq-email-homework-assistant/
```

```bash
git clone https://github.com/hou13851865503-design/domestic-global-ai-workbench.git apps/domestic-global-ai-workbench
git clone https://github.com/hou13851865503-design/qq-email-homework-assistant.git apps/qq-email-homework-assistant
```

## 使用

- **双击桌面快捷方式（或 `launcher.ps1`）**：后台拉起本地门户服务，确认门户页返回 200 后，用**应用窗口（App 形式，无地址栏、无标签栏）**打开它——界面就是上面这张图，原生 DPI 渲染，清晰锐利。优先使用 Chrome 的 `--app`（Edge 是单实例模型，`--app` 会被转发而退化成普通窗口）；没有 Chrome 时退回 Edge。
- 门户里点应用卡片 / 右上角按钮即可启动对应应用（调用本地服务的 `/api/launch`，不依赖注册表协议）；
- 只想看网页版：直接双击 `电工猴的此思妙想工作台.html`（此时「打开」按钮不可用，因为没有本地服务）；
- 「运行概览」实时显示两个应用的运行状态（检测 8765 / 8767 端口）。若应用已经开着但这里显示"未运行"，说明那个进程是旧版本（缺少状态接口），重启该应用即可。

## 两个应用

- **国内外 AI 协同工作台**：多 Agent 协作（评估 → 出题 → 执行 → 验收），支持"多 AI 协作 · 方案博弈"（4 角色论证 → A/B/C 方案 → 红队压测 → 人工叫停/继续/采纳）。启动前需在该仓库构建 `AI多Agent流水线.exe`（见其 `build.ps1`），或直接 `python platform.py`。
- **QQ 邮箱作业班长助手**：本机网页工具，按需扫描 QQ 邮箱收作业 PDF、统计已交/未交、生成提醒，支持截止后自动提醒。用 `pythonw app.pyw` 启动（Python 3.9+）。

## 说明

本仓库只含工作台本体（门户页 + 启动器 + 图标）；两个应用是独立仓库，见 `apps/` 约定。

## 工程质量：硬规则与自检

这些规则对应曾经真实发生过的故障，**改动相关文件前请先跑自检**：

```bash
python tools/lint_portal.py       # 静态守卫：CSS/服务标识/启动器流程/编码/窗口工具冒烟
python tools/verify_portal.py     # 真实渲染自检：起服务 + 真 Chrome + CDP 断言 + 屏幕像素检查
python tools/verify_launcher.py   # 启动器验收：模拟"刚重启"，9 项可判定断言（含遮挡反证）
python tools/profile_startup.py   # 启动耗时剖析：按阶段拆分，定位瓶颈（--runs 3 / --cold）
python tools/grab_screen.py 工作台 shot.png   # 单独抓某个窗口的屏幕像素，排查黑屏用
```

### 六条硬规则

1. **页面禁用**：全屏 `filter: blur()`、`backdrop-filter`、`background-attachment: fixed`。
   这类合成层在部分 GPU 上会整屏渲染成黑色——而无头浏览器截图完全正常，极易误判。
2. **服务必须可识别**：`/api/health` 返回 `{"portal": "workbench", ...}`。
   启动器只能复用通过身份校验的端口，否则会把窗口开到别人（例如 8787 上的 New API）的页面上。
3. **"窗口出现"不等于"启动成功"**：还要等窗口标题变成工作台标题（页面真加载），
   否则拿到的是标题为 `127.0.0.1_/` 的空白窗口。
4. **判断黑屏只能看屏幕像素**：Chrome DevTools 的 `Page.captureScreenshot` 截的是**渲染器输出**，
   屏幕真黑时它仍可能返回正常画面。必须用 `tools/grab_screen.py`（BitBlt 屏幕 DC）取证。
5. **像素只有在"窗口在最前、且没被盖住"时才是证据**：BitBlt 是按矩形拷屏幕像素，
   窗口被别的窗口压住时拷到的是别人。9 宫格采样 ≥5 格被盖 → 返回 `OCCLUDED`，
   此时**不判黑屏、不杀进程**（被杀掉的往往是一个正常窗口）。
6. **"无法判定"不能当成"成功"**：检测失败要如实记为 `像素无法判定`，保留窗口交给用户；
   既不谎报成功，也不能凭一次采样就杀掉窗口。

### 启动性能（实测，`python tools/profile_startup.py --runs 3`）

| 指标 | 优化前 | 优化后 | 变化 |
|---|---|---|---|
| 热启动总耗时（中位数） | 7.57s（5.82–9.39s） | **≈2.5s**（实测 2.44–2.66s） | −67% |
| 冷启动总耗时（删 profile，模拟刚重启） | — | **1.66s**（1.52–1.80s） | — |
| 点击 → 窗口可见 | ~6.5s | **≈0.6s** | −91% |
| 点击 → 页面可用（标题变成工作台） | ~7.1s | **≈1.0s** | −86% |

优化前日志里各阶段加起来只有 1.60s，却有 7.57s 总耗时——**差的 6 秒全花在"① 拉起服务"之前**：
21 个端口逐个盲等 1.5s、再等 HTTP 200、再启动浏览器（全程串行）。现在的链路是：

1. **服务先绑端口，浏览器立刻启动**：`portal_server` 绑定成功即算就绪，启动器用 TCP 监听（连得上）当信号，
   不再等 HTTP 200；浏览器启动和服务启动并行，不再串行叠加。
2. **路径缓存**：`pythonw` / `chrome` 的解析结果缓存在 `%LOCALAPPDATA%\DianGongHouWorkbench\env.json`，
   省掉每次扫 PATH 的几百毫秒。
3. **合并窗口操作**：置前合并进"等页面标题"，少启动一次 pythonw（约 0.25s）。
4. **Chrome 少做事**：关闭后台网络/组件更新/默认应用/扩展/崩溃上报等启动期动作。
5. **像素自检瘦身**：窗口已在最前就不再重复置前，采样等待 0.35s → 0.2s（最坏仍保留 3 次重试）。

剩余瓶颈是**像素自检（约 1.0s）**——它是唯一能证明"不是黑屏"的环节，属于刻意的安全开销：
此时窗口已经可见可用（≈1.0s 就到了），自检在后台完成，用户感知不到。

> 说明：优化前的"点击 → 可见/可用"两行是按日志分段推算的（那 6 秒落在日志覆盖范围之外），
> 不是直接测量值；优化后的数字是 `profile_startup.py` 连续 3 次实测的中位数。

### 已知坑（都已在代码里规避）

| 坑 | 现象 | 规避 |
|---|---|---|
| Chrome `--disable-gpu` | 启动后立即退出 | 不使用该参数（`--disable-gpu-compositing` 允许） |
| Edge 单实例 | `--app` 被转发，退化成普通窗口 | 用 Chrome `--app` + 独立 profile |
| 新建 Chrome profile | 弹首次运行欢迎页盖住应用窗口 | 预置 `First Run` 标记 |
| 刚杀掉 Chrome 就重开 | 新进程 ExitCode=0、无窗口（被退出的实例吞掉） | 等 chrome 进程清零 + 600ms，识别后撤避重试 |
| 固定临时结果文件 | 读到上一次的黑屏判定结果 | 每次 `[guid]` 唯一文件名 |
| `MainWindowHandle` 认窗口 | Chrome 应用窗口有时句柄为 0，误判"没窗口" | 用 `EnumWindows` 按 PID 找窗口 |
| 21 个端口各盲等 1.5s | 双击后 30 秒才起服务 | 先只看 8770，被占用才往后扫 |
| `http_proxy`/`HTTP_PROXY` 同时存在 | `Start-Process -Redirect*` 抛"关键字重复" | 子进程结果一律写文件回传 |
| PowerShell 管道 `\| Remove-Item -Force` | 无匹配项时报 missing path operand 并中断 | 改用 `ForEach-Object` |
| `.ps1` 无 BOM | PowerShell 5.1 中文乱码 | 保存为 UTF-8 BOM + CRLF |
| 工具脚本变量作用域 | `--settle` 只在一个分支里赋值，另一分支 `NameError` → 不写结果文件 → 启动器白等 20s 超时 | 参数解析统一走 `opt()/take_flag()`；`main()` 兜底捕获异常写 `TOOLFAIL`；`lint_portal.py` 对每个子命令做冒烟测试 |
| 等 HTTP 200 才算服务就绪 | 服务其实早已监听，白等一轮握手/健康检查 | 绑定成功即算就绪，用 TCP 连得上当信号 |
| Windows 的 `SO_REUSEADDR` | 第二个服务进程也能绑同一端口，两个进程抢着应答（页面偶发旧内容），且 bind 永不报错 | `allow_reuse_address = False`（非 Windows 才开），端口被占就真的抛 `OSError`，再判"是不是自己在跑" |
| 把 Chrome 当 python 子进程起 | 沙箱/安全软件回收子进程树，窗口 1 秒就没了、CDP 端口消失 | 用 `DETACHED_PROCESS` 脱离进程组启动（自检工具里必须这样） |
| 同标题有多个窗口 | `list_windows(keyword)[0]` 可能拿到 0x0 的隐藏窗口，截图失败 | `pick_window()` 按面积挑最大的可见窗口 |
| 库函数里 `raise SystemExit` | 被别的脚本 import 时会把整个校验进程带走（只输出一句话就没了） | 抛自定义 `CaptureError`，由调用方决定降级 |

### 排障顺序

1. 看 `portal_launcher.log` 最后几行（端口、就绪、页面加载、像素判定、置前结果）；
2. `curl --noproxy '*' http://127.0.0.1:8770/api/health` 确认服务身份；
3. 跑 `python tools/verify_portal.py`，确认页面是否真的渲染出来；
4. 跑 `python tools/verify_launcher.py`，确认"冷启动下双击"整条链路；
5. 仍然黑屏 → 看 `docs/diag/<时间戳>/`（截图 + 窗口清单 + 环境），完整手册见
   `docs/工作台黑屏排查手册.md`。

