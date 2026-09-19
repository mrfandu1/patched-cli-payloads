#!/data/data/com.termux/files/usr/bin/bash
# One-shot installer for patched AI CLIs on native aarch64 Termux.
#
# Usage (from Termux):
#   curl -fsSL https://raw.githubusercontent.com/mrfandu1/patched-cli-payloads/main/install.sh | bash
#
# Installs Claude Code, OpenCode, Antigravity (agy), and OpenAI Codex with
# Termux-compatible patched binaries, wrappers, and the loopback proxy.
# Login state (~/.claude, ~/.codex, ~/.config) is never touched.
set -Eeuo pipefail

DIST_REPO="mrfandu1/patched-cli-payloads"
SRC_REPO="mrfandu1/patched-cli-termux"
RELEASE_TAG="payloads-v1"
BASE_URL="https://github.com/$DIST_REPO/releases/download/$RELEASE_TAG"
# Termux ships no `musl` package, so the musl runtime is fetched from Alpine.
ALPINE_BRANCH="${ALPINE_BRANCH:-v3.24}"
ALPINE_BASE="https://dl-cdn.alpinelinux.org/alpine/$ALPINE_BRANCH/main/aarch64"

PREFIX="${PREFIX:-/data/data/com.termux/files/usr}"
repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
in_repo=0
[[ -f "$repo_dir/payloads/SHA256SUMS" ]] && in_repo=1

die() { echo "ERROR: $*" >&2; exit 1; }

[[ $(uname -m) == aarch64 && $PREFIX == /data/data/com.termux/files/usr ]] \
  || die "This installer supports native aarch64 Termux only."

work_dir=$(mktemp -d "${TMPDIR:-$HOME/tmp}/patched-cli-install.XXXXXX")
trap 'rm -rf "$work_dir"' EXIT

# ---------- prerequisites ----------
for cmd in curl node zstd patchelf tar install; do
  command -v "$cmd" >/dev/null 2>&1 || {
    echo "==> Installing missing packages ($cmd)"
    pkg install -y zstd patchelf tar binutils 2>/dev/null \
      || pkg install -y zstd patchelf tar
    break
  }
done
for cmd in curl node zstd patchelf tar install; do
  command -v "$cmd" >/dev/null 2>&1 || die "missing tool: $cmd (pkg install it and rerun)"
done

mkdir -p "$HOME/bin" "$HOME/.local/bin" "$HOME/.local/share/claude-termux"

# ---------- musl runtime ----------
# `pkg install musl` fails — there is no such Termux package — but claude and
# opencode are patched to use Alpine's musl loader. Fetch that runtime and verify
# it by checksum. Done before anything is installed so a failure here leaves the
# system untouched.
if [[ ! -x "$PREFIX/lib/musl/lib/ld-musl-aarch64.so.1" ]]; then
  echo "==> Installing musl runtime (Alpine $ALPINE_BRANCH)"
  musl_dir="$PREFIX/lib/musl"
  mkdir -p "$musl_dir"
  declare -A MUSL_APKS=(
    [musl-1.2.6-r2.apk]=5e9674b7f41152fe2119093b5cb4c13eaaadb19c2d5422b2d7267913e663ee6e
    [libgcc-15.2.0-r5.apk]=369aaa6e9d099a737bad6dd3e6c2fe7bb1547ca26d22b94ee0411228f709b403
    [libstdc++-15.2.0-r5.apk]=2302e766d4e4926038ec166ecb85837ee884576115236ddb565e3a5fca4a11d7
  )
  for apk in "${!MUSL_APKS[@]}"; do
    curl --noproxy '*' -fsSL -o "$work_dir/$apk" "$ALPINE_BASE/$apk"
    printf '%s  %s\n' "${MUSL_APKS[$apk]}" "$work_dir/$apk" | sha256sum -c --quiet \
      || die "checksum mismatch for $apk"
    # An .apk is a gzipped tar. Drop Alpine's metadata, keep lib/ and usr/lib/.
    tar -xzf "$work_dir/$apk" -C "$musl_dir" \
      --exclude='.PKGINFO' --exclude='.SIGN.RSA.*'
  done
  rm -f "$musl_dir/.PKGINFO" "$musl_dir"/.SIGN.RSA.* 2>/dev/null || true
  [[ -x "$musl_dir/lib/ld-musl-aarch64.so.1" ]] || die "musl runtime install failed"
fi

