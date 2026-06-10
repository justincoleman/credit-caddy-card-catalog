#!/bin/zsh
# Remove the launchd job for the Credit Caddy card catalog agent.
# Logs in ~/Library/Logs/credit-caddy-agent/ are preserved for reference.

set -euo pipefail

for LABEL in com.creditcaddy.catalog-agent com.creditcaddy.news-watcher; do
  PLIST_TARGET="${HOME}/Library/LaunchAgents/${LABEL}.plist"

  if launchctl list "${LABEL}" >/dev/null 2>&1; then
    launchctl unload "${PLIST_TARGET}" 2>/dev/null || true
    echo "Unloaded ${LABEL}"
  else
    echo "${LABEL} was not loaded"
  fi

  if [[ -f "${PLIST_TARGET}" ]]; then
    rm "${PLIST_TARGET}"
    echo "Removed ${PLIST_TARGET}"
  fi
done

echo "Done. Logs preserved at ~/Library/Logs/credit-caddy-agent/"
