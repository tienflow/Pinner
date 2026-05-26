# Mac 端贴边收藏箱 App 实现计划

> **面向 AI 代理的工作者：** 必需子技能：使用 superpowers:executing-plans 逐任务实现此计划。

**目标：** 做一个菜单栏常驻的 macOS 收藏箱，支持拖拽文件/文件夹进入分类 tab，贴边悬浮展开，点击即可快速打开。

**架构：** 用 SwiftUI 搭主体界面和状态展示，用 AppKit 接管菜单栏、边缘悬浮窗、窗口层级和全局热键。数据层用本地持久化保存 tab、入口、排序和窗口状态，入口通过 bookmark 维持到原文件的引用。

**技术栈：** Swift 6、SwiftUI、AppKit、Combine 或 Observation、FileManager、Security-Scoped Bookmark、XCTest。

---

## 文件职责

- 创建 `Mac收藏箱App.xcodeproj`：Xcode 工程入口。
- 创建 `Sources/App/CollectionBoxApp.swift`：应用启动、菜单栏入口、窗口协调。
- 创建 `Sources/App/MenuBarController.swift`：菜单栏状态、唤出/隐藏主窗。
- 创建 `Sources/App/EdgeDockWindowController.swift`：右侧贴边悬浮窗与展开/收起。
- 创建 `Sources/App/RootView.swift`：主视图、tab 栏、列表、拖拽入口。
- 创建 `Sources/App/ViewModels/CollectionStore.swift`：tab、入口、持久化状态管理。
- 创建 `Sources/App/Models/CollectionModels.swift`：Tab、BookmarkEntry、WindowState 等模型。
- 创建 `Sources/App/Services/BookmarkService.swift`：bookmark 创建、解析、失效处理。
- 创建 `Tests/CollectionBoxTests/CollectionStoreTests.swift`：状态持久化与 CRUD 行为测试。
- 创建 `Tests/CollectionBoxTests/BookmarkServiceTests.swift`：bookmark 创建、解析、失效测试。
- 创建 `README.md`：项目简介、启动方式、目录说明、截图占位。

## 任务 1：建立项目骨架与核心模型

**文件：**
- 创建 `Mac收藏箱App.xcodeproj`
- 创建 `Sources/App/Models/CollectionModels.swift`
- 创建 `Sources/App/CollectionBoxApp.swift`
- 创建 `Tests/CollectionBoxTests/CollectionStoreTests.swift`

- [ ] **步骤 1：编写失败的测试**

```swift
import XCTest
@testable import CollectionBox

final class CollectionStoreTests: XCTestCase {
    func testCreateTabAppendsEmptyTab() {
        let store = CollectionStore()
        store.createTab(named: "工作")
        XCTAssertEqual(store.tabs.map(\.name), ["工作"])
    }
}
```

- [ ] **步骤 2：运行测试验证失败**

运行：`xcodebuild test -scheme CollectionBox -destination 'platform=macOS' -only-testing:CollectionBoxTests/CollectionStoreTests/testCreateTabAppendsEmptyTab`
预期：FAIL，原因是 `CollectionStore` 尚未实现。

- [ ] **步骤 3：编写最少实现代码**

```swift
import Foundation

struct CollectionTab: Identifiable, Codable, Equatable {
    let id: UUID
    var name: String
    var entries: [BookmarkEntry]
}

struct BookmarkEntry: Identifiable, Codable, Equatable {
    let id: UUID
    var displayName: String
    var bookmarkData: Data
}

@Observable
final class CollectionStore {
    var tabs: [CollectionTab] = []

    func createTab(named name: String) {
        tabs.append(CollectionTab(id: UUID(), name: name, entries: []))
    }
}
```

- [ ] **步骤 4：运行测试验证通过**

运行：`xcodebuild test -scheme CollectionBox -destination 'platform=macOS' -only-testing:CollectionBoxTests/CollectionStoreTests/testCreateTabAppendsEmptyTab`
预期：PASS。

- [ ] **步骤 5：Commit**

```bash
git add Mac收藏箱App.xcodeproj Sources/App/Models/CollectionModels.swift Sources/App/CollectionBoxApp.swift Tests/CollectionBoxTests/CollectionStoreTests.swift
git commit -m "feat: scaffold collection box app"
```

