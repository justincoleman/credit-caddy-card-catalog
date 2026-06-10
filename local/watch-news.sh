#!/bin/zsh
# Daily news watcher for the Credit Caddy card catalog.
#
# Carries the 48-hour freshness SLA: scans points-press RSS feeds for
# headlines about cards in the catalog, and when one looks like a real
# benefit/fee/earn-rate change, runs a small Claude triage pass that opens
# a GitHub issue (label: data-report) with the source link.
#
# Cost design: quiet days make NO model call — RSS fetch + keyword matching
# is plain python3. Claude (Haiku, $1 budget cap) only runs when a new
# headline matches a tracked card.
#
# Invoked daily by launchd (com.creditcaddy.news-watcher, 09:15 local).
# Manual test without side effects (no state writes, no model, no issues):
#   DRY_RUN=1 ~/credit-caddy-card-catalog/local/watch-news.sh

set -euo pipefail

REPO_DIR="${REPO_DIR:-${HOME}/credit-caddy-card-catalog}"
LOG_DIR="${LOG_DIR:-${HOME}/Library/Logs/credit-caddy-agent}"
STATE_FILE="${STATE_FILE:-${HOME}/.config/credit-caddy/news-watcher-seen.txt}"
PROMPT_FILE="${REPO_DIR}/local/watcher-prompt.md"
DRY_RUN="${DRY_RUN:-0}"
TIMESTAMP=$(date -u +%Y-%m-%dT%H-%M-%SZ)
LOG_FILE="${LOG_DIR}/watch-${TIMESTAMP}.log"

mkdir -p "${LOG_DIR}" "$(dirname "${STATE_FILE}")"
touch "${STATE_FILE}"

log() {
  printf '[%s] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" | tee -a "${LOG_FILE}"
}

log "News watcher started (dry-run: ${DRY_RUN})"

if [[ ! -f "${REPO_DIR}/cards.json" ]]; then
  log "ERROR: ${REPO_DIR}/cards.json not found"
  exit 1
fi

cd "${REPO_DIR}"

MATCHES_FILE=$(mktemp)
trap 'rm -f "${MATCHES_FILE}"' EXIT

# Stage 1 (free): fetch feeds, drop already-seen items, keyword-match
# against catalog card names. Emits "Card Name<TAB>Headline<TAB>Link".
python3 - "${REPO_DIR}/cards.json" "${STATE_FILE}" "${DRY_RUN}" > "${MATCHES_FILE}" 2>>"${LOG_FILE}" <<'PYEOF'
import hashlib
import json
import re
import sys
import urllib.request
import xml.etree.ElementTree as ET

cards_path, state_path, dry_flag = sys.argv[1], sys.argv[2], sys.argv[3]
dry = dry_flag == "1"

FEEDS = [
    "https://www.doctorofcredit.com/feed/",
    "https://frequentmiler.com/feed/",
    "https://thepointsguy.com/feed/",
]

# Tokens too generic to identify a card on their own.
STOP = {
    "the", "a", "an", "card", "cards", "from", "credit", "cash", "rewards",
    "visa", "mastercard", "world", "elite", "signature", "by", "for", "bank",
    "of", "american", "express", "chase", "citi", "citibank", "capital",
    "one", "wells", "fargo", "discover", "barclays", "business", "personal",
    "and", "plus",
}

ISSUER_ALIASES = {
    "american express": ["amex", "american express"],
    "chase": ["chase"],
    "citi": ["citi", "citibank"],
    "capital one": ["capital one"],
    "discover": ["discover"],
    "wells fargo": ["wells fargo"],
    "bank of america": ["bank of america", "bofa"],
    "u.s. bank": ["us bank", "u.s. bank"],
    "barclays": ["barclays"],
}

# A headline only counts if it also smells like a change, not a review/deal.
CHANGE = re.compile(
    r"fee|credit|benefit|refresh|devalu|discontinu|no longer|drops?|adds?|"
    r"cut|increase|coupon|perk|bonus|launch|chang|new|kill|end(s|ing)?\b",
    re.I,
)

catalog = json.load(open(cards_path))
cardterms = []
for card in catalog["cards"]:
    name = re.sub(r"[®℠™]", "", card["cardName"])
    issuer = card.get("issuer", "").lower()
    aliases = ISSUER_ALIASES.get(issuer, [issuer] if issuer else [])
    tokens = [
        t.lower()
        for t in re.findall(r"[A-Za-z][A-Za-z'.]+", name)
        if t.lower() not in STOP
    ]
    # Two-token phrases ("sapphire reserve") identify a card by themselves;
    # single tokens ("platinum") only count alongside an issuer alias.
    phrases = [" ".join(tokens[i:i + 2]) for i in range(len(tokens) - 1)]
    cardterms.append((card["cardName"], aliases, phrases, tokens))

