#!/bin/bash
# Claude Code hook 适配层：Notification / Stop 两个事件共用。
# 只做一件事——把 Claude Code 从 stdin 传来的事件 JSON 翻译成
# lib/send.sh 的参数（kind / project / agent）加正文，开关、措辞、
# 前台静音、渠道推送全在 send.sh 里。
#
# xAI Grok CLI 的 "Claude Code 兼容" 功能会原样执行 ~/.claude/settings.json 里
# 的 hooks，所以 Grok 的回合也会到这里。它每次调 hook 都注入 GROK_HOOK_EVENT
# 环境变量，据此把 agent 标成 Grok（send.sh 默认忽略 Grok，NOTIFY_FROM_GROK=1
# 才推送）。Grok 的载荷是 camelCase（notificationType / lastAssistantMessage），
# 读字段时两种写法都兼容。

input=$(cat)
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
SEND="$SCRIPT_DIR/../../lib/send.sh"

agent="Claude"
[ -n "${GROK_HOOK_EVENT:-}" ] && agent="Grok"

event=$(echo "$input" | jq -r '.hook_event_name // empty')
cwd=$(echo "$input" | jq -r '.cwd // empty')
project=$(basename "${cwd:-unknown}")

case "$event" in
  Stop)
    echo "$input" | jq -r '.last_assistant_message // .lastAssistantMessage // ""' \
      | bash "$SEND" stop "$project" "$agent"
    ;;
  Notification)
    ntype=$(echo "$input" | jq -r '.notification_type // .notificationType // "notification"')
    case "$ntype" in
      permission_prompt) printf '' | bash "$SEND" permission "$project" "$agent" ;;
      idle_prompt)       printf '' | bash "$SEND" idle "$project" "$agent" ;;
      *)                 printf '%s' "$ntype" | bash "$SEND" other "$project" "$agent" ;;
    esac
    ;;
esac
exit 0
