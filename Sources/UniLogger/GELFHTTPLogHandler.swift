import Foundation
import Logging

/// GELF over HTTP log handler with batching, exponential backoff, and redaction hooks.
///
/// Designed for Graylog's GELF HTTP input (enable "Bulk Receiving" to allow newline-delimited batches).
public struct GELFHTTPLogHandler: LogHandler {
    public struct RetryPolicy: Sendable {
        public var initialDelaySeconds: Double = 1.0
        public var maxDelaySeconds: Double = 60.0
        public var jitterFactorRange: ClosedRange<Double> = 0.7...1.3
    }

    public struct Redaction: Sendable {
        public var enabled: Bool = true

        /// Metadata keys that will be replaced with "<redacted>" (case-insensitive).
        public var redactedMetadataKeys: Set<String> = [
            "password", "passwd", "pwd",
            "secret", "token", "authorization", "cookie", "set-cookie",
            "email", "phone", "ssn"
        ]

        /// If a metadata key contains any of these substrings (case-insensitive), it will be redacted.
        public var redactedKeySubstrings: [String] = [
            "auth", "token", "secret", "pass", "pwd", "session"
        ]

        /// Optional custom hook for last-mile redaction/transformation.
        public var custom: (@Sendable (GELFMessage) -> GELFMessage)? = nil
    }

    public struct Configuration: Sendable {
        public var endpoint: URL                      // e.g. https://ingest.example.com/gelf
        public var authHeader: (name: String, value: String)? = nil

        public var host: String                       // GELF "host" field (avoid using real user names)
        public var facility: String? = nil

        public var minimumLevel: Logger.Level = .info // independent of Logger.logLevel
        public var includeSourceLocation: Bool = true

        public var batchSize: Int = 25
        public var flushIntervalSeconds: Double = 2.0
        public var maxQueueDepth: Int = 5_000
        public var maxBatchBytes: Int = 512 * 1024     // 512KB per request

        public var retry: RetryPolicy = .init()
        public var redaction: Redaction = .init()
        public var spool: SpoolConfiguration = .init()

        /// Constant fields included on every message as GELF additional fields (prefixed "_" automatically).
        public var staticFields: [String: String] = [:]

        public init(endpoint: URL, host: String) {
            self.endpoint = endpoint
            self.host = host
        }
    }

    public struct SpoolConfiguration: Sendable {
        public var enabled: Bool = true
        public var directory: URL? = nil
        public var maxTotalBytes: Int = 50 * 1_024 * 1_024   // 50MB default cap
        public var segmentMaxBytes: Int = 512 * 1_024       // align with default batch size

        public init(enabled: Bool = true, directory: URL? = nil) {
            self.enabled = enabled
            self.directory = directory
        }
    }

    /// Minimal Sendable GELF message representation.
    public struct GELFMessage: Sendable, Encodable {
        public var version: String = "1.1"
        public var host: String
        public var shortMessage: String
        public var fullMessage: String?
        public var timestamp: Double
        public var level: Int
        public var facility: String?

        /// Additional GELF fields; keys MUST begin with "_" when encoded.
        public var additional: [String: String]

        enum CodingKeys: String, CodingKey {
            case version
            case host
            case short_message
            case full_message
            case timestamp
            case level
            case facility
        }

        struct DynamicKey: CodingKey {
            var stringValue: String
            init?(stringValue: String) { self.stringValue = stringValue }
            var intValue: Int? { nil }
            init?(intValue: Int) { nil }
        }

        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(version, forKey: .version)
            try c.encode(host, forKey: .host)
            try c.encode(shortMessage, forKey: .short_message)
            try c.encode(timestamp, forKey: .timestamp)
            try c.encode(level, forKey: .level)
            if let fullMessage { try c.encode(fullMessage, forKey: .full_message) }
            if let facility { try c.encode(facility, forKey: .facility) }

