#!/bin/bash
# Claude Code hook 适配层：Notification / Stop 两个事件共用。
# 只做一件事——把 Claude Code 从 stdin 传来的事件 JSON 翻译成
# lib/send.sh 的参数（kind / project / agent）加正文，开关、措辞、
# 前台静音、渠道推送全在 send.sh 里。
#
# Grok 默认也会扫描 Claude hooks；它有独立的 grok/hooks/notify.sh 入口。
# 只跳过本仓库的兼容调用，避免一条事件通知两次，不关闭第三方兼容 hooks。
[ -z "${GROK_HOOK_EVENT:-}" ] || exit 0

input=$(cat)
# dirname only splits on /. Git Bash started from Windows may see D:\...\script.sh.
_self=${BASH_SOURCE[0]//\\//}
SCRIPT_DIR=$(cd "$(dirname "$_self")" && pwd)
SEND="$SCRIPT_DIR/../../lib/send.sh"

event=$(echo "$input" | jq -r '.hook_event_name // empty')
cwd=$(echo "$input" | jq -r '.cwd // empty')
# Windows payloads use backslashes. basename only splits on /.
cwd=${cwd//\\//}
project=$(basename "${cwd:-unknown}")

case "$event" in
  Stop)
    echo "$input" | jq -r '.last_assistant_message // ""' \
      | bash "$SEND" stop "$project" Claude
    ;;
  Notification)
    ntype=$(echo "$input" | jq -r '.notification_type // "notification"')
    case "$ntype" in
      permission_prompt) printf '' | bash "$SEND" permission "$project" Claude ;;
      idle_prompt)       printf '' | bash "$SEND" idle "$project" Claude ;;
      *)                 printf '%s' "$ntype" | bash "$SEND" other "$project" Claude ;;
    esac
    ;;
esac
exit 0
