import BranchRadarCore
import Foundation

struct CLIOptions {
    enum Command { case check(branch: String), scan, prs, project(branch: String), help, version }
    enum OutputFormat: String { case human, json }
    var command: Command
    var target: String?
    var format: OutputFormat = .human
    var quiet = false
    var projected = false
    var mineOnly = false
    var fetchMissingObjects = true
    var bitbucketURL: String?
    var projectKey: String?
    var repositorySlug: String?
    var username: String?
    var mergeStrategyID: String?
    var remote = "origin"
}

enum CLIParseError: Error, CustomStringConvertible {
    case message(String)
    var description: String { switch self { case .message(let message): return message } }
}

struct CLIParser {
    func parse(_ arguments: [String]) throws -> CLIOptions {
        guard let first = arguments.first else { return CLIOptions(command: .help) }
        if ["help", "--help", "-h"].contains(first) { return CLIOptions(command: .help) }
        if ["version", "--version"].contains(first) { return CLIOptions(command: .version) }
        var index = 1; var options: CLIOptions
        switch first {
        case "check":
            guard arguments.count > 1, !arguments[1].hasPrefix("-") else { throw CLIParseError.message("check requires a branch or ref") }
            options = CLIOptions(command: .check(branch: arguments[1])); index = 2
        case "scan": options = CLIOptions(command: .scan)
        case "prs": options = CLIOptions(command: .prs)
        case "project":
            guard arguments.count > 1, !arguments[1].hasPrefix("-") else { throw CLIParseError.message("project requires a branch or ref") }
            options = CLIOptions(command: .project(branch: arguments[1])); index = 2
        default: throw CLIParseError.message("unknown command '\(first)'")
        }
        while index < arguments.count {
            let argument = arguments[index]
            switch argument {
            case "--target", "-t": index += 1; guard index < arguments.count else { throw CLIParseError.message("\(argument) requires a Git ref") }; options.target = arguments[index]
            case "--format": index += 1; guard index < arguments.count, let format = CLIOptions.OutputFormat(rawValue: arguments[index]) else { throw CLIParseError.message("--format must be 'human' or 'json'") }; options.format = format
            case "--json": options.format = .json
            case "--quiet", "-q": options.quiet = true
            case "--local": break
            case "--projected": options.projected = true
            case "--mine": options.mineOnly = true
            case "--no-fetch": options.fetchMissingObjects = false
            case "--bitbucket-url": index += 1; guard index < arguments.count else { throw CLIParseError.message("--bitbucket-url requires a URL") }; options.bitbucketURL = arguments[index]
            case "--project-key": index += 1; guard index < arguments.count else { throw CLIParseError.message("--project-key requires a value") }; options.projectKey = arguments[index]
            case "--repo": index += 1; guard index < arguments.count else { throw CLIParseError.message("--repo requires a repository slug") }; options.repositorySlug = arguments[index]
            case "--username": index += 1; guard index < arguments.count else { throw CLIParseError.message("--username requires a Bitbucket username") }; options.username = arguments[index]
            case "--merge-strategy": index += 1; guard index < arguments.count else { throw CLIParseError.message("--merge-strategy requires a strategy ID") }; options.mergeStrategyID = arguments[index]
            case "--remote": index += 1; guard index < arguments.count else { throw CLIParseError.message("--remote requires a Git remote name") }; options.remote = arguments[index]
            case "--help", "-h": return CLIOptions(command: .help)
            default: throw CLIParseError.message("unknown option '\(argument)'")
            }
            index += 1
        }
        return options
    }
}
