import Foundation

// Local bridge until these additive contracts ship in the next
// LuminaVaultShared release. The adjacent Shared repository contains the
// public copy with the exact same wire format.
enum ImprovementModelMode: String, Codable, Sendable { case economy, main }
enum ImprovementAvailability: String, Codable, Sendable {
    case managed
    case compatibleBYO = "compatible_byo"
    case readOnly = "read_only"
    case unavailable
}

enum ImprovementChangeKind: String, Codable, Sendable { case curator, soul }
enum ImprovementChangeState: String, Codable, Sendable { case pending, approved, rejected, applied, stale, failed }
enum ImprovementTrigger: String, Codable, Sendable {
    case manual, weekly
    case complexSession = "complex_session"
}

enum ImprovementRunStatus: String, Codable, Sendable {
    case queued, running, succeeded, failed
    case rolledBack = "rolled_back"
}

enum ImprovementResourceKind: String, Codable, Sendable { case skill, job }
enum ImprovementResourceState: String, Codable, Sendable { case active, stale, archived }

struct ImprovementSettingsDTO: Codable, Sendable, Equatable {
    let enabled: Bool
    let curatorEnabled: Bool
    let intervalHours: Int
    let minimumIdleHours: Int
    let consolidate: Bool
    let pruneBuiltins: Bool
    let backupKeep: Int
    let soulReviewEnabled: Bool
    let reviewComplexSessions: Bool
    let soulReviewWindowDays: Int
    let soulReviewCooldownHours: Int
    let modelMode: ImprovementModelMode

    init(
        enabled: Bool = true,
        curatorEnabled: Bool = true,
        intervalHours: Int = 168,
        minimumIdleHours: Int = 2,
        consolidate: Bool = true,
        pruneBuiltins: Bool = false,
        backupKeep: Int = 5,
        soulReviewEnabled: Bool = true,
        reviewComplexSessions: Bool = true,
        soulReviewWindowDays: Int = 14,
        soulReviewCooldownHours: Int = 24,
        modelMode: ImprovementModelMode = .economy
    ) {
        self.enabled = enabled
        self.curatorEnabled = curatorEnabled
        self.intervalHours = intervalHours
        self.minimumIdleHours = minimumIdleHours
        self.consolidate = consolidate
        self.pruneBuiltins = pruneBuiltins
        self.backupKeep = backupKeep
        self.soulReviewEnabled = soulReviewEnabled
        self.reviewComplexSessions = reviewComplexSessions
        self.soulReviewWindowDays = soulReviewWindowDays
        self.soulReviewCooldownHours = soulReviewCooldownHours
        self.modelMode = modelMode
    }

    static let safeDefault = ImprovementSettingsDTO()
}

struct ImprovementSettingsUpdateRequest: Codable, Sendable { let settings: ImprovementSettingsDTO }

struct ImprovementStatusDTO: Codable, Sendable {
    let settings: ImprovementSettingsDTO
    let availability: ImprovementAvailability
    let economyModelAvailable: Bool
    let pendingChanges: Int
    let lastCuratorReviewAt: Date?
    let lastSoulReviewAt: Date?
    let nextReviewAt: Date?
    let message: String?
}

struct ImprovementRunDTO: Codable, Sendable {
    let id: UUID
    let kind: ImprovementChangeKind
    let status: ImprovementRunStatus
    let trigger: ImprovementTrigger
    let dryRun: Bool
    let modelUsed: String?
    let reportMarkdown: String?
    let actionsApplied: Int
    let actionsSkipped: Int
    let startedAt: Date?
    let endedAt: Date?
    let createdAt: Date
    let failureReason: String?
}

struct ImprovementRunsResponse: Codable, Sendable { let runs: [ImprovementRunDTO] }

struct ImprovementChangeDTO: Codable, Sendable {
    let id: UUID
    let kind: ImprovementChangeKind
    let state: ImprovementChangeState
    let trigger: ImprovementTrigger
    let title: String
    let summary: String
    let patch: String?
    let baseSHA256: String?
    let reportMarkdown: String?
    let failureReason: String?
    let createdAt: Date
    let decidedAt: Date?
    let appliedAt: Date?
}

struct ImprovementChangesResponse: Codable, Sendable { let changes: [ImprovementChangeDTO] }
struct ImprovementRunRequest: Codable, Sendable {
    let dryRun: Bool
    init(dryRun: Bool = true) {
        self.dryRun = dryRun
    }
}

struct ImprovementRunAcceptedResponse: Codable, Sendable { let run: ImprovementRunDTO }
struct SoulReviewRequest: Codable, Sendable {
    let trigger: ImprovementTrigger
    init(trigger: ImprovementTrigger = .manual) {
        self.trigger = trigger
    }
}

struct ImprovementDecisionResponse: Codable, Sendable { let change: ImprovementChangeDTO }

struct ImprovementSkillDTO: Codable, Sendable {
    let name: String
    let title: String
    let kind: ImprovementResourceKind
    let state: ImprovementResourceState
    let pinned: Bool
    let curatorManaged: Bool
    let lastActivityAt: Date?
}

struct ImprovementSkillsResponse: Codable, Sendable { let skills: [ImprovementSkillDTO] }
struct ImprovementSkillPinRequest: Codable, Sendable { let pinned: Bool }
struct ImprovementRollbackResponse: Codable, Sendable { let run: ImprovementRunDTO }
