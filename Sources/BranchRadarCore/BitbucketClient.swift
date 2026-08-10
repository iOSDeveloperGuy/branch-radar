import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public enum ProviderError: Error, CustomStringConvertible, Sendable {
    case invalidConfiguration(String)
    case invalidURL(String)
    case transport(String)
    case requestFailed(status: Int, message: String)
    case malformedResponse(String)

    public var description: String {
        switch self {
        case .invalidConfiguration(let message):
            return message
        case .invalidURL(let value):
            return "Invalid Bitbucket URL: \(value)"
        case .transport(let message):
            return "Bitbucket request failed: \(message)"
        case .requestFailed(let status, let message):
            return "Bitbucket returned HTTP \(status): \(message)"
        case .malformedResponse(let message):
            return "Unexpected Bitbucket response: \(message)"
        }
    }
}

public struct BitbucketConfiguration: Equatable, Sendable {
    public let baseURL: URL
    public let projectKey: String
    public let repositorySlug: String
    public let token: String
    public let username: String?

    public init(
        baseURL: URL,
        projectKey: String,
        repositorySlug: String,
        token: String,
        username: String? = nil
    ) {
        self.baseURL = baseURL
        self.projectKey = projectKey
        self.repositorySlug = repositorySlug
        self.token = token
        self.username = username
    }

    public var repository: RepositoryIdentity {
        RepositoryIdentity(projectKey: projectKey, slug: repositorySlug)
    }
}

public struct HTTPResponse: Sendable {
    public let data: Data
    public let statusCode: Int

    public init(data: Data, statusCode: Int) {
        self.data = data
        self.statusCode = statusCode
    }
}

public protocol HTTPClient: Sendable {
    func send(_ request: URLRequest) async throws -> HTTPResponse
}

public struct URLSessionHTTPClient: HTTPClient, Sendable {
    public init() {}

    public func send(_ request: URLRequest) async throws -> HTTPResponse {
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw ProviderError.malformedResponse("response was not HTTP")
            }
            return HTTPResponse(data: data, statusCode: http.statusCode)
        } catch let error as ProviderError {
            throw error
        } catch {
            throw ProviderError.transport(error.localizedDescription)
        }
    }
}

public struct BitbucketClient: Sendable {
    private let configuration: BitbucketConfiguration
    private let http: any HTTPClient
    private let decoder = JSONDecoder()

    public init(
        configuration: BitbucketConfiguration,
        http: any HTTPClient = URLSessionHTTPClient()
    ) {
        self.configuration = configuration
        self.http = http
    }

    public func openPullRequests(
        targeting targetBranch: String,
        mineOnly: Bool = false
    ) async throws -> [PullRequestSummary] {
        var start = 0
        var results: [PullRequestSummary] = []

        while true {
            let page = try await fetchPage(start: start)
            results.append(contentsOf: page.values.compactMap(mapPullRequest))

            if page.isLastPage { break }
            guard let next = page.nextPageStart, next > start else {
                throw ProviderError.malformedResponse("pagination did not advance")
            }
            start = next
        }

        let normalizedTarget = normalizeBranch(targetBranch)
        return results
            .filter { $0.state.uppercased() == "OPEN" }
            .filter { $0.target.repository == configuration.repository }
            .filter { normalizeBranch($0.target.id) == normalizedTarget }
            .filter { pullRequest in
                guard mineOnly else { return true }
                guard let username = configuration.username else { return false }
                return pullRequest.author?.username.caseInsensitiveCompare(username) == .orderedSame
            }
            .sorted { $0.id < $1.id }
    }

