#!/bin/bash
# 把本仓库的 Claude Code 定制安装到当前机器。
# 幂等：重复执行只会刷新配置，不会产生重复条目。
#
# 做的事：
#   1. ~/.claude/settings.json 中写入 statusLine 配置（指向仓库内脚本的绝对路径）
#   2. 注册 Notification / Stop hooks → hooks/notify.sh（IM 通知）
#   3. 生成 ~/.claude/notify.env 模板（已存在则不动）
#
# settings 引用的是仓库内脚本的绝对路径，git pull 后无需重新安装；
# 仓库移动位置后需要重跑一次本脚本。

set -euo pipefail

REPO_DIR=$(cd "$(dirname "$0")" && pwd)
CLAUDE_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
SETTINGS="$CLAUDE_DIR/settings.json"

# ---- 依赖检查 ----
for dep in jq curl; do
  command -v "$dep" >/dev/null 2>&1 || {
    echo "缺少依赖：$dep（macOS: brew install $dep；Windows Git Bash 需把 ${dep}.exe 放进 PATH）" >&2
    exit 1
  }
done

mkdir -p "$CLAUDE_DIR"
[ -f "$SETTINGS" ] || echo '{}' > "$SETTINGS"
chmod +x "$REPO_DIR"/statusline/*.sh "$REPO_DIR"/hooks/*.sh 2>/dev/null || true

# ---- 合并 settings.json ----
# statusLine 直接覆盖；hooks 先移除本仓库旧条目（按 notify.sh 路径特征识别）再追加，
# 不影响用户手工配置的其他 hooks。
STATUSLINE_CMD="bash \"$REPO_DIR/statusline/statusline.sh\""
NOTIFY_CMD="bash \"$REPO_DIR/hooks/notify.sh\""

tmp=$(mktemp)
jq --arg sl "$STATUSLINE_CMD" --arg notify "$NOTIFY_CMD" '
  def strip_ours: map(select([.hooks[]?.command // ""] | any(contains("/hooks/notify.sh")) | not));
  .statusLine = {type: "command", command: $sl}
  | .hooks.Notification = ((.hooks.Notification // []) | strip_ours)
      + [{matcher: "permission_prompt|idle_prompt",
          hooks: [{type: "command", command: $notify, timeout: 10}]}]
  | .hooks.Stop = ((.hooks.Stop // []) | strip_ours)
      + [{hooks: [{type: "command", command: $notify, timeout: 10}]}]
' "$SETTINGS" > "$tmp"
mv "$tmp" "$SETTINGS"

# ---- notify.env（本机密钥，不入库，仅本人可读）----
if [ ! -f "$CLAUDE_DIR/notify.env" ]; then
  cp "$REPO_DIR/hooks/notify.env.example" "$CLAUDE_DIR/notify.env"
  NOTIFY_ENV_CREATED=1
else
  NOTIFY_ENV_CREATED=0
fi
chmod 600 "$CLAUDE_DIR/notify.env" 2>/dev/null || true

echo "✅ 安装完成"
echo "   statusLine        → $REPO_DIR/statusline/statusline.sh"
echo "   Notification/Stop → $REPO_DIR/hooks/notify.sh"
echo "   settings          → $SETTINGS"
if [ "$NOTIFY_ENV_CREATED" = "1" ]; then
  echo ""
  echo "⚠️  已生成 $CLAUDE_DIR/notify.env，请填入 Telegram/Discord 配置后 IM 通知才会生效"
fi
echo ""
echo "下一步：重启 Claude Code 会话；用 /hooks 确认 hooks 已注册。"
