#!/bin/bash
# 把本仓库的 coding agent 定制安装到当前机器。
# 幂等：重复执行只会刷新配置，不会产生重复条目；也是从旧版仓库布局升级的方式。
#
# 做的事：
#   1. 生成 / 迁移 / 补齐各 agent 共用的本机配置 ~/.config/coding_agents_env/notify.env
#      （旧版仓库放在 ~/.claude/notify.env，检测到即自动迁移，token 原样保留）
#   2. 检测本机装了哪些 agent，逐个执行 <agent>/install.sh：
#        claude/    → ~/.claude/settings.json 的 statusLine + Notification/Stop hooks
#        codex/     → ~/.codex/hooks.json + config.toml 的 [tui] status_line
#        opencode/  → ~/.config/opencode/plugins/ 的通知插件
#      也可只装指定的：bash install.sh claude
#
# 原则：只增删本仓库自己的条目（按脚本路径特征识别），机器上已有的其他工具
# 的 hooks / 插件 / 配置一律不动。
# settings 引用的是仓库内脚本的绝对路径，git pull 后无需重新安装；
# 仓库移动位置后需要重跑一次本脚本。

set -euo pipefail

REPO_DIR=$(cd "$(dirname "$0")" && pwd)
export REPO_DIR
CLAUDE_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
CONFIG_DIR="${CODING_AGENTS_ENV_DIR:-$HOME/.config/coding_agents_env}"
ENV_FILE="$CONFIG_DIR/notify.env"
LEGACY_ENV="$CLAUDE_DIR/notify.env"
TEMPLATE="$REPO_DIR/lib/notify.env.example"

# ---- 依赖检查 ----
for dep in jq curl; do
  command -v "$dep" >/dev/null 2>&1 || {
    echo "缺少依赖：${dep}（macOS: brew install ${dep}；Windows Git Bash 需把 ${dep}.exe 放进 PATH）" >&2
    exit 1
  }
done

chmod +x "$REPO_DIR"/lib/*.sh "$REPO_DIR"/*/hooks/*.sh "$REPO_DIR"/*/statusline/*.sh \
  "$REPO_DIR"/*/install.sh 2>/dev/null || true

# ---- notify.env：生成 / 迁移 / 补齐 ----
mkdir -p "$CONFIG_DIR"
ENV_CREATED=0
if [ ! -f "$ENV_FILE" ]; then
  if [ -f "$LEGACY_ENV" ] && [ ! -L "$LEGACY_ENV" ]; then
    # 旧版仓库的配置在 ~/.claude/notify.env：搬到新位置，token 原样保留
    tr -d '\r' < "$LEGACY_ENV" > "$ENV_FILE"
    chmod 600 "$ENV_FILE" 2>/dev/null || true
    case "$(uname)" in
      MINGW*|MSYS*|CYGWIN*)
        # Git Bash 的 ln -s 默认是复制而非链接，留一份"假链接"反而会误导；
        # 改名归档，避免以后改错文件
        mv "$LEGACY_ENV" "$LEGACY_ENV.migrated"
        echo "ℹ️  已把 $LEGACY_ENV 迁移到 ${ENV_FILE}（旧文件改名为 notify.env.migrated）" ;;
      *)
        if ln -s "$ENV_FILE" "$LEGACY_ENV.tmp" 2>/dev/null && mv -f "$LEGACY_ENV.tmp" "$LEGACY_ENV"; then
          echo "ℹ️  已把 $LEGACY_ENV 迁移到 ${ENV_FILE}（旧路径保留为软链）"
        else
          rm -f "$LEGACY_ENV.tmp"
          mv "$LEGACY_ENV" "$LEGACY_ENV.migrated"
          echo "ℹ️  已把 $LEGACY_ENV 迁移到 ${ENV_FILE}（旧文件改名为 notify.env.migrated）"
        fi ;;
    esac
  else
    # tr 而非 cp：Windows 检出可能是 CRLF，归一化为 LF（该文件会被 bash 加载）
    tr -d '\r' < "$TEMPLATE" > "$ENV_FILE"
    ENV_CREATED=1
  fi
elif [ -f "$LEGACY_ENV" ] && [ ! -L "$LEGACY_ENV" ]; then
  echo "⚠️  $LEGACY_ENV 和 $ENV_FILE 同时存在，脚本只读后者；确认无用后可删除前者" >&2
fi

# 改名过的键：旧键有值、新键缺失时，用旧值生成新键（不用模板默认值覆盖用户设置）
RENAMED_KEYS="STATUSLINE_USAGE_API:CLAUDE_STATUSLINE_USAGE_API"
for pair in $RENAMED_KEYS; do
  old=${pair%%:*}; new=${pair##*:}
  if grep -q "^${old}=" "$ENV_FILE" && ! grep -q "^${new}=" "$ENV_FILE"; then
    val=$(sed -n "s/^${old}=//p" "$ENV_FILE" | tail -1)
    printf '\n%s=%s\n' "$new" "$val" >> "$ENV_FILE"
    echo "ℹ️  notify.env：$old 已改名为 ${new}（值 $val 保留，旧键可删）"
  fi
done

# 补齐模板后来新增的开关（只追加缺失的 KEY=默认值，不动已填的值）
appended=""
while IFS= read -r line; do
  key=${line%%=*}
  if ! grep -q "^${key}=" "$ENV_FILE"; then
    [ -n "$appended" ] || printf '\n# ---- install.sh 补齐的新开关（含义见仓库 lib/notify.env.example）----\n' \
      >> "$ENV_FILE"
    printf '%s\n' "$line" >> "$ENV_FILE"
    appended=1
  fi
done < <(tr -d '\r' < "$TEMPLATE" | grep '^[A-Z_][A-Z_]*=')
[ -z "$appended" ] || echo "ℹ️  已向 $ENV_FILE 追加新增开关（默认值，可按需修改）"
chmod 600 "$ENV_FILE" 2>/dev/null || true

# ---- 各 agent ----
if [ $# -gt 0 ]; then
  agents="$*"
else
  agents=""
  { [ -d "$CLAUDE_DIR" ] || command -v claude >/dev/null 2>&1; } && agents="$agents claude"
  { [ -d "${CODEX_HOME:-$HOME/.codex}" ] || command -v codex >/dev/null 2>&1; } && agents="$agents codex"
  { [ -d "$HOME/.config/opencode" ] || command -v opencode >/dev/null 2>&1; } && agents="$agents opencode"
fi

installed=""
for a in $agents; do
  if [ -f "$REPO_DIR/$a/install.sh" ]; then
    bash "$REPO_DIR/$a/install.sh"
    installed="$installed $a"
  else
    echo "ℹ️  跳过 ${a}：本仓库尚无 $a/install.sh"
  fi
done
[ -n "$installed" ] || { echo "未检测到任何受支持的 agent（claude / codex / opencode）" >&2; exit 1; }

echo ""
echo "✅ 安装完成：$installed"
echo "   共用配置 → $ENV_FILE"
if [ "$ENV_CREATED" = "1" ]; then
  echo ""
  echo "⚠️  已生成 ${ENV_FILE}，请填入 Telegram/Discord 配置后 IM 通知才会生效"
fi
echo ""
echo "下一步：重启各 agent 会话；Claude Code 用 /hooks 确认 hooks 已注册。"