seen = set(open(state_path).read().split())
new_seen = []
matches = []

for url in FEEDS:
    try:
        req = urllib.request.Request(
            url, headers={"User-Agent": "credit-caddy-news-watcher/1.0"}
        )
        root = ET.fromstring(urllib.request.urlopen(req, timeout=20).read())
    except Exception as exc:  # noqa: BLE001 — one dead feed shouldn't kill the run
        print(f"WARN feed failed: {url}: {exc}", file=sys.stderr)
        continue
    for item in root.iter("item"):
        title = (item.findtext("title") or "").strip()
        link = (item.findtext("link") or "").strip()
        if not title or not link:
            continue
        key = hashlib.sha256(link.encode()).hexdigest()[:16]
        if key in seen:
            continue
        new_seen.append(key)
        headline = title.lower()
        if not CHANGE.search(headline):
            continue
        for name, aliases, phrases, tokens in cardterms:
            phrase_hit = any(p in headline for p in phrases)
            token_hit = any(a in headline for a in aliases) and any(
                re.search(r"\b" + re.escape(t) + r"\b", headline) for t in tokens
            )
            if phrase_hit or token_hit:
                matches.append((name, title, link))
                break

for name, title, link in matches:
    print(f"{name}\t{title}\t{link}")

if not dry and new_seen:
    with open(state_path, "a") as fh:
        fh.write("\n".join(new_seen) + "\n")
PYEOF

MATCH_COUNT=$(grep -c . "${MATCHES_FILE}" || true)
log "Stage 1: ${MATCH_COUNT} new candidate headline(s)"

if [[ "${MATCH_COUNT}" -eq 0 ]]; then
  log "Quiet day — no model call, no cost. Done."
  exit 0
fi

while IFS=$'\t' read -r CARD TITLE LINK; do
  log "  candidate: [${CARD}] ${TITLE} — ${LINK}"
done < "${MATCHES_FILE}"

if [[ "${DRY_RUN}" == "1" ]]; then
  log "Dry run — skipping triage, state untouched. Done."
  exit 0
fi

if [[ ! -f "${PROMPT_FILE}" ]]; then
  log "ERROR: prompt file not found at ${PROMPT_FILE}"
  exit 1
fi

log "Stage 2: invoking claude -p (model: claude-haiku-4-5, budget cap: \$1)"
log "----- triage output begins -----"

set +e
claude -p "$(cat "${PROMPT_FILE}")

## Candidate headlines (card<TAB>headline<TAB>link)

$(cat "${MATCHES_FILE}")" \
  --model claude-haiku-4-5 \
  --allowedTools "Bash Read Grep WebFetch" \
  --permission-mode bypassPermissions \
  --max-budget-usd 1 \
  --no-session-persistence \
  --output-format text \
  >>"${LOG_FILE}" 2>&1
EXIT=$?
set -e

log "----- triage output ends -----"
log "claude exited with status ${EXIT}"

ISSUES=$(grep -o 'ISSUE_CREATED: [^ ]*' "${LOG_FILE}" | sed 's/ISSUE_CREATED: //' || true)
if [[ -n "${ISSUES}" ]]; then
  COUNT=$(echo "${ISSUES}" | grep -c . || true)
  log "✓ ${COUNT} issue(s) filed — 48h SLA clock running"
  osascript -e "display notification \"${COUNT} catalog change report(s) filed — 48h SLA clock running.\" with title \"Credit Caddy: news watcher\" sound name \"Glass\"" 2>/dev/null || true
elif [[ "${EXIT}" -eq 0 ]]; then
  log "Triage found no real catalog changes"
else
  log "Triage run failed — see log above"
  osascript -e "display notification \"Watcher triage failed (exit ${EXIT}). Check logs.\" with title \"Credit Caddy: news watcher ERROR\" sound name \"Basso\"" 2>/dev/null || true
fi

# Prune state and rotate logs (keep 30 watcher runs)
tail -n 2000 "${STATE_FILE}" > "${STATE_FILE}.tmp" && mv "${STATE_FILE}.tmp" "${STATE_FILE}"
cd "${LOG_DIR}"
ls -1t watch-*.log 2>/dev/null | tail -n +31 | while read -r OLD; do
  rm -f "${OLD}"
done || true

log "Run complete"
exit "${EXIT}"
