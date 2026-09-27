import Foundation
import OpenAPIRuntime

/// Accepts both whole-second and fractional-second timestamps emitted by the API.
struct MosemoDateTranscoder: DateTranscoder {
    private let fractional = ISO8601DateTranscoder.iso8601WithFractionalSeconds
    private let wholeSeconds = ISO8601DateTranscoder.iso8601

    func encode(_ date: Date) throws -> String {
        try fractional.encode(date)
    }

    func decode(_ dateString: String) throws -> Date {
        do {
            return try fractional.decode(dateString)
        } catch {
            return try wholeSeconds.decode(dateString)
        }
    }
}
