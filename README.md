# Pinner

你有没有过这种经历：每天都要打开同一批文件夹和文件，在 Finder 里一层层点进去，关掉浏览器标签又重新打开，日复一日。Pinner 解决的就是这两个日常痛点——把你常用的文件和文件夹钉在菜单栏里一键直达，同时内置 TOTP 验证码显示，打开就能看到动态验证码，省去掏手机的步骤。

运行截图见 `image/` 目录。

## 功能

**收藏夹**
- **拖拽收藏**：从 Finder 拖文件或文件夹到面板，自动收藏
- **分类管理**：多个 Tab 收藏夹，支持创建、重命名、删除、在收藏夹之间移动文件
- **置顶文件**：右键置顶常用文件，置顶区始终显示在顶部
- **快速打开**：双击或选中后按空格 / 回车打开文件
- **列表 / 宫格**：两种视图模式自由切换
- **排序**：按名称、添加时间、上次打开时间、文件类型排序，后两者带分区标题
- **搜索**：实时过滤文件
- **右键菜单**：置顶 / 取消置顶、移动到其他收藏夹、在 Finder 中显示、移除
- **自动刷新**：每次展开面板自动验证所有 bookmark，失效文件（含废纸篓）自动移除
- **置顶面板**：点击图钉按钮锁定面板，点击外部不再自动隐藏

**OTP 验证码**
- **独立浮动窗口**：菜单栏右键或快捷键打开，显示所有 OTP 账户的实时验证码
- **自动复制**：通过快捷键打开时，自动复制当前验证码到剪贴板
- **倒计时**：进度条实时显示验证码剩余有效时间，≤10 秒变红提醒
- **添加账户**：粘贴 `otpauth://` URI 自动解析，支持从本地图片识别二维码

**Codex 统计**（开发中）
- **Token 用量**：查询本地 Codex 数据库，按 5 小时 / 今天 / 7 天 / 30 天维度展示 Token 消耗和会话数
- **趋势对比**：每个维度显示与上一周期的环比变化
- **快捷键**：默认 `⌘⇧I`，可自定义

**通用**
- **全局快捷键**：收藏夹 `⌘⇧P`、OTP `⌘⇧O`、Codex 统计 `⌘⇧I`，均可自定义
- **主题**：浅色、深色、自动

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
│   ├── Models/                 # 数据模型（CollectionTab, BookmarkEntry, OTPAccount）
│   ├── Services/               # BookmarkService + OTPService（TOTP 算法）
│   ├── ViewModels/             # CollectionStore + OTPStore（状态 + 持久化）
│   ├── Views/                  # SwiftUI 界面（RootView, OTPView, AddOTPView, QRScannerView）
│   └── AppKit/                 # AppKit 集成
│       ├── MenuBarController.swift        # 菜单栏交互
│       ├── EdgeDockWindowController.swift # 收藏面板管理
│       ├── OTPWindowController.swift      # OTP 面板管理
│       ├── HotkeyManager.swift            # 收藏夹快捷键
│       ├── OTPHotkeyManager.swift         # OTP 快捷键
│       ├── CodexStatsWindowController.swift  # Codex 统计面板（WIP）
│       └── CodexStatsHotkeyManager.swift     # Codex 统计快捷键（WIP）
└── CollectionBoxApp/           # 应用入口（AppDelegate + NSApplication）
```

## 快捷键

### 全局快捷键

| 按键 | 功能 |
|------|------|
| `⌘⇧P`（默认） | 在鼠标位置展开收藏面板 |
| `⌘⇧O`（默认） | 在鼠标位置展开 OTP 面板并自动复制验证码 |
| `⌘⇧I`（默认） | 打开 Codex 统计面板 |

可在菜单栏右键 → 收藏夹快捷键 / OTP 快捷键 / Codex 统计快捷键 → 设置快捷键 中自定义。

### 面板内快捷键

| 按键 | 功能 |
|------|------|
| ↑ ↓ ← → | 选择文件 |
| Tab | 切换到下一个收藏夹 |
| Shift + Tab | 切换到上一个收藏夹 |
| 空格 / 回车 | 打开选中文件 |
| Esc | 收起面板 |

## 菜单栏

- **左键点击**：展开 / 收起收藏面板
- **右键点击**：打开设置菜单

```
Pinner 设置
──────────
收藏夹              ← 打开收藏面板
收藏夹快捷键         ← 子菜单配置
──────────
OTP 验证码          ← 打开 OTP 面板
OTP 快捷键          ← 子菜单配置
──────────
Codex 统计          ← 打开统计面板
Codex 统计快捷键     ← 子菜单配置
──────────
主题                ← 自动 / 浅色 / 深色
──────────
退出
```

## 安装

### 方式一：从 Release 下载

1. 前往 [Releases](../../releases) 页面
2. 下载最新版本的 `Pinner-v1.2.0.dmg`
3. 打开 DMG，将 Pinner 拖入「应用程序」文件夹
4. 首次打开时右键选择「打开」以绕过 Gatekeeper

### 修复「已损坏，无法打开」

macOS 从网上下载的 app 首次打开时可能提示「Pinner 已损坏，无法打开」。在终端执行以下命令即可修复：

```bash
xattr -cr /Applications/Pinner.app
```

### 方式二：从源码编译

需要 macOS 14+ 和 Xcode Command Line Tools：

```bash
git clone https://github.com/tienflow/Pinner.git
cd Pinner
swift build
.build/arm64-apple-macosx/debug/CollectionBoxApp
```

### 设为开机自启

1. 打开「系统设置 → 通用 → 登录项与扩展」
2. 点击「+」添加 Pinner 应用

## 许可

MIT
