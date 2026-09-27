import Foundation

enum LabelReviewSelection: Equatable, Hashable, Sendable {
    case label(id: UUID)
    case unclassified

    func title(in labels: [LabelReviewLabel]) -> String {
        switch self {
        case .label(let id):
            labels.first(where: { $0.id == id })?.displayName ?? "사용할 수 없는 라벨"
        case .unclassified:
            "미분류"
        }
    }
}

enum LabelReviewProposal: Equatable, Sendable {
    case ready(LabelReviewSelection)
    case waiting
    case processing
    case failed

    var selection: LabelReviewSelection? {
        guard case .ready(let selection) = self else { return nil }
        return selection
    }

    func title(in labels: [LabelReviewLabel]) -> String {
        switch self {
        case .ready(let selection): "AI 제안 · \(selection.title(in: labels))"
        case .waiting: "제안 대기 중"
        case .processing: "제안 처리 중"
        case .failed: "제안 실패"
        }
    }
}

struct LabelReviewLabel: Identifiable, Equatable, Sendable {
    let id: UUID
    let displayName: String
}

struct LabelReviewSegment: Identifiable, Equatable, Sendable {
    let id: UUID
    let version: String
    let startedAt: Date
    let endedAt: Date
    let appName: String
    let title: String
    let proposal: LabelReviewProposal

    var durationMinutes: Int { Int(endedAt.timeIntervalSince(startedAt) / 60) }
}

struct LabelReviewDecision: Equatable, Sendable {
    let segmentID: UUID
    let segmentVersion: String
    let selection: LabelReviewSelection
}

struct LabelReviewGroup: Identifiable, Equatable, Sendable {
    let segments: [LabelReviewSegment]

    var id: UUID { segments[0].id }
    var first: LabelReviewSegment { segments[0] }
    var last: LabelReviewSegment { segments[segments.count - 1] }
    var proposal: LabelReviewProposal { first.proposal }
    var durationMinutes: Int { segments.reduce(0) { $0 + $1.durationMinutes } }
}

struct LabelReviewData: Equatable, Sendable {
    let labels: [LabelReviewLabel]
    private let receivedSegments: [LabelReviewSegment]
    private let confirmedVersions: [UUID: String]

    init(response: LabelReviewResponseDTO) {
        labels = response.labels.map { LabelReviewLabel(id: $0.id, displayName: $0.displayName) }
        receivedSegments = response.segments.map { segment in
            LabelReviewSegment(
                id: segment.id,
                version: segment.version,
                startedAt: segment.startedAt,
                endedAt: segment.endedAt,
                appName: segment.appName,
                title: segment.title,
                proposal: Self.proposal(from: segment.proposal)
            )
        }
        confirmedVersions = [:]
    }

    private init(
        labels: [LabelReviewLabel],
        receivedSegments: [LabelReviewSegment],
        confirmedVersions: [UUID: String]
    ) {
        self.labels = labels
        self.receivedSegments = receivedSegments
        self.confirmedVersions = confirmedVersions
    }

    var pendingSegments: [LabelReviewSegment] {
        receivedSegments
            .filter { confirmedVersions[$0.id] != $0.version }
            .sorted {
                if $0.startedAt != $1.startedAt { return $0.startedAt < $1.startedAt }
                if $0.endedAt != $1.endedAt { return $0.endedAt < $1.endedAt }
                return $0.id.uuidString < $1.id.uuidString
            }
    }

    var groups: [LabelReviewGroup] {
        var groupedSegments: [[LabelReviewSegment]] = []
        for segment in pendingSegments {
            if let previous = groupedSegments.last?.last,
               previous.endedAt == segment.startedAt,
               previous.proposal == segment.proposal {
                groupedSegments[groupedSegments.count - 1].append(segment)
            } else {
                groupedSegments.append([segment])
            }
        }
        return groupedSegments.map(LabelReviewGroup.init(segments:))
    }

    func canSelect(_ selection: LabelReviewSelection) -> Bool {
        switch selection {
        case .label(let id): labels.contains(where: { $0.id == id })
        case .unclassified: true
        }
    }

    func applying(_ decisions: [LabelReviewDecision]) -> Self {
        var nextConfirmedVersions = confirmedVersions
        for decision in decisions {
            guard receivedSegments.contains(where: {
                $0.id == decision.segmentID && $0.version == decision.segmentVersion
            }) else { continue }
            nextConfirmedVersions[decision.segmentID] = decision.segmentVersion
        }
        return Self(
            labels: labels,
            receivedSegments: receivedSegments,
            confirmedVersions: nextConfirmedVersions
        )
    }

    func replacing(with response: LabelReviewResponseDTO) -> Self {
        let replacement = Self(response: response)
        return Self(
            labels: replacement.labels,
            receivedSegments: replacement.receivedSegments,
            confirmedVersions: confirmedVersions
        )
    }

    private static func proposal(from dto: LabelReviewProposalDTO) -> LabelReviewProposal {
        switch dto {
        case .ready(let selection):
            switch selection {
            case .label(let id): .ready(.label(id: id))
            case .unclassified: .ready(.unclassified)
            }
        case .waiting: .waiting
        case .processing: .processing
        case .failed: .failed
        }
    }
}
