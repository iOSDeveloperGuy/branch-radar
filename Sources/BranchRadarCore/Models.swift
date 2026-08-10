import Foundation

public enum AnalysisStatus: String, Codable, Sendable {
    case clean
    case conflict
}

public enum ConflictKind: String, Codable, Sendable {
    case content
    case addAdd = "add_add"
    case modifyDelete = "modify_delete"
    case renameRename = "rename_rename"
    case renameDelete = "rename_delete"
    case renameAdd = "rename_add"
    case directoryFile = "directory_file"
    case fileDirectory = "file_directory"
    case unknown
}

public struct Conflict: Codable, Equatable, Sendable {
    public let path: String
    public let kind: ConflictKind
    public let message: String?

    public init(path: String, kind: ConflictKind, message: String? = nil) {
        self.path = path
        self.kind = kind
        self.message = message
    }
}

public struct BranchAnalysis: Codable, Equatable, Sendable {
    public let branch: String
    public let target: String
    public let status: AnalysisStatus
    public let conflicts: [Conflict]
    public let ahead: Int
    public let behind: Int

    public init(
        branch: String,
        target: String,
        status: AnalysisStatus,
        conflicts: [Conflict],
        ahead: Int,
        behind: Int
    ) {
        self.branch = branch
        self.target = target
        self.status = status
        self.conflicts = conflicts
        self.ahead = ahead
        self.behind = behind
    }
}

public struct ScanReport: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let target: String
    public let branches: [BranchAnalysis]

    public init(schemaVersion: Int = 1, target: String, branches: [BranchAnalysis]) {
        self.schemaVersion = schemaVersion
        self.target = target
        self.branches = branches
    }

    public var hasConflicts: Bool {
        branches.contains { $0.status == .conflict }
    }
}

public struct RepositoryIdentity: Codable, Equatable, Sendable {
    public let projectKey: String
    public let slug: String

    public init(projectKey: String, slug: String) {
        self.projectKey = projectKey
        self.slug = slug
    }
}

public struct PullRequestRef: Codable, Equatable, Sendable {
    public let id: String
    public let displayId: String
    public let latestCommit: String
    public let repository: RepositoryIdentity

    public init(id: String, displayId: String, latestCommit: String, repository: RepositoryIdentity) {
        self.id = id
        self.displayId = displayId
        self.latestCommit = latestCommit
        self.repository = repository
    }

    public var branchName: String {
        id.hasPrefix("refs/heads/") ? String(id.dropFirst("refs/heads/".count)) : displayId
    }
}

public struct PullRequestAuthor: Codable, Equatable, Sendable {
    public let username: String
    public let displayName: String

    public init(username: String, displayName: String) {
        self.username = username
        self.displayName = displayName
    }
}

public struct PullRequestSummary: Codable, Equatable, Sendable {
    public let id: Int
    public let title: String
    public let state: String
    public let source: PullRequestRef
    public let target: PullRequestRef
    public let author: PullRequestAuthor?

    public init(
        id: Int,
        title: String,
        state: String,
        source: PullRequestRef,
        target: PullRequestRef,
        author: PullRequestAuthor? = nil
    ) {
        self.id = id
        self.title = title
        self.state = state
        self.source = source
        self.target = target
        self.author = author
    }
}

public struct PullRequestReport: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let target: String
    public let pullRequests: [PullRequestSummary]

    public init(schemaVersion: Int = 1, target: String, pullRequests: [PullRequestSummary]) {
        self.schemaVersion = schemaVersion
        self.target = target
        self.pullRequests = pullRequests
    }
}

public enum ProjectionOutcome: String, Codable, Sendable {
    case clean
    case conflict
    case incomingConflict = "incoming_conflict"
    case unavailable
}

public struct PullRequestProjection: Codable, Equatable, Sendable {
    public let pullRequest: PullRequestSummary
    public let outcome: ProjectionOutcome
    public let conflicts: [Conflict]
    public let message: String?

    public init(
        pullRequest: PullRequestSummary,
        outcome: ProjectionOutcome,
        conflicts: [Conflict] = [],
        message: String? = nil
    ) {
        self.pullRequest = pullRequest
        self.outcome = outcome
        self.conflicts = conflicts
        self.message = message
    }
}

public struct ProjectionReport: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let branch: String
    public let target: String
    public let current: BranchAnalysis
    public let projections: [PullRequestProjection]

    public init(
        schemaVersion: Int = 1,
        branch: String,
        target: String,
        current: BranchAnalysis,
        projections: [PullRequestProjection]
    ) {
        self.schemaVersion = schemaVersion
        self.branch = branch
        self.target = target
        self.current = current
        self.projections = projections
    }

    public var hasConflicts: Bool {
        current.status == .conflict || projections.contains { $0.outcome == .conflict }
    }
}

public struct ProjectedScanReport: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let target: String
    public let branches: [ProjectionReport]

    public init(schemaVersion: Int = 1, target: String, branches: [ProjectionReport]) {
        self.schemaVersion = schemaVersion
        self.target = target
        self.branches = branches
    }

    public var hasConflicts: Bool {
        branches.contains { $0.hasConflicts }
    }
}

public struct ErrorPayload: Codable, Sendable {
    public let schemaVersion: Int
    public let error: ErrorDetail

    public init(code: String, message: String) {
        self.schemaVersion = 1
        self.error = ErrorDetail(code: code, message: message)
    }

    public struct ErrorDetail: Codable, Sendable {
        public let code: String
        public let message: String
    }
}
