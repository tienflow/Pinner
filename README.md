# Pinner

macOS 菜单栏常驻工具——拖拽文件（夹）到分类收藏夹，随时一键打开。

运行截图见 `image/` 目录。

## 技术栈

- Swift 6 / SwiftUI / AppKit
- Swift Package Manager
- Security-Scoped Bookmarks（安全持久化文件访问）
- Carbon API（全局快捷键）
- macOS 14+ (Sonoma)

## 项目结构

```
Sources/
├── CollectionBox/              # 核心库
│   ├── Models/                 # 数据模型（CollectionTab, BookmarkEntry）
│   ├── Services/               # BookmarkService（bookmark 创建/解析/废纸篓检测）
│   ├── ViewModels/             # CollectionStore（状态 + 持久化 + 自动刷新）
│   ├── Views/                  # SwiftUI 界面（RootView, EntryRow, GridEntryItem）
│   └── AppKit/                 # AppKit 集成
│       ├── MenuBarController.swift    # 菜单栏交互
│       ├── EdgeDockWindowController.swift  # 面板管理
│       └── HotkeyManager.swift        # 全局快捷键
├── CollectionBoxApp/           # 应用入口（AppDelegate + NSApplication）
Tests/
└── CollectionBoxTests/         # 测试套件（46 项断言）
```

## 功能

- **拖拽收藏**：从 Finder 拖文件或文件夹到面板，自动收藏
- **分类管理**：多个 Tab 收藏夹，支持创建、重命名、删除
- **置顶文件**：右键置顶常用文件，置顶区始终显示在顶部
- **快速打开**：双击或选中后按空格 / 回车打开文件
- **列表 / 宫格**：两种视图模式自由切换
- **排序**：按名称、添加时间、上次打开时间、文件类型排序，后两者带分区标题
- **搜索**：实时过滤文件
- **右键菜单**：置顶 / 取消置顶、在 Finder 中显示、移除
- **全局快捷键**：默认 `⌘⇧P`，可自定义，面板在鼠标位置展开
- **自动刷新**：每次展开面板自动验证所有 bookmark，失效文件（含废纸篓）自动移除
- **置顶面板**：点击图钉按钮锁定面板，点击外部不再自动隐藏
- **主题**：浅色、深色、自动

## 快捷键

### 全局快捷键

| 按键 | 功能 |
|------|------|
| `⌘⇧P`（默认） | 在鼠标位置展开面板 |

可在菜单栏右键 → 快捷键 → 设置快捷键 中自定义。

### 面板内快捷键

| 按键 | 功能 |
|------|------|
| ↑ ↓ ← → | 选择文件 |
| Tab | 切换到下一个收藏夹 |
| Shift + Tab | 切换到上一个收藏夹 |
| 空格 / 回车 | 打开选中文件 |
| Esc | 收起面板 |

## 菜单栏

- **左键点击**：从图标右侧展开 / 收起面板
- **右键点击**：打开设置菜单（快捷键、主题、隐藏面板、退出）

## 安装

### 方式一：从 Release 下载

1. 前往 [Releases](../../releases) 页面
2. 下载最新版本的 `Pinner-v1.0.1.dmg`
3. 打开 DMG，将 Pinner 拖入「应用程序」文件夹
4. 首次打开时右键选择「打开」以绕过 Gatekeeper

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
