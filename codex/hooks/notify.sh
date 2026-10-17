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
# Windows payloads use backslashes. basename only splits on /.
cwd=${cwd//\\//}
project=$(basename "${cwd:-unknown}")

# Desktop background suggestions use ephemeral sessions and explicitly send
# transcript_path: null. This also covers user-created ephemeral sessions;
# command hooks do not expose a reliable background-task source marker.
# Missing/empty fields and unavailable files are not classified as transcript-less.
without_transcript() {
  printf '%s' "$input" | jq -e 'has("transcript_path") and .transcript_path == null' >/dev/null 2>&1
}

# PermissionRequest 不能直接等同于等待人工审批。hook 未提供 approvals_reviewer；
# 用它给出的 transcript_path + turn_id 查本回合的 turn_context，不能读全局
# config.toml（桌面端可逐会话切换模式）。只识别 Bash / apply_patch：应用和 MCP
# 工具可能单独指定人工审核。transcript 不是稳定接口；缺字段、回合未落盘、
# 格式变化等都返回 unknown；显式 null 的路径另按无记录通知开关处理。
permission_reviewer() {
  local tool turn transcript
  tool=$(printf '%s' "$input" | jq -r '.tool_name // empty')
  case "$tool" in Bash|apply_patch) ;; *) return ;; esac
  turn=$(printf '%s' "$input" | jq -r '.turn_id // empty')
  transcript=$(printf '%s' "$input" | jq -r '.transcript_path // empty')
  # [ -f ] does not treat \ as a separator, so a C:\... transcript would miss.
  transcript=${transcript//\\//}
  [ -n "$turn" ] && [ -n "$transcript" ] && [ -f "$transcript" ] && [ -r "$transcript" ] || return

  # 有界读取，避免长会话耗尽 hook 超时预算；截断首行/未写完的末行按无效 JSON 忽略。
  # 仅匹配当前 turn_id，绝不拿上一回合的自动审核状态来吞掉本回合的人工通知。
  tail -c 2097152 "$transcript" 2>/dev/null | jq -Rn -r --arg turn "$turn" '
    reduce inputs as $line ("unknown";
      (try ($line | fromjson) catch null) as $row
      | if ($row | type) == "object" and $row.type == "turn_context"
          and ($row.payload | type) == "object" and $row.payload.turn_id == $turn
        then ($row.payload.approvals_reviewer // "unknown")
        else . end)
    | if . == "auto_review" or . == "user" then . else "unknown" end
  ' 2>/dev/null
}

case "$event" in
  Stop)
    kind=stop
    if without_transcript; then
      kind=stop_without_transcript
    fi
    echo "$input" | jq -r '.last_assistant_message // ""' \
      | bash "$SEND" "$kind" "$project" Codex
    ;;
  PermissionRequest)
    # 自动审核中的 shell / 文件修改不是用户待办；其他情况仍走统一通知内核。
    [ "$(permission_reviewer)" = "auto_review" ] && exit 0
    kind=permission
    if without_transcript; then
      kind=permission_without_transcript
    fi
    printf '' | bash "$SEND" "$kind" "$project" Codex
    ;;
esac
exit 0
