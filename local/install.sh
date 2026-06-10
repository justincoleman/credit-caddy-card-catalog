#!/bin/zsh
# Install the launchd job for the Credit Caddy card catalog agent.
#
# Run this once on the Mac mini, after cloning this repo into ~/credit-caddy-card-catalog.
# Re-running is safe — it overwrites the existing plist and reloads launchd.

set -euo pipefail

REPO_DIR="${HOME}/credit-caddy-card-catalog"
LOCAL_DIR="${REPO_DIR}/local"
LABELS=("com.creditcaddy.catalog-agent" "com.creditcaddy.news-watcher")

mkdir -p "${HOME}/Library/LaunchAgents"
mkdir -p "${HOME}/Library/Logs/credit-caddy-agent"

# Make sure the runner scripts are executable
chmod +x "${LOCAL_DIR}/run-agent.sh" "${LOCAL_DIR}/watch-news.sh"

for LABEL in "${LABELS[@]}"; do
  PLIST_TEMPLATE="${LOCAL_DIR}/${LABEL}.plist.template"
  PLIST_TARGET="${HOME}/Library/LaunchAgents/${LABEL}.plist"

  if [[ ! -f "${PLIST_TEMPLATE}" ]]; then
    echo "ERROR: ${PLIST_TEMPLATE} not found. Did you clone the catalog repo into ~/credit-caddy-card-catalog?" >&2
    exit 1
  fi

  # Render template → plist with the user's $HOME path baked in
  sed "s|__HOME__|${HOME}|g" "${PLIST_TEMPLATE}" > "${PLIST_TARGET}"
  echo "Wrote ${PLIST_TARGET}"

  # Load (or reload) the job
  if launchctl list "${LABEL}" >/dev/null 2>&1; then
    echo "${LABEL} already loaded; reloading"
    launchctl unload "${PLIST_TARGET}" || true
  fi
  launchctl load "${PLIST_TARGET}"
  echo "Loaded ${LABEL}"
done

# Confirm
launchctl list | grep "com.creditcaddy" || true

cat <<EOF

✓ Install complete.

Scheduled runs:
  catalog agent  — 1st of each month, 08:00 local (full audit)
  news watcher   — daily, 09:15 local (48h SLA detection; quiet days cost \$0)

Manual tests:
  launchctl start com.creditcaddy.catalog-agent
  DRY_RUN=1 ${LOCAL_DIR}/watch-news.sh    # watcher without side effects

Watch live progress:
  tail -f ~/Library/Logs/credit-caddy-agent/run-*.log
  tail -f ~/Library/Logs/credit-caddy-agent/watch-*.log

To remove:
  ${LOCAL_DIR}/uninstall.sh
EOF
