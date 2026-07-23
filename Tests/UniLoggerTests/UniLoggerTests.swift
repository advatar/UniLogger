/// Exercises uni Logger Tests behavior for UniLogger in the shared Swift packages.
///
/// Primary declarations include `UniLoggerTests`.

import Foundation
import XCTest
@testable import UniLogger

/// Implements the uni logger tests type for the UniLogger module.
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
            flowID: "flow-abc",
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

        if case .string(let value) = metadata["_flow_id"] {
            XCTAssertEqual(value, "flow-abc")
        } else {
            XCTFail("missing _flow_id")
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

    func testRedactionRecomputesRangeAfterEachReplacement() async throws {
        let endpoint = try XCTUnwrap(URL(string: "https://example.com/gelf"))
        var config = GELFHTTPLogHandler.Configuration(endpoint: endpoint, host: "com.example.app")
        config.batchSize = 100
        config.spool.enabled = false

        let client = GELFHTTPClient(config: config)
        let message = GELFHTTPLogHandler.GELFMessage(
            host: "com.example.app",
            shortMessage: "user extremely.long.email.address@example.com Bearer abcdefghijklmnopqrstuvwxyz",
            fullMessage: nil,
            timestamp: 0,
            level: 6,
            facility: nil,
            additional: [
                "_detail": "contact extremely.long.email.address@example.com with Bearer abcdefghijklmnopqrstuvwxyz"
            ]
        )

        await client.enqueue(message)
    }

    func testGELFRedactionMasksSensitiveMessagesAndMetadata() async throws {
        let endpoint = try XCTUnwrap(URL(string: "https://example.com/gelf"))
        var config = GELFHTTPLogHandler.Configuration(endpoint: endpoint, host: "com.example.app")
        config.spool.enabled = false

        let client = GELFHTTPClient(config: config)
        let message = GELFHTTPLogHandler.GELFMessage(
            host: "com.example.app",
            shortMessage: "Contact beta.user@example.com with Bearer abcdefghijklmnopqrstuvwxyz",
            fullMessage: "JWT eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjMifQ.signatureValue appears here",
            timestamp: 0,
            level: 6,
            facility: nil,
            additional: [
                "_detail": "secondary beta.user@example.com token Bearer abcdefghijklmnopqrstuvwxyz",
                "_auth_token": "secret-value",
                "_plain": "safe"
            ]
        )

        let redacted = await client.redactedMessageForTesting(message)

        XCTAssertFalse(redacted.shortMessage.contains("beta.user@example.com"))
        XCTAssertFalse(redacted.shortMessage.contains("abcdefghijklmnopqrstuvwxyz"))
        XCTAssertEqual(redacted.shortMessage, "Contact <redacted-email> with Bearer <redacted>")
        XCTAssertEqual(redacted.fullMessage, "JWT <redacted-jwt> appears here")
        XCTAssertEqual(redacted.additional["_auth_token"], "<redacted>")
        XCTAssertEqual(redacted.additional["_plain"], "safe")
        XCTAssertEqual(redacted.additional["_detail"], "secondary <redacted-email> token Bearer <redacted>")
    }

    func testLoggifyRecordMapsSemanticAndTraceFields() throws {
        let endpoint = try XCTUnwrap(URL(string: "https://gateway.example.com"))
        let config = LoggifyHTTPLogHandler.Configuration(
            endpoint: endpoint,
            projectKey: "project-key",
            service: "cardio",
            environment: "test"
        )
        let traceID = "0af7651916cd43dd8448eb211c80319c"
        let spanID = "b9c7c989f97918e1"
        let record = try XCTUnwrap(LoggifyHTTPLogHandler.makeRecord(
            level: .error,
            message: "sync failed",
            metadata: [
                "_event": "invariant.fail",
                "_component": "ecg",
                "_operation": "ecg.sync",
                "_flow_id": "flow-1",
                "_trace_id": .string(traceID),
                "_span_id": .string(spanID)
            ],
            label: "cardio.sync",
            configuration: config,
            timestamp: Date(timeIntervalSince1970: 1)
        ))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: record) as? [String: Any])

        XCTAssertEqual(json["eventName"] as? String, "invariant.fail")
        XCTAssertEqual(json["traceId"] as? String, traceID)
        XCTAssertEqual(json["spanId"] as? String, spanID)
        XCTAssertEqual(json["severityNumber"] as? Int, 17)
        XCTAssertEqual(attribute("loggify.component", in: json), "ecg")
        XCTAssertEqual(attribute("loggify.operation", in: json), "ecg.sync")
        XCTAssertEqual(attribute("loggify.flow.id", in: json), "flow-1")
    }

    func testLoggifyRecordRedactsBeforeSpooling() throws {
        let endpoint = try XCTUnwrap(URL(string: "https://gateway.example.com"))
        let config = LoggifyHTTPLogHandler.Configuration(
            endpoint: endpoint,
            projectKey: "project-key",
            service: "cardio",
            environment: "test"
        )
        let record = try XCTUnwrap(LoggifyHTTPLogHandler.makeRecord(
            level: .info,
            message: "contact patient@example.com with Bearer abcdefghijklmnopqrstuvwxyz",
            metadata: ["patient_id": "123", "safe": "ok"],
            label: "cardio",
            configuration: config
        ))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: record) as? [String: Any])
        let body = try XCTUnwrap(json["body"] as? [String: String])

        XCTAssertEqual(body["stringValue"], "contact <redacted-email> with Bearer <redacted>")
        XCTAssertEqual(attribute("loggify.metadata.patient_id", in: json), "<redacted>")
        XCTAssertEqual(attribute("loggify.metadata.safe", in: json), "ok")
    }

    func testLoggifyPayloadBatchesRecordsWithRequiredResources() throws {
        let endpoint = try XCTUnwrap(URL(string: "https://gateway.example.com"))
        let config = LoggifyHTTPLogHandler.Configuration(
            endpoint: endpoint,
            projectKey: "project-key",
            service: "cardio",
            environment: "production"
        )
        let records = Data(#"{"body":{"stringValue":"one"}}"#.utf8)
            + Data("\n".utf8)
            + Data(#"{"body":{"stringValue":"two"}}"#.utf8)
        let payload = try XCTUnwrap(LoggifyHTTPClient.payload(records: records, configuration: config))
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: payload) as? [String: Any])
        let resourceLogs = try XCTUnwrap(root["resourceLogs"] as? [[String: Any]])
        let resource = try XCTUnwrap(resourceLogs.first?["resource"] as? [String: Any])
        let scopeLogs = try XCTUnwrap(resourceLogs.first?["scopeLogs"] as? [[String: Any]])
        let logRecords = try XCTUnwrap(scopeLogs.first?["logRecords"] as? [[String: Any]])

        XCTAssertEqual(resourceAttribute("service.name", in: resource), "cardio")
        XCTAssertEqual(resourceAttribute("deployment.environment.name", in: resource), "production")
        XCTAssertEqual(resourceAttribute("loggify.schema.version", in: resource), "1")
        XCTAssertEqual(logRecords.count, 2)
    }

    func testLoggifyLiveGatewayWhenConfigured() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let endpointValue = environment["LOGGIFY_TEST_ENDPOINT"],
              let key = environment["LOGGIFY_TEST_KEY"],
              let endpoint = URL(string: endpointValue) else {
            throw XCTSkip("Set LOGGIFY_TEST_ENDPOINT and LOGGIFY_TEST_KEY for the live gateway test")
        }
        var config = LoggifyHTTPLogHandler.Configuration(
            endpoint: endpoint,
            projectKey: key,
            service: "unilogger-tests",
            environment: "test"
        )
        config.spool.enabled = false
        let record = try XCTUnwrap(LoggifyHTTPLogHandler.makeRecord(
            level: .info,
            message: "unilogger integration verified",
            metadata: [
                "_event": "state.transition",
                "_component": "integration",
                "_operation": "unilogger.live_test"
            ],
            label: "unilogger.tests",
            configuration: config
        ))

        let client = LoggifyHTTPClient(configuration: config)
        let succeeded = await client.sendForTesting(records: record)
        XCTAssertTrue(succeeded)
    }

    private func attribute(_ key: String, in record: [String: Any]) -> String? {
        let attributes = record["attributes"] as? [[String: Any]]
        let item = attributes?.first { $0["key"] as? String == key }
        return (item?["value"] as? [String: String])?["stringValue"]
    }

    private func resourceAttribute(_ key: String, in resource: [String: Any]) -> String? {
        let attributes = resource["attributes"] as? [[String: Any]]
        let item = attributes?.first { $0["key"] as? String == key }
        let value = item?["value"] as? [String: String]
        return value?["stringValue"] ?? value?["intValue"]
    }
}
