# Codex Stats 功能 — 开发状态

## 功能概述

菜单栏右键新增「Codex 统计」入口，弹出独立浮动面板，展示 Token 消耗和会话数，支持 4 个时间维度（滑动窗口），每个维度显示环比趋势，含趋势图表。

## 当前状态

**代码已集成但未提交。Release 构建崩溃待排查。**

### 已完成

- SQLite 查询层（CodexStatsService.swift）— 查询 `~/.codex/state_5.sqlite`
- 面板视图（CodexStatsView.swift）— 4 维度 + 趋势图表
- 浮动面板管理器（CodexStatsWindowController.swift）
- 快捷键管理（CodexStatsHotkeyManager.swift）— 默认 ⌘⇧I
- MenuBarController 菜单项集成

### 待解决

1. **Release 构建崩溃** — `swift build -c release` 运行 5-10 秒后崩溃，debug 模式稳定。可能与 SQLite 优化行为有关。
2. **功能验证** — 趋势图表、维度切换、快捷键均未经过完整测试。

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

- 数据库：`~/.codex/state_5.sqlite`，表 `threads`，字段 `tokens_used`（Token）、`created_at`（Unix 秒）、`id`（会话数）
- 时间维度：5 小时 / 今天 / 7 天 / 30 天，均为滑动窗口 + 上一周期对比
- 快捷键：Carbon API，签名 `0x504E_4358` ("PNCX")，ID 3
- 已修复 bug：`SQLITE_READONLY`（值 8）→ `SQLITE_OPEN_READONLY`（值 1）

## 下次接手重点

1. 排查 release 构建崩溃（debug 稳定，可能与编译器优化相关）
2. 完整功能验证
3. 代码清理 + 提交
