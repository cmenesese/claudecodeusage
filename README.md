# Claude Usage

<p align="center">
  <img src="Xnapper-2026-01-09-11.22.53.png" alt="Claude Usage Screenshot" width="300">
</p>

A lightweight macOS menubar app that shows your Claude Code usage limits at a glance, and — in this fork — your LiteLLM proxy spend alongside it.

## Features

### Usage tracking
- 📊 **Session, Weekly & per-model limits** - including model-scoped weekly caps (e.g. Fable/Opus) as Anthropic rolls them out
- 💵 **Overage tracking** - extra-usage spend against your monthly limit
- 🚦 **Color-coded status** - Green (OK), Yellow (>70%), Red (>90%)
- ⏱️ **Time until reset** for each limit
- 🔄 **Auto-refresh** every 5 minutes, with retry on network/keychain hiccups and refresh on wake from sleep

### Multi-account (`CLAUDE_CONFIG_DIR`)
- 👥 **Per-account usage, live and simultaneously** - if you run multiple Claude accounts via `CLAUDE_CONFIG_DIR` (e.g. `~/.claude-accounts/work`, `~/.claude-accounts/personal`), the app discovers each one automatically and shows its own session/weekly/model limits, independently, without needing an open `claude` session for either
- 🏷️ **Menu bar label cycles** through each account's status when more than one is configured
- 🔁 **Falls back to single-account mode** automatically if `~/.claude-accounts/` doesn't exist - nothing changes for everyone else

### LiteLLM spend
- 🔐 **Email + password login** against your LiteLLM proxy (`POST /v2/login`) - no static API key to copy around; the app derives your `user_id` and a session key from the login response
- 🔑 **Password read from Keychain** (`com.litellm-password`, account = your email) - the app never writes it, only reads it
- 💾 **Session cached in memory only** - logs in once per app launch (or after a 401/403), never on every 5-minute refresh, so it doesn't pile up session keys on the proxy
- 💵 **Budget + today's activity** in the popover - current period spend vs. limit, reset countdown, tokens, and ok/failed request counts

### Claude status outage alerts
- 🌡️ **macOS notifications** when [status.claude.com](https://status.claude.com) reports a problem, and again on recovery - checked every 5 minutes, on by default

### General
- 🚀 **Launch at Login** toggle
- 🪶 **Lightweight** - Native Swift, minimal resources, no frameworks

## Installation

### Build from Source

```bash
git clone https://github.com/cmenesese/claudecodeusage.git
cd claudecodeusage
open ClaudeUsage.xcodeproj
```

Then build with ⌘B and run with ⌘R.

## Requirements

- macOS 13.0 (Ventura) or later
- Claude Code CLI installed and logged in
- A LiteLLM proxy account (optional - only needed for the LiteLLM spend section)

## Setup

### Claude Code usage

1. Install [Claude Code](https://claude.ai/code) if you haven't already:
   ```bash
   npm install -g @anthropic-ai/claude-code
   ```
2. Log in to Claude Code:
   ```bash
   claude
   ```
3. Launch Claude Usage - it will read your credentials from Keychain automatically

### LiteLLM spend (optional)

1. Save your LiteLLM account password in Keychain, with the account name set to your login email:
   ```bash
   security add-generic-password -s com.litellm-password -a you@example.com -w
   ```
2. Open the popover → gear icon → enter your **Proxy URL** and **Email**
3. Click **Test Connection** to confirm the login works

## How It Works

Claude Usage reads your Claude Code OAuth credentials from macOS Keychain and queries the usage API endpoint at `api.anthropic.com/api/oauth/usage`.

**Note:** This uses an undocumented API that could change at any time. The app will gracefully handle API changes but may stop working if Anthropic modifies the endpoint.

### Multi-account credential lookup

When `CLAUDE_CONFIG_DIR` is set (e.g. by a shell function that runs `CLAUDE_CONFIG_DIR="$HOME/.claude-accounts/work" claude`), Claude Code stores that account's OAuth token under a Keychain item named `Claude Code-credentials-<hash>`, where `<hash>` is the first 8 hex characters of `SHA-256(<absolute path to CLAUDE_CONFIG_DIR>)` — e.g. `SHA-256("/Users/you/.claude-accounts/work")[:8]`. Claude Usage discovers accounts under `~/.claude-accounts/` and computes this hash per account to read each one's credentials independently.

This algorithm isn't documented by Anthropic — it was reverse-engineered by comparing calculated hashes against real Keychain item names, and could change in a future Claude Code release without notice. If a computed hash stops matching, the app shows a specific "no credential found" error for that account rather than crashing or silently showing stale data.

### LiteLLM login

`POST /v2/login` returns a JWT whose payload carries `user_id` and a session-scoped API key — the app decodes that payload (without verifying the signature; it trusts the token only because it arrived over TLS from the proxy URL you configured) and caches both in memory. Every refresh reuses that cached session; a `401`/`403` from a data call triggers exactly one re-login before giving up. See `Artifacts/litellm-password-auth-feasibility.md` for the full design and validation notes.

## Privacy

- Your credentials never leave your machine
- No analytics or telemetry
- No data sent anywhere except Anthropic's API and, if configured, your own LiteLLM proxy
- Open source - verify the code yourself

## Status Colours

| Normal | Warning | Critical |
|--------|---------|----------|
| 🟢 30% | 🟡 75% | 🔴 95% |

## Troubleshooting

### "Not logged in to Claude Code"

Run `claude` in Terminal and complete the login flow.

### App doesn't appear in menubar

Check if the app is running in Activity Monitor. Try quitting and reopening.

### Usage shows wrong values

Click the refresh button (↻) in the dropdown. If still wrong, your Claude Code session may have expired - run `claude` again.

### "LiteLLM is not configured" after entering email and Proxy URL

Confirm the Keychain entry's account name matches the email exactly:
```bash
security find-generic-password -s com.litellm-password -a you@example.com -w
```
If that fails, re-add it (see Setup above) and click the refresh button in the popover.

## License

MIT License - do whatever you want with it.

## Disclaimer

This is an unofficial tool not affiliated with Anthropic. It uses an undocumented API that may change without notice.
