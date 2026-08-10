# branch-radar

Find merge conflicts before they surprise you.

`branch-radar` is a Swift CLI that asks Git whether your branches merge cleanly now and, with Bitbucket Data Center, whether they would still merge after another open pull request lands first.

The core rule is simple: **Bitbucket tells branch-radar what may land; Git decides whether it conflicts.** Mergeability is calculated with Git's own three-way merge machinery through `git merge-tree`, not a home-grown conflict heuristic.

## Status

**v0.3** includes:

- check one branch/ref against a target
- scan all local branches
- real Git three-way merge simulation
- conflict paths and conflict-type classification
- ahead/behind counts
- Bitbucket Data Center open-PR discovery
- filter PRs to the configured repository and target branch
- optional `--mine` author filtering
- projected conflict analysis: "what if PR #N lands before my branch?"
- stable JSON output for agents and scripts
- deterministic exit codes
- no worktree, index, or branch-ref mutation

## Requirements

- Swift 6+
- Git with `git merge-tree --write-tree` support
- macOS or Linux
- Bitbucket Data Center access token for PR discovery/projection commands

## Build

```bash
swift build -c release
```

The binary will be at:

```bash
.build/release/branch-radar
```

For local development:

```bash
swift run branch-radar --help
```

Install to `~/.local/bin`:

```bash
make install
```

Or choose another prefix:

```bash
make install PREFIX=/usr/local
```

## Local conflict analysis

Check one branch against a target:

```bash
branch-radar check HEAD --target origin/develop
branch-radar check feature/my-change --target origin/develop
```

Scan local branches:

```bash
branch-radar scan --local --target origin/develop
```

If `--target` is omitted, branch-radar tries, in order:

1. `origin/HEAD`
2. `origin/main`
3. `origin/master`
4. `main`
5. `master`

For repositories whose integration branch is `develop`, pass it explicitly unless `origin/HEAD` already points there.

## Bitbucket Data Center setup

Authentication is intentionally environment-only so access tokens do not appear in shell history or process listings.

```bash
export BRANCH_RADAR_BITBUCKET_TOKEN='...'
```

`BITBUCKET_TOKEN` is also accepted as a fallback.

Configure the Bitbucket base URL:

```bash
export BRANCH_RADAR_BITBUCKET_URL='https://bitbucket.example.com'
```

Project key and repository slug are inferred from common Git remotes when possible, including HTTPS remotes such as:

```text
https://bitbucket.example.com/scm/DEMO/sample-service.git
```

You can set them explicitly when needed:

```bash
export BRANCH_RADAR_BITBUCKET_PROJECT='DEMO'
export BRANCH_RADAR_BITBUCKET_REPO='sample-service'
```

For SSH remotes, branch-radar can often infer the project/repository, but it deliberately does **not** guess the HTTP Bitbucket base URL.

To use `--mine`, also configure your Bitbucket username:

```bash
export BRANCH_RADAR_BITBUCKET_USERNAME='alice'
```

Equivalent non-secret values may be passed on the command line:

```bash
branch-radar prs \
  --bitbucket-url https://bitbucket.example.com \
  --project-key DEMO \
  --repo sample-service \
  --target origin/develop
```

## Discover open PRs

List open PRs targeting the selected branch:

```bash
branch-radar prs --target origin/develop
```

Only your PRs:

```bash
branch-radar prs --mine --target origin/develop
```

Example output:

```text
Branch Radar PRs
Target: origin/develop

#42 Validate request handling by Alice Example
  feature/request-validation → develop
  source: 919ee3e447

#43 Background sync cleanup by Bob Example
  feature/sync-cleanup → develop
  source: 3dbfe40cba

Summary: 2 open PRs
```

## Project future conflicts

Check one branch against every relevant open PR:

```bash
branch-radar project feature/my-change --target origin/develop
```

Example:

```text
Branch Radar Projection
Branch: feature/my-change
Target: origin/develop

Current: ✓ clean

✗ after PR #42: Validate request handling
  feature/request-validation → develop
  ! Sources/App/Service.swift [content]
✓ after PR #43: Background sync cleanup
  feature/sync-cleanup → develop

Summary: 2 scenarios, 1 projected conflicts
```

Scan every local branch:

```bash
branch-radar scan --projected --target origin/develop
```

The projection algorithm is:

