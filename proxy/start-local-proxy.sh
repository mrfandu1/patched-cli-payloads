#!/data/data/com.termux/files/usr/bin/bash

# Keep the loopback CONNECT proxy alive without creating duplicate instances.
set -u
umask 077

user_home="${HOME:?HOME is required}"
script_dir="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
proxy_script="${PROXY_SCRIPT:-$script_dir/local-proxy.js}"
node_bin="${NODE_BIN:-/data/data/com.termux/files/usr/bin/node}"
curl_bin="${CURL_BIN:-/data/data/com.termux/files/usr/bin/curl}"
log_file="${PROXY_LOG:-$user_home/.local-proxy.log}"
lock_dir="${PROXY_LOCK:-$user_home/.local-proxy-supervisor.lock}"
proxy_url="${PROXY_URL:-http://127.0.0.1:18080}"
max_log_bytes=1048576

log() {
  printf '%s %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*" >> "$log_file"
}

rotate_log() {
  [ -f "$log_file" ] || return 0
  local bytes
  bytes="$(wc -c < "$log_file" 2>/dev/null || printf '0')"
  if [ "$bytes" -ge "$max_log_bytes" ]; then
    mv -f "$log_file" "$log_file.1" 2>/dev/null || :
  fi
}

cleanup() {
  if [ -r "$lock_dir/pid" ] && [ "$(cat "$lock_dir/pid" 2>/dev/null || true)" = "$$" ]; then
    rm -rf "$lock_dir"
  fi
}

stop() {
  cleanup
  exit 0
}

trap cleanup EXIT
trap stop INT TERM HUP

if mkdir "$lock_dir" 2>/dev/null; then
  printf '%s\n' "$$" > "$lock_dir/pid"
else
  owner="$(cat "$lock_dir/pid" 2>/dev/null || true)"
  case "$owner" in
    ''|*[!0-9]*) ;;
    *)
      if kill -0 "$owner" 2>/dev/null; then
        exit 0
      fi
      ;;
  esac
  rm -rf "$lock_dir" 2>/dev/null || exit 1
  mkdir "$lock_dir" || exit 1
  printf '%s\n' "$$" > "$lock_dir/pid"
fi

proxy_is_healthy() {
  [ -x "$curl_bin" ] || return 1
  local status
  status="$("$curl_bin" --noproxy '' -sS -m 2 -o /dev/null -w '%{http_code}' \
    -x "$proxy_url" 'http://127.0.0.1:18080' 2>/dev/null || true)"
  [ "$status" = "405" ]
}

log "proxy supervisor started pid=$$ script=$proxy_script"
while :; do
  if proxy_is_healthy; then
    sleep 10
    continue
  fi

  if [ ! -f "$proxy_script" ]; then
    log "proxy script missing: $proxy_script"
    sleep 10
    continue
  fi
  if [ ! -x "$node_bin" ]; then
    log "node executable missing: $node_bin"
    sleep 10
    continue
  fi

  rotate_log
  log "starting proxy"
  "$node_bin" "$proxy_script" >> "$log_file" 2>&1
  status=$?
  log "proxy exited status=$status; restarting in 2s"
  sleep 2
done
