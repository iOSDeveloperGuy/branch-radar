# branch-radar

Find merge conflicts and collision risk before they surprise you.

`branch-radar` is a Swift CLI that asks Git whether your branches merge cleanly now and, with Bitbucket Data Center, whether they would still merge after another open pull request lands first.

The core rule is simple: **Bitbucket tells branch-radar what may land; Git decides whether it conflicts.** Real conflicts come from Git's own merge machinery. Heuristic overlap is reported separately as **risk**.

## Status

**v0.4** includes:

- local branch conflict checks
- Bitbucket Data Center open-PR discovery
- projected conflicts after another PR lands
- collision-risk detection for changes that still merge cleanly
- shared-file and rename/delete interaction evidence
- target freshness checks against Bitbucket's target SHA
- deterministic recommendations
- stable JSON for agents and scripts
- no worktree, index, local branch, or remote-tracking branch mutation

## Requirements

- Swift 6+
- Git with `git merge-tree --write-tree` support
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
  ! Sources/App/Service.swift [content]
◐ after PR #43: Logging cleanup
  feature/logging → develop
  ◐ Sources/App/Logger.swift [medium, shared_file]

Recommended:
  • PR #42 is projected to conflict if it lands first. Finish this branch before that PR, or plan to rebase afterward.
  • PR #43 overlaps this branch but Git still merges it cleanly. Review the shared code before both changes land.

Summary: 2 scenarios, 1 projected conflicts, 1 collision risks
```

For all local branches:

```bash
branch-radar scan --projected --target origin/develop
```

### What the states mean

- `✗ conflict`: Git itself cannot produce a clean merge.
- `◐ risk`: Git produces a clean merge, but both changes touch related code.
- `✓ clean`: no conflict or collision evidence was found.
- `? unavailable`: the scenario could not be proven with the available refs/objects.
- `! incoming_conflict`: the incoming PR itself does not currently merge cleanly into its target.

**Risk does not cause exit code `1`.** That exit code remains reserved for proven conflicts.

### Collision-risk evidence

v0.4 intentionally avoids a made-up numeric score. It reports concrete evidence:

- `shared_file` (`medium`): both changes modify the same file, but different hunks merge cleanly.
- `overlapping_lines` (`high`): both changes touch overlapping base-line ranges and Git still merges them cleanly.
- `structural_change` (`high`): a rename/delete/copy interaction overlaps another change to the same path.

These signals are advisory. They are not called conflicts unless Git reports a conflict.

## Target freshness

Projected analysis uses Bitbucket's target commit SHA. If your local target ref is behind or diverged, branch-radar reports that separately and recommends refreshing it. This avoids presenting a stale local `origin/develop` check as if it were current server state.

## Agent / JSON interface

```bash
branch-radar scan --projected --target origin/develop --json
```

Projected reports use schema version `2` in v0.4. New fields include:

- `targetFreshness`
- `risks` on each projected scenario
- `recommendations`
- projection outcome `risk`

Recommendation codes are stable machine values:

- `rebase_now`
- `refresh_target`
- `finish_before_pr`
- `review_overlap`

## Exit codes

| Code | Meaning |
| ---: | --- |
| `0` | Analysis completed with no proven current/projected conflicts; advisory risk may still exist |
| `1` | A current or projected Git conflict was found |
| `2` | Git/repository error |
| `3` | Bitbucket/provider error |
| `4` | Invalid arguments/configuration |

## Projection algorithm

For each relevant open PR, branch-radar:

1. reads the PR source and target commit SHAs from Bitbucket;
2. ensures those Git objects are available locally;
3. uses `git merge-tree` to test the incoming PR against its current target;
4. creates an unreferenced synthetic merge commit with `git commit-tree` when that merge is clean;
5. uses `git merge-tree` again to test your branch against that synthetic future target;
6. if the future merge is clean, compares each side's changes from its merge base to identify collision-risk evidence.

v0.4 models the incoming PR as a normal merge commit. Squash-only or rebase-only repositories can produce a different future history.

Cross-repository/fork PR projection remains `unavailable` in v0.4.

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
- rebase
- merge into your branch
- modify the index
- modify tracked files
- update local or remote-tracking branch refs
- push anything

`git merge-tree`, `git commit-tree`, and projection fetches can create unreachable objects in the repository object database. They do not move refs or modify the worktree.

## Roadmap

### v0.5

- merge-strategy-aware projection for merge/squash/rebase workflows
- GitHub and GitLab providers
- cross-repository PR projections
- optional MCP wrapper
- richer CI integration

## Development

```bash
swift test
swift build -c release
```

The current regression suite covers clean/conflicting merges, add/add classification, projected conflicts, shared-file collision risk, rename/edit structural risk, stale target detection, Bitbucket filtering, and ref-safe object fetching.
