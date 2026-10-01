#!/bin/bash
# 通知推送内核（各 coding agent 共用）。
#
# 用法：printf '%s' "<正文>" | bash send.sh <kind> <project> <agent>
#   kind     permission | idle | stop | other
#            permission：agent 在等审批    idle：agent 停下等输入
#            stop：回合结束（正文 = 最后回复摘要，可为空）
#            other：其他通知（正文 = 类型名或说明）
#   project  项目名（一般是 cwd 的 basename）
#   agent    调用方名字，显示在消息里：Claude / Codex / OpenCode / Grok …
#            同时决定按 agent 覆盖的开关前缀（见下）
#
# 各 agent 目录下的适配层只负责把自家事件格式翻译成这三个参数加正文；
# 开关判定、消息措辞、前台静音、各渠道推送全部在这里，保证三家行为一致。
#
# 配置文件：~/.config/coding_agents_env/notify.env（不入库，模板见同目录
# notify.env.example）。找不到时回退旧位置 ~/.claude/notify.env。
# 所有开关和渠道键都支持按 agent 覆盖：<AGENT>_NOTIFY_ON_STOP、
# <AGENT>_DISCORD_WEBHOOK_URL 之类（agent 名大写），没有该键时用通用键；
# 前缀键留空表示对该 agent 明确关掉。TELEGRAM_BOT_TOKEN / TELEGRAM_CHAT_ID
# 必须成对覆盖。
#
# NOTIFY_DRY_RUN=1：只打印判定结果和最终消息到 stdout，不推送，验证用。

kind=${1:-other}
project=${2:-unknown}
agent=${3:-Claude}
body=$(cat)

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
CLAUDE_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
ENV_FILE="${CODING_AGENTS_ENV_DIR:-$HOME/.config/coding_agents_env}/notify.env"
[ -f "$ENV_FILE" ] || ENV_FILE="$CLAUDE_DIR/notify.env"
# 逐行加载 KEY=VALUE。环境变量 / 命令行前缀里已经设了的键优先于文件
# （方便测试时临时覆盖：NOTIFY_SKIP_WHEN_FOCUSED=0 bash send.sh …）。
# 去掉 \r 再加载：Windows 编辑器可能把文件存成 CRLF，直接 source 会让
# 每个值尾部带 \r（token 失效，且 [ -n ] 判空检测不到）
# 不用 eval：值一律按字面量赋给变量，& ; $ ` 等字符不会被 shell 解释
# （Discord webhook 带 ?wait=true&thread_id=… 这类查询串时 eval 会把 & 当后台
# 命令切断，键变空、通知静默丢失）。兼容 KEY="v" / KEY='v' 写法（去掉成对引号）
# 和 KEY=v  # 注释 写法（未加引号时截掉 " #" 之后的部分）
if [ -f "$ENV_FILE" ]; then
  while IFS= read -r line; do
    case "$line" in [A-Z_]*=*) ;; *) continue ;; esac
    key=${line%%=*}; val=${line#*=}
    case "$key" in *[!A-Z0-9_]*) continue ;; esac
    printenv "$key" >/dev/null 2>&1 && continue
    case "$val" in
      \"*\") val=${val#\"}; val=${val%\"} ;;
      \'*\') val=${val#\'}; val=${val%\'} ;;
      *)  val=${val%%\ \#*}; val=${val%"${val##*[! 	]}"} ;;
    esac
    printf -v "$key" '%s' "$val"
  done < <(tr -d '\r' < "$ENV_FILE")
fi

# ---- 开关：先看 <AGENT>_KEY，再看 KEY，最后默认值 ----
AGENT_UC=$(printf '%s' "$agent" | tr 'a-z' 'A-Z' | tr -c 'A-Z0-9\n' '_')
# 判"是否设置"而不是"是否非空"：<AGENT>_KEY= 留空表示对该 agent 明确设为空
# （比如 CODEX_DISCORD_WEBHOOK_URL= 让 Codex 不发共享的 Discord 频道），
# 不会回退到通用键
is_set() { [ -n "${!1+x}" ]; }
setting() {  # setting KEY DEFAULT
  local scoped="${AGENT_UC}_$1"
  if is_set "$scoped"; then printf '%s' "${!scoped}"
  elif is_set "$1"; then printf '%s' "${!1}"
  else printf '%s' "$2"
  fi
}

# xAI Grok CLI 会执行 Claude 的 hooks；默认忽略其事件（NOTIFY_FROM_GROK=0）
if [ "$agent" = "Grok" ] && [ "$(setting NOTIFY_FROM_GROK 0)" != "1" ]; then
  exit 0
fi

# 多台机器共用一个 IM 渠道时靠主机名区分来源：[项目@主机]
tag="$project"
if [ "$(setting NOTIFY_SHOW_HOST 1)" = "1" ]; then
  host=$(hostname 2>/dev/null || echo "${HOSTNAME:-${COMPUTERNAME:-}}")
  host=${host%%.*}
  [ -n "$host" ] && tag="$project@$host"
fi

case "$kind" in
  permission)
    [ "$(setting NOTIFY_ON_PERMISSION 1)" = "0" ] && exit 0
    msg="🔔 [$tag] $agent 在等你批准一个操作" ;;
  idle)
    [ "$(setting NOTIFY_ON_IDLE 1)" = "0" ] && exit 0
    msg="⏸️ [$tag] $agent 已停下，等待你的输入" ;;
  stop)
    [ "$(setting NOTIFY_ON_STOP 1)" = "0" ] && exit 0
    # 摘要按字符（codepoint）截断，不能用 head -c：按字节截会把 UTF-8 多字节
    # 字符切成两半，Telegram 会以 400 "strings must be encoded in UTF-8" 拒收
    last=$(printf '%s' "$body" | jq -Rrs '.[0:120]' 2>/dev/null)
    msg="✅ [$tag] $agent 任务完成"
    [ -n "$last" ] && msg="$msg
