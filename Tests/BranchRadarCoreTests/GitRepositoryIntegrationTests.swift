import BranchRadarCore
import Foundation
import Testing

struct GitRepositoryIntegrationTests {
    @Test func cleanAndConflictDetectionStillWork() throws {
        let repo = try TestRepo()
        try repo.write("shared.txt", "base\n")
        try repo.commit("base")
        try repo.git("branch", "clean")
        try repo.git("branch", "conflict")

        try repo.git("switch", "clean")
        try repo.write("clean.txt", "clean\n")
        try repo.commit("clean")

        try repo.git("switch", "conflict")
        try repo.write("shared.txt", "branch\n")
        try repo.commit("branch")

        try repo.git("switch", "main")
        try repo.write("shared.txt", "main\n")
        try repo.commit("main")

        let repository = try GitRepository(at: repo.url)
        #expect(try repository.analyze(branch: "clean", against: "main").status == .clean)
        let conflict = try repository.analyze(branch: "conflict", against: "main")
        #expect(conflict.status == .conflict)
        #expect(conflict.conflicts.first?.path == "shared.txt")
    }
}

struct CollisionRiskTests {
    @Test func sameFileDifferentHunksIsMediumRiskAndStillExitCleanSemantics() throws {
        let repo = try TestRepo()
        try repo.write("service.txt", numberedLines(12))
        try repo.commit("base")
        try repo.git("branch", "mine")
        try repo.git("branch", "incoming")

        try repo.git("switch", "mine")
        try repo.replaceLine("service.txt", line: 2, with: "mine-two")
        try repo.commit("mine")

        try repo.git("switch", "incoming")
        try repo.replaceLine("service.txt", line: 10, with: "incoming-ten")
        try repo.commit("incoming")
        let incoming = try repo.oid("HEAD")

        try repo.git("switch", "main")
        let target = try repo.oid("HEAD")

        let report = try GitRepository(at: repo.url).project(
            branch: "mine",
            against: "main",
            after: [pr(id: 42, source: "incoming", sourceCommit: incoming, targetCommit: target)],
            fetchMissingObjects: false
        )

        #expect(report.hasConflicts == false)
        #expect(report.hasRisks == true)
        #expect(report.projections[0].outcome == .risk)
        #expect(report.projections[0].risks == [CollisionRisk(
            path: "service.txt",
            level: .medium,
            kind: .sharedFile,
            message: "Both changes modify this file, but Git currently merges them cleanly."
        )])
        #expect(report.recommendations.map(\.code).contains(.reviewOverlap))
    }

    @Test func renameAndEditIsHighStructuralRiskWhenGitCanMergeIt() throws {
        let repo = try TestRepo()
        try repo.write("service.txt", numberedLines(6))
        try repo.commit("base")
        try repo.git("branch", "mine")
        try repo.git("branch", "incoming")

        try repo.git("switch", "mine")
        try repo.replaceLine("service.txt", line: 2, with: "mine-two")
        try repo.commit("mine")

        try repo.git("switch", "incoming")
        try repo.git("mv", "service.txt", "renamed-service.txt")
        try repo.commit("rename")
        let incoming = try repo.oid("HEAD")

        try repo.git("switch", "main")
        let target = try repo.oid("HEAD")

        let report = try GitRepository(at: repo.url).project(
            branch: "mine",
            against: "main",
            after: [pr(id: 43, source: "incoming", sourceCommit: incoming, targetCommit: target)],
            fetchMissingObjects: false
        )

        #expect(report.projections[0].outcome == .risk)
        #expect(report.projections[0].risks.contains { $0.path == "service.txt" && $0.level == .high && $0.kind == .structuralChange })
    }

    @Test func independentFilesRemainCleanWithNoRecommendation() throws {
        let repo = try TestRepo()
        try repo.write("base.txt", "base\n")
        try repo.commit("base")
        try repo.git("branch", "mine")
        try repo.git("branch", "incoming")
        try repo.git("switch", "mine"); try repo.write("mine.txt", "mine\n"); try repo.commit("mine")
        try repo.git("switch", "incoming"); try repo.write("incoming.txt", "incoming\n"); try repo.commit("incoming")
        let incoming = try repo.oid("HEAD")
        try repo.git("switch", "main"); let target = try repo.oid("HEAD")

        let report = try GitRepository(at: repo.url).project(branch: "mine", against: "main", after: [pr(id: 44, source: "incoming", sourceCommit: incoming, targetCommit: target)], fetchMissingObjects: false)
        #expect(report.projections[0].outcome == .clean)
        #expect(report.projections[0].risks.isEmpty)
        #expect(report.recommendations.isEmpty)
    }
}