# ---------- payloads ----------
fetch() { # $1 = flat asset name, $2 = local relative path
  local asset=$1 dest=$2
  mkdir -p "$work_dir/$(dirname "$dest")"
  if [[ $in_repo == 1 && -f "$repo_dir/payloads/$dest" ]]; then
    cp "$repo_dir/payloads/$dest" "$work_dir/$dest"
  else
    # Bootstrap downloads must never depend on the loopback proxy: it is not
    # started until further down, and may be dead on a re-run.
    curl --noproxy '*' -fL --retry 3 -C - -o "$work_dir/$dest" "$BASE_URL/$asset"
  fi
}

echo "==> Downloading payloads (release $RELEASE_TAG from $DIST_REPO)"
# Release assets are flat-named; mapped to subdirs locally.
declare -A ASSETS=(
  [claude/claude.bin.zst]=claude.bin.zst
  [opencode/opencode.bin.zst]=opencode.bin.zst
  [antigravity/agy.bin.zst]=agy.bin.zst
  [codex/codex.bin.zst]=codex.bin.zst
  [codex/codex-code-mode-host.bin.zst]=codex-code-mode-host.bin.zst
)
for dest in "${!ASSETS[@]}"; do
  fetch "${ASSETS[$dest]}" "$dest"
done

echo "==> Verifying checksums"
verify_sums() { # $1 = sums file (paths may carry a payloads/ prefix)
  (cd "$work_dir" && sed 's|  payloads/|  |' "$1" | sha256sum -c --quiet) \
    || die "checksum mismatch — aborting"
}
if [[ $in_repo == 1 ]]; then
  verify_sums "$repo_dir/payloads/SHA256SUMS"
else
  curl --noproxy '*' -fsSL -o "$work_dir/SHA256SUMS" "$BASE_URL/SHA256SUMS"
  verify_sums "$work_dir/SHA256SUMS"
fi

echo "==> Decompressing payloads"
zstd -d -f "$work_dir/claude/claude.bin.zst" -o "$work_dir/claude.bin"
zstd -d -f "$work_dir/opencode/opencode.bin.zst" -o "$work_dir/opencode.bin"
zstd -d -f "$work_dir/antigravity/agy.bin.zst" -o "$work_dir/agy.bin"
zstd -d -f "$work_dir/codex/codex.bin.zst" -o "$work_dir/codex.bin"
zstd -d -f "$work_dir/codex/codex-code-mode-host.bin.zst" -o "$work_dir/codex-host.bin"

# ---------- npm packages (provides JS entry points + package metadata) ----------
# No shell-wide proxy exports. Only the musl-linked CLIs need the loopback proxy,
# and the wrappers installed below scope it to their own processes. Exporting it
# here would route this script's own npm calls through 127.0.0.1:18080 — which is
# not listening until the proxy is brought up further down, and may be dead on a
# re-run, breaking the install of the very thing that starts it.
export SSL_CERT_FILE="${SSL_CERT_FILE:-$PREFIX/etc/tls/cert.pem}"

proxy_up() { (echo > /dev/tcp/127.0.0.1/18080) 2>/dev/null; }
install_proxy() {
  if [[ $in_repo == 1 ]]; then
    install -m 644 "$repo_dir/proxy/local-proxy.js" "$HOME/bin/local-proxy.js"
    install -m 700 "$repo_dir/proxy/start-local-proxy.sh" "$HOME/bin/start-local-proxy.sh"
    install -m 700 "$repo_dir/proxy/ensure-local-proxy.sh" "$HOME/bin/ensure-local-proxy.sh"
  else
    # standalone: fetch proxy scripts from the public distribution repo
    local raw="https://raw.githubusercontent.com/$DIST_REPO/main/proxy"
    curl --noproxy '*' -fsSL -o "$HOME/bin/local-proxy.js"        "$raw/local-proxy.js"
    curl --noproxy '*' -fsSL -o "$HOME/bin/start-local-proxy.sh"  "$raw/start-local-proxy.sh"
    curl --noproxy '*' -fsSL -o "$HOME/bin/ensure-local-proxy.sh" "$raw/ensure-local-proxy.sh"
    chmod 644 "$HOME/bin/local-proxy.js"
    chmod 700 "$HOME/bin/start-local-proxy.sh" "$HOME/bin/ensure-local-proxy.sh"
  fi
}
if ! proxy_up; then
  install_proxy
  "$HOME/bin/ensure-local-proxy.sh" 2>/dev/null || true
  for _ in {1..20}; do proxy_up && break; sleep 0.25; done
