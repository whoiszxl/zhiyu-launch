# Zhiyu Launch（智屿 Launch）

[English](#english) | [中文](#中文)

---

## 中文

极简、轻量、原生的经典 macOS Launchpad 替代品。macOS 新版本取消了经典 Launchpad 应用网格，Zhiyu Launch 用纯 AppKit 恢复旧版 Launchpad 的核心交互：全屏应用网格、直接打字搜索、分页翻页、拖拽排序与文件夹。

### 特性

- **全屏启动台面板**：无边框、不占独立 Space、覆盖当前显示器、支持 Retina 与深浅色模式
- **自动发现应用**：扫描 `/Applications`、`~/Applications`、`/System/Applications` 等目录，并用 Spotlight 补充发现；事件驱动刷新（文件系统事件 + 防抖），不做轮询；目录扫描完成前不会用不完整的目录重建布局
- **点击即启动**：优先激活已运行的实例，不重复拉起
- **直接打字搜索**：打开即可输入，中英文、大小写不敏感，**支持拼音**（输入 `wx` 或 `weixin` 即可找到「微信」，基于系统内置拼音转换，零第三方词库），完整支持中文输入法（IME 候选期间的回车/方向键不会误触）
- **分页**：触控板跟手拖动（松手吸附到最近的页，支持惯性）、鼠标滚轮、键盘左右方向键 / Home / End、点击底部圆点；翻页为 60Hz 缓动动画
- **拖拽排序与文件夹**：拖动图标边缘排序（显示插入线，拖到屏幕边缘可自动翻页跨页移动），拖到图标/文件夹中部创建或加入文件夹；右键菜单：打开 / 在访达中显示 / 重命名 / 解散文件夹；文件夹浮层支持方向键导航、Enter 启动、名称编辑、内部拖动重排、拖出卡片即移出、内容超出时滚动显示；布局持久化（JSON）
- **最近使用**：第一页顶部显示最近使用的应用（追踪全系统应用激活，不限于从启动台启动），点击即打开；翻页或搜索时自动隐藏；右键可单个移除；有最近记录时网格自动为它让出空间；可在设置中关闭
- **隐藏应用**：右键应用可「隐藏此应用」（布局位置保留），在设置中一键全部恢复
- **中英双语**：界面文案自动跟随系统语言（中文 / English）
- **应用图标**：程序化生成（见 `scripts/generate_app_icon.swift`，可重新生成）
- **标准快捷键**：`⌘W` 关闭启动台、`⌘Q` 退出、搜索框支持 `⌘A / ⌘C / ⌘V / ⌘X`（通过内置最小主菜单提供，LSUIElement 应用不显示菜单栏）
- **全局快捷键**：默认 `⌥⌘L`，可在设置中录制修改（Carbon 公开 API，无需辅助功能权限）
- **菜单栏**：打开启动台、设置、开机启动（`SMAppService`）、显示/隐藏菜单栏图标、退出
- **多显示器**：默认在鼠标所在显示器打开，正确处理分辨率、缩放与显示器变化

### 系统要求

- macOS 27 及以上（构建使用 macOS 27.0 SDK；更低版本未验证）
- 从源码构建需要 Swift 6.x 工具链（Xcode 27 / Command Line Tools）

### 构建与运行

```bash
# 构建 .app 包（release + 临时签名）
make app

# 构建并启动
make run

# 安装到 /Applications（推荐，开机启动功能需要从 .app 包内运行）
make install

# 单元测试
make test

# 开发调试（无 .app 包，LSUIElement/SMAppService 等包相关能力受限）
swift run
```

构建产物：`build/Zhiyu Launch.app`（Bundle ID `com.zhiyu.launch`）。

### 使用说明

| 操作 | 效果 |
|---|---|
| `⌥⌘L` / 菜单栏图标 | 打开 / 关闭启动台 |
| 直接打字 | 搜索应用（无需先点搜索框） |
| `Enter` | 启动选中应用 |
| `Esc` | 关闭文件夹 → 清空搜索 → 关闭启动台 |
| 方向键 | 在网格中移动选择；在行首/行尾时跨页 |
| `Home` / `End` | 跳到第一页 / 最后一页 |
| 触控板滑动 | 跟手拖动，松手吸附（支持惯性） |
| 滚轮 / 点击圆点 | 翻页 |
| 点击图标边缘拖动 | 排序（显示插入线）；拖到屏幕边缘停留可跨页 |
| 拖到图标/文件夹中部 | 创建文件夹 / 加入文件夹 |
| 右键图标 | 打开、在访达中显示；文件夹可重命名、解散 |
| 点击空白区域 / `⌘W` | 关闭启动台 |
| `⌘Q` | 退出 |

文件夹内：方向键移动选择、Enter 启动；点击标题可重命名；拖动应用可重排；右键或把应用拖出卡片可移出文件夹。最近使用条上的应用右键可从列表移除。

「最近使用」通过 `NSWorkspace` 的应用激活通知追踪（公开 API，不采集任何额外数据），仅保存最多 10 个 Bundle ID 到 `UserDefaults`；已卸载的应用会自动从列表中消失。

### 性能（实测数据）

测量环境：MacBook（1512×982 逻辑分辨率、2x）、macOS 27.0.1、目录中 138 个应用。数据来自应用内自测（`ZHIYU_SELFTEST=1`，读取 `phys_footprint`，即「活动监视器」口径）：

| 场景 | 实测 | 目标 |
|---|---|---|
| 后台待机（从未打开面板） | **21 MB** | 15–30 MB |
| 启动台打开（首屏图标渲染完成） | **46 MB** | 40–80 MB |
| 关闭 30 秒后（空闲释放，含系统可回收缓存） | **31 MB** | — |
| 空闲 CPU（面板打开静置） | **0.0%** | 接近 0% |
| 空闲释放后重新打开（重建内容、图标复用缓存） | **24 ms**（面板重建到首帧） | 150 ms 内 |

内存策略：图标按显示尺寸渲染为唯一缩略图并经 `NSCache` 限容（24 MB 上限）；后台渲染及时排空 autorelease；关闭 30 秒后销毁视图树并清空图标缓存（频繁开关时不触发，保证秒开）。`leaks` 检查未发现应用自身的泄漏对象（报告中的 ~20 KB 全部来自系统框架内部缓存）。

> 说明：以上为真实测量值，非承诺指标；不同机器、应用数量、系统压力下会有差异。第三方工具如 vmmap 观察到的值可能不同（共享库与可回收页计入口径不同）。

### 项目结构

```text
zhiyu-launch/
├── Package.swift                  # SwiftPM（macOS 27+）
├── Makefile                       # .app 组装 / 安装 / 测试
├── scripts/                       # 工具脚本（应用图标生成）
├── .github/workflows/ci.yml       # CI：构建 + 测试
├── Resources/Info.plist           # Bundle ID、LSUIElement 等
├── Resources/AppIcon.icns         # 应用图标（程序化生成）
├── Sources/
│   ├── ZhiyuLaunch/main.swift     # 可执行入口
│   └── ZhiyuLaunchKit/
│       ├── App/                   # AppDelegate、菜单栏、设置窗口、调试工具
│       ├── Core/                  # 应用扫描、目录监听、图标缓存、全局热键、开机启动
│       ├── Models/                # AppItem、网格几何、布局模型、偏好、搜索匹配
│       ├── Storage/               # layout.json 读写与防抖保存
│       └── UI/                    # NSPanel、网格控制器、自定义布局、分页滚动、文件夹浮层
└── Tests/ZhiyuLaunchKitTests/     # 44 个单元测试
```

### 开发

```bash
swift test                # 单元测试（布局模型、几何计算、扫描过滤、搜索匹配等）

# QA / 诊断环境变量（运行 .app 或 swift run 时设置）：
ZHIYU_DEBUG=1             # 输出窗口/生命周期/翻页日志到 stderr
ZHIYU_AUTOSHOW=1          # 启动后自动打开启动台
ZHIYU_SELFTEST=1          # 测量打开/关闭内存与重建耗时后退出
ZHIYU_SNAPSHOT=1          # 将面板自渲染为 /tmp/zhiyu-selftest.png 后退出
ZHIYU_UITEST=1            # 运行内置交互冒烟测试（49 步），全过退出码为 0
ZHIYU_IDLE_RELEASE_SECONDS=2   # 覆盖空闲释放延迟（默认 30 秒）
```

`ZHIYU_UITEST` 通过真实响应链注入合成的键盘与滚动事件，覆盖焦点路由、打字搜索、
键盘选择与 Home/End、滚轮与触控板跟手翻页（含部分滑动回弹）、分页点、Esc 层级、
文件夹浮层与浮层键盘导航、⌘W、以及拖拽的完整规划与应用逻辑（排序 / 创建文件夹 /
加入文件夹 / 边缘翻页，通过探针走与系统拖拽完全相同的代码路径），并在隔离的布局
文件上运行（不触碰真实布局）。鼠标点击通过处理入口直接验证：AppKit 只把 mouse-up
派发给 mouse-down 记录的目标视图，脱离真实事件序列的合成 mouse-up 不可靠（真实
点击始终成对到达）；真实拖拽会话同样由 AppKit 驱动，探针覆盖其全部业务逻辑。

### 已知限制

- 目标平台为 macOS 27（当前 SDK）；未在更低系统上验证。
- 拖拽释放位置语义：图标中部 = 创建/加入文件夹，边缘 = 排序；与旧版 Launchpad 的「缝隙插入」略有差异。
- SwiftPM 工程；可用 Xcode 直接打开 `Package.swift`。

### 许可证

MIT，见 [LICENSE](LICENSE)。

---

## English

A minimal, lightweight, native replacement for the classic macOS Launchpad. Recent macOS releases removed the classic Launchpad grid; Zhiyu Launch restores its core interactions with pure AppKit: a full-screen app grid, type-to-search, paging, drag-to-reorder and folders.

### Features

- **Full-screen panel**: borderless, no separate Space, covers the current display, Retina-ready, light/dark mode friendly
- **Automatic app discovery**: scans `/Applications`, `~/Applications`, `/System/Applications`, plus Spotlight results; event-driven refresh (file-system events + debounce), never polls; the layout is not reconciled against a partial catalog before the first directory scan completes
- **Click to launch**: activates running instances instead of spawning duplicates
- **Type-to-search**: start typing immediately — Chinese/English, case-insensitive, **pinyin-aware** (type `wx` or `weixin` to find 「微信」, powered by the system transliterator — no third-party dictionaries), IME-safe (Enter/arrows are not hijacked while the IME candidate window is up)
- **Paging**: live-following trackpad drags (snap to the nearest page on release, momentum supported), mouse wheel, arrow keys / Home / End, page dots; 60 Hz eased page animation
- **Drag & drop with folders**: drag by the icon's edge to reorder (insertion line shown; parking at the screen edge flips pages for cross-page moves), drop on the middle of another icon/folder to create or join a folder; context menu: open / reveal / rename / dissolve; the folder overlay supports arrow-key navigation, Enter to launch, title editing, in-folder drag reordering, drag-out-to-remove and scrolling for large folders; layout is persisted as JSON
- **Recently used**: a strip at the top of the first page shows recently used apps (tracked via system-wide application activation, not just launches from this launcher); click to open, right-click to remove an entry, and it hides while paging or searching; the grid automatically makes room for it when entries exist; can be disabled in Settings
- **Hidden apps**: right-click an app to hide it (its layout position is kept); restore them all from Settings
- **Localized**: the UI follows the system language (Chinese / English)
- **App icon**: generated programmatically (see `scripts/generate_app_icon.swift`; re-run to regenerate)
- **Standard shortcuts**: `⌘W` closes the launchpad, `⌘Q` quits, and the search field supports `⌘A / ⌘C / ⌘V / ⌘X` (provided by a minimal built-in main menu; LSUIElement apps show no menu bar)
- **Global hot key**: defaults to `⌥⌘L`, recordable in Settings (public Carbon API — no accessibility permission needed)
- **Menu bar**: open launchpad, settings, launch at login (`SMAppService`), show/hide menu bar icon, quit
- **Multi-display**: opens on the display under the mouse; handles resolution, scaling and display changes

### Requirements

- macOS 27 or later (built with the macOS 27.0 SDK; older versions are untested)
- Swift 6.x toolchain (Xcode 27 or Command Line Tools) to build from source

### Build & Run

```bash
make app        # build the .app bundle (release + ad-hoc signing)
make run        # build and launch
make install    # copy into /Applications (recommended; required for launch-at-login)
make test       # unit tests
swift run       # dev run without a bundle (bundle-dependent features limited)
```

Artifact: `build/Zhiyu Launch.app` (bundle ID `com.zhiyu.launch`).

### Usage

| Action | Result |
|---|---|
| `⌥⌘L` / menu bar icon | Toggle the launchpad |
| Type anywhere | Search apps (no need to focus the search field first) |
| `Enter` | Launch the selected app |
| `Esc` | Close folder → clear search → close launchpad |
| Arrow keys | Move the selection; rolls over to the adjacent page at row edges |
| `Home` / `End` | Jump to the first / last page |
| Trackpad swipe | Live-follow drag, snaps on release (momentum supported) |
| Wheel / page dots | Flip pages |
| Drag an icon by its edge | Reorder (insertion line shown); park at a screen edge to flip pages |
| Drop on icon/folder center | Create / join a folder |
| Right-click an icon | Open / reveal in Finder; folders can be renamed or dissolved |
| Click empty area / `⌘W` | Close the launchpad |
| `⌘Q` | Quit |

Inside a folder: arrow keys move the selection, Enter launches; click the title to rename; drag tiles to reorder; right-click or drag a tile out of the card to move it out. Right-click an entry in the recent strip to remove it.

"Recently used" is tracked through `NSWorkspace` application-activation notifications (public API, no extra data collected); only up to 10 bundle identifiers are stored in `UserDefaults`, and uninstalled apps fall out of the list automatically.

### Performance (measured)

Test machine: MacBook (1512×982 logical, 2x), macOS 27.0.1, 138 apps installed. Numbers come from the built-in self-test (`ZHIYU_SELFTEST=1`, reading `phys_footprint`, the Activity Monitor metric):

| Scenario | Measured | Target |
|---|---|---|
| Idle background (panel never shown) | **21 MB** | 15–30 MB |
| Launchpad open (first page rendered) | **46 MB** | 40–80 MB |
| 30 s after close (idle release, incl. reclaimable caches) | **31 MB** | — |
| Idle CPU (panel open, at rest) | **0.0%** | ~0% |
| Reopen after idle release (content rebuilt, icons cached) | **24 ms** to first frame | within 150 ms |

Memory strategy: icons are rendered to a single correctly-sized thumbnail and bounded by `NSCache` (24 MB cap); background renders drain autorelease pools eagerly; 30 s after closing, the view tree is torn down and the icon cache cleared — frequent toggling keeps the panel warm for instant reopening. `leaks` reports no app-owned leak objects (the ~20 KB it finds all belong to system framework caches).

> These are real measurements, not guarantees; expect differences across machines, app counts and system pressure. Third-party tools (e.g. vmmap) may report different values due to shared/reclaimable page accounting.

### Project Layout

```text
zhiyu-launch/
├── Package.swift                  # SwiftPM (macOS 27+)
├── Makefile                       # .app assembly / install / test
├── scripts/                       # tooling (app icon generation)
├── .github/workflows/ci.yml       # CI: build + test
├── Resources/Info.plist           # bundle ID, LSUIElement, etc.
├── Resources/AppIcon.icns         # app icon (generated programmatically)
├── Sources/
│   ├── ZhiyuLaunch/main.swift     # executable entry point
│   └── ZhiyuLaunchKit/
│       ├── App/                   # AppDelegate, status bar, settings, QA helpers
│       ├── Core/                  # scanning, directory watching, icon cache, hot key, login item
│       ├── Models/                # AppItem, grid metrics, layout model, preferences, search
│       ├── Storage/               # layout.json load/save with debounce
│       └── UI/                    # NSPanel, grid controller, layout, paging scroll view, folder overlay
└── Tests/ZhiyuLaunchKitTests/     # 44 unit tests
```

### Development

```bash
swift test

# QA / diagnostics environment variables:
ZHIYU_DEBUG=1                  # window & lifecycle logs to stderr
ZHIYU_AUTOSHOW=1               # auto-open the launchpad on start
ZHIYU_SELFTEST=1               # measure open/closed memory + rebuild time, then exit
ZHIYU_SNAPSHOT=1               # self-render the panel to /tmp/zhiyu-selftest.png, then exit
ZHIYU_UITEST=1                 # run the built-in interaction smoke test (49 steps); exit 0 when green
ZHIYU_IDLE_RELEASE_SECONDS=2   # override the idle release delay (default 30 s)
```

`ZHIYU_UITEST` injects synthesized keyboard and scroll events through the real
responder chain, covering focus routing, type-to-search, keyboard selection with
Home/End, wheel and live-follow trackpad paging (including partial-swipe snap
back), page dots, Escape handling, the folder overlay with its keyboard
navigation, ⌘W, and the full drag planning/application pipeline (reorder, create
folder, join folder, edge flipping — the probe runs exactly the same code paths
the system drag delegate uses) — all on an isolated layout file, never touching
the real one. Mouse clicks are verified through their handler entry points
instead of synthetic events: AppKit only routes a mouse-up to the view that
recorded the mouse-down, so a bare synthesized mouse-up (outside a real event
sequence) is unreliable; real clicks always arrive as a down/up pair. Real drag
sessions are likewise driven by AppKit — the probe covers their business logic.

### Known Limitations

- Targets macOS 27 (current SDK); older systems are untested.
- Drop semantics: icon center = folder create/join, edges = reorder — slightly different from the classic gap insertion.
- SwiftPM project; open `Package.swift` in Xcode if you prefer.

### License

MIT, see [LICENSE](LICENSE).
