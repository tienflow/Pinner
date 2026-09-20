# Pinner

你有没有过这种经历：每天都要打开同一批文件夹和文件，在 Finder 里一层层点进去，关掉浏览器标签又重新打开，日复一日。Pinner 把你常用的文件和文件夹钉在菜单栏里一键直达，同时内置 TOTP 验证码显示，以及 Codex / Antigravity (Gemini) / WorkBuddy 三套本地 Token 用量统计。

## 功能

**收藏夹**
- **拖拽收藏**：从 Finder 拖文件或文件夹到面板，自动收藏（同一路径自动去重）；也可点击面板底部 + 按钮选择文件添加
- **分类管理**：多个 Tab 收藏夹，支持创建、重命名、删除、拖拽调整顺序、在收藏夹之间移动文件
- **置顶文件**：右键置顶常用文件，置顶区始终显示在顶部
- **快速打开**：双击或选中后按空格 / 回车打开文件
- **快速预览**：选中文件后按 ⌘Y 使用 Quick Look 预览
- **多选操作**：⌘ 点击逐个加选、⇧ 点击范围选择，支持批量移动 / 移除，Delete 键删除选中项
- **拖出文件**：把面板中的条目拖到其他应用（邮件、聊天窗口等）直接作为文件使用
- **列表 / 宫格**：两种视图模式自由切换，宫格模式下图片 / PDF 显示缩略图
- **排序**：按自定义（拖拽顺序）、名称、添加时间、上次打开时间、文件类型排序，后两者带分区标题
- **拖拽排序**：按住条目拖到目标位置落下即可调整顺序，自动切换为「自定义」排序；拖到面板外仍是把文件拖出使用
- **搜索**：实时过滤当前收藏夹；输入关键词后自动跨所有收藏夹搜索并按收藏夹分组
- **最近访问**：跨收藏夹聚合最近打开的文件，按今天 / 最近 7 天 / 本月 / 更早分组，并标注来源收藏夹
- **右键菜单**：置顶 / 取消置顶、快速预览、拷贝路径、在终端中打开、在 Finder 中显示、重命名、移动到其他收藏夹、移除
- **自动刷新**：每次展开面板自动验证所有 bookmark，失效文件（含废纸篓）标灰显示「未找到」并保留，文件恢复后自动清除标记
- **撤销**：⌘Z 撤销移除文件、删除收藏夹等破坏性操作
- **面板记忆**：记住上次调整后的面板大小
- **置顶面板**：点击图钉按钮锁定面板，点击外部不再自动隐藏

**OTP 验证码**
- **独立浮动窗口**：菜单栏右键或快捷键打开，显示所有 OTP 账户的实时验证码
- **自动复制**：通过快捷键打开时，自动复制当前验证码到剪贴板
- **倒计时**：进度条实时显示验证码剩余有效时间，≤10 秒变红提醒
- **添加账户**：粘贴 `otpauth://` URI 自动解析，支持从本地图片识别二维码

**Codex 统计**
- **Token 用量**：查询本地 Codex 数据库，按 5 小时 / 今天 / 7 天 / 30 天维度展示 Token 消耗和会话数
- **趋势对比**：每个维度显示与上一周期的环比变化
- **快捷键**：默认 `⌘⇧I`，可自定义

**Antigravity 统计**
- **Token 用量**：查询本地 Antigravity 数据库，按 5 小时 / 今天 / 7 天 / 30 天维度展示 Token 消耗和会话数
- **趋势对比**：每个维度显示与上一周期的环比变化，并提供悬浮数值交互的动态折线图
- **快捷键**：默认 `⌘⇧G`，可自定义

**WorkBuddy 统计**
- **Token 用量**：扫描本地 `~/.workbuddy/projects` 会话文件（含 subagents，按消息 id 去重），按 5 小时 / 今天 / 7 天 / 30 天维度展示 Token 消耗和会话数
- **双轨口径**：主卡片为上下文吞吐合计（输入+输出），明细展示净输入 / 缓存命中占比 / 输出
- **趋势对比**：每个维度显示与上一周期的环比变化，并提供悬浮数值交互的动态折线图
- **快捷键**：默认 `⌘⇧W`，可自定义

