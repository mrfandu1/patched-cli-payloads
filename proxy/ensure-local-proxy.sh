#!/data/data/com.termux/files/usr/bin/bash

# Start the detached supervisor if it is not already running.
set -u
user_home="${HOME:?HOME is required}"
supervisor="$user_home/bin/start-local-proxy.sh"
lock_dir="$user_home/.local-proxy-supervisor.lock"
supervisor_log="$user_home/.local-proxy-supervisor.log"

[ -x "$supervisor" ] || exit 1

if [ -r "$lock_dir/pid" ]; then
  owner="$(cat "$lock_dir/pid" 2>/dev/null || true)"
  case "$owner" in
    ''|*[!0-9]*) ;;
    *)
      if kill -0 "$owner" 2>/dev/null; then
        exit 0
      fi
      ;;
  esac
fi

# This prevents CPU sleep while Termux is expected to keep the proxy available.
if command -v termux-wake-lock >/dev/null 2>&1; then
  termux-wake-lock >/dev/null 2>&1 || true
fi

nohup setsid "$supervisor" </dev/null >> "$supervisor_log" 2>&1 &
