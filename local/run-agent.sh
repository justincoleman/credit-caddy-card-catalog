#!/bin/zsh
# Mac mini launchd wrapper for the Credit Caddy card catalog agent.
#
# Runs claude -p in non-interactive mode against the agent prompt that
# lives alongside this script. Logs every run to ~/Library/Logs/credit-caddy-agent/
# and rotates to keep the last 12 runs.
#
# Invoked by the launchd plist on the 1st of each month at 08:00 local time
# (matches the cloud-trigger schedule of 12:00 UTC). Can also be run manually
# for testing: ~/credit-caddy-card-catalog/local/run-agent.sh

set -euo pipefail

REPO_DIR="${HOME}/credit-caddy-card-catalog"
LOG_DIR="${HOME}/Library/Logs/credit-caddy-agent"
PROMPT_FILE="${REPO_DIR}/local/agent-prompt.md"
SECRETS_FILE="${HOME}/.config/credit-caddy/secrets.env"
TIMESTAMP=$(date -u +%Y-%m-%dT%H-%M-%SZ)
LOG_FILE="${LOG_DIR}/run-${TIMESTAMP}.log"

mkdir -p "${LOG_DIR}"

log() {
  printf '[%s] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" | tee -a "${LOG_FILE}"
}

# A failed run used to show only as a banner on the mini itself, and the
# agent failed silently for three months (Jul-Sep 2026: expired Claude login).
# Failures now open (or comment on) a GitHub issue so they're seen anywhere.
FAILURE_ISSUE_TITLE="Monthly catalog agent failed"
report_failure() {
  local reason="$1"
  osascript -e "display notification \"${reason}\" with title \"Credit Caddy: catalog refresh ERROR\" sound name \"Basso\"" 2>/dev/null || true
  local body="The monthly catalog agent on $(hostname -s) failed at $(date -u +%Y-%m-%dT%H:%M:%SZ): ${reason}

Log: ${LOG_FILE}"
  local existing
  existing=$(gh issue list --repo justincoleman/credit-caddy-card-catalog --state open \
    --search "in:title \"${FAILURE_ISSUE_TITLE}\"" --json number --jq '.[0].number // empty' 2>/dev/null || true)
  if [[ -n "${existing}" ]]; then
    gh issue comment "${existing}" --repo justincoleman/credit-caddy-card-catalog --body "${body}" >/dev/null 2>&1 || true
  else
    gh issue create --repo justincoleman/credit-caddy-card-catalog --title "${FAILURE_ISSUE_TITLE}" --body "${body}" >/dev/null 2>&1 || true
  fi
}

log "Run started"
log "Repo dir:    ${REPO_DIR}"
log "Prompt file: ${PROMPT_FILE}"
log "Secrets:     ${SECRETS_FILE}"
log "Log file:    ${LOG_FILE}"

# Load FireCrawl key (and any other secrets) from the user's local secrets file.
# This file is NEVER checked into the repo. See local/README.md for setup.
if [[ ! -f "${SECRETS_FILE}" ]]; then
  log "ERROR: secrets file not found at ${SECRETS_FILE}"
  log "Create it with: mkdir -p ~/.config/credit-caddy && echo 'FIRECRAWL_API_KEY=fc-...' > ${SECRETS_FILE} && chmod 600 ${SECRETS_FILE}"
  exit 1
fi
# shellcheck disable=SC1090
set -a; source "${SECRETS_FILE}"; set +a
if [[ -z "${FIRECRAWL_API_KEY:-}" ]]; then
  log "ERROR: FIRECRAWL_API_KEY not set after sourcing ${SECRETS_FILE}"
  exit 1
fi
# Mode-check the secrets file — should be 600 (owner read/write only).
SECRETS_MODE=$(stat -f '%Lp' "${SECRETS_FILE}" 2>/dev/null || echo "")
if [[ "${SECRETS_MODE}" != "600" ]]; then
  log "WARNING: ${SECRETS_FILE} has mode ${SECRETS_MODE}; recommend chmod 600"
fi

# Pre-flight: required commands
MISSING=()
for cmd in claude git gh jq node npm curl; do
  if ! command -v "${cmd}" >/dev/null 2>&1; then
    MISSING+=("${cmd}")
  fi
