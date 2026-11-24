import CryptoKit
import Foundation
import SQLite3

enum Kind: Int {
    case text, image, file, link
}

struct Item: Identifiable, Equatable {
    let id: Int64
    let kind: Kind
    let style: TextStyle
    let text: String
    let preview: String
    let app: String?
    let created: Double
    let pinned: Bool

    init(id: Int64, kind: Kind, style: TextStyle, text: String, app: String?, created: Double, pinned: Bool) {
        self.id = id
        self.kind = kind
        self.style = style
        self.text = text
        self.app = app
        self.created = created
        self.pinned = pinned
        preview = text.prefix(300).split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ⏎ ")
    }

    var age: String {
        let seconds = Date().timeIntervalSince1970 - created
        let day = 86400.0
        switch seconds {
        case ..<60: return "now"
        case ..<3600: return "\(Int(seconds / 60))m"
        case ..<day: return "\(Int(seconds / 3600))h"
        case ..<(7 * day): return "\(Int(seconds / day))d"
        case ..<(30 * day): return "\(Int(seconds / (7 * day)))w"
        case ..<(365 * day): return "\(Int(seconds / (30 * day)))mo"
        default: return "\(Int(seconds / (365 * day)))y"
        }
    }
}

/// A clipboard capture that is not saved yet.
struct Capture {
    let kind: Kind
    let text: String
    /// Content that decides if two copies are the same item.
    let key: Data
    /// Raw pasteboard data per type, written back as-is on paste.
    let reps: [(String, Data)]
}

private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// SQLite history at ~/Library/Application Support/PasteTrove/history.sqlite.
/// `items` holds the light rows the list needs, `reps` holds the raw data, loaded only to preview or paste.
final class Store {
    static let thumbnailType = "io.github.tawsifahmed.pastetrove.thumbnail"
    static let thumbnailSize = 600

    private var db: OpaquePointer?

    /// `PASTETROVE_DATA_DIR` points the app at another folder, for demo data and screenshots.
    static var directory: URL {
        if let custom = ProcessInfo.processInfo.environment["PASTETROVE_DATA_DIR"] {
            return URL(fileURLWithPath: custom, isDirectory: true)
        }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PasteTrove", isDirectory: true)
    }

    init() throws {
        let dir = Self.directory
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        guard sqlite3_open(dir.appendingPathComponent("history.sqlite").path, &db) == SQLITE_OK else {
            throw NSError(domain: "PasteTrove", code: 1, userInfo: [NSLocalizedDescriptionKey: "Cannot open the history database."])
        }
        sqlite3_exec(db, """
            PRAGMA auto_vacuum = INCREMENTAL;
            PRAGMA journal_mode = WAL;
            PRAGMA synchronous = NORMAL;
            PRAGMA foreign_keys = ON;
            CREATE TABLE IF NOT EXISTS items (
                id INTEGER PRIMARY KEY,
                hash TEXT NOT NULL UNIQUE,
                kind INTEGER NOT NULL,
                text TEXT NOT NULL,
                app TEXT,
                created REAL NOT NULL,
                pinned INTEGER NOT NULL DEFAULT 0
            );
            CREATE TABLE IF NOT EXISTS reps (
                item_id INTEGER NOT NULL REFERENCES items(id) ON DELETE CASCADE,
                type TEXT NOT NULL,
                data BLOB NOT NULL,
                PRIMARY KEY (item_id, type)
            );
            CREATE INDEX IF NOT EXISTS items_order ON items (pinned DESC, created DESC);
            """, nil, nil, nil)
        migrate()
    }

    /// Adds the `style` column to older databases and fills it once for existing text items.
    private func migrate() {
        guard sqlite3_exec(db, "ALTER TABLE items ADD COLUMN style INTEGER NOT NULL DEFAULT 0", nil, nil, nil) == SQLITE_OK
        else { return }
        var texts: [(Int64, String)] = []
        query("SELECT id, text FROM items WHERE kind = ?", [Kind.text.rawValue]) { st in
            texts.append((sqlite3_column_int64(st, 0), Self.string(st, 1) ?? ""))
        }
        sqlite3_exec(db, "BEGIN", nil, nil, nil)
        for (id, text) in texts {
            query("UPDATE items SET style = ? WHERE id = ?", [TextStyle(text).rawValue, id])
        }
        sqlite3_exec(db, "COMMIT", nil, nil, nil)
    }

    /// The list rows. Text is cut to 2,000 characters for the list and search; preview and paste read the full data from `reps`.
    func items() -> [Item] {
        var out: [Item] = []
        query("SELECT id, kind, style, substr(text, 1, 2000), app, created, pinned FROM items ORDER BY pinned DESC, created DESC") { st in
            out.append(Item(
                id: sqlite3_column_int64(st, 0),
                kind: Kind(rawValue: Int(sqlite3_column_int(st, 1))) ?? .text,
                style: TextStyle(rawValue: Int(sqlite3_column_int(st, 2))) ?? .plain,
                text: Self.string(st, 3) ?? "",
                app: Self.string(st, 4),
                created: sqlite3_column_double(st, 5),
                pinned: sqlite3_column_int(st, 6) != 0
            ))
        }
        return out
    }

