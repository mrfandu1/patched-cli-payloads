#!/data/data/com.termux/files/usr/bin/bash
# Install, repair or upgrade the Devin CLI on native aarch64 Termux.
#
# Three things break the stock npm install here:
#   1. npm reads Node's process.platform ("android") and skips the linux-arm64
#      optional dependency, so `npm i -g devin` leaves no runnable binary.
#   2. The launcher starts with #!/usr/bin/env node, and /usr/bin/env does not
#      exist on Termux.
#   3. The launcher's platform allow-list has no "android-arm64" entry.
#
# The payload itself needs no patch: devin-<ver>-linux-arm64 ships a statically
# linked aarch64 ELF (no PT_INTERP), so it runs on bionic as-is.
#
# Idempotent. Re-run it after any `npm install -g devin` / `npm update -g`.
#
# Usage:
#   scripts/install-devin-termux.sh                  # newest upstream
#   scripts/install-devin-termux.sh --check          # report only
#   DEVIN_VER=3000.14.30821 scripts/install-devin-termux.sh
#   scripts/install-devin-termux.sh --wrapper FILE   # use a downloaded wrapper
set -Eeuo pipefail

PREFIX="${PREFIX:-/data/data/com.termux/files/usr}"
REGISTRY="https://registry.npmjs.org"
DEVIN_VER="${DEVIN_VER:-}"
WRAPPER=""
CHECK_ONLY=0

while (($#)); do
  case $1 in
    --check) CHECK_ONLY=1 ;;
    --wrapper)
      WRAPPER="${2:?--wrapper needs a path}"
      shift
      ;;
    --version)
      DEVIN_VER="${2:?--version needs a value}"
      shift
      ;;
    -h | --help)
      sed -n '2,20p' "$0"
      exit 0
      ;;
    *)
      echo "unknown argument: $1" >&2
      exit 2
      ;;
  esac
  shift
done

[[ $(uname -m) == aarch64 ]] || {
  echo "This script supports aarch64 Termux only." >&2
  exit 1
}
[[ $PREFIX == /data/data/com.termux/files/usr ]] || {
  echo "This script supports a native Termux prefix only." >&2
  exit 1
}

launcher_dir="$PREFIX/lib/node_modules/devin"
payload_dir="$PREFIX/lib/node_modules/devin-linux-arm64"

pkg_version() { # $1 = package dir
  node -p "require('$1/package.json').version" 2>/dev/null || true
}

have_launcher=$(pkg_version "$launcher_dir")
have_payload=$(pkg_version "$payload_dir")

if ((CHECK_ONLY)); then
  printf 'launcher %-24s %s\n' "$launcher_dir" "${have_launcher:-absent}"
  printf 'payload  %-24s %s\n' "$payload_dir" "${have_payload:-absent}"
  printf 'binary   %-24s %s\n' "$payload_dir/bin/devin" \
    "$([[ -x $payload_dir/bin/devin ]] && echo present || echo absent)"
  printf 'wrapper  %-24s %s\n' "$PREFIX/bin/devin" \
    "$([[ -f $PREFIX/bin/devin ]] && head -1 "$PREFIX/bin/devin" | grep -q 'bash' && echo present || echo 'npm symlink or absent')"
  [[ -x $payload_dir/bin/devin ]] && "$payload_dir/bin/devin" --version || true
  exit 0
fi

[[ -n $DEVIN_VER ]] || DEVIN_VER=$(npm view devin version 2>/dev/null | tail -1)
[[ -n $DEVIN_VER ]] || {
  echo "could not resolve the devin version from npm" >&2
  exit 1
}
echo "==> Devin CLI $DEVIN_VER"

# ---------- npm launcher ----------
# The launcher package is still worth installing: it owns bin/devin.js and the
# package metadata, and `npm install -g devin@latest` is how upstream expects
# upgrades to arrive. The arm64 payload is fetched separately below.
if [[ $have_launcher != "$DEVIN_VER" ]]; then
  npm install -g "devin@$DEVIN_VER" --force 2>&1 | grep -E '^(added|changed|removed)' || true
else
  echo "   launcher already at $DEVIN_VER"
fi

# ---------- native payload ----------
if [[ $have_payload != "$DEVIN_VER-linux-arm64" || ! -x $payload_dir/bin/devin ]]; then
  echo "   fetching devin@$DEVIN_VER linux-arm64 payload"
  tmp=$(mktemp -d "${TMPDIR:-$HOME/tmp}/devin-payload.XXXXXX")
  trap 'rm -rf "$tmp"' EXIT
  # Never through the loopback proxy: this download must work even when the
  # proxy supervisor is dead.
  curl --noproxy '*' -fsSL --retry 3 -o "$tmp/payload.tgz" \
    "$REGISTRY/devin/-/devin-$DEVIN_VER-linux-arm64.tgz"
  rm -rf "$payload_dir"
  mkdir -p "$payload_dir"
  tar -xzf "$tmp/payload.tgz" -C "$payload_dir" --strip-components=1
  chmod 755 "$payload_dir/bin/devin"
else
  echo "   payload already at $DEVIN_VER-linux-arm64"
fi

# ---------- launcher patch ----------
# Keeps `node .../devin/bin/devin.js` and npx-style invocations working. The
# wrapper below bypasses the launcher, but npm relinks $PREFIX/bin/devin to the
# launcher on every install, so both paths have to be usable.
DEVIN_LAUNCHER="$launcher_dir/bin/devin.js" TERMUX_PREFIX="$PREFIX" node -e '
const fs = require("fs");
const file = process.env.DEVIN_LAUNCHER;
const prefix = process.env.TERMUX_PREFIX;
let s = fs.readFileSync(file, "utf8");
const before = s;
s = s.replace(/^#!\/usr\/bin\/env node/, `#!${prefix}/bin/env node`);
if (!s.includes("process.platform === \"android\"")) {
  s = s.replace(
    "const platform = `${process.platform}-${process.arch}`;",
    "const osName = process.platform === \"android\" ? \"linux\" : process.platform;\n" +
      "const platform = `${osName}-${process.arch}`;",
  );
}
if (s !== before) {
  fs.writeFileSync(file, s);
  console.log("   launcher patched (shebang + android platform map)");
} else {
  console.log("   launcher already patched");
}
'

# ---------- wrapper ----------
if [[ -z $WRAPPER ]]; then
  WRAPPER="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/wrappers/devin"
fi
[[ -f $WRAPPER ]] || {
  echo "wrapper not found: $WRAPPER" >&2
  exit 1
}
# Replace npm's symlink to bin/devin.js with the wrapper. npm recreates the
# symlink on the next install; re-running this script puts the wrapper back.
rm -f "$PREFIX/bin/devin"
install -m 755 "$WRAPPER" "$PREFIX/bin/devin"
echo "   wrapper installed at $PREFIX/bin/devin"

# ---------- man pages ----------
if [[ -d $payload_dir/share/man/man1 ]]; then
  mkdir -p "$PREFIX/share/man/man1"
  cp -f "$payload_dir"/share/man/man1/devin*.1 "$PREFIX/share/man/man1/"
  echo "   man pages installed ($(ls "$payload_dir"/share/man/man1/devin*.1 | wc -l | tr -d ' '))"
fi

# ---------- verify ----------
echo "==> Verify"
"$payload_dir/bin/devin" --version
"$PREFIX/bin/devin" --version
if ! command -v bwrap >/dev/null 2>&1; then
  echo "   note: --sandbox needs bubblewrap, which Termux cannot provide; see docs/devin-termux.md"
fi
