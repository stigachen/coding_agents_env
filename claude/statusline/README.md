# statusline — 两行状态栏

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
- **Subscription usage** — the same plan-level quota data you'd get from `/usage`: the 5-hour session window and 7-day window come straight from the `rate_limits` object Claude Code puts in the statusline stdin payload. Optionally (`CLAUDE_STATUSLINE_USAGE_API=1` in `~/.config/coding_agents_env/notify.env`, off by default) the per-model weekly limit (`fable_weekly:N%`) is added from Anthropic's OAuth usage endpoint, which is then also the fallback for everything on Claude Code versions without `rate_limits`

Works on **macOS**, **Windows (Git Bash)**, and **Linux** from the same script.

> 安装方式见仓库根目录 README / `install.sh` —— 状态栏作为本仓库的一个模块统一部署。

## Why

Claude Code's statusline API pipes a JSON payload to your script after each interaction. Current versions include a `rate_limits` object there (5h / 7d `used_percentage`, Pro/Max only, present from the first API response of a session onward), so plan-level quota can be shown without any credentials or network access. Older versions only carry session-local data (model, directory, context, cost), and plan-level quota was only visible by manually running `/usage`.

This script shows the quota without installing a plugin. It takes the 5h / 7d numbers from stdin `rate_limits` whenever present. With `CLAUDE_STATUSLINE_USAGE_API=1` it additionally reads your existing Claude Code OAuth credentials locally to query the usage endpoint, which is the only source for the per-model weekly limit (stdin doesn't carry scoped limits) and the fallback for all three numbers when stdin has none. That endpoint is undocumented and the OAuth token is nominally for Claude Code's own use, so the API path is **off by default**: out of the box the script never reads credentials or makes network requests. Either way the numbers match `/usage`.

## How it works

```
Claude Code ──stdin JSON──▶ statusline.sh ──stdout (2 lines)──▶ terminal statusline
                                 │
                                 ├─ jq: parse model / effort / cwd / context_window from stdin
                                 ├─ git: current branch (--no-optional-locks)
                                 └─ usage (two sources, merged):
                                      ├─ stdin rate_limits → session:N% weekly:N%  (no token, no network)
                                      └─ OAuth usage API  → <model>_weekly:N%       (+ session/weekly when stdin has none)
                                           only if CLAUDE_STATUSLINE_USAGE_API=1 in ~/.config/coding_agents_env/notify.env (default 0):
                                           ├─ cache fresh (< 5 min)? → read cache
                                           └─ else → read OAuth token
                                                    (macOS: Keychain, then ~/.claude/.credentials.json;
                                                     Windows / Linux: ~/.claude/.credentials.json)
                                                    → GET /api/oauth/usage
                                                    → 200: write cache | 429: back off 10 min
```

### Design points

- **Event-driven, not polled.** Claude Code re-runs the script after each assistant reply (plus UI events like `/compact`), with debouncing. The script itself never runs in the background.
- **Two sources, merged.** When the payload carries `rate_limits`, `session` and `weekly` are built from `rate_limits.five_hour.used_percentage` / `rate_limits.seven_day.used_percentage` (floored to integers) — these are always current and need no credentials. The API response is then used only for its `weekly_scoped` entries (`fable_weekly:N%`), because stdin doesn't carry per-model limits. When stdin has no `rate_limits` (older Claude Code, or before the session's first API response) all three come from the API. If the API path fails, you still get session/weekly from stdin; if stdin has nothing either, the usage segment is omitted.
- **API path is opt-in.** `CLAUDE_STATUSLINE_USAGE_API` in `~/.config/coding_agents_env/notify.env` (the per-machine file shared by all agents that also holds the notification switches; `install.sh` adds the key with its default and migrates the old `STATUSLINE_USAGE_API` key) gates the whole API path. Default `0`: no credential read, no request, no cache, no markers — the segment is just what stdin provides. Set `1` to get the per-model weekly line, or if your Claude Code is too old to provide `rate_limits` at all. The script reads only that one key from the file (no `eval`), so IM tokens never enter the statusline process. Changes take effect on the next refresh.
- **5-minute cache + 429 backoff.** Statusline refreshes can be frequent; the usage API call is throttled to at most once per 5 minutes (`TTL=300`), and a 429 response pauses further calls for 10 minutes. Delete the cache file to force a refresh.
- **API health is visible, not silent** (with `CLAUDE_STATUSLINE_USAGE_API=1`). Because the per-model line comes from a cache that is only rewritten on a successful fetch, a broken API path would otherwise keep showing stale numbers forever. The script marks the API-sourced part instead:
  | shown | meaning |
  |---|---|
  | `fable_weekly:8%` | cache is ≤ 10 min old (one failed refresh is tolerated silently) |
  | `fable_weekly:8%(23m)` | cache is 23 min old: at least two consecutive refreshes failed (token unreadable, endpoint changed, offline) |
  | `fable_weekly:8%(429)` | last fetch was rate-limited; retries automatically after 10 min |
  | `fable_weekly:--` | stdin provided session/weekly but the API path has never succeeded on this machine (no cache file) |

  The label before `_weekly` is the first word of the current model's display name when the cache is missing, or the model name from the API response otherwise. When stdin has no `rate_limits`, the same `(Nm)` / `(429)` suffix is appended to the whole segment.
