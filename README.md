# branch-radar

Find merge conflicts and collision risk before they surprise you.

`branch-radar` is a Swift CLI that asks Git whether your branches merge cleanly now and, with Bitbucket Data Center, whether they would still merge after another open pull request lands first.

The core rule is simple: **Bitbucket tells branch-radar what may land; Git decides what that history would do.** Proven conflicts come from Git's merge machinery. Heuristic overlap is reported separately as **risk**.

## Status

**v0.5** includes:

- local branch conflict checks
- Bitbucket Data Center open-PR discovery
- projected conflicts after another PR lands
- merge-strategy-aware projection for merge, fast-forward, squash, and rebase workflows
- collision-risk detection for changes that still merge cleanly
- target freshness checks against Bitbucket's target SHA
- deterministic recommendations
- stable JSON for agents and scripts
- no worktree, index, local branch, or remote-tracking branch mutation

## Requirements

- Swift 6+
- Git with `git merge-tree --write-tree` and `--merge-base` support
- macOS or Linux
- Bitbucket Data Center access token for PR discovery/projection commands

## Build and install

```bash
swift build -c release
make install
```

The default install path is `~/.local/bin/branch-radar`. Override it with `PREFIX=/usr/local` if needed.

## Local conflict analysis

```bash
branch-radar check HEAD --target origin/develop
branch-radar check feature/my-change --target origin/develop
branch-radar scan --local --target origin/develop
```

If `--target` is omitted, branch-radar tries `origin/HEAD`, `origin/main`, `origin/master`, `main`, then `master`.

## Bitbucket Data Center setup

Authentication is environment-only so access tokens do not appear in shell history or process listings.

```bash
export BRANCH_RADAR_BITBUCKET_TOKEN='...'
export BRANCH_RADAR_BITBUCKET_URL='https://bitbucket.example.com'
```

Project key and repository slug are inferred from common Git remotes when possible. They can also be configured explicitly:

```bash
export BRANCH_RADAR_BITBUCKET_PROJECT='DEMO'
export BRANCH_RADAR_BITBUCKET_REPO='sample-service'
export BRANCH_RADAR_BITBUCKET_USERNAME='alice'   # required for --mine
```

Equivalent non-secret values may be supplied with `--bitbucket-url`, `--project-key`, `--repo`, and `--username`.

## Discover open PRs

```bash
branch-radar prs --target origin/develop
branch-radar prs --mine --target origin/develop
```

## Project future conflicts and risk

```bash
branch-radar project feature/my-change --target origin/develop
```

Example:

```text
Branch Radar Projection
Branch: feature/my-change
Target: origin/develop

Current: ✓ clean

✗ after PR #42: Validation changes
  feature/validation → develop
  strategy: Rebase and fast-forward [rebase-ff-only, auto_merge]
  ! Sources/App/Service.swift [content]

◐ after PR #43: Logging cleanup
  feature/logging → develop
  strategy: Squash [squash, repository_default; manual merge may choose: no-ff]
  ◐ Sources/App/Logger.swift [medium, shared_file]

Recommended:
  • PR #42 is projected to conflict if it lands first. Finish this branch before that PR, or plan to rebase afterward.
  • PR #43 overlaps this branch but Git still merges it cleanly. Review the shared code before both changes land.

Summary: 2 scenarios, 1 projected conflicts, 1 collision risks, 0 strategy rejections
```

For all local branches:

```bash
branch-radar scan --projected --target origin/develop
```

### What the states mean

- `✗ conflict`: Git itself cannot produce the projected merge.
- `◐ risk`: the projected merge is clean, but both changes touch related code.
- `✓ clean`: no conflict or collision evidence was found.
- `⊘ strategy_rejected`: the selected merge strategy cannot land that PR in its current history, such as an out-of-date branch under fast-forward-only.
- `? unavailable`: the scenario could not be proven with the available refs/objects or uses an unsupported strategy.
- `! incoming_conflict`: applying the incoming PR with the selected strategy conflicts before branch-radar can project your branch afterward.

**Risk does not cause exit code `1`.** That exit code remains reserved for proven conflicts.

## Merge-strategy-aware projection

v0.5 models the history shape produced by the selected Bitbucket merge strategy instead of treating every PR as a merge commit.

Supported strategy families:

| Strategy family | Common Bitbucket ID | Projection behavior |
| --- | --- | --- |
| Merge commit | `no-ff` | Three-way merge, then synthetic two-parent merge commit |
| Fast-forward | `ff` | Fast-forward when possible; otherwise merge-commit semantics |
| Fast-forward only | `ff-only` | Rejects the scenario unless target is an ancestor of source |
| Rebase, merge | `rebase-no-ff` | Replays source commits onto target, then creates a synthetic merge commit |
| Rebase, fast-forward | `rebase-ff-only` | Replays source commits onto target and uses the rebased tip |
| Squash | `squash` | Three-way merge result represented as one synthetic commit on target |
| Squash, fast-forward only | `squash-ff-only` | Requires an up-to-date source, then uses squash semantics |

