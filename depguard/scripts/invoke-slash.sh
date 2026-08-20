#!/usr/bin/env bash
# DepGuard — Slash API Invocation Script
#
# Calls the Slash Agents API to trigger a DepGuard dependency scan.
# Used by the GitHub Actions workflow, but can also be run locally for testing.
#
# Usage:
#   ./invoke-slash.sh \
#     --repo "razorpay/edge" \
#     --branch "master" \
#     --slack-channel "edge-alerts" \
#     --skill "depguard" \
#     --manager-email "manager@razorpay.com" \
#     --manager-slack-id "U12345678" \
#     --follow-up-emails "p1@razorpay.com,p2@razorpay.com" \
#     --ecosystems "go,npm" \
#     --severity "medium" \
#     --max-prs "10" \
#     [--api-url "https://slash-api.concierge.razorpay.com"] \
#     [--extra-prompt "..."]
#
# Required env vars (or pass via --ci-user / --ci-pass):
#   SLASH_PROD_CI_USER  — Slash CI username
#   SLASH_PROD_CI_PASS  — Slash CI password

set -euo pipefail

# Defaults
API_URL="https://slash-api.concierge.razorpay.com"
REPO=""
BRANCH="master"
SLACK_CHANNEL=""
SKILL="depguard"
MANAGER_EMAIL=""
MANAGER_SLACK_ID=""
FOLLOW_UP_EMAILS=""
ECOSYSTEMS=""
SEVERITY="medium"
MAX_PRS="10"
EXCLUDE_PACKAGES=""
EXTRA_PROMPT=""
CI_USER="${SLASH_PROD_CI_USER:-}"
CI_PASS="${SLASH_PROD_CI_PASS:-}"

# Parse arguments
while [[ $# -gt 0 ]]; do
  case $1 in
    --repo) REPO="$2"; shift 2 ;;
    --branch) BRANCH="$2"; shift 2 ;;
    --slack-channel) SLACK_CHANNEL="$2"; shift 2 ;;
    --skill) SKILL="$2"; shift 2 ;;
    --manager-email) MANAGER_EMAIL="$2"; shift 2 ;;
    --manager-slack-id) MANAGER_SLACK_ID="$2"; shift 2 ;;
    --follow-up-emails) FOLLOW_UP_EMAILS="$2"; shift 2 ;;
    --ecosystems) ECOSYSTEMS="$2"; shift 2 ;;
    --severity) SEVERITY="$2"; shift 2 ;;
    --max-prs) MAX_PRS="$2"; shift 2 ;;
    --exclude-packages) EXCLUDE_PACKAGES="$2"; shift 2 ;;
    --extra-prompt) EXTRA_PROMPT="$2"; shift 2 ;;
    --api-url) API_URL="$2"; shift 2 ;;
    --ci-user) CI_USER="$2"; shift 2 ;;
    --ci-pass) CI_PASS="$2"; shift 2 ;;
    *) echo "Unknown option: $1"; exit 1 ;;
  esac
done

# Validate required args
if [ -z "$REPO" ]; then
  echo "ERROR: --repo is required"
  exit 1
fi
if [ -z "$CI_USER" ] || [ -z "$CI_PASS" ]; then
  echo "ERROR: SLASH_PROD_CI_USER and SLASH_PROD_CI_PASS must be set"
  exit 1
fi

# Refuse to send org-shared CI credentials anywhere but the known prod host.
if [ "$API_URL" != "https://slash-api.concierge.razorpay.com" ]; then
  echo "ERROR: --api-url must be https://slash-api.concierge.razorpay.com, got: $API_URL"
  exit 1
fi

# Strip # from slack channel if present
SLACK_CHANNEL="${SLACK_CHANNEL#\#}"

# Build the prompt
PROMPT="Run the depguard skill to perform a full dependency hygiene scan on this repository.

Repository: razorpay/${REPO}
Branch: ${BRANCH}

Scan parameters:
- Ecosystems: ${ECOSYSTEMS:-all detected}
- Severity threshold: ${SEVERITY}
- Max upgrades to bundle into the PR: ${MAX_PRS}
- Exclude packages: ${EXCLUDE_PACKAGES:-none}

Manager to tag in Slack: ${MANAGER_EMAIL:-unknown}
Manager Slack ID: ${MANAGER_SLACK_ID:-unknown}
Follow-up contacts: ${FOLLOW_UP_EMAILS:-none}

${EXTRA_PROMPT}

Post your findings to the Slack channel specified in the task. Tag the manager and follow-up contacts using their Slack user IDs. Bundle upgrade fixes for critical and high findings into a single PR (one commit per package), respecting the bundle cap. Follow that PR to a ready-or-blocked terminal state before posting anything to Slack."

# Build API request body. Deliberately no "branch" field: the Slash API
# rejects protected/default branches ("Branch 'master' is not allowed.
# Please use a feature branch.") since the agent must never be told to work
# directly against one. DepGuard's own skill creates its own working branch
# once it needs to commit anything.
REPO_URL="https://github.com/${REPO}"

BODY=$(jq -n \
  --arg prompt "$PROMPT" \
  --arg repo_url "$REPO_URL" \
  --arg slack_channel "$SLACK_CHANNEL" \
  --argjson skills "[\"${SKILL}\"]" \
  '{
    prompt: $prompt,
    repository_url: $repo_url,
    skills: $skills,
    slack_channel: $slack_channel
  }')

echo "DepGuard — calling Slash API"
echo "  Repository:    ${REPO}"
echo "  Branch:        ${BRANCH}"
echo "  Slack channel: ${SLACK_CHANNEL}"
echo "  Skill:         ${SKILL}"
echo "  API:           ${API_URL}/api/v1/agents/run"
echo ""

# Make the API call
RESPONSE=$(curl -s -w "\n%{http_code}" \
  -X POST "${API_URL}/api/v1/agents/run" \
  -H "Content-Type: application/json" \
  -u "${CI_USER}:${CI_PASS}" \
  -d "$BODY" 2>&1)

HTTP_CODE=$(echo "$RESPONSE" | tail -1)
RESPONSE_BODY=$(echo "$RESPONSE" | sed '$d')

echo "HTTP Status: ${HTTP_CODE}"

if [ "$HTTP_CODE" != "200" ] && [ "$HTTP_CODE" != "201" ] && [ "$HTTP_CODE" != "202" ]; then
  echo "ERROR: Slash API call failed"
  echo "Response: ${RESPONSE_BODY}"
  exit 1
fi

# Try to extract task ID
TASK_ID=$(echo "$RESPONSE_BODY" | jq -r '.task_id // .id // .task.id // empty' 2>/dev/null || echo "")

if [ -n "$TASK_ID" ]; then
  echo ""
  echo "Slash task created: ${TASK_ID}"
  echo "View logs: ${API_URL}/tasks/${TASK_ID}/execution-logs"
else
  echo ""
  echo "Response: ${RESPONSE_BODY}"
  echo "WARNING: Could not extract task ID from response"
fi
