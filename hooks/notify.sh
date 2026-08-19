#!/bin/bash
# Claude Code hook：把"需要审批 / 等待输入 / 任务完成"事件推送到 IM。
# 由 Notification 和 Stop 两个 hook 事件共用；stdin 是 Claude Code 传入的事件 JSON。
# 渠道配置读取 ~/.claude/notify.env（不入库，每台机器各自填写，见 notify.env.example）。

input=$(cat)

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
    last=$(echo "$input" | jq -r '.last_assistant_message // ""' | head -c 200)
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

# 消息文本一律经 stdin 传给 curl，不走命令行参数：Windows Git Bash 调用原生
# curl.exe 时，MSYS→Win32 的 argv 编码转换会损坏非 ASCII 的 UTF-8 字节，
# Telegram/Discord 会以 400 "not UTF-8" 拒收

# ---- Telegram ----
if [ -n "${TELEGRAM_BOT_TOKEN:-}" ] && [ -n "${TELEGRAM_CHAT_ID:-}" ]; then
  printf '%s' "$msg" | curl -sS -m 5 \
    "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
    -d chat_id="${TELEGRAM_CHAT_ID}" --data-urlencode text@- >/dev/null 2>&1
fi

# ---- Discord webhook ----
if [ -n "${DISCORD_WEBHOOK_URL:-}" ]; then
  printf '%s' "$msg" | jq -Rs '{content: .}' | curl -sS -m 5 \
    -H "Content-Type: application/json" --data-binary @- \
    "$DISCORD_WEBHOOK_URL" >/dev/null 2>&1
fi

# ---- 本机桌面通知（macOS，窗口在后台时的轻量提醒）----
if [ "${DESKTOP_NOTIFY:-0}" = "1" ] && [ "$(uname)" = "Darwin" ]; then
  title=$(printf '%s' "$msg" | head -1 | sed 's/"/\\"/g')
  osascript -e "display notification \"\" with title \"$title\"" >/dev/null 2>&1
fi

exit 0
