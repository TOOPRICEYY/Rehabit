import Foundation
#if canImport(SQLite3)
import SQLite3
#else
import CSQLite
#endif

public struct DatabaseError: Error, CustomStringConvertible {
    public let description: String
}

public enum SQLValue: Equatable, Sendable {
    case null, integer(Int64), real(Double), text(String)

    public var string: String? { if case .text(let s) = self { return s } else { return nil } }
    public var int: Int? { if case .integer(let i) = self { return Int(i) } else { return nil } }
    public var double: Double? {
        switch self {
        case .real(let d): return d
        case .integer(let i): return Double(i)
        default: return nil
        }
    }
}

/// A thin wrapper over SQLite, which ships with iOS and Android alike.
public final class Database {
    private var handle: OpaquePointer?
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    /// Opens (and creates) the file at `path`. Pass ":memory:" for a throwaway database.
    public init(path: String) throws {
        guard sqlite3_open(path, &handle) == SQLITE_OK else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "cannot open"
            sqlite3_close(handle)
            throw DatabaseError(description: message)
        }
    }

    deinit { sqlite3_close(handle) }

    private func fail(_ sql: String) -> DatabaseError {
        DatabaseError(description: String(cString: sqlite3_errmsg(handle)) + " in: " + sql)
    }

    @discardableResult
    public func run(_ sql: String, _ values: [SQLValue] = []) throws -> [[String: SQLValue]] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else { throw fail(sql) }
        defer { sqlite3_finalize(statement) }
        for (i, value) in values.enumerated() {
            let index = Int32(i + 1)
            switch value {
            case .null: sqlite3_bind_null(statement, index)
            case .integer(let v): sqlite3_bind_int64(statement, index, v)
            case .real(let v): sqlite3_bind_double(statement, index, v)
            case .text(let v): sqlite3_bind_text(statement, index, v, -1, Database.transient)
            }
        }
        var rows: [[String: SQLValue]] = []
        while true {
            let code = sqlite3_step(statement)
            if code == SQLITE_DONE { break }
            guard code == SQLITE_ROW else { throw fail(sql) }
            var row: [String: SQLValue] = [:]
            for column in 0..<sqlite3_column_count(statement) {
                let name = String(cString: sqlite3_column_name(statement, column))
                switch sqlite3_column_type(statement, column) {
                case SQLITE_INTEGER: row[name] = .integer(sqlite3_column_int64(statement, column))
                case SQLITE_FLOAT: row[name] = .real(sqlite3_column_double(statement, column))
                case SQLITE_TEXT: row[name] = .text(String(cString: sqlite3_column_text(statement, column)))
                default: row[name] = .null
                }
            }
            rows.append(row)
        }
        return rows
    }

    public func transaction(_ body: () throws -> Void) throws {
        try run("BEGIN")
        do { try body(); try run("COMMIT") } catch { _ = try? run("ROLLBACK"); throw error }
    }
}
