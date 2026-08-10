import BranchRadarCore
import Foundation
import Testing

struct GitRepositoryIntegrationTests {
    @Test
    func cleanBranchesAreReportedCleanWithDivergence() throws {
        let repo = try TestRepository()
        try repo.write("base.txt", "base\n")
        try repo.commitAll("base")
        try repo.run("branch", "feature")

        try repo.run("switch", "feature")
        try repo.write("feature.txt", "feature\n")
        try repo.commitAll("feature")

        try repo.run("switch", "main")
        try repo.write("main.txt", "main\n")
        try repo.commitAll("main")

        let repository = try GitRepository(at: repo.url)
        let result = try repository.analyze(branch: "feature", against: "main")

        #expect(result.status == .clean)
        #expect(result.conflicts.isEmpty)
        #expect(result.ahead == 1)
        #expect(result.behind == 1)
    }

    @Test
    func contentConflictReportsPathAndType() throws {
        let repo = try TestRepository()
        try repo.write("shared.txt", "base\n")
        try repo.commitAll("base")
        try repo.run("branch", "feature")

        try repo.run("switch", "feature")
        try repo.write("shared.txt", "feature\n")
        try repo.commitAll("feature")

        try repo.run("switch", "main")
        try repo.write("shared.txt", "main\n")
        try repo.commitAll("main")

        let repository = try GitRepository(at: repo.url)
        let result = try repository.analyze(branch: "feature", against: "main")

        #expect(result.status == .conflict)
        #expect(result.conflicts.count == 1)
        #expect(result.conflicts[0].path == "shared.txt")
        #expect(result.conflicts[0].kind == .content)
    }

    @Test
    func addAddConflictIsClassified() throws {
        let repo = try TestRepository()
        try repo.write("base.txt", "base\n")
        try repo.commitAll("base")
        try repo.run("branch", "feature")

        try repo.run("switch", "feature")
        try repo.write("new.txt", "feature\n")
        try repo.commitAll("feature")

        try repo.run("switch", "main")
        try repo.write("new.txt", "main\n")
        try repo.commitAll("main")

        let repository = try GitRepository(at: repo.url)
        let result = try repository.analyze(branch: "feature", against: "main")

        #expect(result.status == .conflict)
        #expect(result.conflicts.first?.kind == .addAdd)
    }

    @Test
    func scanExcludesTargetLocalBranch() throws {
        let repo = try TestRepository()
        try repo.write("base.txt", "base\n")
        try repo.commitAll("base")
        try repo.run("branch", "feature-one")
        try repo.run("branch", "feature-two")

        let repository = try GitRepository(at: repo.url)
        let report = try repository.scanLocalBranches(against: "main")

        #expect(report.branches.map(\.branch) == ["feature-one", "feature-two"])
    }
}

private final class TestRepository {
    let url: URL

    init() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("branch-radar-tests")
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        self.url = root