    private func fetchPage(start: Int) async throws -> BitbucketPage<BitbucketPullRequest> {
        let endpoint = configuration.baseURL
            .appendingPathComponent("rest")
            .appendingPathComponent("api")
            .appendingPathComponent("latest")
            .appendingPathComponent("projects")
            .appendingPathComponent(configuration.projectKey)
            .appendingPathComponent("repos")
            .appendingPathComponent(configuration.repositorySlug)
            .appendingPathComponent("pull-requests")

        guard var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false) else {
            throw ProviderError.invalidURL(endpoint.absoluteString)
        }
        components.queryItems = [
            URLQueryItem(name: "state", value: "OPEN"),
            URLQueryItem(name: "limit", value: "100"),
            URLQueryItem(name: "start", value: String(start))
        ]
        guard let url = components.url else {
            throw ProviderError.invalidURL(endpoint.absoluteString)
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(configuration.token)", forHTTPHeaderField: "Authorization")

        let response = try await http.send(request)
        guard (200..<300).contains(response.statusCode) else {
            throw ProviderError.requestFailed(
                status: response.statusCode,
                message: decodeErrorMessage(response.data)
            )
        }

        do {
            return try decoder.decode(BitbucketPage<BitbucketPullRequest>.self, from: response.data)
        } catch {
            throw ProviderError.malformedResponse(error.localizedDescription)
        }
    }

    private func mapPullRequest(_ value: BitbucketPullRequest) -> PullRequestSummary? {
        guard let source = mapRef(value.fromRef), let target = mapRef(value.toRef) else {
            return nil
        }

        let authorUser = value.author?.user
        let author = authorUser.map {
            PullRequestAuthor(
                username: $0.name ?? $0.slug ?? "unknown",
                displayName: $0.displayName ?? $0.name ?? $0.slug ?? "unknown"
            )
        }

        return PullRequestSummary(
            id: value.id,
            title: value.title,
            state: value.state,
            source: source,
            target: target,
            author: author
        )
    }

    private func mapRef(_ value: BitbucketRef) -> PullRequestRef? {
        guard let projectKey = value.repository.project?.key else { return nil }
        return PullRequestRef(
            id: value.id,
            displayId: value.displayId,
            latestCommit: value.latestCommit,
            repository: RepositoryIdentity(projectKey: projectKey, slug: value.repository.slug)
        )
    }

    private func decodeErrorMessage(_ data: Data) -> String {
        if let envelope = try? decoder.decode(BitbucketErrorEnvelope.self, from: data),
           let message = envelope.errors.first?.message,
           !message.isEmpty {
            return message
        }
        let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? "request failed" : text
    }

    private func normalizeBranch(_ value: String) -> String {
        if value.hasPrefix("refs/heads/") {
            return String(value.dropFirst("refs/heads/".count))
        }
        if value.hasPrefix("refs/remotes/") {
            let rest = String(value.dropFirst("refs/remotes/".count))
            return rest.split(separator: "/", maxSplits: 1).last.map(String.init) ?? rest
        }
        if value.hasPrefix("origin/") {
            return String(value.dropFirst("origin/".count))
        }
        return value
    }
}

private struct BitbucketPage<Value: Decodable>: Decodable {
    let values: [Value]
    let isLastPage: Bool
    let nextPageStart: Int?
}

private struct BitbucketPullRequest: Decodable {
    let id: Int
    let title: String
    let state: String
    let fromRef: BitbucketRef
    let toRef: BitbucketRef
    let author: BitbucketParticipant?
}

private struct BitbucketRef: Decodable {
    let id: String
    let displayId: String
    let latestCommit: String
    let repository: BitbucketRepository
}

private struct BitbucketRepository: Decodable {
    let slug: String
    let project: BitbucketProject?
}

private struct BitbucketProject: Decodable {
    let key: String
}

private struct BitbucketParticipant: Decodable {
    let user: BitbucketUser
}

private struct BitbucketUser: Decodable {
    let name: String?
    let slug: String?
    let displayName: String?
}

private struct BitbucketErrorEnvelope: Decodable {
    let errors: [BitbucketError]
}

private struct BitbucketError: Decodable {
    let message: String?
}
