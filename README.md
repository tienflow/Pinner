# Pinner

> 钉在 macOS 菜单栏的高效常驻工作台。文件收藏、灵感与待办极速捕获、端口与外设监控、多 Agent AI 消耗账本，一键直达，不为你多开一个窗口。

[![Platform](https://img.shields.io/badge/platform-macOS%2014%2B-blue.svg)](https://github.com/tienflow/Pinner/releases)
[![Swift](https://img.shields.io/badge/Swift-6.0-orange.svg)](https://swift.org)
[![License](https://img.shields.io/badge/license-MIT-green.svg)](LICENSE)
[![Release](https://img.shields.io/badge/release-v1.12.0-brightgreen.svg)](https://github.com/tienflow/Pinner/releases/tag/v1.12.0)

---

## 核心功能

### 📂 工作台与中转暂存 (Workspace & Drop Shelf)
- **多 Tab 分类收藏**：常用文件夹与文件拖拽快速纳管（自动路径排重），支持 Tab 拖拽调序、跨收藏夹分类整理与置顶固定。
- **临时暂存中转架 (Drop Shelf)**：跨窗口中转文件的常驻悬浮槽，支持**拖出即焚**（外部应用接收后自动清理条目）、按住 `⌘` 物理剪切移动（防重名自动顺延编号）及一键转存至收藏夹。
- **极速检索与预览**：内置拼音搜索引擎，支持全拼、简拼（如 `zb` 匹配 `项目周报.xlsx`）及跨分类聚合模糊搜索；空格键即开系统级 Quick Look 预览；宫格模式采用 macOS `QLThumbnailGenerator` 硬件加速生成高保真文件缩略图。
- **安全与可逆**：失效文件标灰提醒并安全保留（防误删），全场景支持 `⌘Z` 撤销删除与移动。

### ⚡️ 极速捕获 (Quick Capture)
- **待办快速录入 (Reminders Integration)**：
  - **自然语言一句话建任务**：输入日常语句（如「明天下午三点跟张工对需求」），由大模型智能提炼标题、到期时刻、优先级与目标列表并写入 macOS 系统提醒事项。
  - **确认卡与多行批量拆解**：智能浮出可编辑卡片，四字段均可快速微调；支持一次性粘贴多行文本批量智能拆解建单；断网或超时优雅平滑降级，绝不丢失输入。
  - **今日看板与日报小结**：下半区展开今日/已逾期任务，支持一键快捷推迟（明天 9:00、下周一等）与完成勾选；提供「今日小结」一键导出 Markdown 完成日报闭环。
- **闪念投递 (Fleeting Capture)**：
  - **极速直达 Apple Notes**：菜单栏右键或全局快捷键唤出轻量玻璃卡片，随手记录当下灵感与随笔。
  - **Jev 语义路由 + 大模型终审**：优先通过 TypeSafe Jev 极速预判目标分类与笔记（~200ms），低置信度自动升级大模型仲裁；支持置顶前插与尾部追加。
  - **100% 文本真实性铁律**：正文绝对保真用户原始字词，绝不擅自添加前缀破折号或进行 AI 说教扩写；集成一键 AI 错别字与语病润色。

### 🖥️ 开发者与系统监控 (Dev & Monitor)
- **端口管家 (Port Manager)**：
  - **轻量独立浮窗**：聚焦监听（`LISTEN`）网络端口，用完即走，面板关闭时彻底销毁定时器，零后台常驻电量消耗。
  - **原生 Docker / OrbStack 穿透反查**：自动解析宿主机代理端口（如 `docker-proxy`），穿透识别具体 Docker 容器名与镜像名，支持针对具体容器执行安全平滑停止（`docker stop`）。
  - **外部暴露安全识别**：精准区分外部暴露（`0.0.0.0` / `*`）与本机隔离（`127.0.0.1`），提供专属过滤胶囊。
  - **交互式表头双向排序**：支持点击进程表头按名称、PID、端口、分类、CPU、内存一键升降序切换。
  - **深度进程详情弹窗**：指标卡片严格等高对称排布（64pt），网络暴露安全域归位至头部元信息，多端口清单完整下沉；支持普通进程一键强杀与 root 进程 Touch ID / 密码管理员提权。
- **进程管家 (Process Manager)**：
  - **算力与内存急救**：Mach/Darwin 内核微秒级采样 CPU 综合负载、统一内存压力等级（正常/受压/告警）与 Swap 磁盘换页，用完即走零常驻电量损耗。
  - **Top 资源元凶透视**：智能还原 `node` (如 `vite dev`)、`python` 等脚本命令参数，精准抓取卡死与高耗进程。
  - **进程挂起与恢复 (SIGSTOP/SIGCONT)**：重型编译时一键冻结高耗脚本让出算力，编译完一键恢复；支持普通强杀与管理员提权。
- **键鼠统计 (Input Stats)**：
  - **外设全景监控**：基于 macOS `CGEvent` 监听击键总数、KPS、CPS、鼠标物理滑行位移换算（米/公里）与页面滚动距离。
  - **24 小时心流节律**：00:00–23:59 柱状分布图，自动标识单小时峰值 Peak Hour（🔥）与活跃时段。
  - **7 天 / 30 天历史走势**：折线图与柱状图双形态切换，多日自动结转归档，前台应用活跃排行 (Top Apps) 与常用组合快捷键统计。
  - **绝对本地隐私**：零击键内容、零密码、零光标敏感坐标留存，纯本地内存轻量聚合。

### 📊 数字账本与实用工具 (Ledger & Utilities)
- **Agent 总览 (多 Agent Token 统计)**：
  - **全 Agent 本地聚合**：单窗口聚合 Codex / Antigravity (Gemini) / WorkBuddy / ZCode / DSH 五大本地 Agent 的 Token 消耗与会话量。
  - **全景数据看板**：支持今天 / 昨天 / 近 7 天 / 近 30 天 / 自定义区间；提供 24 小时心流节律卡片、实时 TPS (Tokens/s) 生成速率、半年 GitHub 格热力图、模型份额排行及 CSV 一键导出。
  - **跨 Agent Skill 调用与沉睡治理**：全量逆向分析工具调用记录，对比本机 35+ 已安装技能库，识别 30 天零调用的沉睡技能并提供治理预警。
  - **文件级持久化增量缓存**：mtime + fileSize 增量校验，冷启动扫描时延从 4.2s 降至 0.04s，毫秒级秒开。
- **OTP 工具**：
  - **独立悬浮窗**：展示所有账户实时 6 位验证码，快捷键唤起时自动复制当前验证码到剪贴板。
  - **倒计时提示**：环形进度条实时显示有效剩余秒数（≤10 秒高亮提醒），支持粘贴 URI 或图片二维码识别导入。

---

## 交互设计与体验

- **心智聚类菜单**：右键菜单收敛为「工作台与工具」（收藏夹/待办/闪念/OTP 工具）与「数字监控与管家」（Agent 总览/各 Agent 明细/键鼠统计/端口管家/进程管家）两大心智分区，主菜单清爽精简。
- **统一功能模块管理 (ModuleManager)**：统一偏好设置面板 (`⌘,`) 提供「功能模块」分页，支持自由独立启闭待办、闪念、OTP 工具、Agent 总览、键鼠统计、端口管家与进程管家（核心收藏夹常驻不可关），关闭键鼠统计时彻底注销 CGEventTap 零资源开销。
- **极简圆形关闭按钮规范**：淘汰异形关闭按钮与传统红绿灯，全应用所有子面板（端口管家、进程管家、Agent 总览、收藏夹、OTP 工具、待办、闪念、偏好设置）统一采用右上角极简圆形关闭按钮，操作心智高度统一。
- **Taptic 震动触感反馈**：深度适配 Force Touch 触控板，在待办勾选、路径拷贝、批量保存、撤销、拖拽销毁等高频操作中提供清脆的原生物理触感反馈。
- **macOS 26 原生 Liquid Glass (质感玻璃)**：全应用深度采用苹果原生质感玻璃（`NSGlassEffectView`）元材质与物理光学分层架构，兼顾晶莹高级折射与高对比度文字可读性（旧版系统优雅平滑降级）。

---

## 快捷键速查

### 全局快捷键

| 快捷键 | 功能描述 | 默认状态 |
|:---|:---|:---|
| `⌘⇧P` | 在鼠标当前位置展开收藏面板 | 默认启用 |
| `⌘⇧O` | 展开 OTP 面板并自动复制当前验证码 | 默认启用 |
| `⌘⇧I` | 打开 Codex 统计明细面板 | 默认启用 |
| `⌘⇧G` | 打开 Antigravity 统计明细面板 | 默认启用 |
| `⌘⇧W` | 打开 WorkBuddy 统计明细面板 | 默认启用 |
| 自定义 | Agent 总览、待办录入、闪念投递、键鼠统计、端口管家、进程管家、ZCode/DSH | 可在偏好设置 (`⌘,`) 中一键录制 |

### 核心面板操作快捷键

| 按键 | 适用面板 | 交互动作 |
|:---|:---|:---|
| `空格` | 收藏面板 | Quick Look 预览文件（方向键上下移动实时跟随切换） |
| `Enter` | 收藏面板 / 待办 / 闪念 | 打开选中文件 / 保存待办 / 确认推导投递 |
| `⌘ Enter` | 待办 / 闪念 | 跳过确认，秒级极速直达入库 |
| `⌘Z` | 收藏面板 / 待办 | 撤销误删除文件、误完成任务 |
| `⌘T` / `⌘M` | 待办面板 | 快捷推迟待办任务至明天 / 下周一 |
| `Esc` | 全面板 | 关闭或收起当前浮动面板 |

---

## 技术架构与工程

- **开发语言与框架**：Swift 6 / SwiftUI / AppKit
- **系统底层接入**：Security-Scoped Bookmarks、Carbon Events、CGEvent Tap、EventKit、NSAppleScript 进程内自动化、SMAppService 开机自启
- **系统支持**：macOS 14+ (Sonoma) / 深度适配 macOS 26 (Tahoe) Liquid Glass 质感玻璃

### 源码结构

```text
Sources/
├── CollectionBox/              # 核心框架库
│   ├── Models/                 # 领域模型 (Collection, PortManager, InputStats, OTP, Agent)
│   ├── Services/               # 核心业务服务
│   │   ├── PortManagerService.swift       # lsof 异步监听解析、Docker 穿透与进程控制
│   │   ├── InputStatsService.swift        # CGEvent 键鼠输入捕获、心流节律与历史持久化
│   │   ├── ModuleManager.swift            # 全局功能模块启闭与菜单动态派发
│   │   ├── AppleNotesService.swift        # 备忘录进程内自动化与 HTML DOM 前插
│   │   ├── RemindersService.swift         # EventKit 提醒事项双向同步与管理
│   │   ├── SkillStatsService.swift        # 跨 Agent 技能扫描与持久化增量缓存
│   │   └── ...                            # BookmarkService, Haptics, PinyinMatcher 等
│   ├── ViewModels/             # 视图模型 (CollectionStore, OTPStore)
│   ├── Views/                  # 现代化 SwiftUI 界面组件
│   │   ├── PortManagerView.swift          # 端口管家主面板与排序表格
│   │   ├── PortProcessDetailView.swift    # 进程详情等高卡片与网络安全域
│   │   ├── InputStatsView.swift           # 键鼠统计仪表盘与趋势图表
│   │   ├── StatsDashboardView.swift       # 5 大 Agent Token 统计总览大窗口
│   │   └── ...                            # RootView, SettingsView, TodoCaptureView 等
│   └── AppKit/                 # 窗口控制与系统集成 (WindowControllers, MenuBarController)
└── CollectionBoxApp/           # 应用程序启动入口 (AppDelegate + Info.plist)
```

测试：项目采用独立自动化测试套件（适配纯 CommandLineTools 环境），执行 `swift run PinnerTestRunner`，343 项断言全部通过时退出码为 0。

---

## 安装与使用

### 方式一：从 Release 下载 DMG（推荐）

1. 前往 [GitHub Releases](../../releases) 页面；
2. 下载最新版本 **`Pinner-v1.12.0.dmg`**；
3. 双击打开 DMG，将 Pinner 拖入 `Applications` 应用程序文件夹；
4. 首次启动时右键选择「打开」即可。

> **提示（若提示「已损坏，无法打开」）**：macOS Gatekeeper 对未走 Apple 公证的开源工具有安全拦截，在终端执行以下命令即可清除隔离标记正常打开：
> ```bash
> xattr -cr /Applications/Pinner.app
> ```

### 方式二：从源码构建

构建依赖：DSH 统计模块依赖 Homebrew 的 `zstd`（`brew install zstd`）。

```bash
git clone https://github.com/tienflow/Pinner.git
cd Pinner

# 运行自动化测试套件
SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk swift run PinnerTestRunner

# 编译 Release 并启动
SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk swift build -c release --product CollectionBoxApp
open .build/out/Products/Release/CollectionBoxApp
```

---

## 许可证

本项目基于 [MIT 许可证](LICENSE) 开源。
