import Foundation

extension GitRepository {
    public func project(
        branch: String,
        against target: String,
        after pullRequests: [PullRequestSummary],
        mergeStrategies: [Int: MergeStrategySelection] = [:],
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
                    return PullRequestProjection(
                        pullRequest: pullRequest,
                        outcome: .unavailable,
                        mergeStrategy: mergeStrategies[pullRequest.id] ?? .legacyMergeCommit,
                        message: "Cross-repository pull request projection is not supported yet."
                    )
                }
                try ensureCommitAvailable(pullRequest.source.latestCommit, branch: pullRequest.source.branchName, remote: remote, fetchMissingObjects: fetchMissingObjects)
                try ensureCommitAvailable(pullRequest.target.latestCommit, branch: pullRequest.target.branchName, remote: remote, fetchMissingObjects: fetchMissingObjects)

                let serverTarget = pullRequest.target.latestCommit
                let selection = mergeStrategies[pullRequest.id] ?? .legacyMergeCommit
                let future = try simulateFutureTarget(
                    sourceCommit: pullRequest.source.latestCommit,
                    targetCommit: serverTarget,
                    strategy: selection.strategy
                )

                switch future.outcome {
                case .incomingConflict:
                    return PullRequestProjection(
                        pullRequest: pullRequest,
                        outcome: .incomingConflict,
                        mergeStrategy: selection,
                        conflicts: future.conflicts,
                        message: future.message
                    )
                case .strategyRejected:
                    return PullRequestProjection(
                        pullRequest: pullRequest,
                        outcome: .strategyRejected,
                        mergeStrategy: selection,
                        message: future.message
                    )
                case .unavailable:
                    return PullRequestProjection(
                        pullRequest: pullRequest,
                        outcome: .unavailable,
                        mergeStrategy: selection,
                        message: future.message
                    )
                case .clean, .risk, .conflict:
                    break
                }

                guard let syntheticTarget = future.futureTarget else {
                    return PullRequestProjection(
                        pullRequest: pullRequest,
                        outcome: .unavailable,
                        mergeStrategy: selection,
                        message: "The selected merge strategy did not produce a projected target commit."
                    )
                }
                let projected = try simulateMerge(branch: branchCommit, target: syntheticTarget)
                if projected.status == .conflict {
                    return PullRequestProjection(
                        pullRequest: pullRequest,
                        outcome: .conflict,
                        mergeStrategy: selection,
                        conflicts: projected.conflicts
                    )
                }

                let risks = try collisionRisks(branchCommit: branchCommit, incomingCommit: pullRequest.source.latestCommit, targetCommit: serverTarget)
                return PullRequestProjection(
                    pullRequest: pullRequest,
                    outcome: risks.isEmpty ? .clean : .risk,
                    mergeStrategy: selection,
                    risks: risks
                )
            } catch {
                return PullRequestProjection(
                    pullRequest: pullRequest,
                    outcome: .unavailable,
                    mergeStrategy: mergeStrategies[pullRequest.id] ?? .legacyMergeCommit,
                    message: String(describing: error)
                )
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
        mergeStrategies: [Int: MergeStrategySelection] = [:],
        remote: String = "origin",
        fetchMissingObjects: Bool = true
    ) throws -> ProjectedScanReport {
        let normalizedTarget = normalizeLocalTarget(target)
        let reports = try localBranches().filter { $0 != normalizedTarget }.map {
            try project(
                branch: $0,
                against: target,
                after: pullRequests,
                mergeStrategies: mergeStrategies,
                remote: remote,
                fetchMissingObjects: fetchMissingObjects
            )
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

    private func commitCount(from: String, to: String) throws -> Int {
        let args = ["rev-list", "--count", "\(from)..\(to)"]
        let result = try runner.run(arguments: args, directory: root)
        guard result.exitCode == 0, let count = Int(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw gitFailure(arguments: args, result: result)
        }
        return count
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
}
