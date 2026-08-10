import BranchRadarCore
import Foundation
import Testing

struct MergeStrategyProjectionTests {
    @Test func fastForwardOnlyRejectsOutOfDateSourceWhileMergeCommitProjectsCleanly() throws {
        let repo = try TestRepo()
        try repo.write("base.txt", "base\n")
        try repo.commit("base")
        try repo.git("branch", "mine")
        try repo.git("branch", "incoming")

        try repo.git("switch", "mine")
        try repo.write("mine.txt", "mine\n")
        try repo.commit("mine")

        try repo.git("switch", "incoming")
        try repo.write("incoming.txt", "incoming\n")
        try repo.commit("incoming")
        let incoming = try repo.oid("HEAD")

        try repo.git("switch", "main")
        try repo.write("target.txt", "target\n")
        try repo.commit("target advances")
        let target = try repo.oid("HEAD")

        let pullRequest = pr(id: 60, source: "incoming", sourceCommit: incoming, targetCommit: target)
        let repository = try GitRepository(at: repo.url)

        let mergeCommit = try repository.project(
            branch: "mine",
            against: "main",
            after: [pullRequest],
            mergeStrategies: [60: strategy("no-ff")],
            fetchMissingObjects: false
        )
        #expect(mergeCommit.projections[0].outcome == .clean)

        let ffOnly = try repository.project(
            branch: "mine",
            against: "main",
            after: [pullRequest],
            mergeStrategies: [60: strategy("ff-only")],
            fetchMissingObjects: false
        )
        #expect(ffOnly.projections[0].outcome == .strategyRejected)
        #expect(ffOnly.hasConflicts == false)
    }

    @Test func fastForwardSquashAndRebaseMergeStrategiesProjectCleanlyWhenApplicable() throws {
        let repo = try TestRepo()
        try repo.write("base.txt", "base\n")
        try repo.commit("base")
        try repo.git("branch", "mine")
        try repo.git("branch", "incoming")
        try repo.git("switch", "mine"); try repo.write("mine.txt", "mine\n"); try repo.commit("mine")
        try repo.git("switch", "incoming"); try repo.write("incoming.txt", "incoming\n"); try repo.commit("incoming")
        let incoming = try repo.oid("HEAD")
        try repo.git("switch", "main"); let target = try repo.oid("HEAD")
        let pullRequest = pr(id: 64, source: "incoming", sourceCommit: incoming, targetCommit: target)
        let repository = try GitRepository(at: repo.url)

        for strategyID in ["ff", "squash", "rebase-no-ff"] {
            let report = try repository.project(
                branch: "mine",
                against: "main",
                after: [pullRequest],
                mergeStrategies: [64: strategy(strategyID)],
                fetchMissingObjects: false
            )
            #expect(report.projections[0].outcome == .clean)
            #expect(report.projections[0].mergeStrategy.strategy.id == strategyID)
        }
    }

    @Test func squashFastForwardOnlyRejectsOutOfDateSource() throws {
        let repo = try TestRepo()
        try repo.write("base.txt", "base\n")
        try repo.commit("base")
        try repo.git("branch", "mine")
        try repo.git("branch", "incoming")
        try repo.git("switch", "mine"); try repo.write("mine.txt", "mine\n"); try repo.commit("mine")
        try repo.git("switch", "incoming"); try repo.write("incoming.txt", "incoming\n"); try repo.commit("incoming")
        let incoming = try repo.oid("HEAD")
        try repo.git("switch", "main"); try repo.write("target.txt", "target\n"); try repo.commit("target")
        let target = try repo.oid("HEAD")

        let report = try GitRepository(at: repo.url).project(
            branch: "mine",
            against: "main",
            after: [pr(id: 61, source: "incoming", sourceCommit: incoming, targetCommit: target)],
            mergeStrategies: [61: strategy("squash-ff-only")],
            fetchMissingObjects: false
        )
        #expect(report.projections[0].outcome == .strategyRejected)
    }

    @Test func rebaseCanConflictWhenMergeCommitWouldBeClean() throws {
        let repo = try TestRepo()
        try repo.write("shared.txt", "A\n")
        try repo.commit("base")
        try repo.git("branch", "mine")
        try repo.git("branch", "incoming")

        try repo.git("switch", "mine")
        try repo.write("mine.txt", "mine\n")
        try repo.commit("mine")

        try repo.git("switch", "incoming")
        try repo.write("shared.txt", "B\n")
        try repo.commit("temporary change")
        try repo.write("shared.txt", "A\n")
        try repo.commit("restore content")
        let incoming = try repo.oid("HEAD")

        try repo.git("switch", "main")
        try repo.write("shared.txt", "C\n")
        try repo.commit("target change")
        let target = try repo.oid("HEAD")

        let pullRequest = pr(id: 62, source: "incoming", sourceCommit: incoming, targetCommit: target)
        let repository = try GitRepository(at: repo.url)

        let mergeCommit = try repository.project(
            branch: "mine",
            against: "main",
            after: [pullRequest],
            mergeStrategies: [62: strategy("no-ff")],
            fetchMissingObjects: false
        )
        #expect(mergeCommit.projections[0].outcome == .clean)

        let rebase = try repository.project(
            branch: "mine",
            against: "main",
            after: [pullRequest],
            mergeStrategies: [62: strategy("rebase-ff-only")],
            fetchMissingObjects: false
        )
        #expect(rebase.projections[0].outcome == .incomingConflict)
        #expect(rebase.projections[0].message?.contains("replay") == true)
    }

    @Test func rebaseFastForwardProjectionDoesNotMoveRefs() throws {
        let repo = try TestRepo()
        try repo.write("base.txt", "base\n")
        try repo.commit("base")
        try repo.git("branch", "mine")
        try repo.git("branch", "incoming")
        try repo.git("switch", "mine"); try repo.write("mine.txt", "mine\n"); try repo.commit("mine")
        try repo.git("switch", "incoming"); try repo.write("incoming.txt", "incoming\n"); try repo.commit("incoming")
        let incoming = try repo.oid("HEAD")
        try repo.git("switch", "main"); try repo.write("target.txt", "target\n"); try repo.commit("target")
        let target = try repo.oid("HEAD")
        let refsBefore = try repo.git("show-ref")

        let report = try GitRepository(at: repo.url).project(
            branch: "mine",
            against: "main",
            after: [pr(id: 63, source: "incoming", sourceCommit: incoming, targetCommit: target)],
            mergeStrategies: [63: strategy("rebase-ff-only")],
            fetchMissingObjects: false
        )

        #expect(report.projections[0].outcome == .clean)
        #expect(report.projections[0].mergeStrategy.strategy.kind == .rebaseFastForward)
        #expect(try repo.git("show-ref") == refsBefore)
    }

    @Test func strategyIDsAreClassifiedIntoBitbucketFamilies() {
        #expect(MergeStrategy(id: "no-ff").kind == .mergeCommit)
        #expect(MergeStrategy(id: "ff").kind == .fastForward)
        #expect(MergeStrategy(id: "ff-only").kind == .fastForwardOnly)
        #expect(MergeStrategy(id: "rebase-no-ff").kind == .rebaseMerge)
        #expect(MergeStrategy(id: "rebase-ff-only", flag: "--ff-only").kind == .rebaseFastForward)
        #expect(MergeStrategy(id: "squash").kind == .squash)
        #expect(MergeStrategy(id: "squash-ff-only", flag: "--ff-only").kind == .squashFastForwardOnly)
    }
}

private func strategy(_ id: String) -> MergeStrategySelection {
    MergeStrategySelection(strategy: MergeStrategy(id: id), source: .commandLine)
}
