import Foundation

public enum RepositoryError: Error, CustomStringConvertible, Sendable {
    case notARepository
    case invalidReference(String)
    case noDefaultTarget
    case gitFailure(command: String, message: String, exitCode: Int32)
    case malformedOutput(command: String, output: String)

    public var description: String {
        switch self {
        case .notARepository:
            return "The current directory is not inside a Git repository."
        case .invalidReference(let ref):
            return "Git reference '\(ref)' does not exist."
        case .noDefaultTarget:
            return "Could not determine a target branch. Pass --target <ref>."
        case .gitFailure(let command, let message, let exitCode):
            let detail = message.trimmingCharacters(in: .whitespacesAndNewlines)
            return detail.isEmpty
                ? "Git command failed (\(exitCode)): \(command)"
                : "Git command failed (\(exitCode)): \(command): \(detail)"
        case .malformedOutput(let command, let output):
            return "Unexpected output from '\(command)': \(output)"
        }
    }
}

public struct GitRepository: Sendable {
    public let root: URL
    private let runner: any GitCommandRunning

    public init(at directory: URL, runner: any GitCommandRunning = GitCommandRunner()) throws {
        let result = try runner.run(arguments: ["rev-parse", "--show-toplevel"], directory: directory)
        guard result.exitCode == 0 else {
            throw RepositoryError.notARepository
        }

        let path = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty else {
            throw RepositoryError.notARepository
        }

        self.root = URL(fileURLWithPath: path, isDirectory: true)
        self.runner = runner
    }

    public func referenceExists(_ ref: String) throws -> Bool {
        let result = try runner.run(
            arguments: ["rev-parse", "--verify", "--quiet", "\(ref)^{commit}"],
            directory: root
        )
        return result.exitCode == 0
    }

    public func resolveCommit(_ ref: String) throws -> String {
        let result = try runner.run(
            arguments: ["rev-parse", "--verify", "\(ref)^{commit}"],
            directory: root
        )
        guard result.exitCode == 0 else {
            throw RepositoryError.invalidReference(ref)
        }
        let oid = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !oid.isEmpty else {
            throw RepositoryError.malformedOutput(command: "git rev-parse", output: result.stdout)
        }
        return oid
    }

    public func resolveTarget(explicit: String?) throws -> String {
        if let explicit {
            guard try referenceExists(explicit) else {
                throw RepositoryError.invalidReference(explicit)
            }
            return explicit
        }

        let originHead = try runner.run(
            arguments: ["symbolic-ref", "--quiet", "--short", "refs/remotes/origin/HEAD"],
            directory: root
        )
        if originHead.exitCode == 0 {
            let target = originHead.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            if !target.isEmpty, try referenceExists(target) {
                return target
            }
        }

        for candidate in ["origin/main", "origin/master", "main", "master"] {
            if try referenceExists(candidate) {
                return candidate
            }
        }

        throw RepositoryError.noDefaultTarget
    }

    public func localBranches() throws -> [String] {
        let result = try runner.run(
            arguments: ["for-each-ref", "--format=%(refname:short)", "refs/heads/"],
            directory: root
        )
        guard result.exitCode == 0 else {
            throw gitFailure(arguments: ["for-each-ref", "refs/heads/"], result: result)
        }

        return result.stdout
            .split(separator: "\n")
            .map(String.init)
            .filter { !$0.isEmpty }
            .sorted()
    }

