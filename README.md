# patched-cli-payloads

Public distribution of checksummed, patched ARM64 CLI binaries for native Termux.
This repo holds release assets only — source, wrappers, and upgrade scripts live in
the companion repo.

Please always use the `curl --noproxy '*'` form above, and read
[`docs/updating.md`](docs/updating.md) before updating: it covers the
`curl: (7) ... over proxy 127.0.0.1` failure, which is caused by a stale shell-wide
`HTTPS_PROXY` in `~/.bashrc` rather than by the installer.

## Install

```bash
curl --noproxy '*' -fsSL https://raw.githubusercontent.com/mrfandu1/patched-cli-payloads/main/install.sh | bash
```

## Contents (payloads-v1)

| CLI | Version |
|-----|---------|
| Claude Code | 2.1.260 |
| OpenCode | 1.18.27 |
| Antigravity | 1.1.25 |
| Codex | 0.154.0 |

Antigravity also needs a one-instruction binary patch: Android's seccomp policy
kills `faccessat2`, a syscall this kernel predates, which Go's `Eaccess` calls with
no fallback, so agy died on any task that ran a tool. The installer rewrites it to
`faccessat`. See [`docs/agy-sandbox-crash.md`](docs/agy-sandbox-crash.md).

Assets are vendor binaries with Termux loader patches — no login state, API keys,
or device configuration. Verify with the published `SHA256SUMS`.
