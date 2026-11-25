# Updating the patched CLIs

For installs created with the one-shot curl installer on native aarch64 Termux.
Covers claude, opencode, agy (Antigravity), codex and devin.

## Quick update

Re-run the installer. It is idempotent — it re-checks each version, re-downloads
the pinned payloads, re-applies the musl/glibc loader patches, and rewrites the
wrappers. Your login state (`~/.claude`, `~/.codex`, `~/.config`) and API keys are
never touched.

```bash
curl --noproxy '*' -fsSL https://raw.githubusercontent.com/mrfandu1/patched-cli-payloads/main/install.sh | bash
```

Keep the `--noproxy '*'`. Without it, curl obeys `HTTPS_PROXY` from your
environment, and if that points at a stopped loopback proxy the download fails
before it starts. See [Troubleshooting](#curl-7-failed-to-connect-over-proxy-127001).

To read the script before running it:

```bash
curl --noproxy '*' -fsSL https://raw.githubusercontent.com/mrfandu1/patched-cli-payloads/main/install.sh -o ~/install.sh
less ~/install.sh
bash ~/install.sh
```

## Check what you have

```bash
claude --version
opencode --version
agy --version
codex --version
devin --version
```

## What "update" gets you

The installer pins exact versions. Re-running it puts you on the pinned version,
which may lag upstream if a newer release has shipped since the payloads were
built. That is deliberate: each patched binary is built from the matching npm
package, so the package version and the binary have to move together.

| CLI | Pinned version | Upstream source |
|-----|----------------|-----------------|
| Claude Code | 2.1.331 | `@anthropic-ai/claude-code` (npm) |
| OpenCode | 2.4.1 | `@opencode/cli` + `@opencode/cli-linux-arm64-musl` (npm) |
| Antigravity | 1.5.16 | Google release binary, self-updates via `agy update` |
| Codex | 0.174.0-alpha.1 | `@openai/codex` (npm) |
| Devin | 3000.14.30821 | `devin` + `devin-linux-arm64` (npm) |

To see whether a newer upstream version exists:

```bash
npm view @anthropic-ai/claude-code version
npm view @opencode/cli version
npm view @openai/codex version
npm view devin version
```

If those are higher than the table above, the payloads have not been rebuilt yet.
Re-running the installer will not get you the newer version.

## Do not run `npm update -g`

The patched binaries are not normal npm installs:

- **opencode** — v2 is assembled from `@opencode/cli` plus the platform
  optional dependency `@opencode/cli-linux-arm64-musl`; the patched binary
  lives at `$PREFIX/lib/node_modules/@opencode/cli/bin/opencode.exe`. There is
  no npm package whose postinstall survives Termux's `android` platform, so the
  upgrade script repacks the musl tarball itself.
- **claude** — the patched binary lives outside the package in
  `~/.local/share/claude-termux/`, so an npm update moves the package ahead of
  the binary and the two drift apart.
- **codex** — the vendored `vendor/aarch64-unknown-linux-musl/bin/` tree is
  assembled by the installer, not shipped by npm for Termux.
- **devin** — npm never installs `devin-linux-arm64` on Termux (its `os` field
  is `linux`, Node reports `android`), and npm relinks `$PREFIX/bin/devin` to a
  launcher with no binary to run. Re-run `scripts/install-devin-termux.sh`
  after any npm-driven upgrade.

Always let the installer move the package and the binary together.

## Troubleshooting

### `curl: (7) Failed to connect to ... over proxy 127.0.0.1`

Nothing is listening on the loopback proxy port, but something in your shell is
pointing curl at it. The `after 1 ms` timing is the tell — that is a local
connection refusal, not a network problem.

Find the source:

```bash
env | grep -i proxy
```

Then remove any `HTTP_PROXY` / `HTTPS_PROXY` / `ALL_PROXY` line from `~/.bashrc`
or `~/.profile`. A shell-wide proxy export is never needed — the wrappers set it
for the CLIs that need it. See [Why the proxy is scoped to the wrappers](#why-the-proxy-is-scoped-to-the-wrappers).

To get past it right now:

```bash
unset HTTP_PROXY HTTPS_PROXY ALL_PROXY http_proxy https_proxy all_proxy
export NO_PROXY='*'
curl -fsSL https://raw.githubusercontent.com/mrfandu1/patched-cli-payloads/main/install.sh | bash
unset NO_PROXY
```

### claude, opencode or codex cannot reach the network

The proxy supervisor died — Android kills background processes when Termux is
force-stopped or the device reboots. Restart it:

```bash
~/bin/ensure-local-proxy.sh
```

Confirm it is listening (you want `405`, which is the proxy answering):

```bash
curl --noproxy '*' -sS -m 2 -o /dev/null -w '%{http_code}\n' -x http://127.0.0.1:18080 http://127.0.0.1:18080
```

The wrappers call `ensure-local-proxy.sh` before starting a CLI, so this should
self-heal. A stale shell-wide export will not.

### `agy` works but the others do not

Expected, and not a bug. Antigravity is glibc-linked and Termux patches glibc to
read `$PREFIX/glibc/etc/resolv.conf`, so it resolves DNS itself. claude, opencode
and codex are musl-linked, and musl only ever reads the absolute
`/etc/resolv.conf` — a file Android does not provide and that cannot be created
without root. Those three must go through the proxy.

### `agy` exits 2 with no output on tasks that create or edit files

Plain prompts answer normally; anything that runs a tool dies silently with exit
code 2, sometimes after the file was already written. This is Android's seccomp
policy killing `faccessat2`, a syscall this kernel predates. Full explanation in
[`agy-sandbox-crash.md`](agy-sandbox-crash.md).

The installer patches it, so a normal install is already fixed. If it comes back
— most likely after `agy update`, which replaces the binary — re-run the
installer, or re-apply the patch directly:

```bash
node scripts/patch-agy-faccessat2.js ~/.local/bin/agy.bin   # from a checkout
```

### `devin` says `unsupported platform android-arm64`

An npm install replaced the patched launcher (or the arm64 payload is missing
because npm skipped the optional dependency). Repair both in one step:

```bash
scripts/install-devin-termux.sh
```

### `devin --sandbox` refuses to start

Expected. The bwrap+seccomp sandbox needs unprivileged user namespaces, and
Android refuses them (`unshare -Ur` → `EINVAL`); Termux has no bubblewrap
package either. Run without `--sandbox`. Details in
[`devin-termux.md`](devin-termux.md#sandbox).


## Why the proxy is scoped to the wrappers

The loopback CONNECT proxy exists for exactly one reason: musl binaries cannot
resolve DNS on Android. Termux-native tools — curl, npm, git, node — are
bionic-linked and use Android's resolver directly, so they must *not* be proxied.

Exporting `HTTPS_PROXY` shell-wide routes every command through
`127.0.0.1:18080`. As soon as the supervisor is down, curl and npm break, and so
does the installer's own download step — which is the failure described above.

So each wrapper sets the proxy for its own process only:

| Command | Proxy | Why |
|---------|-------|-----|
| `claude` | yes | musl |
| `opencode` | yes | musl |
| `codex` | yes | static musl Rust binary behind a JS launcher |
| `agy` | no | glibc with Termux's patched resolver |
| `devin` | no | static ELF, bundles hickory-dns |
| `curl`, `npm`, `git`, node | no | bionic |

## Maintainer path

From a checkout of `mrfandu1/patched-cli-termux`:

```bash
scripts/upgrade-all.sh
```

That re-packs the musl/glibc executables from upstream npm packages, re-applies
the loader patches, reinstalls the wrappers, and finishes with `scripts/smoke-test.sh`.
Devin is covered by the same run through `scripts/install-devin-termux.sh`, which
resolves the current npm version itself instead of using a pin.

Shipping a genuinely newer pinned version needs the payloads regenerated and the
current release assets plus `SHA256SUMS` re-uploaded — the installer
verifies checksums, so the release and the pinned versions in `install.sh` have to
be bumped in the same pass. Devin is the exception: its payload comes from the npm
registry by version, so bumping `DEVIN_VER` in `install.sh` is enough.