struct ProjectionAndRecommendationTests {
    @Test func projectedConflictRecommendsFinishBeforePR() throws {
        let repo = try TestRepo()
        try repo.write("shared.txt", "base\n")
        try repo.commit("base")
        try repo.git("branch", "mine"); try repo.git("branch", "incoming")
        try repo.git("switch", "mine"); try repo.write("shared.txt", "mine\n"); try repo.commit("mine")
        try repo.git("switch", "incoming"); try repo.write("shared.txt", "incoming\n"); try repo.commit("incoming")
        let incoming = try repo.oid("HEAD")
        try repo.git("switch", "main"); let target = try repo.oid("HEAD")

        let report = try GitRepository(at: repo.url).project(branch: "mine", against: "main", after: [pr(id: 45, source: "incoming", sourceCommit: incoming, targetCommit: target)], fetchMissingObjects: false)
        #expect(report.projections[0].outcome == .conflict)
        #expect(report.recommendations.contains { $0.code == .finishBeforePR && $0.pullRequestID == 45 })
    }

    @Test func currentConflictRecommendsRebaseNow() throws {
        let repo = try TestRepo()
        try repo.write("shared.txt", "base\n"); try repo.commit("base"); try repo.git("branch", "mine")
        try repo.git("switch", "mine"); try repo.write("shared.txt", "mine\n"); try repo.commit("mine")
        try repo.git("switch", "main"); try repo.write("shared.txt", "main\n"); try repo.commit("main")

        let report = try GitRepository(at: repo.url).project(branch: "mine", against: "main", after: [], fetchMissingObjects: false)
        #expect(report.current.status == .conflict)
        #expect(report.recommendations.map(\.code) == [.rebaseNow])
    }

    @Test func staleLocalTargetIsReportedAndRecommendsRefresh() throws {
        let repo = try TestRepo()
        try repo.write("base.txt", "base\n"); try repo.commit("base")
        try repo.git("branch", "mine"); try repo.git("branch", "server-target")
        try repo.git("switch", "mine"); try repo.write("mine.txt", "mine\n"); try repo.commit("mine")
        try repo.git("switch", "server-target"); try repo.write("target.txt", "server\n"); try repo.commit("server target")
        let serverTarget = try repo.oid("HEAD")
        try repo.git("switch", "-c", "incoming"); try repo.write("incoming.txt", "incoming\n"); try repo.commit("incoming")
        let incoming = try repo.oid("HEAD")
        try repo.git("switch", "main")

        let report = try GitRepository(at: repo.url).project(branch: "mine", against: "main", after: [pr(id: 46, source: "incoming", sourceCommit: incoming, targetCommit: serverTarget)], fetchMissingObjects: false)
        #expect(report.targetFreshness?.status == .behind)
        #expect(report.targetFreshness?.commitsBehind == 1)
        #expect(report.recommendations.map(\.code).contains(.refreshTarget))
    }
}

private func pr(id: Int, source: String, sourceCommit: String, targetCommit: String) -> PullRequestSummary {
    let repository = RepositoryIdentity(projectKey: "DEMO", slug: "sample-service")
    return PullRequestSummary(
        id: id,
        title: "Incoming change",
        state: "OPEN",
        source: PullRequestRef(id: "refs/heads/\(source)", displayId: source, latestCommit: sourceCommit, repository: repository),
        target: PullRequestRef(id: "refs/heads/main", displayId: "main", latestCommit: targetCommit, repository: repository)
    )
}

private func numberedLines(_ count: Int) -> String { (1...count).map { "line-\($0)" }.joined(separator: "\n") + "\n" }

