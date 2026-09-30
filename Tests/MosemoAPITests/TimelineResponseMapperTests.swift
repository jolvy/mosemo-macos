import Foundation
import XCTest
@testable import MosemoAPI

final class TimelineResponseMapperTests: XCTestCase {
    func testGroupsExpandOriginalSegmentsAndOnlyConfirmedSelectionsBecomeLabels() throws {
        let body = Data(#"""
        [
          {"itemType":"activity_group","groupVersion":"g1","startedAt":"2026-09-26T00:00:00Z","endedAt":"2026-09-26T00:10:00Z","state":"confirmed","selection":{"kind":"unclassified"},"segments":[
            {"segmentId":"11111111-1111-1111-1111-111111111111","segmentVersion":"v1","startedAt":"2026-09-26T00:00:00Z","endedAt":"2026-09-26T00:05:00Z","lastObservedAt":"2026-09-26T00:04:00Z","context":{"kind":"detailed","app":{"bundleId":{"status":"absent"},"name":{"status":"captured","value":"Xcode"}},"window":{"status":"absent"},"web":{"kind":"not_applicable"}}},
            {"segmentId":"22222222-2222-2222-2222-222222222222","segmentVersion":"v2","startedAt":"2026-09-26T00:05:00Z","endedAt":"2026-09-26T00:10:00Z","lastObservedAt":"2026-09-26T00:09:00Z","context":{"kind":"detailed","app":{"bundleId":{"status":"absent"},"name":{"status":"captured","value":"Safari"}},"window":{"status":"absent"},"web":{"kind":"not_applicable"}}}
          ]},
          {"itemType":"activity_group","groupVersion":"g2","startedAt":"2026-09-26T00:10:00Z","endedAt":"2026-09-26T00:15:00Z","state":"pending","selection":null,"segments":[
            {"segmentId":"33333333-3333-3333-3333-333333333333","segmentVersion":"v3","startedAt":"2026-09-26T00:10:00Z","endedAt":"2026-09-26T00:15:00Z","lastObservedAt":"2026-09-26T00:14:00Z","context":{"kind":"detailed","app":{"bundleId":{"status":"absent"},"name":{"status":"captured","value":"Notes"}},"window":{"status":"absent"},"web":{"kind":"not_applicable"}}}
          ]}
        ]
        """#.utf8)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let response = try decoder.decode([TimelineResponseMapper.ResponseSegment].self, from: body)
        let segments = try TimelineResponseMapper.segments(from: response)
        let activities = segments.compactMap { segment -> TimelineActivity? in
            if case .activity(let activity) = segment { return activity }
            return nil
        }
        XCTAssertEqual(activities.map(\.id.uuidString), [
            "11111111-1111-1111-1111-111111111111",
            "22222222-2222-2222-2222-222222222222",
            "33333333-3333-3333-3333-333333333333"
        ])
        XCTAssertEqual(activities.map(\.confirmedLabel), [.unclassified, .unclassified, nil])
        XCTAssertEqual(activities[0].endedAt, ISO8601DateFormatter().date(from: "2026-09-26T00:05:00Z"))
        XCTAssertEqual(activities[1].startedAt, ISO8601DateFormatter().date(from: "2026-09-26T00:05:00Z"))
    }
}