        try run("init", "-q", "-b", "main")
        try run("config", "user.name", "Branch Radar Tests")
        try run("config", "user.email", "tests@branch-radar.invalid")
    }

    deinit {
        try? FileManager.default.removeItem(at: url)
    }

    func write(_ path: String, _ contents: String) throws {
        let fileURL = url.appendingPathComponent(path)
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try contents.write(to: fileURL, atomically: true, encoding: .utf8)
    }

    func commitAll(_ message: String) throws {
        try run("add", "-A")
        try run("commit", "-q", "-m", message)
    }

    @discardableResult
    func run(_ arguments: String...) throws -> String {
        let process = Process()
        let stdout = Pipe()
        let stderr = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git"] + arguments
        process.currentDirectoryURL = url
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        process.waitUntilExit()

        let output = String(decoding: stdout.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        let error = String(decoding: stderr.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        guard process.terminationStatus == 0 else {
            throw TestGitError(message: "git \(arguments.joined(separator: " ")) failed: \(error)")
        }
        return output
    }
}

private struct TestGitError: Error {
    let message: String
}

struct ProjectionIntegrationTests {
    @Test
    func cleanTodayCanConflictAfterIncomingPRLands() throws {
        let repo = try ProjectionTestRepository()
        try repo.write("shared.txt", "base\n")
        try repo.commitAll("base")
        try repo.run("branch", "mine")
        try repo.run("branch", "incoming")

        try repo.run("switch", "mine")
        try repo.write("shared.txt", "mine\n")
        try repo.commitAll("mine")
        let mineCommit = try repo.run("rev-parse", "HEAD").trimmed

        try repo.run("switch", "incoming")
        try repo.write("shared.txt", "incoming\n")
        try repo.commitAll("incoming")
        let incomingCommit = try repo.run("rev-parse", "HEAD").trimmed

        try repo.run("switch", "main")
        let targetCommit = try repo.run("rev-parse", "HEAD").trimmed
        let refsBefore = try repo.run("show-ref")

        let repository = try GitRepository(at: repo.url)
        let current = try repository.analyze(branch: "mine", against: "main")
        #expect(current.status == .clean)

        let report = try repository.project(
            branch: "mine",
            against: "main",
            after: [makePullRequest(id: 42, sourceBranch: "incoming", sourceCommit: incomingCommit, targetCommit: targetCommit)],
            fetchMissingObjects: false
        )

        #expect(report.current.status == .clean)
        #expect(report.projections.count == 1)
        #expect(report.projections[0].outcome == .conflict)
        #expect(report.projections[0].conflicts.map(\.path) == ["shared.txt"])
        #expect(try repo.run("rev-parse", "mine").trimmed == mineCommit)
        #expect(try repo.run("show-ref") == refsBefore)
    }

    @Test
    func independentChangesRemainCleanAfterIncomingPRLands() throws {
        let repo = try ProjectionTestRepository()
        try repo.write("base.txt", "base\n")
        try repo.commitAll("base")
        try repo.run("branch", "mine")
        try repo.run("branch", "incoming")

        try repo.run("switch", "mine")
        try repo.write("mine.txt", "mine\n")
        try repo.commitAll("mine")

        try repo.run("switch", "incoming")
        try repo.write("incoming.txt", "incoming\n")
        try repo.commitAll("incoming")
        let incomingCommit = try repo.run("rev-parse", "HEAD").trimmed

        try repo.run("switch", "main")
        let targetCommit = try repo.run("rev-parse", "HEAD").trimmed

        let repository = try GitRepository(at: repo.url)
        let report = try repository.project(
            branch: "mine",
            against: "main",
            after: [makePullRequest(id: 43, sourceBranch: "incoming", sourceCommit: incomingCommit, targetCommit: targetCommit)],
            fetchMissingObjects: false
        )

        #expect(report.projections[0].outcome == .clean)
        #expect(report.projections[0].conflicts.isEmpty)
    }

    @Test
    func incomingPRConflictIsNotMisreportedAsProjectedBranchConflict() throws {
        let repo = try ProjectionTestRepository()
        try repo.write("shared.txt", "base\n")
        try repo.commitAll("base")
        try repo.run("branch", "incoming")

        try repo.run("switch", "incoming")
        try repo.write("shared.txt", "incoming\n")
        try repo.commitAll("incoming")
        let incomingCommit = try repo.run("rev-parse", "HEAD").trimmed

        try repo.run("switch", "main")
        try repo.write("shared.txt", "main\n")
        try repo.commitAll("main")
        try repo.run("branch", "mine")
        let targetCommit = try repo.run("rev-parse", "HEAD").trimmed

        let repository = try GitRepository(at: repo.url)
        let report = try repository.project(
            branch: "mine",
            against: "main",
            after: [makePullRequest(id: 44, sourceBranch: "incoming", sourceCommit: incomingCommit, targetCommit: targetCommit)],
            fetchMissingObjects: false
        )

        #expect(report.current.status == .clean)
        #expect(report.projections[0].outcome == .incomingConflict)
        #expect(report.hasConflicts == false)
    }

    private func makePullRequest(
        id: Int,
        sourceBranch: String,
        sourceCommit: String,
        targetCommit: String
    ) -> PullRequestSummary {
        let repository = RepositoryIdentity(projectKey: "TEST", slug: "repo")
        return PullRequestSummary(
            id: id,
            title: "Incoming change",
            state: "OPEN",
            source: PullRequestRef(
                id: "refs/heads/\(sourceBranch)",
                displayId: sourceBranch,
                latestCommit: sourceCommit,
                repository: repository
            ),
            target: PullRequestRef(
                id: "refs/heads/main",
                displayId: "main",
                latestCommit: targetCommit,
                repository: repository
            )
        )
    }
}

private final class ProjectionTestRepository {
    let url: URL

    init() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("branch-radar-projection-tests")
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        self.url = root

        try run("init", "-q", "-b", "main")
        try run("config", "user.name", "Branch Radar Tests")
        try run("config", "user.email", "tests@branch-radar.invalid")
    }

    deinit { try? FileManager.default.removeItem(at: url) }

    func write(_ path: String, _ contents: String) throws {
        let fileURL = url.appendingPathComponent(path)
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try contents.write(to: fileURL, atomically: true, encoding: .utf8)
    }

    func commitAll(_ message: String) throws {
        try run("add", "-A")
        try run("commit", "-q", "-m", message)
    }

    @discardableResult
    func run(_ arguments: String...) throws -> String {
        let process = Process()
        let stdout = Pipe()
        let stderr = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git"] + arguments
        process.currentDirectoryURL = url
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        process.waitUntilExit()

        let output = String(decoding: stdout.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        let error = String(decoding: stderr.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        guard process.terminationStatus == 0 else {
            throw ProjectionTestGitError(message: "git \(arguments.joined(separator: " ")) failed: \(error)")
        }
        return output
    }
}

private struct ProjectionTestGitError: Error {
    let message: String
}

private extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}

struct ObjectFetchSafetyTests {
    @Test
    func projectionFetchesMissingObjectsWithoutUpdatingRefsOrFetchHead() throws {
        let fixture = try RemoteProjectionFixture()
        defer { fixture.cleanup() }

        let repository = try GitRepository(at: fixture.localURL)
        let refsBefore = try fixture.localGit("show-ref")
        let fetchHeadURL = fixture.localURL.appendingPathComponent(".git/FETCH_HEAD")
        try? FileManager.default.removeItem(at: fetchHeadURL)

        let report = try repository.project(
            branch: "mine",
            against: "origin/main",
            after: [fixture.pullRequest],
            remote: "origin",
            fetchMissingObjects: true
        )

        #expect(report.projections.first?.outcome == .clean)
        #expect(try fixture.localGit("show-ref") == refsBefore)
        #expect(FileManager.default.fileExists(atPath: fetchHeadURL.path) == false)
        #expect(try repository.referenceExists(fixture.incomingCommit))
    }
}

private final class RemoteProjectionFixture {
    let root: URL
    let localURL: URL
    let incomingCommit: String
    let pullRequest: PullRequestSummary

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("branch-radar-fetch-tests")
            .appendingPathComponent(UUID().uuidString)
        let remote = root.appendingPathComponent("remote.git")
        let source = root.appendingPathComponent("source")
        localURL = root.appendingPathComponent("local")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        try Self.runGit(["init", "-q", "--bare", remote.path], in: root)
        try Self.runGit(["init", "-q", "-b", "main", source.path], in: root)
        try Self.runGit(["config", "user.name", "Branch Radar Tests"], in: source)
        try Self.runGit(["config", "user.email", "tests@branch-radar.invalid"], in: source)
        try "base\n".write(to: source.appendingPathComponent("base.txt"), atomically: true, encoding: .utf8)
        try Self.runGit(["add", "-A"], in: source)
        try Self.runGit(["commit", "-q", "-m", "base"], in: source)
        try Self.runGit(["remote", "add", "origin", remote.path], in: source)
        try Self.runGit(["push", "-q", "-u", "origin", "main"], in: source)

        try Self.runGit(["clone", "-q", "--branch", "main", "--single-branch", remote.path, localURL.path], in: root)
        try Self.runGit(["config", "user.name", "Branch Radar Tests"], in: localURL)
        try Self.runGit(["config", "user.email", "tests@branch-radar.invalid"], in: localURL)
        try Self.runGit(["switch", "-q", "-c", "mine"], in: localURL)
        try "mine\n".write(to: localURL.appendingPathComponent("mine.txt"), atomically: true, encoding: .utf8)
        try Self.runGit(["add", "-A"], in: localURL)
        try Self.runGit(["commit", "-q", "-m", "mine"], in: localURL)

        try Self.runGit(["switch", "-q", "-c", "incoming"], in: source)
        try "incoming\n".write(to: source.appendingPathComponent("incoming.txt"), atomically: true, encoding: .utf8)
        try Self.runGit(["add", "-A"], in: source)
        try Self.runGit(["commit", "-q", "-m", "incoming"], in: source)
        incomingCommit = try Self.runGit(["rev-parse", "HEAD"], in: source).trimmed
        try Self.runGit(["push", "-q", "origin", "incoming"], in: source)
        let targetCommit = try Self.runGit(["rev-parse", "origin/main"], in: source).trimmed

        let identity = RepositoryIdentity(projectKey: "TEST", slug: "repo")
        pullRequest = PullRequestSummary(
            id: 50,
            title: "Incoming remote change",
            state: "OPEN",
            source: PullRequestRef(
                id: "refs/heads/incoming",
                displayId: "incoming",
                latestCommit: incomingCommit,
                repository: identity
            ),
            target: PullRequestRef(
                id: "refs/heads/main",
                displayId: "main",
                latestCommit: targetCommit,
                repository: identity
            )
        )
    }

    func localGit(_ arguments: String...) throws -> String {
        try Self.runGit(arguments, in: localURL)
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: root)
    }

    @discardableResult
    private static func runGit(_ arguments: [String], in directory: URL) throws -> String {
        let process = Process()
        let stdout = Pipe()
        let stderr = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git"] + arguments
        process.currentDirectoryURL = directory
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        process.waitUntilExit()
        let output = String(decoding: stdout.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        let error = String(decoding: stderr.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        guard process.terminationStatus == 0 else {
            throw ProjectionTestGitError(message: "git \(arguments.joined(separator: " ")) failed: \(error)")
        }
        return output
    }
}
