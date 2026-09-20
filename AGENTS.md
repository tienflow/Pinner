# 项目约定

## 1. 凭据安全（🔴 红线）

- 密钥、token、密码绝不进代码
- 不要在 commit message 中包含凭据
- 使用环境变量或 .env 文件管理凭据

## 2. 本地启动（🔴 必须用 open）

macOS GUI 应用不能用 `./app &` 后台启动——shell 会话结束时子进程会被 SIGHUP 杀掉，表现为启动后几秒就崩溃。正确方式：

```
# 杀掉旧进程 + ad-hoc 签名（解决 Gatekeeper 每次弹窗问题）
pkill -f CollectionBoxApp 2>/dev/null
codesign --force --deep --sign - .build/debug/CollectionBoxApp  # 或 release 路径

# 构建 + 启动
swift build -c release --product CollectionBoxApp && open .build/release/CollectionBoxApp

# debug 模式
swift build --product CollectionBoxApp && open .build/debug/CollectionBoxApp

# 杀掉进程
pkill -f CollectionBoxApp

# 杀掉已安装到 /Applications 的实例（进程名是 Pinner，上面的 CollectionBoxApp 模式匹配不到它）
killall Pinner 2>/dev/null || pkill -f "Pinner.app/Contents/MacOS/Pinner"
```

⚠️ `pkill -f CollectionBoxApp` 只能匹配开发构建；替换 `/Applications/Pinner.app` 前必须先杀安装实例，否则 `open` 会与旧实例并存，菜单栏出现两个图标。

`open` 通过 LaunchServices 启动应用，进程独立于终端。每次 `swift build` 后必须重新 `codesign`，否则 macOS Gatekeeper 会弹窗拦截。

构建依赖：DSH 统计需要 Homebrew 的 zstd（`brew install zstd`），缺失时链接阶段报 `-lzstd` 找不到。

⚠️ **macOS 26+ CLT（SDK 27）缺 `libSwiftUIMacros.dylib`**：CommandLineTools 的 plugins 目录只有 `libObservationMacros.dylib` / `libSwiftMacros.dylib`，导致任何 SwiftUI `@State` 编译报 `plugin for module 'SwiftUIMacros' not found`（全量重建必现；增量构建因缓存可能不报）。临时方案用旧 SDK 构建：

```
SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk swift build --product CollectionBoxApp
SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk swift run PinnerTestRunner
```

根治：安装完整 Xcode 或等待 Apple 修复 CLT。若环境已恢复正常（plugins 目录出现 `libSwiftUIMacros.dylib`），直接用 `swift build` 即可。

### 2.1 修改构建完后自动重启（🔴 铁律：必须主动执行）

每次代码修改完成并验证通过后，**必须主动、自动重启用户本地的 Pinner 进程**，严禁让用户手动重启或等用户催促：

```
# 标准重装并平滑重启流程
SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk swift build -c release --product CollectionBoxApp
cp .build/release/CollectionBoxApp Pinner.app/Contents/MacOS/Pinner
codesign --force --deep --sign - Pinner.app
rm -rf /Applications/Pinner.app && cp -R Pinner.app /Applications/
killall Pinner 2>/dev/null || pkill -f "Pinner.app/Contents/MacOS/Pinner" || true
sleep 1
open /Applications/Pinner.app
```

⚠️ 注意必须更新 `/Applications/Pinner.app` 并启动该 bundle 路径，避免裸二进制启动导致的 UserDefaults 域隔离问题。

## 3. 质量验证（🔴 改完必须跑）

- 改完跑项目的构建命令（`npm run build` / `swift build` / `cargo build` / `make` 等）
- 改完跑项目的测试命令（`npm test` / `swift run xxTests` / `cargo test` / `make test` 等）
- 本项目测试命令：`swift run PinnerTestRunner`（全部断言通过时退出码 0）。⚠️ 纯 CommandLineTools 环境无 XCTest，`swift test` 无法构建，不要使用
- 不要为了让代码跑起来而注释掉报错

## 4. Git 规范

- commit message 用英文
- git push 前等用户确认（除非用户明确说"直接推"）
- README.md、Release notes、docs/ 等文档使用中文撰写
- 代码、变量名、命令保持英文

## 5. 发布流程（🔴 必须完整执行）

**发布新版本时，代码、文档、Release 必须同步完成。**

### 5.1 发布 checklist

```
1. swift build -c release --product CollectionBoxApp → 验证: 构建成功
2. 打包 .app bundle（Pinner.app/Contents/MacOS/Pinner + Info.plist + Resources/AppIcon.icns）；同步将 Info.plist 的 CFBundleShortVersionString / CFBundleVersion 更新为当前版本 → 验证: ls Pinner.app/Contents/MacOS/Pinner + `/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Pinner.app/Contents/Info.plist`
3. 打包 DMG（含拖拽安装布局）：创建临时目录放入 Pinner.app + Applications 符号链接 → hdiutil create (-fs HFS+) 读写 DMG → osascript 设置 Finder 窗口布局（图标视图、96px、左右排列）→ hdiutil convert 转压缩只读 → 验证: DMG 文件生成并可拖拽安装
4. 更新 README.md → 验证: 功能列表与代码一致，安装段的 DMG 文件名与当前版本一致
5. git add + commit → 验证: git status 干净
6. git push + git tag -a vX.X.X → 验证: 远程分支和 tag 已同步
7. gh release create vX.X.X + gh release upload vX.X.X Pinner-vX.X.X.dmg → 验证: Release 页面有 DMG 下载
8. 更新项目记忆 → 验证: Obsidian vault 已同步
```

### 5.2 常见遗漏（必须检查）

- ✅ 代码已 commit 并 push（不要只创建 release 忘了 push）
- ✅ README.md 功能列表已更新（不要保留已删除的功能描述）
- ✅ 版本号已更新
- ✅ 项目记忆已同步

## 6. 文档同步（🔴 功能变更时必须执行）

| 变更类型 | 必须更新的文档 |
|---------|---------------|
| 新增/删除功能 | README.md 功能列表 |
| 项目结构变更 | README.md 项目结构 |
| 踩坑经验 | Obsidian vault 项目记忆 |
