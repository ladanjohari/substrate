import Foundation
import SQLite3

/// A small wrapper over the SQLite C API.
///
/// No package dependency: SQLite is part of macOS, so the whole store needs
/// nothing installed. That is the point of moving off Python, so adding a
/// database package back would give most of it away again.
public final class DB {
    public enum Failure: Error, CustomStringConvertible {
        case sqlite(String)
        case refused(String)   // a rule said no, which is not a bug

        public var description: String {
            switch self {
            case .sqlite(let m):  return m
            case .refused(let m): return m
            }
        }
    }

    private var handle: OpaquePointer?
    public let path: String

    public init(path: String) throws {
        self.path = path
        try FileManager.default.createDirectory(
            at: URL(fileURLWithPath: path).deletingLastPathComponent(),
            withIntermediateDirectories: true)
        guard sqlite3_open(path, &handle) == SQLITE_OK else {
            throw Failure.sqlite("could not open \(path)")
        }
        // Wait rather than fail when another process is mid-write. The CLI,
        // the app and the agents all hold this file at once.
        sqlite3_busy_timeout(handle, 10_000)
    }

    deinit { sqlite3_close(handle) }

    /// A value going into, or coming out of, a query.
    public enum Value: Equatable {
        case text(String), int(Int64), null

        public var string: String? { if case .text(let s) = self { return s }; return nil }
        public var int: Int? {
            switch self {
            case .int(let i): return Int(i)
            case .text(let s): return Int(s)
            case .null: return nil
            }
        }
    }

    public typealias Row = [String: Value]

    @discardableResult
    public func run(_ sql: String, _ args: [Value] = []) throws -> [Row] {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw Failure.sqlite(lastError() + "\n  in: " + sql)
        }
        defer { sqlite3_finalize(stmt) }

        for (i, a) in args.enumerated() {
            let n = Int32(i + 1)
            switch a {
            case .text(let s): sqlite3_bind_text(stmt, n, s, -1,
                                                 unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            case .int(let v):  sqlite3_bind_int64(stmt, n, v)
            case .null:        sqlite3_bind_null(stmt, n)
            }
        }

        var rows: [Row] = []
        while true {
            let step = sqlite3_step(stmt)
            if step == SQLITE_DONE { break }
            guard step == SQLITE_ROW else { throw Failure.sqlite(lastError()) }
            var row = Row()
            for c in 0..<sqlite3_column_count(stmt) {
                let name = String(cString: sqlite3_column_name(stmt, c))
                switch sqlite3_column_type(stmt, c) {
                case SQLITE_NULL:    row[name] = .null
                case SQLITE_INTEGER: row[name] = .int(sqlite3_column_int64(stmt, c))
                default:
                    if let t = sqlite3_column_text(stmt, c) {
                        row[name] = .text(String(cString: t))
                    } else {
                        row[name] = .null
                    }
                }
            }
            rows.append(row)
        }
        return rows
    }

    /// Several statements at once, for the schema.
    public func script(_ sql: String) throws {
        var err: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(handle, sql, nil, nil, &err) != SQLITE_OK {
            let m = err.map { String(cString: $0) } ?? "unknown error"
            sqlite3_free(err)
            throw Failure.sqlite(m)
        }
    }

    /// Everything inside, or nothing. A rule that refuses halfway through
    /// must not leave the record half changed.
    public func transaction<T>(_ body: () throws -> T) throws -> T {
        try script("BEGIN IMMEDIATE")
        do {
            let out = try body()
            try script("COMMIT")
            return out
        } catch {
            try? script("ROLLBACK")
            throw error
        }
    }

    public var lastInsertedId: Int { Int(sqlite3_last_insert_rowid(handle)) }

    private func lastError() -> String {
        String(cString: sqlite3_errmsg(handle))
    }
}

public func s(_ v: String) -> DB.Value { .text(v) }
public func s(_ v: String?) -> DB.Value { v.map { DB.Value.text($0) } ?? .null }
public func i(_ v: Int) -> DB.Value { .int(Int64(v)) }