## 任务 2：实现 bookmark 导入与失效处理

**文件：**
- 创建 `Sources/App/Services/BookmarkService.swift`
- 修改 `Sources/App/ViewModels/CollectionStore.swift`
- 创建 `Tests/CollectionBoxTests/BookmarkServiceTests.swift`

- [ ] **步骤 1：编写失败的测试**

```swift
import XCTest
@testable import CollectionBox

final class BookmarkServiceTests: XCTestCase {
    func testResolveBookmarkReturnsOriginalURL() throws {
        let url = URL(fileURLWithPath: "/tmp/test.txt")
        let data = try BookmarkService.makeBookmark(for: url)
        let resolved = try BookmarkService.resolveBookmark(data)
        XCTAssertEqual(resolved.standardizedFileURL, url.standardizedFileURL)
    }
}
```

- [ ] **步骤 2：运行测试验证失败**

运行：`xcodebuild test -scheme CollectionBox -destination 'platform=macOS' -only-testing:CollectionBoxTests/BookmarkServiceTests/testResolveBookmarkReturnsOriginalURL`
预期：FAIL，原因是 `BookmarkService` 尚未实现。

- [ ] **步骤 3：编写最少实现代码**

```swift
import Foundation

enum BookmarkService {
    static func makeBookmark(for url: URL) throws -> Data {
        try url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
    }

    static func resolveBookmark(_ data: Data) throws -> URL {
        var stale = false
        return try URL(resolvingBookmarkData: data, options: [.withSecurityScope], relativeTo: nil, bookmarkDataIsStale: &stale)
    }
}
```

- [ ] **步骤 4：运行测试验证通过**

运行：`xcodebuild test -scheme CollectionBox -destination 'platform=macOS' -only-testing:CollectionBoxTests/BookmarkServiceTests/testResolveBookmarkReturnsOriginalURL`
预期：PASS。

- [ ] **步骤 5：Commit**

```bash
git add Sources/App/Services/BookmarkService.swift Sources/App/ViewModels/CollectionStore.swift Tests/CollectionBoxTests/BookmarkServiceTests.swift
git commit -m "feat: add bookmark service"
```

## 任务 3：构建主界面、拖拽和 tab 管理

**文件：**
- 创建 `Sources/App/RootView.swift`
- 修改 `Sources/App/ViewModels/CollectionStore.swift`
- 修改 `Sources/App/Models/CollectionModels.swift`

- [ ] **步骤 1：编写失败的测试**

```swift
import XCTest
@testable import CollectionBox

final class CollectionStoreTests: XCTestCase {
    func testMoveEntryBetweenTabs() {
        let store = CollectionStore()
        store.createTab(named: "A")
        store.createTab(named: "B")
        let entry = BookmarkEntry(id: UUID(), displayName: "file.txt", bookmarkData: Data())
        store.tabs[0].entries = [entry]
        store.moveEntry(entry.id, from: 0, to: 1)
        XCTAssertEqual(store.tabs[0].entries.count, 0)
        XCTAssertEqual(store.tabs[1].entries.map(\.displayName), ["file.txt"])
    }
}
```

- [ ] **步骤 2：运行测试验证失败**

运行：`xcodebuild test -scheme CollectionBox -destination 'platform=macOS' -only-testing:CollectionBoxTests/CollectionStoreTests/testMoveEntryBetweenTabs`
预期：FAIL，原因是 `moveEntry(_:from:to:)` 未实现。

- [ ] **步骤 3：编写最少实现代码**

```swift
extension CollectionStore {
    func moveEntry(_ entryID: UUID, from sourceTabIndex: Int, to destinationTabIndex: Int) {
        guard tabs.indices.contains(sourceTabIndex), tabs.indices.contains(destinationTabIndex) else { return }
        guard let index = tabs[sourceTabIndex].entries.firstIndex(where: { $0.id == entryID }) else { return }
        let entry = tabs[sourceTabIndex].entries.remove(at: index)
        tabs[destinationTabIndex].entries.append(entry)
    }
}
```

