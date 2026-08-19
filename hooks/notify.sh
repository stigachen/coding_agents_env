#!/bin/bash
# Claude Code hook：把"需要审批 / 等待输入 / 任务完成"事件推送到 IM。
# 由 Notification 和 Stop 两个 hook 事件共用；stdin 是 Claude Code 传入的事件 JSON。
# 渠道配置读取 ~/.claude/notify.env（不入库，每台机器各自填写，见 notify.env.example）。

input=$(cat)

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
CLAUDE_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
ENV_FILE="$CLAUDE_DIR/notify.env"
# 去掉 \r 再加载：Windows 编辑器可能把文件存成 CRLF，直接 source 会让
# 每个值尾部带 \r（token 失效，且 [ -n ] 判空检测不到）
[ -f "$ENV_FILE" ] && eval "$(tr -d '\r' < "$ENV_FILE")"

event=$(echo "$input" | jq -r '.hook_event_name // empty')
cwd=$(echo "$input" | jq -r '.cwd // empty')
project=$(basename "${cwd:-unknown}")

case "$event" in
  Stop)
    # Stop 每个回合都触发；置 NOTIFY_ON_STOP=0 可只保留审批/等待通知
    [ "${NOTIFY_ON_STOP:-1}" = "0" ] && exit 0
    # 摘要必须按字符（codepoint）截断，不能用 head -c：按字节截会把 UTF-8
    # 多字节字符切成两半，Telegram 会以 400 "strings must be encoded in UTF-8"
    # 拒收整条消息（中文消息约 2/3 概率踩中）。jq 的字符串切片按字符算
    last=$(echo "$input" | jq -r '(.last_assistant_message // "")[0:120]')
    msg="✅ [$project] Claude 任务完成"
    [ -n "$last" ] && msg="$msg
$last"
    ;;
  Notification)
    ntype=$(echo "$input" | jq -r '.notification_type // "notification"')
    case "$ntype" in
      permission_prompt) msg="🔔 [$project] Claude 在等你批准一个操作" ;;
      idle_prompt)       msg="⏸️ [$project] Claude 已停下，等待你的输入" ;;
      *)                 msg="🔔 [$project] Claude 通知：$ntype" ;;
    esac
    ;;
  *)
    exit 0
    ;;
esac

# ---- 前台静音：终端窗口正被盯着时不推送 ----
# 判定标准是"键盘焦点"而非"可见"：焦点窗口全系统只有一个，多显示器下
# 窗口可见但焦点在别的应用时仍推送（说明你没在看它）。
# 识别方式不硬编码终端名单：把前台窗口的属主进程和本脚本的祖先进程链比对，
# 终端/IDE 必然是 hook 进程的祖先，命中即视为聚焦。
# 任何检测失败（SSH、tmux 断祖先链、无 GUI、缺工具）一律 fail-open 照常推送。
# 已知限制：只能判断到窗口/应用级——同一终端 app 的其他窗口或 tab 聚焦时
# 也会被静音（此时至少桌面就在眼前，代价可接受）。
# NOTIFY_DEBUG=1 时把每次事件的判定现场写入 ~/.claude/notify-debug.log，排障用
dbg() {
  [ "${NOTIFY_DEBUG:-0}" = "1" ] && \
    printf '%s %s\n' "$(date '+%F %T')" "$*" >> "$CLAUDE_DIR/notify-debug.log"
  return 0
}

terminal_is_focused() {
  [ "${NOTIFY_SKIP_WHEN_FOCUSED:-1}" = "1" ] || return 1
  local max_idle="${NOTIFY_FOCUS_MAX_IDLE:-120}"
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
      result=$(powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass \
        -File "$wpath" -StartPid "$winpid" -MaxIdle "$max_idle" 2>/dev/null \
        | tr -d '\r\n ')
      [ "$result" = "FOCUSED" ]
      ;;
    *)
      return 1
      ;;
  esac
}

# 静音对所有渠道生效（IM + 桌面弹窗）；设 NOTIFY_SKIP_WHEN_FOCUSED=0 恢复全量推送
if terminal_is_focused; then
  dbg "event=$event → 静音跳过"
  exit 0
fi
dbg "event=$event → 推送"

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
if [ -n "${TELEGRAM_BOT_TOKEN:-}" ] && [ -n "${TELEGRAM_CHAT_ID:-}" ]; then
  tg_out=$(printf '%s' "$msg" | "$CURL" -sS -m 5 \
    "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
    -d chat_id="${TELEGRAM_CHAT_ID}" --data-urlencode text@- 2>&1)
  tg_rc=$?
  dbg "telegram($CURL) rc=$tg_rc resp=${tg_out:0:120}"
fi

# ---- Discord webhook ----
if [ -n "${DISCORD_WEBHOOK_URL:-}" ]; then
  dc_out=$(printf '%s' "$msg" | jq -Rs '{content: .}' | "$CURL" -sS -m 5 \
    -H "Content-Type: application/json" --data-binary @- \
    "$DISCORD_WEBHOOK_URL" 2>&1)
  dbg "discord($CURL) rc=$? resp=${dc_out:0:120}"
fi

# ---- 本机桌面通知（macOS，窗口在后台时的轻量提醒）----
if [ "${DESKTOP_NOTIFY:-0}" = "1" ] && [ "$(uname)" = "Darwin" ]; then
  title=$(printf '%s' "$msg" | head -1 | sed 's/"/\\"/g')
  osascript -e "display notification \"\" with title \"$title\"" >/dev/null 2>&1
fi

exit 0
