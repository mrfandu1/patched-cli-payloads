# Devin CLI on Termux

`devin` (Devin for Terminal) is a Rust TUI shipped as a per-platform npm optional
dependency. The linux-arm64 payload is a **statically linked aarch64 ELF with no
`PT_INTERP`**, so it needs no musl/glibc runtime, no loader patch, and no
`LD_LIBRARY_PATH`. It also carries hickory-dns and resolves DNS itself, so unlike
claude/opencode/codex it needs no loopback proxy.

Everything that breaks is in npm's install path and the JS launcher, not in the
binary.

## Status

| Feature | State |
|---|---|
| TUI, sessions, `-p/--print`, daemon, ACP | works |
| `devin auth login` (manual token flow) | works |
| `devin auth login` (browser flow) | opens nothing, prints no URL — use the manual flow |
| `devin doctor`, `models`, `rules`, `skills`, `plugins` | works |
| `devin ssh` / `devin forward` | needs `pkg install openssh` |
| `devin desktop` | no — it launches the Electron desktop app, which is not packaged for Termux |
| `--sandbox` / `/mode autonomous` | no — see [Sandbox](#sandbox) |

## Why the stock install fails

```console
$ npm install -g devin
added 1 package in 5s
$ devin --version
/usr/bin/env: bad interpreter: No such file or directory
```

1. `devin` has no binary of its own. It pulls `devin-linux-arm64` through
   `optionalDependencies`, and npm matches those against `process.platform`.
   Termux reports `android`, the payload declares `os: ["linux"]`, so npm drops
   it silently — the launcher is installed with nothing to launch.
2. The launcher's shebang is `#!/usr/bin/env node`; there is no `/usr/bin/env`
   on Termux.
3. The launcher builds `"${process.platform}-${process.arch}"` and checks it
   against a fixed allow-list that contains `linux-arm64`, not `android-arm64`.

`scripts/install-devin-termux.sh` fixes all three: it installs the launcher
package, unpacks the arm64 payload from the npm registry next to it, patches the
launcher (shebang + android→linux platform map), and installs `wrappers/devin`,
which execs the payload directly.

## Install

From a checkout:

```bash
scripts/install-devin-termux.sh
```

Or through the one-shot installer, which now covers devin as well:

```bash
curl --noproxy '*' -fsSL https://raw.githubusercontent.com/mrfandu1/patched-cli-payloads/main/install.sh | bash
```

Pin a version, or inspect what is on disk without changing anything:

```bash
DEVIN_VER=3000.14.30821 scripts/install-devin-termux.sh
scripts/install-devin-termux.sh --check
```

The script is idempotent. It installs the 204 man pages from the payload into
`$PREFIX/share/man/man1` as well.

## Updating

There are three ways devin moves, and they need different handling.

### 1. Re-run the installer (recommended)

```bash
curl --noproxy '*' -fsSL https://raw.githubusercontent.com/mrfandu1/patched-cli-payloads/main/install.sh | bash
```

or, from a checkout:

```bash
scripts/install-devin-termux.sh          # newest upstream from npm
scripts/upgrade-all.sh                   # everything, including devin
```

The script resolves the current `devin` version from npm, installs the launcher
at that version, replaces the payload if its version differs, re-applies the
launcher patch, and rewrites the wrapper. Login state
(`~/.local/share/devin/credentials.toml`, `~/.config/devin/`) is not touched.

### 2. After a manual `npm install -g devin@latest`

npm relinks `$PREFIX/bin/devin` to `bin/devin.js` and, on Termux, installs no
payload. The CLI then fails with "unsupported platform android-arm64" (the
patched launcher keeps working, but only until npm replaces the launcher
itself). Repair:

```bash
scripts/install-devin-termux.sh
```

That is the whole recovery — the payload download is the only slow part
(~85 MB compressed).

### 3. `devin update` / `/update`

For npm-managed installs devin does not replace itself; it prints the npm
command (`npm install -g devin@latest`). Treat that as case 2 and re-run the
install script afterwards.

Background update checks can be turned off in `~/.config/devin/config.json`:

```json
{
  "version": 1,
  "auto_update": false
}
```

The key is part of devin's own settings schema (`devin doctor` stays clean with
it set), and it keeps the CLI from suggesting an upgrade it cannot apply by
itself on Termux.

## Login

The browser flow starts a localhost callback listener and tries to open a
browser. On Termux no opener exists and no URL is printed, so it sits on
"Waiting for login in browser...". Use the manual flow:

```bash
devin auth login      # choose "2 Paste a token manually"
```

It prints an `app.devin.ai/auth/cli/continue?...` URL with a PKCE challenge;
sign in, copy the code, paste it back. Credentials land in
`~/.local/share/devin/credentials.toml`.

Check state with `devin auth status`.

## Sandbox

`--sandbox` and `/mode autonomous` cannot work on Termux, and this is not a
packaging gap that a patch can close:

- devin's Linux sandbox is `bwrap` + `seccomp`. bubblewrap needs unprivileged
  user namespaces.
- Android refuses them: `unshare -Ur true` returns `EINVAL` on this device.
- There is no `bubblewrap` package in the Termux repos (main or TUR), and
  building it would not help — the kernel and seccomp policy are the blocker.

`socat` is packaged and installed, but it is the smaller half of the
requirement; without `bwrap` the sandbox still cannot start.

`wrappers/devin` fails fast instead of letting the CLI die after a prompt:

```console
$ devin --sandbox
devin: --sandbox cannot work on Termux.
  Android blocks unprivileged user namespaces (unshare -Ur -> EINVAL) and there
  is no bubblewrap package for Termux, so bwrap+seccomp has nothing to stand on.
  Run without --sandbox, or run devin inside proot-distro for an isolated box.
```

If you need real isolation, run the whole CLI inside `proot-distro` (the sandbox
flag still will not work there — proot has no namespaces either — but the agent
then runs against a disposable rootfs instead of `$HOME`).

## Uninstall

```bash
rm -f "$PREFIX/bin/devin"
rm -rf "$PREFIX/lib/node_modules/devin-linux-arm64"
npm uninstall -g devin
rm -rf ~/.local/share/devin ~/.config/devin     # credentials and sessions
```

## Troubleshooting

### `unsupported platform android-arm64`

The launcher patch was overwritten by an npm install. Re-run
`scripts/install-devin-termux.sh`.

### `the devin-linux-arm64 package is not installed`

Same cause: npm skipped the optional dependency. The install script fetches it
directly from the registry.

### `devin` starts, then cannot reach the API

The payload resolves DNS itself (it bundles hickory-dns) and works without
`/etc/resolv.conf`, which Android does not provide. A blocked or unreachable
resolver shows up in `~/.local/share/devin/cli/logs/` as
`remote config revalidation failed ... operation timed out`; sessions still
work as long as the API host itself resolves. This device logs that warning for
`unleash.codeium.com` (feature flags) while `app.devin.ai` answers normally.
