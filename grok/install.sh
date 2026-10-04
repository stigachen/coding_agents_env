#!/bin/bash
# Register native Grok hooks. Only our handlers in our own JSON file are
# replaced; other files, handlers and Grok's compatibility settings are retained.

set -euo pipefail

REPO_DIR="${REPO_DIR:-$(cd "$(dirname "$0")/.." && pwd)}"
GROK_DIR="${GROK_HOME:-$HOME/.grok}"
HOOK_DIR="$GROK_DIR/hooks"
HOOKS="$HOOK_DIR/coding_agents_env.json"
target="$REPO_DIR/grok/hooks/notify.sh"
case "$(uname)" in
  MINGW*|MSYS*|CYGWIN*)
    target=$(cygpath -m "$target")
    # Native Grok uses PowerShell on Windows; a literal apostrophe is doubled.
    quoted=${target//\'/\'\'} ;;
  *)
    # POSIX shells close the literal, escape the apostrophe, then reopen it.
    quoted=${target//\'/\'\\\'\'} ;;
esac
# Keep spaces and shell metacharacters in the path literal.
NOTIFY_CMD="bash '$quoted'"

mkdir -p "$HOOK_DIR"
tmp=$(mktemp "$HOOK_DIR/.coding_agents_env.XXXXXX")
trap 'rm -f "$tmp" "$tmp.merged"' EXIT
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

printf '%s\n' 'Grok: native Stop/Notification hooks installed' "   $HOOKS -> $target"