- **Cross-platform via two small shims.**
  - `get_token()` — macOS tries the Keychain first (`security find-generic-password`) and falls back to `~/.claude/.credentials.json`; Windows (Git Bash) and Linux read `~/.claude/.credentials.json` directly. The macOS fallback matters because the statusline runs as a non-interactive child of Claude Code: if the Keychain item lacks an "Always Allow" grant (re-logging in creates a fresh item and resets it), `security` fails with `errSecInteractionNotAllowed` (exit 36) instead of prompting, and the usage segment would silently vanish.
  - `mtime()` — tries GNU `stat -c %Y`, falls back to BSD `stat -f %m`.
- **Fail quiet.** If the token can't be read, the API changes shape, or the request times out (3s cap), the usage segment simply disappears — the rest of the statusline still renders. Same for the context bar: `context_window.used_percentage` can be `null` early in a session, in which case the script recomputes it from `total_input_tokens / context_window_size`, and if that's missing too the bar is omitted.
- **Locale-independent rendering.** The context bar is emitted as raw UTF-8 bytes via `printf` octal escapes (`\342\226\210` = `█`, `\342\226\221` = `░`) rather than manipulating multibyte characters as shell strings. This sidesteps two portability traps at once: macOS's stock bash 3.2 silently drops bytes when appending multibyte characters under a UTF-8 locale, and character-based substring slicing miscounts under C/POSIX locales (bytes vs characters). Output is byte-identical across macOS / Git Bash / Linux and any locale; a `.gitattributes` pins `*.sh` to LF so Windows checkouts with `core.autocrlf=true` can't break the script.
- **Effort fallback.** Effort is read from the stdin payload (`.effort.level`) when the running Claude Code version provides it, falling back to `effortLevel` in `~/.claude/settings.json` for older versions (the fallback reflects persisted config only, not session-scoped overrides).
- **Local only.** The token is read at call time, sent only to `api.anthropic.com`, and never written to disk. The cache file contains just the usage response (percentages, reset timestamps) — no credentials.

### Requirements

