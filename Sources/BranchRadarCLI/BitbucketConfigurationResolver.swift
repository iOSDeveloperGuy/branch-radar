import BranchRadarCore
import Foundation

struct BitbucketConfigurationResolver {
    func resolve(options: CLIOptions, repository: GitRepository) throws -> BitbucketConfiguration {
        let environment = ProcessInfo.processInfo.environment
        let remoteURL = try repository.remoteURL(options.remote)
        let inferred = remoteURL.flatMap(inferRepository(from:))

        let urlString = options.bitbucketURL
            ?? environment["BRANCH_RADAR_BITBUCKET_URL"]
            ?? inferred?.baseURL
        guard let urlString, let baseURL = URL(string: urlString), baseURL.scheme != nil else {
            throw ProviderError.invalidConfiguration(
                "Bitbucket URL is required. Pass --bitbucket-url or set BRANCH_RADAR_BITBUCKET_URL."
            )
        }

        let projectKey = options.projectKey
            ?? environment["BRANCH_RADAR_BITBUCKET_PROJECT"]
            ?? inferred?.projectKey
        guard let projectKey, !projectKey.isEmpty else {
            throw ProviderError.invalidConfiguration(
                "Bitbucket project key is required. Pass --project-key or set BRANCH_RADAR_BITBUCKET_PROJECT."
            )
        }

        let repositorySlug = options.repositorySlug
            ?? environment["BRANCH_RADAR_BITBUCKET_REPO"]
            ?? inferred?.repositorySlug
        guard let repositorySlug, !repositorySlug.isEmpty else {
            throw ProviderError.invalidConfiguration(
                "Bitbucket repository slug is required. Pass --repo or set BRANCH_RADAR_BITBUCKET_REPO."
            )
        }

        let token = environment["BRANCH_RADAR_BITBUCKET_TOKEN"] ?? environment["BITBUCKET_TOKEN"]
        guard let token, !token.isEmpty else {
            throw ProviderError.invalidConfiguration(
                "Bitbucket token is required. Set BRANCH_RADAR_BITBUCKET_TOKEN (or BITBUCKET_TOKEN)."
            )
        }

        let username = options.username ?? environment["BRANCH_RADAR_BITBUCKET_USERNAME"]
        if options.mineOnly, username == nil {
            throw ProviderError.invalidConfiguration(
                "--mine requires --username or BRANCH_RADAR_BITBUCKET_USERNAME."
            )
        }

        return BitbucketConfiguration(
            baseURL: baseURL,
            projectKey: projectKey,
            repositorySlug: repositorySlug,
            token: token,
            username: username
        )
    }

    private func inferRepository(from remote: String) -> InferredRepository? {
        if let url = URL(string: remote), let scheme = url.scheme, let host = url.host {
            let pieces = url.path.split(separator: "/").map(String.init)
            guard pieces.count >= 2 else { return nil }

            var projectIndex = 0
            var basePathPieces: [String] = []
            if let scmIndex = pieces.firstIndex(where: { $0.caseInsensitiveCompare("scm") == .orderedSame }),
               scmIndex + 2 < pieces.count {
                projectIndex = scmIndex + 1
                basePathPieces = Array(pieces[..<scmIndex])
            } else {
                projectIndex = pieces.count - 2
                basePathPieces = Array(pieces[..<projectIndex])
            }

            guard projectIndex + 1 < pieces.count else { return nil }
            let project = pieces[projectIndex]
            let repo = stripGitSuffix(pieces[projectIndex + 1])

            let baseURL: String?
            if scheme == "http" || scheme == "https" {
                var components = URLComponents()
                components.scheme = scheme
                components.host = host
                components.port = url.port
                components.path = basePathPieces.isEmpty ? "" : "/" + basePathPieces.joined(separator: "/")
                baseURL = components.url?.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            } else {
                baseURL = nil
            }
            return InferredRepository(
                baseURL: baseURL,
                projectKey: project,
                repositorySlug: repo
            )
        }

        // SCP-style SSH remote: git@host:PROJECT/repo.git. Project/repo can be
        // inferred, but the HTTP base URL cannot safely be guessed.
        if let colon = remote.lastIndex(of: ":"), remote[..<colon].contains("@") {
            let path = remote[remote.index(after: colon)...]
            let pieces = path.split(separator: "/").map(String.init)
            guard pieces.count >= 2 else { return nil }
            return InferredRepository(
                baseURL: nil,
                projectKey: pieces[pieces.count - 2],
                repositorySlug: stripGitSuffix(pieces.last!)
            )
        }

        return nil
    }

    private func stripGitSuffix(_ value: String) -> String {
        value.hasSuffix(".git") ? String(value.dropLast(4)) : value
    }

    private struct InferredRepository {
        let baseURL: String?
        let projectKey: String
        let repositorySlug: String
    }
}
