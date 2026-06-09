# Credit Caddy Card Catalog

Static JSON feed describing the credit cards known to [Credit Caddy](https://github.com/justincoleman/CreditBenefitsTracker), an iOS app for tracking credit card benefits and rewards programs.

This repo is the source of truth for the in-app card catalog. The iOS client fetches `cards.json` from the `main` branch on cold launch and uses it to:
- Populate "Add from template" when users add a new card
- Detect when an existing user's card has diverged from the current catalog (field changes, added/removed credits) and surface those as suggestions — never applied silently

## Update model

- **Catalog updates are agent-maintained.** A scheduled Claude task runs once a month (1st of the month, 12:00 UTC), re-verifies each card's fields against the issuer's own website, and opens a pull request. A human (the app owner) reviews and merges.
- **No manual edits to `cards.json` on `main`.** All changes land via PR so the validation gate runs. Manual changes are welcome via PR.
- **Every data change must advance freshness metadata.** If any card data changes, update top-level `lastUpdated` (ISO 8601 UTC). Keep `version` as the current date tag (`YYYY.MM.DD`) and never move it backward. The iOS app compares `lastUpdated` to decide whether to fetch, cache, and reconcile earn-rate metadata; stale timestamps can leave users on old card data.
- **GitHub `main` is the source of truth.** After a catalog PR merges, sync the app's bundled `Resources/CardCatalog.json` from this repo's `cards.json` before cutting an app build. The bundle is the offline fallback, but it should never be treated as more authoritative than this repo.
- **Every mutable field requires a citation.** The agent writes a `sources` map on each card whose URLs point back to the issuer's domain. If the agent can't cite a value on a given run, it leaves the prior value in place.
- **Annual fee changes require two independent citations** on the issuer's domain.
- **Nothing gets deleted.** Cards that go away are marked `discontinued: true`; they stay in the catalog so that users who still have the card continue to have their stable id resolve.

## Agent scope

The scheduled agent audits the full catalog. It derives the work queue from
`cards.json`, groups cards by issuer, verifies card facts against issuer-owned
sources, and opens a PR only when catalog data changes.

## File layout

| File | Purpose |
| --- | --- |
| `cards.json` | The live catalog the iOS app consumes |
| `schema.json` | JSON Schema used by the PR validation workflow |
| `scripts/audit_card_catalog.py` | Local optimizer-readiness audit for source coverage, verification coverage, and earn-rate quality |
| `.github/workflows/validate.yml` | Validates every PR: schema, sanity ranges, issuer-domain sources, link-rot |

## Schema

See [`schema.json`](schema.json) for the authoritative spec. Summary:

```jsonc
{
  "schemaVersion": 1,                   // bumps only on breaking client changes
  "version": "2026.04.24",              // YYYY.MM.DD, advances on every merge to main
  "lastUpdated": "2026-04-24T12:00:00Z",// ISO 8601 UTC
  "cards": [
    {
      "id": "american-express-platinum-card",
      "cardName": "Platinum Card",
      "issuer": "American Express",
      "annualFee": 895,
      "noForeignTransactionFees": true,
      "earnRates": [ /* ... */ ],
      "baseEarnRate": 1.0,
      "rewardProgram": "American Express Membership Rewards",
      "affiliateUrl": null,
      "colorHex": "BFC0C0",
      "benefits": [ /* ... each may carry an optional editorial "guide" ... */ ],
      "cardGuide": {                     // optional, curated editorial (not agent-maintained)
        "overview": "How to think about this card…",
        "sections": [ { "title": "Is the fee worth it?", "points": ["…"] } ]
      },
      "discontinued": false,             // optional
      "lastVerified": "2026-04-24T12:00:00Z",  // optional; set by the agent on re-verify
      "sources": {                       // optional; set by the agent per changed/new field
        "annualFee": ["https://americanexpress.com/...", "https://americanexpress.com/..."],
        "benefits.uber-cash": "https://americanexpress.com/..."
      }
    }
  ]
}
```

`sources.annualFee` may be a single URL (unchanged) or an array of exactly two URLs (on change — see the two-citation rule).

**Editorial content.** `benefits[].guide` (whatItIs / howItWorks / maximizingTips) and the card-level `cardGuide` are curated by hand from research — they answer "how do I get the most out of this card?" The monthly issuer-verification agent **preserves them verbatim and never authors or overwrites them**; it only verifies factual fields (fees, rates, benefit existence, signup bonus) against issuer sources. They're exempt from the issuer-only citation rule.

## Source of truth rules

- URLs in `sources` must be HTTPS and must be on the issuer's own domain. No third-party blogs, press-release wires, or aggregators.
- Approved issuer domains are maintained in `scripts/validate.mjs` and mirrored
  in `local/agent-prompt.md`. The current full-catalog set covers American
  Express, Apple, Bank of America/Alaska, Barclays/co-brand airline domains,
  Capital One, Chase, Citi, Bilt, Discover, US Bank, and Wells Fargo.
- The validation workflow re-checks every `sources` URL on every PR and blocks merge on 404/5xx.

## Consuming this catalog

The iOS client fetches:

```
https://raw.githubusercontent.com/justincoleman/credit-caddy-card-catalog/main/cards.json
```

If the fetch fails or the `schemaVersion` is higher than the client understands, the client falls back to its bundled copy. The client never writes catalog changes directly into user records — it only ever surfaces them as per-field suggestions the user can accept individually.

## License

The data here is assembled from publicly available information on the issuers' own websites. Issuer names, card names, and program names are the trademarks of their respective owners. The JSON structure and tooling in this repo are available under the MIT License.
