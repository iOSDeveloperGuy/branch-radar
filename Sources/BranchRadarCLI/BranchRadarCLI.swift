import BranchRadarCore
import Foundation

private let version = "0.5.0"

private enum ExitCode: Int32 {
    case clean = 0
    case conflicts = 1
    case gitOrRepositoryError = 2
    case providerError = 3
    case configurationError = 4
}

@main
struct BranchRadarCLI {
    static func main() async {
        let arguments = Array(CommandLine.arguments.dropFirst())
        do {
            let options = try CLIParser().parse(arguments)
            switch options.command {
            case .help:
                printHelp()
                exit(ExitCode.clean.rawValue)
            case .version:
                print("branch-radar \(version)")
                exit(ExitCode.clean.rawValue)
            case .check, .scan, .prs, .project:
                exit(try await run(options).rawValue)
            }
        } catch let error as CLIParseError {
            writeError(error.description, code: "invalid_arguments", json: wantsJSON(arguments))
            exit(ExitCode.configurationError.rawValue)
        } catch let error as ProviderError {
            writeError(error.description, code: "provider_error", json: wantsJSON(arguments))
            exit(ExitCode.providerError.rawValue)
        } catch let error as RepositoryError {
            writeError(error.description, code: "git_repository_error", json: wantsJSON(arguments))
            exit(ExitCode.gitOrRepositoryError.rawValue)
        } catch {
            writeError(error.localizedDescription, code: "unexpected_error", json: wantsJSON(arguments))
            exit(ExitCode.gitOrRepositoryError.rawValue)
        }
    }

    private static func run(_ options: CLIOptions) async throws -> ExitCode {
        let repository = try GitRepository(at: URL(fileURLWithPath: FileManager.default.currentDirectoryPath))
        let target = try repository.resolveTarget(explicit: options.target)
        let human = HumanRenderer()
        let json = JSONRenderer()

        switch options.command {
        case .check(let branch):
            let analysis = try repository.analyze(branch: branch, against: target)
            if !options.quiet { print(options.format == .human ? human.render(analysis) : try json.render(analysis)) }
            return analysis.status == .conflict ? .conflicts : .clean

        case .scan where !options.projected:
            let report = try repository.scanLocalBranches(against: target)
            if !options.quiet { print(options.format == .human ? human.render(report) : try json.render(report)) }
            return report.hasConflicts ? .conflicts : .clean

        case .prs:
            let configuration = try BitbucketConfigurationResolver().resolve(options: options, repository: repository)
            let prs = try await BitbucketClient(configuration: configuration)
                .openPullRequests(targeting: normalizedBranch(target), mineOnly: options.mineOnly)
            let report = PullRequestReport(target: target, pullRequests: prs)
            if !options.quiet { print(options.format == .human ? human.render(report) : try json.render(report)) }
            return .clean

        case .project(let branch):
            let inputs = try await loadProjectionInputs(options: options, repository: repository, target: target)
            let report = try repository.project(
                branch: branch,
                against: target,
                after: inputs.pullRequests,
                mergeStrategies: inputs.mergeStrategies,
                remote: options.remote,
                fetchMissingObjects: options.fetchMissingObjects
            )
            if !options.quiet { print(options.format == .human ? human.render(report) : try json.render(report)) }
            return report.hasConflicts ? .conflicts : .clean

        case .scan:
            let inputs = try await loadProjectionInputs(options: options, repository: repository, target: target)
            let report = try repository.projectLocalBranches(
                against: target,
                after: inputs.pullRequests,
                mergeStrategies: inputs.mergeStrategies,
                remote: options.remote,
                fetchMissingObjects: options.fetchMissingObjects
            )
            if !options.quiet { print(options.format == .human ? human.render(report) : try json.render(report)) }
            return report.hasConflicts ? .conflicts : .clean

        case .help, .version:
            return .clean
        }
    }

    private struct ProjectionInputs {
        let pullRequests: [PullRequestSummary]
        let mergeStrategies: [Int: MergeStrategySelection]
    }

