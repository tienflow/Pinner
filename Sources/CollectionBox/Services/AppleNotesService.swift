import Foundation
import SQLite3

public enum NoteInsertionMode: String, CaseIterable, Identifiable, Codable, Sendable {
    case prepend = "prepend"  // 置顶前插
    case append = "append"    // 尾部追加
    case create = "create"    // 新建笔记

    public var id: String { rawValue }
    public var label: String {
        switch self {
        case .prepend: return "置顶前插"
        case .append: return "尾部追加"
        case .create: return "新建笔记"
        }
    }
}

public struct AppleNoteSummary: Identifiable, Equatable {
    public let id: String
    public let title: String
    public let folder: String

    public init(id: String, title: String, folder: String) {
        self.id = id
        self.title = title
        self.folder = folder
    }
}

public enum AppleNotesError: LocalizedError {
    case permissionDenied
    case noteNotFound(String)
    case folderNotFound(String)
    case scriptFailed(String)
    case emptyContent

    public var errorDescription: String? {
        switch self {
        case .permissionDenied:
            return "macOS 权限错误 (-54)。请在系统设置中允许 Pinner 控制备忘录 (自动化 -> 备忘录)。"
        case .noteNotFound(let title):
            return "未找到备忘录：\(title)"
        case .folderNotFound(let folder):
            return "未找到备忘录文件夹：\(folder)"
        case .scriptFailed(let reason):
            return "备忘录操作失败：\(reason)"
        case .emptyContent:
            return "投递内容不能为空"
        }
    }
}

/// Service providing interaction with macOS Notes.app.
/// Read path uses direct readonly SQLite queries (zero Notes.app launch / zero Dock icon interruption).
/// Write path uses in-process NSAppleScript to preserve native iCloud sync and note creation semantics.
public final class AppleNotesService: @unchecked Sendable {
    public static let shared = AppleNotesService()

    private let executionLock = NSRecursiveLock()

    public init() {}

    // MARK: - Local SQLite Direct Query (Zero Dock / Notes.app Launch)

