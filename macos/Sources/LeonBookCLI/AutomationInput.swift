import Darwin
import Foundation
import LeonBook

/// Bounded reads also cover pipes, so an oversized request cannot be loaded in
/// full before its limit is checked. A rejected JSON line is drained to newline.
struct AutomationInput {
    private let handle: FileHandle
    private var buffer = Data()
    private var ended = false

    init(_ handle: FileHandle) { self.handle = handle }

    private mutating func readChunk() throws {
        var bytes = [UInt8](repeating: 0, count: 64 * 1024)
        var count: Int
        repeat { count = Darwin.read(handle.fileDescriptor, &bytes, bytes.count) } while count < 0 && errno == EINTR
        guard count >= 0 else { throw AutomationFailure("cli_error", "Cannot read input: \(String(cString: strerror(errno)))") }
        ended = count == 0
        buffer = Data(bytes.prefix(count))
    }

    mutating func nextLine() throws -> Data? {
        var line = Data(), oversized = false
        while true {
            let newline = buffer.firstIndex(of: 10)
            let end = newline ?? buffer.endIndex
            if !oversized {
                if line.count + buffer.distance(from: buffer.startIndex, to: end) > AutomationSocket.maximumMessageBytes {
                    oversized = true
                    line.removeAll(keepingCapacity: false)
                } else { line.append(contentsOf: buffer[..<end]) }
            }
            if let newline { buffer.removeSubrange(...newline) }
            else { buffer.removeAll(keepingCapacity: true) }
            if newline != nil || ended {
                if oversized { throw Self.tooLarge }
                return newline != nil || !line.isEmpty ? line : nil
            }
            try readChunk()
        }
    }

    static func readAll(_ handle: FileHandle) throws -> Data {
        var input = Self(handle), data = Data()
        while !input.ended {
            try input.readChunk()
            guard data.count + input.buffer.count <= AutomationSocket.maximumMessageBytes else { throw tooLarge }
            data.append(input.buffer)
        }
        return data
    }

    static func readFile(_ path: String) throws -> Data {
        let file = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
        defer { try? file.close() }
        return try readAll(file)
    }

    private static var tooLarge: AutomationFailure {
        .init("message_too_large", "Input exceeds 8 MiB; shorten the content or split independent operations.")
    }
}
