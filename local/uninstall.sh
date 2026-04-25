#!/bin/zsh
# Remove the launchd job for the Credit Caddy card catalog agent.
# Logs in ~/Library/Logs/credit-caddy-agent/ are preserved for reference.

set -euo pipefail

PLIST_TARGET="${HOME}/Library/LaunchAgents/com.creditcaddy.catalog-agent.plist"
LABEL="com.creditcaddy.catalog-agent"

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

echo "Done. Logs preserved at ~/Library/Logs/credit-caddy-agent/"