fi

install_pkg() { # pkg_name version
  local have
  have=$(grep -m1 '"version"' "$PREFIX/lib/node_modules/$1/package.json" 2>/dev/null | grep -o '[0-9][^"]*' || true)
  if [[ $have == "$2" ]]; then
    echo "   $1@$2 already installed"
  else
    npm install -g "$1@$2" --force 2>&1 | grep -E '^(added|changed|removed)' || true
  fi
}

echo "==> Installing npm packages"
CODEX_VER=0.154.0
install_pkg @anthropic-ai/claude-code 2.1.260
install_pkg opencode-ai 1.18.27
install_pkg @openai/codex "$CODEX_VER"

# ---------- binaries ----------
echo "==> Installing patched binaries and wrappers"

# Claude Code (musl)
patchelf --set-interpreter "$PREFIX/lib/musl/lib/ld-musl-aarch64.so.1" \
  --set-rpath "$PREFIX/lib/musl/lib:$PREFIX/lib/musl/usr/lib" \
  "$work_dir/claude.bin"
install -m 755 "$work_dir/claude.bin" "$HOME/.local/share/claude-termux/claude"

# OpenCode (musl)
mkdir -p "$PREFIX/lib/node_modules/opencode-ai/bin"
install -m 755 "$work_dir/opencode.bin" "$PREFIX/lib/node_modules/opencode-ai/bin/opencode.exe"
patchelf --set-interpreter "$PREFIX/lib/musl/lib/ld-musl-aarch64.so.1" \
  --set-rpath "$PREFIX/lib/musl/lib:$PREFIX/lib/musl/usr/lib" \
  "$PREFIX/lib/node_modules/opencode-ai/bin/opencode.exe"

# Antigravity (glibc)
install -m 755 "$work_dir/agy.bin" "$HOME/.local/bin/agy.bin"
patchelf --set-rpath "$PREFIX/glibc/lib" "$HOME/.local/bin/agy.bin"

# Codex (static musl — vendor package placement)
DEST="$PREFIX/lib/node_modules/@openai/codex/node_modules/@openai/codex-linux-arm64"
mkdir -p "$DEST/vendor/aarch64-unknown-linux-musl/bin"
install -m 755 "$work_dir/codex.bin" "$DEST/vendor/aarch64-unknown-linux-musl/bin/codex"
install -m 755 "$work_dir/codex-host.bin" "$DEST/vendor/aarch64-unknown-linux-musl/bin/codex-code-mode-host"
# minimal package.json so require.resolve finds it
if [[ ! -f "$DEST/package.json" ]]; then
  printf '{"name":"@openai/codex-linux-arm64","version":"%s-linux-arm64"}\n' "$CODEX_VER" > "$DEST/package.json"
fi

# glibc runtime — musl is handled near the top, since it is not a Termux package.
if [[ ! -x "$PREFIX/glibc/lib/ld-linux-aarch64.so.1" ]]; then
  echo "==> Installing glibc runtime"
  pkg install -y glibc-repo 2>/dev/null || true
  pkg install -y glibc
fi

# ---------- wrappers ----------
if [[ $in_repo == 1 ]]; then
  rm -f "$PREFIX/bin/claude" "$PREFIX/bin/opencode"
  install -m 755 "$repo_dir/wrappers/claude" "$PREFIX/bin/claude"
  install -m 755 "$repo_dir/wrappers/opencode" "$PREFIX/bin/opencode"
  install -m 755 "$repo_dir/wrappers/agy" "$HOME/.local/bin/agy"
else
  # standalone mode: write wrappers directly
  rm -f "$PREFIX/bin/claude" "$PREFIX/bin/opencode"
  # Standalone mode has no checkout to copy wrappers from. The proxy is scoped to
  # each CLI process — see wrappers/claude for why it must not be shell-wide.
  printf '#!%s\n%s\n' "$PREFIX/bin/bash" "unset LD_PRELOAD