    private static func loadProjectionInputs(
        options: CLIOptions,
        repository: GitRepository,
        target: String
    ) async throws -> ProjectionInputs {
        let configuration = try BitbucketConfigurationResolver().resolve(options: options, repository: repository)
        let client = BitbucketClient(configuration: configuration)
        let pullRequests = try await client.openPullRequests(
            targeting: normalizedBranch(target),
            mineOnly: options.mineOnly
        )
        guard !pullRequests.isEmpty else {
            return ProjectionInputs(pullRequests: [], mergeStrategies: [:])
        }

        let mergeConfig = try await client.mergeStrategyConfiguration()
        let enabledByID = Dictionary(uniqueKeysWithValues: mergeConfig.strategies.map { ($0.id, $0) })
        var selections: [Int: MergeStrategySelection] = [:]

        if let overrideID = options.mergeStrategyID {
            guard let strategy = enabledByID[overrideID] else {
                let enabled = mergeConfig.strategies.map(\.id).sorted().joined(separator: ", ")
                throw ProviderError.invalidConfiguration(
                    "Merge strategy '\(overrideID)' is not enabled for this repository. Enabled strategies: \(enabled)."
                )
            }
            for pullRequest in pullRequests {
                selections[pullRequest.id] = MergeStrategySelection(strategy: strategy, source: .commandLine)
            }
            return ProjectionInputs(pullRequests: pullRequests, mergeStrategies: selections)
        }

        let alternatives = mergeConfig.strategies
            .map(\.id)
            .filter { $0 != mergeConfig.defaultStrategy.id }
            .sorted()

        for pullRequest in pullRequests {
            if let autoMergeStrategyID = try await client.autoMergeStrategyID(pullRequestID: pullRequest.id) {
                let strategy = enabledByID[autoMergeStrategyID] ?? MergeStrategy(id: autoMergeStrategyID)
                selections[pullRequest.id] = MergeStrategySelection(strategy: strategy, source: .autoMerge)
            } else {
                selections[pullRequest.id] = MergeStrategySelection(
                    strategy: mergeConfig.defaultStrategy,
                    source: .repositoryDefault,
                    alternativeStrategyIDs: alternatives
                )
            }
        }

        return ProjectionInputs(pullRequests: pullRequests, mergeStrategies: selections)
    }

    private static func normalizedBranch(_ target: String) -> String {
        if target.hasPrefix("refs/heads/") { return String(target.dropFirst("refs/heads/".count)) }
        if target.hasPrefix("refs/remotes/") {
            let rest = String(target.dropFirst("refs/remotes/".count))
            return rest.split(separator: "/", maxSplits: 1).last.map(String.init) ?? rest
        }
        if target.hasPrefix("origin/") { return String(target.dropFirst("origin/".count)) }
        return target
    }

    private static func writeError(_ message: String, code: String, json: Bool) {
        if json, let rendered = try? JSONRenderer().render(ErrorPayload(code: code, message: message)) {
            FileHandle.standardError.write(Data((rendered + "\n").utf8))
        } else {
            FileHandle.standardError.write(Data(("branch-radar: \(message)\n").utf8))
        }
    }

    private static func wantsJSON(_ arguments: [String]) -> Bool {
        arguments.contains("--json") || arguments.contains("json")
    }

    private static func printHelp() {
        print("""
        branch-radar \(version)
        Find merge conflicts and collision risk before they surprise you.

        USAGE
          branch-radar check <branch> [options]
          branch-radar scan [--local] [--projected] [options]
          branch-radar prs [--mine] [options]
          branch-radar project <branch> [--mine] [options]

        MERGE-STRATEGY-AWARE PROJECTION
          Projected analysis reads Bitbucket's effective repository merge settings.
          Auto-merge PRs use their selected strategy when Bitbucket reports one.
          Manual PRs use the repository default and are labeled as assumptions when
          multiple strategies are enabled.

          --merge-strategy <id>   Explicitly model one enabled strategy for all PRs.

        Supported Bitbucket strategy families:
          merge commit, fast-forward, fast-forward only,
          rebase + merge, rebase + fast-forward,
          squash, squash + fast-forward only

        PROJECTED ANALYSIS
          ✗ conflict   Git proves the future merge fails
          ◐ risk       Git merges cleanly, but both changes overlap
          ⊘ rejected   The selected merge strategy cannot land that PR
          ✓ clean      No conflict or overlap evidence found

        Risk and strategy rejection never change the process exit code. Exit 1 remains
        reserved for proven current/projected conflicts.

        ANALYSIS OPTIONS
          -t, --target <ref>      Target branch/ref. Auto-detects origin/HEAD, main, or master.
              --projected         With scan, test each local branch after each open PR lands.
              --mine              Only use PRs authored by the configured Bitbucket username.
              --no-fetch          Do not fetch missing PR commit objects from the Git remote.
              --remote <name>     Git remote used for object fetches (default: origin).

        BITBUCKET OPTIONS
              --bitbucket-url <url>  Bitbucket Data Center base URL.
              --project-key <key>    Bitbucket project key. Often inferred from origin.
              --repo <slug>          Bitbucket repository slug. Often inferred from origin.
              --username <name>      Bitbucket username, required with --mine.

        AUTHENTICATION
          Set BRANCH_RADAR_BITBUCKET_TOKEN (or BITBUCKET_TOKEN). Tokens are never accepted
          as command-line arguments so they do not leak into shell history/process listings.

        OUTPUT OPTIONS
              --format <format>   human (default) or json
              --json              Alias for --format json
          -q, --quiet             Print nothing; communicate through the exit code only
          -h, --help              Show help
              --version           Show version

        EXIT CODES
          0  Analysis completed with no proven current/projected conflicts
          1  Current or projected conflicts were found
          2  Git or repository error
          3  Bitbucket/provider error
          4  Invalid arguments or configuration

        EXAMPLES
          branch-radar project feature/my-change --target origin/develop
          branch-radar project feature/my-change --merge-strategy squash --target origin/develop
          branch-radar scan --projected --target origin/develop --json
        """)
    }
}
