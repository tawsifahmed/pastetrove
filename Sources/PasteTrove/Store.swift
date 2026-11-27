import CryptoKit
import Foundation
import Security
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
    /// Words read from an image, for search. Empty for other kinds.
    let words: String

    init(id: Int64, kind: Kind, style: TextStyle, text: String, app: String?, created: Double, pinned: Bool, words: String = "") {
        self.id = id
        self.kind = kind
        self.style = style
        self.text = text
        self.app = app
        self.created = created
        self.pinned = pinned
        self.words = words
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
/// Every text, word list and data blob is encrypted (AES-GCM) with a key kept beside it but never in backups;
/// deleted rows are overwritten, not only unlinked.
final class Store {
    static let thumbnailType = "io.github.tawsifahmed.pastetrove.thumbnail"
    static let thumbnailSize = 600

    private var db: OpaquePointer?
    private var key: SymmetricKey!
    /// For the duplicate check, so the stored hash can't confirm a guess of what was copied.
    private var hashKey: SymmetricKey!

    private static let defaultDirectory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("PasteTrove", isDirectory: true)

    /// `PASTETROVE_DATA_DIR` points the app at another folder, for demo data and screenshots.
    static var directory: URL {
        ProcessInfo.processInfo.environment["PASTETROVE_DATA_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) } ?? defaultDirectory
    }

    /// `key` is for tests; otherwise the key is the folder's `history.key`.
    init(directory dir: URL = Store.directory, key: SymmetricKey? = nil) throws {
        // Only you can open the folder, so the database and its journal files are yours alone.
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
        guard sqlite3_open(dir.appendingPathComponent("history.sqlite").path, &db) == SQLITE_OK else {
            throw NSError(domain: "PasteTrove", code: 1, userInfo: [NSLocalizedDescriptionKey: "Cannot open the history database."])
        }
        sqlite3_exec(db, """
            PRAGMA auto_vacuum = INCREMENTAL;
            PRAGMA journal_mode = WAL;
            PRAGMA synchronous = NORMAL;
            PRAGMA foreign_keys = ON;
            PRAGMA secure_delete = ON;
            PRAGMA journal_size_limit = 4194304;
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
        var version = 0
        query("PRAGMA user_version") { version = Int(sqlite3_column_int($0, 0)) }
        // A new key only for a history that was never encrypted: a lost key must never silently turn rows into noise.
        self.key = try key ?? Self.loadKey(for: dir, create: version == 0)
        hashKey = HKDF<SHA256>.deriveKey(inputKeyMaterial: self.key, info: Data("hash".utf8), outputByteCount: 32)
        if version == 0 { encryptAll() }
    }

    /// The key sits next to the history, readable only by you and left out of backups, so a copied or backed-up
    /// history can't be read. Not the Keychain: without an Apple Team ID, macOS would ask for your password after every update.
    private static func loadKey(for dir: URL, create: Bool) throws -> SymmetricKey {
        var file = dir.appendingPathComponent("history.key")
        if let data = try? Data(contentsOf: file), data.count == 32 { return SymmetricKey(data: data) }
        let keychain = dir.standardizedFileURL == defaultDirectory.standardizedFileURL ? keychainKey() : nil
        guard let data = keychain ?? (create ? SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) } : nil) else {
            throw NSError(domain: "PasteTrove", code: 2, userInfo: [NSLocalizedDescriptionKey:
                "The key that unlocks your encrypted history (history.key) is missing, so it can't be read."])
        }
        guard FileManager.default.createFile(atPath: file.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
            throw NSError(domain: "PasteTrove", code: 3, userInfo: [NSLocalizedDescriptionKey: "Cannot save the history key."])
        }
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? file.setResourceValues(values)
        if keychain != nil { SecItemDelete(keychainItem as CFDictionary) }
        return SymmetricKey(data: data)
    }

    /// Test builds of 26–27 Nov 2026 kept the key in the Keychain; it moves to the file once.
    private static let keychainItem: [CFString: Any] = [kSecClass: kSecClassGenericPassword,
                                                        kSecAttrService: "io.github.tawsifahmed.PasteTrove", kSecAttrAccount: "history-key"]

    private static func keychainKey() -> Data? {
        var found: CFTypeRef?
        guard SecItemCopyMatching(keychainItem.merging([kSecReturnData: true]) { $1 } as CFDictionary, &found) == errSecSuccess else { return nil }
        return found as? Data
    }

    /// Once, for a history saved before encryption: seals every row, then rewrites the file so no plain page is left.
    private func encryptAll() {
        sqlite3_exec(db, "BEGIN", nil, nil, nil)
        var rows: [(Int64, String, String, String?)] = []
        query("SELECT id, hash, text, words FROM items") { st in
            rows.append((sqlite3_column_int64(st, 0), Self.string(st, 1) ?? "", Self.string(st, 2) ?? "", Self.string(st, 3)))
        }
        for (id, hash, text, words) in rows {
            query("UPDATE items SET hash = ?, text = ?, words = ? WHERE id = ?",
                  [hmac(hash), seal(Data(text.prefix(2000).utf8)), words.map { seal(Data($0.utf8)) }, id])
            for (type, data) in rawReps(id) {
                query("UPDATE reps SET data = ? WHERE item_id = ? AND type = ?", [seal(data), id, type])
            }
        }
        sqlite3_exec(db, "COMMIT", nil, nil, nil)
        sqlite3_exec(db, "PRAGMA user_version = 1", nil, nil, nil)
        sqlite3_exec(db, "VACUUM", nil, nil, nil)
        checkpoint()
    }

    private func seal(_ data: Data) -> Data {
        (try? AES.GCM.seal(data, using: key))?.combined ?? Data()
    }

    private func open(_ data: Data?) -> Data? {
        data.flatMap { try? AES.GCM.open(AES.GCM.SealedBox(combined: $0), using: key) }
    }

    private func hmac(_ hash: String) -> String {
        HMAC<SHA256>.authenticationCode(for: Data(hash.utf8), using: hashKey).map { String(format: "%02x", $0) }.joined()
    }

    /// Moves the journal into the database and empties it, so deleted rows don't linger in `history.sqlite-wal`.
    private func checkpoint() {
        sqlite3_exec(db, "PRAGMA wal_checkpoint(TRUNCATE)", nil, nil, nil)
    }

    /// Adds the `style` column to older databases and fills it once for existing text items.
    /// `words` (image text, NULL until read) is added the same way; images get read in the background.
    private func migrate() {
        sqlite3_exec(db, "ALTER TABLE items ADD COLUMN words TEXT", nil, nil, nil)
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

    /// The list rows. Text is kept to 2,000 characters for the list and search; preview and paste read the full data from `reps`.
    func items() -> [Item] {
        var out: [Item] = []
        query("SELECT id, kind, style, text, app, created, pinned, words FROM items ORDER BY pinned DESC, created DESC") { st in
            // A row that can't be opened (another key) is left out rather than shown as noise.
            guard let text = self.open(Self.blob(st, 3)) else { return }
            out.append(Item(
                id: sqlite3_column_int64(st, 0),
                kind: Kind(rawValue: Int(sqlite3_column_int(st, 1))) ?? .text,
                style: TextStyle(rawValue: Int(sqlite3_column_int(st, 2))) ?? .plain,
                text: String(String(decoding: text, as: UTF8.self).prefix(2000)),
                app: Self.string(st, 4),
                created: sqlite3_column_double(st, 5),
                pinned: sqlite3_column_int(st, 6) != 0,
                words: self.open(Self.blob(st, 7)).map { String(String(decoding: $0, as: UTF8.self).prefix(4000)) } ?? ""
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
        let hash = hmac(SHA256.hash(data: Data([UInt8(clip.kind.rawValue)]) + clip.key).map { String(format: "%02x", $0) }.joined())
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
                    [hash, clip.kind.rawValue, style.rawValue, seal(Data(clip.text.prefix(2000).utf8)), app, now])
        else { return rollback() }
        let id = sqlite3_last_insert_rowid(db)
        for (type, data) in clip.reps {
            guard query("INSERT INTO reps (item_id, type, data) VALUES (?, ?, ?)", [id, type, seal(data)]) else { return rollback() }
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
            checkpoint()
        }
    }

    /// Images whose words have not been read yet, newest first.
    func unreadImages() -> [Int64] {
        var out: [Int64] = []
        query("SELECT id FROM items WHERE kind = ? AND words IS NULL ORDER BY created DESC", [Kind.image.rawValue]) {
            out.append(sqlite3_column_int64($0, 0))
        }
        return out
    }

    func setWords(_ id: Int64, _ words: String) {
        query("UPDATE items SET words = ? WHERE id = ?", [seal(Data(words.utf8)), id])
    }

    func reps(_ id: Int64) -> [(String, Data)] {
        rawReps(id).compactMap { type, data in open(data).map { (type, $0) } }
    }

    /// As stored, still encrypted: for undo, which puts the row back exactly as it was.
    private func rawReps(_ id: Int64) -> [(String, Data)] {
        var out: [(String, Data)] = []
        query("SELECT type, data FROM reps WHERE item_id = ?", [id]) { st in
            if let type = Self.string(st, 0), let data = Self.blob(st, 1) { out.append((type, data)) }
        }
        return out
    }

    func data(_ id: Int64, type: String) -> Data? {
        var out: Data?
        query("SELECT data FROM reps WHERE item_id = ? AND type = ?", [id, type]) { out = self.open(Self.blob($0, 0)) }
        return out
    }

    /// A deleted item exactly as stored, kept in memory so ⌘Z can put it back.
    struct Deleted {
        let row: [Any?]
        let reps: [(String, Data)]
        var bytes: Int { reps.reduce(0) { $0 + $1.1.count } }
    }

    private static let columns = "id, hash, kind, style, text, app, created, pinned, words"

    func snapshot(_ id: Int64) -> Deleted? {
        var row: [Any?]?
        query("SELECT \(Self.columns) FROM items WHERE id = ?", [id]) { st in
            row = (0..<sqlite3_column_count(st)).map { Self.value(st, $0) }
        }
        return row.map { Deleted(row: $0, reps: rawReps(id)) }
    }

    /// Puts a deleted item back with its old id. False when the same content was copied again meanwhile:
    /// it is already back at the top, so nothing is added twice.
    @discardableResult
    func restore(_ deleted: Deleted) -> Bool {
        sqlite3_exec(db, "BEGIN", nil, nil, nil)
        guard query("INSERT INTO items (\(Self.columns)) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)", deleted.row) else {
            rollback()
            return false
        }
        for (type, data) in deleted.reps {
            guard query("INSERT INTO reps (item_id, type, data) VALUES (?, ?, ?)", [deleted.row[0], type, data]) else {
                rollback()
                return false
            }
        }
        sqlite3_exec(db, "COMMIT", nil, nil, nil)
        return true
    }

    func delete(_ id: Int64) {
        query("DELETE FROM items WHERE id = ?", [id])
        checkpoint()
    }

    func setPinned(_ id: Int64, _ pinned: Bool) {
        query("UPDATE items SET pinned = ? WHERE id = ?", [pinned ? 1 : 0, id])
    }

    func clear() {
        query("DELETE FROM items WHERE pinned = 0")
        sqlite3_exec(db, "PRAGMA incremental_vacuum", nil, nil, nil)
        checkpoint()
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

    private static func value(_ st: OpaquePointer, _ column: Int32) -> Any? {
        switch sqlite3_column_type(st, column) {
        case SQLITE_INTEGER: sqlite3_column_int64(st, column)
        case SQLITE_FLOAT: sqlite3_column_double(st, column)
        case SQLITE_TEXT: string(st, column)
        case SQLITE_BLOB: sqlite3_column_blob(st, column).map { Data(bytes: $0, count: Int(sqlite3_column_bytes(st, column))) }
        default: nil
        }
    }

    private static func blob(_ st: OpaquePointer, _ column: Int32) -> Data? {
        sqlite3_column_blob(st, column).map { Data(bytes: $0, count: Int(sqlite3_column_bytes(st, column))) }
    }

    private static func string(_ st: OpaquePointer, _ column: Int32) -> String? {
        sqlite3_column_text(st, column).map { String(cString: $0) }
    }
}