    public func remoteURL(_ remote: String) throws -> String? {
        let result = try runner.run(arguments: ["remote", "get-url", remote], directory: root)
        if result.exitCode != 0 { return nil }
        let value = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    public func analyze(branch: String, against target: String) throws -> BranchAnalysis {
        guard try referenceExists(branch) else {
            throw RepositoryError.invalidReference(branch)
        }
        guard try referenceExists(target) else {
            throw RepositoryError.invalidReference(target)
        }

        let divergence = try aheadBehind(branch: branch, target: target)
        let merge = try simulateMerge(branch: branch, target: target)

        return BranchAnalysis(
            branch: branch,
            target: target,
            status: merge.status,
            conflicts: merge.conflicts,
            ahead: divergence.ahead,
            behind: divergence.behind
        )
    }

    public func scanLocalBranches(against target: String) throws -> ScanReport {
        let branches = try localBranches()
        let normalizedTarget = normalizeLocalTarget(target)

        let analyses = try branches
            .filter { $0 != normalizedTarget }
            .map { try analyze(branch: $0, against: target) }

        return ScanReport(target: target, branches: analyses)
    }

    public func project(
        branch: String,
        against target: String,
        after pullRequests: [PullRequestSummary],
        remote: String = "origin",
        fetchMissingObjects: Bool = true
    ) throws -> ProjectionReport {
        let current = try analyze(branch: branch, against: target)
        let branchCommit = try resolveCommit(branch)

        let projections = pullRequests.compactMap { pullRequest -> PullRequestProjection? in
            if pullRequest.source.latestCommit == branchCommit || pullRequest.source.branchName == branch {
                return nil
            }

            do {
                guard pullRequest.source.repository == pullRequest.target.repository else {
                    return PullRequestProjection(
                        pullRequest: pullRequest,
                        outcome: .unavailable,
                        message: "Cross-repository pull request projection is not supported yet."
                    )
                }

                try ensureCommitAvailable(
                    pullRequest.source.latestCommit,
                    branch: pullRequest.source.branchName,
                    remote: remote,
                    fetchMissingObjects: fetchMissingObjects
                )
                try ensureCommitAvailable(
                    pullRequest.target.latestCommit,
                    branch: pullRequest.target.branchName,
                    remote: remote,
                    fetchMissingObjects: fetchMissingObjects
                )

                let serverTarget = pullRequest.target.latestCommit
                let incoming = try simulateMerge(branch: pullRequest.source.latestCommit, target: serverTarget)
                guard incoming.status == .clean, let incomingTree = incoming.treeOID else {
                    return PullRequestProjection(
                        pullRequest: pullRequest,
                        outcome: .incomingConflict,
                        conflicts: incoming.conflicts,
                        message: "Incoming PR does not merge cleanly into its current target, so no after-merge projection was created."
                    )
                }

                let syntheticTarget = try createSyntheticMergeCommit(
                    treeOID: incomingTree,
                    parents: [serverTarget, pullRequest.source.latestCommit]
                )
                let projected = try simulateMerge(branch: branchCommit, target: syntheticTarget)
                if projected.status == .conflict {
                    return PullRequestProjection(
                        pullRequest: pullRequest,
                        outcome: .conflict,
                        conflicts: projected.conflicts,
                        message: nil
                    )
                }
                return PullRequestProjection(pullRequest: pullRequest, outcome: .clean)
            } catch {
                return PullRequestProjection(
                    pullRequest: pullRequest,
                    outcome: .unavailable,
                    message: String(describing: error)
                )
            }
        }

        return ProjectionReport(branch: branch, target: target, current: current, projections: projections)
    }

    public func projectLocalBranches(
        against target: String,
        after pullRequests: [PullRequestSummary],
        remote: String = "origin",
        fetchMissingObjects: Bool = true
    ) throws -> ProjectedScanReport {
        let normalizedTarget = normalizeLocalTarget(target)
        let branches = try localBranches().filter { $0 != normalizedTarget }
        let reports = try branches.map {
            try project(
                branch: $0,
                against: target,
                after: pullRequests,
                remote: remote,
                fetchMissingObjects: fetchMissingObjects
            )
        }
        return ProjectedScanReport(target: target, branches: reports)
    }

    private func aheadBehind(branch: String, target: String) throws -> (ahead: Int, behind: Int) {
        let result = try runner.run(
            arguments: ["rev-list", "--left-right", "--count", "\(target)...\(branch)"],
            directory: root
        )
        guard result.exitCode == 0 else {
            throw gitFailure(arguments: ["rev-list", "--left-right", "--count", "\(target)...\(branch)"], result: result)
        }

        let parts = result.stdout.split(whereSeparator: { $0 == "\t" || $0 == " " || $0 == "\n" })
        guard parts.count >= 2,
              let behind = Int(parts[0]),
              let ahead = Int(parts[1]) else {
            throw RepositoryError.malformedOutput(command: "git rev-list", output: result.stdout)
        }

        return (ahead, behind)
    }

    private struct MergeSimulation {
        let status: AnalysisStatus
        let conflicts: [Conflict]
        let treeOID: String?
    }

    private func simulateMerge(branch: String, target: String) throws -> MergeSimulation {
        let arguments = ["merge-tree", "--write-tree", "--name-only", target, branch]
        let result = try runner.run(arguments: arguments, directory: root)

        if result.exitCode == 0 {
            let tree = result.stdout
                .split(separator: "\n", maxSplits: 1)
                .first
                .map(String.init)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard let tree, !tree.isEmpty else {
                throw RepositoryError.malformedOutput(command: "git merge-tree", output: result.stdout)
            }
            return MergeSimulation(status: .clean, conflicts: [], treeOID: tree)
        }

        guard result.exitCode == 1 else {
            throw gitFailure(arguments: arguments, result: result)
        }

        return MergeSimulation(
            status: .conflict,
            conflicts: parseConflicts(from: result.stdout + result.stderr),
            treeOID: nil
        )
    }

    private func ensureCommitAvailable(
        _ commit: String,
        branch: String,
        remote: String,
        fetchMissingObjects: Bool
    ) throws {
        if try referenceExists(commit) { return }
        guard fetchMissingObjects else {
            throw RepositoryError.invalidReference(commit)
        }

        let ref = branch.hasPrefix("refs/") ? branch : "refs/heads/\(branch)"
        let arguments = ["fetch", "--no-tags", "--no-write-fetch-head", remote, ref]
        let result = try runner.run(arguments: arguments, directory: root)
        guard result.exitCode == 0 else {
            throw gitFailure(arguments: arguments, result: result)
        }
        guard try referenceExists(commit) else {
            throw RepositoryError.invalidReference(commit)
        }
    }

    private func createSyntheticMergeCommit(treeOID: String, parents: [String]) throws -> String {
        var arguments = [
            "-c", "user.name=branch-radar",
            "-c", "user.email=branch-radar@invalid",
            "commit-tree", treeOID
        ]
        for parent in parents {
            arguments.append(contentsOf: ["-p", parent])
        }
        arguments.append(contentsOf: ["-m", "branch-radar projected merge"])

        let result = try runner.run(arguments: arguments, directory: root)
        guard result.exitCode == 0 else {
            throw gitFailure(arguments: arguments, result: result)
        }
        let oid = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !oid.isEmpty else {
            throw RepositoryError.malformedOutput(command: "git commit-tree", output: result.stdout)
        }
        return oid
    }

    private func parseConflicts(from output: String) -> [Conflict] {
        let lines = output.components(separatedBy: .newlines)
        guard !lines.isEmpty else { return [] }

        var paths: [String] = []
        var messages: [String] = []
        var readingPaths = true

        for line in lines.dropFirst() {
            if readingPaths {
                if line.isEmpty {
                    readingPaths = false
                } else {
                    paths.append(line)
                }
            } else if !line.isEmpty {
                messages.append(line)
            }
        }

        let conflictMessages = messages.filter { $0.contains("CONFLICT (") }
        let uniquePaths = Array(Set(paths)).sorted()

        return uniquePaths.map { path in
            let message = conflictMessages.first(where: { $0.contains(path) })
                ?? (conflictMessages.count == 1 ? conflictMessages[0] : nil)
            return Conflict(
                path: path,
                kind: conflictKind(from: message),
                message: message
            )
        }
    }

    private func conflictKind(from message: String?) -> ConflictKind {
        guard let message else { return .unknown }
        if message.contains("CONFLICT (content)") { return .content }
        if message.contains("CONFLICT (add/add)") { return .addAdd }
        if message.contains("CONFLICT (modify/delete)") { return .modifyDelete }
        if message.contains("CONFLICT (rename/rename)") { return .renameRename }
        if message.contains("CONFLICT (rename/delete)") { return .renameDelete }
        if message.contains("CONFLICT (rename/add)") { return .renameAdd }
        if message.contains("CONFLICT (directory/file)") { return .directoryFile }
        if message.contains("CONFLICT (file/directory)") { return .fileDirectory }
        return .unknown
    }

    private func normalizeLocalTarget(_ target: String) -> String {
        if target.hasPrefix("refs/heads/") {
            return String(target.dropFirst("refs/heads/".count))
        }
        return target
    }

    private func gitFailure(arguments: [String], result: GitCommandResult) -> RepositoryError {
        RepositoryError.gitFailure(
            command: "git " + arguments.joined(separator: " "),
            message: result.stderr.isEmpty ? result.stdout : result.stderr,
            exitCode: result.exitCode
        )
    }
}
