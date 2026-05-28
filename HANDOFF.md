# 交接文档：Pinner

## 项目概述

Pinner 是一个 macOS 菜单栏常驻工具，支持拖拽文件/文件夹到分类收藏夹一键打开，内置 TOTP 验证码显示。从零开发到 v1.1.1。

- **GitHub**: https://github.com/tienflow/Pinner
- **分支**: `codex/mac-collection-box`
- **技术栈**: Swift 6 / SwiftUI / AppKit / SPM / Security-Scoped Bookmarks / Carbon API / RFC 6238 TOTP
- **最低系统**: macOS 14+ (Sonoma)
- **cwd**: `/Users/apple/Documents/My_Code/Pinner`

## 当前状态

v1.1.1 已发布 DMG 到 GitHub Releases。功能完整。

### 未提交的变更

当前工作区有未提交的改动：
- `AGENTS.md` — 小改动
- `Sources/CollectionBoxApp/Resources/AppIcon.icns` — 从 icon.icns（479KB）替换为 icon-1.icns（224KB）
- `Sources/CollectionBoxApp/Resources/Info.plist` — 新增，包含 CFBundleIconFile 等关键配置
- `image/icon-1.png` — 已删除
- `image/icon-1.icns` — 新增（用户提供的新图标）
- `image/icon.icns` — 新增（旧图标备份）
- `Pinner-v1.1.1.dmg` — 新打包的 DMG（515KB）
- `Pinner.app/` — 构建产物，不应提交

**注意**：Info.plist 是本次新增的关键文件，必须提交。之前没有 Info.plist 导致 macOS 安装后找不到图标。

### 本次会话解决的问题

**图标不显示**：拖拽 DMG 中的 app 到 Applications 后，菜单栏不显示图标。

根因：SPM 不编译 `.xcassets`，且项目缺少 `Info.plist`（没有 `CFBundleIconFile` 指向 .icns）。修复：
1. 新增 `Info.plist`，设置 `CFBundleIconFile = AppIcon`
2. 用 `icon-1.icns` 替换旧图标
3. 重新构建 .app bundle 和 DMG

### v1.1.1 新增/变更（相比 v1.0.1）

1. **OTP 验证码**：独立浮动窗口，TOTP 算法（HMAC-SHA1, 6 位, 30 秒），快捷键自动复制，倒计时进度条
2. **QR 码识别添加 OTP**：CIDetector + NSOpenPanel 从本地图片识别二维码
3. **快捷键分离**：收藏夹 `⌘⇧P` / OTP `⌘⇧O`，各自独立 HotkeyManager + UserDefaults
4. **菜单栏重构**：收藏夹 + OTP 验证码 + 主题 + 退出
5. **全局快捷键**：从贴边触发改为 Carbon API 全局快捷键（`⌘⇧P` 默认）
6. **应用图标**：SPM 不编译 .xcassets，需用真正的 .icns 文件（`iconutil -c icns` 生成）

## 架构

```
Sources/
├── CollectionBox/              # 核心库
│   ├── Models/
│   │   ├── CollectionModels.swift     # CollectionTab, BookmarkEntry(isPinned), WindowState
│   │   └── OTPModels.swift            # OTPAccount 模型
│   ├── Services/
│   │   ├── BookmarkService.swift      # bookmark 创建/解析/废纸篓检测
│   │   └── OTPService.swift           # TOTP 算法（RFC 6238）
│   ├── ViewModels/
│   │   ├── CollectionStore.swift      # 收藏 CRUD + 持久化 + refresh
│   │   └── OTPStore.swift             # OTP 账户 CRUD + 持久化
│   ├── Views/
│   │   ├── RootView.swift             # 收藏主界面
│   │   ├── OTPView.swift              # OTP 验证码界面
│   │   ├── AddOTPView.swift           # 添加 OTP 账户（独立 NSWindow）
│   │   └── QRScannerView.swift        # QR 码图片识别
│   └── AppKit/
│       ├── MenuBarController.swift    # 菜单栏交互
│       ├── EdgeDockWindowController.swift  # 收藏面板管理
│       ├── OTPWindowController.swift  # OTP 面板管理
│       ├── HotkeyManager.swift        # 收藏夹全局快捷键（Carbon API）
│       └── OTPHotkeyManager.swift     # OTP 全局快捷键（Carbon API）
└── CollectionBoxApp/
    ├── CollectionBoxApp.swift         # NSApp 入口，.accessory 模式
    └── Resources/
        ├── Info.plist                 # CFBundleIconFile 等（本次新增）
        └── AppIcon.icns               # 应用图标
```