            var dyn = encoder.container(keyedBy: DynamicKey.self)
            for (key, value) in additional {
                guard let dk = DynamicKey(stringValue: key) else { continue }
                try dyn.encode(value, forKey: dk)
            }
        }
    }

    // MARK: LogHandler requirements

    public var logLevel: Logger.Level = .trace
    public var metadata: Logger.Metadata = [:]
    public let label: String

    private let config: Configuration
    private let client: GELFHTTPClient

    public init(label: String, config: Configuration, client: GELFHTTPClient) {
        self.label = label
        self.config = config
        self.client = client
    }

    public subscript(metadataKey key: String) -> Logger.MetadataValue? {
        get { metadata[key] }
        set { metadata[key] = newValue }
    }

    public func log(
        level: Logger.Level,
        message: Logger.Message,
        metadata explicitMetadata: Logger.Metadata?,
        source: String,
        file: String,
        function: String,
        line: UInt
    ) {
        // Independent minimum level gate (lets you keep remote logs cleaner in debug builds).
        let threshold = maxLevel(self.logLevel, config.minimumLevel)
        guard level >= threshold else { return }

        var merged = self.metadata
        if let explicitMetadata {
            merged.merge(explicitMetadata, uniquingKeysWith: { _, new in new })
        }

        let rawMessage = message.description
        let (shortMessage, fullMessage) = splitShortAndFullMessage(rawMessage)

        var additional: [String: String] = [:]
        for (key, value) in config.staticFields {
            additional[ensureUnderscore(sanitizeKey(key))] = value
        }

        additional["_logger"] = label
        additional["_source"] = source

        if config.includeSourceLocation {
            additional["_file"] = file
            additional["_function"] = function
            additional["_line"] = String(line)
        }

        for (key, value) in merged {
            let mappedKey = key.hasPrefix("_") ? key : "meta_" + key
            additional[ensureUnderscore(sanitizeKey(mappedKey))] = value.flattenedString
        }

        let gelf = GELFMessage(
            host: config.host,
            shortMessage: shortMessage,
            fullMessage: fullMessage,
            timestamp: Date().timeIntervalSince1970,
            level: syslogLevel(for: level),
            facility: config.facility,
            additional: additional
        )

        // Fire-and-forget enqueue (do not block call site).
        Task {
            await client.enqueue(gelf)
        }
    }

    // MARK: Helpers

    private func splitShortAndFullMessage(_ message: String, shortLimit: Int = 512) -> (String, String?) {
        guard message.count > shortLimit else { return (message, nil) }
        let index = message.index(message.startIndex, offsetBy: shortLimit)
        return (String(message[..<index]), message)
    }

    private func syslogLevel(for level: Logger.Level) -> Int {
        // Syslog: 0 emerg, 1 alert, 2 crit, 3 err, 4 warning, 5 notice, 6 info, 7 debug.
        switch level {
        case .trace:
            return 7
        case .debug:
            return 7
        case .info:
            return 6
        case .notice:
            return 5
        case .warning:
            return 4
        case .error:
            return 3
        case .critical:
            return 2
        }
    }

    private func maxLevel(_ lhs: Logger.Level, _ rhs: Logger.Level) -> Logger.Level {
        (lhs >= rhs) ? lhs : rhs
    }

    private func sanitizeKey(_ key: String) -> String {
        // Keep it simple: alnum + underscore.
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_"))
        return key.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" }.reduce(into: "", { $0.append($1) })
    }

    private func ensureUnderscore(_ key: String) -> String {
        key.hasPrefix("_") ? key : "_" + key
    }
}

// MARK: - Metadata flattening

private extension Logger.MetadataValue {
    var flattenedString: String {
        switch self {
        case .string(let string):
            return string
        case .stringConvertible(let convertible):
            return String(describing: convertible)
        case .array(let array):
            return "[" + array.map { $0.flattenedString }.joined(separator: ",") + "]"
        case .dictionary(let dictionary):
            let inner = dictionary.map { key, value in "\"\(key)\":\"\(value.flattenedString)\"" }.joined(separator: ",")
            return "{\(inner)}"
        }
    }
}

// MARK: - GELFHTTPClient (batching + backoff + redaction)

