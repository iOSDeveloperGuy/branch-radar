import Foundation

public enum RepositoryError: Error, CustomStringConvertible, Sendable {
    case notARepository
    case invalidReference(String)
    case noDefaultTarget
    case gitFailure(command: String, message: String, exitCode: Int32)
    case malformedOutput(command: String, output: String)

    public var description: String {
        switch self {
        case .notARepository: return "The current directory is not inside a Git repository."
        case .invalidReference(let ref): return "Git reference '\(ref)' does not exist."
        case .noDefaultTarget: return "Could not determine a target branch. Pass --target <ref>."
        case .gitFailure(let command, let message, let exitCode):
            let detail = message.trimmingCharacters(in: .whitespacesAndNewlines)
            return detail.isEmpty ? "Git command failed (\(exitCode)): \(command)" : "Git command failed (\(exitCode)): \(command): \(detail)"
        case .malformedOutput(let command, let output): return "Unexpected output from '\(command)': \(output)"
        }
    }
}

public struct GitRepository: Sendable {
    public let root: URL
    private let runner: any GitCommandRunning

    public init(at directory: URL, runner: any GitCommandRunning = GitCommandRunner()) throws {
        let result = try runner.run(arguments: ["rev-parse", "--show-toplevel"], directory: directory)
        guard result.exitCode == 0 else { throw RepositoryError.notARepository }
        let path = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty else { throw RepositoryError.notARepository }
        root = URL(fileURLWithPath: path, isDirectory: true)
        self.runner = runner
    }

    public func referenceExists(_ ref: String) throws -> Bool {
        try runner.run(arguments: ["rev-parse", "--verify", "--quiet", "\(ref)^{commit}"], directory: root).exitCode == 0
    }

    public func resolveCommit(_ ref: String) throws -> String {
        let result = try runner.run(arguments: ["rev-parse", "--verify", "\(ref)^{commit}"], directory: root)
        guard result.exitCode == 0 else { throw RepositoryError.invalidReference(ref) }
        let oid = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !oid.isEmpty else { throw RepositoryError.malformedOutput(command: "git rev-parse", output: result.stdout) }
        return oid
    }

    public func resolveTarget(explicit: String?) throws -> String {
        if let explicit {
            guard try referenceExists(explicit) else { throw RepositoryError.invalidReference(explicit) }
            return explicit
        }
        let originHead = try runner.run(arguments: ["symbolic-ref", "--quiet", "--short", "refs/remotes/origin/HEAD"], directory: root)
        if originHead.exitCode == 0 {
            let target = originHead.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            if !target.isEmpty, try referenceExists(target) { return target }
        }
        for candidate in ["origin/main", "origin/master", "main", "master"] where try referenceExists(candidate) { return candidate }
        throw RepositoryError.noDefaultTarget
    }

    public func localBranches() throws -> [String] {
        let result = try runner.run(arguments: ["for-each-ref", "--format=%(refname:short)", "refs/heads/"], directory: root)
        guard result.exitCode == 0 else { throw gitFailure(arguments: ["for-each-ref", "refs/heads/"], result: result) }
        return result.stdout.split(separator: "\n").map(String.init).filter { !$0.isEmpty }.sorted()
    }

