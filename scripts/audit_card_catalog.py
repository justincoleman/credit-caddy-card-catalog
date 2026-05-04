#!/usr/bin/env python3
"""Audit Credit Buddy's bundled card catalog for optimizer-readiness.

The goal is not to prove facts are correct. This script flags the records that
cannot support a trustworthy optimizer yet: missing source maps, missing
verification dates, missing earn rules, vague conditions, and coarse travel
rates that should be split into airfare/hotels/portal/other travel.
"""

from __future__ import annotations

import json
from collections import Counter
from datetime import datetime, timezone
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
CATALOG_PATH = ROOT / "cards.json"


def load_catalog() -> dict:
    with CATALOG_PATH.open("r", encoding="utf-8") as f:
        return json.load(f)


def source_keys(card: dict) -> set[str]:
    sources = card.get("sources") or {}
    return set(sources.keys())


def issue_list(card: dict) -> list[str]:
    issues: list[str] = []
    rates = card.get("earnRates") or []
    rate_category_counts = Counter(rate.get("category", "unknown") for rate in rates)
    keys = source_keys(card)

    if not card.get("lastVerified"):
        issues.append("missing lastVerified")
    if not card.get("sources"):
        issues.append("missing sources")
    if not rates and float(card.get("baseEarnRate") or 0) <= 1:
        issues.append("no explicit earn rates and base is not a bonus")

    for field in ("annualFee", "noForeignTransactionFees", "baseEarnRate", "rewardProgram"):
        if card.get("sources") is not None and field not in keys:
            issues.append(f"missing source:{field}")

    for rate in rates:
        category = rate.get("category", "unknown")
        rate_key = f"earnRates.{category}"
        if card.get("sources") is not None and rate_key not in keys:
            issues.append(f"missing source:{rate_key}")

        notes = (rate.get("notes") or "").lower()
        if rate.get("isConditional") and not notes:
            issues.append(f"conditional rate without note:{category}")
        if category == "travel" and rate_category_counts["travel"] > 1:
            travel_rules = [r for r in rates if r.get("category") == "travel"]
            has_conditional = any(r.get("isConditional") for r in travel_rules)
            has_unconditional = any(not r.get("isConditional") for r in travel_rules)
            if has_conditional and has_unconditional:
                continue
            issues.append("duplicate travel rules should be split or deduped")
        if rate.get("cap") is not None:
            if "up to" not in notes and "cap" not in notes and "combined" not in notes:
                issues.append(f"cap without readable note:{category}")
            if "then" not in notes and "after" not in notes:
                issues.append(f"cap missing after-cap language:{category}")

    return sorted(set(issues))


def main() -> None:
    catalog = load_catalog()
    cards = catalog["cards"]
    now = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")

    by_issuer = Counter(card["issuer"] for card in cards)
    issue_counts: Counter[str] = Counter()
    rows: list[tuple[str, str, str, list[str]]] = []
    for card in cards:
        name = f"{card['issuer']} {card['cardName']}"
        issues = issue_list(card)
        issue_counts.update(issues)
        rows.append((card["issuer"], card["id"], name, issues))

    print(f"# Card Catalog Optimizer Audit")
    print()
    print(f"- Generated: {now}")
    print(f"- Catalog version: {catalog.get('version')}")
    print(f"- Cards: {len(cards)}")
    print(f"- Issuers: {len(by_issuer)}")
    print(f"- Cards with issues: {sum(1 for _, _, _, issues in rows if issues)}")
    print()
    print("## Issuer Counts")
    print()
    for issuer, count in sorted(by_issuer.items()):
        print(f"- {issuer}: {count}")
    print()
    print("## Top Issues")
    print()
    for issue, count in issue_counts.most_common():
        print(f"- {issue}: {count}")
    print()
    print("## Card Work Queue")
    print()
    print("| Issuer | Card | Issues |")
    print("|---|---|---|")
    for issuer, _card_id, name, issues in sorted(rows):
        issue_text = "<br>".join(issues) if issues else "Ready"
        print(f"| {issuer} | {name} | {issue_text} |")


if __name__ == "__main__":
    main()
