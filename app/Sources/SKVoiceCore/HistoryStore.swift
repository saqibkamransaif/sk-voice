import Foundation
import SQLite3

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// SQLite-backed capture history. All access is serialized on an internal queue.
public final class HistoryStore: @unchecked Sendable {
    private var db: OpaquePointer?
    private let queue = DispatchQueue(label: "skvoice.history")

    public init(path: String) throws {
        try FileManager.default.createDirectory(
            at: URL(fileURLWithPath: path).deletingLastPathComponent(),
            withIntermediateDirectories: true)
        guard sqlite3_open(path, &db) == SQLITE_OK else {
            throw HistoryError.open(String(cString: sqlite3_errmsg(db)))
        }
        exec("PRAGMA journal_mode=WAL")
        exec("""
        CREATE TABLE IF NOT EXISTS entries (
            id TEXT PRIMARY KEY,
            mode TEXT NOT NULL,
            raw TEXT NOT NULL,
            final TEXT NOT NULL,
            app TEXT NOT NULL,
            duration REAL NOT NULL,
            created_at REAL NOT NULL
        )
        """)
        exec("CREATE INDEX IF NOT EXISTS idx_entries_created ON entries(created_at DESC)")
    }

    deinit {
        sqlite3_close(db)
    }

    private func exec(_ sql: String) {
        sqlite3_exec(db, sql, nil, nil, nil)
    }

    public func save(_ entry: HistoryEntry) throws {
        try queue.sync {
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            let sql = "INSERT OR REPLACE INTO entries VALUES (?,?,?,?,?,?,?)"
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                throw HistoryError.query(String(cString: sqlite3_errmsg(db)))
            }
            sqlite3_bind_text(stmt, 1, entry.id, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 2, entry.mode.rawValue, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 3, entry.rawTranscript, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 4, entry.finalText, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 5, entry.appName, -1, SQLITE_TRANSIENT)
            sqlite3_bind_double(stmt, 6, entry.durationSeconds)
            sqlite3_bind_double(stmt, 7, entry.createdAt.timeIntervalSinceReferenceDate)
            guard sqlite3_step(stmt) == SQLITE_DONE else {
                throw HistoryError.query(String(cString: sqlite3_errmsg(db)))
            }
        }
    }

    public func recent(limit: Int, search: String?) -> [HistoryEntry] {
        queue.sync {
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            var sql = "SELECT id, mode, raw, final, app, duration, created_at FROM entries"
            if search != nil {
                sql += " WHERE final LIKE ? OR raw LIKE ?"
            }
            sql += " ORDER BY created_at DESC LIMIT ?"
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
            var index: Int32 = 1
            if let search {
                let pattern = "%\(search)%"
                sqlite3_bind_text(stmt, index, pattern, -1, SQLITE_TRANSIENT); index += 1
                sqlite3_bind_text(stmt, index, pattern, -1, SQLITE_TRANSIENT); index += 1
            }
            sqlite3_bind_int(stmt, index, Int32(limit))

            var results: [HistoryEntry] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                guard let id = sqlite3_column_text(stmt, 0),
                      let modeRaw = sqlite3_column_text(stmt, 1),
                      let mode = CaptureMode(rawValue: String(cString: modeRaw)),
                      let raw = sqlite3_column_text(stmt, 2),
                      let final = sqlite3_column_text(stmt, 3),
                      let app = sqlite3_column_text(stmt, 4) else { continue }
                results.append(HistoryEntry(
                    id: String(cString: id),
                    mode: mode,
                    rawTranscript: String(cString: raw),
                    finalText: String(cString: final),
                    appName: String(cString: app),
                    durationSeconds: sqlite3_column_double(stmt, 5),
                    createdAt: Date(timeIntervalSinceReferenceDate: sqlite3_column_double(stmt, 6))))
            }
            return results
        }
    }

    public func delete(id: String) throws {
        try queue.sync {
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            guard sqlite3_prepare_v2(db, "DELETE FROM entries WHERE id = ?", -1, &stmt, nil)
                    == SQLITE_OK else {
                throw HistoryError.query(String(cString: sqlite3_errmsg(db)))
            }
            sqlite3_bind_text(stmt, 1, id, -1, SQLITE_TRANSIENT)
            guard sqlite3_step(stmt) == SQLITE_DONE else {
                throw HistoryError.query(String(cString: sqlite3_errmsg(db)))
            }
        }
    }

    public func count() -> Int {
        queue.sync {
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            guard sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM entries", -1, &stmt, nil)
                    == SQLITE_OK,
                  sqlite3_step(stmt) == SQLITE_ROW else { return 0 }
            return Int(sqlite3_column_int(stmt, 0))
        }
    }
}

public enum HistoryError: Error, LocalizedError {
    case open(String)
    case query(String)

    public var errorDescription: String? {
        switch self {
        case .open(let m): "History DB open failed: \(m)"
        case .query(let m): "History DB query failed: \(m)"
        }
    }
}
