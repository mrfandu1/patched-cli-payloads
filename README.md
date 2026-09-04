# patched-cli-payloads

Public distribution of checksummed, patched ARM64 CLI binaries for native Termux.
This repo holds release assets only — source, wrappers, and upgrade scripts live in
the companion repo.

## Install

```bash
curl -fsSL https://raw.githubusercontent.com/mrfandu1/patched-cli-termux/main/install.sh | bash
```

## Contents (payloads-v1)

| CLI | Version |
|-----|---------|
| Claude Code | 2.1.260 |
| OpenCode | 1.18.27 |
| Antigravity | 1.1.25 |
| Codex | 0.153.2 |

Assets are vendor binaries with Termux loader patches — no login state, API keys,
or device configuration. Verify with the published `SHA256SUMS`.