    public func remoteURL(_ remote: String) throws -> String? {
        let result = try runner.run(arguments: ["remote", "get-url", remote], directory: root)
        guard result.exitCode == 0 else { return nil }
        let value = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    public func analyze(branch: String, against target: String) throws -> BranchAnalysis {
        guard try referenceExists(branch) else { throw RepositoryError.invalidReference(branch) }
        guard try referenceExists(target) else { throw RepositoryError.invalidReference(target) }
        let divergence = try aheadBehind(branch: branch, target: target)
        let merge = try simulateMerge(branch: branch, target: target)
        return BranchAnalysis(branch: branch, target: target, status: merge.status, conflicts: merge.conflicts, ahead: divergence.ahead, behind: divergence.behind)
    }

    public func scanLocalBranches(against target: String) throws -> ScanReport {
        let normalizedTarget = normalizeLocalTarget(target)
        return ScanReport(target: target, branches: try localBranches().filter { $0 != normalizedTarget }.map { try analyze(branch: $0, against: target) })
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
        let localTargetCommit = try resolveCommit(target)
        let freshness = targetFreshness(
            localCommit: localTargetCommit,
            pullRequests: pullRequests,
            remote: remote,
            fetchMissingObjects: fetchMissingObjects
        )

        let projections = pullRequests.compactMap { pullRequest -> PullRequestProjection? in
            if pullRequest.source.latestCommit == branchCommit || pullRequest.source.branchName == branch { return nil }
            do {
                guard pullRequest.source.repository == pullRequest.target.repository else {
                    return PullRequestProjection(pullRequest: pullRequest, outcome: .unavailable, message: "Cross-repository pull request projection is not supported yet.")
                }
                try ensureCommitAvailable(pullRequest.source.latestCommit, branch: pullRequest.source.branchName, remote: remote, fetchMissingObjects: fetchMissingObjects)
                try ensureCommitAvailable(pullRequest.target.latestCommit, branch: pullRequest.target.branchName, remote: remote, fetchMissingObjects: fetchMissingObjects)

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

                let syntheticTarget = try createSyntheticMergeCommit(treeOID: incomingTree, parents: [serverTarget, pullRequest.source.latestCommit])
                let projected = try simulateMerge(branch: branchCommit, target: syntheticTarget)
                if projected.status == .conflict {
                    return PullRequestProjection(pullRequest: pullRequest, outcome: .conflict, conflicts: projected.conflicts)
                }

                let risks = try collisionRisks(branchCommit: branchCommit, incomingCommit: pullRequest.source.latestCommit, targetCommit: serverTarget)
                return PullRequestProjection(pullRequest: pullRequest, outcome: risks.isEmpty ? .clean : .risk, risks: risks)
            } catch {
                return PullRequestProjection(pullRequest: pullRequest, outcome: .unavailable, message: String(describing: error))
            }
        }

        let recommendations = recommendations(current: current, freshness: freshness, projections: projections)
        return ProjectionReport(
            branch: branch,
            target: target,
            current: current,
            targetFreshness: freshness,
            projections: projections,
            recommendations: recommendations
        )
    }

    public func projectLocalBranches(
        against target: String,
        after pullRequests: [PullRequestSummary],
        remote: String = "origin",
        fetchMissingObjects: Bool = true
    ) throws -> ProjectedScanReport {
        let normalizedTarget = normalizeLocalTarget(target)
        let reports = try localBranches().filter { $0 != normalizedTarget }.map {
            try project(branch: $0, against: target, after: pullRequests, remote: remote, fetchMissingObjects: fetchMissingObjects)
        }
        return ProjectedScanReport(target: target, branches: reports)
    }

    private func recommendations(current: BranchAnalysis, freshness: TargetFreshness?, projections: [PullRequestProjection]) -> [Recommendation] {
        var result: [Recommendation] = []
        if current.status == .conflict {
            result.append(Recommendation(code: .rebaseNow, message: "This branch already conflicts with the target. Rebase or merge the target before doing more work."))
        }
        for projection in projections where projection.outcome == .conflict {
            result.append(Recommendation(
                code: .finishBeforePR,
                message: "PR #\(projection.pullRequest.id) is projected to conflict if it lands first. Finish this branch before that PR, or plan to rebase afterward.",
                pullRequestID: projection.pullRequest.id
            ))
        }
        if let freshness, freshness.status == .behind || freshness.status == .diverged {
            let detail = freshness.commitsBehind.map { " by \($0) commit(s)" } ?? ""
            result.append(Recommendation(code: .refreshTarget, message: "The local target is \(freshness.status.rawValue) Bitbucket's target\(detail). Fetch the target before relying on current-state analysis."))
        }
        for projection in projections where projection.outcome == .risk {
            result.append(Recommendation(
                code: .reviewOverlap,
                message: "PR #\(projection.pullRequest.id) overlaps this branch but Git still merges it cleanly. Review the shared code before both changes land.",
                pullRequestID: projection.pullRequest.id
            ))
        }
        return result
    }

    private func targetFreshness(localCommit: String, pullRequests: [PullRequestSummary], remote: String, fetchMissingObjects: Bool) -> TargetFreshness? {
        let targets = Set(pullRequests.map { $0.target.latestCommit })
        guard targets.count == 1, let serverCommit = targets.first, let firstPR = pullRequests.first else { return nil }
        do {
            try ensureCommitAvailable(serverCommit, branch: firstPR.target.branchName, remote: remote, fetchMissingObjects: fetchMissingObjects)
            if localCommit == serverCommit { return TargetFreshness(status: .current, localCommit: localCommit, serverCommit: serverCommit) }
            if try isAncestor(localCommit, of: serverCommit) {
                return TargetFreshness(status: .behind, localCommit: localCommit, serverCommit: serverCommit, commitsBehind: try commitCount(from: localCommit, to: serverCommit))
            }
            if try isAncestor(serverCommit, of: localCommit) {
                return TargetFreshness(status: .ahead, localCommit: localCommit, serverCommit: serverCommit)
            }
            return TargetFreshness(status: .diverged, localCommit: localCommit, serverCommit: serverCommit)
        } catch {
            return TargetFreshness(status: .unavailable, localCommit: localCommit, serverCommit: serverCommit)
        }
    }

    private func collisionRisks(branchCommit: String, incomingCommit: String, targetCommit: String) throws -> [CollisionRisk] {
        let branchBase = try mergeBase(targetCommit, branchCommit)
        let incomingBase = try mergeBase(targetCommit, incomingCommit)
        let branchChanges = try changedPaths(base: branchBase, head: branchCommit)
        let incomingChanges = try changedPaths(base: incomingBase, head: incomingCommit)

        let shared = Set(branchChanges.keys).intersection(incomingChanges.keys).sorted()
        var risks: [CollisionRisk] = []
        for path in shared {
            guard let mine = branchChanges[path], let incoming = incomingChanges[path] else { continue }
            if mine.structural || incoming.structural {
                risks.append(CollisionRisk(path: path, level: .high, kind: .structuralChange, message: "Both changes interact with this path and at least one side renames or deletes it."))
                continue
            }
            if branchBase == incomingBase {
                let mineRanges = try changedBaseRanges(base: branchBase, head: branchCommit, path: path)
                let incomingRanges = try changedBaseRanges(base: incomingBase, head: incomingCommit, path: path)
                if rangesOverlap(mineRanges, incomingRanges) {
                    risks.append(CollisionRisk(path: path, level: .high, kind: .overlappingLines, message: "Both changes touch overlapping lines from the same merge base, although Git currently merges them cleanly."))
                    continue
                }
            }
            risks.append(CollisionRisk(path: path, level: .medium, kind: .sharedFile, message: "Both changes modify this file, but Git currently merges them cleanly."))
        }
        return risks.sorted {
            if $0.level != $1.level { return $1.level < $0.level }
            return $0.path < $1.path
        }
    }

    private struct PathChange { let structural: Bool }

    private func changedPaths(base: String, head: String) throws -> [String: PathChange] {
        let args = ["diff", "--name-status", "-M", "\(base)..\(head)"]
        let result = try runner.run(arguments: args, directory: root)
        guard result.exitCode == 0 else { throw gitFailure(arguments: args, result: result) }
        var changes: [String: PathChange] = [:]
        for line in result.stdout.split(separator: "\n") {
            let parts = line.split(separator: "\t").map(String.init)
            guard parts.count >= 2 else { continue }
            let status = parts[0]
            let structural = status.hasPrefix("R") || status.hasPrefix("C") || status == "D"
            if (status.hasPrefix("R") || status.hasPrefix("C")), parts.count >= 3 {
                changes[parts[1]] = PathChange(structural: true)
                changes[parts[2]] = PathChange(structural: true)
            } else {
                changes[parts[1]] = PathChange(structural: structural)
            }
        }
        return changes
    }

    private struct BaseLineRange {
        let start: Int
        let count: Int
        var end: Int { count == 0 ? start : start + count - 1 }
    }

    private func changedBaseRanges(base: String, head: String, path: String) throws -> [BaseLineRange] {
        let args = ["diff", "--unified=0", "--no-color", "\(base)..\(head)", "--", path]
        let result = try runner.run(arguments: args, directory: root)
        guard result.exitCode == 0 else { throw gitFailure(arguments: args, result: result) }
        return result.stdout.split(separator: "\n").compactMap { parseOldRange(fromHunkHeader: String($0)) }
    }

    private func parseOldRange(fromHunkHeader line: String) -> BaseLineRange? {
        guard line.hasPrefix("@@ "), let minus = line.firstIndex(of: "-") else { return nil }
        let tail = line[line.index(after: minus)...]
        guard let space = tail.firstIndex(of: " ") else { return nil }
        let token = tail[..<space]
        let pieces = token.split(separator: ",", maxSplits: 1).map(String.init)
        guard let start = Int(pieces[0]) else { return nil }
        let count = pieces.count == 2 ? (Int(pieces[1]) ?? 0) : 1
        return BaseLineRange(start: start, count: count)
    }

    private func rangesOverlap(_ lhs: [BaseLineRange], _ rhs: [BaseLineRange]) -> Bool {
        for a in lhs {
            for b in rhs {
                if a.count == 0 && b.count == 0, a.start == b.start { return true }
                if a.count == 0, b.count > 0, a.start >= b.start && a.start <= b.end + 1 { return true }
                if b.count == 0, a.count > 0, b.start >= a.start && b.start <= a.end + 1 { return true }
                if a.count > 0 && b.count > 0 && max(a.start, b.start) <= min(a.end, b.end) { return true }
            }
        }
        return false
    }

    private func mergeBase(_ lhs: String, _ rhs: String) throws -> String {
        let args = ["merge-base", lhs, rhs]
        let result = try runner.run(arguments: args, directory: root)
        guard result.exitCode == 0 else { throw gitFailure(arguments: args, result: result) }
        let oid = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !oid.isEmpty else { throw RepositoryError.malformedOutput(command: "git merge-base", output: result.stdout) }
        return oid
    }

    private func isAncestor(_ ancestor: String, of descendant: String) throws -> Bool {
        let args = ["merge-base", "--is-ancestor", ancestor, descendant]
        let result = try runner.run(arguments: args, directory: root)
        if result.exitCode == 0 { return true }
        if result.exitCode == 1 { return false }
        throw gitFailure(arguments: args, result: result)
    }

    private func commitCount(from: String, to: String) throws -> Int {
        let args = ["rev-list", "--count", "\(from)..\(to)"]
        let result = try runner.run(arguments: args, directory: root)
        guard result.exitCode == 0, let count = Int(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw gitFailure(arguments: args, result: result)
        }
        return count
    }

    private func aheadBehind(branch: String, target: String) throws -> (ahead: Int, behind: Int) {
        let args = ["rev-list", "--left-right", "--count", "\(target)...\(branch)"]
        let result = try runner.run(arguments: args, directory: root)
        guard result.exitCode == 0 else { throw gitFailure(arguments: args, result: result) }
        let parts = result.stdout.split(whereSeparator: { $0 == "\t" || $0 == " " || $0 == "\n" })
        guard parts.count >= 2, let behind = Int(parts[0]), let ahead = Int(parts[1]) else {
            throw RepositoryError.malformedOutput(command: "git rev-list", output: result.stdout)
        }
        return (ahead, behind)
    }

    private struct MergeSimulation { let status: AnalysisStatus; let conflicts: [Conflict]; let treeOID: String? }

    private func simulateMerge(branch: String, target: String) throws -> MergeSimulation {
        let args = ["merge-tree", "--write-tree", "--name-only", target, branch]
        let result = try runner.run(arguments: args, directory: root)
        if result.exitCode == 0 {
            let tree = result.stdout.split(separator: "\n", maxSplits: 1).first.map(String.init)?.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let tree, !tree.isEmpty else { throw RepositoryError.malformedOutput(command: "git merge-tree", output: result.stdout) }
            return MergeSimulation(status: .clean, conflicts: [], treeOID: tree)
        }
        guard result.exitCode == 1 else { throw gitFailure(arguments: args, result: result) }
        return MergeSimulation(status: .conflict, conflicts: parseConflicts(from: result.stdout + result.stderr), treeOID: nil)
    }

    private func ensureCommitAvailable(_ commit: String, branch: String, remote: String, fetchMissingObjects: Bool) throws {
        if try referenceExists(commit) { return }
        guard fetchMissingObjects else { throw RepositoryError.invalidReference(commit) }
        let ref = branch.hasPrefix("refs/") ? branch : "refs/heads/\(branch)"
        let args = ["fetch", "--no-tags", "--no-write-fetch-head", remote, ref]
        let result = try runner.run(arguments: args, directory: root)
        guard result.exitCode == 0 else { throw gitFailure(arguments: args, result: result) }
        guard try referenceExists(commit) else { throw RepositoryError.invalidReference(commit) }
    }

    private func createSyntheticMergeCommit(treeOID: String, parents: [String]) throws -> String {
        var args = ["-c", "user.name=branch-radar", "-c", "user.email=branch-radar@invalid", "commit-tree", treeOID]
        for parent in parents { args.append(contentsOf: ["-p", parent]) }
        args.append(contentsOf: ["-m", "branch-radar projected merge"])
        let result = try runner.run(arguments: args, directory: root)
        guard result.exitCode == 0 else { throw gitFailure(arguments: args, result: result) }
        let oid = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !oid.isEmpty else { throw RepositoryError.malformedOutput(command: "git commit-tree", output: result.stdout) }
        return oid
    }

    private func parseConflicts(from output: String) -> [Conflict] {
        let lines = output.components(separatedBy: .newlines)
        guard !lines.isEmpty else { return [] }
        var paths: [String] = []; var messages: [String] = []; var readingPaths = true
        for line in lines.dropFirst() {
            if readingPaths {
                if line.isEmpty { readingPaths = false } else { paths.append(line) }
            } else if !line.isEmpty { messages.append(line) }
        }
        let conflictMessages = messages.filter { $0.contains("CONFLICT (") }
        return Array(Set(paths)).sorted().map { path in
            let message = conflictMessages.first(where: { $0.contains(path) }) ?? (conflictMessages.count == 1 ? conflictMessages[0] : nil)
            return Conflict(path: path, kind: conflictKind(from: message), message: message)
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
        target.hasPrefix("refs/heads/") ? String(target.dropFirst("refs/heads/".count)) : target
    }

    private func gitFailure(arguments: [String], result: GitCommandResult) -> RepositoryError {
        RepositoryError.gitFailure(command: "git " + arguments.joined(separator: " "), message: result.stderr.isEmpty ? result.stdout : result.stderr, exitCode: result.exitCode)
    }
}
