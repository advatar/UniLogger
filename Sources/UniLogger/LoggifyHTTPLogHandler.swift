import Foundation
import Logging

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

/// A `swift-log` handler that sends Loggify schema-v1 OTLP/HTTP JSON.
///
/// Records are redacted before entering the bounded disk spool. Delivery is
/// batched and retried with exponential backoff, matching UniLogger's GELF
/// transport behavior while keeping applications independent of Graylog.
public struct LoggifyHTTPLogHandler: LogHandler {
  public struct Configuration: Sendable {
    public var endpoint: URL
    public var projectKey: String
    public var service: String
    public var environment: String
    public var minimumLevel: Logger.Level = .info
    public var batchSize: Int = 25
    public var flushIntervalSeconds: Double = 2
    public var maxQueueDepth: Int = 5_000
    public var maxBatchBytes: Int = 512 * 1_024
    public var timeoutSeconds: Double = 10
    public var retry: GELFHTTPLogHandler.RetryPolicy = .init()
    public var spool: GELFHTTPLogHandler.SpoolConfiguration = .init()
    public var staticAttributes: [String: String] = [:]
    public var redactedMetadataKeys: Set<String> = [
      "password", "passwd", "pwd", "secret", "token", "authorization",
      "cookie", "set-cookie", "email", "phone", "ssn",
      "account_id", "patient_id", "medical_record_id", "raw_health_data",
    ]
    public var redactedKeySubstrings: [String] = [
      "auth", "token", "secret", "pass", "pwd", "session",
    ]

    public init(
      endpoint: URL,
      projectKey: String,
      service: String,
      environment: String
    ) {
      self.endpoint = endpoint
      self.projectKey = projectKey
      self.service = service
      self.environment = environment
    }
  }

  public var logLevel: Logger.Level = .trace
  public var metadata: Logger.Metadata = [:]
  public let label: String

  private let configuration: Configuration
  private let client: LoggifyHTTPClient

  public init(label: String, configuration: Configuration, client: LoggifyHTTPClient) {
    self.label = label
    self.configuration = configuration
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
    let threshold = logLevel >= configuration.minimumLevel ? logLevel : configuration.minimumLevel
    guard level >= threshold else { return }

    var merged = metadata
    if let explicitMetadata {
      merged.merge(explicitMetadata, uniquingKeysWith: { _, new in new })
    }
    guard
      let record = Self.makeRecord(
        level: level,
        message: message.description,
        metadata: merged,
        label: label,
        configuration: configuration
      )
    else { return }

    Task { await client.enqueue(record) }
  }

  static func makeRecord(
    level: Logger.Level,
    message: String,
    metadata: Logger.Metadata,
    label: String,
    configuration: Configuration,
    timestamp: Date = Date()
  ) -> Data? {
    var mutable = metadata
    let eventName =
      mutable.removeValue(forKey: "_event")?.flattenedString
      ?? mutable.removeValue(forKey: "event.name")?.flattenedString
    let traceID = validHex(mutable.removeValue(forKey: "_trace_id")?.flattenedString, count: 32)
    let spanID = validHex(mutable.removeValue(forKey: "_span_id")?.flattenedString, count: 16)

    let mappings: [String: String] = [
      "_component": "loggify.component",
      "_operation": "loggify.operation",
      "_flow_id": "loggify.flow.id",
      "_error_code": "loggify.error.code",
      "_reason": "loggify.reason",
      "_expected": "loggify.expected",
      "_actual": "loggify.actual",
      "_trace_history": "loggify.trace.history",
      "_peer": "server.address",
      "_http_method": "http.request.method",
      "_http_path": "url.path",
      "_http_status": "http.response.status_code",
      "_duration_ms": "loggify.duration.ms",
    ]

    var attributes = configuration.staticAttributes
    attributes["loggify.logger"] = label
    for (key, value) in mutable {
      let mapped = mappings[key] ?? "loggify.metadata.\(sanitizeKey(key))"
      attributes[mapped] = redact(value.flattenedString, key: key, configuration: configuration)
    }

    var record: [String: Any] = [
      "timeUnixNano": String(UInt64(timestamp.timeIntervalSince1970 * 1_000_000_000)),
      "severityNumber": severityNumber(level),
      "severityText": severityText(level),
      "body": ["stringValue": redact(message, key: "message", configuration: configuration)],
      "attributes": otlpAttributes(attributes),
    ]
    if let eventName { record["eventName"] = eventName }
    if let traceID { record["traceId"] = traceID }
    if let spanID { record["spanId"] = spanID }
    if traceID != nil, spanID != nil { record["flags"] = 1 }
    return try? JSONSerialization.data(withJSONObject: record, options: [.sortedKeys])
  }

