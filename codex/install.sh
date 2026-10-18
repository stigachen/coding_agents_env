#!/bin/bash
# Codex CLI 部分的部署：
#   1. ~/.codex/hooks.json：注册 Stop / PermissionRequest hooks → codex/hooks/notify.sh
#   2. ~/.codex/config.toml：
#      - [hooks.state."<hooks.json>:<event>:<i>:<j>"] trusted_hash：Codex 只执行
#        "已信任" 的 hook（否则 TUI 启动时要求逐个审核，exec 模式直接跳过）。
#        这里按 Codex 的算法预先算好并写入，免去手工审核
#      - [features] hooks = true（缺失时补上；用户显式设 false 则尊重并提示）
#      - [tui] 里插入 codex/tui.toml 的状态栏项（带 "# coding_agents_env" 标记）
# 由根目录 install.sh 调用，也可单独执行。幂等：只增删本仓库自己的条目
# （hooks.json 按 "/hooks/notify.sh" 路径特征识别；config.toml 按标记和自家
# hash/key 识别），不碰其他工具写入的任何 hook / 配置键。

set -euo pipefail

REPO_DIR="${REPO_DIR:-$(cd "$(dirname "$0")/.." && pwd)}"
. "$REPO_DIR/lib/runtime.sh"
CODEX_HOME="${CODEX_HOME:-$HOME/.codex}"
HOOKS="$CODEX_HOME/hooks.json"
CONFIG="$CODEX_HOME/config.toml"
MARK="# coding_agents_env"
# Resolve the hook command before creating any files, so a missing Git Bash
# does not leave an empty Codex home behind.
case "$(uname)" in
  MINGW*|MSYS*|CYGWIN*)
    # Codex runs the command outside Git Bash. PATH bash is often the WSL
    # launcher, which does not understand a C:/... script path.
    bash_exe=$(require_git_bash) || exit 1
    script=$(cygpath -m "$REPO_DIR/codex/hooks/notify.sh")
    NOTIFY_CMD="\"$bash_exe\" \"$script\""
    ;;
  *)
    NOTIFY_CMD="bash \"$REPO_DIR/codex/hooks/notify.sh\""
    ;;
esac
TIMEOUT=30

mkdir -p "$CODEX_HOME"
[ -f "$HOOKS" ] || echo '{"hooks":{}}' > "$HOOKS"
# Snapshot a pre-existing config for rollback. An absent file is created empty
# for the rewrite below, but that placeholder is not a user original and must
# not become config.toml.bak.
config_existed=0
rollback=""
if [ -f "$CONFIG" ]; then
  config_existed=1
  rollback=$(mktemp)
  cp "$CONFIG" "$rollback"
else
  : > "$CONFIG"
fi

# Codex 记 hook 信任状态用的路径是 hooks.json 的绝对路径（Windows 下是原生路径）
HOOKS_KEY_PATH=$(cd "$CODEX_HOME" && pwd -P)/hooks.json
case "$(uname)" in
  MINGW*|MSYS*|CYGWIN*) HOOKS_KEY_PATH=$(cygpath -w "$HOOKS_KEY_PATH") ;;
esac

sha256() {
  if command -v shasum >/dev/null 2>&1; then shasum -a 256 | cut -d' ' -f1
  elif command -v sha256sum >/dev/null 2>&1; then sha256sum | cut -d' ' -f1
  else openssl dgst -sha256 | sed 's/.*= *//'
  fi
}