$last" ;;
  *)
    msg="🔔 [$tag] $agent 通知：${body:-$kind}" ;;
esac

# ---- 排障日志 ----
dbg() {
  [ "$(setting NOTIFY_DEBUG 0)" = "1" ] && \
    printf '%s %s\n' "$(date '+%F %T')" "$*" >> "$CLAUDE_DIR/notify-debug.log"
  return 0
}

# ---- 前台静音：终端窗口正被盯着时不推送 ----
# 判定标准是"键盘焦点"而非"可见"：焦点窗口全系统只有一个，多显示器下
# 窗口可见但焦点在别的应用时仍推送（说明你没在看它）。
# 识别方式不硬编码终端名单：把前台窗口的属主进程和本脚本的祖先进程链比对，
# 终端/IDE 必然是 hook 进程的祖先，命中即视为聚焦。
# 任何检测失败（SSH、tmux 断祖先链、无 GUI、缺工具）一律 fail-open 照常推送。
# 已知限制：只能判断到窗口/应用级——同一终端 app 的其他窗口或 tab 聚焦时
# 也会被静音（此时至少桌面就在眼前，代价可接受）。
terminal_is_focused() {
  [ "$(setting NOTIFY_SKIP_WHEN_FOCUSED 1)" = "1" ] || return 1
  local max_idle
  max_idle=$(setting NOTIFY_FOCUS_MAX_IDLE 120)
  case "$(uname)" in
    Darwin)
      # 已锁屏 → 一定看不到终端，照常推送。单靠下面的空闲阈值不够：
      # 手动立即锁屏（Ctrl+Cmd+Q）时按键会把空闲计时清零，
      # 锁屏后的前 NOTIFY_FOCUS_MAX_IDLE 秒通知会被误静音
      ioreg -n Root -d1 -a 2>/dev/null | grep -q CGSSessionScreenIsLocked && return 1
      # 窗口聚焦但人已走开（无键鼠输入超过阈值）→ 照常推送
      local idle
      idle=$(ioreg -c IOHIDSystem 2>/dev/null \
        | awk '/HIDIdleTime/ {print int($NF/1000000000); exit}')
      case "$idle" in *[!0-9]*|'') : ;; *) [ "$idle" -ge "$max_idle" ] && return 1 ;; esac
      # lsappinfo 不需要 TCC 授权（osascript 查 System Events 会弹自动化授权）
      local asn front_pid
      asn=$(lsappinfo front 2>/dev/null)
      [ -n "$asn" ] || return 1
      front_pid=$(lsappinfo info -only pid "$asn" 2>/dev/null | sed 's/[^0-9]//g')
      case "$front_pid" in ''|*[!0-9]*) return 1 ;; esac
      local front_name
      front_name=$(lsappinfo info -only name "$asn" 2>/dev/null)
      local p=$$ i=0 chain=""
      while [ "$i" -lt 25 ]; do
        chain="$chain $p"
        if [ "$p" = "$front_pid" ]; then
          dbg "front=$front_pid($front_name) idle=${idle}s chain=$chain → FOCUSED"
          return 0
        fi
        p=$(ps -o ppid= -p "$p" 2>/dev/null | tr -d ' ')
        case "$p" in ''|0|1|*[!0-9]*) break ;; esac
        i=$((i + 1))
      done
      dbg "front=$front_pid($front_name) idle=${idle}s chain=$chain → 未聚焦"
      return 1
      ;;
    MINGW*|MSYS*|CYGWIN*)
      # Git Bash：/proc/<pid>/winpid 是 MSYS pid 对应的 Windows pid
      local winpid wpath result
      winpid=$(cat "/proc/$$/winpid" 2>/dev/null)
      case "$winpid" in ''|*[!0-9]*) return 1 ;; esac
      [ -f "$SCRIPT_DIR/focus_check.ps1" ] || return 1
      wpath=$(cygpath -w "$SCRIPT_DIR/focus_check.ps1" 2>/dev/null)
      [ -n "$wpath" ] || return 1
      # timeout 兜底（Git Bash 自带 coreutils timeout）：检测脚本异常变慢时
      # 宁可放弃静音判定也不能吃掉 hook 超时预算，否则后续 curl 推送会被强杀
      result=$(timeout 6 powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass \
        -File "$wpath" -StartPid "$winpid" -MaxIdle "$max_idle" 2>/dev/null \
        | tr -d '\r\n ')
      [ "$result" = "FOCUSED" ]
      ;;
    *)
      return 1
      ;;
  esac
}

