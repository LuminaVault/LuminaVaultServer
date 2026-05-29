# Branch Protection — LuminaVaultServer

Production-grade branch protection for the two deploy branches. **You** (repo admin) apply these settings; this doc records the contract so they can be reproduced or audited.

## Topology

- `main` → deploys to **production** via `.github/workflows/prod.yml` on push.
- `dev` → deploys to **staging** via `.github/workflows/dev.yml` on push.
- All other branches: feature work. PR into `dev` (preferred) or `main` (hotfix).

After protection lands, push to `main`/`dev` is only possible via a PR merge that satisfies the required status checks.

## Required settings (both `main` and `dev`)

- **Require a pull request before merging**: ON
  - Required approvals: **0** (solo dev — CI is the gate, not human eyes)
  - Dismiss stale approvals when new commits are pushed: ON
- **Require status checks to pass before merging**: ON
  - Required checks: `lint` (job id from `.github/workflows/ci.yml`)
  - Require branches to be up to date before merging: ON
  - **`test` is NOT yet required.** The `swift test` job still SIGILLs on
    process exit — an AsyncKit `ConnectionPool.shutdown() was not called
    before deinit` precondition during pool teardown, compounded by a
    migration-ordering bug (`relation "users" does not exist`). The racy
    `defer { Task { … shutdown } }` migration (HER-310, #105) was necessary
    but insufficient; the crash persists and is tracked under **HER-310**.
    Once `test` is green on `main`, promote it: add `"test"` to the
    `contexts` arrays in `branch-protection-main.json` /
    `branch-protection-dev.json` and re-apply (commands below). The
    HER-272 deploy gate (`workflow_run` on CI success) already blocks
    deploys while `test` is red, so this promotion only tightens merges.
- **Require conversation resolution before merging**: ON
- **Restrict who can push to matching branches**: not required (no direct push allowed anyway)
- **Allow force pushes**: OFF
- **Allow deletions**: OFF
- **Do not allow bypassing the above settings** (include administrators): **ON**

## Allowed merge methods (repo-level setting)

- Squash merge: ON
- Merge commit: OFF
- Rebase merge: OFF

## Apply via `gh` CLI

```bash
# main
gh api -X PUT repos/LuminaVault/LuminaVaultServer/branches/main/protection \
  --input docs/cicd/branch-protection-main.json

# dev
gh api -X PUT repos/LuminaVault/LuminaVaultServer/branches/dev/protection \
  --input docs/cicd/branch-protection-dev.json
```

## Verification after apply

```bash
# Direct push should fail
git push origin main
# expect: remote: error: GH006: Protected branch update failed

# Admin merge of a failing PR should fail
gh pr merge <num> --admin --squash
# expect: GraphQL error about required status checks
```
