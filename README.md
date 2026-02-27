# UniLogger

Swift Package providing a GELF-over-HTTP `LogHandler` intended for Graylog ingest via a TLS-terminated reverse proxy. Key traits:

- Batching with newline-delimited JSON (enable **Bulk Receiving** on the Graylog GELF HTTP input)
- Exponential backoff with jitter for retries
- Metadata/message redaction hooks to limit sensitive fields
- Offline-first (disk-backed spool) with bounded disk usage and redaction before disk
- Plays nicely with multiplexed logging (console, OSLog, Graylog)

## Adding the package

```swift
.package(url: "https://github.com/apple/swift-log.git", from: "1.6.0"),
.package(url: "https://github.com/inmotionsoftware/swift-log-oslog.git", from: "1.0.0"),
```

The `UniLogger` target enforces strict concurrency checking (`-strict-concurrency=complete`) to match the workspace settings.

## Usage

```swift
import Logging
import LoggingOSLog
import UniLogger

enum AppLogging {
    static func bootstrap(env: String) {
        let endpoint = URL(string: "https://ingest.example.com/gelf")!

        var gelfConfig = GELFHTTPLogHandler.Configuration(endpoint: endpoint, host: "com.yourco.yourapp")
        gelfConfig.authHeader = (name: "Authorization", value: "Bearer <token>")
        gelfConfig.staticFields = ["_service": "yourapp", "_env": env]
        gelfConfig.redaction.redactedMetadataKeys.formUnion(["user_id", "device_id"])
        gelfConfig.spool.maxTotalBytes = 50 * 1_024 * 1_024 // cap disk use (bytes)

        let gelfClient = GELFHTTPClient(config: gelfConfig)
        let traceProvider = TraceContext.metadataProvider()

        LoggingSystem.bootstrap({ label, metadataProvider in
            var console = StreamLogHandler.standardError(label: label)

            var oslog = OSLogHandler(subsystem: "com.yourco.yourapp", category: label)
            #if !DEBUG
            oslog.metadataContentType = .private
            #endif

            let gelf = GELFHTTPLogHandler(label: label, config: gelfConfig, client: gelfClient)
            return MultiplexLogHandler([console, oslog, gelf], metadataProvider: metadataProvider)
        }, metadataProvider: .multiplex([traceProvider]))
    }
}
```

## Semantic trace logging (for another app)

Use `TraceContext` to propagate trace IDs across async boundaries and inject them into every log line via a metadata provider. Then emit `SemanticEvent` metadata on each important boundary.

### 1) Create a root context for inbound work

```swift
func handleRequest(
    _ request: URLRequest,
    logger: Logger
) async throws {
    let parent = request.value(forHTTPHeaderField: "traceparent").flatMap(TraceParent.init(headerValue:))
    let traceID = parent?.traceID ?? TraceIdentifiers.traceID()
    let spanID = TraceIdentifiers.spanID()
    let journal = BreadcrumbJournal()

    let ctx = TraceContext.Context(
        traceID: traceID,
        spanID: spanID,
        parentSpanID: parent?.spanID,
        service: "yourapp",
        journal: journal
    )

    try await TraceContext.withContext(ctx) {
        let start = SemanticEvent(name: "span.start", component: "api", operation: "GET /v1/items")
        logger.info("request start", metadata: start.metadata())

        // ...handle work...

        let end = SemanticEvent(name: "span.end", component: "api", operation: "GET /v1/items")
        logger.info("request end", metadata: end.metadata())
    }
}
```

### 2) HTTP server middleware helper (framework-agnostic)

