import Foundation

struct FutureTargetSimulation {
    let outcome: ProjectionOutcome
    let futureTarget: String?
    let conflicts: [Conflict]
    let message: String?

    static func ready(_ commit: String) -> FutureTargetSimulation {
        FutureTargetSimulation(outcome: .clean, futureTarget: commit, conflicts: [], message: nil)
    }

    static func incomingConflict(_ conflicts: [Conflict], _ message: String) -> FutureTargetSimulation {
        FutureTargetSimulation(outcome: .incomingConflict, futureTarget: nil, conflicts: conflicts, message: message)
    }

    static func rejected(_ message: String) -> FutureTargetSimulation {
        FutureTargetSimulation(outcome: .strategyRejected, futureTarget: nil, conflicts: [], message: message)
    }

    static func unavailable(_ message: String) -> FutureTargetSimulation {
        FutureTargetSimulation(outcome: .unavailable, futureTarget: nil, conflicts: [], message: message)
    }
}

extension GitRepository {
    func simulateFutureTarget(
        sourceCommit: String,
        targetCommit: String,
        strategy: MergeStrategy
    ) throws -> FutureTargetSimulation {
        switch strategy.kind {
        case .mergeCommit:
            return try simulateMergeCommit(sourceCommit: sourceCommit, targetCommit: targetCommit)

        case .fastForward:
            if try isAncestor(targetCommit, of: sourceCommit) {
                return .ready(sourceCommit)
            }
            return try simulateMergeCommit(sourceCommit: sourceCommit, targetCommit: targetCommit)

        case .fastForwardOnly:
            guard try isAncestor(targetCommit, of: sourceCommit) else {
                return .rejected("Fast-forward only cannot land this PR because the source branch is out of date with the target.")
            }
            return .ready(sourceCommit)

        case .squash:
            return try simulateSquash(sourceCommit: sourceCommit, targetCommit: targetCommit, requireFastForward: false)

        case .squashFastForwardOnly:
            return try simulateSquash(sourceCommit: sourceCommit, targetCommit: targetCommit, requireFastForward: true)

        case .rebaseMerge:
            let replayed = try simulateRebase(sourceCommit: sourceCommit, targetCommit: targetCommit)
            guard replayed.outcome == .clean, let rebasedTip = replayed.futureTarget else { return replayed }
            if rebasedTip == targetCommit { return .ready(targetCommit) }
            let tree = try treeOID(for: rebasedTip)
            let mergeCommit = try createSyntheticMergeCommit(treeOID: tree, parents: [targetCommit, rebasedTip])
            return .ready(mergeCommit)

        case .rebaseFastForward:
            return try simulateRebase(sourceCommit: sourceCommit, targetCommit: targetCommit)

        case .unknown:
            return .unavailable("Merge strategy '\(strategy.id)' is not supported by this version of branch-radar.")
        }
    }

    private func simulateMergeCommit(sourceCommit: String, targetCommit: String) throws -> FutureTargetSimulation {
        let incoming = try simulateMerge(branch: sourceCommit, target: targetCommit)
        guard incoming.status == .clean, let tree = incoming.treeOID else {
            return .incomingConflict(
                incoming.conflicts,
                "The incoming PR does not merge cleanly using the selected merge strategy."
            )
        }
        return .ready(try createSyntheticMergeCommit(treeOID: tree, parents: [targetCommit, sourceCommit]))
    }

    private func simulateSquash(
        sourceCommit: String,
        targetCommit: String,
        requireFastForward: Bool
    ) throws -> FutureTargetSimulation {
        if requireFastForward, try !isAncestor(targetCommit, of: sourceCommit) {
            return .rejected("Squash, fast-forward only cannot land this PR because the source branch is out of date with the target.")
        }

        let incoming = try simulateMerge(branch: sourceCommit, target: targetCommit)
        guard incoming.status == .clean, let tree = incoming.treeOID else {
            return .incomingConflict(
                incoming.conflicts,
                "The incoming PR cannot be squashed cleanly onto the current target."
            )
        }
        let squashCommit = try createSyntheticMergeCommit(treeOID: tree, parents: [targetCommit])
        return .ready(squashCommit)
    }

    private func simulateRebase(sourceCommit: String, targetCommit: String) throws -> FutureTargetSimulation {
        let base = try mergeBase(targetCommit, sourceCommit)
        let commits = try replayableCommits(from: base, to: sourceCommit)
        var tip = targetCommit

        for commit in commits {
            let parent = try firstParent(of: commit)
            let replay = try simulateMerge(branch: commit, target: tip, explicitMergeBase: parent)
            guard replay.status == .clean, let tree = replay.treeOID else {
                return .incomingConflict(
                    replay.conflicts,
                    "The selected rebase strategy conflicts while replaying commit \(String(commit.prefix(10)))."
                )
            }

            if tree == (try treeOID(for: tip)) {
                continue
            }
            tip = try createSyntheticMergeCommit(treeOID: tree, parents: [tip])
        }

        return .ready(tip)
    }

    private func replayableCommits(from base: String, to source: String) throws -> [String] {
        let args = ["rev-list", "--reverse", "--topo-order", "--no-merges", "\(base)..\(source)"]
        let result = try runner.run(arguments: args, directory: root)
        guard result.exitCode == 0 else { throw gitFailure(arguments: args, result: result) }
        return result.stdout.split(separator: "\n").map(String.init)
    }

    private func firstParent(of commit: String) throws -> String {
        let args = ["rev-parse", "\(commit)^1"]
        let result = try runner.run(arguments: args, directory: root)
        guard result.exitCode == 0 else { throw gitFailure(arguments: args, result: result) }
        let oid = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !oid.isEmpty else { throw RepositoryError.malformedOutput(command: "git rev-parse", output: result.stdout) }
        return oid
    }

    private func treeOID(for commit: String) throws -> String {
        let args = ["rev-parse", "\(commit)^{tree}"]
        let result = try runner.run(arguments: args, directory: root)
        guard result.exitCode == 0 else { throw gitFailure(arguments: args, result: result) }
        let oid = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !oid.isEmpty else { throw RepositoryError.malformedOutput(command: "git rev-parse", output: result.stdout) }
        return oid
    }
}
