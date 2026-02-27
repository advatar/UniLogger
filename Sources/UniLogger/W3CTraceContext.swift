import Foundation
import Security

public enum TraceIdentifiers {
    public static func traceID() -> String {
        randomHex(byteCount: 16)
    }

    public static func spanID() -> String {
        randomHex(byteCount: 8)
    }

    private static func randomHex(byteCount: Int) -> String {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        let status = SecRandomCopyBytes(kSecRandomDefault, byteCount, &bytes)
        if status != errSecSuccess {
            var uuid = UUID().uuid
            let data = withUnsafeBytes(of: &uuid) { Data($0) }
            return data.prefix(byteCount).map { String(format: "%02x", $0) }.joined()
        }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }
}

public struct TraceParent: Sendable {
    public var version: String
    public var traceID: String
    public var spanID: String
    public var traceFlags: String

    public init(traceID: String, spanID: String, traceFlags: String = "01", version: String = "00") {
        self.version = TraceParent.normalize(version, length: 2)
        self.traceID = TraceParent.normalize(traceID, length: 32)
        self.spanID = TraceParent.normalize(spanID, length: 16)
        self.traceFlags = TraceParent.normalize(traceFlags, length: 2)
    }

    public init?(headerValue: String) {
        let parts = headerValue.split(separator: "-")
        guard parts.count == 4 else { return nil }
        let version = String(parts[0])
        let traceID = String(parts[1])
        let spanID = String(parts[2])
        let traceFlags = String(parts[3])
        guard TraceParent.isHex(version, length: 2),
              TraceParent.isHex(traceID, length: 32),
              TraceParent.isHex(spanID, length: 16),
              TraceParent.isHex(traceFlags, length: 2) else {
            return nil
        }
        self.version = version.lowercased()
        self.traceID = traceID.lowercased()
        self.spanID = spanID.lowercased()
        self.traceFlags = traceFlags.lowercased()
    }

    public var headerValue: String {
        "\(version)-\(traceID)-\(spanID)-\(traceFlags)"
    }

    private static func normalize(_ value: String, length: Int) -> String {
        let lower = value.lowercased()
        if lower.count == length, isHex(lower, length: length) {
            return lower
        }
        let trimmed = String(lower.prefix(length))
        if trimmed.count < length {
            return String(repeating: "0", count: length - trimmed.count) + trimmed
        }
        return trimmed
    }

    private static func isHex(_ value: String, length: Int) -> Bool {
        guard value.count == length else { return false }
        return value.unicodeScalars.allSatisfy { scalar in
            switch scalar {
            case "0"..."9", "a"..."f", "A"..."F":
                return true
            default:
                return false
            }
        }
    }
}