### How branch-radar chooses a strategy

For each projected PR, strategy selection uses this precedence:

1. `--merge-strategy <id>` when you explicitly provide an enabled repository strategy.
2. The strategy already selected for that PR's Bitbucket auto-merge request, when present.
3. The repository's effective default merge strategy.

The output and JSON report the strategy **and its source**.

A repository default is not always a prediction of what a human will choose. If multiple strategies are enabled, a manual merge can select another one. In that case branch-radar marks the repository-default selection as an assumption and includes the alternative enabled strategy IDs.

To force a scenario using one enabled strategy:

```bash
branch-radar project feature/my-change \
  --target origin/develop \
  --merge-strategy rebase-ff-only
```

This is useful when you know how a particular PR will be merged or when comparing strategy-dependent outcomes.

### Rebase simulation

Rebase projection is intentionally commit-aware. branch-radar:

1. finds the merge base between the PR source and target;
2. enumerates the source branch's non-merge commits in replay order;
3. replays each commit onto a synthetic target using Git's three-way merge machinery and the original commit parent as the explicit merge base;
4. creates only unreferenced synthetic commits with `git commit-tree`;
5. stops and reports `incoming_conflict` if an intermediate replay conflicts.

That distinction matters because a branch's final tree can sometimes merge cleanly even though replaying one of its intermediate commits would fail under a rebase strategy.

## Collision-risk evidence

v0.5 intentionally avoids a made-up numeric score. It reports concrete evidence:

- `shared_file` (`medium`): both changes modify the same file, but Git still merges them cleanly.
- `overlapping_lines` (`high`): both changes touch overlapping base-line ranges and Git still merges them cleanly.
- `structural_change` (`high`): a rename/delete/copy interaction overlaps another change to the same path.

These signals are advisory. They are not called conflicts unless Git reports a conflict.

## Target freshness

Projected analysis uses Bitbucket's target commit SHA. If your local target ref is behind or diverged, branch-radar reports that separately and recommends refreshing it. This avoids presenting a stale local target check as if it were current server state.

## Agent / JSON interface

```bash
branch-radar scan --projected --target origin/develop --json
```

Projected reports use schema version `3` in v0.5. Strategy-aware fields include:

- `mergeStrategy.strategy.id`
- `mergeStrategy.strategy.kind`
- `mergeStrategy.source`
- `mergeStrategy.alternativeStrategyIDs`
- projection outcome `strategy_rejected`

Existing v0.4 fields remain available, including `targetFreshness`, `risks`, and `recommendations`.

Recommendation codes are stable machine values:

- `rebase_now`
- `refresh_target`
- `finish_before_pr`
- `review_overlap`

## Exit codes

| Code | Meaning |
| ---: | --- |
| `0` | Analysis completed with no proven current/projected conflicts; advisory risk or strategy rejection may still exist |
| `1` | A current or projected Git conflict was found |
| `2` | Git/repository error |
| `3` | Bitbucket/provider error |
| `4` | Invalid arguments or configuration |

## Fetch safety

When a PR commit is missing locally, branch-radar uses:

```bash
git fetch --no-tags --no-write-fetch-head <remote> refs/heads/<source>
```

This downloads Git objects without updating local branches, remote-tracking branches, or `FETCH_HEAD`. A regression test verifies this behavior.

Disable object fetching with `--no-fetch`.

## Safety

Analysis commands do not:

- checkout or switch branches
- rebase your branches
- merge into your branches
- modify the index
- modify tracked files
- update local or remote-tracking branch refs
- push anything

`git merge-tree`, `git commit-tree`, and projection fetches can create unreachable objects in the repository object database. They do not move refs or modify the worktree.

## Current limitations

- Cross-repository/fork PR projection is reported as `unavailable`.
- Unknown/custom merge-strategy IDs are reported as `unavailable` rather than guessed.
- For manual merges, the effective repository default is an assumption when other strategies are enabled.
- Rebase projection currently replays non-merge commits; source histories containing merge commits are not reconstructed as merge-preserving rebases.

## Roadmap

### v0.6

- GitHub and GitLab providers
- cross-repository PR projections
- optional MCP wrapper
- richer CI integration

## Development

```bash
swift test
swift build -c release
```

The regression suite covers clean/conflicting merges, collision risk, target freshness, Bitbucket strategy discovery, auto-merge strategy selection, strategy classification, fast-forward-only rejection, squash projection, rebase projection, strategy-dependent conflict behavior, and ref-safe object fetching.
