import Foundation
import MosemoAPI

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
    let archivedAt: Date?

    init(id: UUID, displayName: String, archivedAt: Date? = nil) {
        self.id = id
        self.displayName = displayName
        self.archivedAt = archivedAt
    }
}

struct LabelReviewSegmentDTO: Equatable, Sendable {
    let id: UUID
    let version: String
    let startedAt: Date
    let endedAt: Date
    let appName: String
    let title: String
    let proposal: LabelReviewProposalDTO
    let sourceGroupVersion: String?

    init(
        id: UUID,
        version: String,
        startedAt: Date,
        endedAt: Date,
        appName: String,
        title: String,
        proposal: LabelReviewProposalDTO,
        sourceGroupVersion: String? = nil
    ) {
        self.id = id
        self.version = version
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.appName = appName
        self.title = title
        self.proposal = proposal
        self.sourceGroupVersion = sourceGroupVersion
    }
}

struct LabelReviewResponseDTO: Equatable, Sendable {
    let labels: [LabelReviewLabelDTO]
    let segments: [LabelReviewSegmentDTO]
}

protocol LabelReviewFetching: Sendable {
    func fetchLabelReview(day: TimelineDate) async throws -> LabelReviewSnapshot
    func confirmedSelection(segmentID: UUID) async throws -> LabelReviewSelection?
}

extension LabelReviewSelection {
    init(remote: LabelConfirmationSelection) {
        switch remote {
        case .label(let id): self = .label(id: id)
        case .unclassified: self = .unclassified
        }
    }

    var remote: LabelConfirmationSelection {
        switch self {
        case .label(let id): .label(id)
        case .unclassified: .unclassified
        }
    }
}

enum LabelReviewFetchError: Error {
    case changedDuringFetch
    case missingLabel
}

struct LiveLabelReviewFetcher: LabelReviewFetching {
    let reader: any LabelReviewReading

    func confirmedSelection(segmentID: UUID) async throws -> LabelReviewSelection? {
        guard case .confirmed(let id, _, let selection) = try await reader.labelState(segmentID: segmentID),
              id == segmentID else { return nil }
        return LabelReviewSelection(remote: selection)
    }

    func fetchLabelReview(day: TimelineDate) async throws -> LabelReviewSnapshot {
        for attempt in 0..<2 {
            let labels = try await reader.listLabels()
            let segments = try await reader.pendingLabelSegments(day: day)
            let states: [RemoteSegmentLabelState]
            do {
                states = try await fetchStates(for: segments)
            } catch MosemoAPIError.unexpectedResponse(let statusCode)
                where attempt == 0 && (statusCode == 404 || statusCode == 409) {
                continue
            }
            guard let response = try makeResponse(labels: labels, segments: segments, states: states) else {
                if attempt == 0 { continue }
                throw LabelReviewFetchError.changedDuringFetch
            }
            return LabelReviewSnapshot(response: response)
        }
        throw LabelReviewFetchError.changedDuringFetch
    }

    private func fetchStates(
        for segments: [PendingLabelTimelineSegment]
    ) async throws -> [RemoteSegmentLabelState] {
        var states = Array<RemoteSegmentLabelState?>(repeating: nil, count: segments.count)
        for start in stride(from: 0, to: segments.count, by: 8) {
            let end = min(start + 8, segments.count)
            try await withThrowingTaskGroup(of: (Int, RemoteSegmentLabelState).self) { group in
                for index in start..<end {
                    let id = segments[index].id
                    group.addTask { (index, try await reader.labelState(segmentID: id)) }
                }
                for try await (index, state) in group { states[index] = state }
            }
        }
        return states.compactMap { $0 }
    }

    private func makeResponse(
        labels: [LabelCatalogEntry],
        segments: [PendingLabelTimelineSegment],
        states: [RemoteSegmentLabelState]
    ) throws -> LabelReviewResponseDTO? {
        guard states.count == segments.count else { return nil }
        let labelIDs = Set(labels.map(\.id))
        var mapped: [LabelReviewSegmentDTO] = []
        for (segment, state) in zip(segments, states) {
            guard case .pending(let id, let version, let remoteProposal) = state,
                  id == segment.id, version == segment.version else { return nil }
            let proposal: LabelReviewProposalDTO
            switch remoteProposal {
            case .readyLabel(let labelID):
                guard labelIDs.contains(labelID) else { throw LabelReviewFetchError.missingLabel }
                proposal = .ready(.label(id: labelID))
            case .readyUnclassified: proposal = .ready(.unclassified)
            case .waiting: proposal = .waiting
            case .processing: proposal = .processing
            case .failed: proposal = .failed
            }
            mapped.append(LabelReviewSegmentDTO(
                id: segment.id,
                version: segment.version,
                startedAt: segment.startedAt,
                endedAt: segment.endedAt,
                appName: segment.appName,
                title: segment.title,
                proposal: proposal,
                sourceGroupVersion: segment.sourceGroupVersion
            ))
        }
        return LabelReviewResponseDTO(
            labels: labels.map {
                LabelReviewLabelDTO(id: $0.id, displayName: $0.displayName, archivedAt: $0.archivedAt)
            },
            segments: mapped
        )
    }
}

struct MockLabelReviewFetcher: LabelReviewFetching {
    let response: LabelReviewResponseDTO

    func confirmedSelection(segmentID: UUID) async throws -> LabelReviewSelection? { nil }

    func fetchLabelReview(day: TimelineDate) async throws -> LabelReviewSnapshot {
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