private final class TestRepo {
    let url: URL
    init() throws {
        url = FileManager.default.temporaryDirectory.appendingPathComponent("branch-radar-v04-tests").appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try git("init", "-q", "-b", "main")
        try git("config", "user.name", "Branch Radar Tests")
        try git("config", "user.email", "tests@branch-radar.invalid")
    }
    deinit { try? FileManager.default.removeItem(at: url) }
    func write(_ path: String, _ content: String) throws {
        let file = url.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try content.write(to: file, atomically: true, encoding: .utf8)
    }
    func replaceLine(_ path: String, line: Int, with value: String) throws {
        let file = url.appendingPathComponent(path)
        var lines = try String(contentsOf: file, encoding: .utf8).split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        lines[line - 1] = value
        try lines.joined(separator: "\n").write(to: file, atomically: true, encoding: .utf8)
    }
    func commit(_ message: String) throws { try git("add", "-A"); try git("commit", "-q", "-m", message) }
    func oid(_ ref: String) throws -> String { try git("rev-parse", ref).trimmingCharacters(in: .whitespacesAndNewlines) }
    @discardableResult func git(_ args: String...) throws -> String {
        let process = Process(); let stdout = Pipe(); let stderr = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env"); process.arguments = ["git"] + args; process.currentDirectoryURL = url
        process.standardOutput = stdout; process.standardError = stderr; try process.run(); process.waitUntilExit()
        let out = String(decoding: stdout.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        let err = String(decoding: stderr.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        guard process.terminationStatus == 0 else { throw TestError.message("git \(args.joined(separator: " ")): \(err)") }
        return out
    }
}

private enum TestError: Error { case message(String) }

struct RegressionSafetyTests {
    @Test func addAddConflictRemainsClassified() throws {
        let repo = try TestRepo()
        try repo.write("base.txt", "base\n"); try repo.commit("base"); try repo.git("branch", "feature")
        try repo.git("switch", "feature"); try repo.write("new.txt", "feature\n"); try repo.commit("feature")
        try repo.git("switch", "main"); try repo.write("new.txt", "main\n"); try repo.commit("main")
        let analysis = try GitRepository(at: repo.url).analyze(branch: "feature", against: "main")
        #expect(analysis.status == .conflict)
        #expect(analysis.conflicts.first?.kind == .addAdd)
    }

    @Test func fetchingMissingProjectionObjectsDoesNotMoveRefsOrWriteFetchHead() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("branch-radar-fetch-v04").appendingPathComponent(UUID().uuidString)
        let bare = root.appendingPathComponent("remote.git")
        let source = root.appendingPathComponent("source")
        let local = root.appendingPathComponent("local")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try runGit(["init", "-q", "--bare", bare.path], in: root)
        try runGit(["init", "-q", "-b", "main", source.path], in: root)
        try runGit(["config", "user.name", "Branch Radar Tests"], in: source)
        try runGit(["config", "user.email", "tests@branch-radar.invalid"], in: source)
        try "base\n".write(to: source.appendingPathComponent("base.txt"), atomically: true, encoding: .utf8)
        try runGit(["add", "-A"], in: source); try runGit(["commit", "-q", "-m", "base"], in: source)
        try runGit(["remote", "add", "origin", bare.path], in: source); try runGit(["push", "-q", "-u", "origin", "main"], in: source)

        try runGit(["clone", "-q", "--branch", "main", "--single-branch", bare.path, local.path], in: root)
        try runGit(["config", "user.name", "Branch Radar Tests"], in: local); try runGit(["config", "user.email", "tests@branch-radar.invalid"], in: local)
        try runGit(["switch", "-q", "-c", "mine"], in: local)
        try "mine\n".write(to: local.appendingPathComponent("mine.txt"), atomically: true, encoding: .utf8)
        try runGit(["add", "-A"], in: local); try runGit(["commit", "-q", "-m", "mine"], in: local)

        try runGit(["switch", "-q", "-c", "incoming"], in: source)
        try "incoming\n".write(to: source.appendingPathComponent("incoming.txt"), atomically: true, encoding: .utf8)
        try runGit(["add", "-A"], in: source); try runGit(["commit", "-q", "-m", "incoming"], in: source)
        let incomingOID = try runGit(["rev-parse", "HEAD"], in: source).trimmingCharacters(in: .whitespacesAndNewlines)
        try runGit(["push", "-q", "origin", "incoming"], in: source)
        let targetOID = try runGit(["rev-parse", "origin/main"], in: local).trimmingCharacters(in: .whitespacesAndNewlines)

        let refsBefore = try runGit(["show-ref"], in: local)
        let fetchHead = local.appendingPathComponent(".git/FETCH_HEAD")
        try? FileManager.default.removeItem(at: fetchHead)

        let report = try GitRepository(at: local).project(
            branch: "mine",
            against: "origin/main",
            after: [pr(id: 47, source: "incoming", sourceCommit: incomingOID, targetCommit: targetOID)],
            remote: "origin",
            fetchMissingObjects: true
        )

        #expect(report.projections.first?.outcome == .clean)
        #expect(try runGit(["show-ref"], in: local) == refsBefore)
        #expect(FileManager.default.fileExists(atPath: fetchHead.path) == false)
        #expect(try GitRepository(at: local).referenceExists(incomingOID))
    }
}

@discardableResult
private func runGit(_ args: [String], in directory: URL) throws -> String {
    let process = Process(); let stdout = Pipe(); let stderr = Pipe()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env"); process.arguments = ["git"] + args; process.currentDirectoryURL = directory
    process.standardOutput = stdout; process.standardError = stderr; try process.run(); process.waitUntilExit()
    let out = String(decoding: stdout.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    let err = String(decoding: stderr.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    guard process.terminationStatus == 0 else { throw TestError.message("git \(args.joined(separator: " ")): \(err)") }
    return out
}
