import Foundation
import XCTest
@testable import UniLogger

final class UniLoggerTests: XCTestCase {
    func testConfigurationDefaults() throws {
        let endpoint = try XCTUnwrap(URL(string: "https://example.com/gelf"))
        let config = GELFHTTPLogHandler.Configuration(endpoint: endpoint, host: "com.example.app")

        XCTAssertEqual(config.batchSize, 25)
        XCTAssertEqual(config.maxQueueDepth, 5_000)
        XCTAssertEqual(config.minimumLevel, .info)
        XCTAssertEqual(config.host, "com.example.app")
    }

    func testSpoolDefaults() throws {
        let endpoint = try XCTUnwrap(URL(string: "https://example.com/gelf"))
        let config = GELFHTTPLogHandler.Configuration(endpoint: endpoint, host: "com.example.app")

        XCTAssertTrue(config.spool.enabled)
        XCTAssertEqual(config.spool.segmentMaxBytes, 512 * 1024)
        XCTAssertEqual(config.spool.maxTotalBytes, 50 * 1_024 * 1_024)
    }

    func testBreadcrumbJournalDropsOldest() throws {
        let journal = BreadcrumbJournal(config: .init(maxEvents: 2, maxBytes: 10_000))
        journal.add(event: "a")
        journal.add(event: "b")
        journal.add(event: "c")

        let snapshot = journal.snapshot()
        XCTAssertEqual(snapshot.count, 2)
        XCTAssertEqual(snapshot.first?.event, "b")
        XCTAssertEqual(snapshot.last?.event, "c")
    }

    func testBreadcrumbJournalSnapshotJSON() throws {
        let journal = BreadcrumbJournal(config: .init(maxEvents: 3, maxBytes: 10_000))
        journal.add(event: "span.start", fields: ["component": "sessions"])
        journal.add(event: "span.end", fields: ["status": "ok"])

        let json = try XCTUnwrap(journal.snapshotJSON())
        let data = try XCTUnwrap(json.data(using: .utf8))
        let decoded = try JSONDecoder().decode([Breadcrumb].self, from: data)

        XCTAssertEqual(decoded.count, 2)
        XCTAssertEqual(decoded.first?.event, "span.start")
        XCTAssertEqual(decoded.last?.event, "span.end")
    }

    func testTraceContextMetadataProvider() throws {
        let ctx = TraceContext.Context(
            traceID: "trace-123",
            spanID: "span-456",
            parentSpanID: "parent-789",
            service: "svc",
            sessionID: "sess"
        )

        let metadata = TraceContext.withContext(ctx) {
            TraceContext.currentMetadata()
        }

        if case .string(let value) = metadata["_trace_id"] {
            XCTAssertEqual(value, "trace-123")
        } else {
            XCTFail("missing _trace_id")
        }

        if case .string(let value) = metadata["_span_id"] {
            XCTAssertEqual(value, "span-456")
        } else {
            XCTFail("missing _span_id")
        }

        if case .string(let value) = metadata["_parent_span_id"] {
            XCTAssertEqual(value, "parent-789")
        } else {
            XCTFail("missing _parent_span_id")
        }
    }

    func testTraceIdentifiersLengths() throws {
        let traceID = TraceIdentifiers.traceID()
        let spanID = TraceIdentifiers.spanID()

        XCTAssertEqual(traceID.count, 32)
        XCTAssertEqual(spanID.count, 16)
    }

    func testTraceParentRoundTrip() throws {
        let traceID = "0af7651916cd43dd8448eb211c80319c"
        let spanID = "b9c7c989f97918e1"
        let parent = TraceParent(traceID: traceID, spanID: spanID)
        let header = parent.headerValue

        let parsed = try XCTUnwrap(TraceParent(headerValue: header))
        XCTAssertEqual(parsed.traceID, traceID)
        XCTAssertEqual(parsed.spanID, spanID)
        XCTAssertEqual(parsed.traceFlags, "01")
    }
}
