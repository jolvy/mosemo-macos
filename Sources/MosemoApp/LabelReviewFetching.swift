import Foundation

enum LabelReviewSelectionDTO: Equatable, Sendable {
    case label(id: UUID)
    case unclassified
}

enum LabelReviewProposalDTO: Equatable, Sendable {
    case ready(LabelReviewSelectionDTO)
    case waiting
    case processing
    case failed
}

struct LabelReviewLabelDTO: Equatable, Sendable {
    let id: UUID
    let displayName: String
}

struct LabelReviewSegmentDTO: Equatable, Sendable {
    let id: UUID
    let version: String
    let startedAt: Date
    let endedAt: Date
    let appName: String
    let title: String
    let proposal: LabelReviewProposalDTO
}

struct LabelReviewResponseDTO: Equatable, Sendable {
    let labels: [LabelReviewLabelDTO]
    let segments: [LabelReviewSegmentDTO]
}

protocol LabelReviewFetching: Sendable {
    func fetchLabelReview() async throws -> LabelReviewSnapshot
}

struct MockLabelReviewFetcher: LabelReviewFetching {
    let response: LabelReviewResponseDTO

    func fetchLabelReview() async throws -> LabelReviewSnapshot {
        LabelReviewSnapshot(response: response)
    }

    static var demo: Self {
        let day = Calendar.current.startOfDay(for: .now)
        func at(_ minute: Int) -> Date {
            day.addingTimeInterval(TimeInterval(minute * 60))
        }

        let coding = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let communication = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        let learning = UUID(uuidString: "00000000-0000-0000-0000-000000000003")!
        func segment(
            _ id: Int,
            _ start: Int,
            _ end: Int,
            _ app: String,
            _ title: String,
            _ proposal: LabelReviewProposalDTO
        ) -> LabelReviewSegmentDTO {
            LabelReviewSegmentDTO(
                id: UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", id))!,
                version: String(repeating: String(id % 10), count: 64),
                startedAt: at(start),
                endedAt: at(end),
                appName: app,
                title: title,
                proposal: proposal
            )
        }

        return Self(response: LabelReviewResponseDTO(
            labels: [
                LabelReviewLabelDTO(id: coding, displayName: "코딩"),
                LabelReviewLabelDTO(id: communication, displayName: "소통"),
                LabelReviewLabelDTO(id: learning, displayName: "학습"),
            ],
            segments: [
                segment(1, 544, 552, "Chrome", "Mosemo API 설계 문서", .ready(.label(id: coding))),
                segment(2, 552, 560, "Xcode", "AuthCoordinator.swift", .ready(.label(id: coding))),
                segment(3, 560, 568, "Chrome", "Swift OpenAPI 문서", .ready(.label(id: coding))),
                segment(4, 574, 580, "Slack", "팀 채널", .ready(.label(id: communication))),
                segment(5, 580, 585, "Mail", "디자인 피드백", .ready(.label(id: communication))),
                segment(6, 593, 601, "Safari", "자료 검색", .ready(.unclassified)),
                segment(7, 608, 613, "Chrome", "문서 읽기", .processing),
                segment(8, 621, 626, "Firefox", "메모 정리", .failed),
                segment(9, 660, 668, "Chrome", "Mosemo API 설계 문서", .ready(.label(id: coding))),
                segment(10, 680, 686, "Books", "Swift 동시성", .waiting),
            ]
        ))
    }
}
