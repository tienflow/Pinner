# 交接文档：Pinner

## 项目概述

Pinner 是一个 macOS 菜单栏常驻工具，支持拖拽文件/文件夹到分类收藏夹，贴边展开面板，一键打开。从零开发到 v1.0.1 发布。

- **GitHub**: https://github.com/tienflow/Pinner
- **分支**: `codex/mac-collection-box`
- **技术栈**: Swift 6 / SwiftUI / AppKit / SPM / Security-Scoped Bookmarks
- **最低系统**: macOS 14+ (Sonoma)
- **cwd**: `/Users/apple/Downloads/dev`

## 当前状态

v1.0.1 已发布 DMG 到 GitHub Releases。功能完整，46 项测试全绿。

### 已完成功能

1. Tab 管理：创建(弹窗命名)、删除、重命名(右键)
2. 文件收藏：拖拽导入(bookmark)、双击/空格打开、单击选中
3. 键盘导航：方向键选择文件、Tab/Shift+Tab 切换收藏夹、Esc 收起
4. 选中反馈：simultaneousGesture 即时响应、背景高亮
5. 列表/宫格切换：视图模式切换、记忆到 UserDefaults
6. 排序：名称(正序/反序)、添加时间、上次打开时间、文件类型——后两者带分区标题
7. 文件类型图标：macOS 系统原生图标
8. 搜索：实时过滤
9. 右键菜单：置顶/取消置顶、在 Finder 中显示、移除
10. 触发边缘：多选(右/左/上/下)、全屏边缘触发、从触发方向展开
11. 面板置顶：图钉按钮控制点击外部是否收起、状态持久化
12. 主题：浅色/深色/自动
13. 自动刷新：展开面板时自动验证所有 bookmark、失效文件(含废纸篓)自动移除
14. 菜单栏图标：SF Symbol `tray.full`，16pt

### 已知限制

- 无 Xcode，只有 Command Line Tools，用 SPM 管理项目
- Swift Testing 不可用，用自定义 `main.swift` executable runner + assert
- `icon(forFileType:)` 在 macOS 12+ 已废弃，但目前仍可用

## 架构

```
Sources/
├── CollectionBox/           # 核心库
│   ├── Models/CollectionModels.swift     # CollectionTab, BookmarkEntry(isPinned), WindowState
│   ├── Services/BookmarkService.swift    # bookmark 创建/解析/废纸篓检测
│   ├── ViewModels/CollectionStore.swift  # CRUD + 持久化 + refresh + recordOpen
│   ├── Views/RootView.swift              # 主界面: tab bar + search/sort + entry list/grid + pin
│   └── AppKit/
│       ├── MenuBarController.swift       # 菜单栏: 左键切换面板, 右键设置菜单
│       └── EdgeDockWindowController.swift # 触发面板 + 主面板(KeyPanel) + 钉住逻辑
├── CollectionBoxApp/CollectionBoxApp.swift  # NSApp 入口, .accessory
Tests/CollectionBoxTests/main.swift          # 自定义测试 runner
```

## 关键踩坑（重要）

1. **废纸篓检测**: `FileManager.fileExists` 对废纸篓文件返回 true。需要额外 `isTrashed` 检测：`URL.path.hasPrefix(trashPath)`
2. **Tab 键拦截**: `.nonactivatingPanel` 下 `performKeyEquivalent` 不可靠。用 `NSEvent.addLocalMonitorForEvents(matching: .keyDown)` 全局拦截
3. **Observer 泄漏**: `onAppear` 注册 NotificationCenter observer 不在 `onDisappear` 移除会导致多次触发
4. **SF Symbol**: 需要 `img.isTemplate = true` 才能自适应深色/浅色。部分 symbol 在 macOS 26 不渲染
5. **菜单栏图标**: `NSImage.SymbolConfiguration(pointSize: 16, weight: .medium)` 控制大小
6. **构建命令**: `swift build -c release --product CollectionBoxApp`，二进制在 `.build/arm64-apple-macosx/release/`
7. **发布流程**: 构建 → 创建 .app bundle (Info.plist 需 LSUIElement=true) → `hdiutil create` DMG → `gh release create`

## 构建与运行

```bash
swift build                              # debug
swift run CollectionBoxTests             # 测试 (46 assertions)
.build/arm64-apple-macosx/debug/CollectionBoxApp  # 运行
swift build -c release --product CollectionBoxApp # release
swift package clean                      # 清理 (519MB → 2MB)
```

## 用户偏好（重要）

- 中文沟通，代码/变量英文
- 偏好直接行动，不喜欢过多确认
- UI 交互响应速度要求高
- 原生 macOS 风格，不要花哨装饰
- git push 前等用户确认
- commit message 英文

## 建议技能

- `$neat-freak` — 会话结束时同步文档和记忆
- `$programming-workflow` — 继续开发新功能时使用完整工作流
- `$frontend-design` — 如果要重新设计 UI
- `$test-driven-development` — 新功能开发时先写测试
