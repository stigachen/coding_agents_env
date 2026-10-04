#!/bin/bash
# Native Grok events -> the shared notification core. No Claude installation or
# compatibility hooks are required. Never return a Stop/permission decision.

input=$(cat)
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
SEND="$SCRIPT_DIR/../../lib/send.sh"

# Grok supplies camelCase fields and a Claude-compatible event-name alias.
# The runner also supplies GROK_HOOK_EVENT for every hook invocation.
event=$(printf '%s' "$input" | jq -r '.hook_event_name // .hookEventName // empty' 2>/dev/null)
event=${event:-${GROK_HOOK_EVENT:-}}
cwd=$(printf '%s' "$input" | jq -r '.cwd // empty' 2>/dev/null)
# Native Windows payloads use backslashes even when the hook runs in Git Bash.
cwd=${cwd//\\//}
project=$(basename "${cwd:-unknown}")
subagent=$(printf '%s' "$input" | jq -r '.subagentType // .subagent_type // empty' 2>/dev/null)

case "$event" in
  Stop|stop)
    [ -z "$subagent" ] || exit 0
    # Session teardown emits another Stop. Only a completed turn is a task
    # completion; shutdown/channel_closed and missing reasons are ignored.
    reason=$(printf '%s' "$input" | jq -r '.reason // empty' 2>/dev/null)
    [ "$reason" = "end_turn" ] || exit 0
    printf '%s' "$input" | jq -r '.lastAssistantMessage // .last_assistant_message // ""' \
      | bash "$SEND" stop "$project" Grok
    ;;
  Notification|notification)
    ntype=$(printf '%s' "$input" | jq -r '.notificationType // .notification_type // empty' 2>/dev/null)
    case "$ntype" in
      # A child can also be waiting for the user; do not lose its approval alert.
      permission_prompt) printf '' | bash "$SEND" permission "$project" Grok ;;
      idle_prompt)
        [ -z "$subagent" ] || exit 0
        printf '' | bash "$SEND" idle "$project" Grok ;;
      # task_complete is not a documented substitute for a completed turn.
      # Completion notifications come only from Stop(reason=end_turn).
      *) ;;
    esac
    ;;
esac
exit 0