- [ ] **步骤 4：运行测试验证通过**

运行：`xcodebuild test -scheme CollectionBox -destination 'platform=macOS' -only-testing:CollectionBoxTests/CollectionStoreTests/testMoveEntryBetweenTabs`
预期：PASS。

- [ ] **步骤 5：Commit**

```bash
git add Sources/App/RootView.swift Sources/App/ViewModels/CollectionStore.swift Sources/App/Models/CollectionModels.swift
git commit -m "feat: add tab management and drag support"
```

## 任务 4：实现菜单栏、贴边窗口和全局热键

**文件：**
- 创建 `Sources/App/MenuBarController.swift`
- 创建 `Sources/App/EdgeDockWindowController.swift`
- 修改 `Sources/App/CollectionBoxApp.swift`

- [ ] **步骤 1：编写失败的测试**

```swift
import XCTest
@testable import CollectionBox

final class WindowControllerTests: XCTestCase {
    func testWindowStatePersistsFrameAndVisibility() {
        let state = WindowState(frame: CGRect(x: 0, y: 0, width: 320, height: 480), isExpanded: true)
        let data = try! JSONEncoder().encode(state)
        let decoded = try! JSONDecoder().decode(WindowState.self, from: data)
        XCTAssertEqual(decoded.isExpanded, true)
        XCTAssertEqual(decoded.frame.size.width, 320)
    }
}
```

- [ ] **步骤 2：运行测试验证失败**

运行：`xcodebuild test -scheme CollectionBox -destination 'platform=macOS' -only-testing:CollectionBoxTests/WindowControllerTests/testWindowStatePersistsFrameAndVisibility`
预期：FAIL，原因是 `WindowState` 尚未定义。

- [ ] **步骤 3：编写最少实现代码**

```swift
import Foundation
import CoreGraphics

struct WindowState: Codable, Equatable {
    var frame: CGRect
    var isExpanded: Bool
}
```

- [ ] **步骤 4：运行测试验证通过**

运行：`xcodebuild test -scheme CollectionBox -destination 'platform=macOS' -only-testing:CollectionBoxTests/WindowControllerTests/testWindowStatePersistsFrameAndVisibility`
预期：PASS。

- [ ] **步骤 5：Commit**

```bash
git add Sources/App/MenuBarController.swift Sources/App/EdgeDockWindowController.swift Sources/App/CollectionBoxApp.swift
git commit -m "feat: add menu bar and edge dock window"
```

## 任务 5：补齐 README 与项目交付

**文件：**
- 创建 `README.md`
- 创建 `screenshots/` 目录

- [ ] **步骤 1：编写失败的检查**

```bash
test -f README.md && echo ok || echo missing
```

- [ ] **步骤 2：运行检查验证失败**

预期：输出 `missing`。

- [ ] **步骤 3：编写最少内容**

```markdown
# Mac 端贴边收藏箱

一个菜单栏常驻的 macOS 收藏箱，支持拖拽文件/文件夹进入分类 tab，贴边展开，点击快速打开。

## 技术栈
- Swift
- SwiftUI
- AppKit

## 本地运行
1. 打开 Xcode 工程
2. 选择 `CollectionBox` scheme
3. 运行到 macOS

## 目录
- `Sources/App/`
- `Tests/CollectionBoxTests/`
- `screenshots/`
```

- [ ] **步骤 4：运行检查验证通过**

运行：`test -f README.md && echo ok`
预期：输出 `ok`。

- [ ] **步骤 5：Commit**

```bash
git add README.md screenshots
git commit -m "docs: add project readme"
```

## 验收标准
- 应用可常驻菜单栏并从右侧贴边展开。
- 可通过拖拽将文件/文件夹加入 tab。
- 入口能通过 bookmark 重新解析并打开。
- Tab、入口、窗口状态可持久化并恢复。
- 本地测试通过，README 可指导启动。

## 风险与约束
- bookmark 失效后需要显式处理，否则用户会看到“看似存在但打不开”的入口。
- 菜单栏悬浮窗和全局热键需要 AppKit，不建议纯 SwiftUI 硬做。
- v1 不包含 Finder 右键扩展和 iCloud，同步会拖慢交付。