    public static var noteStoreDatabasePath: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return "\(home)/Library/Group Containers/group.com.apple.notes/NoteStore.sqlite"
    }

    /// Read folder tree directly from local Notes SQLite database in readonly mode.
    /// Returns nil if database file does not exist or cannot be read.
    public static func fetchFolderTreeFromSQLite() -> [FolderItem]? {
        let dbPath = noteStoreDatabasePath
        guard FileManager.default.fileExists(atPath: dbPath) else {
            return nil
        }

        var db: OpaquePointer?
        let uri = "file:\(dbPath)?mode=ro"
        let status = sqlite3_open_v2(uri, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil)
        guard status == SQLITE_OK, let db else {
            if let db { sqlite3_close(db) }
            return nil
        }
        defer { sqlite3_close(db) }

        // Query folders and non-deleted notes ordered by folder, then modification date desc
        let query = """
        SELECT f.Z_PK, f.ZTITLE2, n.ZTITLE1
        FROM ZICCLOUDSYNCINGOBJECT f
        LEFT JOIN ZICCLOUDSYNCINGOBJECT n ON n.ZFOLDER = f.Z_PK 
            AND n.ZTITLE1 IS NOT NULL 
            AND (n.ZMARKEDFORDELETION IS NULL OR n.ZMARKEDFORDELETION = 0)
        WHERE f.ZTITLE2 IS NOT NULL 
            AND (f.ZFOLDERTYPE IS NULL OR f.ZFOLDERTYPE != 1)
            AND (f.ZMARKEDFORDELETION IS NULL OR f.ZMARKEDFORDELETION = 0)
            AND f.ZTITLE2 NOT IN ('Recently Deleted', '最近删除')
        ORDER BY CASE WHEN f.ZTITLE2 = 'Notes' THEN 0 ELSE 1 END, f.Z_PK ASC, n.ZMODIFICATIONDATE1 DESC;
        """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, query, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            return nil
        }
        defer { sqlite3_finalize(stmt) }

        var folderOrder: [Int64] = []
        var folderNames: [Int64: String] = [:]
        var folderNotes: [Int64: [String]] = [:]

        while sqlite3_step(stmt) == SQLITE_ROW {
            let folderId = sqlite3_column_int64(stmt, 0)
            if let folderNamePtr = sqlite3_column_text(stmt, 1) {
                let folderName = String(cString: folderNamePtr)
                if folderNames[folderId] == nil {
                    folderNames[folderId] = folderName
                    folderOrder.append(folderId)
                    folderNotes[folderId] = []
                }
            }
            if let noteTitlePtr = sqlite3_column_text(stmt, 2) {
                let noteTitle = String(cString: noteTitlePtr).trimmingCharacters(in: .whitespacesAndNewlines)
                if !noteTitle.isEmpty {
                    folderNotes[folderId]?.append(noteTitle)
                }
            }
        }

        let items = folderOrder.compactMap { id -> FolderItem? in
            guard let name = folderNames[id] else { return nil }
            return FolderItem(name: name, notes: folderNotes[id] ?? [])
        }

        return items
    }

    // MARK: - AppleScript Execution

    /// Execute AppleScript in-process via NSAppleScript to bind with Pinner's permanent TCC bundle authorization.
    public func runScript(_ script: String) async throws -> String {
        try await Task.detached { [self] in
            executionLock.lock()
            defer { executionLock.unlock() }

            var errorDict: NSDictionary?
            guard let appleScript = NSAppleScript(source: script) else {
                throw AppleNotesError.scriptFailed("无法编译 AppleScript")
            }
            let descriptor = appleScript.executeAndReturnError(&errorDict)
            if let error = errorDict {
                let errorNumber = error[NSAppleScript.errorNumber] as? Int ?? 0
                let errorMessage = error[NSAppleScript.errorMessage] as? String ?? "未知错误"
                if errorNumber == -1743 || errorNumber == -54 {
                    throw AppleNotesError.permissionDenied
                }
                throw AppleNotesError.scriptFailed("\(errorMessage) (错误码: \(errorNumber))")
            }

            if descriptor.numberOfItems > 0 {
                var items: [String] = []
                for i in 1...descriptor.numberOfItems {
                    if let itemStr = descriptor.atIndex(i)?.stringValue {
                        items.append(itemStr)
                    }
                }
                return items.joined(separator: "\n")
            }
            if descriptor.descriptorType == typeAEList {
                return ""
            }
            return descriptor.stringValue ?? ""
        }.value
    }

    // MARK: - Folder & Note Discovery

    public struct FolderItem: Equatable, Sendable {
        public var name: String
        public var notes: [String]
        public init(name: String, notes: [String] = []) {
            self.name = name
            self.notes = notes
        }
    }

    private var cachedFolderTree: [FolderItem]?
    private var folderTreeCachedAt: Date?
    private let folderTreeTTL: TimeInterval = 300 // 5 minutes cache

    /// Invalidate in-memory folder tree cache.
    public func invalidateFolderTreeCache() {
        executionLock.lock()
        cachedFolderTree = nil
        folderTreeCachedAt = nil
        executionLock.unlock()
    }

    /// Fetches all folders and their note titles in one roundtrip with in-memory TTL caching.
    /// Prefers direct readonly SQLite query to prevent Notes.app from launching in the Dock.
    public func getFolderTree(force: Bool = false) async throws -> [FolderItem] {
        executionLock.lock()
        if !force, let cached = cachedFolderTree, let cachedAt = folderTreeCachedAt,
           Date().timeIntervalSince(cachedAt) < folderTreeTTL {
            executionLock.unlock()
            return cached
        }
        executionLock.unlock()

        // 1. 优先尝试本地 SQLite 直读（只读 WAL 模式，杜绝唤起 Notes.app 与 Dock 栏图标）
        if let sqliteTree = Self.fetchFolderTreeFromSQLite() {
            executionLock.lock()
            cachedFolderTree = sqliteTree
            folderTreeCachedAt = Date()
            executionLock.unlock()
            return sqliteTree
        }

        // 2. 降级容灾：若 SQLite 无法读取，回退到 AppleScript
        let script = """
        tell application "Notes"
            set res to ""
            set prevTID to AppleScript's text item delimiters
            repeat with f in every folder
                set fName to name of f
                if fName is not "Recently Deleted" and fName is not "最近删除" then
                    set nList to name of every note of f
                    set AppleScript's text item delimiters to tab
                    set noteStr to (nList as text)
                    set AppleScript's text item delimiters to prevTID
                    if res is "" then
                        set res to fName & "\n" & noteStr
                    else
                        set res to res & "\n---\n" & fName & "\n" & noteStr
                    end if
                end if
            end repeat
            return res
        end tell
        """
        let raw = try await runScript(script)
        if raw.isEmpty { return [] }

        var result: [FolderItem] = []
        let sections = raw.components(separatedBy: "\n---\n")
        for section in sections {
            let lines = section.components(separatedBy: "\n")
            guard let folderName = lines.first?.trimmingCharacters(in: .whitespacesAndNewlines), !folderName.isEmpty else {
                continue
            }
            let noteLine = lines.count > 1 ? lines[1] : ""
            let notes = noteLine.components(separatedBy: "\t")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            result.append(FolderItem(name: folderName, notes: notes))
        }

        executionLock.lock()
        cachedFolderTree = result
        folderTreeCachedAt = Date()
        executionLock.unlock()

        return result
    }

    /// Get all available folders in Notes.app (excluding Recently Deleted).
    /// Prefers local SQLite cache to avoid launching Notes.app.
    public func getFolders() async throws -> [String] {
        if let tree = try? await getFolderTree(), !tree.isEmpty {
            return tree.map { $0.name }
        }

        let script = """
        tell application "Notes"
            set fList to {}
            repeat with f in every folder
                set fName to name of f
                if fName is not "Recently Deleted" and fName is not "最近删除" then
                    set end of fList to fName
                end if
            end repeat
            return fList
        end tell
        """
        let raw = try await runScript(script)
        if raw.isEmpty { return [] }
        return raw.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    /// Get note titles in a specific folder or across the app.
    /// Prefers local SQLite cache to avoid launching Notes.app.
    public func getNoteTitles(inFolder folder: String? = nil) async throws -> [String] {
        if let tree = try? await getFolderTree(), !tree.isEmpty {
            if let folder, !folder.isEmpty {
                if let matched = tree.first(where: { $0.name.caseInsensitiveCompare(folder) == .orderedSame }) {
                    return matched.notes
                }
            } else {
                return tree.flatMap { $0.notes }
            }
        }

        let script: String
        if let folder, !folder.isEmpty {
            let escaped = folder.replacingOccurrences(of: "\"", with: "\\\"")
            script = """
            tell application "Notes"
                try
                    return name of every note of folder "\(escaped)"
                on error
                    try
                        return name of every note
                    on error
                        return {}
                    end try
                end try
            end tell
            """
        } else {
            script = """
            tell application "Notes"
                try
                    return name of every note
                on error
                    return {}
                end try
            end tell
            """
        }
        let raw = try await runScript(script)
        if raw.isEmpty { return [] }
        return raw.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    /// Fetch raw HTML body of a note by title, optionally scoped to a target folder.
    public func getNoteBody(title: String, folder: String? = nil) async throws -> String {
        let escapedTitle = title.replacingOccurrences(of: "\"", with: "\\\"")
        let script: String
        if let folder, !folder.isEmpty {
            let escapedFolder = folder.replacingOccurrences(of: "\"", with: "\\\"")
            script = """
            tell application "Notes"
                try
                    set matchingNotes to (every note of folder "\(escapedFolder)" whose name is "\(escapedTitle)")
                    if (count of matchingNotes) > 0 then
                        return body of item 1 of matchingNotes
                    end if
                end try
                set matchingNotes to (every note whose name is "\(escapedTitle)")
                if (count of matchingNotes) > 0 then
                    return body of item 1 of matchingNotes
                else
                    return ""
                end if
            end tell
            """
        } else {
            script = """
            tell application "Notes"
                set matchingNotes to (every note whose name is "\(escapedTitle)")
                if (count of matchingNotes) > 0 then
                    return body of item 1 of matchingNotes
                else
                    return ""
                end if
            end tell
            """
        }
        return try await runScript(script)
    }

    /// Read first few lines of text from note for day-count or format inference.
    public func getNoteHeadSnippet(title: String, folder: String? = nil, maxLines: Int = 3) async throws -> String? {
        let body = try await getNoteBody(title: title, folder: folder)
        guard !body.isEmpty else { return nil }

        // Strip HTML tags for clean text analysis
        let plainText = Self.stripHTML(body)
        let lines = plainText.split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        guard !lines.isEmpty else { return nil }
        return lines.prefix(maxLines).joined(separator: "\n")
    }

    // MARK: - Note Operations

    /// Append, prepend, or create a note in Notes.app.
    public func write(title: String, folder: String, content: String, mode: NoteInsertionMode) async throws {
        guard !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AppleNotesError.emptyContent
        }

        switch mode {
        case .create:
            try await createNote(title: title, folder: folder, bodyMarkdown: content)
        case .prepend:
            try await prependToNote(title: title, folder: folder, content: content)
        case .append:
            try await appendToNote(title: title, folder: folder, content: content)
        }
    }

    private func createNote(title: String, folder: String, bodyMarkdown: String) async throws {
        let targetFolder = folder.isEmpty ? "Notes" : folder
        let bodyHTML = Self.markdownToHTML(bodyMarkdown)
        let fullHTML = "<h1>\(Self.escapeHTML(title))</h1><div><br></div>" + bodyHTML

        let escapedFolder = targetFolder.replacingOccurrences(of: "\"", with: "\\\"")
        let escapedHTML = fullHTML.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")

        let script = """
        tell application "Notes"
            if not (exists folder "\(escapedFolder)") then
                make new folder with properties {name:"\(escapedFolder)"}
            end if
            set targetFolder to folder "\(escapedFolder)"
            make new note at targetFolder with properties {body:"\(escapedHTML)"}
        end tell
        """
        _ = try await runScript(script)
        invalidateFolderTreeCache()
    }

    private func prependToNote(title: String, folder: String, content: String) async throws {
        var oldBody = try await getNoteBody(title: title, folder: folder)
        if oldBody.isEmpty {
            // Note does not exist, fallback to create
            try await createNote(title: title, folder: folder, bodyMarkdown: content)
            return
        }

        let newBody = Self.insertPrepend(into: oldBody, content: content)
        try await updateNoteBody(title: title, folder: folder, newBody: newBody)
    }

    private func appendToNote(title: String, folder: String, content: String) async throws {
        var oldBody = try await getNoteBody(title: title, folder: folder)
        if oldBody.isEmpty {
            try await createNote(title: title, folder: folder, bodyMarkdown: content)
            return
        }

        let newBody = Self.insertAppend(into: oldBody, content: content)
        try await updateNoteBody(title: title, folder: folder, newBody: newBody)
    }

    private func updateNoteBody(title: String, folder: String? = nil, newBody: String) async throws {
        let escapedTitle = title.replacingOccurrences(of: "\"", with: "\\\"")
        let escapedBody = newBody.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")

        let script: String
        if let folder, !folder.isEmpty {
            let escapedFolder = folder.replacingOccurrences(of: "\"", with: "\\\"")
            script = """
            tell application "Notes"
                set didUpdate to false
                try
                    set matchingNotes to (every note of folder "\(escapedFolder)" whose name is "\(escapedTitle)")
                    if (count of matchingNotes) > 0 then
                        set body of item 1 of matchingNotes to "\(escapedBody)"
                        set didUpdate to true
                    end if
                end try
                if not didUpdate then
                    set matchingNotes to (every note whose name is "\(escapedTitle)")
                    if (count of matchingNotes) > 0 then
                        set body of item 1 of matchingNotes to "\(escapedBody)"
                    end if
                end if
            end tell
            """
        } else {
            script = """
            tell application "Notes"
                set matchingNotes to (every note whose name is "\(escapedTitle)")
                if (count of matchingNotes) > 0 then
                    set body of item 1 of matchingNotes to "\(escapedBody)"
                end if
            end tell
            """
        }
        _ = try await runScript(script)
    }

    // MARK: - HTML Formatting Helpers

    public static func stripHTML(_ html: String) -> String {
        var text = html
        text = text.replacingOccurrences(of: "<br>", with: "\n")
        text = text.replacingOccurrences(of: "<br/>", with: "\n")
        text = text.replacingOccurrences(of: "</div>", with: "\n")
        text = text.replacingOccurrences(of: "</li>", with: "\n")
        text = text.replacingOccurrences(of: "</h[1-6]>", with: "\n", options: .regularExpression)
        text = text.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: "&nbsp;", with: " ")
        text = text.replacingOccurrences(of: "&amp;", with: "&")
        text = text.replacingOccurrences(of: "&lt;", with: "<")
        text = text.replacingOccurrences(of: "&gt;", with: ">")
        return text
    }

    public static func escapeHTML(_ str: String) -> String {
        str.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    public static func markdownToHTML(_ md: String) -> String {
        let lines = md.split(separator: "\n", omittingEmptySubsequences: false)
        var htmlLines: [String] = []
        var inList = false

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let isBullet = trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ")

            if inList && !isBullet {
                htmlLines.append("</ul>")
                inList = false
            }

            if trimmed.isEmpty {
                htmlLines.append("<div><br></div>")
                continue
            }

            if isBullet {
                if !inList {
                    htmlLines.append("<ul>")
                    inList = true
                }
                let itemContent = String(trimmed.dropFirst(2))
                htmlLines.append("<li>\(escapeHTML(itemContent))<br></li>")
            } else if trimmed.hasPrefix("# ") {
                htmlLines.append("<h1>\(escapeHTML(String(trimmed.dropFirst(2))))</h1>")
            } else if trimmed.hasPrefix("## ") {
                htmlLines.append("<h2>\(escapeHTML(String(trimmed.dropFirst(3))))</h2>")
            } else {
                htmlLines.append("<div>\(escapeHTML(trimmed))</div>")
            }
        }

        if inList {
            htmlLines.append("</ul>")
        }

        return htmlLines.joined()
    }

    public static func insertPrepend(into oldBody: String, content: String) -> String {
        let isBullet = content.trimmingCharacters(in: .whitespaces).hasPrefix("- ") ||
                       content.trimmingCharacters(in: .whitespaces).hasPrefix("* ")

        // If the note has a <ul> list and the new content is a list item
        if isBullet, let ulRange = oldBody.range(of: "<ul[^>]*>", options: .regularExpression) {
            let rawItem = content.trimmingCharacters(in: .whitespaces)
            let strippedBullet = rawItem.hasPrefix("- ") ? String(rawItem.dropFirst(2)) : (rawItem.hasPrefix("* ") ? String(rawItem.dropFirst(2)) : rawItem)
            let newLi = "<li>\(escapeHTML(strippedBullet))<br></li>"
            var modified = oldBody
            modified.insert(contentsOf: newLi, at: ulRange.upperBound)
            return modified
        }

        // Otherwise insert after first title/header tag
        if let headerRange = oldBody.range(of: "^(<div>.*?</div>|<h[1-6]>.*?</h[1-6]>)", options: [.regularExpression, .caseInsensitive]) {
            var modified = oldBody
            let added = markdownToHTML(content)
            modified.insert(contentsOf: added, at: headerRange.upperBound)
            return modified
        }

        // Fallback: prepend at top
        return markdownToHTML(content) + oldBody
    }

    public static func insertAppend(into oldBody: String, content: String) -> String {
        let isBullet = content.trimmingCharacters(in: .whitespaces).hasPrefix("- ") ||
                       content.trimmingCharacters(in: .whitespaces).hasPrefix("* ")

        if isBullet, let closeUlRange = oldBody.range(of: "</ul>", options: [.backwards, .caseInsensitive]) {
            let rawItem = content.trimmingCharacters(in: .whitespaces)
            let strippedBullet = rawItem.hasPrefix("- ") ? String(rawItem.dropFirst(2)) : (rawItem.hasPrefix("* ") ? String(rawItem.dropFirst(2)) : rawItem)
            let newLi = "<li>\(escapeHTML(strippedBullet))<br></li>"
            var modified = oldBody
            modified.insert(contentsOf: newLi, at: closeUlRange.lowerBound)
            return modified
        }
        return oldBody + markdownToHTML(content)
    }
}
