import Foundation
import MosemoAPI

struct TimelinePreviewFetcher: TimelineFetching {
    let delayNanoseconds: UInt64

    init(delayNanoseconds: UInt64 = 100_000_000) { self.delayNanoseconds = delayNanoseconds }

    func fetch(day: TimelineDate, timeZoneID: String) async throws -> TimelineDay {
        try await Task.sleep(nanoseconds: delayNanoseconds)
        let zone = TimeZone(identifier: "Asia/Seoul")!
        let today = TimelineDate(.now, timeZone: zone)
        let segments = day == today ? Self.examples(for: day, timeZone: zone) : []
        return TimelineDay(date: day, timeZoneID: zone.identifier, segments: segments)
    }

    private static func examples(for day: TimelineDate, timeZone: TimeZone) -> [TimelineSegment] {
        let start = day.startOfDay(timeZone: timeZone)
        func at(_ hour: Int, _ minute: Int) -> Date { start.addingTimeInterval(Double(hour * 60 + minute) * 60) }
        return [
            .activity(.init(id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!, startedAt: at(9, 0), endedAt: at(9, 42), lastObservedAt: at(9, 42), context: .detailed(appName: "Xcode", windowTitle: "MosemoApp.swift · 코드 편집", webURL: nil))),
            .activity(.init(id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!, startedAt: at(9, 42), endedAt: at(10, 10), lastObservedAt: at(10, 10), context: .detailed(appName: "Firefox", windowTitle: "이슈 확인", webURL: URL(string: "https://github.com")))),
            .activity(.init(id: UUID(uuidString: "00000000-0000-0000-0000-000000000003")!, startedAt: at(10, 10), endedAt: at(10, 24), lastObservedAt: at(10, 24), context: .opaque)),
            .captureGap(.init(id: UUID(uuidString: "00000000-0000-0000-0000-000000000004")!, startedAt: at(10, 24), endedAt: at(10, 48), reason: "이 시간에는 활동을 관찰하지 못했습니다")),
            .activity(.init(id: UUID(uuidString: "00000000-0000-0000-0000-000000000005")!, startedAt: at(10, 48), endedAt: at(11, 31), lastObservedAt: at(11, 31), context: .detailed(appName: "Notes", windowTitle: "작업 메모", webURL: nil))),
            .activity(.init(id: UUID(uuidString: "00000000-0000-0000-0000-000000000006")!, startedAt: at(11, 31), endedAt: at(11, 31), lastObservedAt: at(11, 31), context: .detailed(appName: "Finder", windowTitle: nil, webURL: nil))),
            .captureGap(.init(id: UUID(uuidString: "00000000-0000-0000-0000-000000000007")!, startedAt: at(12, 15), endedAt: nil, reason: "종료 시각을 아직 알 수 없습니다")),
            .activity(.init(id: UUID(uuidString: "00000000-0000-0000-0000-000000000008")!, startedAt: at(13, 0), endedAt: nil, lastObservedAt: at(13, 12), context: .detailed(appName: "Xcode", windowTitle: "열린 구간", webURL: nil)))
        ]
    }
}
