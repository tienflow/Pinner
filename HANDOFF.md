# Pinner: Gemini 统计功能交接文档 (HANDOFF)

## 1. 项目与任务概述

- **项目**：Pinner（macOS 菜单栏常驻工具，基于 Swift 6 / SwiftUI / AppKit）
- **本地路径**：`/Users/apple/Documents/My_Code/Pinner`
- **当前分支**：`codex/mac-collection-box`
- **本次交付目标**：
  在 Pinner 中新增「Gemini 统计」面板与全局快捷键（默认 `⌘⇧G`），统计 Google Antigravity 本地运行产生的 Token 消耗量与会话趋势，并落地全量上下文吞吐与明细双轨展示方案。
- **当前运行状态**：
  Release 二进制已编译并安装至 `/Applications/Pinner.app/Contents/MacOS/Pinner`，已完成 ad-hoc 签名并平滑重启（进程 PID `66117` 正常运行中）。

---

## 2. 核心架构与技术实现

### 2.1 数据链路与 Protobuf 解码
- **数据源**：`~/.gemini/antigravity/conversations/*.db` 与会话元数据 `conversation_summaries.db`。
- **查询表**：`steps` 表中的 `step_type = 15`（模型生成与交互步骤）。
- **解码实现**：[`GeminiStatsService.swift`](file:///Users/apple/Documents/My_Code/Pinner/Sources/CollectionBox/Services/GeminiStatsService.swift) 内置轻量 Varint 与 Protobuf 解码逻辑，提取 `CortexStepMetadata (tag 5)` -> `ModelUsageStats (tag 9)`：
  - `tag 2`（`input_tokens`）：单步未缓存的新增净输入；
  - `tag 3`（`output_tokens`）：模型生成 Token（含思考链与最终输出）；
  - `tag 5`（`cache_read_tokens`）：命中的历史上下文缓存 Token。

### 2.2 统计口径（双轨方案）
- **主指标（Token 消耗卡片）**：
  - 计算公式：`input_tokens + cache_read_tokens + output_tokens`（反映大模型实际“阅读”与处理的真实上下文吞吐总量）。
  - 实测数据：近 7 天约 `744.1M`（~7.44 亿），今天约 `72.1M`（~7,208 万）。
- **明细胶囊栏（卡片正下方）**：
  - 呈现：`净输入: 53.1M · 缓存: 687.0M (92%) · 输出: 4.2M`。
  - 悬浮交互：鼠标悬停显示精确到个位数的千分位明细 Tooltip。
- **趋势折线图**：
  - 时间区间：5 小时（25 分钟桶）、今天（1 小时桶）、7 天（1 天桶）、30 天（1 天桶）。
  - 聚合指标与主卡片完全一致（全量吞吐），支持 Hover 交互十字指示线与数值提示。

### 2.3 快捷键与窗口系统
- **Carbon 快捷键**：[`GeminiStatsHotkeyManager.swift`](file:///Users/apple/Documents/My_Code/Pinner/Sources/CollectionBox/AppKit/GeminiStatsHotkeyManager.swift)
  - 签名：`OSType(0x504E_474D)`（"PNGM"），事件 ID 为 `4`（避免与收藏夹 1、OTP 2、Codex 3 冲突）；
  - 默认快捷键：`⌘⇧G`；持久化于 `UserDefaults`。
- **窗口控制器**：[`GeminiStatsWindowController.swift`](file:///Users/apple/Documents/My_Code/Pinner/Sources/CollectionBox/AppKit/GeminiStatsWindowController.swift)
  - 面板尺寸：宽 360px，高 336px（微调高度适配明细胶囊行）。
  - 支持右键菜单栏吸附展开与鼠标就近弹出，失焦或外部点击自动收起。

### 2.4 构建规范与环境陷阱
- **SDK 路径**：在纯 CommandLineTools 环境下编译必须显式指定 SDK，否则会因系统 SDK 缺失报错：
  `swift build -c release --sdk /Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk`
- **Asset 编译**：非完整 Xcode 环境下 `actool` 不可用，`Package.swift` 中对 `CollectionBoxApp` 显式设置了 `exclude: ["Assets.xcassets", "Resources"]`。
- **App 结构**：安装包可执行文件名必须与 `Info.plist` 中的 `CFBundleExecutable`（即 `Pinner`）一致：
  `cp .build/release/CollectionBoxApp /Applications/Pinner.app/Contents/MacOS/Pinner`，随后必须执行 `codesign --force --deep -s - /Applications/Pinner.app`。

---

## 3. 文件变更清单

### 新增文件
1. [`Sources/CollectionBox/Services/GeminiStatsService.swift`](file:///Users/apple/Documents/My_Code/Pinner/Sources/CollectionBox/Services/GeminiStatsService.swift) — Antigravity SQLite 与 Protobuf 数据提取服务
2. [`Sources/CollectionBox/Views/GeminiStatsView.swift`](file:///Users/apple/Documents/My_Code/Pinner/Sources/CollectionBox/Views/GeminiStatsView.swift) — SwiftUI 双轨统计面板与 Canvas 折线图
3. [`Sources/CollectionBox/AppKit/GeminiStatsWindowController.swift`](file:///Users/apple/Documents/My_Code/Pinner/Sources/CollectionBox/AppKit/GeminiStatsWindowController.swift) — 浮动 NSPanel 控制器
4. [`Sources/CollectionBox/AppKit/GeminiStatsHotkeyManager.swift`](file:///Users/apple/Documents/My_Code/Pinner/Sources/CollectionBox/AppKit/GeminiStatsHotkeyManager.swift) — Carbon 全局快捷键注册与录制

### 修改文件
1. [`Package.swift`](file:///Users/apple/Documents/My_Code/Pinner/Package.swift) — 排除资源目录避免 actool 报错
2. [`README.md`](file:///Users/apple/Documents/My_Code/Pinner/README.md) — 补充 Gemini 统计功能说明、快捷键表格与目录树
3. [`Sources/CollectionBox/AppKit/MenuBarController.swift`](file:///Users/apple/Documents/My_Code/Pinner/Sources/CollectionBox/AppKit/MenuBarController.swift) — 菜单栏右键二级菜单集成与浮窗响应
4. [`Sources/CollectionBox/Services/CodexStatsService.swift`](file:///Users/apple/Documents/My_Code/Pinner/Sources/CollectionBox/Services/CodexStatsService.swift) — 清除未使用的循环变量 warning

### 外部文档与记忆库引用
- 详细执行与测试记录：[walkthrough.md](file:///Users/apple/.gemini/antigravity/brain/597ec276-516a-4e36-8e5c-8c66a82529e7/walkthrough.md)
- Obsidian 长期项目知识库：`codex-memory/projects/Pinner.md`

---

## 4. 建议技能 (Suggested Skills)

下次接手该项目的 agent 建议按需调用以下技能：
- `neat-freak`：在进行 git commit 之前，检查并治理工作区遗留的构建产物（如 `Pinner-v1.2.0.dmg`、`Pinner.app/` 等），确保文档与实际代码保持单一真实来源。

---

## 5. 下次接手重点 (Next Steps)

1. **Git 提交**：已完成（2026-09-12，Gemini 统计特性 + 收藏面板升级合并提交；`.dmg` 与根目录 `Pinner.app/` 已加入 `.gitignore`）。
2. **版本发布（可选）**：
   - 版本号升至 `v1.3.0`，发布前跑 `swift run PinnerTestRunner` 确认全部断言通过。
   - 如需制作分发安装包，遵循 `projects/Pinner.md` 中的标准发布 checklist 制作并签名 DMG。
