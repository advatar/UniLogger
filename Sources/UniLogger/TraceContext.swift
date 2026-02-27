import Foundation
import Logging

public enum TraceContext {
    @TaskLocal public static var current: Context?

    public struct Context: Sendable {
        public var traceID: String
        public var spanID: String
        public var parentSpanID: String?
        public var service: String?
        public var sessionID: String?
        public var debugEnabled: Bool
        public var journal: BreadcrumbJournal?

        public init(
            traceID: String,
            spanID: String,
            parentSpanID: String? = nil,
            service: String? = nil,
            sessionID: String? = nil,
            debugEnabled: Bool = false,
            journal: BreadcrumbJournal? = nil
        ) {
            self.traceID = traceID
            self.spanID = spanID
            self.parentSpanID = parentSpanID
            self.service = service
            self.sessionID = sessionID
            self.debugEnabled = debugEnabled
            self.journal = journal
        }
    }

    public static func withContext<T>(_ context: Context, _ body: () throws -> T) rethrows -> T {
        try $current.withValue(context, operation: body)
    }

    public static func withContext<T>(_ context: Context, _ body: () async throws -> T) async rethrows -> T {
        try await $current.withValue(context, operation: body)
    }

    public static func currentMetadata() -> Logger.Metadata {
        guard let ctx = current else { return [:] }
        return metadata(from: ctx)
    }

    public static func metadataProvider() -> Logger.MetadataProvider {
        Logger.MetadataProvider {
            guard let ctx = current else { return [:] }
            return metadata(from: ctx)
        }
    }

    public static func breadcrumbsMetadata(
        fieldName: String = "_trace_history",
        maxEvents: Int? = nil,
        maxBytes: Int? = nil
    ) -> Logger.Metadata {
        guard let journal = current?.journal else { return [:] }
        guard let json = journal.snapshotJSON(maxEvents: maxEvents, maxBytes: maxBytes) else { return [:] }
        return [fieldName: .string(json)]
    }

    private static func metadata(from ctx: Context) -> Logger.Metadata {
        var md: Logger.Metadata = [
            "_trace_id": .string(ctx.traceID),
            "_span_id": .string(ctx.spanID)
        ]
        if let parent = ctx.parentSpanID {
            md["_parent_span_id"] = .string(parent)
        }
        if let service = ctx.service {
            md["_service"] = .string(service)
        }
        if let sessionID = ctx.sessionID {
            md["_session_id"] = .string(sessionID)
        }
        return md
    }
}
