#!/bin/bash
input=$(cat)

# ---- 平台检测 ----
IS_MAC=0
[ "$(uname)" = "Darwin" ] && IS_MAC=1

# 文件 mtime（GNU stat / BSD stat 兼容）
mtime() { stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null || echo 0; }

# ---- 模型 + effort ----
model=$(echo "$input" | jq -r '.model.display_name')
effort=$(echo "$input" | jq -r '.effort.level // empty')
[ -z "$effort" ] && effort=$(jq -r '.effortLevel // empty' ~/.claude/settings.json 2>/dev/null)

# ---- 目录 + git ----
dir=$(echo "$input" | jq -r '.workspace.current_dir')
cwd_display=$(basename "$dir")
branch=""
if git -C "$dir" --no-optional-locks rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  branch=$(git -C "$dir" --no-optional-locks branch --show-current 2>/dev/null)
fi

# ---- usage（5 分钟缓存 + 429 退避）----
CACHE="${TMPDIR:-/tmp}/claude-statusline-usage.json"
BACKOFF="${TMPDIR:-/tmp}/claude-statusline-usage.backoff"
TTL=300
usage=""

get_token() {
  if [ "$IS_MAC" = "1" ]; then
    # macOS: 凭据存在 Keychain
    security find-generic-password -s "Claude Code-credentials" -w 2>/dev/null \
      | jq -r '.claudeAiOauth.accessToken // empty'
  else
    # Windows (Git Bash) / Linux: 凭据文件
    jq -r '.claudeAiOauth.accessToken // empty' \
      "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/.credentials.json" 2>/dev/null
  fi
}

fetch_usage() {
  local token resp http_code
  token=$(get_token)
  [ -z "$token" ] && return 1
  resp=$(curl -sS -m 3 -w '\n%{http_code}' \
    -H "Authorization: Bearer $token" \
    -H "anthropic-beta: oauth-2025-04-20" \
    "https://api.anthropic.com/api/oauth/usage" 2>/dev/null)
  http_code=$(echo "$resp" | tail -1)
  if [ "$http_code" = "200" ]; then
    echo "$resp" | sed '$d' > "$CACHE"
    rm -f "$BACKOFF"
    return 0
  elif [ "$http_code" = "429" ]; then
    touch "$BACKOFF"
  fi
  return 1
}

now=$(date +%s)
cache_age=$(( now - $(mtime "$CACHE") ))
backoff_age=$(( now - $(mtime "$BACKOFF") ))
if [ "$cache_age" -gt "$TTL" ] && { [ ! -f "$BACKOFF" ] || [ "$backoff_age" -gt 600 ]; }; then
  fetch_usage
fi

if [ -f "$CACHE" ]; then
  usage=$(jq -r '
    [ .limits[]?
      | if .kind == "session" then "session:" + (.percent|tostring) + "%"
        elif .kind == "weekly_all" then "weekly:" + (.percent|tostring) + "%"
        elif .kind == "weekly_scoped" then
          ((.scope.model.display_name // "scoped") | ascii_downcase)
          + "_weekly:" + (.percent|tostring) + "%"
        else empty end
    ] | join(" ")' "$CACHE" 2>/dev/null)
fi

# ---- 拼装 ----
out="$model"
[ -n "$effort" ] && out="$out (effort:$effort)"
out="$out | $cwd_display"
[ -n "$branch" ] && out="$out | git:$branch"
[ -n "$usage" ] && out="$out | $usage"
printf '\033[2m%s\033[0m' "$out"