**待办快速录入**
- **自然语言解析**：一句话 → 结构化任务（标题 / 到期 / 优先级 / 列表），由 OpenAI 兼容 API（自带 Key，Base URL / API Key / 模型名可配置，本地持久化无系统弹窗）解析后写入 macOS 提醒事项
- **预览确认卡**：解析结果先浮出可编辑卡片，四字段均可改，⏎ 保存、⎋ 丢弃
- **失败降级**：断网 / 超时（5s）/ 响应不可解析时，原文直接作为任务标题保存（无到期日），不阻断录入
- **今日概览**：面板下半区实时显示「今天 + 已逾期」未完成条目，可直接勾选标记完成，点击外部按钮跳转提醒事项 App
- **快捷键直达**：可自定义全局快捷键（默认未设置，可于偏好设置随时录制）

**通用与偏好设置**
- **扁平极简菜单**：右键菜单全面扁平化，去除繁冗的层级子菜单，高频入口一目了然
- **统一偏好设置面板 (`⌘,`)**：
  - **通用**：开机自启开关（`SMAppService`）、外观主题（自动 / 浅色 / 深色）、参与统计的 Agent 勾选（双向联动）
  - **快捷键**：可视化呈现总览、收藏夹、OTP、待办及各 Agent 统计的全局快捷键状态，支持独立录制与恢复默认
  - **待办 AI**：配置 Base URL、API Key、Model Name，支持连通性一键测试与状态提示
- **统计总览**：菜单栏右键 →「总览」打开统计大窗口，聚合五个 Agent（Codex / Antigravity / WorkBuddy / ZCode / DSH）的本地 Token 用量，默认展示今天，可切换近 7 天 / 30 天 / 全部 / 自定义日期；支持勾选参与统计的 Agent，右键菜单的「X 统计」入口跟随勾选结果同步显示 / 隐藏（至少保留一个 Agent）；含合计与分 Agent 卡片、按 Agent 份额条、每日明细 / 会话排行 / 模型排行三张表（点击列头排序）、半年 GitHub 格热力图（带月份标注）、每日明细一键导出 CSV，窗口大小自动记忆；增量加载——勾选切换不重扫已扫描的 Agent，刷新按钮强制全量
- **分 Agent 统计面板**：Codex / Antigravity / WorkBuddy 为专属面板；ZCode / DSH 为同款紧凑浮动面板（时间范围、Token/会话卡、明细行、趋势图）；入口均随勾选联动
- **全局快捷键**：收藏夹 `⌘⇧P`、OTP `⌘⇧O`、Codex 统计 `⌘⇧I`、Antigravity 统计 `⌘⇧G`、WorkBuddy 统计 `⌘⇧W`，均可自定义；总览 / 待办 / ZCode / DSH 统计可在偏好设置中随时配置；组合键被系统或其他应用占用时弹系统通知提醒

产品落地页位于 `landing/`（单文件静态页，字体已内联，可部署到任意静态托管）。

## 技术栈

- Swift 6 / SwiftUI / AppKit
- Swift Package Manager
- Security-Scoped Bookmarks（安全持久化文件访问）
- Carbon API（全局快捷键）
- RFC 6238 TOTP（HMAC-SHA1，6 位，30 秒周期）
- macOS 14+ (Sonoma)

## 项目结构

```
Sources/
├── CollectionBox/              # 核心库
│   ├── Models/                 # 数据模型（CollectionTab, BookmarkEntry, OTPAccount, StatsAgent）
│   ├── Services/               # BookmarkService + OTPService + CodexStatsService + GeminiStatsService + WorkBuddyStatsService + AgentStatsService + RemindersService + TodoLLMClient + TodoPrompt + TodoSettingsStore
│   ├── ViewModels/             # CollectionStore + OTPStore（状态 + 持久化）
│   ├── Views/                  # SwiftUI 界面（RootView, OTPView, SettingsView, TodoCaptureView, CodexStatsView, GeminiStatsView, AgentStatsView 等）
│   └── AppKit/                 # AppKit 集成
│       ├── MenuBarController.swift           # 菜单栏交互与极简扁平菜单
│       ├── EdgeDockWindowController.swift    # 收藏面板管理
│       ├── SettingsWindowController.swift    # 统一偏好设置窗口管理
│       ├── HotkeyRecorder.swift              # 快捷键录制面板（通用组件）
│       ├── OTPWindowController.swift         # OTP 面板管理
│       ├── HotkeyManager.swift               # 收藏夹快捷键
│       ├── OTPHotkeyManager.swift            # OTP 快捷键
│       ├── CodexStatsWindowController.swift  # Codex 统计面板
│       ├── CodexStatsHotkeyManager.swift     # Codex 统计快捷键
│       ├── GeminiStatsWindowController.swift # Antigravity 统计面板
│       ├── GeminiStatsHotkeyManager.swift    # Antigravity 统计快捷键
│       ├── WorkBuddyStatsWindowController.swift # WorkBuddy 统计面板
│       ├── WorkBuddyStatsHotkeyManager.swift    # WorkBuddy 统计快捷键
│       ├── AgentStatsHotkeyManager.swift        # ZCode / DSH / 待办统计快捷键
│       ├── AgentStatsWindowController.swift     # ZCode / DSH 紧凑统计窗口
│       ├── HotkeyRegistrationNotifier.swift     # 快捷键注册失败系统通知
│       ├── DashboardWindowController.swift      # 总览与单 Agent 统计窗口
│       ├── TodoCaptureWindowController.swift    # 待办快速录入面板
│       └── TodoSettingsWindowController.swift   # 兼容路由至偏好设置
└── CollectionBoxApp/           # 应用入口（AppDelegate + NSApplication）
```

