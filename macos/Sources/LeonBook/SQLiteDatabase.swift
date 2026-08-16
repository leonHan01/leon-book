import CSQLite
import Foundation

enum SQLiteValue {
    case integer(Int)
    case text(String)
    case null
}

struct SQLiteRow {
    private let statement: OpaquePointer

    fileprivate init(statement: OpaquePointer) {
        self.statement = statement
    }

    func text(at index: Int32) -> String? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL,
              let pointer = sqlite3_column_text(statement, index) else {
            return nil
        }
        let length = Int(sqlite3_column_bytes(statement, index))
        let bytes = UnsafeBufferPointer(start: pointer, count: length)
        return String(decoding: bytes, as: UTF8.self)
    }

    func integer(at index: Int32) -> Int? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL else { return nil }
        return Int(sqlite3_column_int64(statement, index))
    }
}

final class SQLiteDatabase {
    private var handle: OpaquePointer?

    init(url: URL) throws {
        var openedHandle: OpaquePointer?
        let flags = SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
        let result = sqlite3_open_v2(url.path, &openedHandle, flags, nil)
        guard result == SQLITE_OK, let openedHandle else {
            let message = openedHandle.map { String(cString: sqlite3_errmsg($0)) } ?? "无法打开数据库"
            if let openedHandle { sqlite3_close(openedHandle) }
            throw NativeStoreError.fileSystem("SQLite：\(message)")
        }
        handle = openedHandle
        sqlite3_busy_timeout(openedHandle, 5_000)
        do {
            try execute("PRAGMA journal_mode = WAL")
            try execute("PRAGMA foreign_keys = ON")
        } catch {
            sqlite3_close(openedHandle)
            handle = nil
            throw error
        }
    }

    deinit {
        if let handle { sqlite3_close(handle) }
    }

    func execute(_ sql: String, values: [SQLiteValue] = []) throws {
        if values.isEmpty {
            guard let handle else { throw NativeStoreError.fileSystem("SQLite：数据库连接已关闭") }
            var errorMessage: UnsafeMutablePointer<CChar>?
            let result = sqlite3_exec(handle, sql, nil, nil, &errorMessage)
            guard result == SQLITE_OK else {
                let message = errorMessage.map { String(cString: $0) } ?? String(cString: sqlite3_errmsg(handle))
                if let errorMessage { sqlite3_free(errorMessage) }
                throw NativeStoreError.fileSystem("SQLite：\(message)")
            }
            if let errorMessage { sqlite3_free(errorMessage) }
            return
        }

        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        try bind(values, to: statement)
        let result = sqlite3_step(statement)
        guard result == SQLITE_DONE else { throw databaseError() }
    }

    func query(_ sql: String, values: [SQLiteValue] = [], row: (SQLiteRow) throws -> Void) throws {
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        try bind(values, to: statement)

        while true {
            let result = sqlite3_step(statement)
            switch result {
            case SQLITE_ROW:
                try row(SQLiteRow(statement: statement))
            case SQLITE_DONE:
                return
            default:
                throw databaseError()
            }
        }
    }

    func transaction(_ body: () throws -> Void) throws {
        try execute("BEGIN IMMEDIATE")
        do {
            try body()
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    func integer(_ sql: String, values: [SQLiteValue] = []) throws -> Int? {
        var result: Int?
        try query(sql, values: values) { row in
            result = row.integer(at: 0)
        }
        return result
    }

    func text(_ sql: String, values: [SQLiteValue] = []) throws -> String? {
        var result: String?
        try query(sql, values: values) { row in
            result = row.text(at: 0)
        }
        return result
    }

    private func prepare(_ sql: String) throws -> OpaquePointer {
        guard let handle else { throw NativeStoreError.fileSystem("SQLite：数据库连接已关闭") }
        var statement: OpaquePointer?
        let result = sqlite3_prepare_v2(handle, sql, -1, &statement, nil)
        guard result == SQLITE_OK, let statement else { throw databaseError() }
        return statement
    }

    private func bind(_ values: [SQLiteValue], to statement: OpaquePointer) throws {
        for (offset, value) in values.enumerated() {
            let index = Int32(offset + 1)
            let result: Int32
            switch value {
            case .integer(let number):
                result = sqlite3_bind_int64(statement, index, sqlite3_int64(number))
            case .text(let string):
                result = string.withCString { pointer in
                    sqlite3_bind_text(statement, index, pointer, -1, SQLITE_TRANSIENT)
                }
            case .null:
                result = sqlite3_bind_null(statement, index)
            }
            guard result == SQLITE_OK else { throw databaseError() }
        }
    }

    private func databaseError() -> NativeStoreError {
        let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "未知数据库错误"
        return .fileSystem("SQLite：\(message)")
    }
}

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
