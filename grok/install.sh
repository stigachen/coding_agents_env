#!/bin/bash
# Register native Grok hooks and this repo's status line.
# Hooks: only our handlers in our own JSON file are replaced; other files,
# handlers and Grok's compatibility settings are retained.
# Status line: merge [ui.status_line] type and command by TOML structure.
# Other tables and keys are kept. If the file cannot be merged safely, it is
# left unchanged and the installer fails. A symlink is edited at its target.

set -euo pipefail

# dirname only splits on /. Git Bash started from Windows may see D:\...\script.sh.
_self=${0//\\//}
REPO_DIR="${REPO_DIR:-$(cd "$(dirname "$_self")/.." && pwd)}"
. "$REPO_DIR/lib/runtime.sh"
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
    # Windows readlink can return C:\... or C:/.... A drive path is absolute.
    # Joining it onto the symlink's directory makes the install edit the wrong file.
    link=${link//\\//}
    case "$link" in
      /*|[A-Za-z]:*) p=$link ;;
      *)
        dir=$(cd "$(dirname "${p//\\//}")" && pwd)
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
status_target="$REPO_DIR/grok/statusline/statusline.sh"

# Windows status command is this file's path and nothing else. Grok starts
# that path as the program. The file calls Git Bash on statusline.sh.
write_status_wrapper() {
  local bash_exe=$1 script=$2 dest bash_w script_w wrapper_dir
  dest="$GROK_DIR/coding_agents_env-statusline.cmd"
  bash_w=$(cygpath -w "$bash_exe")
  script_w=$(cygpath -w "$script")
  # cmd expands %VAR% while it reads the line. A path percent must be doubled.
  bash_w=${bash_w//%/%%}
  script_w=${script_w//%/%%}
  # A quote would close the wrapper's quotes. & | < > ^ stay literal inside them.
  case "${bash_w}${script_w}" in
    *\"*)
      echo "Grok status line: bash or script path contains a quote, wrapper not written" >&2
      exit 1 ;;
  esac
  mkdir -p "$GROK_DIR"
  printf '%s\r\n' '@echo off' "\"${bash_w}\" \"${script_w}\"" > "$dest"
  # pwd -W is Git Bash. It prints a Windows path the status line can start.
  wrapper_dir=$(cd "$GROK_DIR" && pwd -W)
  wrapper_dir=${wrapper_dir//\\//}
  printf '%s' "${wrapper_dir}/coding_agents_env-statusline.cmd"
}

case "$(uname)" in
  MINGW*|MSYS*|CYGWIN*)
    # Quote Git Bash's bash.exe. PATH bash on Windows is usually the WSL launcher.
    # Grok's hook runner inserts & before a quoted program path that has
    # arguments, so the hook command stays without a call operator.
    # The status line starts `command` as the program name. A leading & or
    # quotes stay in that name, and Windows returns os error 123. A .cmd path
    # has neither; Windows starts .cmd itself, and the wrapper calls Git Bash.
    bash_exe=$(require_git_bash) || exit 1
    bash_quoted=$(shell_single_quote "$bash_exe")
    notify_quoted=$(shell_single_quote "$notify_target")
    NOTIFY_CMD="'$bash_quoted' '$notify_quoted'"
    status_cmd=$(write_status_wrapper "$bash_exe" "$status_target")
    ;;
  *)
    notify_quoted=$(shell_single_quote "$notify_target")
    status_quoted=$(shell_single_quote "$status_target")
    # Keep spaces and shell metacharacters in the path literal.
    NOTIFY_CMD="bash '$notify_quoted'"
    status_cmd="bash '$status_quoted'"
    ;;
esac
STATUSLINE_TOML=$(toml_basic_escape "$status_cmd")
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

# Keep only a successful stat. GNU `stat -f` is --file-system: it can print
# filesystem text and still exit non-zero, so `$(stat -f || stat -c)` would
# glue that text onto the mode. Each attempt is captured on its own.
# GNU `stat -c %a` is tried first; BSD `stat -f %OLp` is the fallback.
read_mode() {
  local path=$1 out
  if out=$(stat -c '%a' "$path" 2>/dev/null); then
    :
  elif out=$(stat -f '%OLp' "$path" 2>/dev/null); then
    :
  else
    return 1
  fi
  out=$(printf '%s' "$out" | tr -d '[:space:]')
  case $out in
    [0-7][0-7][0-7]|[0-7][0-7][0-7][0-7]) printf '%s' "$out" ;;
    *) return 1 ;;
  esac
}

# When python3 can run a script and has tomllib, refuse to publish a merge
# that does not parse or does not point at this repo's status line.
# The Windows Store python3 stub is on PATH but cannot run a script; skip it.
# Older Python without tomllib skips the check.
# Exit 1 means the file is not TOML; exit 2 means the status line is missing.
toml_check() {
  local file=$1
  python3_runs || return 0
  python3 - "$file" <<'PY'
import sys
try:
    import tomllib
except ImportError:
    sys.exit(0)
try:
    with open(sys.argv[1], "rb") as fh:
        data = tomllib.load(fh)
except tomllib.TOMLDecodeError:
    sys.exit(1)
ui = data.get("ui")
status = ui.get("status_line") if isinstance(ui, dict) else None
if not isinstance(status, dict):
    sys.exit(2)
command = status.get("command")
if status.get("type") != "command" or not isinstance(command, str):
    sys.exit(2)
if (
    "/grok/statusline/statusline.sh" not in command
    and "coding_agents_env-statusline.cmd" not in command
):
    sys.exit(2)
PY
}

require_toml() {
  local file=$1 created=$2 status=0
  toml_check "$file" || status=$?
  if [ "$status" -eq 0 ]; then
    return 0
  fi
  if [ "$created" -eq 1 ]; then
    rm -f "$file"
  fi
  if [ "$status" -eq 1 ]; then
    echo "Grok config.toml 合并结果不是合法 TOML，原文件未修改" >&2
  else
    echo "Grok config.toml 合并结果没有写入本仓库的状态栏，原文件未修改" >&2
  fi
  exit 1
}

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
    require_toml "$config" 1
    return
  fi

  mode=$(read_mode "$config") || {
    echo "Grok config.toml 无法读取权限，原文件未修改" >&2
    exit 1
  }
  sl_tmp=$(mktemp "$(dirname "$config")/.config.toml.XXXXXX")
  # LC_ALL=C makes awk scan bytes, so a multibyte string cannot hide a quote.
  if ! LC_ALL=C awk -f "$REPO_DIR/grok/statusline/merge_config.awk" "$config" > "$sl_tmp"; then
    exit 1
  fi
  require_toml "$sl_tmp" 0
  # Set the mode before rename. A failed chmod then leaves the original in place.
  chmod "$mode" "$sl_tmp"
  # Keep the first pre-install copy. A later run must not replace it with the
  # already merged file. Skip the copy when the bytes will not change, so a
  # config this installer created (no user original) never grows a .bak.
  if files_differ "$config" "$sl_tmp"; then
    preserve_original_backup "$config"
    mv "$sl_tmp" "$config"
  else
    rm -f "$sl_tmp"
  fi
  sl_tmp=""
}

install_statusline

printf '%s\n' \
  'Grok: native Stop/Notification hooks installed' \
  "   $HOOKS -> $notify_target" \
  'Grok: status line installed' \
  "   $CONFIG_LINK -> $status_target" \
  '   restart Grok to load [ui.status_line]'
