# DepGuard

AI-powered dependency guardian for Razorpay repos. Scans third-party dependencies
for CVEs, deprecations, EOL status, and breaking changes — then posts findings to
Slack and opens upgrade PRs.

Built on [Slash](https://slash.concierge.razorpay.com), Razorpay's autonomous AI agent.

## How it works

```
┌─────────────────────────────────────────────────────────────────┐
│  Each Razorpay repo                                              │
│  ┌─────────────────────────────────────────────────────────┐    │
│  │ .github/workflows/depguard.yml                           │    │
│  │   schedule: cron (per-repo customizable)                 │    │
│  │ uses: razorpay/.github/.github/workflows/               │    │
│  │         depguard-reusable.yml@master                     │    │
│  └───────────────────────┬─────────────────────────────────┘    │
│                          │ calls                                  │
│  ┌───────────────────────▼─────────────────────────────────┐    │
│  │ Central reusable workflow (razorpay/.github)             │    │
│  │   1. Read .github/depguard.yml (config)                  │    │
│  │   2. Read .github/repo_owners.json (manager info)        │    │
│  │   3. Call Slash API → POST /api/v1/agents/run            │    │
│  └───────────────────────┬─────────────────────────────────┘    │
└──────────────────────────┼──────────────────────────────────────┘
                           │
                           ▼
┌──────────────────────────────────────────────────────────────────┐
│  Slash (AI Agent)                                                │
│  ┌──────────────────────────────────────────────────────────┐   │
│  │ Skill: depguard (from razorpay/agent-skills)              │   │
│  │                                                           │   │
│  │  1. Parse dependency manifests (go.mod, package.json...)  │   │
│  │  2. Run semgrep vulnerability scan                        │   │
│  │  3. Check OSV / GHSA / deps.dev for CVEs                  │   │
│  │  4. Check endoflife.date for EOL status                   │   │
│  │  5. Analyze upstream changelogs for breaking changes      │   │
│  │  6. Post findings to Slack channel (tags manager)         │   │
│  │  7. Open upgrade PRs for critical/high findings           │   │
│  └──────────────────────────────────────────────────────────┘   │
└──────────────────────────────────────────────────────────────────┘
```

## Components

| Component | Location | Purpose |
|-----------|----------|---------|
| Central reusable workflow | `razorpay/.github` `.github/workflows/depguard-reusable.yml` | Reads per-repo config, calls Slash API |
| Per-repo cron workflow | Each repo's `.github/workflows/depguard.yml` | Defines cron schedule, calls central workflow |
| Per-repo config | Each repo's `.github/depguard.yml` | Slack channel, ecosystems, severity, PR limits |
| Repo owners | Each repo's `.github/repo_owners.json` | Manager email, Slack ID, team, oncall |
| Slash skill | `razorpay/agent-skills` `depguard/SKILL.md` | Analysis logic: semgrep, CVEs, deprecations, PRs |
| Invocation script | `razorpay/.github` `depguard/scripts/invoke-slash.sh` | Standalone script to trigger scans (for testing) |

## Setup — For each repo

### 1. Add the cron workflow

Copy `workflow/depguard-repo-template.yml` to `.github/workflows/depguard.yml`
in your repo. Adjust the cron schedule:

```yaml
on:
  schedule:
    - cron: '30 3 * * 1'  # Monday 9 AM IST
  workflow_dispatch:       # Keep for manual triggers
```

### 2. Add per-repo config

Copy `config/depguard.yml.example` to `.github/depguard.yml`:

```yaml
enabled: true
slack_channel: "edge-alerts"
ecosystems: [go, npm]
severity_threshold: medium
max_prs_per_run: 3
```

### 3. Add repo owners

Copy `config/repo_owners.json.example` to `.github/repo_owners.json`:

```json
{
  "manager": {
    "name": "Jane Manager",
    "email": "jane.manager@razorpay.com",
    "slack_user_id": "U12345678"
  },
  "team": "Spine Edge",
  "oncall": ["oncall1@razorpay.com", "oncall2@razorpay.com"]
}
```

The `slack_user_id` is used to tag the manager in Slack findings. Find it via
Slack → Profile → "Copy Member ID".

### 4. Set up secrets

The workflow needs `SLASH_PROD_CI_USER` and `SLASH_PROD_CI_PASS` as GitHub
secrets. These should be set at the **organization level** so all repos inherit
them automatically:

1. Go to GitHub Organization Settings → Secrets and variables → Actions
2. Add `SLASH_PROD_CI_USER` and `SLASH_PROD_CI_PASS`
3. Ensure secrets are available to all repos (or specific repos)

If org-level secrets are not available, set them per-repo:
Settings → Secrets and variables → Actions → New repository secret.

### 5. Ensure the Slash GitHub App is installed

Slash needs access to your repo to clone it and open PRs. The `rzp-swe-agent`
GitHub App must be installed on the repo. If scans return 404:
Settings → Integrations → GitHub Apps → Add `rzp-swe-agent`.

### 6. Ensure Slash can post to your Slack channel

Slash must be invited to the Slack channel where findings will be posted:
1. Create or pick a channel (e.g., `#depguard-alerts`)
2. `/invite @Slash`
3. If Slash still can't post, contact `#slash-support` to add the channel to
   the posting allowlist.

## Central repo setup (one-time)

The central `razorpay/.github` repo contains:
- `.github/workflows/depguard-reusable.yml` — the reusable workflow
- `depguard/scripts/invoke-slash.sh` — standalone invocation script
- `depguard/config/` — example config templates
- `depguard/README.md` — this documentation
- `depguard/workflow/depguard-repo-template.yml` — per-repo workflow template

### Adding the skill to razorpay/agent-skills

The `skill/SKILL.md` file in this repo is the source of truth. To make it
available to Slash:

1. Clone `razorpay/agent-skills`
2. Create directory `depguard/`
3. Copy `SKILL.md` into it
4. Open a PR to `razorpay/agent-skills`

Once merged, Slash can load the skill via `skills:depguard`.

## Testing

### Manual trigger from GitHub

Go to Actions → DepGuard → Run workflow. This triggers the scan immediately
without waiting for the cron schedule.

### Local testing with the invocation script

```bash
export SLASH_PROD_CI_USER="your_ci_user"
export SLASH_PROD_CI_PASS="your_ci_pass"

./scripts/invoke-slash.sh \
  --repo "razorpay/edge" \
  --branch "master" \
  --slack-channel "edge-alerts" \
  --skill "depguard" \
  --manager-email "manager@razorpay.com" \
  --manager-slack-id "U12345678" \
  --ecosystems "go"
```

## What Slash does with the scan

When the DepGuard skill runs, Slash:

1. **Inventories** all dependencies from manifest files (go.mod, package.json, etc.)
2. **Runs semgrep** with OWASP and security-audit rulesets
3. **Queries CVE databases**: OSV API, GitHub Security Advisories, deps.dev
4. **Checks EOL status** via endoflife.date API
5. **Analyzes breaking changes** by reading upstream changelogs and grepping call sites
6. **Posts a findings report** to the Slack channel, tagged with the repo manager
7. **Opens upgrade PRs** for critical/high findings (capped at `max_prs_per_run`)

Each finding is classified as: `not_affected`, `safe_bump`, `breaking`, or
`deprecated_with_deadline`, with a risk score.

## Configuration reference

### `.github/depguard.yml`

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `enabled` | bool | `true` | Enable/disable scans |
| `slack_channel` | string | `{team}` or `depguard-alerts` | Channel for findings |
| `ecosystems` | list | all detected | Which ecosystems to scan |
| `severity_threshold` | string | `medium` | Min severity to report |
| `max_prs_per_run` | int | `3` | Max PRs per scan |
| `exclude_packages` | list | `[]` | Packages to skip |
| `extra_prompt` | string | `""` | Repo-specific instructions |

### `.github/repo_owners.json`

| Field | Type | Description |
|-------|------|-------------|
| `manager.name` | string | Manager's full name |
| `manager.email` | string | Manager's email (for reference) |
| `manager.slack_user_id` | string | Slack user ID for tagging |
| `team` | string | Team name |
| `oncall` | list | Oncall contact emails |
| `fallback_contacts` | list | Additional contacts with Slack IDs |

## FAQ

**Q: Does this replace Dependabot/Renovate?**
DepGuard subsumes the version-bump functionality and adds what those tools don't do: deprecation detection, affected-call-site analysis, automated migration, and cross-repo coordination. You can run it alongside Dependabot.

**Q: Can Slash merge the PRs it opens?**
No. Every PR requires human review and merge. Slash is explicitly prohibited from merging.

**Q: What if my repo uses `main` instead of `master`?**
Set `repo-default-branch: "main"` in your workflow's `with:` block.

**Q: How much does each scan cost?**
Cost depends on the number of dependencies and findings. Slash runs on Claude — each scan is an agentic task. Typical cost is comparable to a medium-complexity coding task.

**Q: Can I disable DepGuard for a specific run?**
Set `enabled: false` in `.github/depguard.yml`, or just don't add the workflow file.

**Q: What if Slash can't post to my Slack channel?**
Contact `#slash-support` to add your channel to the posting allowlist. Slash can only post to channels it's been invited to and that are on the allowlist.