- `bash`, `curl`, `git` — preinstalled on macOS and Git Bash
- [`jq`](https://jqlang.github.io/jq/) — `brew install jq` on macOS; on Windows drop `jq.exe` into a directory on your `PATH` (e.g. `C:\Program Files\Git\usr\bin\`)
- A Claude **Pro / Max / Team subscription** signed in via OAuth. API-key, Bedrock, and Vertex setups have no subscription quota, so the usage segment won't appear (the rest still works).

## Verify & smoke-test

### Credentials access

Only relevant with `CLAUDE_STATUSLINE_USAGE_API=1`: needed for the per-model weekly line (`fable_weekly:N%`), and for everything if your Claude Code version doesn't put `rate_limits` in the statusline payload. If that line shows up in a normal session, skip this.

**macOS**

```bash
security find-generic-password -s "Claude Code-credentials" -w | jq -r '.claudeAiOauth.accessToken' | head -c 20
```

This may pop a Keychain authorization dialog — choose **Always Allow** if you want the Keychain path to work from Claude Code's non-interactive statusline process. If you don't, or the dialog was dismissed, the script transparently falls back to `~/.claude/.credentials.json`; to confirm what the statusline itself sees, run the command with stdin detached: `security find-generic-password -s "Claude Code-credentials" -w </dev/null >/dev/null; echo $?` — `36` means "user interaction not allowed" and the file fallback is in use. If the entry isn't found, list candidates with `security dump-keychain | grep -i claude` and adjust the `-s` service name in `get_token()`.

**Windows (Git Bash) / Linux (and macOS fallback)**

```bash
jq -r '.claudeAiOauth.accessToken' ~/.claude/.credentials.json | head -c 20
```

Both should print a token prefix (typically `sk-ant-oat…`).

### Smoke-test without Claude Code

```bash
echo '{"model":{"display_name":"Fable 5"},"effort":{"level":"high"},"workspace":{"current_dir":"'$HOME'"},"context_window":{"used_percentage":42}}' | bash statusline.sh
```

Expected output with `CLAUDE_STATUSLINE_USAGE_API=1` (this payload has no `rate_limits`, so all three numbers come from the API; usage appears from the second run once the cache exists). With the default `0` this payload yields no usage segment at all, because there is nothing on stdin either:

```
Fable 5 (effort:high) | yourname
ctx ████░░░░░░ 42% | session:3% weekly:9% fable_weekly:15%
```

To see the merged behaviour, add a `rate_limits` object to the payload — session/weekly then come from stdin and only the scoped line from the API:

```bash
echo '{"model":{"display_name":"Fable 5"},"workspace":{"current_dir":"'$HOME'"},"context_window":{"used_percentage":42},"rate_limits":{"five_hour":{"used_percentage":23.5},"seven_day":{"used_percentage":41.2}}}' | bash statusline.sh
# CLAUDE_STATUSLINE_USAGE_API=1 → ctx ████░░░░░░ 42% | session:23% weekly:41% fable_weekly:15%
# CLAUDE_STATUSLINE_USAGE_API=0 → ctx ████░░░░░░ 42% | session:23% weekly:41%
```

### Troubleshooting `--` / `(Nm)` / `(429)`

These markers only exist with `CLAUDE_STATUSLINE_USAGE_API=1`. If you see no usage segment at all with the default `0`, your Claude Code isn't providing `rate_limits` yet (older version, or the session hasn't had its first API response) — either wait a turn or enable the API path.

- `(429)` — nothing to do; the script backs off for 10 minutes and retries by itself.
- `--` or `(Nm)` — the API path can't complete. Run the smoke test above from a terminal: if it prints `fable_weekly:N%` and creates `$TMPDIR/claude-statusline-usage.json`, credentials work from an interactive shell but not from Claude Code's non-interactive statusline process — on macOS that means the Keychain item needs an "Always Allow" grant, or `~/.claude/.credentials.json` is missing/expired (see *Credentials access*). If the smoke test itself fails, check network access to `api.anthropic.com` and whether the endpoint's response shape changed (`jq . "$TMPDIR/claude-statusline-usage.json"`).
- The marker clears on the next successful fetch; delete the cache file to force one immediately.

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

- **Undocumented endpoint.** `/api/oauth/usage` is not part of Anthropic's public API. Field names or the endpoint itself may change or disappear without notice. When that happens the per-model weekly line silently drops out (session/weekly keep coming from stdin); fix by inspecting the new response (`jq . <cache-file>`) and updating the jq block. The stdin `rate_limits` fields are documented by Claude Code and unaffected.
- **Numbers refresh on interaction, not on a timer.** If a window resets while you're idle, the statusline shows stale percentages until your next message. Live countdowns are out of scope for the statusline mechanism.
- **Per-machine credentials, account-wide numbers.** The token is machine-local, but the quota it reports is your account's — usage from other devices is already included.

## Customization ideas

- **Reset countdown** — parse `resets_at` and append e.g. `(rst 1h23m)`. On macOS, avoid BSD `date` parsing pain by converting via `python3 -c "from datetime import datetime; …"` or installing GNU coreutils.
- **Severity colors** — swap the dim `\033[2m` styling for yellow/red when any limit's `severity` isn't `normal`.
- **Cost data** — the stdin payload also carries a `cost` object; extra-usage spend lives in the API response's `spend` object.
- **Bar width / thresholds** — the context bar is 10 segments with green/yellow/red cut-offs at 60% and 80%; both are one-line tweaks in the "第二行" block.
