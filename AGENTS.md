# 项目约定

> 通用规则见全局 `~/.codex/AGENTS.md`，本文件只记录项目特有约定。

## 1. 凭据安全（🔴 红线）

- 密钥、token、密码绝不进代码
- 不要在 commit message 中包含凭据
- 使用环境变量或 .env 文件管理凭据

## 2. 质量验证（🔴 改完必须跑）

- 改完跑项目的构建命令（`npm run build` / `swift build` / `cargo build` / `make` 等）
- 改完跑项目的测试命令（`npm test` / `swift run xxTests` / `cargo test` / `make test` 等）
- 不要为了让代码跑起来而注释掉报错

## 3. Git 规范

- commit message 用英文
- git push 前等用户确认（除非用户明确说"直接推"）
- README.md、Release notes、docs/ 等文档使用中文撰写
- 代码、变量名、命令保持英文

## 4. 发布流程（🔴 必须完整执行）

**发布新版本时，代码、文档、Release 必须同步完成。**

### 4.1 发布 checklist

```
1. 构建/编译 → 验证: 构建成功
2. 打包产物（DMG/app/zip 等）→ 验证: 产物生成
3. 更新 README.md → 验证: 功能列表与代码一致
4. git add + commit → 验证: git status 干净
5. git push → 验证: 远程分支已同步
6. 创建 Release（gh release create 或平台发布）→ 验证: Release 页面正确
7. 更新项目记忆 → 验证: Obsidian vault 已同步
```

### 4.2 常见遗漏（必须检查）

- ✅ 代码已 commit 并 push（不要只创建 release 忘了 push）
- ✅ README.md 功能列表已更新（不要保留已删除的功能描述）
- ✅ 版本号已更新
- ✅ 项目记忆已同步

## 5. 文档同步（🔴 功能变更时必须执行）

| 变更类型 | 必须更新的文档 |
|---------|---------------|
| 新增/删除功能 | README.md 功能列表 |
| 项目结构变更 | README.md 项目结构 |
| 踩坑经验 | Obsidian vault 项目记忆 |
