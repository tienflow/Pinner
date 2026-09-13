import Foundation
import SQLite3

/// Token usage of the ZCode CLI, read from `~/.zcode/cli/db/db.sqlite`.
///
/// `model_usage` (status = completed) is the record source: it carries the
/// model id directly and its per-request totals sum to the turn aggregates
/// in `turn_usage`. The DB is WAL-held by the running ZCode app, so reads
/// fall back to an immutable=1 URI (same pattern as GeminiStatsService).
final class ZCodeStatsService {
    private let dbPath: String

    init() {
        dbPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".zcode/cli/db/db.sqlite").path
    }

    struct Record {
        let tsMs: Int64
        let tokens: Int
        let freshInput: Int
        let cached: Int
        let output: Int
        let sessionId: String
        let model: String?
        let title: String?
    }

    func collectRecords(sinceMs: Int64) -> [Record] {
        var records: [Record] = []
        queryReadOnly(sql: """
            SELECT mu.started_at, mu.computed_total_tokens, mu.input_tokens,
                   mu.output_tokens, mu.cache_read_input_tokens,
                   mu.cache_creation_input_tokens, mu.model_id, mu.session_id, s.title
            FROM model_usage mu
            LEFT JOIN session s ON s.id = mu.session_id
            WHERE mu.status = 'completed' AND mu.started_at >= ?
            """, sinceMs: sinceMs) { stmt in
            let startedAt = sqlite3_column_int64(stmt, 0)
            let total = Int(sqlite3_column_int64(stmt, 1))
            let input = Int(sqlite3_column_int64(stmt, 2))
            let output = Int(sqlite3_column_int64(stmt, 3))
            let cacheRead = Int(sqlite3_column_int64(stmt, 4))
            let cacheCreation = Int(sqlite3_column_int64(stmt, 5))
            let model = sqlite3_column_text(stmt, 6).map { String(cString: $0) }
            let sessionId = sqlite3_column_text(stmt, 7).map { String(cString: $0) } ?? UUID().uuidString
            let title = sqlite3_column_text(stmt, 8).map { String(cString: $0) }
            // ZCode's input_tokens includes cached reads (like WorkBuddy);
            // computed_total = input + output.
            records.append(Record(
                tsMs: startedAt,
                tokens: total,
                freshInput: max(0, input - cacheRead - cacheCreation),
                cached: cacheRead + cacheCreation,
                output: output,
                sessionId: sessionId,
                model: (model?.isEmpty == false) ? model : nil,
                title: (title?.isEmpty == false) ? title : nil
            ))
        }
        return records
    }

    /// Read-only query with an immutable fallback: the running ZCode app
    /// holds the WAL, and a plain READONLY connection cannot access -shm
    /// (prepare fails rc 14). The immutable URI reads the checkpointed main
    /// file — possibly missing the newest turns, acceptable for statistics.
    private func queryReadOnly(sql: String, sinceMs: Int64, row: (OpaquePointer) -> Void) {
        guard FileManager.default.fileExists(atPath: dbPath) else { return }
        for immutable in [false, true] {
            var db: OpaquePointer?
            let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_URI
            let target = immutable ? "file:\(dbPath)?immutable=1" : dbPath
            guard sqlite3_open_v2(target, &db, flags, nil) == SQLITE_OK, let db = db else {
                if db != nil { sqlite3_close(db) }
                continue
            }
            sqlite3_busy_timeout(db, 3000)
            var stmt: OpaquePointer?
            if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt = stmt {
                sqlite3_bind_int64(stmt, 1, sinceMs)
                while sqlite3_step(stmt) == SQLITE_ROW { row(stmt) }
                sqlite3_finalize(stmt)
                sqlite3_close(db)
                return
            }
            if stmt != nil { sqlite3_finalize(stmt) }
            sqlite3_close(db)
        }
    }
}
