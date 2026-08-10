import BranchRadarCore
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing

struct BitbucketClientTests {
    @Test
    func filtersOpenPRsByTargetRepositoryBranchAndAuthor() async throws {
        let payload = """
        {
          "values": [
            {
              "id": 10,
              "title": "Targeted PR",
              "state": "OPEN",
              "fromRef": {
                "id": "refs/heads/feature/one",
                "displayId": "feature/one",
                "latestCommit": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
                "repository": { "slug": "sample-service", "project": { "key": "DEMO" } }
              },
              "toRef": {
                "id": "refs/heads/develop",
                "displayId": "develop",
                "latestCommit": "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
                "repository": { "slug": "sample-service", "project": { "key": "DEMO" } }
              },
              "author": {
                "user": { "name": "alice", "slug": "alice", "displayName": "Alice Example" }
              }
            },
            {
              "id": 11,
              "title": "Wrong target",
              "state": "OPEN",
              "fromRef": {
                "id": "refs/heads/feature/two",
                "displayId": "feature/two",
                "latestCommit": "cccccccccccccccccccccccccccccccccccccccc",
                "repository": { "slug": "sample-service", "project": { "key": "DEMO" } }
              },
              "toRef": {
                "id": "refs/heads/main",
                "displayId": "main",
                "latestCommit": "dddddddddddddddddddddddddddddddddddddddd",
                "repository": { "slug": "sample-service", "project": { "key": "DEMO" } }
              },
              "author": {
                "user": { "name": "alice", "slug": "alice", "displayName": "Alice Example" }
              }
            },
            {
              "id": 12,
              "title": "Other author",
              "state": "OPEN",
              "fromRef": {
                "id": "refs/heads/feature/three",
                "displayId": "feature/three",
                "latestCommit": "eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee",
                "repository": { "slug": "sample-service", "project": { "key": "DEMO" } }
              },
              "toRef": {
                "id": "refs/heads/develop",
                "displayId": "develop",
                "latestCommit": "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
                "repository": { "slug": "sample-service", "project": { "key": "DEMO" } }
              },
              "author": {
                "user": { "name": "bob", "slug": "bob", "displayName": "Bob Example" }
              }
            }
          ],
          "isLastPage": true,
          "limit": 100,
          "size": 3,
          "start": 0
        }
        """

        let config = BitbucketConfiguration(
            baseURL: URL(string: "https://bitbucket.example.com")!,
            projectKey: "DEMO",
            repositorySlug: "sample-service",
            token: "secret",
            username: "alice"
        )
        let client = BitbucketClient(
            configuration: config,
            http: StaticHTTPClient(response: HTTPResponse(data: Data(payload.utf8), statusCode: 200))
        )

        let all = try await client.openPullRequests(targeting: "develop")
        #expect(all.map(\.id) == [10, 12])

        let mine = try await client.openPullRequests(targeting: "origin/develop", mineOnly: true)
        #expect(mine.map(\.id) == [10])
        #expect(mine[0].source.branchName == "feature/one")
    }

    @Test
    func reportsBitbucketErrorMessage() async throws {
        let body = #"{"errors":[{"message":"Token rejected"}]}"#
        let config = BitbucketConfiguration(
            baseURL: URL(string: "https://bitbucket.example.com")!,
            projectKey: "DEMO",
            repositorySlug: "sample-service",
            token: "bad"
        )
        let client = BitbucketClient(
            configuration: config,
            http: StaticHTTPClient(response: HTTPResponse(data: Data(body.utf8), statusCode: 401))
        )

        do {
            _ = try await client.openPullRequests(targeting: "develop")
            Issue.record("Expected provider error")
        } catch let error as ProviderError {
            #expect(error.description.contains("Token rejected"))
            #expect(error.description.contains("401"))
        }
    }
}

private struct StaticHTTPClient: HTTPClient, Sendable {
    let response: HTTPResponse

    func send(_ request: URLRequest) async throws -> HTTPResponse {
        #expect(request.value(forHTTPHeaderField: "Authorization")?.hasPrefix("Bearer ") == true)
        return response
    }
}