测试：本仓库使用独立测试运行器（CommandLineTools 环境无 XCTest），运行 `swift run PinnerTestRunner`，全部断言通过时退出码为 0。

## 快捷键

### 全局快捷键

| 按键 | 功能 |
|------|------|
| `⌘⇧P`（默认） | 在鼠标位置展开收藏面板 |
| `⌘⇧O`（默认） | 在鼠标位置展开 OTP 面板并自动复制验证码 |
| `⌘⇧I`（默认） | 打开 Codex 统计面板 |
| `⌘⇧G`（默认） | 打开 Antigravity 统计面板 |
| `⌘⇧W`（默认） | 打开 WorkBuddy 统计面板 |

待办快速录入、总览、ZCode 与 DSH 统计默认未分配快捷键，可在菜单栏右键 →「偏好设置…」(⌘,) →「快捷键」选项卡中一键录制。

### 面板内快捷键

| 按键 | 功能 |
|------|------|
| ↑ ↓ ← → | 选择文件（宫格模式下左右键按列移动） |
| Tab | 切换到下一个收藏夹 |
| Shift + Tab | 切换到上一个收藏夹 |
| 空格 / 回车 | 打开选中文件 |
| ⌘Y | Quick Look 预览选中文件 |
| ⌘Z | 撤销移除 / 删除操作 |
| Delete | 移除选中的文件 |
| Esc | 收起面板 |

## 菜单栏

- **左键点击**：展开 / 收起收藏面板
- **右键点击**：打开极简扁平菜单

```
总览                  ← 打开统计大窗口
──────────
待办                  ← 打开待办快速录入面板（自然语言 → 提醒事项）
收藏夹                ← 打开收藏面板
OTP 验证码            ← 打开 OTP 面板
──────────
（以下随「设置」勾选显示 / 隐藏，至少保留一个）
Codex 统计            ← 打开统计面板
Antigravity 统计        ← 打开统计面板
WorkBuddy 统计        ← 打开统计面板
ZCode 统计            ← 打开 ZCode 紧凑统计面板
DSH 统计              ← 打开 DSH 紧凑统计面板
──────────
偏好设置… (⌘,)         ← 打开统一偏好设置面板（通用 / 快捷键 / 待办 AI）
──────────
退出 Pinner (⌘Q)      ← 退出应用
```

## 安装

### 方式一：从 Release 下载

1. 前往 [Releases](../../releases) 页面
2. 下载最新版本的 `Pinner-v1.6.0.dmg`
3. 打开 DMG，将 Pinner 拖入「应用程序」文件夹
4. 首次打开时右键选择「打开」以绕过 Gatekeeper

### 修复「已损坏，无法打开」

macOS 从网上下载的 app 首次打开时可能提示「Pinner 已损坏，无法打开」。在终端执行以下命令即可修复：

```bash
xattr -cr /Applications/Pinner.app
```

### 方式二：从源码编译

需要 macOS 14+ 和 Xcode Command Line Tools，以及 Homebrew 的 zstd（用于解压 DSH 会话）：

```bash
brew install zstd
```

```bash
git clone https://github.com/tienflow/Pinner.git
cd Pinner
swift build
open .build/debug/CollectionBoxApp
```

> 注意：macOS 26+ 的 CommandLineTools（SDK 27）因缺少 `libSwiftUIMacros.dylib` 宏插件无法编译 SwiftUI `@State`（报 `plugin for module 'SwiftUIMacros' not found`）。临时方案是使用旧 SDK 构建：
>
> ```bash
> SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk swift build
> ```
>
> 根治方案是安装完整 Xcode（或等待 Apple 修复 CLT 插件缺失）。

### 设为开机自启

1. 打开「系统设置 → 通用 → 登录项与扩展」
2. 点击「+」添加 Pinner 应用

## 许可

MIT
