#!/bin/bash
# Register native Grok hooks and this repo's status line.
# Hooks: only our handlers in our own JSON file are replaced; other files,
# handlers and Grok's compatibility settings are retained.
# Status line: only [ui.status_line] type and command are replaced. Every
# other config.toml table and key is kept. A symlink is edited at its target.

set -euo pipefail

REPO_DIR="${REPO_DIR:-$(cd "$(dirname "$0")/.." && pwd)}"
GROK_DIR="${GROK_HOME:-$HOME/.grok}"
HOOK_DIR="$GROK_DIR/hooks"
HOOKS="$HOOK_DIR/coding_agents_env.json"
CONFIG_LINK="$GROK_DIR/config.toml"

# Quote a path for inclusion in bash '...' (POSIX) or PowerShell (Windows).
# The substitution must stay outside double quotes; quoting it changes the
# replacement and leaves a broken path literal.
shell_single_quote() {
  local path=$1 quoted
  case "$(uname)" in
    MINGW*|MSYS*|CYGWIN*)
      path=$(cygpath -m "$path")
      # Native Grok uses PowerShell on Windows; a literal apostrophe is doubled.
      quoted=${path//\'/\'\'} ;;
    *)
      # POSIX shells close the literal, escape the apostrophe, then reopen it.
      quoted=${path//\'/\'\\\'\'} ;;
  esac
  printf '%s' "$quoted"
}

# Escape a value for a TOML basic double-quoted string.
toml_basic_escape() {
  local s=$1
  s=${s//\\/\\\\}
  s=${s//\"/\\\"}
  printf '%s' "$s"
}

# Follow symlinks. mv onto the link path would replace the symlink itself.
resolve_file() {
  local p=$1 i=0 link dir
  while [ -L "$p" ] && [ "$i" -lt 10 ]; do
    link=$(readlink "$p")
    case "$link" in
      /*) p=$link ;;
      *)
        dir=$(cd "$(dirname "$p")" && pwd)
        p="$dir/$link" ;;
    esac
    i=$((i + 1))
  done
  if [ -L "$p" ]; then
    echo "Grok config.toml symlink loop: $1" >&2
    exit 1
  fi
  printf '%s\n' "$p"
}

notify_target="$REPO_DIR/grok/hooks/notify.sh"
notify_quoted=$(shell_single_quote "$notify_target")
# Keep spaces and shell metacharacters in the path literal.
NOTIFY_CMD="bash '$notify_quoted'"

status_target="$REPO_DIR/grok/statusline/statusline.sh"
status_quoted=$(shell_single_quote "$status_target")
STATUSLINE_TOML=$(toml_basic_escape "bash '$status_quoted'")
export STATUSLINE_TOML

mkdir -p "$HOOK_DIR"
tmp=$(mktemp "$HOOK_DIR/.coding_agents_env.XXXXXX")
sl_tmp=""
trap 'rm -f "$tmp" "$tmp.merged" ${sl_tmp:+"$sl_tmp"}' EXIT
if [ -e "$HOOKS" ]; then
  jq -e -s 'length == 1 and (.[0] | type == "object" and ((.hooks // {}) | type == "object"))' "$HOOKS" >/dev/null
  cat "$HOOKS" > "$tmp"
else
  printf '{}\n' > "$tmp"
fi

jq --arg notify "$NOTIFY_CMD" '
  def ours: .type == "command" and ((.command // "") | contains("/grok/hooks/notify.sh"));
  def strip_ours:
    map(if any(.hooks[]?; ours)
        then .hooks |= map(select(ours | not)) | select(.hooks | length > 0)
        else . end);
  .hooks = (.hooks // {})
  | .hooks.Stop = ((.hooks.Stop // []) | strip_ours)
      + [{hooks: [{type: "command", command: $notify, timeout: 30}]}]
  | .hooks.Notification = ((.hooks.Notification // []) | strip_ours)
      + [{hooks: [{type: "command", command: $notify, timeout: 30}]}]
' "$tmp" > "$tmp.merged"
mv "$tmp.merged" "$HOOKS"

install_statusline() {
  local config mode
  if [ -e "$CONFIG_LINK" ] || [ -L "$CONFIG_LINK" ]; then
    config=$(resolve_file "$CONFIG_LINK")
    if [ ! -e "$config" ]; then
      echo "Grok config.toml 软链悬空：${CONFIG_LINK} -> ${config}" >&2
      exit 1
    fi
    if [ ! -f "$config" ]; then
      echo "Grok config.toml 不是普通文件：${config}" >&2
      exit 1
    fi
  else
    config=$CONFIG_LINK
  fi

  if [ ! -f "$config" ]; then
    mkdir -p "$(dirname "$config")"
    printf '%s\n' \
      '[ui.status_line]' \
      'type = "command"' \
      "command = \"${STATUSLINE_TOML}\"" \
      > "$config"
    return
  fi

  # %OLp is "octal, user/group/other only" on BSD stat. GNU stat uses -c %a.
  mode=$(stat -f '%OLp' "$config" 2>/dev/null || stat -c '%a' "$config" 2>/dev/null || true)
  cp "$config" "$config.bak"
  sl_tmp=$(mktemp "$(dirname "$config")/.config.toml.XXXXXX")
  awk '
BEGIN { cmd = ENVIRON["STATUSLINE_TOML"]; seen = 0; ours = 0; in_sl = 0; use_cr = 0; last = "" }
function stripped(s) { sub(/\r$/, "", s); return s }
function emit_new(cr) {
  printf "%s%s\n", "type = \"command\"", cr
  printf "%s%s\n", "command = \"" cmd "\"", cr
}
{
  raw = $0
  cr = ""
  if (raw ~ /\r$/) { use_cr = 1; cr = "\r" }
  l = stripped(raw)
  last = l
  if (l ~ /^[ \t]*\[[ \t]*ui\.status_line[ \t]*\][ \t]*(#.*)?$/) {
    seen = 1
    in_sl = 1
    print raw
    emit_new(cr)
    next
  }
  if (l ~ /^[ \t]*\[/) in_sl = 0
  if (in_sl && l ~ /^[ \t]*(type|command)[ \t]*=/) {
    if (l ~ /^[ \t]*command[ \t]*=/ && index(l, "/grok/statusline/statusline.sh") > 0) ours = 1
    next
  }
  print raw
}
END {
  end_cr = use_cr ? "\r" : ""
  if (!seen) {
    if (NR > 0 && last != "") printf "%s\n", end_cr
    printf "%s%s\n", "[ui.status_line]", end_cr
    emit_new(end_cr)
  } else if (!ours) {
    print "ℹ️  config.toml [ui.status_line] 原有配置已被仓库的 command 状态栏接管" > "/dev/stderr"
  }
}
' "$config" > "$sl_tmp"
  mv "$sl_tmp" "$config"
  sl_tmp=""
  if [ -n "$mode" ]; then
    chmod "$mode" "$config"
  fi
}

install_statusline

printf '%s\n' \
  'Grok: native Stop/Notification hooks installed' \
  "   $HOOKS -> $notify_target" \
  'Grok: status line installed' \
  "   $CONFIG_LINK -> $status_target" \
  '   restart Grok to load [ui.status_line]'
