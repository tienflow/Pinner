# Pinner

> 钉在 macOS 菜单栏的高效常驻工作台。文件收藏、灵感与待办极速捕获、端口与外设监控、多 Agent AI 消耗账本，一键直达，不为你多开一个窗口。

[![Platform](https://img.shields.io/badge/platform-macOS%2014%2B-blue.svg)](https://github.com/tienflow/Pinner/releases)
[![Swift](https://img.shields.io/badge/Swift-5.9%2B-orange.svg)](https://swift.org)
[![License](https://img.shields.io/badge/license-MIT-green.svg)](LICENSE)
[![Release](https://img.shields.io/badge/release-v1.14.0-brightgreen.svg)](https://github.com/tienflow/Pinner/releases/tag/v1.14.0)

---

## 核心功能

### 📂 工作台与快捷访问 (Workspace & Quick Access)
- **多 Tab 分类收藏**：常用文件夹与文件拖拽快速纳管（自动路径排重），支持 Tab 拖拽调序、跨收藏夹分类整理与置顶固定。
- **最近访问**：常驻快速入口，跨收藏夹聚合最近打开的文件与项目，随用随取。
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
- **进程管理 (Process Manager)**：
  - **算力与内存急救**：Mach/Darwin 内核微秒级采样 CPU 综合负载、统一内存压力等级（正常/受压/告警）与 Swap 磁盘换页，用完即走零常驻电量损耗。
  - **能耗与功耗透视**：采集核心 C-State 唤醒频次与瞬时能耗影响（Energy Impact），支持按功耗双向排序，揪出隐蔽偷电与发热后台。
  - **Top 资源元凶透视**：智能还原 `node` (如 `vite dev`)、`python` 等脚本命令参数，精准抓取卡死与高耗进程。
  - **进程挂起与恢复 (SIGSTOP/SIGCONT)**：重型编译时一键冻结高耗脚本让出算力，编译完一键恢复；支持普通强杀与管理员提权。
- **键鼠统计 (Input Stats)**：
  - **外设全景监控**：基于 macOS `CGEvent` 监听击键总数、KPS、CPS、鼠标物理滑行位移换算（米/公里）与页面滚动距离。
  - **24 小时心流节律**：00:00–23:59 柱状分布图，自动标识单小时峰值 Peak Hour（🔥）与活跃时段。
  - **7 天 / 30 天历史走势**：折线图与柱状图双形态切换，多日自动结转归档，前台应用活跃排行 (Top Apps) 与常用组合快捷键统计。
  - **绝对本地隐私**：零击键内容、零密码、零光标敏感坐标留存，纯本地内存轻量聚合。
- **剪贴统计 (Clipboard Stats)**：
  - **无缝挂载本地库**：开箱适配 PasteNow 商业版本地 SQLite 数据库，零常驻电量消耗与免权限读取。
  - **核心指标大盘**：统计今日新增、选定时段总吞吐、历史总存量与日均频次。
  - **内容形态与来源画像**：解析纯文本/代码、图片截图、网页链接与文件形态分布；还原前 8 大高频来源 App 真实图标与占比。
  - **高频复用资产沉淀**：自动提炼被反复复制的高频片段（命令、常用 Prompt、地址），支持一键点击快速再次回拷。
- **浏览统计 (Browser Stats)**：
  - **Dia + Chrome 跨配置聚合**：自动发现 `Dia/User Data` 与 `Google/Chrome` 下所有本地 Profile 历史库，采用快照只读模式绕过运行期锁冲突，免额外系统权限。
  - **有效停留与冲浪节律**：统计访问次数、有效停留时长（单次封顶 30 分钟过滤挂机噪声）、独立站点数与 24 小时冲浪心流。
  - **域名 Favicon 与高频资产**：直读 `Favicons` 库还原站点图标与 Top 域名排行；提炼高频回访页面（支持一键打开、复制或移出榜单）。
- **流量统计 (Traffic Monitor)**：
  - **整机实时速率**：基于物理网络接口（`en*`）精准差分计算实时整机下载/上传速率，排除回环（`lo0`）与虚拟接口干扰。
  - **周期累计与时段覆盖**：支持今日、昨日、本月多时段切换，展示整机总流量、下载接收、上传发送与监控覆盖时间。
  - **24 小时心流穿透**：00:00–23:59 柱状分布图，原生极简时间槽微光选区，自动高亮单小时峰值 Peak Hour（🔥），点击任意整点柱条穿透联动筛选该时段进程流量排行。
  - **按 Wi-Fi / 接口智能筛选**：自动嗅探当前 Wi-Fi SSID 与物理网卡，支持按特定网络下钻统计。
  - **移动热点感知与流量保护**：接入 `NWPathMonitor` 实时感知 iPhone 个人热点或按流量计费网络，自动弹出顶部保护横幅并在进程表中标注大消耗进程。
  - **进程流量排行榜**：基于 `nettop` 采集进程上下行消耗，还原 App 真实名称与高清图标；自动标识代理/VPN 转发徽章，支持搜索与多维度双向排序。
  - **代理流量归属修正**：检测到本机系统代理（`SCDynamicStore` 读回环代理端口）时，额外采样回环 flow，把「经代理转发」的字节按 `对端端口 = 代理端口` 的占比回填到真实客户端应用名下（写入账本时即完成扣减，保证排行数值单调不倒退）；代理进程仅显示未归属余量，排除 IDE/本地服务的纯回环 RPC 噪声。
  - **口径对账**：表格底部固定展示「未归属（采样缺口）」行，等于整机物理流量减去各进程合计，保证排行与整机总量恒等；采样周期 3 秒，缩短「连接在两次采样间关闭」的漏计窗口。
  - **7 天 / 30 天历史趋势**：总流量、下载量、上传量三维切换，折线图与柱状图双形态自由切换，沉底展示全局网络演进。
  - **本地持久化与 CSV 导出**：定期自动落盘 `traffic_ledger.json`，支持一键导出 CSV 报表。

### 📊 数字账本与实用工具 (Ledger & Utilities)
- **Agent 总览 (多 Agent Token 统计)**：
  - **全 Agent 本地聚合**：单窗口聚合 Codex / Antigravity (Gemini) / WorkBuddy / ZCode / DSH 五大本地 Agent 的 Token 消耗与会话量。
  - **全景数据看板**：支持今天 / 昨天 / 近 7 天 / 近 30 天 / 自定义区间；提供 24 小时心流节律卡片、实时 TPS (Tokens/s) 生成速率、半年 GitHub 格热力图、模型份额排行及 CSV 一键导出。
  - **跨模块工作流 AI 复盘**：复用周度洞察入口按需并发聚合 Agent 账本、Dia/Chrome 浏览域名、PasteNow 剪贴分布、键鼠节律与流量摘要（含可选静默 `KnowledgeC` 亮屏与通知打扰探针），全部本地脱敏聚合后输出跨源心流与提效洞察。
  - **跨 Agent Skill 调用与沉睡治理**：全量逆向分析工具调用记录，对比本机 35+ 已安装技能库，识别 30 天零调用的沉睡技能并提供治理预警。
  - **模型别名重命名**：自定义映射规则将冗长原始模型名（如带时间戳的快照版本号）统一显示为简洁别名，全看板生效，配置本地持久化。
  - **高性能扫描内核**：会话日志统一 mmap 单次读取 + single-flight 并发去重闸门（相同时间窗共享一次扫描），消除重复全量读取与 zstd 重复解压，Dashboard 刷新开销减半。
  - **文件级持久化增量缓存**：mtime + fileSize 增量校验，冷启动扫描时延从 4.2s 降至 0.04s，毫秒级秒开。
  - **数据新鲜度可见**：窗口头部常驻状态标识（如 `更新中 2/5` / `已更新 刚刚`），刷新期间数据区轻微降透明度并显示扫描进度，杜绝把上一轮缓存误读为最新数据；并发刷新按令牌去重，旧扫描结果不会覆盖新数据。
- **OTP 工具**：
  - **独立悬浮窗**：展示所有账户实时 6 位验证码，快捷键唤起时自动复制当前验证码到剪贴板。
  - **倒计时提示与平滑录入**：环形进度条实时显示有效剩余秒数（≤10 秒高亮提醒）；支持粘贴 URI 或图片二维码识别导入，添加完成后面板内无缝切回，新验证码立即可查可复制。

---

## 交互设计与体验

- **心智聚类菜单**：右键菜单按「观测」（Agent 总览/各 Agent 明细/剪贴统计/浏览统计/键鼠统计/流量统计）、「录入」（待办/闪念）与「工具」（端口/进程/收藏夹/验证码）三大心智分区排布，主菜单清爽精简；模块命名由 `ModuleManager` 单一来源统一派发，菜单与设置面板永不漂移。
- **统一功能模块管理 (ModuleManager)**：统一偏好设置面板 (`⌘,`) 提供「功能模块」分页，支持自由独立启闭待办、闪念、OTP 工具、Agent 总览、剪贴统计、浏览统计、键鼠统计、流量统计、端口管家与进程管理（核心收藏夹常驻不可关），关闭键鼠统计时彻底注销 CGEventTap 零资源开销。
- **极简圆形关闭按钮规范**：淘汰异形关闭按钮与传统红绿灯，全应用所有面板与子窗口（端口管家、进程管理、流量统计、Agent 总览、收藏夹、OTP 工具、添加 OTP 账户、待办、闪念、偏好设置、快捷键录制）统一采用极简圆形关闭按钮（收藏夹面板位于左上角，其余位于右上角），操作心智高度统一。
- **统一面板顶栏与 Esc 关闭行为**：全部面板顶栏共用同一规格（14pt 半粗图标 + 14pt 加粗标题 + 16/10 内边距，行高由 24pt 圆形按钮驱动）；全部浮动面板与子窗口由共享 `EscDismissableWindow` / `EscDismissablePanel` 承载，tooltips 承诺的「关闭面板 (⎋)」在每一处真实生效。
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
| 自定义 | Agent 总览、待办录入、闪念投递、剪贴统计、浏览统计、键鼠统计、流量面板、端口管家、进程管理、ZCode/DSH | 可在偏好设置 (`⌘,`) 中一键录制 |

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

- **开发语言与框架**：Swift 5.9+ / SwiftUI / AppKit
- **系统底层接入**：Security-Scoped Bookmarks、Carbon Events、CGEvent Tap、EventKit、NSAppleScript 进程内自动化、SMAppService 开机自启
- **系统支持**：macOS 14+ (Sonoma) / 深度适配 macOS 26 (Tahoe) Liquid Glass 质感玻璃

### 源码结构

```text
Sources/
├── CollectionBox/              # 核心框架库
│   ├── Models/                 # 领域模型 (Collection, PortManager, InputStats, OTP, Agent)
│   ├── Services/               # 核心业务服务
│   │   ├── PortManagerService.swift       # lsof 异步监听解析、Docker 穿透与进程控制
│   │   ├── TrafficMonitorService.swift    # 物理网卡差分吞吐、nettop 进程采集、热点感知与历史记账
│   │   ├── InputStatsService.swift        # CGEvent 键鼠输入捕获、心流节律与历史持久化
│   │   ├── ClipboardStatsService.swift    # PasteNow 本地 SQLite 历史解析、内容分布与高频复用
│   │   ├── BrowserStatsService.swift      # Dia / Chrome 多 Profile 浏览历史聚合与站点停留统计
│   │   ├── WorkflowDigestService.swift    # 跨源工作流摘要与 KnowledgeC 可选探针聚合
│   │   ├── ModuleManager.swift            # 全局功能模块启闭与菜单动态派发
│   │   ├── AppleNotesService.swift        # 备忘录进程内自动化与 HTML DOM 前插
│   │   ├── RemindersService.swift         # EventKit 提醒事项双向同步与管理
│   │   ├── SkillStatsService.swift        # 跨 Agent 技能扫描与持久化增量缓存
│   │   ├── JSONLReader.swift              # 会话日志 mmap 共享读取内核
│   │   ├── ScanGate.swift                 # 高开销扫描 single-flight 并发闸门
│   │   ├── ModelAliasService.swift        # 模型别名重命名规则与本地持久化
│   │   └── ...                            # BookmarkService, Haptics, PinyinMatcher 等
│   ├── ViewModels/             # 视图模型 (CollectionStore, OTPStore)
│   ├── Views/                  # 现代化 SwiftUI 界面组件
│   │   ├── PortManagerView.swift          # 端口管家主面板与排序表格
│   │   ├── TrafficView.swift              # 流量统计面板、24小时心流穿透与进程排行榜
│   │   ├── PortProcessDetailView.swift    # 进程详情等高卡片与网络安全域
│   │   ├── InputStatsView.swift           # 键鼠统计仪表盘与趋势图表
│   │   ├── ClipboardStatsView.swift       # 剪贴统计大盘与高频复用沉淀
│   │   ├── BrowserStatsView.swift         # 浏览统计心流与站点排行榜
│   │   ├── StatsDashboardView.swift       # 5 大 Agent Token 统计总览大窗口
│   │   ├── AgentStatsView.swift           # 单 Agent 紧凑统计面板 (Codex/Antigravity/WorkBuddy/ZCode/DSH)
│   │   └── ...                            # RootView, SettingsView, TodoCaptureView 等
│   └── AppKit/                 # 窗口控制与系统集成 (WindowControllers, MenuBarController)
└── CollectionBoxApp/           # 应用程序启动入口 (AppDelegate + Info.plist)
```

测试：项目采用独立自动化测试套件（适配纯 CommandLineTools 环境），执行 `swift run PinnerTestRunner`，全部断言通过时退出码为 0。

---

## 安装与使用

### 方式一：从 Release 下载 DMG（推荐）

1. 前往 [GitHub Releases](../../releases) 页面；
2. 下载最新版本 **`Pinner-v1.14.0.dmg`**；
3. 双击打开 DMG，将 Pinner 拖入 `Applications` 应用程序文件夹；
4. 首次启动时右键选择「打开」即可。

> **提示（若提示「已损坏，无法打开」）**：macOS Gatekeeper 对未走 Apple 公证的开源工具有安全拦截，在终端执行以下命令即可清除隔离标记正常打开：
> ```bash
> xattr -cr /Applications/Pinner.app
> ```

### 方式二：从源码构建

构建依赖：DSH 统计模块在构建期静态链接 Homebrew 的 `zstd`（`brew install zstd`）；打包后的 `.app` 无运行时外部 dylib 依赖。

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