## 关键踩坑（重要）

1. **SPM 不编译 .xcassets**：`CFBundleIconFile` 需要真正的 .icns 文件 + Info.plist。用 `iconutil -c icns` 从 `.appiconset` 生成，不要用 PNG 改扩展名
2. **SPM 不生成 Info.plist**：手动创建 `Resources/Info.plist`，构建 .app bundle 时拷贝到 `Contents/`
3. **图标安装后不显示**：必须有 Info.plist 且 `CFBundleIconFile` 指向正确的 .icns 文件名（不带扩展名）
4. **NSPanel nonactivatingPanel + Cmd+V**：`.nonactivatingPanel` 下 NSTextField 无法接收键盘快捷键。根因修复：添加 Edit 菜单到 `NSApp.mainMenu`
5. **SwiftUI .sheet() 在 NSHostingView+NSPanel 中不工作**：AddOTPView 改用独立 NSWindow
6. **两个 Carbon HotkeyManager 共用 GetApplicationEventTarget**：互相触发，需在回调中校验 hotkey signature
7. **废纸篓检测**：`FileManager.fileExists` 对废纸篓文件返回 true，需额外 `URL.path.hasPrefix(trashPath)` 检测
8. **Tab 键拦截**：`.nonactivatingPanel` 下 `performKeyEquivalent` 不可靠，用 `NSEvent.addLocalMonitorForEvents` 全局拦截
9. **ad-hoc 签名**：`codesign --force --deep --sign -` 确保图标正确关联

## 构建与运行

```bash
swift build                                    # debug
swift build -c release --product CollectionBoxApp  # release
swift run CollectionBoxTests                   # 测试
.build/arm64-apple-macosx/debug/CollectionBoxApp  # 运行 debug
swift package clean                            # 清理构建缓存
```

### 打包 DMG（手动流程）

```bash
# 1. 构建 release
swift build -c release --product CollectionBoxApp

# 2. 创建 .app bundle
mkdir -p Pinner.app/Contents/{MacOS,Resources}
cp .build/release/CollectionBoxApp Pinner.app/Contents/MacOS/Pinner
cp Sources/CollectionBoxApp/Resources/Info.plist Pinner.app/Contents/
cp Sources/CollectionBoxApp/Resources/AppIcon.icns Pinner.app/Contents/Resources/

# 3. 打包 DMG（含拖拽安装布局）
rm -rf /tmp/pinner-dmg-staging
mkdir -p /tmp/pinner-dmg-staging
cp -R Pinner.app /tmp/pinner-dmg-staging/
ln -s /Applications /tmp/pinner-dmg-staging/Applications
hdiutil create -volname "Pinner" -srcfolder /tmp/pinner-dmg-staging -ov -format UDRW /tmp/pinner-rw.dmg
hdiutil attach /tmp/pinner-rw.dmg -readwrite -noverify
# Finder 布局用 osascript 设置（icon view, 96px, 左右排列）
osascript -e 'tell application "Finder" ...'  # 详见 AGENTS.md
hdiutil detach /Volumes/Pinner
hdiutil convert /tmp/pinner-rw.dmg -format UDZO -imagekey zlib-level=9 -o Pinner-vX.X.X.dmg
```

## 发布流程

参见 `AGENTS.md` 第 4 节「发布流程」，完整 checklist 包含：构建 → .app bundle → DMG（含拖拽安装布局）→ README → git tag → GitHub Release。

## 用户偏好（重要）

- 中文沟通，代码/变量/commit message 英文
- 偏好直接行动，不喜欢过多确认
- UI 交互响应速度要求高，原生 macOS 风格
- git push 前等用户确认（除非用户说"直接推"）
- 无 Xcode，只有 Command Line Tools，用 SPM 管理项目
- Swift Testing 不可用，用自定义 executable runner + assert

## 建议技能

- `$neat-freak` — 会话结束时同步文档和记忆
- `$programming-workflow` — 继续开发新功能时使用完整工作流
- `$frontend-design` — 如果要重新设计 UI
- `$test-driven-development` — 新功能开发时先写测试
