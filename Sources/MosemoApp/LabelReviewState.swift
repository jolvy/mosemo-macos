import Foundation
import MosemoAPI

enum LabelReviewSelection: Equatable, Hashable, Sendable {
    case label(id: UUID)
    case unclassified
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
}

struct LabelReviewLabel: Identifiable, Equatable, Sendable {
    let id: UUID
    let displayName: String
    let archivedAt: Date?
}

struct LabelReviewSegment: Identifiable, Equatable, Sendable {
    let id: UUID
    let version: String
    let startedAt: Date
    let endedAt: Date
    let appName: String
    let context: LabelReviewActivityContext
    var title: String { context.title ?? "수집 불가" }
    let proposal: LabelReviewProposal
    let sourceGroupVersion: String?

    var durationSeconds: Int { Int(endedAt.timeIntervalSince(startedAt)) }
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

struct LabelReviewSnapshot: Equatable, Sendable {
    let labels: [LabelReviewLabel]
    let segments: [LabelReviewSegment]

    init(response: LabelReviewResponseDTO) {
        labels = response.labels.map {
            LabelReviewLabel(id: $0.id, displayName: $0.displayName, archivedAt: $0.archivedAt)
        }
        segments = response.segments.map { segment in
            LabelReviewSegment(
                id: segment.id,
                version: segment.version,
                startedAt: segment.startedAt,
                endedAt: segment.endedAt,
                appName: segment.appName,
                context: segment.context,
                proposal: Self.proposal(from: segment.proposal),
                sourceGroupVersion: segment.sourceGroupVersion
            )
        }
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

struct LabelReviewState: Equatable, Sendable {
    let snapshot: LabelReviewSnapshot
    private let confirmedVersions: [UUID: String]

    init(snapshot: LabelReviewSnapshot) {
        self.snapshot = snapshot
        confirmedVersions = [:]
    }

    private init(snapshot: LabelReviewSnapshot, confirmedVersions: [UUID: String]) {
        self.snapshot = snapshot
        self.confirmedVersions = confirmedVersions
    }

    var labels: [LabelReviewLabel] { snapshot.labels }

    var pendingSegments: [LabelReviewSegment] {
        snapshot.segments
            .filter { confirmedVersions[$0.id] != $0.version }
    }

    var groups: [LabelReviewGroup] {
        var groupedSegments: [[LabelReviewSegment]] = []
        for segment in pendingSegments {
            if let previous = groupedSegments.last?.last,
               previous.endedAt == segment.startedAt,
               previous.sourceGroupVersion == segment.sourceGroupVersion,
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
        case .label(let id): labels.contains(where: { $0.id == id && $0.archivedAt == nil })
        case .unclassified: true
        }
    }

    func applying(_ decisions: [LabelReviewDecision]) -> Self {
        var nextConfirmedVersions = confirmedVersions
        for decision in decisions {
            guard snapshot.segments.contains(where: {
                $0.id == decision.segmentID && $0.version == decision.segmentVersion
            }) else { continue }
            nextConfirmedVersions[decision.segmentID] = decision.segmentVersion
        }
        return Self(snapshot: snapshot, confirmedVersions: nextConfirmedVersions)
    }

    func replacing(with snapshot: LabelReviewSnapshot) -> Self {
        Self(snapshot: snapshot, confirmedVersions: confirmedVersions)
    }
}
