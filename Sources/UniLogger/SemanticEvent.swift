import Foundation
import Logging

public struct SemanticEvent: Sendable {
    public var name: String
    public var component: String
    public var operation: String
    public var errorCode: String?
    public var reason: String?
    public var expected: String?
    public var actual: String?
    public var peer: String?
    public var httpMethod: String?
    public var httpPath: String?
    public var httpStatus: Int?
    public var durationMs: Int?

    public init(
        name: String,
        component: String,
        operation: String,
        errorCode: String? = nil,
        reason: String? = nil,
        expected: String? = nil,
        actual: String? = nil,
        peer: String? = nil,
        httpMethod: String? = nil,
        httpPath: String? = nil,
        httpStatus: Int? = nil,
        durationMs: Int? = nil
    ) {
        self.name = name
        self.component = component
        self.operation = operation
        self.errorCode = errorCode
        self.reason = reason
        self.expected = expected
        self.actual = actual
        self.peer = peer
        self.httpMethod = httpMethod
        self.httpPath = httpPath
        self.httpStatus = httpStatus
        self.durationMs = durationMs
    }

    public func metadata() -> Logger.Metadata {
        var md: Logger.Metadata = [
            "_event": .string(name),
            "_component": .string(component),
            "_operation": .string(operation)
        ]
        if let errorCode { md["_error_code"] = .string(errorCode) }
        if let reason { md["_reason"] = .string(reason) }
        if let expected { md["_expected"] = .string(expected) }
        if let actual { md["_actual"] = .string(actual) }
        if let peer { md["_peer"] = .string(peer) }
        if let httpMethod { md["_http_method"] = .string(httpMethod) }
        if let httpPath { md["_http_path"] = .string(httpPath) }
        if let httpStatus { md["_http_status"] = .string(String(httpStatus)) }
        if let durationMs { md["_duration_ms"] = .string(String(durationMs)) }
        return md
    }

    public func breadcrumbFields() -> [String: String] {
        var fields: [String: String] = [
            "component": component,
            "operation": operation
        ]
        if let errorCode { fields["error_code"] = errorCode }
        if let reason { fields["reason"] = reason }
        if let expected { fields["expected"] = expected }
        if let actual { fields["actual"] = actual }
        if let peer { fields["peer"] = peer }
        if let httpMethod { fields["http_method"] = httpMethod }
        if let httpPath { fields["http_path"] = httpPath }
        if let httpStatus { fields["http_status"] = String(httpStatus) }
        if let durationMs { fields["duration_ms"] = String(durationMs) }
        return fields
    }

    public func recordBreadcrumb(journal: BreadcrumbJournal? = TraceContext.current?.journal) {
        journal?.add(event: name, fields: breadcrumbFields())
    }
}