export DISABLE_AUTOUPDATER=1
export HTTP_PROXY=http://127.0.0.1:18080
export HTTPS_PROXY=http://127.0.0.1:18080
export NO_PROXY=localhost,127.0.0.1
export SSL_CERT_FILE=\"\${SSL_CERT_FILE:-$PREFIX/etc/tls/cert.pem}\"
if [ -x \"\$HOME/bin/ensure-local-proxy.sh\" ]; then \"\$HOME/bin/ensure-local-proxy.sh\" >/dev/null 2>&1; fi
exec \"\$HOME/.local/share/claude-termux/claude\" \"\$@\"" > "$PREFIX/bin/claude"
  printf '#!%s\n%s\n' "$PREFIX/bin/bash" "unset LD_PRELOAD
export HTTP_PROXY=http://127.0.0.1:18080
export HTTPS_PROXY=http://127.0.0.1:18080
export NO_PROXY=localhost,127.0.0.1
export SSL_CERT_FILE=\"\${SSL_CERT_FILE:-$PREFIX/etc/tls/cert.pem}\"
if [ -x \"\$HOME/bin/ensure-local-proxy.sh\" ]; then \"\$HOME/bin/ensure-local-proxy.sh\" >/dev/null 2>&1; fi
exec $PREFIX/lib/node_modules/opencode-ai/bin/opencode.exe \"\$@\"" > "$PREFIX/bin/opencode"
  # Antigravity is glibc-linked and resolves DNS through Termux's patched
  # $PREFIX/glibc/etc/resolv.conf, so it needs no proxy.
  printf '#!%s\n%s\n' "$PREFIX/bin/bash" "exec env -u LD_PRELOAD $PREFIX/glibc/lib/ld-linux-aarch64.so.1 \\
  --library-path $PREFIX/glibc/lib \\
  \"\$HOME/.local/bin/agy.bin\" \"\$@\"" > "$HOME/.local/bin/agy"
  chmod 755 "$PREFIX/bin/claude" "$PREFIX/bin/opencode" "$HOME/.local/bin/agy"
fi

# codex entry: the npm shim uses a #!/usr/bin/env shebang that does not exist on
# Termux, so this replaces it. It stays a node script rather than a bash wrapper
# on purpose: with a script file, process.argv keeps the script path at [1] and
# user arguments at [2], which `node -e` would shift. Codex's CLI is a JS launcher
# for a static musl Rust binary, so the proxy has to sit in the environment that
# child inherits — set it on process.env before the dynamic import.
rm -f "$PREFIX/bin/codex"
printf '#!%s\n%s\n' "$PREFIX/bin/node" "process.env.HTTP_PROXY = 'http://127.0.0.1:18080';
process.env.HTTPS_PROXY = 'http://127.0.0.1:18080';
process.env.NO_PROXY = 'localhost,127.0.0.1';
process.env.SSL_CERT_FILE = process.env.SSL_CERT_FILE || '$PREFIX/etc/tls/cert.pem';
import('$PREFIX/lib/node_modules/@openai/codex/bin/codex.js')" > "$PREFIX/bin/codex"
chmod 755 "$PREFIX/bin/codex"

# ---------- proxy ----------
echo "==> Ensuring loopback proxy"
proxy_up || { install_proxy; "$HOME/bin/ensure-local-proxy.sh" 2>/dev/null || true; }

echo
echo "Installed:"
for c in claude opencode agy codex; do
  printf '  %-10s ' "$c"
  command -v "$c" >/dev/null 2>&1 && timeout 30 "$c" --version 2>&1 | head -1 || echo "(not on PATH)"
done
echo
# A loopback proxy exported shell-wide is a foot-gun: Android can kill the
# supervisor at any time, after which every command in that shell — including a
# plain `curl` — fails with a connection refusal.
for rc in "$HOME/.bashrc" "$HOME/.profile"; do
  [[ -f $rc ]] || continue
  if grep -qE '(HTTPS?_PROXY|ALL_PROXY)=.*127\.0\.0\.1:18080' "$rc"; then
    echo "WARNING: $rc exports a loopback proxy for the whole shell."
    echo "  Remove those lines. The CLI wrappers set the proxy for themselves, and"
    echo "  leaving them breaks curl and npm whenever the supervisor is down."
    echo
  fi
done
echo "Next steps:"
echo "  1. Add to ~/.bashrc (PATH and cert bundle only — do NOT export a proxy there):"
echo "     export SSL_CERT_FILE=\$PREFIX/etc/tls/cert.pem DISABLE_AUTOUPDATER=1"
echo "     export PATH=\"\$HOME/.local/bin:\$HOME/bin:\$PATH\""
echo "  2. Log in to each CLI (claude, codex login --device-auth, agy, opencode auth login)"
echo "  See shell/bashrc.example and README.md for details."
echo
echo "  claude, opencode and codex set the loopback proxy inside their own wrappers,"
echo "  so a shell-wide HTTPS_PROXY is never needed. agy resolves DNS on its own."