# ---- 渠道：同样支持按 agent 覆盖（OPENCODE_DISCORD_WEBHOOK_URL 之类）----
# 不同 agent 可以推到不同的群/频道，没有前缀键时回退通用键；前缀键留空 = 该
# agent 不发这个渠道。Telegram 的 token 和 chat_id 成对解析：只要有一个前缀键
# 存在就整对用前缀值，缺另一个则跳过 Telegram（否则会拿 A bot 去发 B 群，
# Telegram 返回 400、通知静默丢失）
tg_token=""; tg_chat=""
if is_set "${AGENT_UC}_TELEGRAM_BOT_TOKEN" || is_set "${AGENT_UC}_TELEGRAM_CHAT_ID"; then
  _t="${AGENT_UC}_TELEGRAM_BOT_TOKEN"; _c="${AGENT_UC}_TELEGRAM_CHAT_ID"
  tg_token=${!_t:-}; tg_chat=${!_c:-}
  if [ -z "$tg_token" ] || [ -z "$tg_chat" ]; then
    dbg "telegram: ${AGENT_UC}_TELEGRAM_BOT_TOKEN / ${AGENT_UC}_TELEGRAM_CHAT_ID 需成对设置，跳过 Telegram"
    tg_token=""; tg_chat=""
  fi
else
  tg_token=${TELEGRAM_BOT_TOKEN:-}; tg_chat=${TELEGRAM_CHAT_ID:-}
fi
dc_url=$(setting DISCORD_WEBHOOK_URL "")
tg_on=no; [ -n "$tg_token" ] && [ -n "$tg_chat" ] && tg_on=yes
dc_on=no; [ -n "$dc_url" ] && dc_on=yes

if [ "${NOTIFY_DRY_RUN:-0}" = "1" ]; then
  focused=no
  terminal_is_focused && focused=yes
  printf '[dry-run] agent=%s kind=%s env=%s focused=%s telegram=%s discord=%s\n%s\n' \
    "$agent" "$kind" "$ENV_FILE" "$focused" "$tg_on" "$dc_on" "$msg"
  exit 0
fi

# 静音对所有渠道生效（IM + 桌面弹窗）；设 NOTIFY_SKIP_WHEN_FOCUSED=0 恢复全量推送
if terminal_is_focused; then
  dbg "agent=$agent kind=$kind → 静音跳过"
  exit 0
fi
dbg "agent=$agent kind=$kind tag=$tag → 推送: $(printf '%s' "$msg" | head -1)"

# 消息文本一律经 stdin 传给 curl，不走命令行参数：Windows Git Bash 调用原生
# curl.exe 时，MSYS→Win32 的 argv 编码转换会损坏非 ASCII 的 UTF-8 字节，
# Telegram/Discord 会以 400 "not UTF-8" 拒收

# Windows 优先用系统原生 curl：hook 是无控制台的分离进程，mingw64 curl 在这种
# 环境下会偶发卡死在进程初始化阶段（自身的 -m 超时都不生效，直到 hook 超时被
# 整体强杀，通知静默丢失）；原生 curl 无此问题。消息数据全走 stdin，
# 原生 curl 同样不受 MSYS→Win32 argv 编码转换影响
CURL=curl
case "$(uname)" in
  MINGW*|MSYS*|CYGWIN*)
    [ -x /c/Windows/System32/curl.exe ] && CURL=/c/Windows/System32/curl.exe ;;
esac

# ---- Telegram ----
if [ "$tg_on" = "yes" ]; then
  tg_out=$(printf '%s' "$msg" | "$CURL" -sS -m 5 \
    "https://api.telegram.org/bot${tg_token}/sendMessage" \
    -d chat_id="${tg_chat}" --data-urlencode text@- 2>&1)
  tg_rc=$?
  dbg "telegram($CURL) rc=$tg_rc resp=${tg_out:0:120}"
fi

# ---- Discord webhook ----
if [ "$dc_on" = "yes" ]; then
  dc_out=$(printf '%s' "$msg" | jq -Rs '{content: .}' | "$CURL" -sS -m 5 \
    -H "Content-Type: application/json" --data-binary @- \
    "$dc_url" 2>&1)
  dbg "discord($CURL) rc=$? resp=${dc_out:0:120}"
fi

# ---- 本机桌面通知（macOS，窗口在后台时的轻量提醒）----
if [ "$(setting DESKTOP_NOTIFY 0)" = "1" ] && [ "$(uname)" = "Darwin" ]; then
  title=$(printf '%s' "$msg" | head -1 | sed 's/"/\\"/g')
  osascript -e "display notification \"\" with title \"$title\"" >/dev/null 2>&1
fi

exit 0
