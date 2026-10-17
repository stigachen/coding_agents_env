#!/bin/bash
# Grok Build status line. Grok writes one JSON object to stdin and shows
# stdout, at most five lines. Missing fields are omitted: a missing cost is
# unknown, and a missing context percentage is not zero. No network, no
# credentials, and no git — this script runs continuously during a turn.

input=$(cat)

parsed=$(printf '%s' "$input" | jq -r '
  def s: if . == null or . == "" then "" else tostring end;
  [
    (.model.display_name | s),
    (.effort.level | s),
    (if ((.workspace.current_dir | s) != "") then .workspace.current_dir else .cwd end | s),
    (.workspace.branch | s),
    (if ((.workspace.git_worktree | s) != "") then .workspace.git_worktree else .worktree.name end | s),
    (if .context_window.used_percentage == null then ""
     else (.context_window.used_percentage | floor | tostring) end),
    (if .context_window.auto_compact_threshold_percent == null then ""
     else (.context_window.auto_compact_threshold_percent | floor | tostring) end),
    (if .cost.total_cost_usd == null then "" else (.cost.total_cost_usd | tostring) end)
  ] | join("\u001f")
' 2>/dev/null) || parsed=""

model=""
effort=""
dir=""
branch=""
wt=""
ctx_pct=""
threshold=""
cost_raw=""
# Tab is IFS whitespace, so read would drop the empty fields in front of a
# real value. Unit separator is not whitespace, and it keeps those fields.
IFS=$(printf '\037')
# A failed jq leaves parsed empty. read returns 1 on EOF; the row is then blank.
read -r model effort dir branch wt ctx_pct threshold cost_raw <<EOF || true
$parsed
EOF
unset IFS

cwd_display=""
if [ -n "$dir" ]; then
  # Windows payloads use backslashes. basename only splits on /.
  dir=${dir//\\//}
  cwd_display=$(basename "$dir")
fi

line1=""
if [ -n "$model" ]; then
  line1="$model"
  if [ -n "$effort" ]; then
    line1="$line1 (effort:${effort})"
  fi
fi
if [ -n "$cwd_display" ]; then
  if [ -n "$line1" ]; then
    line1="$line1 | $cwd_display"
  else
    line1="$cwd_display"
  fi
fi
gitpart=""
if [ -n "$branch" ]; then
  gitpart="git:${branch}"
  if [ -n "$wt" ]; then
    gitpart="${gitpart}@${wt}"
  fi
elif [ -n "$wt" ]; then
  gitpart="wt:${wt}"
fi
if [ -n "$gitpart" ]; then
  if [ -n "$line1" ]; then
    line1="$line1 | $gitpart"
  else
    line1="$gitpart"
  fi
fi

line2=""
if [ -n "$ctx_pct" ]; then
  if [ -z "$threshold" ]; then
    threshold=80
  fi
  if [ "$ctx_pct" -ge "$threshold" ]; then
    color="31"
  elif [ "$ctx_pct" -ge 60 ]; then
    color="33"
  else
    color="32"
  fi
  filled=$((ctx_pct / 10))
  if [ "$filled" -gt 10 ]; then
    filled=10
  fi
  if [ "$filled" -lt 0 ]; then
    filled=0
  fi
  # █ / ░ as raw UTF-8 bytes. bash 3.2 drops bytes when a multibyte
  # character is appended to a string under a UTF-8 locale.
  bar=$(
    i=0
    while [ "$i" -lt 10 ]; do
      if [ "$i" -lt "$filled" ]; then
        printf '\342\226\210'
      else
        printf '\342\226\221'
      fi
      i=$((i + 1))
    done
  )
  line2=$(printf 'ctx \033[0;%sm%s\033[0;2m %s%%' "$color" "$bar" "$ctx_pct")
fi

cost_disp=""
if [ -n "$cost_raw" ]; then
  cost_disp=$(awk -v c="$cost_raw" 'BEGIN {
    c += 0
    if (c >= 0.005) {
      s = sprintf("%.2f", c)
      if ((s + 0) >= 0.01) printf "$%s", s
    }
  }')
fi
if [ -n "$cost_disp" ]; then
  if [ -n "$line2" ]; then
    line2="$line2 | $cost_disp"
  else
    line2="$cost_disp"
  fi
fi

if [ -z "$line1" ] && [ -z "$line2" ]; then
  exit 0
fi
if [ -n "$line1" ]; then
  printf '\033[2m%s\033[0m\n' "$line1"
fi
if [ -n "$line2" ]; then
  printf '\033[2m%s\033[0m\n' "$line2"
fi
exit 0
