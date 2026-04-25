#!/bin/zsh
# Install the launchd job for the Credit Caddy card catalog agent.
#
# Run this once on the Mac mini, after cloning this repo into ~/credit-caddy-card-catalog.
# Re-running is safe — it overwrites the existing plist and reloads launchd.

set -euo pipefail

REPO_DIR="${HOME}/credit-caddy-card-catalog"
LOCAL_DIR="${REPO_DIR}/local"
PLIST_TEMPLATE="${LOCAL_DIR}/com.creditcaddy.catalog-agent.plist.template"
PLIST_TARGET="${HOME}/Library/LaunchAgents/com.creditcaddy.catalog-agent.plist"
LABEL="com.creditcaddy.catalog-agent"

if [[ ! -f "${PLIST_TEMPLATE}" ]]; then
  echo "ERROR: ${PLIST_TEMPLATE} not found. Did you clone the catalog repo into ~/credit-caddy-card-catalog?" >&2
  exit 1
fi

# Make sure the runner script is executable
chmod +x "${LOCAL_DIR}/run-agent.sh"

# Render template → plist with the user's $HOME path baked in
mkdir -p "${HOME}/Library/LaunchAgents"
mkdir -p "${HOME}/Library/Logs/credit-caddy-agent"
sed "s|__HOME__|${HOME}|g" "${PLIST_TEMPLATE}" > "${PLIST_TARGET}"
echo "Wrote ${PLIST_TARGET}"

# Load (or reload) the agent
if launchctl list "${LABEL}" >/dev/null 2>&1; then
  echo "Agent already loaded; reloading"
  launchctl unload "${PLIST_TARGET}" || true
fi
launchctl load "${PLIST_TARGET}"
echo "Loaded ${LABEL}"

# Confirm
launchctl list | grep "${LABEL}" || true

cat <<EOF

✓ Install complete.

Next scheduled run: 1st of next month at 08:00 local time.

Manual test (kicks off a run right now):
  launchctl start ${LABEL}

Watch live progress:
  tail -f ~/Library/Logs/credit-caddy-agent/run-*.log

To remove:
  ${LOCAL_DIR}/uninstall.sh
EOF
