# Shared installer helpers. Source this after REPO_DIR is set.
# bash 3.2 / Git Bash. No arrays. Do not run commands at source time.
#
# Callers that enable set -e must invoke these from an if/|| list. On bash 3.2,
# set -e is suppressed for the whole function body in that case, so every
# failing command below is checked explicitly.

# Print Git Bash's bash.exe as a C:/... path.
# Return 1 when this is not Windows. Return 2 when Git Bash was not found.
# System32\bash.exe is the WSL launcher and is skipped.
git_bash_exe() {
  case "$(uname)" in
    MINGW*|MSYS*|CYGWIN*) ;;
    *) return 1 ;;
  esac

  # Print a usable bash.exe, or return 1. stdout is the C:/... path.
  _git_bash_emit() {
    [ -n "$1" ] && [ -f "$1" ] || return 1
    local win lower mingw
    win=$(cygpath -w "$1" 2>/dev/null) || win=$1
    # Compare a folded form so System32 / Sysnative / SysWOW64 all match.
    lower=$(printf '%s' "$win" | tr '\\' '/' | tr '[:upper:]' '[:lower:]') || return 1
    case "$lower" in
      *:/windows/system32/bash.exe) return 1 ;;
      *:/windows/sysnative/bash.exe) return 1 ;;
      *:/windows/syswow64/bash.exe) return 1 ;;
    esac
    mingw=$(cygpath -m "$1" 2>/dev/null) || return 1
    [ -n "$mingw" ] || return 1
    printf '%s\n' "$mingw"
  }

  if _git_bash_emit "${CLAUDE_CODE_GIT_BASH_PATH:-}"; then
    return 0
  fi

  local root
  if [ -n "${PROGRAMFILES:-}" ]; then
    if _git_bash_emit "$PROGRAMFILES/Git/bin/bash.exe"; then return 0; fi
    if _git_bash_emit "$PROGRAMFILES/Git/usr/bin/bash.exe"; then return 0; fi
  fi
  if [ -n "${LOCALAPPDATA:-}" ]; then
    if _git_bash_emit "$LOCALAPPDATA/Programs/Git/bin/bash.exe"; then return 0; fi
    if _git_bash_emit "$LOCALAPPDATA/Programs/Git/usr/bin/bash.exe"; then return 0; fi
  fi
  # The variable name contains parentheses; ${ProgramFiles(x86)} is a syntax error.
  root=$(printenv 'ProgramFiles(x86)' 2>/dev/null || true)
  root=${root%$'\r'}
  if [ -n "$root" ]; then
    if _git_bash_emit "$root/Git/bin/bash.exe"; then return 0; fi
    if _git_bash_emit "$root/Git/usr/bin/bash.exe"; then return 0; fi
  fi

  # Git Bash's PATH is colon-separated. Walk every entry: the first bash is
  # often the WSL launcher, and a later one can still be Git Bash.
  # local IFS is restored when this function returns.
  local IFS dir
  IFS=:
  for dir in $PATH; do
    if _git_bash_emit "$dir/bash.exe"; then return 0; fi
    if _git_bash_emit "$dir/bash"; then return 0; fi
  done
  return 2
}

# Print the C:/... path, or a message on stderr and return non-zero.
require_git_bash() {
  local exe
  if exe=$(git_bash_exe); then
    printf '%s\n' "$exe"
    return 0
  fi
  echo "找不到 Git Bash。请安装 Git for Windows，或设置 CLAUDE_CODE_GIT_BASH_PATH 为 bash.exe 的绝对路径。" >&2
  return 1
}

# Return 0 only when python3 can execute a script.
# The Microsoft Store stub is often on PATH and exits non-zero (commonly 9009)
# without starting Python. Treat that as "no python3".
python3_runs() {
  command -v python3 >/dev/null 2>&1 || return 1
  python3 -c 'import sys; raise SystemExit(0)' >/dev/null 2>&1 || return 1
}