public actor GELFHTTPClient {
    private let config: GELFHTTPLogHandler.Configuration
    private let session: URLSession
    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = []
        return encoder
    }()

    private var memoryQueue: [Data] = []
    private var spool: DiskSpool?
    private var sending: Bool = false
    private var failureCount: Int = 0
    private var retryScheduled: Bool = false

    // Precompiled redaction regexes (kept inside actor for safety).
    private lazy var messageRedactors: [(NSRegularExpression, String)] = [
        // Emails
        (try! NSRegularExpression(pattern: #"[A-Z0-9._%+\-]+@[A-Z0-9.\-]+\.[A-Z]{2,}"#, options: [.caseInsensitive]),
         "<redacted-email>"),
        // Bearer tokens
        (try! NSRegularExpression(pattern: #"Bearer\s+[A-Za-z0-9\-\._~\+\/]+=*"#, options: [.caseInsensitive]),
         "Bearer <redacted>"),
        // JWT-ish
        (try! NSRegularExpression(pattern: #"eyJ[A-Za-z0-9_\-]+\.[A-Za-z0-9_\-]+\.[A-Za-z0-9_\-]+"#, options: []),
         "<redacted-jwt>")
    ]

    public init(config: GELFHTTPLogHandler.Configuration) {
        self.config = config

        let urlConfig = URLSessionConfiguration.ephemeral
        urlConfig.waitsForConnectivity = true
        urlConfig.timeoutIntervalForRequest = 10
        urlConfig.timeoutIntervalForResource = 20
        self.session = URLSession(configuration: urlConfig)

        if config.spool.enabled {
            spool = DiskSpool(config: config.spool, label: config.host)
        }

        // Periodic flush loop (runs independently of enqueue calls).
        Task.detached { [weak self] in
            guard let self else { return }
            let nanos = UInt64(max(0.25, config.flushIntervalSeconds) * 1_000_000_000)
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: nanos)
                await self.flushIfNeeded()
            }
        }
    }

    public func enqueue(_ message: GELFHTTPLogHandler.GELFMessage) {
        let redacted = applyRedaction(message)
        guard let encoded = try? encoder.encode(redacted) else { return }

        var storedToSpool = false
        if var spool = spool {
            storedToSpool = spool.append(encoded)
            self.spool = spool
        }

        if !storedToSpool {
            memoryQueue.append(encoded)
            trimMemoryQueueIfNeeded()
        }

        if memoryQueue.count >= config.batchSize || (spool?.hasPendingData ?? false) {
            triggerFlush()
        }
    }

    public func flushIfNeeded() async {
        guard !memoryQueue.isEmpty || (spool?.hasPendingData ?? false) else { return }
        triggerFlush()
    }

    private func triggerFlush() {
        guard !sending else { return }
        sending = true
        Task.detached { [weak self] in
            guard let self else { return }
            await self.flushLoop()
        }
    }

    private func flushLoop() async {
        defer { sending = false }

        while true {
            if var spool = spool, let batch = spool.readBatch(maxLines: config.batchSize, maxBytes: config.maxBatchBytes) {
                let succeeded = await post(body: batch.data)
                if succeeded {
                    spool.commit(batch)
                    self.spool = spool
                    failureCount = 0
                    retryScheduled = false
                    continue
                }

                self.spool = spool
                failureCount += 1
                scheduleRetry()
                return
            }

            guard !memoryQueue.isEmpty else { return }

            let (body, count) = encodeMemoryBatch(prefixCount: min(memoryQueue.count, config.batchSize),
                                                  maxBytes: config.maxBatchBytes)
            guard count > 0 else { return }

            let succeeded = await post(body: body)

            if succeeded {
                removeFirst(count)
                failureCount = 0
                retryScheduled = false
                continue
            }

            failureCount += 1
            scheduleRetry()
            return
        }
    }

    private func encodeMemoryBatch(prefixCount: Int, maxBytes: Int) -> (Data, Int) {
        var output = Data()
        output.reserveCapacity(min(maxBytes, 64 * 1024))

        var included = 0
        for index in 0..<prefixCount {
            let line = memoryQueue[index]
            let separator = included == 0 ? Data() : Data("\r\n".utf8)
            let projectedSize = output.count + separator.count + line.count
            if projectedSize > maxBytes { break }

            output.append(separator)
            output.append(line)
            included += 1
        }

        return (output, included)
    }

    private func post(body: Data) async -> Bool {
        var request = URLRequest(url: config.endpoint)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        if let auth = config.authHeader {
            request.setValue(auth.value, forHTTPHeaderField: auth.name)
        }

        do {
            let (_, response) = try await session.data(for: request)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            return code == 202
        } catch {
            return false
        }
    }

    private func scheduleRetry() {
        guard !retryScheduled else { return }
        retryScheduled = true

        let base = config.retry.initialDelaySeconds
        let maxDelay = config.retry.maxDelaySeconds
        let exponent = min(16.0, Double(failureCount))
        let rawDelay = min(maxDelay, base * pow(2.0, exponent))
        let jitter = Double.random(in: config.retry.jitterFactorRange)
        let delay = max(0.5, rawDelay * jitter)

        Task.detached { [weak self] in
            guard let self else { return }
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            await self.flushIfNeeded()
        }
    }

    private func applyRedaction(_ message: GELFHTTPLogHandler.GELFMessage) -> GELFHTTPLogHandler.GELFMessage {
        guard config.redaction.enabled else { return message }

        var mutableMessage = message

        mutableMessage.shortMessage = redactString(mutableMessage.shortMessage)
        if let full = mutableMessage.fullMessage {
            mutableMessage.fullMessage = redactString(full)
        }

        var redactedAdditional: [String: String] = [:]
        for (key, value) in mutableMessage.additional {
            if shouldRedactKey(key) {
                redactedAdditional[key] = "<redacted>"
            } else {
                redactedAdditional[key] = redactString(value)
            }
        }
        mutableMessage.additional = redactedAdditional

        if let custom = config.redaction.custom {
            mutableMessage = custom(mutableMessage)
        }
        return mutableMessage
    }

    private func shouldRedactKey(_ key: String) -> Bool {
        let normalized = key.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "_"))
        if config.redaction.redactedMetadataKeys.contains(normalized) {
            return true
        }
        return config.redaction.redactedKeySubstrings.contains { normalized.contains($0.lowercased()) }
    }

    private func redactString(_ value: String) -> String {
        guard config.redaction.enabled else { return value }
        var output = value
        let fullRange = NSRange(output.startIndex..<output.endIndex, in: output)
        for (regex, replacement) in messageRedactors {
            output = regex.stringByReplacingMatches(in: output, options: [], range: fullRange, withTemplate: replacement)
        }
        return output
    }

    private func trimMemoryQueueIfNeeded() {
        while memoryQueue.count > config.maxQueueDepth {
            memoryQueue.removeFirst()
        }
    }

    private func removeFirst(_ count: Int) {
        guard count > 0 else { return }
        for _ in 0..<count {
            if memoryQueue.isEmpty { break }
            memoryQueue.removeFirst()
        }
    }
}