```swift
struct TraceSpan {
    static func run<T>(
        traceparentHeader: String?,
        component: String,
        operation: String,
        logger: Logger,
        handler: () async throws -> T
    ) async throws -> (result: T, traceparent: TraceParent) {
        let parent = traceparentHeader.flatMap(TraceParent.init(headerValue:))
        let traceID = parent?.traceID ?? TraceIdentifiers.traceID()
        let spanID = TraceIdentifiers.spanID()
        let ctx = TraceContext.Context(
            traceID: traceID,
            spanID: spanID,
            parentSpanID: parent?.spanID,
            service: "yourapp",
            journal: TraceContext.current?.journal ?? BreadcrumbJournal()
        )

        return try await TraceContext.withContext(ctx) {
            let start = Date()
            let startEvent = SemanticEvent(
                name: "span.start",
                component: component,
                operation: operation
            )
            logger.info("request start", metadata: startEvent.metadata())

            do {
                let result = try await handler()
                let durationMs = Int(Date().timeIntervalSince(start) * 1000)
                let endEvent = SemanticEvent(
                    name: "span.end",
                    component: component,
                    operation: operation,
                    durationMs: durationMs
                )
                logger.info("request end", metadata: endEvent.metadata())
                return (result, TraceParent(traceID: traceID, spanID: spanID))
            } catch {
                let failEvent = SemanticEvent(
                    name: "invariant.fail",
                    component: component,
                    operation: operation,
                    errorCode: "request_failed",
                    reason: error.localizedDescription
                )
                var meta = failEvent.metadata()
                meta.merge(TraceContext.breadcrumbsMetadata(), uniquingKeysWith: { _, new in new })
                logger.error("request failed", metadata: meta)
                throw error
            }
        }
    }
}
```

### 3) Create child spans for outbound calls

```swift
var request = URLRequest(url: URL(string: "https://example.com/v1/items")!)
let traceID = TraceContext.current?.traceID ?? TraceIdentifiers.traceID()
let spanID = TraceIdentifiers.spanID()
let parentSpanID = TraceContext.current?.spanID
let traceparent = TraceParent(traceID: traceID, spanID: spanID).headerValue
request.setValue(traceparent, forHTTPHeaderField: "traceparent")

let ctx = TraceContext.Context(
    traceID: traceID,
    spanID: spanID,
    parentSpanID: parentSpanID,
    service: "yourapp",
    journal: TraceContext.current?.journal
)

try await TraceContext.withContext(ctx) {
    let start = SemanticEvent(
        name: "external.call.start",
        component: "network",
        operation: "GET /v1/items",
        peer: "example.com",
        httpMethod: "GET",
        httpPath: "/v1/items"
    )
    logger.info("request", metadata: start.metadata())
}
```

### 4) Attach breadcrumbs on failure

```swift
logger.error(
    "request failed",
    metadata: TraceContext.breadcrumbsMetadata()
)
```

### 5) Minimal sample app

```swift
import Foundation
import Logging
import UniLogger

@main
struct SemanticTraceSample {
    static func main() async throws {
        AppLogging.bootstrap(env: "dev")
        let logger = Logger(label: "sample.trace")

        let traceID = TraceIdentifiers.traceID()
        let spanID = TraceIdentifiers.spanID()
        let ctx = TraceContext.Context(
            traceID: traceID,
            spanID: spanID,
            service: "sample",
            journal: BreadcrumbJournal()
        )

        try await TraceContext.withContext(ctx) {
            let start = SemanticEvent(name: "span.start", component: "demo", operation: "run")
            logger.info("demo start", metadata: start.metadata())

            var request = URLRequest(url: URL(string: "https://example.com/health")!)
            let childSpan = TraceIdentifiers.spanID()
            let traceparent = TraceParent(traceID: traceID, spanID: childSpan).headerValue
            request.setValue(traceparent, forHTTPHeaderField: "traceparent")
            _ = try await URLSession.shared.data(for: request)

            let end = SemanticEvent(name: "span.end", component: "demo", operation: "run")
            logger.info("demo end", metadata: end.metadata())
        }
    }
}
```

Metadata keys that start with `_` are passed through as raw GELF fields (no `meta_` prefix), which aligns with the semantic logging schema in `docs/ai/log_schema.yaml`.

Ensure your Graylog GELF HTTP input listens on `12202`, has **Bulk Receiving** enabled, and requires the same auth header you configure above.

## Behavior notes

- The handler keeps a bounded in-memory queue (`maxQueueDepth`) and will drop the oldest entries if pressure persists.
- Batches flush on `batchSize` or `flushIntervalSeconds`. Backoff caps at `maxDelaySeconds` with jitter.
- Redaction happens before encoding: metadata keys listed in `redactedMetadataKeys` or matching `redactedKeySubstrings` become `<redacted>`. Message strings are scrubbed with a few high-value regexes (emails, bearer tokens, JWT-like strings). Provide a `Redaction.custom` closure for additional rules.
- Disk spool (enabled by default) writes redacted GELF lines to `~/Library/Caches/UniLoggerSpool/<host>` and will stay within `spool.maxTotalBytes`, removing oldest entries first. Set `spool.enabled = false` to disable.
- The HTTP client uses `URLSession` in ephemeral mode and expects a `202 Accepted` response from Graylog.
