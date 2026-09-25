#!/bin/bash
# Claude Code 部分的部署：向 ~/.claude/settings.json 写入
#   - statusLine → claude/statusline/statusline.sh
#   - Notification / Stop hooks → claude/hooks/notify.sh
# 由根目录 install.sh 调用，也可单独执行。幂等：重复执行只刷新本仓库自己的
# 条目（按 "/hooks/notify.sh" 路径特征识别，旧版仓库布局的条目也能识别并替换），
# 不碰用户或其他工具写入的任何 hook / 设置。

set -euo pipefail

REPO_DIR="${REPO_DIR:-$(cd "$(dirname "$0")/.." && pwd)}"
CLAUDE_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
SETTINGS="$CLAUDE_DIR/settings.json"

mkdir -p "$CLAUDE_DIR"
[ -f "$SETTINGS" ] || echo '{}' > "$SETTINGS"

# Notification 不设 matcher（放行所有通知类型）：哪些类型要推送由 send.sh 读
# notify.env 里的开关决定，这样部署一次后调整开关只改 notify.env、即时生效。
STATUSLINE_CMD="bash \"$REPO_DIR/claude/statusline/statusline.sh\""
NOTIFY_CMD="bash \"$REPO_DIR/claude/hooks/notify.sh\""

tmp=$(mktemp)
jq --arg sl "$STATUSLINE_CMD" --arg notify "$NOTIFY_CMD" '
  def strip_ours: map(select([.hooks[]?.command // ""] | any(contains("/hooks/notify.sh")) | not));
  .statusLine = {type: "command", command: $sl}
  | .hooks.Notification = ((.hooks.Notification // []) | strip_ours)
      + [{hooks: [{type: "command", command: $notify, timeout: 30}]}]
  | .hooks.Stop = ((.hooks.Stop // []) | strip_ours)
      + [{hooks: [{type: "command", command: $notify, timeout: 30}]}]
' "$SETTINGS" > "$tmp"
mv "$tmp" "$SETTINGS"

echo "✅ Claude Code"
echo "   statusLine        → $REPO_DIR/claude/statusline/statusline.sh"
echo "   Notification/Stop → $REPO_DIR/claude/hooks/notify.sh"
echo "   settings          → $SETTINGS"