// MARK: - Disk spool (segment files + state)

private struct DiskSpool {
    private struct State: Codable {
        var readSegment: Int
        var readOffset: Int
        var writeSegment: Int
        var bytes: Int
    }

    private let config: GELFHTTPLogHandler.SpoolConfiguration
    private let directory: URL
    private let stateURL: URL
    private let fm = FileManager.default
    private var state: State

    var bytes: Int { state.bytes }
    var hasPendingData: Bool { state.bytes > 0 }

    init?(config: GELFHTTPLogHandler.SpoolConfiguration, label: String) {
        self.config = config

        if let directory = config.directory {
            self.directory = directory
        } else if let caches = fm.urls(for: .cachesDirectory, in: .userDomainMask).first {
            let folder = Self.sanitize(label)
            self.directory = caches.appendingPathComponent("UniLoggerSpool/\(folder)", isDirectory: true)
        } else {
            return nil
        }

        self.stateURL = directory.appendingPathComponent("spool-state.json", isDirectory: false)

        do {
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            return nil
        }

        if let loaded = Self.loadState(from: stateURL) {
            self.state = loaded
            migrateLegacyFiles(startingAt: state.writeSegment + 1)
        } else {
            self.state = State(readSegment: 0, readOffset: 0, writeSegment: 0, bytes: 0)
            normalizeSegmentsForFreshState()
        }

        state.bytes = (try? existingBytes()) ?? state.bytes
        normalizeState()
        persistState()
    }

