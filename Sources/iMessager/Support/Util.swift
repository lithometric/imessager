import Foundation

extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}

extension Duration {
    var ms: Int {
        let c = components
        return Int(c.seconds * 1000 + c.attoseconds / 1_000_000_000_000_000)
    }
}

extension KeyedDecodingContainer {
    /// Decodes a key if present, falling back to a default so old config files keep loading.
    func value<T: Decodable>(_ key: Key, default fallback: T) -> T {
        (try? decodeIfPresent(T.self, forKey: key)) ?? fallback
    }
}

enum Slug {
    /// Tool-name-safe identifier: lowercase ASCII letters, digits and underscores.
    static func make(_ s: String, max: Int = 40) -> String {
        var out = String(s.lowercased().map { $0.isASCII && ($0.isLetter || $0.isNumber) ? $0 : "_" })
        while out.contains("__") { out = out.replacingOccurrences(of: "__", with: "_") }
        out = String(out.trimmingCharacters(in: CharacterSet(charactersIn: "_")).prefix(max))
        return out.isEmpty ? "tool" : out
    }
}

enum KeyValue {
    /// Parses "KEY=value" / "Key: value" lines.
    static func parse(_ text: String, separator: Character) -> [(String, String)] {
        text.split(whereSeparator: \.isNewline).compactMap { line in
            guard let i = line.firstIndex(of: separator) else { return nil }
            let key = line[..<i].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: i)...].trimmingCharacters(in: .whitespaces)
            return key.isEmpty ? nil : (key, value)
        }
    }
}

struct AppError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

/// Tracks spawned helper processes (MCP servers) so they die with the app.
enum ChildProcesses {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var running: [ObjectIdentifier: Process] = [:]

    static func add(_ p: Process) { lock.withLock { running[ObjectIdentifier(p)] = p } }
    static func remove(_ p: Process) { lock.withLock { running[ObjectIdentifier(p)] = nil } }
    static func terminateAll() {
        lock.withLock { running.values.filter(\.isRunning).forEach { $0.terminate() } }
    }
}

/// Splits a byte stream into newline-delimited lines (JSON-RPC over stdio).
final class LineSplitter: @unchecked Sendable {
    private var buffer = Data()
    private let onLine: @Sendable (String) -> Void

    init(onLine: @escaping @Sendable (String) -> Void) { self.onLine = onLine }

    func feed(_ data: Data) {
        buffer.append(data)
        while let nl = buffer.firstIndex(of: 0x0A) {
            let line = Data(buffer[buffer.startIndex..<nl])
            buffer.removeSubrange(buffer.startIndex...nl)
            if let s = String(data: line, encoding: .utf8), !s.trimmed.isEmpty { onLine(s) }
        }
    }
}
