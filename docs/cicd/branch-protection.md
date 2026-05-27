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
  - Required checks: `lint` (job names from `.github/workflows/ci.yml`)
  - Require branches to be up to date before merging: ON
  - **`test` is NOT yet required** — the `swift test` job has been failing on main for 30+ consecutive runs (Linux Swift 6.3 runtime SIGILL + missing migration ordering). Promote `test` to required only after the test infra is repaired. Add `"test"` back to the `contexts` array in the JSON payloads when stable.
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