  private static func validHex(_ value: String?, count: Int) -> String? {
    guard let value, value.count == count,
      value.unicodeScalars.allSatisfy({
        ("0"..."9").contains($0) || ("a"..."f").contains($0) || ("A"..."F").contains($0)
      })
    else { return nil }
    return value.lowercased()
  }

  private static func sanitizeKey(_ key: String) -> String {
    let allowed = CharacterSet.alphanumerics.union(.init(charactersIn: "._-"))
    return key.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" }
      .reduce(into: "", { $0.append($1) })
      .trimmingCharacters(in: CharacterSet(charactersIn: "_"))
  }

  private static func redact(_ value: String, key: String, configuration: Configuration) -> String {
    let normalized = key.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "_"))
    if configuration.redactedMetadataKeys.contains(normalized)
      || configuration.redactedKeySubstrings.contains(where: {
        normalized.contains($0.lowercased())
      })
    {
      return "<redacted>"
    }

    var output = value
    let patterns = [
      (#"[A-Z0-9._%+\-]+@[A-Z0-9.\-]+\.[A-Z]{2,}"#, "<redacted-email>"),
      (#"Bearer\s+[A-Za-z0-9\-\._~\+\/]+=*"#, "Bearer <redacted>"),
      (#"eyJ[A-Za-z0-9_\-]+\.[A-Za-z0-9_\-]+\.[A-Za-z0-9_\-]+"#, "<redacted-jwt>"),
    ]
    for (pattern, replacement) in patterns {
      guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
      else { continue }
      let range = NSRange(output.startIndex..<output.endIndex, in: output)
      output = regex.stringByReplacingMatches(in: output, range: range, withTemplate: replacement)
    }
    return output
  }

  private static func otlpAttributes(_ values: [String: String]) -> [[String: Any]] {
    values.sorted(by: { $0.key < $1.key }).map {
      ["key": $0.key, "value": ["stringValue": $0.value]]
    }
  }

  private static func severityNumber(_ level: Logger.Level) -> Int {
    switch level {
    case .trace: 1
    case .debug: 5
    case .info: 9
    case .notice: 10
    case .warning: 13
    case .error: 17
    case .critical: 21
    }
  }

  private static func severityText(_ level: Logger.Level) -> String {
    switch level {
    case .trace: "TRACE"
    case .debug: "DEBUG"
    case .info: "INFO"
    case .notice: "NOTICE"
    case .warning: "WARN"
    case .error: "ERROR"
    case .critical: "FATAL"
    }
  }
}

public actor LoggifyHTTPClient {
  private let configuration: LoggifyHTTPLogHandler.Configuration
  private let session: URLSession
  private var memoryQueue: [Data] = []
  private var spool: DiskSpool?
  private var sending = false
  private var failureCount = 0
  private var retryScheduled = false

  public init(configuration: LoggifyHTTPLogHandler.Configuration) {
    self.configuration = configuration
    let sessionConfiguration = URLSessionConfiguration.ephemeral
    sessionConfiguration.waitsForConnectivity = true
    sessionConfiguration.timeoutIntervalForRequest = configuration.timeoutSeconds
    sessionConfiguration.timeoutIntervalForResource = configuration.timeoutSeconds * 2
    session = URLSession(configuration: sessionConfiguration)
    if configuration.spool.enabled {
      spool = DiskSpool(config: configuration.spool, label: "loggify-\(configuration.service)")
    }

    Task.detached { [weak self] in
      guard let self else { return }
      let interval = UInt64(max(0.25, configuration.flushIntervalSeconds) * 1_000_000_000)
      while !Task.isCancelled {
        try? await Task.sleep(nanoseconds: interval)
        await self.flushIfNeeded()
      }
    }
  }

  public func enqueue(_ record: Data) {
    var storedToSpool = false
    if var spool {
      storedToSpool = spool.append(record)
      self.spool = spool
    }
    if !storedToSpool {
      memoryQueue.append(record)
      while memoryQueue.count > configuration.maxQueueDepth { memoryQueue.removeFirst() }
    }
    if memoryQueue.count >= configuration.batchSize || (spool?.hasPendingData ?? false) {
      triggerFlush()
    }
  }

  public func flushIfNeeded() {
    guard !memoryQueue.isEmpty || (spool?.hasPendingData ?? false) else { return }
    triggerFlush()
  }

  /// Waits for the currently queued records to be attempted.
  ///
  /// Call this from application lifecycle hooks before suspension or
  /// termination. Failed records remain in the bounded spool for retry.
  public func flush() async {
    guard !sending else { return }
    guard !memoryQueue.isEmpty || (spool?.hasPendingData ?? false) else { return }
    sending = true
    await flushLoop()
  }

  private func triggerFlush() {
    guard !sending else { return }
    sending = true
    Task { await flushLoop() }
  }

  private func flushLoop() async {
    defer { sending = false }
    while true {
      if var spool,
        let batch = spool.readBatch(
          maxLines: configuration.batchSize,
          maxBytes: configuration.maxBatchBytes
        )
      {
        if await post(records: batch.data) {
          spool.commit(batch)
          self.spool = spool
          resetRetry()
          continue
        }
        self.spool = spool
        failed()
        return
      }

      guard !memoryQueue.isEmpty else { return }
      let (records, count) = memoryBatch()
      guard count > 0 else { return }
      if await post(records: records) {
        memoryQueue.removeFirst(min(count, memoryQueue.count))
        resetRetry()
        continue
      }
      failed()
      return
    }
  }

  private func memoryBatch() -> (Data, Int) {
    var output = Data()
    var count = 0
    for record in memoryQueue.prefix(configuration.batchSize) {
      let separator = count == 0 ? Data() : Data("\n".utf8)
      guard output.count + separator.count + record.count <= configuration.maxBatchBytes else {
        break
      }
      output.append(separator)
      output.append(record)
      count += 1
    }
    return (output, count)
  }

  private func post(records: Data) async -> Bool {
    guard let body = Self.payload(records: records, configuration: configuration) else {
      return false
    }
    var request = URLRequest(url: Self.logsURL(configuration.endpoint))
    request.httpMethod = "POST"
    request.httpBody = body
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue(configuration.projectKey, forHTTPHeaderField: "X-Loggify-Key")
    do {
      let (_, response) = try await session.data(for: request)
      let status = (response as? HTTPURLResponse)?.statusCode ?? 0
      return (200..<300).contains(status)
    } catch {
      return false
    }
  }

  static func payload(
    records: Data,
    configuration: LoggifyHTTPLogHandler.Configuration
  ) -> Data? {
    let normalized = String(decoding: records, as: UTF8.self)
      .split(whereSeparator: \.isNewline)
      .joined(separator: ",")
    guard !normalized.isEmpty else { return nil }
    let resource: [String: Any] = [
      "attributes": [
        ["key": "service.name", "value": ["stringValue": configuration.service]],
        [
          "key": "deployment.environment.name", "value": ["stringValue": configuration.environment],
        ],
        ["key": "loggify.schema.version", "value": ["intValue": "1"]],
      ]
    ]
    guard let resourceData = try? JSONSerialization.data(withJSONObject: resource),
      let resourceJSON = String(data: resourceData, encoding: .utf8)
    else { return nil }
    let payload = """
      {"resourceLogs":[{"resource":\(resourceJSON),"scopeLogs":[{"scope":{"name":"unilogger","version":"1"},"logRecords":[\(normalized)]}]}]}
      """
    return Data(payload.utf8)
  }

  func sendForTesting(records: Data) async -> Bool {
    await post(records: records)
  }

  private static func logsURL(_ endpoint: URL) -> URL {
    if endpoint.path.hasSuffix("/v1/logs") { return endpoint }
    return endpoint.appendingPathComponent("v1/logs")
  }

  private func resetRetry() {
    failureCount = 0
    retryScheduled = false
  }

  private func failed() {
    failureCount += 1
    scheduleRetry()
  }

  private func scheduleRetry() {
    guard !retryScheduled else { return }
    retryScheduled = true
    let exponent = min(16.0, Double(failureCount))
    let raw = min(
      configuration.retry.maxDelaySeconds,
      configuration.retry.initialDelaySeconds * pow(2, exponent)
    )
    let delay = max(0.5, raw * Double.random(in: configuration.retry.jitterFactorRange))
    Task { [weak self] in
      try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
      guard let self else { return }
      await self.clearScheduledRetryAndFlush()
    }
  }

  private func clearScheduledRetryAndFlush() {
    retryScheduled = false
    flushIfNeeded()
  }
}
