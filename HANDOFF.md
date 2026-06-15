# Codex Stats 功能 — 开发状态

## 功能概述

菜单栏右键新增「Codex 统计」入口，弹出独立浮动面板，展示 Token 消耗和会话数，支持 4 个时间维度（滑动窗口），每个维度显示环比趋势，含趋势图表。

## 当前状态

**功能已完成，代码已集成但未提交。**

### 已完成

- SQLite 查询层（CodexStatsService.swift）— 查询 `~/.codex/sqlite/state_5.sqlite`
- 面板视图（CodexStatsView.swift）— 4 维度 + 趋势图表
- 浮动面板管理器（CodexStatsWindowController.swift）
- 快捷键管理（CodexStatsHotkeyManager.swift）— 默认 ⌘⇧I
- MenuBarController 菜单项集成
- Release 构建已稳定（已验证 `swift build -c release` + 本地安装运行正常）
- SQL 查询使用 `updated_at` 而非 `created_at`，正确统计跨时间窗口的活跃会话
- `openDB()` 重试机制，覆盖 Codex Desktop WAL checkpoint 导致的短暂锁库

### 待解决

1. **代码清理 + 提交** — 功能已验证通过，待 commit
2. **完整功能验证** — 趋势图表、维度切换、快捷键的边界场景测试

## 文件变更（未提交）

```
新增：Sources/CollectionBox/Services/CodexStatsService.swift
新增：Sources/CollectionBox/Views/CodexStatsView.swift
新增：Sources/CollectionBox/AppKit/CodexStatsWindowController.swift
新增：Sources/CollectionBox/AppKit/CodexStatsHotkeyManager.swift
修改：Sources/CollectionBox/AppKit/MenuBarController.swift
修改：Sources/CollectionBox/AppKit/OTPWindowController.swift
```

## 技术要点

- 数据库：`~/.codex/sqlite/state_5.sqlite`，表 `threads`，字段 `tokens_used`（Token）、`updated_at`（Unix 秒）、`id`（会话数）
- 时间维度：5 小时 / 今天 / 7 天 / 30 天，均为滑动窗口 + 上一周期对比
- 快捷键：Carbon API，签名 `0x504E_4358` ("PNCX")，ID 3
- 已修复 bug：
  - `SQLITE_READONLY`（值 8）→ `SQLITE_OPEN_READONLY`（值 1）
  - SQL 查询从 `created_at` 改为 `updated_at`，修复 5 小时窗口显示 0 的问题
  - `openDB()` 重试 3 次（间隔 100ms），覆盖 WAL checkpoint 短暂锁库

## 下次接手重点

1. 代码清理 + 提交
2. 完整功能验证
3. 考虑发布新版本
