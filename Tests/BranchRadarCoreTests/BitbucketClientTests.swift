import BranchRadarCore
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing

struct BitbucketClientTests {
    @Test func filtersByTargetRepositoryAndAuthor() async throws {
        let payload = """
        {"values":[
          {"id":10,"title":"Targeted PR","state":"OPEN","fromRef":{"id":"refs/heads/feature/a","displayId":"feature/a","latestCommit":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","repository":{"slug":"sample-service","project":{"key":"DEMO"}}},"toRef":{"id":"refs/heads/develop","displayId":"develop","latestCommit":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","repository":{"slug":"sample-service","project":{"key":"DEMO"}}},"author":{"user":{"name":"alice","slug":"alice","displayName":"Alice Example"}}},
          {"id":11,"title":"Wrong target","state":"OPEN","fromRef":{"id":"refs/heads/feature/b","displayId":"feature/b","latestCommit":"cccccccccccccccccccccccccccccccccccccccc","repository":{"slug":"sample-service","project":{"key":"DEMO"}}},"toRef":{"id":"refs/heads/main","displayId":"main","latestCommit":"dddddddddddddddddddddddddddddddddddddddd","repository":{"slug":"sample-service","project":{"key":"DEMO"}}},"author":{"user":{"name":"alice","slug":"alice","displayName":"Alice Example"}}},
          {"id":12,"title":"Other author","state":"OPEN","fromRef":{"id":"refs/heads/feature/c","displayId":"feature/c","latestCommit":"eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee","repository":{"slug":"sample-service","project":{"key":"DEMO"}}},"toRef":{"id":"refs/heads/develop","displayId":"develop","latestCommit":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","repository":{"slug":"sample-service","project":{"key":"DEMO"}}},"author":{"user":{"name":"bob","slug":"bob","displayName":"Bob Example"}}}
        ],"isLastPage":true,"limit":100,"size":3,"start":0}
        """
        let config = BitbucketConfiguration(baseURL: URL(string: "https://bitbucket.example.com")!, projectKey: "DEMO", repositorySlug: "sample-service", token: "secret", username: "alice")
        let client = BitbucketClient(configuration: config, http: StaticHTTP(response: HTTPResponse(data: Data(payload.utf8), statusCode: 200)))
        #expect(try await client.openPullRequests(targeting: "develop").map(\.id) == [10, 12])
        #expect(try await client.openPullRequests(targeting: "origin/develop", mineOnly: true).map(\.id) == [10])
    }

    @Test func readsEffectiveMergeStrategyConfiguration() async throws {
        let payload = """
        {
          "mergeConfig": {
            "defaultStrategy": {"id":"squash","name":"Squash","flag":"--squash","enabled":true},
            "strategies": [
              {"id":"no-ff","name":"Merge commit","flag":"--no-ff","enabled":true},
              {"id":"squash","name":"Squash","flag":"--squash","enabled":true},
              {"id":"rebase-ff-only","name":"Rebase, fast-forward","flag":"--ff-only","enabled":true},
              {"id":"ff-only","name":"Fast-forward only","flag":"--ff-only","enabled":false}
            ]
          }
        }
        """
        let config = BitbucketConfiguration(baseURL: URL(string: "https://bitbucket.example.com")!, projectKey: "DEMO", repositorySlug: "sample-service", token: "secret")
        let client = BitbucketClient(configuration: config, http: StaticHTTP(response: HTTPResponse(data: Data(payload.utf8), statusCode: 200)))
        let strategies = try await client.mergeStrategyConfiguration()
        #expect(strategies.defaultStrategy.id == "squash")
        #expect(strategies.defaultStrategy.kind == .squash)
        #expect(strategies.strategies.map(\.id) == ["no-ff", "squash", "rebase-ff-only"])
        #expect(strategies.strategies.last?.kind == .rebaseFastForward)
    }

    @Test func readsAutoMergeStrategyAndTreatsMissingRequestAsNil() async throws {
        let config = BitbucketConfiguration(baseURL: URL(string: "https://bitbucket.example.com")!, projectKey: "DEMO", repositorySlug: "sample-service", token: "secret")
        let selected = BitbucketClient(
            configuration: config,
            http: StaticHTTP(response: HTTPResponse(data: Data(#"{"strategyId":"rebase-ff-only"}"#.utf8), statusCode: 200))
        )
        #expect(try await selected.autoMergeStrategyID(pullRequestID: 42) == "rebase-ff-only")

        let missing = BitbucketClient(
            configuration: config,
            http: StaticHTTP(response: HTTPResponse(data: Data(), statusCode: 404))
        )
        #expect(try await missing.autoMergeStrategyID(pullRequestID: 42) == nil)
    }

}

private struct StaticHTTP: HTTPClient, Sendable {
    let response: HTTPResponse
    func send(_ request: URLRequest) async throws -> HTTPResponse {
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer secret")
        return response
    }
}