# TOML basic string, including the quotes. A literal '…' string ends at the
# first apostrophe, so C:\Users\O'Brien\... is not valid TOML. Backslashes are
# escaped and apostrophes stay inside the double quotes.
toml_basic_string() {
  local s=$1
  s=${s//\\/\\\\}
  s=${s//\"/\\\"}
  printf '"%s"' "$s"
}

# ---- 1. hooks.json ----
tmp=$(mktemp)
jq --arg notify "$NOTIFY_CMD" --argjson t "$TIMEOUT" '
  def strip_ours: map(select([.hooks[]?.command // ""] | any(contains("/hooks/notify.sh")) | not));
  .hooks = (.hooks // {})
  | .hooks.Stop = ((.hooks.Stop // []) | strip_ours)
      + [{hooks: [{type: "command", command: $notify, timeout: $t}]}]
  | .hooks.PermissionRequest = ((.hooks.PermissionRequest // []) | strip_ours)
      + [{hooks: [{type: "command", command: $notify, timeout: $t}]}]
' "$HOOKS" > "$tmp"
mv "$tmp" "$HOOKS"

# ---- 2. config.toml ----
# 2a. 信任 hash：Codex 对 {event_name, matcher?, hooks:[归一化后的 handler]} 做
#     canonical JSON（键排序、紧凑）再 sha256（codex-rs/hooks/src/engine/discovery.rs
#     hook_hash + config/src/fingerprint.rs version_for_toml）。归一化会把 timeout
#     补成实际值、async 补成 false。state key 为 <hooks.json 路径>:<event 小写>:<组序号>:<handler 序号>
our_keys=""; our_hashes=""; state_blocks=""
for pair in Stop:stop PermissionRequest:permission_request; do
  ev=${pair%%:*}; label=${pair##*:}
  gi=$(jq -r --arg ev "$ev" '.hooks[$ev] | to_entries[] | select([.value.hooks[]?.command // ""] | any(contains("/hooks/notify.sh"))) | .key' "$HOOKS" | head -1)
  h=$(jq -n -S -c --arg l "$label" --arg c "$NOTIFY_CMD" --argjson t "$TIMEOUT" \
        '{event_name: $l, hooks: [{type: "command", command: $c, timeout: $t, async: false}]}' \
      | tr -d '\n' | sha256)
  key="$HOOKS_KEY_PATH:$label:$gi:0"
  qkey=$(toml_basic_string "$key")
  our_keys="$our_keys
$key"
  our_hashes="$our_hashes
sha256:$h"
  state_blocks="$state_blocks
[hooks.state.$qkey]
trusted_hash = \"sha256:$h\"
"
done

# 2b. 用 awk 重写 config.toml：
#   - 删掉属于我们的 [hooks.state."…"] 块（key 指向我们的槽位，或 hash 是我们的）
#   - 删掉带标记的旧行；[tui] 表里与 codex/tui.toml 同名的未标记键也删（我们接管该键）
#   - [tui] 头后插入 codex/tui.toml 的行；[features] 里补 hooks = true
tui_lines=$(grep -E '^[a-z_]+ *=' "$REPO_DIR/codex/tui.toml" | tr -d '\r' | sed "s/\$/  $MARK/")
tui_keys=$(printf '%s\n' "$tui_lines" | sed 's/ *=.*//' | tr '\n' ' ')
# 多行值经 ENVIRON 传给 awk（BSD awk 的 -v 不接受含换行的字符串）
export OUR_KEYS="$our_keys" OUR_HASHES="$our_hashes" TUI_LINES="$tui_lines"
awk -v tui_keys="$tui_keys" -v mark="$MARK" '
BEGIN {
  tui_lines = ENVIRON["TUI_LINES"]
  n = split(ENVIRON["OUR_KEYS"], a, "\n");   for (i = 1; i <= n; i++) if (a[i] != "") K[a[i]] = 1
  n = split(ENVIRON["OUR_HASHES"], a, "\n"); for (i = 1; i <= n; i++) if (a[i] != "") H[a[i]] = 1
  n = split(tui_keys, a, " ");                for (i = 1; i <= n; i++) if (a[i] != "") TK[a[i]] = 1
  seen_tui = 0; seen_features = 0; features_has_hooks = 0
}
# 取 hooks.state 头里的键名，双引号和字面引号都认。
# 基本字符串还原反斜杠，才能和 OUR_KEYS 里的原始路径比较；字面字符串只去引号。
# 重装因此会删掉旧的字面引号键，而不是留下重复键。
function is_state_header(l) {
  return substr(l, 1, 13) == "[hooks.state." && (substr(l, 14, 1) == "\"" || substr(l, 14, 1) == "\047")
}
function state_key(l,    k, quote, i, n, c, out) {
  if (!is_state_header(l)) return ""
  k = substr(l, 14)
  sub(/\][ \t]*$/, "", k)
  quote = substr(k, 1, 1)
  if (quote == "\047") {
    sub(/^\047/, "", k)
    sub(/\047$/, "", k)
    return k
  }
  sub(/^"/, "", k)
  sub(/"$/, "", k)
  out = ""
  n = length(k)
  i = 1
  while (i <= n) {
    c = substr(k, i, 1)
    if (c == "\\" && i < n) {
      out = out substr(k, i + 1, 1)
      i += 2
    } else {
      out = out c
      i++
    }
  }
  return out
}
# 第一遍：找出要删的 hooks.state 块（按 key 或 hash）。匹配前去掉行尾 \r，
# Windows 上 config.toml 可能是 CRLF；输出仍写原行，不改用户文件的换行风格
NR == FNR {
  l = $0; sub(/\r$/, "", l)
  if (is_state_header(l)) {
    cur = state_key(l)
    if (cur in K) DROP[cur] = 1
  } else if (l ~ /^\[/) cur = ""
  else if (cur != "" && l ~ /^trusted_hash *=/) {
    v = l; sub(/^trusted_hash *= *"/, "", v); sub(/".*/, "", v)
    if (v in H) DROP[cur] = 1
  }
  next
}
# 空行先攒着，遇到下一行实际内容再吐出：删块、追加块时不会越攒越多空行
function out(l) { if (l == "") { pending++; return } ; while (pending > 0) { print ""; pending-- } ; print l }
# 第二遍：输出
{
  line = $0; l = line; sub(/\r$/, "", l)
  if (l ~ /^\[/) {
    section = l
    if (is_state_header(l)) {
      dropping = (state_key(l) in DROP); if (dropping) next
    } else dropping = 0
    if (l ~ /^\[tui\]/)      { out(line); seen_tui = 1; out(tui_lines); next }
    if (l ~ /^\[features\]/) { out(line); seen_features = 1; in_features = 1; next }
    in_features = 0
  }
  if (dropping) next
  if (index(line, mark) > 0) next
  if (section ~ /^\[tui\]/ && l ~ /^[a-z_]+ *=/) {
    k = l; sub(/ *=.*/, "", k)
    if (k in TK) { printf("ℹ️  config.toml [tui] 原有的 %s 已被仓库版本接管\n", k) > "/dev/stderr"; next }
  }
  if (in_features && l ~ /^hooks *=/) {
    features_has_hooks = 1
    if (l ~ /false/) printf("⚠️  config.toml [features] hooks = false，Codex 不会执行任何 hook；需要通知请改成 true\n") > "/dev/stderr"
  }
  out(line)
}
END {
  if (!seen_tui)      { print ""; print "[tui]"; print tui_lines }
  if (!seen_features) { print ""; print "[features]"; print "hooks = true  " mark }
  else if (!features_has_hooks) FEATURES_FIX = 1
  if (FEATURES_FIX) exit 42
}' "$CONFIG" "$CONFIG" > "$CONFIG.tmp" || {
  rc=$?
  if [ "$rc" = "42" ]; then
    # [features] 存在但没有 hooks 键：在其表头后插一行
    awk -v mark="$MARK" '{ print } /^\[features\]/ { print "hooks = true  " mark }' "$CONFIG.tmp" > "$CONFIG.tmp2"
    mv "$CONFIG.tmp2" "$CONFIG.tmp"
  else
    rm -f "$CONFIG.tmp" "$rollback"
    echo "改写 $CONFIG 失败" >&2
    exit 1
  fi
}
# 追加我们的信任块（放文件末尾；上面已删掉旧的同 key / 同 hash 块，不会重复定义）
printf '%s' "$state_blocks" >> "$CONFIG.tmp"
# 只在真正改写一份已经存在的配置时，把改写前的内容留下。bak 已存在则不动，
# 这样第二次安装不会用已经改过的文件盖掉用户原件。原来没有 config.toml 时不备份。
if [ "$config_existed" = "1" ] && files_differ "$CONFIG" "$CONFIG.tmp"; then
  preserve_original_backup "$CONFIG"
fi
mv "$CONFIG.tmp" "$CONFIG"

# 语法自检：python3 能真正执行脚本且带 tomllib 时才校验。Windows Store 的
# python3 占位程序（常见退出码 9009）视为没有 Python，不回滚已经写好的文件。
# 只有退出码 1（解析失败）才回滚。
if python3_runs; then
  set +e
  python3 - "$CONFIG" <<'PY' 2>/dev/null
import sys
try:
    import tomllib
except ImportError:
    sys.exit(0)
tomllib.load(open(sys.argv[1], "rb"))
PY
  rc=$?
  set -e
  if [ "$rc" -eq 1 ]; then
    echo "⚠️  $CONFIG 不是合法 TOML，已恢复这一轮改写前的内容" >&2
    if [ -n "$rollback" ] && [ -f "$rollback" ]; then
      cp "$rollback" "$CONFIG"
    elif [ "$config_existed" = "0" ]; then
      rm -f "$CONFIG"
    fi
    rm -f "$rollback"
    exit 1
  fi
fi
rm -f "$rollback"

echo "✅ Codex"
echo "   Stop/PermissionRequest hooks → $REPO_DIR/codex/hooks/notify.sh（已写入信任 hash）"
echo "   [tui] status_line            → 来自 codex/tui.toml"
echo "   hooks.json / config.toml     → ${CODEX_HOME}（已有 config.toml 时，首次改写前备份为 config.toml.bak，重复安装不覆盖）"
