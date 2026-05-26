# Mac 端贴边收藏箱

一个菜单栏常驻的 macOS 收藏箱，支持拖拽文件/文件夹进入分类 tab，贴边展开，点击快速打开。

## 技术栈

- Swift 6 / SwiftUI / AppKit
- Swift Package Manager
- Security-Scoped Bookmarks
- macOS 14+ (Sonoma)

## 本地运行

```bash
swift build
swift run CollectionBoxApp
```

> 需要 macOS 14+ 和 Xcode Command Line Tools（或完整 Xcode）。

## 运行测试

```bash
swift run CollectionBoxTests
```

## 项目结构

```
Sources/
├── CollectionBox/           # 核心库
│   ├── Models/              # 数据模型（CollectionTab, BookmarkEntry, WindowState）
│   ├── Services/            # BookmarkService（bookmark 创建/解析/失效处理）
│   ├── ViewModels/          # CollectionStore（状态管理 + 持久化）
│   ├── Views/               # SwiftUI 界面（RootView, EntryRow）
│   └── AppKit/              # AppKit 集成（MenuBarController, EdgeDockWindowController）
├── CollectionBoxApp/        # 可执行入口（AppDelegate + NSApplication）
Tests/
└── CollectionBoxTests/      # 测试套件（25 项断言）
docs/superpowers/            # 设计文档 + 实现计划
```

## 截图

> 截图将在完整 Xcode 环境下补充至 `screenshots/` 目录。

## 许可

MIT
