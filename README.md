# TicketParty

<img src="docs/img/app-icon.png" width="128" height="128">

TicketParty is a macOS app for queuing up tasks for Codex to run in your project.

Read more about it [in my blog post](https://kelan.io/2026/ticket-party/).

Current status: Very early MVP. Not ready for real use! But please LMK what you think about the idea.

## Prerequisites

- macOS with Xcode installed
- Node.js + npm available on `PATH`
- Codex credentials configured for `@openai/codex-sdk` (for example, `OPENAI_API_KEY`)

## Setup (Sidecar + Supervisor)

Run this once from the repo root:

```bash
just codex-setup
```

This does the full setup:

1. Installs sidecar npm dependencies in `codex-sidecar/`
2. Builds and installs the `codex-supervisor` binary
3. Installs and starts the LaunchAgent (`io.kelan.ticketparty.codex-supervisor`)
4. Pins the supervisor to this repo's sidecar script path via `--sidecar-script`

## Useful Commands

```bash
# sidecar only
just sidecar-install
just sidecar-status

# supervisor lifecycle
just supervisor-start
just supervisor-stop
just supervisor-status
just supervisor-logs

# quick health check
just codex-doctor
```
