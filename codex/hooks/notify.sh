#!/bin/bash
# Codex CLI hook 适配层：Stop / PermissionRequest 两个事件共用（~/.codex/hooks.json）。
# 只把 Codex 从 stdin 传来的事件 JSON 翻译成 lib/send.sh 的参数；开关、措辞、
# 前台静音、渠道推送全在 send.sh 里。
#
# Codex 的 hook 载荷和 Claude Code 同构：hook_event_name / cwd /
# last_assistant_message（Stop）/ tool_name（PermissionRequest）。Codex 没有
# "等输入" 一类的 idle 事件。
# PermissionRequest 是决策型 hook：Codex 会等它退出；本脚本不输出任何决策、
# 直接退出 0，让 Codex 继续自己的审批流程（可能交给自动审核，不一定弹窗）。

input=$(cat)
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
SEND="$SCRIPT_DIR/../../lib/send.sh"

event=$(echo "$input" | jq -r '.hook_event_name // empty')
cwd=$(echo "$input" | jq -r '.cwd // empty')
project=$(basename "${cwd:-unknown}")

case "$event" in
  Stop)
    echo "$input" | jq -r '.last_assistant_message // ""' \
      | bash "$SEND" stop "$project" Codex
    ;;
  PermissionRequest)
    # hook 不含实际审核方；同回合切换模式后 transcript 的 reviewer 也可能过时。
    # 只表达“发起审批请求”，不能据此静音或声称已经在等待用户。
    printf '' | bash "$SEND" permission_request "$project" Codex
    ;;
esac
exit 0