    mutating func append(_ data: Data) -> Bool {
        var line = data
        line.append(0x0A)

        guard let target = prepareWriteSegment(for: line.count) else { return false }

        do {
            if !fm.fileExists(atPath: target.path) {
                fm.createFile(atPath: target.path, contents: nil)
            }
            let handle = try FileHandle(forWritingTo: target)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: line)
            state.bytes += line.count
            trimIfNeeded()
            persistState()
            return true
        } catch {
            return false
        }
    }

    mutating func readBatch(maxLines: Int, maxBytes: Int) -> SpoolBatch? {
        guard maxLines > 0, maxBytes > 0 else { return nil }
        normalizeState()
        guard hasPendingData else { return nil }

        var currentSegment = state.readSegment
        var currentOffset = state.readOffset
        var consumedSegments: [Int] = []
        var output = Data()
        var lines = 0
        var bytesUsed = 0

        outer: while lines < maxLines {
            guard let segmentIndex = firstExistingSegmentIndex(atOrAfter: currentSegment) else { break }
            if segmentIndex != currentSegment {
                currentSegment = segmentIndex
                currentOffset = 0
            }

            let url = segmentURL(for: currentSegment)
            guard let fileData = try? Data(contentsOf: url) else {
                currentSegment += 1
                currentOffset = 0
                continue
            }

            if currentOffset >= fileData.count {
                consumedSegments.append(currentSegment)
                currentSegment += 1
                currentOffset = 0
                continue
            }

            var idx = fileData.index(fileData.startIndex, offsetBy: currentOffset)
            while idx < fileData.endIndex && lines < maxLines {
                guard let newlineIndex = fileData[idx...].firstIndex(of: 0x0A) else {
                    break outer
                }
                let line = fileData[idx..<newlineIndex]
                if line.isEmpty {
                    currentOffset += 1
                    idx = fileData.index(after: newlineIndex)
                    continue
                }

                let separatorCount = lines == 0 ? 0 : 2
                let projectedSize = bytesUsed + separatorCount + line.count
                if projectedSize > maxBytes { break outer }

                if lines > 0 {
                    output.append(0x0D)
                    output.append(0x0A)
                }
                output.append(line)
                lines += 1
                bytesUsed = projectedSize

                currentOffset += line.count + 1
                idx = fileData.index(after: newlineIndex)
            }

            if currentOffset >= fileData.count {
                consumedSegments.append(currentSegment)
                currentSegment += 1
                currentOffset = 0
            } else if lines >= maxLines || bytesUsed >= maxBytes {
                break
            } else {
                break
            }
        }

        guard lines > 0 else { return nil }
        return SpoolBatch(
            data: output,
            count: lines,
            nextReadSegment: currentSegment,
            nextReadOffset: currentOffset,
            consumedSegments: consumedSegments
        )
    }

    mutating func commit(_ batch: SpoolBatch) {
        for segment in batch.consumedSegments {
            deleteSegment(segment)
        }
        state.readSegment = batch.nextReadSegment
        state.readOffset = batch.nextReadOffset
        normalizeState()
        persistState()
    }

    private func segmentURL(for index: Int) -> URL {
        directory.appendingPathComponent("segment-\(index).jsonl", isDirectory: false)
    }

    private func existingSegmentIndices() -> [Int] {
        guard let files = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else {
            return []
        }
        return files.compactMap { segmentIndex(from: $0.lastPathComponent) }
    }

    private func firstExistingSegmentIndex(atOrAfter index: Int) -> Int? {
        let indices = existingSegmentIndices().sorted()
        return indices.first { $0 >= index }
    }

    private func existingBytes() throws -> Int {
        let urls = try fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey], options: [.skipsHiddenFiles])
        var total = 0
        for url in urls {
            guard segmentIndex(from: url.lastPathComponent) != nil else { continue }
            if let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) {
                total += size
            }
        }
        return total
    }

    private mutating func normalizeState() {
        let indices = existingSegmentIndices().sorted()
        guard let minIndex = indices.first, let maxIndex = indices.last else {
            state.readSegment = 0
            state.readOffset = 0
            state.writeSegment = 0
            state.bytes = 0
            return
        }

        if state.readSegment < minIndex {
            state.readSegment = minIndex
            state.readOffset = 0
        }
        if state.readSegment > maxIndex {
            state.readSegment = minIndex
            state.readOffset = 0
        }
        if state.writeSegment < maxIndex {
            state.writeSegment = maxIndex
        }
        if state.writeSegment < state.readSegment {
            state.writeSegment = state.readSegment
        }

        if let size = fileSize(segmentURL(for: state.readSegment)), state.readOffset > size {
            state.readOffset = 0
        }
        if state.bytes == 0, let recalculated = try? existingBytes(), recalculated > 0 {
            state.bytes = recalculated
        }
    }

    private mutating func prepareWriteSegment(for lineSize: Int) -> URL? {
        normalizeState()
        let currentURL = segmentURL(for: state.writeSegment)
        let currentSize = fileSize(currentURL) ?? 0
        if currentSize > 0 && currentSize + lineSize > config.segmentMaxBytes {
            state.writeSegment += 1
        }
        return segmentURL(for: state.writeSegment)
    }

    private func fileSize(_ url: URL) -> Int? {
        (try? fm.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue
    }

    private mutating func deleteSegment(_ index: Int) {
        let url = segmentURL(for: index)
        if let size = fileSize(url) {
            state.bytes = max(0, state.bytes - size)
        }
        try? fm.removeItem(at: url)
    }

    private mutating func trimIfNeeded() {
        guard state.bytes > config.maxTotalBytes else { return }
        let indices = existingSegmentIndices().sorted()
        for index in indices {
            if state.bytes <= config.maxTotalBytes { break }
            deleteSegment(index)
        }
        normalizeState()
    }

    private mutating func normalizeSegmentsForFreshState() {
        guard let files = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.creationDateKey], options: [.skipsHiddenFiles]) else {
            return
        }
        let candidates = files.filter {
            let name = $0.lastPathComponent
            return segmentIndex(from: name) != nil || name.hasPrefix("spool-")
        }
        let sorted = candidates.sorted { lhs, rhs in
            let lhsDate = (try? lhs.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? Date.distantPast
            let rhsDate = (try? rhs.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? Date.distantPast
            return lhsDate < rhsDate
        }
        for (index, url) in sorted.enumerated() {
            let target = segmentURL(for: index)
            if url.path != target.path {
                try? fm.moveItem(at: url, to: target)
            }
        }
    }

    private mutating func migrateLegacyFiles(startingAt startIndex: Int) {
        guard let files = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.creationDateKey], options: [.skipsHiddenFiles]) else {
            return
        }
        let legacy = files.filter { $0.lastPathComponent.hasPrefix("spool-") }
        guard !legacy.isEmpty else { return }

        let sorted = legacy.sorted { lhs, rhs in
            let lhsDate = (try? lhs.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? Date.distantPast
            let rhsDate = (try? rhs.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? Date.distantPast
            return lhsDate < rhsDate
        }

        var index = startIndex
        for url in sorted {
            let target = segmentURL(for: index)
            try? fm.moveItem(at: url, to: target)
            index += 1
        }
        if index > state.writeSegment {
            state.writeSegment = index - 1
        }
    }

    private func persistState() {
        if let data = try? JSONEncoder().encode(state) {
            try? data.write(to: stateURL, options: .atomic)
        }
    }

    private static func loadState(from url: URL) -> State? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(State.self, from: data)
    }

    private static func sanitize(_ value: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._"))
        return value.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" }.reduce(into: "", { $0.append($1) })
    }

    private func segmentIndex(from filename: String) -> Int? {
        guard filename.hasPrefix("segment-"), filename.hasSuffix(".jsonl") else { return nil }
        let start = filename.index(filename.startIndex, offsetBy: "segment-".count)
        let end = filename.index(filename.endIndex, offsetBy: -".jsonl".count)
        return Int(filename[start..<end])
    }
}

private struct SpoolBatch {
    let data: Data
    let count: Int
    let nextReadSegment: Int
    let nextReadOffset: Int
    let consumedSegments: [Int]
}
