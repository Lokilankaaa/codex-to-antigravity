#!/usr/bin/env sh
# Cross-platform POSIX launcher for codex2agy.py (macOS & Linux)
set -eu

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
PY_SCRIPT="$SCRIPT_DIR/codex2agy.py"

find_python3() {
  for cand in /opt/homebrew/bin/python3 /usr/local/bin/python3; do
    if [ -x "$cand" ]; then
      printf '%s\n' "$cand"
      return 0
    fi
  done
  if command -v python3 >/dev/null 2>&1; then
    p="$(command -v python3)"
    # On macOS, /usr/bin/python3 is an Xcode CLT shim; verify CLT is present so we don't pop a GUI dialog
    if [ "$(uname -s)" = "Darwin" ] && [ "$p" = "/usr/bin/python3" ]; then
      if ! xcode-select -p >/dev/null 2>&1; then
        return 1
      fi
    fi
    printf '%s\n' "$p"
    return 0
  fi
  return 1
}

if PY_BIN="$(find_python3)"; then
  exec "$PY_BIN" "$PY_SCRIPT" "$@"
fi

echo "Error: Python 3.8+ was not found. On macOS, run 'xcode-select --install' or 'brew install python', then retry." >&2
exit 1
