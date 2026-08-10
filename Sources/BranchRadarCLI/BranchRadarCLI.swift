import BranchRadarCore
import Foundation

private let version = "0.3.0"

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
        let parser = CLIParser()

        do {
            let options = try parser.parse(arguments)

            switch options.command {
            case .help:
                printHelp()
                exit(ExitCode.clean.rawValue)
            case .version:
                print("branch-radar \(version)")
                exit(ExitCode.clean.rawValue)
            case .check, .scan, .prs, .project:
                let code = try await run(options)
                exit(code.rawValue)
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
            if !options.quiet {
                switch options.format {
                case .human: print(human.render(analysis))
                case .json: print(try json.render(analysis))
                }
            }
            return analysis.status == .conflict ? .conflicts : .clean

        case .scan where !options.projected:
            let report = try repository.scanLocalBranches(against: target)
            if !options.quiet {
                switch options.format {
                case .human: print(human.render(report))
                case .json: print(try json.render(report))
                }
            }
            return report.hasConflicts ? .conflicts : .clean

        case .prs:
            let pullRequests = try await loadPullRequests(options: options, repository: repository, target: target)
            let report = PullRequestReport(target: target, pullRequests: pullRequests)
            if !options.quiet {
                switch options.format {
                case .human: print(human.render(report))
                case .json: print(try json.render(report))
                }
            }
            return .clean

        case .project(let branch):
            let pullRequests = try await loadPullRequests(options: options, repository: repository, target: target)
            let report = try repository.project(
                branch: branch,
                against: target,
                after: pullRequests,
                remote: options.remote,
                fetchMissingObjects: options.fetchMissingObjects
            )
            if !options.quiet {
                switch options.format {
                case .human: print(human.render(report))
                case .json: print(try json.render(report))
                }
            }
            return report.hasConflicts ? .conflicts : .clean

        case .scan:
            let pullRequests = try await loadPullRequests(options: options, repository: repository, target: target)
            let report = try repository.projectLocalBranches(
                against: target,
                after: pullRequests,
                remote: options.remote,
                fetchMissingObjects: options.fetchMissingObjects
            )
            if !options.quiet {
                switch options.format {
                case .human: print(human.render(report))
                case .json: print(try json.render(report))
                }
            }
            return report.hasConflicts ? .conflicts : .clean

        case .help, .version:
            return .clean
        }
    }

    private static func loadPullRequests(
        options: CLIOptions,
        repository: GitRepository,
        target: String
    ) async throws -> [PullRequestSummary] {
        let configuration = try BitbucketConfigurationResolver().resolve(options: options, repository: repository)
        let client = BitbucketClient(configuration: configuration)
        return try await client.openPullRequests(
            targeting: normalizedBranch(target),
            mineOnly: options.mineOnly
        )
    }

    private static func normalizedBranch(_ target: String) -> String {
        if target.hasPrefix("refs/heads/") {
            return String(target.dropFirst("refs/heads/".count))
        }
        if target.hasPrefix("refs/remotes/") {
            let rest = String(target.dropFirst("refs/remotes/".count))
            return rest.split(separator: "/", maxSplits: 1).last.map(String.init) ?? rest
        }
        if target.hasPrefix("origin/") {
            return String(target.dropFirst("origin/".count))
        }
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
        Find merge conflicts before they surprise you.

        USAGE
          branch-radar check <branch> [options]
          branch-radar scan [--local] [--projected] [options]
          branch-radar prs [--mine] [options]
          branch-radar project <branch> [--mine] [options]

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

          Optional environment defaults:
            BRANCH_RADAR_BITBUCKET_URL
            BRANCH_RADAR_BITBUCKET_PROJECT
            BRANCH_RADAR_BITBUCKET_REPO
            BRANCH_RADAR_BITBUCKET_USERNAME

        OUTPUT OPTIONS
              --format <format>   human (default) or json
              --json              Alias for --format json
          -q, --quiet             Print nothing; communicate through the exit code only
          -h, --help              Show help
              --version           Show version

        EXIT CODES
          0  Analysis completed with no current/projected conflicts
          1  Current or projected conflicts were found
          2  Git or repository error
          3  Bitbucket/provider error
          4  Invalid arguments or configuration

        EXAMPLES
          branch-radar check HEAD --target origin/develop
          branch-radar prs --target origin/develop
          branch-radar project feature/my-change --target origin/develop
          branch-radar scan --projected --target origin/develop --json
        """)
    }
}
