# claude-code-statusline

A single-file, dependency-light statusline script for [Claude Code](https://docs.claude.com/en/docs/claude-code) that shows — right at the bottom of your terminal:

```
Fable 5 (effort:high) | my-project | git:main
ctx ██████░░░░ 67% | session:3% weekly:9% fable_weekly:15%
```

Line 1:
- **Model + effort level** — which model you're talking to and its current reasoning effort
- **Working directory + git branch**

Line 2:
- **Context bar** — how full the current conversation's context window is, as a 10-segment bar colored green (< 60%) → yellow (60–79%) → red (≥ 80%), from the `context_window` data in the statusline stdin payload
- **Subscription usage** — the same plan-level quota data you'd get from `/usage` (5-hour session window, 7-day window, and per-model weekly limits), fetched from Anthropic's OAuth usage endpoint

Works on **macOS**, **Windows (Git Bash)**, and **Linux** from the same script.

## Why

Claude Code's statusline API pipes a JSON payload to your script after each interaction, but that payload only covers session-local data (model, directory, context, cost). Plan-level quota — how much of your 5h / 7d allowance is left — is only visible by manually running `/usage`.

This script fills the gap without installing a plugin: it reads your existing Claude Code OAuth credentials locally and queries the usage endpoint directly, so the numbers in your statusline match `/usage`.

## How it works

```
Claude Code ──stdin JSON──▶ statusline.sh ──stdout (2 lines)──▶ terminal statusline
                                 │
                                 ├─ jq: parse model / effort / cwd / context_window from stdin
                                 ├─ git: current branch (--no-optional-locks)
                                 └─ usage:
                                      ├─ cache fresh (< 5 min)? → read cache
                                      └─ else → read OAuth token
                                               → GET /api/oauth/usage
                                               → 200: write cache | 429: back off 10 min
```

### Design points

- **Event-driven, not polled.** Claude Code re-runs the script after each assistant reply (plus UI events like `/compact`), with debouncing. The script itself never runs in the background.
- **5-minute cache + 429 backoff.** Statusline refreshes can be frequent; the usage API call is throttled to at most once per 5 minutes (`TTL=300`), and a 429 response pauses further calls for 10 minutes. Delete the cache file to force a refresh.
- **Cross-platform via two small shims.**
  - `get_token()` — macOS reads the OAuth credential from the Keychain (`security find-generic-password`); Windows (Git Bash) and Linux read `~/.claude/.credentials.json`.
  - `mtime()` — tries GNU `stat -c %Y`, falls back to BSD `stat -f %m`.
- **Fail quiet.** If the token can't be read, the API changes shape, or the request times out (3s cap), the usage segment simply disappears — the rest of the statusline still renders. Same for the context bar: `context_window.used_percentage` can be `null` early in a session, in which case the script recomputes it from `total_input_tokens / context_window_size`, and if that's missing too the bar is omitted.
- **bash 3.2 compatible.** The context bar is built by slicing two 10-char literals (`${FULL:0:filled}`) instead of appending `█` in a loop — macOS's stock bash 3.2 silently drops bytes when appending multibyte characters one at a time under a UTF-8 locale.
- **Effort fallback.** Effort is read from the stdin payload (`.effort.level`) when the running Claude Code version provides it, falling back to `effortLevel` in `~/.claude/settings.json` for older versions (the fallback reflects persisted config only, not session-scoped overrides).
- **Local only.** The token is read at call time, sent only to `api.anthropic.com`, and never written to disk. The cache file contains just the usage response (percentages, reset timestamps) — no credentials.

### Requirements

- `bash`, `curl`, `git` — preinstalled on macOS and Git Bash
- [`jq`](https://jqlang.github.io/jq/) — `brew install jq` on macOS; on Windows drop `jq.exe` into a directory on your `PATH` (e.g. `C:\Program Files\Git\usr\bin\`)
- A Claude **Pro / Max / Team subscription** signed in via OAuth. API-key, Bedrock, and Vertex setups have no subscription quota, so the usage segment won't appear (the rest still works).

## Install

### 1. Get the script

```bash
curl -o ~/.claude/statusline.sh https://raw.githubusercontent.com/<you>/<repo>/main/statusline.sh
chmod +x ~/.claude/statusline.sh
```

Or clone and copy. **Windows note:** keep the file LF-ended, UTF-8 without BOM. CRLF line endings are the #1 cause of `\r: command not found` errors in Git Bash.

### 2. Point Claude Code at it

In `~/.claude/settings.json`:

```json
{
  "statusLine": {
    "type": "command",
    "command": "bash ~/.claude/statusline.sh"
  }
}
```

### 3. Verify credentials access

**macOS**

```bash
security find-generic-password -s "Claude Code-credentials" -w | jq -r '.claudeAiOauth.accessToken' | head -c 20
```

The first run may pop a Keychain authorization dialog — choose **Always Allow**, otherwise every statusline refresh will prompt. If the entry isn't found, list candidates with `security dump-keychain | grep -i claude` and adjust the `-s` service name in `get_token()`.

**Windows (Git Bash) / Linux**

```bash
jq -r '.claudeAiOauth.accessToken' ~/.claude/.credentials.json | head -c 20
```

Both should print a token prefix (typically `sk-ant-oat…`).

### 4. Smoke-test without Claude Code

```bash
echo '{"model":{"display_name":"Fable 5"},"effort":{"level":"high"},"workspace":{"current_dir":"'$HOME'"},"context_window":{"used_percentage":42}}' | bash ~/.claude/statusline.sh
```

Expected output (usage appears from the second run once the cache exists):

```
Fable 5 (effort:high) | yourname
ctx ████░░░░░░ 42% | session:3% weekly:9% fable_weekly:15%
```

### 5. Restart Claude Code

Open a new session and send a message — the statusline renders after the first reply.

## Usage endpoint & response shape

The script calls `GET https://api.anthropic.com/api/oauth/usage` with your OAuth access token and the `anthropic-beta: oauth-2025-04-20` header. The response contains a `limits` array; each entry looks like:

| field | meaning |
|---|---|
| `kind` | `session` (5h rolling window), `weekly_all` (7d, all models), `weekly_scoped` (7d, one model — see `scope.model`) |
| `percent` | utilization as an integer percentage (already ×100) |
| `resets_at` | ISO timestamp of the next window reset |
| `severity` | `normal` under no pressure; other values under quota pressure |
| `is_active` | whether this limit currently binds |

The jq block in the script maps `session` → `session:N%`, `weekly_all` → `weekly:N%`, and `weekly_scoped` → `<model>_weekly:N%`. Rename the labels there to taste.

## ⚠️ Caveats

- **Undocumented endpoint.** `/api/oauth/usage` is not part of Anthropic's public API. Field names or the endpoint itself may change or disappear without notice. When that happens the usage segment silently drops out; fix by inspecting the new response (`jq . <cache-file>`) and updating the jq block.
- **Numbers refresh on interaction, not on a timer.** If a window resets while you're idle, the statusline shows stale percentages until your next message. Live countdowns are out of scope for the statusline mechanism.
- **Per-machine credentials, account-wide numbers.** The token is machine-local, but the quota it reports is your account's — usage from other devices is already included.

## Customization ideas

- **Reset countdown** — parse `resets_at` and append e.g. `(rst 1h23m)`. On macOS, avoid BSD `date` parsing pain by converting via `python3 -c "from datetime import datetime; …"` or installing GNU coreutils.
- **Severity colors** — swap the dim `\033[2m` styling for yellow/red when any limit's `severity` isn't `normal`.
- **Cost data** — the stdin payload also carries a `cost` object; extra-usage spend lives in the API response's `spend` object.
- **Bar width / thresholds** — the context bar is 10 segments with green/yellow/red cut-offs at 60% and 80%; both are one-line tweaks in the "第二行" block.

## License

MIT
