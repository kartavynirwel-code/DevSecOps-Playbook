# GitHub CLI (gh)

GitHub ke platform-specific features (PR, issues, releases, workflows) ko terminal se access karne ka official CLI tool. `git` version control handle karta hai, `gh` GitHub platform ke features handle karta hai.

---

## Setup

### 1. Install (Ubuntu/Debian)

```bash
type -p curl >/dev/null || sudo apt install curl -y
curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg | sudo dd of=/usr/share/keyrings/githubcli-archive-keyring.gpg
sudo chmod go+r /usr/share/keyrings/githubcli-archive-keyring.gpg
echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" | sudo tee /etc/apt/sources.list.d/github-cli.list > /dev/null
sudo apt update
sudo apt install gh -y
```

Verify:
```bash
gh --version
```

### 2. Authenticate

```bash
gh auth login
```

Prompts:
- Account: `GitHub.com` (not Enterprise — Enterprise is for self-hosted GitHub instances)
- Protocol: `HTTPS`
- Auth method: `Login with a web browser` (or paste a Personal Access Token)

**If using a Personal Access Token**, generate it at `github.com/settings/tokens/new` with minimum required scopes:
- `repo`
- `read:org`
- `workflow`

### 3. Verify

```bash
gh auth status          # confirms logged-in account + token scopes
gh repo list --limit 5  # quick sanity check
```

---

## Command Pattern

```
gh <noun> <verb> [flags]
```
e.g. `gh repo create`, not `gh create repo`.

---

## Important Commands

### Repository

```bash
gh repo create <name> --public/--private --clone     # create + clone in one step
gh repo clone owner/repo                              # clone existing repo
gh repo view                                           # view current repo details
gh repo view --json url -q .url                        # get HTTPS URL of current repo
gh repo view owner/repo --json url -q .url              # get HTTPS URL of any repo
gh repo list --limit 10                                 # list your repos
gh repo delete owner/repo                                 # delete a repo
```

### Pull Requests

```bash
gh pr create --title "title" --body "description"    # create PR from current branch
gh pr create --draft                                   # create as draft PR
gh pr create --base develop                             # target a specific base branch
gh pr list                                               # list open PRs
gh pr view 12                                             # view PR details in terminal
gh pr view 12 --web                                        # open PR in browser
gh pr checkout 12                                          # checkout someone else's PR locally
gh pr diff 12                                               # view PR diff in terminal
gh pr comment 12 --body "LGTM"                               # comment on a PR
gh pr merge 12 --squash                                       # merge PR (squash/merge/rebase)
gh pr close 12                                                  # close PR without merging
gh pr status                                                     # your PRs' overall status
```

### Issues

```bash
gh issue create                     # create an issue (interactive)
gh issue list                        # list issues
gh issue view 5                       # view issue details
gh issue close 5                       # close an issue
```

### GitHub Actions (Workflows)

```bash
gh workflow list                    # list workflows in repo
gh workflow run <workflow-name>      # trigger a workflow manually
gh workflow view <workflow-name>      # view workflow details
gh run list                            # list recent workflow runs
gh run view <run-id>                    # view a specific run's details/logs
gh run watch <run-id>                    # watch a run live
```

### Releases

```bash
gh release create v1.0.0                        # create a release
gh release create v1.0.0 --notes "changelog"      # with release notes
gh release list                                     # list releases
gh release view v1.0.0                               # view release details
```

### Raw API Access

```bash
gh api repos/owner/repo                    # call GitHub API directly, no manual token/curl needed
```

---

## Where This Fits in DevOps Workflow

`gh` is used in **CI/CD automation**, not deployment/runtime:

- **GitHub Actions** — pre-installed in Actions runners, used for automation scripts (release creation, PR comments, workflow triggers)
- **GitOps automation** — e.g. Jenkins pipeline updates image tag in manifest repo → `gh pr create` raises PR automatically → ArgoCD picks up the merge
- **Release automation** — tag push triggers `gh release create` with auto-generated changelog

```
git  → code version control (local + remote)
gh   → GitHub platform automation (PR, issue, release, Actions)
Jenkins/ArgoCD/K8s → actual build-deploy-run pipeline
```