done
if [[ ${#MISSING[@]} -gt 0 ]]; then
  log "ERROR: missing required commands on PATH: ${MISSING[*]}"
  log "Install via Homebrew: brew install ${MISSING[*]}"
  exit 1
fi

# Pre-flight: gh auth
if ! gh auth status >/dev/null 2>&1; then
  log "ERROR: gh CLI not authenticated. Run: gh auth login"
  exit 1
fi

# Pre-flight: gh scopes — need 'repo' (or contents:write+pull-requests:write) to push and open PRs.
# Fail fast here rather than after 16 min of agent work.
GH_SCOPES=$(gh auth status 2>&1 | grep -E '^\s*-?\s*Token scopes:' | head -1 || true)
if ! echo "${GH_SCOPES}" | grep -qE "'repo'|'public_repo'"; then
  log "WARNING: gh CLI may lack 'repo' scope (push + PR create). Detected: ${GH_SCOPES}"
  log "If push fails, run: gh auth refresh -h github.com -s repo"
fi

# Clone or refresh the catalog repo. We use SSH for the remote so git push doesn't
# depend on gh's OAuth token scopes (which can be fine-grained-PAT-restricted).
SSH_REMOTE="git@github.com:justincoleman/credit-caddy-card-catalog.git"
if [[ ! -d "${REPO_DIR}/.git" ]]; then
  log "Cloning catalog repo into ${REPO_DIR} (via SSH)"
  git clone "${SSH_REMOTE}" "${REPO_DIR}" >>"${LOG_FILE}" 2>&1
else
  log "Refreshing existing checkout"
  cd "${REPO_DIR}"
  # Migrate from HTTPS to SSH if needed
  CURRENT_REMOTE=$(git remote get-url origin 2>/dev/null || echo "")
  if [[ "${CURRENT_REMOTE}" != "${SSH_REMOTE}" ]]; then
    log "Switching origin from ${CURRENT_REMOTE} to SSH"
    git remote set-url origin "${SSH_REMOTE}"
  fi
  git fetch origin >>"${LOG_FILE}" 2>&1
  git checkout main >>"${LOG_FILE}" 2>&1
  git reset --hard origin/main >>"${LOG_FILE}" 2>&1
fi

cd "${REPO_DIR}"

if [[ ! -f "${PROMPT_FILE}" ]]; then
  log "ERROR: prompt file not found at ${PROMPT_FILE}"
  log "Did the catalog repo's local/agent-prompt.md get pulled correctly?"
  exit 1
fi

# Model and budget can be overridden in secrets.env. A full 149-card audit
# needs more than the original $5: the June 2026 run re-verified only 75 cards.
AGENT_MODEL="${CATALOG_AGENT_MODEL:-claude-sonnet-5-5}"
AGENT_BUDGET_USD="${CATALOG_AGENT_BUDGET_USD:-15}"

# Pre-flight: Claude login. A 20-second check here beats finding out a month
# later. For an unattended machine, run `claude setup-token` once and put the
# result in secrets.env as CLAUDE_CODE_OAUTH_TOKEN (valid for a year).
set +e
AUTH_CHECK=$(claude -p "Reply with the single word OK." --model "${AGENT_MODEL}" \
  --max-budget-usd 0.05 --no-session-persistence --output-format text 2>&1)
AUTH_EXIT=$?
set -e
if [[ ${AUTH_EXIT} -ne 0 ]]; then
  log "ERROR: claude pre-flight failed (exit ${AUTH_EXIT}): ${AUTH_CHECK}"
  report_failure "Claude pre-flight failed: ${AUTH_CHECK}. On the mini, run 'claude setup-token' and set CLAUDE_CODE_OAUTH_TOKEN in ~/.config/credit-caddy/secrets.env."
  exit 1
fi

log "Invoking claude -p (model: ${AGENT_MODEL}, budget cap: \$${AGENT_BUDGET_USD})"
log "Tools: Bash Read Write Edit Glob Grep WebFetch"
log "----- agent output begins -----"

# The agent prompt is the entire file contents.
# --permission-mode bypassPermissions is required so the agent can run
# autonomously without prompting for tool approval at every step.
# --max-budget-usd caps cost per run as a safety net.
# --no-session-persistence keeps each monthly run self-contained.
set +e
claude -p "$(cat "${PROMPT_FILE}")" \
  --model "${AGENT_MODEL}" \
  --allowedTools "Bash Read Write Edit Glob Grep WebFetch" \
  --permission-mode bypassPermissions \
  --max-budget-usd "${AGENT_BUDGET_USD}" \
  --no-session-persistence \
  --output-format text \
  >>"${LOG_FILE}" 2>&1
EXIT=$?
set -e

log "----- agent output ends -----"
log "claude exited with status ${EXIT}"

# Detect run outcome: did a new PR get opened?
PR_URL=$(gh pr list --repo justincoleman/credit-caddy-card-catalog --state open \
  --search "in:title Catalog refresh $(date -u +%Y-%m-%d)" \
  --json url --jq '.[0].url // empty' 2>/dev/null || true)

if [[ -n "${PR_URL}" ]]; then
  log "✓ PR opened: ${PR_URL}"
  # macOS Notification Center banner (visible if you're near the mini)
  osascript -e "display notification \"Review and merge: ${PR_URL}\" with title \"Credit Caddy: catalog PR ready\" sound name \"Glass\"" 2>/dev/null || true
elif [[ "${EXIT}" -eq 0 ]]; then
  log "No PR opened — agent reported no changes needed"
  osascript -e "display notification \"No changes this month.\" with title \"Credit Caddy: catalog refresh\" sound name \"Pop\"" 2>/dev/null || true
else
  log "Run failed — see log above"
  report_failure "claude exited with status ${EXIT}. $(grep -m1 -iE 'error|failed' "${LOG_FILE}" | cut -c1-300)"
fi

# Rotate logs: keep last 12 (one year of monthly runs)
cd "${LOG_DIR}"
ls -1t run-*.log 2>/dev/null | tail -n +13 | while read -r OLD; do
  rm -f "${OLD}"
  log "Rotated out: ${OLD}"
done || true

log "Run complete"
exit "${EXIT}"
