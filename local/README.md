# Local launchd agent (Mac mini)

Runs the monthly card catalog refresh on a Mac that's on 24/7, instead of
in the Anthropic cloud trigger environment. Local execution sidesteps the
WAF/proxy-pool blocking we hit from cloud IPs against issuer sites.

## Files

| File | Purpose |
| --- | --- |
| `agent-prompt.md` | The canonical prompt the agent receives. Single source of truth. References `$FIRECRAWL_API_KEY` from the environment — never holds the key directly. |
| `run-agent.sh` | Wrapper: sources secrets, refreshes the repo, runs `claude -p`, logs to `~/Library/Logs/credit-caddy-agent/`. |
| `com.creditcaddy.catalog-agent.plist.template` | launchd job spec — fires monthly on the 1st at 08:00 local. |
| `install.sh` | Renders the plist with your `$HOME` path and loads the launchd job. |
| `uninstall.sh` | Unloads + removes the plist. Preserves logs. |
| `secrets.env.example` | Template for the secrets file you create at `~/.config/credit-caddy/secrets.env` (NOT in this repo). |

## Prerequisites on the Mac mini

The runner needs these on `PATH` (Homebrew Apple Silicon defaults work):

- `claude` — Claude Code CLI, **logged in** (run `claude` once interactively to verify)
- `git` — installed, with an **SSH key registered with GitHub** (the wrapper uses SSH for push, so OAuth-token scopes don't matter for push)
- `gh` — GitHub CLI, authenticated with `repo` scope (`gh auth status` should pass; needed for `gh pr create`)
- `node`, `npm` — for the validator
- `jq`, `curl` — for the FireCrawl fetch pattern

Quick check:
```sh
for cmd in claude git gh jq node npm curl; do command -v $cmd >/dev/null && echo "✓ $cmd" || echo "✗ $cmd MISSING"; done
gh auth status
ssh -T git@github.com   # should print "Hi <username>! You've successfully authenticated"
```

If SSH auth doesn't work yet:
```sh
# Generate a key if you don't have one
[ -f ~/.ssh/id_ed25519 ] || ssh-keygen -t ed25519 -C "$(hostname)-credit-caddy"
# Register the public key with GitHub
gh ssh-key add ~/.ssh/id_ed25519.pub --title "$(hostname) credit-caddy"
# Verify
ssh -T git@github.com
```

If `gh` is missing the `repo` scope:
```sh
gh auth refresh -h github.com -s repo
```

## Setup

```sh
# 1. Clone the catalog repo into your home directory
git clone https://github.com/justincoleman/credit-caddy-card-catalog ~/credit-caddy-card-catalog

# 2. Create the local secrets file with your FireCrawl key
mkdir -p ~/.config/credit-caddy
cp ~/credit-caddy-card-catalog/local/secrets.env.example ~/.config/credit-caddy/secrets.env
$EDITOR ~/.config/credit-caddy/secrets.env   # paste your real fc-... key
chmod 600 ~/.config/credit-caddy/secrets.env

# 3. Run the installer
~/credit-caddy-card-catalog/local/install.sh
```

That's it. The job is now registered with launchd and will fire at **08:00 local time on the 1st of each month**.

The secrets file lives **outside** the repo (this repo is public). The wrapper script sources it before invoking the agent, so the FireCrawl key is in the agent's environment but never written to disk inside the repo.

## Manual test (recommended before waiting for the 1st)

```sh
# Fire a run right now without waiting for the cron
launchctl start com.creditcaddy.catalog-agent

# Watch live progress (Ctrl-C to stop tailing — the run continues)
tail -f ~/Library/Logs/credit-caddy-agent/run-*.log
```

Expected outcome on a successful run: a new branch `refresh/<date>` and an open PR titled "Catalog refresh `<date>` (Amex pilot)" in [credit-caddy-card-catalog](https://github.com/justincoleman/credit-caddy-card-catalog/pulls).

If FireCrawl fails or no cards changed, the agent should print "no changes" and **not** open a PR (per the prompt's Step 5 + Step 7 rules — version bumps are conditional on real card-level changes).

## Cost

Each run uses your Anthropic API quota via Claude Code (Sonnet 4.6). The wrapper caps each run at **\$5** via `--max-budget-usd`. Typical monthly run is well under \$2 for the 13-card Amex pilot.

FireCrawl free tier covers ~500 scrapes/month, which is plenty (we use ~20-30 per run).

## Updating the prompt

The agent reads `local/agent-prompt.md` from the repo at the start of every run. To change behavior:

1. Edit `local/agent-prompt.md` on any machine
2. Commit + push to `main`
3. Next monthly run (or next manual `launchctl start`) automatically picks up the new version

No redeploy of the launchd job needed.

## Troubleshooting

- **`launchctl list` shows the job, but it doesn't fire on the 1st** — check the Mac mini was awake at 08:00. launchd skips missed runs unless you set `StartCalendarInterval` differently. If the mini sleeps, fire on next wake or use `pmset` to keep awake.
- **`claude` command not found from launchd** — launchd doesn't load your shell rc files. The plist sets `PATH=/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin`. If `claude` lives elsewhere on your machine, edit the plist's `EnvironmentVariables` block and add the path, then re-run `install.sh`.
- **`gh auth status` fails inside the run** — the wrapper aborts early with a clear error. Run `gh auth login` once interactively to fix.
- **PR never opens but the log says the agent ran** — read the run log; the agent prints a final report explaining "no changes" or "manual review needed". This is by design when FireCrawl can't fetch real data.

## Removing

```sh
~/credit-caddy-card-catalog/local/uninstall.sh
```

Logs in `~/Library/Logs/credit-caddy-agent/` are preserved for reference.
