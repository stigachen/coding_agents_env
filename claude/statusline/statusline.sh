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

# ---- context 使用率（stdin payload，会话早期可能为 null）----
ctx_pct=$(echo "$input" | jq -r '.context_window.used_percentage // empty | floor')
if [ -z "$ctx_pct" ]; then
  ctx_pct=$(echo "$input" | jq -r '
    (.context_window // {}) as $c
    | if ($c.total_input_tokens != null and ($c.context_window_size // 0) > 0)
      then ($c.total_input_tokens * 100 / $c.context_window_size | floor)
      else empty end')
fi

# ---- usage：两路并行 ----
# 路 1（优先）：Claude Code 直接把订阅配额放进 stdin 的 rate_limits（Pro/Max，
# 会话首个 API 响应之后出现）→ session / weekly，不需要 token、不联网、无授权弹窗
stdin_usage=$(echo "$input" | jq -r '
  [ (.rate_limits.five_hour.used_percentage // empty | "session:" + (floor|tostring) + "%"),
    (.rate_limits.seven_day.used_percentage // empty | "weekly:"  + (floor|tostring) + "%") ]
  | join(" ")' 2>/dev/null)

# 路 2（默认关闭，STATUSLINE_USAGE_API=1 开启）：用本机 OAuth token 查未公开的
# 用量接口（5 分钟缓存 + 429 退避）。stdin 里没有按模型的周配额（fable_weekly
# 等），这一项只能从接口拿；stdin 完全没给 rate_limits 时（老版本 Claude Code /
# 会话首个响应之前）三项也都从这里取。关闭时不读凭据、不发任何请求。
# 开关放 ~/.config/coding_agents_env/notify.env（本机文件，各 agent 共用，
# 改完即时生效；找不到时回退旧位置 ~/.claude/notify.env）。键名
# CLAUDE_STATUSLINE_USAGE_API，兼容旧键名 STATUSLINE_USAGE_API。
# 只取这一个键，不 eval 整个文件，避免把 IM token 加载进 statusline 进程
ENV_FILE="${CODING_AGENTS_ENV_DIR:-$HOME/.config/coding_agents_env}/notify.env"
[ -f "$ENV_FILE" ] || ENV_FILE="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/notify.env"
STATUSLINE_USAGE_API=$(
  [ -f "$ENV_FILE" ] && tr -d '\r' < "$ENV_FILE" \
    | sed -n 's/^\(CLAUDE_\)\{0,1\}STATUSLINE_USAGE_API=["'"'"']*\([01]\).*/\2/p' | tail -1
)
STATUSLINE_USAGE_API="${STATUSLINE_USAGE_API:-0}"

CACHE="${TMPDIR:-/tmp}/claude-statusline-usage.json"
BACKOFF="${TMPDIR:-/tmp}/claude-statusline-usage.backoff"
TTL=300

get_token() {
  local t=""
  if [ "$IS_MAC" = "1" ]; then
    # macOS：Claude Code 把凭据存在 Keychain。但 statusline 是 Claude Code 拉起的
    # 非交互进程，Keychain 条目缺少 "Always Allow" 时（重新登录会新建条目、授权
    # 重置）security 会以 errSecInteractionNotAllowed（退出码 36）静默失败
    t=$(security find-generic-password -s "Claude Code-credentials" -w 2>/dev/null \
      | jq -r '.claudeAiOauth.accessToken // empty' 2>/dev/null)
  fi
  if [ -z "$t" ]; then
    # Windows (Git Bash) / Linux 的常规位置；macOS 上 Keychain 读不到时也回退到这里
    t=$(jq -r '.claudeAiOauth.accessToken // empty' \
      "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/.credentials.json" 2>/dev/null)
  fi
  [ -n "$t" ] && echo "$t"
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

usage="$stdin_usage"
if [ "$STATUSLINE_USAGE_API" = "1" ]; then
  now=$(date +%s)
  cache_age=$(( now - $(mtime "$CACHE") ))
  backoff_age=$(( now - $(mtime "$BACKOFF") ))
  if [ "$cache_age" -gt "$TTL" ] && { [ ! -f "$BACKOFF" ] || [ "$backoff_age" -gt 600 ]; }; then
    fetch_usage
    cache_age=$(( $(date +%s) - $(mtime "$CACHE") ))
  fi

  # 接口数据的健康标记，附在接口来的那一项后面：
  #   (429) 被限流、退避中，10 分钟后自动重试；(Nm) 数据是 N 分钟前的，
  #   说明至少连续两次刷新失败（token 读不到 / 接口变了 / 断网）
  stale=""
  if [ -f "$CACHE" ] && [ "$cache_age" -gt "$TTL" ]; then
    if [ -f "$BACKOFF" ] && [ "$backoff_age" -le 600 ]; then
      stale="(429)"
    elif [ "$cache_age" -gt $(( TTL * 2 )) ]; then
      stale="($(( cache_age / 60 ))m)"
    fi
  fi

  if [ -n "$stdin_usage" ]; then
    if [ -f "$CACHE" ]; then
      # stdin 已给 session/weekly，接口只补按模型的周配额
      scoped=$(jq -r '
        [ .limits[]? | select(.kind == "weekly_scoped")
          | ((.scope.model.display_name // "scoped") | ascii_downcase)
            + "_weekly:" + (.percent|tostring) + "%"
        ] | join(" ")' "$CACHE" 2>/dev/null)
      [ -n "$scoped" ] && usage="$usage $scoped$stale"
    else
      # 接口路径从没成功过 → 明确标出缺失，而不是悄悄少一项
      usage="$usage $(echo "$model" | tr 'A-Z' 'a-z' | cut -d' ' -f1)_weekly:--"
    fi
  elif [ -f "$CACHE" ]; then
    usage=$(jq -r '
      [ .limits[]?
        | if .kind == "session" then "session:" + (.percent|tostring) + "%"
          elif .kind == "weekly_all" then "weekly:" + (.percent|tostring) + "%"
          elif .kind == "weekly_scoped" then
            ((.scope.model.display_name // "scoped") | ascii_downcase)
            + "_weekly:" + (.percent|tostring) + "%"
          else empty end
      ] | join(" ")' "$CACHE" 2>/dev/null)
    [ -n "$usage" ] && usage="$usage$stale"
  fi
fi

# ---- 第一行：模型 + effort | 项目 | git 分支 ----
line1="$model"
[ -n "$effort" ] && line1="$line1 (effort:$effort)"
line1="$line1 | $cwd_display"
[ -n "$branch" ] && line1="$line1 | git:$branch"

# ---- 第二行：context 进度条（绿→黄→红）+ usage ----
line2=""
if [ -n "$ctx_pct" ]; then
  if   [ "$ctx_pct" -ge 80 ]; then color="31"   # 红
  elif [ "$ctx_pct" -ge 60 ]; then color="33"   # 黄
  else                             color="32"   # 绿
  fi
  filled=$(( ctx_pct / 10 ))
  [ "$filled" -gt 10 ] && filled=10
  # 进度条用 printf 八进制转义逐字节输出（█=\342\226\210 ░=\342\226\221）：
  # 字节流不经过 shell 的字符处理，输出与 locale 无关（C/POSIX locale 下
  # 也不会切错），同时绕开 macOS bash 3.2 在 UTF-8 locale 下
  # 拼接多字节字符（bar="$bar█"）丢字节的 bug
  bar=$(
    i=0
    while [ "$i" -lt 10 ]; do
      if [ "$i" -lt "$filled" ]; then printf '\342\226\210'; else printf '\342\226\221'; fi
      i=$(( i + 1 ))
    done
  )
  line2=$(printf 'ctx \033[0;%sm%s\033[0;2m %s%%' "$color" "$bar" "$ctx_pct")
fi
if [ -n "$usage" ]; then
  [ -n "$line2" ] && line2="$line2 | $usage" || line2="$usage"
fi

printf '\033[2m%s\033[0m' "$line1"
[ -n "$line2" ] && printf '\n\033[2m%s\033[0m' "$line2"
exit 0
