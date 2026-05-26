# Pinner

macOS 菜单栏常驻工具——拖拽文件（夹）到分类收藏夹，随时一键打开。

运行截图见 `image/` 目录。


## 技术栈

- Swift 6 / SwiftUI / AppKit
- Swift Package Manager
- Security-Scoped Bookmarks（安全持久化文件访问）
- macOS 14+ (Sonoma)

## 项目结构

```
Sources/
├── CollectionBox/              # 核心库
│   ├── Models/                 # 数据模型
│   ├── Services/               # BookmarkService
│   ├── ViewModels/             # CollectionStore（状态 + 持久化）
│   ├── Views/                  # SwiftUI 界面
│   └── AppKit/                 # AppKit 集成
├── CollectionBoxApp/           # 应用入口
Tests/
└── CollectionBoxTests/         # 测试套件
```

## 安装

### 方式一：从 Release 下载

1. 前往 [Releases](../../releases) 页面
2. 下载最新版本的 `Pinner.app.zip`
3. 解压后将 Pinner.app 拖入「应用程序」文件夹
4. 首次打开时右键选择「打开」以绕过 Gatekeeper

### 方式二：从源码编译

需要 macOS 14+ 和 Xcode Command Line Tools：

```bash
git clone <repo-url>
cd Pinner
swift build
.build/arm64-apple-macosx/debug/CollectionBoxApp
```

### 设为开机自启

1. 打开「系统设置 → 通用 → 登录项与扩展」
2. 点击「+」添加 Pinner 应用

## 功能

- **拖拽收藏**：从 Finder 拖文件或文件夹到面板，自动收藏
- **分类管理**：多个 Tab 收藏夹，支持创建、重命名、删除
- **置顶文件**：右键置顶常用文件，置顶区始终显示在顶部
- **快速打开**：双击或选中后按空格 / 回车打开文件
- **列表 / 宫格**：两种视图模式自由切换
- **排序**：按名称、添加时间、上次打开时间、文件类型排序，后两者带分区标题
- **搜索**：实时过滤文件
- **右键菜单**：置顶 / 取消置顶、在 Finder 中显示、移除
- **贴边触发**：鼠标移至屏幕边缘自动展开面板
- **多边缘**：支持右侧、左侧、顶部、底部，可多选
- **置顶面板**：点击图钉按钮锁定面板，点击外部不再自动隐藏
- **主题**：浅色、深色、自动

## 快捷键

| 按键 | 功能 |
|------|------|
| ↑ ↓ ← → | 选择文件 |
| Tab | 切换到下一个收藏夹 |
| Shift + Tab | 切换到上一个收藏夹 |
| 空格 / 回车 | 打开选中文件 |
| Esc | 收起面板 |

## 菜单栏

- **左键点击**：展开 / 收起面板
- **右键点击**：打开设置菜单（触发边缘、主题、隐藏面板、退出）

## 许可

MIT