1. Read the PR source and target commit SHAs from Bitbucket.
2. Ensure those Git objects exist locally.
3. Ask `git merge-tree` to merge the incoming PR into its current target.
4. If that merge is clean, create an **unreferenced synthetic merge commit** with `git commit-tree`.
5. Ask `git merge-tree` whether your branch merges cleanly into that synthetic target.
6. Report a conflict only when Git itself reports one.

### Projection assumptions

v0.3 models the PR landing as a normal Git merge commit. Repositories using squash-only or rebase-only merge strategies can produce a different future history, so projected results should be interpreted with that limitation.

Cross-repository/fork PR projection is reported as `unavailable` in v0.3. PR discovery still works, but branch-radar does not yet fetch Git objects from a second repository automatically.

## Fetch safety

Projection may need commit objects that your local clone has not fetched yet. By default branch-radar uses:

```bash
git fetch --no-tags --no-write-fetch-head <remote> refs/heads/<source>
```

This brings the required objects into Git's object database without updating local branches, remote-tracking branches, or `FETCH_HEAD`. This behavior is covered by an integration test.

Disable object fetching entirely with:

```bash
branch-radar project feature/my-change --no-fetch --target origin/develop
```

A scenario whose commit is unavailable will then be reported as `unavailable` rather than modifying refs.

## Agent / JSON interface

All major commands support structured JSON:

```bash
branch-radar scan --projected --target origin/develop --json
```

Example projected result:

```json
{
  "branch": "feature/my-change",
  "current": {
    "ahead": 3,
    "behind": 8,
    "branch": "feature/my-change",
    "conflicts": [],
    "status": "clean",
    "target": "origin/develop"
  },
  "projections": [
    {
      "conflicts": [
        {
          "kind": "content",
          "path": "Sources/App/Service.swift"
        }
      ],
      "outcome": "conflict",
      "pullRequest": {
        "id": 42,
        "title": "Validate request handling"
      }
    }
  ],
  "schemaVersion": 1,
  "target": "origin/develop"
}
```

The full emitted PR object also includes source/target refs, repository identity, commit SHAs, state, and author when Bitbucket supplies it.

## Exit codes

| Code | Meaning |
| ---: | --- |
| `0` | Analysis completed and no current/projected branch conflicts were found |
| `1` | A current or projected branch conflict was found |
| `2` | Git/repository error |
| `3` | Bitbucket/provider error |
| `4` | Invalid arguments/configuration |

For scripts or agents that only care about status:

```bash
branch-radar project HEAD --target origin/develop --quiet
```

An incoming PR that already conflicts with its target is labeled `incoming_conflict`. That does **not** cause exit code `1` by itself because branch-radar has not proven that your branch will conflict after that PR lands.

## What "conflict" means

A conflict means Git itself could not produce a clean three-way merge for the refs in that scenario. `branch-radar` does not claim that two branches conflict merely because they edit the same file.

A future release can add a separate **collision risk** state for overlapping edits that still merge cleanly.

## Safety

The analysis commands do not:

- checkout or switch branches
- rebase
- merge into your branch
- modify the index
- modify tracked files
- update local or remote-tracking branch refs
- push anything

`git merge-tree`, `git commit-tree`, and projection fetches may create unreachable Git objects in the repository object database. That is deliberate and does not move refs or change the worktree.

## Roadmap

### v0.4: collision risk and recommendations

- shared-file / overlapping-hunk analysis
- distinguish `clean`, `risk`, and `conflict`
- deterministic "rebase now" / "finish before PR #..." recommendations
- highlight stale local targets versus Bitbucket's target SHA

### v0.5: broader provider / agent integration

- GitHub/GitLab providers
- cross-repository PR projections
- merge-strategy-aware projection (merge/squash/rebase)
- optional MCP wrapper
- CI integration

## Design principles

1. **Git decides mergeability.** Do not reimplement Git's merge algorithm.
2. **Read-only refs and worktree.** Analysis should not surprise developers by moving branches or changing files.
3. **Machine-readable from day one.** Human and agent output use the same typed analysis models.
4. **Do not confuse uncertainty with conflict.** Unsupported/unavailable projections are labeled explicitly.
5. **Provider integrations stay outside the Git engine.** Bitbucket tells us what might land; Git tells us what happens if it does.

## Development

Run tests:

```bash
swift test
```

The integration tests construct temporary Git repositories with known histories, including:

- clean merges
- content conflicts
- add/add conflicts
- a branch that is clean now but conflicts after another PR lands
- an incoming PR that itself cannot merge
- projection object-fetch behavior that verifies refs and `FETCH_HEAD` remain unchanged
- Bitbucket response decoding/filtering and API error handling
