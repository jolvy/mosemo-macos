import Foundation
import MosemoAPI

/// In-memory cache for server-shaped timeline responses. It intentionally has no disk behavior.
struct TimelineStore {
    private(set) var accountID: UUID?
    private var days: [TimelineDate: TimelineDay] = [:]

    func day(for date: TimelineDate) -> TimelineDay? { days[date] }

    mutating func replace(_ day: TimelineDay) {
        days[day.date] = day
    }

    mutating func switchAccount(to accountID: UUID) {
        guard self.accountID != accountID else { return }
        self.accountID = accountID
        days.removeAll()
    }

    mutating func clear() {
        accountID = nil
        days.removeAll()
    }
}
