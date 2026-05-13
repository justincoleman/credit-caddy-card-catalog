#!/usr/bin/env node
// Credit Caddy card catalog validator.
// Runs on every PR; also runnable locally with `npm run validate`.
//
// Checks:
//   1. JSON Schema (via ajv) — HARD
//   2. Issuer-domain whitelist on every `sources.*` URL — HARD
//   3. Link-rot (HTTP 2xx/3xx on every source URL) — SOFT (warning only)
//      Reason: issuer WAFs reliably 403 against cloud IP ranges including
//      GitHub Actions runners. The authoritative liveness signal is the agent's
//      successful FireCrawl (or equivalent) fetch at write-time. A 403 here
//      means "our runner is blocked", not "the source URL is dead".
//   4. Two-citation rule for annualFee changes vs origin/main — HARD
//   5. No id may be deleted from cards (use `discontinued: true` instead) — HARD
//   6. Conditional earn rates must include structured condition metadata — HARD
//   7. Recently verified cards must cite every card field, earn-rate category,
//      and benefit with approved source URLs — HARD
//
// Env:
//   SKIP_HTTP_CHECK=1  — skip the network-dependent link-rot check (local dev)
//   BASE_REF=<ref>     — override the base ref for the diff (default origin/main)

import fs from 'node:fs/promises';
import path from 'node:path';
import { execSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import Ajv2020 from 'ajv/dist/2020.js';
import addFormats from 'ajv-formats';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const ROOT = path.resolve(__dirname, '..');
const CARDS_PATH = path.join(ROOT, 'cards.json');
const SCHEMA_PATH = path.join(ROOT, 'schema.json');

// Issuer → approved domain suffixes. Add an entry here when onboarding a new
// issuer to the agent's scope. Subdomains are allowed (e.g. cards.chase.com
// is allowed under "chase.com").
const ISSUER_DOMAINS = {
  'American Express': ['americanexpress.com'],
  Chase: ['chase.com'],
  Citi: ['citi.com'],
  'Capital One': ['capitalone.com'],
  'Bank of America': ['bankofamerica.com', 'alaskaair.com'],
  'US Bank': ['usbank.com'],
  Discover: ['discover.com'],
  'Wells Fargo': ['wellsfargo.com'],
  Barclays: ['barclaycardus.com', 'aa.com', 'hawaiianairlines.com'],
  Apple: ['apple.com'],
  'Column N.A.': ['biltrewards.com'],
  'Synchrony Bank': ['synchrony.com', 'amazon.com'],
};

const errors = [];
const warnings = [];
const err = (msg) => errors.push(msg);
const warn = (msg) => warnings.push(msg);

const CONDITION_TYPES = new Set([
  'activationRequired',
  'businessCategoryTopSpend',
  'chosenCategory',
  'directBooking',
  'foreignCurrency',
  'largePurchase',
  'merchant',
  'membershipRequired',
  'partnerProgram',
  'rotatingCategory',
  'travelPortal',
]);

const SPENDING_CATEGORIES = new Set([
  'airfare',
  'dining',
  'drugstores',
  'gas',
  'groceries',
  'hotels',
  'homeImprovement',
  'onlineShopping',
  'other',
  'rent',
  'streaming',
  'transit',
  'travel',
]);

const BENEFIT_CATEGORIES = new Set(['Dining', 'Travel', 'Shopping', 'Entertainment', 'Lifestyle']);
const ENTERTAINMENT_BENEFIT_PATTERN =
  /\b(apple tv|apple music|digital entertainment|disney|hulu|espn|streaming|stubhub|ticket|tickets|fandango|movie|movies|theater|concert|entertainment|peacock|paramount|netflix|spotify|audible|sirius|siriusxm|youtube tv|max|hbo|showtime|starz)\b/i;
const LIFESTYLE_BENEFIT_PATTERN =
  /\b(equinox|peloton|oura|fitness|wellness|lifestyle|gym|health)\b/i;
const BROAD_OTHER_EARN_PATTERN =
  /\b(all purchases|every purchase|everything else|other purchases|all other purchases|all eligible purchases|all other eligible purchases|non[- ]?bonus|base)\b/i;
const CONDITIONAL_OTHER_EARN_PATTERN =
  /\b(choice category|chosen category|select category|one chosen|two chosen|top eligible|top 2|top spend|rotating|activate|eligible business categories|large purchase|single purchases)\b/i;
const NARROW_UNSUPPORTED_OTHER_EARN_PATTERN =
  /\b(apple pay|apple purchases|mobile wallet|office suppl|advertising|phone plan|telephone|wireless|utilities|utility|fitness|gym|costco|entertainment|foreign currency|construction material|software\/cloud|shipping provider|internet, cable|cable and phone|social media|search engine)\b/i;

const SOURCE_REQUIRED_CARD_FIELDS = [
  'annualFee',
  'noForeignTransactionFees',
  'baseEarnRate',
  'rewardProgram',
];

function sourceUrls(value) {
  if (typeof value === 'string') return [value];
  if (Array.isArray(value) && value.every((item) => typeof item === 'string')) return value;
  return [];
}

function benefitSourceKey(name) {
  return `benefits.${String(name)
    .normalize('NFD')
    .replace(/[\u0300-\u036f]/g, '')
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, '-')
    .replace(/^-|-$/g, '')}`;
}

function validateSourcePresent(card, key) {
  const urls = sourceUrls(card.sources?.[key]);
  if (urls.length === 0) {
    err(`${card.id}: missing source for ${key}`);
  }
}

// -------- load --------
const [cardsRaw, schemaRaw] = await Promise.all([
  fs.readFile(CARDS_PATH, 'utf8'),
  fs.readFile(SCHEMA_PATH, 'utf8'),
]);
const cards = JSON.parse(cardsRaw);
const schema = JSON.parse(schemaRaw);

// -------- 1. schema --------
const ajv = new Ajv2020({ allErrors: true, strict: false });
addFormats(ajv);
const validate = ajv.compile(schema);
if (!validate(cards)) {
  for (const e of validate.errors) {
    err(`schema: ${e.instancePath || '<root>'} ${e.message}`);
  }
}

// -------- 2. issuer-domain whitelist + collect URLs --------
const urlEntries = []; // { url, card, field }

for (const card of cards.cards || []) {
  if (!card.sources) continue;

  const allowed = ISSUER_DOMAINS[card.issuer];
  if (!allowed) {
    err(
      `${card.id}: issuer "${card.issuer}" has no approved domain whitelist. ` +
        `Add it to ISSUER_DOMAINS in scripts/validate.mjs before citing any source URLs for this card.`
    );
    continue;
  }

  for (const [field, value] of Object.entries(card.sources)) {
    const urls = Array.isArray(value) ? value : [value];
    for (const url of urls) {
      let host;
      try {
        host = new URL(url).hostname.toLowerCase();
      } catch {
        err(`${card.id}.sources.${field}: unparseable URL: ${url}`);
        continue;
      }
      const ok = allowed.some((d) => host === d || host.endsWith('.' + d));
      if (!ok) {
        err(
          `${card.id}.sources.${field}: ${host} is not in the approved domain list for "${card.issuer}" (${allowed.join(', ')})`
        );
      }
      urlEntries.push({ url, card: card.id, field });
    }
  }
}

// -------- recently verified source completeness --------
//
// Older catalog records are being hardened issuer-by-issuer, so this gate is
// intentionally scoped to cards verified under the stricter 2026-05-08+
// standard. Any future agent-edited card that advances lastVerified must carry
// complete citations for the fields it claims to have verified.
for (const card of cards.cards || []) {
  if (typeof card.lastVerified !== 'string' || card.lastVerified < '2026-05-08') continue;

  if (!card.sources) {
    err(`${card.id}: recently verified card is missing sources`);
    continue;
  }

  for (const field of SOURCE_REQUIRED_CARD_FIELDS) {
    validateSourcePresent(card, field);
  }

  for (const rate of card.earnRates || []) {
    validateSourcePresent(card, `earnRates.${rate.category}`);
  }

  for (const benefit of card.benefits || []) {
    validateSourcePresent(card, benefitSourceKey(benefit.name));
    validateBenefitCategory(card, benefit);
  }
}

function validateBenefitCategory(card, benefit) {
  if (!BENEFIT_CATEGORIES.has(benefit.category)) {
    err(`${card.id}: benefit "${benefit.name}" uses unsupported category "${benefit.category}"`);
    return;
  }

  const text = benefit.name || '';
  if (ENTERTAINMENT_BENEFIT_PATTERN.test(text) && benefit.category !== 'Entertainment') {
    err(`${card.id}: benefit "${benefit.name}" should use Entertainment, not ${benefit.category}`);
  }
  if (LIFESTYLE_BENEFIT_PATTERN.test(text) && benefit.category !== 'Lifestyle') {
    err(`${card.id}: benefit "${benefit.name}" should use Lifestyle, not ${benefit.category}`);
  }
}

// -------- conditional earn-rate metadata --------
for (const card of cards.cards || []) {
  for (const [index, rate] of (card.earnRates || []).entries()) {
    if (rate.category === 'travel') {
      const scopes = Array.isArray(rate.appliesToCategories) ? rate.appliesToCategories : [];
      if (scopes.length === 0) {
        err(
          `${card.id}.earnRates[${index}]: travel ${rate.multiplier}x needs appliesToCategories[] ` +
            `so airfare/hotels inheritance cannot use the wrong travel sub-scope.`
        );
      }

      if (!scopes.includes('travel')) {
        err(`${card.id}.earnRates[${index}].appliesToCategories: travel rates must include "travel"`);
      }

      for (const scope of scopes) {
        if (!SPENDING_CATEGORIES.has(scope)) {
          err(`${card.id}.earnRates[${index}].appliesToCategories: unsupported category "${scope}"`);
        }
      }

      const notes = typeof rate.notes === 'string' ? rate.notes.toLowerCase() : '';
      const looksPortalScoped =
        notes.includes('portal')
        || notes.includes('travel center')
        || notes.includes('booked through')
        || notes.includes('chase travel')
        || notes.includes('citi travel')
        || notes.includes('capital one travel');
      if (looksPortalScoped && rate.isConditional !== true) {
        err(
          `${card.id}.earnRates[${index}]: travel ${rate.multiplier}x looks portal-scoped, ` +
            `so mark isConditional=true and add conditions[].`
        );
      }
    }

    validateEarnRateCategory(card, rate, index);

    if (!rate.isConditional) continue;

    const hasConditions = Array.isArray(rate.conditions) && rate.conditions.length > 0;
    const hasTimeWindows = Array.isArray(rate.timeWindows) && rate.timeWindows.length > 0;
    if (!hasConditions && !hasTimeWindows) {
      err(
        `${card.id}.earnRates[${index}]: conditional ${rate.category} ${rate.multiplier}x needs ` +
          `structured conditions[] or timeWindows[] metadata. Notes alone are not enough.`
      );
      continue;
    }

    for (const [conditionIndex, condition] of (rate.conditions || []).entries()) {
      if (!CONDITION_TYPES.has(condition.type)) {
        err(
          `${card.id}.earnRates[${index}].conditions[${conditionIndex}]: unsupported type "${condition.type}"`
        );
      }

      const hasDescriptor = [condition.label, condition.provider, condition.merchant, condition.details]
        .some((value) => typeof value === 'string' && value.trim().length > 0);
      if (!hasDescriptor) {
        err(
          `${card.id}.earnRates[${index}].conditions[${conditionIndex}]: add label, provider, merchant, or details`
        );
      }
    }
  }
}

function validateEarnRateCategory(card, rate, index) {
  if (rate.category !== 'other') return;

  const conditionText = (rate.conditions || [])
    .map((condition) => [condition.label, condition.provider, condition.merchant, condition.details].join(' '))
    .join(' ');
  const text = `${rate.notes || ''} ${conditionText}`;

  if (
    NARROW_UNSUPPORTED_OTHER_EARN_PATTERN.test(text)
    && !BROAD_OTHER_EARN_PATTERN.test(text)
    && !CONDITIONAL_OTHER_EARN_PATTERN.test(text)
  ) {
    err(
      `${card.id}.earnRates[${index}]: ${rate.multiplier}x is mapped to "other" but describes a narrow ` +
        `merchant/category the app does not model. Add a supported category or omit it from optimizer data.`
    );
  }
}

// -------- 3. link-rot HTTP check --------
async function httpOk(url) {
  try {
    const res = await fetch(url, {
      method: 'GET',
      redirect: 'follow',
      signal: AbortSignal.timeout(15000),
      headers: {
        // Real UA — some issuer sites reject the default fetch UA.
        'User-Agent':
          'Mozilla/5.0 (compatible; credit-caddy-catalog-validator/1.0; +https://github.com/justincoleman/credit-caddy-card-catalog)',
        Accept: 'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
      },
    });
    return { ok: res.status >= 200 && res.status < 400, status: res.status };
  } catch (e) {
    return { ok: false, status: 0, error: e.message || String(e) };
  }
}

if (process.env.SKIP_HTTP_CHECK === '1') {
  console.log(`[validate] SKIP_HTTP_CHECK=1 — skipping link-rot for ${urlEntries.length} URL(s)`);
} else if (urlEntries.length > 0) {
  console.log(`[validate] Checking ${urlEntries.length} source URL(s) for link-rot…`);
  const batchSize = 10;
  for (let i = 0; i < urlEntries.length; i += batchSize) {
    const chunk = urlEntries.slice(i, i + batchSize);
    const results = await Promise.all(
      chunk.map(async (e) => ({ entry: e, ...(await httpOk(e.url)) }))
    );
    for (const r of results) {
      if (!r.ok) {
        const detail = r.status ? `HTTP ${r.status}` : `network error: ${r.error}`;
        // Soft: issuer WAFs block our runner. If the cited URL was fetchable via
        // the agent's transport at write-time, that's the real signal.
        warn(`${r.entry.card}.sources.${r.entry.field}: ${detail} — soft warning, likely WAF (${r.entry.url})`);
      }
    }
  }
}

// -------- 4 & 5. diff-aware checks --------
const baseRef = process.env.BASE_REF || 'origin/main';
let prevCards = null;
try {
  const prev = execSync(`git show ${baseRef}:cards.json`, {
    encoding: 'utf8',
    stdio: ['ignore', 'pipe', 'ignore'],
  });
  prevCards = JSON.parse(prev);
} catch {
  console.log(`[validate] no ${baseRef}:cards.json available — skipping diff checks (first-run or fresh clone)`);
}

if (prevCards) {
  const prevById = new Map((prevCards.cards || []).map((c) => [c.id, c]));

  const currentCardsJson = JSON.stringify(cards.cards || []);
  const previousCardsJson = JSON.stringify(prevCards.cards || []);
  if (currentCardsJson !== previousCardsJson) {
    if (cards.version < prevCards.version) {
      err(
        `catalog version must not move backward when cards.json data changes (${prevCards.version} → ${cards.version}).`
      );
    }
    if (cards.lastUpdated <= prevCards.lastUpdated) {
      err(
        `catalog lastUpdated must advance when cards.json data changes (${prevCards.lastUpdated} → ${cards.lastUpdated}).`
      );
    }
  }

  // 4. annualFee two-citation rule
  for (const card of cards.cards || []) {
    const prev = prevById.get(card.id);
    if (!prev) continue; // new card — single citation is fine
    if (prev.annualFee === card.annualFee) continue; // unchanged

    const src = card.sources?.annualFee;
    if (!src) {
      err(
        `${card.id}: annualFee changed (${prev.annualFee} → ${card.annualFee}) but sources.annualFee is missing. ` +
          `Changes to annualFee require two independent citations.`
      );
      continue;
    }
    if (!Array.isArray(src) || src.length !== 2) {
      err(
        `${card.id}: annualFee changed (${prev.annualFee} → ${card.annualFee}) — ` +
          `sources.annualFee must be an array of exactly 2 URLs (two-citation rule).`
      );
    }
  }

  // 5. no-deletion rule
  const currentIds = new Set((cards.cards || []).map((c) => c.id));
  for (const prevId of prevById.keys()) {
    if (!currentIds.has(prevId)) {
      err(`${prevId}: card removed from catalog — deletions are not allowed. Mark the card "discontinued": true instead.`);
    }
  }
}

// -------- report --------
if (warnings.length > 0) {
  console.warn(`\n⚠️  ${warnings.length} warning(s) (non-blocking):`);
  for (const w of warnings) console.warn('  • ' + w);
}

if (errors.length > 0) {
  console.error(`\n❌ Validation failed with ${errors.length} error(s):\n`);
  for (const e of errors) console.error('  • ' + e);
  process.exit(1);
}

console.log(
  `\n✅ Validation passed. ${cards.cards.length} card(s), ${urlEntries.length} source URL(s) checked.`
);