    /// Unpinned items, of one kind or all, that a lower limit could remove.
    func unpinnedCount(kind: Kind? = nil) -> Int {
        var count = 0
        let read: (OpaquePointer) -> Void = { count = Int(sqlite3_column_int64($0, 0)) }
        if let kind {
            query("SELECT COUNT(*) FROM items WHERE pinned = 0 AND kind = ?", [kind.rawValue], row: read)
        } else {
            query("SELECT COUNT(*) FROM items WHERE pinned = 0", row: read)
        }
        return count
    }

    /// Saves a capture. Copying the same content again moves the old item to the top instead of adding a duplicate.
    func save(_ clip: Capture, app: String?, limit: Int, imageLimit: Int) {
        let hash = SHA256.hash(data: Data([UInt8(clip.kind.rawValue)]) + clip.key)
            .map { String(format: "%02x", $0) }.joined()
        let now = Date().timeIntervalSince1970
        var existing: Int64?
        query("SELECT id FROM items WHERE hash = ?", [hash]) { existing = sqlite3_column_int64($0, 0) }
        if let existing {
            query("UPDATE items SET created = ?, app = ? WHERE id = ?", [now, app, existing])
            return
        }
        sqlite3_exec(db, "BEGIN", nil, nil, nil)
        let style = clip.kind == .text ? TextStyle(clip.text) : .plain
        // All or nothing: an item without its data could not be pasted.
        guard query("INSERT INTO items (hash, kind, style, text, app, created) VALUES (?, ?, ?, ?, ?, ?)",
                    [hash, clip.kind.rawValue, style.rawValue, String(clip.text.prefix(20_000)), app, now])
        else { return rollback() }
        let id = sqlite3_last_insert_rowid(db)
        for (type, data) in clip.reps {
            guard query("INSERT INTO reps (item_id, type, data) VALUES (?, ?, ?)", [id, type, data]) else { return rollback() }
        }
        sqlite3_exec(db, "COMMIT", nil, nil, nil)
        trim(limit: limit, imageLimit: imageLimit)
    }

    private func rollback() {
        sqlite3_exec(db, "ROLLBACK", nil, nil, nil)
    }

    /// Drops the oldest unpinned items over the limits. Images get a separate, smaller limit because they are large.
    func trim(limit: Int, imageLimit: Int) {
        let before = sqlite3_total_changes(db)
        query("""
            DELETE FROM items WHERE pinned = 0 AND kind = ? AND id NOT IN
            (SELECT id FROM items WHERE pinned = 0 AND kind = ? ORDER BY created DESC LIMIT ?)
            """, [Kind.image.rawValue, Kind.image.rawValue, imageLimit])
        query("""
            DELETE FROM items WHERE pinned = 0 AND id NOT IN
            (SELECT id FROM items WHERE pinned = 0 ORDER BY created DESC LIMIT ?)
            """, [limit])
        // Give space back only when something was deleted.
        if sqlite3_total_changes(db) > before {
            sqlite3_exec(db, "PRAGMA incremental_vacuum", nil, nil, nil)
        }
    }

    func reps(_ id: Int64) -> [(String, Data)] {
        var out: [(String, Data)] = []
        query("SELECT type, data FROM reps WHERE item_id = ?", [id]) { st in
            if let type = Self.string(st, 0), let blob = sqlite3_column_blob(st, 1) {
                out.append((type, Data(bytes: blob, count: Int(sqlite3_column_bytes(st, 1)))))
            }
        }
        return out
    }

    func data(_ id: Int64, type: String) -> Data? {
        var out: Data?
        query("SELECT data FROM reps WHERE item_id = ? AND type = ?", [id, type]) { st in
            if let blob = sqlite3_column_blob(st, 0) {
                out = Data(bytes: blob, count: Int(sqlite3_column_bytes(st, 0)))
            }
        }
        return out
    }

    func delete(_ id: Int64) {
        query("DELETE FROM items WHERE id = ?", [id])
    }

    func setPinned(_ id: Int64, _ pinned: Bool) {
        query("UPDATE items SET pinned = ? WHERE id = ?", [pinned ? 1 : 0, id])
    }

    func clear() {
        query("DELETE FROM items WHERE pinned = 0")
        sqlite3_exec(db, "PRAGMA incremental_vacuum", nil, nil, nil)
    }

    /// Runs one statement. Returns false when SQLite reports an error.
    @discardableResult
    private func query(_ sql: String, _ args: [Any?] = [], row: ((OpaquePointer) -> Void)? = nil) -> Bool {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let st = statement else { return false }
        defer { sqlite3_finalize(st) }
        for (index, arg) in args.enumerated() {
            let n = Int32(index + 1)
            switch arg {
            case let value as Int64: sqlite3_bind_int64(st, n, value)
            case let value as Int: sqlite3_bind_int64(st, n, Int64(value))
            case let value as Double: sqlite3_bind_double(st, n, value)
            case let value as String: sqlite3_bind_text(st, n, value, -1, transient)
            case let value as Data:
                _ = value.withUnsafeBytes { sqlite3_bind_blob(st, n, $0.baseAddress, Int32($0.count), transient) }
            default: sqlite3_bind_null(st, n)
            }
        }
        var result = sqlite3_step(st)
        while result == SQLITE_ROW {
            row?(st)
            result = sqlite3_step(st)
        }
        return result == SQLITE_DONE
    }

    private static func string(_ st: OpaquePointer, _ column: Int32) -> String? {
        sqlite3_column_text(st, column).map { String(cString: $0) }
    }
}
