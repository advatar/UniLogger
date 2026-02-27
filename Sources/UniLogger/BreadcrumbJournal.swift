import Foundation

public struct Breadcrumb: Sendable, Codable {
    public var tMillis: Int
    public var event: String
    public var fields: [String: String]

    public init(tMillis: Int, event: String, fields: [String: String]) {
        self.tMillis = tMillis
        self.event = event
        self.fields = fields
    }
}

public final class BreadcrumbJournal: @unchecked Sendable {
    public struct Configuration: Sendable {
        public var maxEvents: Int = 25
        public var maxBytes: Int = 16 * 1024
        public var fieldValueMaxBytes: Int = 512
        public var redactor: (@Sendable (String) -> String)? = nil

        public init(
            maxEvents: Int = 25,
            maxBytes: Int = 16 * 1024,
            fieldValueMaxBytes: Int = 512,
            redactor: (@Sendable (String) -> String)? = nil
        ) {
            self.maxEvents = maxEvents
            self.maxBytes = maxBytes
            self.fieldValueMaxBytes = fieldValueMaxBytes
            self.redactor = redactor
        }
    }

    private struct Entry {
        let crumb: Breadcrumb
        let size: Int
    }

    private let config: Configuration
    private let lock = NSLock()
    private var entries: [Entry] = []
    private var totalBytes: Int = 0

    public init(config: Configuration = .init()) {
        self.config = config
    }

    public func add(event: String, fields: [String: String] = [:], timestampMillis: Int? = nil) {
        let ts = timestampMillis ?? Int(Date().timeIntervalSince1970 * 1000)
        let sanitized = sanitizeFields(fields)
        let crumb = Breadcrumb(tMillis: ts, event: event, fields: sanitized)
        let size = estimateSize(crumb)

        lock.lock()
        defer { lock.unlock() }

        entries.append(Entry(crumb: crumb, size: size))
        totalBytes += size
        trimIfNeeded()
    }

    public func snapshot(maxEvents: Int? = nil, maxBytes: Int? = nil) -> [Breadcrumb] {
        lock.lock()
        let snapshotEntries = entries
        lock.unlock()

        let eventLimit = maxEvents ?? config.maxEvents
        let byteLimit = maxBytes ?? config.maxBytes

        var result: [Breadcrumb] = []
        result.reserveCapacity(min(eventLimit, snapshotEntries.count))

        var usedBytes = 0
        for entry in snapshotEntries.reversed() {
            if result.count >= eventLimit { break }
            if usedBytes + entry.size > byteLimit { break }
            result.append(entry.crumb)
            usedBytes += entry.size
        }

        return result.reversed()
    }

    public func snapshotJSON(maxEvents: Int? = nil, maxBytes: Int? = nil) -> String? {
        let crumbs = snapshot(maxEvents: maxEvents, maxBytes: maxBytes)
        guard !crumbs.isEmpty else { return nil }
        let encoder = JSONEncoder()
        guard let data = try? encoder.encode(crumbs) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func sanitizeFields(_ fields: [String: String]) -> [String: String] {
        var sanitized: [String: String] = [:]
        sanitized.reserveCapacity(fields.count)
        for (key, value) in fields {
            let redacted = config.redactor?(value) ?? value
            sanitized[key] = capValue(redacted)
        }
        return sanitized
    }

    private func capValue(_ value: String) -> String {
        let bytes = value.utf8
        if bytes.count <= config.fieldValueMaxBytes {
            return value
        }
        var capped = String(decoding: bytes.prefix(config.fieldValueMaxBytes), as: UTF8.self)
        capped.append("...")
        return capped
    }

    private func estimateSize(_ crumb: Breadcrumb) -> Int {
        var size = 0
        size += String(crumb.tMillis).utf8.count
        size += crumb.event.utf8.count
        for (key, value) in crumb.fields {
            size += key.utf8.count
            size += value.utf8.count
        }
        return size + 16
    }

    private func trimIfNeeded() {
        let maxEvents = max(config.maxEvents, 1)
        let maxBytes = max(config.maxBytes, 1)

        while entries.count > maxEvents || totalBytes > maxBytes {
            guard let first = entries.first else { break }
            entries.removeFirst()
            totalBytes -= first.size
        }
    }
}
